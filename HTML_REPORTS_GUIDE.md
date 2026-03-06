# HTML Report Generation Guide

## Overview

The `generate_html_report.sh` script creates interactive, static HTML reports from operator health check data collected by `collect_operator_health.sh` or `collect_from_multiple_clusters.sh`.

## Features

- **Interactive Charts**: CPU and memory usage visualized over time using Chart.js
- **Event Markers**: Visual indicators showing operator version updates and pod restarts
- **Health Check Details**: Expandable sections for each health check with detailed metrics
- **Multi-Cluster Support**: Single report can include data from multiple clusters
- **Responsive Design**: Works on desktop, tablet, and mobile devices
- **Print-Friendly**: Optimized layout for printing reports
- **Self-Contained**: Single HTML file with embedded data and CDN-loaded libraries

## Usage

### Basic Usage

```bash
./generate_html_report.sh <json_file> [output_html]
```

**Arguments**:
- `json_file`: JSON or JSON Lines file from health check scripts
- `output_html`: (optional) Output HTML file path (default: `health_report_YYYYMMDD_HHMMSS.html`)

### Examples

#### Generate report from single cluster data:
```bash
./collect_operator_health.sh example1cluster2id3456789abcdef01 configure-alertmanager-operator > health_data.json
./generate_html_report.sh health_data.json cluster_report.html
open cluster_report.html
```

#### Generate report from multi-cluster data:
```bash
./collect_from_multiple_clusters.sh -f clusters.list -o configure-alertmanager-operator -O camo_health_$(date +%Y%m%d).json
./generate_html_report.sh camo_health_$(date +%Y%m%d).json camo_report_$(date +%Y%m%d).html
open camo_report_$(date +%Y%m%d).html
```

#### Generate report with auto-named output file:
```bash
./generate_html_report.sh health_data.json
# Creates: health_report_20260302_143025.html
```

## Report Contents

### 1. Cluster Header Section

Each cluster in the report includes:
- **Cluster Name**: Display name of the cluster
- **Cluster ID**: OCM cluster identifier
- **Operator Name**: Name of the operator being monitored
- **Operator Version**: Current version/commit of the operator
- **Timestamp**: When the health check was performed

### 2. Health Summary

- **Overall Status**: HEALTHY, WARNING, or CRITICAL badge
- **Critical Issues Count**: Number of critical health check failures
- **Warnings Count**: Number of warning-level health check failures

### 3. Interactive Charts

#### Memory Usage Chart
- Line chart showing memory consumption over time (in MB)
- Blue filled area representing memory usage
- Time-series data collected from Prometheus
- Hover tooltips showing exact values and timestamps

#### CPU Usage Chart
- Line chart showing CPU consumption over time (in millicores)
- Teal filled area representing CPU usage
- Time-series data collected from Prometheus
- Hover tooltips showing exact values and timestamps

#### Chart Annotations (when available)
- **Version Update Markers**: Red dashed vertical lines showing when operator version changed
- **Pod Restart Markers**: Orange vertical lines showing when pods restarted

### 4. Health Check Details

Each health check can be expanded to show:
- **Check Name**: Type of health check performed
- **Status Badge**: PASS, FAIL, WARNING, or UNKNOWN
- **Status Icon**: Visual indicator (✓, ✗, ⚠, ?)
- **Message**: Summary of check results
- **Details Grid**: Key metrics and values from the check

Available health checks:
1. **Version Verification**: Compares operator version against staging clusters
2. **Pod Status and Restarts**: Monitors pod availability and restart counts
3. **Resource Leak Detection**: Analyzes CPU and memory trends for leaks
4. **Log Error Analysis**: Scans operator logs for errors and warnings
5. **Operator-Specific Health**: Custom checks per operator type

## Technical Details

### Data Format

The script accepts:
- **Single JSON object**: Wrapped into an array automatically
- **JSON Lines format**: Multiple objects, one per line (slurped into array)
- **JSON array**: Used directly

### Chart Library

- **Chart.js 4.4.0**: Core charting library
- **chartjs-plugin-annotation 3.0.1**: For version/restart markers
- Libraries loaded from CDN (requires internet connection to view charts)

### Time-Series Data Requirements

