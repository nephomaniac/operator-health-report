# CAMO Operator Version Comparison

This directory contains scripts to collect and analyze CAMO operator resource usage across version upgrades, enabling performance regression detection and resource efficiency tracking.

## Overview

When the CAMO operator is upgraded, these scripts:

1. **Detect the upgrade** by analyzing ReplicaSet creation times
2. **Collect historical metrics** from Prometheus for the previous version
3. **Collect current metrics** from Prometheus for the new version
4. **Compare resource usage** (CPU and memory) between versions
5. **Identify regressions** or improvements in resource efficiency

## How It Works

### Version Detection

The system detects operator version changes by:

- Examining ReplicaSet creation timestamps
- Comparing container image tags
- Identifying the upgrade timestamp

### Metric Collection

For each version period, the system queries Prometheus for:

- **CPU usage**: Rate of CPU consumption (cores)
- **Memory usage**: Working set memory (bytes)
- **Time ranges**: 24-hour periods before and after upgrade
- **Statistics**: Maximum and average values for each metric

### Comparison Analysis

The analysis script:

- Calculates percentage changes in resource usage
- Identifies clusters with significant increases/decreases
- Provides overall assessment (regression, improvement, stable)
- Generates recommendations based on thresholds

## Scripts

### collect_versioned_metrics.sh

Collects resource metrics for both previous and current operator versions from a single cluster.

**Usage:**
```bash
./collect_versioned_metrics.sh --reason "SREP-12345 version comparison"
```

**Options:**
- `--reason, -r REASON` - JIRA ticket for OCM elevation (required)
- `--namespace, -n NAMESPACE` - Namespace (default: openshift-monitoring)
- `--deployment, -d DEPLOY` - Deployment name (default: configure-alertmanager-operator)
- `--format, -f FORMAT` - Output format: csv or json (default: csv)
- `--cluster-id, -c ID` - Cluster ID (auto-detected if not provided)
- `--cluster-name NAME` - Cluster name (auto-detected if not provided)
- `--cluster-version VERSION` - Cluster version (auto-detected if not provided)
- `--operator-name NAME` - Operator name (defaults to deployment name)
- `--lookback-days DAYS` - Days to look back for version changes (default: 14)

**Output (CSV):**
```
operator,cluster_id,cluster_name,cluster_version,operator_version,version_period,namespace,deployment,replicas,requests_cpu,requests_memory,limits_cpu,limits_memory,max_cpu_cores,avg_cpu_cores,max_memory_bytes,avg_memory_bytes,period_start,period_end,timestamp
```

**Note:** Outputs TWO rows per cluster:
1. One row for `previous` version (if upgrade detected within lookback period)
2. One row for `current` version

### collect_from_multiple_clusters.sh (with --version-compare flag)

Collects version comparison metrics from multiple clusters in parallel.

**Usage:**
```bash
# Collect from all accessible clusters
./collect_from_multiple_clusters.sh --reason "SREP-12345" --version-compare --oper camo

# Collect from clusters in a specific list
./collect_from_multiple_clusters.sh --reason "SREP-12345" --version-compare --oper camo --cluster-list camo_promo.list

# Limit to first 10 clusters
./collect_from_multiple_clusters.sh --reason "SREP-12345" --version-compare --oper camo --max-clusters 10
```

**Output:**
- CSV file: `version_compare_YYYYMMDD_HHMMSS.csv`

### analyze_version_comparison.sh

Analyzes collected version comparison data and generates detailed reports.

**Usage:**
```bash
./analyze_version_comparison.sh version_compare_20260203_120000.csv
```

**Features:**
- Version identification and progression tracking
- Statistical analysis (min, max, avg) for CPU and memory
- Percentage change calculations
- Cluster-by-cluster comparison
- Regression detection (>10% increase)
- Improvement detection (>10% decrease)
- Overall assessment and recommendations

**Sample Output:**
```
================================================================================
VERSION COMPARISON ANALYSIS
================================================================================
Input file: version_compare_20260203_120000.csv

Data summary:
  Total data rows: 24
  Total clusters: 12
  Clusters with version comparison data: 12
  Clusters with only current version: 0

Analyzing operator versions...
Operator versions detected:
  0.1.781-geab01dd (12 data points)
  0.1.791-g4babac1 (12 data points)

Version progression:
  Previous: 0.1.781-geab01dd
  Current:  0.1.791-g4babac1

================================================================================
RESOURCE USAGE COMPARISON
================================================================================

CPU Usage Analysis (cores)
----------------------------------------
Previous version (max CPU):
  Min: 0.0012 cores
  Max: 0.0045 cores
  Avg: 0.0028 cores

Current version (max CPU):
  Min: 0.0011 cores
  Max: 0.0042 cores
  Avg: 0.0026 cores

Change:
  Average CPU: -7.14% (DECREASE)

Memory Usage Analysis (bytes)
----------------------------------------
Previous version (max memory):
  Min: 45.23 MB
  Max: 62.45 MB
  Avg: 52.34 MB

Current version (max memory):
  Min: 43.67 MB
  Max: 58.91 MB
  Avg: 49.82 MB

Change:
  Average Memory: -4.81% (-2.52 MB) (DECREASE)

================================================================================
CLUSTERS WITH SIGNIFICANT CHANGES
================================================================================

Clusters with CPU DECREASES (>10%):
  cluster-a (abc123): -12.5% decrease
    Version: 0.1.781-geab01dd -> 0.1.791-g4babac1

Stable clusters (changes within ±10%): 11

================================================================================
SUMMARY
================================================================================
Overall Assessment:

  ✓ CPU: STABLE - Average CPU change within ±10%
  ✓ MEMORY: STABLE - Average memory change within ±10%

Recommendation:
  ✓ Resource usage remains stable across version upgrade
    No significant performance regressions detected

================================================================================
ANALYSIS COMPLETE
================================================================================
```

