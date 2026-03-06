#!/usr/bin/env bash
#
# Collect Pod Resource Usage for Capacity Planning
#
# This script collects CPU and memory usage data for pods in a deployment
# across multiple clusters to determine appropriate resource requests/limits.
#
# Usage:
#   ./collect_pod_resource_usage.sh [OPTIONS]
#
# Output: CSV format suitable for aggregation across multiple clusters
#

set -uo pipefail
# Note: NOT using set -e to allow graceful error handling and data collection

# Default values
NAMESPACE="openshift-monitoring"
DEPLOYMENT="configure-alertmanager-operator"
PROMETHEUS_POD="prometheus-k8s-0"
OUTPUT_FORMAT="csv"
CLUSTER_ID=""
CLUSTER_NAME=""
CLUSTER_VERSION=""
REASON=""
OP_VER_ONLY=false
OPERATOR_NAME=""

# Parse command line arguments
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Collect resource usage data for capacity planning

OPTIONS:
    --namespace, -n NAMESPACE   Namespace to query (default: openshift-monitoring)
    --deployment, -d DEPLOY     Deployment name (default: configure-alertmanager-operator)
    --prometheus, -p POD        Prometheus pod name (default: prometheus-k8s-0)
    --format, -f FORMAT         Output format: csv or json (default: csv)
    --cluster-id, -c ID         Cluster ID for tracking (auto-detected if not provided)
    --cluster-name NAME         Cluster name for display (auto-detected if not provided)
    --cluster-version VERSION   Cluster OpenShift version (auto-detected if not provided)
    --reason, -r REASON         JIRA ticket for OCM elevation (required for OCM clusters)
    --operator-name NAME        Operator name for tracking (defaults to deployment name)
    --op-ver-only               Only fetch operator version (skip resource usage queries)
    --help, -h                  Show this help message

EXAMPLES:
    # Single cluster
    $0 --reason "SREP-12345 capacity planning"

    # Custom deployment
    $0 -d kube-apiserver -r "SREP-12345"

    # Only fetch operator version
    $0 -r "SREP-12345" --op-ver-only

    # Aggregate across multiple clusters
    for cluster in \$(ocm list clusters --columns id --no-headers); do
      ocm backplane login \$cluster
      $0 -r "SREP-12345" >> all_clusters_data.csv
    done

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        --deployment|-d) DEPLOYMENT="$2"; shift 2 ;;
        --prometheus|-p) PROMETHEUS_POD="$2"; shift 2 ;;
        --format|-f) OUTPUT_FORMAT="$2"; shift 2 ;;
        --cluster-id|-c) CLUSTER_ID="$2"; shift 2 ;;
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --cluster-version) CLUSTER_VERSION="$2"; shift 2 ;;
        --reason|-r) REASON="$2"; shift 2 ;;
        --operator-name) OPERATOR_NAME="$2"; shift 2 ;;
        --op-ver-only) OP_VER_ONLY=true; shift ;;
        --help|-h) usage ;;
        *) echo "Error: Unknown option: $1" >&2; usage ;;
    esac
done

# Default operator name to deployment name if not specified
if [ -z "$OPERATOR_NAME" ]; then
    OPERATOR_NAME="$DEPLOYMENT"
fi

# Check if reason is provided for OCM
if [ -z "$REASON" ]; then
    echo "Error: --reason is required for OCM backplane elevation" >&2
    echo "Example: --reason \"SREP-12345 capacity planning\"" >&2
    exit 1
fi

# Auto-detect cluster ID if not provided
if [ -z "$CLUSTER_ID" ]; then
    CLUSTER_ID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "unknown")
fi

# Auto-detect cluster name if not provided
if [ -z "$CLUSTER_NAME" ]; then
    # Try backplane status first
    CLUSTER_NAME=$(ocm backplane status 2>/dev/null | grep "Cluster Name:" | awk '{print $3}' || echo "")
    # Fallback to OCM API if backplane status doesn't return name
    if [ -z "$CLUSTER_NAME" ]; then
        CLUSTER_NAME=$(ocm get cluster "$CLUSTER_ID" 2>/dev/null | jq -r '.name // "unknown"' || echo "unknown")
    fi
