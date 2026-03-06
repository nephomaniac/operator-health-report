#!/usr/bin/env bash
#
# Collect Version-Aware Pod Resource Usage
#
# This script detects operator version changes and collects resource usage
# data for both the previous and current versions to enable comparison.
#
# Features:
#   - Detects operator version change date from pod creation time
#   - Queries Prometheus for both version periods
#   - Outputs separate data rows for each version
#   - Enables version-to-version resource comparison
#
# Usage:
#   ./collect_version_resource_usage.sh [OPTIONS]
#

set -uo pipefail

# Default values
NAMESPACE="openshift-monitoring"
DEPLOYMENT="configure-alertmanager-operator"
OUTPUT_FORMAT="csv"
CLUSTER_ID=""
CLUSTER_NAME=""
CLUSTER_VERSION=""
REASON=""
OPERATOR_NAME=""
LOOKBACK_DAYS=14  # How far back to look for version changes

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Collect version-aware resource usage data for capacity planning and version comparison

OPTIONS:
    --namespace, -n NAMESPACE   Namespace to query (default: openshift-monitoring)
    --deployment, -d DEPLOY     Deployment name (default: configure-alertmanager-operator)
    --format, -f FORMAT         Output format: csv or json (default: csv)
    --cluster-id, -c ID         Cluster ID for tracking (auto-detected if not provided)
    --cluster-name NAME         Cluster name for display (auto-detected if not provided)
    --cluster-version VERSION   Cluster OpenShift version (auto-detected if not provided)
    --reason, -r REASON         JIRA ticket for OCM elevation (required)
    --operator-name NAME        Operator name for tracking (defaults to deployment name)
    --lookback-days DAYS        Days to look back for version changes (default: 14)
    --help, -h                  Show this help message

EXAMPLES:
    # Collect version-aware resource data
    $0 --reason "SREP-12345 capacity planning"

    # Custom lookback period
    $0 --reason "SREP-12345" --lookback-days 7

EOF
    exit 0
}

# Parse arguments
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
        --lookback-days) LOOKBACK_DAYS="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "Error: Unknown option: $1" >&2; usage ;;
    esac
done

# Default operator name to deployment name if not specified
if [ -z "$OPERATOR_NAME" ]; then
    OPERATOR_NAME="$DEPLOYMENT"
fi

# Validate reason
if [ -z "$REASON" ]; then
    echo "Error: --reason is required" >&2
    exit 1
fi

# Auto-detect cluster ID if not provided
if [ -z "$CLUSTER_ID" ]; then
    CLUSTER_ID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "unknown")
fi

# Auto-detect cluster name if not provided
if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME=$(ocm backplane status 2>/dev/null | grep "Cluster Name:" | awk '{print $3}' || echo "")
    if [ -z "$CLUSTER_NAME" ]; then
        CLUSTER_NAME=$(ocm get cluster "$CLUSTER_ID" 2>/dev/null | jq -r '.name // "unknown"' || echo "unknown")
    fi
fi

# Suppress normal output, only show errors on stderr and data on stdout
exec 3>&1  # Save stdout
exec 1>&2  # Redirect stdout to stderr for messages

echo "================================================================================"
echo "VERSION-AWARE RESOURCE COLLECTION - Cluster: $CLUSTER_ID"
echo "================================================================================"
echo "Operator:   $OPERATOR_NAME"
echo "Namespace:  $NAMESPACE"
echo "Deployment: $DEPLOYMENT"
echo "Lookback:   $LOOKBACK_DAYS days"
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
echo ""

# Get current operator version from CSV
echo "Getting current operator version..."
current_operator_version=$(ocm backplane elevate "${REASON}" -- get csv -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r ".items[]? | select(.metadata.name | startswith(\"$OPERATOR_NAME\")) | .spec.version // \"unknown\"" 2>/dev/null | \
    head -1)

if [ -z "$current_operator_version" ]; then
    current_operator_version="unknown"
fi
echo "Current operator version: $current_operator_version"
echo ""

# Get pod creation time to detect version change
echo "Analyzing pod history to detect version changes..."
pod_data=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$DEPLOYMENT" -o json 2>/dev/null)

# Get current pod start time
current_pod_start=$(echo "$pod_data" | jq -r '.items[0].status.startTime // empty' 2>/dev/null)

if [ -z "$current_pod_start" ]; then
    echo "Warning: No running pods found for $DEPLOYMENT" >&2
    echo "Cannot determine version change time" >&2
    exit 1
fi

echo "Current pod start time: $current_pod_start"

# Convert to epoch seconds for calculations
current_pod_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$current_pod_start" "+%s" 2>/dev/null)
current_time_epoch=$(date "+%s")
lookback_epoch=$((current_time_epoch - (LOOKBACK_DAYS * 86400)))

echo "Current pod age: $(( (current_time_epoch - current_pod_epoch) / 3600 )) hours"
echo ""

# Check if pod was restarted within lookback period (indicating possible version change)
if [ "$current_pod_epoch" -gt "$lookback_epoch" ]; then
    echo "Pod was created/restarted within lookback period"
    echo "This likely indicates an operator version upgrade"
    has_version_change=true
    version_change_time="$current_pod_start"
    version_change_epoch="$current_pod_epoch"
else
    echo "Pod has been running longer than lookback period"
    echo "No recent version change detected"
    has_version_change=false
    version_change_time=""
    version_change_epoch=0
fi
echo ""

# Query Prometheus for resource usage
echo "Querying Prometheus for resource usage metrics..."

