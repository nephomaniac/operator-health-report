# CAMO Prometheus Metrics Collection

This directory contains scripts to collect and analyze CAMO (Configure AlertManager Operator) Prometheus metrics across multiple OpenShift clusters.

## Overview

CAMO exposes Prometheus metrics on port 8080 at the `/metrics` endpoint. These metrics provide insights into:

- Secret existence and configuration (GoAlert, PagerDuty, DeadMan's Snitch)
- AlertManager configuration state
- ConfigMap presence
- Configuration validation status

## Metrics Collected

All metrics are gauge metrics with values of 0 (false) or 1 (true):

| Metric | Description |
|--------|-------------|
| `ga_secret_exists` | GoAlert secret exists in cluster |
| `pd_secret_exists` | PagerDuty secret exists in cluster |
| `dms_secret_exists` | DeadMan's Snitch secret exists in cluster |
| `am_secret_exists` | AlertManager config secret exists |
| `am_secret_contains_ga` | AlertManager config contains GoAlert configuration |
| `am_secret_contains_pd` | AlertManager config contains PagerDuty configuration |
| `am_secret_contains_dms` | AlertManager config contains DeadMan's Snitch configuration |
| `managed_namespaces_configmap_exists` | managed-namespaces ConfigMap exists |
| `ocp_namespaces_configmap_exists` | ocp-namespaces ConfigMap exists |
| `alertmanager_config_validation_failed` | AlertManager config validation failed (1=failed, 0=passed) |

## Scripts

### collect_camo_metrics.sh

Collects CAMO Prometheus metrics from a single cluster.

**Usage:**
```bash
./collect_camo_metrics.sh --reason "SREP-12345 metrics collection"
```

**Options:**
- `--reason, -r REASON` - JIRA ticket for OCM elevation (required)
- `--namespace, -n NAMESPACE` - Namespace (default: openshift-monitoring)
- `--deployment, -d DEPLOY` - Deployment name (default: configure-alertmanager-operator)
- `--format, -f FORMAT` - Output format: csv or json (default: csv)
- `--cluster-id, -c ID` - Cluster ID (auto-detected if not provided)
- `--cluster-name NAME` - Cluster name (auto-detected if not provided)
- `--cluster-version VERSION` - Cluster version (auto-detected if not provided)

**Output (CSV):**
```
cluster_id,cluster_name,cluster_version,operator_version,namespace,health_status,health_issues,ga_secret_exists,pd_secret_exists,dms_secret_exists,am_secret_exists,am_secret_contains_ga,am_secret_contains_pd,am_secret_contains_dms,managed_namespaces_configmap_exists,ocp_namespaces_configmap_exists,alertmanager_config_validation_failed,timestamp
```

### collect_from_multiple_clusters.sh (with --metrics flag)

Collects CAMO metrics from multiple clusters in parallel.

**Usage:**
```bash
# Collect metrics from all accessible clusters
./collect_from_multiple_clusters.sh --reason "SREP-12345" --metrics --oper camo

# Collect from clusters in a specific list
./collect_from_multiple_clusters.sh --reason "SREP-12345" --metrics --oper camo --cluster-list camo_promo.list

# Limit to first 10 clusters
./collect_from_multiple_clusters.sh --reason "SREP-12345" --metrics --oper camo --max-clusters 10
```

**Output:**
- CSV file: `camo_metrics_YYYYMMDD_HHMMSS.csv`

### analyze_camo_metrics.sh

Analyzes collected metrics and generates version comparison reports.

**Usage:**
```bash
./analyze_camo_metrics.sh camo_metrics_20260203_120000.csv
```

**Features:**
- Identifies current and previous operator versions
- Compares health status across versions
- Highlights clusters with issues (CRITICAL or WARNING)
- Generates percentage-based metrics summaries
- Creates version-specific CSV reports

**Output:**
- Console report with statistics and comparisons
- `camo_metrics_TIMESTAMP_VERSION.csv` - Per-version filtered data

## Health Assessment

The scripts automatically assess cluster health based on metrics:

**CRITICAL Status:**
- AlertManager secret missing (`am_secret_exists` = 0)
- AlertManager config validation failed (`alertmanager_config_validation_failed` = 1)

**WARNING Status:**
- managed-namespaces ConfigMap missing
- ocp-namespaces ConfigMap missing

**HEALTHY Status:**
- All critical checks passing

## Workflow Example

### 1. Collect metrics from promotion clusters

```bash
./collect_from_multiple_clusters.sh \
    --reason "SREP-12345 Weekly CAMO promotion checks" \
    --metrics \
    --oper camo \
    --cluster-list camo_promo.list
```

This creates: `camo_metrics_20260203_120000.csv`

### 2. Analyze metrics and compare versions

```bash
./analyze_camo_metrics.sh camo_metrics_20260203_120000.csv
```

**Sample Output:**
```
================================================================================
CAMO METRICS ANALYSIS
================================================================================
Input file: camo_metrics_20260203_120000.csv

Analyzing operator versions...
Operator versions found:
  0.1.791-g4babac1     (12 clusters)
  0.1.781-geab01dd     (5 clusters)

Current version:  0.1.791-g4babac1 (12 clusters)
Previous version: 0.1.781-geab01dd (5 clusters)

================================================================================
CURRENT VERSION: 0.1.791-g4babac1
================================================================================
Clusters: 12

Health Status:
  HEALTHY:  12
  WARNING:  0
  CRITICAL: 0

Metric Summary (clusters with metric = 1):
  GoAlert secret exists                         12 / 12 (100.0%)
  PagerDuty secret exists                       12 / 12 (100.0%)
  DeadMansSnitch secret exists                  10 / 12 (83.3%)
  AlertManager secret exists                    12 / 12 (100.0%)
  AlertManager contains GoAlert config          12 / 12 (100.0%)
  AlertManager contains PagerDuty config        12 / 12 (100.0%)
  AlertManager contains DMS config              10 / 12 (83.3%)
  managed-namespaces ConfigMap exists           12 / 12 (100.0%)
  ocp-namespaces ConfigMap exists               12 / 12 (100.0%)
  AlertManager config validation FAILED          0 / 12 (0.0%)

================================================================================
PREVIOUS VERSION: 0.1.781-geab01dd
================================================================================
...similar output...

================================================================================
VERSION COMPARISON
================================================================================
Comparing: 0.1.781-geab01dd --> 0.1.791-g4babac1

Health Status (% HEALTHY clusters):
  Previous version: 100.0%
  Current version:  100.0%

AlertManager Config Validation Failures:
  Previous version: 0.0% (0/5 clusters)
  Current version:  0.0% (0/12 clusters)
```

### 3. Review version-specific reports

The analysis generates separate CSV files for each version:
- `camo_metrics_20260203_120000_0.1.791-g4babac1.csv` - Current version data
- `camo_metrics_20260203_120000_0.1.781-geab01dd.csv` - Previous version data

These can be used for detailed per-version analysis or historical tracking.

## Version Awareness

The system tracks which metrics are available in each CAMO version using `camo_metrics_versions.conf`. This ensures:

- Version-specific metric collection
- Accurate comparison between versions
- Future extensibility for new metrics

## Integration with Existing Scripts

The metrics collection integrates seamlessly with existing health check and resource usage scripts:

```bash
# Health check (pod status, restarts, errors)
./collect_from_multiple_clusters.sh --reason "SREP-12345" --health --oper camo

# Metrics collection (Prometheus metrics)
./collect_from_multiple_clusters.sh --reason "SREP-12345" --metrics --oper camo

# Resource usage (CPU, memory)
./collect_from_multiple_clusters.sh --reason "SREP-12345" --oper camo
```

## Troubleshooting

### No metrics collected

**Symptom:** Script reports "Error: Failed to scrape metrics from pod"

**Possible causes:**
1. CAMO pod not running
2. Metrics endpoint not accessible on port 8080
3. Pod name detection failed

**Solution:**
```bash
# Verify pod is running
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=configure-alertmanager-operator

# Check metrics endpoint manually
oc exec -n openshift-monitoring <pod-name> -- curl -s http://localhost:8080/metrics
```

### "unknown" operator version

**Symptom:** Operator version shows as "unknown" in output

**Possible causes:**
1. CSV (ClusterServiceVersion) not found
2. OCM backplane elevation failed
3. Operator not installed via OLM

**Solution:**
```bash
# Check CSV exists
ocm backplane elevate "SREP-12345" -- get csv -n openshift-monitoring

# Verify operator installation
oc get deployment -n openshift-monitoring configure-alertmanager-operator
```

## Files

- `collect_camo_metrics.sh` - Single-cluster metrics collection
- `collect_from_multiple_clusters.sh` - Multi-cluster orchestration (with --metrics flag)
- `analyze_camo_metrics.sh` - Metrics analysis and version comparison
- `camo_metrics_versions.conf` - Metrics version mapping configuration
- `README_METRICS.md` - This file

## Read-Only Operations

All metrics collection scripts are **read-only** and make **no modifications** to clusters:
- Uses `oc get` and `oc exec curl` for read-only operations
- No `oc apply`, `oc create`, `oc delete`, or other write operations
- Safe to run in production environments
