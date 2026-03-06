# Comprehensive Operator Health Check

This guide explains how to use the comprehensive health check system to validate operator deployments across multiple clusters.

## Overview

The comprehensive health check performs the following validations:

1. **Version Verification** - Compares deployed operator version against expected staging cluster versions
2. **Pod Status & Restarts** - Checks for pod availability and excessive restart counts
3. **Memory Leak Detection** - Analyzes memory usage trends over time to detect potential memory leaks
4. **Log Error Analysis** - Scans recent logs for error patterns
5. **Operator-Specific Health** - Performs operator-specific checks (e.g., CAMO alertmanager pods, RMO routes)

## Quick Start

### Single Cluster Check

Check a single cluster (after logging in):

```bash
./collect_operator_health.sh --reason "SREP-12345 health check"
```

For RMO instead of CAMO:

```bash
./collect_operator_health.sh \
  --deployment route-monitor-operator \
  --namespace openshift-route-monitor-operator \
  --saas-file saas-route-monitor-operator.yaml \
  --reason "SREP-12345 health check"
```

### Multiple Clusters

Check all production clusters:

```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --reason "SREP-12345 pre-release validation"
```

Check specific clusters from a file:

```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --cluster-list my_clusters.txt \
  --reason "SREP-12345 health check"
```

Check only CAMO operator:

```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper camo \
  --reason "SREP-12345 CAMO validation"
```

Check only RMO operator:

```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper rmo \
  --reason "SREP-12345 RMO validation"
```

## Output Formats

### JSON Output (Default)

The health check generates JSON Lines format (one JSON object per cluster per line). This is the default format and is designed for programmatic parsing.

Example output structure:

```json
{
  "cluster_id": "abc123...",
  "cluster_name": "my-cluster",
  "cluster_version": "4.14.0",
  "operator_name": "configure-alertmanager-operator",
  "operator_version": "v0.1.798-g038acc6",
  "operator_image": "quay.io/app-sre/configure-alertmanager-operator:...",
  "namespace": "openshift-monitoring",
  "deployment": "configure-alertmanager-operator",
  "timestamp": "2026-02-24T12:00:00Z",
  "health_summary": {
    "overall_status": "WARNING",
    "critical_count": 0,
    "warning_count": 2
  },
  "health_checks": [
    {
      "check": "version_verification",
      "status": "PASS",
      "severity": "warning",
      "message": "Version matches staging deployment",
      "details": {
        "current_version": "v0.1.798-g038acc6",
        "expected_versions": ["038acc6a1b2c...", "12345abc..."]
      }
    },
    {
      "check": "pod_status_and_restarts",
      "status": "WARNING",
      "severity": "warning",
      "message": "High pod restart count (max: 7)",
      "details": {
        "desired_replicas": 1,
        "ready_replicas": 1,
        "available_replicas": 1,
        "total_restarts": 7,
        "max_restarts": 7,
        "pods_not_running": 0
      }
    },
    {
      "check": "memory_leak_detection",
      "status": "PASS",
      "severity": "warning",
      "message": "Memory usage is stable",
      "details": {
        "trend": "stable",
        "increase_percent": 5.2,
        "threshold_percent": 20
      }
    },
    {
      "check": "log_error_analysis",
      "status": "PASS",
      "severity": "warning",
      "message": "Error count within acceptable range",
      "details": {
        "error_count": 3,
        "warning_count": 12,
        "error_threshold": 10,
        "error_samples": []
      }
    },
    {
      "check": "operator_specific_health",
      "status": "PASS",
      "severity": "critical",
      "message": "",
      "details": {}
    }
  ]
}
```

## Analyzing Results

### Table Format

Generate a human-readable table summary:

```bash
./analyze_comprehensive_health.sh comprehensive_health_20260224.json
```

Example output:

```
================================================================================
COMPREHENSIVE HEALTH CHECK REPORT
================================================================================

Generated: Mon Feb 24 12:00:00 PST 2026
Input file: comprehensive_health_20260224.json

Total clusters analyzed: 45

================================================================================
OVERALL HEALTH SUMMARY
================================================================================
CRITICAL:                2 (  4.4%)
WARNING:                12 ( 26.7%)
HEALTHY:                31 ( 68.9%)

================================================================================
CLUSTER HEALTH STATUS
================================================================================
CLUSTER NAME                        VERSION         STATUS     CRITICAL WARNINGS
------------                        -------         ------     -------- --------
cluster-001                         v0.1.798-g0     HEALTHY           0        0
cluster-002                         v0.1.798-g0     WARNING           0        2
cluster-003                         v0.1.795-g1     CRITICAL          1        1
...
```

