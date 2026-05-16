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
SCRIPT_VERSION="aae2e8d"

# Default values
NAMESPACE="openshift-monitoring"
DEPLOYMENT="configure-alertmanager-operator"
OUTPUT_FORMAT="json"  # only JSON output is supported
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
    local _psef
    _psef=$(mktemp)
    provision_shard=$(ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/provision_shard" 2>"$_psef")
    local _psrc=$?
    if [ $_psrc -ne 0 ]; then
        local _pserr=$(head -1 "$_psef")
        log_api_error "Get provision shard for $cluster_id" "${_pserr:-unknown error}" "$_psrc"
    fi
    rm -f "$_psef"

    if [ $_psrc -ne 0 ] || [ -z "$provision_shard" ]; then
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
        --format|-f) shift 2 ;; # ignored, JSON is the only output format
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

# Current check context — set before each check section so errors know which check they belong to
CURRENT_CHECK=""

# Function to log API errors
log_api_error() {
    local operation="$1"
    local error_message="$2"
    local exit_code="${3:-1}"
    local command="${4:-}"

    debug_log "API Error: $operation - $error_message (exit code: $exit_code)"

    # Escape values for JSON
    local escaped_operation=$(echo "$operation" | jq -Rs . 2>/dev/null || echo "\"unknown\"")
    local escaped_error=$(echo "$error_message" | jq -Rs . 2>/dev/null || echo "\"API error\"")
    local escaped_command=$(echo "$command" | jq -Rs . 2>/dev/null || echo "\"\"")

    # Classify error type: api_error (server response) vs script_error (local tooling/bash)
    local error_type="api_error"
    local err_lower=$(echo "$error_message" | tr '[:upper:]' '[:lower:]')
    if echo "$err_lower" | grep -qE 'command not found|no such file|permission denied|syntax error|unbound variable|bad substitution'; then
        error_type="script_error"
    elif echo "$err_lower" | grep -qE 'forbidden|unauthorized|not found|error from server|cannot|denied'; then
        error_type="api_error"
    elif [ "$exit_code" -eq 126 ] || [ "$exit_code" -eq 127 ]; then
        error_type="script_error"
    fi

    local error_entry=$(cat <<EOF
{
  "operation": $escaped_operation,
  "error_message": $escaped_error,
  "command": $escaped_command,
  "check": "${CURRENT_CHECK:-unknown}",
  "error_type": "$error_type",
  "exit_code": $exit_code,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)
    api_errors+=("$error_entry")
    debug_log "Added API error entry #${#api_errors[@]} (check: ${CURRENT_CHECK:-unknown})"
}

# Run an oc/ocm command with error capture and reporting.
# Sets global variables instead of using subshell capture, so api_errors is updated.
#   __oc_out  — stdout of the command (empty on failure)
#   __oc_rc   — exit code
#   __oc_err  — first line of stderr (empty on success)
# Usage:
#   _run_oc "Get RouteMonitor CRs" ocm backplane elevate "$REASON" -- get routemonitor -A -o json
#   routemonitors="$__oc_out"
#   if [ $__oc_rc -ne 0 ]; then echo "FAILED: $__oc_err"; fi
_run_oc() {
    local _desc="$1"
    shift
    local _cmd="$*"
    local _ef
    _ef=$(mktemp)
    __oc_out=$("$@" 2>"$_ef")
    __oc_rc=$?
    if [ $__oc_rc -ne 0 ]; then
        __oc_err=$(head -1 "$_ef")
        rm -f "$_ef"
        log_api_error "$_desc" "$__oc_err" "$__oc_rc" "$_cmd"
        __oc_out=""
        return $__oc_rc
    fi
    __oc_err=""
    rm -f "$_ef"
    return 0
}

# Like _run_oc but treats "not found" as an expected result, not an error.
# Use for existence checks where absence is a valid outcome (e.g., OLM subscription on PKO cluster).
# Still sets __oc_out/__oc_rc/__oc_err; only logs to api_errors if error is NOT "not found".
_run_oc_optional() {
    local _desc="$1"
    shift
    local _cmd="$*"
    local _ef
    _ef=$(mktemp)
    __oc_out=$("$@" 2>"$_ef")
    __oc_rc=$?
    if [ $__oc_rc -ne 0 ]; then
        __oc_err=$(head -1 "$_ef")
        rm -f "$_ef"
        if ! echo "$__oc_err" | grep -qi "not found"; then
            log_api_error "$_desc" "$__oc_err" "$__oc_rc" "$_cmd"
        fi
        __oc_out=""
        return $__oc_rc
    fi
    __oc_err=""
    rm -f "$_ef"
    return 0
}

# Auto-detect cluster ID if not provided
if [ -z "$CLUSTER_ID" ]; then
    _run_oc "Get cluster ID from clusterversion" oc get clusterversion version -o jsonpath='{.spec.clusterID}'
    CLUSTER_ID="${__oc_out:-unknown}"
fi
debug_var CLUSTER_ID

# Auto-detect cluster name if not provided
if [ -z "$CLUSTER_NAME" ]; then
    _run_oc "Get cluster name from backplane status" ocm backplane status
    CLUSTER_NAME=$(echo "$__oc_out" | grep "Cluster Name:" | awk '{print $3}')
    if [ -z "$CLUSTER_NAME" ]; then
        _run_oc "Get cluster name from OCM API" ocm get cluster "$CLUSTER_ID"
        CLUSTER_NAME=$(echo "$__oc_out" | jq -r '.name // "unknown"' 2>/dev/null || echo "unknown")
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
    _run_oc "Get cluster data from OCM" ocm get cluster "$cluster_id"
    local cluster_data="$__oc_out"

    if [ -z "$cluster_data" ]; then
        echo "{}"
        return
    fi

    # Query provision_shard separately (not in main cluster object)
    _run_oc "Get provision shard for $cluster_id" ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/provision_shard"
    local provision_shard="$__oc_out"
    local shard_url
    shard_url=$(echo "$provision_shard" | jq -r '.hive_config.server // "unknown"' 2>/dev/null || echo "unknown")

    # Query limited support reasons if cluster is in limited support
    local limited_support_count
    limited_support_count=$(echo "$cluster_data" | jq -r '.status.limited_support_reason_count // 0')
    local limited_support_reasons="[]"
    if [ "$limited_support_count" -gt 0 ]; then
        _run_oc "Get limited support reasons for $cluster_id" ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/limited_support_reasons"
        limited_support_reasons=$(echo "$__oc_out" | jq '[.items[] | {summary: .summary, details: .details, created: .creation_timestamp}]' 2>/dev/null || echo "[]")
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
    _run_oc "Get cluster version" oc get clusterversion version -o jsonpath='{.status.desired.version}'
    cluster_version="${__oc_out:-unknown}"
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
    _run_oc "Get operator image from ClusterPackage" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.spec.config.image}'
    operator_image="$__oc_out"
    if [ -n "$operator_image" ]; then
        echo "  ✓ Recovered image from ClusterPackage: $operator_image"
    else
        # Last resort: try with elevation
        _run_oc "Get deployment with elevation" ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json
        operator_image=$(echo "$__oc_out" | jq -r '.spec.template.spec.containers[0].image // ""' 2>/dev/null)
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
    _run_oc "Get ClusterPackage version" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.spec.config.version}'
    pkg_version="$__oc_out"
    _run_oc "Get ClusterPackage image" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.spec.config.image}'
    pkg_image="$__oc_out"
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
        _run_oc "Version detection: read git commit from image labels (skopeo inspect $operator_image)" skopeo inspect --no-tags "docker://$operator_image"
        image_labels=$(echo "$__oc_out" | jq -r '.Labels // {}' 2>/dev/null)

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
        _run_oc "Get deployment annotations" oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json
        deployment_annotations=$(echo "$__oc_out" | jq -r '.metadata.annotations // {}' 2>/dev/null)

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
        _run_oc "Get ClusterPackage Available message (version fallback)" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Available")].message}'
        pkg_image=$(echo "$__oc_out" | grep -oE '[a-f0-9]{7,12}' | head -1)
        if [ -z "$pkg_image" ]; then
            # Try getting image directly from the running pod
            _run_oc "Get pod image (version fallback)" oc get pods -n "$NAMESPACE" -l "${pod_selector:-name=$DEPLOYMENT}" -o jsonpath='{.items[0].spec.containers[0].image}'
            pod_image="$__oc_out"
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
CURRENT_CHECK="namespace_status"
echo "CHECK 0: Namespace Status"
echo "================================================================================"

namespace_check_status="PASS"
namespace_message=""
_run_oc "Get namespace $NAMESPACE phase" oc get namespace "$NAMESPACE" -o jsonpath='{.status.phase}'
namespace_phase="$__oc_out"
namespace_exit=$__oc_rc

