# DynatraceDynakubeComponentsDegradedSRE Alert Investigation - Final Summary

**Cluster:** hs-mc-s73d6f8p0 (ID: 2mmhjmo829o9gg539pvjl0n9sa7uvith)
**Alert Time:** 2026-04-06 11:59 UTC - 12:19 UTC (20 minutes)
**Investigation Date:** 2026-04-06 to 2026-04-07
**Status:** ✅ CONCLUDED

---

## Executive Summary

The **DynatraceDynakubeComponentsDegradedSRE** alert correctly fired due to sustained DaemonSet degradation. The incident was **far smaller than initially thought** - only **3 nodes** affected (not 98), with **no cluster scaling event**.

The investigation revealed a **critical Dynatrace configuration gap**: Kubernetes event monitoring is disabled, preventing validation of the alert's 60-minute threshold.

---

## Key Findings

### Actual Incident Scope (Cluster-Specific Data)

| Metric | Value |
|--------|-------|
| **Affected nodes** | 3 nodes (2.1% of cluster) |
| **Mount errors** | 3 errors (11:45, 11:46, 12:58 UTC) |
| **Cluster size** | 127-133 nodes (stable) |
| **Scaling event** | None - normal rotation only |
| **DaemonSets affected** | 1 (hs-mc-s73d6f8p0-wqn9x-oneagent) |

### What We Thought Initially (Cross-Cluster Data - WRONG)

| Metric | Incorrect Value | Actual Value |
|--------|----------------|--------------|
| Affected nodes | 98 | 3 |
| Cluster size | 222 | 127-133 |
| Nodes removed | 90 | ~11 (normal) |
| DaemonSets | 6 | 1 |
| Scaling event | Yes | No |

### Affected Nodes

1. **ip-10-0-48-154.ec2.internal** - mount error at 11:45:15 UTC
2. **ip-10-0-128-156.ec2.internal** - mount error at 11:46:28 UTC
3. **ip-10-0-128-4.ec2.internal** - mount error at 12:58:37 UTC

All 3 nodes have been replaced through normal lifecycle rotation (confirmed via `oc get nodes`).

---

## Root Cause

**Direct cause:** Mount write errors during OneAgent pod initialization
**Trigger:** Unknown (no operator rollout or mass pod recreation detected)
**Recovery:** Pods self-recovered after transient mount errors

**The alert threshold (60 minutes) was appropriate** - prevented alerting on brief transient issues.

---

## Critical Investigation Mistake

### The Cross-Cluster Data Pollution

**Problem:** Initial Dynatrace queries lacked cluster-specific filtering.

**Wrong queries:**
```dql
fetch logs
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(k8s.pod.name, "*hs-mc*oneagent*")
```

**Correct queries:**
```dql
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")  // ← CRITICAL
| filter k8s.namespace.name == "dynatrace"
```

**Impact:**
- Aggregated data from **38 clusters** in the Dynatrace tenant
- Led to false "98 affected nodes" and "90-node scaling event" theories
- Wasted investigation time on invalid hypotheses

**Lesson:** Always filter multi-cluster Dynatrace tenants by `dt.kubernetes.cluster.name`.

---

## Dynatrace Configuration Gap

### Kubernetes Monitoring Disabled

**Current configuration:**
```yaml
spec:
  kubernetesMonitoring: null  # ← NOT ENABLED
  metadataEnrichment:
    enabled: false
  activeGate:
    capabilities:
      - kubernetes-monitoring  # Capability present but unused
```

**Impact:**
- ❌ Zero Kubernetes events captured
- ❌ No readiness probe failure events
- ❌ No pod lifecycle events
- ❌ Cannot validate alert's 60-minute threshold
- ❌ Missing 60 minutes of incident timeline (10:59-11:59 UTC)

**Alert source:** Prometheus metrics (kube-state-metrics), not Dynatrace

**Recommendation:** Enable Kubernetes monitoring:
```bash
oc patch dynakube hs-mc-s73d6f8p0-wqn9x -n dynatrace --type=merge \
  -p '{"spec":{"kubernetesMonitoring":{"enabled":true}}}'
```

---

## dtctl Query Requirements

### Missing Parameters

Initial queries failed because they lacked:

1. **Timeframe parameters:**
   ```bash
   --default-timeframe-start "2026-04-06T00:00:00Z"
   --default-timeframe-end "2026-04-06T23:59:59Z"
   ```

2. **Scan limit:**
   ```bash
   --default-scan-limit-gbytes 2000
   ```

**Without these:** Queries return only last 2 hours of data and hit 500GB scan limits.

---

## Node Count Timeline

| Date/Time | Nodes | Change |
|-----------|-------|--------|
| Apr 6, 09:00 UTC | 127 | - |
| Apr 6, 11:00 UTC | 129 | +2 |
| Apr 6, 21:00 UTC | 133 | +4 (peak) |
| Apr 7, 04:00 UTC | 129 | -4 |
| Apr 7, current | 132 | +3 |

**Analysis:** Normal node lifecycle rotation. No scaling event occurred.

---

## Alert Validation

### Can Dynatrace Data Support the Alert?

**NO** - for these reasons:

1. **Alert uses Prometheus metrics**, not Dynatrace
2. **Kubernetes events not captured** (monitoring disabled)
3. **Only 2 mount errors in 1 minute** visible in logs
4. **60-minute degradation not verifiable** in Dynatrace