fi

# If --op-ver-only is set, only fetch operator version and exit
if [ "$OP_VER_ONLY" = true ]; then
    # Suppress normal output, only show errors on stderr and data on stdout
    exec 3>&1  # Save stdout
    exec 1>&2  # Redirect stdout to stderr for messages

    echo "Getting cluster version and operator version for cluster $CLUSTER_ID..."

    # Get cluster version (use provided value or fetch from cluster)
    if [ -n "$CLUSTER_VERSION" ]; then
        cluster_version="$CLUSTER_VERSION"
    else
        cluster_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
    fi

    # Get operator version from CSV JSON (more reliable than grep/awk)
    # Query: Get all CSVs, find one with name starting with operator name, extract .spec.version
    operator_version=$(ocm backplane elevate "${REASON}" -- get csv -n "$NAMESPACE" -o json 2>/dev/null | \
        jq -r ".items[]? | select(.metadata.name | startswith(\"$OPERATOR_NAME\")) | .spec.version // \"unknown\"" 2>/dev/null | \
        head -1)

    # Fallback to unknown if empty
    if [ -z "$operator_version" ]; then
        operator_version="unknown"
    fi

    echo "Operator: $OPERATOR_NAME"
    echo "Cluster: $CLUSTER_NAME ($CLUSTER_ID)"
    echo "Cluster version: $cluster_version"
    echo "Operator version: $operator_version"

    # Restore stdout and output data
    exec 1>&3

    # Output CSV format (operator,cluster_id,cluster_name,cluster_version,operator_version)
    echo "$OPERATOR_NAME,$CLUSTER_ID,$CLUSTER_NAME,$cluster_version,$operator_version"
    exit 0
fi

# Function to execute query via OCM backplane
# Note: Prometheus always runs in openshift-monitoring namespace
execute_prom_query() {
    local query="$1"

    ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring "$PROMETHEUS_POD" -c prometheus -- \
        curl -s "http://localhost:9090/api/v1/query?query=$(echo "$query" | jq -sRr @uri)" 2>/dev/null | jq -r '.'
}

# Function to get single value from query result
get_single_value() {
    local query_result="$1"
    echo "$query_result" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "0"
}

# Suppress normal output, only show errors on stderr and data on stdout
exec 3>&1  # Save stdout
exec 1>&2  # Redirect stdout to stderr for messages

# Check if pods exist
pod_count=$(ocm backplane elevate "${REASON}" -- get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "^${DEPLOYMENT}-" 2>/dev/null || echo "0")
# Clean up any whitespace/newlines
pod_count=$(echo "$pod_count" | tr -d '\n' | tr -d ' ')

# Ensure it's a valid number
if ! [[ "$pod_count" =~ ^[0-9]+$ ]]; then
    pod_count=0
fi

if [ "$pod_count" -eq 0 ]; then
    echo "Warning: No pods found for deployment '$DEPLOYMENT' in cluster $CLUSTER_ID"
    # Still continue - might have historical data
fi

# Get current resource requests and limits
echo "Querying resource requests/limits for cluster $CLUSTER_ID..."
requests_cpu=$(ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>/dev/null | \
    jq -r '.spec.template.spec.containers[0].resources.requests.cpu // "none"' || echo "none")
requests_memory=$(ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>/dev/null | \
    jq -r '.spec.template.spec.containers[0].resources.requests.memory // "none"' || echo "none")
limits_cpu=$(ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>/dev/null | \
    jq -r '.spec.template.spec.containers[0].resources.limits.cpu // "none"' || echo "none")
limits_memory=$(ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>/dev/null | \
    jq -r '.spec.template.spec.containers[0].resources.limits.memory // "none"' || echo "none")

