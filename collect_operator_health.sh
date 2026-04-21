#!/usr/bin/env bash
#
# Comprehensive Operator Health Check
#
# This script performs a comprehensive health check for operators including:
#   - Pod status and restart counts
#   - Memory leak detection
#   - Log error analysis
#   - Version verification against staging clusters
#   - Performance metrics validation
#
# Usage:
#   ./collect_operator_health.sh [OPTIONS]
#
# Output: JSON format suitable for later parsing into tables/HTML
#

set -uo pipefail

# Detect OCM environment
detect_ocm_environment() {
    local ocm_url=$(ocm config get url 2>/dev/null || echo "")

    if [[ "$ocm_url" == *"integration"* ]]; then
        echo "integration"
    elif [[ "$ocm_url" == *"stage"* ]] || [[ "$ocm_url" == *"staging"* ]]; then
        echo "stage"
    elif [[ "$ocm_url" == *"production"* ]] || [[ "$ocm_url" == "https://api.openshift.com" ]]; then
        echo "production"
    else
        echo "unknown"
    fi
}

# Get OCM environment
OCM_ENV=$(detect_ocm_environment)

# Default values
NAMESPACE="openshift-monitoring"
DEPLOYMENT="configure-alertmanager-operator"
OUTPUT_FORMAT="json"
CLUSTER_ID=""
CLUSTER_NAME=""
CLUSTER_VERSION=""
REASON=""
OPERATOR_NAME=""

# Function to discover Hive cluster managing this service cluster via OCM
# Returns the SAAS target name (e.g., "camo-<hive-cluster-name>")
discover_hive_target() {
    local cluster_id="$1"
    local ocm_env="$2"

    # For integration environment, use PKO naming convention
    if [ "$ocm_env" = "integration" ]; then
        echo "camo-pko-integration"
        return 0
    fi

    # Query OCM for provision_shard to get Hive cluster info
    local provision_shard
    provision_shard=$(ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/provision_shard" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$provision_shard" ]; then
        # Fallback to environment-based defaults if OCM query fails
        case "$ocm_env" in
            stage) echo "staging" ;;
            production) echo "production" ;;
            *) echo "unknown" ;;
        esac
        return 1
    fi

    # Extract Hive cluster name from server URL
    # Example: https://api.hive-stage-01.n1u3.p1.openshiftapps.com:6443 -> hive-stage-01
    local hive_cluster
    hive_cluster=$(echo "$provision_shard" | jq -r '.hive_config.server // empty' | sed -n 's|https://api\.\([^.]*\)\..*|\1|p')

    if [ -z "$hive_cluster" ]; then
        # Fallback if extraction fails
        case "$ocm_env" in
            stage) echo "staging" ;;
            production) echo "production" ;;
            *) echo "unknown" ;;
        esac
        return 1
    fi

    # Derive SAAS target name: camo-<hive-cluster>
    echo "camo-${hive_cluster}"
    return 0
}

# Environment-aware SAAS file mapping for CAMO
# Integration uses PKO (OLM is deprecated with delete:true)
# Stage/Production may use OLM or PKO depending on migration status
case "$OCM_ENV" in
    integration)
        DEFAULT_SAAS_FILE="saas-configure-alertmanager-operator-pko.yaml"
        ;;
    stage|production)
        DEFAULT_SAAS_FILE="saas-configure-alertmanager-operator.yaml"
        ;;
    *)
        # Unknown environment - use legacy defaults
        DEFAULT_SAAS_FILE="saas-configure-alertmanager-operator.yaml"
        ;;
esac

# Default target will be discovered dynamically after we have cluster ID
DEFAULT_TARGET_NAME="unknown"

SAAS_FILE="${SAAS_FILE:-$DEFAULT_SAAS_FILE}"
# TARGET_NAME will be set after cluster ID discovery (see below)
# Initialize with empty value for now to avoid unbound variable error
TARGET_NAME="${TARGET_NAME:-}"

# Legacy STAGING_CLUSTERS array - now replaced by TARGET_NAME but kept for compatibility
STAGING_CLUSTERS=("${STAGING_CLUSTERS[@]}")
if [ ${#STAGING_CLUSTERS[@]} -eq 0 ] && [ -n "$TARGET_NAME" ]; then
    # Use target name as the single "cluster" to check (only if TARGET_NAME is set)
    STAGING_CLUSTERS=("$TARGET_NAME")
fi

MEMORY_LEAK_THRESHOLD_PERCENT=20  # Flag if memory increases >20% over time
ERROR_LOG_THRESHOLD=0  # Number of error log lines to trigger warning (any errors = warning)
DEBUG="${DEBUG:-false}"  # Enable debug output with DEBUG=true environment variable

# Parse command line arguments
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Perform comprehensive operator health check

OPTIONS:
    --namespace, -n NAMESPACE   Namespace to query (default: openshift-monitoring)
    --deployment, -d DEPLOY     Deployment name (default: configure-alertmanager-operator)
    --format, -f FORMAT         Output format: json or csv (default: json)
    --cluster-id, -c ID         Cluster ID for tracking (auto-detected if not provided)
    --cluster-name NAME         Cluster name for display (auto-detected if not provided)
    --cluster-version VERSION   Cluster OpenShift version (auto-detected if not provided)
    --reason, -r REASON         JIRA ticket for OCM elevation
                                If not provided, will prompt interactively (default: "Checking CAMO operator health")
    --operator-name NAME        Operator name for tracking (defaults to deployment name)
    --saas-file FILE           SAAS file for version checking (default: saas-configure-alertmanager-operator.yaml)
    --target-name NAME         SAAS target name for version checking (auto-discovered from OCM if not provided)
                                Examples: camo-<hive-name>, camo-pko-integration, production
    --secrets                   Enable secret-based health checks (requires elevation, OFF by default)
    --help, -h                  Show this help message

EXAMPLES:
    # Interactive mode (will prompt for reason)
    $0

    # Check CAMO operator health with specific reason
    $0 --reason "SREP-12345 health check"

    # Check RMO operator health
    $0 -d route-monitor-operator -n openshift-route-monitor-operator \\
       --saas-file saas-route-monitor-operator.yaml -r "SREP-12345"

EOF
    exit 0
}

# Parse arguments
# Initialize flags
CHECK_SECRETS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        --deployment|-d) DEPLOYMENT="$2"; shift 2 ;;
        --format|-f) OUTPUT_FORMAT="$2"; shift 2 ;;
        --cluster-id|-c) CLUSTER_ID="$2"; shift 2 ;;
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --cluster-version) CLUSTER_VERSION="$2"; shift 2 ;;
        --reason|-r) REASON="$2"; shift 2 ;;
        --operator-name) OPERATOR_NAME="$2"; shift 2 ;;
        --saas-file) SAAS_FILE="$2"; shift 2 ;;
        --target-name) TARGET_NAME="$2"; shift 2 ;;
        --secrets) CHECK_SECRETS=true; shift ;;
        --help|-h) usage ;;
        *) echo "Error: Unknown option: $1" >&2; usage ;;
    esac
done

# Default operator name to deployment name if not specified
if [ -z "$OPERATOR_NAME" ]; then
    OPERATOR_NAME="$DEPLOYMENT"
fi

# Check if reason is provided for OCM (prompt if running interactively)
if [ -z "$REASON" ]; then
    DEFAULT_REASON="Checking CAMO operator health"

    # Check if running interactively (stdin is a terminal)
    if [ -t 0 ]; then
        echo ""
        echo "OCM Elevation Reason"
        echo "-------------------"
        echo "Default: $DEFAULT_REASON"
        echo ""
        read -p "Press Enter to use default, or type custom reason: " user_input

        if [ -z "$user_input" ]; then
            REASON="$DEFAULT_REASON"
            echo "Using default reason: $REASON"
        else
            REASON="$user_input"
            echo "Using custom reason: $REASON"
        fi
        echo ""
    else
        # Non-interactive mode (piped input or automation)
        REASON="$DEFAULT_REASON"
        echo "Note: Using default reason: $REASON" >&2
    fi
fi

# Debug logging functions
debug_log() {
    if [ "$DEBUG" = "true" ]; then
        echo "[DEBUG] $*" >&2
    fi
}

debug_var() {
    if [ "$DEBUG" = "true" ]; then
        local var_name="$1"
        local var_value="${!1:-<unset>}"
        echo "[DEBUG] $var_name=$var_value" >&2
    fi
}

add_health_check() {
    local check_data="$1"
    local check_name="${2:-unknown}"
    health_checks+=("$check_data")
    debug_log "Added health check #${#health_checks[@]}: $check_name"
}

# Function to log API errors
log_api_error() {
    local operation="$1"
    local error_message="$2"
    local exit_code="${3:-1}"

    debug_log "API Error: $operation - $error_message (exit code: $exit_code)"

    # Escape values for JSON
    local escaped_operation=$(echo "$operation" | jq -Rs . 2>/dev/null || echo "\"unknown\"")
    local escaped_error=$(echo "$error_message" | jq -Rs . 2>/dev/null || echo "\"API error\"")

    local error_entry=$(cat <<EOF
{
  "operation": $escaped_operation,
  "error_message": $escaped_error,
  "exit_code": $exit_code,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)
    api_errors+=("$error_entry")
    debug_log "Added API error entry #${#api_errors[@]}"
}

# Auto-detect cluster ID if not provided
if [ -z "$CLUSTER_ID" ]; then
    CLUSTER_ID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "unknown")
fi
debug_var CLUSTER_ID

# Auto-detect cluster name if not provided
if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME=$(ocm backplane status 2>/dev/null | grep "Cluster Name:" | awk '{print $3}' || echo "")
    if [ -z "$CLUSTER_NAME" ]; then
        CLUSTER_NAME=$(ocm get cluster "$CLUSTER_ID" 2>/dev/null | jq -r '.name // "unknown"' || echo "unknown")
    fi
fi

# Dynamically discover Hive cluster and SAAS target if not already set
if [ "$DEFAULT_TARGET_NAME" = "unknown" ] && [ "$CLUSTER_ID" != "unknown" ]; then
    DEFAULT_TARGET_NAME=$(discover_hive_target "$CLUSTER_ID" "$OCM_ENV")
    debug_log "Dynamically discovered target: $DEFAULT_TARGET_NAME"
fi

# Apply discovered target name if TARGET_NAME not explicitly set
TARGET_NAME="${TARGET_NAME:-$DEFAULT_TARGET_NAME}"
debug_var TARGET_NAME

# Suppress normal output, only show errors on stderr and data on stdout
exec 3>&1  # Save stdout
exec 1>&2  # Redirect stdout to stderr for messages

echo "================================================================================"
echo "COMPREHENSIVE OPERATOR HEALTH CHECK - Cluster: $CLUSTER_ID"
echo "================================================================================"
echo "Operator:   $OPERATOR_NAME"
echo "Namespace:  $NAMESPACE"
echo "Deployment: $DEPLOYMENT"
echo "================================================================================"
echo ""

# Get cluster version
if [ -n "$CLUSTER_VERSION" ]; then
    cluster_version="$CLUSTER_VERSION"
else
    echo "Getting cluster version..."
    cluster_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
fi
echo "Cluster version: $cluster_version"

# Get operator version from deployment image
echo "Getting operator version from deployment..."
deployment_fetch_error=$(mktemp)
operator_image=$(ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>"$deployment_fetch_error" | \
    jq -r '.spec.template.spec.containers[0].image // "unknown"' 2>/dev/null)
deployment_fetch_exit_code=$?

if [ $deployment_fetch_exit_code -ne 0 ] || [ -z "$operator_image" ] || [ "$operator_image" = "unknown" ]; then
    deployment_fetch_error_msg=$(cat "$deployment_fetch_error" 2>/dev/null | head -20)
    if [ -n "$deployment_fetch_error_msg" ]; then
        log_api_error "Get deployment $NAMESPACE/$DEPLOYMENT" "$deployment_fetch_error_msg" $deployment_fetch_exit_code
    fi
fi
rm -f "$deployment_fetch_error"

# Check for ClusterServiceVersion (CSV) which may have authoritative version info
csv_version=""
csv_git_commit=""
csv_fetch_error=$(mktemp)
csv_data=$(ocm backplane elevate "${REASON}" -- get csv -n "$NAMESPACE" -o json 2>"$csv_fetch_error" | \
    jq -r ".items[] | select(.spec.install.spec.deployments[]?.name == \"$DEPLOYMENT\") | {version: .spec.version, name: .metadata.name}" 2>/dev/null | head -1)
csv_fetch_exit_code=$?

