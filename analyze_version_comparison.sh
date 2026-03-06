#!/usr/bin/env bash
#
# Analyze Version Comparison Data
#
# This script analyzes resource usage metrics collected for both previous
# and current operator versions to identify changes and trends.
#
# Features:
#   - Compares CPU and memory usage between versions
#   - Calculates percentage changes (increases/decreases)
#   - Identifies clusters with significant resource changes
#   - Generates statistical summaries
#   - Highlights regressions and improvements
#
# Usage:
#   ./analyze_version_comparison.sh <version_compare_csv_file>
#

set -euo pipefail

# Check if input file provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <version_compare_csv_file>" >&2
    echo "" >&2
    echo "Example: $0 version_compare_20260203_120000.csv" >&2
    exit 1
fi

COMPARE_FILE="$1"

# Validate input file
if [ ! -f "$COMPARE_FILE" ]; then
    echo "Error: File not found: $COMPARE_FILE" >&2
    exit 1
fi

echo "================================================================================"
echo "VERSION COMPARISON ANALYSIS"
echo "================================================================================"
echo "Input file: $COMPARE_FILE"
echo ""

# Count clusters and version periods
total_rows=$(tail -n +2 "$COMPARE_FILE" | wc -l | tr -d ' ')
clusters_with_previous=$(tail -n +2 "$COMPARE_FILE" | grep ',previous,' | cut -d',' -f2 | sort -u | wc -l | tr -d ' ')
total_clusters=$(tail -n +2 "$COMPARE_FILE" | cut -d',' -f2 | sort -u | wc -l | tr -d ' ')

echo "Data summary:"
echo "  Total data rows: $total_rows"
echo "  Total clusters: $total_clusters"
echo "  Clusters with version comparison data: $clusters_with_previous"
echo "  Clusters with only current version: $((total_clusters - clusters_with_previous))"

# Check for empty metrics
empty_cpu_rows=$(tail -n +2 "$COMPARE_FILE" | awk -F',' '$14 == "" || $14 == "0"' | wc -l | tr -d ' ')
empty_mem_rows=$(tail -n +2 "$COMPARE_FILE" | awk -F',' '$16 == "" || $16 == "0"' | wc -l | tr -d ' ')

if [ "$empty_cpu_rows" -gt 0 ] || [ "$empty_mem_rows" -gt 0 ]; then
    echo "  Rows with empty/zero CPU metrics: $empty_cpu_rows"
    echo "  Rows with empty/zero memory metrics: $empty_mem_rows"
    echo ""
    echo "  ⚠ WARNING: Many rows have missing or zero metric values"
    echo "    This indicates Prometheus queries may have failed during collection"
fi
echo ""

if [ "$clusters_with_previous" -eq 0 ]; then
    echo "Warning: No clusters have previous version data for comparison" >&2
    echo "This may indicate:" >&2
    echo "  - No operator upgrades in the lookback period" >&2
    echo "  - Insufficient Prometheus historical data" >&2
    exit 1
fi

# Identify operator versions
echo "Analyzing operator versions..."
versions=$(tail -n +2 "$COMPARE_FILE" | cut -d',' -f5 | grep -v '^none$' | sort -u)
version_count=$(echo "$versions" | wc -l | tr -d ' ')

if [ "$version_count" -eq 0 ]; then
    echo "Error: No operator versions found" >&2
    exit 1
fi

echo "Operator versions detected:"
echo "$versions" | while read -r ver; do
    count=$(tail -n +2 "$COMPARE_FILE" | grep -c ",$ver," || true)
    echo "  $ver ($count data points)"
done
echo ""

# Extract previous and current version identifiers
previous_versions=$(tail -n +2 "$COMPARE_FILE" | grep ',previous,' | cut -d',' -f5 | sort -u | tr '\n' ',' | sed 's/,$//')
current_versions=$(tail -n +2 "$COMPARE_FILE" | grep ',current,' | cut -d',' -f5 | sort -u | tr '\n' ',' | sed 's/,$//')

echo "Version progression:"
echo "  Previous: $previous_versions"
echo "  Current:  $current_versions"
echo ""

