# Dynatrace Investigation Queries for OneAgent Readiness Failures

Alert: `DynatraceDynakubeComponentsDegradedSRE`
Time: 2026-04-06 10:59-12:19 UTC (2:59am-4:19am PST)
Issue: OneAgent pods failing readiness probes - missing watchdog.conf

## Query 1: OneAgent Container Startup Logs (MOST IMPORTANT)

Shows what happened during pod initialization for the affected pods.

```dql
fetch logs
| filter k8s.namespace.name == "dynatrace"
| filter k8s.pod.name in (
    "hs-mc-39koj380g-8p85p-oneagent-27bds",
    "hs-mc-39koj380g-8p85p-oneagent-5x8b4",
    "hs-mc-co775rj1g-ctglt-oneagent-vzcq6",
    "hs-mc-g1lr73hi0-xppdv-oneagent-2dncr",
    "hs-mc-up2eebpog-skmrm-oneagent-jkc5h"
  )
| filter timestamp >= toTimestamp("2026-04-06T10:50:00Z") and timestamp <= toTimestamp("2026-04-06T12:30:00Z")
| filter loglevel in ("ERROR", "WARN", "INFO")
| fields timestamp, k8s.pod.name, k8s.container.name, loglevel, content
| sort timestamp asc
| limit 500
```

**What to look for:**
- Installation/initialization errors
- Timing issues (watchdog.conf created late)
- Missing dependencies
- Container startup sequence problems

---

## Query 2: Search for Installation/Initialization Errors

Broader search across all affected OneAgent pods for watchdog, install, init, mount keywords.

```dql
fetch logs
| filter k8s.namespace.name == "dynatrace"
| filter matchesValue(k8s.pod.name, "*hs-mc*oneagent*")
| filter timestamp >= toTimestamp("2026-04-06T10:50:00Z") and timestamp <= toTimestamp("2026-04-06T12:30:00Z")
| filter matchesPhrase(content, "watchdog") or matchesPhrase(content, "install") or matchesPhrase(content, "init") or matchesPhrase(content, "mount")
| fields timestamp, k8s.pod.name, loglevel, content
| sort timestamp asc
| limit 200
```

**What to look for:**
- watchdog.conf creation/missing messages
- Installation failures
- Initialization steps failing
- Mount point issues

---

## Query 3: Volume/Mount Issues

Checks for volume mounting problems that could prevent watchdog.conf from being accessible.

```dql
fetch logs
| filter k8s.namespace.name == "dynatrace"
| filter matchesValue(k8s.pod.name, "*hs-mc*oneagent*")
| filter timestamp >= toTimestamp("2026-04-06T10:50:00Z") and timestamp <= toTimestamp("2026-04-06T12:30:00Z")
| filter matchesPhrase(content, "volume") or matchesPhrase(content, "mount") or matchesPhrase(content, "permission") or matchesPhrase(content, "read-only")
| fields timestamp, k8s.pod.name, loglevel, content
| sort timestamp asc
| limit 200
```

**What to look for:**
- Failed volume mounts
- Permission denied errors
- Read-only filesystem issues
- PersistentVolume problems

---

## Query 4: Pod Creation/Deletion Events

Shows Kubernetes events for pod lifecycle during the incident.

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter k8s.namespace.name == "dynatrace"
| filter matchesValue(k8s.daemonset.name, "hs-mc*oneagent")
| filter timestamp >= toTimestamp("2026-04-06T10:50:00Z") and timestamp <= toTimestamp("2026-04-06T12:30:00Z")
| filter event.type in ("Created", "Started", "Killing", "Pulled", "Failed", "BackOff", "FailedMount", "FailedAttachVolume")
| fields timestamp, event.type, event.reason, k8s.pod.name, k8s.node.name, event.description
| sort timestamp asc
```

**What to look for:**
- Pods being killed/restarted
- Image pull issues
- Container creation failures
- Mount failures

---

## Query 5: DaemonSet Rollout/Update Activity

Checks if there was a DaemonSet update that triggered the issues.

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter k8s.namespace.name == "dynatrace"
| filter event.type in ("Updated", "ScalingReplicaSet", "SuccessfulCreate", "SuccessfulDelete")
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| fields timestamp, event.type, event.reason, k8s.daemonset.name, event.description
| sort timestamp asc
```

**What to look for:**
- DaemonSet updates around 10:00-11:00 UTC
- Rolling updates in progress
- Image version changes

---

## Query 6: Node-Level Issues

Check if the nodes hosting the failing pods had issues.

