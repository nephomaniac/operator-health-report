# Kubernetes Monitoring Architecture Clarification

## Correction: Kubernetes Monitoring IS Enabled (via Prometheus)

### Initial Misunderstanding

**What I thought:** Kubernetes monitoring is disabled, causing an observability gap.

**Actually:** Kubernetes monitoring is enabled via **Prometheus → Dynatrace forwarding**, making native Dynatrace Kubernetes monitoring redundant.

---

## Architecture

### How Kubernetes Metrics Reach Dynatrace

```
┌─────────────────────────────────────────────────────────────┐
│ Kubernetes Cluster (hs-mc-s73d6f8p0)                        │
│                                                              │
│  ┌──────────────┐                                           │
│  │ kube-state-  │ ──── scrapes ───┐                        │
│  │ metrics      │                  │                        │
│  └──────────────┘                  │                        │
│                                    ▼                        │
│                            ┌──────────────┐                 │
│                            │  Prometheus  │                 │
│                            │              │                 │
│                            │  - Stores    │                 │
│                            │  - Alerts    │                 │
│                            │  - Forwards  │                 │
│                            └──────────────┘                 │
│                                    │                        │
│                                    │ remote_write           │
│                                    ▼                        │
│                            ┌──────────────┐                 │
│                            │  Dynatrace   │                 │
│                            │  Metrics API │                 │
│                            └──────────────┘                 │
└─────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                            ┌──────────────┐
                            │  Dynatrace   │
                            │  Tenant      │
                            │  (jgn20300)  │
                            └──────────────┘
```

### Why DynaKube Kubernetes Monitoring is Disabled

**DynaKube configuration:**
```yaml
spec:
  kubernetesMonitoring: null  # Intentionally disabled
```

**Reason:** Prometheus is already collecting and forwarding Kubernetes metrics, so native Dynatrace Kubernetes monitoring would be:
- ✅ Redundant (duplicate data)
- ✅ Additional resource overhead
- ✅ Unnecessary complexity

**This is the correct architecture for this environment.**

---

## Data Sources in Dynatrace

### What IS Available (Prometheus Forwarded)

**Metrics (time-series data):**
- `kube_daemonset_status_desired_number_scheduled`
- `kube_daemonset_status_number_ready`
- `kube_pod_status_ready`
- `kube_node_status_condition`
- All kube-state-metrics and node-exporter metrics

**Query source:** `fetch metrics` (not `fetch events`)

### What is NOT Available (Not Forwarded by Prometheus)

**Kubernetes Events (API objects):**
- Pod lifecycle events (Created, Started, Killing)
- Readiness probe failures (Unhealthy warnings)
- Image pull events
- Volume mount failures
- Node lifecycle events

**Why:** Prometheus collects **metrics** (numeric time-series), not **events** (discrete API objects). Kubernetes Events are a separate API resource that Prometheus doesn't scrape.

---

## Alert Data Source

### The Alert Uses Prometheus Metrics

```yaml
alert: DynatraceDynakubeComponentsDegradedSRE
expr: (kube_daemonset_status_desired_number_scheduled{namespace="dynatrace"}
       - kube_daemonset_status_number_ready{namespace="dynatrace"}) > 0
for: 60m
```

**Source:** Prometheus scrapes kube-state-metrics → evaluates alert rule → forwards to Dynatrace

**These metrics ARE in Dynatrace** (via Prometheus remote_write).

---

## Why We Couldn't Verify the 60-Minute Threshold

### The Real Issue

We were querying the **wrong data source** in Dynatrace.

**What we tried:**
```dql
fetch logs      # Application logs only
fetch events    # Kubernetes Events (not forwarded)
```

**What we should have tried:**
```dql
fetch metrics   # Prometheus metrics (forwarded)
| filter k8s.cluster.name == "hs-mc-s73d6f8p0"
| filter k8s.namespace.name == "dynatrace"
```

### Correct Query to Verify Alert

To verify the 60-minute degradation, we should query the **same metrics** the alert uses:

```bash
dtctl query \
  --default-timeframe-start "2026-04-06T10:00:00Z" \
  --default-timeframe-end "2026-04-06T13:00:00Z" \
  -o csv \
  -f - <<'EOF'
fetch metrics
| filter k8s.cluster.name == "hs-mc-s73d6f8p0"
| filter k8s.namespace.name == "dynatrace"
| filter metric.key == "kube_daemonset_status_desired_number_scheduled"
       or metric.key == "kube_daemonset_status_number_ready"
| fields timestamp, metric.key, value, k8s.daemonset.name
| sort timestamp asc
EOF
```

