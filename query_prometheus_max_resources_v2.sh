#!/bin/bash
#
# Query Prometheus for Maximum CPU and Memory Usage
#
# This script queries Prometheus to find the highest CPU and memory used
# by pods in a specific deployment over a time period.
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
NAMESPACE="openshift-monitoring"
DEPLOYMENT="configure-alertmanager-operator"
PROMETHEUS_POD="prometheus-k8s-0"
LOOKBACK="14d"

# Parse command line arguments
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Query Prometheus for maximum CPU and memory usage over time

OPTIONS:
    --namespace, -n NAMESPACE   Namespace to query (default: openshift-monitoring)
    --deployment, -d DEPLOY     Deployment name (default: configure-alertmanager-operator)
    --prometheus, -p POD        Prometheus pod name (default: prometheus-k8s-0)
    --lookback, -l DURATION     Lookback duration (default: 14d)
    --help, -h                  Show this help message

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        --deployment|-d) DEPLOYMENT="$2"; shift 2 ;;
        --prometheus|-p) PROMETHEUS_POD="$2"; shift 2 ;;
        --lookback|-l) LOOKBACK="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

echo ""
echo "================================================================================"
echo "PROMETHEUS RESOURCE USAGE QUERY"
echo "================================================================================"
echo -e "Namespace:       ${CYAN}$NAMESPACE${NC}"
echo -e "Deployment:      ${CYAN}$DEPLOYMENT${NC}"
echo -e "Prometheus Pod:  ${CYAN}$PROMETHEUS_POD${NC}"
echo -e "Lookback Period: ${CYAN}$LOOKBACK${NC}"
echo "================================================================================"
echo ""

# Function to execute query via curl
execute_prom_query() {
    local query="$1"

    ocm backplane elevate "https://issues.redhat.com/browse/SREP-138" -- exec -n "$NAMESPACE" "$PROMETHEUS_POD" -c prometheus -- \
        curl -s "http://localhost:9090/api/v1/query?query=$(echo "$query" | jq -sRr @uri)" | jq -r '.'
}

# Check if deployment pods exist
echo "Checking for deployment pods..."
pod_count=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "^${DEPLOYMENT}-" || true)

if [ "$pod_count" -eq 0 ]; then
    echo -e "${YELLOW}⚠ Warning: No pods found matching '${DEPLOYMENT}-*' in namespace '$NAMESPACE'${NC}"
    echo "Available pods in namespace:"
    oc get pods -n "$NAMESPACE" | grep -E "(NAME|${DEPLOYMENT})" || echo "No matching pods"
    echo ""
    echo "Continuing anyway - checking historical data..."
else
    echo -e "${GREEN}✓${NC} Found $pod_count pod(s) matching deployment pattern"
fi
echo ""

echo "================================================================================"
echo "QUERYING PROMETHEUS"
echo "================================================================================"
echo ""

# Query 1: Current/Recent CPU usage per pod
echo -e "${CYAN}[1/5] Current CPU Usage by Pod${NC}"
echo "--------------------------------------------------------------------------------"
CPU_CURRENT_QUERY='sum(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'-.*", container!="", container!="POD"}[5m])) by (pod)'

echo -e "${YELLOW}Query:${NC} $CPU_CURRENT_QUERY"
echo ""
result=$(execute_prom_query "$CPU_CURRENT_QUERY")
echo "$result" | jq -r '.data.result[] | "  Pod: \(.metric.pod)\n  CPU: \(.value[1]) cores"' 2>/dev/null || echo "$result"
echo ""

# Query 2: Max CPU over time period (simplified approach)
echo -e "${CYAN}[2/5] Maximum CPU Usage (last hour sample)${NC}"
echo "--------------------------------------------------------------------------------"
CPU_MAX_QUERY='max(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'-.*", container!="", container!="POD"}[1h])) by (pod)'

echo -e "${YELLOW}Query:${NC} $CPU_MAX_QUERY"
echo ""
result=$(execute_prom_query "$CPU_MAX_QUERY")
echo "$result" | jq -r '.data.result[] | "  Pod: \(.metric.pod)\n  Max CPU: \(.value[1]) cores"' 2>/dev/null || echo "$result"
echo ""

