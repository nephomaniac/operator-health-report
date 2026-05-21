#!/bin/bash

echo "==================================================================="
echo "Cluster Scaling Analysis"
echo "==================================================================="
echo ""

# Get all node creation timestamps
jq -r '.items[] | .metadata.creationTimestamp' /Users/maclark/operator-health-report/current-nodes.json | \
    sort > node-creation-times.txt

# Count nodes by date
echo "[1] Nodes created per day (last 30 days):"
echo ""
jq -r '.items[] | .metadata.creationTimestamp' /Users/maclark/operator-health-report/current-nodes.json | \
    cut -d'T' -f1 | sort | uniq -c | tail -30

echo ""
echo "==================================================================="
echo "[2] Cluster size calculation:"
echo "==================================================================="
echo ""

# Current state
CURRENT_TOTAL=132
echo "Current total nodes: ${CURRENT_TOTAL}"
echo ""

# Nodes before incident
BEFORE_INCIDENT=$(jq -r '.items[] | select(.metadata.creationTimestamp < "2026-04-06T10:59:00Z") | .metadata.creationTimestamp' \
    /Users/maclark/operator-health-report/current-nodes.json | wc -l | tr -d ' ')
echo "Nodes created BEFORE incident (still exist): ${BEFORE_INCIDENT}"

# Nodes after incident  
AFTER_INCIDENT=$(jq -r '.items[] | select(.metadata.creationTimestamp > "2026-04-06T12:19:00Z") | .metadata.creationTimestamp' \
    /Users/maclark/operator-health-report/current-nodes.json | wc -l | tr -d ' ')
echo "Nodes created AFTER incident: ${AFTER_INCIDENT}"
echo ""

# Incident analysis
AFFECTED_NODES=98
echo "Nodes affected during incident: ${AFFECTED_NODES}"
echo "Affected nodes still exist: 0 (all replaced)"
echo ""

# Minimum cluster size at incident
MIN_AT_INCIDENT=$((BEFORE_INCIDENT + AFFECTED_NODES))
echo "Minimum cluster size at incident: ${MIN_AT_INCIDENT}"
echo "  = ${BEFORE_INCIDENT} (unaffected, still exist) + ${AFFECTED_NODES} (affected, now replaced)"
echo ""

# Potential scaling
POTENTIAL_REMOVED=$((MIN_AT_INCIDENT - CURRENT_TOTAL))
echo "Nodes potentially removed: ${POTENTIAL_REMOVED}"
echo "  = ${MIN_AT_INCIDENT} (min at incident) - ${CURRENT_TOTAL} (current)"
echo ""

echo "==================================================================="
echo "[3] Determining if cluster scaled DOWN:"
echo "==================================================================="
echo ""

if [ ${POTENTIAL_REMOVED} -gt 0 ]; then
    echo "⚠️  Cluster likely SCALED DOWN or nodes were removed"
    echo ""
    echo "Evidence:"
    echo "  - Cluster had at least ${MIN_AT_INCIDENT} nodes during incident"
    echo "  - Cluster has ${CURRENT_TOTAL} nodes today"
    echo "  - Difference: ${POTENTIAL_REMOVED} nodes removed"
    echo ""
    echo "Possible explanations:"
    echo "  1. Cluster autoscaling reduced capacity"
    echo "  2. Manual scaling operation"
    echo "  3. Node deprovisioning during maintenance"
    echo ""
    echo "Note: This assumes all ${BEFORE_INCIDENT} unaffected nodes still exist,"
    echo "which may not be true if some were also replaced."
elif [ ${POTENTIAL_REMOVED} -lt 0 ]; then
    echo "✅ Cluster likely SCALED UP"
    echo ""
    echo "Current cluster (${CURRENT_TOTAL}) > Minimum at incident (${MIN_AT_INCIDENT})"
else
    echo "➡️  Cluster size appears STABLE"
    echo ""
    echo "Current cluster (${CURRENT_TOTAL}) ≈ Minimum at incident (${MIN_AT_INCIDENT})"
fi

echo ""
echo "==================================================================="
echo "[4] Node replacement rate:"
echo "==================================================================="
echo ""

# Calculate replacement rate
TOTAL_DAYS=0
OLDEST=$(head -1 node-creation-times.txt | cut -d'T' -f1)
NEWEST=$(tail -1 node-creation-times.txt | cut -d'T' -f1)

echo "Node age range: ${OLDEST} to ${NEWEST}"
echo ""
echo "Node age distribution:"
echo "  < 7 days: $(jq -r '.items[] | select(.metadata.creationTimestamp > "'$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)'") | .metadata.creationTimestamp' /Users/maclark/operator-health-report/current-nodes.json 2>/dev/null | wc -l | tr -d ' ') nodes"
echo "  < 14 days: $(jq -r '.items[] | select(.metadata.creationTimestamp > "'$(date -u -v-14d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)'") | .metadata.creationTimestamp' /Users/maclark/operator-health-report/current-nodes.json 2>/dev/null | wc -l | tr -d ' ') nodes"
echo "  < 30 days: $(jq -r '.items[] | select(.metadata.creationTimestamp > "'$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)'") | .metadata.creationTimestamp' /Users/maclark/operator-health-report/current-nodes.json 2>/dev/null | wc -l | tr -d ' ') nodes"
echo ""
echo "This shows normal node lifecycle rotation over time."