echo "================================================================================"
echo "RESOURCE USAGE COMPARISON"
echo "================================================================================"
echo ""

# Function to calculate statistics for a metric
calc_stats() {
    local period="$1"
    local metric_field="$2"

    tail -n +2 "$COMPARE_FILE" | grep ",$period," | cut -d',' -f"$metric_field" | \
        awk 'BEGIN {min=""; max=""; sum=0; count=0}
             {
                 # Skip empty, zero, or non-numeric values
                 if ($1 != "" && $1 != "0" && $1 ~ /^[0-9.]+$/) {
                     sum += $1;
                     if (max == "" || $1 > max) max = $1;
                     if (min == "" || $1 < min) min = $1;
                     count++;
                 }
             }
             END {
                 if (count > 0) {
                     print min, max, sum/count, count
                 } else {
                     print "0", "0", "0", "0"
                 }
             }'
}

# CPU Analysis
echo "CPU Usage Analysis (cores)"
echo "----------------------------------------"

# Previous version CPU stats
previous_cpu=$(calc_stats "previous" 14)  # max_cpu_cores field
prev_cpu_min=$(echo "$previous_cpu" | awk '{print $1}')
prev_cpu_max=$(echo "$previous_cpu" | awk '{print $2}')
prev_cpu_avg=$(echo "$previous_cpu" | awk '{print $3}')
prev_cpu_count=$(echo "$previous_cpu" | awk '{print $4}')

# Current version CPU stats
current_cpu=$(calc_stats "current" 14)
curr_cpu_min=$(echo "$current_cpu" | awk '{print $1}')
curr_cpu_max=$(echo "$current_cpu" | awk '{print $2}')
curr_cpu_avg=$(echo "$current_cpu" | awk '{print $3}')
curr_cpu_count=$(echo "$current_cpu" | awk '{print $4}')

if [ "$prev_cpu_count" -gt 0 ]; then
    echo "Previous version (max CPU):"
    printf "  Min: %.4f cores\n" "$prev_cpu_min"
    printf "  Max: %.4f cores\n" "$prev_cpu_max"
    printf "  Avg: %.4f cores\n" "$prev_cpu_avg"
    echo "  Data points: $prev_cpu_count"
else
    echo "Previous version (max CPU):"
    echo "  No valid data"
fi
echo ""

if [ "$curr_cpu_count" -gt 0 ]; then
    echo "Current version (max CPU):"
    printf "  Min: %.4f cores\n" "$curr_cpu_min"
    printf "  Max: %.4f cores\n" "$curr_cpu_max"
    printf "  Avg: %.4f cores\n" "$curr_cpu_avg"
    echo "  Data points: $curr_cpu_count"
else
    echo "Current version (max CPU):"
    echo "  No valid data"
fi
echo ""

# Calculate percent change (only if both have valid data)
if [ "$prev_cpu_count" -gt 0 ] && [ "$curr_cpu_count" -gt 0 ] && [ "$(echo "$prev_cpu_avg > 0" | bc -l)" -eq 1 ]; then
    cpu_change=$(awk -v prev="$prev_cpu_avg" -v curr="$curr_cpu_avg" 'BEGIN {print ((curr-prev)/prev)*100}')
    echo "Change:"
    printf "  Average CPU: %.2f%% " "$cpu_change"
    if (( $(echo "$cpu_change > 0" | bc -l) )); then
        echo "(INCREASE)"
    elif (( $(echo "$cpu_change < 0" | bc -l) )); then
        echo "(DECREASE)"
    else
        echo "(NO CHANGE)"
    fi
else
    echo "Change:"
    echo "  Cannot calculate (insufficient data)"
fi
echo ""

# Memory Analysis
echo "Memory Usage Analysis (bytes)"
echo "----------------------------------------"

# Previous version Memory stats
previous_memory=$(calc_stats "previous" 16)  # max_memory_bytes field
prev_mem_min=$(echo "$previous_memory" | awk '{print $1}')
prev_mem_max=$(echo "$previous_memory" | awk '{print $2}')
prev_mem_avg=$(echo "$previous_memory" | awk '{print $3}')
prev_mem_count=$(echo "$previous_memory" | awk '{print $4}')

