# Operator Health Report - Architecture

## Overview

This project provides multi-modal health monitoring for OpenShift operators across production clusters. The architecture is designed around three output formats, each optimized for different use cases and audiences.

## Core Design Principles

### 1. **Fast vs Comprehensive**
- **Fast checks** prioritize speed and coverage (CSV output)
- **Comprehensive checks** prioritize depth and analysis (JSON/HTML output)

### 2. **Machine-readable vs Human-readable**
- **CSV/JSON** for automation, programmatic parsing, and archival
- **HTML** for human analysis, sharing with stakeholders, and visual insights

### 3. **Multi-operator Support**
- Unified interface for all operators (CAMO, RMO, future operators)
- Consistent health check framework across operators
- Operator-specific checks when needed

## Output Formats

### CSV Format (Simple Health Checks)

**When to use:**
- Quick "are things running?" checks before/after deployments
- Spreadsheet analysis (Excel, Google Sheets)
- Unix tool processing (grep, awk, cut, sort)
- Large-scale fleet scans (1000+ clusters)
- CI/CD pipeline status checks

**What it contains:**
- Cluster ID, name, version
- Pod status, restart counts, uptime
- Deployment replica status
- Error event counts
- Basic health status (HEALTHY/WARNING/CRITICAL)

**Triggered by:**
```bash
./collect_from_multiple_clusters.sh --health --reason "SREP-1234"
```

**Performance:**
- ~5-10 seconds per cluster
- No Prometheus queries
- No log analysis
- Minimal API calls

**Example use case:**
*"I need to verify CAMO pods are running across all production clusters before the deployment freeze"*

### JSON Format (Comprehensive Health Checks)

**When to use:**
- Pre-release validation with full diagnostics
- Root cause analysis of production issues
- Programmatic integration with other tools
- Long-term archival of health state
- Automation pipelines that need detailed data

**What it contains:**
All CSV data PLUS:
- Version verification against app-interface
- Memory leak detection (24h trend analysis)
- CPU leak detection (24h trend analysis)
- Log error analysis (last 100 lines)
- Operator-specific health checks
- Time-series metrics from Prometheus
- Secret/ConfigMap validation (with --secrets)

**Triggered by:**
```bash
./collect_from_multiple_clusters.sh --comprehensive-health --reason "SREP-1234"
```

**Performance:**
- ~30-60 seconds per cluster
- Requires Prometheus/Thanos access
- Parses operator logs
- Queries app-interface for version verification
- Uses caching to optimize repeated checks

**Example use case:**
*"I need to validate that the new CAMO version doesn't have memory leaks and matches the expected version across the fleet"*

### HTML Format (Visual Reports)

**When to use:**
- Sharing results with stakeholders (team, management)
- Visual analysis of trends and patterns
- Inclusion in RCA documents
- Pre-release go/no-go decision reports
- Archival documentation for incidents

**What it contains:**
- All JSON data rendered visually
- Interactive CPU/memory charts (Chart.js)
- Color-coded health status badges
- Expandable detail sections per cluster
- Version change markers on charts
- Pod restart event markers
- Responsive design (mobile/desktop/print)

**Generated from:**
JSON comprehensive health check data

**Triggered by:**
Automatically generated after `--comprehensive-health` (unless `--no-html` specified)

Or manually:
```bash
./generate_html_report.sh comprehensive_health_20260327.json report.html
```

**Example use case:**
*"I need to present CAMO health status to the team lead before promoting to production"*

## Architecture Flow

```
┌─────────────────────────────────────────────────────────────┐
│                  User Invokes Collection                     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  Which mode?    │
                    └─────────────────┘
                              │
                ┌─────────────┼─────────────┐
                │             │             │
                ▼             ▼             ▼
         ┌──────────┐  ┌──────────┐  ┌──────────┐
         │ --health │  │ --comp-  │  │ --op-ver │
         │          │  │ rehensive│  │  (fast)  │
         └──────────┘  └──────────┘  └──────────┘
                │             │             │
                ▼             ▼             ▼
         ┌──────────┐  ┌──────────┐  ┌──────────┐
         │   CSV    │  │   JSON   │  │   CSV    │
         │  Output  │  │  Output  │  │  Output  │
         └──────────┘  └──────────┘  └──────────┘
                              │
                              │ (unless --no-html)
                              ▼
                        ┌──────────┐
                        │   HTML   │
                        │  Report  │
                        └──────────┘
                              │
                              ▼
                     ┌─────────────────┐
                     │ open report.html│
                     └─────────────────┘
```

