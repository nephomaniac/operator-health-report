#!/usr/bin/env bash
#
# Analyze CAMO Prometheus Metrics
#
# This script analyzes CAMO metrics collected from multiple clusters
# and generates reports comparing different operator versions.
#
# Features:
#   - Identifies current and previous operator versions
#   - Compares metrics between versions
#   - Detects clusters with issues (validation failures, missing secrets)
#   - Generates version-specific reports
#
# Usage:
#   ./analyze_camo_metrics.sh <metrics_csv_file>
#

set -euo pipefail

# Check if input file provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <metrics_csv_file>" >&2
    echo "" >&2
    echo "Example: $0 camo_metrics_20260203_120000.csv" >&2
    exit 1
fi

METRICS_FILE="$1"

# Validate input file
if [ ! -f "$METRICS_FILE" ]; then
    echo "Error: File not found: $METRICS_FILE" >&2
    exit 1
fi

echo "================================================================================"
echo "CAMO METRICS ANALYSIS"
echo "================================================================================"
echo "Input file: $METRICS_FILE"
echo ""

# Get unique operator versions and their counts
echo "Analyzing operator versions..."
versions_data=$(tail -n +2 "$METRICS_FILE" | cut -d',' -f4 | grep -v '^unknown$' | sort | uniq -c | sort -rn)

if [ -z "$versions_data" ]; then
    echo "Error: No valid operator versions found in metrics file" >&2
    exit 1
fi

echo "Operator versions found:"
echo "$versions_data" | awk '{printf "  %-20s (%d clusters)\n", $2, $1}'
echo ""

# Identify current and previous versions
current_version=$(echo "$versions_data" | head -1 | awk '{print $2}')
current_count=$(echo "$versions_data" | head -1 | awk '{print $1}')

if [ $(echo "$versions_data" | wc -l) -gt 1 ]; then
    previous_version=$(echo "$versions_data" | sed -n '2p' | awk '{print $2}')
    previous_count=$(echo "$versions_data" | sed -n '2p' | awk '{print $1}')
    has_multiple_versions=true
else
    previous_version=""
    previous_count=0
    has_multiple_versions=false
fi

echo "Current version:  $current_version ($current_count clusters)"
if [ "$has_multiple_versions" = true ]; then
    echo "Previous version: $previous_version ($previous_count clusters)"
fi
echo ""

