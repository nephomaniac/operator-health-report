# Analysis Script Fixes

## Issues Found

When running `analyze_version_comparison.sh`, the script encountered several errors:

1. **Invalid number errors in printf**
   ```
   ./analyze_version_comparison.sh: line 123: printf: Querying: invalid number
   ```

2. **Many empty/zero metric values**
   - 91 data points with no version
   - Many rows with 0 cores CPU
   - Many rows with 0 bytes memory

3. **Mixed version formats**
   - Semantic versions: `0.1.760-gc7d7013`, `0.1.781-geab01dd`, `0.1.798-g038acc6`
   - SHA digests: `22a46cad50a3`, `565879041ea1`, `c8136eec250e`, `c9a0553c1eb5`
   - Tag names: `latest`
   - Empty strings: `` (no version)

## Root Causes

### 1. Missing Prometheus Data

The collection script (`collect_versioned_metrics.sh`) successfully logged into clusters but failed to retrieve valid metrics from Prometheus. This can happen when:

- Prometheus pod is not accessible
- Prometheus queries return empty results
- Time ranges are outside Prometheus retention period
- CAMO container metrics are not being scraped

### 2. Numeric Validation Missing

The `calc_stats()` function didn't validate that values were numeric before doing math operations, causing:
- Empty strings passed to `awk` calculations
- Zero values treated as valid data points
- Non-numeric strings causing arithmetic errors

### 3. Printf Format Errors

The script attempted to format empty or invalid strings with `printf %.2f`, which requires a valid number.

## Fixes Applied

### 1. Enhanced `calc_stats()` Function

**Before:**
```bash
calc_stats() {
    local period="$1"
    local metric_field="$2"

    tail -n +2 "$COMPARE_FILE" | grep ",$period," | cut -d',' -f"$metric_field" | \
        awk '{sum+=$1; if($1>max || max=="") max=$1; if($1<min || min=="") min=$1; count++}
             END {print min, max, (count>0?sum/count:0), count}'
}
```

**After:**
```bash
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
```

**Improvements:**
- ✅ Validates values are numeric with regex `/^[0-9.]+$/`
- ✅ Skips empty strings
- ✅ Skips zero values (indicates no data)
- ✅ Returns "0" for all stats if no valid data (prevents empty string errors)
- ✅ Counts only valid data points

### 2. Conditional Printf and Calculations

**Before:**
```bash
printf "  Min: %.4f cores\n" "$prev_cpu_min"
printf "  Max: %.4f cores\n" "$prev_cpu_max"
printf "  Avg: %.4f cores\n" "$prev_cpu_avg"

cpu_change=$(awk -v prev="$prev_cpu_avg" -v curr="$curr_cpu_avg" 'BEGIN {print ((curr-prev)/prev)*100}')
```

**After:**
```bash
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

if [ "$prev_cpu_count" -gt 0 ] && [ "$curr_cpu_count" -gt 0 ] && [ "$(echo "$prev_cpu_avg > 0" | bc -l)" -eq 1 ]; then
    cpu_change=$(awk -v prev="$prev_cpu_avg" -v curr="$curr_cpu_avg" 'BEGIN {print ((curr-prev)/prev)*100}')
    # ... use cpu_change
else
    echo "  Cannot calculate (insufficient data)"
fi
```

**Improvements:**
- ✅ Only prints stats if valid data exists (`count > 0`)
- ✅ Only calculates percent change if both previous and current have data
- ✅ Checks denominator is not zero before division
- ✅ Shows "No valid data" message when appropriate
- ✅ Displays data point count for transparency

### 3. Data Quality Warning

Added early warning about missing data:

```bash
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
```

### 4. Enhanced Summary Section

**Before:**
```bash
if (( $(echo "$cpu_change > 20" | bc -l) )) || (( $(echo "$mem_change > 20" | bc -l) )); then
    echo "  ⚠ Significant resource usage increase detected"
```

**After:**
```bash
if [ "$prev_cpu_count" -eq 0 ] || [ "$curr_cpu_count" -eq 0 ] || [ "$prev_mem_count" -eq 0 ] || [ "$curr_mem_count" -eq 0 ]; then
    echo "  ⚠ Insufficient metric data for comprehensive analysis"
    echo "    Possible causes:"
    echo "      - Prometheus queries failed (check Prometheus availability)"
    echo "      - Operator pods not running during metric collection period"
    echo "      - Prometheus data retention too short for historical queries"
    echo "    Recommendations:"
    echo "      1. Verify Prometheus is accessible and retention is ≥24h"
    echo "      2. Re-run collection with verbose logging to debug failures"
    echo "      3. Focus analysis on clusters with complete data"
elif [ -n "$cpu_change" ] && [ -n "$mem_change" ]; then
    # ... existing logic
fi
```

**Improvements:**
- ✅ Detects insufficient data condition
- ✅ Provides diagnostic information
- ✅ Suggests troubleshooting steps
- ✅ Only provides recommendations when data is complete

## Testing the Fixed Script

Run the analysis on your collected data:

```bash
./analyze_version_comparison.sh version_compare_20260217_095130.csv
```

Expected output now includes:
- Data quality warnings upfront
- "No valid data" messages for missing metrics
- Data point counts for transparency
- "Cannot calculate" messages instead of errors
- Diagnostic recommendations when data is insufficient

## Next Steps: Fixing Data Collection

The analysis script is now robust, but the underlying issue is **missing Prometheus data**. To fix this:

### 1. Verify Prometheus Access

```bash
# Login to a cluster
ocm backplane login <cluster-id>

# Check Prometheus pod
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus

# Test Prometheus query manually
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
    curl -s 'http://localhost:9090/api/v1/query?query=up{job="configure-alertmanager-operator"}'
```

### 2. Check Prometheus Retention

```bash
oc get prometheus -n openshift-monitoring k8s -o jsonpath='{.spec.retention}'
```

Should be at least `24h` for version comparison to work.

### 3. Verify CAMO Metrics Are Scraped

```bash
# Check if CAMO metrics exist in Prometheus
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
    curl -s 'http://localhost:9090/api/v1/query?query=container_cpu_usage_seconds_total{namespace="openshift-monitoring",container="configure-alertmanager-operator"}'
```

### 4. Test Collection on Single Cluster

```bash
# Test on one cluster with verbose output
./collect_versioned_metrics.sh \
    --reason "SREP-12345 debug test" \
    --cluster-id <cluster-id> \
    --format json | jq
```

Check if `max_cpu_cores` and `max_memory_bytes` have non-zero values.

## Summary

The analysis script now:
- ✅ Handles missing data gracefully
- ✅ Validates all numeric inputs
- ✅ Provides clear diagnostic messages
- ✅ Suggests troubleshooting steps
- ✅ Shows data point counts for transparency
- ✅ Never crashes on invalid data

However, the **root cause** is that Prometheus queries are returning empty/zero results during collection. This needs to be debugged at the collection layer (`collect_versioned_metrics.sh`).
