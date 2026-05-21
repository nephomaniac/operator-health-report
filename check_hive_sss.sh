#!/bin/bash
# Run this on a hive shard (e.g., hive-stage-01 or hives02ue1)
# Usage: ./check_hive_sss.sh | tee hive_sss_check.out

echo "============================================"
echo "Hive SSS Investigation for RMO RouteMonitor CRs"
echo "Date: $(date)"
echo "Context: $(oc whoami --show-server 2>/dev/null)"
echo "============================================"
echo ""

echo "=== 1. All SSS matching route-monitor ==="
oc get selectorsyncset --no-headers 2>/dev/null | grep -i "route-monitor\|osd-route-monitor"
echo ""

echo "=== 2. osd-route-monitor-operator SSS spec (resources + resourcesToDelete) ==="
oc get selectorsyncset osd-route-monitor-operator -o json 2>/dev/null | jq '{
  name: .metadata.name,
  resourceApplyMode: .spec.resourceApplyMode,
  clusterSelector: .spec.clusterDeploymentSelector,
  resourceCount: (.spec.resources // [] | length),
  resources: [(.spec.resources // [])[] | {kind: .kind, name: .metadata.name, namespace: .metadata.namespace}],
  resourcesToDelete: .spec.resourcesToDelete
}' 2>/dev/null || echo "SSS not found"
echo ""

echo "=== 3. route-monitor-operator-pko SSS spec ==="
oc get selectorsyncset route-monitor-operator-pko -o json 2>/dev/null | jq '{
  name: .metadata.name,
  resourceApplyMode: .spec.resourceApplyMode,
  clusterSelector: .spec.clusterDeploymentSelector,
  resourceCount: (.spec.resources // [] | length),
  resources: [(.spec.resources // [])[] | {kind: .kind, name: .metadata.name}],
  resourcesToDelete: .spec.resourcesToDelete
}' 2>/dev/null || echo "SSS not found"
echo ""

echo "=== 4. Any other SSS with RouteMonitor/ClusterUrlMonitor resources ==="
for sss in $(oc get selectorsyncset --no-headers 2>/dev/null | awk '{print $1}'); do
  has_rm=$(oc get selectorsyncset "$sss" -o json 2>/dev/null | jq '[(.spec.resources // [])[] | select(.kind == "RouteMonitor" or .kind == "ClusterUrlMonitor")] | length' 2>/dev/null)
  has_delete=$(oc get selectorsyncset "$sss" -o json 2>/dev/null | jq '[(.spec.resourcesToDelete // [])[] | select(.kind == "RouteMonitor" or .kind == "ClusterUrlMonitor")] | length' 2>/dev/null)
  if [ "${has_rm:-0}" -gt 0 ] || [ "${has_delete:-0}" -gt 0 ]; then
    echo "  SSS: $sss (resources: $has_rm, resourcesToDelete: $has_delete)"
  fi
done
echo ""

echo "=== 5. Check a standard managed cluster's ClusterSync for osd-route-monitor-operator ==="
echo "Looking for a standard managed cluster ClusterSync..."
cs_ns=$(oc get clustersync -A --no-headers 2>/dev/null | head -1 | awk '{print $1}')
cs_name=$(oc get clustersync -A --no-headers 2>/dev/null | head -1 | awk '{print $2}')
if [ -n "$cs_ns" ] && [ -n "$cs_name" ]; then
  echo "  Using: $cs_ns/$cs_name"
  oc get clustersync "$cs_name" -n "$cs_ns" -o json 2>/dev/null | jq '[.status.selectorSyncSets[]? | select(.name | test("route-monitor"))] | .[] | {name, result, resourcesToDelete}'
else
  echo "  No ClusterSync found"
fi
echo ""

echo "=== 6. SSS labels and annotations on osd-route-monitor-operator ==="
oc get selectorsyncset osd-route-monitor-operator -o json 2>/dev/null | jq '{labels: .metadata.labels, annotations: .metadata.annotations, generation: .metadata.generation, creationTimestamp: .metadata.creationTimestamp}' 2>/dev/null || echo "Not found"
echo ""

echo "============================================"
echo "Done"
echo "============================================"