# Current version Memory stats
current_memory=$(calc_stats "current" 16)
curr_mem_min=$(echo "$current_memory" | awk '{print $1}')
curr_mem_max=$(echo "$current_memory" | awk '{print $2}')
curr_mem_avg=$(echo "$current_memory" | awk '{print $3}')
curr_mem_count=$(echo "$current_memory" | awk '{print $4}')

# Convert to MB for display
prev_mem_min_mb=$(awk -v bytes="$prev_mem_min" 'BEGIN {printf "%.2f", bytes/1024/1024}')
prev_mem_max_mb=$(awk -v bytes="$prev_mem_max" 'BEGIN {printf "%.2f", bytes/1024/1024}')
prev_mem_avg_mb=$(awk -v bytes="$prev_mem_avg" 'BEGIN {printf "%.2f", bytes/1024/1024}')

curr_mem_min_mb=$(awk -v bytes="$curr_mem_min" 'BEGIN {printf "%.2f", bytes/1024/1024}')
curr_mem_max_mb=$(awk -v bytes="$curr_mem_max" 'BEGIN {printf "%.2f", bytes/1024/1024}')
curr_mem_avg_mb=$(awk -v bytes="$curr_mem_avg" 'BEGIN {printf "%.2f", bytes/1024/1024}')

if [ "$prev_mem_count" -gt 0 ]; then
    echo "Previous version (max memory):"
    echo "  Min: ${prev_mem_min_mb} MB"
    echo "  Max: ${prev_mem_max_mb} MB"
    echo "  Avg: ${prev_mem_avg_mb} MB"
    echo "  Data points: $prev_mem_count"
else
    echo "Previous version (max memory):"
    echo "  No valid data"
fi
echo ""

if [ "$curr_mem_count" -gt 0 ]; then
    echo "Current version (max memory):"
    echo "  Min: ${curr_mem_min_mb} MB"
    echo "  Max: ${curr_mem_max_mb} MB"
    echo "  Avg: ${curr_mem_avg_mb} MB"
    echo "  Data points: $curr_mem_count"
else
    echo "Current version (max memory):"
    echo "  No valid data"
fi
echo ""

# Calculate percent change (only if both have valid data)
if [ "$prev_mem_count" -gt 0 ] && [ "$curr_mem_count" -gt 0 ] && [ "$(echo "$prev_mem_avg > 0" | bc -l)" -eq 1 ]; then
    mem_change=$(awk -v prev="$prev_mem_avg" -v curr="$curr_mem_avg" 'BEGIN {print ((curr-prev)/prev)*100}')
    mem_change_mb=$(awk -v prev="$prev_mem_avg" -v curr="$curr_mem_avg" 'BEGIN {printf "%.2f", (curr-prev)/1024/1024}')

    echo "Change:"
    printf "  Average Memory: %.2f%% (%s MB) " "$mem_change" "$mem_change_mb"
    if (( $(echo "$mem_change > 0" | bc -l) )); then
        echo "(INCREASE)"
    elif (( $(echo "$mem_change < 0" | bc -l) )); then
        echo "(DECREASE)"
    else
        echo "(NO CHANGE)"
    fi
else
    echo "Change:"
    echo "  Cannot calculate (insufficient data)"
fi
echo ""

# Identify clusters with significant changes
echo "================================================================================"
echo "CLUSTERS WITH SIGNIFICANT CHANGES"
echo "================================================================================"
echo ""

# Create temporary file for per-cluster analysis
temp_file=$(mktemp)