# Function to analyze metrics for a specific version
analyze_version() {
    local version="$1"
    local label="$2"

    echo "================================================================================"
    echo "$label: $version"
    echo "================================================================================"

    # Extract data for this version
    version_data=$(grep ",${version}," "$METRICS_FILE")
    cluster_count=$(echo "$version_data" | wc -l | tr -d ' ')

    echo "Clusters: $cluster_count"
    echo ""

    # Count clusters by health status
    healthy_count=$(echo "$version_data" | grep -c ',HEALTHY,' || true)
    warning_count=$(echo "$version_data" | grep -c ',WARNING,' || true)
    critical_count=$(echo "$version_data" | grep -c ',CRITICAL,' || true)

    echo "Health Status:"
    echo "  HEALTHY:  $healthy_count"
    echo "  WARNING:  $warning_count"
    echo "  CRITICAL: $critical_count"
    echo ""

    # Analyze individual metrics (sum of 1's across all clusters)
    ga_secret_total=$(echo "$version_data" | awk -F',' '{sum+=$8} END {print sum}')
    pd_secret_total=$(echo "$version_data" | awk -F',' '{sum+=$9} END {print sum}')
    dms_secret_total=$(echo "$version_data" | awk -F',' '{sum+=$10} END {print sum}')
    am_secret_total=$(echo "$version_data" | awk -F',' '{sum+=$11} END {print sum}')
    am_ga_total=$(echo "$version_data" | awk -F',' '{sum+=$12} END {print sum}')
    am_pd_total=$(echo "$version_data" | awk -F',' '{sum+=$13} END {print sum}')
    am_dms_total=$(echo "$version_data" | awk -F',' '{sum+=$14} END {print sum}')
    managed_ns_cm_total=$(echo "$version_data" | awk -F',' '{sum+=$15} END {print sum}')
    ocp_ns_cm_total=$(echo "$version_data" | awk -F',' '{sum+=$16} END {print sum}')
    validation_failed_total=$(echo "$version_data" | awk -F',' '{sum+=$17} END {print sum}')

    echo "Metric Summary (clusters with metric = 1):"
    printf "  %-45s %3d / %d (%.1f%%)\n" "GoAlert secret exists" "$ga_secret_total" "$cluster_count" "$(awk "BEGIN {printf \"%.1f\", ($ga_secret_total/$cluster_count)*100}")"
    printf "  %-45s %3d / %d (%.1f%%)\n" "PagerDuty secret exists" "$pd_secret_total" "$cluster_count" "$(awk "BEGIN {printf \"%.1f\", ($pd_secret_total/$cluster_count)*100}")"
    printf "  %-45s %3d / %d (%.1f%%)\n" "DeadMansSnitch secret exists" "$dms_secret_total" "$cluster_count" "$(awk "BEGIN {printf \"%.1f\", ($dms_secret_total/$cluster_count)*100}")"
    printf "  %-45s %3d / %d (%.1f%%)\n" "AlertManager secret exists" "$am_secret_total" "$cluster_count" "$(awk "BEGIN {printf \"%.1f\", ($am_secret_total/$cluster_count)*100}")"
    printf "  %-45s %3d / %d (%.1f%%)\n" "AlertManager contains GoAlert config" "$am_ga_total" "$cluster_count" "$(awk "BEGIN {printf \"%.1f\", ($am_ga_total/$cluster_count)*100}")"
    printf "  %-45s %3d / %d (%.1f%%)\n" "AlertManager contains PagerDuty config" "$am_pd_total" "$cluster_count" "$(awk "BEGIN {printf \"%.1f\", ($am_pd_total/$cluster_count)*100}")"
    printf "  %-45s %3d / %d (%.1f%%)\n" "AlertManager contains DMS config" "$am_dms_total" "$cluster_count" "$(awk "BEGIN {printf \"%.1f\", ($am_dms_total/$cluster_count)*100}")"
    printf "  %-45s %3d / %d (%.1f%%)\n" "managed-namespaces ConfigMap exists" "$managed_ns_cm_total" "$cluster_count" "$(awk "BEGIN {printf \"%.1f\", ($managed_ns_cm_total/$cluster_count)*100}")"
    printf "  %-45s %3d / %d (%.1f%%)\n" "ocp-namespaces ConfigMap exists" "$ocp_ns_cm_total" "$cluster_count" "$(awk "BEGIN {printf \"%.1f\", ($ocp_ns_cm_total/$cluster_count)*100}")"
    printf "  %-45s %3d / %d (%.1f%%)\n" "AlertManager config validation FAILED" "$validation_failed_total" "$cluster_count" "$(awk "BEGIN {printf \"%.1f\", ($validation_failed_total/$cluster_count)*100}")"
    echo ""

    # List clusters with issues
    if [ $critical_count -gt 0 ]; then
        echo "Clusters with CRITICAL issues:"
        echo "$version_data" | grep ',CRITICAL,' | while IFS=',' read -r cluster_id cluster_name cluster_version op_ver namespace health_status health_issues rest; do
            echo "  - $cluster_name ($cluster_id)"
            echo "    Issues: $health_issues"
        done
        echo ""
    fi

    if [ $warning_count -gt 0 ]; then
        echo "Clusters with WARNING issues:"
        echo "$version_data" | grep ',WARNING,' | while IFS=',' read -r cluster_id cluster_name cluster_version op_ver namespace health_status health_issues rest; do
            echo "  - $cluster_name ($cluster_id)"
            echo "    Issues: $health_issues"
        done
        echo ""
    fi
}

