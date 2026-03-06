# Comprehensive Health Check - Quick Start Guide

## TL;DR - Most Common Commands

### Check all CAMO clusters
```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper camo \
  --reason "SREP-XXXXX health check"
```

### Check specific clusters
```bash
# Create file with cluster IDs
cat > my_clusters.txt << EOF
cluster-id-1
cluster-id-2
cluster-id-3
EOF

./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --cluster-list my_clusters.txt \
  --reason "SREP-XXXXX health check"
```

### Analyze results
```bash
# Table output
./analyze_comprehensive_health.sh comprehensive_health_*.json

# Summary HTML report
./analyze_comprehensive_health.sh comprehensive_health_*.json --format html

# Interactive charts with CPU/memory trends
./generate_html_report.sh comprehensive_health_*.json health_charts.html

# Both table and HTML
./analyze_comprehensive_health.sh comprehensive_health_*.json --format both
```

## What Gets Checked?

1. ✓ **Version Verification** - Does deployed version match staging?
2. ✓ **Pod Restarts** - Are pods crash looping?
3. ✓ **Memory Leaks** - Is memory usage growing over time?
4. ✓ **Log Errors** - Are there many errors in logs?
5. ✓ **Operator Health** - Are operator-managed resources healthy?

## Status Levels

- **HEALTHY** - All checks passed ✅
- **WARNING** - Non-critical issues detected ⚠️
- **CRITICAL** - Serious problems requiring immediate attention ❌

## Output Files

### JSON Output (for automation)
```json
{
  "cluster_name": "my-cluster",
  "operator_version": "v0.1.798-g038acc6",
  "health_summary": {
    "overall_status": "WARNING",
    "critical_count": 0,
    "warning_count": 2
  },
  "health_checks": [...]
}
```

### Table Output (human-readable)
```
CLUSTER NAME                        VERSION         STATUS     CRITICAL WARNINGS
cluster-001                         v0.1.798        HEALTHY           0        0
cluster-002                         v0.1.798        WARNING           0        2
cluster-003                         v0.1.795        CRITICAL          1        1
```

### HTML Report (detailed)
- Color-coded status indicators
- Detailed per-cluster breakdowns
- Sortable tables
- Ready to attach to JIRA tickets

## Common Workflows

### Pre-Release Validation
```bash
# 1. Check operator version on staging
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --cluster-list staging.txt \
  --reason "SREP-XXXXX pre-release validation"

# 2. Review results
./analyze_comprehensive_health.sh comprehensive_health_*.json

# 3. If healthy, monitor production rollout
```

### Incident Investigation
```bash
# 1. Health check on affected clusters
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --cluster-list affected.txt \
  --reason "SREP-XXXXX incident investigation"

# 2. Generate HTML report for JIRA
./analyze_comprehensive_health.sh comprehensive_health_*.json \
  --format html \
  --html-output incident_report.html
```

### Regular Monitoring
```bash
# Weekly health check (sample 50 clusters)
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --max-clusters 50 \
  --reason "SREP-XXXXX weekly monitoring"
```

## Thresholds

Default thresholds (can be modified in script):

| Check | Warning | Critical |
|-------|---------|----------|
| Pod Restarts | >5 | >10 |
| Memory Increase | >20% in 6h | N/A |
| Log Errors | >10 lines | N/A |
| Pod Not Running | N/A | Any pod |
| Version Mismatch | Yes | N/A |

## Prerequisites

1. Connected to VPN (for app-interface access)
2. OCM logged in: `ocm login --url=https://api.stage.openshift.com`
3. Have `~/.get_app_interface_saas_refs.sh` script installed
4. JIRA ticket number for `--reason` parameter

## Operators Supported

- **CAMO** (Configure Alertmanager Operator) - Default
- **RMO** (Route Monitor Operator) - Use `--oper rmo`

## Quick Examples

### CAMO only
```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper camo \
  --reason "SREP-12345"
```

### RMO only
```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper rmo \
  --reason "SREP-12345"
```

### Both operators
```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper camo --oper rmo \
  --reason "SREP-12345"
```

### Limit to 10 clusters
```bash
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --max-clusters 10 \
  --reason "SREP-12345"
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Unable to fetch staging versions" | Check VPN connection and `~/.get_app_interface_saas_refs.sh` |
| "Unable to query memory metrics" | Verify Prometheus is running and backplane elevation works |
| "Login failed" | Ensure OCM session is active: `ocm whoami` |
| "No clusters found" | Check cluster list file or OCM query filters |

## Reading Results

### All Healthy ✅
```
CRITICAL:                0 (  0.0%)
WARNING:                 0 (  0.0%)
HEALTHY:                45 (100.0%)
```
**Action**: None needed, operator version is stable

### Some Warnings ⚠️
```
CRITICAL:                0 (  0.0%)
WARNING:                12 ( 26.7%)
HEALTHY:                33 ( 73.3%)
```
**Action**: Review warnings, plan remediation if needed

### Critical Issues ❌
```
CRITICAL:                5 ( 11.1%)
WARNING:                12 ( 26.7%)
HEALTHY:                28 ( 62.2%)
```
**Action**: Investigate critical clusters immediately, may require incident

## Full Documentation

For complete documentation, see [README_COMPREHENSIVE_HEALTH.md](README_COMPREHENSIVE_HEALTH.md)
