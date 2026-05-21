#!/bin/bash
# Run cluster-specific Dynatrace queries for hs-mc-s73d6f8p0
# Uses dtctl CLI to execute DQL queries with proper cluster filtering

CLUSTER_NAME="hs-mc-s73d6f8p0"
OUTPUT_DIR="/Users/maclark/operator-health-report"

echo "==================================================================="
echo "Running Cluster-Specific Dynatrace Queries"
echo "Cluster: ${CLUSTER_NAME}"
echo "==================================================================="
echo ""

# Query 1: Unique Node Count Per Day
echo "[1/8] Query 1: Node count by day (April 5-7)..."
dtctl query --default-timeframe-start "2026-04-05T00:00:00Z" --default-timeframe-end "2026-04-07T23:59:59Z" --default-scan-limit-gbytes 2000 -f - -o csv > "${OUTPUT_DIR}/cluster-q1-node-count-daily.csv" <<'EOF'
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter k8s.namespace.name == "dynatrace"
| filter timestamp >= toTimestamp("2026-04-05T00:00:00Z") and timestamp <= toTimestamp("2026-04-07T23:59:59Z")
| summarize unique_nodes = countDistinct(k8s.node.name), by:{day = bin(timestamp, 1d)}
| sort day asc
EOF
echo "   ✓ Saved to: cluster-q1-node-count-daily.csv"
cat "${OUTPUT_DIR}/cluster-q1-node-count-daily.csv"
echo ""