## File Naming Conventions

| Mode | Output Pattern | Example |
|------|---------------|---------|
| Health Check (CSV) | `health_check_YYYYMMDD_HHMMSS.csv` | `health_check_20260327_083626.csv` |
| Comprehensive (JSON) | `comprehensive_health_YYYYMMDD_HHMMSS.json` | `comprehensive_health_20260327_143022.json` |
| HTML Report | `comprehensive_health_YYYYMMDD_HHMMSS.html` | `comprehensive_health_20260327_143022.html` |
| Resource Usage (CSV) | `resource_usage_YYYYMMDD_HHMMSS.csv` | `resource_usage_20260327_120000.csv` |
| Metrics (CSV) | `camo_metrics_YYYYMMDD_HHMMSS.csv` | `camo_metrics_20260327_150000.csv` |

## Script Organization

### Primary Scripts

#### `collect_from_multiple_clusters.sh`
**Purpose:** Multi-cluster orchestrator

**Responsibilities:**
- Cluster discovery via OCM or file-based list
- Batch cluster login via OCM backplane
- Parallel/sequential cluster processing
- Operator detection and configuration
- Mode routing (health/comprehensive/metrics)
- Output aggregation
- HTML report generation (auto-trigger)

**Key flags:**
- `--health` - Simple CSV health checks
- `--comprehensive-health` - Full JSON health checks + auto HTML
- `--no-html` - Skip HTML generation (JSON only)
- `--oper camo|rmo` - Operator selection
- `--cluster-list FILE` - File-based cluster targeting
- `--cluster-filter FILTER` - OCM-based cluster filtering (see below)

**Cluster Discovery:**
The script supports two modes for selecting clusters:

1. **File-based** (`--cluster-list FILE`):
   - Read cluster IDs from a file (one per line)
   - Useful for targeting specific clusters
   - No interactive approval needed

2. **OCM-based** (default when no `--cluster-list`):
   - Fetches clusters directly from OCM API
   - Displays table of clusters for review
   - Requires user approval before proceeding (interactive mode)
   - Supports filtering via `--cluster-filter`

**Cluster Filter Options:**
- `all` (default) - All ready ROSA/OSD clusters (includes HyperShift MC/SC)
- `no-hcp` - Exclude HyperShift management/service clusters (hs-mc-*, hs-sc-*)
- `custom:QUERY` - Custom OCM search query

Examples:
```bash
# Fetch all ready clusters (default)
./collect_from_multiple_clusters.sh --comprehensive-health -r "SREP-1234"

# Exclude HyperShift infrastructure clusters
./collect_from_multiple_clusters.sh --comprehensive-health -r "SREP-1234" --cluster-filter no-hcp

# Custom OCM query (US East 1 only)
./collect_from_multiple_clusters.sh --comprehensive-health -r "SREP-1234" \
    --cluster-filter "custom:product.id='rosa' and region.id='us-east-1' and state='ready'"
```

#### `collect_operator_health.sh`
**Purpose:** Single-cluster comprehensive health checker

**Responsibilities:**
- Version verification via app-interface
- Memory/CPU leak detection (Prometheus queries)
- Log error analysis (last 100 lines)
- Operator-specific checks
- JSON output formatting

**Called by:** `collect_from_multiple_clusters.sh` when `--comprehensive-health`

#### `collect_pod_health.sh`
**Purpose:** Single-cluster simple health checker

**Responsibilities:**
- Pod status and uptime
- Restart count monitoring
- Error event detection
- Deployment replica status
- CSV output formatting

**Called by:** `collect_from_multiple_clusters.sh` when `--health`

#### `generate_html_report.sh`
**Purpose:** JSON-to-HTML transformer

**Responsibilities:**
- Parse JSON health check data
- Generate interactive Chart.js visualizations
- Render color-coded status badges
- Create expandable cluster sections
- Embed all data in self-contained HTML

**Triggered by:**
- Automatically after `--comprehensive-health` (unless `--no-html`)
- Manually: `./generate_html_report.sh input.json output.html`

### Analysis Scripts

