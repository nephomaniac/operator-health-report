#!/usr/bin/env bash
#
# Collect Version-Compared Resource Metrics
#
# This script detects operator version upgrades and collects resource usage
# metrics for BOTH the previous and current versions from Prometheus.
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
LOOKBACK_DAYS=14
DEBUG_MODE=false
DEBUG_FILE=""

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Collect resource metrics for both previous and current operator versions

OPTIONS:
    --namespace, -n NAMESPACE   Namespace (default: openshift-monitoring)
    --deployment, -d DEPLOY     Deployment name (default: configure-alertmanager-operator)
    --format, -f FORMAT         Output format: csv or json (default: csv)
    --cluster-id, -c ID         Cluster ID (auto-detected if not provided)
    --cluster-name NAME         Cluster name (auto-detected if not provided)
    --cluster-version VERSION   Cluster version (auto-detected if not provided)
    --reason, -r REASON         JIRA ticket for OCM elevation (required)
    --operator-name NAME        Operator name (defaults to deployment name)
    --lookback-days DAYS        Days to look back for version changes (default: 14)
    --debug                     Enable debug logging to file
    --help, -h                  Show this help message

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
        --debug) DEBUG_MODE=true; shift ;;
        --help|-h) usage ;;
        *) echo "Error: Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$OPERATOR_NAME" ]; then
    OPERATOR_NAME="$DEPLOYMENT"
fi

if [ -z "$REASON" ]; then
    echo "Error: --reason is required" >&2
    exit 1
fi

# Auto-detect cluster info
if [ -z "$CLUSTER_ID" ]; then
    CLUSTER_ID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "unknown")
fi

if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME=$(ocm backplane status 2>/dev/null | grep "Cluster Name:" | awk '{print $3}' || echo "")
    if [ -z "$CLUSTER_NAME" ]; then
        CLUSTER_NAME=$(ocm get cluster "$CLUSTER_ID" 2>/dev/null | jq -r '.name // "unknown"' || echo "unknown")
    fi
fi

# Setup debug logging
if [ "$DEBUG_MODE" = true ]; then
    DEBUG_FILE="debug_${CLUSTER_ID}_$(date +%Y%m%d_%H%M%S).log"
    echo "Debug mode enabled - logging to $DEBUG_FILE" >&2
    exec 4>>"$DEBUG_FILE"  # Open fd 4 for debug logging
else
    exec 4>/dev/null  # Send debug to /dev/null if disabled
fi

# Debug logging function
debug_log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&4
}

# Redirect to stderr for messages
exec 3>&1
exec 1>&2

debug_log "=== SCRIPT START ==="
debug_log "Cluster: $CLUSTER_ID ($CLUSTER_NAME)"
debug_log "Namespace: $NAMESPACE"
debug_log "Deployment: $DEPLOYMENT"

echo "================================================================================"
echo "VERSIONED METRICS COLLECTION - Cluster: $CLUSTER_ID"
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
    cluster_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
fi
echo "Cluster version: $cluster_version"
debug_log "Cluster version: $cluster_version"
echo ""

