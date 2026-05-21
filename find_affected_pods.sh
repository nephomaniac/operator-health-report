#!/bin/bash

echo "==================================================================="
echo "Finding Affected Pods and Their Nodes"
echo "==================================================================="
echo ""

# Get pod names that had readiness failures from Dynatrace events
PODS=$(awk -F',' 'NR>1 && $3 ~ /Readiness probe failed/ {print $4}' /Users/maclark/operator-health-report/table-data-all-ns-events.csv | tr -d '"' | sort -u | head -10)

echo "Sample pods with readiness failures:"
echo "$PODS"
echo ""
echo "Checking which pods still exist and getting their node assignments..."
echo ""

rm -f affected-pods-nodes.csv 2>/dev/null
echo "pod_name,node_name,status" > affected-pods-nodes.csv

for POD in $PODS; do
    echo -n "Checking ${POD} ... "
    
    # Try to get pod details from dynatrace namespace
    POD_INFO=$(oc get pod ${POD} -n dynatrace -o json 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        NODE=$(echo "$POD_INFO" | jq -r '.spec.nodeName // "unknown"')
        STATUS=$(echo "$POD_INFO" | jq -r '.status.phase // "unknown"')
        echo "✓ Found on node: ${NODE} (${STATUS})"
        echo "${POD},${NODE},${STATUS}" >> affected-pods-nodes.csv
    else
        echo "✗ Not found (terminated?)"
    fi
done

echo ""
if [ -f affected-pods-nodes.csv ] && [ $(wc -l < affected-pods-nodes.csv) -gt 1 ]; then
    echo "Results saved to: affected-pods-nodes.csv"
    cat affected-pods-nodes.csv | column -t -s','
else
    echo "⚠️  No existing pods found from Dynatrace events"
fi
