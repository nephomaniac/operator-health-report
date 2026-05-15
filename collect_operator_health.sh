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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse ISO8601 timestamp to epoch seconds (handles both GNU and BSD date, strips fractional seconds)
parse_timestamp() {
    local ts="${1:-}"
    [ -z "$ts" ] && echo "0" && return
    local clean="${ts%%.*}"
    [[ "$ts" == *"."* ]] && clean="${clean}Z"
    TZ=UTC /bin/date -j -f "%Y-%m-%dT%H:%M:%SZ" "$clean" "+%s" 2>/dev/null || \
    date -u -d "$clean" "+%s" 2>/dev/null || \
    echo "0"
}

# SAAS refs script — prefer repo copy, fall back to home directory
SAAS_REFS_SCRIPT=""
if [ -f "$SCRIPT_DIR/get_app_interface_saas_refs_with_images.sh" ]; then
    SAAS_REFS_SCRIPT="$SCRIPT_DIR/get_app_interface_saas_refs_with_images.sh"
elif [ -f "$SCRIPT_DIR/get_app_interface_saas_refs.sh" ]; then
    SAAS_REFS_SCRIPT="$SCRIPT_DIR/get_app_interface_saas_refs.sh"
elif [ -n "$SAAS_REFS_SCRIPT" ] && [ -f "$SAAS_REFS_SCRIPT" ]; then
    SAAS_REFS_SCRIPT="$SAAS_REFS_SCRIPT"
fi

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

# Capture script version (git commit SHA of operator-health-report repo)
# This allows regenerating HTML from JSON by checking out the matching commit
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# AUTO-UPDATED by post-commit hook — do not edit manually
SCRIPT_VERSION="8417798"

# Default values
NAMESPACE="openshift-monitoring"
DEPLOYMENT="configure-alertmanager-operator"
OUTPUT_FORMAT="json"
CLUSTER_ID=""
CLUSTER_NAME=""
CLUSTER_VERSION=""
REASON=""
OPERATOR_NAME=""

# Cache for image tag to SHA resolution (to avoid repeated registry queries)
declare -A image_sha_cache

# Check if skopeo is available for image SHA resolution
SKOPEO_AVAILABLE=false
SKOPEO_WARNING_SHOWN=false
if command -v skopeo &>/dev/null; then
    SKOPEO_AVAILABLE=true
fi

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

    # Return the raw hive cluster name — target name derivation happens later
    # after we determine whether to use the PKO or OLM SAAS file
    echo "$hive_cluster"
    return 0
}

# Derive SAAS target name and file for a given hive cluster
# PKO targets use "camo-pko-<simplified-name>" naming convention
# OLM targets use "camo-<hive-cluster>" naming convention
# Tries PKO SAAS file first (active), falls back to OLM (deprecated)
resolve_saas_target() {
    local hive_cluster="$1"
    local ocm_env="$2"
    local operator="${3:-$OPERATOR_NAME}"

    # Per-operator SAAS file and target prefix mappings
    local pko_saas olm_saas target_prefix
    case "$operator" in
        *configure-alertmanager*)
            pko_saas="saas-configure-alertmanager-operator-pko.yaml"
            olm_saas="saas-configure-alertmanager-operator.yaml"
            target_prefix="camo"
            ;;
        *route-monitor*)
            pko_saas="saas-route-monitor-operator-pko.yaml"
            olm_saas="saas-route-monitor-operator.yaml"
            target_prefix="rmo"
            ;;
        *osd-metrics-exporter*)
            pko_saas="saas-osd-metrics-exporter-pko.yaml"
            olm_saas="saas-osd-metrics-exporter.yaml"
            target_prefix="ome"
            ;;
        *)
            pko_saas="saas-${operator}-pko.yaml"
            olm_saas="saas-${operator}.yaml"
            target_prefix=$(echo "$operator" | sed 's/-operator$//' | cut -c1-4)
            ;;
    esac

    # For integration, always PKO
    if [ "$ocm_env" = "integration" ]; then
        echo "${target_prefix}-pko-integration|$pko_saas"
        return 0
    fi

    # Try to find a matching target in the PKO SAAS file first
    if [ -n "$SAAS_REFS_SCRIPT" ] && [ -f "$SAAS_REFS_SCRIPT" ]; then
        local pko_refs
        pko_refs=$(bash "$SAAS_REFS_SCRIPT" "$pko_saas" 2>/dev/null)
        if [ -n "$pko_refs" ]; then
            local simplified
            simplified=$(echo "$hive_cluster" | sed 's/^hive-//')
            local pko_target="${target_prefix}-pko-${simplified}"
            if echo "$pko_refs" | grep -q "^${pko_target}"; then
                echo "${pko_target}|${pko_saas}"
                return 0
            fi
            if echo "$pko_refs" | grep -q "^${target_prefix}-${hive_cluster}"; then
                echo "${target_prefix}-${hive_cluster}|${pko_saas}"
                return 0
            fi
        fi
    fi

    # Fall back to OLM SAAS file
    echo "${target_prefix}-${hive_cluster}|${olm_saas}"
    return 0
}

# Environment-aware SAAS file default (refined after hive cluster discovery)
case "$OCM_ENV" in
    integration)
        DEFAULT_SAAS_FILE="saas-${OPERATOR_NAME}-pko.yaml"
        ;;
    *)
        DEFAULT_SAAS_FILE="saas-${OPERATOR_NAME}.yaml"
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

# Package name for ClusterPackage/Subscription queries (operator name, not deployment name)
PACKAGE_NAME="$OPERATOR_NAME"

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

