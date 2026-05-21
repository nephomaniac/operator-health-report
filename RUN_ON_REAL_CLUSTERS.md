# Running Health Checks on Real Clusters

## Quick Start - Complete Workflow

### 1. Ensure OCM Login

```bash
# Check if logged in
ocm whoami

# If not logged in:
ocm login --url=https://api.stage.openshift.com
```

### 2. Collect Health Data from Multiple Clusters

```bash
# All ROSA Classic/OSD clusters for CAMO operator (recommended)
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper camo \
  -o health_$(date +%Y%m%d).json \
  -r "SREP-XXXXX health check"

# Or from specific cluster list
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper camo \
  -c my_clusters.list \
  -o health_$(date +%Y%m%d).json \
  -r "SREP-XXXXX health check"

# Or limit to first N clusters (for testing)
./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper camo \
  -m 5 \
  -o health_test.json \
  -r "SREP-XXXXX testing"
```

### 3. Generate Interactive HTML Report

```bash
# Generate single-file HTML report with charts
./generate_html_report.sh health_$(date +%Y%m%d).json health_report_$(date +%Y%m%d).html

# Open in browser
open health_report_$(date +%Y%m%d).html
```

## What Gets Collected

The comprehensive health check collects:

1. **Cluster Metadata**: ID, name, version
2. **Operator Info**: Name, version/commit, container image
3. **Version Verification**: Compares against staging clusters
4. **Pod Status**: Replicas, availability, restart counts
5. **Resource Usage**: CPU and memory time-series data from Prometheus
6. **Log Analysis**: Recent errors and warnings from operator logs
7. **Operator-Specific Checks**: e.g., CAMO alertmanager pods health
8. **Event Data** (NEW):
   - Pod restart events with timestamps and reasons
   - Operator version change history from ReplicaSets

## What the HTML Report Shows

### Summary Overview (Top of Page)
- Total cluster count
- Health distribution (Healthy/Warning/Critical) with percentages
- Quick navigation links to jump to each cluster

### Individual Cluster Drill-Down
Each cluster section includes:

1. **Cluster Header**
   - Cluster name and ID
   - Operator version
   - Timestamp
   - Overall health status badge

2. **Interactive Charts** (if Prometheus data available)
   - **Memory Usage Chart**: MB over time
   - **CPU Usage Chart**: Millicores over time
   - **Event Markers on Charts**:
     - Red dashed lines = operator version changes
     - Orange lines = pod restart events
   - Hover tooltips showing exact values

3. **Health Check Details** (Expandable)
   - Version verification
   - Pod status and restarts
   - Resource leak detection
   - Log error analysis
   - Operator-specific health

## Example Complete Workflow

```bash
# 1. Login to OCM
ocm login --url=https://api.stage.openshift.com

# 2. Collect from 10 clusters as a test
./collect_from_multiple_clusters.sh \\
  --comprehensive-health \\
  --oper camo \\
  -m 10 \\
  -o test_health.json \\
  -r "SREP-12345 testing new health check"

# Wait for collection to complete...

# 3. Generate HTML report
./generate_html_report.sh test_health.json test_health_report.html

# 4. Open and review
open test_health_report.html

# 5. If looks good, run on all clusters
./collect_from_multiple_clusters.sh \\
  --comprehensive-health \\
  --oper camo \\
  -o full_health_$(date +%Y%m%d).json \\
  -r "SREP-12345 production health check"

# 6. Generate full report
./generate_html_report.sh full_health_$(date +%Y%m%d).json full_report_$(date +%Y%m%d).html

# 7. Share the HTML file (attach to JIRA, email, etc.)
```

## Troubleshooting

### Charts Not Showing

**Problem**: HTML opens but charts are blank

**Causes**:
1. No Prometheus data was collected (backplane elevation failed)
2. No internet connection (Chart.js loads from CDN)
3. Browser JavaScript disabled

**Solution**:
- Check browser console (F12) for errors
- Verify internet connection
- Re-run collection with proper backplane elevation

### No Event Markers on Charts

**Problem**: Charts show but no version change or restart markers

**Cause**: The `events` field was not collected

**Solution**:
- Ensure you're using the latest version of `collect_operator_health.sh`
- Events require Kubernetes API access via backplane

### Empty Health Data

**Problem**: "No health data available" message

**Cause**: JSON file is empty or malformed

**Solution**:
- Check JSON file: `jq '.' your_file.json`
- Verify health check completed successfully
- Check collection script output for errors

## Data Privacy & Security

- Health check data includes cluster IDs and names
- No sensitive customer data is collected
- Container image SHAs and operator versions are included
- Safe to share within Red Hat (e.g., attach to JIRA)
- HTML file is self-contained (no external dependencies except CDN)

## Performance Notes

- **Collection Time**: ~30-60 seconds per cluster
- **5 clusters**: ~5 minutes total
- **50 clusters**: ~30-45 minutes total
- **HTML Generation**: <5 seconds for any size dataset
- **HTML File Size**: ~30-50 KB per cluster

## Advanced Usage

### Collect from Both CAMO and RMO

```bash
./collect_from_multiple_clusters.sh \\
  --comprehensive-health \\
  --oper camo --oper rmo \\
  -o multi_operator_health.json \\
  -r "SREP-12345"

./generate_html_report.sh multi_operator_health.json multi_op_report.html
```

### Include HyperShift Infrastructure Clusters

```bash
# By default, hs-mc-* and hs-sc-* clusters are excluded
# To include them:
./collect_from_multiple_clusters.sh \\
  --comprehensive-health \\
  --oper camo \\
  --check-hcp-controllers \\
  -r "SREP-12345"
```

### Filter by Cluster State

```bash
# Only ready clusters
ocm list clusters --columns id --parameter search="state='ready'" | \\
  tail -n +2 > ready_clusters.list

./collect_from_multiple_clusters.sh \\
  --comprehensive-health \\
  -c ready_clusters.list \\
  -r "SREP-12345"
```

## Next Steps

After generating the report:

1. **Review the summary** - Check overall health distribution
2. **Investigate warnings** - Click on WARNING clusters to see details
3. **Examine critical issues** - Priority: clusters marked CRITICAL
4. **Analyze trends** - Look at CPU/memory charts for patterns
5. **Check version consistency** - Verify all clusters on expected version
6. **Document findings** - Attach HTML report to JIRA ticket
7. **Take action** - Create follow-up tickets for issues found

## Related Documentation

- [HTML_REPORTS_GUIDE.md](HTML_REPORTS_GUIDE.md) - Detailed HTML report documentation
- [README_COMPREHENSIVE_HEALTH.md](README_COMPREHENSIVE_HEALTH.md) - Complete health check guide
- [HEALTH_CHECK_QUICK_START.md](HEALTH_CHECK_QUICK_START.md) - Quick reference
