# Debug Logging Guide

## Overview

The collection scripts now include comprehensive debug logging to help diagnose and fix Prometheus query issues.

## What Was Fixed

### 1. Prometheus Metric Detection

The script now **automatically detects** which container name to use for queries by:

1. Testing Prometheus connectivity
2. Querying all available containers in `openshift-monitoring` namespace
3. Finding the correct container name (`configure-alertmanager-operator` or `manager`)
4. Warning if container metrics are not found

### 2. Debug Logging

Every script run now creates a debug log file with:

- Timestamp for all operations
- Prometheus query strings
- Raw Prometheus responses
- Number of data points found
- Calculated metrics (max, avg)
- Error messages and warnings

### 3. Diagnostic Output

The debug log includes:
- **Test Query Results**: What containers are available in Prometheus
- **Query Construction**: Exact PromQL queries being executed
- **Response Analysis**: Raw JSON responses from Prometheus
- **Data Point Counts**: How many metric samples were found
- **Final Values**: Calculated max/avg CPU and memory

## How to Use Debug Logs

### Automatic Debug Mode

Debug mode is now **enabled by default** when running version comparison:

```bash
./collect_from_multiple_clusters.sh \
    --reason "Weekly CAMO promotion checks" \
    --version-compare \
    --oper camo \
    --cluster-list test.list
```

This automatically creates debug files named:
```
debug_<cluster_id>_<timestamp>.log
```

### Example Debug Log Locations

After running collection, you'll find files like:
```
debug_abc123def456ghi789jkl012mno345pq_20260217_132600.log
debug_xyz789uvw456rst123opq890lmn567ab_20260217_132625.log
...
```

### Reading Debug Logs

Each debug log contains sections like:

```
[2026-02-17T21:26:03Z] === SCRIPT START ===
[2026-02-17T21:26:03Z] Cluster: abc123def456ghi789jkl012mno345pq (hs-mc-s73d61p7g)
[2026-02-17T21:26:03Z] Namespace: openshift-monitoring
[2026-02-17T21:26:03Z] Deployment: configure-alertmanager-operator
[2026-02-17T21:26:05Z] Cluster version: 4.19.17
[2026-02-17T21:26:05Z] Prometheus pod: prometheus-k8s-0
[2026-02-17T21:26:06Z] === TESTING PROMETHEUS METRICS ===
[2026-02-17T21:26:06Z] Testing Prometheus connectivity...
[2026-02-17T21:26:06Z] Prometheus health: Prometheus Server is Healthy.
[2026-02-17T21:26:06Z] Searching for CAMO metrics in Prometheus...
[2026-02-17T21:26:06Z] Test query: container_cpu_usage_seconds_total{namespace="openshift-monitoring"}
[2026-02-17T21:26:07Z] Test query response: {"status":"success","data":{"resultType":"vector","result":[...]}}
[2026-02-17T21:26:07Z] Available containers: prometheus,configure-alertmanager-operator,kube-state-metrics,...
[2026-02-17T21:26:07Z] Found container: configure-alertmanager-operator
[2026-02-17T21:26:07Z] Using container name: configure-alertmanager-operator
[2026-02-17T21:26:08Z] === QUERY PERIOD: current ===
[2026-02-17T21:26:08Z] Start: 2026-02-16T21:26:03Z
[2026-02-17T21:26:08Z] End: 2026-02-17T21:26:03Z
[2026-02-17T21:26:08Z] Container: configure-alertmanager-operator
[2026-02-17T21:26:08Z] CPU query: rate(container_cpu_usage_seconds_total{namespace="openshift-monitoring",container="configure-alertmanager-operator"}[5m])
[2026-02-17T21:26:10Z] CPU response: {"status":"success","data":{"resultType":"matrix","result":[]}}
[2026-02-17T21:26:10Z] CPU data points: 0
[2026-02-17T21:26:10Z] CPU - Max: 0, Avg: 0
[2026-02-17T21:26:10Z] Memory query: container_memory_working_set_bytes{namespace="openshift-monitoring",container="configure-alertmanager-operator"}
[2026-02-17T21:26:12Z] Memory response: {"status":"success","data":{"resultType":"matrix","result":[]}}
[2026-02-17T21:26:12Z] Memory data points: 0
[2026-02-17T21:26:12Z] Memory - Max: 0, Avg: 0
```

## Diagnosing Issues

### Problem: 0 CPU and 0 Memory Values

If you see:
```
[timestamp] CPU data points: 0
[timestamp] CPU - Max: 0, Avg: 0
[timestamp] Memory data points: 0
[timestamp] Memory - Max: 0, Avg: 0
```

**Check the debug log for:**

1. **Is Prometheus healthy?**
   ```
   [timestamp] Prometheus health: Prometheus Server is Healthy.
   ```
   - If not "Healthy", Prometheus is down

2. **Is the container found?**
   ```
   [timestamp] Available containers: prometheus,kube-state-metrics,...
   [timestamp] Found container: configure-alertmanager-operator
   ```
   - If "configure-alertmanager-operator" is NOT in available containers, the metrics aren't being scraped