## Workflow Example

### 1. Detect and collect version comparison data

After the CAMO operator has been upgraded in your clusters:

```bash
./collect_from_multiple_clusters.sh \
    --reason "SREP-12345 Weekly CAMO promotion checks" \
    --version-compare \
    --oper camo \
    --cluster-list camo_promo.list
```

This creates: `version_compare_20260203_120000.csv`

### 2. Analyze resource usage changes

```bash
./analyze_version_comparison.sh version_compare_20260203_120000.csv
```

The analysis will:
- Identify which clusters were upgraded
- Calculate resource usage changes
- Flag any significant regressions (>10% increase)
- Provide an overall assessment

### 3. Review results and take action

**If regressions detected (>20% increase):**
- Investigate the specific clusters showing increases
- Review code changes between versions
- Consider holding the rollout until investigated

**If improvements detected (>20% decrease):**
- Document the efficiency gains
- Proceed confidently with wider rollout

**If stable (<10% change):**
- Proceed with rollout
- No performance impact detected

## Requirements

### Prometheus Data Retention

The version comparison requires Prometheus to retain metrics for at least:
- **Minimum**: 24 hours before the upgrade
- **Recommended**: 7+ days for better baseline

Check your Prometheus retention:
```bash
oc get prometheus -n openshift-monitoring -o jsonpath='{.items[0].spec.retention}'
```

### Upgrade Detection Window

The `--lookback-days` parameter (default: 14) determines how far back to search for version upgrades:

- **14 days** (default): Covers bi-weekly release cycles
- **7 days**: For more frequent upgrade cadences
- **30 days**: For monthly releases or thorough historical analysis

## Interpretation Guide

### CPU Changes

- **< -10%**: Significant improvement (efficiency gain)
- **-10% to +10%**: Stable (normal variation)
- **> +10%**: Potential regression (investigate)
- **> +20%**: Significant regression (review before rollout)

### Memory Changes

- **< -10%**: Significant improvement (reduced footprint)
- **-10% to +10%**: Stable (normal variation)
- **> +10%**: Potential regression (investigate)
- **> +20%**: Significant regression (review before rollout)

### Common Causes of Resource Changes

**Increases (Regressions):**
- New features with higher resource requirements
- Memory leaks or inefficient algorithms
- Increased logging or metric collection
- Bug fixes that trade performance for correctness

**Decreases (Improvements):**
- Code optimizations
- Reduced logging verbosity
- Algorithm improvements
- Dependency updates

## Troubleshooting

### No previous version data

**Symptom:** All rows show `version_period: current`, no `previous` rows

**Causes:**
1. No upgrades within lookback period (increase `--lookback-days`)
2. ReplicaSets were pruned (check cluster `kubectl.kubernetes.io/last-applied-configuration`)
3. Operator never upgraded on these clusters

**Solution:**
```bash
# Check if upgrade happened recently
oc get replicasets -n openshift-monitoring -l app.kubernetes.io/name=configure-alertmanager-operator
```

### Prometheus query failures

**Symptom:** Resource metrics show 0 or empty values

**Causes:**
1. Prometheus pod not accessible
2. Metrics not being collected (ServiceMonitor missing)
3. Time range outside Prometheus retention

**Solution:**
```bash
# Verify Prometheus is running
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus

# Check metrics are being scraped
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
    curl -s 'http://localhost:9090/api/v1/query?query=up{job="configure-alertmanager-operator"}' | jq
```

### Inaccurate version detection

**Symptom:** Incorrect previous/current version labels

**Causes:**
1. Image tags don't match operator versions
2. CSV not found or mismatched

**Solution:**
- Verify operator version from CSV:
  ```bash
  ocm backplane elevate "SREP-12345" -- get csv -n openshift-monitoring | grep configure-alertmanager
  ```

## Integration with Other Scripts

The version comparison integrates with existing health check and metrics scripts:

```bash
# Health check (pod status)
./collect_from_multiple_clusters.sh --reason "SREP-12345" --health --oper camo

# Prometheus metrics (CAMO-specific)
./collect_from_multiple_clusters.sh --reason "SREP-12345" --metrics --oper camo

# Version comparison (resource usage)
./collect_from_multiple_clusters.sh --reason "SREP-12345" --version-compare --oper camo
```

## Files

- `collect_versioned_metrics.sh` - Single-cluster version comparison
- `collect_from_multiple_clusters.sh` - Multi-cluster orchestration (with --version-compare flag)
- `analyze_version_comparison.sh` - Version comparison analysis
- `README_VERSION_COMPARISON.md` - This file

## Read-Only Operations

All version comparison scripts are **read-only** and make **no modifications** to clusters:
- Uses `oc get`, `oc exec curl` for read-only Prometheus queries
- No `oc apply`, `oc create`, `oc delete`, or other write operations
- Safe to run in production environments

## Future Enhancements

Potential improvements to the version comparison system:

1. **Automated alerting**: Send notifications when regressions detected
2. **Historical trending**: Track resource usage across multiple versions
3. **Grafana dashboard**: Visualize version comparisons
4. **Automatic regression analysis**: ML-based anomaly detection
5. **Per-feature resource attribution**: Break down usage by CAMO features