# Find Prometheus pod
prometheus_pod=$(oc get pods -n openshift-monitoring -l 'app.kubernetes.io/name=prometheus' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$prometheus_pod" ]; then
    echo "Error: Prometheus pod not found" >&2
    debug_log "ERROR: Prometheus pod not found"
    exit 1
fi

echo "Prometheus pod: $prometheus_pod"
debug_log "Prometheus pod: $prometheus_pod"
echo ""

# Get ReplicaSets ordered by creation time
echo "Analyzing ReplicaSets to detect version changes..."
debug_log "Querying ReplicaSets with label: name=$DEPLOYMENT"

replicasets=$(oc get replicasets -n "$NAMESPACE" -l "name=$DEPLOYMENT" \
    -o json 2>/dev/null | \
    jq -r '.items | sort_by(.metadata.creationTimestamp) | reverse | .[] | [.metadata.name, .metadata.creationTimestamp, (.spec.template.spec.containers[0].image | if contains("@sha256:") then split("@sha256:")[1][0:12] else (split(":")[1] // "unknown") end)] | @tsv')

if [ -z "$replicasets" ]; then
    echo "Error: No ReplicaSets found for $DEPLOYMENT" >&2
    debug_log "ERROR: No ReplicaSets found"
    exit 1
fi

rs_count=$(echo "$replicasets" | wc -l | tr -d ' ')
echo "Found $rs_count ReplicaSet(s)"
debug_log "Found $rs_count ReplicaSets"
echo ""

# Parse current and previous ReplicaSet
current_rs_name=$(echo "$replicasets" | sed -n '1p' | awk '{print $1}')
current_rs_time=$(echo "$replicasets" | sed -n '1p' | awk '{print $2}')
current_rs_image=$(echo "$replicasets" | sed -n '1p' | awk '{print $3}')

echo "Current ReplicaSet:"
echo "  Name: $current_rs_name"
echo "  Created: $current_rs_time"
echo "  Image tag: $current_rs_image"
debug_log "Current RS: $current_rs_name @ $current_rs_time (image: $current_rs_image)"
echo ""

# Check for previous ReplicaSet
if [ "$rs_count" -gt 1 ]; then
    previous_rs_name=$(echo "$replicasets" | sed -n '2p' | awk '{print $1}')
    previous_rs_time=$(echo "$replicasets" | sed -n '2p' | awk '{print $2}')
    previous_rs_image=$(echo "$replicasets" | sed -n '2p' | awk '{print $3}')

    echo "Previous ReplicaSet:"
    echo "  Name: $previous_rs_name"
    echo "  Created: $previous_rs_time"
    echo "  Image tag: $previous_rs_image"
    debug_log "Previous RS: $previous_rs_name @ $previous_rs_time (image: $previous_rs_image)"
    echo ""

    has_previous_version=true
    version_change_time="$current_rs_time"
else
    echo "No previous ReplicaSet found (no recent version change)"
    debug_log "No previous ReplicaSet found"
    has_previous_version=false
    version_change_time=""
fi
echo ""

# Get operator version
echo "Getting operator version information..."
current_operator_version=$(ocm backplane elevate "${REASON}" -- get csv -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r ".items[]? | select(.metadata.name | startswith(\"$OPERATOR_NAME\")) | .spec.version // \"unknown\"" 2>/dev/null | \
    head -1)

if [ -z "$current_operator_version" ] || [ "$current_operator_version" = "unknown" ]; then
    current_operator_version="$current_rs_image"
fi

if [ "$has_previous_version" = true ]; then
    previous_operator_version="$previous_rs_image"

    if [[ "$current_operator_version" =~ ^[0-9]+\.[0-9]+\. ]] && [[ "$previous_operator_version" =~ ^[a-f0-9]{12}$ ]]; then
        echo "  Note: Previous version is SHA-based identifier, current is semver"
        echo "  This indicates image deployment changed from SHA to tagged release"
    fi
else
    previous_operator_version="none"
fi

echo "Current version:  $current_operator_version"
echo "Previous version: $previous_operator_version"
debug_log "Current version: $current_operator_version"
debug_log "Previous version: $previous_operator_version"
echo ""

# Function to test Prometheus connectivity and find correct metric labels
test_prometheus_metrics() {
    debug_log "=== TESTING PROMETHEUS METRICS ==="

    # Test basic connectivity - capture stderr for debugging
    debug_log "Testing Prometheus connectivity..."
    prom_status=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring "$prometheus_pod" -c prometheus -- \
        curl -s 'http://localhost:9090/-/healthy' 2>&1)
    prom_exit=$?
    debug_log "oc exec exit code: $prom_exit"
    debug_log "Prometheus health: $prom_status"

    # Find CAMO container metrics
    debug_log "Searching for CAMO metrics in Prometheus..."

    # Try to find any container metrics for CAMO
    test_query='container_cpu_usage_seconds_total{namespace="openshift-monitoring"}'
    debug_log "Test query: $test_query"

    test_result=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring "$prometheus_pod" -c prometheus -- \
        curl -s -G "http://localhost:9090/api/v1/query" \
        --data-urlencode "query=${test_query}" 2>&1)
    test_exit=$?
    debug_log "oc exec exit code: $test_exit"
    debug_log "Test query response: $test_result"

    # Extract all container names from the response
    containers=$(echo "$test_result" | jq -r '.data.result[].metric.container' 2>/dev/null | sort -u)
    debug_log "Available containers: $containers"

    # Check if our deployment container exists
    if echo "$containers" | grep -q "^${DEPLOYMENT}$"; then
        debug_log "Found container: $DEPLOYMENT"
        echo "configure-alertmanager-operator"
    elif echo "$containers" | grep -q "manager"; then
        debug_log "Found container: manager (alternate name)"
        echo "manager"
    else
        debug_log "Container '$DEPLOYMENT' not found in Prometheus metrics"
        debug_log "Available containers: $(echo "$containers" | tr '\n' ',' | sed 's/,$//')"
        echo ""
    fi
}

