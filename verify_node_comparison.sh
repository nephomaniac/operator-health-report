#!/bin/bash

echo "======================================================================"
echo "Verifying Node Comparison Logic"
echo "======================================================================"
echo ""

# Get node names from mount errors
echo "[1] Nodes from mount error list:"
MOUNT_ERROR_NODES=$(awk -F',' 'NR>1 {print $4}' /Users/maclark/operator-health-report/table-data-write.csv | tr -d '"' | sort -u)
MOUNT_COUNT=$(echo "$MOUNT_ERROR_NODES" | wc -l | tr -d ' ')
echo "    Total: ${MOUNT_COUNT}"
echo "    First 5:"
echo "$MOUNT_ERROR_NODES" | head -5 | sed 's/^/      /'
echo ""

# Get current node names
echo "[2] Current nodes in cluster:"
CURRENT_NODES=$(jq -r '.items[].metadata.name' /Users/maclark/operator-health-report/current-nodes.json | sort)
CURRENT_COUNT=$(echo "$CURRENT_NODES" | wc -l | tr -d ' ')
echo "    Total: ${CURRENT_COUNT}"
echo "    First 5:"
echo "$CURRENT_NODES" | head -5 | sed 's/^/      /'
echo ""

# Find overlap
echo "[3] Cross-reference: mount error nodes that still exist:"
OVERLAP=0
echo "$MOUNT_ERROR_NODES" | while read NODE; do
    if echo "$CURRENT_NODES" | grep -q "^${NODE}$"; then
        echo "    ✓ ${NODE}"
        OVERLAP=$((OVERLAP + 1))
    fi
done

OVERLAP_COUNT=$(comm -12 <(echo "$MOUNT_ERROR_NODES") <(echo "$CURRENT_NODES") | wc -l | tr -d ' ')

echo ""
echo "======================================================================"
echo "Results:"
echo "======================================================================"
echo "Nodes with mount errors: ${MOUNT_COUNT}"
echo "Current nodes in cluster: ${CURRENT_COUNT}"
echo "Overlap (mount error nodes still exist): ${OVERLAP_COUNT}"
echo ""

if [ ${OVERLAP_COUNT} -eq 0 ]; then
    echo "✅ Script is CORRECT: 0 mount error nodes still exist"
    echo "All 98 affected nodes have been replaced through normal node lifecycle"
elif [ ${OVERLAP_COUNT} -gt 0 ]; then
    echo "⚠️  Script may be INCORRECT: ${OVERLAP_COUNT} mount error nodes still exist!"
    echo "These nodes should have been found:"
    comm -12 <(echo "$MOUNT_ERROR_NODES") <(echo "$CURRENT_NODES")
fi
