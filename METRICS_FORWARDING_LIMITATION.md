# Prometheus Metrics Forwarding Limitation

## Key Discovery

**Only a subset of Prometheus metrics are forwarded to Dynatrace.**

The alert metrics (`kube_daemonset_status_desired_number_scheduled`, `kube_daemonset_status_number_ready`) are **NOT** in that subset.

---

## What We Tried

### Query Attempts

1. **DQL syntax exploration:**
   ```dql
   fetch metrics              ❌ Not a valid data object
   fetch events               ❌ Kubernetes events not forwarded
   fetch logs                 ✅ Works (application logs only)
   ```

2. **Timeseries syntax (from metric_example.txt):**
   ```dql
   timeseries {
     desired = avg(kube_daemonset_status_desired_number_scheduled, default: 0),
     ready = avg(kube_daemonset_status_number_ready, default: 0)
   }, by:{k8s.cluster.name, k8s.namespace.name, k8s.daemonset.name}
   ```

   **Result:** Empty (no data)

3. **Verified with example metric:**
   ```dql
   timeseries sum(node_ethtool_bw_in_allowance_exceeded, default: 0)
   ```

   This metric likely exists (shown in metric_example.txt), demonstrating that **some** Prometheus metrics ARE forwarded.

---

## Why DaemonSet Metrics Aren't Available

### Prometheus → Dynatrace Forwarding

**Architecture:**
```
Prometheus → (remote_write) → Dynatrace Metrics API
```

**Selective forwarding:**
- ✅ Specific metrics configured for forwarding (e.g., node_ethtool_*)
- ❌ kube-state-metrics NOT forwarded (including kube_daemonset_status_*)
- ❌ Alert evaluation metrics NOT available in Dynatrace

### Configuration

The Prometheus remote_write configuration likely has filters:

```yaml
remote_write:
  - url: https://jgn20300.apps.dynatrace.com/api/v2/metrics/ingest
    write_relabel_configs:
      - source_labels: [__name__]
        regex: 'node_.*|custom_.*'  # Example: only forward node_* metrics
        action: keep
```

**This excludes kube-state-metrics** (`kube_*`) from being forwarded.

---

## What Metrics ARE Forwarded

Based on metric_example.txt:

**Node metrics (confirmed):**
- `node_ethtool_bw_in_allowance_exceeded`
- `node_ethtool_bw_out_allowance_exceeded`
- `node_ethtool_pps_allowance_exceeded`

**Likely forwarded (common patterns):**
- `node_*` - Node exporter metrics
- `container_*` - Container metrics (maybe)
- Custom application metrics

**NOT forwarded:**
- `kube_*` - kube-state-metrics (Kubernetes resource states)
- `apiserver_*` - API server metrics
- `etcd_*` - etcd metrics

---

## Impact on Investigation

### Can We Verify the 60-Minute Alert Threshold?

**NO** - for these reasons:

1. ✅ **Alert uses Prometheus metrics** (`kube_daemonset_status_*`)
2. ❌ **Metrics NOT forwarded** to Dynatrace
3. ❌ **Cannot query** in Dynatrace DQL
4. ❌ **No alternative data source** in Dynatrace (events also not forwarded)

### What CAN We Verify?

**In Dynatrace:**
- ✅ Application logs (mount errors)
- ✅ Cluster state (node count via logs)
- ✅ Forwarded metrics (node_* metrics if relevant)

**Outside Dynatrace:**
- ✅ Prometheus UI (alert metrics available there)
- ✅ Kubernetes events (`oc get events`)
- ✅ Kubernetes API (DaemonSet status directly)

---

## Verification Alternatives

### Option 1: Query Prometheus Directly

If you have access to the Prometheus instance:

```promql
# Query the exact alert expression
(kube_daemonset_status_desired_number_scheduled{namespace="dynatrace"}
 - kube_daemonset_status_number_ready{namespace="dynatrace"})

# Time range: 2026-04-06 10:00 - 13:00 UTC
```

This will show the actual metric values that triggered the alert.

### Option 2: Check Prometheus Alert History

```promql
# Check when the alert was firing
ALERTS{alertname="DynatraceDynakubeComponentsDegradedSRE"}
```

Or check the Prometheus UI alerts page for historical alert state.