### HTML Reports

There are two types of HTML reports available:

#### 1. Summary HTML Report (Table-based)

Generate a styled summary report with tables:

```bash
./analyze_comprehensive_health.sh comprehensive_health_20260224.json \
  --format html \
  --html-output health_report.html
```

Generate both table and HTML:

```bash
./analyze_comprehensive_health.sh comprehensive_health_20260224.json \
  --format both
```

The summary HTML report includes:
- Overall health summary with statistics
- Sortable table of all clusters
- Detailed per-cluster health check results
- Color-coded status indicators
- Responsive design for mobile/desktop viewing

#### 2. Interactive HTML Report (with Charts)

Generate an interactive report with CPU/memory usage charts:

```bash
./generate_html_report.sh comprehensive_health_20260224.json cluster_health_charts.html
```

The interactive HTML report includes:
- **Interactive time-series charts**: CPU and memory usage over time
- **Visual event markers**: Version updates and pod restart indicators
- **Expandable health checks**: Click to view detailed metrics for each check
- **Multi-cluster support**: Single report can display data from multiple clusters
- **Self-contained**: Single HTML file that can be shared via email or web

**Note**: Charts require time-series data from Prometheus, which is automatically collected by `collect_operator_health.sh` when running with proper backplane elevation.

For complete details on the interactive HTML reports, see [HTML_REPORTS_GUIDE.md](HTML_REPORTS_GUIDE.md).

## Health Check Details

### 1. Version Verification

**What it checks:**
- Compares the deployed operator version against expected versions from staging clusters
- Staging cluster references are fetched from app-interface via `~/.get_app_interface_saas_refs.sh`

**Default staging clusters for CAMO:**
- camo-hive-stage-01
- camo-hives02ue1
- camo-hives03ue1

**Status levels:**
- `PASS`: Version matches one of the staging cluster versions
- `FAIL`: Version does not match any staging cluster version (indicates potential installation error)
- `UNKNOWN`: Unable to fetch staging version references

**Why this matters:**
If the version on a production cluster doesn't match any of the staging clusters, it may indicate:
- The operator was not installed correctly
- A manual intervention occurred
- The deployment pipeline failed

### 2. Pod Status & Restarts

**What it checks:**
- All replicas are ready and available
- Pod restart counts are within acceptable limits
- All pods are in Running state

**Thresholds:**
- **Critical**: >10 restarts on any pod, or pods not in Running state
- **Warning**: >5 restarts on any pod, or not all replicas ready

**Why this matters:**
Excessive restarts indicate:
- Crash loops
- Resource constraints
- Configuration issues
- Application bugs

### 3. Memory Leak Detection

**What it checks:**
- Queries Prometheus for memory usage over the last 6 hours
- Calculates the percentage increase in memory usage
- Compares against threshold (default: 20% increase)

**Status levels:**
- `PASS`: Memory usage is stable (increase <20%)
- `WARNING`: Memory increased by >20% (possible memory leak)
- `UNKNOWN`: Unable to query memory metrics or insufficient data

**Why this matters:**
Steady memory growth over time indicates:
- Memory leaks in the operator
- Unbounded caching
- Resource exhaustion risk

### 4. Log Error Analysis

**What it checks:**
- Retrieves last 500 log lines from operator pod
- Counts error and warning messages
- Captures sample error messages

**Thresholds:**
- **Warning**: >10 error lines in recent logs
- **Pass**: ≤10 error lines

**Why this matters:**
High error counts indicate:
- Runtime errors
- Integration issues
- Configuration problems
- Failing reconciliation loops

### 5. Operator-Specific Health

**What it checks:**

**For CAMO:**
- Alertmanager pods are Running and Ready
- Configure-alertmanager-operator pods are Running and Ready

**For RMO:**
- (Future implementation for route monitoring checks)

**Status levels:**
- `PASS`: All operator-managed resources are healthy
- `FAIL`: One or more managed resources are not healthy
- `UNKNOWN`: Unable to check operator-specific resources

**Why this matters:**
The operator may be running, but the resources it manages could be unhealthy.

## Typical Workflows

### Pre-Release Validation

Before promoting a new operator version to production:

```bash
# 1. Check staging clusters first
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --cluster-list staging_clusters.txt \
  --reason "SREP-12345 v0.1.800 staging validation"

# 2. Review results
./analyze_comprehensive_health.sh comprehensive_health_*.json

# 3. If healthy, proceed with production rollout monitoring
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --reason "SREP-12345 v0.1.800 production rollout monitoring"
```