# Query 2: Mount Error Nodes
echo "[2/8] Query 2: Nodes with mount errors during incident..."
dtctl query --default-timeframe-start "2026-04-06T10:30:00Z" --default-timeframe-end "2026-04-06T13:00:00Z" --default-scan-limit-gbytes 2000 -f - -o csv > "${OUTPUT_DIR}/cluster-q2-mount-errors.csv" <<'EOF'
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(content, "mount: write error") or matchesPhrase(content, "mount error")
| filter timestamp >= toTimestamp("2026-04-06T10:30:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| summarize error_count = count(), by:{node = k8s.node.name}
| sort error_count desc
EOF
echo "   ✓ Saved to: cluster-q2-mount-errors.csv"
wc -l "${OUTPUT_DIR}/cluster-q2-mount-errors.csv"
echo ""

# Query 3: OneAgent Readiness Failures
echo "[3/8] Query 3: Readiness probe failures by hour..."
dtctl query --default-timeframe-start "2026-04-06T10:30:00Z" --default-timeframe-end "2026-04-06T13:00:00Z" --default-scan-limit-gbytes 2000 -f - -o csv > "${OUTPUT_DIR}/cluster-q3-readiness-failures.csv" <<'EOF'
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(k8s.pod.name, "hs-mc-s73d6f8p0-wqn9x-oneagent")
| filter matchesPhrase(content, "Cannot find") and matchesPhrase(content, "watchdog.conf")
| filter timestamp >= toTimestamp("2026-04-06T10:30:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| summarize failures = count(), unique_pods = countDistinct(k8s.pod.name), unique_nodes = countDistinct(k8s.node.name), by:{hour = bin(timestamp, 1h)}
| sort hour asc
EOF
echo "   ✓ Saved to: cluster-q3-readiness-failures.csv"
cat "${OUTPUT_DIR}/cluster-q3-readiness-failures.csv"
echo ""

# Query 4: Dynatrace Operator Events
echo "[4/8] Query 4: Dynatrace operator events..."
dtctl query --default-timeframe-start "2026-04-06T10:00:00Z" --default-timeframe-end "2026-04-06T13:00:00Z" --default-scan-limit-gbytes 2000 -f - -o csv > "${OUTPUT_DIR}/cluster-q4-operator-events.csv" <<'EOF'
fetch events
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter event.provider == "KUBERNETES_EVENT"
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(event.name, "dynatrace-operator") or matchesPhrase(k8s.deployment.name, "dynatrace-operator")
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| fields timestamp, event.type, event.name, k8s.deployment.name
| sort timestamp asc
| limit 100
EOF
echo "   ✓ Saved to: cluster-q4-operator-events.csv"
wc -l "${OUTPUT_DIR}/cluster-q4-operator-events.csv"
echo ""

# Query 5: Node Deletion Events
echo "[5/8] Query 5: Node deletion events (April 6-14)..."
dtctl query --default-timeframe-start "2026-04-06T00:00:00Z" --default-timeframe-end "2026-04-14T00:00:00Z" --default-scan-limit-gbytes 2000 -f - -o csv > "${OUTPUT_DIR}/cluster-q5-node-deletions.csv" <<'EOF'
fetch events
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter event.provider == "KUBERNETES_EVENT"
| filter matchesPhrase(event.name, "Removing") or matchesPhrase(event.name, "Terminating") or matchesPhrase(event.name, "Deleting")
| filter timestamp >= toTimestamp("2026-04-06T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| summarize deletion_events = count(), by:{day = bin(timestamp, 1d), event_name = event.name}
| sort day asc
EOF
echo "   ✓ Saved to: cluster-q5-node-deletions.csv"
cat "${OUTPUT_DIR}/cluster-q5-node-deletions.csv"
echo ""

# Query 6: Mount Error Timeline
echo "[6/8] Query 6: Mount error timeline with details..."
dtctl query --default-timeframe-start "2026-04-06T10:30:00Z" --default-timeframe-end "2026-04-06T12:30:00Z" --default-scan-limit-gbytes 2000 -f - -o csv > "${OUTPUT_DIR}/cluster-q6-mount-error-timeline.csv" <<'EOF'
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(content, "mount: write error")
| filter timestamp >= toTimestamp("2026-04-06T10:30:00Z") and timestamp <= toTimestamp("2026-04-06T12:30:00Z")
| fields timestamp, k8s.node.name, k8s.pod.name, content
| sort timestamp asc
| limit 500
EOF
echo "   ✓ Saved to: cluster-q6-mount-error-timeline.csv"
wc -l "${OUTPUT_DIR}/cluster-q6-mount-error-timeline.csv"
echo ""

# Query 7: Hourly Node Count (April 5-14)
echo "[7/8] Query 7: Hourly node count for trend analysis..."
dtctl query --default-timeframe-start "2026-04-05T00:00:00Z" --default-timeframe-end "2026-04-14T00:00:00Z" --default-scan-limit-gbytes 2000 -f - -o csv > "${OUTPUT_DIR}/cluster-q7-node-count-hourly.csv" <<'EOF'
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter k8s.namespace.name == "dynatrace"
| filter timestamp >= toTimestamp("2026-04-05T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| summarize unique_nodes = countDistinct(k8s.node.name), total_events = count(), by:{hour = bin(timestamp, 1h)}
| sort hour asc
EOF
echo "   ✓ Saved to: cluster-q7-node-count-hourly.csv"
wc -l "${OUTPUT_DIR}/cluster-q7-node-count-hourly.csv"
echo ""

# Query 8: Machine/Node Events
echo "[8/8] Query 8: Machine/Node lifecycle events..."
dtctl query --default-timeframe-start "2026-04-06T00:00:00Z" --default-timeframe-end "2026-04-14T00:00:00Z" --default-scan-limit-gbytes 2000 -f - -o csv > "${OUTPUT_DIR}/cluster-q8-machine-node-events.csv" <<'EOF'
fetch events
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter event.provider == "KUBERNETES_EVENT"
| filter matchesPhrase(event.name, "Machine") or matchesPhrase(event.name, "Node")
| filter timestamp >= toTimestamp("2026-04-06T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| summarize events = count(), by:{day = bin(timestamp, 1d), event_type = event.type}
| sort day asc
EOF
echo "   ✓ Saved to: cluster-q8-machine-node-events.csv"
cat "${OUTPUT_DIR}/cluster-q8-machine-node-events.csv"
echo ""

echo "==================================================================="
echo "Query Execution Complete!"
echo "==================================================================="
echo ""
echo "Results saved in: ${OUTPUT_DIR}"
echo ""
echo "Key files to review:"
echo "  1. cluster-q1-node-count-daily.csv - Node count April 5-7"
echo "  2. cluster-q2-mount-errors.csv - Affected nodes"
echo "  3. cluster-q3-readiness-failures.csv - Readiness probe failures"
echo "  6. cluster-q6-mount-error-timeline.csv - Mount error details"
echo "  7. cluster-q7-node-count-hourly.csv - Node count trend"
echo ""
echo "Next steps:"
echo "  - Compare Q1 node count to current (132 nodes)"
echo "  - Count affected nodes in Q2"
echo "  - Check Q7 for scaling events"
echo ""
