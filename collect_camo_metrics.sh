#!/usr/bin/env bash
#
# Collect CAMO Prometheus Metrics
#
# This script collects CAMO-specific Prometheus metrics from the operator pod
# to assess operator health and configuration state.
#
# Metrics collected (all gauge metrics with values 0 or 1):
#   - ga_secret_exists
#   - pd_secret_exists
#   - dms_secret_exists
#   - am_secret_exists
#   - am_secret_contains_ga
#   - am_secret_contains_pd
#   - am_secret_contains_dms
#   - managed_namespaces_configmap_exists
#   - ocp_namespaces_configmap_exists
#   - alertmanager_config_validation_failed
#
# Usage:
#   ./collect_camo_metrics.sh [OPTIONS]
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
OPERATOR_NAME="configure-alertmanager-operator"

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Collect CAMO Prometheus metrics for operator health assessment

OPTIONS:
    --namespace, -n NAMESPACE   Namespace (default: openshift-monitoring)
    --deployment, -d DEPLOY     Deployment name (default: configure-alertmanager-operator)
    --format, -f FORMAT         Output format: csv or json (default: csv)
    --cluster-id, -c ID         Cluster ID
    --cluster-name NAME         Cluster name
    --cluster-version VERSION   Cluster OpenShift version
    --reason, -r REASON         JIRA ticket for OCM elevation (required)
    --help, -h                  Show this help message

EXAMPLES:
    $0 --reason "SREP-12345 metrics collection"

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
        --help|-h) usage ;;
        *) echo "Error: Unknown option: $1" >&2; usage ;;
    esac
done

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
echo "CAMO METRICS COLLECTION - Cluster: $CLUSTER_ID"
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

# Get operator version from CSV
echo "Getting operator version..."
operator_version=$(ocm backplane elevate "${REASON}" -- get csv -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r ".items[]? | select(.metadata.name | startswith(\"$OPERATOR_NAME\")) | .spec.version // \"unknown\"" 2>/dev/null | \
    head -1)

if [ -z "$operator_version" ]; then
    operator_version="unknown"
fi
echo "Operator version: $operator_version"
echo ""

# Get CAMO pod name
echo "Finding CAMO operator pod..."
camo_pod=$(oc get pods -n "$NAMESPACE" -l "name=$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$camo_pod" ] || [ "$camo_pod" = "null" ]; then
    echo "Error: No CAMO operator pod found" >&2
    exit 1
fi

echo "CAMO pod: $camo_pod"
echo ""

