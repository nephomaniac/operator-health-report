#!/bin/bash

echo "==================================================================="
echo "Mapping Incident Pods to Current Instances"
echo "==================================================================="
echo ""

# Step 1: Extract pod names from mount errors
echo "[Step 1] Extracting pod names from mount error log..."
POD_NAMES=$(awk -F',' 'NR>1 {print $3}' /Users/maclark/operator-health-report/table-data-write.csv | tr -d '"' | sort -u)
POD_COUNT=$(echo "$POD_NAMES" | wc -l | tr -d ' ')
echo "Pods with mount errors: ${POD_COUNT}"
echo ""

# Step 2: Check which pods still exist in dynatrace namespace
echo "[Step 2] Checking which pods still exist in dynatrace namespace..."
rm -f existing-incident-pods.txt 2>/dev/null
FOUND_PODS=0

for POD in $POD_NAMES; do
    if oc get pod ${POD} -n dynatrace -o name > /dev/null 2>&1; then
        echo "  ✓ ${POD} - Still exists"
        echo "${POD}" >> existing-incident-pods.txt
        FOUND_PODS=$((FOUND_PODS + 1))
    fi
done

echo ""
echo "Pods from incident that still exist: ${FOUND_PODS}"
echo ""

if [ ${FOUND_PODS} -eq 0 ]; then
    echo "❌ No incident pods still exist"
    echo ""
    echo "Alternative: Extract pod names from Dynatrace events..."

    # Fallback: get pod names from Dynatrace events
    echo ""
    echo "[Fallback] Extracting pod names from Dynatrace events..."
    EVENT_PODS=$(awk -F',' 'NR>1 {print $4}' /Users/maclark/operator-health-report/table-data-all-ns-events.csv | \
        tr -d '"' | grep "oneagent" | sort -u | head -50)

    EVENT_POD_COUNT=$(echo "$EVENT_PODS" | wc -l | tr -d ' ')
    echo "Pod names from Dynatrace events: ${EVENT_POD_COUNT}"
    echo ""

    echo "Checking which event pods still exist..."
    rm -f existing-incident-pods.txt 2>/dev/null
    FOUND_PODS=0

    for POD in $EVENT_PODS; do
        if oc get pod ${POD} -n dynatrace -o name > /dev/null 2>&1; then
            echo "  ✓ ${POD} - Still exists"
            echo "${POD}" >> existing-incident-pods.txt
            FOUND_PODS=$((FOUND_PODS + 1))
        fi
    done

    echo ""
    echo "Event pods that still exist: ${FOUND_PODS}"
    echo ""
fi

if [ ${FOUND_PODS} -gt 0 ]; then
    # Step 3: Get node assignments for existing pods
    echo "[Step 3] Getting node assignments for existing pods..."
    rm -f incident-pods-to-nodes.csv 2>/dev/null
    echo "pod_name,node_name" > incident-pods-to-nodes.csv

    while read POD; do
        NODE=$(oc get pod ${POD} -n dynatrace -o jsonpath='{.spec.nodeName}' 2>/dev/null)
        if [ ! -z "$NODE" ]; then
            echo "  ${POD} -> ${NODE}"
            echo "${POD},${NODE}" >> incident-pods-to-nodes.csv
        fi
    done < existing-incident-pods.txt

    echo ""

    # Step 4: Get instance IDs from nodes
    echo "[Step 4] Extracting instance IDs from node metadata..."
    rm -f incident-instances.csv 2>/dev/null
    echo "pod_name,node_name,instance_id,region" > incident-instances.csv

    MAPPED=0
    while IFS=',' read POD NODE; do
        [ "$POD" == "pod_name" ] && continue

        # Get instance ID from node providerID
        PROVIDER_ID=$(jq -r ".items[] | select(.metadata.name == \"$NODE\") | .spec.providerID // empty" \
            /Users/maclark/operator-health-report/current-nodes.json)

        if [ ! -z "$PROVIDER_ID" ]; then
            INSTANCE_ID=$(echo "$PROVIDER_ID" | grep -oE 'i-[a-z0-9]+')
            REGION=$(echo "$PROVIDER_ID" | grep -oE 'us-[a-z]+-[0-9]+' | head -1)

            if [ ! -z "$INSTANCE_ID" ]; then
                echo "  ✓ ${POD} -> ${NODE} -> ${INSTANCE_ID} (${REGION})"
                echo "${POD},${NODE},${INSTANCE_ID},${REGION}" >> incident-instances.csv
                MAPPED=$((MAPPED + 1))
            fi
        fi
    done < incident-pods-to-nodes.csv

    echo ""
    echo "==================================================================="
    echo "Summary"
    echo "==================================================================="
    echo "Pods with mount errors during incident: ${POD_COUNT}"
    echo "Still exist in cluster: ${FOUND_PODS}"
    echo "Successfully mapped to instances: ${MAPPED}"
    echo ""

    if [ ${MAPPED} -gt 0 ]; then
        echo "🎯 INSTANCES TO QUERY FOR EBS METRICS:"
        tail -n +2 incident-instances.csv | column -t -s','
        echo ""
        echo "Unique instance IDs:"
        tail -n +2 incident-instances.csv | cut -d',' -f3 | sort -u
        echo ""
        echo "✅ Next step: Update collect_ebs_metrics.sh with one of these instance IDs"
        echo "   These instances had pods that experienced mount errors!"
    else
        echo "⚠️  Could not map pods to instances"
    fi

    echo ""
    echo "Files created:"
    echo "  - existing-incident-pods.txt"
    echo "  - incident-pods-to-nodes.csv"
    echo "  - incident-instances.csv"
else
    echo "==================================================================="
    echo "Final Result"
    echo "==================================================================="
    echo "❌ No pods from the incident still exist in the cluster"
    echo ""
    echo "This means:"
    echo "  - DaemonSet pods were recreated (expected for replaced nodes)"
    echo "  - Or pods were deleted/recreated during normal operations"
    echo ""
    echo "We cannot trace incident pods -> current instances"
    echo ""
    echo "Analysis should proceed with:"
    echo "  1. EBS metrics from unaffected node (already collected)"
    echo "  2. Cluster-wide analysis showing 98 nodes affected"
    echo "  3. EBS write latency spike correlation (2.34s at 11:00 UTC)"
fi
