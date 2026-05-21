#!/bin/bash
#
# Check actual timestamps of DNS warnings to see when they occur
#

NAMESPACE="${NAMESPACE:-openshift-monitoring}"

echo "Checking when DNS warnings actually occur"
echo "=========================================="
echo ""

for pod in alertmanager-main-0 alertmanager-main-1; do
    echo "Pod: $pod"
    echo "----------"

    # Get pod info
    echo "Pod created: $(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
    echo "Restarts: $(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"

    last_restart=$(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.finishedAt}' 2>/dev/null)
    if [ -n "$last_restart" ]; then
        echo "Last restart finished: $last_restart"
    fi

    echo ""
    echo "DNS warning timestamps (showing all):"
    oc logs "$pod" -n "$NAMESPACE" --tail=1000 2>/dev/null | \
        grep -i "level=WARN.*\(no such host\|Failed to resolve\)" | \
        grep -o "time=[^ ]*" | \
        sort -u

    echo ""
    echo "First DNS warning:"
    oc logs "$pod" -n "$NAMESPACE" --tail=1000 2>/dev/null | \
        grep -i "level=WARN.*\(no such host\|Failed to resolve\)" | \
        head -1

    echo ""
    echo "Last DNS warning:"
    oc logs "$pod" -n "$NAMESPACE" --tail=1000 2>/dev/null | \
        grep -i "level=WARN.*\(no such host\|Failed to resolve\)" | \
        tail -1

    echo ""
    echo "=========================================="
    echo ""
done

echo ""
echo "Other recent events that might correlate:"
echo "=========================================="
echo ""

# Check for recent pod events
echo "Recent pod events:"
oc get events -n "$NAMESPACE" --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp' 2>/dev/null | grep alertmanager | tail -10

echo ""
echo "Recent service/endpoint events:"
oc get events -n "$NAMESPACE" --field-selector involvedObject.kind=Service --sort-by='.lastTimestamp' 2>/dev/null | grep alertmanager | tail -10

echo ""
echo "Recent configmap changes (CAMO reconfigurations):"
oc get events -n "$NAMESPACE" --field-selector involvedObject.kind=ConfigMap --sort-by='.lastTimestamp' 2>/dev/null | tail -10