if [ $csv_fetch_exit_code -ne 0 ]; then
    csv_fetch_error_msg=$(cat "$csv_fetch_error" 2>/dev/null | head -20)
    if [ -n "$csv_fetch_error_msg" ]; then
        log_api_error "Get ClusterServiceVersion in $NAMESPACE" "$csv_fetch_error_msg" $csv_fetch_exit_code
    fi
fi
rm -f "$csv_fetch_error"

if [ -n "$csv_data" ] && [ "$csv_data" != "null" ]; then
    csv_version=$(echo "$csv_data" | jq -r '.version // empty' 2>/dev/null)
    csv_name=$(echo "$csv_data" | jq -r '.name // empty' 2>/dev/null)
    if [ -n "$csv_version" ]; then
        echo "  Found CSV: $csv_name (version: $csv_version)"
        # Try to extract git commit from CSV version if it contains one
        if [[ "$csv_version" =~ -g([a-f0-9]+) ]]; then
            csv_git_commit="${BASH_REMATCH[1]}"
        fi
    fi
fi

# Extract version tag from image (e.g., v0.1.798-g038acc6)
operator_version="unknown"
git_commit=""

# Try to extract version from image tag
if [[ "$operator_image" =~ :v([0-9]+\.[0-9]+\.[0-9]+(-g[a-f0-9]+)?) ]]; then
    operator_version="${BASH_REMATCH[1]}"
    # Extract git commit from version tag (e.g., v0.1.798-g038acc6 -> 038acc6)
    if [[ "$operator_version" =~ -g([a-f0-9]+) ]]; then
        git_commit="${BASH_REMATCH[1]}"
    fi
elif [[ "$operator_image" =~ :([a-f0-9]{7,40})$ ]]; then
    # Image uses short hash tag
    git_commit="${BASH_REMATCH[1]:0:12}"
    operator_version="$git_commit"
fi

# Prefer CSV version/commit if available and we didn't find it from image
if [ "$operator_version" = "unknown" ] && [ -n "$csv_version" ]; then
    operator_version="$csv_version"
    git_commit="$csv_git_commit"
    echo "  Using CSV version as fallback: $operator_version"
fi