### Is the Alert Valid?

**YES** - the alert is valid:

1. **Prometheus observed** sustained DaemonSet degradation (10:59-11:59 UTC)
2. **Alert correctly fired** at 11:59 UTC after 60-minute threshold
3. **Alert correctly resolved** at 12:19 UTC when condition cleared

**The alert is valid; Dynatrace lacks observability to verify it.**

---

## What Worked

1. ✅ **Alert threshold (60 min)** - filtered transient issues
2. ✅ **Prometheus metrics** - accurate source of truth
3. ✅ **Pod self-recovery** - no manual intervention needed
4. ✅ **Node lifecycle** - normal rotation replaced affected nodes

---

## What Didn't Work

1. ❌ **Dynatrace event ingestion** - disabled, missing critical data
2. ❌ **Initial query filtering** - cross-cluster pollution
3. ❌ **dtctl parameter knowledge** - missing timeframe/scan limits
4. ❌ **Root cause identification** - trigger remains unknown

---

## Lessons Learned

### For Future Investigations

1. **ALWAYS filter by cluster name** in multi-cluster Dynatrace tenants:
   ```dql
   | filter matchesPhrase(dt.kubernetes.cluster.name, "CLUSTER_NAME")
   ```

2. **ALWAYS use timeframe parameters** with dtctl:
   ```bash
   --default-timeframe-start "YYYY-MM-DDTHH:MM:SSZ"
   --default-timeframe-end "YYYY-MM-DDTHH:MM:SSZ"
   --default-scan-limit-gbytes 2000
   ```

3. **Check data availability first** before deep investigation:
   ```bash
   dtctl query "fetch events | filter dt.kubernetes.cluster.name == 'X' | summarize count()"
   ```

4. **Verify cluster ID** matches investigation target early

5. **Don't assume single-cluster** when seeing aggregated metrics

### For Dynatrace Configuration

1. **Enable Kubernetes monitoring** on all production clusters
2. **Enable metadata enrichment** for better log context
3. **Verify event ingestion** is working (test queries)
4. **Document required dtctl parameters** for team runbooks

---

## Recommendations

### Immediate Actions

1. **Enable Kubernetes monitoring:**
   ```bash
   oc patch dynakube hs-mc-s73d6f8p0-wqn9x -n dynatrace --type=merge \
     -p '{"spec":{"kubernetesMonitoring":{"enabled":true}}}'
   ```

2. **Verify event ingestion** after enabling (wait 10 min)

3. **Update investigation runbooks** with correct dtctl parameters

### Long-term Improvements

1. **Review alert threshold** - consider if 60 min is appropriate for DaemonSet degradation
2. **Add alert scope** - consider alerting only if >5% pods unhealthy
3. **Enable monitoring on all clusters** - ensure no observability gaps
4. **Create Dynatrace query templates** - pre-configured with cluster filters

---

## Documentation Created

1. **CLUSTER_SPECIFIC_FINDINGS.md** - Corrected incident analysis
2. **ALERT_DATA_GAP_ANALYSIS.md** - Why Dynatrace can't verify the alert
3. **KUBERNETES_MONITORING_DISABLED.md** - Configuration issue details
4. **cluster_specific_queries.md** - Correct DQL queries with filtering
5. **run_cluster_queries.sh** - dtctl script with proper parameters
6. **HYPERSHIFT_MIGRATION_FINDINGS.md** - Invalid theory (cross-cluster data)
7. **CLUSTER_SCALING_ANALYSIS.md** - Initial analysis (later corrected)

---

## Files Generated

### Query Results (Cluster-Specific, Correct)
- `cluster-q1-node-count-daily.csv` - Node count Apr 5-7
- `cluster-q2-mount-errors.csv` - 3 affected nodes
- `cluster-q3-readiness-failures.csv` - No data (events disabled)
- `cluster-q6-mount-error-timeline.csv` - 2 mount errors captured
- `cluster-q7-node-count-hourly.csv` - Hourly trend (127-133 nodes)

### Previous Files (Cross-Cluster, Invalid)
- `table-data-nodes.csv` - 98 nodes (from multiple clusters)
- `table-data-q5.csv` - Machine events (multiple clusters)
- `table-data-q6.csv` - Deletion errors (ip-10-25-* cluster)

---

## Conclusion

The April 6 **DynatraceDynakubeComponentsDegradedSRE** alert was a **valid, minimal incident** affecting only 3 nodes with mount errors. The alert correctly fired after 60 minutes of sustained DaemonSet degradation and resolved after 20 minutes.

**Initial investigation was misled by cross-cluster data pollution**, leading to false theories about 98 affected nodes and a 90-node scaling event. **Cluster-specific queries revealed the actual scope:** 3 nodes, normal cluster operations, no scaling.

**Dynatrace cannot verify the alert** due to disabled Kubernetes event monitoring, but the **alert itself is valid** based on Prometheus metrics.

**Key action:** Enable Kubernetes monitoring to prevent future observability gaps.

---

**Investigation Status:** ✅ COMPLETE
**Alert Status:** Valid - Minor incident, correctly detected
**Follow-up Required:** Enable Kubernetes monitoring on cluster hs-mc-s73d6f8p0