# Process each cluster that has both previous and current data
tail -n +2 "$COMPARE_FILE" | cut -d',' -f2 | sort -u | while read -r cluster_id; do
    # Get previous and current data for this cluster
    prev_data=$(tail -n +2 "$COMPARE_FILE" | grep "^[^,]*,$cluster_id," | grep ',previous,')
    curr_data=$(tail -n +2 "$COMPARE_FILE" | grep "^[^,]*,$cluster_id," | grep ',current,')

    if [ -z "$prev_data" ] || [ -z "$curr_data" ]; then
        continue  # Skip clusters without both data points
    fi

    cluster_name=$(echo "$curr_data" | cut -d',' -f3)
    prev_version=$(echo "$prev_data" | cut -d',' -f5)
    curr_version=$(echo "$curr_data" | cut -d',' -f5)

    prev_cpu=$(echo "$prev_data" | cut -d',' -f14)
    curr_cpu=$(echo "$curr_data" | cut -d',' -f14)
    cpu_pct_change=$(awk -v prev="$prev_cpu" -v curr="$curr_cpu" 'BEGIN {if(prev>0) print ((curr-prev)/prev)*100; else print 0}')

    prev_mem=$(echo "$prev_data" | cut -d',' -f16)
    curr_mem=$(echo "$curr_data" | cut -d',' -f16)
    mem_pct_change=$(awk -v prev="$prev_mem" -v curr="$curr_mem" 'BEGIN {if(prev>0) print ((curr-prev)/prev)*100; else print 0}')

    # Output to temp file: cluster_id,cluster_name,prev_ver,curr_ver,cpu_change%,mem_change%
    echo "$cluster_id,$cluster_name,$prev_version,$curr_version,$cpu_pct_change,$mem_pct_change" >> "$temp_file"
done

# Check if we have any comparison data
if [ ! -s "$temp_file" ]; then
    echo "No clusters with complete previous and current version data"
else
    # Define threshold for "significant" change (e.g., >10%)
    THRESHOLD=10

    # CPU increases
    cpu_increases=$(awk -F',' -v thresh="$THRESHOLD" '$5 > thresh {print}' "$temp_file" | sort -t',' -k5 -rn)
    if [ -n "$cpu_increases" ]; then
        echo "Clusters with CPU INCREASES (>$THRESHOLD%):"
        echo "$cpu_increases" | while IFS=',' read -r cid cname pver cver cpu_chg mem_chg; do
            printf "  %s (%s): %.1f%% increase\n" "$cname" "$cid" "$cpu_chg"
            echo "    Version: $pver -> $cver"
        done
        echo ""
    fi

    # CPU decreases
    cpu_decreases=$(awk -F',' -v thresh="-$THRESHOLD" '$5 < thresh {print}' "$temp_file" | sort -t',' -k5 -n)
    if [ -n "$cpu_decreases" ]; then
        echo "Clusters with CPU DECREASES (>$THRESHOLD%):"
        echo "$cpu_decreases" | while IFS=',' read -r cid cname pver cver cpu_chg mem_chg; do
            printf "  %s (%s): %.1f%% decrease\n" "$cname" "$cid" "$cpu_chg"
            echo "    Version: $pver -> $cver"
        done
        echo ""
    fi

    # Memory increases
    mem_increases=$(awk -F',' -v thresh="$THRESHOLD" '$6 > thresh {print}' "$temp_file" | sort -t',' -k6 -rn)
    if [ -n "$mem_increases" ]; then
        echo "Clusters with MEMORY INCREASES (>$THRESHOLD%):"
        echo "$mem_increases" | while IFS=',' read -r cid cname pver cver cpu_chg mem_chg; do
            printf "  %s (%s): %.1f%% increase\n" "$cname" "$cid" "$mem_chg"
            echo "    Version: $pver -> $cver"
        done
        echo ""
    fi

    # Memory decreases
    mem_decreases=$(awk -F',' -v thresh="-$THRESHOLD" '$6 < thresh {print}' "$temp_file" | sort -t',' -k6 -n)
    if [ -n "$mem_decreases" ]; then
        echo "Clusters with MEMORY DECREASES (>$THRESHOLD%):"
        echo "$mem_decreases" | while IFS=',' read -r cid cname pver cver cpu_chg mem_chg; do
            printf "  %s (%s): %.1f%% decrease\n" "$cname" "$cid" "$mem_chg"
            echo "    Version: $pver -> $cver"
        done
        echo ""
    fi

    # Stable clusters (changes within threshold)
    stable_clusters=$(awk -F',' -v thresh="$THRESHOLD" '$5 >= -thresh && $5 <= thresh && $6 >= -thresh && $6 <= thresh {print}' "$temp_file" | wc -l | tr -d ' ')
    echo "Stable clusters (changes within ±$THRESHOLD%): $stable_clusters"
    echo ""
