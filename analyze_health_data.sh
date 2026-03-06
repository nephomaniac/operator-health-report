#!/usr/bin/env bash
#
# Analyze Health Check Data
#
# This script analyzes health check data collected from multiple clusters
# and provides a summary for production readiness assessment.
#
# Usage:
#   ./analyze_health_data.sh <health_data.csv>
#

set -eo pipefail

# Check if file provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <health_data.csv>" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 health_check_20250101_120000.csv" >&2
    exit 1
fi

HEALTH_FILE="$1"

# Check if file exists
if [ ! -f "$HEALTH_FILE" ]; then
    echo "Error: File not found: $HEALTH_FILE" >&2
    exit 1
fi

# Check for required tools
if ! command -v jq &> /dev/null; then
    echo "Warning: jq not found. Some features may be limited." >&2
fi

echo "================================================================================"
echo "HEALTH CHECK ANALYSIS"
echo "================================================================================"
echo "Data file: $HEALTH_FILE"
echo ""

# Count total records (excluding header)
total_records=$(tail -n +2 "$HEALTH_FILE" | wc -l | tr -d ' ')
echo "Total health checks: $total_records"

if [ "$total_records" -eq 0 ]; then
    echo ""
    echo "No data to analyze."
    exit 0
fi

echo ""

# Count by health status
echo "Health Status Distribution:"
healthy_count=$(tail -n +2 "$HEALTH_FILE" | cut -d, -f8 | grep -c "^HEALTHY$" || echo "0")
warning_count=$(tail -n +2 "$HEALTH_FILE" | cut -d, -f8 | grep -c "^WARNING$" || echo "0")
critical_count=$(tail -n +2 "$HEALTH_FILE" | cut -d, -f8 | grep -c "^CRITICAL$" || echo "0")

echo "  HEALTHY:  $healthy_count ($(( healthy_count * 100 / total_records ))%)"
echo "  WARNING:  $warning_count ($(( warning_count * 100 / total_records ))%)"
echo "  CRITICAL: $critical_count ($(( critical_count * 100 / total_records ))%)"
echo ""

# Operator version distribution
echo "Operator Version Distribution:"
tail -n +2 "$HEALTH_FILE" | cut -d, -f5 | sort | uniq -c | sort -rn | while read count version; do
    echo "  $version: $count clusters"
done
echo ""

# Calculate aggregate metrics
echo "Aggregate Metrics:"

# Total restarts across all clusters
total_restarts=$(tail -n +2 "$HEALTH_FILE" | cut -d, -f15 | awk '{s+=$1} END {print s}')
echo "  Total Restarts (all clusters): $total_restarts"

# Total error events across all clusters
total_errors=$(tail -n +2 "$HEALTH_FILE" | cut -d, -f16 | awk '{s+=$1} END {print s}')
echo "  Total Error Events (all clusters): $total_errors"

# Average uptime statistics
avg_min_uptime=$(tail -n +2 "$HEALTH_FILE" | cut -d, -f17 | awk '{s+=$1; c++} END {if(c>0) print int(s/c); else print 0}')
avg_max_uptime=$(tail -n +2 "$HEALTH_FILE" | cut -d, -f18 | awk '{s+=$1; c++} END {if(c>0) print int(s/c); else print 0}')

echo "  Average Min Pod Uptime: ${avg_min_uptime}s ($(( avg_min_uptime / 3600 ))h $(( (avg_min_uptime % 3600) / 60 ))m)"
echo "  Average Max Pod Uptime: ${avg_max_uptime}s ($(( avg_max_uptime / 3600 ))h $(( (avg_max_uptime % 3600) / 60 ))m)"
echo ""

# Clusters with issues (WARNING or CRITICAL)
echo "Clusters with Issues:"
if [ "$warning_count" -gt 0 ] || [ "$critical_count" -gt 0 ]; then
    tail -n +2 "$HEALTH_FILE" | awk -F, '$8 != "HEALTHY" {print $0}' | while IFS=, read -r operator cluster_id cluster_name cluster_version operator_version namespace deployment health_status health_issues rest; do
        # Remove quotes from health_issues if present
        health_issues=$(echo "$health_issues" | sed 's/^"//;s/"$//' | sed 's/;/, /g')
        echo ""
        echo "  Cluster: $cluster_name ($cluster_id)"
        echo "    Operator: $operator v$operator_version"
        echo "    Status: $health_status"
        if [ -n "$health_issues" ]; then
            echo "    Issues: $health_issues"
        fi
    done
else
    echo "  None - all clusters are HEALTHY"
fi

echo ""
echo "================================================================================"
echo "PRODUCTION READINESS ASSESSMENT"
echo "================================================================================"

# Determine overall readiness
if [ "$critical_count" -gt 0 ]; then
    echo "Status: NOT READY FOR PRODUCTION"
    echo ""
    echo "Recommendation:"
    echo "  ✗ DO NOT release to production"
    echo "  ✗ $critical_count cluster(s) have CRITICAL issues"
    echo "  → Investigate and resolve critical issues before proceeding"
elif [ "$warning_count" -gt $(( total_records / 2 )) ]; then
    echo "Status: REVIEW REQUIRED"
    echo ""
    echo "Recommendation:"
    echo "  ⚠ Review warnings before production release"
    echo "  ⚠ More than 50% of clusters ($warning_count/$total_records) have warnings"
    echo "  → Investigate warnings to ensure they are acceptable"
elif [ "$warning_count" -gt 0 ]; then
    echo "Status: READY WITH CAUTION"
    echo ""
    echo "Recommendation:"
    echo "  ⚠ Generally ready, but review warnings"
    echo "  ⚠ $warning_count cluster(s) have warnings ($(( warning_count * 100 / total_records ))%)"
    echo "  → Verify warnings are acceptable before proceeding"
else
    echo "Status: READY FOR PRODUCTION"
    echo ""
    echo "Recommendation:"
    echo "  ✓ All clusters are HEALTHY"
    echo "  ✓ No critical issues or warnings detected"
    echo "  ✓ Operator appears stable and ready for production release"
fi

echo "================================================================================"
echo ""