# ==============================================================================
# RESOURCE USAGE QUERIES - Optimized to capture spikes over maximum time window
# ==============================================================================
# Lookback Strategy:
#   - Tries 14 days first (2 weeks)
#   - Falls back to 7 days if 14d data not available
#   - Falls back to 24 hours if 7d data not available
#   - Falls back to 1 hour as last resort
#   - Uses whichever gives the longest time window available
#
# CPU queries:
#   - Use [1m] rate window (not [5m]) to capture short spikes (30s-1min bursts)
#   - max_over_time samples every 1 minute to find the highest peak
#   - Higher resolution (1m) ensures short-lived spikes are not missed
#
# Memory queries:
#   - Memory metrics are instantaneous (not averaged), naturally capture spikes
#   - max_over_time samples every 1 minute to find the highest peak
#   - Higher resolution (1m) ensures short-lived spikes are not missed
# ==============================================================================

# Query current CPU usage (average over last 5 minutes)
echo "Querying current CPU usage..."
echo "Debug: Namespace=$NAMESPACE, Deployment=$DEPLOYMENT"
# Try primary query with deployment pod pattern
CPU_CURRENT='sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"}[5m]))'
echo "Debug: Primary query=$CPU_CURRENT"
cpu_current_result=$(execute_prom_query "$CPU_CURRENT")
echo "Debug: CPU current result preview: $(echo "$cpu_current_result" | head -c 200)..."
cpu_current=$(get_single_value "$cpu_current_result")
echo "Debug: CPU current value from primary query: $cpu_current"

# If primary query returns 0 or empty and we're querying a controller-manager deployment, try alternative pod pattern
if ([ "$cpu_current" = "0" ] || [ -z "$cpu_current" ]) && echo "$DEPLOYMENT" | grep -q "controller-manager"; then
    echo "Debug: Primary query returned 0 or empty, trying alternative pattern for controller-manager"
    # Try without the full deployment name - just the operator name
    base_name=$(echo "$DEPLOYMENT" | sed 's/-controller-manager$//')
    CPU_ALT='sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"}[5m]))'
    echo "Debug: Alternative query=$CPU_ALT"
    cpu_alt_result=$(execute_prom_query "$CPU_ALT")
    cpu_alt=$(get_single_value "$cpu_alt_result")
    echo "Debug: CPU current value from alternative query: $cpu_alt"
    if [ "$cpu_alt" != "0" ] && [ -n "$cpu_alt" ]; then
        cpu_current="$cpu_alt"
        echo "Debug: Using alternative query result"
    fi
fi

# Query max CPU - Try longest lookback possible with fallbacks
# Try 14 days, fall back to 7 days, fall back to 24 hours
echo "Querying max CPU (attempting longest available period)..."

# Try 14 days first (2 weeks)
CPU_MAX_14D='max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"}[1m]))[14d:1m])'
cpu_max_result=$(execute_prom_query "$CPU_MAX_14D")
cpu_max=$(get_single_value "$cpu_max_result")
cpu_lookback_period="14d"

# Fall back to 7 days if 14 days failed
if [ "$cpu_max" = "0" ] || [ -z "$cpu_max" ]; then
    echo "  14d lookback failed, trying 7d..."
    CPU_MAX_7D='max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"}[1m]))[7d:1m])'
    cpu_max_result=$(execute_prom_query "$CPU_MAX_7D")
    cpu_max=$(get_single_value "$cpu_max_result")
    cpu_lookback_period="7d"
fi

# Fall back to 24 hours if 7 days failed
if [ "$cpu_max" = "0" ] || [ -z "$cpu_max" ]; then
    echo "  7d lookback failed, trying 24h..."
    CPU_MAX_24H='max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"}[1m]))[24h:1m])'
    cpu_max_result=$(execute_prom_query "$CPU_MAX_24H")
    cpu_max=$(get_single_value "$cpu_max_result")
    cpu_lookback_period="24h"
fi