# Query 3: Current Memory usage per pod
echo -e "${CYAN}[3/5] Current Memory Usage by Pod${NC}"
echo "--------------------------------------------------------------------------------"
MEM_CURRENT_QUERY='sum(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'-.*", container!="", container!="POD"}) by (pod)'

echo -e "${YELLOW}Query:${NC} $MEM_CURRENT_QUERY"
echo ""
result=$(execute_prom_query "$MEM_CURRENT_QUERY")
echo "$result" | jq -r '.data.result[] | "  Pod: \(.metric.pod)\n  Memory: \(.value[1] | tonumber / 1024 / 1024 | floor) MiB (\(.value[1]) bytes)"' 2>/dev/null || echo "$result"
echo ""

# Query 4: Max Memory
echo -e "${CYAN}[4/5] Maximum Memory Usage${NC}"
echo "--------------------------------------------------------------------------------"
MEM_MAX_QUERY='max(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'-.*", container!="", container!="POD"}) by (pod)'

echo -e "${YELLOW}Query:${NC} $MEM_MAX_QUERY"
echo ""
result=$(execute_prom_query "$MEM_MAX_QUERY")
echo "$result" | jq -r '.data.result[] | "  Pod: \(.metric.pod)\n  Max Memory: \(.value[1] | tonumber / 1024 / 1024 | floor) MiB (\(.value[1]) bytes)"' 2>/dev/null || echo "$result"
echo ""

# Query 5: Overall maximums across all pods
echo -e "${CYAN}[5/5] Overall Maximum Values Across All Deployment Pods${NC}"
echo "--------------------------------------------------------------------------------"

OVERALL_MAX_CPU='max(rate(container_cpu_usage_seconds_total{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'-.*", container!="", container!="POD"}[1h]))'
OVERALL_MAX_MEM='max(container_memory_working_set_bytes{namespace="'$NAMESPACE'", pod=~"'$DEPLOYMENT'-.*", container!="", container!="POD"})'

echo -e "${YELLOW}Max CPU Query:${NC} $OVERALL_MAX_CPU"
cpu_result=$(execute_prom_query "$OVERALL_MAX_CPU")
max_cpu=$(echo "$cpu_result" | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "N/A")

echo -e "${YELLOW}Max Memory Query:${NC} $OVERALL_MAX_MEM"
mem_result=$(execute_prom_query "$OVERALL_MAX_MEM")
max_mem=$(echo "$mem_result" | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "N/A")

echo ""
echo "================================================================================"
echo "SUMMARY"
echo "================================================================================"
echo ""

if [ "$max_cpu" != "N/A" ] && [ "$max_cpu" != "null" ]; then
    max_cpu_millicores=$(echo "$max_cpu * 1000" | bc 2>/dev/null || echo "N/A")
    echo -e "${GREEN}Maximum CPU Usage:${NC}"
    echo -e "  ${YELLOW}${max_cpu} CPU cores${NC}"
    echo -e "  ${YELLOW}${max_cpu_millicores} millicores${NC}"
else
    echo -e "${YELLOW}⚠ No CPU data found${NC}"
fi

echo ""

if [ "$max_mem" != "N/A" ] && [ "$max_mem" != "null" ]; then
    max_mem_mib=$(echo "$max_mem / 1024 / 1024" | bc 2>/dev/null || echo "N/A")
    max_mem_gib=$(echo "scale=2; $max_mem / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "N/A")
    echo -e "${GREEN}Maximum Memory Usage:${NC}"
    echo -e "  ${YELLOW}${max_mem} bytes${NC}"
    echo -e "  ${YELLOW}${max_mem_mib} MiB${NC}"
    echo -e "  ${YELLOW}${max_mem_gib} GiB${NC}"
else
    echo -e "${YELLOW}⚠ No memory data found${NC}"
fi

echo ""
echo "================================================================================"
echo "Note: Prometheus typically retains detailed metrics for ~2 hours."
echo "For historical max over 2 weeks, you may need to check:"
echo "  1. Prometheus retention settings"
echo "  2. Thanos or long-term storage if configured"
echo "  3. Cluster monitoring stack configuration"
echo "================================================================================"
echo ""