For charts to display, the health check JSON must include:
```json
{
  "health_checks": [
    {
      "check": "resource_leak_detection",
      "details": {
        "memory_timeseries": [[timestamp1, value1], [timestamp2, value2], ...],
        "cpu_timeseries": [[timestamp1, value1], [timestamp2, value2], ...],
        "lookback_hours": 24.0
      }
    }
  ]
}
```

**Note**: Time-series data is collected automatically by `collect_operator_health.sh` from Prometheus/Thanos when:
- Pods are running
- Metrics are available (requires backplane elevation)
- Lookback period is within 24 hours of pod age

### Browser Compatibility

- Modern browsers (Chrome, Firefox, Safari, Edge) - latest versions
- Requires JavaScript enabled
- Requires internet connection for CDN resources (Chart.js)

## Customization

### Modifying Chart Appearance

Edit the chart creation functions in the script:

```javascript
// Example: Change memory chart color
borderColor: '#36a2eb',  // Change this
backgroundColor: 'rgba(54, 162, 235, 0.1)',  // Change this
```

### Adjusting Time Format

Modify the time scale configuration:

```javascript
time: {
    unit: 'hour',  // Options: 'minute', 'hour', 'day'
    displayFormats: {
        hour: 'MMM d, HH:mm'  // Change format string
    }
}
```

### Styling Changes

All CSS is embedded in the `<style>` section. Modify colors, fonts, and layout by editing the CSS variables and classes.

## Troubleshooting

### Charts not displaying

**Problem**: HTML opens but charts are blank or missing

**Possible causes**:
1. **No time-series data in JSON**: Charts require `memory_timeseries` and `cpu_timeseries` arrays
   - Solution: Ensure Prometheus queries succeeded during collection
   - Check: `jq '.health_checks[] | select(.check == "resource_leak_detection") | .details | keys' your_file.json`

2. **No internet connection**: Chart.js loads from CDN
   - Solution: Download Chart.js locally and update script to use local files

3. **Browser JavaScript disabled**
   - Solution: Enable JavaScript in browser settings

### JSON parsing errors

**Problem**: `Error: Unable to parse JSON file`

**Solution**:
1. Validate JSON: `jq '.' your_file.json`
2. Check file format (should be JSON object or JSON Lines)
3. Ensure file is not corrupted or truncated

### Blank health check details

**Problem**: Health checks show but no details when expanded

**Cause**: Missing or empty `details` field in health check data

**Solution**: Re-run health check collection to ensure all checks complete successfully

## Future Enhancements

Planned features (marked as TODO in code):
- [ ] Extract actual restart timestamps from pod events
- [ ] Query deployment/replicaset history for version change markers
- [ ] Add pod restart events timeline chart
- [ ] Offline mode with locally bundled Chart.js
- [ ] Export charts as images (PNG/SVG)
- [ ] Comparison view for before/after operator updates

## Examples

### Typical Workflow

```bash
# 1. Collect health data from multiple clusters
./collect_from_multiple_clusters.sh -f clusters.list -o configure-alertmanager-operator \
    -O camo_health_202603 02.json

# 2. Generate HTML report
./generate_html_report.sh camo_health_20260302.json camo_report.html

# 3. Open in browser
open camo_report.html

# 4. (Optional) Share the report
# The HTML file is self-contained and can be emailed or uploaded
```

### Monitoring Over Time

```bash
# Collect daily snapshots
for day in $(seq 1 7); do
    date_suffix=$(date -v-${day}d +%Y%m%d)
    ./collect_from_multiple_clusters.sh -f clusters.list -o configure-alertmanager-operator \
        -O camo_health_${date_suffix}.json
    ./generate_html_report.sh camo_health_${date_suffix}.json camo_report_${date_suffix}.html
done

# Now you have 7 days of reports to compare trends
```

## Related Documentation

- [README_COMPREHENSIVE_HEALTH.md](README_COMPREHENSIVE_HEALTH.md) - Complete health check system guide
- [HEALTH_CHECK_QUICK_START.md](HEALTH_CHECK_QUICK_START.md) - Quick reference for health checks
- [VERSION_VERIFICATION_GUIDE.md](VERSION_VERIFICATION_GUIDE.md) - Version verification details

## Support

For issues or questions:
1. Check this guide first
2. Review example JSON files in the repository
3. Verify JSON structure with `jq`
4. Check browser console for JavaScript errors (F12 → Console tab)