# Fall back to 1 hour as last resort
if [ "$cpu_max" = "0" ] || [ -z "$cpu_max" ]; then
    echo "  24h lookback failed, trying 1h..."
    CPU_MAX_1H='max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"}[1m]))[1h:30s])'
    cpu_max_result=$(execute_prom_query "$CPU_MAX_1H")
    cpu_max=$(get_single_value "$cpu_max_result")
    cpu_lookback_period="1h"
fi

# Try alternative query pattern if all queries returned 0 or empty and we're querying a controller-manager deployment
if ([ "$cpu_max" = "0" ] || [ -z "$cpu_max" ]) && echo "$DEPLOYMENT" | grep -q "controller-manager"; then
    echo "  Primary queries returned 0 or empty, trying alternative pattern for controller-manager"
    base_name=$(echo "$DEPLOYMENT" | sed 's/-controller-manager$//')

    # Try longest lookback with alternative pattern
    CPU_ALT_14D='max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"}[1m]))[14d:1m])'
    cpu_alt_result=$(execute_prom_query "$CPU_ALT_14D")
    cpu_alt=$(get_single_value "$cpu_alt_result")

    if [ "$cpu_alt" != "0" ] && [ -n "$cpu_alt" ]; then
        cpu_max="$cpu_alt"
        cpu_lookback_period="14d"
        echo "  Using alternative query result (14d)"
    else
        # Try 7d
        CPU_ALT_7D='max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"}[1m]))[7d:1m])'
        cpu_alt_result=$(execute_prom_query "$CPU_ALT_7D")
        cpu_alt=$(get_single_value "$cpu_alt_result")

        if [ "$cpu_alt" != "0" ] && [ -n "$cpu_alt" ]; then
            cpu_max="$cpu_alt"
            cpu_lookback_period="7d"
            echo "  Using alternative query result (7d)"
        else
            # Try 24h
            CPU_ALT_24H='max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"}[1m]))[24h:1m])'
            cpu_alt_result=$(execute_prom_query "$CPU_ALT_24H")
            cpu_alt=$(get_single_value "$cpu_alt_result")

            if [ "$cpu_alt" != "0" ] && [ -n "$cpu_alt" ]; then
                cpu_max="$cpu_alt"
                cpu_lookback_period="24h"
                echo "  Using alternative query result (24h)"
            else
                # Try 1h
                CPU_ALT_1H='max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"}[1m]))[1h:30s])'
                cpu_alt_result=$(execute_prom_query "$CPU_ALT_1H")
                cpu_alt=$(get_single_value "$cpu_alt_result")

                if [ "$cpu_alt" != "0" ] && [ -n "$cpu_alt" ]; then
                    cpu_max="$cpu_alt"
                    cpu_lookback_period="1h"
                    echo "  Using alternative query result (1h)"
                fi
            fi
        fi
    fi
fi

echo "  CPU max over $cpu_lookback_period: $cpu_max cores"
echo "Debug: CPU max query result: $cpu_max_result" | head -c 500

# Save for later use
cpu_max_24h="$cpu_max"
cpu_max_1h="$cpu_max"

# Query current memory usage
# Note: Memory is instantaneous (not averaged), so captures spikes naturally
echo "Querying current memory usage..."
MEM_CURRENT='sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"})'
mem_current_result=$(execute_prom_query "$MEM_CURRENT")
mem_current=$(get_single_value "$mem_current_result")

# If primary query returns 0 or empty and we're querying a controller-manager deployment, try alternative pod pattern
if ([ "$mem_current" = "0" ] || [ -z "$mem_current" ]) && echo "$DEPLOYMENT" | grep -q "controller-manager"; then
    echo "Debug: Primary memory query returned 0 or empty, trying alternative pattern for controller-manager"
    base_name=$(echo "$DEPLOYMENT" | sed 's/-controller-manager$//')
    MEM_ALT='sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"})'
    mem_alt_result=$(execute_prom_query "$MEM_ALT")
    mem_alt=$(get_single_value "$mem_alt_result")
    if [ "$mem_alt" != "0" ] && [ -n "$mem_alt" ]; then
        mem_current="$mem_alt"
        echo "Debug: Using alternative memory query result"
    fi
