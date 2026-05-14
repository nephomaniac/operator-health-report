# Operator Health Report - Claude Directives

## Overview

This repo contains scripts for comprehensive health monitoring of SRE-managed OpenShift operators across multiple clusters. The primary collection script (`collect_operator_health.sh`) gathers pod status, resource usage, version info, log analysis, and operator-specific metrics.

## Architecture

This tool is designed to run health checks across multiple operators. Each operator has:
- **General checks** that apply to all operators (pod status, restarts, resource limits, PKO package health, deployment replicas, etc.)
- **Operator-specific checks** unique to that operator (e.g., CAMO's alertmanager config validation, OME's ClusterRole caching)

When adding new checks, prefer general checks that work for any operator by parameterizing the namespace, deployment name, and operator name. Mark operator-specific checks clearly so they only run for the relevant operator.

## Currently Supported Operators

- **CAMO** (configure-alertmanager-operator) — namespace: `openshift-monitoring`, deployment: `configure-alertmanager-operator`
- **RMO** (route-monitor-operator) — namespace: `openshift-route-monitor-operator`, deployment: `route-monitor-operator`

## Operators To Add

- **OME** (osd-metrics-exporter) — namespace: `openshift-osd-metrics`, deployment: `osd-metrics-exporter`

## Enhancements Needed

### 1. Add Peak CPU and Peak Memory Metrics

The resource metrics collection (around line 970 of `collect_operator_health.sh`) currently queries `query_range` and reports first/last/trend values. It does NOT capture peak (max) values over the available Prometheus history.

**Add these metrics for all operators:**

- `memory_peak_bytes`: Peak memory working set over the available lookback window
- `memory_peak_mb`: Same in MB for display
- `cpu_peak_cores`: Peak CPU usage (max of rate) over the available lookback window
- `cpu_peak_millicores`: Same in millicores for display

**PromQL queries to add:**

```promql
# Peak memory
max_over_time(container_memory_working_set_bytes{namespace="NAMESPACE",container="CONTAINER"}[LOOKBACK])

# Peak CPU
max_over_time(rate(container_cpu_usage_seconds_total{namespace="NAMESPACE",container="CONTAINER"}[5m])[LOOKBACK:5m])
```

These should use `query` (instant) not `query_range`, since we only need the single max value.

**Include peak values in:**
- The JSON output alongside existing `first_memory`, `last_memory` fields
- The HTML report tables
- The console output during collection

### 2. Add OME Operator Support

Add osd-metrics-exporter to the operator selection logic. Key differences from CAMO/RMO:

- **Namespace:** `openshift-osd-metrics`
- **Deployment:** `osd-metrics-exporter`
- **Container:** `osd-metrics-exporter`

**OME-specific health checks to add:**

- Verify the deprecated `ClusterRole` controller is not caching excessive resources (watch for memory impact from ~400-900+ ClusterRoles being cached cluster-wide)
- Check resource limits are set (OME currently has NO resource limits or requests on its Deployment)
- Verify namespace scoping is active (`DefaultNamespaces` in manager cache config)

**OME-specific metrics:**
OME exposes custom metrics — check if the following are present and have expected values:
- Cluster admin group membership metrics
- OAuth identity provider metrics
- Proxy configuration metrics

### 3. Resource Limits Validation

For all operators, add a check that verifies resource limits and requests are set on the Deployment. Report:
- Whether `resources.limits.cpu` is set
- Whether `resources.limits.memory` is set
- Whether `resources.requests.cpu` is set
- Whether `resources.requests.memory` is set
- If set, whether current usage is within a reasonable percentage of the limit (e.g., warn if >80%)

### 4. Cluster Type Context

When reporting resource usage, include the cluster type context since resource usage varies significantly:

| Cluster Type | Expected OME Memory | Expected CAMO Memory |
|---|---|---|
| Standard ROSA | ~36 Mi | ~30-60 Mi |
| Service Cluster | ~40 Mi | ~50-100 Mi |
| Management Cluster | ~85 Mi | ~50-100 Mi |

Cluster type can be detected via:
```bash
infra_name=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
# hs-mc-* = Management Cluster
# hs-sc-* = Service Cluster
# otherwise = Standard
```

### 5. Filter Shared-Namespace Logs by Operator Rollout Time

