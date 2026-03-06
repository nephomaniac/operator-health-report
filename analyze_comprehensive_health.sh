#!/usr/bin/env bash
#
# Analyze Comprehensive Health Check Results
#
# This script parses the JSON output from collect_operator_health.sh
# and generates human-readable table format and HTML reports.
#
# Usage:
#   ./analyze_comprehensive_health.sh INPUT_FILE [OPTIONS]
#

set -euo pipefail

# Default values
INPUT_FILE=""
OUTPUT_FORMAT="table"  # table, html, or both
HTML_FILE=""

usage() {
    cat << EOF
Usage: $0 INPUT_FILE [OPTIONS]

Analyze comprehensive health check results

ARGUMENTS:
    INPUT_FILE                  JSON Lines file from --comprehensive-health collection

OPTIONS:
    --format, -f FORMAT         Output format: table, html, or both (default: table)
    --html-output, -o FILE      HTML output filename (default: health_report_TIMESTAMP.html)
    --help, -h                  Show this help message

EXAMPLES:
    # Display table summary
    $0 comprehensive_health_20260224.json

    # Generate HTML report
    $0 comprehensive_health_20260224.json --format html

    # Generate both table and HTML
    $0 comprehensive_health_20260224.json --format both -o health_report.html

EOF
    exit 0
}

# Parse arguments
if [ $# -eq 0 ]; then
    usage
fi

INPUT_FILE="$1"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --format|-f) OUTPUT_FORMAT="$2"; shift 2 ;;
        --html-output|-o) HTML_FILE="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "Error: Unknown option: $1" >&2; usage ;;
    esac
done

# Validate input file
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file not found: $INPUT_FILE" >&2
    exit 1
fi

# Set default HTML filename if not specified
if [ -z "$HTML_FILE" ]; then
    HTML_FILE="health_report_$(date +%Y%m%d_%H%M%S).html"
fi

# Check for jq
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

