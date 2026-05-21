#!/usr/bin/env bash
#
# Debug script to investigate RMO pod naming and Prometheus queries
#

set -euo pipefail

CLUSTER_ID="${1:-}"
REASON="${2:-}"

if [ -z "$CLUSTER_ID" ] || [ -z "$REASON" ]; then
    echo "Usage: $0 CLUSTER_ID REASON"
    echo "Example: $0 2o02tm3erg615hcks9tno4umvrus9c3d 'SREP-12345 debug'"
    exit 1
fi

echo "=== Connecting to cluster $CLUSTER_ID ==="
ocm backplane login "$CLUSTER_ID"

NAMESPACE="openshift-route-monitor-operator"
DEPLOYMENT="route-monitor-operator-controller-manager"

echo ""
echo "=== Checking actual pod names ==="
echo "Command: ocm backplane elevate \"$REASON\" -- get pods -n $NAMESPACE"
ocm backplane elevate "$REASON" -- get pods -n "$NAMESPACE" -o wide

echo ""
echo "=== Checking deployment ==="
echo "Command: ocm backplane elevate \"$REASON\" -- get deployment -n $NAMESPACE"
ocm backplane elevate "$REASON" -- get deployment -n "$NAMESPACE"

echo ""
echo "=== Testing Prometheus queries ==="
echo "Using prometheus pod: prometheus-k8s-0"
PROMETHEUS_POD="prometheus-k8s-0"

# Function to execute query
execute_prom_query() {
    local query="$1"
    local desc="$2"

    echo ""
    echo "--- Query: $desc ---"
    echo "PromQL: $query"

    result=$(ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring "$PROMETHEUS_POD" -c prometheus -- \
        curl -s "http://localhost:9090/api/v1/query?query=$(echo "$query" | jq -sRr @uri)" 2>/dev/null)

    echo "Result:"
    echo "$result" | jq '.'

    value=$(echo "$result" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "0")
    echo "Extracted value: $value"
}

# Test primary pattern
execute_prom_query \
    'sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"}[5m]))' \
    "CPU current - primary pattern (pod=~\"$DEPLOYMENT.*\")"

# Test alternative pattern (without -controller-manager)
base_name=$(echo "$DEPLOYMENT" | sed 's/-controller-manager$//')
execute_prom_query \
    'sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"}[5m]))' \
    "CPU current - alternative pattern (pod=~\"$base_name.*\")"

# Test just namespace pattern (no pod filter)
execute_prom_query \
    'sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", container!="", container!="POD"}[5m]))' \
    "CPU current - namespace only (all pods in $NAMESPACE)"

# Test memory queries
execute_prom_query \
    'sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'.*", container!="", container!="POD"})' \
    "Memory current - primary pattern"

execute_prom_query \
    'sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$base_name'.*", container!="", container!="POD"})' \
    "Memory current - alternative pattern"

execute_prom_query \
    'sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", container!="", container!="POD"})' \
    "Memory current - namespace only"

echo ""
echo "=== Listing actual metric labels ==="
echo "Checking what pod labels exist in Prometheus for this namespace..."

# Query for actual pod names in metrics
execute_prom_query \
    'container_cpu_usage_seconds_total{namespace="'$NAMESPACE'"}' \
    "All CPU metrics in namespace (to see pod names)"

echo ""
echo "=== Done ==="