When checking logs of other pods in the operator's namespace (e.g., alertmanager logs in `openshift-monitoring` for CAMO), long-running pods can contain stale entries from months ago. Only logs from the current operator version's deployment are relevant.

**Current behavior**: The health report scans the full log buffer of shared-namespace pods, which can span months on pods that haven't restarted.

**Required behavior**: Filter log entries to only include timestamps >= the current operator pod's start time. This ensures we only report warnings/errors that occurred under the currently deployed operator version.

**Implementation approach**:
1. Get the operator pod's start time:
   ```bash
   oc get pod -n <namespace> -l name=<operator> \
     -o jsonpath='{.items[0].status.startTime}'
   ```
2. Use `--since-time` with `oc logs` to filter:
   ```bash
   oc logs -n <namespace> <shared-pod> -c <container> \
     --since-time="<operator-pod-start-time>"
   ```
3. Or if parsing log output directly, compare the timestamp field in each log line against the operator pod's start time and discard entries older than that.

This applies to any shared-namespace logs that may predate the current operator deployment. Operator-specific pod logs are naturally scoped by the pod's lifetime and don't need this filter.

**CAMO-specific**: CAMO runs in `openshift-monitoring` alongside alertmanager, prometheus, and other monitoring components. Alertmanager logs should be filtered by CAMO's pod start time when checking for CAMO-related warnings.

### 6. Check for Hung or Stale PKO Jobs

Applies to any operator deployed via PKO that includes Jobs in its package (e.g., OLM cleanup Jobs). These Jobs should complete quickly. A Job stuck in a non-terminal state can block future PKO revision rollouts or leave orphaned pods.

