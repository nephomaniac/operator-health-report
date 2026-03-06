#!/usr/bin/env bash
#
# Collect Pod Health Checks for Production Readiness
#
# This script collects health metrics for pods in a deployment to determine
# if the current operator version is ready for production release.
#
# Health metrics collected:
#   - Pod uptime
#   - Restart counts
#   - Error events
#   - Pod status
#   - Operator version
#
# Usage:
#   ./collect_pod_health.sh [OPTIONS]
#
# Output: CSV format suitable for aggregation across multiple clusters
#

set -uo pipefail
# Note: NOT using set -e to allow graceful error handling and data collection

# Default values
NAMESPACE="openshift-monitoring"
DEPLOYMENT="configure-alertmanager-operator"
OUTPUT_FORMAT="csv"
CLUSTER_ID=""
CLUSTER_NAME=""
CLUSTER_VERSION=""
REASON=""
OPERATOR_NAME=""

# Parse command line arguments
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Collect health check data for production readiness

OPTIONS:
    --namespace, -n NAMESPACE   Namespace to query (default: openshift-monitoring)
    --deployment, -d DEPLOY     Deployment name (default: configure-alertmanager-operator)
    --format, -f FORMAT         Output format: csv or json (default: csv)
    --cluster-id, -c ID         Cluster ID for tracking (auto-detected if not provided)
    --cluster-name NAME         Cluster name for display (auto-detected if not provided)
    --cluster-version VERSION   Cluster OpenShift version (auto-detected if not provided)
    --reason, -r REASON         JIRA ticket for OCM elevation (required for OCM clusters)
    --operator-name NAME        Operator name for tracking (defaults to deployment name)
    --help, -h                  Show this help message

EXAMPLES:
    # Single cluster
    $0 --reason "SREP-12345 pre-release health check"

    # Custom deployment
    $0 -d route-monitor-operator -r "SREP-12345"

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
    echo "Example: --reason \"SREP-12345 pre-release health check\"" >&2
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

# Suppress normal output, only show errors on stderr and data on stdout
exec 3>&1  # Save stdout
exec 1>&2  # Redirect stdout to stderr for messages

echo "================================================================================"
echo "HEALTH CHECK - Cluster: $CLUSTER_ID"
echo "================================================================================"
echo "Operator:   $OPERATOR_NAME"
echo "Namespace:  $NAMESPACE"
echo "Deployment: $DEPLOYMENT"
echo "================================================================================"
echo ""

# Get cluster version (use provided value or fetch from cluster)
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

# Fallback to unknown if empty
if [ -z "$operator_version" ]; then
    operator_version="unknown"
fi
echo "Operator version: $operator_version"
echo ""

# Get deployment status
echo "Getting deployment status..."
deployment_json=$(ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json 2>/dev/null)
desired_replicas=$(echo "$deployment_json" | jq -r '.spec.replicas // 0' 2>/dev/null || echo "0")
ready_replicas=$(echo "$deployment_json" | jq -r '.status.readyReplicas // 0' 2>/dev/null || echo "0")
available_replicas=$(echo "$deployment_json" | jq -r '.status.availableReplicas // 0' 2>/dev/null || echo "0")
unavailable_replicas=$(echo "$deployment_json" | jq -r '.status.unavailableReplicas // 0' 2>/dev/null || echo "0")

echo "Deployment replicas:"
echo "  Desired:      $desired_replicas"
echo "  Ready:        $ready_replicas"
echo "  Available:    $available_replicas"
echo "  Unavailable:  $unavailable_replicas"
echo ""

# Get pod list
echo "Getting pod information..."
pods_json=$(ocm backplane elevate "${REASON}" -- get pods -n "$NAMESPACE" -l "name=$DEPLOYMENT" -o json 2>/dev/null)

# Parse pod data
pod_count=$(echo "$pods_json" | jq -r '.items | length' 2>/dev/null || echo "0")
echo "Found $pod_count pods"
echo ""

# Initialize health metrics
total_restarts=0
total_errors=0
min_uptime_seconds=999999999
max_uptime_seconds=0
pod_status_summary=""
error_events=""

