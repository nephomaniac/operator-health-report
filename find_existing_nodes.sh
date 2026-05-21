#!/bin/bash

# Get sample of nodes that had mount errors
NODES=$(awk -F',' 'NR>1 {print $3}' /Users/maclark/operator-health-report/table-data-write.csv | sort -u | head -10)

REGION="us-east-1"

echo "Checking which nodes from mount error list still exist..."
echo ""

for NODE in $NODES; do
    # Remove quotes
    NODE_CLEAN=$(echo $NODE | tr -d '"')
    
    echo -n "Checking $NODE_CLEAN ... "
    
    INSTANCE_ID=$(aws ec2 describe-instances \
        --region ${REGION} \
        --filters "Name=private-dns-name,Values=${NODE_CLEAN}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null)
    
    if [ "$INSTANCE_ID" != "None" ] && [ ! -z "$INSTANCE_ID" ]; then
        echo "✓ FOUND: ${INSTANCE_ID}"
        echo "$NODE_CLEAN,$INSTANCE_ID" >> found-instances.csv
    else
        echo "✗ Not found (terminated?)"
    fi
done

echo ""
if [ -f found-instances.csv ]; then
    echo "Found instances saved to: found-instances.csv"
    cat found-instances.csv
else
    echo "No running instances found from mount error list"
fi
