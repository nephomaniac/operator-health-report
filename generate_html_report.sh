#!/bin/bash

# generate_html_report_table.sh
# Generates HTML reports with table-based landing page and expandable cluster details
#
# Usage:
#   ./generate_html_report_table.sh <json_file> [output_html]

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_FILE="${1:-}"
OUTPUT_HTML="${2:-health_report_$(date +%Y%m%d_%H%M%S).html}"

# Validate input
if [ -z "$JSON_FILE" ]; then
    echo "Error: JSON file path required"
    echo "Usage: $0 <json_file> [output_html]"
    exit 1
fi

if [ ! -f "$JSON_FILE" ]; then
    echo "Error: JSON file not found: $JSON_FILE"
    exit 1
fi

echo "Generating HTML report from: $JSON_FILE"
echo "Output file: $OUTPUT_HTML"

# Convert JSON input to a JSON array
if jq -e 'type == "array"' "$JSON_FILE" >/dev/null 2>&1; then
    # Already a JSON array, use as-is
    json_data=$(jq -c '.' "$JSON_FILE")
elif jq -e 'type == "object"' "$JSON_FILE" >/dev/null 2>&1; then
    # Single object, wrap in array
    json_data=$(jq -c "[.]" "$JSON_FILE")
elif jq -s -e 'type == "array"' "$JSON_FILE" >/dev/null 2>&1; then
    # JSON Lines, slurp into array
    json_data=$(jq -s -c '.' "$JSON_FILE")
else
    echo "Error: Unable to parse JSON file"
    exit 1
fi