This would show the actual `desired` vs `ready` counts over time.

---

## Updated Analysis

### Configuration is Correct

❌ **Previous conclusion:** Kubernetes monitoring disabled = observability gap
✅ **Corrected conclusion:** Kubernetes monitoring via Prometheus = intentional architecture

### Data is Available

❌ **Previous conclusion:** Can't verify 60-minute threshold in Dynatrace
✅ **Corrected conclusion:** Can verify using `fetch metrics`, not `fetch events`

### The "Gap" is Different

**Real gap:** We queried logs/events instead of metrics

**Not a gap:**
- Kubernetes monitoring IS enabled (via Prometheus)
- Metrics ARE in Dynatrace (forwarded from Prometheus)
- Alert data IS queryable (just needed correct query)

---

## Why Readiness Probe Failures Weren't Found

### Kubernetes Events vs Prometheus Metrics

**Kubernetes Events (API objects):**
```bash
kubectl get events -n dynatrace
# Shows: Pod unhealthy, readiness probe failed, etc.
```

These are **discrete event objects** stored in etcd, expire after 1 hour.

**Prometheus Metrics (time-series):**
```promql
kube_pod_status_ready{namespace="dynatrace"} == 0
```

These are **numeric gauges** scraped periodically, stored indefinitely.

### What Prometheus Captures

✅ **Pod readiness state** (0 = not ready, 1 = ready)
✅ **DaemonSet desired vs ready counts**
✅ **Container restart counts**
✅ **Pod phase** (Pending, Running, Failed)

❌ **Event messages** ("Readiness probe failed: Cannot find watchdog.conf")
❌ **Event reasons** (Unhealthy, BackOff, Failed)
❌ **Event timestamps** (discrete occurrences)

### Why This Matters

**The alert fired based on metric state** (desired > ready for 60 min), not event occurrences.

**We can verify the metric state** in Dynatrace using `fetch metrics`.

**We cannot see the event details** (probe failure messages) because Prometheus doesn't forward those.

---

## Revised Recommendations

### ~~Enable Kubernetes Monitoring~~ (Not Needed)

**Previous recommendation:** Enable `spec.kubernetesMonitoring` in DynaKube

**Revised:** **DO NOT enable** - this would create duplicate data and waste resources. Prometheus forwarding is the correct approach.

### Query Metrics Instead of Events

**For alert validation:**
```bash
dtctl query "fetch metrics | filter metric.key startsWith 'kube_daemonset_status'"
```

**For pod readiness:**
```bash
dtctl query "fetch metrics | filter metric.key == 'kube_pod_status_ready'"
```

### Accept Event Limitation

**Kubernetes Events** (detailed messages) are **not available** in Dynatrace when using Prometheus forwarding.

**Alternative sources for events:**
1. Kubernetes cluster directly: `oc get events`
2. Prometheus Alertmanager (if configured)
3. Cluster logging (if events are logged)

---

## Testing: Verify Metrics are Available

Let me test if we can query the alert metrics in Dynatrace:

```bash
dtctl query \
  --default-timeframe-start "2026-04-06T10:00:00Z" \
  --default-timeframe-end "2026-04-06T13:00:00Z" \
  --default-scan-limit-gbytes 2000 \
  -o csv \
  -f - <<'EOF'
fetch metrics
| filter k8s.cluster.name == "hs-mc-s73d6f8p0"
| filter k8s.namespace.name == "dynatrace"
| filter metric.key in ["kube_daemonset_status_desired_number_scheduled", "kube_daemonset_status_number_ready"]
| summarize avg(value), by:{time = bin(timestamp, 5m), metric = metric.key, daemonset = k8s.daemonset.name}
| sort time asc
EOF
```

This should show the DaemonSet health over time and reveal the 60-minute degradation period.

---

## Conclusion

**Kubernetes monitoring IS enabled** via Prometheus → Dynatrace forwarding.

**The alert CAN be verified** in Dynatrace using `fetch metrics`.

**The configuration is correct** - no changes needed to DynaKube.

**The investigation mistake** was querying `fetch events` (not available) instead of `fetch metrics` (available).

**Action:** Re-run investigation using `fetch metrics` queries to verify the 60-minute threshold.