```dql
fetch events
| filter event.kind == "KUBERNETES_EVENT"
| filter k8s.namespace.name == "dynatrace"
| filter timestamp >= toTimestamp("2026-04-06T10:00:00Z") and timestamp <= toTimestamp("2026-04-06T13:00:00Z")
| filter event.type in ("NodeNotReady", "NodePressure", "EvictionThresholdMet", "SystemOOM")
| fields timestamp, event.type, k8s.node.name, event.description
| sort timestamp asc
```

**What to look for:**
- Node pressure (memory, disk, PID)
- Node not ready states
- OOM events
- Evictions

---

## Query 7: Specific Error Patterns

Searches for common error patterns that could explain the failures.

```dql
fetch logs
| filter k8s.namespace.name == "dynatrace"
| filter matchesValue(k8s.pod.name, "*hs-mc*oneagent*")
| filter timestamp >= toTimestamp("2026-04-06T10:50:00Z") and timestamp <= toTimestamp("2026-04-06T12:30:00Z")
| filter matchesPhrase(content, "Cannot find") or
         matchesPhrase(content, "No such file") or
         matchesPhrase(content, "failed to") or
         matchesPhrase(content, "error")
| fields timestamp, k8s.pod.name, k8s.container.name, content
| sort timestamp asc
| limit 300
```

**What to look for:**
- "Cannot find" messages for watchdog.conf
- File not found errors
- General failure messages
- Error stack traces

---

## Affected Pods (for reference)

### DaemonSets that caused the alert (had failures during 10:59-11:59 UTC):

1. **hs-mc-39koj380g-8p85p-oneagent** - 4 failing pods, 86 readiness failures
   - hs-mc-39koj380g-8p85p-oneagent-27bds
   - hs-mc-39koj380g-8p85p-oneagent-5x8b4
   - hs-mc-39koj380g-8p85p-oneagent-6qrbw
   - hs-mc-39koj380g-8p85p-oneagent-q25wt

2. **hs-mc-co775rj1g-ctglt-oneagent** - 2 failing pods, 41 failures
   - hs-mc-co775rj1g-ctglt-oneagent-vzcq6
   - hs-mc-co775rj1g-ctglt-oneagent-xrnf5

3. **hs-mc-e3pjgj3h0-p5lbb-oneagent** - 1 failing pod, 21 failures
   - hs-mc-e3pjgj3h0-p5lbb-oneagent-mh4mm

4. **hs-mc-g1lr73hi0-xppdv-oneagent** - 4 failing pods, 38 failures
   - hs-mc-g1lr73hi0-xppdv-oneagent-2dncr
   - hs-mc-g1lr73hi0-xppdv-oneagent-5rrdh
   - hs-mc-g1lr73hi0-xppdv-oneagent-mscb2
   - hs-mc-g1lr73hi0-xppdv-oneagent-s7c5g

5. **hs-mc-l537etb8g-bzfmk-oneagent** - 1 failing pod, 21 failures
   - hs-mc-l537etb8g-bzfmk-oneagent-vcfwz

6. **hs-mc-up2eebpog-skmrm-oneagent** - 3 failing pods, 60 failures
   - hs-mc-up2eebpog-skmrm-oneagent-5w824
   - hs-mc-up2eebpog-skmrm-oneagent-g27gt
   - hs-mc-up2eebpog-skmrm-oneagent-jkc5h

---

## Investigation Workflow

1. **Start with Query 1** - Look at startup logs for specific failing pods
2. **Run Query 2** - Search for watchdog/install/init messages across all pods
3. **Run Query 4** - Check pod lifecycle events to see creation/restart patterns
4. **Run Query 5** - Look for DaemonSet updates that might have triggered this
5. **Run Query 3** - If mount issues are suspected from above queries
6. **Run Query 7** - General error search if root cause isn't clear yet
7. **Run Query 6** - Check node health if multiple pods on same node failed

---

## Expected Root Causes

Based on the error pattern, likely causes:

1. **Timing issue**: watchdog.conf created after readiness probe runs
2. **Installation failure**: OneAgent installer didn't complete successfully
3. **Volume mount issue**: Config directory not properly mounted
4. **Image issue**: New OneAgent image with initialization bug
5. **Resource constraint**: Not enough resources to complete installation
6. **Node issue**: Nodes under pressure causing installation delays

---

**Created:** 2026-04-06
**Incident:** DynatraceDynakubeComponentsDegradedSRE alert firing
**Duration:** 80 minutes (10:59 UTC - 12:19 UTC)
