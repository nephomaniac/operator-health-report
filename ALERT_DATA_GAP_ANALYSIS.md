# Alert Data Gap Analysis

## Question
Does the Dynatrace data support the Prometheus alert rule and the `for: 60m` threshold?

## Answer
**NO** - Dynatrace data does NOT support the alert.

---

## Alert Definition

```yaml
alert: DynatraceDynakubeComponentsDegradedSRE
expr: (kube_daemonset_status_desired_number_scheduled{namespace="dynatrace", daemonset=~"hs-mc.+"}
       - kube_daemonset_status_number_ready{namespace="dynatrace", daemonset=~"hs-mc.+"}) > 0
for: 60m
```

**Requirements:**
- Condition `(desired - ready) > 0` must be **continuously true** for 60 minutes
- Alert fired at **11:59 UTC** → condition started at **10:59 UTC**
- Alert resolved at **12:19 UTC** (20 minutes later)

**Expected Evidence:**
- DaemonSet pods in "not ready" state from 10:59-11:59 UTC
- Readiness probe failures logged
- Kubernetes Warning events for unhealthy pods

---

## Dynatrace Data - Cluster hs-mc-s73d6f8p0

### Logs (fetch logs)

**Mount Errors:**
```
11:45:15 UTC - ip-10-0-48-154 - mount: write error
11:46:28 UTC - ip-10-0-128-156 - mount: write error
```

- **Total errors:** 2 during 10:59-11:59 window
- **Duration:** ~1 minute
- **Impact:** 2 pods affected

**Readiness Probe Failures:**
```
NONE captured
```

**Cluster Stability:**
| Time | Nodes | Events |
|------|-------|--------|
| 10:00 | 127 | 25,919 |
| 11:00 | 129 | 27,935 |
| 12:00 | 130 | 26,879 |

- Stable node count
- Normal event volume
- No anomalies detected

### Events (fetch events, KUBERNETES_EVENT)

**During incident window (10:00-13:00 UTC):**
```
Total events: 0
Event types: 0
Unique pods: 0
```

**ZERO Kubernetes events captured for this cluster.**

---

## Gap Analysis

| Data Source | Expected | Actual | Gap |
|-------------|----------|--------|-----|
| **Readiness failures** | 60 minutes of failures (10:59-11:59) | 0 minutes | **100% missing** |
| **Kubernetes events** | Warning events for unhealthy pods | 0 events | **100% missing** |
| **Mount errors** | Multiple errors spanning 60 min | 2 errors in 1 min | **98% missing** |
| **Pod degradation** | Multiple pods not ready | 2-3 pods briefly | **95% missing** |

---

## Why the Gap Exists

### Prometheus Alert Source
The alert uses **Prometheus metrics** from `kube-state-metrics`:
- `kube_daemonset_status_desired_number_scheduled`
- `kube_daemonset_status_number_ready`

These metrics are scraped directly from **Kubernetes API** and stored in **Prometheus**, NOT Dynatrace.

### Dynatrace Data Sources

**Dynatrace logs:**
- Sourced from: Pod stdout/stderr
- Captures: Application logs, container logs
- **Does NOT capture:** Kubernetes resource metrics, DaemonSet status

**Dynatrace events:**
- Sourced from: Kubernetes Event API
- Should capture: Pod lifecycle, readiness probes, warnings
- **Result for this cluster:** ZERO events ingested during incident

### Why Events Are Missing

**Hypothesis 1: Dynatrace Event Ingestion Disabled**
- Cluster hs-mc-s73d6f8p0 may not have Kubernetes event ingestion enabled
- Events are not forwarded to Dynatrace Grail storage

**Hypothesis 2: OneAgent Not Running During Incident**
- If OneAgent DaemonSet pods were degraded, they couldn't forward events
- Self-referential problem: degraded OneAgent can't report its own degradation

**Hypothesis 3: Event Retention/Storage Issue**
- Events captured but stored in different bucket
- Events expired faster than logs
- Events not indexed for querying

---

## Verification: Check Current Event Ingestion

### Test 1: Are events being captured NOW?

