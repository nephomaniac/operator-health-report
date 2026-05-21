#!/bin/bash

# Find existing instances from nodes that had mount errors
# This script will check multiple regions since mount errors spanned us-east-1, us-east-2, and default

echo "==================================================================="
echo "Finding Existing Instances from Mount Error List"
echo "==================================================================="
echo ""

# Extract unique node names from mount error data
NODES=$(awk -F',' 'NR>1 {print $3}' /Users/maclark/operator-health-report/table-data-write.csv | tr -d '"' | sort -u)
TOTAL=$(echo "$NODES" | wc -l | tr -d ' ')

echo "Total unique nodes with mount errors: ${TOTAL}"
echo "Checking which ones still exist across all regions..."
echo ""

# Clean up previous results
rm -f found-affected-instances.csv 2>/dev/null
echo "node_name,instance_id,region" > found-affected-instances.csv

FOUND_COUNT=0

# Check each region
for REGION in us-east-1 us-east-2 us-west-2; do
    echo "--- Checking region: ${REGION} ---"

    for NODE in $NODES; do
        # Query for running instances
        INSTANCE_ID=$(aws ec2 describe-instances \
            --region ${REGION} \
            --filters "Name=private-dns-name,Values=${NODE}" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null)

        if [ "$INSTANCE_ID" != "None" ] && [ "$INSTANCE_ID" != "" ] && [ "$INSTANCE_ID" != "null" ]; then
            echo "  ✓ FOUND: ${NODE} = ${INSTANCE_ID}"
            echo "${NODE},${INSTANCE_ID},${REGION}" >> found-affected-instances.csv
            FOUND_COUNT=$((FOUND_COUNT + 1))
        fi
    done
done

echo ""
echo "==================================================================="
echo "Summary"
echo "==================================================================="
echo "Total nodes with mount errors: ${TOTAL}"
echo "Still existing (running): ${FOUND_COUNT}"
echo ""

if [ ${FOUND_COUNT} -gt 0 ]; then
    echo "Results saved to: found-affected-instances.csv"
    echo ""
    echo "Found instances:"
    cat found-affected-instances.csv | column -t -s','
    echo ""
    echo "Next step: Run collect_ebs_metrics.sh for one of these instances"
else
    echo "⚠️  No running instances found from the mount error list"
    echo "All affected nodes may have been terminated"
fi