### Troubleshooting Deployment Issues

When investigating operator issues:

```bash
# 1. Run comprehensive check on affected clusters
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --cluster-list affected_clusters.txt \
  --reason "SREP-12345 incident investigation"

# 2. Generate detailed HTML report
./analyze_comprehensive_health.sh comprehensive_health_*.json \
  --format html \
  --html-output incident_report.html

# 3. Attach HTML report to JIRA ticket
```

### Regular Health Monitoring

Periodic health checks for proactive monitoring:

```bash
# Weekly health check
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --max-clusters 50 \
  --reason "SREP-12345 weekly health check"

# Generate summary
./analyze_comprehensive_health.sh comprehensive_health_*.json > weekly_report.txt
```

## Configuration

### Thresholds

You can modify thresholds in `collect_operator_health.sh`:

```bash
MEMORY_LEAK_THRESHOLD_PERCENT=20  # Warn if memory increases >20% over 6h
ERROR_LOG_THRESHOLD=10             # Warn if >10 error lines in logs
```

### Staging Cluster List

For CAMO, the default staging clusters are:

```bash
STAGING_CLUSTERS=("camo-hive-stage-01" "camo-hives02ue1" "camo-hives03ue1")
```

For RMO or other operators, modify the `--saas-file` parameter when running the check.

### SAAS File Location

The script expects `~/.get_app_interface_saas_refs.sh` to exist and be executable. This script fetches deployment references from app-interface.

Ensure you're connected to the VPN before running comprehensive health checks.

## Troubleshooting

### "Unable to fetch staging versions"

**Cause**: Cannot access app-interface or `~/.get_app_interface_saas_refs.sh` not found

**Solution**:
1. Verify VPN connection
2. Check that `~/.get_app_interface_saas_refs.sh` exists and is executable
3. Test manually: `~/.get_app_interface_saas_refs.sh saas-configure-alertmanager-operator.yaml`

### "Unable to query memory metrics"

**Cause**: Cannot access Prometheus or Prometheus pod not running

**Solution**:
1. Verify cluster access
2. Check that Prometheus is running: `oc get pods -n openshift-monitoring | grep prometheus`
3. Verify backplane elevation is working

### "Error count exceeds threshold"

**Cause**: Operator logs contain many error messages

**Solution**:
1. Review the error samples in the JSON output
2. Investigate specific error patterns
3. Check if errors are transient or recurring
4. Consider raising threshold if errors are expected/benign

## Files

- `collect_operator_health.sh` - Single-cluster comprehensive health check
- `collect_from_multiple_clusters.sh` - Multi-cluster collection wrapper
- `analyze_comprehensive_health.sh` - Result parser and report generator
- `~/.get_app_interface_saas_refs.sh` - Staging version reference fetcher

## Examples

### Check all clusters for CAMO health

```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper camo \
  --reason "SREP-12345 CAMO health audit" \
  --output camo_health_audit.json

./analyze_comprehensive_health.sh camo_health_audit.json --format both
```

### Check specific cluster list for RMO

```bash
# Create cluster list file
cat > rmo_clusters.txt << EOF
cluster-001
cluster-002
cluster-003
EOF

# Run health check
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper rmo \
  --cluster-list rmo_clusters.txt \
  --reason "SREP-12345 RMO validation"

# Generate HTML report
./analyze_comprehensive_health.sh comprehensive_health_*.json \
  --format html \
  --html-output rmo_health_report.html
```

### Quick status check (first 10 clusters)

```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --max-clusters 10 \
  --reason "SREP-12345 quick health check"

./analyze_comprehensive_health.sh comprehensive_health_*.json
```

## Best Practices

1. **Always provide a JIRA ticket** in the `--reason` parameter for audit trail
2. **Run on staging first** before validating production deployments
3. **Review HTML reports** for detailed analysis before taking action
4. **Monitor trends over time** by keeping historical health check results
5. **Set realistic thresholds** based on your operator's normal behavior
6. **Investigate CRITICAL issues immediately** as they indicate serious problems
7. **Use cluster lists** to focus on specific subsets when troubleshooting
8. **Combine with other metrics** (resource usage, Prometheus alerts) for complete picture

## Next Steps

After running comprehensive health checks:

1. Review the overall health summary
2. Investigate any CRITICAL issues immediately
3. Plan remediation for WARNING issues
4. Update JIRA tickets with findings
5. Schedule follow-up checks after making changes
6. Consider trending analysis if running regularly