# Analyze current version
analyze_version "$current_version" "CURRENT VERSION"

# Analyze previous version if exists
if [ "$has_multiple_versions" = true ]; then
    echo ""
    analyze_version "$previous_version" "PREVIOUS VERSION"

    echo ""
    echo "================================================================================"
    echo "VERSION COMPARISON"
    echo "================================================================================"
    echo "Comparing: $previous_version --> $current_version"
    echo ""

    # Compare health status percentages
    current_healthy_pct=$(grep ",${current_version}," "$METRICS_FILE" | grep -c ',HEALTHY,' | awk -v total=$current_count 'BEGIN{sum=0} {sum+=$1} END{printf "%.1f", (sum/total)*100}')
    previous_healthy_pct=$(grep ",${previous_version}," "$METRICS_FILE" | grep -c ',HEALTHY,' | awk -v total=$previous_count 'BEGIN{sum=0} {sum+=$1} END{printf "%.1f", (sum/total)*100}')

    echo "Health Status (% HEALTHY clusters):"
    echo "  Previous version: $previous_healthy_pct%"
    echo "  Current version:  $current_healthy_pct%"

    # Compare critical metric: AlertManager config validation
    current_validation_failed=$(grep ",${current_version}," "$METRICS_FILE" | awk -F',' '{sum+=$17} END {print sum}')
    previous_validation_failed=$(grep ",${previous_version}," "$METRICS_FILE" | awk -F',' '{sum+=$17} END {print sum}')

    current_validation_pct=$(awk -v failed=$current_validation_failed -v total=$current_count 'BEGIN{printf "%.1f", (failed/total)*100}')
    previous_validation_pct=$(awk -v failed=$previous_validation_failed -v total=$previous_count 'BEGIN{printf "%.1f", (failed/total)*100}')

    echo ""
    echo "AlertManager Config Validation Failures:"
    echo "  Previous version: $previous_validation_pct% ($previous_validation_failed/$previous_count clusters)"
    echo "  Current version:  $current_validation_pct% ($current_validation_failed/$current_count clusters)"
    echo ""
fi

echo "================================================================================"
echo "ANALYSIS COMPLETE"
echo "================================================================================"
echo ""

# Generate summary output files
output_dir=$(dirname "$METRICS_FILE")
base_name=$(basename "$METRICS_FILE" .csv)

echo "Generating version-specific reports..."

# Current version report
current_report="${output_dir}/${base_name}_${current_version}.csv"
echo "cluster_id,cluster_name,cluster_version,operator_version,namespace,health_status,health_issues,ga_secret_exists,pd_secret_exists,dms_secret_exists,am_secret_exists,am_secret_contains_ga,am_secret_contains_pd,am_secret_contains_dms,managed_namespaces_configmap_exists,ocp_namespaces_configmap_exists,alertmanager_config_validation_failed,timestamp" > "$current_report"
grep ",${current_version}," "$METRICS_FILE" >> "$current_report"
echo "  Current version report: $current_report"

# Previous version report (if exists)
if [ "$has_multiple_versions" = true ]; then
    previous_report="${output_dir}/${base_name}_${previous_version}.csv"
    echo "cluster_id,cluster_name,cluster_version,operator_version,namespace,health_status,health_issues,ga_secret_exists,pd_secret_exists,dms_secret_exists,am_secret_exists,am_secret_contains_ga,am_secret_contains_pd,am_secret_contains_dms,managed_namespaces_configmap_exists,ocp_namespaces_configmap_exists,alertmanager_config_validation_failed,timestamp" > "$previous_report"
    grep ",${previous_version}," "$METRICS_FILE" >> "$previous_report"
    echo "  Previous version report: $previous_report"
fi

echo ""
echo "Done!"