# If version is still unknown (SHA-based image reference), query image metadata
if [ "$operator_version" = "unknown" ] && [ -n "$operator_image" ] && [ "$operator_image" != "unknown" ]; then
    echo "Querying image metadata for git commit information..."

    # Try to get image labels using skopeo (if available)
    if command -v skopeo &> /dev/null; then
        image_labels=$(skopeo inspect --no-tags "docker://$operator_image" 2>/dev/null | jq -r '.Labels // {}' 2>/dev/null)

        if [ -n "$image_labels" ] && [ "$image_labels" != "{}" ]; then
            # Try common label keys for git commit
            git_commit=$(echo "$image_labels" | jq -r '
                .["io.openshift.build.commit.id"] //
                .["vcs-ref"] //
                .["org.opencontainers.image.revision"] //
                .["git-commit"] //
                .["git.commit"] //
                empty
            ' 2>/dev/null)

            if [ -n "$git_commit" ] && [ "$git_commit" != "null" ]; then
                # Take first 12 characters of git commit
                git_commit="${git_commit:0:12}"
                operator_version="$git_commit"
                echo "  Found git commit in image labels: $git_commit"
            fi
        fi
    fi

    # Fallback: try to get build annotations from deployment
    if [ -z "$git_commit" ] || [ "$git_commit" = "null" ]; then
        deployment_annotations=$(ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>/dev/null | \
            jq -r '.metadata.annotations // {}' 2>/dev/null)

        if [ -n "$deployment_annotations" ] && [ "$deployment_annotations" != "{}" ]; then
            git_commit=$(echo "$deployment_annotations" | jq -r '
                .["io.openshift.build.commit.id"] //
                .["app.openshift.io/vcs-ref"] //
                empty
            ' 2>/dev/null)

            if [ -n "$git_commit" ] && [ "$git_commit" != "null" ]; then
                git_commit="${git_commit:0:12}"
                operator_version="$git_commit"
                echo "  Found git commit in deployment annotations: $git_commit"
            fi
        fi
    fi
fi

echo "Operator version: $operator_version"
if [ -n "$git_commit" ] && [ "$git_commit" != "null" ]; then
    echo "Git commit: $git_commit"
fi
echo "Operator image: $operator_image"
echo ""

# Initialize health data structure
declare -A health_data
health_data["cluster_id"]="$CLUSTER_ID"
health_data["cluster_name"]="$CLUSTER_NAME"
health_data["cluster_version"]="$cluster_version"
health_data["operator_name"]="$OPERATOR_NAME"
health_data["operator_version"]="$operator_version"
health_data["operator_image"]="$operator_image"
health_data["namespace"]="$NAMESPACE"
health_data["deployment"]="$DEPLOYMENT"
health_data["timestamp"]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Initialize check results
declare -a health_checks
declare -a api_errors
overall_status="HEALTHY"
critical_count=0
warning_count=0

#=============================================================================
# 1. VERSION VERIFICATION
#=============================================================================
echo "================================================================================"
echo "CHECK 1: Version Verification Against ${OCM_ENV^} Environment Target"
echo "================================================================================"

version_check_status="UNKNOWN"
version_message=""
expected_versions=()
canonical_version=""

# Get expected versions from app-interface target
# Initialize variables
canonical_image_tag=""

echo "OCM Environment: $OCM_ENV"
echo "Target Name: $TARGET_NAME"
echo "SAAS File: $SAAS_FILE"
echo ""

# Check if we have a cached version from the multi-cluster script
if [ -n "${CACHED_STAGING_VERSION_camo:-}" ] && [[ "$SAAS_FILE" == *"configure-alertmanager"* ]]; then
    echo "Using cached version from multi-cluster run..."
    canonical_version="$CACHED_STAGING_VERSION_camo"
    canonical_image_tag="${CACHED_STAGING_IMAGE_TAG_camo:-}"
    expected_versions=("$canonical_version")
    echo "  Cached version: $canonical_version (tag: $canonical_image_tag)"
elif [ -n "${CACHED_STAGING_VERSION_rmo:-}" ] && [[ "$SAAS_FILE" == *"route-monitor"* ]]; then
    echo "Using cached version from multi-cluster run..."
    canonical_version="$CACHED_STAGING_VERSION_rmo"
    canonical_image_tag="${CACHED_STAGING_IMAGE_TAG_rmo:-}"
    expected_versions=("$canonical_version")
    echo "  Cached version: $canonical_version (tag: $canonical_image_tag)"
elif [ -f "$HOME/.get_app_interface_saas_refs.sh" ]; then
    echo "Fetching expected version from app-interface..."
    echo "  Note: This uses an optional external script for version lookup"
    echo "  Alternative: Set EXPECTED_VERSION environment variable"

    # Run the script and capture output
    saas_refs=$(bash "$HOME/.get_app_interface_saas_refs.sh" "$SAAS_FILE" 2>/dev/null)

    if [ -n "$saas_refs" ]; then
        # Look for the target name in the output
        target_line=$(echo "$saas_refs" | grep "^$TARGET_NAME")

        if [ -n "$target_line" ]; then
            # Extract the REF and IMAGE_TAG columns for this target
            ref=$(echo "$target_line" | awk '{print $2}')
            image_tag=$(echo "$target_line" | awk '{print $4}')

            if [ -n "$ref" ]; then
                canonical_version="$ref"
                canonical_image_tag="$image_tag"
                expected_versions=("$ref")
                echo "  Target: $TARGET_NAME"
                echo "  Expected Git Ref: $ref"
                echo "  Expected Image Tag: $image_tag"
                echo ""

                # Check if this is a branch ref (like "master") vs commit hash
                if [[ ! "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
                    echo "  ℹ Note: Target uses branch '$ref' (not a specific commit)"
                    echo "  Fetching current HEAD commit of branch '$ref' from GitHub..."

                    # Get GitHub repo URL from saas file
                    github_repo_url=$(curl -s "https://gitlab.cee.redhat.com/service/app-interface/-/raw/master/data/services/osd-operators/cicd/saas/${SAAS_FILE}?ref_type=heads" 2>/dev/null | yq -r '.resourceTemplates[] | select(.name | test("configure-alertmanager-operator")) | .url' 2>/dev/null)

                    if [ -n "$github_repo_url" ]; then
                        # Extract owner/repo from GitHub URL
                        github_repo=$(echo "$github_repo_url" | sed -E 's|https://github.com/||' | sed 's|\.git$||')

                        # Query GitHub API for current HEAD of the branch
                        branch_head=$(curl -s "https://api.github.com/repos/${github_repo}/commits/${ref}" 2>/dev/null | jq -r '.sha' 2>/dev/null)

                        if [ -n "$branch_head" ] && [ "$branch_head" != "null" ]; then
                            # Replace canonical_version with the actual branch HEAD commit
                            canonical_version="$branch_head"
                            echo "  ✓ Current HEAD of '$ref': ${branch_head:0:12}"
                            echo "  Will verify deployed commit matches current branch HEAD"
                        else
                            echo "  ⚠ Warning: Could not fetch branch HEAD from GitHub API"
                            echo "  Continuing with branch name verification"
                        fi
                    else
                        echo "  ⚠ Warning: Could not fetch GitHub repo URL from saas file"
                    fi
                    echo ""
                fi
            fi
        else
            echo "  ⚠ Warning: Target '$TARGET_NAME' not found in saas file $SAAS_FILE"
            echo "  Available targets:"
            echo "$saas_refs" | grep -v "^TARGET" | grep -v "^------" | awk '{print "    - " $1}'
            echo ""
        fi
    else
        echo "  ⚠ Warning: Could not fetch version references from app-interface"
        version_check_status="UNKNOWN"
        version_message="Unable to fetch version references from saas file"
    fi
else
    # app-interface script not found - check for alternative version source
    echo "  Note: app-interface integration not available (optional)"

    # Check if EXPECTED_VERSION is provided via environment variable
    if [ -n "${EXPECTED_VERSION:-}" ]; then
        echo "  Using EXPECTED_VERSION from environment: $EXPECTED_VERSION"
        canonical_version="$EXPECTED_VERSION"
        expected_versions=("$canonical_version")
    else
        echo "  Skipping version verification (no expected version configured)"
        echo "  Tip: Set EXPECTED_VERSION environment variable or configure app-interface integration"
        version_check_status="SKIP"
        version_message="Version verification skipped (no expected version configured)"
    fi
fi

# Compare operator version against canonical expected version
if [ -n "$canonical_version" ]; then
    version_match=false
    match_method=""

    # Extract image SHA from current operator image (if using SHA reference)
    current_image_sha=""
    current_image_sha_short=""
    if [[ "$operator_image" == *"@sha256:"* ]]; then
        current_image_sha=$(echo "$operator_image" | grep -oE 'sha256:[a-f0-9]{64}' | head -1)
        current_image_sha_short=$(echo "$current_image_sha" | cut -c8-19)  # First 12 chars of SHA
    fi

    # Handle both full hash and short hash matching
    canonical_short="${canonical_version:0:12}"
    operator_short="${operator_version:0:12}"

    # Display image SHA for manual verification
    if [ -n "$current_image_sha_short" ]; then
        echo "  Current image SHA: $current_image_sha_short"
    fi

    # Try SHA comparison if we have both the current SHA and staging image tag
    if [ "$version_match" = false ] && [ -n "$current_image_sha" ] && [ -n "$canonical_image_tag" ] && [ "$canonical_image_tag" != "null" ] && [ "$canonical_image_tag" != "N/A" ]; then
        echo "  Querying staging image SHA for comparison..."
        staging_image_sha=$(skopeo inspect --no-tags "docker://quay.io/app-sre/${DEPLOYMENT}:${canonical_image_tag}" 2>/dev/null | jq -r '.Digest' 2>/dev/null)

        if [ -n "$staging_image_sha" ] && [ "$staging_image_sha" != "null" ]; then
            staging_image_sha_short=$(echo "$staging_image_sha" | cut -c8-19)
            echo "  Staging image SHA: $staging_image_sha_short"

            if [ "$current_image_sha" = "$staging_image_sha" ]; then
                version_match=true
                match_method="image_sha"
                echo "  ✓ Image SHA matches staging!"
            else
                echo "  ✗ Image SHA does not match staging"
            fi
        else
            echo "  ⚠ Could not query staging image SHA"
        fi
    fi

    # If SHA comparison didn't work, fall back to git commit comparison
    if [ "$version_match" = false ] && [ "$operator_version" != "unknown" ]; then
        # Direct match (both full or both short)
        if [ "$operator_version" = "$canonical_version" ]; then
            version_match=true
            match_method="git_commit_exact"
        # Short vs full comparison
        elif [ "$operator_short" = "$canonical_short" ]; then
            version_match=true
            match_method="git_commit_short"
        # Check if operator version contains the canonical version
        elif [[ "$operator_version" == *"$canonical_short"* ]]; then
            version_match=true
            match_method="git_commit_substring"
        # Check if canonical version contains the operator version
        elif [[ "$canonical_version" == *"$operator_short"* ]]; then
            version_match=true
            match_method="git_commit_substring"
        # Check image reference contains canonical version
        elif [[ "$operator_image" == *"$canonical_version"* ]]; then
            version_match=true
            match_method="image_tag"
        fi
    fi

    if [ "$version_match" = true ]; then
        version_check_status="PASS"
        if [ "$match_method" = "image_sha" ]; then
            version_message="Image SHA matches $OCM_ENV target deployment (verified via SHA comparison)"
            echo "  ✓ Version verified via image SHA match"
        else
            version_message="Version matches $OCM_ENV target deployment ($canonical_version)"
            echo "  ✓ Version matches expected $OCM_ENV target version"
        fi
    else
        version_check_status="FAIL"
        version_message="Version mismatch - may indicate installation error (expected: $canonical_version, got: $operator_version)"
        warning_count=$((warning_count + 1))
        echo "  ✗ Version does NOT match expected $OCM_ENV target version"
        echo "    Current: $operator_version"
        echo "    Expected: $canonical_version (target: $TARGET_NAME)"
    fi
elif [ ${#expected_versions[@]} -eq 0 ]; then
    version_check_status="UNKNOWN"
    version_message="No $OCM_ENV version references available"
    echo "  ⚠ Unable to verify version - no $OCM_ENV target references found"
else
    version_check_status="UNKNOWN"
    version_message="Version check skipped"
    echo "  ⚠ Version check skipped"
fi

# Build expected versions JSON array safely
expected_versions_json="[]"
if [ ${#expected_versions[@]} -gt 0 ]; then
    expected_versions_json=$(printf '%s\n' "${expected_versions[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
fi

health_checks+=("$(cat <<EOF
{
  "check": "version_verification",
  "status": "$version_check_status",
  "severity": "warning",
  "message": "$version_message",
  "details": {
    "ocm_environment": "$OCM_ENV",
    "target_name": "$TARGET_NAME",
    "saas_file": "$SAAS_FILE",
    "current_version": "$operator_version",
    "current_image_sha": "${current_image_sha_short:-unknown}",
    "expected_version": "$canonical_version",
    "expected_image_tag": "${canonical_image_tag:-unknown}",
    "match_method": "${match_method:-none}"
  }
}
EOF
)")

echo ""

#=============================================================================
# 2. POD STATUS AND RESTART CHECKS
#=============================================================================
echo "================================================================================"
echo "CHECK 2: Pod Status and Restart Analysis"
echo "================================================================================"

# Get deployment status
deployment_status_error=$(mktemp)
deployment_json=$(ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>"$deployment_status_error")
deployment_status_exit_code=$?

if [ $deployment_status_exit_code -ne 0 ] || [ -z "$deployment_json" ]; then
    deployment_status_error_msg=$(cat "$deployment_status_error" 2>/dev/null | head -20)
    if [ -n "$deployment_status_error_msg" ]; then
        log_api_error "Get deployment status $NAMESPACE/$DEPLOYMENT" "$deployment_status_error_msg" $deployment_status_exit_code
    fi
fi
rm -f "$deployment_status_error"

desired_replicas=$(echo "$deployment_json" | jq -r '.spec.replicas // 0' 2>/dev/null)
desired_replicas=${desired_replicas:-0}
ready_replicas=$(echo "$deployment_json" | jq -r '.status.readyReplicas // 0' 2>/dev/null)
ready_replicas=${ready_replicas:-0}
available_replicas=$(echo "$deployment_json" | jq -r '.status.availableReplicas // 0' 2>/dev/null)
available_replicas=${available_replicas:-0}

echo "Deployment replicas: $ready_replicas/$desired_replicas ready"

# Get pod list
pods_fetch_error=$(mktemp)
pods_json=$(ocm backplane elevate "${REASON}" -- get pods -n "$NAMESPACE" -l "name=$DEPLOYMENT" -o json 2>"$pods_fetch_error")
pods_fetch_exit_code=$?

if [ $pods_fetch_exit_code -ne 0 ]; then
    pods_fetch_error_msg=$(cat "$pods_fetch_error" 2>/dev/null | head -20)
    if [ -n "$pods_fetch_error_msg" ]; then
        log_api_error "Get pods in $NAMESPACE with label name=$DEPLOYMENT" "$pods_fetch_error_msg" $pods_fetch_exit_code
    fi
fi
rm -f "$pods_fetch_error"

pod_count=$(echo "$pods_json" | jq -r '.items | length' 2>/dev/null || echo "0")
pod_name=""

total_restarts=0
max_restart_count=0
pods_not_running=0
restart_check_status="PASS"
restart_message=""

if [ "$pod_count" -gt 0 ]; then
    while IFS=$'\t' read -r pod_name pod_phase restart_count; do
        if [ -z "$pod_name" ] || [ "$pod_name" = "null" ]; then
            continue
        fi

        echo "  Pod: $pod_name"
        echo "    Phase: $pod_phase"
        echo "    Restarts: $restart_count"

        # Track restarts
        if [ -n "$restart_count" ] && [ "$restart_count" != "null" ]; then
            total_restarts=$((total_restarts + restart_count))
            if [ "$restart_count" -gt "$max_restart_count" ]; then
                max_restart_count=$restart_count
            fi
        fi

        # Track non-running pods
        if [ "$pod_phase" != "Running" ]; then
            pods_not_running=$((pods_not_running + 1))
        fi
    done < <(echo "$pods_json" | jq -r '.items[] | [.metadata.name, .status.phase, (.status.containerStatuses[0].restartCount // 0)] | @tsv' 2>/dev/null)
fi

# Evaluate restart status
if [ "$max_restart_count" -gt 10 ]; then
    restart_check_status="FAIL"
    restart_message="Excessive pod restarts detected (max: $max_restart_count)"
    critical_count=$((critical_count + 1))
    echo "  ✗ CRITICAL: Pod has $max_restart_count restarts"
elif [ "$max_restart_count" -gt 5 ]; then
    restart_check_status="WARNING"
    restart_message="High pod restart count (max: $max_restart_count)"
    warning_count=$((warning_count + 1))
    echo "  ⚠ WARNING: Pod has $max_restart_count restarts"
else
    restart_check_status="PASS"
    restart_message="Pod restart count is within acceptable range"
    echo "  ✓ Pod restart count acceptable ($max_restart_count)"
fi

# Check pod availability
if [ "$pods_not_running" -gt 0 ]; then
    restart_check_status="FAIL"
    restart_message="$pods_not_running pod(s) not in Running state"
    critical_count=$((critical_count + 1))
    echo "  ✗ CRITICAL: $pods_not_running pod(s) not running"
elif [ "$ready_replicas" != "$desired_replicas" ]; then
    if [ "$restart_check_status" = "PASS" ]; then
        restart_check_status="WARNING"
    fi
    restart_message="${restart_message}; Not all replicas ready ($ready_replicas/$desired_replicas)"
    warning_count=$((warning_count + 1))
    echo "  ⚠ WARNING: Not all replicas ready"
fi

health_checks+=("$(cat <<EOF
{
  "check": "pod_status_and_restarts",
  "status": "$restart_check_status",
  "severity": "$([ "$restart_check_status" = "FAIL" ] && echo "critical" || echo "warning")",
  "message": "$restart_message",
  "details": {
    "desired_replicas": $desired_replicas,
    "ready_replicas": $ready_replicas,
    "available_replicas": $available_replicas,
    "total_restarts": $total_restarts,
    "max_restarts": $max_restart_count,
    "pods_not_running": $pods_not_running
  }
}
EOF
)")

echo ""

#=============================================================================
# 3. CPU AND MEMORY LEAK DETECTION
#=============================================================================
echo "================================================================================"
echo "CHECK 3: CPU and Memory Trend Analysis"
echo "================================================================================"

memory_check_status="PASS"
memory_message=""
memory_trend="stable"
memory_increase_percent=0
cpu_increase_percent=0
cpu_trend="stable"
memory_timeseries="[]"
cpu_timeseries="[]"
lookback_hours=0

# Get pod start time to determine how long to look back
if [ "$pod_count" -gt 0 ]; then
    pod_name=$(echo "$pods_json" | jq -r '.items[0].metadata.name' 2>/dev/null)
    pod_start_time=$(echo "$pods_json" | jq -r '.items[0].status.startTime // empty' 2>/dev/null)

    if [ -n "$pod_name" ] && [ "$pod_name" != "null" ]; then
        echo "Analyzing resource trends for pod: $pod_name"

        # Calculate time range based on pod age (or max 24 hours)
        current_time=$(date +%s)

        if [ -n "$pod_start_time" ]; then
            pod_start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pod_start_time" "+%s" 2>/dev/null || echo "$((current_time - 21600))")
            pod_age_seconds=$((current_time - pod_start_epoch))

            # Use pod age or 24 hours, whichever is shorter
            if [ $pod_age_seconds -lt 86400 ]; then
                lookback_seconds=$pod_age_seconds
            else
                lookback_seconds=86400  # 24 hours max
            fi
        else
            lookback_seconds=21600  # Default to 6 hours if we can't get pod start time
        fi

        lookback_hours=$(awk "BEGIN {printf \"%.1f\", $lookback_seconds / 3600}")
        echo "  Pod age: ${lookback_hours}h (analyzing trends since pod started)"

        start_time=$((current_time - lookback_seconds))
        end_time=$current_time

        # Query Thanos via port-forward or service
        # Try to use thanos-querier service
        thanos_url="http://thanos-querier.openshift-monitoring.svc:9091"

        echo "  Querying Prometheus/Thanos for metrics..."

        # Memory query
        memory_query="container_memory_working_set_bytes{namespace=\"$NAMESPACE\",pod=\"$pod_name\",container=\"$DEPLOYMENT\"}"
        memory_query_encoded=$(printf '%s' "$memory_query" | jq -sRr @uri)

        memory_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
            wget -q -O- "http://localhost:9090/api/v1/query_range?query=${memory_query_encoded}&start=${start_time}&end=${end_time}&step=300" 2>/dev/null)

        # CPU query (rate over 5m)
        cpu_query="rate(container_cpu_usage_seconds_total{namespace=\"$NAMESPACE\",pod=\"$pod_name\",container=\"$DEPLOYMENT\"}[5m])"
        cpu_query_encoded=$(printf '%s' "$cpu_query" | jq -sRr @uri)

        cpu_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
            wget -q -O- "http://localhost:9090/api/v1/query_range?query=${cpu_query_encoded}&start=${start_time}&end=${end_time}&step=300" 2>/dev/null)

        # Process memory data
        memory_timeseries="[]"
        if [ -n "$memory_data" ] && echo "$memory_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
            # Store full time series for charting
            memory_timeseries=$(echo "$memory_data" | jq -c '.data.result[0].values // []' 2>/dev/null)

            first_memory=$(echo "$memory_data" | jq -r '.data.result[0].values[0][1] // "0"' 2>/dev/null)
            last_memory=$(echo "$memory_data" | jq -r '.data.result[0].values[-1][1] // "0"' 2>/dev/null)

            if [ "$first_memory" != "0" ] && [ "$last_memory" != "0" ] && [ "$first_memory" != "null" ] && [ "$last_memory" != "null" ]; then
                # Calculate percentage increase
                memory_increase_percent=$(awk "BEGIN {printf \"%.2f\", (($last_memory - $first_memory) / $first_memory) * 100}")

                # Convert to MB for display
                first_memory_mb=$(awk "BEGIN {printf \"%.2f\", $first_memory / 1048576}")
                last_memory_mb=$(awk "BEGIN {printf \"%.2f\", $last_memory / 1048576}")

                echo "  Memory usage over last ${lookback_hours}h:"
                echo "    Initial: ${first_memory_mb} MB"
                echo "    Current: ${last_memory_mb} MB"
                echo "    Change: ${memory_increase_percent}%"

                # Evaluate memory trend
                if (( $(echo "$memory_increase_percent > $MEMORY_LEAK_THRESHOLD_PERCENT" | bc -l) )); then
                    memory_trend="increasing"
                    echo "  ⚠ Memory increased significantly"
                else
                    echo "  ✓ Memory usage stable"
                fi
            else
                echo "  ℹ Insufficient memory data points"
            fi
        else
            echo "  ⚠ Could not retrieve memory metrics from Prometheus"
        fi

        # Process CPU data
        cpu_timeseries="[]"
        if [ -n "$cpu_data" ] && echo "$cpu_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
            # Store full time series for charting
            cpu_timeseries=$(echo "$cpu_data" | jq -c '.data.result[0].values // []' 2>/dev/null)

            first_cpu=$(echo "$cpu_data" | jq -r '.data.result[0].values[0][1] // "0"' 2>/dev/null)
            last_cpu=$(echo "$cpu_data" | jq -r '.data.result[0].values[-1][1] // "0"' 2>/dev/null)

            if [ "$first_cpu" != "0" ] && [ "$last_cpu" != "0" ] && [ "$first_cpu" != "null" ] && [ "$last_cpu" != "null" ]; then
                # Calculate percentage increase
                cpu_increase_percent=$(awk "BEGIN {printf \"%.2f\", (($last_cpu - $first_cpu) / $first_cpu) * 100}")

                # Convert to millicores for display
                first_cpu_mc=$(awk "BEGIN {printf \"%.0f\", $first_cpu * 1000}")
                last_cpu_mc=$(awk "BEGIN {printf \"%.0f\", $last_cpu * 1000}")

                echo "  CPU usage over last ${lookback_hours}h:"
                echo "    Initial: ${first_cpu_mc}m"
                echo "    Current: ${last_cpu_mc}m"
                echo "    Change: ${cpu_increase_percent}%"

                # Evaluate CPU trend
                if (( $(echo "$cpu_increase_percent > $MEMORY_LEAK_THRESHOLD_PERCENT" | bc -l) )); then
                    cpu_trend="increasing"
                    echo "  ⚠ CPU increased significantly"
                else
                    echo "  ✓ CPU usage stable"
                fi
            else
                echo "  ℹ Insufficient CPU data points"
            fi
        else
            echo "  ⚠ Could not retrieve CPU metrics from Prometheus"
        fi

        # Overall assessment
        if [ "$memory_trend" = "increasing" ] && [ "$cpu_trend" = "increasing" ]; then
            memory_check_status="WARNING"
            memory_message="Both CPU and memory increased by >${MEMORY_LEAK_THRESHOLD_PERCENT}% (CPU: ${cpu_increase_percent}%, Mem: ${memory_increase_percent}%) - possible resource leak"
            warning_count=$((warning_count + 1))
        elif [ "$memory_trend" = "increasing" ]; then
            memory_check_status="WARNING"
            memory_message="Memory increased by ${memory_increase_percent}% over ${lookback_hours}h - possible memory leak"
            warning_count=$((warning_count + 1))
        elif [ "$cpu_trend" = "increasing" ]; then
            memory_check_status="WARNING"
            memory_message="CPU increased by ${cpu_increase_percent}% over ${lookback_hours}h - possible CPU leak"
            warning_count=$((warning_count + 1))
        elif [ -z "$memory_data" ] && [ -z "$cpu_data" ]; then
            memory_check_status="UNKNOWN"
            memory_message="Unable to query resource metrics from Prometheus"
        else
            memory_check_status="PASS"
            memory_message="CPU and memory usage are stable"
        fi
    fi
else
    memory_check_status="UNKNOWN"
    memory_message="No pods found to analyze"
    echo "  ⚠ No pods found"
fi

health_checks+=("$(cat <<EOF
{
  "check": "resource_leak_detection",
  "status": "$memory_check_status",
  "severity": "warning",
  "message": "$memory_message",
  "details": {
    "memory_trend": "$memory_trend",
    "memory_increase_percent": $memory_increase_percent,
    "cpu_trend": "$cpu_trend",
    "cpu_increase_percent": $cpu_increase_percent,
    "threshold_percent": $MEMORY_LEAK_THRESHOLD_PERCENT,
    "memory_timeseries": $memory_timeseries,
    "cpu_timeseries": $cpu_timeseries,
    "lookback_hours": $lookback_hours
  }
}
EOF
)")

echo ""

#=============================================================================
# 4. LOG ERROR ANALYSIS
#=============================================================================
echo "================================================================================"
echo "CHECK 4: Log Error Analysis"
echo "================================================================================"

log_check_status="PASS"
log_message=""
error_count=0
warning_log_count=0
declare -a error_samples=()
declare -a warning_samples=()

if [ "$pod_count" -gt 0 ]; then
    pod_name=$(echo "$pods_json" | jq -r '.items[0].metadata.name' 2>/dev/null)

    if [ -n "$pod_name" ] && [ "$pod_name" != "null" ]; then
        echo "Analyzing logs for pod: $pod_name"

        # Get recent logs and look for errors
        logs=$(ocm backplane elevate "${REASON}" -- logs -n "$NAMESPACE" "$pod_name" --tail=500 2>/dev/null || echo "")

        if [ -n "$logs" ]; then
            # Count error lines (case-insensitive)
            error_count=$(echo "$logs" | grep -ic "error" 2>/dev/null || echo "0")
            warning_log_count=$(echo "$logs" | grep -ic "warning" 2>/dev/null || echo "0")

            # Trim any whitespace from counts
            error_count=$(echo "$error_count" | tr -d '[:space:]')
            warning_log_count=$(echo "$warning_log_count" | tr -d '[:space:]')

            echo "  Error lines found: $error_count"
            echo "  Warning lines found: $warning_log_count"

            # Collect sample error messages (first 5)
            if [ -n "$error_count" ] && [ "$error_count" -gt 0 ]; then
                while IFS= read -r line; do
                    error_samples+=("$line")
                done < <(echo "$logs" | grep -i "error" | head -5)

                echo "  Sample errors:"
                printf '    %s\n' "${error_samples[@]}"
            fi

            # Collect sample warning messages (first 5)
            if [ -n "$warning_log_count" ] && [ "$warning_log_count" -gt 0 ]; then
                while IFS= read -r line; do
                    warning_samples+=("$line")
                done < <(echo "$logs" | grep -i "warning" | head -5)

                echo "  Sample warnings:"
                printf '    %s\n' "${warning_samples[@]}"
            fi

            # Evaluate log status
            if [ -n "$error_count" ] && [ "$error_count" -gt "$ERROR_LOG_THRESHOLD" ]; then
                log_check_status="WARNING"
                log_message="Found $error_count errors and $warning_log_count warnings in CAMO logs"
                warning_count=$((warning_count + 1))
                echo "  ⚠ WARNING: CAMO has $error_count errors and $warning_log_count warnings in logs"
            elif [ -n "$warning_log_count" ] && [ "$warning_log_count" -gt 0 ]; then
                log_check_status="WARNING"
                log_message="Found $warning_log_count warnings in CAMO logs (0 errors)"
                warning_count=$((warning_count + 1))
                echo "  ⚠ WARNING: CAMO has $warning_log_count warnings in logs (0 errors)"
            else
                log_check_status="PASS"
                log_message="Error and warning count acceptable (0 errors, 0 warnings)"
                echo "  ✓ Error and warning count acceptable"
            fi
        else
            log_check_status="UNKNOWN"
            log_message="Unable to retrieve pod logs"
            echo "  ⚠ Could not retrieve logs"
        fi
    fi
else
    log_check_status="UNKNOWN"
    log_message="No pods found to analyze"
    echo "  ⚠ No pods found"
fi

# Escape error samples for JSON
error_samples_json="[]"
if [ ${#error_samples[@]} -gt 0 ]; then
    error_samples_json=$(printf '%s\n' "${error_samples[@]}" | jq -R . | jq -s .)
fi

# Escape warning samples for JSON
warning_samples_json="[]"
if [ ${#warning_samples[@]} -gt 0 ]; then
    warning_samples_json=$(printf '%s\n' "${warning_samples[@]}" | jq -R . | jq -s .)
fi

health_checks+=("$(cat <<EOF
{
  "check": "log_error_analysis",
  "status": "$log_check_status",
  "severity": "warning",
  "message": "$log_message",
  "details": {
    "error_count": $error_count,
    "warning_count": $warning_log_count,
    "error_threshold": $ERROR_LOG_THRESHOLD,
    "error_samples": $error_samples_json,
    "warning_samples": $warning_samples_json
  }
}
EOF
)")

echo ""

#=============================================================================
# 5. OPERATOR-SPECIFIC HEALTH CHECKS
#=============================================================================
echo "================================================================================"
echo "CHECK 5: Operator-Specific Health"
echo "================================================================================"

# CAMO-specific checks
if [[ "$OPERATOR_NAME" == *"configure-alertmanager"* ]]; then
    echo "Running CAMO-specific health checks..."

    # Check 1: Alertmanager pods status and restarts
    alertmanager_pods=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=alertmanager" -o json 2>/dev/null)
    alertmanager_pod_count=$(echo "$alertmanager_pods" | jq -r '.items | length' 2>/dev/null || echo "0")

    alertmanager_pods_status="SKIP"
    alertmanager_pods_message="No alertmanager pods found"
    alertmanager_total_restarts=0
    alertmanager_last_restart_time=""
    alertmanager_time_since_restart=""
    alertmanager_pod_age=""
    camo_pod_age="unknown"
    alertmanager_restart_details="[]"

    if [ "$alertmanager_pod_count" -gt 0 ]; then
        alertmanager_not_ready=$(echo "$alertmanager_pods" | jq -r '[.items[] | select(.status.phase != "Running" or ([.status.conditions[]? | select(.type == "Ready" and .status == "False")] | length > 0))] | length' 2>/dev/null)

        # Calculate total restarts across all alertmanager pods
        alertmanager_total_restarts=$(echo "$alertmanager_pods" | jq -r '[.items[].status.containerStatuses[]?.restartCount // 0] | add // 0' 2>/dev/null)

        # Get restart details for each container with exit reasons
        alertmanager_restart_details=$(echo "$alertmanager_pods" | jq -c '[.items[] | {
            pod_name: .metadata.name,
            pod_age: .metadata.creationTimestamp,
            containers: [.status.containerStatuses[]? | {
                name: .name,
                restart_count: .restartCount,
                ready: .ready,
                last_restart: (if .lastState.terminated != null then {
                    reason: .lastState.terminated.reason,
                    exit_code: .lastState.terminated.exitCode,
                    finished_at: .lastState.terminated.finishedAt,
                    message: .lastState.terminated.message
                } else "No recent restart data" end)
            }]
        }]' 2>/dev/null || echo "[]")

        # Get most recent restart time across all pods
        alertmanager_last_restart_time=$(echo "$alertmanager_pods" | jq -r '[.items[].status.containerStatuses[]? | select(.lastState.terminated != null) | .lastState.terminated.finishedAt] | sort | .[-1] // "never"' 2>/dev/null)

        # Calculate time since last restart if there was one
        if [ "$alertmanager_last_restart_time" != "never" ] && [ -n "$alertmanager_last_restart_time" ]; then
            current_timestamp=$(date -u +%s)
            restart_timestamp=$(date -u -d "$alertmanager_last_restart_time" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$alertmanager_last_restart_time" +%s 2>/dev/null || echo "$current_timestamp")
            time_diff=$((current_timestamp - restart_timestamp))

            if [ "$time_diff" -lt 3600 ]; then
                alertmanager_time_since_restart="$((time_diff / 60))m ago"
            elif [ "$time_diff" -lt 86400 ]; then
                alertmanager_time_since_restart="$((time_diff / 3600))h ago"
            else
                alertmanager_time_since_restart="$((time_diff / 86400))d ago"
            fi
        else
            alertmanager_time_since_restart="No restarts"
        fi

        # Get pod age (oldest pod)
        alertmanager_creation_time=$(echo "$alertmanager_pods" | jq -r '[.items[].metadata.creationTimestamp] | sort | .[0] // ""' 2>/dev/null)
        if [ -n "$alertmanager_creation_time" ]; then
            current_timestamp=$(date -u +%s)
            creation_timestamp=$(date -u -d "$alertmanager_creation_time" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$alertmanager_creation_time" +%s 2>/dev/null || echo "$current_timestamp")
            pod_age_seconds=$((current_timestamp - creation_timestamp))

            if [ "$pod_age_seconds" -lt 3600 ]; then
                alertmanager_pod_age="$((pod_age_seconds / 60))m"
            elif [ "$pod_age_seconds" -lt 86400 ]; then
                alertmanager_pod_age="$((pod_age_seconds / 3600))h"
            else
                alertmanager_pod_age="$((pod_age_seconds / 86400))d"
            fi
        fi

        # Get CAMO operator pod creation time to correlate with AlertManager restarts
        camo_pod_creation=""
        camo_pod_age="unknown"
        camo_pods=$(oc get pods -n "$NAMESPACE" -l "app=$DEPLOYMENT" -o json 2>/dev/null)
        if [ -n "$camo_pods" ]; then
            camo_pod_creation=$(echo "$camo_pods" | jq -r '[.items[].metadata.creationTimestamp] | sort | .[0] // ""' 2>/dev/null)

            # Calculate CAMO pod age
            if [ -n "$camo_pod_creation" ]; then
                current_timestamp=$(date -u +%s)
                camo_creation_timestamp=$(date -u -d "$camo_pod_creation" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$camo_pod_creation" +%s 2>/dev/null || echo "$current_timestamp")
                camo_pod_age_seconds=$((current_timestamp - camo_creation_timestamp))

                if [ "$camo_pod_age_seconds" -lt 3600 ]; then
                    camo_pod_age="$((camo_pod_age_seconds / 60))m"
                elif [ "$camo_pod_age_seconds" -lt 86400 ]; then
                    camo_pod_age="$((camo_pod_age_seconds / 3600))h"
                else
                    camo_pod_age="$((camo_pod_age_seconds / 86400))d"
                fi
            fi
        fi

        # Determine status based on recency of restarts relative to CAMO operator deployment
        if [ "$alertmanager_not_ready" -gt 0 ]; then
            alertmanager_pods_status="FAIL"
            alertmanager_pods_message="$alertmanager_not_ready alertmanager pod(s) not ready"
            critical_count=$((critical_count + 1))
            echo "  ✗ CRITICAL: Alertmanager pods not ready"
        elif [ "$alertmanager_total_restarts" -gt 3 ]; then
            # Check if restarts happened after current CAMO version was deployed
            restart_relevant=false

            if [ "$alertmanager_last_restart_time" != "never" ] && [ -n "$alertmanager_last_restart_time" ] && [ -n "$camo_pod_creation" ]; then
                current_timestamp=$(date -u +%s)
                restart_timestamp=$(date -u -d "$alertmanager_last_restart_time" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$alertmanager_last_restart_time" +%s 2>/dev/null || echo "0")
                camo_deployment_timestamp=$(date -u -d "$camo_pod_creation" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$camo_pod_creation" +%s 2>/dev/null || echo "$current_timestamp")
                time_since_restart=$((current_timestamp - restart_timestamp))

                # Only flag as issue if restart happened AFTER current CAMO version was deployed
                if [ "$restart_timestamp" -gt "$camo_deployment_timestamp" ]; then
                    restart_relevant=true
                    if [ "$time_since_restart" -lt 86400 ]; then
                        # Recent restart after CAMO deployment (< 24h) = WARN
                        alertmanager_pods_status="WARN"
                        alertmanager_pods_message="AlertManager restarted after current CAMO deployment ($alertmanager_total_restarts total, last $alertmanager_time_since_restart)"
                        warning_count=$((warning_count + 1))
                        echo "  ⚠ WARNING: AlertManager restarted after current CAMO version deployed ($alertmanager_total_restarts total, last $alertmanager_time_since_restart)"
                    else
                        # Old restart but still after CAMO deployment
                        alertmanager_pods_status="PASS"
                        alertmanager_pods_message="All $alertmanager_pod_count pods healthy (restart after CAMO deployment but stable for $alertmanager_time_since_restart)"
                        echo "  ✓ AlertManager pods healthy (restart after CAMO deployment but stable for $alertmanager_time_since_restart)"
                    fi
                fi
            fi

            # If no restart data or restarts happened before CAMO deployment
            if [ "$restart_relevant" = false ]; then
                alertmanager_pods_status="PASS"
                alertmanager_pods_message="All $alertmanager_pod_count pods healthy (restarts pre-date current CAMO version: $alertmanager_total_restarts total)"
                echo "  ✓ AlertManager pods healthy (restarts pre-date current CAMO version: $alertmanager_total_restarts total)"
            fi
        else
            alertmanager_pods_status="PASS"
            alertmanager_pods_message="All $alertmanager_pod_count alertmanager pods healthy ($alertmanager_total_restarts restarts)"
            echo "  ✓ All alertmanager pods are healthy ($alertmanager_total_restarts restarts)"
        fi
    else
        echo "  ℹ No alertmanager pods found"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "alertmanager_pods",
  "status": "$alertmanager_pods_status",
  "severity": "critical",
  "message": "$alertmanager_pods_message",
  "details": {
    "pod_count": $alertmanager_pod_count,
    "not_ready": ${alertmanager_not_ready:-0},
    "total_restarts": $alertmanager_total_restarts,
    "last_restart_time": "$alertmanager_last_restart_time",
    "time_since_restart": "$alertmanager_time_since_restart",
    "pod_age": "$alertmanager_pod_age",
    "camo_pod_age": "$camo_pod_age",
    "restart_details": $alertmanager_restart_details,
    "interpretation": "Only restarts AFTER current CAMO deployment are relevant to CAMO health. Restarts before current CAMO version are historical/unrelated. Check restart_details for exit codes: OOMKilled (memory), Error (crash), Completed (upgrade), Evicted (node pressure)."
  }
}
EOF
)")

    # Check 2: Alertmanager StatefulSet status
    alertmanager_sts_error=$(mktemp)
    alertmanager_sts=$(oc get statefulset alertmanager-main -n "$NAMESPACE" -o json 2>"$alertmanager_sts_error")
    alertmanager_sts_exit_code=$?

    if [ $alertmanager_sts_exit_code -ne 0 ]; then
        alertmanager_sts_error_msg=$(cat "$alertmanager_sts_error" 2>/dev/null | head -20)
        if [ -n "$alertmanager_sts_error_msg" ]; then
            log_api_error "Get StatefulSet alertmanager-main in $NAMESPACE" "$alertmanager_sts_error_msg" $alertmanager_sts_exit_code
        fi
    fi
    rm -f "$alertmanager_sts_error"

    alertmanager_sts_status="SKIP"
    alertmanager_sts_message="StatefulSet not found"
    ready_replicas=0
    desired_replicas=0

    if [ -n "$alertmanager_sts" ] && [ "$alertmanager_sts" != "null" ]; then
        ready_replicas=$(echo "$alertmanager_sts" | jq -r '.status.readyReplicas // 0')
        desired_replicas=$(echo "$alertmanager_sts" | jq -r '.status.replicas // 0')

        if [ "$ready_replicas" -eq "$desired_replicas" ] && [ "$desired_replicas" -gt 0 ]; then
            alertmanager_sts_status="PASS"
            alertmanager_sts_message="StatefulSet ready ($ready_replicas/$desired_replicas)"
            echo "  ✓ Alertmanager StatefulSet ready ($ready_replicas/$desired_replicas)"
        else
            alertmanager_sts_status="FAIL"
            alertmanager_sts_message="StatefulSet not ready ($ready_replicas/$desired_replicas)"
            critical_count=$((critical_count + 1))
            echo "  ✗ Alertmanager StatefulSet not ready ($ready_replicas/$desired_replicas)"
        fi
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "alertmanager_statefulset",
  "status": "$alertmanager_sts_status",
  "severity": "critical",
  "message": "$alertmanager_sts_message",
  "details": {
    "ready_replicas": $ready_replicas,
    "desired_replicas": $desired_replicas
  }
}
EOF
)")

    # Check 3: Operator controller availability
    controller_available=$(oc get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
    controller_status="FAIL"
    controller_message="Controller not available"

    if [ "$controller_available" = "True" ]; then
        controller_status="PASS"
        controller_message="Controller is available"
        echo "  ✓ Operator controller is available"
    else
        critical_count=$((critical_count + 1))
        echo "  ✗ Operator controller not available"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "controller_availability",
  "status": "$controller_status",
  "severity": "critical",
  "message": "$controller_message",
  "details": {}
}
EOF
)")

    # Check 4: Recent reconciliation activity with resource change validation
    # Get recent reconciliation log count
    recent_logs=$(oc logs -n "$NAMESPACE" "deployment/$DEPLOYMENT" --since=5m --tail=10 2>/dev/null | wc -l)

    # Get timestamp for 5 minutes ago for resource change detection
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux)
        lookback_timestamp=$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')
    else
        # BSD date (macOS)
        lookback_timestamp=$(date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')
    fi

    # Check for recent changes to CAMO-watched resources (cluster-wide)
    echo "  Checking for recent changes to watched resources..."

    # Count recent secret changes across all namespaces (CAMO watches secrets cluster-wide)
    secret_changes_count=0
    secrets_data=$(oc get secrets --all-namespaces -o json 2>/dev/null)
    if [ -n "$secrets_data" ]; then
        secret_changes_count=$(echo "$secrets_data" | jq "[.items[] | select(
            (.metadata.creationTimestamp > \"$lookback_timestamp\") or
            ([.metadata.managedFields[]?.time // \"\" | select(. > \"$lookback_timestamp\")] | length > 0)
        )] | length" 2>/dev/null || echo "0")
    fi

    # Count recent configmap changes across all namespaces (CAMO watches configmaps cluster-wide)
    configmap_changes_count=0
    configmaps_data=$(oc get configmaps --all-namespaces -o json 2>/dev/null)
    if [ -n "$configmaps_data" ]; then
        configmap_changes_count=$(echo "$configmaps_data" | jq "[.items[] | select(
            (.metadata.creationTimestamp > \"$lookback_timestamp\") or
            ([.metadata.managedFields[]?.time // \"\" | select(. > \"$lookback_timestamp\")] | length > 0)
        )] | length" 2>/dev/null || echo "0")
    fi

    # Check for recent ClusterVersion changes (CAMO watches for upgrades)
    clusterversion_changes_count=0
    clusterversion_data=$(oc get clusterversion version -o json 2>/dev/null)
    if [ -n "$clusterversion_data" ]; then
        clusterversion_last_update=$(echo "$clusterversion_data" | jq -r '.status.history[0].completionTime // ""' 2>/dev/null)
        if [ -n "$clusterversion_last_update" ] && [ "$clusterversion_last_update" != "null" ]; then
            if [[ "$clusterversion_last_update" > "$lookback_timestamp" ]]; then
                clusterversion_changes_count=1
            fi
        fi

        # Also check if an upgrade is currently in progress
        clusterversion_progressing=$(echo "$clusterversion_data" | jq -r '.status.conditions[] | select(.type == "Progressing") | .status' 2>/dev/null)
        if [ "$clusterversion_progressing" = "True" ]; then
            clusterversion_changes_count=1
        fi
    fi

    total_resource_changes=$((secret_changes_count + configmap_changes_count + clusterversion_changes_count))
    echo "    Resource changes (last 5m): secrets=$secret_changes_count, configmaps=$configmap_changes_count, clusterversion=$clusterversion_changes_count, total=$total_resource_changes"

    # Determine reconciliation status based on activity vs resource changes
    reconciliation_status="PASS"
    reconciliation_message=""

    if [ "$recent_logs" -gt 0 ]; then
        reconciliation_status="PASS"
        reconciliation_message="Active reconciliation ($recent_logs log entries, $total_resource_changes resource changes in last 5m)"
        echo "  ✓ Operator is actively reconciling (${recent_logs} logs, ${total_resource_changes} resource changes)"
    elif [ "$total_resource_changes" -gt 0 ]; then
        # Resources changed but no reconciliation - this is a problem
        reconciliation_status="FAIL"
        reconciliation_message="Resources changed but no reconciliation activity ($total_resource_changes resource changes, 0 reconciliations)"
        critical_count=$((critical_count + 1))
        echo "  ✗ CRITICAL: Resources changed but operator not reconciling (${total_resource_changes} changes, 0 logs)"
    else
        # No resource changes and no reconciliation - correctly idle
        reconciliation_status="PASS"
        reconciliation_message="Operator idle (0 resource changes, 0 reconciliations - expected)"
        echo "  ✓ Operator idle (expected when no changes)"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "reconciliation_activity",
  "status": "$reconciliation_status",
  "severity": "$([ "$reconciliation_status" = "FAIL" ] && echo "critical" || echo "info")",
  "message": "$reconciliation_message",
  "details": {
    "recent_log_count": $recent_logs,
    "secret_changes": $secret_changes_count,
    "configmap_changes": $configmap_changes_count,
    "clusterversion_changes": $clusterversion_changes_count,
    "total_resource_changes": $total_resource_changes
  }
}
EOF
)")

    # Check 5: Configuration errors in operator logs
    config_errors=$(oc logs -n "$NAMESPACE" "deployment/$DEPLOYMENT" --tail=100 2>/dev/null | grep -iE "failed|error|invalid.*config" | grep -v "level=info" | wc -l)
    config_errors_status="PASS"
    config_errors_message="No significant configuration errors"

    if [ "$config_errors" -gt 5 ]; then
        config_errors_status="WARN"
        config_errors_message="$config_errors configuration errors detected in logs"
        warning_count=$((warning_count + 1))
        echo "  ⚠ WARNING: ${config_errors} configuration errors found in recent logs"
    else
        echo "  ✓ No significant configuration errors in logs"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "configuration_errors",
  "status": "$config_errors_status",
  "severity": "warning",
  "message": "$config_errors_message",
  "details": {
    "error_count": $config_errors
  }
}
EOF
)")

    # Check 6: Prometheus Metrics Validation (All 10 CAMO metrics)
    echo "  Querying operator Prometheus metrics from Thanos..."

    prometheus_metrics_status="PASS"
    prometheus_metrics_message="All metrics healthy"
    prometheus_metrics_issues=""

    # Initialize all metrics with defaults
    am_config_validation_failed=0
    am_secret_exists_metric=1
    managed_ns_cm_exists=1
    ocp_ns_cm_exists=1
    ga_secret_exists=0
    pd_secret_exists=0
    dms_secret_exists=0
    am_secret_contains_ga=0
    am_secret_contains_pd=0
    am_secret_contains_dms=0

    # Helper function to query a single metric
    query_metric() {
        local metric_name="$1"
        local query="${metric_name}{namespace=\"$NAMESPACE\"}"
        local query_encoded=$(printf '%s' "$query" | jq -sRr @uri)

        local data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
            wget -q -O- "http://localhost:9090/api/v1/query?query=${query_encoded}" 2>/dev/null)

        if [ -n "$data" ] && echo "$data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
            echo "$data" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null
        else
            echo "0"
        fi
    }

    # Query all CAMO metrics
    am_config_validation_failed=$(query_metric "alertmanager_config_validation_failed")
    am_secret_exists_metric=$(query_metric "am_secret_exists")
    managed_ns_cm_exists=$(query_metric "managed_namespaces_configmap_exists")
    ocp_ns_cm_exists=$(query_metric "ocp_namespaces_configmap_exists")
    ga_secret_exists=$(query_metric "ga_secret_exists")
    pd_secret_exists=$(query_metric "pd_secret_exists")
    dms_secret_exists=$(query_metric "dms_secret_exists")
    am_secret_contains_ga=$(query_metric "am_secret_contains_ga")
    am_secret_contains_pd=$(query_metric "am_secret_contains_pd")
    am_secret_contains_dms=$(query_metric "am_secret_contains_dms")

    # Evaluate CRITICAL conditions
    if [ "$am_config_validation_failed" = "1" ]; then
        prometheus_metrics_status="FAIL"
        prometheus_metrics_issues="${prometheus_metrics_issues}Config validation failed; "
        critical_count=$((critical_count + 1))
        echo "  ✗ CRITICAL: AlertManager config validation failed"
    else
        echo "  ✓ AlertManager config validation passing"
    fi

    if [ "$am_secret_exists_metric" != "1" ]; then
        prometheus_metrics_status="FAIL"
        prometheus_metrics_issues="${prometheus_metrics_issues}AM secret missing; "
        critical_count=$((critical_count + 1))
        echo "  ✗ CRITICAL: AlertManager secret missing"
    else
        echo "  ✓ AlertManager secret exists"
    fi

    # Evaluate WARNING conditions
    if [ "$managed_ns_cm_exists" != "1" ]; then
        if [ "$prometheus_metrics_status" = "PASS" ]; then
            prometheus_metrics_status="WARN"
        fi
        prometheus_metrics_issues="${prometheus_metrics_issues}Managed namespaces ConfigMap missing; "
        warning_count=$((warning_count + 1))
        echo "  ⚠ WARNING: Managed namespaces ConfigMap missing"
    else
        echo "  ✓ Managed namespaces ConfigMap exists"
    fi

    if [ "$ocp_ns_cm_exists" != "1" ]; then
        if [ "$prometheus_metrics_status" = "PASS" ]; then
            prometheus_metrics_status="WARN"
        fi
        prometheus_metrics_issues="${prometheus_metrics_issues}OCP namespaces ConfigMap missing; "
        warning_count=$((warning_count + 1))
        echo "  ⚠ WARNING: OCP namespaces ConfigMap missing"
    else
        echo "  ✓ OCP namespaces ConfigMap exists"
    fi

    # Report INFO on optional integration secrets/configs (don't affect status)
    integrations_configured=()
    integrations_missing=()

    if [ "$pd_secret_exists" = "1" ]; then
        integrations_configured+=("PagerDuty secret")
        if [ "$am_secret_contains_pd" = "1" ]; then
            echo "  ✓ PagerDuty integration fully configured"
        else
            echo "  ℹ PagerDuty secret exists but not in AlertManager config"
        fi
    fi

    if [ "$ga_secret_exists" = "1" ]; then
        integrations_configured+=("GoAlert secret")
        if [ "$am_secret_contains_ga" = "1" ]; then
            echo "  ✓ GoAlert integration fully configured"
        else
            echo "  ℹ GoAlert secret exists but not in AlertManager config"
        fi
    fi

    if [ "$dms_secret_exists" = "1" ]; then
        integrations_configured+=("DMS secret")
        if [ "$am_secret_contains_dms" = "1" ]; then
            echo "  ✓ Dead Man's Snitch integration fully configured"
        else
            echo "  ℹ DMS secret exists but not in AlertManager config"
        fi
    fi

    if [ ${#integrations_configured[@]} -eq 0 ]; then
        echo "  ℹ No optional integrations configured (PD/GA/DMS)"
    fi

    # Clean up trailing separator
    prometheus_metrics_issues=$(echo "$prometheus_metrics_issues" | sed 's/; $//')
    if [ -n "$prometheus_metrics_issues" ]; then
        prometheus_metrics_message="$prometheus_metrics_issues"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "prometheus_metrics",
  "status": "$prometheus_metrics_status",
  "severity": "critical",
  "message": "$prometheus_metrics_message",
  "details": {
    "config_validation_failed": $am_config_validation_failed,
    "am_secret_exists": $am_secret_exists_metric,
    "managed_namespaces_cm_exists": $managed_ns_cm_exists,
    "ocp_namespaces_cm_exists": $ocp_ns_cm_exists,
    "ga_secret_exists": $ga_secret_exists,
    "pd_secret_exists": $pd_secret_exists,
    "dms_secret_exists": $dms_secret_exists,
    "am_secret_contains_ga": $am_secret_contains_ga,
    "am_secret_contains_pd": $am_secret_contains_pd,
    "am_secret_contains_dms": $am_secret_contains_dms
  }
}
EOF
)")

    # Check 7: Reconciliation Behavior Validation
    # NOTE: Reuses resource change data from reconciliation_activity check to avoid duplicate API calls
    echo "  Validating reconciliation behavior for loops and excessive reconciliation..."

    reconciliation_behavior_status="PASS"
    reconciliation_behavior_message="Reconciliation matches resource activity"
    reconciliation_rate=0

    # Resource counts already collected in reconciliation_activity check
    # (secret_changes_count, configmap_changes_count, clusterversion_changes_count, total_resource_changes)

    # Calculate reconciliation rate (reconciliations per resource change)
    if [ "$total_resource_changes" -gt 0 ]; then
        reconciliation_rate=$(awk "BEGIN {printf \"%.2f\", $recent_logs / $total_resource_changes}")
    else
        reconciliation_rate=0
    fi

    echo "    Reconciliation rate: $reconciliation_rate reconciliations per resource change"

    # Evaluate reconciliation behavior
    if [ "$recent_logs" -gt 0 ] && [ "$total_resource_changes" -eq 0 ]; then
        # Reconciling without resource changes - possible reconciliation loop
        if [ "$recent_logs" -gt 20 ]; then
            reconciliation_behavior_status="WARN"
            reconciliation_behavior_message="Excessive reconciliation without resource changes (${recent_logs} reconciliations, 0 changes)"
            warning_count=$((warning_count + 1))
            echo "  ⚠ WARNING: Reconciling without resource changes (possible loop)"
        else
            reconciliation_behavior_status="INFO"
            reconciliation_behavior_message="Reconciling without recent resource changes (${recent_logs} reconciliations, 0 changes detected in 5m window)"
            echo "  ℹ Reconciling without recent resource changes (may be older changes or cluster-scoped resources)"
        fi
    elif [ "$recent_logs" -eq 0 ] && [ "$total_resource_changes" -gt 3 ]; then
        # Resources changed but operator not reconciling - broken watch
        reconciliation_behavior_status="FAIL"
        reconciliation_behavior_message="Resources changed but operator not reconciling (${total_resource_changes} changes, 0 reconciliations)"
        critical_count=$((critical_count + 1))
        echo "  ✗ CRITICAL: Resources changed but operator not reconciling (possible broken watch)"
    elif [ "$recent_logs" -gt 0 ] && [ "$total_resource_changes" -gt 0 ]; then
        # Both activity present - check for excessive reconciliation
        rate_float=$(awk "BEGIN {print $reconciliation_rate}")
        if awk "BEGIN {exit !($rate_float > 10.0)}"; then
            reconciliation_behavior_status="WARN"
            reconciliation_behavior_message="High reconciliation rate (${reconciliation_rate}x per change, ${recent_logs} reconciliations, ${total_resource_changes} changes)"
            warning_count=$((warning_count + 1))
            echo "  ⚠ WARNING: High reconciliation rate (${reconciliation_rate}x per change)"
        else
            reconciliation_behavior_status="PASS"
            reconciliation_behavior_message="Reconciliation matches resource activity (${recent_logs} reconciliations, ${total_resource_changes} changes)"
            echo "  ✓ Reconciliation behavior is appropriate"
        fi
    else
        # Both idle - expected
        reconciliation_behavior_status="PASS"
        reconciliation_behavior_message="Operator idle (no resources changed, no reconciliation)"
        echo "  ✓ Operator idle (expected when no changes)"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "reconciliation_behavior",
  "status": "$reconciliation_behavior_status",
  "severity": "warning",
  "message": "$reconciliation_behavior_message",
  "details": {
    "recent_log_count": $recent_logs,
    "secret_changes": $secret_changes_count,
    "configmap_changes": $configmap_changes_count,
    "clusterversion_changes": $clusterversion_changes_count,
    "total_resource_changes": $total_resource_changes,
    "reconciliation_rate": "$reconciliation_rate",
    "lookback_window": "5m",
    "note": "CAMO watches Secrets, ConfigMaps, and ClusterVersion. Reconciliations can be triggered by creates, updates, or deletes of these resources."
  }
}
EOF
)")

    # Check 8: AlertManager Log Analysis
    echo "  Analyzing AlertManager logs..."

    alertmanager_log_errors=0
    alertmanager_log_warnings=0
    alertmanager_log_status="PASS"
    alertmanager_log_message="No errors or warnings in AlertManager logs"
    am_error_samples=()
    am_warning_samples=()

    # Get alertmanager pod names
    alertmanager_pod_names=$(echo "$alertmanager_pods" | jq -r '.items[].metadata.name' 2>/dev/null)

    if [ -n "$alertmanager_pod_names" ]; then
        # Count errors and warnings in AlertManager logs (last 1000 lines per pod)
        # Also collect sample log lines
        for am_pod in $alertmanager_pod_names; do
            pod_logs=$(oc logs -n "$NAMESPACE" "$am_pod" --tail=1000 2>/dev/null)

            pod_errors=$(echo "$pod_logs" | grep -i "level=error" | wc -l | tr -d ' ')
            pod_warnings=$(echo "$pod_logs" | grep -i "level=warn" | wc -l | tr -d ' ')

            alertmanager_log_errors=$((alertmanager_log_errors + pod_errors))
            alertmanager_log_warnings=$((alertmanager_log_warnings + pod_warnings))

            # Collect sample error messages (first 5 total across all pods)
            if [ "$pod_errors" -gt 0 ] && [ ${#am_error_samples[@]} -lt 5 ]; then
                while IFS= read -r line; do
                    if [ ${#am_error_samples[@]} -lt 5 ]; then
                        am_error_samples+=("[$am_pod] $line")
                    fi
                done < <(echo "$pod_logs" | grep -i "level=error" | head -5)
            fi

            # Collect sample warning messages (first 5 total across all pods)
            if [ "$pod_warnings" -gt 0 ] && [ ${#am_warning_samples[@]} -lt 5 ]; then
                while IFS= read -r line; do
                    if [ ${#am_warning_samples[@]} -lt 5 ]; then
                        am_warning_samples+=("[$am_pod] $line")
                    fi
                done < <(echo "$pod_logs" | grep -i "level=warn" | head -5)
            fi
        done

        if [ "$alertmanager_log_errors" -gt 0 ]; then
            alertmanager_log_status="WARN"
            alertmanager_log_message="Found $alertmanager_log_errors errors and $alertmanager_log_warnings warnings in AlertManager logs"
            warning_count=$((warning_count + 1))
            echo "  ⚠ WARNING: AlertManager has $alertmanager_log_errors errors and $alertmanager_log_warnings warnings in logs"
        elif [ "$alertmanager_log_warnings" -gt 0 ]; then
            alertmanager_log_status="WARN"
            alertmanager_log_message="Found $alertmanager_log_warnings warnings in AlertManager logs (0 errors)"
            warning_count=$((warning_count + 1))
            echo "  ⚠ WARNING: AlertManager has $alertmanager_log_warnings warnings in logs (0 errors)"
        else
            echo "  ✓ AlertManager logs clean (no errors or warnings)"
        fi
    else
        alertmanager_log_status="SKIP"
        alertmanager_log_message="No AlertManager pods to check"
        echo "  ℹ No AlertManager pods found for log analysis"
    fi

    # Escape samples for JSON
    am_error_samples_json="[]"
    if [ ${#am_error_samples[@]} -gt 0 ]; then
        am_error_samples_json=$(printf '%s\n' "${am_error_samples[@]}" | jq -R . | jq -s .)
    fi

    am_warning_samples_json="[]"
    if [ ${#am_warning_samples[@]} -gt 0 ]; then
        am_warning_samples_json=$(printf '%s\n' "${am_warning_samples[@]}" | jq -R . | jq -s .)
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "alertmanager_logs",
  "status": "$alertmanager_log_status",
  "severity": "warning",
  "message": "$alertmanager_log_message",
  "details": {
    "error_count": $alertmanager_log_errors,
    "warning_count": $alertmanager_log_warnings,
    "log_lines_checked": 1000,
    "error_samples": $am_error_samples_json,
    "warning_samples": $am_warning_samples_json
  }
}
EOF
)")

    # Check 9: AlertManager Pod Events
    echo "  Checking AlertManager pod events..."

    alertmanager_events_status="PASS"
    alertmanager_events_message="No warning or error events"
    alertmanager_warning_events=0
    alertmanager_error_events=0
    alertmanager_events_json="[]"

    if [ -n "$alertmanager_pod_names" ]; then
        for am_pod in $alertmanager_pod_names; do
            pod_events=$(oc get events -n "$NAMESPACE" --field-selector involvedObject.name="$am_pod" -o json 2>/dev/null)

            if [ -n "$pod_events" ]; then
                warning_events=$(echo "$pod_events" | jq -r '[.items[] | select(.type == "Warning")] | length' 2>/dev/null || echo "0")
                alertmanager_warning_events=$((alertmanager_warning_events + warning_events))

                # Collect event details
                events_detail=$(echo "$pod_events" | jq -c '[.items[] | select(.type == "Warning") | {
                    pod: .involvedObject.name,
                    reason: .reason,
                    message: .message,
                    count: .count,
                    last_timestamp: .lastTimestamp
                }]' 2>/dev/null || echo "[]")

                # Merge events
                if [ "$alertmanager_events_json" = "[]" ]; then
                    alertmanager_events_json="$events_detail"
                else
                    alertmanager_events_json=$(echo "$alertmanager_events_json $events_detail" | jq -s 'add' 2>/dev/null || echo "[]")
                fi
            fi
        done

        if [ "$alertmanager_warning_events" -gt 0 ]; then
            alertmanager_events_status="WARN"
            alertmanager_events_message="Found $alertmanager_warning_events warning events for AlertManager pods"
            warning_count=$((warning_count + 1))
            echo "  ⚠ WARNING: AlertManager has $alertmanager_warning_events warning events"
        else
            echo "  ✓ No warning or error events for AlertManager pods"
        fi
    else
        alertmanager_events_status="SKIP"
        alertmanager_events_message="No AlertManager pods to check"
        echo "  ℹ No AlertManager pods found for event checking"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "alertmanager_events",
  "status": "$alertmanager_events_status",
  "severity": "warning",
  "message": "$alertmanager_events_message",
  "details": {
    "warning_event_count": $alertmanager_warning_events,
    "events": $alertmanager_events_json
  }
}
EOF
)")

    # Check 10: CAMO Deployment Events
    echo "  Checking CAMO deployment events..."

    camo_events_status="PASS"
    camo_events_message="No warning or error events"
    camo_warning_events=0
    camo_events_json="[]"

    camo_events=$(oc get events -n "$NAMESPACE" --field-selector involvedObject.name="$DEPLOYMENT" -o json 2>/dev/null)

    if [ -n "$camo_events" ]; then
        camo_warning_events=$(echo "$camo_events" | jq -r '[.items[] | select(.type == "Warning")] | length' 2>/dev/null || echo "0")

        camo_events_json=$(echo "$camo_events" | jq -c '[.items[] | select(.type == "Warning") | {
            reason: .reason,
            message: .message,
            count: .count,
            last_timestamp: .lastTimestamp
        }]' 2>/dev/null || echo "[]")

        if [ "$camo_warning_events" -gt 0 ]; then
            camo_events_status="WARN"
            camo_events_message="Found $camo_warning_events warning events for CAMO deployment"
            warning_count=$((warning_count + 1))
            echo "  ⚠ WARNING: CAMO deployment has $camo_warning_events warning events"
        else
            echo "  ✓ No warning or error events for CAMO deployment"
        fi
    else
        echo "  ✓ No warning or error events for CAMO deployment"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "camo_events",
  "status": "$camo_events_status",
  "severity": "warning",
  "message": "$camo_events_message",
  "details": {
    "warning_event_count": $camo_warning_events,
    "events": $camo_events_json
  }
}
EOF
)")

    # Check 11: OLM Subscription and CSV Orphan Detection
    # Only run if version doesn't match expected version (potential OLM issue)
    echo "  Checking for OLM subscription issues..."

    olm_subscription_status="SKIP"
    olm_subscription_message="Version matches expected - no OLM check needed"
    resolution_failed="false"
    resolution_failed_message=""
    orphaned_csvs=0
    orphaned_csv_names="[]"
    subscription_exists="false"

    if [ "$version_check_status" != "PASS" ]; then
        # Check if subscription exists (indicates OLM installation vs PKO)
        subscription_check=$(oc get subscription.operators.coreos.com "$DEPLOYMENT" -n "$NAMESPACE" 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$subscription_check" ]; then
            subscription_exists="true"
            echo "  ✓ Subscription exists (OLM installation detected)"

            # Check for ResolutionFailed status
            resolution_failed_status=$(oc get subscription.operators.coreos.com "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].status}' 2>/dev/null)

            if [ "$resolution_failed_status" = "True" ]; then
                resolution_failed="true"
                resolution_failed_message=$(oc get subscription.operators.coreos.com "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].message}' 2>/dev/null | head -c 500)

                echo "  ✗ CRITICAL: Subscription has ResolutionFailed=True"
                echo "    Error: ${resolution_failed_message:0:100}..."

                # Check for orphaned CSVs (CSVs without ownerReferences)
                csvs=$(oc get csv.operators.coreos.com -n "$NAMESPACE" -o json 2>/dev/null | jq -r ".items[] | select(.metadata.name | contains(\"$DEPLOYMENT\"))")

                if [ -n "$csvs" ]; then
                    orphaned_csv_list=$(echo "$csvs" | jq -r '. | select(.metadata.ownerReferences == null or (.metadata.ownerReferences | length) == 0) | .metadata.name' 2>/dev/null)

                    if [ -n "$orphaned_csv_list" ]; then
                        orphaned_csvs=$(echo "$orphaned_csv_list" | wc -l | tr -d ' ')
                        orphaned_csv_names=$(echo "$orphaned_csv_list" | jq -R . | jq -s . 2>/dev/null || echo "[]")

                        olm_subscription_status="FAIL"
                        olm_subscription_message="OLM subscription has ResolutionFailed; Found $orphaned_csvs orphaned CSV(s) blocking upgrade"
                        critical_count=$((critical_count + 1))

                        echo "  ✗ CRITICAL: Found $orphaned_csvs orphaned CSV(s): $orphaned_csv_list"
                    else
                        olm_subscription_status="FAIL"
                        olm_subscription_message="OLM subscription has ResolutionFailed but no orphaned CSVs detected"
                        critical_count=$((critical_count + 1))
                    fi
                else
                    olm_subscription_status="FAIL"
                    olm_subscription_message="OLM subscription has ResolutionFailed; No CSVs found"
                    critical_count=$((critical_count + 1))
                fi
            else
                olm_subscription_status="PASS"
                olm_subscription_message="OLM subscription healthy (no ResolutionFailed)"
                echo "  ✓ OLM subscription healthy"
            fi
        else
            # No OLM subscription found - defer judgment until PKO check
            subscription_exists="false"
            olm_subscription_status="PENDING_PKO_CHECK"
            olm_subscription_message="No OLM subscription found"
            echo "  ℹ No OLM subscription found (checking PKO...)"
        fi
    else
        echo "  ℹ Version matches expected - skipping OLM check"
    fi

    # Check 12: PKO (Package Operator) ClusterPackage Health
    echo "  Checking for PKO ClusterPackage..."

    pko_package_status="SKIP"
    pko_package_message="Version matches expected - no PKO check needed"
    cluster_package_exists="false"
    cluster_package_ready="unknown"
    cluster_package_phase="unknown"
    cluster_package_conditions="[]"
    dual_installation="false"
    dual_installation_message=""

    if [ "$version_check_status" != "PASS" ]; then
        # Check if ClusterPackage exists (indicates PKO installation)
        cluster_package_check=$(oc get clusterpackage "$DEPLOYMENT" 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$cluster_package_check" ]; then
            cluster_package_exists="true"
            echo "  ✓ ClusterPackage exists (PKO installation detected)"

            # Get ClusterPackage status
            cluster_package_phase=$(oc get clusterpackage "$DEPLOYMENT" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
            cluster_package_ready=$(oc get clusterpackage "$DEPLOYMENT" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "unknown")

            # Get all conditions
            cluster_package_conditions=$(oc get clusterpackage "$DEPLOYMENT" -o json 2>/dev/null | jq -c '.status.conditions // []' 2>/dev/null || echo "[]")

            # Check for dual installation (CRITICAL ERROR)
            if [ "$subscription_exists" = "true" ]; then
                dual_installation="true"
                dual_installation_message="CRITICAL: Both OLM Subscription and PKO ClusterPackage detected - conflicting deployment methods"
                pko_package_status="FAIL"
                pko_package_message="$dual_installation_message"
                critical_count=$((critical_count + 1))
                echo "  ✗ CRITICAL: Dual installation detected (OLM + PKO)"
            else
                # Check ClusterPackage health
                if [ "$cluster_package_ready" = "True" ] && [ "$cluster_package_phase" = "Available" ]; then
                    pko_package_status="PASS"
                    pko_package_message="PKO ClusterPackage healthy (Ready=True, Phase=$cluster_package_phase)"
                    echo "  ✓ PKO ClusterPackage healthy (Phase: $cluster_package_phase)"
                elif [ "$cluster_package_ready" = "False" ]; then
                    # Get failure reason from conditions
                    failure_reason=$(oc get clusterpackage "$DEPLOYMENT" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null | head -c 200)
                    pko_package_status="FAIL"
                    pko_package_message="PKO ClusterPackage not ready (Phase: $cluster_package_phase): $failure_reason"
                    critical_count=$((critical_count + 1))
                    echo "  ✗ CRITICAL: PKO ClusterPackage not ready"
                    echo "    Phase: $cluster_package_phase"
                    echo "    Reason: ${failure_reason:0:100}..."
                else
                    pko_package_status="WARN"
                    pko_package_message="PKO ClusterPackage in unexpected state (Ready=$cluster_package_ready, Phase=$cluster_package_phase)"
                    warning_count=$((warning_count + 1))
                    echo "  ⚠ WARNING: PKO ClusterPackage state unclear"
                    echo "    Ready: $cluster_package_ready"
                    echo "    Phase: $cluster_package_phase"
                fi
            fi
        else
            cluster_package_exists="false"

            # Check for dual installation scenario (neither or OLM only)
            if [ "$subscription_exists" = "true" ]; then
                pko_package_status="SKIP"
                pko_package_message="No PKO ClusterPackage found (OLM-only installation)"
                echo "  ℹ No PKO ClusterPackage found (OLM-only installation)"
            else
                # CRITICAL: Neither OLM nor PKO found - operator not deployed
                pko_package_status="FAIL"
                pko_package_message="CRITICAL: No OLM Subscription or PKO ClusterPackage found - operator not deployed"
                critical_count=$((critical_count + 1))
                echo "  ✗ CRITICAL: No OLM or PKO artifacts found - operator not deployed"

                # Update OLM check status as well (since neither exists)
                olm_subscription_status="FAIL"
                olm_subscription_message="CRITICAL: No OLM Subscription or PKO ClusterPackage found - operator not deployed"
            fi
        fi
    else
        echo "  ℹ Version matches expected - skipping PKO check"
    fi

    # Finalize OLM check status if it was pending PKO check
    if [ "$olm_subscription_status" = "PENDING_PKO_CHECK" ]; then
        if [ "$cluster_package_exists" = "true" ]; then
            # PKO found, OLM not found = PKO-only installation (normal)
            olm_subscription_status="SKIP"
            olm_subscription_message="No OLM subscription found (PKO installation detected)"
        else
            # Neither found - already set to FAIL above
            : # no-op, status already set
        fi
    fi

    # Escape resolution failed message for JSON
    resolution_failed_message_escaped=$(echo "$resolution_failed_message" | jq -Rs . 2>/dev/null || echo '""')

    health_checks+=("$(cat <<EOF
{
  "check": "olm_subscription_health",
  "status": "$olm_subscription_status",
  "severity": "critical",
  "message": "$olm_subscription_message",
  "details": {
    "subscription_exists": $subscription_exists,
    "resolution_failed": $resolution_failed,
    "resolution_failed_message": $resolution_failed_message_escaped,
    "orphaned_csv_count": $orphaned_csvs,
    "orphaned_csv_names": $orphaned_csv_names
  }
}
EOF
)")

    health_checks+=("$(cat <<EOF
{
  "check": "pko_clusterpackage_health",
  "status": "$pko_package_status",
  "severity": "critical",
  "message": "$pko_package_message",
  "details": {
    "cluster_package_exists": $cluster_package_exists,
    "cluster_package_phase": "$cluster_package_phase",
    "cluster_package_ready": "$cluster_package_ready",
    "cluster_package_conditions": $cluster_package_conditions,
    "dual_installation": $dual_installation,
    "dual_installation_message": "$dual_installation_message"
  }
}
EOF
)")

    # Secret-based checks (require --secrets flag)
    if [ "$CHECK_SECRETS" = true ]; then
        echo "  Running extended checks (secrets enabled)..."

        # Check 6: Alertmanager main secret exists (managed by CAMO)
        alertmanager_secret=$(ocm backplane elevate "${REASON}" -- get secret alertmanager-main -n "$NAMESPACE" -o json 2>/dev/null)
        alertmanager_secret_status="FAIL"
        alertmanager_secret_message="Secret not found"
        secret_size=0

        if [ -n "$alertmanager_secret" ] && [ "$alertmanager_secret" != "null" ]; then
            secret_size=$(echo "$alertmanager_secret" | jq -r '.data | length')
            alertmanager_secret_status="PASS"
            alertmanager_secret_message="Secret exists (${secret_size} keys)"
            echo "  ✓ Alertmanager secret exists (${secret_size} keys)"
        else
            critical_count=$((critical_count + 1))
            echo "  ✗ Alertmanager secret not found"
        fi

        health_checks+=("$(cat <<EOF
{
  "check": "alertmanager_secret",
  "status": "$alertmanager_secret_status",
  "severity": "critical",
  "message": "$alertmanager_secret_message",
  "details": {
    "key_count": $secret_size
  }
}
EOF
)")

        # Check 7: CAMO ConfigMap exists
        camo_config=$(oc get configmap configure-alertmanager-operator-config -n "$NAMESPACE" -o json 2>/dev/null)
        camo_configmap_status="INFO"
        camo_configmap_message="ConfigMap not found (may not be required)"
        config_keys=0

        if [ -n "$camo_config" ] && [ "$camo_config" != "null" ]; then
            config_keys=$(echo "$camo_config" | jq -r '.data | keys | length')
            camo_configmap_status="PASS"
            camo_configmap_message="ConfigMap exists (${config_keys} keys)"
            echo "  ✓ CAMO ConfigMap exists (${config_keys} keys)"
        else
            echo "  ℹ CAMO ConfigMap not found (may not be required)"
        fi

        health_checks+=("$(cat <<EOF
{
  "check": "camo_configmap",
  "status": "$camo_configmap_status",
  "severity": "info",
  "message": "$camo_configmap_message",
  "details": {
    "key_count": $config_keys
  }
}
EOF
)")

        # Check 8: PagerDuty secret (if configured)
        pd_secret=$(ocm backplane elevate "${REASON}" -- get secret pd-secret -n "$NAMESPACE" 2>/dev/null)
        pd_secret_status="INFO"
        pd_secret_message="PagerDuty secret not found (may not be configured)"

        if [ -n "$pd_secret" ]; then
            pd_secret_status="PASS"
            pd_secret_message="PagerDuty integration configured"
            echo "  ✓ PagerDuty integration secret exists"
        else
            echo "  ℹ PagerDuty secret not found (may not be configured)"
        fi

        health_checks+=("$(cat <<EOF
{
  "check": "pagerduty_secret",
  "status": "$pd_secret_status",
  "severity": "info",
  "message": "$pd_secret_message",
  "details": {}
}
EOF
)")
    else
        echo "  ℹ Extended secret checks disabled (use --secrets to enable)"
    fi
fi

# RMO-specific checks (placeholder for future implementation)
if [[ "$OPERATOR_NAME" == *"route-monitor"* ]]; then
    echo "Running RMO-specific health checks..."
    echo "  ℹ No specific checks implemented yet"
fi

echo ""

#=============================================================================
# EVENT COLLECTION FOR CHARTING
#=============================================================================
echo "================================================================================"
echo "Collecting events for chart visualization..."
echo "================================================================================"

# Collect pod restart events
restart_events="[]"
if [ -n "$pod_name" ]; then
    echo "Collecting pod restart events..."

    # Get pod events related to restarts
    pod_events=$(oc get events -n "$NAMESPACE" \
        --field-selector involvedObject.name="$pod_name" \
        -o json 2>/dev/null || echo '{"items":[]}')

    # Extract restart events with timestamps
    restart_events=$(echo "$pod_events" | jq -c '
        [.items[] |
         select(.reason == "BackOff" or .reason == "CrashLoopBackOff" or .message | contains("restart")) |
         {
           timestamp: (.lastTimestamp // .eventTime // .firstTimestamp | fromdateiso8601),
           reason: .reason,
           message: .message
         }
        ] | sort_by(.timestamp)
    ' 2>/dev/null || echo "[]")

    restart_count=$(echo "$restart_events" | jq 'length' 2>/dev/null || echo "0")
    echo "  Found $restart_count restart events"
fi

# Collect version change events
version_events="[]"
echo "Collecting operator version change history..."

# Query ReplicaSet history to find version changes
replicasets=$(oc get replicasets -n "$NAMESPACE" \
    -l "app.kubernetes.io/name=$DEPLOYMENT" \
    -o json 2>/dev/null || echo '{"items":[]}')

# Extract version changes from ReplicaSet annotations and creation times
version_events=$(echo "$replicasets" | jq -c '
    [.items[] |
     select(.metadata.annotations."deployment.kubernetes.io/revision") |
     {
       timestamp: (.metadata.creationTimestamp | fromdateiso8601),
       version: (.spec.template.spec.containers[0].image |
                 split("@")[1] // split(":")[1] // "unknown" |
                 split(":")[0] |
                 .[0:12]),
       revision: .metadata.annotations."deployment.kubernetes.io/revision",
       replicas: .status.replicas
     }
    ] | sort_by(.timestamp)
' 2>/dev/null || echo "[]")

version_count=$(echo "$version_events" | jq 'length' 2>/dev/null || echo "0")
echo "  Found $version_count version change events"

echo ""

#=============================================================================
# FINAL HEALTH SUMMARY
#=============================================================================

# Determine overall status
if [ "$critical_count" -gt 0 ]; then
    overall_status="CRITICAL"
elif [ "$warning_count" -gt 0 ]; then
    overall_status="WARNING"
else
    overall_status="HEALTHY"
fi

echo "================================================================================"
echo "HEALTH CHECK SUMMARY"
echo "================================================================================"
echo "Overall Status: $overall_status"
echo "Critical Issues: $critical_count"
echo "Warnings: $warning_count"
echo "================================================================================"
echo ""

# Debug: Show health check array status before JSON conversion
debug_log "================================================================================"
debug_log "PRE-JSON CONVERSION DIAGNOSTICS"
debug_log "================================================================================"
debug_log "health_checks array size: ${#health_checks[@]}"
debug_log "restart_events size: $(echo "$restart_events" | jq 'length' 2>/dev/null || echo 'invalid')"
debug_log "version_events size: $(echo "$version_events" | jq 'length' 2>/dev/null || echo 'invalid')"
if [ "$DEBUG" = "true" ] && [ ${#health_checks[@]} -gt 0 ]; then
    debug_log "First 3 health check entries:"
    for i in 0 1 2; do
        if [ $i -lt ${#health_checks[@]} ]; then
            debug_log "--- Entry $i (first 100 chars): ${health_checks[$i]:0:100}"
        fi
    done
fi
debug_log "================================================================================"

# Restore stdout and output data
exec 1>&3

# Build final JSON output
if [ "$OUTPUT_FORMAT" = "json" ]; then
    # Combine all health checks into JSON array
    # Default to empty array if health_checks is empty or jq fails
    debug_log "Health checks array size: ${#health_checks[@]}"
    debug_log "Critical count: $critical_count, Warning count: $warning_count"

    if [ ${#health_checks[@]} -eq 0 ]; then
        debug_log "Health checks array is empty, using empty JSON array"
        health_checks_json="[]"
    else
        debug_log "Converting ${#health_checks[@]} health check entries to JSON..."

        # If DEBUG is enabled, test each health check individually
        if [ "$DEBUG" = "true" ]; then
            debug_log "Testing each health check entry for JSON validity..."
            for idx in "${!health_checks[@]}"; do
                entry_check=$(echo "${health_checks[$idx]}" | jq . 2>/dev/null)
                if [ $? -ne 0 ]; then
                    debug_log "ERROR: Health check entry #$idx failed JSON parsing:"
                    echo "${health_checks[$idx]}" >&2
                else
                    check_name=$(echo "$entry_check" | jq -r '.check // "unknown"' 2>/dev/null)
                    debug_log "  ✓ Entry #$idx ($check_name) - valid JSON"
                fi
            done
        fi

        # Try to convert to JSON and capture any errors
        jq_error_file=$(mktemp)
        health_checks_json=$(printf '%s\n' "${health_checks[@]}" | jq -s . 2>"$jq_error_file")
        jq_exit_code=$?

        if [ $jq_exit_code -ne 0 ]; then
            debug_log "ERROR: jq failed with exit code $jq_exit_code"
            debug_log "jq error output:"
            if [ "$DEBUG" = "true" ]; then
                cat "$jq_error_file" >&2
            fi
            debug_log "First health check entry (for diagnosis):"
            if [ "$DEBUG" = "true" ] && [ ${#health_checks[@]} -gt 0 ]; then
                echo "${health_checks[0]}" | head -20 >&2
            fi
            health_checks_json="[]"
        fi
        rm -f "$jq_error_file"

        debug_log "Health checks JSON length: ${#health_checks_json} characters"
    fi

    # Convert API errors to JSON array
    api_errors_json="[]"
    if [ -n "${api_errors+x}" ] && [ ${#api_errors[@]} -gt 0 ]; then
        api_errors_json=$(printf '%s\n' "${api_errors[@]}" | jq -s . 2>/dev/null || echo "[]")
        debug_log "API errors count: ${#api_errors[@]}"
    fi

    cat << EOF
{
  "cluster_id": "${health_data[cluster_id]}",
  "cluster_name": "${health_data[cluster_name]}",
  "cluster_version": "${health_data[cluster_version]}",
  "operator_name": "${health_data[operator_name]}",
  "operator_version": "${health_data[operator_version]}",
  "operator_image": "${health_data[operator_image]}",
  "namespace": "${health_data[namespace]}",
  "deployment": "${health_data[deployment]}",
  "timestamp": "${health_data[timestamp]}",
  "backplane_login": {
    "status": "SUCCESS",
    "exit_code": 0,
    "error_message": ""
  },
  "health_summary": {
    "overall_status": "$overall_status",
    "critical_count": $critical_count,
    "warning_count": $warning_count
  },
  "health_checks": $health_checks_json,
  "api_errors": $api_errors_json,
  "events": {
    "pod_restarts": $restart_events,
    "version_changes": $version_events
  }
}
EOF
else
    # CSV output (simplified)
    echo "cluster_id,cluster_name,operator_version,overall_status,critical_count,warning_count,timestamp"
    echo "${health_data[cluster_id]},${health_data[cluster_name]},${health_data[operator_version]},$overall_status,$critical_count,$warning_count,${health_data[timestamp]}"
fi