if [ $namespace_exit -ne 0 ] || [ -z "$namespace_phase" ]; then
    namespace_check_status="FAIL"
    namespace_message="Namespace $NAMESPACE does not exist${__oc_err:+ (error: $__oc_err)}"
    critical_count=$((critical_count + 1))
    echo "  ✗ CRITICAL: Namespace $NAMESPACE not found${__oc_err:+ (error: $__oc_err)}"
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
CURRENT_CHECK="version_verification"
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
                    _run_oc "Fetch SAAS file from app-interface" curl -s "https://gitlab.cee.redhat.com/service/app-interface/-/raw/master/data/services/osd-operators/cicd/saas/${SAAS_FILE}?ref_type=heads"
                    github_repo_url=$(echo "$__oc_out" | yq -r ".resourceTemplates[] | select(.name | test(\"${OPERATOR_NAME}\")) | .url" 2>/dev/null)

                    if [ -n "$github_repo_url" ]; then
                        # Extract owner/repo from GitHub URL
                        github_repo=$(echo "$github_repo_url" | sed -E 's|https://github.com/||' | sed 's|\.git$||')

                        # Query GitHub API for current HEAD of the branch
                        _run_oc "Get branch HEAD from GitHub API" curl -s "https://api.github.com/repos/${github_repo}/commits/${ref}"
                        branch_head=$(echo "$__oc_out" | jq -r '.sha' 2>/dev/null)

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
            _run_oc "Version check: resolve deployed image tag to SHA digest (skopeo)" skopeo inspect --no-tags "docker://${operator_image}"
            resolved_sha=$(echo "$__oc_out" | jq -r '.Digest // empty' 2>/dev/null)
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
        _run_oc "Version check: compare deployed image SHA against staging tag '${canonical_image_tag}' in quay.io/app-sre/${OPERATOR_NAME}" skopeo inspect --no-tags "docker://quay.io/app-sre/${OPERATOR_NAME}:${canonical_image_tag}"
        staging_image_sha=$(echo "$__oc_out" | jq -r '.Digest' 2>/dev/null)

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
CURRENT_CHECK="pod_status_and_restarts"
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
    _run_oc "Get deployment creation timestamp" oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.metadata.creationTimestamp}'
    deploy_created="$__oc_out"

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
CURRENT_CHECK="leader_election"
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
_run_oc "Get lease $NAMESPACE/$lease_name" oc get lease -n "$NAMESPACE" "$lease_name" -o json
lease_json="$__oc_out"

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
CURRENT_CHECK="resource_leak_detection"
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
        # Probe timeseries: per-endpoint success rate and latency
        # Returns separate timeseries per probe (api, console) instead of avg()
        # probe_timeseries format: [{label: "api|console", values: [[ts, val], ...]}, ...]
        probe_timeseries="[]"
        probe_duration_timeseries="[]"
        probe_target_count=0
        probe_target_names=""
        if [[ "$OPERATOR_NAME" == *"route-monitor"* ]]; then
            # Per-probe success rate over time (each probe gets its own line)
            probe_query="probe_success{namespace=\"openshift-route-monitor-operator\"}"
            probe_query_encoded=$(printf '%s' "$probe_query" | jq -sRr @uri)
            probe_ts_err=$(mktemp)
            probe_ts_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
                wget -q -T 30 -O- "http://localhost:9090/api/v1/query_range?query=${probe_query_encoded}&start=${start_time}&end=${end_time}&step=${query_step}" 2>"$probe_ts_err")
            if [ $? -ne 0 ]; then
                probe_ts_err_msg=$(head -1 "$probe_ts_err")
                query_errors="${query_errors}probe success query failed${probe_ts_err_msg:+ ($probe_ts_err_msg)}, "
                log_api_error "Local probe success rate query" "${probe_ts_err_msg:-timeout or connection error}" "$?"
                echo "  ⚠ Probe success query failed: ${probe_ts_err_msg:-timeout or connection error}"
            elif [ -n "$probe_ts_data" ] && echo "$probe_ts_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
                # Extract per-probe timeseries with labels derived from probe_url
                probe_timeseries=$(echo "$probe_ts_data" | jq -c '[.data.result[] | {
                    label: (if .metric.probe_url then
                        (if (.metric.probe_url | test("console")) then "console"
                         elif (.metric.probe_url | test("api|livez")) then "api"
                         else (.metric.probe_url | split("/")[-1] // "unknown") end)
                    else "probe-" + (.metric.instance // "unknown") end),
                    probe_url: (.metric.probe_url // ""),
                    values: .values
                }]' 2>/dev/null || echo "[]")
                probe_target_count=$(echo "$probe_ts_data" | jq '.data.result | length' 2>/dev/null | tr -d '[:space:]')
                probe_target_names=$(echo "$probe_ts_data" | jq -r '[.data.result[] | if .metric.probe_url then (if (.metric.probe_url | test("console")) then "console" elif (.metric.probe_url | test("api|livez")) then "api" else .metric.probe_url end) else "unknown" end] | join(", ")' 2>/dev/null)
                echo "  Probe success: $probe_target_count endpoint(s): $probe_target_names"
            else
                echo "  ℹ Probe success: no data returned (probes may not be active)"
            fi
            rm -f "$probe_ts_err"

            # Per-probe duration (latency) over time
            duration_query="probe_duration_seconds{namespace=\"openshift-route-monitor-operator\"}"
            duration_query_encoded=$(printf '%s' "$duration_query" | jq -sRr @uri)
            duration_ts_err=$(mktemp)
            duration_ts_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
                wget -q -T 30 -O- "http://localhost:9090/api/v1/query_range?query=${duration_query_encoded}&start=${start_time}&end=${end_time}&step=${query_step}" 2>"$duration_ts_err")
            if [ $? -ne 0 ]; then
                dur_err_msg=$(head -1 "$duration_ts_err")
                query_errors="${query_errors}probe duration query failed${dur_err_msg:+ ($dur_err_msg)}, "
                log_api_error "Local probe duration query" "${dur_err_msg:-timeout or connection error}" "$?"
                echo "  ⚠ Probe duration query failed: ${dur_err_msg:-timeout or connection error}"
            elif [ -n "$duration_ts_data" ] && echo "$duration_ts_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
                probe_duration_timeseries=$(echo "$duration_ts_data" | jq -c '[.data.result[] | {
                    label: (if .metric.probe_url then
                        (if (.metric.probe_url | test("console")) then "console"
                         elif (.metric.probe_url | test("api|livez")) then "api"
                         else (.metric.probe_url | split("/")[-1] // "unknown") end)
                    else "probe-" + (.metric.instance // "unknown") end),
                    probe_url: (.metric.probe_url // ""),
                    values: .values
                }]' 2>/dev/null || echo "[]")
                echo "  Probe duration: $(echo "$duration_ts_data" | jq '.data.result | length' 2>/dev/null | tr -d '[:space:]') endpoint(s)"
            else
                echo "  ℹ Probe duration: no data returned"
            fi
            rm -f "$duration_ts_err"
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

                # Evaluate memory trend — only flag if percentage increase AND absolute value is meaningful
                # A 50% increase from 10MB to 15MB is normal startup, not a leak
                last_memory_mb_val=$(awk "BEGIN {printf \"%.1f\", ${last_memory:-0} / 1048576}")
                if (( $(echo "$memory_increase_percent > $MEMORY_LEAK_THRESHOLD_PERCENT && $last_memory_mb_val > 20.0" | bc -l) )); then
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

                # Evaluate CPU trend — only flag if percentage increase AND absolute value is meaningful
                # A 1000% increase from 0.0001 to 0.001 cores (0.1m to 1m) is noise, not a leak
                last_cpu_mc_val=$(awk "BEGIN {printf \"%.1f\", ${last_cpu:-0} * 1000}")
                if (( $(echo "$cpu_increase_percent > $MEMORY_LEAK_THRESHOLD_PERCENT && $last_cpu_mc_val > 1.0" | bc -l) )); then
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
CURRENT_CHECK="resource_limits_validation"
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
    _run_oc "Get deployment resource limits" oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].resources}'
    resource_json="$__oc_out"

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
CURRENT_CHECK="log_error_analysis"
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
        _run_oc "Get logs for pod $pod_name" oc logs -n "$NAMESPACE" "$pod_name" --tail=500
        logs="$__oc_out"

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
CURRENT_CHECK="operator_specific"
echo "CHECK 5: Operator-Specific Health"
echo "================================================================================"

# CAMO-specific checks
if [[ "$OPERATOR_NAME" == *"configure-alertmanager"* ]]; then
    echo "Running CAMO-specific health checks..."

    CURRENT_CHECK="alertmanager_pods"
    # Check 1: Alertmanager pods status and restarts
    _run_oc "Get AlertManager pods" oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=alertmanager" -o json
    alertmanager_pods="$__oc_out"
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
        _run_oc "Get CAMO operator pods" oc get pods -n "$NAMESPACE" -l "app=$DEPLOYMENT" -o json
        camo_pods="$__oc_out"
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

    CURRENT_CHECK="alertmanager_statefulset"
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

    CURRENT_CHECK="controller_availability"
    # Check 3: Operator controller availability
    _run_oc "Get deployment Available condition" oc get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
    controller_available="$__oc_out"
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

    CURRENT_CHECK="reconciliation_activity"
    # Check 4: Recent reconciliation activity with resource change validation
    # Get recent reconciliation log count
    _run_oc "Get recent CAMO logs (5m)" oc logs -n "$NAMESPACE" "deployment/$DEPLOYMENT" --since=5m --tail=10
    recent_logs=$(echo "$__oc_out" | wc -l | tr -d ' ')

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
    # Requires elevation — cluster-wide secret listing is RBAC-restricted
    secret_changes_count=0
    reconciliation_query_errors=""
    _run_oc "Get secrets (all namespaces, elevated)" ocm backplane elevate "${REASON}" -- get secrets --all-namespaces -o json
    secrets_data="$__oc_out"
    if [ $__oc_rc -ne 0 ]; then
        reconciliation_query_errors="${reconciliation_query_errors}secrets query failed (${__oc_err}); "
    elif [ -n "$secrets_data" ]; then
        secret_changes_count=$(echo "$secrets_data" | jq "[.items[] | select(
            (.metadata.creationTimestamp > \"$lookback_timestamp\") or
            ([.metadata.managedFields[]?.time // \"\" | select(. > \"$lookback_timestamp\")] | length > 0)
        )] | length" 2>/dev/null || echo "0")
    fi

    # Count recent configmap changes across all namespaces (CAMO watches configmaps cluster-wide)
    configmap_changes_count=0
    _run_oc "Get configmaps (all namespaces, elevated)" ocm backplane elevate "${REASON}" -- get configmaps --all-namespaces -o json
    configmaps_data="$__oc_out"
    if [ $__oc_rc -ne 0 ]; then
        reconciliation_query_errors="${reconciliation_query_errors}configmaps query failed (${__oc_err}); "
    elif [ -n "$configmaps_data" ]; then
        configmap_changes_count=$(echo "$configmaps_data" | jq "[.items[] | select(
            (.metadata.creationTimestamp > \"$lookback_timestamp\") or
            ([.metadata.managedFields[]?.time // \"\" | select(. > \"$lookback_timestamp\")] | length > 0)
        )] | length" 2>/dev/null || echo "0")
    fi

    # Check for recent ClusterVersion changes (CAMO watches for upgrades)
    clusterversion_changes_count=0
    _run_oc "Get clusterversion" oc get clusterversion version -o json
    clusterversion_data="$__oc_out"
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

    if [ -n "$reconciliation_query_errors" ]; then
        reconciliation_status="WARNING"
        reconciliation_message="Cannot fully assess reconciliation — query errors: ${reconciliation_query_errors%. }"
        warning_count=$((warning_count + 1))
        echo "  ⚠ Incomplete data: ${reconciliation_query_errors%. }"
    elif [ "$recent_logs" -gt 0 ]; then
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
    "total_resource_changes": $total_resource_changes,
    "query_errors": "$(echo "${reconciliation_query_errors:-}" | sed 's/"/\\"/g')"
  }
}
EOF
)")

    CURRENT_CHECK="configuration_errors"
    # Check 5: Configuration errors in operator logs
    _run_oc "Get CAMO logs (last 100 lines)" oc logs -n "$NAMESPACE" "deployment/$DEPLOYMENT" --tail=100
    config_errors=$(echo "$__oc_out" | grep -iE "failed|error|invalid.*config" | grep -v "level=info" | wc -l)
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

    CURRENT_CHECK="prometheus_metrics"
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

        local _qef
        _qef=$(mktemp)
        local data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
            wget -q -T 30 -O- "http://localhost:9090/api/v1/query?query=${query_encoded}" 2>"$_qef")
        local _qrc=$?
        if [ $_qrc -ne 0 ]; then
            local _qerr=$(head -1 "$_qef")
            log_api_error "Prometheus query: $metric_name" "${_qerr:-timeout or connection error}" "$_qrc"
            echo "  ⚠ $metric_name query failed: ${_qerr:-timeout or connection error}" >&2
        fi
        rm -f "$_qef"

        if [ $_qrc -eq 0 ] && [ -n "$data" ] && echo "$data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
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

    CURRENT_CHECK="reconciliation_behavior"
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

    CURRENT_CHECK="alertmanager_logs"
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
                _run_oc "Get AlertManager logs for $am_pod (since pod start)" oc logs -n "$NAMESPACE" "$am_pod" --since-time="$pod_start_time"
            else
                _run_oc "Get AlertManager logs for $am_pod (tail 1000)" oc logs -n "$NAMESPACE" "$am_pod" --tail=1000
            fi
            pod_logs="$__oc_out"

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

    CURRENT_CHECK="alertmanager_events"
    # Check 9: AlertManager Pod Events
    echo "  Checking AlertManager pod events..."

    alertmanager_events_status="PASS"
    alertmanager_events_message="No warning or error events"
    alertmanager_warning_events=0
    alertmanager_error_events=0
    alertmanager_events_json="[]"

    if [ -n "$alertmanager_pod_names" ]; then
        for am_pod in $alertmanager_pod_names; do
            _run_oc "Get events for pod $am_pod" oc get events -n "$NAMESPACE" --field-selector involvedObject.name="$am_pod" -o json
            pod_events="$__oc_out"

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

    CURRENT_CHECK="camo_events"
    # Check 10: CAMO Deployment Events
    echo "  Checking CAMO deployment events..."

    camo_events_status="PASS"
    camo_events_message="No warning or error events"
    camo_warning_events=0
    camo_events_json="[]"

    _run_oc "Get events for deployment $DEPLOYMENT" oc get events -n "$NAMESPACE" --field-selector involvedObject.name="$DEPLOYMENT" -o json
    camo_events="$__oc_out"

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

    CURRENT_CHECK="olm_subscription_health"
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
    _run_oc_optional "Check OLM subscription $PACKAGE_NAME" oc get subscription.operators.coreos.com "$PACKAGE_NAME" -n "$NAMESPACE"
    subscription_check="$__oc_out"

    if [ $__oc_rc -eq 0 ] && [ -n "$subscription_check" ]; then
        subscription_exists="true"
        echo "  ✓ Subscription exists (OLM installation detected)"

        # Check for ResolutionFailed status
        _run_oc "Get subscription ResolutionFailed condition" oc get subscription.operators.coreos.com "$PACKAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].status}'
        resolution_failed_status="$__oc_out"

        if [ "$resolution_failed_status" = "True" ]; then
            resolution_failed="true"
            _run_oc "Get subscription ResolutionFailed message" oc get subscription.operators.coreos.com "$PACKAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].message}'
            resolution_failed_message=$(echo "$__oc_out" | head -c 500)

            echo "  ✗ CRITICAL: Subscription has ResolutionFailed=True"
            echo "    Error: ${resolution_failed_message:0:100}..."

            # Check for orphaned CSVs (CSVs without ownerReferences)
            _run_oc "Get CSVs in $NAMESPACE" oc get csv.operators.coreos.com -n "$NAMESPACE" -o json
            csvs=$(echo "$__oc_out" | jq -r ".items[] | select(.metadata.name | contains(\"$DEPLOYMENT\"))" 2>/dev/null)

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

    CURRENT_CHECK="pko_clusterpackage_health"
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
    _run_oc_optional "Check ClusterPackage $PACKAGE_NAME" oc get clusterpackage "$PACKAGE_NAME"
    cluster_package_check="$__oc_out"
    cluster_package_check_rc=$__oc_rc

    if [ $cluster_package_check_rc -eq 0 ] && [ -n "$cluster_package_check" ]; then
        cluster_package_exists="true"
        echo "  ✓ ClusterPackage exists (PKO installation detected)"

        # Get ClusterPackage status conditions (PKO uses Available/Progressing/Unpacked, not Ready/Phase)
        _run_oc "Get ClusterPackage Available condition" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
        cluster_package_available="${__oc_out:-unknown}"
        _run_oc "Get ClusterPackage Progressing condition" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}'
        cluster_package_progressing="${__oc_out:-unknown}"
        _run_oc "Get ClusterPackage Unpacked condition" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Unpacked")].status}'
        cluster_package_unpacked="${__oc_out:-unknown}"

        # Get all conditions
        _run_oc "Get ClusterPackage conditions JSON" oc get clusterpackage "$PACKAGE_NAME" -o json
        cluster_package_conditions=$(echo "$__oc_out" | jq -c '.status.conditions // []' 2>/dev/null || echo "[]")

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
                _run_oc "Get ClusterPackage Available message" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Available")].message}'
                failure_reason=$(echo "$__oc_out" | head -c 200)
                pko_package_status="FAIL"
                pko_package_message="PKO ClusterPackage not available: $failure_reason"
                critical_count=$((critical_count + 1))
                echo "  ✗ CRITICAL: PKO ClusterPackage not available"
                echo "    Available: $cluster_package_available"
                echo "    Reason: ${failure_reason:0:100}..."
            elif [ "$cluster_package_progressing" = "True" ]; then
                _run_oc "Get ClusterPackage Progressing message" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}'
                progressing_msg="$__oc_out"
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
                _run_oc "Get ClusterPackage Unpacked message" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Unpacked")].message}'
                unpack_reason=$(echo "$__oc_out" | head -c 200)
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
            _run_oc "Get CSVs in $NAMESPACE (leftover check)" oc get csv -n "$NAMESPACE" -o json
            leftover_csvs=$(echo "$__oc_out" | jq -r "[.items[] | select(.metadata.name | test(\"$DEPLOYMENT\"))] | length" 2>/dev/null || echo "0")
            if [ "$leftover_csvs" -gt 0 ]; then
                leftover_csv_names=$(echo "$__oc_out" | jq -r "[.items[] | select(.metadata.name | test(\"$DEPLOYMENT\")) | .metadata.name]" 2>/dev/null || echo "[]")
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
    "revision": $(if [ "$cluster_package_exists" = "true" ]; then _run_oc "Get ClusterPackage revision" oc get clusterpackage "$PACKAGE_NAME" -o jsonpath='{.status.revision}'; echo "${__oc_out:-0}"; else echo "0"; fi),
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

    _run_oc "Get jobs in $NAMESPACE" oc get jobs -n "$NAMESPACE" -o json
    jobs_json="$__oc_out"
    if [ -n "$jobs_json" ]; then
        olm_cleanup_jobs=$(echo "$jobs_json" | jq '[.items[] | select(.metadata.name | startswith("olm-cleanup"))]' 2>/dev/null)
        stale_job_count=$(echo "$olm_cleanup_jobs" | jq 'length' 2>/dev/null || echo "0")

        if [ "$stale_job_count" -gt 0 ]; then
            current_epoch=$(date +%s)
            hung_jobs=$(echo "$olm_cleanup_jobs" | jq --argjson now "$current_epoch" '[.[] | select(.status.active > 0) | select(($now - (.metadata.creationTimestamp | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) > 300)] | length' 2>/dev/null || echo "0")
            failed_jobs=$(echo "$olm_cleanup_jobs" | jq '[.[] | select(.status.failed > 0)] | length' 2>/dev/null || echo "0")

            echo "  OLM cleanup jobs: $stale_job_count total, $hung_jobs hung, $failed_jobs failed"

            # Check for orphaned pods
            _run_oc "Get pods in $NAMESPACE for orphan check" oc get pods -n "$NAMESPACE" -o json
            orphaned_pods=$(echo "$__oc_out" | jq '[.items[] | select(.metadata.name | startswith("olm-cleanup")) | select(.status.phase == "Running") | select(.metadata.ownerReferences == null)] | length' 2>/dev/null || echo "0")

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

    CURRENT_CHECK="image_pull_status"\n    # Check for ImagePullBackOff — indicates SAAS deployed before Konflux build completed
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

    # Check by operator name pattern in CSV/CatalogSource names
    op_name_pattern="${OPERATOR_NAME:-$DEPLOYMENT}"

    orphan_details=""
    if [ "$pko_only" = true ]; then
        # Check for CSVs owned by this operator (by name match — label queries are unreliable due to 63-char limit)
        _run_oc_optional "Get CSVs in $NAMESPACE (orphan check)" oc get csv -n "$NAMESPACE" --no-headers
        op_csvs=$(echo "$__oc_out" | grep -i "$op_name_pattern" || true)
        op_olm_csvs=$(echo "$op_csvs" | grep -c . 2>/dev/null || echo "0")
        op_olm_csvs=$(echo "$op_olm_csvs" | tr -d '[:space:]')

        if [ "${op_olm_csvs:-0}" -gt 0 ]; then
            orphan_csv_names=$(echo "$op_csvs" | awk '{print "'"$NAMESPACE"'/" $1}' | tr '\n' ', ' | sed 's/,$//')
            orphan_details="${orphan_details}${op_olm_csvs} orphaned CSV(s): ${orphan_csv_names}; "
        fi

        # Check for CatalogSources owned by this operator
        _run_oc_optional "Get CatalogSources in $NAMESPACE" oc get catalogsource -n "$NAMESPACE" --no-headers
        op_catsrc=$(echo "$__oc_out" | grep -i "$op_name_pattern" || true)
        op_olm_catsrc=$(echo "$op_catsrc" | grep -c . 2>/dev/null || echo "0")
        op_olm_catsrc=$(echo "$op_olm_catsrc" | tr -d '[:space:]')

        if [ "${op_olm_catsrc:-0}" -gt 0 ]; then
            orphan_catsrc_names=$(echo "$op_catsrc" | awk '{print "'"$NAMESPACE"'/" $1}' | tr '\n' ', ' | sed 's/,$//')
            orphan_details="${orphan_details}${op_olm_catsrc} orphaned CatalogSource(s): ${orphan_catsrc_names}; "
        fi

        # Check for Subscriptions owned by this operator (should not exist on PKO-only)
        _run_oc_optional "Get Subscription $PACKAGE_NAME (orphan check)" oc get subscription.operators.coreos.com "$PACKAGE_NAME" -n "$NAMESPACE" --no-headers
        op_subs="$__oc_out"
        op_olm_subs=$(echo "$op_subs" | grep -c . 2>/dev/null || echo "0")
        op_olm_subs=$(echo "$op_olm_subs" | tr -d '[:space:]')

        if [ "${op_olm_subs:-0}" -gt 0 ]; then
            orphan_sub_names=$(echo "$op_subs" | awk '{print "'"$NAMESPACE"'/" $1}' | tr '\n' ', ' | sed 's/,$//')
            orphan_details="${orphan_details}${op_olm_subs} orphaned Subscription(s): ${orphan_sub_names}; "
        fi
    fi

    if [ -n "$orphan_details" ]; then
        orphan_check_status="FAIL"
        orphan_details="${orphan_details%; }"
        orphan_check_message="PKO-only: orphaned OLM artifacts — OLM-to-PKO migration cleanup incomplete. $orphan_details"
        critical_count=$((critical_count + 1))
        echo "  ✗ CRITICAL: Orphaned OLM artifacts (migration cleanup failed): $orphan_details"
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
  "severity": "critical",
  "message": "$orphan_check_message",
  "details": {
    "pko_only": $pko_only,
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

        CURRENT_CHECK="alertmanager_secret"
        # Check 6: Alertmanager main secret exists (managed by CAMO)
        _run_oc "Get alertmanager-main secret (elevated)" ocm backplane elevate "${REASON}" -- get secret alertmanager-main -n "$NAMESPACE" -o json
        alertmanager_secret="$__oc_out"
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
        _run_oc "Get CAMO ConfigMap" oc get configmap configure-alertmanager-operator-config -n "$NAMESPACE" -o json
        camo_config="$__oc_out"
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
        _run_oc "Get pd-secret (elevated)" ocm backplane elevate "${REASON}" -- get secret pd-secret -n "$NAMESPACE"
        pd_secret="$__oc_out"
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

# RHOBS Prometheus query helper (MC only)
# Execs into the RHOBS hypershift monitoring stack Prometheus to query HCP metrics.
# Returns query result on stdout. Sets __rhobs_rc and __rhobs_err.
# Usage: result=$(query_rhobs_prometheus "description" "promql_query")
query_rhobs_prometheus() {
    local _desc="$1"
    local _query="$2"
    local _qenc=$(printf '%s' "$_query" | jq -sRr @uri)
    local _qerr=$(mktemp)
    local _qout
    _qout=$(ocm backplane elevate "${REASON}" -- exec -n openshift-observability-operator \
        statefulset/prometheus-rhobs-hypershift-monitoring-stack -c prometheus -- \
        curl -sf --max-time 30 "http://localhost:9090/api/v1/query?query=${_qenc}" 2>"$_qerr")
    __rhobs_rc=$?
    if [ $__rhobs_rc -ne 0 ]; then
        __rhobs_err=$(head -1 "$_qerr")
        log_api_error "$_desc" "$__rhobs_err" "$__rhobs_rc" "exec prometheus-rhobs-hypershift-monitoring-stack: query=$_query"
        echo "  ⚠ RHOBS query failed: $_desc: ${__rhobs_err:-timeout}" >&2
        rm -f "$_qerr"
        echo ""
        return $__rhobs_rc
    fi
    __rhobs_err=""
    rm -f "$_qerr"
    if [ -n "$_qout" ] && echo "$_qout" | jq -e '.data.result[0]' >/dev/null 2>&1; then
        echo "$_qout"
    else
        echo ""
    fi
    return 0
}

# Extract a scalar value from a Prometheus instant query result
# Usage: count=$(echo "$result" | prom_scalar)
prom_scalar() {
    jq -r '.data.result[0].value[1] // "0"' 2>/dev/null | tr -d '[:space:]'
}

# RMO-specific checks
if [[ "$OPERATOR_NAME" == *"route-monitor"* ]]; then
    echo "Running RMO-specific health checks..."

    CURRENT_CHECK="rmo_controller_manager"
    # RMO Check 1: Controller-manager pod status
    rmo_cm_status="PASS"
    rmo_cm_message=""
    _run_oc "Get RMO controller-manager pods" oc get pods -n "$NAMESPACE" -l control-plane=controller-manager -o json
    rmo_cm_pods="$__oc_out"
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

    # Query RouteMonitor and ClusterUrlMonitor CRs with elevation (required on managed clusters).
    # Results are shared by the blackbox check (Check 2) and the CR validation check (Check 3).
    _run_oc "Get RouteMonitor CRs (elevated)" ocm backplane elevate "${REASON}" -- get routemonitor -A -o json
    routemonitors="$__oc_out"
    rm_query_error="$__oc_err"
    rm_query_rc=$__oc_rc

    _run_oc "Get ClusterUrlMonitor CRs (elevated)" ocm backplane elevate "${REASON}" -- get clusterurlmonitor -A -o json
    clusterurlmonitors="$__oc_out"
    cum_query_error="$__oc_err"
    cum_query_rc=$__oc_rc

    CURRENT_CHECK="rmo_blackbox_exporter"
    # RMO Check 2: Blackbox exporter health
    # Blackbox is created by RMO on-demand — only exists if RouteMonitors/ClusterUrlMonitors exist
    rmo_bb_status="PASS"
    rmo_bb_message=""
    rmo_bb_desired=0
    rmo_bb_ready=0
    rmo_bb_restarts=0
    rmo_bb_svc_exists=false
    rmo_bb_cm_exists=false
    _run_oc "Get blackbox-exporter deployment" oc get deployment -n "$NAMESPACE" blackbox-exporter -o json
    rmo_bb_deploy="$__oc_out"

    # Check if any monitors exist to determine if blackbox should be present
    has_monitors=false
    monitor_count=0
    cum_count=0
    if [ -n "$routemonitors" ] && echo "$routemonitors" | jq -e '.items' >/dev/null 2>&1; then
        monitor_count=$(echo "$routemonitors" | jq '.items | length' 2>/dev/null | tr -d '[:space:]')
        [ -z "$monitor_count" ] && monitor_count=0
    fi
    if [ -n "$clusterurlmonitors" ] && echo "$clusterurlmonitors" | jq -e '.items' >/dev/null 2>&1; then
        cum_count=$(echo "$clusterurlmonitors" | jq '.items | length' 2>/dev/null | tr -d '[:space:]')
        [ -z "$cum_count" ] && cum_count=0
    fi
    total_monitors=$((monitor_count + cum_count))
    [ "$total_monitors" -gt 0 ] && has_monitors=true

    # If both CR queries failed, report it — cannot determine blackbox necessity
    if [ $rm_query_rc -ne 0 ] && [ $cum_query_rc -ne 0 ]; then
        rmo_bb_status="UNKNOWN"
        rmo_bb_message="Cannot determine monitor count — RouteMonitor query failed: ${rm_query_error}; ClusterUrlMonitor query failed: ${cum_query_error}"
        echo "  ⚠ Cannot query RouteMonitor/ClusterUrlMonitor CRs (RBAC? auth?): ${rm_query_error}"
    fi

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

        _run_oc "Get blackbox-exporter pods" oc get pods -n "$NAMESPACE" -l app=blackbox-exporter -o json
        rmo_bb_pods="$__oc_out"
        rmo_bb_restarts=$(echo "$rmo_bb_pods" | jq '[.items[].status.containerStatuses[]?.restartCount // 0] | add // 0' 2>/dev/null || echo "0")
        rmo_bb_restarts=$(echo "$rmo_bb_restarts" | tr -d '[:space:]')
        [ -z "$rmo_bb_restarts" ] && rmo_bb_restarts=0

        # Check companion resources
        _run_oc "Check blackbox-exporter service" oc get service -n "$NAMESPACE" blackbox-exporter
        [ $__oc_rc -eq 0 ] && rmo_bb_svc_exists=true
        _run_oc "Check blackbox-exporter configmap" oc get configmap -n "$NAMESPACE" blackbox-exporter
        [ $__oc_rc -eq 0 ] && rmo_bb_cm_exists=true

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

    CURRENT_CHECK="rmo_routemonitor_status"
    # RMO Check 3: RouteMonitor and ClusterUrlMonitor — MCC-expected resources
    # Deployment chain:
    #   managed-cluster-config (MCC) → osd-route-monitor-operator SSS → Hive ClusterSync → RouteMonitor CRs
    #   RMO reconciler → ServiceMonitors, PrometheusRules, blackbox-exporter
    # Expected CRs per cluster type (defined in MCC deploy/osd-route-monitor-operator/):
    #   Standard/SC: RouteMonitor "console" (99.5% SLO) + ClusterUrlMonitor "api" (99.0% SLO)
    #   MC: ClusterUrlMonitor "api" (99.0% SLO) + per-HCP RouteMonitors
    rmo_rm_status="PASS"
    rmo_rm_message=""
    rm_count=0
    cum_count_detail=0
    rm_errors=0
    rm_missing_url=0
    rm_missing_sm=0
    console_rm_exists=false
    api_cum_exists=false

    # routemonitors and clusterurlmonitors were already queried with elevation above (before Check 2)
    # rm_query_rc/rm_query_error and cum_query_rc/cum_query_error track query status

    # If CR queries failed, report UNKNOWN — cannot validate what we cannot see
    if [ $rm_query_rc -ne 0 ] && [ $cum_query_rc -ne 0 ]; then
        rmo_rm_status="UNKNOWN"
        rmo_rm_message="Cannot query RouteMonitor/ClusterUrlMonitor CRs — API error (${rm_query_error}). Check RBAC, auth token, or cluster state."
        echo "  ⚠ CANNOT QUERY CRs — all results below are unreliable: ${rm_query_error}"
    fi

    if [ -n "$routemonitors" ] && echo "$routemonitors" | jq -e '.items' >/dev/null 2>&1; then
        rm_count=$(echo "$routemonitors" | jq '.items | length' 2>/dev/null | tr -d '[:space:]')
        [ -z "$rm_count" ] && rm_count=0

        console_check=$(echo "$routemonitors" | jq -r '.items[] | select(.metadata.name == "console" and .metadata.namespace == "openshift-route-monitor-operator")' 2>/dev/null)
        [ -n "$console_check" ] && console_rm_exists=true

        if [ "$rm_count" -gt 0 ]; then
            rm_errors=$(echo "$routemonitors" | jq '[.items[] | select(.status.errorStatus != null and .status.errorStatus != "")] | length' 2>/dev/null | tr -d '[:space:]')
            [ -z "$rm_errors" ] && rm_errors=0
            rm_missing_url=$(echo "$routemonitors" | jq '[.items[] | select(.status.routeURL == null or .status.routeURL == "")] | length' 2>/dev/null | tr -d '[:space:]')
            [ -z "$rm_missing_url" ] && rm_missing_url=0
            rm_missing_sm=$(echo "$routemonitors" | jq '[.items[] | select(.status.serviceMonitorRef.name == null or .status.serviceMonitorRef.name == "")] | length' 2>/dev/null | tr -d '[:space:]')
            [ -z "$rm_missing_sm" ] && rm_missing_sm=0
        fi
    elif [ $rm_query_rc -ne 0 ]; then
        echo "  ⚠ RouteMonitor query failed (rc=$rm_query_rc): $rm_query_error"
    fi

    if [ -n "$clusterurlmonitors" ] && echo "$clusterurlmonitors" | jq -e '.items' >/dev/null 2>&1; then
        cum_count_detail=$(echo "$clusterurlmonitors" | jq '.items | length' 2>/dev/null | tr -d '[:space:]')
        [ -z "$cum_count_detail" ] && cum_count_detail=0

        api_check=$(echo "$clusterurlmonitors" | jq -r '.items[] | select(.metadata.name == "api" and .metadata.namespace == "openshift-route-monitor-operator")' 2>/dev/null)
        [ -n "$api_check" ] && api_cum_exists=true

        if [ "$cum_count_detail" -gt 0 ]; then
            cum_errors=$(echo "$clusterurlmonitors" | jq '[.items[] | select(.status.errorStatus != null and .status.errorStatus != "")] | length' 2>/dev/null | tr -d '[:space:]')
            [ -z "$cum_errors" ] && cum_errors=0
            rm_errors=$((rm_errors + cum_errors))
        fi
    elif [ $cum_query_rc -ne 0 ]; then
        echo "  ⚠ ClusterUrlMonitor query failed (rc=$cum_query_rc): $cum_query_error"
    fi

    total_crd_count=$((rm_count + cum_count_detail))

    # Validate MCC-expected resources per cluster type (only if queries succeeded)
    mcc_issues=""
    if [ "$rmo_rm_status" != "UNKNOWN" ]; then
        if [ "$cluster_type" = "management_cluster" ]; then
            [ "$api_cum_exists" = false ] && mcc_issues="${mcc_issues}ClusterUrlMonitor 'api' missing (expected from MCC osd-route-monitor-operator/management-cluster/), "
        else
            [ "$console_rm_exists" = false ] && mcc_issues="${mcc_issues}RouteMonitor 'console' missing (expected from MCC osd-route-monitor-operator SSS), "
            [ "$api_cum_exists" = false ] && mcc_issues="${mcc_issues}ClusterUrlMonitor 'api' missing (expected from MCC osd-route-monitor-operator SSS), "
        fi
        mcc_issues="${mcc_issues%, }"
    fi

    if [ "$rmo_rm_status" = "UNKNOWN" ]; then
        # Already reported above — skip all downstream validation
        :
    elif [ "$total_crd_count" -eq 0 ]; then
        # Check if CRDs exist (different from CRs missing)
        _run_oc "Check RouteMonitor CRD existence" oc get crd routemonitors.monitoring.openshift.io --no-headers
        rm_crd_exists=$(echo "$__oc_out" | wc -l | tr -d ' ')
        _run_oc "Check ClusterUrlMonitor CRD existence" oc get crd clusterurlmonitors.monitoring.openshift.io --no-headers
        cum_crd_exists=$(echo "$__oc_out" | wc -l | tr -d ' ')

        if [ "${rm_crd_exists:-0}" -eq 0 ] && [ "${cum_crd_exists:-0}" -eq 0 ]; then
            rmo_rm_status="FAIL"
            rmo_rm_message="CRDs not installed — RMO PKO package (deployed via route-monitor-operator-pko SSS) may not have deployed correctly"
            critical_count=$((critical_count + 1))
            echo "  ✗ CRITICAL: CRDs missing (source: PKO ClusterPackage via route-monitor-operator-pko SSS)"
        else
            # CRDs exist but no CRs — check for orphaned monitoring resources
            _run_oc "Get ServiceMonitors in $NAMESPACE" ocm backplane elevate "${REASON}" -- get servicemonitor -n "$NAMESPACE" --no-headers
            orphan_sm_names=$(echo "$__oc_out" | awk '{print $1}' | sed '/controller-manager-metrics-monitor/d' | tr '\n' ', ' | sed 's/,$//')
            orphan_sms_filtered=$(echo "$orphan_sm_names" | tr ',' '\n' | command grep -c . 2>/dev/null || echo "0")
            [ -z "$orphan_sm_names" ] && orphan_sms_filtered=0
            _run_oc "Get PrometheusRules in $NAMESPACE" ocm backplane elevate "${REASON}" -- get prometheusrule -n "$NAMESPACE" --no-headers
            orphan_pr_names=$(echo "$__oc_out" | awk '{print $1}' | tr '\n' ', ' | sed 's/,$//')
            orphan_prs=$(echo "$orphan_pr_names" | tr ',' '\n' | command grep -c . 2>/dev/null || echo "0")
            [ -z "$orphan_pr_names" ] && orphan_prs=0
            _run_oc "Get blackbox-exporter ready replicas" oc get deployment blackbox-exporter -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}'
            bb_running="${__oc_out:-0}"

            if [ "${orphan_sms_filtered:-0}" -gt 0 ] || [ "${orphan_prs:-0}" -gt 0 ] || [ "${bb_running:-0}" -gt 0 ]; then
                rmo_rm_status="WARNING"
                orphan_detail=""
                [ "${orphan_sms_filtered:-0}" -gt 0 ] && orphan_detail="${orphan_detail}ServiceMonitors: $NAMESPACE/{$orphan_sm_names}, "
                [ "${orphan_prs:-0}" -gt 0 ] && orphan_detail="${orphan_detail}PrometheusRules: $NAMESPACE/{$orphan_pr_names}, "
                [ "${bb_running:-0}" -gt 0 ] && orphan_detail="${orphan_detail}blackbox-exporter running, "
                orphan_detail="${orphan_detail%, }"
                rmo_rm_message="LOAD-BEARING ORPHANS: ${mcc_issues}. Orphaned resources remain: ${orphan_detail}. Source: MCC osd-route-monitor-operator SSS should deploy CRs via Hive ClusterSync. RMO reconciler creates child resources from CRs. If CRs are deleted, children become unmanaged. DO NOT DELETE orphans — nothing will recreate them."
                warning_count=$((warning_count + 1))
                echo "  ⚠ LOAD-BEARING ORPHANS: $mcc_issues"
                echo "    Orphaned: $orphan_detail"
                echo "    Source: MCC → osd-route-monitor-operator SSS → Hive ClusterSync → CRs → RMO reconciler → monitoring"
                echo "    Fix: Investigate ClusterSync on hive shard for this cluster"
            else
                rmo_rm_status="WARNING"
                rmo_rm_message="$mcc_issues. No monitoring resources present. Source: MCC osd-route-monitor-operator SSS should deploy CRs via Hive ClusterSync. Investigate ClusterSync status on hive shard."
                warning_count=$((warning_count + 1))
                echo "  ⚠ $mcc_issues"
                echo "    No monitoring resources — route monitoring completely absent"
                echo "    Source: MCC → osd-route-monitor-operator SSS → Hive ClusterSync"
            fi
        fi
    elif [ -n "$mcc_issues" ]; then
        # Some CRs exist but MCC-expected ones are missing
        rmo_rm_status="WARNING"
        rmo_rm_message="$mcc_issues (${rm_count} RouteMonitor(s), ${cum_count_detail} ClusterUrlMonitor(s) present)"
        warning_count=$((warning_count + 1))
        echo "  ⚠ $mcc_issues"
    elif [ "$rm_errors" -gt 0 ]; then
        rmo_rm_status="WARNING"
        rmo_rm_message="$rm_errors monitor(s) have errorStatus — RMO reconciler failed to create monitoring resources"
        warning_count=$((warning_count + 1))
        echo "  ⚠ $rm_errors monitor(s) with errors (RMO reconciler issue)"
    elif [ "$rm_missing_url" -gt 0 ]; then
        rmo_rm_status="WARNING"
        rmo_rm_message="$rm_missing_url RouteMonitor(s) missing routeURL — target route may not exist"
        warning_count=$((warning_count + 1))
        echo "  ⚠ $rm_missing_url RouteMonitor(s) missing URL"
    elif [ "$rm_missing_sm" -gt 0 ]; then
        rmo_rm_status="WARNING"
        rmo_rm_message="$rm_missing_sm RouteMonitor(s) missing ServiceMonitor ref — RMO reconciler may not have processed them"
        warning_count=$((warning_count + 1))
        echo "  ⚠ $rm_missing_sm RouteMonitor(s) missing ServiceMonitor"
    else
        rmo_rm_message="$rm_count RouteMonitor(s), $cum_count_detail ClusterUrlMonitor(s) — all healthy (console: $console_rm_exists, api: $api_cum_exists)"
        echo "  ✓ $rm_count RouteMonitor(s), $cum_count_detail ClusterUrlMonitor(s) — MCC expectations met"
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
    "console_routemonitor_present": $console_rm_exists,
    "api_clusterurlmonitor_present": $api_cum_exists,
    "error_count": $rm_errors,
    "missing_url_count": $rm_missing_url,
    "missing_servicemonitor_count": $rm_missing_sm,
    "mcc_issues": "$(echo "${mcc_issues:-none}" | sed 's/"/\\"/g')",
    "deployment_chain": "MCC (deploy/osd-route-monitor-operator/) → osd-route-monitor-operator SSS → Hive ClusterSync → RouteMonitor CRs → RMO reconciler → ServiceMonitors + PrometheusRules + blackbox",
    "routemonitor_query_error": "$(echo "${rm_query_error:-}" | sed 's/"/\\"/g')",
    "clusterurlmonitor_query_error": "$(echo "${cum_query_error:-}" | sed 's/"/\\"/g')"
  }
}
EOF
)")

    CURRENT_CHECK="rmo_sre_probe_expectations"
    # RMO Check 3a: SRE probe-missing alerts — verify monitoring expectations are met
    rmo_sre_status="PASS"
    rmo_sre_message=""
    _run_oc_optional "Check SRE probe-missing-api PrometheusRule" ocm backplane elevate "${REASON}" -- get prometheusrule sre-route-monitor-operator-probe-missing-api -n openshift-monitoring --no-headers
    sre_probe_missing_api=$(echo "$__oc_out" | wc -l | tr -d ' ')
    [ $__oc_rc -ne 0 ] && sre_probe_missing_api=0
    # Console probe-missing rule only exists on standard/SC clusters (MCC deploys console RouteMonitor there, not on MCs)
    sre_probe_missing_console=0
    if [ "$cluster_type" != "management_cluster" ]; then
        _run_oc_optional "Check SRE probe-missing-console PrometheusRule" ocm backplane elevate "${REASON}" -- get prometheusrule sre-route-monitor-operator-probe-missing-console -n openshift-monitoring --no-headers
        sre_probe_missing_console=$(echo "$__oc_out" | wc -l | tr -d ' ')
        [ $__oc_rc -ne 0 ] && sre_probe_missing_console=0
    fi
    sre_expects_probes=false

    if [ "${sre_probe_missing_api:-0}" -gt 0 ] || [ "${sre_probe_missing_console:-0}" -gt 0 ]; then
        sre_expects_probes=true
        # SRE expects probes — verify they exist
        if [ "$total_crd_count" -eq 0 ]; then
            # No RouteMonitor CRs but SRE expects probes — check if orphaned probes satisfy the requirement
            if [ "${orphan_sms_filtered:-0}" -gt 0 ]; then
                rmo_sre_status="WARNING"
                rmo_sre_message="SRE probe-missing alerts exist — probes present but orphaned (no parent RouteMonitor CRs)"
                warning_count=$((warning_count + 1))
                echo "  ⚠ SRE expects probes — orphaned probes satisfy requirement but are unmanaged"
            else
                rmo_sre_status="FAIL"
                rmo_sre_message="SRE probe-missing alerts exist but no probes found — api/console route monitoring is absent"
                critical_count=$((critical_count + 1))
                echo "  ✗ CRITICAL: SRE expects probes but none exist — route monitoring gap"
            fi
        else
            rmo_sre_message="SRE probe-missing alerts present, RouteMonitor CRs exist — monitoring expectations met"
            echo "  ✓ SRE probe expectations met (${total_crd_count} monitors active)"
        fi
    else
        rmo_sre_status="INFO"
        rmo_sre_message="No SRE probe-missing PrometheusRules found"
        echo "  ℹ No SRE probe-missing alerts configured"
    fi

    health_checks+=("$(cat <<EOF
{
  "check": "rmo_sre_probe_expectations",
  "status": "$rmo_sre_status",
  "severity": "$([ "$rmo_sre_status" = "FAIL" ] && echo "critical" || echo "warning")",
  "message": "$rmo_sre_message",
  "details": {
    "sre_probe_missing_api_rule": $([ "${sre_probe_missing_api:-0}" -gt 0 ] && echo "true" || echo "false"),
    "sre_probe_missing_console_rule": $([ "${sre_probe_missing_console:-0}" -gt 0 ] && echo "true" || echo "false"),
    "sre_expects_probes": $sre_expects_probes,
    "routemonitor_crs_present": $([ "$total_crd_count" -gt 0 ] && echo "true" || echo "false")
  }
}
EOF
)")

    CURRENT_CHECK="rmo_probe_health"
    # RMO Check 3b: Probe health — verify blackbox probes are succeeding
    rmo_probe_status="PASS"
    rmo_probe_message=""
    rmo_probe_total=0
    rmo_probe_failing=0
    rmo_probe_failing_targets=""
    probe_count_mismatch=false

    if [ "$total_crd_count" -gt 0 ]; then
        echo "  Querying probe_success metrics from Thanos..."
        probe_err=$(mktemp)
        probe_data=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
            wget -q -T 30 -O- "http://localhost:9090/api/v1/query?query=$(printf 'probe_success{namespace=~"openshift-route-monitor-operator|ocm-.*"}' | jq -sRr @uri)" 2>"$probe_err")
        probe_data_rc=$?
        if [ $probe_data_rc -ne 0 ]; then
            probe_err_msg=$(head -1 "$probe_err")
            log_api_error "Probe success instant query" "${probe_err_msg:-timeout or connection error}" "$probe_data_rc"
            echo "  ⚠ Probe success query failed: ${probe_err_msg:-timeout or connection error}"
        fi
        rm -f "$probe_err"

        if [ $probe_data_rc -eq 0 ] && [ -n "$probe_data" ] && echo "$probe_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
            rmo_probe_total=$(echo "$probe_data" | jq '.data.result | length' 2>/dev/null || echo "0")
            rmo_probe_total=$(echo "$rmo_probe_total" | tr -d '[:space:]')

            # Extract endpoint names from probe_url for display
            probe_endpoint_names=$(echo "$probe_data" | jq -r '[.data.result[] | {
                name: (if .metric.probe_url then
                    (if (.metric.probe_url | test("console")) then "console"
                     elif (.metric.probe_url | test("api|livez")) then "api"
                     else (.metric.probe_url | split("/")[-1] // "unknown") end)
                else "unknown" end),
                status: (if .value[1] == "1" then "ok" else "FAILING" end),
                url: (.metric.probe_url // "")
            }] | map("\(.name)=\(.status)") | join(", ")' 2>/dev/null)

            # Find probes with success=0 (currently failing)
            rmo_probe_failing=$(echo "$probe_data" | jq '[.data.result[] | select(.value[1] == "0")] | length' 2>/dev/null || echo "0")
            rmo_probe_failing=$(echo "$rmo_probe_failing" | tr -d '[:space:]')
            rmo_probe_failing_targets=$(echo "$probe_data" | jq -r '[.data.result[] | select(.value[1] == "0") | if .metric.probe_url then (if (.metric.probe_url | test("console")) then "console" elif (.metric.probe_url | test("api|livez")) then "api" else .metric.probe_url end) else "unknown" end] | join(", ")' 2>/dev/null)

            # On MCs, only the ClusterUrlMonitor "api" probe is visible in platform Thanos
            # HCP probes are scraped by the RHOBS monitoring stack (checked in rmo_hcp_probe_coverage)
            expected_visible_probes=$total_crd_count
            probe_count_mismatch=false
            if [ "$cluster_type" = "management_cluster" ]; then
                expected_visible_probes=$cum_count_detail
                echo "  ℹ MC: HCP probes in RHOBS stack (see HCP Probes check); local probes: $expected_visible_probes expected"
            fi
            if [ "$rmo_probe_total" -lt "$expected_visible_probes" ]; then
                probe_count_mismatch=true
            fi

            if [ "${rmo_probe_failing:-0}" -gt 0 ]; then
                rmo_probe_status="WARNING"
                rmo_probe_message="Failing endpoint(s): $rmo_probe_failing_targets ($rmo_probe_failing/$rmo_probe_total failing)"
                warning_count=$((warning_count + 1))
                echo "  ⚠ Failing: $rmo_probe_failing_targets"
            elif [ "$probe_count_mismatch" = true ]; then
                rmo_probe_status="WARNING"
                rmo_probe_message="Probe count mismatch: $rmo_probe_total active ($probe_endpoint_names) but $expected_visible_probes expected"
                warning_count=$((warning_count + 1))
                echo "  ⚠ Mismatch: $rmo_probe_total vs $expected_visible_probes expected"
            else
                rmo_probe_message="All endpoints healthy: $probe_endpoint_names ($rmo_probe_total/$expected_visible_probes)"
                echo "  ✓ All endpoints healthy: $probe_endpoint_names"
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

    CURRENT_CHECK="rmo_servicemonitor_health"
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
        # Collect serviceMonitorRefs with their API group (from spec.serviceMonitorType)
        # serviceMonitorType: "monitoring.coreos.com" or "monitoring.rhobs"
        sm_refs=""
        if [ -n "${routemonitors:-}" ]; then
            sm_refs=$(echo "$routemonitors" | jq -r '.items[] | select(.status.serviceMonitorRef.name != null and .status.serviceMonitorRef.name != "") | "\(.spec.serviceMonitorType // "monitoring.coreos.com")|\(.status.serviceMonitorRef.namespace)/\(.status.serviceMonitorRef.name)"' 2>/dev/null)
        fi
        if [ -n "${clusterurlmonitors:-}" ]; then
            cum_sm_refs=$(echo "$clusterurlmonitors" | jq -r '.items[] | select(.status.serviceMonitorRef.name != null and .status.serviceMonitorRef.name != "") | "\(.spec.serviceMonitorType // "monitoring.coreos.com")|\(.status.serviceMonitorRef.namespace)/\(.status.serviceMonitorRef.name)"' 2>/dev/null)
            [ -n "$cum_sm_refs" ] && sm_refs="${sm_refs}${sm_refs:+$'\n'}${cum_sm_refs}"
        fi

        # Verify each referenced ServiceMonitor exists using the correct API group
        if [ -n "$sm_refs" ]; then
            while IFS= read -r ref_line; do
                [ -z "$ref_line" ] && continue
                sm_api="${ref_line%%|*}"
                ref="${ref_line#*|}"
                sm_ns="${ref%%/*}"
                sm_name="${ref#*/}"
                _run_oc "Check ServiceMonitor $sm_ns/$sm_name" ocm backplane elevate "${REASON}" -- get servicemonitor.${sm_api} "$sm_name" -n "$sm_ns"
                if [ $__oc_rc -eq 0 ]; then
                    rmo_sm_found=$((rmo_sm_found + 1))
                    echo "  ✓ ServiceMonitor: $sm_ns/$sm_name (${sm_api})"
                else
                    rmo_sm_missing=$((rmo_sm_missing + 1))
                    echo "  ⚠ Missing ServiceMonitor: $sm_ns/$sm_name (${sm_api}): $__oc_err"
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

    CURRENT_CHECK="rmo_prometheusrule_health"
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
            _run_oc "Check PrometheusRule $pr_ns/$pr_name" ocm backplane elevate "${REASON}" -- get prometheusrule "$pr_name" -n "$pr_ns"
            if [ $__oc_rc -eq 0 ]; then
                rmo_pr_found=$((rmo_pr_found + 1))
            else
                rmo_pr_missing=$((rmo_pr_missing + 1))
                echo "  ⚠ Missing: $pr_ns/$pr_name (error: $__oc_err)"
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

    CURRENT_CHECK="rmo_operator_metrics"
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
        local _mef
        _mef=$(mktemp)
        local _mout
        _mout=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
            wget -q -T 30 -O- "http://localhost:9090/api/v1/query?query=${query_encoded}" 2>"$_mef")
        local _mrc=$?
        if [ $_mrc -ne 0 ]; then
            local _merr=$(head -1 "$_mef")
            log_api_error "Prometheus query: $metric_name" "${_merr:-timeout or connection error}" "$_mrc"
            echo "  ⚠ $metric_name query failed: ${_merr:-timeout or connection error}" >&2
        fi
        rm -f "$_mef"
        echo "$_mout"
        return $_mrc
    }

    echo "  Querying RMO Prometheus metrics..."
    rmo_info_data=$(query_rmo_metric "rhobs_route_monitor_operator_info")
    if [ $? -eq 0 ] && [ -n "$rmo_info_data" ] && echo "$rmo_info_data" | jq -e '.data.result[0]' >/dev/null 2>&1; then
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

    CURRENT_CHECK="rmo_config"
    # RMO Check 7: ConfigMap configuration
    rmo_config_status="PASS"
    rmo_config_message=""
    # PKO creates route-monitor-operator-manager-config; runtime creates route-monitor-operator-config
    _run_oc "Get RMO manager ConfigMap" oc get configmap -n "$NAMESPACE" route-monitor-operator-manager-config -o json
    rmo_config_data="$__oc_out"
    if [ -z "$rmo_config_data" ] || ! echo "$rmo_config_data" | jq -e '.metadata.name' >/dev/null 2>&1; then
        _run_oc "Get RMO ConfigMap (alternate name)" oc get configmap -n "$NAMESPACE" route-monitor-operator-config -o json
        rmo_config_data="$__oc_out"
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

    CURRENT_CHECK="rmo_hcp_coverage"
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

        _run_oc "Get HostedControlPlane CRs" oc get hostedcontrolplane -A -o json
        hcp_list="$__oc_out"
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

        CURRENT_CHECK="rmo_hcp_probe_coverage"
        # RMO Check 8b: HCP Probe Health (from RHOBS Prometheus)
        # Queries the RHOBS hypershift monitoring stack for actual HCP probe status
        echo "  Querying HCP probe health from RHOBS Prometheus..."
        hpc_cov_status="PASS"
        hpc_cov_message=""
        hpc_total_probes=0
        hpc_probes_ok=0
        hpc_probes_failing=0
        hpc_ready_with_probes=0
        hpc_failing_urls=""
        __rhobs_rc=0
        __rhobs_err=""

        # Query RHOBS Prometheus for HCP probe data
        rhobs_probe_raw=$(query_rhobs_prometheus "HCP probe_success (all)" 'probe_success')
        if [ -n "$rhobs_probe_raw" ]; then
            hpc_total_probes=$(echo "$rhobs_probe_raw" | jq '.data.result | length' 2>/dev/null | tr -d '[:space:]')
            [ -z "$hpc_total_probes" ] && hpc_total_probes=0
            hpc_probes_ok=$(echo "$rhobs_probe_raw" | jq '[.data.result[] | select(.value[1] == "1")] | length' 2>/dev/null | tr -d '[:space:]')
            [ -z "$hpc_probes_ok" ] && hpc_probes_ok=0
            hpc_probes_failing=$(echo "$rhobs_probe_raw" | jq '[.data.result[] | select(.value[1] == "0")] | length' 2>/dev/null | tr -d '[:space:]')
            [ -z "$hpc_probes_failing" ] && hpc_probes_failing=0
            hpc_failing_urls=$(echo "$rhobs_probe_raw" | jq -r '[.data.result[] | select(.value[1] == "0") | .metric.probe_url] | join(", ")' 2>/dev/null)
        fi

        # Ready HCPs with probes (filtered by state)
        rhobs_ready_raw=$(query_rhobs_prometheus "Ready HCPs with probes" 'count(count by (_id) (probe_success and on (_id) hypershift_cluster_vcpus > 0 unless on (_id) hypershift_cluster_limited_support_enabled == 1 unless on (_id) hypershift_cluster_waiting_initial_availability_duration_seconds unless on (_id) hypershift_cluster_deleting_duration_seconds))')
        if [ -n "$rhobs_ready_raw" ]; then
            hpc_ready_with_probes=$(echo "$rhobs_ready_raw" | prom_scalar)
        fi
        [ -z "$hpc_ready_with_probes" ] && hpc_ready_with_probes=0

        echo "  Total probes: $hpc_total_probes ($hpc_probes_ok ok, $hpc_probes_failing failing) | Ready with probes: $hpc_ready_with_probes"

        if [ $__rhobs_rc -ne 0 ]; then
            hpc_cov_status="UNKNOWN"
            hpc_cov_message="Cannot query RHOBS Prometheus: $__rhobs_err"
        elif [ "$hpc_total_probes" -eq 0 ] 2>/dev/null; then
            hpc_cov_status="WARNING"
            hpc_cov_message="No HCP probes found in RHOBS Prometheus — RMO may not have created probes yet"
            warning_count=$((warning_count + 1))
            echo "  ⚠ No HCP probes in RHOBS Prometheus"
        elif [ "$hpc_probes_failing" -gt 0 ] 2>/dev/null; then
            hpc_cov_status="WARNING"
            hpc_cov_message="$hpc_probes_failing/$hpc_total_probes HCP probe(s) failing — kube-apiserver may be unreachable"
            warning_count=$((warning_count + 1))
            echo "  ⚠ $hpc_probes_failing failing probes: $hpc_failing_urls"
        else
            hpc_cov_message="All $hpc_total_probes HCP probes succeeding ($hpc_ready_with_probes on ready HCPs)"
            echo "  ✓ All $hpc_total_probes HCP probes succeeding"
        fi

        health_checks+=("$(cat <<EOF
{
  "check": "rmo_hcp_probe_coverage",
  "status": "$hpc_cov_status",
  "severity": "warning",
  "message": "$hpc_cov_message",
  "details": {
    "total_probes": $hpc_total_probes,
    "probes_succeeding": $hpc_probes_ok,
    "probes_failing": $hpc_probes_failing,
    "ready_hcps_with_probes": $hpc_ready_with_probes,
    "failing_probe_urls": "$(echo "${hpc_failing_urls:-none}" | sed 's/"/\\"/g')",
    "data_source": "RHOBS Prometheus (openshift-observability-operator/prometheus-rhobs-hypershift-monitoring-stack)"
  }
}
EOF
)")

        CURRENT_CHECK="rmo_hcp_state"
        # RMO Check 8c: HCP State Breakdown (from RHOBS Prometheus)
        echo "  Querying HCP state breakdown from RHOBS Prometheus..."
        hcp_prom_provisioned=0
        hcp_prom_limited=0
        hcp_prom_deleting=0
        hcp_prom_waiting=0
        hcp_prom_ready=0

        prov_raw=$(query_rhobs_prometheus "HCP provisioned count" 'count(hypershift_cluster_vcpus > 0)')
        [ -n "$prov_raw" ] && hcp_prom_provisioned=$(echo "$prov_raw" | prom_scalar)
        [ -z "$hcp_prom_provisioned" ] && hcp_prom_provisioned=0

        ls_raw=$(query_rhobs_prometheus "HCP limited support count" 'count(hypershift_cluster_limited_support_enabled == 1)')
        [ -n "$ls_raw" ] && hcp_prom_limited=$(echo "$ls_raw" | prom_scalar)
        [ -z "$hcp_prom_limited" ] && hcp_prom_limited=0

        del_raw=$(query_rhobs_prometheus "HCP deleting count" 'count(hypershift_cluster_deleting_duration_seconds)')
        [ -n "$del_raw" ] && hcp_prom_deleting=$(echo "$del_raw" | prom_scalar)
        [ -z "$hcp_prom_deleting" ] && hcp_prom_deleting=0

        wait_raw=$(query_rhobs_prometheus "HCP waiting availability count" 'count(hypershift_cluster_waiting_initial_availability_duration_seconds)')
        [ -n "$wait_raw" ] && hcp_prom_waiting=$(echo "$wait_raw" | prom_scalar)
        [ -z "$hcp_prom_waiting" ] && hcp_prom_waiting=0

        ready_raw=$(query_rhobs_prometheus "HCP ready count" 'count(hypershift_cluster_vcpus > 0 unless on(_id) hypershift_cluster_limited_support_enabled == 1 unless on(_id) hypershift_cluster_waiting_initial_availability_duration_seconds unless on(_id) hypershift_cluster_deleting_duration_seconds)')
        [ -n "$ready_raw" ] && hcp_prom_ready=$(echo "$ready_raw" | prom_scalar)
        [ -z "$hcp_prom_ready" ] && hcp_prom_ready=0

        echo "  HCP State: ${hcp_prom_provisioned} provisioned, ${hcp_prom_ready} ready, ${hcp_prom_limited} limited support, ${hcp_prom_deleting} deleting, ${hcp_prom_waiting} waiting"

        health_checks+=("$(cat <<EOF
{
  "check": "rmo_hcp_state",
  "status": "INFO",
  "severity": "info",
  "message": "${hcp_prom_provisioned} provisioned HCPs: ${hcp_prom_ready} ready, ${hcp_prom_limited} limited support, ${hcp_prom_deleting} deleting, ${hcp_prom_waiting} waiting",
  "details": {
    "provisioned": $hcp_prom_provisioned,
    "ready": $hcp_prom_ready,
    "limited_support": $hcp_prom_limited,
    "deleting": $hcp_prom_deleting,
    "waiting_availability": $hcp_prom_waiting,
    "data_source": "RHOBS Prometheus hypershift_cluster_* metrics"
  }
}
EOF
)")

        CURRENT_CHECK="rmo_limited_support_disagreement"
        # RMO Check 8d: Limited Support Label vs Metric Disagreement
        # RMO uses HCP label api.openshift.com/limited-support to decide probe lifecycle.
        # Prometheus metric hypershift_cluster_limited_support_enabled comes from hypershift operator.
        # If they disagree, RMO may keep probes on limited-support clusters (false SLO alerts)
        # or delete probes on non-limited clusters (monitoring gap).
        echo "  Cross-referencing limited support: HCP labels vs RHOBS Prometheus metrics..."
        ls_status="PASS"
        ls_message=""
        ls_disagreements=""
        ls_disagree_count=0

        # Get limited-support cluster IDs from Prometheus
        ls_prom_raw=$(query_rhobs_prometheus "Limited support cluster IDs (Prometheus)" 'hypershift_cluster_limited_support_enabled == 1')
        prom_ls_ids=""
        if [ -n "$ls_prom_raw" ]; then
            prom_ls_ids=$(echo "$ls_prom_raw" | jq -r '[.data.result[] | .metric._id] | unique | .[]' 2>/dev/null)
        fi

        # Get limited-support labels from HCP CRs (reuse hcp_list from HCP coverage check)
        if [ -n "${hcp_list:-}" ] && echo "$hcp_list" | jq -e '.items[0]' >/dev/null 2>&1; then
            # Build lookup: clusterID -> label value, name
            hcp_ls_data=$(echo "$hcp_list" | jq -r '.items[] | "\(.spec.clusterID // "unknown")|\(.metadata.labels["api.openshift.com/limited-support"] // "not-set")|\(.metadata.name)"' 2>/dev/null)

            while IFS='|' read -r cid label_val hcp_name; do
                [ -z "$cid" ] || [ "$cid" = "unknown" ] && continue
                label_is_ls=false
                [ "$label_val" = "true" ] && label_is_ls=true

                prom_is_ls=false
                if echo "$prom_ls_ids" | grep -q "^${cid}$" 2>/dev/null; then
                    prom_is_ls=true
                fi

                if [ "$label_is_ls" != "$prom_is_ls" ]; then
                    ls_disagree_count=$((ls_disagree_count + 1))
                    if [ "$label_is_ls" = false ] && [ "$prom_is_ls" = true ]; then
                        ls_disagreements="${ls_disagreements}${hcp_name} (${cid:0:12}): Prometheus=limited but label=${label_val} — RMO will NOT delete probe (false SLO alerts possible); "
                    else
                        ls_disagreements="${ls_disagreements}${hcp_name} (${cid:0:12}): label=limited but Prometheus=not-limited — RMO deleted probe but cluster may not be limited (monitoring gap); "
                    fi
                fi
            done <<< "$hcp_ls_data"

            ls_disagreements="${ls_disagreements%; }"

            if [ "$ls_disagree_count" -gt 0 ]; then
                ls_status="FAIL"
                ls_message="${ls_disagree_count} HCP(s) disagree between label (what RMO uses) and Prometheus metric (what dashboards show): ${ls_disagreements}"
                critical_count=$((critical_count + 1))
                echo "  ✗ CRITICAL: ${ls_disagree_count} limited support disagreement(s) — probe lifecycle incorrect"
                echo "    $ls_disagreements"
            else
                ls_message="All HCPs agree: label api.openshift.com/limited-support matches Prometheus hypershift_cluster_limited_support_enabled"
                echo "  ✓ Limited support labels and metrics agree"
            fi
        else
            ls_status="UNKNOWN"
            ls_message="Cannot cross-reference — HCP list not available"
            echo "  ⚠ Cannot check: HCP list not available"
        fi

        health_checks+=("$(cat <<EOF
{
  "check": "rmo_limited_support_disagreement",
  "status": "$ls_status",
  "severity": "critical",
  "message": "$(echo "$ls_message" | sed 's/"/\\"/g')",
  "details": {
    "disagreement_count": $ls_disagree_count,
    "disagreements": "$(echo "${ls_disagreements:-none}" | sed 's/"/\\"/g')",
    "rmo_source": "HCP label api.openshift.com/limited-support",
    "dashboard_source": "Prometheus metric hypershift_cluster_limited_support_enabled",
    "prom_limited_count": ${hcp_prom_limited:-0},
    "label_limited_count": $(echo "$hcp_ls_data" | grep -c '|true|' 2>/dev/null || echo "0")
  }
}
EOF
)")

        CURRENT_CHECK="rmo_rhobs_api_health"
        # RMO Check 8e: RHOBS API Health (from RHOBS Prometheus)
        # RMO's own operational metrics for RHOBS probe management
        echo "  Querying RMO RHOBS API health from RHOBS Prometheus..."
        rhobs_api_status="PASS"
        rhobs_api_message=""
        rhobs_get_success=0
        rhobs_get_error=0
        rhobs_create_success=0
        rhobs_create_error=0
        rhobs_delete_success=0
        rhobs_delete_error=0
        rhobs_update_success=0
        rhobs_update_error=0
        rhobs_oidc_success=0
        rhobs_oidc_error=0
        rhobs_deletion_timeouts=0
        rhobs_rmo_version=""

        # API requests by operation
        api_raw=$(query_rhobs_prometheus "RMO API requests" 'rhobs_route_monitor_operator_api_requests_total')
        if [ -n "$api_raw" ]; then
            rhobs_get_success=$(echo "$api_raw" | jq -r '[.data.result[] | select(.metric.operation == "get_probe" and .metric.status == "success") | .value[1] | tonumber] | add // 0' 2>/dev/null | tr -d '[:space:]')
            rhobs_get_error=$(echo "$api_raw" | jq -r '[.data.result[] | select(.metric.operation == "get_probe" and .metric.status == "error") | .value[1] | tonumber] | add // 0' 2>/dev/null | tr -d '[:space:]')
            rhobs_create_success=$(echo "$api_raw" | jq -r '[.data.result[] | select(.metric.operation == "create_probe" and .metric.status == "success") | .value[1] | tonumber] | add // 0' 2>/dev/null | tr -d '[:space:]')
            rhobs_create_error=$(echo "$api_raw" | jq -r '[.data.result[] | select(.metric.operation == "create_probe" and .metric.status == "error") | .value[1] | tonumber] | add // 0' 2>/dev/null | tr -d '[:space:]')
            rhobs_delete_success=$(echo "$api_raw" | jq -r '[.data.result[] | select(.metric.operation == "delete_probe" and .metric.status == "success") | .value[1] | tonumber] | add // 0' 2>/dev/null | tr -d '[:space:]')
            rhobs_delete_error=$(echo "$api_raw" | jq -r '[.data.result[] | select(.metric.operation == "delete_probe" and .metric.status == "error") | .value[1] | tonumber] | add // 0' 2>/dev/null | tr -d '[:space:]')
            rhobs_update_success=$(echo "$api_raw" | jq -r '[.data.result[] | select(.metric.operation == "update_probe_labels" and .metric.status == "success") | .value[1] | tonumber] | add // 0' 2>/dev/null | tr -d '[:space:]')
            rhobs_update_error=$(echo "$api_raw" | jq -r '[.data.result[] | select(.metric.operation == "update_probe_labels" and .metric.status == "error") | .value[1] | tonumber] | add // 0' 2>/dev/null | tr -d '[:space:]')
        fi
        # Defaults
        [ -z "$rhobs_get_success" ] && rhobs_get_success=0
        [ -z "$rhobs_get_error" ] && rhobs_get_error=0
        [ -z "$rhobs_create_success" ] && rhobs_create_success=0
        [ -z "$rhobs_create_error" ] && rhobs_create_error=0
        [ -z "$rhobs_delete_success" ] && rhobs_delete_success=0
        [ -z "$rhobs_delete_error" ] && rhobs_delete_error=0
        [ -z "$rhobs_update_success" ] && rhobs_update_success=0
        [ -z "$rhobs_update_error" ] && rhobs_update_error=0

        # OIDC token refresh
        oidc_raw=$(query_rhobs_prometheus "RMO OIDC token refresh" 'rhobs_route_monitor_operator_oidc_token_refresh_total')
        if [ -n "$oidc_raw" ]; then
            rhobs_oidc_success=$(echo "$oidc_raw" | jq -r '[.data.result[] | select(.metric.status == "success") | .value[1] | tonumber] | add // 0' 2>/dev/null | tr -d '[:space:]')
            rhobs_oidc_error=$(echo "$oidc_raw" | jq -r '[.data.result[] | select(.metric.status == "error") | .value[1] | tonumber] | add // 0' 2>/dev/null | tr -d '[:space:]')
        fi
        [ -z "$rhobs_oidc_success" ] && rhobs_oidc_success=0
        [ -z "$rhobs_oidc_error" ] && rhobs_oidc_error=0

        # Probe deletion timeouts (SREP-2832/2966)
        timeout_raw=$(query_rhobs_prometheus "RMO probe deletion timeouts" 'rhobs_route_monitor_operator_probe_deletion_timeout_total')
        if [ -n "$timeout_raw" ]; then
            rhobs_deletion_timeouts=$(echo "$timeout_raw" | prom_scalar)
        fi
        [ -z "$rhobs_deletion_timeouts" ] && rhobs_deletion_timeouts=0

        # RMO version from RHOBS Prometheus
        info_raw=$(query_rhobs_prometheus "RMO info (RHOBS)" 'rhobs_route_monitor_operator_info')
        if [ -n "$info_raw" ]; then
            rhobs_rmo_version=$(echo "$info_raw" | jq -r '.data.result[0].metric.version // "unknown"' 2>/dev/null)
        fi

        total_api_errors=$((rhobs_get_error + rhobs_create_error + rhobs_delete_error + rhobs_update_error))
        total_api_success=$((rhobs_get_success + rhobs_create_success + rhobs_delete_success + rhobs_update_success))

        echo "  RHOBS API: get=${rhobs_get_success}ok/${rhobs_get_error}err create=${rhobs_create_success}ok/${rhobs_create_error}err delete=${rhobs_delete_success}ok/${rhobs_delete_error}err update=${rhobs_update_success}ok/${rhobs_update_error}err"
        echo "  OIDC: ${rhobs_oidc_success} ok / ${rhobs_oidc_error} err | Deletion timeouts: ${rhobs_deletion_timeouts} | RMO version: ${rhobs_rmo_version:-unknown}"

        if [ "$total_api_errors" -gt 0 ] && [ "$total_api_success" -eq 0 ]; then
            rhobs_api_status="FAIL"
            rhobs_api_message="All RHOBS API calls failing ($total_api_errors errors, 0 success) — probe management is broken"
            critical_count=$((critical_count + 1))
            echo "  ✗ CRITICAL: All RHOBS API calls failing"
        elif [ "$rhobs_oidc_error" -gt 0 ] && [ "$rhobs_oidc_success" -eq 0 ]; then
            rhobs_api_status="FAIL"
            rhobs_api_message="OIDC token refresh failing ($rhobs_oidc_error errors, 0 success) — cannot authenticate to RHOBS API"
            critical_count=$((critical_count + 1))
            echo "  ✗ CRITICAL: OIDC token refresh failing"
        elif [ "$rhobs_deletion_timeouts" -gt 0 ]; then
            rhobs_api_status="WARNING"
            rhobs_api_message="$rhobs_deletion_timeouts probe deletion timeout(s) (SREP-2832/2966) — HCP deletions were delayed waiting for probe cleanup"
            warning_count=$((warning_count + 1))
            echo "  ⚠ $rhobs_deletion_timeouts deletion timeouts (fail-open after 15min)"
        elif [ "$total_api_errors" -gt 0 ]; then
            rhobs_api_status="WARNING"
            rhobs_api_message="Some RHOBS API errors: $total_api_errors errors out of $((total_api_success + total_api_errors)) total calls"
            warning_count=$((warning_count + 1))
        else
            rhobs_api_message="RHOBS API healthy: $total_api_success API calls, OIDC ${rhobs_oidc_success} refreshes, 0 errors, 0 deletion timeouts"
            echo "  ✓ RHOBS API healthy"
        fi

        health_checks+=("$(cat <<EOF
{
  "check": "rmo_rhobs_api_health",
  "status": "$rhobs_api_status",
  "severity": "$([ "$rhobs_api_status" = "FAIL" ] && echo "critical" || echo "warning")",
  "message": "$(echo "$rhobs_api_message" | sed 's/"/\\"/g')",
  "details": {
    "get_probe_success": $rhobs_get_success,
    "get_probe_error": $rhobs_get_error,
    "create_probe_success": $rhobs_create_success,
    "create_probe_error": $rhobs_create_error,
    "delete_probe_success": $rhobs_delete_success,
    "delete_probe_error": $rhobs_delete_error,
    "update_labels_success": $rhobs_update_success,
    "update_labels_error": $rhobs_update_error,
    "oidc_refresh_success": $rhobs_oidc_success,
    "oidc_refresh_error": $rhobs_oidc_error,
    "probe_deletion_timeouts": $rhobs_deletion_timeouts,
    "rmo_version": "${rhobs_rmo_version:-unknown}",
    "data_source": "RHOBS Prometheus rhobs_route_monitor_operator_* metrics"
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
        for _skip_check in rmo_hcp_probe_coverage rmo_hcp_state rmo_limited_support_disagreement rmo_rhobs_api_health; do
            health_checks+=("$(cat <<EOF
{
  "check": "$_skip_check",
  "status": "SKIP",
  "severity": "info",
  "message": "MC-only check not applicable (${cluster_type} cluster)",
  "details": { "cluster_type": "$cluster_type" }
}
EOF
)")
        done
    fi

    CURRENT_CHECK="rmo_rhobs_integration"
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
    _run_oc "Get restart events for pod $pod_name" oc get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod_name" -o json
    pod_events="${__oc_out:-{\"items\":[]}}"

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
_run_oc "Get ReplicaSets for version history" oc get replicasets -n "$NAMESPACE" -l "${pod_selector:-name=$DEPLOYMENT}" -o json
replicasets="${__oc_out:-{\"items\":[]}}"

# Fallback: try owner-based lookup if label selector found nothing
rs_count=$(echo "$replicasets" | jq '.items | length' 2>/dev/null || echo "0")
if [ "$rs_count" -eq 0 ]; then
    _run_oc "Get ReplicaSets (owner-based fallback)" oc get replicasets -n "$NAMESPACE" -o json
    replicasets=$(echo "$__oc_out" | jq "{items: [.items[] | select(.metadata.ownerReferences[]? | select(.name == \"$DEPLOYMENT\"))]}" 2>/dev/null || echo '{"items":[]}')
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

# Ensure event variables are valid single-line JSON arrays
# Use jq -cs to slurp all input into one value, flatten if accidentally doubled
version_events=$(printf '%s' "${version_events:-[]}" | jq -cs 'if type == "array" and (.[0] | type) == "array" then .[0] else if type == "array" then . else [] end end' 2>/dev/null || echo "[]")
restart_events=$(printf '%s' "${restart_events:-[]}" | jq -cs 'if type == "array" and (.[0] | type) == "array" then .[0] else if type == "array" then . else [] end end' 2>/dev/null || echo "[]")

# Restore stdout and output data
exec 1>&3

# Build final JSON output
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