# Generate HTML file
cat > "$OUTPUT_HTML" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Operator Health Check Report</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation@3.0.1/dist/chartjs-plugin-annotation.min.js"></script>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-primary: #0f1117;
            --bg-secondary: #161922;
            --bg-card: #1c1f2e;
            --bg-hover: #242838;
            --bg-expanded: #1a1d2b;
            --border: #2a2e3f;
            --border-light: #353a4f;
            --text-primary: #f0f1f7;
            --text-secondary: #b0b4c8;
            --text-muted: #7e83a0;
            --accent: #6c8cff;
            --accent-dim: rgba(108,140,255,0.15);
            --green: #2dd4a0;
            --green-dim: rgba(45,212,160,0.12);
            --green-text: #2dd4a0;
            --yellow: #f5c542;
            --yellow-dim: rgba(245,197,66,0.12);
            --yellow-text: #f5c542;
            --red: #f25c5c;
            --red-dim: rgba(242,92,92,0.12);
            --red-text: #f25c5c;
            --info: #56b8e6;
            --info-dim: rgba(86,184,230,0.12);
            --radius: 6px;
            --radius-lg: 10px;
            --font: 'IBM Plex Sans', -apple-system, BlinkMacSystemFont, sans-serif;
            --mono: 'IBM Plex Mono', 'Menlo', monospace;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: var(--font);
            background: var(--bg-primary);
            color: var(--text-primary);
            padding: 16px;
            line-height: 1.55;
            font-size: 14px;
        }
        .container {
            max-width: 1800px;
            margin: 0 auto;
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: var(--radius-lg);
            overflow: hidden;
        }
        .header {
            background: var(--bg-card);
            border-bottom: 1px solid var(--border);
            color: var(--text-primary);
            padding: 24px 32px;
            display: flex;
            align-items: baseline;
            gap: 16px;
        }
        .header h1 {
            font-size: 1.4em;
            font-weight: 700;
            letter-spacing: -0.02em;
            color: var(--text-primary);
        }
        .header .subtitle {
            font-size: 0.82em;
            color: var(--text-muted);
            font-family: var(--mono);
        }
        .summary-overview {
            background: var(--bg-secondary);
            padding: 20px 32px;
            border-bottom: 1px solid var(--border);
        }
        .summary-overview h2 { color: var(--accent); margin-bottom: 16px; font-size: 1.05em; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
            gap: 12px;
        }
        .stat-card {
            background: var(--bg-card);
            padding: 16px;
            border-radius: var(--radius);
            text-align: center;
            border: 1px solid var(--border);
            transition: border-color 0.2s;
        }
        .stat-card.critical { border-color: var(--red); background: var(--red-dim); }
        .stat-card.warning { border-color: var(--yellow); background: var(--yellow-dim); }
        .stat-card.healthy { border-color: var(--green); background: var(--green-dim); }
        .operator-tabs {
            display: flex;
            background: linear-gradient(180deg, #2a2d3a 0%, #1e2130 100%);
            border-bottom: 1px solid #3d4155;
            padding: 6px 24px 0;
            gap: 4px;
        }
        .operator-tab {
            padding: 10px 24px;
            cursor: pointer;
            border: 1px solid transparent;
            border-bottom: none;
            background: linear-gradient(180deg, #33374a 0%, #282c3e 100%);
            font-family: var(--font);
            font-size: 0.88em;
            font-weight: 700;
            color: #8a8fa8;
            border-radius: 6px 6px 0 0;
            transition: all 0.15s;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            position: relative;
            top: 1px;
        }
        .operator-tab:hover {
            color: #c8ccdf;
            background: linear-gradient(180deg, #3d4258 0%, #303448 100%);
        }
        .operator-tab.active {
            color: #e8ecff;
            background: linear-gradient(180deg, #4a5070 0%, #3a3f58 100%);
            border-color: #4d5370 #4d5370 transparent;
            box-shadow: 0 -2px 8px rgba(108,140,255,0.15);
        }
        .operator-tab .tab-badge {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 3px;
            font-size: 0.78em;
            margin-left: 8px;
            font-weight: 600;
            font-family: var(--mono);
            border: 1px solid rgba(255,255,255,0.08);
        }
        .operator-tab .tab-badge.healthy { background: rgba(45,212,160,0.2); color: #5eecc0; }
        .operator-tab .tab-badge.warning { background: rgba(245,197,66,0.2); color: #fdd76b; }
        .operator-tab .tab-badge.critical { background: rgba(242,92,92,0.2); color: #ff8a8a; }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        .stat-number { font-size: 2em; font-weight: 700; margin: 6px 0; font-family: var(--mono); }
        .stat-number.critical { color: var(--red); }
        .stat-number.warning { color: var(--yellow); }
        .stat-number.healthy { color: var(--green); }
        .stat-label {
            font-size: 0.75em;
            color: var(--text-primary);
            text-transform: uppercase;
            letter-spacing: 0.1em;
            font-weight: 600;
        }
        .content { padding: 16px; }
        .clusters-table-wrapper { overflow-x: auto; }
        .clusters-table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.85em;
        }
        .clusters-table thead {
            background: var(--bg-card);
            color: var(--text-secondary);
            position: sticky;
            top: 0;
            z-index: 10;
        }
        .clusters-table th {
            padding: 10px 6px;
            text-align: left;
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.72em;
            letter-spacing: 0.08em;
            white-space: nowrap;
            border-bottom: 1px solid var(--border);
            border-right: 1px solid var(--border);
        }
        .clusters-table th:last-child { border-right: none; }
        .clusters-table tbody tr {
            border-bottom: 1px solid var(--border);
            cursor: pointer;
            transition: background 0.12s;
        }
        .clusters-table tbody tr.main-row:hover { background: var(--bg-hover); }
        .clusters-table tbody tr.main-row.expanded {
            background: var(--accent-dim);
        }
        .clusters-table td {
            padding: 8px 6px;
            vertical-align: middle;
            border-right: 1px solid rgba(42,46,63,0.5);
        }
        .clusters-table td:last-child { border-right: none; }
        .cluster-name-cell {
            font-weight: 600;
            color: var(--accent);
            min-width: 170px;
            font-size: 0.92em;
        }
        .check-status-cell {
            text-align: center;
            min-width: 26px;
            padding: 8px 2px;
        }
        .resource-cell {
            text-align: center;
            font-family: var(--mono);
            font-size: 0.82em;
            min-width: 30px;
            padding: 8px 3px;
            color: var(--text-secondary);
        }
        .resource-cell:first-of-type { border-left: 1px solid var(--border-light); }
        .resource-header-diagonal:first-of-type { border-left: 1px solid var(--border) !important; }
        .status-icon {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 20px;
            height: 20px;
            border-radius: 3px;
            font-weight: 700;
            font-size: 0.75em;
        }
        .status-icon.pass { background: var(--green-dim); color: var(--green); }
        .status-icon.fail { background: var(--red-dim); color: var(--red); box-shadow: 0 0 8px var(--red-dim); }
        .status-icon.warning { background: var(--yellow-dim); color: var(--yellow); box-shadow: 0 0 8px var(--yellow-dim); }
        .status-icon.info { background: var(--info-dim); color: var(--info); }
        .status-icon.na { background: rgba(92,96,120,0.15); color: var(--text-muted); }
        .status-icon.no-access { background: rgba(92,96,120,0.1); color: var(--text-muted); border: 1px dashed var(--text-muted); }
        .status-icon.status-pass { background: #28a745; color: white; }
        .status-icon.status-critical { background: #dc3545; color: white; }
        .status-icon.status-unknown { background: #6c757d; color: white; }
        .resource-value { font-weight: 600; }
        .resource-value.resource-normal { color: var(--green); }
        .resource-value.resource-warning { color: var(--yellow); font-weight: 700; }
        .resource-value.resource-error { color: var(--red); font-weight: 700; }
        .cluster-details-row { display: none; }
        .cluster-details-row.expanded { display: table-row; }
        .cluster-details-cell {
            padding: 0 !important;
            background: #e8eaef;
            border-top: 2px solid var(--accent);
        }

        /* ── Light island: everything inside .cluster-section uses dark-on-light ── */
        .cluster-section {
            padding: 24px;
            background: #f0f2f5;
            margin: 12px;
            border-radius: var(--radius);
            border: 1px solid #c8ccd6;
            color: #1a1d2b;
        }
        .cluster-header {
            background: #ffffff;
            padding: 18px;
            border-radius: var(--radius);
            margin-bottom: 16px;
            border: 1px solid #d5d8e0;
        }
        .cluster-header h2 { color: #1a3a6e; margin-bottom: 12px; font-size: 1.1em; font-weight: 700; }
        .cluster-header strong { color: #222; }
        .cluster-meta {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 12px;
        }
        .meta-item { display: flex; flex-direction: column; min-width: 0; }
        .meta-label {
            font-size: 0.72em;
            color: #6b7080;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            margin-bottom: 2px;
            font-weight: 600;
        }
        .meta-value {
            font-size: 0.95em;
            font-weight: 600;
            color: #111318;
            word-break: break-word;
            overflow-wrap: break-word;
            font-family: var(--mono);
        }
        .health-summary {
            display: flex;
            gap: 16px;
            margin-top: 12px;
            padding: 12px;
            background: #ffffff;
            border-radius: var(--radius);
            border: 1px solid #d5d8e0;
            color: #1a1d2b;
        }
        .health-summary strong { color: #222; }

        /* Status badges — always dark text on pastel, works on any background */
        .status-badge {
            display: inline-block;
            padding: 3px 10px;
            border-radius: 3px;
            font-weight: 700;
            font-size: 0.78em;
            text-transform: uppercase;
            letter-spacing: 0.06em;
            font-family: var(--mono);
            border: 1px solid rgba(0,0,0,0.12);
        }
        .status-badge.healthy, .status-badge.pass { background: #d4edda; color: #155724; }
        .status-badge.warning { background: #fff3cd; color: #856404; }
        .status-badge.info { background: #d1ecf1; color: #0c5460; }
        .status-badge.fail, .status-badge.critical { background: #f8d7da; color: #721c24; }
        .status-badge.no-access { background: #e2e3e5; color: #383d41; }

        /* Charts — light panel */
        .charts-container { padding: 16px 0; }
        .chart-wrapper {
            margin-bottom: 20px;
            background: #ffffff;
            padding: 18px;
            border: 1px solid #d5d8e0;
            border-radius: var(--radius);
            color: #1a1d2b;
        }
        .chart-wrapper h3 { color: #111318; margin-bottom: 12px; font-size: 1em; font-weight: 700; }
        .chart-wrapper div { color: #333; }
        .chart-wrapper strong { color: #111318; }
        .chart-canvas { max-height: 320px; background: #fafbfc; border-radius: 4px; padding: 4px; }

        /* Health check accordion — dark cards on light island */
        .health-checks { margin-top: 16px; }
        .health-check {
            margin-bottom: 8px;
            border: 1px solid #c8ccd6;
            border-radius: var(--radius);
            overflow: hidden;
        }
        .check-header {
            padding: 10px 14px;
            background: #ffffff;
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            transition: background 0.12s;
            color: #1a1d2b;
        }
        .check-header:hover { background: #f0f2f5; }
        .check-title { font-weight: 600; font-size: 0.88em; color: #1a1d2b; }
        .check-icon { font-size: 1.1em; margin-right: 8px; }
        .check-icon.pass { color: #1a8754; }
        .check-icon.fail { color: #c82333; }
        .check-icon.warning { color: #d39e00; }
        .check-icon.info { color: #138496; }
        .check-icon.unknown { color: #6c757d; }
        .check-details {
            padding: 14px;
            border-top: 1px solid #d5d8e0;
            background: #f5f6f9;
            display: none;
            color: #1a1d2b;
        }
        .check-details.expanded { display: block; }
        .check-message {
            margin-bottom: 10px;
            padding: 10px 12px;
            background: #ffffff;
            border-left: 3px solid #4a6cf7;
            border-radius: 3px;
            font-size: 0.85em;
            color: #333;
            font-family: var(--mono);
        }
        .detail-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
            gap: 8px;
        }
        .detail-item {
            background: #ffffff;
            padding: 8px 10px;
            border-radius: 3px;
            border: 1px solid #d5d8e0;
        }
        .detail-label {
            font-size: 0.72em;
            color: #6b7080;
            margin-bottom: 2px;
            text-transform: uppercase;
            letter-spacing: 0.06em;
        }
        .detail-value { font-weight: 600; color: #111318; font-size: 0.85em; font-family: var(--mono); }
        .legend {
            margin-top: 12px;
            padding: 10px;
            background: var(--bg-card);
            border-radius: var(--radius);
            font-size: 0.82em;
            border: 1px solid var(--border);
        }
        .legend h4 { margin-bottom: 6px; color: var(--accent); font-size: 0.85em; }
        .legend-item { margin: 3px 0; display: flex; align-items: center; color: var(--text-secondary); }
        .legend-marker {
            width: 18px;
            height: 3px;
            margin-right: 8px;
            display: inline-block;
        }
        .legend-marker.version {
            background: repeating-linear-gradient(90deg, #ff6384 0px, #ff6384 4px, transparent 4px, transparent 8px);
        }
        .legend-marker.restart { background: #ff9f40; }
        .footer {
            text-align: center;
            padding: 16px;
            background: var(--bg-card);
            color: var(--text-muted);
            font-size: 0.78em;
            border-top: 1px solid var(--border);
            font-family: var(--mono);
        }
        .footer a { color: var(--accent); text-decoration: none; }
        .footer a:hover { text-decoration: underline; }
        .check-name-header {
            height: 160px;
            white-space: nowrap;
            vertical-align: bottom;
            padding: 0 2px !important;
            position: relative;
            min-width: 26px;
            border-right: none !important;
        }
        .check-name-header > div {
            transform: rotate(-55deg);
            transform-origin: left bottom;
            position: absolute;
            bottom: 6px;
            left: 50%;
            width: 160px;
            text-align: left;
            padding-left: 4px;
            font-size: 0.9em;
        }
        .shard-group-header td {
            background: var(--bg-card) !important;
            color: var(--text-secondary) !important;
            border-top: 1px solid var(--border-light) !important;
            font-size: 0.82em !important;
            letter-spacing: 0.04em;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Operator Health Report</h1>
            <div class="subtitle">Generated on <span id="reportDate"></span> | Script version: <span id="scriptVersion">unknown</span></div>
        </div>

        <div class="summary-overview" id="summaryOverview"></div>

        <div class="operator-tabs" id="operatorTabs"></div>

        <div id="tabContents"></div>

        <div class="footer">
            Generated by CAMO/RMO Health Check System &bull;
            <a href="https://github.com/openshift/configure-alertmanager-operator" target="_blank">CAMO</a> &bull;
            <a href="https://github.com/openshift/route-monitor-operator" target="_blank">RMO</a>
        </div>
    </div>

    <script>
        document.getElementById('reportDate').textContent = new Date().toLocaleString();
        let healthDataRaw =
HTMLEOF

# Append the JSON data
echo "$json_data" >> "$OUTPUT_HTML"

# Append the rest of the HTML
cat >> "$OUTPUT_HTML" <<'HTMLEOF'
;

        let healthData = healthDataRaw;
        if (Array.isArray(healthDataRaw) && healthDataRaw.length === 1 && Array.isArray(healthDataRaw[0])) {
            healthData = healthDataRaw[0];
        }

        // Extract and display script version from first cluster's data
        if (healthData && healthData.length > 0 && healthData[0].script_version) {
            document.getElementById('scriptVersion').textContent = healthData[0].script_version;
        }

        function expandToCheck(clusterIdx, checkId) {
            const detailsRow = document.getElementById(`cluster-details-${clusterIdx}`);
            if (detailsRow && !detailsRow.classList.contains('expanded')) {
                toggleClusterDetails(clusterIdx);
            }
            setTimeout(() => {
                const checkHeader = document.querySelector(`[onclick*="toggleCheckDetails('${checkId}')"]`);
                if (checkHeader) {
                    const checkDetails = document.getElementById(`check-details-${checkId}`);
                    if (checkDetails && !checkDetails.classList.contains('expanded')) {
                        toggleCheckDetails(checkId);
                    }
                    checkHeader.scrollIntoView({ behavior: 'smooth', block: 'center' });
                }
            }, 150);
        }

        const chartsRendered = {};
        function toggleClusterDetails(clusterIdx) {
            const detailsRow = document.getElementById(`cluster-details-${clusterIdx}`);
            const mainRow = document.getElementById(`cluster-row-${clusterIdx}`);
            if (detailsRow && mainRow) {
                detailsRow.classList.toggle('expanded');
                mainRow.classList.toggle('expanded');
                // Render charts on first expand (Chart.js needs visible canvas)
                if (detailsRow.classList.contains('expanded') && !chartsRendered[clusterIdx]) {
                    chartsRendered[clusterIdx] = true;
                    const pendingCharts = detailsRow.querySelectorAll('[data-pending-chart]');
                    pendingCharts.forEach(el => {
                        const chartType = el.dataset.pendingChart;
                        const chartData = JSON.parse(el.dataset.chartData || '{}');
                        const restarts = JSON.parse(el.dataset.restartEvents || '[]');
                        const versions = JSON.parse(el.dataset.versionEvents || '[]');
                        setTimeout(() => {
                            if (chartType === 'memory') createMemoryChart(el.id, chartData, restarts, versions);
                            if (chartType === 'cpu') createCPUChart(el.id, chartData, restarts, versions);
                            if (chartType === 'probe') createProbeChart(el.id, chartData, restarts, versions);
                            if (chartType === 'duration') createDurationChart(el.id, chartData, restarts, versions);
                        }, 50);
                    });
                }
            }
        }

        function toggleCheckDetails(checkId) {
            const details = document.getElementById(`check-details-${checkId}`);
            if (details) {
                details.classList.toggle('expanded');
            }
        }

        function getStatusIcon(status) {
            return {
                'PASS': '✓',
                'FAIL': '✗',
                'WARNING': '⚠',
                'WARN': '⚠',
                'INFO': 'ℹ',
                'SKIP': '-',
                'UNKNOWN': '?',
                'NO_ACCESS': '🔒',
                'N/A': '-'
            }[status] || '?';
        }

        function getStatusClass(status) {
            return {
                'PASS': 'pass',
                'FAIL': 'fail',
                'WARNING': 'warning',
                'WARN': 'warning',
                'INFO': 'info',
                'SKIP': 'na',
                'UNKNOWN': 'unknown',
                'NO_ACCESS': 'no-access',
                'N/A': 'na'
            }[status] || 'na';
        }

        function getAllCheckTypes(data) {
            const sourceData = data || healthData;
            const checkTypes = new Set();
            sourceData.forEach(cluster => {
                (cluster.health_checks || []).forEach(check => {
                    checkTypes.add(check.check);
                });
            });

            // Define preferred order for checks
            const checkOrder = [
                'namespace_status',
                'version_verification',
                'pod_status_and_restarts',
                'leader_election',
                'resource_leak_detection',
                'resource_limits_validation',
                'log_error_analysis',
                // CAMO-specific checks grouped together
                'alertmanager_pods',
                'alertmanager_logs',
                'alertmanager_events',
                'camo_events',
                'alertmanager_statefulset',
                'controller_availability',
                'reconciliation_activity',
                'reconciliation_behavior',
                'configuration_errors',
                'prometheus_metrics',
                'alertmanager_secret',
                'camo_configmap',
                'pagerduty_secret',
                'pko_job_health',
                'image_pull_status',
                'orphaned_resources',
                // RMO-specific checks
                'rmo_controller_manager',
                'rmo_blackbox_exporter',
                'rmo_routemonitor_status',
                'rmo_probe_health',
                'rmo_servicemonitor_health',
                'rmo_prometheusrule_health',
                'rmo_operator_metrics',
                'rmo_config',
                'rmo_hcp_coverage',
                'rmo_rhobs_integration'
            ];

            const checksArray = Array.from(checkTypes);
            return checksArray.sort((a, b) => {
                const aIdx = checkOrder.indexOf(a);
                const bIdx = checkOrder.indexOf(b);
                if (aIdx !== -1 && bIdx !== -1) return aIdx - bIdx;
                if (aIdx !== -1) return -1;
                if (bIdx !== -1) return 1;
                return a.localeCompare(b);
            });
        }

        function getCheckStatus(cluster, checkType) {
            const check = (cluster.health_checks || []).find(c => c.check === checkType);
            return check ? check.status : 'N/A';
        }

        // Resource thresholds based on 29 version-matched staging clusters
        // CPU: Min 0.3m, Max 0.4m, Avg 0.4m, Median 0.4m
        // Memory: Min 33.0 MB, Max 44.4 MB, Avg 38.0 MB, Median 37.4 MB
        const CPU_WARNING_THRESHOLD = 1.0;  // millicores
        const CPU_ERROR_THRESHOLD = 5.0;    // millicores
        const MEM_WARNING_THRESHOLD = 60;    // MB
        const MEM_ERROR_THRESHOLD = 100;     // MB

        function getResourceValues(cluster) {
            const resourceCheck = (cluster.health_checks || []).find(c => c.check === 'resource_leak_detection');
            if (!resourceCheck || !resourceCheck.details) {
                return {
                    cpu: 'N/A',
                    memory: 'N/A',
                    cpuLevel: 'normal',
                    memLevel: 'normal'
                };
            }
            const details = resourceCheck.details;
            const memTimeseries = details.memory_timeseries || [];
            const cpuTimeseries = details.cpu_timeseries || [];

            let cpuValue = 0;
            let memValue = 0;
            let cpuText = 'N/A';
            let memText = 'N/A';
            let cpuLevel = 'normal';
            let memLevel = 'normal';

            if (cpuTimeseries.length > 0) {
                cpuValue = parseFloat(cpuTimeseries[cpuTimeseries.length - 1][1]) * 1000;
                cpuText = cpuValue.toFixed(1) + 'm';
                if (cpuValue > CPU_ERROR_THRESHOLD) {
                    cpuLevel = 'error';
                } else if (cpuValue > CPU_WARNING_THRESHOLD) {
                    cpuLevel = 'warning';
                }
            }

            if (memTimeseries.length > 0) {
                memValue = parseFloat(memTimeseries[memTimeseries.length - 1][1]) / 1048576;
                memText = memValue.toFixed(1) + ' MB';
                if (memValue > MEM_ERROR_THRESHOLD) {
                    memLevel = 'error';
                } else if (memValue > MEM_WARNING_THRESHOLD) {
                    memLevel = 'warning';
                }
            }

            return {
                cpu: cpuText,
                memory: memText,
                cpuLevel: cpuLevel,
                memLevel: memLevel
            };
        }

        function getPodRestarts(cluster) {
            const podCheck = (cluster.health_checks || []).find(c => c.check === 'pod_status_and_restarts');
            if (!podCheck || !podCheck.details) {
                return 'N/A';
            }
            return podCheck.details.total_restarts || 0;
        }

        function getLogErrors(cluster) {
            const logCheck = (cluster.health_checks || []).find(c => c.check === 'log_error_analysis');
            if (!logCheck || !logCheck.details) {
                return 'N/A';
            }
            return logCheck.details.error_count || 0;
        }

        function getLogWarnings(cluster) {
            const logCheck = (cluster.health_checks || []).find(c => c.check === 'log_error_analysis');
            if (!logCheck || !logCheck.details) {
                return 'N/A';
            }
            return logCheck.details.warning_count || 0;
        }

        function formatCheckName(checkName) {
            // Custom names for specific checks
            const customNames = {
                'alertmanager_pods': 'AM Pods',
                'alertmanager_logs': 'AM Logs',
                'alertmanager_events': 'AM Events',
                'camo_events': 'CAMO Events',
                'alertmanager_statefulset': 'AM StatefulSet',
                'controller_availability': 'Controller',
                'reconciliation_activity': 'Reconciliation',
                'reconciliation_behavior': 'Recon Behavior',
                'configuration_errors': 'Config Errors',
                'prometheus_metrics': 'Metrics',
                'alertmanager_secret': 'AM Secret',
                'camo_configmap': 'CAMO Config',
                'pagerduty_secret': 'PD Secret',
                'version_verification': 'Version',
                'pod_status_and_restarts': 'Pod Status',
                'resource_leak_detection': 'Resources',
                'resource_limits_validation': 'Limits',
                'leader_election': 'Leader',
                'namespace_status': 'Namespace',
                'pko_job_health': 'PKO Jobs',
                'image_pull_status': 'Image Pull',
                'orphaned_resources': 'Orphans',
                'rmo_controller_manager': 'RMO Controller',
                'rmo_blackbox_exporter': 'Blackbox',
                'rmo_routemonitor_status': 'RouteMonitors',
                'rmo_probe_health': 'Probes',
                'rmo_servicemonitor_health': 'SvcMonitors',
                'rmo_prometheusrule_health': 'PromRules',
                'rmo_operator_metrics': 'RMO Metrics',
                'rmo_config': 'RMO Config',
                'rmo_hcp_coverage': 'HCP Coverage',
                'rmo_rhobs_integration': 'RHOBS',
                'log_error_analysis': 'Log Analysis'
            };

            if (customNames[checkName]) {
                return customNames[checkName];
            }
            return checkName.replace(/_/g, ' ').split(' ').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
        }

        function getThresholdPanel(checkType, cluster) {
            const op = cluster?.operator_name || '';
            const isRMO = op.includes('route-monitor');
            const rmCheck = (cluster?.health_checks || []).find(c => c.check === 'rmo_routemonitor_status');
            const monitorCount = rmCheck ? ((rmCheck.details?.routemonitor_count || 0) + (rmCheck.details?.clusterurlmonitor_count || 0)) : 0;
            const clusterType = cluster?.cluster_type || 'standard';

            const thresholds = {
                'resource_leak_detection': isRMO ?
                    '<div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">' +
                    '<strong style="color: #667eea; display: block; margin-bottom: 8px;">RMO Resource Context (' + monitorCount + ' monitors, ' + clusterType.replace('_', ' ') + '):</strong>' +
                    '<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">' +
                    '<div><strong>Expected Memory by Type:</strong>' +
                    '<div style="margin-left: 10px;">Standard (0 monitors): ~20-26 MB</div>' +
                    '<div style="margin-left: 10px;">SC (2 monitors): ~28-88 MB</div>' +
                    '<div style="margin-left: 10px;">MC (1-3 HCPs): ~60-200 MB</div>' +
                    '<div style="margin-left: 10px;">MC (6-10 HCPs): ~225-460 MB</div></div>' +
                    '<div><strong>Memory per Monitor:</strong>' +
                    '<div style="margin-left: 10px;">~20 MB base + ~25-30 MB per HCP RouteMonitor</div>' +
                    '<div style="margin-left: 10px;">Current: ' + (cluster?.health_checks?.find(c => c.check === 'resource_leak_detection')?.details?.peak_memory_mb || '?') + ' MB peak</div>' +
                    (monitorCount > 0 ? '<div style="margin-left: 10px;">Per-monitor: ~' + ((cluster?.health_checks?.find(c => c.check === 'resource_leak_detection')?.details?.peak_memory_mb || 0) / Math.max(monitorCount, 1)).toFixed(0) + ' MB/monitor</div>' : '') +
                    '</div></div></div>'
                    :
                    '<div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">' +
                    '<strong style="color: #667eea; display: block; margin-bottom: 8px;">CAMO Pod Resource Thresholds:</strong>' +
                    '<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">' +
                    '<div><strong>CPU:</strong>' +
                    '<div style="color: #28a745; margin-left: 10px;">✓ Normal: &lt; 1.0m</div>' +
                    '<div style="color: #ffc107; margin-left: 10px;">⚠ Warning: 1.0m - 5.0m</div>' +
                    '<div style="color: #dc3545; margin-left: 10px;">✗ Error: &gt; 5.0m</div></div>' +
                    '<div><strong>Memory:</strong>' +
                    '<div style="color: #28a745; margin-left: 10px;">✓ Normal: &lt; 60 MB</div>' +
                    '<div style="color: #ffc107; margin-left: 10px;">⚠ Warning: 60 - 100 MB</div>' +
                    '<div style="color: #dc3545; margin-left: 10px;">✗ Error: &gt; 100 MB</div></div>' +
                    '</div></div>',
                'reconciliation_behavior': '<div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">' +
                    '<strong style="color: #667eea; display: block; margin-bottom: 8px;">Reconciliation Thresholds:</strong>' +
                    '<div style="color: #28a745; margin-left: 10px;">✓ Normal Rate: &lt; 10x per change</div>' +
                    '<div style="color: #ffc107; margin-left: 10px;">⚠ High Rate: &gt; 10x per change</div>' +
                    '<div style="color: #dc3545; margin-left: 10px;">✗ Loop Detected: &gt; 20 w/o changes</div>' +
                    '</div>',
                'log_error_analysis': '<div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">' +
                    '<strong style="color: #667eea; display: block; margin-bottom: 8px;">CAMO Log Thresholds:</strong>' +
                    '<div style="color: #28a745; margin-left: 10px;">✓ Normal: 0 errors</div>' +
                    '<div style="color: #ffc107; margin-left: 10px;">⚠ Warning: &gt; 0 errors</div>' +
                    '</div>',
                'pod_status_and_restarts': '<div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">' +
                    '<strong style="color: #667eea; display: block; margin-bottom: 8px;">CAMO Pod Restart Thresholds:</strong>' +
                    '<div style="color: #28a745; margin-left: 10px;">✓ Normal: ≤ 3 restarts</div>' +
                    '<div style="color: #ffc107; margin-left: 10px;">⚠ Warning: 4-10 restarts</div>' +
                    '<div style="color: #dc3545; margin-left: 10px;">✗ Error: &gt; 10 restarts</div>' +
                    '</div>',
                'alertmanager_pods': '<div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">' +
                    '<strong style="color: #667eea; display: block; margin-bottom: 8px;">AlertManager Pod Restart Analysis:</strong>' +
                    '<div style="color: #28a745; margin-left: 10px;">✓ Normal: Restarts pre-date current CAMO version, OR ≤ 3 recent restarts</div>' +
                    '<div style="color: #ffc107; margin-left: 10px;">⚠ Warning: &gt; 3 restarts AFTER current CAMO deployed (&lt; 24h ago)</div>' +
                    '<div style="color: #dc3545; margin-left: 10px;">✗ Error: Pods currently not ready</div>' +
                    '<div style="margin-top: 8px; padding: 8px; background: #fff; border-radius: 3px;">' +
                    '<strong>Key Insight:</strong> Only restarts happening AFTER the current CAMO operator version was deployed indicate a potential CAMO-related issue. ' +
                    'Historical restarts (before current CAMO pod creation) are not relevant to current CAMO health.<br/><br/>' +
                    '<strong>Restart Exit Codes:</strong><br/>' +
                    '• OOMKilled = Memory limit exceeded<br/>' +
                    '• Error/CrashLoopBackOff = Application crash<br/>' +
                    '• Completed = Normal termination (upgrade)<br/>' +
                    '• Evicted = Node resource pressure' +
                    '</div></div>',
                'alertmanager_logs': '<div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">' +
                    '<strong style="color: #667eea; display: block; margin-bottom: 8px;">AlertManager Log Thresholds:</strong>' +
                    '<div style="color: #28a745; margin-left: 10px;">✓ Normal: 0 errors, 0 warnings</div>' +
                    '<div style="color: #ffc107; margin-left: 10px;">⚠ Warning: &gt; 0 errors</div>' +
                    '</div>',
                'alertmanager_events': '<div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">' +
                    '<strong style="color: #667eea; display: block; margin-bottom: 8px;">AlertManager Event Thresholds:</strong>' +
                    '<div style="color: #28a745; margin-left: 10px;">✓ Normal: 0 warning events</div>' +
                    '<div style="color: #ffc107; margin-left: 10px;">⚠ Warning: &gt; 0 warning events</div>' +
                    '</div>',
                'camo_events': '<div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">' +
                    '<strong style="color: #667eea; display: block; margin-bottom: 8px;">CAMO Event Thresholds:</strong>' +
                    '<div style="color: #28a745; margin-left: 10px;">✓ Normal: 0 warning events</div>' +
                    '<div style="color: #ffc107; margin-left: 10px;">⚠ Warning: &gt; 0 warning events</div>' +
                    '</div>'
            };

            return thresholds[checkType] || '';
        }

        function filterEventsToRange(events, minTs, maxTs) {
            if (!events) return [];
            return events.filter(e => (e.timestamp * 1000) >= minTs && (e.timestamp * 1000) <= maxTs);
        }

        function addEventAnnotations(annotations, versionEvents, restartEvents, minTs, maxTs) {
            const clippedVersions = filterEventsToRange(versionEvents, minTs, maxTs);
            const clippedRestarts = filterEventsToRange(restartEvents, minTs, maxTs);
            clippedVersions.forEach((event, idx) => {
                annotations[`version${idx}`] = {
                    type: 'line',
                    xMin: event.timestamp * 1000, xMax: event.timestamp * 1000,
                    borderColor: '#ff6384', borderWidth: 2, borderDash: [5, 5],
                    label: { content: `v${event.version}`, enabled: true, position: 'top' }
                };
            });
            clippedRestarts.forEach((event, idx) => {
                annotations[`restart${idx}`] = {
                    type: 'line',
                    xMin: event.timestamp * 1000, xMax: event.timestamp * 1000,
                    borderColor: '#ff9f40', borderWidth: 2,
                    label: { content: 'Restart', enabled: true, position: 'bottom' }
                };
            });
        }

        function createMemoryChart(canvasId, data, restartEvents, versionEvents) {
            const ctx = document.getElementById(canvasId);
            if (!ctx) return;
            const memoryData = data.memory_timeseries || [];
            if (memoryData.length === 0) return;

            const timestamps = memoryData.map(point => point[0] * 1000);
            const values = memoryData.map(point => parseFloat(point[1]) / 1048576);
            const annotations = {};
            const minTs = Math.min(...timestamps);
            const maxTs = Math.max(...timestamps);
            addEventAnnotations(annotations, versionEvents, restartEvents, minTs, maxTs);

            const chartData = timestamps.map((time, idx) => ({ x: time, y: values[idx] }));

            new Chart(ctx, {
                type: 'line',
                data: {
                    datasets: [{
                        label: 'Memory Usage (MB)',
                        data: chartData,
                        borderColor: '#36a2eb',
                        backgroundColor: 'rgba(54, 162, 235, 0.1)',
                        tension: 0.4,
                        fill: true,
                        pointRadius: 2,
                        pointHoverRadius: 4
                    }, {
                        label: '--- Version Update (pod restart)',
                        data: [],
                        borderColor: '#ff6384',
                        borderDash: [5, 5],
                        pointRadius: 0
                    }, {
                        label: '— Abnormal Restart',
                        data: [],
                        borderColor: '#ff9f40',
                        pointRadius: 0
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: true,
                    plugins: {
                        legend: { display: true, position: 'top' },
                        tooltip: {
                            mode: 'index',
                            intersect: false,
                            callbacks: {
                                title: ctx => new Date(ctx[0].parsed.x).toLocaleString(),
                                label: ctx => `Memory: ${ctx.parsed.y.toFixed(2)} MB`
                            }
                        },
                        annotation: { annotations }
                    },
                    scales: {
                        x: {
                            type: 'time',
                            time: { unit: 'hour', displayFormats: { hour: 'MMM d, HH:mm' } },
                            title: { display: true, text: 'Time' }
                        },
                        y: {
                            beginAtZero: false,
                            title: { display: true, text: 'Memory (MB)' }
                        }
                    }
                }
            });
        }

        function createCPUChart(canvasId, data, restartEvents, versionEvents) {
            const ctx = document.getElementById(canvasId);
            if (!ctx) return;
            const cpuData = data.cpu_timeseries || [];
            if (cpuData.length === 0) return;

            const timestamps = cpuData.map(point => point[0] * 1000);
            const values = cpuData.map(point => parseFloat(point[1]) * 1000);
            const annotations = {};
            const minTs = Math.min(...timestamps);
            const maxTs = Math.max(...timestamps);
            addEventAnnotations(annotations, versionEvents, restartEvents, minTs, maxTs);

            const chartData = timestamps.map((time, idx) => ({ x: time, y: values[idx] }));

            new Chart(ctx, {
                type: 'line',
                data: {
                    datasets: [{
                        label: 'CPU Usage (millicores)',
                        data: chartData,
                        borderColor: '#4bc0c0',
                        backgroundColor: 'rgba(75, 192, 192, 0.1)',
                        tension: 0.4,
                        fill: true,
                        pointRadius: 2,
                        pointHoverRadius: 4
                    }, {
                        label: '--- Version Update (pod restart)',
                        data: [],
                        borderColor: '#ff6384',
                        borderDash: [5, 5],
                        pointRadius: 0
                    }, {
                        label: '— Abnormal Restart',
                        data: [],
                        borderColor: '#ff9f40',
                        pointRadius: 0
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: true,
                    plugins: {
                        legend: { display: true, position: 'top' },
                        tooltip: {
                            mode: 'index',
                            intersect: false,
                            callbacks: {
                                title: ctx => new Date(ctx[0].parsed.x).toLocaleString(),
                                label: ctx => `CPU: ${ctx.parsed.y.toFixed(0)}m`
                            }
                        },
                        annotation: { annotations }
                    },
                    scales: {
                        x: {
                            type: 'time',
                            time: { unit: 'hour', displayFormats: { hour: 'MMM d, HH:mm' } },
                            title: { display: true, text: 'Time' }
                        },
                        y: {
                            beginAtZero: false,
                            title: { display: true, text: 'CPU (millicores)' }
                        }
                    }
                }
            });
        }

        function createProbeChart(canvasId, data, restartEvents, versionEvents) {
            const ctx = document.getElementById(canvasId);
            if (!ctx) return;
            const probeData = data.probe_timeseries || [];
            if (probeData.length === 0) return;

            const timestamps = probeData.map(point => point[0] * 1000);
            const values = probeData.map(point => parseFloat(point[1]) * 100);
            const annotations = {};
            const minTs = Math.min(...timestamps);
            const maxTs = Math.max(...timestamps);
            addEventAnnotations(annotations, versionEvents, restartEvents, minTs, maxTs);

            const chartData = timestamps.map((time, idx) => ({ x: time, y: values[idx] }));
            new Chart(ctx, {
                type: 'line',
                data: {
                    datasets: [{
                        label: 'Probe Success Rate (%)',
                        data: chartData,
                        borderColor: '#28a745',
                        backgroundColor: 'rgba(40, 167, 69, 0.1)',
                        tension: 0.4, fill: true, pointRadius: 2, pointHoverRadius: 4
                    }, {
                        label: '--- Version Update (pod restart)',
                        data: [],
                        borderColor: '#ff6384',
                        borderDash: [5, 5],
                        pointRadius: 0
                    }]
                },
                options: {
                    responsive: true, maintainAspectRatio: true,
                    plugins: {
                        legend: { display: true, position: 'top' },
                        tooltip: {
                            mode: 'index', intersect: false,
                            callbacks: {
                                title: ctx => new Date(ctx[0].parsed.x).toLocaleString(),
                                label: ctx => `Success: ${ctx.parsed.y.toFixed(1)}%`
                            }
                        },
                        annotation: { annotations }
                    },
                    scales: {
                        x: { type: 'time', time: { unit: 'hour', displayFormats: { hour: 'MMM d, HH:mm' } }, title: { display: true, text: 'Time' } },
                        y: { min: 0, max: 100, title: { display: true, text: 'Success Rate (%)' } }
                    }
                }
            });
        }

        function createDurationChart(canvasId, data, restartEvents, versionEvents) {
            const ctx = document.getElementById(canvasId);
            if (!ctx) return;
            const durationData = data.probe_duration_timeseries || [];
            if (durationData.length === 0) return;

            const timestamps = durationData.map(point => point[0] * 1000);
            const values = durationData.map(point => parseFloat(point[1]) * 1000);
            const annotations = {};
            const minTs = Math.min(...timestamps);
            const maxTs = Math.max(...timestamps);
            addEventAnnotations(annotations, versionEvents, restartEvents, minTs, maxTs);

            const chartData = timestamps.map((time, idx) => ({ x: time, y: values[idx] }));
            new Chart(ctx, {
                type: 'line',
                data: {
                    datasets: [{
                        label: 'Avg Probe Duration (ms)',
                        data: chartData,
                        borderColor: '#e67e22',
                        backgroundColor: 'rgba(230, 126, 34, 0.1)',
                        tension: 0.4, fill: true, pointRadius: 2, pointHoverRadius: 4
                    }, {
                        label: '--- Version Update (pod restart)',
                        data: [],
                        borderColor: '#ff6384',
                        borderDash: [5, 5],
                        pointRadius: 0
                    }]
                },
                options: {
                    responsive: true, maintainAspectRatio: true,
                    plugins: {
                        legend: { display: true, position: 'top' },
                        tooltip: {
                            mode: 'index', intersect: false,
                            callbacks: {
                                title: ctx => new Date(ctx[0].parsed.x).toLocaleString(),
                                label: ctx => `Duration: ${ctx.parsed.y.toFixed(1)} ms`
                            }
                        },
                        annotation: { annotations }
                    },
                    scales: {
                        x: { type: 'time', time: { unit: 'hour', displayFormats: { hour: 'MMM d, HH:mm' } }, title: { display: true, text: 'Time' } },
                        y: { beginAtZero: true, title: { display: true, text: 'Duration (ms)' } }
                    }
                }
            });
        }

        function generateClusterDetails(cluster, clusterIdx) {
            const detailsDiv = document.createElement('div');
            detailsDiv.className = 'cluster-section';

            // Header
            const header = document.createElement('div');
            header.className = 'cluster-header';
            const summary = cluster.health_summary || {};
            const overallStatus = summary.overall_status || 'UNKNOWN';
            const statusClass = overallStatus === 'NO_ACCESS' ? 'no-access' :
                               (summary.critical_count > 0 ? 'critical' :
                               (summary.warning_count > 0 ? 'warning' : 'healthy'));

            header.innerHTML = `
                <h2>${cluster.cluster_name || 'Unknown Cluster'}</h2>
                <div class="cluster-meta">
                    <div class="meta-item">
                        <div class="meta-label">Cluster ID</div>
                        <div class="meta-value">${cluster.cluster_id || 'N/A'}</div>
                    </div>
                    <div class="meta-item">
                        <div class="meta-label">Type</div>
                        <div class="meta-value">${(cluster.cluster_type || 'standard').replace('_', ' ').replace(/\\b\\w/g, l => l.toUpperCase())}</div>
                    </div>
                    <div class="meta-item">
                        <div class="meta-label">Operator</div>
                        <div class="meta-value">${cluster.operator_name || 'N/A'}</div>
                    </div>
                    <div class="meta-item">
                        <div class="meta-label">Version</div>
                        <div class="meta-value">${cluster.operator_version || 'unknown'}</div>
                    </div>
                    <div class="meta-item">
                        <div class="meta-label">Hive Shard</div>
                        <div class="meta-value">${cluster.hive_shard || (cluster.health_checks || []).find(c => c.check === 'version_verification')?.details?.target_name || 'N/A'}</div>
                    </div>
                    <div class="meta-item">
                        <div class="meta-label">Timestamp</div>
                        <div class="meta-value">${cluster.timestamp || 'N/A'}</div>
                    </div>
                </div>
                <div class="health-summary">
                    <div>
                        <strong>Overall Status:</strong>
                        <span class="status-badge ${statusClass}">${summary.overall_status || 'UNKNOWN'}</span>
                    </div>
                    <div><strong>Critical Issues:</strong> ${summary.critical_count || 0}</div>
                    <div><strong>Warnings:</strong> ${summary.warning_count || 0}</div>
                </div>
                ${cluster.cluster_metadata && Object.keys(cluster.cluster_metadata).length > 0 ? `
                    <div class="cluster-summary" style="margin-top: 20px; padding: 15px; background: #f8f9fa; border-left: 4px solid #667eea; border-radius: 4px;">
                        <h4 style="margin: 0 0 15px 0; color: #667eea; font-size: 1em;">Cluster Summary</h4>
                        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; font-size: 0.9em;">
                            <div style="grid-column: 1 / -1;"><strong>ID:</strong> <code style="font-size: 0.85em; background: #fff; padding: 2px 6px; border-radius: 3px; word-break: break-all;">${cluster.cluster_metadata.id || 'N/A'}</code></div>
                            <div style="grid-column: 1 / -1;"><strong>External ID:</strong> <code style="font-size: 0.85em; background: #fff; padding: 2px 6px; border-radius: 3px; word-break: break-all;">${cluster.cluster_metadata.external_id || 'N/A'}</code></div>
                            <div><strong>Name:</strong> ${cluster.cluster_metadata.name || 'N/A'}</div>
                            <div><strong>State:</strong> <span style="color: ${cluster.cluster_metadata.state === 'ready' ? '#28a745' : '#ffc107'};">${cluster.cluster_metadata.state || 'N/A'}</span></div>
                            <div><strong>API Listening:</strong> ${cluster.cluster_metadata.api_listening || 'N/A'}</div>
                            <div><strong>Product:</strong> ${cluster.cluster_metadata.product || 'N/A'}</div>
                            <div><strong>Provider:</strong> ${cluster.cluster_metadata.provider || 'N/A'}</div>
                            <div><strong>Version:</strong> ${cluster.cluster_metadata.version || 'N/A'}</div>
                            <div><strong>Region:</strong> ${cluster.cluster_metadata.region || 'N/A'}</div>
                            <div><strong>Multi-AZ:</strong> ${cluster.cluster_metadata.multi_az ? '✓ Yes' : '✗ No'}</div>
                            <div><strong>CNI Type:</strong> ${cluster.cluster_metadata.cni_type || 'N/A'}</div>
                            <div><strong>PrivateLink:</strong> ${cluster.cluster_metadata.privatelink ? '✓ Yes' : '✗ No'}</div>
                            <div><strong>STS:</strong> ${cluster.cluster_metadata.sts ? '✓ Yes' : '✗ No'}</div>
                            <div><strong>CCS:</strong> ${cluster.cluster_metadata.ccs ? '✓ Yes' : '✗ No'}</div>
                            <div><strong>HCP:</strong> ${cluster.cluster_metadata.hypershift ? '✓ Yes' : '✗ No'}</div>
                            <div><strong>Existing VPC:</strong> ${cluster.cluster_metadata.existing_vpc ? '✓ Yes' : '✗ No'}</div>
                            <div><strong>Channel Group:</strong> ${cluster.cluster_metadata.channel_group || 'N/A'}</div>
                            <div style="grid-column: 1 / -1;"><strong>Limited Support:</strong> ${cluster.cluster_metadata.limited_support ? '<span style="color: #dc3545;">⚠ Yes</span>' : '✓ No'}</div>
                            ${cluster.cluster_metadata.limited_support && cluster.cluster_metadata.limited_support_reasons && cluster.cluster_metadata.limited_support_reasons.length > 0 ? `
                                <div style="grid-column: 1 / -1; margin-top: 8px; padding: 12px; background: #fff3cd; border-left: 4px solid #ffc107; border-radius: 4px;">
                                    <strong style="color: #856404;">Limited Support Reasons:</strong>
                                    ${cluster.cluster_metadata.limited_support_reasons.map((reason, idx) => `
                                        <div style="margin-top: ${idx > 0 ? '12px' : '8px'}; padding: 10px; background: #fff; border: 1px solid #ffeeba; border-radius: 4px;">
                                            <div style="font-weight: 600; color: #856404; margin-bottom: 6px;">${reason.summary || 'No summary available'}</div>
                                            ${reason.details ? `<div style="font-size: 0.9em; color: #6c757d; margin-bottom: 6px;">${reason.details}</div>` : ''}
                                            ${reason.created ? `<div style="font-size: 0.85em; color: #999;">Created: ${new Date(reason.created).toLocaleString()}</div>` : ''}
                                        </div>
                                    `).join('')}
                                </div>
                            ` : ''}
                            <div style="grid-column: 1 / -1;"><strong>Shard:</strong> <code style="font-size: 0.85em; background: #fff; padding: 2px 6px; border-radius: 3px; word-break: break-all;">${cluster.cluster_metadata.shard || 'N/A'}</code></div>
                        </div>
                    </div>
                ` : ''}
                ${cluster.backplane_login ? `
                    <div class="backplane-login-status" style="margin-top: 15px; padding: 12px; background: ${cluster.backplane_login.status === 'SUCCESS' ? '#d4edda' : '#f8d7da'}; border-left: 4px solid ${cluster.backplane_login.status === 'SUCCESS' ? '#28a745' : '#dc3545'}; border-radius: 4px;">
                        <strong style="color: ${cluster.backplane_login.status === 'SUCCESS' ? '#155724' : '#721c24'};">Backplane Login:</strong>
                        <span style="margin-left: 10px;">${cluster.backplane_login.status === 'SUCCESS' ? '✓ SUCCESS' : '✗ FAILED (Exit Code: ' + cluster.backplane_login.exit_code + ')'}</span>
                        ${cluster.backplane_login.status === 'FAILED' && cluster.backplane_login.error_message ? `
                            <details style="margin-top: 10px;">
                                <summary style="cursor: pointer; font-weight: 500; color: #721c24;">Show Error Details</summary>
                                <pre style="margin-top: 8px; padding: 10px; background: #fff; border: 1px solid #f5c6cb; border-radius: 4px; font-size: 0.85em; overflow-x: auto; white-space: pre-wrap; word-break: break-all;">${cluster.backplane_login.error_message}</pre>
                            </details>
                        ` : ''}
                    </div>
                ` : ''}
                ${cluster.api_errors && cluster.api_errors.length > 0 ? `
                    <div class="api-errors-status" style="margin-top: 15px; padding: 12px; background: #fff3cd; border-left: 4px solid #f57c00; border-radius: 4px;">
                        <strong style="color: #856404;">⚠ API Request Errors (${cluster.api_errors.length}):</strong>
                        <details style="margin-top: 10px;">
                            <summary style="cursor: pointer; font-weight: 500; color: #856404;">Show API Error Details</summary>
                            <div style="margin-top: 10px;">
                                ${cluster.api_errors.map(err => `
                                    <div style="margin-bottom: 15px; padding: 10px; background: #fff; border: 1px solid #ffeaa7; border-radius: 4px;">
                                        <div style="font-weight: 600; color: #856404; margin-bottom: 5px;">
                                            ${err.operation || 'Unknown operation'}
                                            <span style="float: right; font-size: 0.9em; color: #6c757d;">${err.timestamp || ''}</span>
                                        </div>
                                        <div style="font-size: 0.9em; color: #dc3545; margin-bottom: 5px;">
                                            Exit Code: ${err.exit_code || 'unknown'}
                                        </div>
                                        <pre style="margin: 0; padding: 8px; background: #f8f9fa; border: 1px solid #dee2e6; border-radius: 4px; font-size: 0.85em; overflow-x: auto; white-space: pre-wrap; word-break: break-all;">${err.error_message || 'No error message available'}</pre>
                                    </div>
                                `).join('')}
                            </div>
                        </details>
                    </div>
                ` : ''}
                <div class="health-thresholds" style="margin-top: 15px; padding: 15px; background: #e7f3ff; border-left: 4px solid #667eea; border-radius: 4px;">
                    <h4 style="margin: 0 0 10px 0; color: #667eea; font-size: 0.95em;">Health Check Thresholds</h4>
                    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 10px; font-size: 0.85em;">
                        <div>
                            <strong>CPU:</strong>
                            <div style="color: #28a745;">✓ Normal: &lt; 1.0m</div>
                            <div style="color: #ffc107;">⚠ Warning: 1.0m - 5.0m</div>
                            <div style="color: #dc3545;">✗ Error: &gt; 5.0m</div>
                        </div>
                        <div>
                            <strong>Memory:</strong>
                            <div style="color: #28a745;">✓ Normal: &lt; 60 MB</div>
                            <div style="color: #ffc107;">⚠ Warning: 60 - 100 MB</div>
                            <div style="color: #dc3545;">✗ Error: &gt; 100 MB</div>
                        </div>
                        <div>
                            <strong>Reconciliation:</strong>
                            <div style="color: #28a745;">✓ Rate: &lt; 10x per change</div>
                            <div style="color: #ffc107;">⚠ High: &gt; 10x per change</div>
                            <div style="color: #dc3545;">✗ Loop: &gt; 20 w/o changes</div>
                        </div>
                        <div>
                            <strong>Logs:</strong>
                            <div style="color: #28a745;">✓ Errors: 0</div>
                            <div style="color: #ffc107;">⚠ Warning: &gt; 0 errors</div>
                        </div>
                    </div>
                </div>
            `;
            detailsDiv.appendChild(header);

            // Charts
            const chartsDiv = document.createElement('div');
            chartsDiv.className = 'charts-container';
            const resourceCheck = (cluster.health_checks || []).find(c => c.check === 'resource_leak_detection');

            if (resourceCheck && resourceCheck.details) {
                const details = resourceCheck.details;
                const restartEvents = cluster.events && cluster.events.pod_restarts ? cluster.events.pod_restarts : [];
                const versionEvents = cluster.events && cluster.events.version_changes ? cluster.events.version_changes : [];

                const ns = cluster.namespace || 'unknown';
                const deploy = cluster.deployment || 'unknown';
                const containerName = details.container_name || deploy;
                const podName = details.pod_name || deploy + '-*';

                if (details.memory_timeseries && details.memory_timeseries.length > 0) {
                    const memoryChartDiv = document.createElement('div');
                    memoryChartDiv.className = 'chart-wrapper';
                    memoryChartDiv.innerHTML = `
                        <h3>${cluster.operator_name || 'Operator'} Memory Usage Over Time</h3>
                        <canvas id="memory-chart-${clusterIdx}" class="chart-canvas"
                            data-pending-chart="memory"
                            data-chart-data='${JSON.stringify(details).replace(/'/g, "&#39;")}'
                            data-restart-events='${JSON.stringify(restartEvents).replace(/'/g, "&#39;")}'
                            data-version-events='${JSON.stringify(versionEvents).replace(/'/g, "&#39;")}'
                        ></canvas>
                        <div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">
                            ${cluster.operator_name?.includes('route-monitor') ?
                            `<strong style="color: #667eea; display: block; margin-bottom: 8px;">RMO Memory Context (${(cluster.health_checks?.find(c => c.check === 'rmo_routemonitor_status')?.details?.routemonitor_count || 0) + (cluster.health_checks?.find(c => c.check === 'rmo_routemonitor_status')?.details?.clusterurlmonitor_count || 0)} monitors):</strong>
                            <div style="margin-left: 10px;">Base: ~20 MB | Per HCP monitor: ~25-30 MB</div>
                            <div style="margin-left: 10px;">Peak: ${details.peak_memory_mb || '?'} MB | Limit: ${cluster.health_checks?.find(c => c.check === 'resource_limits_validation')?.details?.limits_memory || '1000Mi'}</div>`
                            :
                            `<strong style="color: #667eea; display: block; margin-bottom: 8px;">Memory Thresholds:</strong>
                            <div style="color: #28a745; margin-left: 10px;">✓ Normal: &lt; 60 MB</div>
                            <div style="color: #ffc107; margin-left: 10px;">⚠ Warning: 60 - 100 MB</div>
                            <div style="color: #dc3545; margin-left: 10px;">✗ Error: &gt; 100 MB</div>`}
                        </div>
                        <div style="margin-top: 8px; padding: 8px 12px; background: #eef0f4; border-radius: 4px; font-family: monospace; font-size: 0.75em; color: #333; word-break: break-all;">
                            <strong>Query:</strong> container_memory_working_set_bytes{namespace="${ns}", pod=~"${deploy}-.*", container="${containerName}"}
                        </div>
                    `;
                    chartsDiv.appendChild(memoryChartDiv);
                }

                if (details.cpu_timeseries && details.cpu_timeseries.length > 0) {
                    const cpuChartDiv = document.createElement('div');
                    cpuChartDiv.className = 'chart-wrapper';
                    cpuChartDiv.innerHTML = `
                        <h3>${cluster.operator_name || 'Operator'} CPU Usage Over Time</h3>
                        <canvas id="cpu-chart-${clusterIdx}" class="chart-canvas"
                            data-pending-chart="cpu"
                            data-chart-data='${JSON.stringify(details).replace(/'/g, "&#39;")}'
                            data-restart-events='${JSON.stringify(restartEvents).replace(/'/g, "&#39;")}'
                            data-version-events='${JSON.stringify(versionEvents).replace(/'/g, "&#39;")}'
                        ></canvas>
                        <div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">
                            <strong style="color: #667eea; display: block; margin-bottom: 8px;">CPU Thresholds:</strong>
                            <div style="color: #28a745; margin-left: 10px;">✓ Normal: &lt; 1.0m</div>
                            <div style="color: #ffc107; margin-left: 10px;">⚠ Warning: 1.0m - 5.0m</div>
                            <div style="color: #dc3545; margin-left: 10px;">✗ Error: &gt; 5.0m</div>
                        </div>
                        <div style="margin-top: 8px; padding: 8px 12px; background: #eef0f4; border-radius: 4px; font-family: monospace; font-size: 0.75em; color: #333; word-break: break-all;">
                            <strong>Query:</strong> rate(container_cpu_usage_seconds_total{namespace="${ns}", pod=~"${deploy}-.*", container="${containerName}"}[5m])
                        </div>
                    `;
                    chartsDiv.appendChild(cpuChartDiv);
                }

                if (details.probe_timeseries && details.probe_timeseries.length > 0) {
                    const targetCount = details.probe_target_count || 0;
                    const probeChartDiv = document.createElement('div');
                    probeChartDiv.className = 'chart-wrapper';
                    probeChartDiv.innerHTML = `
                        <h3>Endpoint Availability — Probe Success Rate (${targetCount} active targets)</h3>
                        <canvas id="probe-chart-${clusterIdx}" class="chart-canvas"
                            data-pending-chart="probe"
                            data-chart-data='${JSON.stringify(details).replace(/'/g, "&#39;")}'
                            data-restart-events='${JSON.stringify(restartEvents).replace(/'/g, "&#39;")}'
                            data-version-events='${JSON.stringify(versionEvents).replace(/'/g, "&#39;")}'
                        ></canvas>
                        <div style="margin-top: 8px; padding: 8px 12px; background: #eef0f4; border-radius: 4px; font-size: 0.8em; color: #333;">
                            <strong>Note:</strong> RMO creates and manages these probes via ServiceMonitors and blackbox exporter.
                            Missing probes or target count mismatch = RMO issue (failed reconciliation).
                            Probe failure with correct target count = endpoint unreachable (infra issue, not RMO).
                            Expected targets should match RouteMonitor + ClusterUrlMonitor count.
                        </div>
                        <div style="margin-top: 6px; padding: 8px 12px; background: #eef0f4; border-radius: 4px; font-family: monospace; font-size: 0.75em; color: #333; word-break: break-all;">
                            <strong>Query:</strong> avg(probe_success{namespace=~"openshift-route-monitor-operator|ocm-.*"})
                        </div>
                    `;
                    chartsDiv.appendChild(probeChartDiv);
                }

                if (details.probe_duration_timeseries && details.probe_duration_timeseries.length > 0) {
                    const durationChartDiv = document.createElement('div');
                    durationChartDiv.className = 'chart-wrapper';
                    durationChartDiv.innerHTML = `
                        <h3>Endpoint Latency — Avg Probe Duration</h3>
                        <canvas id="duration-chart-${clusterIdx}" class="chart-canvas"
                            data-pending-chart="duration"
                            data-chart-data='${JSON.stringify(details).replace(/'/g, "&#39;")}'
                            data-restart-events='${JSON.stringify(restartEvents).replace(/'/g, "&#39;")}'
                            data-version-events='${JSON.stringify(versionEvents).replace(/'/g, "&#39;")}'
                        ></canvas>
                        <div style="margin-top: 8px; padding: 8px 12px; background: #eef0f4; border-radius: 4px; font-family: monospace; font-size: 0.75em; color: #333; word-break: break-all;">
                            <strong>Query:</strong> avg(probe_duration_seconds{namespace=~"openshift-route-monitor-operator|ocm-.*"})
                        </div>
                    `;
                    chartsDiv.appendChild(durationChartDiv);
                }

                // Legend is now inline in each chart via empty datasets
            }
            detailsDiv.appendChild(chartsDiv);

            // Health checks
            const checksDiv = document.createElement('div');
            checksDiv.className = 'health-checks';
            checksDiv.innerHTML = '<h3 style="margin-bottom: 15px; color: #667eea;">Health Check Details</h3>';

            (cluster.health_checks || []).forEach((check, checkIdx) => {
                const checkDiv = document.createElement('div');
                checkDiv.className = 'health-check';
                const checkId = `${clusterIdx}-${checkIdx}`;
                const statusClass = getStatusClass(check.status);
                const icon = getStatusIcon(check.status);

                checkDiv.innerHTML = `
                    <div class="check-header" onclick="toggleCheckDetails('${checkId}')">
                        <div>
                            <span class="check-icon ${statusClass}">${icon}</span>
                            <span class="check-title">${check.check.replace(/_/g, ' ').toUpperCase()}</span>
                        </div>
                        <span class="status-badge ${statusClass}">${check.status}</span>
                    </div>
                    <div class="check-details" id="check-details-${checkId}">
                        ${check.message ? `<div class="check-message">${check.message}</div>` : ''}
                        <div class="detail-grid">
                            ${Object.entries(check.details || {}).map(([key, value]) => {
                                if (key.includes('timeseries') || key.includes('restart_details') || key.includes('events') || key.includes('error_samples') || key.includes('warning_samples')) return '';
                                let displayValue = value;
                                let valueClass = '';

                                if (typeof value === 'object' && value !== null) {
                                    if (Array.isArray(value) && value.length > 0 && typeof value[0] !== 'object') {
                                        displayValue = value.join(', ');
                                    } else {
                                        displayValue = JSON.stringify(value, null, 2);
                                    }
                                } else if (typeof value === 'number') {
                                    displayValue = value.toFixed(2);

                                    // Apply color coding based on check type and key
                                    if (check.check === 'resource_leak_detection') {
                                        if (key === 'latest_cpu_cores') {
                                            const cpuMillicores = value * 1000;
                                            if (cpuMillicores > CPU_ERROR_THRESHOLD) valueClass = 'resource-error';
                                            else if (cpuMillicores > CPU_WARNING_THRESHOLD) valueClass = 'resource-warning';
                                            else valueClass = 'resource-normal';
                                        } else if (key === 'latest_memory_bytes') {
                                            const memMB = value / 1048576;
                                            if (memMB > MEM_ERROR_THRESHOLD) valueClass = 'resource-error';
                                            else if (memMB > MEM_WARNING_THRESHOLD) valueClass = 'resource-warning';
                                            else valueClass = 'resource-normal';
                                        } else if (key === 'peak_memory_mb') {
                                            if (value > MEM_ERROR_THRESHOLD) valueClass = 'resource-error';
                                            else if (value > MEM_WARNING_THRESHOLD) valueClass = 'resource-warning';
                                            else valueClass = 'resource-normal';
                                        } else if (key === 'peak_cpu_millicores') {
                                            if (value > CPU_ERROR_THRESHOLD) valueClass = 'resource-error';
                                            else if (value > CPU_WARNING_THRESHOLD) valueClass = 'resource-warning';
                                            else valueClass = 'resource-normal';
                                        }
                                    } else if (check.check === 'resource_limits_validation') {
                                        if ((key === 'memory_usage_percent' || key === 'cpu_usage_percent') && value > 80) valueClass = 'resource-warning';
                                    } else if (check.check === 'log_error_analysis') {
                                        if (key === 'error_count' && value > 0) valueClass = 'resource-warning';
                                        else if (key === 'warning_count' && value > 0) valueClass = 'resource-warning';
                                    } else if (check.check === 'pod_status_and_restarts') {
                                        if (key === 'total_restarts' && value > 3) valueClass = 'resource-warning';
                                        else if (key === 'total_restarts' && value > 10) valueClass = 'resource-error';
                                    } else if (check.check === 'alertmanager_pods') {
                                        if (key === 'total_restarts' && value > 3) valueClass = 'resource-warning';
                                        else if (key === 'total_restarts' && value > 10) valueClass = 'resource-error';
                                    } else if (check.check === 'reconciliation_behavior') {
                                        if (key === 'reconciliation_rate') {
                                            const rate = parseFloat(value);
                                            if (rate > 10) valueClass = 'resource-warning';
                                        }
                                    } else if (check.check === 'alertmanager_logs') {
                                        if (key === 'error_count' && value > 0) valueClass = 'resource-warning';
                                        else if (key === 'warning_count' && value > 0) valueClass = 'resource-warning';
                                    } else if (check.check === 'alertmanager_events' || check.check === 'camo_events') {
                                        if (key === 'warning_event_count' && value > 0) valueClass = 'resource-warning';
                                    }
                                }

                                return `
                                    <div class="detail-item">
                                        <div class="detail-label">${key.replace(/_/g, ' ')}</div>
                                        <div class="detail-value ${valueClass}">${displayValue}</div>
                                    </div>
                                `;
                            }).join('')}
                        </div>
                        ${check.check === 'alertmanager_pods' && check.details && check.details.restart_details && Array.isArray(check.details.restart_details) && check.details.restart_details.length > 0 ? `
                            <div style="margin-top: 15px;">
                                <strong style="display: block; margin-bottom: 8px; color: #667eea;">Restart Details by Pod:</strong>
                                ${check.details.restart_details.map(pod => `
                                    <div style="background: #f8f9fa; padding: 10px; margin-bottom: 10px; border-radius: 4px; border-left: 3px solid #667eea;">
                                        <strong>${pod.pod_name}</strong>
                                        <div style="font-size: 0.85em; margin-top: 5px;">
                                            ${pod.containers.map(c => `
                                                <div style="margin-left: 15px; padding: 5px 0;">
                                                    <strong>${c.name}:</strong> ${c.restart_count} restart(s)
                                                    ${c.last_restart !== "No recent restart data" ? `
                                                        <div style="margin-left: 15px; font-size: 0.9em; color: #666;">
                                                            Reason: ${c.last_restart.reason || 'N/A'} |
                                                            Exit Code: ${c.last_restart.exit_code || 'N/A'} |
                                                            Time: ${c.last_restart.finished_at || 'N/A'}
                                                        </div>
                                                    ` : '<div style="margin-left: 15px; font-size: 0.9em; color: #999;">No recent restart data (restart >7 days ago)</div>'}
                                                </div>
                                            `).join('')}
                                        </div>
                                    </div>
                                `).join('')}
                            </div>
                        ` : ''}
                        ${(check.check === 'log_error_analysis' || check.check === 'alertmanager_logs') && check.details ? `
                            ${check.details.error_samples && Array.isArray(check.details.error_samples) && check.details.error_samples.length > 0 ? `
                                <div style="margin-top: 15px;">
                                    <strong style="display: block; margin-bottom: 8px; color: #dc3545;">Sample Error Logs:</strong>
                                    <div style="background: #fff5f5; padding: 10px; border-radius: 4px; border-left: 3px solid #dc3545; font-family: monospace; font-size: 0.8em;">
                                        ${check.details.error_samples.map(log => `
                                            <div style="padding: 5px 0; border-bottom: 1px solid #ffe0e0; white-space: pre-wrap; word-break: break-all;">
                                                ${log}
                                            </div>
                                        `).join('')}
                                    </div>
                                </div>
                            ` : ''}
                            ${check.details.warning_samples && Array.isArray(check.details.warning_samples) && check.details.warning_samples.length > 0 ? `
                                <div style="margin-top: 15px;">
                                    <strong style="display: block; margin-bottom: 8px; color: #f57c00;">Sample Warning Logs:</strong>
                                    <div style="background: #fff8e1; padding: 10px; border-radius: 4px; border-left: 3px solid #f57c00; font-family: monospace; font-size: 0.8em;">
                                        ${check.details.warning_samples.map(log => `
                                            <div style="padding: 5px 0; border-bottom: 1px solid #ffe0b2; white-space: pre-wrap; word-break: break-all;">
                                                ${log}
                                            </div>
                                        `).join('')}
                                    </div>
                                </div>
                            ` : ''}
                        ` : ''}
                        ${getThresholdPanel(check.check, cluster)}
                    </div>
                `;
                checksDiv.appendChild(checkDiv);
            });

            detailsDiv.appendChild(checksDiv);

            // Close button at bottom of details panel
            const closeDiv = document.createElement('div');
            closeDiv.style.cssText = 'text-align: center; padding: 12px; margin-top: 20px; border-top: 1px solid #e0e0e0;';
            closeDiv.innerHTML = `<button onclick="toggleClusterDetails('${clusterIdx}'); this.closest('.cluster-details-row').previousElementSibling.scrollIntoView({behavior: 'smooth', block: 'nearest'})" style="padding: 8px 24px; background: var(--bg-card); color: var(--accent); border: 1px solid var(--accent); border-radius: 3px; cursor: pointer; font-size: 0.82em; font-family: var(--font); font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; transition: all 0.15s;" onmouseover="this.style.background='var(--accent)';this.style.color='var(--bg-primary)'" onmouseout="this.style.background='var(--bg-card)';this.style.color='var(--accent)'">▲ Collapse</button>`;
            detailsDiv.appendChild(closeDiv);

            return detailsDiv;
        }

        function generateSummary() {
            const summaryEl = document.getElementById('summaryOverview');
            if (!summaryEl || !healthData || healthData.length === 0) return;

            // Count unique clusters, aggregate worst status per cluster across operators
            const clusterStatuses = {};
            healthData.forEach(entry => {
                if (entry.operator_name === 'unknown') return;
                const cid = entry.cluster_id || entry.cluster_name;
                const status = entry.health_summary?.overall_status || 'UNKNOWN';
                const priority = { 'CRITICAL': 4, 'NO_ACCESS': 3, 'WARNING': 2, 'HEALTHY': 1, 'UNKNOWN': 0 };
                if (!clusterStatuses[cid] || (priority[status] || 0) > (priority[clusterStatuses[cid]] || 0)) {
                    clusterStatuses[cid] = status;
                }
            });

            let criticalCount = 0, warningCount = 0, healthyCount = 0, noAccessCount = 0;
            Object.values(clusterStatuses).forEach(status => {
                if (status === 'CRITICAL') criticalCount++;
                else if (status === 'WARNING') warningCount++;
                else if (status === 'HEALTHY') healthyCount++;
                else if (status === 'NO_ACCESS') noAccessCount++;
            });

            const totalClusters = Object.keys(clusterStatuses).length;

            // CVE data for the operator image (optional)
            // To enable CVE reporting, populate this object with scan results
            // Example: Use trivy, grype, or similar tool to scan your operator image
            const cveData = {
                image_tag: "",  // Set to your operator image tag (e.g., "v0.1.810-g01fde38")
                image_sha: "",  // Set to your image SHA (e.g., "ae6e064a909f")
                total_high: 0,
                total_medium: 0,
                medium_fixable: 0,
                medium_not_fixable: 0,
                high_cves: []  // Array of {id, severity, package, installed_version, fixed_version, title}
            };
            // Set to true to display CVE section in report (requires cveData above)
            const enableCVESection = false;

            summaryEl.innerHTML = '<h2>📊 Summary Overview</h2>' +
                '<div class="stats-grid">' +
                    '<div class="stat-card">' +
                        '<div class="stat-label">Total Clusters</div>' +
                        '<div class="stat-number">' + totalClusters + '</div>' +
                    '</div>' +
                    '<div class="stat-card healthy">' +
                        '<div class="stat-label">Healthy</div>' +
                        '<div class="stat-number healthy">' + healthyCount + '</div>' +
                        '<div class="stat-label">' + ((healthyCount/totalClusters)*100).toFixed(1) + '%</div>' +
                    '</div>' +
                    '<div class="stat-card warning">' +
                        '<div class="stat-label">Warnings</div>' +
                        '<div class="stat-number warning">' + warningCount + '</div>' +
                        '<div class="stat-label">' + ((warningCount/totalClusters)*100).toFixed(1) + '%</div>' +
                    '</div>' +
                    '<div class="stat-card critical">' +
                        '<div class="stat-label">Critical</div>' +
                        '<div class="stat-number critical">' + criticalCount + '</div>' +
                        '<div class="stat-label">' + ((criticalCount/totalClusters)*100).toFixed(1) + '%</div>' +
                    '</div>' +
                    '<div class="stat-card" style="border-color: var(--text-muted);">' +
                        '<div class="stat-label">No Access</div>' +
                        '<div class="stat-number" style="color: var(--text-muted);">' + noAccessCount + '</div>' +
                        '<div class="stat-label">' + ((noAccessCount/totalClusters)*100).toFixed(1) + '%</div>' +
                    '</div>' +
                '</div>' +
                // CVE Security Section (optional)
                (enableCVESection && (cveData.image_tag || cveData.image_sha) ?
                '<div style="margin-top: 35px; padding: 0; background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15); overflow: hidden;">' +
                    '<div style="padding: 25px 30px; background: linear-gradient(135deg, #0f3460 0%, #16213e 100%); border-bottom: 3px solid #e94560;">' +
                        '<h2 style="margin: 0; color: #ffffff; font-size: 1.5em; font-weight: 600; display: flex; align-items: center; gap: 12px;">' +
                            '<span style="font-size: 1.3em;">🔒</span>' +
                            'Container Image Security Analysis' +
                        '</h2>' +
                    '</div>' +
                    '<div style="padding: 30px; background: #16213e;">' +
                        '<div style="margin-bottom: 25px; padding: 20px; background: rgba(255,255,255,0.05); border-radius: 8px; border: 2px solid rgba(233,69,96,0.3); backdrop-filter: blur(10px);">' +
                            '<div style="display: grid; grid-template-columns: auto 1fr; gap: 15px; font-size: 0.95em; color: #e0e0e0;">' +
                                '<strong style="color: #e94560;">Image Tag:</strong>' +
                                '<span style="color: #ffffff; font-family: monospace; background: rgba(255,255,255,0.1); padding: 4px 8px; border-radius: 4px;">' + cveData.image_tag + '</span>' +
                                '<strong style="color: #e94560;">Image SHA:</strong>' +
                                '<span style="color: #ffffff; font-family: monospace; background: rgba(255,255,255,0.1); padding: 4px 8px; border-radius: 4px;">' + cveData.image_sha + '</span>' +
                            '</div>' +
                        '</div>' +
                        '<h3 style="margin: 0 0 20px 0; color: #e94560; font-size: 1.2em; font-weight: 600; text-transform: uppercase; letter-spacing: 1px; border-bottom: 2px solid rgba(233,69,96,0.3); padding-bottom: 10px;">Vulnerability Summary</h3>' +
                        '<table style="width: 100%; border-collapse: separate; border-spacing: 0; background: rgba(255,255,255,0.03); border-radius: 8px; overflow: hidden; box-shadow: 0 4px 16px rgba(0,0,0,0.2);">' +
                            '<thead>' +
                                '<tr style="background: linear-gradient(135deg, #e94560 0%, #d63447 100%);">' +
                                    '<th style="padding: 16px; text-align: left; color: #ffffff; font-weight: 600; font-size: 0.95em; text-transform: uppercase; letter-spacing: 0.5px; border: none;">Severity Level</th>' +
                                    '<th style="padding: 16px; text-align: center; color: #ffffff; font-weight: 600; font-size: 0.95em; text-transform: uppercase; letter-spacing: 0.5px; border: none;">Total CVEs</th>' +
                                    '<th style="padding: 16px; text-align: center; color: #ffffff; font-weight: 600; font-size: 0.95em; text-transform: uppercase; letter-spacing: 0.5px; border: none;">Fixable</th>' +
                                    '<th style="padding: 16px; text-align: center; color: #ffffff; font-weight: 600; font-size: 0.95em; text-transform: uppercase; letter-spacing: 0.5px; border: none;">Not Fixable</th>' +
                                '</tr>' +
                            '</thead>' +
                            '<tbody>' +
                                '<tr style="background: rgba(255,255,255,0.05); border-bottom: 1px solid rgba(255,255,255,0.1);">' +
                                    '<td style="padding: 18px; border: none; font-weight: 600; font-size: 1.05em;">' +
                                        '<span style="color: #ff6b6b; display: inline-flex; align-items: center; gap: 8px; padding: 6px 12px; background: rgba(255,107,107,0.15); border-radius: 6px; border-left: 4px solid #ff6b6b;">' +
                                            '<span style="font-size: 1.2em;">🔴</span> HIGH' +
                                        '</span>' +
                                    '</td>' +
                                    '<td style="padding: 18px; border: none; text-align: center;">' +
                                        '<span style="color: #ffffff; font-weight: 700; font-size: 1.3em; text-shadow: 0 0 10px rgba(255,107,107,0.5);">' +
                                            cveData.total_high +
                                        '</span>' +
                                    '</td>' +
                                    '<td style="padding: 18px; border: none; text-align: center;">' +
                                        '<span style="color: #51cf66; font-weight: 600; font-size: 1.1em;">0</span>' +
                                    '</td>' +
                                    '<td style="padding: 18px; border: none; text-align: center;">' +
                                        '<span style="color: #868e96; font-weight: 600; font-size: 1.1em;">0</span>' +
                                    '</td>' +
                                '</tr>' +
                                '<tr style="background: rgba(255,255,255,0.02);">' +
                                    '<td style="padding: 18px; border: none; font-weight: 600; font-size: 1.05em;">' +
                                        '<span style="color: #ffa94d; display: inline-flex; align-items: center; gap: 8px; padding: 6px 12px; background: rgba(255,169,77,0.15); border-radius: 6px; border-left: 4px solid #ffa94d;">' +
                                            '<span style="font-size: 1.2em;">🟡</span> MEDIUM' +
                                        '</span>' +
                                    '</td>' +
                                    '<td style="padding: 18px; border: none; text-align: center;">' +
                                        '<span style="color: #ffffff; font-weight: 700; font-size: 1.3em; text-shadow: 0 0 10px rgba(255,169,77,0.5);">' +
                                            cveData.total_medium +
                                        '</span>' +
                                    '</td>' +
                                    '<td style="padding: 18px; border: none; text-align: center;">' +
                                        '<span style="color: #51cf66; font-weight: 600; font-size: 1.1em;">' + cveData.medium_fixable + '</span>' +
                                    '</td>' +
                                    '<td style="padding: 18px; border: none; text-align: center;">' +
                                        '<span style="color: #ffa94d; font-weight: 600; font-size: 1.1em;">' + cveData.medium_not_fixable + '</span>' +
                                    '</td>' +
                                '</tr>' +
                            '</tbody>' +
                        '</table>' +
                    (cveData.high_cves.length > 0 ?
                        '<h3 style="margin: 30px 0 20px 0; color: #ff6b6b; font-size: 1.2em; font-weight: 600; text-transform: uppercase; letter-spacing: 1px; border-bottom: 2px solid rgba(255,107,107,0.3); padding-bottom: 10px;">🔴 High Severity CVE Details</h3>' +
                        '<table style="width: 100%; border-collapse: separate; border-spacing: 0; background: rgba(255,255,255,0.03); border-radius: 8px; overflow: hidden; box-shadow: 0 4px 16px rgba(0,0,0,0.2);">' +
                            '<thead>' +
                                '<tr style="background: linear-gradient(135deg, #ff6b6b 0%, #ee5a6f 100%);">' +
                                    '<th style="padding: 14px; text-align: left; color: #ffffff; font-weight: 600; font-size: 0.9em; text-transform: uppercase; letter-spacing: 0.5px; border: none;">CVE ID</th>' +
                                    '<th style="padding: 14px; text-align: left; color: #ffffff; font-weight: 600; font-size: 0.9em; text-transform: uppercase; letter-spacing: 0.5px; border: none;">Package</th>' +
                                    '<th style="padding: 14px; text-align: left; color: #ffffff; font-weight: 600; font-size: 0.9em; text-transform: uppercase; letter-spacing: 0.5px; border: none;">Installed</th>' +
                                    '<th style="padding: 14px; text-align: left; color: #ffffff; font-weight: 600; font-size: 0.9em; text-transform: uppercase; letter-spacing: 0.5px; border: none;">Fixed In</th>' +
                                    '<th style="padding: 14px; text-align: left; color: #ffffff; font-weight: 600; font-size: 0.9em; text-transform: uppercase; letter-spacing: 0.5px; border: none;">Title</th>' +
                                '</tr>' +
                            '</thead>' +
                            '<tbody>' +
                                cveData.high_cves.map((cve, idx) =>
                                    '<tr style="background: ' + (idx % 2 === 0 ? 'rgba(255,255,255,0.05)' : 'rgba(255,255,255,0.02)') + '; border-bottom: 1px solid rgba(255,255,255,0.1);">' +
                                        '<td style="padding: 14px; border: none;">' +
                                            '<a href="' + cve.cve_url + '" target="_blank" style="color: #ff6b6b; text-decoration: none; font-weight: 700; font-family: monospace; padding: 4px 8px; background: rgba(255,107,107,0.15); border-radius: 4px; display: inline-block; transition: all 0.2s;">' +
                                                cve.cve_id +
                                            '</a>' +
                                        '</td>' +
                                        '<td style="padding: 14px; border: none; font-family: monospace; font-size: 0.9em; color: #e0e0e0;">' +
                                            cve.package +
                                        '</td>' +
                                        '<td style="padding: 14px; border: none; font-family: monospace; font-size: 0.85em; color: #b0b0b0;">' +
                                            cve.installed_version +
                                        '</td>' +
                                        '<td style="padding: 14px; border: none; font-family: monospace; font-size: 0.85em; color: #b0b0b0;">' +
                                            (cve.fixed_version || '<span style="color: #ffa94d; font-weight: 600;">Not Available</span>') +
                                        '</td>' +
                                        '<td style="padding: 14px; border: none; font-size: 0.9em; color: #d0d0d0;">' +
                                            cve.title +
                                        '</td>' +
                                    '</tr>'
                                ).join('') +
                            '</tbody>' +
                        '</table>'
                    :
                        '<div style="margin-top: 25px; padding: 18px; background: rgba(81,207,102,0.15); border-left: 4px solid #51cf66; border-radius: 8px; backdrop-filter: blur(10px);">' +
                            '<strong style="color: #51cf66; font-size: 1.05em; display: flex; align-items: center; gap: 10px;">' +
                                '<span style="font-size: 1.3em;">✓</span> No High Severity CVEs Found' +
                            '</strong>' +
                        '</div>'
                    ) +
                    '<div style="margin-top: 25px; padding: 18px; background: rgba(255,169,77,0.1); border-left: 4px solid #ffa94d; border-radius: 8px; font-size: 0.95em; backdrop-filter: blur(10px);">' +
                        '<strong style="color: #ffa94d; display: flex; align-items: center; gap: 8px; margin-bottom: 8px;">' +
                            '<span style="font-size: 1.2em;">ℹ️</span> Important Note' +
                        '</strong>' +
                        '<p style="margin: 0; color: #d0d0d0; line-height: 1.6;">All MEDIUM severity CVEs are currently not fixable (no patches available from upstream vendors). These require OS package updates from the base image maintainer.</p>' +
                    '</div>' +
                    '</div>' +
                '</div>'
                : '');  // End CVE section conditional
        }

        function sortClusters(data) {
            return data.sort((a, b) => {
                const aShard = a.hive_shard || a.health_checks?.find(c => c.check === 'version_verification')?.details?.target_name || 'unknown';
                const bShard = b.hive_shard || b.health_checks?.find(c => c.check === 'version_verification')?.details?.target_name || 'unknown';
                if (aShard !== bShard) return aShard.localeCompare(bShard);

                const aIsNoAccess = (a.backplane_login?.status === 'FAILED') || (a.health_summary?.overall_status === 'NO_ACCESS');
                const bIsNoAccess = (b.backplane_login?.status === 'FAILED') || (b.health_summary?.overall_status === 'NO_ACCESS');
                if (aIsNoAccess && !bIsNoAccess) return 1;
                if (!aIsNoAccess && bIsNoAccess) return -1;
                return (a.cluster_name || '').localeCompare(b.cluster_name || '');
            });
        }

        function renderOperatorTable(operatorData, tableHeader, tableBody, idPrefix) {
            const checkTypes = getAllCheckTypes(operatorData);

            let headerHTML = '<tr><th>Cluster Name</th><th class="check-name-header" title="Backplane Login"><div>Backplane Login</div></th>';
            checkTypes.forEach(checkType => {
                headerHTML += `<th class="check-name-header" title="${formatCheckName(checkType)}"><div>${formatCheckName(checkType)}</div></th>`;
            });
            headerHTML += '<th class="check-name-header resource-header-diagonal" title="Restarts"><div>Restarts</div></th>';
            headerHTML += '<th class="check-name-header resource-header-diagonal" title="Logged Errors"><div>Logged Errors</div></th>';
            headerHTML += '<th class="check-name-header resource-header-diagonal" title="Logged Warnings"><div>Logged Warnings</div></th>';
            headerHTML += '<th class="check-name-header resource-header-diagonal" title="CPU"><div>CPU</div></th>';
            headerHTML += '<th class="check-name-header resource-header-diagonal" title="Memory"><div>Memory</div></th></tr>';
            tableHeader.innerHTML = headerHTML;

            let currentShard = null;
            const totalColumns = checkTypes.length + 7;
            operatorData.forEach((cluster, idx) => {
                const clusterIdx = `${idPrefix}-${idx}`;
                const clusterShard = cluster.hive_shard || cluster.health_checks?.find(c => c.check === 'version_verification')?.details?.target_name || 'unknown';

                if (clusterShard !== currentShard) {
                    currentShard = clusterShard;
                    const shardClusters = operatorData.filter(c => (c.hive_shard || c.health_checks?.find(ch => ch.check === 'version_verification')?.details?.target_name || 'unknown') === clusterShard);
                    const shardRow = document.createElement('tr');
                    shardRow.className = 'shard-group-header';
                    shardRow.innerHTML = `<td colspan="${totalColumns}" style="padding: 8px 14px; font-weight: 600; letter-spacing: 0.04em;">Hive Shard: ${clusterShard} (${shardClusters.length} clusters)</td>`;
                    tableBody.appendChild(shardRow);
                }

                const resources = getResourceValues(cluster);
                const restarts = getPodRestarts(cluster);
                const errors = getLogErrors(cluster);
                const warnings = getLogWarnings(cluster);

                const mainRow = document.createElement('tr');
                mainRow.id = `cluster-row-${clusterIdx}`;
                mainRow.className = 'main-row';
                mainRow.onclick = () => toggleClusterDetails(clusterIdx);

                const loginStatus = cluster.backplane_login?.status || 'UNKNOWN';
                const loginIcon = loginStatus === 'SUCCESS' ? '✓' : (loginStatus === 'FAILED' ? '✗' : '?');
                const loginClass = loginStatus === 'SUCCESS' ? 'status-pass' : (loginStatus === 'FAILED' ? 'status-critical' : 'status-unknown');

                let rowHTML = `<td class="cluster-name-cell">${cluster.cluster_name || 'Unknown'}</td>`;
                rowHTML += `<td class="check-status-cell"><span class="status-icon ${loginClass}">${loginIcon}</span></td>`;
                checkTypes.forEach(checkType => {
                    const status = getCheckStatus(cluster, checkType);
                    const statusClass = getStatusClass(status);
                    const icon = getStatusIcon(status);
                    const checkIndex = (cluster.health_checks || []).findIndex(c => c.check === checkType);
                    const checkId = `${clusterIdx}-${checkIndex}`;
                    rowHTML += `<td class="check-status-cell" onclick="event.stopPropagation(); expandToCheck('${clusterIdx}', '${checkId}')"><span class="status-icon ${statusClass}" title="${checkType}: ${status}">${icon}</span></td>`;
                });
                rowHTML += `<td class="resource-cell">${restarts}</td>`;
                rowHTML += `<td class="resource-cell">${errors}</td>`;
                rowHTML += `<td class="resource-cell">${warnings}</td>`;
                rowHTML += `<td class="resource-cell"><span class="resource-value resource-${resources.cpuLevel}">${resources.cpu}</span></td>`;
                rowHTML += `<td class="resource-cell"><span class="resource-value resource-${resources.memLevel}">${resources.memory}</span></td>`;
                mainRow.innerHTML = rowHTML;
                tableBody.appendChild(mainRow);

                const detailsRow = document.createElement('tr');
                detailsRow.id = `cluster-details-${clusterIdx}`;
                detailsRow.className = 'cluster-details-row';
                const detailsCell = document.createElement('td');
                detailsCell.className = 'cluster-details-cell';
                detailsCell.colSpan = totalColumns;
                detailsCell.appendChild(generateClusterDetails(cluster, clusterIdx));
                detailsRow.appendChild(detailsCell);
                tableBody.appendChild(detailsRow);
            });
        }

        function switchTab(operatorName) {
            document.querySelectorAll('.operator-tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.querySelector(`.operator-tab[data-operator="${operatorName}"]`).classList.add('active');
            document.getElementById(`tab-${operatorName}`).classList.add('active');
        }

        function generateReport() {
            if (!healthData || healthData.length === 0) {
                document.getElementById('tabContents').innerHTML = '<p style="padding: 40px; text-align: center;">No health data available</p>';
                return;
            }

            generateSummary();

            // Group data by operator
            const operatorGroups = {};
            healthData.forEach(cluster => {
                const op = cluster.operator_name || 'unknown';
                if (op === 'unknown') return;
                if (!operatorGroups[op]) operatorGroups[op] = [];
                operatorGroups[op].push(cluster);
            });

            const operators = Object.keys(operatorGroups).sort();
            const tabsContainer = document.getElementById('operatorTabs');
            const contentsContainer = document.getElementById('tabContents');

            // Build tabs and tab content for each operator (always show tabs)
            operators.forEach((op, idx) => {
                const opData = sortClusters(operatorGroups[op]);
                const shortName = op.replace(/-operator$/, '').replace(/configure-alertmanager/, 'CAMO').replace(/route-monitor/, 'RMO').replace(/osd-metrics-exporter/, 'OME');

                // Count statuses for badge
                const critCount = opData.filter(c => c.health_summary?.overall_status === 'CRITICAL').length;
                const warnCount = opData.filter(c => c.health_summary?.overall_status === 'WARNING').length;
                const badgeClass = critCount > 0 ? 'critical' : (warnCount > 0 ? 'warning' : 'healthy');
                const badgeText = critCount > 0 ? `${critCount} crit` : (warnCount > 0 ? `${warnCount} warn` : `${opData.length} ok`);

                // Tab button
                const tab = document.createElement('button');
                tab.className = `operator-tab${idx === 0 ? ' active' : ''}`;
                tab.dataset.operator = op;
                tab.innerHTML = `${shortName} <span class="tab-badge ${badgeClass}">${badgeText}</span>`;
                tab.onclick = () => switchTab(op);
                tabsContainer.appendChild(tab);

                // Tab content
                const content = document.createElement('div');
                content.id = `tab-${op}`;
                content.className = `tab-content${idx === 0 ? ' active' : ''}`;
                content.innerHTML = `<div class="content"><div class="clusters-table-wrapper"><table class="clusters-table"><thead id="header-${op}"></thead><tbody id="body-${op}"></tbody></table></div></div>`;
                contentsContainer.appendChild(content);

                renderOperatorTable(opData, document.getElementById(`header-${op}`), document.getElementById(`body-${op}`), op);
            });
        }

        window.addEventListener('DOMContentLoaded', generateReport);
    </script>
</body>
</html>
HTMLEOF

echo "✓ HTML report generated successfully: $OUTPUT_HTML"
echo ""
echo "Open in browser:"
echo "  open $OUTPUT_HTML"
