# Dynatrace Queries: Cluster Scaling Investigation

## Query 1: Node Count Over Time (Around Incident)

Check if node count changed significantly after the incident.

```dql
fetch events
| filter event.provider == "KUBERNETES_EVENT"
| filter event.type == "Normal" or event.type == "CUSTOM_INFO"
| filter matchesPhrase(event.name, "Node") or matchesPhrase(event.name, "node")
| filter timestamp >= toTimestamp("2026-04-06T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| summarize node_events = count(), by:{day = bin(timestamp, 1d), event_type = event.type, event_name = event.name}
| sort day asc
```

**What to look for:** Spike in "Node" deletion/termination events after April 6


## Query 2: Cluster Autoscaler Events

Look for cluster autoscaler scaling decisions.

```dql
fetch logs
| filter contains(content, "autoscaler") or contains(content, "scale") or contains(content, "ScaleDown") or contains(content, "ScaleUp")
| filter timestamp >= toTimestamp("2026-04-06T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| fields timestamp, content, k8s.pod.name
| sort timestamp asc
| limit 500
```

**What to look for:**
- "ScaleDown" events
- "Removing node" messages
- "Cluster size reduced" logs


## Query 3: Node Lifecycle Events (Removals/Terminations)

Count node removal events by day.

```dql
fetch events
| filter event.provider == "KUBERNETES_EVENT"
| filter event.type == "NodeNotReady" or event.type == "NodeRemoved" or matchesPhrase(event.name, "Removing") or matchesPhrase(event.name, "Terminating")
| filter timestamp >= toTimestamp("2026-04-06T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| summarize removal_events = count(), by:{day = bin(timestamp, 1d)}
| sort day asc
```

**What to look for:** Spike in removals on specific day(s) after April 6


## Query 4: Unique Node Count Per Day

Count distinct nodes reporting each day to see cluster size change.

```dql
fetch logs
| filter k8s.namespace.name == "dynatrace"
| filter timestamp >= toTimestamp("2026-04-06T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| summarize unique_nodes = countDistinct(k8s.node.name), by:{day = bin(timestamp, 1d)}
| sort day asc
```

**What to look for:** Drop from ~222 nodes to ~132 nodes over time


## Query 5: Node Not Ready Events (Mass Terminations)

Check if many nodes went "NotReady" simultaneously (indicating mass termination).

```dql
fetch events
| filter event.provider == "KUBERNETES_EVENT"
| filter matchesPhrase(event.name, "Node is not ready") or matchesPhrase(event.name, "NotReady")
| filter timestamp >= toTimestamp("2026-04-06T12:19:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| summarize events = count(), unique_nodes = countDistinct(k8s.node.name), by:{hour = bin(timestamp, 1h)}
| sort hour asc
| limit 200
```

**What to look for:**
- Hours with high "Not Ready" events
- Indicates nodes being drained/terminated
- If you see 50-100+ node terminations in a short window, that's evidence of scaling


## Query 6: Machine Set / Machine Deployment Changes

Look for OpenShift Machine API events (if using OpenShift).

```dql
fetch events
| filter event.provider == "KUBERNETES_EVENT"
| filter contains(event.name, "Machine") or contains(k8s.pod.name, "machine")
| filter timestamp >= toTimestamp("2026-04-06T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| fields timestamp, event.name, event.type, k8s.namespace.name
| sort timestamp asc
| limit 500
```

**What to look for:** Machine deletion events after incident


## Expected Findings

**If cluster scaled down:**
- Unique node count drops from ~220+ to ~132 over days/weeks
- Spike in "Node Not Ready" or "Removing" events
- Cluster autoscaler logs showing "ScaleDown" decisions
- Machine deletion events (if OpenShift)

**If no scaling (just normal rotation):**
- Steady node count ~220-230 throughout the period
- Gradual node replacements (1-5 per day)
- No mass termination events

---

## How to Use These Queries

1. Run Query 4 first - it will show if node count changed
2. If count dropped, run Query 5 to find WHEN mass terminations happened
3. Run Query 2 to find WHY (autoscaler logs)
4. Run Query 3 to quantify the reduction

Save results to files:
- `cluster-size-over-time.csv` (Query 4)
- `node-removal-events.csv` (Query 5)
- `autoscaler-logs.csv` (Query 2)