```bash
dtctl query \
  --default-timeframe-start "2026-04-07T00:00:00Z" \
  --default-timeframe-end "2026-04-07T06:00:00Z" \
  --default-scan-limit-gbytes 2000 \
  -o csv \
  -f - <<'EOF'
fetch events
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter event.provider == "KUBERNETES_EVENT"
| summarize total_events = count(), event_types = countDistinct(event.type)
EOF
```

**If result is 0:** Event ingestion is broken/disabled for this cluster.
**If result > 0:** Event ingestion works now, but was broken on April 6.

### Test 2: Check Dynatrace DynaKube configuration

```bash
oc get dynakube -n dynatrace -o yaml | grep -A10 "kubernetesMonitoring"
```

Look for: `enabled: true` under kubernetesMonitoring or activeGate event forwarding.

---

## Conclusion

### Can Dynatrace Data Support the Alert?

**NO** - for the following reasons:

1. **Wrong data source:** Alert uses Prometheus metrics, not Dynatrace data
2. **Missing events:** Zero Kubernetes events captured during incident
3. **Insufficient logs:** Only 2 mount errors in 1 minute (not 60 minutes)
4. **No readiness failures:** Readiness probe failures not logged to Dynatrace

### What Actually Happened?

**Prometheus observed (source of truth):**
- DaemonSet had `(desired - ready) > 0` for 60+ minutes (10:59-11:59 UTC)
- Alert correctly fired at 11:59 UTC
- Condition cleared, alert resolved at 12:19 UTC

**Dynatrace observed (incomplete view):**
- 2 mount errors at 11:45-11:46 UTC
- No events, no readiness failures, stable metrics
- Insufficient data to explain 60-minute degradation

### The Truth

The **60-minute degradation DID occur** (Prometheus metrics don't lie), but:
- Dynatrace **did not capture** the degradation events
- Dynatrace **did not capture** readiness probe failures
- Dynatrace **only captured** 2 application-level mount errors

**This is a Dynatrace observability gap, not an invalid alert.**

---

## Recommendations

### 1. Enable Kubernetes Event Forwarding

Ensure Dynatrace captures Kubernetes events:

```yaml
apiVersion: dynatrace.com/v1beta2
kind: DynaKube
spec:
  kubernetesMonitoring:
    enabled: true
    eventIngestion: true
```

### 2. Verify OneAgent Event Collection

Check OneAgent configuration:
```bash
oc get dynakube -n dynatrace -o jsonpath='{.spec.oneAgent.classicFullStack.eventCollection}'
```

### 3. Add Prometheus as Alert Source in Dynatrace

Configure Dynatrace to ingest Prometheus metrics:
- Prometheus remote write to Dynatrace
- Or use Dynatrace Prometheus exporter
- This would make alert metrics queryable in Dynatrace

### 4. Cross-Reference Multiple Data Sources

For future incidents:
1. **Prometheus:** Alert metrics (kube-state-metrics)
2. **Dynatrace:** Application logs, events
3. **Kubernetes:** `oc get events`
4. **Cluster metrics:** Prometheus queries for DaemonSet status

Don't rely on single source of truth.

### 5. Validate Alert with Historical Data

Before investigating future alerts:
```bash
# Check if Dynatrace has events for the timeframe
dtctl query "fetch events | filter dt.kubernetes.cluster.name == 'CLUSTER' | summarize count()"

# If count = 0, use alternative data sources
```

---

## Investigation Impact

This gap invalidates several investigation steps:

1. ❌ **Cannot use Dynatrace to validate alert duration**
   - 60-minute threshold not verifiable in Dynatrace data

2. ❌ **Cannot determine exact number of affected pods**
   - Only 2-3 mount errors visible, likely more pods affected

3. ❌ **Cannot see full incident timeline**
   - Missing events from 10:59-11:45 UTC (45 minutes)

4. ✅ **Can validate resolution**
   - No errors after 12:00 UTC, consistent with 12:19 UTC resolution

5. ✅ **Can identify root cause pattern**
   - Mount errors still occurred (even if incomplete view)

---

## Final Answer

**Does Dynatrace data support the `for: 60m` threshold?**

**NO.**

The alert is based on **Prometheus metrics** showing 60 minutes of DaemonSet degradation. Dynatrace only captured **2 mount errors in 1 minute** and **zero Kubernetes events**, insufficient to validate the 60-minute threshold.

**The alert is VALID, but Dynatrace lacks the observability to verify it.**
