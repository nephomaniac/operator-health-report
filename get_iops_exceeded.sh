#!/bin/bash

# Get one volume ID to test the metric first
VOLUME_ID=$(jq -r '.[0].VolumeId' /Users/maclark/operator-health-report/volume-details.json)

# Time range for the incident (10:00 UTC - 14:00 UTC on 2026-04-06)
START_TIME="2026-04-06T10:00:00Z"
END_TIME="2026-04-06T14:00:00Z"

# Get region from first write error node
REGION="us-east-2"

echo "Testing VolumeIOPSExceededCheck metric for volume: ${VOLUME_ID}"
echo "Region: ${REGION}"
echo "Time window: ${START_TIME} to ${END_TIME}"
echo ""

aws cloudwatch get-metric-statistics \
    --region ${REGION} \
    --namespace AWS/EBS \
    --metric-name VolumeIOPSExceededCheck \
    --dimensions Name=VolumeId,Value=${VOLUME_ID} \
    --start-time ${START_TIME} \
    --end-time ${END_TIME} \
    --period 300 \
    --statistics Maximum,Average \
    --output json | tee /Users/maclark/operator-health-report/cloudwatch-iops-exceeded-test.json

echo ""
echo "Checking if datapoints exist..."
jq '.Datapoints | length' /Users/maclark/operator-health-report/cloudwatch-iops-exceeded-test.json