3. **What's in the Prometheus response?**
   ```
   [timestamp] CPU response: {"status":"success","data":{"resultType":"matrix","result":[]}}
   ```
   - If `"result":[]` is empty, no metrics match the query
   - If `"status":"error"`, the query is invalid

4. **Are the time ranges correct?**
   ```
   [timestamp] Start: 2026-02-16T21:26:03Z
   [timestamp] End: 2026-02-17T21:26:03Z
   ```
   - Check if these times are within Prometheus retention period
   - Check if the pod was running during this time

### Common Issues and Solutions

#### Issue 1: Container Not Found in Prometheus

**Debug log shows:**
```
[timestamp] Available containers: prometheus,kube-state-metrics,node-exporter,...
[timestamp] Container 'configure-alertmanager-operator' not found in Prometheus metrics
```

**Cause:** CAMO metrics are not being scraped by Prometheus

**Solution:**
```bash
# Check if ServiceMonitor exists
oc get servicemonitor -n openshift-monitoring

# Check if CAMO service has correct labels
oc get service -n openshift-monitoring -l name=configure-alertmanager-operator -o yaml

# Check Prometheus scrape configuration
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
    curl -s 'http://localhost:9090/api/v1/targets' | jq '.data.activeTargets[] | select(.labels.job | contains("alertmanager"))'
```

#### Issue 2: Empty Prometheus Response

**Debug log shows:**
```
[timestamp] CPU response: {"status":"success","data":{"resultType":"matrix","result":[]}}
[timestamp] CPU data points: 0
```

**Cause:** Query finds no matching metrics

**Possible reasons:**
1. Time range is outside Prometheus retention
2. Pod wasn't running during query period
3. Metrics use different labels

**Solution:**
```bash
# Check Prometheus retention
oc get prometheus -n openshift-monitoring k8s -o jsonpath='{.spec.retention}'

# Test if ANY CAMO metrics exist (no time range)
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
    curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=container_cpu_usage_seconds_total{namespace="openshift-monitoring",container="configure-alertmanager-operator"}'

# Check pod uptime
oc get pods -n openshift-monitoring -l name=configure-alertmanager-operator -o wide
```

#### Issue 3: Old/Deleted Pods

**Debug log shows:**
```
[timestamp] Previous RS: configure-alertmanager-operator-old @ 2025-12-10T00:28:56Z
[timestamp] Start: 2025-12-09T08:28:56Z
[timestamp] End: 2025-12-10T00:28:56Z
```

**Cause:** Querying for metrics from months ago, outside retention

**Solution:**
- Prometheus typically retains 15 days of data
- If version change was > 15 days ago, historical data is gone
- Solution: Only compare versions changed within retention window

## Sharing Debug Logs for Troubleshooting

When requesting help, please provide:

1. **The debug log file**
   ```bash
   cat debug_<cluster_id>_<timestamp>.log
   ```

2. **The CSV output**
   ```bash
   cat version_compare_<timestamp>.csv
   ```

3. **Cluster context**
   ```bash
   oc get deployment -n openshift-monitoring configure-alertmanager-operator
   oc get pods -n openshift-monitoring -l name=configure-alertmanager-operator
   oc get prometheus -n openshift-monitoring k8s -o jsonpath='{.spec.retention}'
   ```

## Advanced Debugging

### Test Prometheus Queries Manually

From the debug log, copy the exact query and test it:

```bash
# Login to cluster
ocm backplane login <cluster-id>

# Get the query from debug log
QUERY='rate(container_cpu_usage_seconds_total{namespace="openshift-monitoring",container="configure-alertmanager-operator"}[5m])'

# Test it
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
    curl -s -G 'http://localhost:9090/api/v1/query_range' \
    --data-urlencode "query=$QUERY" \
    --data-urlencode "start=$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ')" \
    --data-urlencode "end=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --data-urlencode "step=5m" | jq
```

### Check What Metrics Are Available

```bash
# Get all metric names
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
    curl -s 'http://localhost:9090/api/v1/label/__name__/values' | \
    jq -r '.data[]' | grep -i container

# Get all labels for a specific metric
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
    curl -s 'http://localhost:9090/api/v1/series?match[]=container_cpu_usage_seconds_total' | \
    jq -r '.data[] | select(.namespace=="openshift-monitoring") | .container' | sort -u
```

## Disabling Debug Mode

If you want to disable debug logging (not recommended for troubleshooting):

Edit `collect_from_multiple_clusters.sh` and remove the `--debug` flag:

```bash
./collect_versioned_metrics.sh \
    --namespace "$op_namespace" \
    --deployment "$op_deployment" \
    --cluster-id "$cluster_id" \
    --cluster-name "$cluster_name" \
    --cluster-version "$cluster_version" \
    --reason "$REASON" \
    --operator-name "$op_name" \
    --format csv \
    # Remove this line: --debug
    >> "$OUTPUT_FILE"
```

## Summary

Debug logging now provides:
- ✅ Prometheus connectivity tests
- ✅ Container name auto-detection
- ✅ Raw query responses
- ✅ Data point counts
- ✅ Detailed error messages
- ✅ Timestamp tracking for all operations

All logs are saved to `debug_<cluster_id>_<timestamp>.log` for review and troubleshooting.

Use these logs to diagnose why Prometheus queries are returning 0 values and fix the underlying metric collection issues.
