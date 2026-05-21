#!/bin/bash

# Get instance ID from node that had mount error
# Example node from table-data-write.csv: ip-10-0-48-154.ec2.internal

NODE_NAME="ip-10-0-48-154.ec2.internal"
REGION="us-east-1"

echo "Looking up instance for node: ${NODE_NAME}"

# Query EC2 for instance with this private DNS name
aws ec2 describe-instances \
    --region ${REGION} \
    --filters "Name=private-dns-name,Values=${NODE_NAME}" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text