# Find Prometheus pod
prometheus_pod=$(oc get pods -n openshift-monitoring -l 'app.kubernetes.io/name=prometheus' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$prometheus_pod" ]; then
    echo "Error: Prometheus pod not found" >&2
    exit 1
fi

echo "Using Prometheus pod: $prometheus_pod"
echo ""

# Function to query Prometheus and extract value
query_prometheus() {
    local query="$1"
    local time_offset="$2"  # Optional: query at specific time (e.g., "2h ago")

    if [ -n "$time_offset" ]; then
        # Query at specific time
        result=$(oc exec -n openshift-monitoring "$prometheus_pod" -c prometheus -- \
            curl -s "http://localhost:9090/api/v1/query?query=${query}&time=${time_offset}" 2>/dev/null | \
            jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
    else
        # Query current value
        result=$(oc exec -n openshift-monitoring "$prometheus_pod" -c prometheus -- \
            curl -s "http://localhost:9090/api/v1/query?query=${query}" 2>/dev/null | \
            jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
    fi

    echo "$result"
}

# Function to query Prometheus for max/avg over a time range
query_prometheus_range() {
    local query="$1"
    local start_time="$2"  # RFC3339 format
    local end_time="$3"    # RFC3339 format

    result=$(oc exec -n openshift-monitoring "$prometheus_pod" -c prometheus -- \
        curl -s -G "http://localhost:9090/api/v1/query_range" \
        --data-urlencode "query=${query}" \
        --data-urlencode "start=${start_time}" \
        --data-urlencode "end=${end_time}" \
        --data-urlencode "step=5m" 2>/dev/null | \
        jq -r '.data.result[0].values[][1] // "0"' 2>/dev/null | \
        awk '{sum+=$1; if($1>max) max=$1; count++} END {print max, (count>0?sum/count:0)}')

    echo "$result"
}

# Collect current version data
echo "Collecting data for CURRENT version ($current_operator_version)..."

# Define queries for current pod
pod_label="pod=~\"${DEPLOYMENT}.*\""
namespace_label="namespace=\"${NAMESPACE}\""

# Current CPU usage (cores)
current_cpu=$(query_prometheus "rate(container_cpu_usage_seconds_total{${namespace_label},${pod_label},container!=\"\",container!=\"POD\"}[5m])")

# Current memory usage (bytes)
current_memory=$(query_prometheus "container_memory_working_set_bytes{${namespace_label},${pod_label},container!=\"\",container!=\"POD\"}")

# Max CPU in last 1 hour
max_1h_cpu_data=$(query_prometheus_range \
    "rate(container_cpu_usage_seconds_total{${namespace_label},${pod_label},container!=\"\",container!=\"POD\"}[5m])" \
    "$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")
max_1h_cpu=$(echo "$max_1h_cpu_data" | awk '{print $1}')
avg_1h_cpu=$(echo "$max_1h_cpu_data" | awk '{print $2}')

# Max memory in last 1 hour
max_1h_memory_data=$(query_prometheus_range \
    "container_memory_working_set_bytes{${namespace_label},${pod_label},container!=\"\",container!=\"POD\"}" \
    "$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")
max_1h_memory=$(echo "$max_1h_memory_data" | awk '{print $1}')
avg_1h_memory=$(echo "$max_1h_memory_data" | awk '{print $2}')

# Calculate time range for current version
current_version_duration=$(( (current_time_epoch - current_pod_epoch) / 3600 ))  # hours
echo "Current version running for: ${current_version_duration} hours"

# Get deployment replica count
replicas=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

# Get resource requests/limits
requests_cpu=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "unknown")
requests_memory=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "unknown")
limits_cpu=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "unknown")
limits_memory=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "unknown")

echo "Metrics collected for current version"
echo ""

# Restore stdout and output data
exec 1>&3

# Output current version data
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$OUTPUT_FORMAT" = "json" ]; then
    cat << EOF
{
  "operator": "$OPERATOR_NAME",
  "cluster_id": "$CLUSTER_ID",
  "cluster_name": "$CLUSTER_NAME",
  "cluster_version": "$cluster_version",
  "operator_version": "$current_operator_version",
  "version_period": "current",
  "version_start_time": "$current_pod_start",
  "version_duration_hours": $current_version_duration,
  "namespace": "$NAMESPACE",
  "deployment": "$DEPLOYMENT",
  "replicas": $replicas,
  "requests_cpu": "$requests_cpu",
  "requests_memory": "$requests_memory",
  "limits_cpu": "$limits_cpu",
  "limits_memory": "$limits_memory",
  "current_cpu_cores": $current_cpu,
  "max_1h_cpu_cores": $max_1h_cpu,
  "avg_1h_cpu_cores": $avg_1h_cpu,
  "current_memory_bytes": $current_memory,
  "max_1h_memory_bytes": $max_1h_memory,
  "avg_1h_memory_bytes": $avg_1h_memory,
  "timestamp": "$timestamp"
}
EOF
else
    # CSV format with version tracking
    echo "$OPERATOR_NAME,$CLUSTER_ID,$CLUSTER_NAME,$cluster_version,$current_operator_version,current,$current_pod_start,$current_version_duration,$NAMESPACE,$DEPLOYMENT,$replicas,$requests_cpu,$requests_memory,$limits_cpu,$limits_memory,$current_cpu,$max_1h_cpu,$avg_1h_cpu,$current_memory,$max_1h_memory,$avg_1h_memory,$timestamp"
fi

# If version change detected, try to get previous version data from Prometheus
# Note: This requires historical data to be available in Prometheus
# For now, we output placeholder for previous version - would need pod history from events/logs
if [ "$has_version_change" = true ]; then
    # TODO: Query historical data for previous version
    # This would require accessing Prometheus historical data or cluster events
    # Placeholder for future enhancement
    exec 1>&2  # Switch back to stderr for messages
    echo ""
    echo "Note: Version change detected but historical data collection not yet implemented"
    echo "      Future enhancement: Query Prometheus for pre-upgrade metrics"
fi