# Process each pod
if [ "$pod_count" -gt 0 ]; then
    echo "Analyzing pod health..."

    while IFS=$'\t' read -r pod_name pod_phase restart_count start_time; do
        if [ -z "$pod_name" ] || [ "$pod_name" = "null" ]; then
            continue
        fi

        echo "  Pod: $pod_name"
        echo "    Phase: $pod_phase"
        echo "    Restarts: $restart_count"

        # Calculate uptime
        if [ -n "$start_time" ] && [ "$start_time" != "null" ]; then
            start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" "+%s" 2>/dev/null || echo "0")
            current_epoch=$(date "+%s")
            uptime_seconds=$((current_epoch - start_epoch))

            # Update min/max uptime
            if [ "$uptime_seconds" -lt "$min_uptime_seconds" ]; then
                min_uptime_seconds=$uptime_seconds
            fi
            if [ "$uptime_seconds" -gt "$max_uptime_seconds" ]; then
                max_uptime_seconds=$uptime_seconds
            fi

            # Convert to human-readable format
            uptime_days=$((uptime_seconds / 86400))
            uptime_hours=$(( (uptime_seconds % 86400) / 3600 ))
            uptime_mins=$(( (uptime_seconds % 3600) / 60 ))
            echo "    Uptime: ${uptime_days}d ${uptime_hours}h ${uptime_mins}m (${uptime_seconds}s)"
        else
            echo "    Uptime: N/A (no start time)"
        fi

        # Accumulate restart count
        if [ -n "$restart_count" ] && [ "$restart_count" != "null" ]; then
            total_restarts=$((total_restarts + restart_count))
        fi

        # Get pod events (errors and warnings)
        echo "    Checking for error events..."
        pod_events=$(ocm backplane elevate "${REASON}" -- get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod_name" -o json 2>/dev/null | \
            jq -r '.items[] | select(.type == "Warning" or .type == "Error") | "\(.type): \(.reason) - \(.message)"' 2>/dev/null | head -5)

        if [ -n "$pod_events" ]; then
            event_count=$(echo "$pod_events" | wc -l | tr -d ' ')
            total_errors=$((total_errors + event_count))
            echo "    Events (last 5):"
            echo "$pod_events" | sed 's/^/      /'

            # Store for summary
            if [ -n "$error_events" ]; then
                error_events="$error_events; $pod_name: $event_count events"
            else
                error_events="$pod_name: $event_count events"
            fi
        else
            echo "    Events: None"
        fi

        echo ""
    done < <(echo "$pods_json" | jq -r '.items[] | [.metadata.name, .status.phase, (.status.containerStatuses[0].restartCount // 0), .status.startTime] | @tsv' 2>/dev/null)
fi

# Calculate average uptime
if [ "$pod_count" -gt 0 ]; then
    avg_uptime_seconds=$(( (min_uptime_seconds + max_uptime_seconds) / 2 ))
else
    avg_uptime_seconds=0
fi

# Determine health status
health_status="HEALTHY"
health_issues=""

if [ "$ready_replicas" != "$desired_replicas" ]; then
    health_status="WARNING"
    health_issues="${health_issues}Not all replicas ready ($ready_replicas/$desired_replicas); "
fi

if [ "$total_restarts" -gt 5 ]; then
    health_status="WARNING"
    health_issues="${health_issues}High restart count ($total_restarts); "
fi

if [ "$total_errors" -gt 10 ]; then
    health_status="CRITICAL"
    health_issues="${health_issues}High error event count ($total_errors); "
fi

# Check for pods in non-running state
non_running=$(echo "$pods_json" | jq -r '[.items[] | select(.status.phase != "Running")] | length' 2>/dev/null || echo "0")
if [ "$non_running" -gt 0 ]; then
    health_status="WARNING"
    health_issues="${health_issues}$non_running pods not in Running state; "
fi

# Uptime threshold: warn if any pod is less than 1 hour old (potential crash loop)
if [ "$min_uptime_seconds" -lt 3600 ] && [ "$pod_count" -gt 0 ]; then
    health_status="WARNING"
    health_issues="${health_issues}Recent pod restart (uptime < 1h); "
fi

# CAMO-specific checks: alertmanager-main and configure-alertmanager-operator pods
# These pods are managed by CAMO and should be healthy
echo "Checking CAMO-managed resources..."

# Check alertmanager-main-* pods (read-only operation, no elevation needed)
echo "  Checking alertmanager-main pods..."
alertmanager_pods=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=alertmanager" -o json 2>/dev/null)
alertmanager_pod_count=$(echo "$alertmanager_pods" | jq -r '.items | length' 2>/dev/null || echo "0")

if [ "$alertmanager_pod_count" -gt 0 ]; then
    # Check for non-Running or non-Ready alertmanager pods
    alertmanager_issues=$(echo "$alertmanager_pods" | jq -r '.items[] | select(.status.phase != "Running" or ([.status.conditions[]? | select(.type == "Ready" and .status == "False")] | length > 0)) | .metadata.name' 2>/dev/null)

    if [ -n "$alertmanager_issues" ]; then
        alertmanager_issue_count=$(echo "$alertmanager_issues" | wc -l | tr -d ' ')
        health_status="CRITICAL"
        health_issues="${health_issues}$alertmanager_issue_count alertmanager-main pod(s) down or not ready: $(echo "$alertmanager_issues" | tr '\n' ',' | sed 's/,$//'); "
        echo "    ✗ Found $alertmanager_issue_count alertmanager pod(s) with issues:"
        echo "$alertmanager_issues" | sed 's/^/      /'
    else
        echo "    ✓ All $alertmanager_pod_count alertmanager pods are Running and Ready"
    fi
else
    echo "    ℹ No alertmanager pods found (may not be deployed yet)"
fi

# Check configure-alertmanager-operator-* pods (read-only operation, no elevation needed)
echo "  Checking configure-alertmanager-operator pods..."
camo_op_pods=$(oc get pods -n "$NAMESPACE" -l "name=configure-alertmanager-operator" -o json 2>/dev/null)
camo_op_pod_count=$(echo "$camo_op_pods" | jq -r '.items | length' 2>/dev/null || echo "0")

if [ "$camo_op_pod_count" -gt 0 ]; then
    # Check for non-Running or non-Ready operator pods
    camo_op_issues=$(echo "$camo_op_pods" | jq -r '.items[] | select(.status.phase != "Running" or ([.status.conditions[]? | select(.type == "Ready" and .status == "False")] | length > 0)) | .metadata.name' 2>/dev/null)

    if [ -n "$camo_op_issues" ]; then
        camo_op_issue_count=$(echo "$camo_op_issues" | wc -l | tr -d ' ')
        health_status="CRITICAL"
        health_issues="${health_issues}$camo_op_issue_count configure-alertmanager-operator pod(s) down or not ready: $(echo "$camo_op_issues" | tr '\n' ',' | sed 's/,$//'); "
        echo "    ✗ Found $camo_op_issue_count operator pod(s) with issues:"
        echo "$camo_op_issues" | sed 's/^/      /'
    else
        echo "    ✓ All $camo_op_pod_count operator pods are Running and Ready"
    fi
else
    echo "    ℹ No configure-alertmanager-operator pods found (may not be deployed yet)"
fi

echo ""

# Clean up trailing separator
health_issues=$(echo "$health_issues" | sed 's/; $//')

# Display summary
echo "================================================================================"
echo "HEALTH SUMMARY"
echo "================================================================================"
echo "Health Status:     $health_status"
if [ -n "$health_issues" ]; then
    echo "Issues:            $health_issues"
fi
echo ""
echo "Pod Metrics:"
echo "  Total Restarts:  $total_restarts"
echo "  Error Events:    $total_errors"
echo "  Min Uptime:      ${min_uptime_seconds}s"
echo "  Max Uptime:      ${max_uptime_seconds}s"
echo "  Avg Uptime:      ${avg_uptime_seconds}s"
echo ""
echo "Recommendation:"
if [ "$health_status" = "HEALTHY" ]; then
    echo "  ✓ Operator appears healthy and stable for production release"
elif [ "$health_status" = "WARNING" ]; then
    echo "  ⚠ Review warnings before production release"
else
    echo "  ✗ Critical issues detected - do NOT release to production"
fi
echo "================================================================================"
echo ""

# Restore stdout and output data
exec 1>&3

# Escape any commas in text fields for CSV
error_events_csv=$(echo "$error_events" | sed 's/,/;/g')
health_issues_csv=$(echo "$health_issues" | sed 's/,/;/g')

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
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "health": {
    "status": "$health_status",
    "issues": "$health_issues"
  },
  "deployment_status": {
    "desired_replicas": $desired_replicas,
    "ready_replicas": $ready_replicas,
    "available_replicas": $available_replicas,
    "unavailable_replicas": $unavailable_replicas
  },
  "pod_metrics": {
    "count": $pod_count,
    "total_restarts": $total_restarts,
    "error_events": $total_errors,
    "min_uptime_seconds": $min_uptime_seconds,
    "max_uptime_seconds": $max_uptime_seconds,
    "avg_uptime_seconds": $avg_uptime_seconds
  },
  "error_summary": "$error_events"
}
EOF
else
    # CSV format
    echo "$OPERATOR_NAME,$CLUSTER_ID,$CLUSTER_NAME,$cluster_version,$operator_version,$NAMESPACE,$DEPLOYMENT,$health_status,\"$health_issues_csv\",$desired_replicas,$ready_replicas,$available_replicas,$unavailable_replicas,$pod_count,$total_restarts,$total_errors,$min_uptime_seconds,$max_uptime_seconds,$avg_uptime_seconds,\"$error_events_csv\",$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