# Scrape metrics from pod
echo "Scraping Prometheus metrics from pod..."
metrics_output=$(oc exec -n "$NAMESPACE" "$camo_pod" -- curl -s http://localhost:8080/metrics 2>/dev/null)

if [ -z "$metrics_output" ]; then
    echo "Error: Failed to scrape metrics from pod" >&2
    exit 1
fi

echo "Metrics scraped successfully"
echo ""

# Parse CAMO-specific metrics
echo "Parsing CAMO metrics..."

# Extract metric values (all are gauge metrics with 0 or 1 values)
ga_secret_exists=$(echo "$metrics_output" | grep '^ga_secret_exists{' | grep -oP 'ga_secret_exists{.*?}\s+\K\d+' || echo "0")
pd_secret_exists=$(echo "$metrics_output" | grep '^pd_secret_exists{' | grep -oP 'pd_secret_exists{.*?}\s+\K\d+' || echo "0")
dms_secret_exists=$(echo "$metrics_output" | grep '^dms_secret_exists{' | grep -oP 'dms_secret_exists{.*?}\s+\K\d+' || echo "0")
am_secret_exists=$(echo "$metrics_output" | grep '^am_secret_exists{' | grep -oP 'am_secret_exists{.*?}\s+\K\d+' || echo "0")
am_secret_contains_ga=$(echo "$metrics_output" | grep '^am_secret_contains_ga{' | grep -oP 'am_secret_contains_ga{.*?}\s+\K\d+' || echo "0")
am_secret_contains_pd=$(echo "$metrics_output" | grep '^am_secret_contains_pd{' | grep -oP 'am_secret_contains_pd{.*?}\s+\K\d+' || echo "0")
am_secret_contains_dms=$(echo "$metrics_output" | grep '^am_secret_contains_dms{' | grep -oP 'am_secret_contains_dms{.*?}\s+\K\d+' || echo "0")
managed_ns_cm_exists=$(echo "$metrics_output" | grep '^managed_namespaces_configmap_exists{' | grep -oP 'managed_namespaces_configmap_exists{.*?}\s+\K\d+' || echo "0")
ocp_ns_cm_exists=$(echo "$metrics_output" | grep '^ocp_namespaces_configmap_exists{' | grep -oP 'ocp_namespaces_configmap_exists{.*?}\s+\K\d+' || echo "0")
am_config_validation_failed=$(echo "$metrics_output" | grep '^alertmanager_config_validation_failed{' | grep -oP 'alertmanager_config_validation_failed{.*?}\s+\K\d+' || echo "0")

# Display parsed metrics
echo "Metric Values:"
echo "  ga_secret_exists:                        $ga_secret_exists"
echo "  pd_secret_exists:                        $pd_secret_exists"
echo "  dms_secret_exists:                       $dms_secret_exists"
echo "  am_secret_exists:                        $am_secret_exists"
echo "  am_secret_contains_ga:                   $am_secret_contains_ga"
echo "  am_secret_contains_pd:                   $am_secret_contains_pd"
echo "  am_secret_contains_dms:                  $am_secret_contains_dms"
echo "  managed_namespaces_configmap_exists:     $managed_ns_cm_exists"
echo "  ocp_namespaces_configmap_exists:         $ocp_ns_cm_exists"
echo "  alertmanager_config_validation_failed:   $am_config_validation_failed"
echo ""

# Health assessment
health_status="HEALTHY"
health_issues=""

if [ "$am_secret_exists" != "1" ]; then
    health_status="CRITICAL"
    health_issues="${health_issues}AlertManager secret missing; "
fi

if [ "$am_config_validation_failed" = "1" ]; then
    health_status="CRITICAL"
    health_issues="${health_issues}AlertManager config validation failed; "
fi

if [ "$managed_ns_cm_exists" != "1" ]; then
    health_status="WARNING"
    health_issues="${health_issues}managed-namespaces ConfigMap missing; "
fi

if [ "$ocp_ns_cm_exists" != "1" ]; then
    health_status="WARNING"
    health_issues="${health_issues}ocp-namespaces ConfigMap missing; "
fi

# Clean up trailing separator
health_issues=$(echo "$health_issues" | sed 's/; $//')

echo "================================================================================"
echo "METRICS HEALTH ASSESSMENT"
echo "================================================================================"
echo "Health Status: $health_status"
if [ -n "$health_issues" ]; then
    echo "Issues:        $health_issues"
fi
echo "================================================================================"
echo ""

# Restore stdout and output data
exec 1>&3

# Output in requested format
if [ "$OUTPUT_FORMAT" = "json" ]; then
    cat << EOF
{
  "cluster_id": "$CLUSTER_ID",
  "cluster_name": "$CLUSTER_NAME",
  "cluster_version": "$cluster_version",
  "operator_version": "$operator_version",
  "namespace": "$NAMESPACE",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "health_status": "$health_status",
  "health_issues": "$health_issues",
  "metrics": {
    "ga_secret_exists": $ga_secret_exists,
    "pd_secret_exists": $pd_secret_exists,
    "dms_secret_exists": $dms_secret_exists,
    "am_secret_exists": $am_secret_exists,
    "am_secret_contains_ga": $am_secret_contains_ga,
    "am_secret_contains_pd": $am_secret_contains_pd,
    "am_secret_contains_dms": $am_secret_contains_dms,
    "managed_namespaces_configmap_exists": $managed_ns_cm_exists,
    "ocp_namespaces_configmap_exists": $ocp_ns_cm_exists,
    "alertmanager_config_validation_failed": $am_config_validation_failed
  }
}
EOF
else
    # CSV format
    echo "$CLUSTER_ID,$CLUSTER_NAME,$cluster_version,$operator_version,$NAMESPACE,$health_status,\"$health_issues\",$ga_secret_exists,$pd_secret_exists,$dms_secret_exists,$am_secret_exists,$am_secret_contains_ga,$am_secret_contains_pd,$am_secret_contains_dms,$managed_ns_cm_exists,$ocp_ns_cm_exists,$am_config_validation_failed,$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