# Collect cluster metadata from OCM for display in report
# This provides context about the cluster configuration
collect_cluster_metadata() {
    local cluster_id="$1"

    if [ "$cluster_id" = "unknown" ] || [ -z "$cluster_id" ]; then
        echo "{}"
        return
    fi

    local cluster_data
    cluster_data=$(ocm get cluster "$cluster_id" 2>/dev/null)

    if [ -z "$cluster_data" ]; then
        echo "{}"
        return
    fi

    # Query provision_shard separately (not in main cluster object)
    local provision_shard
    provision_shard=$(ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/provision_shard" 2>/dev/null)
    local shard_url
    shard_url=$(echo "$provision_shard" | jq -r '.hive_config.server // "unknown"' 2>/dev/null || echo "unknown")

    # Query limited support reasons if cluster is in limited support
    local limited_support_count
    limited_support_count=$(echo "$cluster_data" | jq -r '.status.limited_support_reason_count // 0')
    local limited_support_reasons="[]"
    if [ "$limited_support_count" -gt 0 ]; then
        limited_support_reasons=$(ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/limited_support_reasons" 2>/dev/null | jq '[.items[] | {summary: .summary, details: .details, created: .creation_timestamp}]' 2>/dev/null || echo "[]")
    fi

    # Use jq to extract and format all fields in one pass (avoids newlines in output)
    echo "$cluster_data" | jq --arg shard "$shard_url" --argjson reasons "$limited_support_reasons" '{
      "id": (.id // "unknown"),
      "external_id": (.external_id // "unknown"),
      "name": (.name // "unknown"),
      "state": (.state // "unknown"),
      "api_listening": (.api.listening // "unknown"),
      "product": (.product.id // "unknown"),
      "provider": (.cloud_provider.id // "unknown"),
      "version": (.openshift_version // "unknown"),
      "region": (.region.id // "unknown"),
      "multi_az": (.multi_az // false),
      "cni_type": (.network.type // "unknown"),
      "privatelink": (.aws.private_link // false),
      "sts": (.aws.sts.enabled // false),
      "ccs": (.ccs.enabled // false),
      "hypershift": (.hypershift.enabled // false),
      "existing_vpc": ((.aws.subnet_ids | length > 0) // false),
      "channel_group": (.version.channel_group // "unknown"),
      "shard": $shard,
      "limited_support": ((.status.limited_support_reason_count > 0) // false),
      "limited_support_reasons": $reasons
    }'
}

CLUSTER_METADATA=$(collect_cluster_metadata "$CLUSTER_ID")

# Determine hive cluster name — either from --target-name or by querying OCM
if [ -n "$TARGET_NAME" ]; then
    # --target-name was explicitly provided (from multi-cluster script)
    # Treat it as the raw hive cluster name
    HIVE_SHARD="$TARGET_NAME"
elif [ "$CLUSTER_ID" != "unknown" ]; then
    # Discover hive cluster from OCM provision shard
    HIVE_SHARD=$(discover_hive_target "$CLUSTER_ID" "$OCM_ENV")
    debug_log "Dynamically discovered hive cluster: $HIVE_SHARD"
else
    HIVE_SHARD="unknown"
fi

# Resolve the correct SAAS target name and file (PKO first, OLM fallback)
resolved=$(resolve_saas_target "$HIVE_SHARD" "$OCM_ENV")
TARGET_NAME=$(echo "$resolved" | cut -d'|' -f1)
resolved_saas_file=$(echo "$resolved" | cut -d'|' -f2)
if [ -n "$resolved_saas_file" ]; then
    SAAS_FILE="$resolved_saas_file"
fi
debug_log "Resolved target: $TARGET_NAME (saas: $SAAS_FILE, hive: $HIVE_SHARD)"

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
operator_image=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>"$deployment_fetch_error")
deployment_fetch_exit_code=$?

if [ $deployment_fetch_exit_code -ne 0 ] || [ -z "$operator_image" ]; then
    echo "  ⚠ Deployment fetch failed (backplane creds may not have synced)"
    # Try ClusterPackage as fallback (cluster-scoped, doesn't require namespace RBAC)
    operator_image=$(oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.spec.config.image}' 2>/dev/null)
    if [ -n "$operator_image" ]; then
        echo "  ✓ Recovered image from ClusterPackage: $operator_image"
    else
        # Last resort: try with elevation
        operator_image=$(ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>>"$deployment_fetch_error" | \
            jq -r '.spec.template.spec.containers[0].image // ""' 2>/dev/null)
    fi
fi

if [ -z "$operator_image" ]; then
    deployment_fetch_error_msg=$(cat "$deployment_fetch_error" 2>/dev/null | head -20)
    if [ -n "$deployment_fetch_error_msg" ]; then
        log_api_error "Get deployment $NAMESPACE/$DEPLOYMENT" "$deployment_fetch_error_msg" $deployment_fetch_exit_code
    fi
    operator_image=""
fi
rm -f "$deployment_fetch_error"

# Check for ClusterServiceVersion (CSV) which may have authoritative version info
csv_version=""
csv_git_commit=""
csv_fetch_error=$(mktemp)
csv_data=$(oc get csv -n "$NAMESPACE" -o json 2>"$csv_fetch_error" | \
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

# Try ClusterPackage spec.config.version (authoritative for PKO-deployed operators)
if [ "$operator_version" = "unknown" ]; then
    pkg_version=$(oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.spec.config.version}' 2>/dev/null)
    pkg_image=$(oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.spec.config.image}' 2>/dev/null)
    if [ -n "$pkg_version" ] && [ "$pkg_version" != "null" ]; then
        operator_version="$pkg_version"
        git_commit="${pkg_version:0:12}"
        echo "  Found version from ClusterPackage: $operator_version"
        if [ -n "$pkg_image" ] && ([ -z "$operator_image" ] || [ "$operator_image" = "unknown" ]); then
            operator_image="$pkg_image"
            echo "  Using ClusterPackage image: $operator_image"
        fi
    fi
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
        deployment_annotations=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>/dev/null | \
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

# Diagnostic info when version is unknown
if [ "$operator_version" = "unknown" ]; then
    echo ""
    echo "  ⚠ Version detection failed. Diagnostics:"
    if [ -z "$operator_image" ] || [ "$operator_image" = "unknown" ]; then
        echo "    - Deployment image: not found (deployment fetch may have failed)"
    elif [[ "$operator_image" == *"@sha256:"* ]]; then
        echo "    - Image uses SHA digest (no tag): ${operator_image##*@}"
    else
        echo "    - Image tag did not match expected patterns: ${operator_image##*:}"
    fi
    [ -z "$csv_version" ] && echo "    - No CSV version found (PKO-only or CSV missing)"
    [ -z "$git_commit" ] && echo "    - No git commit found in image labels or annotations"
    if ! command -v skopeo &> /dev/null; then
        echo "    - skopeo not available (needed for image label inspection)"
    fi

    # Retry: try extracting version from ClusterPackage image if available
    if [ "$operator_version" = "unknown" ]; then
        pkg_image=$(oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null | grep -oE '[a-f0-9]{7,12}' | head -1)
        if [ -z "$pkg_image" ]; then
            # Try getting image directly from the running pod
            pod_image=$(oc get pods -n "$NAMESPACE" -l "${pod_selector:-name=$DEPLOYMENT}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
            if [ -n "$pod_image" ] && [ "$pod_image" != "$operator_image" ]; then
                echo "    - Retrying with pod image: $pod_image"
                if [[ "$pod_image" =~ :v([0-9]+\.[0-9]+\.[0-9]+(-g[a-f0-9]+)?) ]]; then
                    operator_version="${BASH_REMATCH[1]}"
                    [[ "$operator_version" =~ -g([a-f0-9]+) ]] && git_commit="${BASH_REMATCH[1]}"
                    echo "    ✓ Recovered version from pod image: $operator_version"
                elif [[ "$pod_image" =~ :([a-f0-9]{7,40})$ ]]; then
                    git_commit="${BASH_REMATCH[1]:0:12}"
                    operator_version="$git_commit"
                    echo "    ✓ Recovered version from pod image tag: $operator_version"
                fi
            fi
        fi
    fi
fi
echo ""

# Detect cluster type from cluster name
case "$CLUSTER_NAME" in
    hs-mc-*) cluster_type="management_cluster" ;;
    hs-sc-*) cluster_type="service_cluster" ;;
    *)       cluster_type="standard" ;;
esac

# Initialize health data structure
declare -A health_data
health_data["cluster_id"]="$CLUSTER_ID"
health_data["cluster_name"]="$CLUSTER_NAME"
health_data["cluster_type"]="$cluster_type"
health_data["hive_shard"]="$HIVE_SHARD"
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
# 0. NAMESPACE STATUS CHECK
#=============================================================================
echo "================================================================================"
echo "CHECK 0: Namespace Status"
echo "================================================================================"

namespace_check_status="PASS"
namespace_message=""
namespace_phase=$(oc get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
namespace_exit=$?

if [ $namespace_exit -ne 0 ] || [ -z "$namespace_phase" ]; then
    namespace_check_status="FAIL"
    namespace_message="Namespace $NAMESPACE does not exist"
    critical_count=$((critical_count + 1))
    echo "  ✗ CRITICAL: Namespace $NAMESPACE not found"
elif [ "$namespace_phase" = "Terminating" ]; then
    namespace_check_status="FAIL"
    namespace_message="Namespace $NAMESPACE is Terminating"
    critical_count=$((critical_count + 1))
    echo "  ✗ CRITICAL: Namespace $NAMESPACE is Terminating"
else
    namespace_message="Namespace $NAMESPACE is $namespace_phase"
    echo "  ✓ Namespace $NAMESPACE is $namespace_phase"
fi

health_checks+=("$(cat <<EOF
{
  "check": "namespace_status",
  "status": "$namespace_check_status",
  "severity": "critical",
  "message": "$namespace_message",
  "details": {
    "namespace": "$NAMESPACE",
    "phase": "${namespace_phase:-not_found}"
  }
}
EOF
)")

# Skip remaining checks if namespace is missing or terminating
if [ "$namespace_check_status" = "FAIL" ]; then
    echo ""
    echo "⚠ Skipping remaining checks — namespace unavailable"
    overall_status="CRITICAL"

    # Jump to output section
    health_data["operator_version"]="unknown"
    health_data["operator_image"]=""
fi

echo ""

if [ "$namespace_check_status" != "FAIL" ]; then
# Begin namespace-dependent checks (closed at end of script before output)

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
elif [ -n "$SAAS_REFS_SCRIPT" ] && [ -f "$SAAS_REFS_SCRIPT" ]; then
    echo "Fetching expected version from app-interface..."
    echo "  Note: This uses an optional external script for version lookup"
    echo "  Alternative: Set EXPECTED_VERSION environment variable"

    # Run the script and capture output
    saas_refs=$(bash "$SAAS_REFS_SCRIPT" "$SAAS_FILE" 2>/dev/null)

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
                    github_repo_url=$(curl -s "https://gitlab.cee.redhat.com/service/app-interface/-/raw/master/data/services/osd-operators/cicd/saas/${SAAS_FILE}?ref_type=heads" 2>/dev/null | yq -r ".resourceTemplates[] | select(.name | test(\"${OPERATOR_NAME}\")) | .url" 2>/dev/null)

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

    # Extract image SHA from current operator image
    current_image_sha=""
    current_image_sha_short=""
    if [[ "$operator_image" == *"@sha256:"* ]]; then
        # Image already uses SHA reference - extract it directly
        current_image_sha=$(echo "$operator_image" | grep -oE 'sha256:[a-f0-9]{64}' | head -1)
        current_image_sha_short=$(echo "$current_image_sha" | cut -c8-19)  # First 12 chars of SHA
    elif [ -n "$operator_image" ] && [ "$SKOPEO_AVAILABLE" = true ]; then
        # Image uses tag reference - resolve to SHA via registry (with caching)
        if [ -n "${image_sha_cache[$operator_image]:-}" ]; then
            # Use cached SHA
            current_image_sha="${image_sha_cache[$operator_image]}"
            current_image_sha_short=$(echo "$current_image_sha" | cut -c8-19)
        else
            # Query registry and cache result
            echo "  Resolving tag to SHA: $operator_image"
            resolved_sha=$(skopeo inspect --no-tags "docker://${operator_image}" 2>/dev/null | jq -r '.Digest // empty' 2>/dev/null)
            if [ -n "$resolved_sha" ] && [ "$resolved_sha" != "null" ]; then
                image_sha_cache[$operator_image]="$resolved_sha"
                current_image_sha="$resolved_sha"
                current_image_sha_short=$(echo "$current_image_sha" | cut -c8-19)
            fi
        fi
    elif [ -n "$operator_image" ] && [ "$SKOPEO_AVAILABLE" = false ] && [ "$SKOPEO_WARNING_SHOWN" = false ]; then
        # Warn once that skopeo is not available for SHA resolution
        echo "Warning: skopeo not installed - cannot resolve image tags to SHAs" >&2
        SKOPEO_WARNING_SHOWN=true
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
deployment_json=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>"$deployment_status_error")
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

# Determine the primary container name from the deployment spec
container_name=$(echo "$deployment_json" | jq -r '.spec.template.spec.containers[0].name // empty' 2>/dev/null)
container_name="${container_name:-$DEPLOYMENT}"

echo "Deployment: $NAMESPACE/$DEPLOYMENT (container: $container_name)"
echo "Deployment replicas: $ready_replicas/$desired_replicas ready"

# Get pod list using deployment's matchLabels selector
pods_fetch_error=$(mktemp)
pod_selector=$(echo "$deployment_json" | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null)
if [ -z "$pod_selector" ] || [ "$pod_selector" = "null" ]; then
    pod_selector="name=$DEPLOYMENT"
fi
echo "  Pod selector: $pod_selector"
pods_json=$(oc get pods -n "$NAMESPACE" -l "$pod_selector" -o json 2>"$pods_fetch_error")
pods_fetch_exit_code=$?

if [ $pods_fetch_exit_code -ne 0 ]; then
    pods_fetch_error_msg=$(cat "$pods_fetch_error" 2>/dev/null | head -20)
    if [ -n "$pods_fetch_error_msg" ]; then
        log_api_error "Get pods in $NAMESPACE with label $pod_selector" "$pods_fetch_error_msg" $pods_fetch_exit_code
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

        echo "  Pod: $NAMESPACE/$pod_name"
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

# Check for OOMKilled termination reason
last_termination_reason=""
if [ "$pod_count" -gt 0 ]; then
    last_termination_reason=$(echo "$pods_json" | jq -r '.items[0].status.containerStatuses[0].lastState.terminated.reason // empty' 2>/dev/null)
    if [ "$last_termination_reason" = "OOMKilled" ]; then
        echo "  ⚠ Last termination reason: OOMKilled — operator may need higher memory limits"
    elif [ -n "$last_termination_reason" ]; then
        echo "  ℹ Last termination reason: $last_termination_reason"
    fi
fi

# Evaluate restart status
if [ "$max_restart_count" -gt 10 ]; then
    restart_check_status="FAIL"
    restart_message="$NAMESPACE/$DEPLOYMENT: excessive restarts ($max_restart_count)"
    critical_count=$((critical_count + 1))
    echo "  ✗ CRITICAL: $NAMESPACE/$DEPLOYMENT has $max_restart_count restarts"
elif [ "$max_restart_count" -gt 5 ]; then
    restart_check_status="WARNING"
    restart_message="$NAMESPACE/$DEPLOYMENT: elevated restarts ($max_restart_count)"
    warning_count=$((warning_count + 1))
    echo "  ⚠ WARNING: $NAMESPACE/$DEPLOYMENT has $max_restart_count restarts"
else
    restart_check_status="PASS"
    restart_message="$NAMESPACE/$DEPLOYMENT pod healthy ($max_restart_count restarts)"
    echo "  ✓ $NAMESPACE/$DEPLOYMENT pod healthy ($max_restart_count restarts)"
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

# Flag OOMKilled as warning if not already critical/warning from restarts
if [ "$last_termination_reason" = "OOMKilled" ] && [ "$restart_check_status" = "PASS" ]; then
    restart_check_status="WARNING"
    restart_message="Last pod termination was OOMKilled — may need higher memory limits"
    warning_count=$((warning_count + 1))
elif [ "$last_termination_reason" = "OOMKilled" ]; then
    restart_message="${restart_message}; Last termination: OOMKilled"
fi

# Check pod age vs deployment age — recent crash detection
pod_age_seconds=0
deployment_age_seconds=0
recent_crash=false
if [ "$pod_count" -gt 0 ]; then
    current_ts=$(date +%s)
    pod_created=$(echo "$pods_json" | jq -r '.items[0].status.startTime // empty' 2>/dev/null)
    deploy_created=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)

    if [ -n "$pod_created" ]; then
        pod_epoch=$(parse_timestamp "$pod_created")
        [ "$pod_epoch" -eq 0 ] && pod_epoch=$current_ts
        pod_age_seconds=$((current_ts - pod_epoch))
    fi
    if [ -n "$deploy_created" ]; then
        deploy_epoch=$(parse_timestamp "$deploy_created")
        [ "$deploy_epoch" -eq 0 ] && deploy_epoch=$current_ts
        deployment_age_seconds=$((current_ts - deploy_epoch))
    fi

    if [ "$pod_age_seconds" -lt 3600 ] && [ "$max_restart_count" -gt 0 ]; then
        recent_crash=true
        if [ "$restart_check_status" = "PASS" ]; then
            restart_check_status="WARNING"
            warning_count=$((warning_count + 1))
        fi
        restart_message="${restart_message}; Pod restarted recently (age: $((pod_age_seconds / 60))m, restarts: $max_restart_count)"
        echo "  ⚠ Pod is less than 1 hour old with restarts — recent crash likely"
    fi
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
    "pods_not_running": $pods_not_running,
    "last_termination_reason": "$(echo "$last_termination_reason" | sed 's/"/\\"/g')",
    "pod_age_seconds": $pod_age_seconds,
    "deployment_age_seconds": $deployment_age_seconds,
    "recent_crash": $recent_crash
  }
}
EOF
)")

echo ""

#=============================================================================
# 2b. LEADER ELECTION LEASE CHECK
#=============================================================================
echo "================================================================================"
echo "CHECK 2b: Leader Election"
echo "================================================================================"

lease_check_status="PASS"
lease_message=""
lease_holder=""
lease_renew_time=""
lease_duration=""

# Leader election check — skip for single-replica operators that don't enable it
lease_name="${DEPLOYMENT}-lock"
if [[ "$OPERATOR_NAME" == *"route-monitor"* ]]; then
    lease_name="2793210b.openshift.io"
fi

# Check if this is a single-replica deployment (leader election not needed)
if [ "${desired_replicas:-1}" -le 1 ]; then
    lease_check_status="SKIP"
    lease_message="Single-replica deployment — leader election not required"
    echo "  ℹ Leader election: skip (single replica)"
fi

if [ "$lease_check_status" != "SKIP" ]; then
lease_json=$(oc get lease -n "$NAMESPACE" "$lease_name" -o json 2>/dev/null)

if [ -n "$lease_json" ] && echo "$lease_json" | jq -e '.metadata.name' >/dev/null 2>&1; then
    lease_holder=$(echo "$lease_json" | jq -r '.spec.holderIdentity // empty' 2>/dev/null)
    lease_renew_time=$(echo "$lease_json" | jq -r '.spec.renewTime // empty' 2>/dev/null)
    lease_duration=$(echo "$lease_json" | jq -r '.spec.leaseDurationSeconds // "15"' 2>/dev/null)

    echo "  Lease holder: ${lease_holder:-none}"
    echo "  Renew time: ${lease_renew_time:-unknown}"
    echo "  Duration: ${lease_duration}s"

    if [ -z "$lease_holder" ]; then
        lease_check_status="WARNING"
        lease_message="Lease exists but has no holder — operator may not be leading"
        warning_count=$((warning_count + 1))
        echo "  ⚠ No lease holder"
    else
        # Check if holder matches a running pod
        holder_pod=$(echo "$lease_holder" | cut -d'_' -f1)
        pod_exists=$(echo "$pods_json" | jq -r --arg pod "$holder_pod" '[.items[] | select(.metadata.name == $pod)] | length' 2>/dev/null)

        if [ "${pod_exists:-0}" -eq 0 ]; then
            # Check if lease is old (>24h) — likely a remnant from when leader election was enabled
            renew_check_epoch=$(parse_timestamp "$lease_renew_time")
            current_check_ts=$(date +%s)
            lease_age_seconds=$(( current_check_ts - renew_check_epoch ))
            if [ "$renew_check_epoch" -gt 0 ] && [ "$lease_age_seconds" -gt 86400 ]; then
                lease_check_status="INFO"
                lease_message="Stale lease from previous deployment (last renewed $(( lease_age_seconds / 86400 ))d ago) — likely leader election disabled"
                echo "  ℹ Stale lease ($(( lease_age_seconds / 86400 ))d old) — remnant from previous deployment"
            else
                lease_check_status="WARNING"
                lease_message="Lease holder ($holder_pod) does not match any running pod"
                warning_count=$((warning_count + 1))
                echo "  ⚠ Lease holder does not match a running pod"
            fi
        elif [ -n "$lease_renew_time" ]; then
            # Check if renew time is recent (within 2x lease duration)
            renew_epoch=$(parse_timestamp "$lease_renew_time")
            current_ts_lease=$(date +%s)
            stale_threshold=$((lease_duration * 2))
            time_since_renew=$((current_ts_lease - renew_epoch))

            if [ "$renew_epoch" -gt 0 ] && [ "$time_since_renew" -gt "$stale_threshold" ]; then
                lease_check_status="WARNING"
                lease_message="Lease not renewed in ${time_since_renew}s (threshold: ${stale_threshold}s)"
                warning_count=$((warning_count + 1))
                echo "  ⚠ Lease appears stale (last renewed ${time_since_renew}s ago)"
            else
                lease_message="Lease healthy — held by $holder_pod, recently renewed"
                echo "  ✓ Lease healthy"
            fi
        else
            lease_message="Lease held by $holder_pod"
            echo "  ✓ Lease held"
        fi
    fi
else
    lease_check_status="INFO"
    lease_message="No lease found for $lease_name (single-replica, leader election not required)"
    echo "  ℹ No lease for $lease_name (single-replica deployment)"
fi
fi  # end of lease_check_status != SKIP

health_checks+=("$(cat <<EOF
{
  "check": "leader_election",
  "status": "$lease_check_status",
  "severity": "$([ "$lease_check_status" = "WARNING" ] && echo "warning" || echo "info")",
  "message": "$lease_message",
  "details": {
    "lease_name": "$lease_name",
    "holder_identity": "$(echo "$lease_holder" | sed 's/"/\\"/g')",
    "renew_time": "$lease_renew_time",
    "lease_duration_seconds": ${lease_duration:-15}
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
peak_memory_bytes=0
peak_memory_mb="0.00"
peak_cpu_cores=0
peak_cpu_millicores="0"
last_memory="0"
last_cpu="0"
first_memory="0"
first_cpu="0"

# Get pod start time to determine how long to look back
if [ "$pod_count" -gt 0 ]; then
    pod_name=$(echo "$pods_json" | jq -r '.items[0].metadata.name' 2>/dev/null)
    pod_start_time=$(echo "$pods_json" | jq -r '.items[0].status.startTime // empty' 2>/dev/null)

    if [ -n "$pod_name" ] && [ "$pod_name" != "null" ]; then
        echo "Analyzing resource trends for pod: $pod_name"

        # Calculate time range based on pod age (or max 24 hours)
        current_time=$(date +%s)

        if [ -n "$pod_start_time" ]; then
            pod_start_epoch=$(parse_timestamp "$pod_start_time")
            [ "$pod_start_epoch" -eq 0 ] && pod_start_epoch=$((current_time - 21600))
            pod_age_seconds=$((current_time - pod_start_epoch))
        fi

        # Always look back 7 days (Thanos retention) since pod regex captures
        # data across all pod incarnations, not just the current pod
        lookback_seconds=604800
        # Check if deployment is younger than 7 days — use deployment age if shorter
        if [ -n "${deploy_created:-}" ]; then
            deploy_age_seconds=$((current_time - $(parse_timestamp "$deploy_created")))
            if [ "$deploy_age_seconds" -gt 0 ] && [ "$deploy_age_seconds" -lt 604800 ]; then
                lookback_seconds=$deploy_age_seconds
            fi
        fi
        # Minimum 1 hour lookback
        [ $lookback_seconds -lt 3600 ] && lookback_seconds=3600

        lookback_hours=$(awk "BEGIN {printf \"%.1f\", $lookback_seconds / 3600}")
        echo "  Pod age: $(awk "BEGIN {printf \"%.1f\", $pod_age_seconds / 3600}")h, lookback: ${lookback_hours}h"

        start_time=$((current_time - lookback_seconds))
        end_time=$current_time

        # Scale query step to keep ~200-300 data points regardless of lookback
        # <6h: 60s (360 pts), <24h: 300s (288 pts), <72h: 900s (288 pts), 7d: 1800s (336 pts)
        if [ $lookback_seconds -lt 21600 ]; then
            query_step=60
        elif [ $lookback_seconds -lt 86400 ]; then
            query_step=300
        elif [ $lookback_seconds -lt 259200 ]; then
            query_step=900
        else
            query_step=1800
        fi

        # Query Thanos via port-forward or service
        # Try to use thanos-querier service
        thanos_url="http://thanos-querier.openshift-monitoring.svc:9091"

        echo "  Querying Prometheus/Thanos for metrics..."

        # Use pod regex to capture data across pod restarts/redeployments
        pod_query_selector="pod=~\"${DEPLOYMENT}-.*\""
        query_errors=""

        # Memory query
        memory_query="container_memory_working_set_bytes{namespace=\"$NAMESPACE\",${pod_query_selector},container=\"$container_name\"}"
        memory_query_encoded=$(printf '%s' "$memory_query" | jq -sRr @uri)

        memory_err=$(mktemp)
        memory_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
            wget -q -T 30 -O- "http://localhost:9090/api/v1/query_range?query=${memory_query_encoded}&start=${start_time}&end=${end_time}&step=${query_step}" 2>"$memory_err")
        if [ $? -ne 0 ]; then
            mem_err_msg=$(cat "$memory_err" 2>/dev/null | head -1)
            query_errors="${query_errors}memory query failed${mem_err_msg:+ ($mem_err_msg)}, "
            echo "  ⚠ Memory query failed: ${mem_err_msg:-timeout or connection error}"
        fi
        rm -f "$memory_err"

        # CPU query (rate over 5m)
        cpu_query="rate(container_cpu_usage_seconds_total{namespace=\"$NAMESPACE\",${pod_query_selector},container=\"$container_name\"}[5m])"
        cpu_query_encoded=$(printf '%s' "$cpu_query" | jq -sRr @uri)

        cpu_err=$(mktemp)
        cpu_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
            wget -q -T 30 -O- "http://localhost:9090/api/v1/query_range?query=${cpu_query_encoded}&start=${start_time}&end=${end_time}&step=${query_step}" 2>"$cpu_err")
        if [ $? -ne 0 ]; then
            cpu_err_msg=$(cat "$cpu_err" 2>/dev/null | head -1)
            query_errors="${query_errors}CPU query failed${cpu_err_msg:+ ($cpu_err_msg)}, "
            echo "  ⚠ CPU query failed: ${cpu_err_msg:-timeout or connection error}"
        fi
        rm -f "$cpu_err"

        # Compute peaks client-side from timeseries data (avoids 2 extra Thanos queries)
        peak_memory_bytes=0
        peak_memory_mb="0.00"
        peak_cpu_cores=0
        peak_cpu_millicores="0"

        # Query probe metrics for RMO (blackbox exporter probes)
        probe_timeseries="[]"
        probe_duration_timeseries="[]"
        probe_target_count=0
        if [[ "$OPERATOR_NAME" == *"route-monitor"* ]]; then
            # Probe success rate over time
            probe_query="avg(probe_success{namespace=~\"openshift-route-monitor-operator|ocm-.*\"})"
            probe_query_encoded=$(printf '%s' "$probe_query" | jq -sRr @uri)
            probe_ts_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
                wget -q -T 30 -O- "http://localhost:9090/api/v1/query_range?query=${probe_query_encoded}&start=${start_time}&end=${end_time}&step=${query_step}" 2>/dev/null)
            if [ -n "$probe_ts_data" ] && echo "$probe_ts_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
                probe_timeseries=$(echo "$probe_ts_data" | jq -c '[.data.result[].values[]] | sort_by(.[0]) | unique_by(.[0])' 2>/dev/null || echo "[]")
                echo "  Probe success: $(echo "$probe_timeseries" | jq 'length' 2>/dev/null || echo 0) data points"
            fi

            # Probe duration (avg response time) over time
            duration_query="avg(probe_duration_seconds{namespace=~\"openshift-route-monitor-operator|ocm-.*\"})"
            duration_query_encoded=$(printf '%s' "$duration_query" | jq -sRr @uri)
            duration_ts_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
                wget -q -T 30 -O- "http://localhost:9090/api/v1/query_range?query=${duration_query_encoded}&start=${start_time}&end=${end_time}&step=${query_step}" 2>/dev/null)
            if [ -n "$duration_ts_data" ] && echo "$duration_ts_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
                probe_duration_timeseries=$(echo "$duration_ts_data" | jq -c '[.data.result[].values[]] | sort_by(.[0]) | unique_by(.[0])' 2>/dev/null || echo "[]")
                echo "  Probe duration: $(echo "$probe_duration_timeseries" | jq 'length' 2>/dev/null || echo 0) data points"
            fi

            # Count active probe targets
            target_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
                wget -q -T 30 -O- "http://localhost:9090/api/v1/query?query=$(printf 'count(probe_success{namespace=~"openshift-route-monitor-operator|ocm-.*"})' | jq -sRr @uri)" 2>/dev/null)
            if [ -n "$target_data" ] && echo "$target_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
                probe_target_count=$(echo "$target_data" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
                probe_target_count=$(echo "$probe_target_count" | tr -d '[:space:]')
                echo "  Active probe targets: $probe_target_count"
            fi
        fi

        # Process memory data
        memory_timeseries="[]"
        if [ -n "$memory_data" ] && echo "$memory_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
            # Merge all result series into a single timeline (covers pod restarts/redeployments)
            # Sort by timestamp, deduplicate, keep latest value per timestamp
            memory_timeseries=$(echo "$memory_data" | jq -c '[.data.result[].values[]] | sort_by(.[0]) | unique_by(.[0])' 2>/dev/null || echo "[]")

            first_memory=$(echo "$memory_timeseries" | jq -r '.[0][1] // "0"' 2>/dev/null)
            last_memory=$(echo "$memory_timeseries" | jq -r '.[-1][1] // "0"' 2>/dev/null)
            peak_memory_bytes=$(echo "$memory_timeseries" | jq -r '[.[][1] | tonumber] | max // 0' 2>/dev/null || echo "${last_memory:-0}")
            peak_memory_mb=$(awk "BEGIN {printf \"%.2f\", ${peak_memory_bytes:-0} / 1048576}")

            if [ "$first_memory" != "0" ] && [ "$last_memory" != "0" ] && [ "$first_memory" != "null" ] && [ "$last_memory" != "null" ]; then
                # Calculate percentage increase
                memory_increase_percent=$(awk "BEGIN {printf \"%.2f\", (($last_memory - $first_memory) / $first_memory) * 100}")

                # Convert to MB for display
                first_memory_mb=$(awk "BEGIN {printf \"%.2f\", $first_memory / 1048576}")
                last_memory_mb=$(awk "BEGIN {printf \"%.2f\", $last_memory / 1048576}")

                echo "  Memory usage over last ${lookback_hours}h:"
                echo "    Initial: ${first_memory_mb} MB"
                echo "    Current: ${last_memory_mb} MB"
                echo "    Peak:    ${peak_memory_mb} MB"
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
            # Merge all result series into a single timeline
            cpu_timeseries=$(echo "$cpu_data" | jq -c '[.data.result[].values[]] | sort_by(.[0]) | unique_by(.[0])' 2>/dev/null || echo "[]")

            first_cpu=$(echo "$cpu_timeseries" | jq -r '.[0][1] // "0"' 2>/dev/null)
            last_cpu=$(echo "$cpu_timeseries" | jq -r '.[-1][1] // "0"' 2>/dev/null)
            peak_cpu_cores=$(echo "$cpu_timeseries" | jq -r '[.[][1] | tonumber] | max // 0' 2>/dev/null || echo "${last_cpu:-0}")
            peak_cpu_millicores=$(awk "BEGIN {printf \"%.0f\", ${peak_cpu_cores:-0} * 1000}")

            if [ "$first_cpu" != "0" ] && [ "$last_cpu" != "0" ] && [ "$first_cpu" != "null" ] && [ "$last_cpu" != "null" ]; then
                # Calculate percentage increase
                cpu_increase_percent=$(awk "BEGIN {printf \"%.2f\", (($last_cpu - $first_cpu) / $first_cpu) * 100}")

                # Convert to millicores for display
                first_cpu_mc=$(awk "BEGIN {printf \"%.0f\", $first_cpu * 1000}")
                last_cpu_mc=$(awk "BEGIN {printf \"%.0f\", $last_cpu * 1000}")

                echo "  CPU usage over last ${lookback_hours}h:"
                echo "    Initial: ${first_cpu_mc}m"
                echo "    Current: ${last_cpu_mc}m"
                echo "    Peak:    ${peak_cpu_millicores}m"
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
            memory_message="Both CPU and memory increased by >${MEMORY_LEAK_THRESHOLD_PERCENT}% (CPU: ${cpu_increase_percent}%, Mem: ${memory_increase_percent}%) — investigate resource growth"
            warning_count=$((warning_count + 1))
        elif [ "$memory_trend" = "increasing" ]; then
            memory_check_status="WARNING"
            memory_message="Memory increased by ${memory_increase_percent}% over ${lookback_hours}h — possible memory leak"
            warning_count=$((warning_count + 1))
        elif [ "$cpu_trend" = "increasing" ]; then
            memory_check_status="WARNING"
            memory_message="CPU increased by ${cpu_increase_percent}% over ${lookback_hours}h — elevated CPU usage, may indicate increased reconciliation or workload"
            warning_count=$((warning_count + 1))
        elif [ -z "$memory_data" ] && [ -z "$cpu_data" ]; then
            memory_check_status="UNKNOWN"
            memory_message="Unable to query resource metrics from Prometheus${query_errors:+ (${query_errors%, })}"
        else
            memory_check_status="PASS"
            memory_message="$NAMESPACE/$DEPLOYMENT (container: $container_name): CPU and memory usage stable"
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
    "peak_memory_bytes": $peak_memory_bytes,
    "peak_memory_mb": $peak_memory_mb,
    "peak_cpu_cores": $peak_cpu_cores,
    "peak_cpu_millicores": $peak_cpu_millicores,
    "memory_timeseries": $memory_timeseries,
    "cpu_timeseries": $cpu_timeseries,
    "lookback_hours": $lookback_hours,
    "container_name": "$container_name",
    "pod_name": "${pod_name:-unknown}",
    "query_errors": "$(echo "${query_errors%, }" | sed 's/"/\\"/g')",
    "probe_timeseries": $probe_timeseries,
    "probe_duration_timeseries": $probe_duration_timeseries,
    "probe_target_count": ${probe_target_count:-0}
  }
}
EOF
)")

echo ""

#=============================================================================
# 3b. RESOURCE LIMITS VALIDATION
#=============================================================================
echo "================================================================================"
echo "CHECK 3b: Resource Limits Validation"
echo "================================================================================"

limits_check_status="PASS"
limits_message=""
limits_cpu_set=false
limits_memory_set=false
requests_cpu_set=false
requests_memory_set=false
limits_cpu_value=""
limits_memory_value=""
requests_cpu_value=""
requests_memory_value=""
cpu_usage_percent="0"
memory_usage_percent="0"

if [ "$pod_count" -gt 0 ]; then
    resource_json=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null)

    if [ -n "$resource_json" ]; then
        limits_cpu_value=$(echo "$resource_json" | jq -r '.limits.cpu // empty' 2>/dev/null)
        limits_memory_value=$(echo "$resource_json" | jq -r '.limits.memory // empty' 2>/dev/null)
        requests_cpu_value=$(echo "$resource_json" | jq -r '.requests.cpu // empty' 2>/dev/null)
        requests_memory_value=$(echo "$resource_json" | jq -r '.requests.memory // empty' 2>/dev/null)

        [ -n "$limits_cpu_value" ] && limits_cpu_set=true
        [ -n "$limits_memory_value" ] && limits_memory_set=true
        [ -n "$requests_cpu_value" ] && requests_cpu_set=true
        [ -n "$requests_memory_value" ] && requests_memory_set=true

        echo "  Limits CPU: ${limits_cpu_value:-not set}"
        echo "  Limits Memory: ${limits_memory_value:-not set}"
        echo "  Requests CPU: ${requests_cpu_value:-not set}"
        echo "  Requests Memory: ${requests_memory_value:-not set}"

        # Compare current usage against memory limit if both are available
        if [ "$limits_memory_set" = true ] && [ "$last_memory" != "0" ] && [ "$last_memory" != "null" ] && [ -n "$last_memory" ]; then
            # Convert memory limit to bytes (handles Mi, Gi suffixes)
            limits_memory_bytes=$(echo "$limits_memory_value" | awk '{
                val=$1;
                if (match(val, /[0-9]+Gi/)) { gsub(/Gi/,"",val); printf "%.0f", val*1073741824 }
                else if (match(val, /[0-9]+Mi/)) { gsub(/Mi/,"",val); printf "%.0f", val*1048576 }
                else if (match(val, /[0-9]+Ki/)) { gsub(/Ki/,"",val); printf "%.0f", val*1024 }
                else { printf "%.0f", val }
            }')
            if [ "$limits_memory_bytes" -gt 0 ] 2>/dev/null; then
                memory_usage_percent=$(awk "BEGIN {printf \"%.1f\", ($last_memory / $limits_memory_bytes) * 100}")
                echo "  Memory usage: ${memory_usage_percent}% of limit"
            fi
        fi

        # Compare current usage against CPU limit if both are available
        if [ "$limits_cpu_set" = true ] && [ "$last_cpu" != "0" ] && [ "$last_cpu" != "null" ] && [ -n "$last_cpu" ]; then
            # Convert CPU limit to cores (handles m suffix)
            limits_cpu_cores=$(echo "$limits_cpu_value" | awk '{
                val=$1;
                if (match(val, /[0-9]+m/)) { gsub(/m/,"",val); printf "%.4f", val/1000 }
                else { printf "%.4f", val }
            }')
            if (( $(echo "$limits_cpu_cores > 0" | bc -l 2>/dev/null) )); then
                cpu_usage_percent=$(awk "BEGIN {printf \"%.1f\", ($last_cpu / $limits_cpu_cores) * 100}")
                echo "  CPU usage: ${cpu_usage_percent}% of limit"
            fi
        fi

        # Evaluate
        missing_fields=""
        [ "$limits_cpu_set" = false ] && missing_fields="${missing_fields}limits.cpu, "
        [ "$limits_memory_set" = false ] && missing_fields="${missing_fields}limits.memory, "
        [ "$requests_cpu_set" = false ] && missing_fields="${missing_fields}requests.cpu, "
        [ "$requests_memory_set" = false ] && missing_fields="${missing_fields}requests.memory, "

        if [ -n "$missing_fields" ]; then
            missing_fields="${missing_fields%, }"
            # Missing requests is expected when limits are set (Kubernetes defaults requests=limits)
            if [ "$limits_cpu_set" = true ] && [ "$limits_memory_set" = true ]; then
                limits_check_status="PASS"
                limits_message="$NAMESPACE/$DEPLOYMENT: limits set (${limits_cpu_value} CPU, ${limits_memory_value} mem), requests default to limits"
                echo "  ✓ Limits set, requests default to limits"
            else
                limits_check_status="INFO"
                limits_message="$NAMESPACE/$DEPLOYMENT: missing resource fields: ${missing_fields}"
                echo "  ℹ Missing: ${missing_fields}"
            fi
        fi

        if (( $(echo "${memory_usage_percent} > 80" | bc -l 2>/dev/null) )); then
            limits_check_status="WARNING"
            limits_message="Memory usage at ${memory_usage_percent}% of limit (${limits_memory_value})"
            warning_count=$((warning_count + 1))
            echo "  ⚠ Memory usage above 80% of limit"
        elif (( $(echo "${cpu_usage_percent} > 80" | bc -l 2>/dev/null) )); then
            limits_check_status="WARNING"
            limits_message="CPU usage at ${cpu_usage_percent}% of limit (${limits_cpu_value})"
            warning_count=$((warning_count + 1))
            echo "  ⚠ CPU usage above 80% of limit"
        elif [ "$limits_check_status" = "PASS" ]; then
            limits_message="$NAMESPACE/$DEPLOYMENT: all resource limits and requests set, usage within bounds"
            echo "  ✓ $NAMESPACE/$DEPLOYMENT: resource limits healthy"
        fi
    else
        limits_check_status="INFO"
        limits_message="No resource configuration found on deployment"
        echo "  ℹ No resource limits or requests configured"
    fi
else
    limits_check_status="UNKNOWN"
    limits_message="No pods found"
fi

health_checks+=("$(cat <<EOF
{
  "check": "resource_limits_validation",
  "status": "$limits_check_status",
  "severity": "$([ "$limits_check_status" = "WARNING" ] && echo "warning" || echo "info")",
  "message": "$limits_message",
  "details": {
    "limits_cpu": "$([ "$limits_cpu_set" = true ] && echo "$limits_cpu_value" || echo "not set")",
    "limits_memory": "$([ "$limits_memory_set" = true ] && echo "$limits_memory_value" || echo "not set")",
    "requests_cpu": "$([ "$requests_cpu_set" = true ] && echo "$requests_cpu_value" || echo "not set")",
    "requests_memory": "$([ "$requests_memory_set" = true ] && echo "$requests_memory_value" || echo "not set")",
    "cpu_usage_percent": $cpu_usage_percent,
    "memory_usage_percent": $memory_usage_percent
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
        logs=$(oc logs -n "$NAMESPACE" "$pod_name" --tail=500 2>/dev/null || echo "")

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
                log_message="$NAMESPACE/${pod_name:-$DEPLOYMENT}: 0 errors, 0 warnings"
                echo "  ✓ $NAMESPACE/${pod_name:-$DEPLOYMENT}: 0 errors, 0 warnings"
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
    recent_logs=$(oc logs -n "$NAMESPACE" "deployment/$DEPLOYMENT" --since=5m --tail=10 2>/dev/null | wc -l | tr -d ' ')

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
            wget -q -T 30 -O- "http://localhost:9090/api/v1/query?query=${query_encoded}" 2>/dev/null)

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
            reconciliation_behavior_status="PASS"
            reconciliation_behavior_message="Normal idle reconciliation (${recent_logs} periodic reconciliations, 0 resource changes in 5m)"
            echo "  ✓ Normal idle reconciliation (${recent_logs} periodic, 0 changes)"
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

    # Check 8: AlertManager Log Analysis (with smart DNS warning filtering)
    echo "  Analyzing AlertManager logs..."

    alertmanager_log_errors=0
    alertmanager_log_warnings=0
    alertmanager_dns_warnings_filtered=0
    alertmanager_log_status="PASS"
    alertmanager_log_message="No errors or warnings in AlertManager logs"
    am_error_samples=()
    am_warning_samples=()

    # Get alertmanager pod names
    alertmanager_pod_names=$(echo "$alertmanager_pods" | jq -r '.items[].metadata.name' 2>/dev/null)

    if [ -n "$alertmanager_pod_names" ]; then
        # Determine if ANY AlertManager pod is in startup/restart grace period
        # DNS warnings occur on ALL pods when ANY peer pod is starting/restarting
        # because they're trying to form a cluster and DNS entries aren't ready yet
        cluster_in_grace_period="false"
        youngest_pod_age=999999

        for am_pod in $alertmanager_pod_names; do
            pod_created=$(echo "$alertmanager_pods" | jq -r ".items[] | select(.metadata.name==\"$am_pod\") | .metadata.creationTimestamp" 2>/dev/null)

            if [ -n "$pod_created" ]; then
                created_epoch=$(parse_timestamp "$pod_created")
                current_epoch=$(date -u +%s)
                if [ "$created_epoch" -gt 0 ]; then
                    pod_age_seconds=$((current_epoch - created_epoch))
                    if [ "$pod_age_seconds" -lt "$youngest_pod_age" ]; then
                        youngest_pod_age=$pod_age_seconds
                    fi

                    # If ANY pod is younger than 5 minutes, the whole cluster is in grace period
                    if [ "$pod_age_seconds" -lt 300 ]; then
                        cluster_in_grace_period="true"
                        debug_log "Cluster in grace period: $am_pod is ${pod_age_seconds}s old"
                    fi
                fi
            fi
        done

        debug_log "AlertManager cluster grace period: $cluster_in_grace_period (youngest pod: ${youngest_pod_age}s)"

        # Count errors and warnings in AlertManager logs
        # Scope to logs since the operator pod started to avoid stale entries from long-running AM pods
        # Filter out expected DNS warnings during cluster formation
        for am_pod in $alertmanager_pod_names; do
            if [ -n "${pod_start_time:-}" ]; then
                pod_logs=$(oc logs -n "$NAMESPACE" "$am_pod" --since-time="$pod_start_time" 2>/dev/null)
            else
                pod_logs=$(oc logs -n "$NAMESPACE" "$am_pod" --tail=1000 2>/dev/null)
            fi

            # Count all errors (no filtering)
            pod_errors=$(echo "$pod_logs" | grep -i "level=error" | wc -l | tr -d ' ')
            alertmanager_log_errors=$((alertmanager_log_errors + pod_errors))

            # Count warnings, filtering out DNS lookup failures during cluster formation
            # DNS warnings like "Failed to resolve alertmanager-main-X:9094: no such host"
            # are expected when ANY pod in the cluster is starting/restarting
            pod_all_warnings=$(echo "$pod_logs" | grep -i "level=warn" | wc -l | tr -d ' ')
            pod_dns_warnings=$(echo "$pod_logs" | grep -i "level=warn.*\(no such host\|Failed to resolve.*alertmanager.*:9094\)" | wc -l | tr -d ' ')

            # Always filter AlertManager peer DNS resolution warnings
            # These are transient during any pod startup/restart and self-resolve
            if [ "$pod_dns_warnings" -gt 0 ]; then
                pod_actionable_warnings=$((pod_all_warnings - pod_dns_warnings))
                alertmanager_dns_warnings_filtered=$((alertmanager_dns_warnings_filtered + pod_dns_warnings))
                debug_log "Filtered $pod_dns_warnings DNS warnings from $am_pod"
            else
                pod_actionable_warnings=$pod_all_warnings
            fi

            alertmanager_log_warnings=$((alertmanager_log_warnings + pod_actionable_warnings))

            # Collect sample error messages (first 5 total across all pods)
            if [ "$pod_errors" -gt 0 ] && [ ${#am_error_samples[@]} -lt 5 ]; then
                while IFS= read -r line; do
                    if [ ${#am_error_samples[@]} -lt 5 ]; then
                        am_error_samples+=("[$am_pod] $line")
                    fi
                done < <(echo "$pod_logs" | grep -i "level=error" | head -5)
            fi

            # Collect sample warning messages (first 5 total across all pods, excluding filtered DNS warnings)
            if [ "$pod_actionable_warnings" -gt 0 ] && [ ${#am_warning_samples[@]} -lt 5 ]; then
                # Get warnings excluding DNS lookup failures
                warnings_to_sample=$(echo "$pod_logs" | grep -i "level=warn" | grep -v -i "no such host\|Failed to resolve.*alertmanager.*:9094" | head -5)
                if [ -z "$warnings_to_sample" ]; then
                    # If all warnings were DNS-related, sample those if not in grace period
                    if [ "$cluster_in_grace_period" != "true" ]; then
                        warnings_to_sample=$(echo "$pod_logs" | grep -i "level=warn" | head -5)
                    fi
                fi

                while IFS= read -r line; do
                    if [ ${#am_warning_samples[@]} -lt 5 ] && [ -n "$line" ]; then
                        am_warning_samples+=("[$am_pod] $line")
                    fi
                done <<< "$warnings_to_sample"
            fi
        done

        # Build status message
        if [ "$alertmanager_log_errors" -gt 0 ]; then
            alertmanager_log_status="WARN"
            if [ "$alertmanager_dns_warnings_filtered" -gt 0 ]; then
                alertmanager_log_message="Found $alertmanager_log_errors errors and $alertmanager_log_warnings warnings in AlertManager logs ($alertmanager_dns_warnings_filtered DNS warnings filtered)"
                echo "  ⚠ WARNING: AlertManager has $alertmanager_log_errors errors and $alertmanager_log_warnings warnings in logs (filtered $alertmanager_dns_warnings_filtered DNS warnings)"
            else
                alertmanager_log_message="Found $alertmanager_log_errors errors and $alertmanager_log_warnings warnings in AlertManager logs"
                echo "  ⚠ WARNING: AlertManager has $alertmanager_log_errors errors and $alertmanager_log_warnings warnings in logs"
            fi
            warning_count=$((warning_count + 1))
        elif [ "$alertmanager_log_warnings" -gt 0 ]; then
            alertmanager_log_status="WARN"
            if [ "$alertmanager_dns_warnings_filtered" -gt 0 ]; then
                alertmanager_log_message="Found $alertmanager_log_warnings warnings in AlertManager logs ($alertmanager_dns_warnings_filtered DNS warnings filtered, 0 errors)"
            else
                alertmanager_log_message="Found $alertmanager_log_warnings warnings in AlertManager logs (0 errors)"
            fi
            warning_count=$((warning_count + 1))
            echo "  ⚠ WARNING: AlertManager has $alertmanager_log_warnings warnings in logs (0 errors)"
        elif [ "$alertmanager_dns_warnings_filtered" -gt 0 ]; then
            # All warnings were filtered DNS warnings
            alertmanager_log_status="PASS"
            alertmanager_log_message="AlertManager logs clean (filtered $alertmanager_dns_warnings_filtered expected DNS warnings during startup/restart)"
            echo "  ✓ AlertManager logs clean (filtered $alertmanager_dns_warnings_filtered expected DNS warnings)"
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
    "dns_warnings_filtered": $alertmanager_dns_warnings_filtered,
    "log_scope": "$([ -n "${pod_start_time:-}" ] && echo "since_operator_start" || echo "tail_1000")",
    "log_since": "$([ -n "${pod_start_time:-}" ] && echo "$pod_start_time" || echo "N/A")",
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

    # End of CAMO-specific checks — remaining checks are general (all operators)
fi

# General deployment method checks (OLM/PKO) — applies to all operators

    # Check 11: OLM Subscription and CSV Orphan Detection
    # Always check deployment method health regardless of version match
    echo "  Checking for OLM subscription issues..."

    olm_subscription_status="SKIP"
    olm_subscription_message="No OLM subscription found"
    resolution_failed="false"
    resolution_failed_message=""
    orphaned_csvs=0
    orphaned_csv_names="[]"
    subscription_exists="false"

    # Check if subscription exists (indicates OLM installation vs PKO)
    subscription_check=$(oc get subscription.operators.coreos.com "$PACKAGE_NAME" -n "$NAMESPACE" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$subscription_check" ]; then
        subscription_exists="true"
        echo "  ✓ Subscription exists (OLM installation detected)"

        # Check for ResolutionFailed status
        resolution_failed_status=$(oc get subscription.operators.coreos.com "$PACKAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].status}' 2>/dev/null)

        if [ "$resolution_failed_status" = "True" ]; then
            resolution_failed="true"
            resolution_failed_message=$(oc get subscription.operators.coreos.com "$PACKAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].message}' 2>/dev/null | head -c 500)

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

    # Check 12: PKO (Package Operator) ClusterPackage Health
    # Always check deployment method health regardless of version match
    echo "  Checking for PKO ClusterPackage..."

    pko_package_status="SKIP"
    pko_package_message="No PKO ClusterPackage found"
    cluster_package_exists="false"
    cluster_package_ready="unknown"
    cluster_package_phase="unknown"
    cluster_package_conditions="[]"
    dual_installation="false"
    dual_installation_message=""

    # Check if ClusterPackage exists (indicates PKO installation)
    cluster_package_check=$(oc get clusterpackage "$PACKAGE_NAME" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$cluster_package_check" ]; then
        cluster_package_exists="true"
        echo "  ✓ ClusterPackage exists (PKO installation detected)"

        # Get ClusterPackage status conditions (PKO uses Available/Progressing/Unpacked, not Ready/Phase)
        cluster_package_available=$(oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")
        cluster_package_progressing=$(oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "unknown")
        cluster_package_unpacked=$(oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Unpacked")].status}' 2>/dev/null || echo "unknown")

        # Get all conditions
        cluster_package_conditions=$(oc get clusterpackage "$PACKAGE_NAME" -o json 2>/dev/null | jq -c '.status.conditions // []' 2>/dev/null || echo "[]")

        # Store legacy field names for JSON output compatibility
        cluster_package_ready="$cluster_package_available"  # Map Available to ready for backwards compatibility
        cluster_package_phase="N/A"  # PKO doesn't use phase field

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
            # Healthy state: Available=True, Progressing=False (idle), Unpacked=True
            if [ "$cluster_package_available" = "True" ] && [ "$cluster_package_progressing" = "False" ] && [ "$cluster_package_unpacked" = "True" ]; then
                pko_package_status="PASS"
                pko_package_message="PKO ClusterPackage healthy (Available=True, Progressing=False, Unpacked=True)"
                echo "  ✓ PKO ClusterPackage healthy (Available, not progressing, unpacked)"
            elif [ "$cluster_package_available" = "False" ]; then
                # Get failure reason from Available condition
                failure_reason=$(oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null | head -c 200)
                pko_package_status="FAIL"
                pko_package_message="PKO ClusterPackage not available: $failure_reason"
                critical_count=$((critical_count + 1))
                echo "  ✗ CRITICAL: PKO ClusterPackage not available"
                echo "    Available: $cluster_package_available"
                echo "    Reason: ${failure_reason:0:100}..."
            elif [ "$cluster_package_progressing" = "True" ]; then
                progressing_msg=$(oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null)
                if echo "$progressing_msg" | grep -q "immutable" 2>/dev/null; then
                    pko_package_status="FAIL"
                    pko_package_message="PKO ClusterPackage stuck: spec.template field is immutable"
                    critical_count=$((critical_count + 1))
                    echo "  ✗ CRITICAL: ClusterPackage stuck with immutability error"
                    echo "    Message: ${progressing_msg:0:150}..."
                else
                    pko_package_status="WARN"
                    pko_package_message="PKO ClusterPackage is progressing (update in progress)"
                    warning_count=$((warning_count + 1))
                    echo "  ⚠ WARNING: PKO ClusterPackage update in progress"
                fi
                echo "    Progressing: $cluster_package_progressing"
            elif [ "$cluster_package_unpacked" = "False" ]; then
                # Package not unpacked
                unpack_reason=$(oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Unpacked")].message}' 2>/dev/null | head -c 200)
                pko_package_status="FAIL"
                pko_package_message="PKO ClusterPackage not unpacked: $unpack_reason"
                critical_count=$((critical_count + 1))
                echo "  ✗ CRITICAL: PKO ClusterPackage not unpacked"
                echo "    Unpacked: $cluster_package_unpacked"
                echo "    Reason: ${unpack_reason:0:100}..."
            else
                pko_package_status="WARN"
                pko_package_message="PKO ClusterPackage in unexpected state (Available=$cluster_package_available, Progressing=$cluster_package_progressing, Unpacked=$cluster_package_unpacked)"
                warning_count=$((warning_count + 1))
                echo "  ⚠ WARNING: PKO ClusterPackage state unclear"
                echo "    Available: $cluster_package_available"
                echo "    Progressing: $cluster_package_progressing"
                echo "    Unpacked: $cluster_package_unpacked"
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

    # Finalize OLM check status if it was pending PKO check
    if [ "$olm_subscription_status" = "PENDING_PKO_CHECK" ]; then
        if [ "$cluster_package_exists" = "true" ]; then
            # PKO found, OLM not found = PKO-only installation (normal)
            olm_subscription_status="SKIP"
            olm_subscription_message="No OLM subscription found (PKO installation detected)"

            # On PKO-only clusters, verify no orphaned CSVs remain from OLM migration
            leftover_csvs=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | \
                jq -r "[.items[] | select(.metadata.name | test(\"$DEPLOYMENT\"))] | length" 2>/dev/null || echo "0")
            if [ "$leftover_csvs" -gt 0 ]; then
                leftover_csv_names=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | \
                    jq -r "[.items[] | select(.metadata.name | test(\"$DEPLOYMENT\")) | .metadata.name]" 2>/dev/null || echo "[]")
                orphaned_csvs=$leftover_csvs
                orphaned_csv_names="$leftover_csv_names"
                olm_subscription_status="WARNING"
                olm_subscription_message="PKO-only but $leftover_csvs orphaned CSV(s) remain from OLM migration"
                warning_count=$((warning_count + 1))
                echo "  ⚠ WARNING: $leftover_csvs orphaned CSV(s) found on PKO-only cluster"
            fi
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
    "revision": $([ "$cluster_package_exists" = "true" ] && oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.revision}' 2>/dev/null || echo "0"),
    "dual_installation": $dual_installation,
    "dual_installation_message": "$dual_installation_message"
  }
}
EOF
)")

    # Check PKO cleanup jobs for hung/failed/stale state
    pko_job_status="PASS"
    pko_job_message=""
    hung_jobs=0
    failed_jobs=0
    stale_job_count=0
    orphaned_pods=0

    jobs_json=$(oc get jobs -n "$NAMESPACE" -o json 2>/dev/null)
    if [ -n "$jobs_json" ]; then
        olm_cleanup_jobs=$(echo "$jobs_json" | jq '[.items[] | select(.metadata.name | startswith("olm-cleanup"))]' 2>/dev/null)
        stale_job_count=$(echo "$olm_cleanup_jobs" | jq 'length' 2>/dev/null || echo "0")

        if [ "$stale_job_count" -gt 0 ]; then
            current_epoch=$(date +%s)
            hung_jobs=$(echo "$olm_cleanup_jobs" | jq --argjson now "$current_epoch" '[.[] | select(.status.active > 0) | select(($now - (.metadata.creationTimestamp | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) > 300)] | length' 2>/dev/null || echo "0")
            failed_jobs=$(echo "$olm_cleanup_jobs" | jq '[.[] | select(.status.failed > 0)] | length' 2>/dev/null || echo "0")

            echo "  OLM cleanup jobs: $stale_job_count total, $hung_jobs hung, $failed_jobs failed"

            # Check for orphaned pods
            orphaned_pods=$(oc get pods -n "$NAMESPACE" -o json 2>/dev/null | jq '[.items[] | select(.metadata.name | startswith("olm-cleanup")) | select(.status.phase == "Running") | select(.metadata.ownerReferences == null)] | length' 2>/dev/null || echo "0")

            issues=()
            [ "$hung_jobs" -gt 0 ] && issues+=("$hung_jobs hung job(s)")
            [ "$failed_jobs" -gt 0 ] && issues+=("$failed_jobs failed job(s)")
            [ "$stale_job_count" -gt 3 ] && issues+=("$stale_job_count stale jobs (>3)")
            [ "$orphaned_pods" -gt 0 ] && issues+=("$orphaned_pods orphaned pod(s)")

            if [ ${#issues[@]} -gt 0 ]; then
                pko_job_status="WARNING"
                pko_job_message=$(IFS=', '; echo "${issues[*]}")
                warning_count=$((warning_count + 1))
                echo "  ⚠ PKO job issues: $pko_job_message"
            else
                pko_job_message="$stale_job_count OLM cleanup job(s), all healthy"
                echo "  ✓ PKO cleanup jobs healthy"
            fi
        else
            pko_job_message="No OLM cleanup jobs found"
            echo "  ✓ No OLM cleanup jobs"
        fi
    else
        pko_job_status="SKIP"
        pko_job_message="Could not query jobs"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "pko_job_health",
  "status": "$pko_job_status",
  "severity": "warning",
  "message": "$pko_job_message",
  "details": {
    "olm_cleanup_job_count": $stale_job_count,
    "hung_jobs": $hung_jobs,
    "failed_jobs": $failed_jobs,
    "orphaned_pods": $orphaned_pods
  }
}
EOF
)")

    # Check for ImagePullBackOff — indicates SAAS deployed before Konflux build completed
    image_pull_status="PASS"
    image_pull_message=""
    waiting_pods=$(echo "${pods_json:-{}}" | jq -r '[.items[]? | select(.status.containerStatuses[]? | select(.state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull")) | .metadata.name] | length' 2>/dev/null || echo "0")
    waiting_pods=$(echo "$waiting_pods" | tr -d '[:space:]')

    if [ "${waiting_pods:-0}" -gt 0 ]; then
        image_pull_status="FAIL"
        image_pull_message="$waiting_pods pod(s) in ImagePullBackOff — image may not exist in registry yet (Konflux build pending?)"
        critical_count=$((critical_count + 1))
        echo "  ✗ CRITICAL: $waiting_pods pod(s) in ImagePullBackOff"
    else
        image_pull_message="No ImagePullBackOff issues"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "image_pull_status",
  "status": "$image_pull_status",
  "severity": "critical",
  "message": "$image_pull_message",
  "details": {
    "pods_waiting": ${waiting_pods:-0}
  }
}
EOF
)")

    # Check for orphaned operator-specific OLM resources on PKO-only clusters
    # Filter to only this operator's resources using the OLM label pattern:
    #   operators.coreos.com/<operator-name>.<namespace>
    orphan_check_status="PASS"
    orphan_check_message=""
    orphan_csv_names=""
    orphan_catsrc_names=""
    orphan_sub_names=""
    op_olm_csvs=0
    op_olm_subs=0
    op_olm_catsrc=0

    pko_only=false
    if [ "${cluster_package_exists:-false}" = "true" ] && [ "${subscription_exists:-false}" = "false" ]; then
        pko_only=true
    fi

    # OLM label for this operator: operators.coreos.com/<deployment>.<namespace>
    olm_label="operators.coreos.com/${DEPLOYMENT}.${NAMESPACE}"
    # Also check by operator name pattern in CSV/CatalogSource names
    op_name_pattern="${OPERATOR_NAME:-$DEPLOYMENT}"

    orphan_details=""
    if [ "$pko_only" = true ]; then
        # Check for CSVs owned by this operator (by label or name match)
        op_csvs=$(oc get csv -n "$NAMESPACE" -l "$olm_label" --no-headers 2>/dev/null)
        if [ -z "$op_csvs" ]; then
            # Fallback: match by operator name in CSV name
            op_csvs=$(oc get csv -n "$NAMESPACE" --no-headers 2>/dev/null | grep -i "$op_name_pattern" || true)
        fi
        op_olm_csvs=$(echo "$op_csvs" | grep -c . 2>/dev/null || echo "0")
        op_olm_csvs=$(echo "$op_olm_csvs" | tr -d '[:space:]')

        if [ "${op_olm_csvs:-0}" -gt 0 ]; then
            orphan_csv_names=$(echo "$op_csvs" | awk '{print "'"$NAMESPACE"'/" $1}' | tr '\n' ', ' | sed 's/,$//')
            orphan_details="${orphan_details}${op_olm_csvs} orphaned CSV(s): ${orphan_csv_names}; "
        fi

        # Check for CatalogSources owned by this operator
        op_catsrc=$(oc get catalogsource -n "$NAMESPACE" --no-headers 2>/dev/null | grep -i "$op_name_pattern" || true)
        op_olm_catsrc=$(echo "$op_catsrc" | grep -c . 2>/dev/null || echo "0")
        op_olm_catsrc=$(echo "$op_olm_catsrc" | tr -d '[:space:]')

        if [ "${op_olm_catsrc:-0}" -gt 0 ]; then
            orphan_catsrc_names=$(echo "$op_catsrc" | awk '{print "'"$NAMESPACE"'/" $1}' | tr '\n' ', ' | sed 's/,$//')
            orphan_details="${orphan_details}${op_olm_catsrc} orphaned CatalogSource(s): ${orphan_catsrc_names}; "
        fi

        # Check for Subscriptions owned by this operator (should not exist on PKO-only)
        op_subs=$(oc get subscription.operators.coreos.com -n "$NAMESPACE" -l "$olm_label" --no-headers 2>/dev/null)
        if [ -z "$op_subs" ]; then
            op_subs=$(oc get subscription.operators.coreos.com "$PACKAGE_NAME" -n "$NAMESPACE" --no-headers 2>/dev/null || true)
        fi
        op_olm_subs=$(echo "$op_subs" | grep -c . 2>/dev/null || echo "0")
        op_olm_subs=$(echo "$op_olm_subs" | tr -d '[:space:]')

        if [ "${op_olm_subs:-0}" -gt 0 ]; then
            orphan_sub_names=$(echo "$op_subs" | awk '{print "'"$NAMESPACE"'/" $1}' | tr '\n' ', ' | sed 's/,$//')
            orphan_details="${orphan_details}${op_olm_subs} orphaned Subscription(s): ${orphan_sub_names}; "
        fi
    fi

    if [ -n "$orphan_details" ]; then
        orphan_check_status="WARNING"
        orphan_details="${orphan_details%; }"
        orphan_check_message="PKO-only: orphaned OLM resources for $DEPLOYMENT — $orphan_details"
        warning_count=$((warning_count + 1))
        echo "  ⚠ Orphaned OLM resources for $DEPLOYMENT: $orphan_details"
    else
        if [ "$pko_only" = true ]; then
            orphan_check_message="PKO-only: no orphaned OLM resources for $DEPLOYMENT"
        else
            orphan_check_message="Not PKO-only — orphan check not applicable"
        fi
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "orphaned_resources",
  "status": "$orphan_check_status",
  "severity": "warning",
  "message": "$orphan_check_message",
  "details": {
    "pko_only": $pko_only,
    "olm_label": "$(echo "$olm_label" | sed 's/"/\\"/g')",
    "operator_csvs": ${op_olm_csvs:-0},
    "orphaned_csv_names": "$(echo "${orphan_csv_names:-none}" | sed 's/"/\\"/g')",
    "operator_subscriptions": ${op_olm_subs:-0},
    "orphaned_subscription_names": "$(echo "${orphan_sub_names:-none}" | sed 's/"/\\"/g')",
    "operator_catalogsources": ${op_olm_catsrc:-0},
    "orphaned_catalogsource_names": "$(echo "${orphan_catsrc_names:-none}" | sed 's/"/\\"/g')"
  }
}
EOF
)")

    # Secret-based checks (CAMO-specific, require --secrets flag)
    if [ "$CHECK_SECRETS" = true ] && [[ "$OPERATOR_NAME" == *"configure-alertmanager"* ]]; then
        echo "  Running extended CAMO checks (secrets enabled)..."

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

# RMO-specific checks
if [[ "$OPERATOR_NAME" == *"route-monitor"* ]]; then
    echo "Running RMO-specific health checks..."

    # RMO Check 1: Controller-manager pod status
    rmo_cm_status="PASS"
    rmo_cm_message=""
    rmo_cm_pods=$(oc get pods -n "$NAMESPACE" -l control-plane=controller-manager -o json 2>/dev/null)
    rmo_cm_pod_count=$(echo "$rmo_cm_pods" | jq '.items | length' 2>/dev/null || echo "0")
    rmo_cm_restarts=0
    rmo_cm_termination_reason=""
    rmo_cm_blackbox_image=""

    if [ "$rmo_cm_pod_count" -eq 0 ]; then
        rmo_cm_status="FAIL"
        rmo_cm_message="No controller-manager pod found"
        critical_count=$((critical_count + 1))
        echo "  ✗ CRITICAL: No controller-manager pod found"
    else
        rmo_cm_phase=$(echo "$rmo_cm_pods" | jq -r '.items[0].status.phase // "Unknown"' 2>/dev/null)
        rmo_cm_restarts=$(echo "$rmo_cm_pods" | jq -r '.items[0].status.containerStatuses[] | select(.name == "manager") | .restartCount // 0' 2>/dev/null || echo "0")
        rmo_cm_restarts=$(echo "$rmo_cm_restarts" | tr -d '[:space:]')
        [ -z "$rmo_cm_restarts" ] && rmo_cm_restarts=0
        rmo_cm_termination_reason=$(echo "$rmo_cm_pods" | jq -r '.items[0].status.containerStatuses[] | select(.name == "manager") | .lastState.terminated.reason // empty' 2>/dev/null)
        rmo_cm_pod_name=$(echo "$rmo_cm_pods" | jq -r '.items[0].metadata.name' 2>/dev/null)
        rmo_cm_blackbox_image=$(echo "$rmo_cm_pods" | jq -r '.items[0].spec.containers[] | select(.name == "manager") | .env[] | select(.name == "BLACKBOX_IMAGE") | .value // empty' 2>/dev/null)

        if [ "$rmo_cm_phase" != "Running" ]; then
            rmo_cm_status="FAIL"
            rmo_cm_message="Controller-manager pod is $rmo_cm_phase (expected Running)"
            critical_count=$((critical_count + 1))
            echo "  ✗ CRITICAL: Controller-manager pod is $rmo_cm_phase"
        elif [ "$rmo_cm_restarts" -gt 10 ]; then
            rmo_cm_status="FAIL"
            rmo_cm_message="Controller-manager has excessive restarts ($rmo_cm_restarts)"
            critical_count=$((critical_count + 1))
            echo "  ✗ CRITICAL: $rmo_cm_restarts restarts"
        elif [ "$rmo_cm_restarts" -gt 5 ]; then
            rmo_cm_status="WARNING"
            rmo_cm_message="Controller-manager has elevated restarts ($rmo_cm_restarts)"
            warning_count=$((warning_count + 1))
            echo "  ⚠ WARNING: $rmo_cm_restarts restarts"
        elif [ "$rmo_cm_termination_reason" = "OOMKilled" ]; then
            rmo_cm_status="WARNING"
            rmo_cm_message="Controller-manager last termination was OOMKilled"
            warning_count=$((warning_count + 1))
            echo "  ⚠ Last termination: OOMKilled"
        else
            rmo_cm_message="Controller-manager pod healthy ($rmo_cm_pod_name, $rmo_cm_restarts restarts)"
            echo "  ✓ Controller-manager pod healthy ($rmo_cm_restarts restarts)"
        fi
        [ -n "$rmo_cm_blackbox_image" ] && echo "  ℹ Blackbox image: ${rmo_cm_blackbox_image##*@}"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "rmo_controller_manager",
  "status": "$rmo_cm_status",
  "severity": "$([ "$rmo_cm_status" = "FAIL" ] && echo "critical" || echo "warning")",
  "message": "$rmo_cm_message",
  "details": {
    "pod_count": $rmo_cm_pod_count,
    "restart_count": $rmo_cm_restarts,
    "last_termination_reason": "${rmo_cm_termination_reason:-none}",
    "blackbox_image": "$(echo "${rmo_cm_blackbox_image:-none}" | sed 's/"/\\"/g')"
  }
}
EOF
)")

    # RMO Check 2: Blackbox exporter health
    # Blackbox is created by RMO on-demand — only exists if RouteMonitors/ClusterUrlMonitors exist
    rmo_bb_status="PASS"
    rmo_bb_message=""
    rmo_bb_desired=0
    rmo_bb_ready=0
    rmo_bb_restarts=0
    rmo_bb_svc_exists=false
    rmo_bb_cm_exists=false
    rmo_bb_deploy=$(oc get deployment -n "$NAMESPACE" blackbox-exporter -o json 2>/dev/null)

    # Check if any monitors exist to determine if blackbox should be present
    has_monitors=false
    monitor_count=$(oc get routemonitor -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    cum_count=$(oc get clusterurlmonitor -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    total_monitors=$((monitor_count + cum_count))
    [ "$total_monitors" -gt 0 ] && has_monitors=true

    if [ -z "$rmo_bb_deploy" ] || ! echo "$rmo_bb_deploy" | jq -e '.metadata.name' >/dev/null 2>&1; then
        if [ "$has_monitors" = true ]; then
            rmo_bb_status="WARNING"
            rmo_bb_message="Blackbox exporter missing but $total_monitors monitor(s) exist — probes cannot run"
            warning_count=$((warning_count + 1))
            echo "  ⚠ Blackbox exporter missing ($total_monitors monitors need it)"
        else
            rmo_bb_status="INFO"
            rmo_bb_message="No blackbox-exporter (expected — no monitors configured)"
            echo "  ℹ No blackbox-exporter (no monitors configured)"
        fi
    else
        rmo_bb_desired=$(echo "$rmo_bb_deploy" | jq -r '.spec.replicas // 0' 2>/dev/null)
        rmo_bb_ready=$(echo "$rmo_bb_deploy" | jq -r '.status.readyReplicas // 0' 2>/dev/null)

        rmo_bb_pods=$(oc get pods -n "$NAMESPACE" -l app=blackbox-exporter -o json 2>/dev/null)
        rmo_bb_restarts=$(echo "$rmo_bb_pods" | jq '[.items[].status.containerStatuses[]?.restartCount // 0] | add // 0' 2>/dev/null || echo "0")
        rmo_bb_restarts=$(echo "$rmo_bb_restarts" | tr -d '[:space:]')
        [ -z "$rmo_bb_restarts" ] && rmo_bb_restarts=0

        # Check companion resources
        oc get service -n "$NAMESPACE" blackbox-exporter &>/dev/null && rmo_bb_svc_exists=true
        oc get configmap -n "$NAMESPACE" blackbox-exporter &>/dev/null && rmo_bb_cm_exists=true

        if [ "$rmo_bb_ready" -ne "$rmo_bb_desired" ]; then
            rmo_bb_status="WARNING"
            rmo_bb_message="Blackbox exporter not fully ready ($rmo_bb_ready/$rmo_bb_desired)"
            warning_count=$((warning_count + 1))
            echo "  ⚠ Blackbox exporter: $rmo_bb_ready/$rmo_bb_desired ready"
        elif [ "$rmo_bb_restarts" -gt 5 ]; then
            rmo_bb_status="WARNING"
            rmo_bb_message="Blackbox exporter has elevated restarts ($rmo_bb_restarts)"
            warning_count=$((warning_count + 1))
            echo "  ⚠ Blackbox exporter: $rmo_bb_restarts restarts"
        elif [ "$rmo_bb_svc_exists" = false ]; then
            rmo_bb_status="WARNING"
            rmo_bb_message="Blackbox exporter Service missing"
            warning_count=$((warning_count + 1))
            echo "  ⚠ Blackbox exporter Service missing"
        else
            rmo_bb_message="Blackbox exporter healthy ($rmo_bb_ready/$rmo_bb_desired ready)"
            echo "  ✓ Blackbox exporter healthy ($rmo_bb_ready/$rmo_bb_desired ready)"
        fi
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "rmo_blackbox_exporter",
  "status": "$rmo_bb_status",
  "severity": "warning",
  "message": "$rmo_bb_message",
  "details": {
    "desired_replicas": $rmo_bb_desired,
    "ready_replicas": $rmo_bb_ready,
    "total_restarts": $rmo_bb_restarts,
    "service_exists": $rmo_bb_svc_exists,
    "configmap_exists": $rmo_bb_cm_exists,
    "monitors_present": $has_monitors,
    "total_monitors": $total_monitors
  }
}
EOF
)")

    # RMO Check 3: RouteMonitor and ClusterUrlMonitor CRD health
    rmo_rm_status="PASS"
    rmo_rm_message=""
    rm_count=0
    cum_count_detail=0
    rm_errors=0
    rm_missing_url=0
    rm_missing_sm=0

    routemonitors=$(oc get routemonitor -A -o json 2>/dev/null)
    clusterurlmonitors=$(oc get clusterurlmonitor -A -o json 2>/dev/null)

    if [ -n "$routemonitors" ] && echo "$routemonitors" | jq -e '.items' >/dev/null 2>&1; then
        rm_count=$(echo "$routemonitors" | jq '.items | length' 2>/dev/null || echo "0")
        rm_count=$(echo "$rm_count" | tr -d '[:space:]')
        [ -z "$rm_count" ] && rm_count=0

        if [ "$rm_count" -gt 0 ]; then
            rm_errors=$(echo "$routemonitors" | jq '[.items[] | select(.status.errorStatus != null and .status.errorStatus != "")] | length' 2>/dev/null || echo "0")
            rm_errors=$(echo "$rm_errors" | tr -d '[:space:]')
            rm_missing_url=$(echo "$routemonitors" | jq '[.items[] | select(.status.routeURL == null or .status.routeURL == "")] | length' 2>/dev/null || echo "0")
            rm_missing_url=$(echo "$rm_missing_url" | tr -d '[:space:]')
            rm_missing_sm=$(echo "$routemonitors" | jq '[.items[] | select(.status.serviceMonitorRef.name == null or .status.serviceMonitorRef.name == "")] | length' 2>/dev/null || echo "0")
            rm_missing_sm=$(echo "$rm_missing_sm" | tr -d '[:space:]')
        fi
    fi

    if [ -n "$clusterurlmonitors" ] && echo "$clusterurlmonitors" | jq -e '.items' >/dev/null 2>&1; then
        cum_count_detail=$(echo "$clusterurlmonitors" | jq '.items | length' 2>/dev/null || echo "0")
        cum_count_detail=$(echo "$cum_count_detail" | tr -d '[:space:]')
        [ -z "$cum_count_detail" ] && cum_count_detail=0

        if [ "$cum_count_detail" -gt 0 ]; then
            cum_errors=$(echo "$clusterurlmonitors" | jq '[.items[] | select(.status.errorStatus != null and .status.errorStatus != "")] | length' 2>/dev/null || echo "0")
            cum_errors=$(echo "$cum_errors" | tr -d '[:space:]')
            rm_errors=$((rm_errors + cum_errors))
        fi
    fi

    total_crd_count=$((rm_count + cum_count_detail))
    if [ "$total_crd_count" -eq 0 ]; then
        # Check if CRDs exist (different from CRs missing)
        rm_crd_exists=$(oc get crd routemonitors.monitoring.openshift.io --no-headers 2>/dev/null | wc -l | tr -d ' ')
        cum_crd_exists=$(oc get crd clusterurlmonitors.monitoring.openshift.io --no-headers 2>/dev/null | wc -l | tr -d ' ')

        if [ "${rm_crd_exists:-0}" -eq 0 ] && [ "${cum_crd_exists:-0}" -eq 0 ]; then
            rmo_rm_status="FAIL"
            rmo_rm_message="RouteMonitor and ClusterUrlMonitor CRDs not installed — RMO PKO package may not have deployed correctly"
            critical_count=$((critical_count + 1))
            echo "  ✗ CRITICAL: RouteMonitor/ClusterUrlMonitor CRDs missing"
        elif [ "$cluster_type" = "management_cluster" ] || [ "$cluster_type" = "service_cluster" ]; then
            rmo_rm_status="WARNING"
            rmo_rm_message="No RouteMonitor or ClusterUrlMonitor CRs on $cluster_type — console/api monitors expected via SyncSet"
            warning_count=$((warning_count + 1))
            echo "  ⚠ No monitor CRs on $cluster_type (expected via SyncSet)"
        else
            # Check if monitoring resources exist despite no RouteMonitor CRs
            # SyncSet may delete CRs but leave ServiceMonitors/PrometheusRules/blackbox functional
            orphan_sms=$(oc get servicemonitor -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            orphan_prs=$(oc get prometheusrule -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            bb_running=$(oc get deployment blackbox-exporter -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

            if [ "${orphan_sms:-0}" -gt 0 ] || [ "${orphan_prs:-0}" -gt 0 ] || [ "${bb_running:-0}" -gt 0 ]; then
                rmo_rm_status="WARNING"
                rmo_rm_message="Orphaned RMO resources: no RouteMonitor CRs but $orphan_sms ServiceMonitor(s), $orphan_prs PrometheusRule(s), blackbox replicas: ${bb_running:-0} — likely PKO/OLM migration cleanup issue"
                warning_count=$((warning_count + 1))
                echo "  ⚠ Orphaned resources without parent CRs: $orphan_sms SMs, $orphan_prs PRs, blackbox: ${bb_running:-0}"
            else
                rmo_rm_status="INFO"
                rmo_rm_message="No RouteMonitor CRs and no monitoring resources in $NAMESPACE (CRDs present)"
                echo "  ℹ No CRs and no monitoring resources in namespace"
            fi
        fi
    elif [ "$rm_errors" -gt 0 ]; then
        rmo_rm_status="WARNING"
        rmo_rm_message="$rm_errors monitor(s) have errorStatus set"
        warning_count=$((warning_count + 1))
        echo "  ⚠ $rm_errors monitor(s) with errors"
    elif [ "$rm_missing_url" -gt 0 ]; then
        rmo_rm_status="WARNING"
        rmo_rm_message="$rm_missing_url RouteMonitor(s) missing routeURL"
        warning_count=$((warning_count + 1))
        echo "  ⚠ $rm_missing_url RouteMonitor(s) missing URL"
    elif [ "$rm_missing_sm" -gt 0 ]; then
        rmo_rm_status="WARNING"
        rmo_rm_message="$rm_missing_sm RouteMonitor(s) missing ServiceMonitor reference"
        warning_count=$((warning_count + 1))
        echo "  ⚠ $rm_missing_sm RouteMonitor(s) missing ServiceMonitor"
    else
        rmo_rm_message="$rm_count RouteMonitor(s), $cum_count_detail ClusterUrlMonitor(s) — all healthy"
        echo "  ✓ $rm_count RouteMonitor(s), $cum_count_detail ClusterUrlMonitor(s) — all healthy"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "rmo_routemonitor_status",
  "status": "$rmo_rm_status",
  "severity": "warning",
  "message": "$rmo_rm_message",
  "details": {
    "routemonitor_count": $rm_count,
    "clusterurlmonitor_count": $cum_count_detail,
    "error_count": $rm_errors,
    "missing_url_count": $rm_missing_url,
    "missing_servicemonitor_count": $rm_missing_sm
  }
}
EOF
)")

    # RMO Check 3b: Probe health — verify blackbox probes are succeeding
    rmo_probe_status="PASS"
    rmo_probe_message=""
    rmo_probe_total=0
    rmo_probe_failing=0
    rmo_probe_failing_targets=""
    probe_count_mismatch=false

    if [ "$total_crd_count" -gt 0 ]; then
        echo "  Querying probe_success metrics from Thanos..."
        probe_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
            wget -q -T 30 -O- "http://localhost:9090/api/v1/query?query=$(printf 'probe_success{namespace=~"openshift-route-monitor-operator|ocm-.*"}' | jq -sRr @uri)" 2>/dev/null)

        if [ -n "$probe_data" ] && echo "$probe_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
            rmo_probe_total=$(echo "$probe_data" | jq '.data.result | length' 2>/dev/null || echo "0")
            rmo_probe_total=$(echo "$rmo_probe_total" | tr -d '[:space:]')

            # Find probes with success=0 (currently failing)
            rmo_probe_failing=$(echo "$probe_data" | jq '[.data.result[] | select(.value[1] == "0")] | length' 2>/dev/null || echo "0")
            rmo_probe_failing=$(echo "$rmo_probe_failing" | tr -d '[:space:]')

            # Compare probe count against expected monitor count
            probe_count_mismatch=false
            if [ "$rmo_probe_total" -lt "$total_crd_count" ]; then
                probe_count_mismatch=true
            fi

            if [ "${rmo_probe_failing:-0}" -gt 0 ]; then
                rmo_probe_failing_targets=$(echo "$probe_data" | jq -r '.data.result[] | select(.value[1] == "0") | .metric.instance // .metric.target // .metric.namespace | .[0:60]' 2>/dev/null | head -5 | tr '\n' ', ' | sed 's/,$//')
                rmo_probe_status="WARNING"
                rmo_probe_message="$rmo_probe_failing/$rmo_probe_total probe(s) failing (${total_crd_count} monitors expected)"
                warning_count=$((warning_count + 1))
                echo "  ⚠ $rmo_probe_failing/$rmo_probe_total probes failing"
            elif [ "$probe_count_mismatch" = true ]; then
                rmo_probe_status="WARNING"
                rmo_probe_message="Probe count mismatch: $rmo_probe_total active probes but $total_crd_count monitors configured — RMO may not have created all ServiceMonitors"
                warning_count=$((warning_count + 1))
                echo "  ⚠ Probe count mismatch: $rmo_probe_total probes vs $total_crd_count monitors"
            else
                rmo_probe_message="All $rmo_probe_total/$total_crd_count probe(s) succeeding"
                echo "  ✓ All $rmo_probe_total/$total_crd_count probes succeeding"
            fi
        else
            if [ "$total_crd_count" -gt 0 ]; then
                rmo_probe_status="WARNING"
                rmo_probe_message="No probe metrics found but $total_crd_count monitors exist — probes may not be scraped"
                warning_count=$((warning_count + 1))
                echo "  ⚠ No probe metrics despite $total_crd_count monitors"
            else
                rmo_probe_status="INFO"
                rmo_probe_message="No probe metrics (no monitors configured)"
                echo "  ℹ No probe metrics available"
            fi
        fi
    else
        rmo_probe_status="SKIP"
        rmo_probe_message="No monitors configured — no probes to check"
        echo "  ℹ Probe check skipped (no monitors)"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "rmo_probe_health",
  "status": "$rmo_probe_status",
  "severity": "warning",
  "message": "$rmo_probe_message",
  "details": {
    "active_probes": $rmo_probe_total,
    "expected_monitors": $total_crd_count,
    "probe_count_match": $([ "$probe_count_mismatch" = true ] && echo "false" || echo "true"),
    "failing_probes": $rmo_probe_failing,
    "failing_targets": "$(echo "${rmo_probe_failing_targets:-none}" | sed 's/"/\\"/g')"
  }
}
EOF
)")

    # RMO Check 4: ServiceMonitor validation
    # Use status.serviceMonitorRef from each monitor to verify existence directly
    # (ownerReferences are not always set, especially on coreos.com ServiceMonitors)
    rmo_sm_status="PASS"
    rmo_sm_message=""
    rmo_sm_found=0
    rmo_sm_missing=0
    rmo_sm_expected=$total_crd_count

    if [ "$rmo_rm_status" = "WARNING" ] && [ "$total_crd_count" -eq 0 ]; then
        # No monitors found (already warned in routemonitor_status) — skip dependent checks
        rmo_sm_status="SKIP"
        rmo_sm_message="Skipped — no RouteMonitor/ClusterUrlMonitor CRs exist (see routemonitor_status)"
        echo "  ℹ ServiceMonitor check skipped (no monitors)"
    elif [ "$total_crd_count" -gt 0 ]; then
        # Collect serviceMonitorRefs from RouteMonitors
        sm_refs=""
        if [ -n "${routemonitors:-}" ]; then
            sm_refs=$(echo "$routemonitors" | jq -r '.items[] | select(.status.serviceMonitorRef.name != null and .status.serviceMonitorRef.name != "") | "\(.status.serviceMonitorRef.namespace)/\(.status.serviceMonitorRef.name)"' 2>/dev/null)
        fi
        if [ -n "${clusterurlmonitors:-}" ]; then
            cum_sm_refs=$(echo "$clusterurlmonitors" | jq -r '.items[] | select(.status.serviceMonitorRef.name != null and .status.serviceMonitorRef.name != "") | "\(.status.serviceMonitorRef.namespace)/\(.status.serviceMonitorRef.name)"' 2>/dev/null)
            [ -n "$cum_sm_refs" ] && sm_refs="${sm_refs}${sm_refs:+$'\n'}${cum_sm_refs}"
        fi

        # Verify each referenced ServiceMonitor exists (try both API groups)
        if [ -n "$sm_refs" ]; then
            while IFS= read -r ref; do
                [ -z "$ref" ] && continue
                sm_ns="${ref%%/*}"
                sm_name="${ref#*/}"
                if oc get servicemonitor.monitoring.coreos.com "$sm_name" -n "$sm_ns" &>/dev/null || \
                   oc get servicemonitor.monitoring.rhobs "$sm_name" -n "$sm_ns" &>/dev/null; then
                    rmo_sm_found=$((rmo_sm_found + 1))
                    echo "  ✓ ServiceMonitor: $sm_ns/$sm_name"
                else
                    rmo_sm_missing=$((rmo_sm_missing + 1))
                    echo "  ⚠ Missing ServiceMonitor: $sm_ns/$sm_name"
                fi
            done <<< "$sm_refs"
        fi

        if [ "$rmo_sm_missing" -gt 0 ]; then
            rmo_sm_status="WARNING"
            rmo_sm_message="$rmo_sm_missing ServiceMonitor(s) missing ($rmo_sm_found/$rmo_sm_expected found)"
            warning_count=$((warning_count + 1))
        elif [ "$rmo_sm_found" -eq 0 ] && [ "$total_crd_count" -gt 0 ]; then
            rmo_sm_status="WARNING"
            rmo_sm_message="No ServiceMonitors referenced in monitor status ($total_crd_count monitors exist)"
            warning_count=$((warning_count + 1))
            echo "  ⚠ No serviceMonitorRef in monitor status"
        else
            rmo_sm_message="$rmo_sm_found ServiceMonitor(s) verified"
            echo "  ✓ $rmo_sm_found ServiceMonitor(s) verified"
        fi
    else
        rmo_sm_status="INFO"
        rmo_sm_message="No monitors configured — no ServiceMonitors expected"
        echo "  ℹ No ServiceMonitors expected (no monitors)"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "rmo_servicemonitor_health",
  "status": "$rmo_sm_status",
  "severity": "warning",
  "message": "$rmo_sm_message",
  "details": {
    "found_servicemonitors": $rmo_sm_found,
    "missing_servicemonitors": $rmo_sm_missing,
    "expected_monitors": $rmo_sm_expected
  }
}
EOF
)")

    # RMO Check 5: PrometheusRule validation
    # Use status.prometheusRuleRef from each monitor to verify rules exist in their namespaces
    rmo_pr_status="PASS"
    rmo_pr_message=""
    rmo_pr_total=0
    rmo_pr_expected=0
    rmo_pr_found=0
    rmo_pr_missing=0

    if [ "$rmo_rm_status" = "WARNING" ] && [ "$total_crd_count" -eq 0 ]; then
        rmo_pr_status="SKIP"
        rmo_pr_message="Skipped — no RouteMonitor/ClusterUrlMonitor CRs exist (see routemonitor_status)"
        echo "  ℹ PrometheusRule check skipped (no monitors)"
    fi

    # Collect prometheusRuleRefs from RouteMonitors (skip those with skipPrometheusRule=true)
    pr_refs=""
    if [ "$rmo_pr_status" != "SKIP" ] && [ -n "${routemonitors:-}" ]; then
        pr_refs=$(echo "$routemonitors" | jq -r '.items[] | select(.spec.skipPrometheusRule != true) | select(.status.prometheusRuleRef.name != null and .status.prometheusRuleRef.name != "") | "\(.status.prometheusRuleRef.namespace)/\(.status.prometheusRuleRef.name)"' 2>/dev/null)
        rmo_pr_expected=$(echo "$routemonitors" | jq '[.items[] | select(.spec.skipPrometheusRule != true)] | length' 2>/dev/null || echo "0")
        rmo_pr_expected=$(echo "$rmo_pr_expected" | tr -d '[:space:]')
    fi
    if [ -n "${clusterurlmonitors:-}" ]; then
        cum_refs=$(echo "$clusterurlmonitors" | jq -r '.items[] | select(.spec.skipPrometheusRule != true) | select(.status.prometheusRuleRef.name != null and .status.prometheusRuleRef.name != "") | "\(.status.prometheusRuleRef.namespace)/\(.status.prometheusRuleRef.name)"' 2>/dev/null)
        [ -n "$cum_refs" ] && pr_refs="${pr_refs}${pr_refs:+$'\n'}${cum_refs}"
        cum_expected=$(echo "$clusterurlmonitors" | jq '[.items[] | select(.spec.skipPrometheusRule != true)] | length' 2>/dev/null || echo "0")
        cum_expected=$(echo "$cum_expected" | tr -d '[:space:]')
        rmo_pr_expected=$(( ${rmo_pr_expected:-0} + ${cum_expected:-0} ))
    fi
    [ -z "$rmo_pr_expected" ] && rmo_pr_expected=0

    # Verify each referenced PrometheusRule exists
    if [ -n "$pr_refs" ]; then
        while IFS= read -r ref; do
            [ -z "$ref" ] && continue
            pr_ns="${ref%%/*}"
            pr_name="${ref#*/}"
            if oc get prometheusrule "$pr_name" -n "$pr_ns" &>/dev/null; then
                rmo_pr_found=$((rmo_pr_found + 1))
            else
                rmo_pr_missing=$((rmo_pr_missing + 1))
                echo "  ⚠ Missing: $pr_ns/$pr_name"
            fi
        done <<< "$pr_refs"
    fi
    rmo_pr_total=$rmo_pr_found

    if [ "$rmo_pr_expected" -eq 0 ]; then
        rmo_pr_status="INFO"
        rmo_pr_message="No PrometheusRules expected (all monitors skip rules or none configured)"
        echo "  ℹ No PrometheusRules expected"
    elif [ "$rmo_pr_missing" -gt 0 ]; then
        rmo_pr_status="WARNING"
        rmo_pr_message="$rmo_pr_missing PrometheusRule(s) missing ($rmo_pr_found/$rmo_pr_expected found)"
        warning_count=$((warning_count + 1))
        echo "  ⚠ $rmo_pr_found/$rmo_pr_expected PrometheusRules found"
    else
        rmo_pr_message="$rmo_pr_total PrometheusRule(s) verified ($rmo_pr_expected expected)"
        echo "  ✓ $rmo_pr_total PrometheusRule(s) verified"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "rmo_prometheusrule_health",
  "status": "$rmo_pr_status",
  "severity": "warning",
  "message": "$rmo_pr_message",
  "details": {
    "total_prometheusrules": $rmo_pr_total,
    "expected_prometheusrules": ${rmo_pr_expected:-0}
  }
}
EOF
)")

    # RMO Check 6: Operator metrics
    rmo_metrics_status="PASS"
    rmo_metrics_message=""
    rmo_info_version=""
    rmo_api_success=0
    rmo_api_errors=0
    rmo_probe_timeouts=0

    query_rmo_metric() {
        local metric_name="$1"
        local query="${metric_name}{namespace=\"$NAMESPACE\"}"
        local query_encoded=$(printf '%s' "$query" | jq -sRr @uri)
        ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
            wget -q -T 30 -O- "http://localhost:9090/api/v1/query?query=${query_encoded}" 2>/dev/null
    }

    echo "  Querying RMO Prometheus metrics..."
    rmo_info_data=$(query_rmo_metric "rhobs_route_monitor_operator_info")
    if [ -n "$rmo_info_data" ] && echo "$rmo_info_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
        rmo_info_version=$(echo "$rmo_info_data" | jq -r '.data.result[0].metric.version // empty' 2>/dev/null)
        echo "  ✓ RMO info metric present (version: ${rmo_info_version:-unknown})"
    else
        echo "  ℹ RMO info metric not found"
    fi

    rmo_api_data=$(query_rmo_metric "rhobs_route_monitor_operator_api_requests_total")
    if [ -n "$rmo_api_data" ] && echo "$rmo_api_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
        rmo_api_success=$(echo "$rmo_api_data" | jq -r '[.data.result[] | select(.metric.status == "success") | .value[1] | tonumber] | add // 0' 2>/dev/null || echo "0")
        rmo_api_errors=$(echo "$rmo_api_data" | jq -r '[.data.result[] | select(.metric.status == "error") | .value[1] | tonumber] | add // 0' 2>/dev/null || echo "0")
        rmo_api_success=$(echo "$rmo_api_success" | tr -d '[:space:]')
        rmo_api_errors=$(echo "$rmo_api_errors" | tr -d '[:space:]')
        [ -z "$rmo_api_success" ] && rmo_api_success=0
        [ -z "$rmo_api_errors" ] && rmo_api_errors=0
        echo "  ℹ API requests: ${rmo_api_success} success, ${rmo_api_errors} errors"
    fi

    rmo_timeout_data=$(query_rmo_metric "rhobs_route_monitor_operator_probe_deletion_timeout_total")
    if [ -n "$rmo_timeout_data" ] && echo "$rmo_timeout_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
        rmo_probe_timeouts=$(echo "$rmo_timeout_data" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
        rmo_probe_timeouts=$(echo "$rmo_probe_timeouts" | tr -d '[:space:]')
        [ -z "$rmo_probe_timeouts" ] && rmo_probe_timeouts=0
        if [ "$rmo_probe_timeouts" -gt 0 ] 2>/dev/null; then
            rmo_metrics_status="WARNING"
            rmo_metrics_message="$rmo_probe_timeouts probe deletion timeout(s) detected"
            warning_count=$((warning_count + 1))
            echo "  ⚠ $rmo_probe_timeouts probe deletion timeouts"
        fi
    fi

    if [ "$rmo_api_errors" -gt 0 ] 2>/dev/null && [ "$rmo_api_success" -eq 0 ] 2>/dev/null; then
        rmo_metrics_status="WARNING"
        rmo_metrics_message="All RHOBS API requests failing ($rmo_api_errors errors, 0 success)"
        warning_count=$((warning_count + 1))
        echo "  ⚠ All RHOBS API requests failing"
    elif [ "$rmo_metrics_status" = "PASS" ]; then
        rmo_metrics_message="RMO metrics healthy"
        echo "  ✓ RMO metrics healthy"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "rmo_operator_metrics",
  "status": "$rmo_metrics_status",
  "severity": "warning",
  "message": "$rmo_metrics_message",
  "details": {
    "info_version": "${rmo_info_version:-unknown}",
    "api_success_count": $rmo_api_success,
    "api_error_count": $rmo_api_errors,
    "probe_deletion_timeouts": $rmo_probe_timeouts
  }
}
EOF
)")

    # RMO Check 7: ConfigMap configuration
    rmo_config_status="PASS"
    rmo_config_message=""
    # PKO creates route-monitor-operator-manager-config; runtime creates route-monitor-operator-config
    rmo_config_data=$(oc get configmap -n "$NAMESPACE" route-monitor-operator-manager-config -o json 2>/dev/null)
    if [ -z "$rmo_config_data" ] || ! echo "$rmo_config_data" | jq -e '.metadata.name' >/dev/null 2>&1; then
        rmo_config_data=$(oc get configmap -n "$NAMESPACE" route-monitor-operator-config -o json 2>/dev/null)
    fi
    rmo_probe_api_url=""
    rmo_only_public=""
    rmo_skip_health=""

    if [ -n "$rmo_config_data" ] && echo "$rmo_config_data" | jq -e '.metadata.name' >/dev/null 2>&1; then
        rmo_probe_api_url=$(echo "$rmo_config_data" | jq -r '.data["probe-api-url"] // empty' 2>/dev/null)
        rmo_only_public=$(echo "$rmo_config_data" | jq -r '.data["only-public-clusters"] // empty' 2>/dev/null)
        rmo_skip_health=$(echo "$rmo_config_data" | jq -r '.data["skip-infrastructure-health-check"] // empty' 2>/dev/null)
        rmo_config_message="ConfigMap present"
        echo "  ✓ ConfigMap present"
        [ -n "$rmo_probe_api_url" ] && echo "    probe-api-url: ${rmo_probe_api_url:0:50}..."
        [ -n "$rmo_only_public" ] && echo "    only-public-clusters: $rmo_only_public"
        [ -n "$rmo_skip_health" ] && echo "    skip-infrastructure-health-check: $rmo_skip_health"
    else
        rmo_config_status="INFO"
        rmo_config_message="No ConfigMap found (using defaults)"
        echo "  ℹ No ConfigMap (using defaults)"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "rmo_config",
  "status": "$rmo_config_status",
  "severity": "info",
  "message": "$rmo_config_message",
  "details": {
    "probe_api_url": "$(echo "${rmo_probe_api_url:-none}" | sed 's/"/\\"/g')",
    "only_public_clusters": "${rmo_only_public:-not set}",
    "skip_infrastructure_health_check": "${rmo_skip_health:-not set}"
  }
}
EOF
)")

    # RMO Check 8: HCP RouteMonitor coverage (MC clusters only)
    if [ "$cluster_type" = "management_cluster" ]; then
        rmo_hcp_status="PASS"
        rmo_hcp_message=""
        hcp_count=0
        hcp_monitored=0
        hcp_unmonitored=0
        hcp_stale=0
        hcp_unmonitored_names=""
        hcp_expected=0
        hcp_not_ready=0
        hcp_deleting=0
        hcp_orphaned=0
        rm_with_errors=0

        hcp_list=$(oc get hostedcontrolplane -A -o json 2>/dev/null)
        if [ -n "$hcp_list" ] && echo "$hcp_list" | jq -e '.items[0]' >/dev/null 2>&1; then
            hcp_count=$(echo "$hcp_list" | jq '.items | length' 2>/dev/null || echo "0")
            hcp_count=$(echo "$hcp_count" | tr -d '[:space:]')

            if [ "$hcp_count" -gt 0 ]; then
                echo "  Checking RouteMonitor coverage for $hcp_count HostedControlPlane(s)..."
                hcp_expected=0
                hcp_not_ready=0
                hcp_deleting=0

                # Get namespaces that have RouteMonitors
                rm_namespaces=$(echo "${routemonitors:-{}}" | jq -r '[.items[]? | .metadata.namespace] | unique | .[]' 2>/dev/null)

                # Check only-public-clusters setting to understand private cluster handling
                rmo_public_only="${rmo_only_public:-false}"

                while IFS=$'\t' read -r hcp_name hcp_ns hcp_available hcp_has_deletion hcp_phase; do
                    [ -z "$hcp_name" ] && continue

                    # Classify HCP state
                    if [ "$hcp_has_deletion" = "true" ] || [ "$hcp_phase" = "Deleting" ]; then
                        hcp_deleting=$((hcp_deleting + 1))
                        echo "  ℹ HCP ${hcp_name}: deleting — RouteMonitor cleanup expected"
                        continue
                    fi

                    if [ "$hcp_available" != "True" ]; then
                        hcp_not_ready=$((hcp_not_ready + 1))
                        echo "  ℹ HCP ${hcp_name}: not yet Available — monitor pending (gated on 5 consecutive health checks)"
                        continue
                    fi

                    # HCP is available and not deleting — should have a RouteMonitor
                    hcp_expected=$((hcp_expected + 1))
                    if echo "$rm_namespaces" | grep -q "^${hcp_ns}$"; then
                        hcp_monitored=$((hcp_monitored + 1))
                    else
                        hcp_unmonitored=$((hcp_unmonitored + 1))
                        hcp_unmonitored_names="${hcp_unmonitored_names}${hcp_unmonitored_names:+, }${hcp_ns}/${hcp_name}"
                        echo "  ⚠ HCP ${hcp_name} (Available) has no RouteMonitor in ${hcp_ns}"
                    fi
                done < <(echo "$hcp_list" | jq -r '.items[] | [
                    .metadata.name,
                    .metadata.namespace,
                    ((.status.conditions[]? | select(.type == "Available") | .status) // "Unknown"),
                    (if .metadata.deletionTimestamp then "true" else "false" end),
                    ((.status.conditions[]? | select(.type == "Progressing") | .message) // "")
                ] | @tsv' 2>/dev/null)

                # Check for orphaned/stale RouteMonitors
                hcp_namespaces=$(echo "$hcp_list" | jq -r '[.items[] | .metadata.namespace] | unique | .[]' 2>/dev/null)
                deleting_namespaces=$(echo "$hcp_list" | jq -r '[.items[] | select(.metadata.deletionTimestamp) | .metadata.namespace] | unique | .[]' 2>/dev/null)
                hcp_orphaned=0

                if [ -n "$rm_namespaces" ]; then
                    while IFS= read -r rm_ns; do
                        [ -z "$rm_ns" ] && continue
                        [[ "$rm_ns" == "openshift-route-monitor-operator" ]] && continue
                        if ! echo "$hcp_namespaces" | grep -q "^${rm_ns}$"; then
                            hcp_stale=$((hcp_stale + 1))
                            echo "  ⚠ Orphaned RouteMonitor in ${rm_ns} (HCP namespace gone)"
                        elif echo "$deleting_namespaces" | grep -q "^${rm_ns}$"; then
                            hcp_orphaned=$((hcp_orphaned + 1))
                            echo "  ℹ RouteMonitor in ${rm_ns} for deleting HCP (cleanup pending)"
                        fi
                    done <<< "$rm_namespaces"
                fi

                # Check for RouteMonitors with errors
                rm_with_errors=0
                if [ -n "${routemonitors:-}" ]; then
                    rm_with_errors=$(echo "$routemonitors" | jq '[.items[] | select(.metadata.namespace != "openshift-route-monitor-operator") | select(.status.errorStatus != null and .status.errorStatus != "")] | length' 2>/dev/null || echo "0")
                    rm_with_errors=$(echo "$rm_with_errors" | tr -d '[:space:]')
                    if [ "${rm_with_errors:-0}" -gt 0 ]; then
                        echo "  ⚠ $rm_with_errors HCP RouteMonitor(s) have errors"
                        # Print error details
                        echo "$routemonitors" | jq -r '.items[] | select(.metadata.namespace != "openshift-route-monitor-operator") | select(.status.errorStatus != null and .status.errorStatus != "") | "    \(.metadata.namespace)/\(.metadata.name): \(.status.errorStatus[0:80])"' 2>/dev/null
                    fi
                fi

                echo "  HCP summary: $hcp_count total, $hcp_expected expected, $hcp_monitored monitored, $hcp_not_ready not ready, $hcp_deleting deleting, $hcp_stale orphaned, $hcp_orphaned cleanup pending"

                if [ "$hcp_unmonitored" -gt 0 ]; then
                    rmo_hcp_status="WARNING"
                    rmo_hcp_message="$hcp_unmonitored/$hcp_expected Available HCP(s) missing RouteMonitor ($hcp_not_ready not ready, $hcp_deleting deleting)"
                    warning_count=$((warning_count + 1))
                elif [ "$hcp_stale" -gt 0 ]; then
                    rmo_hcp_status="WARNING"
                    rmo_hcp_message="$hcp_stale orphaned RouteMonitor(s) — HCP namespace no longer exists"
                    warning_count=$((warning_count + 1))
                elif [ "${rm_with_errors:-0}" -gt 0 ]; then
                    rmo_hcp_status="WARNING"
                    rmo_hcp_message="$rm_with_errors HCP RouteMonitor(s) have errors"
                    warning_count=$((warning_count + 1))
                else
                    rmo_hcp_message="$hcp_monitored/$hcp_expected Available HCP(s) monitored ($hcp_not_ready not ready, $hcp_deleting deleting)"
                fi
            else
                rmo_hcp_status="INFO"
                rmo_hcp_message="No HostedControlPlane resources on this MC"
                echo "  ℹ No HCPs on this MC"
            fi
        else
            rmo_hcp_status="WARNING"
            rmo_hcp_message="HostedControlPlane CRD not accessible on this MC — MC infrastructure issue (backplane RBAC or HCP operator), not an RMO problem"
            warning_count=$((warning_count + 1))
            echo "  ⚠ HCP CRD not accessible (MC infrastructure issue, not RMO)"
        fi

        health_checks+=("$(cat <<EOF
{
  "check": "rmo_hcp_coverage",
  "status": "$rmo_hcp_status",
  "severity": "warning",
  "message": "$rmo_hcp_message",
  "details": {
    "hcp_total": $hcp_count,
    "hcp_expected": $hcp_expected,
    "hcp_monitored": $hcp_monitored,
    "hcp_unmonitored": $hcp_unmonitored,
    "hcp_not_ready": $hcp_not_ready,
    "hcp_deleting": $hcp_deleting,
    "orphaned_monitors": $hcp_stale,
    "cleanup_pending": $hcp_orphaned,
    "monitors_with_errors": ${rm_with_errors:-0},
    "unmonitored_hcps": "$(echo "${hcp_unmonitored_names:-none}" | sed 's/"/\\"/g')"
  }
}
EOF
)")
    else
        # Non-MC cluster — HCP coverage not applicable
        health_checks+=("$(cat <<EOF
{
  "check": "rmo_hcp_coverage",
  "status": "SKIP",
  "severity": "info",
  "message": "HCP coverage check not applicable (${cluster_type} cluster — only runs on management_cluster)",
  "details": {
    "cluster_type": "$cluster_type"
  }
}
EOF
)")
    fi

    # RMO Check 9: RHOBS synthetics integration
    # RHOBS is enabled when HCP CRD exists or probe-api-url is configured (not limited to MC/SC)
    {
        rmo_rhobs_status="PASS"
        rmo_rhobs_message=""
        rmo_rhobs_enabled=false
        rmo_oidc_configured=false
        rmo_oidc_refresh_success=0
        rmo_oidc_refresh_errors=0

        # Check if RHOBS is enabled via env vars on the controller-manager
        if [ -n "$rmo_cm_pods" ] && [ "$rmo_cm_pod_count" -gt 0 ]; then
            probe_api=$(echo "$rmo_cm_pods" | jq -r '.items[0].spec.containers[] | select(.name == "manager") | .env[] | select(.name == "PROBE_API_URL") | .value // empty' 2>/dev/null)
            oidc_client=$(echo "$rmo_cm_pods" | jq -r '.items[0].spec.containers[] | select(.name == "manager") | .env[] | select(.name == "OIDC_CLIENT_ID") | .value // empty' 2>/dev/null)

            if [ -n "$probe_api" ] && [ "$probe_api" != "" ]; then
                rmo_rhobs_enabled=true
                echo "  ✓ RHOBS synthetics enabled (probe API configured)"
            fi
            if [ -n "$oidc_client" ] && [ "$oidc_client" != "" ]; then
                rmo_oidc_configured=true
                echo "  ✓ OIDC authentication configured"
            fi

            # Also check ConfigMap for probe-api-url
            if [ "$rmo_rhobs_enabled" = false ] && [ -n "$rmo_probe_api_url" ]; then
                rmo_rhobs_enabled=true
                echo "  ✓ RHOBS synthetics enabled (via ConfigMap)"
            fi
        fi

        if [ "$rmo_rhobs_enabled" = true ]; then
            # Check OIDC token refresh metrics
            oidc_data=$(query_rmo_metric "rhobs_route_monitor_operator_oidc_token_refresh_total")
            if [ -n "$oidc_data" ] && echo "$oidc_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
                rmo_oidc_refresh_success=$(echo "$oidc_data" | jq -r '[.data.result[] | select(.metric.status == "success") | .value[1] | tonumber] | add // 0' 2>/dev/null || echo "0")
                rmo_oidc_refresh_errors=$(echo "$oidc_data" | jq -r '[.data.result[] | select(.metric.status == "error") | .value[1] | tonumber] | add // 0' 2>/dev/null || echo "0")
                rmo_oidc_refresh_success=$(echo "$rmo_oidc_refresh_success" | tr -d '[:space:]')
                rmo_oidc_refresh_errors=$(echo "$rmo_oidc_refresh_errors" | tr -d '[:space:]')
                [ -z "$rmo_oidc_refresh_success" ] && rmo_oidc_refresh_success=0
                [ -z "$rmo_oidc_refresh_errors" ] && rmo_oidc_refresh_errors=0
            fi

            if [ "$rmo_oidc_refresh_errors" -gt 0 ] 2>/dev/null && [ "$rmo_oidc_refresh_success" -eq 0 ] 2>/dev/null; then
                rmo_rhobs_status="WARNING"
                rmo_rhobs_message="OIDC token refresh failing ($rmo_oidc_refresh_errors errors, 0 success)"
                warning_count=$((warning_count + 1))
                echo "  ⚠ OIDC token refresh failing"
            elif [ "$rmo_rhobs_enabled" = true ] && [ "$rmo_oidc_configured" = false ]; then
                rmo_rhobs_status="WARNING"
                rmo_rhobs_message="RHOBS enabled but OIDC not configured"
                warning_count=$((warning_count + 1))
                echo "  ⚠ RHOBS enabled without OIDC"
            else
                rmo_rhobs_message="RHOBS synthetics healthy"
                echo "  ✓ RHOBS synthetics healthy"
            fi
        else
            rmo_rhobs_status="INFO"
            if [ "$cluster_type" = "management_cluster" ] || [ "$cluster_type" = "service_cluster" ]; then
                rmo_rhobs_message="RHOBS synthetics not configured on this $cluster_type (probe-api-url not set — may need configuration)"
                echo "  ℹ RHOBS not configured on $cluster_type (probe-api-url not set)"
            else
                rmo_rhobs_message="RHOBS synthetics not applicable (standard cluster, no HCP workloads)"
                echo "  ℹ RHOBS not applicable (standard cluster)"
            fi
        fi

        health_checks+=("$(cat <<EOF
{
  "check": "rmo_rhobs_integration",
  "status": "$rmo_rhobs_status",
  "severity": "warning",
  "message": "$rmo_rhobs_message",
  "details": {
    "rhobs_enabled": $rmo_rhobs_enabled,
    "oidc_configured": $rmo_oidc_configured,
    "oidc_refresh_success": $rmo_oidc_refresh_success,
    "oidc_refresh_errors": $rmo_oidc_refresh_errors,
    "cluster_type": "$cluster_type"
  }
}
EOF
)")
    }

fi

echo ""

fi  # End of namespace-dependent checks (opened after CHECK 0)

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
# Use deployment's own label selector to find ReplicaSets
replicasets=$(oc get replicasets -n "$NAMESPACE" \
    -l "${pod_selector:-name=$DEPLOYMENT}" \
    -o json 2>/dev/null || echo '{"items":[]}')

# Fallback: try owner-based lookup if label selector found nothing
rs_count=$(echo "$replicasets" | jq '.items | length' 2>/dev/null || echo "0")
if [ "$rs_count" -eq 0 ]; then
    replicasets=$(oc get replicasets -n "$NAMESPACE" -o json 2>/dev/null | \
        jq "{items: [.items[] | select(.metadata.ownerReferences[]? | select(.name == \"$DEPLOYMENT\"))]}" 2>/dev/null || echo '{"items":[]}')
fi

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
       replicas: (.status.replicas // 0)
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
  "script_version": "$SCRIPT_VERSION",
  "cluster_id": "${health_data[cluster_id]}",
  "cluster_name": "${health_data[cluster_name]}",
  "cluster_type": "${health_data[cluster_type]}",
  "hive_shard": "${health_data[hive_shard]}",
  "cluster_version": "${health_data[cluster_version]}",
  "operator_name": "${health_data[operator_name]}",
  "operator_version": "${health_data[operator_version]}",
  "operator_image": "${health_data[operator_image]}",
  "namespace": "${health_data[namespace]}",
  "deployment": "${health_data[deployment]}",
  "timestamp": "${health_data[timestamp]}",
  "cluster_metadata": $CLUSTER_METADATA,
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