# Test and find correct container name
echo "Testing Prometheus metrics..."
container_name=$(test_prometheus_metrics)

if [ -z "$container_name" ]; then
    echo "Warning: Could not find CAMO container metrics in Prometheus" >&2
    echo "Metrics may return zero values" >&2
    debug_log "WARNING: Container metrics not found - queries will likely return 0"
    container_name="$DEPLOYMENT"  # Use deployment name as fallback
fi

echo "Using container name: $container_name"
debug_log "Using container name: $container_name"
echo ""

# Function to query Prometheus for metrics over a time range
query_metrics_for_period() {
    local start_time="$1"
    local end_time="$2"
    local version_label="$3"
    local container="$4"

    echo "Querying metrics for period: $start_time to $end_time ($version_label)" >&2
    debug_log "=== QUERY PERIOD: $version_label ==="
    debug_log "Start: $start_time"
    debug_log "End: $end_time"
    debug_log "Container: $container"

    # Define Prometheus queries
    local container_label="container=\"${container}\""
    local namespace_label="namespace=\"${NAMESPACE}\""

    # CPU usage (rate over 5m, max and avg over period)
    local cpu_query="rate(container_cpu_usage_seconds_total{${namespace_label},${container_label}}[5m])"
    debug_log "CPU query: $cpu_query"

    cpu_response=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring "$prometheus_pod" -c prometheus -- \
        curl -s -G "http://localhost:9090/api/v1/query_range" \
        --data-urlencode "query=${cpu_query}" \
        --data-urlencode "start=${start_time}" \
        --data-urlencode "end=${end_time}" \
        --data-urlencode "step=5m" 2>&1)
    cpu_exit=$?
    debug_log "oc exec exit code: $cpu_exit"
    debug_log "CPU response: $cpu_response"

    cpu_data=$(echo "$cpu_response" | jq -r '.data.result[0].values[]?[1] // empty' 2>/dev/null)
    debug_log "CPU data points: $(echo "$cpu_data" | wc -l | tr -d ' ')"

    if [ -n "$cpu_data" ]; then
        max_cpu=$(echo "$cpu_data" | awk '{if($1>max) max=$1} END {print (max==""?0:max)}')
        avg_cpu=$(echo "$cpu_data" | awk '{sum+=$1; count++} END {print (count>0?sum/count:0)}')
    else
        max_cpu="0"
        avg_cpu="0"
    fi

    debug_log "CPU - Max: $max_cpu, Avg: $avg_cpu"

    # Memory usage (working set bytes, max and avg over period)
    local memory_query="container_memory_working_set_bytes{${namespace_label},${container_label}}"
    debug_log "Memory query: $memory_query"

    memory_response=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring "$prometheus_pod" -c prometheus -- \
        curl -s -G "http://localhost:9090/api/v1/query_range" \
        --data-urlencode "query=${memory_query}" \
        --data-urlencode "start=${start_time}" \
        --data-urlencode "end=${end_time}" \
        --data-urlencode "step=5m" 2>&1)
    memory_exit=$?
    debug_log "oc exec exit code: $memory_exit"
    debug_log "Memory response: $memory_response"

    memory_data=$(echo "$memory_response" | jq -r '.data.result[0].values[]?[1] // empty' 2>/dev/null)
    debug_log "Memory data points: $(echo "$memory_data" | wc -l | tr -d ' ')"

    if [ -n "$memory_data" ]; then
        max_memory=$(echo "$memory_data" | awk '{if($1>max) max=$1} END {print (max==""?0:max)}')
        avg_memory=$(echo "$memory_data" | awk '{sum+=$1; count++} END {print (count>0?sum/count:0)}')
    else
        max_memory="0"
        avg_memory="0"
    fi

    debug_log "Memory - Max: $max_memory, Avg: $avg_memory"

    echo "  Max CPU: $max_cpu cores, Avg CPU: $avg_cpu cores" >&2
    echo "  Max Memory: $max_memory bytes, Avg Memory: $avg_memory bytes" >&2
    echo "" >&2

    # ONLY the result goes to stdout
    echo "$max_cpu,$avg_cpu,$max_memory,$avg_memory"
}

