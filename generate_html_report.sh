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
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #f5f5f5;
            color: #333;
            padding: 20px;
            line-height: 1.6;
        }
        .container {
            max-width: 1800px;
            margin: 0 auto;
            background: white;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            border-radius: 8px;
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; }
        .header .subtitle { font-size: 1.1em; opacity: 0.9; }
        .summary-overview {
            background: white;
            padding: 30px;
            border-bottom: 2px solid #e0e0e0;
        }
        .summary-overview h2 { color: #667eea; margin-bottom: 20px; }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .stat-card {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 8px;
            text-align: center;
            border: 2px solid #e0e0e0;
        }
        .stat-card.critical { border-color: #dc3545; background: #fff5f5; }
        .stat-card.warning { border-color: #ffc107; background: #fffbf0; }
        .stat-card.healthy { border-color: #28a745; background: #f0fff4; }
        .operator-tabs {
            display: flex;
            background: #f0f0f0;
            border-bottom: 2px solid #e0e0e0;
            padding: 0 20px;
            gap: 4px;
        }
        .operator-tab {
            padding: 12px 24px;
            cursor: pointer;
            border: none;
            background: transparent;
            font-size: 0.95em;
            font-weight: 500;
            color: #666;
            border-bottom: 3px solid transparent;
            transition: all 0.2s;
            position: relative;
            top: 2px;
        }
        .operator-tab:hover { color: #333; background: #e8e8e8; }
        .operator-tab.active {
            color: #667eea;
            border-bottom-color: #667eea;
            background: white;
        }
        .operator-tab .tab-badge {
            display: inline-block;
            padding: 1px 8px;
            border-radius: 10px;
            font-size: 0.8em;
            margin-left: 6px;
        }
        .operator-tab .tab-badge.healthy { background: #d4edda; color: #155724; }
        .operator-tab .tab-badge.warning { background: #fff3cd; color: #856404; }
        .operator-tab .tab-badge.critical { background: #f8d7da; color: #721c24; }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        .stat-number { font-size: 2.5em; font-weight: bold; margin: 10px 0; }
        .stat-number.critical { color: #dc3545; }
        .stat-number.warning { color: #ffc107; }
        .stat-number.healthy { color: #28a745; }
        .stat-label {
            font-size: 0.9em;
            color: #666;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        .content { padding: 30px; }
        .clusters-table-wrapper { overflow-x: auto; margin-bottom: 30px; }
        .clusters-table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.9em;
        }
        .clusters-table thead {
            background: #667eea;
            color: white;
            position: sticky;
            top: 0;
            z-index: 10;
        }
        .clusters-table th {
            padding: 12px 6px;
            text-align: left;
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.8em;
            letter-spacing: 0.5px;
            white-space: nowrap;
            border-right: 1px solid rgba(255, 255, 255, 0.2);
        }
        .clusters-table th:last-child {
            border-right: none;
        }
        .clusters-table tbody tr {
            border-bottom: 1px solid #e0e0e0;
            cursor: pointer;
            transition: all 0.2s;
        }
        .clusters-table tbody tr.main-row:hover {
            background: #f8f9fa;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .clusters-table tbody tr.main-row.expanded {
            background: #e7f0ff;
            box-shadow: 0 2px 4px rgba(102, 126, 234, 0.2);
        }
        .clusters-table td {
            padding: 10px 6px;
            vertical-align: middle;
            border-right: 1px solid #f0f0f0;
        }
        .clusters-table td:last-child {
            border-right: none;
        }
        .cluster-name-cell {
            font-weight: 600;
            color: #667eea;
            min-width: 180px;
        }
        .check-status-cell {
            text-align: center;
            min-width: 28px;
            padding: 10px 3px;
        }
        .resource-cell {
            text-align: center;
            font-family: 'Monaco', 'Courier New', monospace;
            font-size: 0.85em;
            min-width: 32px;
            padding: 10px 4px;
        }
        .resource-cell:first-of-type {
            border-left: 2px solid #d0d0d0;
        }
        .resource-header-diagonal:first-of-type {
            border-left: 2px solid rgba(255, 255, 255, 0.3) !important;
        }
        .status-icon {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 22px;
            height: 22px;
            border-radius: 50%;
            font-weight: bold;
            font-size: 0.85em;
        }
        .status-icon.pass { background: #d4edda; color: #155724; }
        .status-icon.fail {
            background: linear-gradient(135deg, #dc3545 0%, #bd2130 100%);
            color: white;
            font-weight: bold;
            box-shadow: 0 3px 8px rgba(220, 53, 69, 0.5);
            border: 1px solid #c82333;
        }
        .status-icon.warning {
            background: linear-gradient(135deg, #ffc107 0%, #ff9800 100%);
            color: #000;
            font-weight: bold;
            box-shadow: 0 3px 8px rgba(255, 193, 7, 0.5);
            border: 1px solid #e0a800;
        }
        .status-icon.info { background: #d1ecf1; color: #0c5460; }
        .status-icon.na { background: #e9ecef; color: #6c757d; }
        .status-icon.no-access {
            background: #f0f0f0;
            color: #6c757d;
            border: 1px dashed #adb5bd;
        }

        /* Login status specific styling */
        .status-icon.status-pass {
            background: linear-gradient(135deg, #28a745 0%, #20c997 100%);
            color: white;
            font-weight: bold;
            box-shadow: 0 2px 6px rgba(40, 167, 69, 0.4);
        }
        .status-icon.status-critical {
            background: linear-gradient(135deg, #dc3545 0%, #c82333 100%);
            color: white;
            font-weight: bold;
            box-shadow: 0 2px 6px rgba(220, 53, 69, 0.4);
        }
        .status-icon.status-unknown {
            background: #f0f0f0;
            color: #6c757d;
            border: 1px dashed #adb5bd;
        }

        /* Resource value color coding */
        .resource-value {
            font-weight: 600;
        }
        .resource-value.resource-normal {
            color: #28a745;
        }
        .resource-value.resource-warning {
            color: #ffc107;
            font-weight: 700;
        }
        .resource-value.resource-error {
            color: #dc3545;
            font-weight: 700;
        }

        .cluster-details-row { display: none; }
        .cluster-details-row.expanded { display: table-row; }
        .cluster-details-cell {
            padding: 0 !important;
            background: #f8f9fa;
            border-top: 2px solid #667eea;
        }
        .cluster-section {
            padding: 30px;
            background: white;
            margin: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        .cluster-header {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 6px;
            margin-bottom: 20px;
        }
        .cluster-header h2 { color: #667eea; margin-bottom: 15px; }
        .cluster-meta {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 15px;
        }
        .meta-item {
            display: flex;
            flex-direction: column;
            min-width: 0; /* Allow flex items to shrink below content size */
        }
        .meta-label {
            font-size: 0.85em;
            color: #666;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 3px;
        }
        .meta-value {
            font-size: 1.05em;
            font-weight: 600;
            color: #333;
            word-break: break-word; /* Break long strings like cluster IDs */
            overflow-wrap: break-word;
        }
        .health-summary {
            display: flex;
            gap: 20px;
            margin-top: 15px;
            padding: 15px;
            background: white;
            border-radius: 6px;
        }
        .status-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-weight: 600;
            font-size: 0.85em;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        .status-badge.healthy { background: #d4edda; color: #155724; }
        .status-badge.pass { background: #d4edda; color: #155724; }
        .status-badge.warning { background: #fff3cd; color: #856404; }
        .status-badge.info { background: #d1ecf1; color: #0c5460; }
        .status-badge.fail { background: #f8d7da; color: #721c24; }
        .status-badge.critical { background: #f8d7da; color: #721c24; }
        .status-badge.no-access {
            background: #f0f0f0;
            color: #6c757d;
            border: 1px dashed #adb5bd;
        }
        .charts-container { padding: 20px 0; }
        .chart-wrapper {
            margin-bottom: 30px;
            background: white;
            padding: 20px;
            border: 1px solid #e0e0e0;
            border-radius: 8px;
        }
        .chart-wrapper h3 { color: #667eea; margin-bottom: 15px; font-size: 1.2em; }
        .chart-canvas { max-height: 350px; }
        .health-checks { margin-top: 20px; }
        .health-check {
            margin-bottom: 15px;
            border: 1px solid #e0e0e0;
            border-radius: 6px;
            overflow: hidden;
        }
        .check-header {
            padding: 12px 15px;
            background: #f8f9fa;
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            transition: background 0.2s;
        }
        .check-header:hover { background: #e9ecef; }
        .check-title { font-weight: 600; font-size: 0.95em; }
        .check-icon {
            font-size: 1.2em;
            margin-right: 10px;
        }
        .check-icon.pass { color: #28a745; }
        .check-icon.fail { color: #dc3545; }
        .check-icon.warning { color: #ffc107; }
        .check-icon.info { color: #17a2b8; }
        .check-icon.unknown { color: #6c757d; }
        .check-details {
            padding: 15px;
            border-top: 1px solid #e0e0e0;
            background: #fafafa;
            display: none;
        }
        .check-details.expanded { display: block; }
        .check-message {
            margin-bottom: 12px;
            padding: 10px;
            background: white;
            border-left: 4px solid #667eea;
            border-radius: 4px;
            font-size: 0.9em;
        }
        .detail-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 12px;
        }
        .detail-item {
            background: white;
            padding: 10px;
            border-radius: 4px;
            border: 1px solid #e0e0e0;
        }
        .detail-label {
            font-size: 0.8em;
            color: #666;
            margin-bottom: 3px;
        }
        .detail-value { font-weight: 600; color: #333; font-size: 0.9em; }
        .legend {
            margin-top: 15px;
            padding: 12px;
            background: #f8f9fa;
            border-radius: 6px;
            font-size: 0.85em;
        }
        .legend h4 { margin-bottom: 8px; color: #667eea; font-size: 0.95em; }
        .legend-item {
            margin: 4px 0;
            display: flex;
            align-items: center;
        }
        .legend-marker {
            width: 18px;
            height: 3px;
            margin-right: 8px;
            display: inline-block;
        }
        .legend-marker.version { background: #ff6384; }
        .legend-marker.restart { background: #ff9f40; }
        .footer {
            text-align: center;
            padding: 20px;
            background: #f8f9fa;
            color: #666;
            font-size: 0.9em;
            border-top: 1px solid #e0e0e0;
        }
        .check-name-header {
            height: 180px;
            white-space: nowrap;
            vertical-align: bottom;
            padding: 0 3px !important;
            position: relative;
            min-width: 28px;
            border-right: none !important;
        }
        .check-name-header > div {
            transform: rotate(-45deg);
            transform-origin: left bottom;
            position: absolute;
            bottom: 8px;
            left: 50%;
            width: 180px;
            text-align: left;
            padding-left: 5px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔍 Operator Health Check Report</h1>
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

        function toggleClusterDetails(clusterIdx) {
            const detailsRow = document.getElementById(`cluster-details-${clusterIdx}`);
            const mainRow = document.getElementById(`cluster-row-${clusterIdx}`);
            if (detailsRow && mainRow) {
                detailsRow.classList.toggle('expanded');
                mainRow.classList.toggle('expanded');
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
                // RMO-specific checks
                'rmo_controller_manager',
                'rmo_blackbox_exporter',
                'rmo_routemonitor_status',
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
                'rmo_controller_manager': 'RMO Controller',
                'rmo_blackbox_exporter': 'Blackbox',
                'rmo_routemonitor_status': 'RouteMonitors',
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

        function getThresholdPanel(checkType) {
            const thresholds = {
                'resource_leak_detection': '<div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">' +
                    '<strong style="color: #667eea; display: block; margin-bottom: 8px;">CAMO Pod Resource Thresholds:</strong>' +
                    '<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">' +
                    '<div><strong>CAMO Pod CPU:</strong>' +
                    '<div style="color: #28a745; margin-left: 10px;">✓ Normal: &lt; 1.0m</div>' +
                    '<div style="color: #ffc107; margin-left: 10px;">⚠ Warning: 1.0m - 5.0m</div>' +
                    '<div style="color: #dc3545; margin-left: 10px;">✗ Error: &gt; 5.0m</div></div>' +
                    '<div><strong>CAMO Pod Memory:</strong>' +
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

        function createMemoryChart(canvasId, data, restartEvents, versionEvents) {
            const ctx = document.getElementById(canvasId);
            if (!ctx) return;
            const memoryData = data.memory_timeseries || [];
            if (memoryData.length === 0) return;

            const timestamps = memoryData.map(point => point[0] * 1000);
            const values = memoryData.map(point => parseFloat(point[1]) / 1048576);
            const annotations = {};

            if (versionEvents && versionEvents.length > 0) {
                versionEvents.forEach((event, idx) => {
                    annotations[`version${idx}`] = {
                        type: 'line',
                        xMin: event.timestamp * 1000,
                        xMax: event.timestamp * 1000,
                        borderColor: '#ff6384',
                        borderWidth: 2,
                        borderDash: [5, 5],
                        label: { content: `v${event.version}`, enabled: true, position: 'top' }
                    };
                });
            }

            if (restartEvents && restartEvents.length > 0) {
                restartEvents.forEach((event, idx) => {
                    annotations[`restart${idx}`] = {
                        type: 'line',
                        xMin: event.timestamp * 1000,
                        xMax: event.timestamp * 1000,
                        borderColor: '#ff9f40',
                        borderWidth: 2,
                        label: { content: 'Restart', enabled: true, position: 'bottom' }
                    };
                });
            }

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

            if (versionEvents && versionEvents.length > 0) {
                versionEvents.forEach((event, idx) => {
                    annotations[`version${idx}`] = {
                        type: 'line',
                        xMin: event.timestamp * 1000,
                        xMax: event.timestamp * 1000,
                        borderColor: '#ff6384',
                        borderWidth: 2,
                        borderDash: [5, 5],
                        label: { content: `v${event.version}`, enabled: true, position: 'top' }
                    };
                });
            }

            if (restartEvents && restartEvents.length > 0) {
                restartEvents.forEach((event, idx) => {
                    annotations[`restart${idx}`] = {
                        type: 'line',
                        xMin: event.timestamp * 1000,
                        xMax: event.timestamp * 1000,
                        borderColor: '#ff9f40',
                        borderWidth: 2,
                        label: { content: 'Restart', enabled: true, position: 'bottom' }
                    };
                });
            }

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
                        <canvas id="memory-chart-${clusterIdx}" class="chart-canvas"></canvas>
                        <div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">
                            <strong style="color: #667eea; display: block; margin-bottom: 8px;">Memory Thresholds:</strong>
                            <div style="color: #28a745; margin-left: 10px;">✓ Normal: &lt; 60 MB</div>
                            <div style="color: #ffc107; margin-left: 10px;">⚠ Warning: 60 - 100 MB</div>
                            <div style="color: #dc3545; margin-left: 10px;">✗ Error: &gt; 100 MB</div>
                        </div>
                        <div style="margin-top: 8px; padding: 8px 12px; background: #f8f8f8; border-radius: 4px; font-family: monospace; font-size: 0.75em; color: #666; word-break: break-all;">
                            <strong>Query:</strong> container_memory_working_set_bytes{namespace="${ns}", pod="${podName}", container="${containerName}"}
                        </div>
                    `;
                    chartsDiv.appendChild(memoryChartDiv);
                    setTimeout(() => createMemoryChart(`memory-chart-${clusterIdx}`, details, restartEvents, versionEvents), 100);
                }

                if (details.cpu_timeseries && details.cpu_timeseries.length > 0) {
                    const cpuChartDiv = document.createElement('div');
                    cpuChartDiv.className = 'chart-wrapper';
                    cpuChartDiv.innerHTML = `
                        <h3>${cluster.operator_name || 'Operator'} CPU Usage Over Time</h3>
                        <canvas id="cpu-chart-${clusterIdx}" class="chart-canvas"></canvas>
                        <div style="margin-top: 15px; padding: 12px; background: #f0f8ff; border-left: 4px solid #667eea; border-radius: 4px; font-size: 0.85em;">
                            <strong style="color: #667eea; display: block; margin-bottom: 8px;">CPU Thresholds:</strong>
                            <div style="color: #28a745; margin-left: 10px;">✓ Normal: &lt; 1.0m</div>
                            <div style="color: #ffc107; margin-left: 10px;">⚠ Warning: 1.0m - 5.0m</div>
                            <div style="color: #dc3545; margin-left: 10px;">✗ Error: &gt; 5.0m</div>
                        </div>
                        <div style="margin-top: 8px; padding: 8px 12px; background: #f8f8f8; border-radius: 4px; font-family: monospace; font-size: 0.75em; color: #666; word-break: break-all;">
                            <strong>Query:</strong> rate(container_cpu_usage_seconds_total{namespace="${ns}", pod="${podName}", container="${containerName}"}[5m])
                        </div>
                    `;
                    chartsDiv.appendChild(cpuChartDiv);
                    setTimeout(() => createCPUChart(`cpu-chart-${clusterIdx}`, details, restartEvents, versionEvents), 100);
                }

                if ((details.memory_timeseries && details.memory_timeseries.length > 0) ||
                    (details.cpu_timeseries && details.cpu_timeseries.length > 0)) {
                    const legendDiv = document.createElement('div');
                    legendDiv.className = 'legend';
                    legendDiv.innerHTML = `
                        <h4>Chart Indicators</h4>
                        <div class="legend-item"><span class="legend-marker version"></span><span>Version Update (dashed red line)</span></div>
                        <div class="legend-item"><span class="legend-marker restart"></span><span>Pod Restart (orange line)</span></div>
                    `;
                    chartsDiv.appendChild(legendDiv);
                }
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
                        ${getThresholdPanel(check.check)}
                    </div>
                `;
                checksDiv.appendChild(checkDiv);
            });

            detailsDiv.appendChild(checksDiv);
            return detailsDiv;
        }

        function generateSummary() {
            const summaryEl = document.getElementById('summaryOverview');
            if (!summaryEl || !healthData || healthData.length === 0) return;

            let criticalCount = 0, warningCount = 0, healthyCount = 0, noAccessCount = 0;
            healthData.forEach(cluster => {
                const status = cluster.health_summary?.overall_status || 'UNKNOWN';
                if (status === 'CRITICAL') criticalCount++;
                else if (status === 'WARNING') warningCount++;
                else if (status === 'HEALTHY') healthyCount++;
                else if (status === 'NO_ACCESS') noAccessCount++;
            });

            const totalClusters = healthData.length;

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
                    '<div class="stat-card" style="background: #f0f0f0; border-left: 4px solid #6c757d;">' +
                        '<div class="stat-label">No Access</div>' +
                        '<div class="stat-number" style="color: #6c757d;">' + noAccessCount + '</div>' +
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
                    shardRow.innerHTML = `<td colspan="${totalColumns}" style="background: #2d3748; color: #e2e8f0; font-weight: 600; padding: 8px 12px; font-size: 0.9em; letter-spacing: 0.5px; border-top: 2px solid #4a5568;">Hive Shard: ${clusterShard} (${shardClusters.length} clusters)</td>`;
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
                    rowHTML += `<td class="check-status-cell"><span class="status-icon ${statusClass}">${icon}</span></td>`;
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

            // If only one operator, skip tabs entirely
            if (operators.length === 1) {
                const opData = sortClusters(operatorGroups[operators[0]]);
                const wrapper = document.createElement('div');
                wrapper.className = 'content';
                wrapper.innerHTML = '<div class="clusters-table-wrapper"><table class="clusters-table"><thead id="singleHeader"></thead><tbody id="singleBody"></tbody></table></div>';
                contentsContainer.appendChild(wrapper);
                renderOperatorTable(opData, document.getElementById('singleHeader'), document.getElementById('singleBody'), 'all');
                tabsContainer.style.display = 'none';
                return;
            }

            // Build tabs and tab content for each operator
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
