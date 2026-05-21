#!/bin/bash
#
# Simple AlertManager warning analysis
# Checks if DNS warnings exist and when pods last started
#

NAMESPACE="${NAMESPACE:-openshift-monitoring}"

echo "AlertManager DNS Warning Analysis"
echo "=================================="
echo ""

# Get AlertManager pods
for pod in alertmanager-main-0 alertmanager-main-1; do
    echo "Pod: $pod"
    echo "----------"

    # Get pod age
    created=$(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
    echo "Created: $created"

    # Get restart count
    restart_count=$(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
    echo "Restarts: $restart_count"

    # Get last restart time if available
    if [ "$restart_count" -gt 0 ]; then
        last_restart=$(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.finishedAt}' 2>/dev/null)
        if [ -n "$last_restart" ]; then
            echo "Last restart: $last_restart"
        fi
    fi

    echo ""
    echo "DNS lookup warnings in logs:"
    oc logs "$pod" -n "$NAMESPACE" --tail=1000 2>/dev/null | \
        grep -i "level=WARN.*\(no such host\|Failed to resolve\)" | \
        head -10

    echo ""
    echo "Warning timestamps (first 5):"
    oc logs "$pod" -n "$NAMESPACE" --tail=1000 2>/dev/null | \
        grep -i "level=WARN.*\(no such host\|Failed to resolve\)" | \
        grep -o "time=[^ ]*" | \
        head -5

    echo ""
    echo "Warning count:"
    warning_count=$(oc logs "$pod" -n "$NAMESPACE" --tail=1000 2>/dev/null | \
        grep -i "level=WARN.*\(no such host\|Failed to resolve\)" | \
        wc -l | tr -d ' ')
    echo "Total: $warning_count"

    echo ""
    echo "=================================="
    echo ""
done

echo ""
echo "Recommendation:"
echo "Compare warning timestamps with pod creation/restart times."
echo "If all warnings are within 5 minutes of pod start, they are expected."
echo ""