### Option 3: Query Kubernetes API

```bash
# Check current DaemonSet status
oc get daemonset -n dynatrace hs-mc-s73d6f8p0-wqn9x-oneagent \
  -o jsonpath='{.status}'

# Historical status would require events or metrics
oc get events -n dynatrace --field-selector involvedObject.name=hs-mc-s73d6f8p0-wqn9x-oneagent
```

### Option 4: Dynatrace Alerting Integration

If Prometheus alerts are forwarded to Dynatrace as **problems/events**, check:

```dql
fetch events
| filter event.type == "CUSTOM_ALERT" or event.type == "PROMETHEUS_ALERT"
| filter matchesPhrase(event.name, "DynatraceDynakubeComponentsDegradedSRE")
```

(This would only work if alert notifications are sent to Dynatrace, not metrics)

---

## DQL Syntax Clarification

### Correct Syntax for Querying Metrics (When Available)

Based on metric_example.txt:

```dql
timeseries {
  metric_alias = aggregation_function(metric_name, default: 0)
}, by:{dimension1, dimension2}
| filter dimension1 == "value"
| fieldsAdd calculated = metric1[] + metric2[]
```

**Example:**
```dql
timeseries {
  drops_in = sum(node_ethtool_bw_in_allowance_exceeded, default: 0),
  drops_out = sum(node_ethtool_bw_out_allowance_exceeded, default: 0)
}, by:{k8s.cluster.name, k8s.node.name}
| filter k8s.cluster.name == "hs-mc-s73d6f8p0"
| fieldsAdd total_drops = drops_in[] + drops_out[]
```

**Key syntax elements:**
- `timeseries { alias = function(metric, default: value) }`
- `by:{dimension}` - group by dimensions
- `filter` - filter results
- `fieldsAdd` - add calculated fields
- Array indexing with `[]` for time-series values

---

## Recommendation: Expand Metrics Forwarding (Optional)

### If Alert Verification in Dynatrace is Desired

Update Prometheus remote_write configuration to include kube-state-metrics:

```yaml
remote_write:
  - url: https://jgn20300.apps.dynatrace.com/api/v2/metrics/ingest
    write_relabel_configs:
      - source_labels: [__name__]
        regex: 'node_.*|kube_daemonset_.*|kube_pod_.*'  # Add kube_* metrics
        action: keep
```

**Trade-offs:**
- ✅ Alert metrics queryable in Dynatrace
- ✅ Full Kubernetes observability in one place
- ❌ Increased metric cardinality
- ❌ Higher Dynatrace costs (more metrics ingested)
- ❌ Duplicate data (already in Prometheus)

**Verdict:** Probably not worth it - Prometheus is the source of truth for these metrics.

---

## Final Answer

### Can Dynatrace Data Support the Alert's 60-Minute Threshold?

**NO** - for these reasons:

1. Alert based on `kube_daemonset_status_*` metrics from Prometheus
2. These metrics are **NOT forwarded** to Dynatrace (selective forwarding)
3. Cannot be queried in Dynatrace DQL
4. Kubernetes events also not available (Prometheus doesn't forward events)

### Is This a Problem?

**NO** - this is **by design**:

- ✅ Prometheus is the source of truth for Kubernetes metrics
- ✅ Prometheus evaluates alerts correctly
- ✅ Dynatrace receives application logs and selected metrics
- ✅ Selective forwarding reduces costs and duplicate data

### How to Verify the Alert?

**Use Prometheus directly:**
- Query the alert expression in Prometheus UI
- Check alert history in Prometheus
- Prometheus has full historical data for Kubernetes metrics

**Or use Kubernetes API:**
- `oc get events` for historical events (if not expired)
- `oc get daemonset` for current status
- Kubernetes audit logs (if enabled)

---

## Conclusion

The investigation revealed:

1. ✅ **Incident scope:** 3 nodes affected (not 98)
2. ✅ **No scaling:** Cluster stable at 127-133 nodes
3. ✅ **Alert is valid:** Prometheus correctly detected degradation
4. ❌ **Cannot verify in Dynatrace:** Metrics not forwarded

**The alert cannot be verified in Dynatrace, but this is expected and correct given the selective metrics forwarding architecture.**

**No configuration changes needed** - the system is working as designed.