fi

# Query max memory - Try longest lookback possible with fallbacks
# Try 14 days, fall back to 7 days, fall back to 24 hours
echo "Querying max memory (attempting longest available period)..."

# Try 14 days first (2 weeks)
MEM_MAX_14D='max_over_time(sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"})[14d:1m])'
mem_max_result=$(execute_prom_query "$MEM_MAX_14D")
mem_max=$(get_single_value "$mem_max_result")
mem_lookback_period="14d"

# Fall back to 7 days if 14 days failed
if [ "$mem_max" = "0" ] || [ -z "$mem_max" ]; then
    echo "  14d lookback failed, trying 7d..."
    MEM_MAX_7D='max_over_time(sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"})[7d:1m])'
    mem_max_result=$(execute_prom_query "$MEM_MAX_7D")
    mem_max=$(get_single_value "$mem_max_result")
    mem_lookback_period="7d"
fi

# Fall back to 24 hours if 7 days failed
if [ "$mem_max" = "0" ] || [ -z "$mem_max" ]; then
    echo "  7d lookback failed, trying 24h..."
    MEM_MAX_24H='max_over_time(sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"})[24h:1m])'
    mem_max_result=$(execute_prom_query "$MEM_MAX_24H")
    mem_max=$(get_single_value "$mem_max_result")
    mem_lookback_period="24h"
fi

# Fall back to 1 hour as last resort
if [ "$mem_max" = "0" ] || [ -z "$mem_max" ]; then
    echo "  24h lookback failed, trying 1h..."
    MEM_MAX_1H='max_over_time(sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"})[1h:30s])'
    mem_max_result=$(execute_prom_query "$MEM_MAX_1H")
    mem_max=$(get_single_value "$mem_max_result")
    mem_lookback_period="1h"
fi

# Try alternative query pattern if all queries returned 0 or empty and we're querying a controller-manager deployment
if ([ "$mem_max" = "0" ] || [ -z "$mem_max" ]) && echo "$DEPLOYMENT" | grep -q "controller-manager"; then
    echo "  Primary queries returned 0 or empty, trying alternative pattern for controller-manager"
    base_name=$(echo "$DEPLOYMENT" | sed 's/-controller-manager$//')

    # Try longest lookback with alternative pattern
    MEM_ALT_14D='max_over_time(sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"})[14d:1m])'
    mem_alt_result=$(execute_prom_query "$MEM_ALT_14D")
    mem_alt=$(get_single_value "$mem_alt_result")

    if [ "$mem_alt" != "0" ] && [ -n "$mem_alt" ]; then
        mem_max="$mem_alt"
        mem_lookback_period="14d"
        echo "  Using alternative query result (14d)"
    else
        # Try 7d
        MEM_ALT_7D='max_over_time(sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"})[7d:1m])'
        mem_alt_result=$(execute_prom_query "$MEM_ALT_7D")
        mem_alt=$(get_single_value "$mem_alt_result")

        if [ "$mem_alt" != "0" ] && [ -n "$mem_alt" ]; then
            mem_max="$mem_alt"
            mem_lookback_period="7d"
            echo "  Using alternative query result (7d)"
        else
            # Try 24h
            MEM_ALT_24H='max_over_time(sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"})[24h:1m])'
            mem_alt_result=$(execute_prom_query "$MEM_ALT_24H")
            mem_alt=$(get_single_value "$mem_alt_result")

            if [ "$mem_alt" != "0" ] && [ -n "$mem_alt" ]; then
                mem_max="$mem_alt"
                mem_lookback_period="24h"
                echo "  Using alternative query result (24h)"
            else
                # Try 1h
                MEM_ALT_1H='max_over_time(sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"})[1h:30s])'
                mem_alt_result=$(execute_prom_query "$MEM_ALT_1H")
                mem_alt=$(get_single_value "$mem_alt_result")

                if [ "$mem_alt" != "0" ] && [ -n "$mem_alt" ]; then
                    mem_max="$mem_alt"
                    mem_lookback_period="1h"
                    echo "  Using alternative query result (1h)"
                fi
            fi
        fi
    fi
