#!/bin/bash

echo "==================================================================="
echo "Mapping Current Dynatrace Pods to EC2 Instances"
echo "==================================================================="
echo ""

# Step 1: List all current pods in dynatrace namespace
echo "[Step 1] Getting all current pods in dynatrace namespace..."
oc get pods -n dynatrace -o json > current-dynatrace-pods.json

TOTAL_PODS=$(jq '[.items[]] | length' current-dynatrace-pods.json)
echo "Total pods in dynatrace namespace: ${TOTAL_PODS}"
echo ""

# Step 2: Extract pod-to-node mapping for OneAgent pods
echo "[Step 2] Extracting OneAgent pod-to-node mappings..."
jq -r '.items[] | select(.metadata.name | contains("oneagent")) | "\(.metadata.name),\(.spec.nodeName)"' \
    current-dynatrace-pods.json | head -20 > current-pod-to-node.csv

ONEAGENT_COUNT=$(wc -l < current-pod-to-node.csv | tr -d ' ')
echo "OneAgent pods found: ${ONEAGENT_COUNT}"
echo ""

# Step 3: Get unique node names
echo "[Step 3] Getting unique nodes from current pods..."
NODES=$(awk -F',' '{print $2}' current-pod-to-node.csv | sort -u)
NODE_COUNT=$(echo "$NODES" | wc -l | tr -d ' ')
echo "Unique nodes: ${NODE_COUNT}"
echo ""

# Step 4: Cross-reference with nodes that had mount errors
echo "[Step 4] Checking which current nodes had mount errors during incident..."
rm -f affected-current-nodes.csv 2>/dev/null
echo "node_name,had_mount_error" > affected-current-nodes.csv

for NODE in $NODES; do
    # Check if this node had mount errors
    if grep -q "$NODE" /Users/maclark/operator-health-report/table-data-write.csv 2>/dev/null; then
        echo "  ✓ ${NODE} - HAD MOUNT ERROR"
        echo "${NODE},YES" >> affected-current-nodes.csv
    else
        echo "  · ${NODE} - No mount error"
        echo "${NODE},NO" >> affected-current-nodes.csv
    fi
done

echo ""

# Step 5: Map nodes to instance IDs
echo "[Step 5] Finding EC2 instance IDs for current nodes..."
rm -f current-node-to-instance.csv 2>/dev/null
echo "node_name,instance_id,region,had_mount_error" > current-node-to-instance.csv

FOUND_INSTANCES=0
AFFECTED_INSTANCES=0

for NODE in $NODES; do
    echo -n "  ${NODE} ... "

    # Check if node had mount error
    HAD_ERROR="NO"
    if grep -q "$NODE" /Users/maclark/operator-health-report/table-data-write.csv 2>/dev/null; then
        HAD_ERROR="YES"
    fi

    # Try multiple regions
    FOUND=false
    for REGION in us-east-1 us-east-2 us-west-2; do
        INSTANCE_ID=$(aws ec2 describe-instances \
            --region ${REGION} \
            --filters "Name=private-dns-name,Values=${NODE}" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null)

        if [ "$INSTANCE_ID" != "None" ] && [ "$INSTANCE_ID" != "" ] && [ "$INSTANCE_ID" != "null" ]; then
            if [ "$HAD_ERROR" == "YES" ]; then
                echo "✓ ${INSTANCE_ID} (${REGION}) ⚠️  HAD MOUNT ERROR"
                AFFECTED_INSTANCES=$((AFFECTED_INSTANCES + 1))
            else
                echo "✓ ${INSTANCE_ID} (${REGION})"
            fi
            echo "${NODE},${INSTANCE_ID},${REGION},${HAD_ERROR}" >> current-node-to-instance.csv
            FOUND_INSTANCES=$((FOUND_INSTANCES + 1))
            FOUND=true
            break
        fi
    done

    if [ "$FOUND" = false ]; then
        echo "✗ Not found"
    fi
done

echo ""
echo "==================================================================="
echo "Summary"
echo "==================================================================="
echo "Current OneAgent pods: ${ONEAGENT_COUNT}"
echo "Current unique nodes: ${NODE_COUNT}"
echo "EC2 instances found: ${FOUND_INSTANCES}"
echo "Instances that HAD mount errors during incident: ${AFFECTED_INSTANCES}"
echo ""

if [ ${AFFECTED_INSTANCES} -gt 0 ]; then
    echo "🎯 AFFECTED INSTANCES (had mount errors during incident):"
    grep ",YES$" current-node-to-instance.csv | column -t -s','
    echo ""
    echo "✅ Next step: Use one of these instance IDs to collect EBS metrics!"
elif [ ${FOUND_INSTANCES} -gt 0 ]; then
    echo "Current instances (no mount errors during incident):"
    cat current-node-to-instance.csv | column -t -s','
    echo ""
    echo "⚠️  None of the current nodes had mount errors during the incident"
    echo "This suggests the affected nodes have been recycled/replaced"
else
    echo "⚠️  No instances found"
fi

echo ""
echo "Files created:"
echo "  - current-dynatrace-pods.json"
echo "  - current-pod-to-node.csv"
echo "  - current-node-to-instance.csv"