#### `analyze_health_data.sh`
**Purpose:** CSV health check analyzer

**Input:** `health_check_*.csv`

**Output:**
- Health status distribution
- Clusters with warnings/errors
- Production readiness assessment
- Aggregate metrics (restarts, errors, uptime)

#### `analyze_resource_data.sh`
**Purpose:** Resource usage analyzer

**Input:** `resource_usage_*.csv`

**Output:**
- CPU/memory usage statistics
- Percentile calculations (p50, p95, p99)
- Resource limit recommendations
- Per-cluster resource breakdown

## Data Flow: Comprehensive Health Check

```
┌────────────────────────────────────────────────────────────┐
│ 1. User runs comprehensive health check                    │
│    $ ./collect_from_multiple_clusters.sh \                 │
│        --comprehensive-health \                             │
│        --reason "SREP-1234" \                              │
│        --oper camo                                         │
└────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌────────────────────────────────────────────────────────────┐
│ 2. For each cluster:                                        │
│    a. Login via OCM backplane                              │
│    b. Call collect_operator_health.sh                      │
│    c. Append JSON object to output file (JSON Lines)       │
└────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌────────────────────────────────────────────────────────────┐
│ 3. Post-processing:                                         │
│    a. Convert JSON Lines → JSON array (jq -s)              │
│    b. Call generate_html_report.sh (unless --no-html)      │
└────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌────────────────────────────────────────────────────────────┐
│ 4. Output:                                                  │
│    ✓ comprehensive_health_20260327_143022.json             │
│    ✓ comprehensive_health_20260327_143022.html             │
│                                                             │
│    User can open HTML in browser immediately               │
└────────────────────────────────────────────────────────────┘
```

## Health Check Framework

### Health Check Types

1. **version_verification**
   - Compares deployed version against app-interface staging refs
   - Severity: warning
   - Status: PASS/FAIL/UNKNOWN

2. **pod_status_and_restarts**
   - Monitors pod availability and restart counts
   - Severity: critical (if pods not ready)
   - Severity: warning (if excessive restarts)
   - Status: PASS/FAIL

3. **resource_leak_detection**
   - Analyzes 24h memory/CPU trends
   - Detects >20% increase (memory leak)
   - Detects >50% increase (CPU leak)
   - Severity: critical
   - Status: PASS/FAIL/UNKNOWN

4. **log_error_analysis**
   - Scans last 100 log lines for errors
   - Pattern matching for critical errors
   - Severity: warning
   - Status: PASS/FAIL

5. **operator_specific_health**
   - CAMO: alertmanager-main pods, secrets, ConfigMaps
   - RMO: route status, blackbox exporter
   - Severity: varies
   - Status: PASS/FAIL

### Health Status Calculation

```python
overall_status = "HEALTHY"

if any(check.status == "FAIL" and check.severity == "critical"):
    overall_status = "CRITICAL"
elif any(check.status == "FAIL" and check.severity == "warning"):
    overall_status = "WARNING"

return {
    "overall_status": overall_status,
    "critical_count": count(severity="critical", status="FAIL"),
    "warning_count": count(severity="warning", status="FAIL")
}
```

## Caching Strategy

To avoid redundant API calls when checking multiple clusters:

### App-Interface Version Cache
- Caches saas file content (CAMO/RMO staging refs)
- Shared across all clusters in single run
- Invalidated after run completes

### OCM Cluster Metadata Cache
- Batch fetches cluster info (1 OCM API call for 50 clusters)
- Caches: name, version, creation date
- Reduces API calls by 98%

### Prometheus/Thanos Queries
- NOT cached (time-series data changes)
- Each cluster queries its own Prometheus

## Performance Characteristics

| Mode | Clusters | Time per Cluster | Total Time (50 clusters) |
|------|----------|------------------|--------------------------|
| `--health` | 50 | 5-10s | ~5-8 min |
| `--comprehensive-health` | 50 | 30-60s | ~25-50 min |
| `--op-ver` (version only) | 50 | 3-5s | ~3-5 min |

**Bottlenecks:**
1. OCM backplane login (serial, ~2-3s per cluster)
2. Prometheus queries (parallel within cluster, ~10-20s)
3. Log fetching (serial, ~5-10s)

**Optimizations:**
- Batch OCM metadata fetching
- App-interface caching
- Parallel pod queries within cluster
- Early exit on cluster login failures