# Get deployment info
replicas=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
requests_cpu=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "unknown")
requests_memory=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "unknown")
limits_cpu=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "unknown")
limits_memory=$(oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "unknown")

timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Collect metrics for current version
echo "================================================================================"
echo "COLLECTING METRICS FOR CURRENT VERSION"
echo "================================================================================"
current_start=$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ')
current_end=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

current_metrics=$(query_metrics_for_period "$current_start" "$current_end" "current" "$container_name")
current_max_cpu=$(echo "$current_metrics" | cut -d',' -f1)
current_avg_cpu=$(echo "$current_metrics" | cut -d',' -f2)
current_max_memory=$(echo "$current_metrics" | cut -d',' -f3)
current_avg_memory=$(echo "$current_metrics" | cut -d',' -f4)

# Collect metrics for previous version (if exists)
if [ "$has_previous_version" = true ]; then
    echo "================================================================================"
    echo "COLLECTING METRICS FOR PREVIOUS VERSION"
    echo "================================================================================"

    version_change_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$version_change_time" "+%s" 2>/dev/null || date "+%s")
    previous_end="$version_change_time"
    previous_start=$(date -u -r $((version_change_epoch - 86400)) '+%Y-%m-%dT%H:%M:%SZ')

    previous_metrics=$(query_metrics_for_period "$previous_start" "$previous_end" "previous" "$container_name")
    previous_max_cpu=$(echo "$previous_metrics" | cut -d',' -f1)
    previous_avg_cpu=$(echo "$previous_metrics" | cut -d',' -f2)
    previous_max_memory=$(echo "$previous_metrics" | cut -d',' -f3)
    previous_avg_memory=$(echo "$previous_metrics" | cut -d',' -f4)
fi

debug_log "=== SCRIPT END ==="

# Restore stdout and output data
exec 1>&3

# Output data
if [ "$OUTPUT_FORMAT" = "json" ]; then
    echo "["
    if [ "$has_previous_version" = true ]; then
        cat << EOF
{
  "operator": "$OPERATOR_NAME",
  "cluster_id": "$CLUSTER_ID",
  "cluster_name": "$CLUSTER_NAME",
  "cluster_version": "$cluster_version",
  "operator_version": "$previous_operator_version",
  "version_period": "previous",
  "namespace": "$NAMESPACE",
  "deployment": "$DEPLOYMENT",
  "replicas": $replicas,
  "max_cpu_cores": $previous_max_cpu,
  "avg_cpu_cores": $previous_avg_cpu,
  "max_memory_bytes": $previous_max_memory,
  "avg_memory_bytes": $previous_avg_memory,
  "period_start": "$previous_start",
  "period_end": "$previous_end",
  "timestamp": "$timestamp"
},
EOF
    fi
    cat << EOF
{
  "operator": "$OPERATOR_NAME",
  "cluster_id": "$CLUSTER_ID",
  "cluster_name": "$CLUSTER_NAME",
  "cluster_version": "$cluster_version",
  "operator_version": "$current_operator_version",
  "version_period": "current",
  "namespace": "$NAMESPACE",
  "deployment": "$DEPLOYMENT",
  "replicas": $replicas,
  "max_cpu_cores": $current_max_cpu,
  "avg_cpu_cores": $current_avg_cpu,
  "max_memory_bytes": $current_max_memory,
  "avg_memory_bytes": $current_avg_memory,
  "period_start": "$current_start",
  "period_end": "$current_end",
  "timestamp": "$timestamp"
}
]
EOF
else
    # CSV output
    if [ "$has_previous_version" = true ]; then
        echo "$OPERATOR_NAME,$CLUSTER_ID,$CLUSTER_NAME,$cluster_version,$previous_operator_version,previous,$NAMESPACE,$DEPLOYMENT,$replicas,$requests_cpu,$requests_memory,$limits_cpu,$limits_memory,$previous_max_cpu,$previous_avg_cpu,$previous_max_memory,$previous_avg_memory,$previous_start,$previous_end,$timestamp"
    fi
    echo "$OPERATOR_NAME,$CLUSTER_ID,$CLUSTER_NAME,$cluster_version,$current_operator_version,current,$NAMESPACE,$DEPLOYMENT,$replicas,$requests_cpu,$requests_memory,$limits_cpu,$limits_memory,$current_max_cpu,$current_avg_cpu,$current_max_memory,$current_avg_memory,$current_start,$current_end,$timestamp"
fi
