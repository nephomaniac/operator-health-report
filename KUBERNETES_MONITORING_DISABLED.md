# Kubernetes Monitoring Configuration Issue

## Root Cause: Kubernetes Monitoring Not Enabled

### Current Configuration (DynaKube: hs-mc-s73d6f8p0-wqn9x)

```json
{
  "kubernetesMonitoring": null,
  "metadataEnrichment": {
    "enabled": false
  },
  "activeGate": {
    "capabilities": [
      "routing",
      "kubernetes-monitoring",  // ← Capability present
      "dynatrace-api",
      "metrics-ingest"
    ]
  }
}
```

### The Problem

**Kubernetes event ingestion is DISABLED** because:

1. ✅ **ActiveGate has capability:** `kubernetes-monitoring` is listed
2. ❌ **DynaKube spec missing:** `spec.kubernetesMonitoring` is `null`
3. ❌ **Metadata enrichment disabled:** `spec.metadataEnrichment.enabled: false`

### Impact on Investigation

**This explains why:**
- ❌ Zero Kubernetes events captured in Dynatrace (both April 6 and April 7)
- ❌ No pod lifecycle events (Created, Started, Killing, etc.)
- ❌ No readiness probe failure events (Unhealthy warnings)
- ❌ No DaemonSet status change events
- ❌ Cannot verify the 60-minute alert threshold in Dynatrace

**We can only see:**
- ✅ Application logs (stdout/stderr from pods)
- ✅ Mount errors in logs (2 errors captured)
- ✅ Basic metrics (node count, event volume)

### Why ActiveGate Capability Alone Isn't Enough

The Dynatrace Operator requires **two-level enablement**:

**Level 1: ActiveGate Capability** ✅ Present
```yaml
spec:
  activeGate:
    capabilities:
      - kubernetes-monitoring  # Capability present
```

**Level 2: Feature Configuration** ❌ Missing
```yaml
spec:
  kubernetesMonitoring:
    enabled: true  # Feature NOT enabled
```

**Without Level 2, the ActiveGate capability is unused.**

### Comparison: What Should Be Enabled

**Minimal configuration for event ingestion:**
```yaml
apiVersion: dynatrace.com/v1beta2
kind: DynaKube
metadata:
  name: hs-mc-s73d6f8p0-wqn9x
  namespace: dynatrace
spec:
  activeGate:
    capabilities:
      - routing
      - kubernetes-monitoring  # ← Already present
      - dynatrace-api
      - metrics-ingest

  kubernetesMonitoring:  # ← ADD THIS
    enabled: true

  metadataEnrichment:  # ← OPTIONAL: Adds K8s metadata to logs
    enabled: true
```

**Full configuration for comprehensive monitoring:**
```yaml
spec:
  kubernetesMonitoring:
    enabled: true
    replicas: 1
    group: "hs-mc-s73d6f8p0-wqn9x"
    serviceAccountName: dynatrace-kubernetes-monitoring

  metadataEnrichment:
    enabled: true
    namespaceSelector:
      matchExpressions:
        - key: name
          operator: NotIn
          values:
            - kube-system
            - kube-public
```

### How to Enable Kubernetes Monitoring

**Option 1: Patch the DynaKube resource**
```bash
oc patch dynakube hs-mc-s73d6f8p0-wqn9x -n dynatrace --type=merge -p '
{
  "spec": {
    "kubernetesMonitoring": {
      "enabled": true
    }
  }
}'
```

**Option 2: Edit the DynaKube YAML**
```bash
oc edit dynakube hs-mc-s73d6f8p0-wqn9x -n dynatrace
```

Add:
```yaml
spec:
  kubernetesMonitoring:
    enabled: true
```

**Option 3: Apply full configuration**
```bash
oc apply -f - <<EOF
apiVersion: dynatrace.com/v1beta2
kind: DynaKube
metadata:
  name: hs-mc-s73d6f8p0-wqn9x
  namespace: dynatrace
spec:
  # ... existing spec fields ...
  kubernetesMonitoring:
    enabled: true
  metadataEnrichment:
    enabled: true
EOF
```

### Verification After Enabling

**1. Check DynaKube status:**
```bash
oc get dynakube -n dynatrace hs-mc-s73d6f8p0-wqn9x -o jsonpath='{.status.kubernetesMonitoring}'
```

Expected: `{"state":"Running","version":"..."}`

**2. Check ActiveGate pods:**
```bash
oc get pods -n dynatrace -l app.kubernetes.io/component=activegate
```

Should see ActiveGate pods restarted with kubernetes-monitoring enabled.

**3. Test event ingestion (wait 5-10 minutes):**
```bash
dtctl query \
  --default-timeframe-start "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --default-timeframe-end "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -o csv \
  -f - <<'EOF'
fetch events
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter event.provider == "KUBERNETES_EVENT"
| summarize count()
EOF
```

Expected: `count() > 0`

**4. Check for pod events:**
```bash
dtctl query -f - -o table <<'EOF'
fetch events
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter event.provider == "KUBERNETES_EVENT"
| summarize count(), by:{event_type = event.type}
| sort count() desc
EOF
```

Expected to see: `Normal`, `Warning`, `Error` event types.

### Impact on Future Incidents

**With Kubernetes Monitoring Enabled:**
- ✅ Readiness probe failures captured as Warning events
- ✅ Pod lifecycle visible (Created, Started, Killing, Terminated)
- ✅ DaemonSet status changes logged
- ✅ Can validate alert thresholds in Dynatrace
- ✅ Full incident timeline visible
- ✅ No need to cross-reference Kubernetes events via `oc get events`

**Current State (Monitoring Disabled):**
- ❌ Must use `oc get events` for incident investigation
- ❌ Cannot verify Prometheus alerts in Dynatrace
- ❌ Missing 60+ minutes of incident timeline
- ❌ Only application logs visible (incomplete view)

### Recommendation

**Enable Kubernetes Monitoring immediately** to avoid future observability gaps.

**Priority: HIGH**

This is a production cluster with active alerting. The monitoring gap prevented validation of a critical alert and forced reliance on ephemeral Kubernetes events (which expire after 1 hour).

### Related Documentation

- Dynatrace Operator: https://docs.dynatrace.com/docs/setup-and-configuration/setup-on-k8s/installation/classic-full-stack
- Kubernetes Monitoring: https://docs.dynatrace.com/docs/setup-and-configuration/setup-on-k8s/guides/operation/k8s-monitoring
- Event Ingestion: https://docs.dynatrace.com/docs/observe-and-explore/events-and-alerts/kubernetes-events

---

## Summary

**Why Dynatrace can't support the 60-minute alert threshold:**

1. Kubernetes monitoring **not enabled** in DynaKube spec
2. Kubernetes events **not ingested** into Dynatrace
3. Readiness probe failures **not captured**
4. Only **application logs** available (incomplete)

**Solution:** Enable `spec.kubernetesMonitoring.enabled: true` in DynaKube.

**Impact:** Future incidents will have full observability in Dynatrace.
