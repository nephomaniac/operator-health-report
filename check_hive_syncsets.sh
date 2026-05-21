#!/bin/bash
# Run this on a hive shard to investigate how RouteMonitor CRs are deployed
# Usage: ./check_hive_syncsets.sh <cluster-namespace> [reason]
#
# Requires backplane elevation for hive resources
# cluster-namespace: uhc-staging-* namespace for a specific cluster

CLUSTER_NS="${1:-}"
REASON="${2:-investigating RMO route monitor deployment}"
E="ocm backplane elevate $REASON --"

echo "============================================"
echo "SyncSet Investigation for RouteMonitor CRs"
echo "Date: $(date)"
echo "Context: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
echo "Cluster namespace: ${CLUSTER_NS:-not provided}"
echo "============================================"
echo ""

echo "=== 1. All SelectorSyncSets ==="
$E get selectorsyncset --no-headers 2>&1 || echo "ERROR: failed to list SelectorSyncSets"
echo ""

echo "=== 2. SelectorSyncSets with RouteMonitor/ClusterUrlMonitor ==="
for sss in $($E get selectorsyncset --no-headers 2>/dev/null | awk '{print $1}'); do
    content=$($E get selectorsyncset "$sss" -o json 2>/dev/null)
    has_rm=$(echo "$content" | jq '[(.spec.resources // [])[], (.spec.resourcesToDelete // [])[]] | map(select(.kind == "RouteMonitor" or .kind == "ClusterUrlMonitor")) | length' 2>/dev/null || echo "0")
    if [ "${has_rm:-0}" -gt 0 ]; then
        echo "  Found: $sss"
        echo "$content" | jq '{resources: [(.spec.resources // [])[] | select(.kind == "RouteMonitor" or .kind == "ClusterUrlMonitor") | {kind, name: .metadata.name}], resourcesToDelete: [(.spec.resourcesToDelete // [])[] | select(.kind == "RouteMonitor" or .kind == "ClusterUrlMonitor") | {kind, name}]}' 2>/dev/null
    fi
done
echo "(if empty above, no SSS has RouteMonitor resources)"
echo ""

if [ -n "$CLUSTER_NS" ]; then
    echo "=== 3. Per-cluster SyncSets in $CLUSTER_NS ==="
    $E get syncset -n "$CLUSTER_NS" --no-headers 2>&1 || echo "ERROR: failed to list SyncSets"
    echo ""

    echo "=== 4. SyncSets with resource details ==="
    for ss in $($E get syncset -n "$CLUSTER_NS" --no-headers 2>/dev/null | awk '{print $1}'); do
        kinds=$($E get syncset "$ss" -n "$CLUSTER_NS" -o json 2>/dev/null | jq -r '[(.spec.resources // [])[] | .kind] | unique | join(", ")' 2>/dev/null || echo "unknown")
        echo "  $ss: [$kinds]"
    done
    echo ""

    echo "=== 5. ClusterSync for $CLUSTER_NS ==="
    CD_NAME=$($E get clusterdeployment -n "$CLUSTER_NS" --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$CD_NAME" ]; then
        echo "  ClusterDeployment: $CD_NAME"
        $E get clustersync "$CD_NAME" -n "$CLUSTER_NS" -o json 2>/dev/null | jq '{
          syncSets: [(.status.syncSets // [])[] | select(.name | test("route-monitor|osd-route"))],
          selectorSyncSets: [(.status.selectorSyncSets // [])[] | select(.name | test("route-monitor|osd-route"))]
        }' 2>/dev/null || echo "ERROR: failed to get ClusterSync"
    else
        echo "  ERROR: no ClusterDeployment found in $CLUSTER_NS"
    fi
    echo ""
else
    echo "=== 3-5. Skipped — provide cluster namespace as first argument ==="
    echo ""
fi

echo "=== 6. Check main MCC SelectorSyncSets for RouteMonitor resources ==="
for sss_name in $($E get selectorsyncset --no-headers 2>/dev/null | awk '{print $1}' | grep -i "managed-cluster-config\|osd-managed"); do
    has_rm=$($E get selectorsyncset "$sss_name" -o json 2>/dev/null | jq '[(.spec.resources // [])[] | select(.kind == "RouteMonitor" or .kind == "ClusterUrlMonitor")] | length' 2>/dev/null || echo "0")
    echo "  $sss_name: $has_rm RouteMonitor/ClusterUrlMonitor resources"
    if [ "${has_rm:-0}" -gt 0 ]; then
        $E get selectorsyncset "$sss_name" -o json 2>/dev/null | jq '[(.spec.resources // [])[] | select(.kind == "RouteMonitor" or .kind == "ClusterUrlMonitor") | {kind, name: .metadata.name, namespace: .metadata.namespace}]' 2>/dev/null
    fi
done
echo ""

echo "============================================"
echo "Done"
echo "============================================"