fi

# Cleanup
rm -f "$temp_file"

echo "================================================================================"
echo "SUMMARY"
echo "================================================================================"

# Overall assessment
echo "Overall Assessment:"
echo ""

# CPU assessment
if [ "$prev_cpu_count" -gt 0 ] && [ "$curr_cpu_count" -gt 0 ] && [ -n "$cpu_change" ]; then
    if (( $(echo "$cpu_change > $THRESHOLD" | bc -l) )); then
        echo "  ⚠ CPU: REGRESSION - Average CPU increased by $(printf %.1f "$cpu_change")%"
    elif (( $(echo "$cpu_change < -$THRESHOLD" | bc -l) )); then
        echo "  ✓ CPU: IMPROVEMENT - Average CPU decreased by $(printf %.1f "${cpu_change#-}")%"
    else
        echo "  ✓ CPU: STABLE - Average CPU change within ±$THRESHOLD%"
    fi
else
    echo "  ℹ CPU: INSUFFICIENT DATA - Cannot assess (need both previous and current metrics)"
fi

# Memory assessment
if [ "$prev_mem_count" -gt 0 ] && [ "$curr_mem_count" -gt 0 ] && [ -n "$mem_change" ]; then
    if (( $(echo "$mem_change > $THRESHOLD" | bc -l) )); then
        echo "  ⚠ MEMORY: REGRESSION - Average memory increased by $(printf %.1f "$mem_change")%"
    elif (( $(echo "$mem_change < -$THRESHOLD" | bc -l) )); then
        echo "  ✓ MEMORY: IMPROVEMENT - Average memory decreased by $(printf %.1f "${mem_change#-}")%"
    else
        echo "  ✓ MEMORY: STABLE - Average memory change within ±$THRESHOLD%"
    fi
else
    echo "  ℹ MEMORY: INSUFFICIENT DATA - Cannot assess (need both previous and current metrics)"
fi

echo ""
echo "Recommendation:"
if [ "$prev_cpu_count" -eq 0 ] || [ "$curr_cpu_count" -eq 0 ] || [ "$prev_mem_count" -eq 0 ] || [ "$curr_mem_count" -eq 0 ]; then
    echo "  ⚠ Insufficient metric data for comprehensive analysis"
    echo "    Many clusters are missing CPU/memory metrics"
    echo "    Possible causes:"
    echo "      - Prometheus queries failed (check Prometheus availability)"
    echo "      - Operator pods not running during metric collection period"
    echo "      - Prometheus data retention too short for historical queries"
    echo ""
    echo "    Recommendations:"
    echo "      1. Verify Prometheus is accessible and retention is ≥24h"
    echo "      2. Re-run collection with verbose logging to debug failures"
    echo "      3. Focus analysis on clusters with complete data"
elif [ -n "$cpu_change" ] && [ -n "$mem_change" ]; then
    if (( $(echo "$cpu_change > 20" | bc -l) )) || (( $(echo "$mem_change > 20" | bc -l) )); then
        echo "  ⚠ Significant resource usage increase detected"
        echo "    Consider investigating the cause before wider rollout"
    elif (( $(echo "$cpu_change < -20" | bc -l) )) || (( $(echo "$mem_change < -20" | bc -l) )); then
        echo "  ✓ Significant resource usage improvement detected"
        echo "    Version upgrade shows positive resource efficiency gains"
    else
        echo "  ✓ Resource usage remains stable across version upgrade"
        echo "    No significant performance regressions detected"
    fi
else
    echo "  ℹ Unable to provide recommendation due to incomplete data"
fi

echo ""
echo "================================================================================"
echo "ANALYSIS COMPLETE"
echo "================================================================================"
echo ""