**Checks to add (for each operator's namespace):**

1. **Hung Jobs**: Any Job in `Running` state for more than 5 minutes
   ```bash
   oc get jobs -n <namespace> -o json | jq '[.items[] | select(.metadata.name | startswith("olm-cleanup")) | select(.status.active > 0) | {name: .metadata.name, age: .metadata.creationTimestamp}]'
   ```

2. **Failed Jobs**: Any Job in `Failed` state — cleanup may be incomplete
   ```bash
   oc get jobs -n <namespace> -o json | jq '[.items[] | select(.metadata.name | startswith("olm-cleanup")) | select(.status.failed > 0) | {name: .metadata.name, failed: .status.failed}]'
   ```

3. **Stale Jobs**: Multiple cleanup Jobs existing simultaneously — may indicate ObjectSet archival is delayed
   ```bash
   oc get jobs -n <namespace> --no-headers | grep olm-cleanup | wc -l
   ```

4. **Orphaned pods**: Running pods with no ownerReferences from deleted Jobs
   ```bash
   oc get pods -n <namespace> -o json | jq '[.items[] | select(.metadata.name | startswith("olm-cleanup")) | select(.status.phase == "Running") | select(.metadata.ownerReferences == null) | .metadata.name]'
   ```

5. **ClusterPackage stuck with immutability error**: `Progressing=True` with `spec.template: field is immutable` in the message
   ```bash
   oc get clusterpackage <name> -o json | jq '.status.conditions[] | select(.type == "Progressing") | select(.message | test("immutable"))'
   ```

**Severity mapping:**
- Hung Job (>5min): WARNING
- Failed Job: WARNING
- Multiple stale Jobs (>3): WARNING
- Orphaned pod: WARNING
- ClusterPackage stuck with immutability error: FAIL

### 7. General Operator and PKO Package Health Checks

These are fast, read-only checks applicable to most operators and PKO packages. Each should complete in under a few seconds per cluster.

**ClusterPackage status:**
- `Available=True` and `Progressing=False` = healthy
- `Available=True` and `Progressing=True` = latest revision stuck, previous still serving
- `Available=False` = operator not running
```bash
oc get clusterpackage <name> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'
```

**Operator pod restarts:**
Non-zero restart count may indicate crashloops, OOM kills, or readiness probe failures.
```bash
oc get pod -n <namespace> -l name=<operator> \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'
```

**Pod age vs deployment age:**
If the pod is much younger than the deployment, it recently restarted. Flag if pod age < 1 hour and restarts > 0.

**Leader election (if applicable):**
Some operators use leader election. Check if the lease is held and not expired:
```bash
oc get lease -n <namespace> <operator>-lock -o jsonpath='{.spec.holderIdentity}'
```

**Deployment replica mismatch:**
Available replicas should match desired replicas:
```bash
oc get deployment -n <namespace> <operator> \
  -o jsonpath='desired={.spec.replicas} available={.status.availableReplicas} updated={.status.updatedReplicas}'
```

**PKO revision count:**
High revision count relative to cluster age may indicate rapid rollouts or configuration churn:
```bash
oc get clusterpackage <name> -o jsonpath='{.status.revision}'
```

**Container termination reason:**
If the operator pod's last termination reason is `OOMKilled`, flag as WARNING — the operator may need higher memory limits:
```bash
oc get pod -n <namespace> -l name=<operator> \
  -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}'
```

## OLM-to-PKO Migration Health Checks

These checks detect common failures from OLM-to-PKO operator migrations, derived from real incidents (ITN-2026-00093) and the `olm-to-pko-migration` skill.

### Implemented Checks

| Check | Status | What it detects |
|---|---|---|
| Dual installation (OLM + PKO) | CRITICAL | Both Subscription and ClusterPackage exist — conflicting deployment methods |
| ClusterPackage immutability error | CRITICAL | `Progressing=True` with `spec.template: field is immutable` — Job name collision |
| ClusterPackage not available | CRITICAL | `Available=False` — operator not running |
| Cleanup Job failure | WARNING | OLM cleanup Job in Failed state — OLM artifacts may persist |
| Cleanup Job hung | WARNING | Job running >5 minutes — may be stuck |
| Orphaned CSVs on PKO cluster | WARNING | CSVs remain after OLM removal — incomplete cleanup |
| Orphaned operator resources | WARNING | ServiceMonitors/PrometheusRules/blackbox exist without parent RouteMonitor CRs |
| CRDs missing | CRITICAL | RouteMonitor/ClusterUrlMonitor CRDs not installed — PKO package broken |
| Namespace Terminating | CRITICAL | Operator namespace stuck deleting — may be CRD finalizer issue |

### Known Migration Patterns

**Fleetwide operators (deployed via SelectorSyncSet):**
- OLM SSS must have `delete: true` set in SAAS before PKO can fully take over
- Orphaned SSS on Hive causes OLM/PKO conflict (OLM resources reappear after cleanup)
- Namespace must be in the SSS resources, not in `deploy_pko/` (prevents deletion on rollout)
- `resourceApplyMode: Sync` on SSS means deleting the SSS removes all synced resources
- CRD finalizers can block namespace deletion during cleanup

**Hive-resident operators:**
- OLM target removal WITHOUT `delete: true` is intentional — PKO adopts resources
- Cleanup Job only removes OLM artifacts (CSV, Subscription, CatalogSource, OperatorGroup)
- Operator-created resources (ServiceMonitors, PrometheusRules) are NOT cleaned by the Job

**Standard managed clusters:**
- SyncSet may actively delete RouteMonitor CRs (`resourcesToDelete` in ClusterSync)
- Orphaned ServiceMonitors/PrometheusRules/blackbox indicate incomplete cleanup
- Check `oc get clustersync` on Hive for `resourcesToDelete` entries

### Checks To Add

- **SSS ownership verification** (requires Hive access): Verify PKO SSS owns the namespace
- **`resourceApplyMode` validation** (requires Hive access): Ensure SSS uses correct mode
- **Cross-namespace RBAC** (fleetwide): Verify CredentialsRequests and cross-namespace Roles exist in `deploy_pko/`
- **Image pull verification**: Check if operator pod has ImagePullBackOff (SAAS deployed before Konflux build completed)

## Key Scripts

- `collect_operator_health.sh` — Single-cluster health collection (JSON output)
- `collect_from_multiple_clusters.sh` — Multi-cluster orchestration
- `generate_html_report.sh` — Converts JSON results to HTML reports
- `collect_pod_resource_usage.sh` — Resource usage collection (CPU/memory snapshots)

## Testing

When making changes, test against at least one cluster of each type:
- Standard ROSA classic cluster
- Service Cluster (integration or stage)
- Management Cluster (integration or stage)

Use `--reason "testing health report changes"` for backplane elevation.
