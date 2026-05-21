#!/bin/bash
#
# Analyze AlertManager log timing vs pod/deployment events
#
# This script correlates AlertManager warning logs (especially DNS lookup failures)
# with pod lifecycle events to determine if warnings are expected during normal
# startup/reconfiguration windows.
#

set -euo pipefail

NAMESPACE="${NAMESPACE:-openshift-monitoring}"
LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-30}"

echo "=================================================================="
echo "AlertManager Log Timing Analysis"
echo "=================================================================="
echo "Namespace: $NAMESPACE"
echo "Lookback: Last $LOOKBACK_MINUTES minutes"
echo ""

# Get current time for reference
current_time=$(date -u +%s)
lookback_seconds=$((LOOKBACK_MINUTES * 60))
cutoff_time=$((current_time - lookback_seconds))

echo "1. Analyzing AlertManager pod events..."
echo "=================================================================="
echo ""

# Get AlertManager pods
am_pods=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=alertmanager -o json)

echo "$am_pods" | jq -r '.items[] |
  "Pod: \(.metadata.name)",
  "  Created: \(.metadata.creationTimestamp)",
  "  Phase: \(.status.phase)",
  "  Container Statuses:",
  (.status.containerStatuses[]? |
    "    \(.name): ready=\(.ready), restarts=\(.restartCount), state=\(.state | keys[0])"
  ),
  ""'

echo ""
echo "2. Recent pod events (last $LOOKBACK_MINUTES min)..."
echo "=================================================================="
echo ""

oc get events -n "$NAMESPACE" \
  --field-selector involvedObject.kind=Pod \
  --sort-by='.lastTimestamp' 2>/dev/null | \
  grep alertmanager-main | tail -20

echo ""
echo "3. AlertManager StatefulSet events..."
echo "=================================================================="
echo ""

oc get events -n "$NAMESPACE" \
  --field-selector involvedObject.kind=StatefulSet,involvedObject.name=alertmanager-main \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -10

echo ""
echo "4. CAMO deployment events..."
echo "=================================================================="
echo ""

oc get events -n "$NAMESPACE" \
  --field-selector involvedObject.kind=Deployment,involvedObject.name=configure-alertmanager-operator \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -10

echo ""
echo "5. Analyzing AlertManager logs with timestamps..."
echo "=================================================================="
echo ""

# Get logs from each AlertManager pod
for pod in $(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=alertmanager -o name 2>/dev/null); do
    pod_name=${pod#pod/}
    echo "Pod: $pod_name"
    echo "----------------------------------------"

    # Get pod start time
    pod_start=$(oc get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.startTime}' 2>/dev/null || echo "unknown")
    echo "Pod started: $pod_start"
    echo ""

    # Get recent logs with grep for common warning patterns
    echo "Recent WARNING logs:"
    oc logs "$pod_name" -n "$NAMESPACE" --tail=500 2>/dev/null | \
      grep -i "level=WARN" | \
      tail -20

    echo ""
    echo "DNS lookup failure logs:"
    oc logs "$pod_name" -n "$NAMESPACE" --tail=500 2>/dev/null | \
      grep -i "no such host\|Failed to resolve" | \
      tail -10

    echo ""
    echo ""
done

echo ""
echo "6. Timeline correlation analysis..."
echo "=================================================================="
echo ""

# Get detailed pod info with creation and ready times
for pod in $(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=alertmanager -o name 2>/dev/null); do
    pod_name=${pod#pod/}

    echo "Pod: $pod_name"
    echo "----------------------------------------"

    # Get pod creation time
    created=$(oc get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
    echo "Created: $created"

    # Get container ready time from conditions
    ready_time=$(oc get pod "$pod_name" -n "$NAMESPACE" -o json 2>/dev/null | \
      jq -r '.status.conditions[] | select(.type=="Ready") | .lastTransitionTime' || echo "unknown")
    echo "Ready: $ready_time"

    # Calculate time to ready (if both timestamps available)
    if [ "$created" != "unknown" ] && [ "$ready_time" != "unknown" ]; then
        created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" "+%s" 2>/dev/null || echo 0)
        ready_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ready_time" "+%s" 2>/dev/null || echo 0)

        if [ "$created_epoch" -gt 0 ] && [ "$ready_epoch" -gt 0 ]; then
            time_to_ready=$((ready_epoch - created_epoch))
            echo "Time to ready: ${time_to_ready}s"
        fi
    fi

    # Get most recent restart time if any
    restart_count=$(oc get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)
    if [ "$restart_count" -gt 0 ]; then
        last_state=$(oc get pod "$pod_name" -n "$NAMESPACE" -o json 2>/dev/null | \
          jq -r '.status.containerStatuses[0].lastState.terminated.finishedAt // "unknown"')
        echo "Last restart: $last_state (total: $restart_count)"
    fi

    echo ""

    # Get timestamps from warning logs
    echo "Warning log timestamps:"
    oc logs "$pod_name" -n "$NAMESPACE" --tail=500 2>/dev/null | \
      grep "level=WARN.*no such host" | \
      grep -o "time=[^ ]*" | \
      head -5

    echo ""
    echo ""
done

echo ""
echo "7. Summary and recommendations..."
echo "=================================================================="
echo ""
echo "Expected timing windows for DNS lookup warnings:"
echo "  - During pod startup: 0-120 seconds after pod creation"
echo "  - During StatefulSet scaling: 0-60 seconds after new pod added"
echo "  - During pod restarts: 0-120 seconds after container restart"
echo ""
echo "If warnings occur ONLY within these windows, they are expected and"
echo "should not be flagged as health issues."
echo ""
echo "To verify: Compare warning log timestamps with pod creation/restart times."
echo "Warnings > 5 minutes after pod ready = actual issue"
echo "Warnings < 2 minutes after pod start = expected during cluster formation"
echo ""