fi

echo "  Memory max over $mem_lookback_period: $mem_max bytes"
echo "Debug: Memory max query result: $mem_max_result" | head -c 500

# Save for later use
mem_max_24h="$mem_max"
mem_max_1h="$mem_max"

# Clean up all numeric values to ensure they're valid
echo "Debug: Raw values before sanitization:"
echo "  cpu_max_24h: '$cpu_max_24h'"
echo "  mem_max_24h: '$mem_max_24h'"

cpu_current=$(echo "$cpu_current" | tr -d '\n' | tr -d ' ')
cpu_max_1h=$(echo "$cpu_max_1h" | tr -d '\n' | tr -d ' ')
cpu_max_24h=$(echo "$cpu_max_24h" | tr -d '\n' | tr -d ' ')
mem_current=$(echo "$mem_current" | tr -d '\n' | tr -d ' ')
mem_max_1h=$(echo "$mem_max_1h" | tr -d '\n' | tr -d ' ')
mem_max_24h=$(echo "$mem_max_24h" | tr -d '\n' | tr -d ' ')

# Validate they're numbers (including scientific notation), default to 0 if not
[[ "$cpu_current" =~ ^[0-9]+(\.[0-9]+)?(e[+-][0-9]+)?$ ]] || cpu_current="0"
[[ "$cpu_max_1h" =~ ^[0-9]+(\.[0-9]+)?(e[+-][0-9]+)?$ ]] || cpu_max_1h="0"
[[ "$cpu_max_24h" =~ ^[0-9]+(\.[0-9]+)?(e[+-][0-9]+)?$ ]] || cpu_max_24h="0"
[[ "$mem_current" =~ ^[0-9]+(\.[0-9]+)?(e[+-][0-9]+)?$ ]] || mem_current="0"
[[ "$mem_max_1h" =~ ^[0-9]+(\.[0-9]+)?(e[+-][0-9]+)?$ ]] || mem_max_1h="0"
[[ "$mem_max_24h" =~ ^[0-9]+(\.[0-9]+)?(e[+-][0-9]+)?$ ]] || mem_max_24h="0"

echo "Debug: Sanitized values:"
echo "  cpu_max_24h: '$cpu_max_24h'"
echo "  mem_max_24h: '$mem_max_24h'"

# Get cluster version (use provided value or fetch from cluster)
if [ -n "$CLUSTER_VERSION" ]; then
    cluster_version="$CLUSTER_VERSION"
    echo "Using provided cluster version: $cluster_version"
else
    echo "Getting cluster version..."
    cluster_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
fi

# Get operator version from CSV JSON (more reliable than grep/awk)
echo "Getting operator version..."
# Query: Get all CSVs, find one with name starting with operator name, extract .spec.version
operator_version=$(ocm backplane elevate "${REASON}" -- get csv -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r ".items[]? | select(.metadata.name | startswith(\"$OPERATOR_NAME\")) | .spec.version // \"unknown\"" 2>/dev/null | \
    head -1)

# Fallback to unknown if empty
if [ -z "$operator_version" ]; then
    operator_version="unknown"
fi

