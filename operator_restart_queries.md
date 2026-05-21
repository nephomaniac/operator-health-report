# Dynatrace Queries to Check Operator Pod Restart

These queries will help determine if the Dynatrace operator pod restarted at 10:30 UTC on 2026-04-06, which would explain the mass reconciliation trigger.

## Query 1: Check for Operator Pod Restart Events

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(k8s.pod.name, "dynatrace-operator")
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T11:00:00Z")
| filter event.type in ("Started", "Created", "Killing", "Stopped")
| fields timestamp, k8s.pod.name, event.type, event.reason, event.description
| sort timestamp asc
```

**What to look for:**
- Pod "Started" or "Created" events around 10:30 UTC
- Pod "Killing" or "Stopped" events shortly before 10:30 UTC
- This would indicate operator pod restart

---

## Query 2: Check Operator Container Logs for Startup Messages

```dql
fetch logs
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(k8s.pod.name, "dynatrace-operator")
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T11:00:00Z")
| filter matchesPhrase(content, "Starting") or
         matchesPhrase(content, "startup") or
         matchesPhrase(content, "Reconciling") or
         matchesPhrase(content, "version")
| fields timestamp, k8s.pod.name, content
| sort timestamp asc
| limit 100
```

**What to look for:**
- Operator startup log messages around 10:30 UTC
- Version information logs (printed at startup)
- First "Reconciling" messages after startup

---

## Query 3: Check for Operator Pod Deletion or Eviction

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(k8s.pod.name, "dynatrace-operator")
| filter timestamp >= toTimestamp("2026-04-06T09:00:00Z") and timestamp <= toTimestamp("2026-04-06T11:00:00Z")
| filter event.type in ("Killing", "Evicted", "Preempted", "OOMKilled")
| fields timestamp, k8s.pod.name, event.type, event.reason, event.description
| sort timestamp asc
```

**What to look for:**
- Pod eviction due to resource pressure
- OOMKilled events (operator ran out of memory)
- Manual deletion or preemption

---

## Query 4: Check Operator Deployment Updates

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter k8s.namespace.name == "dynatrace"
| filter timestamp >= toTimestamp("2026-04-06T09:00:00Z") and timestamp <= toTimestamp("2026-04-06T11:00:00Z")
| filter event.type == "Updated"
| filter matchesPhrase(event.description, "operator") or matchesPhrase(event.description, "Deployment")
| fields timestamp, k8s.namespace.name, event.type, event.description
| sort timestamp asc
```

**What to look for:**
- Deployment updates around 10:30 UTC
- ConfigMap or Secret updates that triggered operator restart
- Image updates or configuration changes

---

## Query 5: Timeline of All Operator Activity

```dql
fetch logs
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(k8s.pod.name, "dynatrace-operator")
| filter timestamp >= toTimestamp("2026-04-06T10:25:00Z") and timestamp <= toTimestamp("2026-04-06T10:35:00Z")
| fields timestamp, k8s.pod.name, loglevel, content
| sort timestamp asc
| limit 200
```

**What to look for:**
- Continuous log stream before 10:30 UTC = operator was running
- Gap in logs followed by startup messages = operator restarted
- Mass reconciliation messages starting at 10:30:00 UTC

---

## Alternative: oc Command (if cluster access available)

```bash
# Check operator pod age
oc get pods -n dynatrace -l app.kubernetes.io/name=dynatrace-operator \
  -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp,AGE:.status.startTime

# Check operator deployment history
oc rollout history deployment -n dynatrace dynatrace-operator

# Check operator pod events
oc describe pod -n dynatrace -l app.kubernetes.io/name=dynatrace-operator | grep -A20 "Events:"
```

---

## Expected Findings

### If Operator Restarted (Most Likely):
- Query 1 will show "Started" event around 10:30 UTC
- Query 2 will show startup log messages at 10:30 UTC
- Query 5 will show gap in logs, then startup, then mass reconciliation
- This confirms: Operator restart → Full state resync → All nodes reconciled → Mass pod recreation → Mount errors

### If Scheduled Reconciliation:
- Query 5 will show continuous operator logs (no restart)
- Reconciliation starts at 10:30 UTC without startup messages
- Less likely based on evidence (100 nodes reconciled simultaneously)

### If ConfigMap/Secret Update:
- Query 4 will show Update events for ConfigMap or Secret
- Query 5 will show operator reacting to update event
- May or may not involve operator restart

---

## Next Steps

1. Run Query 1 first - if it shows operator pod restart, investigation is complete
2. If Query 1 shows nothing, run Query 5 to see operator activity timeline
3. Run Query 2 and Query 3 for additional context
4. If using oc commands, check pod age and events directly

The combination of these queries should definitively answer: **Why did the operator trigger mass reconciliation at 10:30 UTC?**