## Supported Operators

### Configure Alertmanager Operator (CAMO)

**Namespace:** `openshift-monitoring`
**Deployment:** `configure-alertmanager-operator`
**App-interface file:** `saas-configure-alertmanager-operator.yaml`

**Specific health checks:**
- alertmanager-main pods (2 replicas expected)
- alertmanager-main secret validation
- CAMO ConfigMap presence
- PagerDuty secret configuration (with --secrets)

### Route Monitor Operator (RMO)

**Namespace:** `openshift-route-monitor-operator`
**Deployment:** `route-monitor-operator-controller-manager`
**App-interface file:** `saas-route-monitor-operator.yaml`

**Specific health checks:**
- RouteMonitor CRD availability
- Blackbox exporter deployment
- Route creation and monitoring

## Extension Guide: Adding a New Operator

To add support for a new operator:

### 1. Add operator configuration

Edit `collect_from_multiple_clusters.sh`:

```bash
OPERATOR_CONFIGS["your-operator"]="your-operator-name:your-namespace:your-deployment"
ALL_OPERATORS=("camo" "rmo" "your-operator")
```

### 2. Create operator-specific health checks

Edit `collect_operator_health.sh`:

```bash
check_your_operator_health() {
    local namespace=$1
    # Add operator-specific checks
    # Return JSON health check result
}
```

### 3. Add app-interface support

If operator uses app-interface for version management:

```bash
SAAS_FILE_MAP["your-operator"]="saas-your-operator.yaml"
```

### 4. Update documentation

- Add to `README.md` examples
- Update `OPERATOR_CONFIGS` in this file
- Add operator-specific health check details

## Common Workflows

### Pre-Release Validation

```bash
# 1. Comprehensive health check with HTML report (auto-fetches all ready clusters)
./collect_from_multiple_clusters.sh \
    --comprehensive-health \
    --oper camo \
    --reason "SREP-1234 CAMO v1.2.3 release validation"

# The script will:
#   a. Fetch all ready ROSA/OSD clusters from OCM
#   b. Display table of clusters for review
#   c. Prompt for approval (Y/n)
#   d. Perform health checks on approved clusters
#   e. Generate HTML report automatically

# 2. Open HTML report (auto-generated)
open comprehensive_health_20260327_143022.html

# 3. Review in browser:
#    - Check for CRITICAL or WARNING status
#    - Verify version matches expected
#    - Review memory/CPU trends
#    - Check for log errors

# 4. Go/no-go decision based on report
```

### Targeted Cluster Checks

```bash
# Check specific clusters from a file
./collect_from_multiple_clusters.sh \
    --comprehensive-health \
    --oper camo \
    --cluster-list problem_clusters.txt \
    --reason "SREP-1234 investigating specific issues"

# Check only non-HyperShift clusters
./collect_from_multiple_clusters.sh \
    --comprehensive-health \
    --oper camo \
    --cluster-filter no-hcp \
    --reason "SREP-1234 ROSA Classic validation"

# Check clusters in specific region
./collect_from_multiple_clusters.sh \
    --comprehensive-health \
    --oper camo \
    --cluster-filter "custom:region.id='us-west-2' and state='ready'" \
    --reason "SREP-1234 US West 2 validation"
```

### Post-Deployment Verification

```bash
# Quick health check across fleet (CSV)
./collect_from_multiple_clusters.sh \
    --health \
    --oper camo \
    --reason "SREP-1234 post-deployment verification"

# Analyze results
./analyze_health_data.sh health_check_20260327_150000.csv

# If issues found, run comprehensive check on problem clusters
./collect_from_multiple_clusters.sh \
    --comprehensive-health \
    --oper camo \
    --cluster-list problem_clusters.txt \
    --reason "SREP-1234 investigating deployment issues"
```

### Daily Monitoring

```bash
# Automated daily comprehensive check (cron job)
0 8 * * * cd /path/to/operator-health-report && \
    ./collect_from_multiple_clusters.sh \
        --comprehensive-health \
        --oper camo \
        --oper rmo \
        --reason "Daily health monitoring" \
        --no-html && \
    ./generate_html_report.sh \
        comprehensive_health_$(date +%Y%m%d)_*.json \
        /var/www/html/daily_reports/$(date +%Y%m%d).html
```

## Troubleshooting

