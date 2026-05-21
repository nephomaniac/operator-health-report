#!/bin/bash
#
# Filter expected AlertManager warnings based on timing
#
# This script demonstrates how to filter out AlertManager DNS lookup warnings
# that occur within expected startup windows, which should be integrated into
# the health check.
#

set -euo pipefail

NAMESPACE="${NAMESPACE:-openshift-monitoring}"
STARTUP_GRACE_PERIOD_SECONDS="${STARTUP_GRACE_PERIOD:-300}"  # 5 minutes

echo "=================================================================="
echo "AlertManager Warning Filter Analysis"
echo "=================================================================="
echo "Startup grace period: ${STARTUP_GRACE_PERIOD_SECONDS}s"
echo ""

# Function to convert ISO8601 timestamp to epoch seconds (macOS compatible)
iso_to_epoch() {
    local iso_time="$1"
    # Remove the 'Z' and convert
    iso_time="${iso_time%Z}"
    date -j -f "%Y-%m-%dT%H:%M:%S" "$iso_time" "+%s" 2>/dev/null || echo 0
}

# Function to convert AlertManager log timestamp to epoch
# Format: time=2026-04-17T16:47:14.403Z
log_time_to_epoch() {
    local log_time="$1"
    # Extract time value: time=2026-04-17T16:47:14.403Z -> 2026-04-17T16:47:14.403Z
    log_time="${log_time#time=}"
    # Remove milliseconds: 2026-04-17T16:47:14.403Z -> 2026-04-17T16:47:14Z
    log_time="${log_time%.*}Z"
    iso_to_epoch "$log_time"
}

# Get AlertManager pods
am_pods=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=alertmanager -o json 2>/dev/null)

if [ -z "$am_pods" ] || [ "$(echo "$am_pods" | jq '.items | length')" -eq 0 ]; then
    echo "No AlertManager pods found"
    exit 0
fi

total_warnings=0
expected_warnings=0
unexpected_warnings=0

# Process each AlertManager pod
echo "$am_pods" | jq -c '.items[]' | while IFS= read -r pod_json; do
    pod_name=$(echo "$pod_json" | jq -r '.metadata.name')

    # Get pod creation time
    created=$(echo "$pod_json" | jq -r '.metadata.creationTimestamp')
    created_epoch=$(iso_to_epoch "$created")

    # Get container restart count and last restart time
    restart_count=$(echo "$pod_json" | jq -r '.status.containerStatuses[0].restartCount // 0')

    # Determine the relevant start time (creation or last restart)
    start_epoch=$created_epoch
    start_type="creation"

    if [ "$restart_count" -gt 0 ]; then
        last_restart=$(echo "$pod_json" | jq -r '.status.containerStatuses[0].lastState.terminated.finishedAt // empty')
        if [ -n "$last_restart" ]; then
            restart_epoch=$(iso_to_epoch "$last_restart")
            if [ "$restart_epoch" -gt "$start_epoch" ]; then
                start_epoch=$restart_epoch
                start_type="restart"
            fi
        fi
    fi

    echo ""
    echo "Pod: $pod_name"
    echo "  Created: $created"
    echo "  Restarts: $restart_count"
    echo "  Effective start: $(date -r $start_epoch -u '+%Y-%m-%dT%H:%M:%SZ') ($start_type)"
    echo "  Grace period ends: $(date -r $((start_epoch + STARTUP_GRACE_PERIOD_SECONDS)) -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""

    # Get logs and analyze warnings
    pod_logs=$(oc logs -n "$NAMESPACE" "$pod_name" --tail=1000 2>/dev/null || echo "")

    if [ -z "$pod_logs" ]; then
        echo "  (No logs available)"
        continue
    fi

    # Find DNS-related warnings
    dns_warnings=$(echo "$pod_logs" | grep -i "level=WARN.*\(no such host\|Failed to resolve\)" || true)

    if [ -z "$dns_warnings" ]; then
        echo "  ✓ No DNS lookup warnings"
        continue
    fi

    warning_count=$(echo "$dns_warnings" | wc -l | tr -d ' ')
    total_warnings=$((total_warnings + warning_count))
    echo "  Found $warning_count DNS lookup warnings:"
    echo ""

    # Analyze each warning
    echo "$dns_warnings" | while IFS= read -r warning_line; do
        # Extract timestamp from log line
        # Format: time=2026-04-17T16:47:14.403Z
        log_timestamp=$(echo "$warning_line" | grep -o "time=[^ ]*" | head -1)

        if [ -z "$log_timestamp" ]; then
            echo "    ⚠ (no timestamp) $warning_line"
            continue
        fi

        log_epoch=$(log_time_to_epoch "$log_timestamp")

        if [ "$log_epoch" -eq 0 ]; then
            echo "    ⚠ (invalid timestamp) $warning_line"
            continue
        fi

        # Calculate time since pod start
        time_since_start=$((log_epoch - start_epoch))

        # Determine if this is expected (within grace period)
        if [ "$time_since_start" -le "$STARTUP_GRACE_PERIOD_SECONDS" ] && [ "$time_since_start" -ge 0 ]; then
            echo "    ✓ EXPECTED (${time_since_start}s after $start_type) - $(echo "$warning_line" | head -c 120)..."
            expected_warnings=$((expected_warnings + 1))
        else
            echo "    ✗ UNEXPECTED (${time_since_start}s after $start_type) - $(echo "$warning_line" | head -c 120)..."
            unexpected_warnings=$((unexpected_warnings + 1))
        fi
    done
    echo ""
done

echo ""
echo "=================================================================="
echo "Summary"
echo "=================================================================="
echo "Total DNS lookup warnings: $total_warnings"
echo "Expected (within ${STARTUP_GRACE_PERIOD_SECONDS}s grace period): $expected_warnings"
echo "Unexpected (outside grace period): $unexpected_warnings"
echo ""
echo "Recommendation:"
if [ "$unexpected_warnings" -eq 0 ]; then
    echo "  ✓ All DNS warnings are expected during pod startup"
    echo "  → Health check should filter these out"
else
    echo "  ⚠ $unexpected_warnings warnings outside grace period"
    echo "  → These indicate a potential issue and should be flagged"
fi
echo ""
