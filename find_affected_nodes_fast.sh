#!/bin/bash

echo "==================================================================="
echo "Finding Affected Nodes (Fast Method)"
echo "==================================================================="
echo ""

# Step 1: Get all current nodes from Kubernetes
echo "[Step 1] Getting all current nodes from Kubernetes..."
oc get nodes -o json > current-nodes.json

TOTAL_K8S_NODES=$(jq '[.items[]] | length' current-nodes.json)
echo "Total nodes in cluster: ${TOTAL_K8S_NODES}"
echo ""

# Step 2: Extract node names that had mount errors
echo "[Step 2] Extracting node names from mount error list..."
awk -F',' 'NR>1 {print $4}' /Users/maclark/operator-health-report/table-data-write.csv | \
    tr -d '"' | \
    sort -u > mount-error-nodes.txt

MOUNT_ERROR_COUNT=$(wc -l < mount-error-nodes.txt | tr -d ' ')
echo "Nodes with mount errors during incident: ${MOUNT_ERROR_COUNT}"
echo ""

# Step 3: Check which mount error nodes still exist in Kubernetes
echo "[Step 3] Cross-referencing: which mount error nodes still exist?"
rm -f existing-affected-nodes.txt 2>/dev/null

STILL_EXIST=0
while read NODE; do
    # Check if this node exists in current-nodes.json
    if jq -e ".items[] | select(.metadata.name == \"$NODE\")" current-nodes.json > /dev/null 2>&1; then
        echo "  ✓ ${NODE} - Still exists"
        echo "$NODE" >> existing-affected-nodes.txt
        STILL_EXIST=$((STILL_EXIST + 1))
    fi
done < mount-error-nodes.txt

echo ""
echo "Nodes with mount errors that still exist: ${STILL_EXIST}"
echo ""

# Step 4: For existing nodes, get their instance IDs from Kubernetes node annotations
if [ ${STILL_EXIST} -gt 0 ]; then
    echo "[Step 4] Extracting instance IDs from Kubernetes node metadata..."
    rm -f affected-nodes-with-instances.csv 2>/dev/null
    echo "node_name,instance_id,region" > affected-nodes-with-instances.csv

    while read NODE; do
        # Extract instance ID from node spec.providerID (format: aws:///us-east-1a/i-0123456789abcdef)
        PROVIDER_ID=$(jq -r ".items[] | select(.metadata.name == \"$NODE\") | .spec.providerID // empty" current-nodes.json)

        if [ ! -z "$PROVIDER_ID" ]; then
            # Extract instance ID and region from providerID
            INSTANCE_ID=$(echo "$PROVIDER_ID" | grep -oE 'i-[a-z0-9]+')
            REGION=$(echo "$PROVIDER_ID" | grep -oE 'us-[a-z]+-[0-9]+' | head -1)

            if [ ! -z "$INSTANCE_ID" ]; then
                echo "  ✓ ${NODE} -> ${INSTANCE_ID} (${REGION})"
                echo "${NODE},${INSTANCE_ID},${REGION}" >> affected-nodes-with-instances.csv
            else
                echo "  ⚠ ${NODE} -> Could not parse instance ID from: ${PROVIDER_ID}"
            fi
        else
            echo "  ⚠ ${NODE} -> No providerID found"
        fi
    done < existing-affected-nodes.txt

    MAPPED_COUNT=$(tail -n +2 affected-nodes-with-instances.csv | wc -l | tr -d ' ')

    echo ""
    echo "==================================================================="
    echo "Summary"
    echo "==================================================================="
    echo "Total Kubernetes nodes: ${TOTAL_K8S_NODES}"
    echo "Nodes with mount errors during incident: ${MOUNT_ERROR_COUNT}"
    echo "Still exist in cluster: ${STILL_EXIST}"
    echo "Successfully mapped to instance IDs: ${MAPPED_COUNT}"
    echo ""

    if [ ${MAPPED_COUNT} -gt 0 ]; then
        echo "🎯 AFFECTED NODES AVAILABLE FOR ANALYSIS:"
        cat affected-nodes-with-instances.csv | column -t -s','
        echo ""
        echo "✅ Pick an instance ID and update collect_ebs_metrics.sh:"
        echo "   INSTANCE_ID=\"<instance-id-from-above>\""
        echo "   REGION=\"<region-from-above>\""
    else
        echo "⚠️  Could not map nodes to instance IDs"
    fi
else
    echo "==================================================================="
    echo "Summary"
    echo "==================================================================="
    echo "Total Kubernetes nodes: ${TOTAL_K8S_NODES}"
    echo "Nodes with mount errors during incident: ${MOUNT_ERROR_COUNT}"
    echo "Still exist in cluster: 0"
    echo ""
    echo "❌ None of the nodes with mount errors still exist in the cluster"
    echo ""
    echo "This means all affected nodes have been recycled/replaced."
    echo "We can still analyze the EBS metrics we already collected from"
    echo "the unaffected node, which showed 2.34s write latency spikes."
fi

echo ""
echo "Files created:"
echo "  - current-nodes.json (all current nodes)"
echo "  - mount-error-nodes.txt (nodes that had mount errors)"
if [ -f existing-affected-nodes.txt ]; then
    echo "  - existing-affected-nodes.txt (affected nodes still in cluster)"
fi
if [ -f affected-nodes-with-instances.csv ]; then
    echo "  - affected-nodes-with-instances.csv (node -> instance mapping)"
fi
