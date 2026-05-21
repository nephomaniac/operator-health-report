#!/bin/bash

echo "==================================================================="
echo "Finding EC2 Instances from Mount Error List"
echo "==================================================================="
echo ""

# Extract unique node names from mount error data
# Note: Field 4 contains node names (field 1-2 are timestamp split by comma)
echo "[Step 1] Extracting node names from mount error list..."
NODES=$(awk -F',' 'NR>1 {print $4}' /Users/maclark/operator-health-report/table-data-write.csv | \
    tr -d '"' | \
    sort -u)
TOTAL=$(echo "$NODES" | wc -l | tr -d ' ')

echo "Total unique nodes with mount errors: ${TOTAL}"
echo ""

# Try to find these nodes in AWS across all regions
echo "[Step 2] Querying AWS for these specific nodes..."
rm -f mount-error-instances.csv 2>/dev/null
echo "node_name,instance_id,region,state" > mount-error-instances.csv

FOUND_RUNNING=0
FOUND_STOPPED=0
NOT_FOUND=0

for NODE in $NODES; do
    echo -n "  ${NODE} ... "

    FOUND=false
    # Try multiple regions
    for REGION in us-east-1 us-east-2 us-west-2; do
        # Try to find instance in any state (running, stopped, terminated)
        RESULT=$(aws ec2 describe-instances \
            --region ${REGION} \
            --filters "Name=private-dns-name,Values=${NODE}" \
            --query 'Reservations[0].Instances[0].[InstanceId,State.Name]' \
            --output text 2>/dev/null)

        if [ "$RESULT" != "None" ] && [ "$RESULT" != "" ]; then
            INSTANCE_ID=$(echo "$RESULT" | awk '{print $1}')
            STATE=$(echo "$RESULT" | awk '{print $2}')

            if [ "$STATE" == "running" ]; then
                echo "✓ ${INSTANCE_ID} (${REGION}) - RUNNING ✅"
                FOUND_RUNNING=$((FOUND_RUNNING + 1))
            elif [ "$STATE" == "stopped" ]; then
                echo "✓ ${INSTANCE_ID} (${REGION}) - STOPPED ⏸️"
                FOUND_STOPPED=$((FOUND_STOPPED + 1))
            else
                echo "✓ ${INSTANCE_ID} (${REGION}) - ${STATE}"
            fi

            echo "${NODE},${INSTANCE_ID},${REGION},${STATE}" >> mount-error-instances.csv
            FOUND=true
            break
        fi
    done

    if [ "$FOUND" = false ]; then
        echo "✗ Not found (terminated)"
        NOT_FOUND=$((NOT_FOUND + 1))
    fi
done

echo ""
echo "==================================================================="
echo "Summary"
echo "==================================================================="
echo "Total nodes with mount errors: ${TOTAL}"
echo "  - Running instances: ${FOUND_RUNNING} ✅"
echo "  - Stopped instances: ${FOUND_STOPPED} ⏸️"
echo "  - Not found (terminated): ${NOT_FOUND} ✗"
echo ""

if [ ${FOUND_RUNNING} -gt 0 ]; then
    echo "🎯 RUNNING INSTANCES AVAILABLE FOR ANALYSIS:"
    grep ",running$" mount-error-instances.csv | column -t -s','
    echo ""
    echo "✅ You can now collect EBS metrics from these instances!"
    echo "   Pick one and update INSTANCE_ID in collect_ebs_metrics.sh"
elif [ ${FOUND_STOPPED} -gt 0 ]; then
    echo "⚠️  Only stopped instances found:"
    grep ",stopped$" mount-error-instances.csv | column -t -s','
    echo ""
    echo "You can still get CloudWatch metrics for stopped instances"
else
    echo "❌ All nodes with mount errors have been terminated"
    echo "CloudWatch metrics may still be available for ~15 days after termination"
fi

echo ""
echo "Results saved to: mount-error-instances.csv"