#=============================================================================
# TABLE OUTPUT
#=============================================================================
generate_table() {
    echo "================================================================================"
    echo "COMPREHENSIVE HEALTH CHECK REPORT"
    echo "================================================================================"
    echo ""
    echo "Generated: $(date)"
    echo "Input file: $INPUT_FILE"
    echo ""

    # Count total clusters
    total_clusters=$(jq -s 'length' "$INPUT_FILE")
    echo "Total clusters analyzed: $total_clusters"
    echo ""

    # Overall health summary
    echo "================================================================================"
    echo "OVERALL HEALTH SUMMARY"
    echo "================================================================================"

    critical_clusters=$(jq -s '[.[] | select(.health_summary.overall_status == "CRITICAL")] | length' "$INPUT_FILE")
    warning_clusters=$(jq -s '[.[] | select(.health_summary.overall_status == "WARNING")] | length' "$INPUT_FILE")
    healthy_clusters=$(jq -s '[.[] | select(.health_summary.overall_status == "HEALTHY")] | length' "$INPUT_FILE")

    printf "%-20s %5d (%5.1f%%)\n" "CRITICAL:" $critical_clusters $(awk "BEGIN {printf \"%.1f\", ($critical_clusters / $total_clusters) * 100}")
    printf "%-20s %5d (%5.1f%%)\n" "WARNING:" $warning_clusters $(awk "BEGIN {printf \"%.1f\", ($warning_clusters / $total_clusters) * 100}")
    printf "%-20s %5d (%5.1f%%)\n" "HEALTHY:" $healthy_clusters $(awk "BEGIN {printf \"%.1f\", ($healthy_clusters / $total_clusters) * 100}")
    echo ""

    # Cluster-by-cluster summary
    echo "================================================================================"
    echo "CLUSTER HEALTH STATUS"
    echo "================================================================================"
    printf "%-35s %-15s %-10s %8s %8s\n" "CLUSTER NAME" "VERSION" "STATUS" "CRITICAL" "WARNINGS"
    printf "%-35s %-15s %-10s %8s %8s\n" "------------" "-------" "------" "--------" "--------"

    jq -s -r '.[] | [
        .cluster_name,
        .operator_version,
        .health_summary.overall_status,
        .health_summary.critical_count,
        .health_summary.warning_count
    ] | @tsv' "$INPUT_FILE" | while IFS=$'\t' read -r name version status critical warnings; do
        printf "%-35s %-15s %-10s %8d %8d\n" "${name:0:35}" "${version:0:15}" "$status" "$critical" "$warnings"
    done

    echo ""

    # Failed health checks by type
    echo "================================================================================"
    echo "FAILED CHECKS BY TYPE"
    echo "================================================================================"

    # Version verification failures
    version_failures=$(jq -s '[.[] | .health_checks[] | select(.check == "version_verification" and .status == "FAIL")] | length' "$INPUT_FILE")
    echo "Version Verification Failures: $version_failures"

    if [ "$version_failures" -gt 0 ]; then
        echo ""
        echo "Clusters with version mismatches:"
        jq -s -r '.[] | select(.health_checks[] | select(.check == "version_verification" and .status == "FAIL")) | "  - \(.cluster_name): \(.operator_version)"' "$INPUT_FILE"
        echo ""
    fi

    # Pod restart issues
    restart_failures=$(jq -s '[.[] | .health_checks[] | select(.check == "pod_status_and_restarts" and (.status == "FAIL" or .status == "WARNING"))] | length' "$INPUT_FILE")
    echo "Pod Restart Issues: $restart_failures"

    if [ "$restart_failures" -gt 0 ]; then
        echo ""
        echo "Clusters with high restart counts:"
        jq -s -r '.[] | select(.health_checks[] | select(.check == "pod_status_and_restarts" and (.status == "FAIL" or .status == "WARNING"))) | "  - \(.cluster_name): max \(.health_checks[] | select(.check == "pod_status_and_restarts") | .details.max_restarts) restarts"' "$INPUT_FILE"
        echo ""
    fi

    # Memory leak warnings
    memory_warnings=$(jq -s '[.[] | .health_checks[] | select(.check == "memory_leak_detection" and .status == "WARNING")] | length' "$INPUT_FILE")
    echo "Memory Leak Warnings: $memory_warnings"

    if [ "$memory_warnings" -gt 0 ]; then
        echo ""
        echo "Clusters with potential memory leaks:"
        jq -s -r '.[] | select(.health_checks[] | select(.check == "memory_leak_detection" and .status == "WARNING")) | "  - \(.cluster_name): \(.health_checks[] | select(.check == "memory_leak_detection") | .details.increase_percent)% increase over 6h"' "$INPUT_FILE"
        echo ""
    fi

    # Log error warnings
    log_warnings=$(jq -s '[.[] | .health_checks[] | select(.check == "log_error_analysis" and .status == "WARNING")] | length' "$INPUT_FILE")
    echo "Log Error Warnings: $log_warnings"

    if [ "$log_warnings" -gt 0 ]; then
        echo ""
        echo "Clusters with high error log counts:"
        jq -s -r '.[] | select(.health_checks[] | select(.check == "log_error_analysis" and .status == "WARNING")) | "  - \(.cluster_name): \(.health_checks[] | select(.check == "log_error_analysis") | .details.error_count) errors in logs"' "$INPUT_FILE"
        echo ""
    fi

    # Operator-specific failures
    operator_failures=$(jq -s '[.[] | .health_checks[] | select(.check == "operator_specific_health" and .status == "FAIL")] | length' "$INPUT_FILE")
    echo "Operator-Specific Health Failures: $operator_failures"

    if [ "$operator_failures" -gt 0 ]; then
        echo ""
        echo "Clusters with operator-specific issues:"
        jq -s -r '.[] | select(.health_checks[] | select(.check == "operator_specific_health" and .status == "FAIL")) | "  - \(.cluster_name): \(.health_checks[] | select(.check == "operator_specific_health") | .message)"' "$INPUT_FILE"
        echo ""
    fi

    echo "================================================================================"
    echo "RECOMMENDATIONS"
    echo "================================================================================"

    if [ "$critical_clusters" -gt 0 ]; then
        echo "⚠ CRITICAL: $critical_clusters cluster(s) have critical issues that require immediate attention"
        echo ""
        echo "Clusters requiring immediate action:"
        jq -s -r '.[] | select(.health_summary.overall_status == "CRITICAL") | "  - \(.cluster_name) (\(.cluster_id))"' "$INPUT_FILE"
        echo ""
    fi

    if [ "$warning_clusters" -gt 0 ]; then
        echo "⚠ WARNING: $warning_clusters cluster(s) have warnings that should be investigated"
        echo ""
    fi

    if [ "$healthy_clusters" -eq "$total_clusters" ]; then
        echo "✓ All clusters are healthy - operator version appears stable for production"
    fi

    echo "================================================================================"
}

