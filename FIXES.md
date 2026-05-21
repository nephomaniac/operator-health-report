# Label Selector Fixes

## Issue

The scripts were failing with:
```
Error: No ReplicaSets found for configure-alertmanager-operator
```

## Root Cause

The scripts were using the wrong Kubernetes label selector:
- **Incorrect**: `app.kubernetes.io/name=configure-alertmanager-operator`
- **Correct**: `name=configure-alertmanager-operator`

CAMO uses the simple `name` label, not the `app.kubernetes.io/name` label.

## Verification

From the cluster, we can see the actual labels used:
```bash
oc get replicasets -n openshift-monitoring -o json | \
  jq '.items[] | select(.metadata.name | contains("configure-alertmanager")) | {name: .metadata.name, labels: .metadata.labels}'
```

**Output:**
```json
{
  "name": "configure-alertmanager-operator-6cb8747cf9",
  "labels": {
    "name": "configure-alertmanager-operator",
    "pod-template-hash": "6cb8747cf9"
  }
}
{
  "name": "configure-alertmanager-operator-86cddd698d",
  "labels": {
    "name": "configure-alertmanager-operator",
    "pod-template-hash": "86cddd698d"
  }
}
```

## Files Fixed

### 1. collect_versioned_metrics.sh
- **Line ~66**: Changed ReplicaSet label selector from `app.kubernetes.io/name=$DEPLOYMENT` to `name=$DEPLOYMENT`
- **Line ~187**: Changed Prometheus query from pod-based to container-based to improve reliability
- **Line ~200**: Fixed image version extraction to handle SHA digests (`@sha256:...`) instead of just tags

### 2. collect_pod_health.sh
- **Line 158**: Changed pod label selector from `app.kubernetes.io/name=$DEPLOYMENT` to `name=$DEPLOYMENT`
- **Line 306**: Changed CAMO operator pod check from `app.kubernetes.io/name=configure-alertmanager-operator` to `name=configure-alertmanager-operator`
- **Note**: Left alertmanager pod check (line 284) unchanged as those pods may use different labels

### 3. collect_camo_metrics.sh
- **Line 129**: Changed pod label selector from `app.kubernetes.io/name=$DEPLOYMENT` to `name=$DEPLOYMENT`

## Additional Improvements

### Version Detection Enhancement
Updated `collect_versioned_metrics.sh` to handle image references that use SHA digests instead of version tags:

**Before:**
```bash
(.spec.template.spec.containers[0].image | split(":")[1] // "unknown")
```

**After:**
```bash
(.spec.template.spec.containers[0].image | if contains("@sha256:") then split("@sha256:")[1][0:12] else (split(":")[1] // "unknown") end)
```

This extracts the first 12 characters of the SHA digest when no version tag is present, similar to git short hashes.

### Prometheus Query Improvements
Changed from pod-based to container-based Prometheus queries for better reliability:

**Before:**
```bash
local pod_label="pod=~\"${DEPLOYMENT}.*\""
cpu_query="rate(container_cpu_usage_seconds_total{${namespace_label},${pod_label},container!=\"\",container!=\"POD\"}[5m])"
```

**After:**
```bash
local container_label="container=\"${DEPLOYMENT}\""
cpu_query="rate(container_cpu_usage_seconds_total{${namespace_label},${container_label}}[5m])"
```

This directly targets the container name instead of pattern-matching pod names, which is more precise and avoids matching POD infrastructure containers.

## Testing

To test the fixes, run:

```bash
# Version comparison (fixed script)
./collect_from_multiple_clusters.sh \
    --reason "SREP-12345 test" \
    --version-compare \
    --oper camo \
    --max-clusters 5

# Health check (fixed script)
./collect_from_multiple_clusters.sh \
    --reason "SREP-12345 test" \
    --health \
    --oper camo \
    --max-clusters 5

# CAMO metrics (fixed script)
./collect_from_multiple_clusters.sh \
    --reason "SREP-12345 test" \
    --metrics \
    --oper camo \
    --max-clusters 5
```

## Impact

These fixes ensure all CAMO collection scripts can properly:
1. Find CAMO ReplicaSets to detect version changes
2. Find CAMO pods to collect health status
3. Find CAMO pods to scrape Prometheus metrics
4. Query Prometheus for resource usage data
5. Handle both tagged and SHA-digest container images

All scripts should now work correctly across all ROSA clusters.
