# Mount Failure Triage Guide

Investigation of mount write errors during OneAgent pod initialization.

---

## Step 1: Identify Affected Nodes

### Dynatrace Query - Get Pod-to-Node Mapping

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter k8s.namespace.name == "dynatrace"
| filter k8s.pod.name in (
    "hs-mc-39koj380g-8p85p-oneagent-5x8b4",
    "hs-mc-39koj380g-8p85p-oneagent-27bds",
    "hs-mc-co775rj1g-ctglt-oneagent-vzcq6",
    "hs-mc-g1lr73hi0-xppdv-oneagent-2dncr",
    "hs-mc-up2eebpog-skmrm-oneagent-jkc5h"
  )
| filter timestamp >= toTimestamp("2026-04-06T10:50:00Z") and timestamp <= toTimestamp("2026-04-06T12:30:00Z")
| fields timestamp, k8s.pod.name, k8s.node.name, event.type, event.description
| sort timestamp asc
```

**Alternative - Get all pods with mount errors:**

```dql
fetch logs
| filter k8s.namespace.name == "dynatrace"
| filter matchesPhrase(content, "mount: write error")
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| fields timestamp, k8s.pod.name, k8s.node.name, k8s.daemonset.name
| summarize count(), by:{k8s.node.name}
| sort count desc
```

**What to look for:**
- Are all mount errors on the same node? (Node-specific issue)
- Spread across multiple nodes? (Cluster-wide issue)
- Correlation with node type/region/zone?

---

## Step 2: Node Resource Pressure

### Dynatrace Query - Node Metrics During Incident

```dql
timeseries
  cpu_usage = avg(dt.host.cpu.usage),
  memory_usage = avg(dt.host.memory.used),
  disk_io_write = avg(dt.host.disk.write.bytes),
  disk_io_read = avg(dt.host.disk.read.bytes),
by: {dt.entity.host},
filter: dt.entity.host in (
  // Insert host IDs from Step 1 results
  ),
from: toTimestamp("2026-04-06T10:00:00Z"),
to: toTimestamp("2026-04-06T13:00:00Z")
```

### Dynatrace Query - Node Events During Incident

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| filter event.type in (
    "NodeNotReady",
    "NodePressure",
    "DiskPressure",
    "MemoryPressure",
    "PIDPressure",
    "EvictionThresholdMet",
    "SystemOOM",
    "FreeDiskSpaceFailed"
  )
| filter k8s.node.name in (
    // Insert node names from Step 1
  )
| fields timestamp, k8s.node.name, event.type, event.reason, event.description
| sort timestamp asc
```

**What to look for:**
- Memory pressure events
- Disk pressure events
- High CPU/disk I/O during mount errors
- PID exhaustion
- OOM events

---

## Step 3: Filesystem-Specific Issues

### Dynatrace Query - Disk Space and Inode Usage

```dql
timeseries
  disk_used_percent = avg(dt.host.disk.used) / avg(dt.host.disk.total) * 100,
  disk_avail_bytes = avg(dt.host.disk.available),
  inode_used = avg(dt.host.disk.inodes.used),
by: {dt.entity.host, mount_point},
filter: dt.entity.host in (
  // Insert host IDs from Step 1
),
from: toTimestamp("2026-04-06T10:00:00Z"),
to: toTimestamp("2026-04-06T13:00:00Z")
```

### Dynatrace Query - Mount-Related Errors in System Logs

```dql
fetch logs
| filter dt.entity.host in (
    // Insert host IDs from Step 1
  )
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| filter matchesPhrase(content, "mount") or
         matchesPhrase(content, "filesystem") or
         matchesPhrase(content, "I/O error") or
         matchesPhrase(content, "read-only") or
         matchesPhrase(content, "remount")
| filter loglevel == "ERROR" or loglevel == "WARN"
| fields timestamp, dt.entity.host, content
| sort timestamp asc
| limit 200
```

**What to look for:**
- Filesystem going read-only
- Disk full conditions
- Inode exhaustion
- Mount/remount operations
- I/O errors from kernel

---

## Step 4: Storage Backend Issues