#=============================================================================
# HTML OUTPUT
#=============================================================================
generate_html() {
    local output_file="$1"

    # Count statistics
    local total_clusters=$(jq -s 'length' "$INPUT_FILE")
    local critical_clusters=$(jq -s '[.[] | select(.health_summary.overall_status == "CRITICAL")] | length' "$INPUT_FILE")
    local warning_clusters=$(jq -s '[.[] | select(.health_summary.overall_status == "WARNING")] | length' "$INPUT_FILE")
    local healthy_clusters=$(jq -s '[.[] | select(.health_summary.overall_status == "HEALTHY")] | length' "$INPUT_FILE")

    cat > "$output_file" << 'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Operator Health Check Report</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            max-width: 1400px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        h1, h2 {
            color: #333;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 8px;
            margin-bottom: 20px;
        }
        .header h1 {
            margin: 0;
            color: white;
        }
        .header p {
            margin: 5px 0;
            opacity: 0.9;
        }
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .card {
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .card h3 {
            margin-top: 0;
            font-size: 14px;
            text-transform: uppercase;
            color: #666;
        }
        .card .value {
            font-size: 36px;
            font-weight: bold;
            margin: 10px 0;
        }
        .card .percentage {
            font-size: 14px;
            color: #666;
        }
        .card.critical .value { color: #dc3545; }
        .card.warning .value { color: #ffc107; }
        .card.healthy .value { color: #28a745; }
        table {
            width: 100%;
            background: white;
            border-radius: 8px;
            overflow: hidden;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            border-collapse: collapse;
            margin-bottom: 30px;
        }
        thead {
            background-color: #667eea;
            color: white;
        }
        th {
            padding: 15px;
            text-align: left;
            font-weight: 600;
        }
        td {
            padding: 12px 15px;
            border-bottom: 1px solid #e0e0e0;
        }
        tr:last-child td {
            border-bottom: none;
        }
        tbody tr:hover {
            background-color: #f8f9fa;
        }
        .status-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 12px;
            font-size: 12px;
            font-weight: 600;
            text-transform: uppercase;
        }
        .status-critical {
            background-color: #dc3545;
            color: white;
        }
        .status-warning {
            background-color: #ffc107;
            color: #333;
        }
        .status-healthy {
            background-color: #28a745;
            color: white;
        }
        .status-unknown {
            background-color: #6c757d;
            color: white;
        }
        .section {
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 20px;
        }
        .section h2 {
            margin-top: 0;
            border-bottom: 2px solid #667eea;
            padding-bottom: 10px;
        }
        .check-item {
            padding: 10px;
            margin: 5px 0;
            border-left: 4px solid #e0e0e0;
            background-color: #f8f9fa;
        }
        .check-item.pass {
            border-left-color: #28a745;
        }
        .check-item.warning {
            border-left-color: #ffc107;
        }
        .check-item.fail {
            border-left-color: #dc3545;
        }
        .cluster-details {
            margin-top: 20px;
        }
        .cluster-card {
            background: white;
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 15px;
            border-left: 4px solid #e0e0e0;
        }
        .cluster-card.critical {
            border-left-color: #dc3545;
        }
        .cluster-card.warning {
            border-left-color: #ffc107;
        }
        .cluster-card.healthy {
            border-left-color: #28a745;
        }
        .cluster-card h3 {
            margin-top: 0;
        }
        pre {
            background-color: #f4f4f4;
            padding: 10px;
            border-radius: 4px;
            overflow-x: auto;
            font-size: 12px;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Operator Health Check Report</h1>
EOF_HTML

    echo "        <p>Generated: $(date)</p>" >> "$output_file"
    echo "        <p>Source: $INPUT_FILE</p>" >> "$output_file"

    cat >> "$output_file" << 'EOF_HTML'
    </div>

    <div class="summary-cards">
EOF_HTML

    # Add summary cards
    cat >> "$output_file" << EOF_HTML
        <div class="card">
            <h3>Total Clusters</h3>
            <div class="value">$total_clusters</div>
        </div>
        <div class="card critical">
            <h3>Critical Issues</h3>
            <div class="value">$critical_clusters</div>
            <div class="percentage">$(awk "BEGIN {printf \"%.1f\", ($critical_clusters / $total_clusters) * 100}")%</div>
        </div>
        <div class="card warning">
            <h3>Warnings</h3>
            <div class="value">$warning_clusters</div>
            <div class="percentage">$(awk "BEGIN {printf \"%.1f\", ($warning_clusters / $total_clusters) * 100}")%</div>
        </div>
        <div class="card healthy">
            <h3>Healthy</h3>
            <div class="value">$healthy_clusters</div>
            <div class="percentage">$(awk "BEGIN {printf \"%.1f\", ($healthy_clusters / $total_clusters) * 100}")%</div>
        </div>
EOF_HTML

    cat >> "$output_file" << 'EOF_HTML'
    </div>

    <div class="section">
        <h2>Cluster Health Status</h2>
        <table>
            <thead>
                <tr>
                    <th>Cluster Name</th>
                    <th>Operator Version</th>
                    <th>Status</th>
                    <th>Critical</th>
                    <th>Warnings</th>
                    <th>Timestamp</th>
                </tr>
            </thead>
            <tbody>
EOF_HTML

    # Add cluster rows
    jq -s -r '.[] | @json' "$INPUT_FILE" | while IFS= read -r cluster_json; do
        cluster_name=$(echo "$cluster_json" | jq -r '.cluster_name')
        operator_version=$(echo "$cluster_json" | jq -r '.operator_version')
        status=$(echo "$cluster_json" | jq -r '.health_summary.overall_status')
        critical=$(echo "$cluster_json" | jq -r '.health_summary.critical_count')
        warnings=$(echo "$cluster_json" | jq -r '.health_summary.warning_count')
        timestamp=$(echo "$cluster_json" | jq -r '.timestamp')

        status_class=$(echo "$status" | tr '[:upper:]' '[:lower:]')

        cat >> "$output_file" << EOF_HTML
                <tr>
                    <td><strong>$cluster_name</strong></td>
                    <td><code>$operator_version</code></td>
                    <td><span class="status-badge status-$status_class">$status</span></td>
                    <td>$critical</td>
                    <td>$warnings</td>
                    <td>$timestamp</td>
                </tr>
EOF_HTML
    done

    cat >> "$output_file" << 'EOF_HTML'
            </tbody>
        </table>
    </div>

    <div class="section">
        <h2>Detailed Cluster Reports</h2>
        <div class="cluster-details">
EOF_HTML

    # Add detailed cluster cards
    jq -s -r '.[] | @json' "$INPUT_FILE" | while IFS= read -r cluster_json; do
        cluster_name=$(echo "$cluster_json" | jq -r '.cluster_name')
        cluster_id=$(echo "$cluster_json" | jq -r '.cluster_id')
        status=$(echo "$cluster_json" | jq -r '.health_summary.overall_status')
        status_class=$(echo "$status" | tr '[:upper:]' '[:lower:]')

        cat >> "$output_file" << EOF_HTML
            <div class="cluster-card $status_class">
                <h3>$cluster_name <span style="font-weight: normal; font-size: 14px; color: #666;">($cluster_id)</span></h3>
EOF_HTML

        # Add health checks
        echo "$cluster_json" | jq -c '.health_checks[]' | while IFS= read -r check_json; do
            check_name=$(echo "$check_json" | jq -r '.check')
            check_status=$(echo "$check_json" | jq -r '.status')
            check_message=$(echo "$check_json" | jq -r '.message')
            check_status_class=$(echo "$check_status" | tr '[:upper:]' '[:lower:]')

            cat >> "$output_file" << EOF_HTML
                <div class="check-item $check_status_class">
                    <strong>$(echo "$check_name" | sed 's/_/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1'):</strong> $check_message
                </div>
EOF_HTML
        done

        echo "            </div>" >> "$output_file"
    done

    cat >> "$output_file" << 'EOF_HTML'
        </div>
    </div>

</body>
</html>
EOF_HTML

    echo "HTML report generated: $output_file"
}

#=============================================================================
# MAIN
#=============================================================================

case "$OUTPUT_FORMAT" in
    table)
        generate_table
        ;;
    html)
        generate_html "$HTML_FILE"
        ;;
    both)
        generate_table
        echo ""
        generate_html "$HTML_FILE"
        ;;
    *)
        echo "Error: Invalid format: $OUTPUT_FORMAT" >&2
        echo "Valid formats: table, html, both" >&2
        exit 1
        ;;
esac
