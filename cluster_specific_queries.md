# Cluster-Specific Dynatrace Queries for hs-mc-s73d6f8p0

**Cluster Name:** hs-mc-s73d6f8p0
**Cluster ID:** 2mmhjmo829o9gg539pvjl0n9sa7uvith
**Filter:** `matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")`

---

## Query 1: Unique Node Count Per Day (Cluster-Specific)

Determine actual node count for THIS cluster on April 5-6.

```dql
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter k8s.namespace.name == "dynatrace"
| filter timestamp >= toTimestamp("2026-04-05T00:00:00Z") and timestamp <= toTimestamp("2026-04-07T00:00:00Z")
| summarize unique_nodes = countDistinct(k8s.node.name), by:{day = bin(timestamp, 1d)}
| sort day asc
```

**Expected Output:**
- April 5: X nodes
- April 6: Y nodes
- April 7: Z nodes

**This will show if node count changed for THIS cluster.**

---

## Query 2: Mount Error Nodes (Cluster-Specific)

Find nodes that experienced mount errors during the incident.

```dql
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(content, "mount: write error") or matchesPhrase(content, "mount error")
| filter timestamp >= toTimestamp("2026-04-06T10:30:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| summarize error_count = count(), by:{node = k8s.node.name}
| sort error_count desc
```

**Expected Output:**
- List of nodes with mount errors
- Count of errors per node

**This will show actual affected nodes for THIS cluster.**

---

## Query 3: OneAgent Readiness Failures (Cluster-Specific)

Count readiness probe failures during incident window.

```dql
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(k8s.pod.name, "hs-mc-s73d6f8p0-wqn9x-oneagent")
| filter matchesPhrase(content, "Cannot find") and matchesPhrase(content, "watchdog.conf")
| filter timestamp >= toTimestamp("2026-04-06T10:30:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| summarize failures = count(), unique_pods = countDistinct(k8s.pod.name), unique_nodes = countDistinct(k8s.node.name), by:{hour = bin(timestamp, 1h)}
| sort hour asc
```

**Expected Output:**
- Hourly breakdown of readiness failures
- Number of unique pods affected
- Number of unique nodes affected

---

## Query 4: Dynatrace Operator Rollout Events (Cluster-Specific)

Check if operator Deployment updated during incident.

```dql
fetch events
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter event.provider == "KUBERNETES_EVENT"
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(event.name, "dynatrace-operator") or matchesPhrase(k8s.deployment.name, "dynatrace-operator")
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| fields timestamp, event.type, event.name, k8s.deployment.name
| sort timestamp asc
```

**Expected Output:**
- Deployment update events
- Pod creation/deletion events
- Timing of operator changes

---

## Query 5: Node Deletion Events (Cluster-Specific)

Check for node deletions/terminations after incident.

```dql
fetch events
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter event.provider == "KUBERNETES_EVENT"
| filter matchesPhrase(event.name, "Removing") or matchesPhrase(event.name, "Terminating") or matchesPhrase(event.name, "Deleting")
| filter timestamp >= toTimestamp("2026-04-06T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| summarize deletion_events = count(), by:{day = bin(timestamp, 1d), event_name = event.name}
| sort day asc
```

**Expected Output:**
- Daily count of node deletion events
- Event types (Removing, Terminating, etc.)

---

## Query 6: EBS Write Latency Correlation (Cluster-Specific)

Find nodes experiencing mount errors and correlate with time.

```dql
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(content, "mount: write error")
| filter timestamp >= toTimestamp("2026-04-06T10:30:00Z") and timestamp <= toTimestamp("2026-04-06T12:30:00Z")
| fields timestamp, k8s.node.name, k8s.pod.name, content
| sort timestamp asc
| limit 500
```

**Expected Output:**
- Timeline of mount errors
- Specific nodes and pods affected
- Correlation with 11:00 UTC EBS write latency spike

---

## Query 7: Cluster Size Over Time (Hourly Granularity)

More granular view of node count changes.

```dql
fetch logs
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter k8s.namespace.name == "dynatrace"
| filter timestamp >= toTimestamp("2026-04-05T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| summarize unique_nodes = countDistinct(k8s.node.name), total_events = count(), by:{hour = bin(timestamp, 1h)}
| sort hour asc
```

**Expected Output:**
- Hourly node count
- Shows gradual vs sudden changes

---

## Query 8: Machine/Node Replacement Events (Cluster-Specific)

Check for Machine API activity during/after incident.

```dql
fetch events
| filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")
| filter event.provider == "KUBERNETES_EVENT"
| filter matchesPhrase(event.name, "Machine") or matchesPhrase(event.name, "Node")
| filter timestamp >= toTimestamp("2026-04-06T00:00:00Z") and timestamp <= toTimestamp("2026-04-14T00:00:00Z")
| summarize events = count(), by:{day = bin(timestamp, 1d), event_type = event.type}
| sort day asc
```

**Expected Output:**
- Machine/Node lifecycle events
- Patterns indicating replacement vs scaling

---

## Priority Order

Run these queries in this order:

1. **Query 1** - Establish baseline node count for THIS cluster
2. **Query 2** - Identify actual affected nodes
3. **Query 3** - Quantify readiness failures
4. **Query 6** - Get mount error timeline
5. **Query 7** - Check for node count changes over time
6. **Query 4** - Confirm operator rollout timing
7. **Query 5** - Check for node deletions
8. **Query 8** - Machine API activity

---

## Critical Questions to Answer

1. **How many nodes did THIS cluster have on April 6?**
   - Query 1 will answer this

2. **How many nodes were affected by mount errors?**
   - Query 2 will answer this

3. **Did THIS cluster scale down after the incident?**
   - Compare Query 1 (April 6 count) to current count (132)

4. **Were the affected nodes replaced?**
   - Cross-reference Query 2 node list with current node list

5. **Was this incident unique to April 6 or ongoing?**
   - Query 3 & 7 will show if pattern continues

---

## Notes

- All queries now include: `filter matchesPhrase(dt.kubernetes.cluster.name, "hs-mc-s73d6f8p0")`
- This eliminates cross-cluster data pollution
- Previous investigation conclusions based on multi-cluster data are invalid
- Must re-establish facts with cluster-specific data