### Dynatrace Query - Storage Layer Metrics

```dql
fetch logs
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| filter matchesPhrase(content, "EBS") or
         matchesPhrase(content, "volume") or
         matchesPhrase(content, "device") or
         matchesPhrase(content, "scsi") or
         matchesPhrase(content, "nvme")
| filter loglevel == "ERROR" or loglevel == "WARN"
| fields timestamp, dt.entity.host, content
| sort timestamp asc
```

**For AWS/cloud environments:**
```dql
fetch logs
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| filter matchesPhrase(content, "throttl") or
         matchesPhrase(content, "IOPS") or
         matchesPhrase(content, "burst")
| fields timestamp, dt.entity.host, content
| sort timestamp asc
```

**What to look for:**
- EBS/storage volume throttling
- IOPS limits hit
- Device errors
- SCSI/NVMe errors
- Volume detach/reattach events

---

## Step 5: Pod Volume Mounts

### Dynatrace Query - Volume Mount Events

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter k8s.namespace.name == "dynatrace"
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| filter event.type in (
    "FailedMount",
    "FailedAttachVolume",
    "FailedMapVolume",
    "VolumeResizeFailed",
    "VolumeMountFailed"
  )
| fields timestamp, k8s.pod.name, k8s.node.name, event.type, event.description
| sort timestamp asc
```

### Dynatrace Query - Container Mount Logs

```dql
fetch logs
| filter k8s.namespace.name == "dynatrace"
| filter matchesValue(k8s.pod.name, "*oneagent*")
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| filter matchesPhrase(content, "Permission denied") or
         matchesPhrase(content, "Operation not permitted") or
         matchesPhrase(content, "Read-only file system") or
         matchesPhrase(content, "No space left")
| fields timestamp, k8s.pod.name, k8s.container.name, content
| sort timestamp asc
```

**What to look for:**
- Permission errors on volume mounts
- Read-only filesystem errors
- Space issues on mounted volumes
- PersistentVolume/PersistentVolumeClaim issues

---

## Step 6: Cluster-Wide Activity During Window

### Dynatrace Query - Pod Churn Rate

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| filter event.type in ("Created", "Started", "Killing", "Stopped")
| summarize pod_events = count(), by:{bin(timestamp, 5m), event.type}
| sort timestamp asc
```

