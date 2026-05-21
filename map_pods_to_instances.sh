#!/bin/bash

echo "==================================================================="
echo "Mapping Affected Pods to EC2 Instances"
echo "==================================================================="
echo ""

# Step 1: Get pod names with readiness failures from Dynatrace events
echo "[Step 1] Extracting pods with readiness failures from Dynatrace events..."
AFFECTED_PODS=$(awk -F',' 'NR>1 && $3 ~ /Readiness probe failed|Node is not ready/ {print $4}' \
    /Users/maclark/operator-health-report/table-data-all-ns-events.csv | \
    tr -d '"' | sort -u | head -20)

POD_COUNT=$(echo "$AFFECTED_PODS" | wc -l | tr -d ' ')
echo "Found ${POD_COUNT} unique pods with issues"
echo ""

# Step 2: Check which pods still exist and get their nodes
echo "[Step 2] Checking which pods still exist in dynatrace namespace..."
rm -f pod-to-node.csv 2>/dev/null
echo "pod_name,node_name" > pod-to-node.csv

FOUND_PODS=0
for POD in $AFFECTED_PODS; do
    NODE=$(oc get pod ${POD} -n dynatrace -o jsonpath='{.spec.nodeName}' 2>/dev/null)

    if [ ! -z "$NODE" ] && [ "$NODE" != "" ]; then
        echo "  ✓ ${POD} -> ${NODE}"
        echo "${POD},${NODE}" >> pod-to-node.csv
        FOUND_PODS=$((FOUND_PODS + 1))
    fi
done

echo ""
echo "Found ${FOUND_PODS} existing pods"
echo ""

if [ ${FOUND_PODS} -eq 0 ]; then
    echo "⚠️  No existing pods found. All may have been terminated."
    echo ""
    echo "Alternative: Checking nodes from mount error list..."

    # Fallback: Use mount error nodes
    awk -F',' 'NR>1 {print "N/A," $3}' /Users/maclark/operator-health-report/table-data-write.csv | \
        tr -d '"' | sort -u | head -5 >> pod-to-node.csv
fi

# Step 3: Get unique nodes and find their instance IDs
echo "[Step 3] Finding EC2 instance IDs for these nodes..."
NODES=$(awk -F',' 'NR>1 {print $2}' pod-to-node.csv | sort -u)

rm -f node-to-instance.csv 2>/dev/null
echo "node_name,instance_id,region" > node-to-instance.csv

FOUND_INSTANCES=0
for NODE in $NODES; do
    echo -n "  Checking ${NODE} ... "

    # Try multiple regions
    for REGION in us-east-1 us-east-2 us-west-2; do
        INSTANCE_ID=$(aws ec2 describe-instances \
            --region ${REGION} \
            --filters "Name=private-dns-name,Values=${NODE}" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null)

        if [ "$INSTANCE_ID" != "None" ] && [ "$INSTANCE_ID" != "" ] && [ "$INSTANCE_ID" != "null" ]; then
            echo "✓ ${INSTANCE_ID} (${REGION})"
            echo "${NODE},${INSTANCE_ID},${REGION}" >> node-to-instance.csv
            FOUND_INSTANCES=$((FOUND_INSTANCES + 1))
            break
        fi
    done

    if [ "$INSTANCE_ID" == "None" ] || [ -z "$INSTANCE_ID" ]; then
        echo "✗ Not found"
    fi
done

echo ""
echo "==================================================================="
echo "Summary"
echo "==================================================================="
echo "Affected pods in Dynatrace events: ${POD_COUNT}"
echo "Still existing pods: ${FOUND_PODS}"
echo "EC2 instances found: ${FOUND_INSTANCES}"
echo ""

if [ ${FOUND_INSTANCES} -gt 0 ]; then
    echo "Mapped instances:"
    cat node-to-instance.csv | column -t -s','
    echo ""
    echo "Files created:"
    echo "  - pod-to-node.csv (pod -> node mapping)"
    echo "  - node-to-instance.csv (node -> instance mapping)"
    echo ""
    echo "Next: Pick an instance ID and update collect_ebs_metrics.sh"
else
    echo "⚠️  No running instances found"
    echo "Options:"
    echo "  1. Nodes may have been terminated/recycled"
    echo "  2. Check if cluster still exists"
    echo "  3. Proceed with existing analysis from unaffected node"
fi