# Get pod count
echo "Getting pod count..."
current_replicas=$(ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
# Clean up any whitespace/newlines
current_replicas=$(echo "$current_replicas" | tr -d '\n' | tr -d ' ')

# Ensure it's a valid number
if ! [[ "$current_replicas" =~ ^[0-9]+$ ]]; then
    current_replicas=0
fi

# Display summary to user (still on stderr)
echo ""
echo "================================================================================"
echo "RESOURCE USAGE SUMMARY - Cluster: $CLUSTER_ID"
echo "================================================================================"

# CPU Summary
echo "CPU Usage:"
if [ "$cpu_max_24h" != "0" ] && [ -n "$cpu_max_24h" ]; then
    cpu_max_24h_millicores=$(echo "$cpu_max_24h * 1000" | bc 2>/dev/null | cut -d. -f1)
    echo "  Max (${cpu_lookback_period:-unknown}): ${cpu_max_24h} cores (${cpu_max_24h_millicores}m)"
elif [ "$cpu_current" != "0" ] && [ -n "$cpu_current" ]; then
    cpu_current_millicores=$(echo "$cpu_current * 1000" | bc 2>/dev/null | cut -d. -f1)
    echo "  Current: ${cpu_current} cores (${cpu_current_millicores}m) [historical data not available]"
else
    echo "  No CPU data available"
fi

echo ""

# Memory Summary
echo "Memory Usage:"
if [ "$mem_max_24h" != "0" ] && [ -n "$mem_max_24h" ]; then
    mem_max_24h_mib=$(echo "$mem_max_24h / 1024 / 1024" | bc 2>/dev/null)
    mem_max_24h_gib=$(echo "scale=2; $mem_max_24h / 1024 / 1024 / 1024" | bc 2>/dev/null)
    echo "  Max (${mem_lookback_period:-unknown}): ${mem_max_24h_mib}Mi (${mem_max_24h_gib}Gi)"
elif [ "$mem_current" != "0" ] && [ -n "$mem_current" ]; then
    mem_current_mib=$(echo "$mem_current / 1024 / 1024" | bc 2>/dev/null)
    mem_current_gib=$(echo "scale=2; $mem_current / 1024 / 1024 / 1024" | bc 2>/dev/null)
    echo "  Current: ${mem_current_mib}Mi (${mem_current_gib}Gi) [historical data not available]"
else
    echo "  No memory data available"
fi

echo ""

# Current Resource Configuration
echo "Current Resource Configuration:"
echo "  Requests: CPU=${requests_cpu}, Memory=${requests_memory}"
echo "  Limits:   CPU=${limits_cpu}, Memory=${limits_memory}"
echo "  Replicas: ${current_replicas}"
echo "================================================================================"
echo ""

# Restore stdout and output data
exec 1>&3

# Output in requested format
if [ "$OUTPUT_FORMAT" = "json" ]; then
    cat << EOF
{
  "operator": "$OPERATOR_NAME",
  "cluster_id": "$CLUSTER_ID",
  "cluster_name": "$CLUSTER_NAME",
  "cluster_version": "$cluster_version",
  "operator_version": "$operator_version",
  "namespace": "$NAMESPACE",
  "deployment": "$DEPLOYMENT",
  "replicas": $current_replicas,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "resources": {
    "requests": {
      "cpu": "$requests_cpu",
      "memory": "$requests_memory"
    },
    "limits": {
      "cpu": "$limits_cpu",
      "memory": "$limits_memory"
    }
  },
  "usage": {
    "cpu": {
      "current_cores": $cpu_current,
      "max_1h_cores": $cpu_max_1h,
      "max_24h_cores": $cpu_max_24h
    },
    "memory": {
      "current_bytes": $mem_current,
      "max_1h_bytes": $mem_max_1h,
      "max_24h_bytes": $mem_max_24h
    }
  }
}
EOF
else
    # CSV format
    # Print header only if file is empty or doesn't exist
    if [ ! -s /dev/stdout ] 2>/dev/null; then
        echo "operator,cluster_id,cluster_name,cluster_version,operator_version,namespace,deployment,replicas,requests_cpu,requests_memory,limits_cpu,limits_memory,current_cpu_cores,max_1h_cpu_cores,max_24h_cpu_cores,current_memory_bytes,max_1h_memory_bytes,max_24h_memory_bytes,timestamp"
    fi
    echo "$OPERATOR_NAME,$CLUSTER_ID,$CLUSTER_NAME,$cluster_version,$operator_version,$NAMESPACE,$DEPLOYMENT,$current_replicas,$requests_cpu,$requests_memory,$limits_cpu,$limits_memory,$cpu_current,$cpu_max_1h,$cpu_max_24h,$mem_current,$mem_max_1h,$mem_max_24h,$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