### Dynatrace Query - Check for Other DaemonSet Rollouts

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter timestamp >= toTimestamp("2026-04-06T09:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| filter event.type == "Updated"
| filter matchesPhrase(event.description, "DaemonSet")
| fields timestamp, k8s.namespace.name, event.description
| sort timestamp asc
```

**What to look for:**
- High pod creation rate (putting pressure on nodes)
- Multiple DaemonSet updates happening simultaneously
- Cluster scaling events
- Node additions/removals

---

## oc Commands (If Cluster Access Available)

### 1. Get Node Names for Failing Pods

```bash
# Get pod to node mapping
oc get pods -n dynatrace -o wide | grep oneagent | grep -E "(5x8b4|27bds|vzcq6|2dncr|jkc5h)"
```

### 2. Check Node Conditions

```bash
# Get list of affected nodes from above, then:
for node in <node1> <node2> <node3>; do
  echo "=== Node: $node ==="
  oc describe node "$node" | grep -A10 "Conditions:"
  oc describe node "$node" | grep -A5 "Allocated resources:"
  echo ""
done
```

### 3. Check Node Filesystem Info

```bash
# Debug pod on affected node
NODE_NAME="<node-from-step-1>"

oc debug node/$NODE_NAME -- chroot /host df -h
oc debug node/$NODE_NAME -- chroot /host df -i  # Inode usage
```

### 4. Check Node Logs for Mount Errors

```bash
# Get kernel/system logs from the time window
oc debug node/$NODE_NAME -- chroot /host journalctl \
  --since "2026-04-06 10:00:00" \
  --until "2026-04-06 13:00:00" \
  | grep -i -E "(mount|error|filesystem|I/O|read-only)"
```

### 5. Check for Disk Pressure

```bash
# Look for eviction events
oc get events --all-namespaces --sort-by='.lastTimestamp' \
  --field-selector type=Warning \
  | grep -E "(Evict|DiskPressure|MemoryPressure)"
```

### 6. Check Container Runtime Logs

```bash
# Check CRI-O/containerd logs
oc debug node/$NODE_NAME -- chroot /host journalctl \
  -u crio \
  --since "2026-04-06 10:00:00" \
  --until "2026-04-06 13:00:00" \
  | grep -i error
```

### 7. Examine OneAgent DaemonSet Volume Configuration

```bash
# Check what volumes the OneAgent DaemonSet uses
oc get daemonset -n dynatrace hs-mc-39koj380g-8p85p-oneagent -o yaml | grep -A20 "volumes:"

# Check volume mounts in containers
oc get daemonset -n dynatrace hs-mc-39koj380g-8p85p-oneagent -o yaml | grep -A10 "volumeMounts:"
```

### 8. Check for Storage Class Issues

```bash
# If using PersistentVolumes
oc get pv | grep dynatrace
oc get pvc -n dynatrace

# Check for storage class problems
oc get sc
oc describe sc <storage-class-name>
```

---

## Investigation Workflow

1. **Start with Step 1** → Identify which nodes had mount errors
2. **Run Step 2** → Check if those nodes had resource pressure
3. **Run Step 3** → Look for filesystem-specific issues
4. **Run Step 6** → Check if cluster-wide activity correlates
5. **If pattern emerges:**
   - Same node → Node hardware/config issue
   - Same zone → Zone-level infrastructure problem
   - All nodes → Cluster-wide event (upgrade, scaling, etc.)
6. **Run Steps 4-5** if filesystem/volume issues suspected
7. **Use oc commands** for deeper node-level investigation

---

## Common Patterns and Causes

### Pattern 1: Same Node, Multiple Pods
**Likely Cause:** Node-specific issue
- Failing disk
- Filesystem corruption
- Node running out of inodes
- Kernel bug on that node

**Next Steps:**
- Cordon and drain the node
- Check node hardware health
- Review node system logs

### Pattern 2: Multiple Nodes, Same Time
**Likely Cause:** Cluster-wide event
- Storage backend degradation
- Network storage latency spike
- Cluster scaling operation
- DaemonSet rollout timing

**Next Steps:**
- Check cloud provider status page
- Review cluster scaling events
- Check storage backend metrics

### Pattern 3: High I/O Nodes Only
**Likely Cause:** Resource contention
- Too many pods starting simultaneously
- DaemonSet rolling update too aggressive
- Node disk I/O saturation

**Next Steps:**
- Adjust DaemonSet maxUnavailable
- Stagger deployments
- Increase node disk IOPS

### Pattern 4: Specific Mount Point
**Likely Cause:** Volume configuration
- PersistentVolume issues
- HostPath mount permissions
- Volume plugin bug

**Next Steps:**
- Review volume definitions
- Check volume plugin logs
- Test with different volume type

---

## Expected Findings

Based on the evidence so far, most likely scenarios:

### Scenario A: Transient I/O Pressure (70% probability)
- Multiple OneAgent pods initializing simultaneously
- Node disk I/O queues saturated
- Mount points temporarily slow to respond
- Self-resolves after initialization wave passes

**Evidence to look for:**
- High disk I/O metrics during incident window
- Multiple pod starts on same nodes
- No specific node events/errors

### Scenario B: Storage Backend Issue (20% probability)
- Cloud storage (EBS/persistent disk) throttling
- IOPS limits exceeded
- Storage backend latency spike

**Evidence to look for:**
- Storage backend metrics show degradation
- Cloud provider incident during timeframe
- Multiple mount errors across many nodes

### Scenario C: Node-Level Problem (10% probability)
- Specific node(s) with hardware/kernel issues
- Filesystem corruption or disk errors
- Node resource exhaustion

**Evidence to look for:**
- All errors from same node(s)
- Node condition changes
- Kernel errors in node logs

---

**Created:** 2026-04-06
**Purpose:** Deep investigation of mount write errors during OneAgent initialization
