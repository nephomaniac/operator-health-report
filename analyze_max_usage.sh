#!/bin/bash
# Analyze MAX resource usage (peak values)

CSV_FILE="$1"

echo "================================================================================"
echo "CAMO MAX RESOURCE USAGE ANALYSIS"
echo "================================================================================"
echo ""

# Previous version max usage
echo "Previous Versions - PEAK USAGE:"
tail -n +2 "$CSV_FILE" | awk -F',' '
$6=="previous" && $14 > 0 && $16 > 0 {
    if ($14 > max_cpu) max_cpu = $14
    if ($16 > max_mem) max_mem = $16
    if (min_cpu == 0 || $14 < min_cpu) min_cpu = $14
    if (min_mem == 0 || $16 < min_mem) min_mem = $16
    sum_cpu += $14
    sum_mem += $16
    count++
}
END {
    if (count > 0) {
        printf "  Peak CPU (highest): %.6f cores (%.2f millicores)\n", max_cpu, max_cpu*1000
        printf "  Lowest CPU: %.6f cores (%.2f millicores)\n", min_cpu, min_cpu*1000
        printf "  Avg of max CPU: %.6f cores (%.2f millicores)\n", sum_cpu/count, (sum_cpu/count)*1000
        printf "  \n"
        printf "  Peak Memory (highest): %.2f MB\n", max_mem/1048576
        printf "  Lowest Memory: %.2f MB\n", min_mem/1048576
        printf "  Avg of max Memory: %.2f MB\n", sum_mem/count/1048576
        printf "  Data points: %d\n", count
    }
}'

echo ""
echo "Current Versions - PEAK USAGE:"
tail -n +2 "$CSV_FILE" | awk -F',' '
$6=="current" && $14 > 0 && $16 > 0 {
    if ($14 > max_cpu) max_cpu = $14
    if ($16 > max_mem) max_mem = $16
    if (min_cpu == 0 || $14 < min_cpu) min_cpu = $14
    if (min_mem == 0 || $16 < min_mem) min_mem = $16
    sum_cpu += $14
    sum_mem += $16
    count++
}
END {
    if (count > 0) {
        printf "  Peak CPU (highest): %.6f cores (%.2f millicores)\n", max_cpu, max_cpu*1000
        printf "  Lowest CPU: %.6f cores (%.2f millicores)\n", min_cpu, min_cpu*1000
        printf "  Avg of max CPU: %.6f cores (%.2f millicores)\n", sum_cpu/count, (sum_cpu/count)*1000
        printf "  \n"
        printf "  Peak Memory (highest): %.2f MB\n", max_mem/1048576
        printf "  Lowest Memory: %.2f MB\n", min_mem/1048576
        printf "  Avg of max Memory: %.2f MB\n", sum_mem/count/1048576
        printf "  Data points: %d\n", count
    }
}'

echo ""
echo "================================================================================"
echo "COMPARISON (focus on PEAK values - the highest observed)"
echo "================================================================================"

tail -n +2 "$CSV_FILE" | awk -F',' '
$6=="previous" && $14 > 0 && $16 > 0 {
    if ($14 > prev_max_cpu) prev_max_cpu = $14
    if ($16 > prev_max_mem) prev_max_mem = $16
}
$6=="current" && $14 > 0 && $16 > 0 {
    if ($14 > curr_max_cpu) curr_max_cpu = $14
    if ($16 > curr_max_mem) curr_max_mem = $16
}
END {
    printf "\nPEAK CPU across all clusters:\n"
    printf "  Previous versions (worst case): %.6f cores (%.2f millicores)\n", prev_max_cpu, prev_max_cpu*1000
    printf "  Current versions (worst case):  %.6f cores (%.2f millicores)\n", curr_max_cpu, curr_max_cpu*1000
    cpu_change = ((curr_max_cpu - prev_max_cpu) / prev_max_cpu) * 100
    printf "  Change: %.1f%%\n", cpu_change
    
    printf "\nPEAK MEMORY across all clusters:\n"
    printf "  Previous versions (worst case): %.2f MB\n", prev_max_mem/1048576
    printf "  Current versions (worst case):  %.2f MB\n", curr_max_mem/1048576
    mem_change = ((curr_max_mem - prev_max_mem) / prev_max_mem) * 100
    printf "  Change: %.1f%%\n", mem_change
}
'

echo ""
echo "================================================================================"
echo "TOP 10 CLUSTERS BY MAX MEMORY USAGE (Current Version)"
echo "================================================================================"
tail -n +2 "$CSV_FILE" | awk -F',' '$6=="current" && $16 > 0 {print $3 "," $5 "," $16/1048576}' | sort -t',' -k3 -rn | head -10 | awk -F',' '{printf "  %-30s %-20s %6.2f MB\n", $1, $2, $3}'

echo ""
echo "================================================================================"