### HTML report not generated

**Symptom:** JSON file created but no HTML

**Check:**
1. Was `--no-html` specified? (expected behavior)
2. Is `generate_html_report.sh` executable? Run `chmod +x generate_html_report.sh`
3. Check for errors in script output
4. Manually run: `./generate_html_report.sh your_file.json output.html`

### Charts not displaying in HTML

**Symptom:** HTML opens but charts are blank

**Causes:**
1. No internet connection (Chart.js loads from CDN)
2. No time-series data in JSON (Prometheus queries failed)
3. JavaScript errors (check browser console)

**Fix:**
- Check JSON has `memory_timeseries` and `cpu_timeseries` arrays
- Verify Prometheus access during collection
- Check browser console for errors

### Slow comprehensive health checks

**Symptom:** Taking >60s per cluster

**Causes:**
1. Prometheus queries timing out
2. Large log files (>1000 lines)
3. Slow app-interface API responses

**Optimizations:**
- Use `--cluster-list` to target subset
- Reduce lookback period (modify script)
- Run during off-peak hours

### Version verification fails

**Symptom:** All clusters show "UNKNOWN" for version check

**Causes:**
1. App-interface API unreachable
2. Saas file not found
3. No staging refs in saas file

**Fix:**
- Check app-interface URL in script
- Verify saas file name in SAAS_FILE_MAP
- Check network access to app-interface API

## Security Considerations

### OCM Backplane Elevation

All cluster access requires OCM backplane login with justification:
- `--reason` flag is REQUIRED for audit trail
- Should reference JIRA ticket (e.g., "SREP-1234")
- Sessions are automatically logged out on exit

### Secrets Access

The `--secrets` flag enables extended health checks that read secrets:
- Requires backplane elevation (automatic)
- Accesses: alertmanager-main secret, PagerDuty secrets
- Only enabled when explicitly requested
- DO NOT enable in automated pipelines without approval

### Data Sensitivity

Health check output may contain:
- Cluster IDs and names
- Operator versions and images
- Error messages (may include paths)
- Resource usage patterns

**DO NOT:**
- Commit HTML/CSV/JSON reports to public repos
- Share reports outside Red Hat
- Include in public documentation

**OK to:**
- Archive in internal systems
- Share via internal Slack/email
- Include in RCA documents (internal)

## Future Enhancements

### Planned Features
- [ ] SLO-based health scoring
- [ ] Historical trend analysis (compare with previous runs)
- [ ] Alert integration (PagerDuty/Slack on failures)
- [ ] Cluster grouping by product/region
- [ ] PDF export from HTML reports
- [ ] Real-time monitoring mode (websocket updates)

### Under Consideration
- [ ] Grafana dashboard integration
- [ ] Prometheus alerting rules generation
- [ ] Machine learning anomaly detection
- [ ] Multi-cloud support (GCP, Azure)

## Getting Help

### For Users
1. Check `README.md` for quick start
2. Review `HEALTH_CHECK_QUICK_START.md`
3. See `HTML_REPORTS_GUIDE.md` for report details
4. Ask in #team-rocket-internal Slack

### For AI Assistants
- This document (`ARCHITECTURE.md`) explains design decisions
- Check function comments in scripts for implementation details
- Review example output files for data structure
- Prefer comprehensive health checks for diagnostic tasks
- Always include `--reason` with JIRA ticket

### For Developers
- Code follows bash best practices
- Uses `set -uo pipefail` (NOT `-e` for graceful error handling)
- Requires bash 4.0+ for associative arrays
- All external commands have error checking
- JSON parsing uses `jq`

## Related Documentation

- [README.md](README.md) - Quick start and basic usage
- [HEALTH_CHECK_QUICK_START.md](HEALTH_CHECK_QUICK_START.md) - Health check reference
- [HTML_REPORTS_GUIDE.md](HTML_REPORTS_GUIDE.md) - HTML report generation guide
- [VERSION_VERIFICATION_GUIDE.md](VERSION_VERIFICATION_GUIDE.md) - Version checking details
- [README_COMPREHENSIVE_HEALTH.md](README_COMPREHENSIVE_HEALTH.md) - Comprehensive health system

---

**Last Updated:** 2026-03-27
**Maintainer:** SREP Observability Team (Team Rocket)
**Repository:** operator-health-report (internal)
