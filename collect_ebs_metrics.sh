#!/bin/bash

# EBS Metrics Collection Script - READ ONLY
# This script collects CloudWatch metrics for EBS volumes during the incident window
# All commands are read-only and safe to execute

REGION="us-east-1"
INSTANCE_ID="i-0bfb68ed870cba722"
START_TIME="2026-04-06T10:00:00Z"  # 10:00 UTC (incident start)
END_TIME="2026-04-06T14:00:00Z"    # 14:00 UTC (incident end)

echo "==================================================================="
echo "EBS Metrics Collection for Incident Analysis"
echo "==================================================================="
echo "Region: ${REGION}"
echo "Instance: ${INSTANCE_ID}"
echo "Time Window: ${START_TIME} to ${END_TIME}"
echo ""

# Step 1: Get all volumes attached to this instance
echo "[Step 1] Getting all volumes attached to instance ${INSTANCE_ID}..."
aws ec2 describe-instances \
    --region ${REGION} \
    --instance-ids ${INSTANCE_ID} \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[*].Ebs.VolumeId' \
    --output json > instance-i-0bfb68ed870cba722-volumes.json

echo "Results saved to: instance-i-0bfb68ed870cba722-volumes.json"
echo ""

# Step 2: Get volume details for all volumes
echo "[Step 2] Getting details for all volumes on this instance..."
VOLUME_IDS=$(jq -r '.[]' instance-i-0bfb68ed870cba722-volumes.json | tr '\n' ' ')
echo "Volume IDs: ${VOLUME_IDS}"

aws ec2 describe-volumes \
    --region ${REGION} \
    --volume-ids ${VOLUME_IDS} \
    --query 'Volumes[*].{VolumeId:VolumeId,VolumeType:VolumeType,Size:Size,Iops:Iops,Throughput:Throughput,State:State,Device:Attachments[0].Device}' \
    --output json > instance-volumes-details.json

echo "Results saved to: instance-volumes-details.json"
echo ""

# Step 3: List all available metrics for this instance
echo "[Step 3] Listing all EBS metrics available for instance ${INSTANCE_ID}..."
aws cloudwatch list-metrics \
    --region ${REGION} \
    --namespace AWS/EBS \
    --dimensions Name=InstanceId,Value=${INSTANCE_ID} \
    --output json > cloudwatch-metrics-instance-all.json

echo "Results saved to: cloudwatch-metrics-instance-all.json"
echo ""

# Step 4: For each volume, collect IOPS exceeded metrics
echo "[Step 4] Collecting VolumeIOPSExceededCheck for each volume..."
for VOLUME_ID in ${VOLUME_IDS}; do
    echo "  Checking volume: ${VOLUME_ID}"

    aws cloudwatch get-metric-statistics \
        --region ${REGION} \
        --namespace AWS/EBS \
        --metric-name VolumeIOPSExceededCheck \
        --dimensions Name=VolumeId,Value=${VOLUME_ID} Name=InstanceId,Value=${INSTANCE_ID} \
        --start-time ${START_TIME} \
        --end-time ${END_TIME} \
        --period 60 \
        --statistics Maximum \
        --output json > cloudwatch-iops-exceeded-${VOLUME_ID}.json

    # Check if there were any non-zero values
    NON_ZERO=$(jq '[.Datapoints[] | select(.Maximum > 0)] | length' cloudwatch-iops-exceeded-${VOLUME_ID}.json)
    if [ "$NON_ZERO" -gt 0 ]; then
        echo "    ⚠️  FOUND ${NON_ZERO} IOPS EXCEEDED EVENTS!"
    else
        echo "    ✓ No IOPS throttling detected"
    fi
done
echo ""

# Step 5: For each volume, collect write latency metrics
echo "[Step 5] Collecting VolumeAvgWriteLatency for each volume..."
for VOLUME_ID in ${VOLUME_IDS}; do
    echo "  Checking volume: ${VOLUME_ID}"

    aws cloudwatch get-metric-statistics \
        --region ${REGION} \
        --namespace AWS/EBS \
        --metric-name VolumeAvgWriteLatency \
        --dimensions Name=VolumeId,Value=${VOLUME_ID} Name=InstanceId,Value=${INSTANCE_ID} \
        --start-time ${START_TIME} \
        --end-time ${END_TIME} \
        --period 60 \
        --statistics Average Maximum \
        --output json > cloudwatch-write-latency-${VOLUME_ID}.json

    # Show max latency if available
    MAX_LATENCY=$(jq -r '[.Datapoints[].Maximum] | max // "N/A"' cloudwatch-write-latency-${VOLUME_ID}.json)
    echo "    Max Write Latency: ${MAX_LATENCY} seconds"
done
echo ""

# Step 6: For each volume, collect write operations to see IOPS spikes
echo "[Step 6] Collecting VolumeWriteOps for each volume..."
for VOLUME_ID in ${VOLUME_IDS}; do
    echo "  Checking volume: ${VOLUME_ID}"

    aws cloudwatch get-metric-statistics \
        --region ${REGION} \
        --namespace AWS/EBS \
        --metric-name VolumeWriteOps \
        --dimensions Name=VolumeId,Value=${VOLUME_ID} \
        --start-time ${START_TIME} \
        --end-time ${END_TIME} \
        --period 60 \
        --statistics Maximum Sum \
        --output json > cloudwatch-write-ops-${VOLUME_ID}.json

    # Show max write ops
    MAX_OPS=$(jq -r '[.Datapoints[].Maximum] | max // "N/A"' cloudwatch-write-ops-${VOLUME_ID}.json)
    echo "    Max Write Ops (60s): ${MAX_OPS}"
done
echo ""

# Step 7: Collect queue length metrics
echo "[Step 7] Collecting VolumeQueueLength for each volume..."
for VOLUME_ID in ${VOLUME_IDS}; do
    echo "  Checking volume: ${VOLUME_ID}"

    aws cloudwatch get-metric-statistics \
        --region ${REGION} \
        --namespace AWS/EBS \
        --metric-name VolumeQueueLength \
        --dimensions Name=VolumeId,Value=${VOLUME_ID} \
        --start-time ${START_TIME} \
        --end-time ${END_TIME} \
        --period 60 \
        --statistics Average Maximum \
        --output json > cloudwatch-queue-length-${VOLUME_ID}.json

    # Show max queue length
    MAX_QUEUE=$(jq -r '[.Datapoints[].Maximum] | max // "N/A"' cloudwatch-queue-length-${VOLUME_ID}.json)
    echo "    Max Queue Length: ${MAX_QUEUE}"
done
echo ""

echo "==================================================================="
echo "Collection Complete!"
echo "==================================================================="
echo ""
echo "Summary files created:"
echo "  - instance-i-0bfb68ed870cba722-volumes.json (volume IDs)"
echo "  - instance-volumes-details.json (volume configurations)"
echo "  - cloudwatch-metrics-instance-all.json (available metrics)"
echo ""
echo "Per-volume metric files created:"
echo "  - cloudwatch-iops-exceeded-<volumeId>.json"
echo "  - cloudwatch-write-latency-<volumeId>.json"
echo "  - cloudwatch-write-ops-<volumeId>.json"
echo "  - cloudwatch-queue-length-<volumeId>.json"
echo ""
echo "Next: Review files for IOPS exceeded events and latency spikes"
