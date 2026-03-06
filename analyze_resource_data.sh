#!/usr/bin/env bash
#
# Analyze Resource Usage Data
#
# This script analyzes CSV data collected from multiple clusters
# and provides recommendations for resource requests and limits.
#
# Usage:
#   ./analyze_resource_data.sh [OPTIONS] <csv_file>
#
# Options:
#   --mem              Sort clusters by memory usage (default: CPU)
#   --name-len LEN     Max characters for cluster name (default: 27, 0=hide column)
#   --id-len LEN       Max characters for cluster ID (default: 32, 0=hide column)
#   --ver-len LEN      Max characters for version (default: 12, 0=hide column)
#

set -euo pipefail

# Parse arguments
SORT_BY="cpu"
CSV_FILE=""
NAME_LEN=27
ID_LEN=32
VER_LEN=12
OP_VER_LEN=12

while [ $# -gt 0 ]; do
    case "$1" in
        --mem)
            SORT_BY="mem"
            shift
            ;;
        --op)
            SORT_BY="op"
            shift
            ;;
        --name-len)
            NAME_LEN="$2"
            shift 2
            ;;
        --id-len)
            ID_LEN="$2"
            shift 2
            ;;
        --ver-len)
            VER_LEN="$2"
            shift 2
            ;;
        --op-ver-len)
            OP_VER_LEN="$2"
            shift 2
            ;;
        *)
            CSV_FILE="$1"
            shift
            ;;
    esac
done

if [ -z "$CSV_FILE" ]; then
    echo "Usage: $0 [OPTIONS] <csv_file>"
    echo ""
    echo "Options:"
    echo "  --mem              Sort clusters by memory usage (default: CPU)"
    echo "  --op               Sort clusters by operator version"
    echo "  --name-len LEN     Max characters for cluster name (default: 27, 0=hide column)"
    echo "  --id-len LEN       Max characters for cluster ID (default: 32, 0=hide column)"
    echo "  --ver-len LEN      Max characters for cluster version (default: 12, 0=hide column)"
    echo "  --op-ver-len LEN   Max characters for operator version (default: 12, 0=hide column)"
    echo ""
    echo "Examples:"
    echo "  $0 all_clusters_data.csv"
    echo "  $0 --mem all_clusters_data.csv"
    echo "  $0 --op all_clusters_data.csv"
    echo "  $0 --name-len 20 all_clusters_data.csv"
    echo "  $0 --id-len 0 all_clusters_data.csv  # Hide cluster ID column"
    echo "  $0 --ver-len 15 all_clusters_data.csv"
    echo "  $0 --op-ver-len 15 all_clusters_data.csv"
    exit 1
fi

if [ ! -f "$CSV_FILE" ]; then
    echo "Error: File not found: $CSV_FILE"
    exit 1
fi

echo "================================================================================"
echo "RESOURCE USAGE ANALYSIS"
echo "================================================================================"
echo "Input file: $CSV_FILE"
echo ""

# Count clusters
total_clusters=$(tail -n +2 "$CSV_FILE" | wc -l | tr -d ' ')
echo "Total clusters analyzed: $total_clusters"
echo ""

if [ "$total_clusters" -eq 0 ]; then
    echo "Error: No data found in CSV file"
    exit 1
fi

# Check if this is an operator-version-only CSV
header=$(head -1 "$CSV_FILE")
num_columns=$(echo "$header" | awk -F',' '{print NF}')
is_op_ver_only=false
has_operator_column=false

# Check if CSV has operator column (first column)
if echo "$header" | grep -q "^operator,"; then
    has_operator_column=true
fi

# Detect operator-version-only CSV formats
if [ "$has_operator_column" = true ] && [ "$num_columns" -eq 5 ] && echo "$header" | grep -q "operator_version" && ! echo "$header" | grep -q "namespace"; then
    # New format: operator,cluster_id,cluster_name,cluster_version,operator_version
    is_op_ver_only=true
    echo "Note: Operator-version-only CSV detected (with operator column). Skipping resource usage analysis."
    echo ""
elif [ "$num_columns" -eq 4 ] && echo "$header" | grep -q "operator_version" && ! echo "$header" | grep -q "namespace" && ! echo "$header" | grep -q "^operator,"; then
    # Legacy format: cluster_id,cluster_name,cluster_version,operator_version
    is_op_ver_only=true
    echo "Note: Operator-version-only CSV detected. Skipping resource usage analysis."
    echo ""
elif [ "$num_columns" -eq 3 ] && echo "$header" | grep -q "operator_version"; then
    # Old legacy 3-column format (cluster_id,cluster_name,operator_version)
    is_op_ver_only=true
    echo "Note: Operator-version-only CSV detected (legacy 3-column format). Skipping resource usage analysis."
    echo ""
fi

# Get list of unique operators if operator column exists
if [ "$has_operator_column" = true ]; then
    # Extract operators from well-formed CSV lines only (lines with correct number of commas)
    if [ "$is_op_ver_only" = true ]; then
        # Operator-version-only format: 5 fields = 4 commas
        operators=($(tail -n +2 "$CSV_FILE" | awk -F',' 'NF==5 {print $1}' | sort -u))
    else
        # Full format: 19 fields = 18 commas
        operators=($(tail -n +2 "$CSV_FILE" | awk -F',' 'NF==19 {print $1}' | sort -u))
    fi

    if [ ${#operators[@]} -eq 0 ]; then
        echo "Warning: No valid operators found in CSV file"
        echo "CSV may be malformed or empty"
        exit 1
    fi

    echo "Operators found: ${operators[@]}"
    echo ""
fi

# Function to analyze resource usage for a specific operator or all data
analyze_resources() {
    local operator_filter="$1"
    local operator_label="$2"
    local cpu_col="$3"
    local mem_col="$4"

    if [ -n "$operator_label" ]; then
        echo "================================================================================"
        echo "RESOURCE ANALYSIS FOR: $operator_label"
        echo "================================================================================"
        echo ""
    fi

# Extract CPU values
echo "================================================================================"
echo "CPU ANALYSIS (in cores)"
echo "================================================================================"
echo ""

# Get all max 24h CPU values
if [ -n "$operator_filter" ]; then
    # Filter by operator
    cpu_values=$(tail -n +2 "$CSV_FILE" | grep "^${operator_filter}," | awk -F',' -v col="$cpu_col" '{print $col}' | grep -v '^$' | grep -v '^0$' || true)
else
    # No filter, get all data
    cpu_values=$(tail -n +2 "$CSV_FILE" | awk -F',' -v col="$cpu_col" '{print $col}' | grep -v '^$' | grep -v '^0$' || true)
fi

if [ -z "$cpu_values" ]; then
    echo "Warning: No CPU data found"
else
    # Calculate statistics
    cpu_min=$(echo "$cpu_values" | sort -n | head -1)
    cpu_max=$(echo "$cpu_values" | sort -n | tail -1)
    cpu_avg=$(echo "$cpu_values" | awk '{sum+=$1; count++} END {if(count>0) printf "%.10f", sum/count; else print 0}')
    cpu_p50=$(echo "$cpu_values" | sort -n | awk '{arr[NR]=$1} END {print arr[int(NR/2)+1]}')
    cpu_p90=$(echo "$cpu_values" | sort -n | awk '{arr[NR]=$1} END {print arr[int(NR*0.9)+1]}')
    cpu_p95=$(echo "$cpu_values" | sort -n | awk '{arr[NR]=$1} END {print arr[int(NR*0.95)+1]}')
    cpu_p99=$(echo "$cpu_values" | sort -n | awk '{arr[NR]=$1} END {print arr[int(NR*0.99)+1]}')

    echo "Max 24h CPU Usage Statistics:"
    echo "  Min:         $cpu_min cores"
    echo "  Max:         $cpu_max cores"
    echo "  Average:     $cpu_avg cores"
    echo "  50th %ile:   $cpu_p50 cores"
    echo "  90th %ile:   $cpu_p90 cores"
    echo "  95th %ile:   $cpu_p95 cores"
    echo "  99th %ile:   $cpu_p99 cores"
    echo ""

    # Recommendations
    echo "CPU Recommendations:"
    echo "  Conservative (P95):  ${cpu_p95} cores (~$(echo "$cpu_p95 * 1000" | bc | cut -d. -f1)m)"
    echo "  Aggressive (P90):    ${cpu_p90} cores (~$(echo "$cpu_p90 * 1000" | bc | cut -d. -f1)m)"
    echo "  Request (P50):       ${cpu_p50} cores (~$(echo "$cpu_p50 * 1000" | bc | cut -d. -f1)m)"

    # Add 20% headroom for limit
    cpu_limit_p95=$(echo "$cpu_p95 * 1.2" | bc)
    cpu_limit_p90=$(echo "$cpu_p90 * 1.2" | bc)
    echo ""
    echo "  Suggested CPU Request: $(echo "$cpu_p50 * 1000" | bc | cut -d. -f1)m"
    echo "  Suggested CPU Limit:   $(echo "$cpu_limit_p95 * 1000" | bc | cut -d. -f1)m (P95 + 20% headroom)"
fi

echo ""

# Extract Memory values
echo "================================================================================"
echo "MEMORY ANALYSIS"
echo "================================================================================"
echo ""

# Get all max 24h memory values
if [ -n "$operator_filter" ]; then
    # Filter by operator
    mem_values=$(tail -n +2 "$CSV_FILE" | grep "^${operator_filter}," | awk -F',' -v col="$mem_col" '{print $col}' | grep -v '^$' | grep -v '^0$' || true)
else
    # No filter, get all data
    mem_values=$(tail -n +2 "$CSV_FILE" | awk -F',' -v col="$mem_col" '{print $col}' | grep -v '^$' | grep -v '^0$' || true)
fi

if [ -z "$mem_values" ]; then
    echo "Warning: No memory data found"
else
    # Calculate statistics
    mem_min=$(echo "$mem_values" | sort -n | head -1)
    mem_max=$(echo "$mem_values" | sort -n | tail -1)
    mem_avg=$(echo "$mem_values" | awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print 0}')
    mem_p50=$(echo "$mem_values" | sort -n | awk '{arr[NR]=$1} END {print arr[int(NR/2)+1]}')
    mem_p90=$(echo "$mem_values" | sort -n | awk '{arr[NR]=$1} END {print arr[int(NR*0.9)+1]}')
    mem_p95=$(echo "$mem_values" | sort -n | awk '{arr[NR]=$1} END {print arr[int(NR*0.95)+1]}')
    mem_p99=$(echo "$mem_values" | sort -n | awk '{arr[NR]=$1} END {print arr[int(NR*0.99)+1]}')

    # Convert to MiB
    mem_min_mib=$(echo "$mem_min / 1024 / 1024" | bc)
    mem_max_mib=$(echo "$mem_max / 1024 / 1024" | bc)
    mem_avg_mib=$(echo "$mem_avg / 1024 / 1024" | bc)
    mem_p50_mib=$(echo "$mem_p50 / 1024 / 1024" | bc)
    mem_p90_mib=$(echo "$mem_p90 / 1024 / 1024" | bc)
    mem_p95_mib=$(echo "$mem_p95 / 1024 / 1024" | bc)
    mem_p99_mib=$(echo "$mem_p99 / 1024 / 1024" | bc)

    echo "Max 24h Memory Usage Statistics:"
    echo "  Min:         $mem_min_mib MiB ($mem_min bytes)"
    echo "  Max:         $mem_max_mib MiB ($mem_max bytes)"
    echo "  Average:     $mem_avg_mib MiB ($mem_avg bytes)"
    echo "  50th %ile:   $mem_p50_mib MiB ($mem_p50 bytes)"
    echo "  90th %ile:   $mem_p90_mib MiB ($mem_p90 bytes)"
    echo "  95th %ile:   $mem_p95_mib MiB ($mem_p95 bytes)"
    echo "  99th %ile:   $mem_p99_mib MiB ($mem_p99 bytes)"
    echo ""

    # Recommendations
    echo "Memory Recommendations:"
    echo "  Conservative (P95):  ${mem_p95_mib} MiB"
    echo "  Aggressive (P90):    ${mem_p90_mib} MiB"
    echo "  Request (P50):       ${mem_p50_mib} MiB"

    # Add 20% headroom for limit
    mem_limit_p95=$(echo "$mem_p95_mib * 1.2" | bc | cut -d. -f1)
    echo ""
    echo "  Suggested Memory Request: ${mem_p50_mib}Mi"
    echo "  Suggested Memory Limit:   ${mem_limit_p95}Mi (P95 + 20% headroom)"
fi

echo ""
echo "================================================================================"
echo "RECOMMENDED RESOURCE CONFIGURATION"
echo "================================================================================"
echo ""

if [ -n "$cpu_values" ] && [ -n "$mem_values" ]; then
    cpu_request_m=$(echo "$cpu_p50 * 1000" | bc | cut -d. -f1)
    cpu_limit_m=$(echo "$cpu_limit_p95 * 1000" | bc | cut -d. -f1)

    cat << EOF
resources:
  requests:
    cpu: ${cpu_request_m}m        # P50 - typical usage
    memory: ${mem_p50_mib}Mi      # P50 - typical usage
  limits:
    cpu: ${cpu_limit_m}m          # P95 + 20% headroom
    memory: ${mem_limit_p95}Mi    # P95 + 20% headroom
EOF
else
    echo "Insufficient data to generate recommendations"
fi

echo ""
echo "================================================================================"
echo "NOTES"
echo "================================================================================"
echo "- P50 (median) used for requests - typical steady-state usage"
echo "- P95 + 20% headroom used for limits - handles spikes without OOMKill"
echo "- Review clusters with unusually high values for anomalies"
echo "- Consider separate configurations for different cluster sizes if needed"
echo ""
}  # End of analyze_resources function

# Skip CPU/Memory analysis for operator-version-only CSV
if [ "$is_op_ver_only" = false ]; then

# Determine column positions based on whether operator column exists
if [ "$has_operator_column" = true ]; then
    # With operator column: max_24h_cpu is column 15, max_24h_mem is column 18
    cpu_col=15
    mem_col=18

    # Analyze each operator separately
    for op in "${operators[@]}"; do
        analyze_resources "$op" "$op" "$cpu_col" "$mem_col"
    done
else
    # Without operator column (legacy): max_24h_cpu is column 14, max_24h_mem is column 17
    cpu_col=14
    mem_col=17

    # Analyze all data together
    analyze_resources "" "" "$cpu_col" "$mem_col"
fi

fi  # End of resource usage analysis (skipped for operator-version-only CSV)

# Check if CSV has cluster_name column (column 2)
header=$(head -1 "$CSV_FILE")
has_cluster_name=false
if echo "$header" | grep -q "cluster_name"; then
    has_cluster_name=true
fi

# Check if CSV has operator_version column (column 4)
has_operator_version=false
if echo "$header" | grep -q "operator_version"; then
    has_operator_version=true
fi

# Note: is_op_ver_only is already set earlier in the script

#================================================================================"
# TABLE DISPLAY SECTION
#================================================================================"

# Determine if we need to loop through operators
operators_to_display=()
if [ "$has_operator_column" = true ] && [ "${#operators[@]}" -gt 0 ]; then
    operators_to_display=("${operators[@]}")
else
    operators_to_display=("")  # Single iteration with no filter
fi

# Loop through each operator (or once if no operator column)
for current_op in "${operators_to_display[@]}"; do

# Set operator-specific labels and filters
if [ -n "$current_op" ]; then
    echo "================================================================================"
    echo "OPERATOR: $current_op"
    echo "================================================================================"
    echo ""
fi

# Show all clusters sorted by CPU, memory, or operator version
# Column indices change based on whether operator column and other columns are present
if [ "$is_op_ver_only" = true ] && [ "$has_operator_column" = true ]; then
    # operator,cluster_id,cluster_name,cluster_version,operator_version (5 columns)
    # operator_version is column 5
    if [ "$SORT_BY" = "op" ]; then
        SORT_COL=5
        SORT_LABEL="OPERATOR VERSION"
        SORT_OPTS=""  # alphabetic sort
    else
        # For op-ver-only CSV, always sort by operator version
        SORT_COL=5
        SORT_LABEL="OPERATOR VERSION"
        SORT_OPTS=""  # alphabetic sort
        if [ "$SORT_BY" = "mem" ] || [ "$SORT_BY" = "cpu" ]; then
            echo "Note: CPU/Memory data not available in operator-version-only CSV, sorting by operator version" >&2
        fi
    fi
elif [ "$is_op_ver_only" = true ]; then
    # Legacy operator-version-only formats (without operator column)
    if [ "$num_columns" -eq 4 ]; then
        # 4-column format: cluster_id,cluster_name,cluster_version,operator_version
        SORT_COL=4
    else
        # 3-column format: cluster_id,cluster_name,operator_version
        SORT_COL=3
    fi
    SORT_LABEL="OPERATOR VERSION"
    SORT_OPTS=""  # alphabetic sort
    if [ "$SORT_BY" = "mem" ] || [ "$SORT_BY" = "cpu" ]; then
        echo "Note: CPU/Memory data not available in operator-version-only CSV, sorting by operator version" >&2
    fi
elif [ "$has_operator_column" = true ] && [ "$has_cluster_name" = true ] && [ "$has_operator_version" = true ]; then
    # Full CSV with operator column: operator,cluster_id,cluster_name,cluster_version,operator_version,...
    # op_ver is column 5, max_24h_cpu is column 15, max_24h_mem is column 18
    if [ "$SORT_BY" = "mem" ]; then
        SORT_COL=18
        SORT_LABEL="MEMORY"
        SORT_OPTS="-nr"  # numeric reverse sort
    elif [ "$SORT_BY" = "op" ]; then
        SORT_COL=5
        SORT_LABEL="OPERATOR VERSION"
        SORT_OPTS=""  # alphabetic sort
    else
        SORT_COL=15
        SORT_LABEL="CPU"
        SORT_OPTS="-nr"  # numeric reverse sort
    fi
elif [ "$has_cluster_name" = true ] && [ "$has_operator_version" = true ]; then
    # Legacy full CSV without operator column: cluster_id,cluster_name,cluster_version,operator_version,...
    # op_ver is column 4, max_24h_cpu is column 14, max_24h_mem is column 17
    if [ "$SORT_BY" = "mem" ]; then
        SORT_COL=17
        SORT_LABEL="MEMORY"
        SORT_OPTS="-nr"  # numeric reverse sort
    elif [ "$SORT_BY" = "op" ]; then
        SORT_COL=4
        SORT_LABEL="OPERATOR VERSION"
        SORT_OPTS=""  # alphabetic sort
    else
        SORT_COL=14
        SORT_LABEL="CPU"
        SORT_OPTS="-nr"  # numeric reverse sort
    fi
elif [ "$has_cluster_name" = true ]; then
    # With cluster_name only: max_24h_cpu is column 13, max_24h_mem is column 16
    if [ "$SORT_BY" = "mem" ]; then
        SORT_COL=16
        SORT_LABEL="MEMORY"
        SORT_OPTS="-nr"  # numeric reverse sort
    elif [ "$SORT_BY" = "op" ]; then
        echo "Warning: operator_version column not found in CSV, sorting by CPU instead" >&2
        SORT_COL=13
        SORT_LABEL="CPU"
        SORT_OPTS="-nr"  # numeric reverse sort
    else
        SORT_COL=13
        SORT_LABEL="CPU"
        SORT_OPTS="-nr"  # numeric reverse sort
    fi
else
    # Without cluster_name: max_24h_cpu is column 12, max_24h_mem is column 15
    if [ "$SORT_BY" = "mem" ]; then
        SORT_COL=15
        SORT_LABEL="MEMORY"
        SORT_OPTS="-nr"  # numeric reverse sort
    elif [ "$SORT_BY" = "op" ]; then
        echo "Warning: operator_version column not found in CSV, sorting by CPU instead" >&2
        SORT_COL=12
        SORT_LABEL="CPU"
        SORT_OPTS="-nr"  # numeric reverse sort
    else
        SORT_COL=12
        SORT_LABEL="CPU"
        SORT_OPTS="-nr"  # numeric reverse sort
    fi
fi

# Display table header
if [ -z "$current_op" ]; then
    echo "================================================================================"
    echo "ALL CLUSTERS (sorted by $SORT_LABEL)"
    echo "================================================================================"
else
    echo "ALL CLUSTERS (sorted by $SORT_LABEL)"
    echo "================================================================================"
fi
echo ""

# Filter and sort data
if [ -n "$current_op" ]; then
    # Filter by operator
    csv_data=$(tail -n +2 "$CSV_FILE" | grep "^${current_op}," | sort -t',' -k${SORT_COL} ${SORT_OPTS})
else
    # No filter
    csv_data=$(tail -n +2 "$CSV_FILE" | sort -t',' -k${SORT_COL} ${SORT_OPTS})
fi

if [ "$is_op_ver_only" = true ]; then
    # Simple display for operator-version-only CSV
    echo "$csv_data" | \
        awk -F',' -v id_len="$ID_LEN" -v name_len="$NAME_LEN" -v ver_len="$VER_LEN" -v op_ver_len="$OP_VER_LEN" -v num_cols="$num_columns" -v has_op_col="$has_operator_column" '
        BEGIN {
            # Initialize min column widths based on headers
            id_width = (id_len > 0) ? length("ID") : 0;
            name_width = (name_len > 0) ? length("NAME") : 0;
            ver_width = (ver_len > 0) ? length("VERSION") : 0;
            op_ver_width = (op_ver_len > 0) ? length("OPERATOR_VERSION") : 0;
        }
        {
            # Skip malformed lines
            if (has_op_col == "true" && NF != 5) next;
            if (has_op_col != "true" && num_cols == 4 && NF != 4) next;
            if (has_op_col != "true" && num_cols == 3 && NF != 3) next;

            if (has_op_col == "true") {
                # With operator column: operator,cluster_id,cluster_name,cluster_version,operator_version (5 cols)
                cluster_id = $2;
                cluster_name = $3;
                cluster_version = $4;
                operator_version = $5;
                has_cluster_version = 1;
            } else if (num_cols == 4) {
                # Without operator column: cluster_id,cluster_name,cluster_version,operator_version (4 cols)
                cluster_id = $1;
                cluster_name = $2;
                cluster_version = $3;
                operator_version = $4;
                has_cluster_version = 1;
            } else {
                # Legacy 3-column: cluster_id,cluster_name,operator_version
                cluster_id = $1;
                cluster_name = $2;
                cluster_version = "";
                operator_version = $3;
                has_cluster_version = 0;
            }

            # Truncate cluster ID if needed and add ".*" suffix
            if (id_len > 0 && length(cluster_id) > id_len) {
                cluster_id = substr(cluster_id, 1, id_len) ".*";
            }

            # Truncate cluster name if needed and add ".*" suffix
            if (name_len > 0 && length(cluster_name) > name_len) {
                cluster_name = substr(cluster_name, 1, name_len) ".*";
            }

            # Truncate cluster version if needed and add ".*" suffix
            if (has_cluster_version && ver_len > 0 && length(cluster_version) > ver_len) {
                cluster_version = substr(cluster_version, 1, ver_len) ".*";
            }

            # Truncate operator version if needed and add ".*" suffix
            if (op_ver_len > 0 && length(operator_version) > op_ver_len) {
                operator_version = substr(operator_version, 1, op_ver_len) ".*";
            }

            # Store row data in separate arrays
            row_id[NR] = cluster_id;
            row_name[NR] = cluster_name;
            row_version[NR] = cluster_version;
            row_op_version[NR] = operator_version;

            # Update max widths
            if (id_len > 0 && length(cluster_id) > id_width) id_width = length(cluster_id);
            if (name_len > 0 && length(cluster_name) > name_width) name_width = length(cluster_name);
            if (has_cluster_version && ver_len > 0 && length(cluster_version) > ver_width) ver_width = length(cluster_version);
            if (op_ver_len > 0 && length(operator_version) > op_ver_width) op_ver_width = length(operator_version);
        }
        END {
            # Build format string with 2-space padding between columns
            fmt = "";
            header = "";
            separator = "";

            if (id_len > 0) {
                fmt = fmt "%-" id_width "s  ";
                header = header sprintf("%-" id_width "s  ", "ID");
                separator = separator sprintf("%-" id_width "s  ", substr("----------", 1, id_width));
            }
            if (name_len > 0) {
                fmt = fmt "%-" name_width "s  ";
                header = header sprintf("%-" name_width "s  ", "NAME");
                separator = separator sprintf("%-" name_width "s  ", substr("------------", 1, name_width));
            }
            if (has_cluster_version && ver_len > 0) {
                fmt = fmt "%-" ver_width "s  ";
                header = header sprintf("%-" ver_width "s  ", "VERSION");
                separator = separator sprintf("%-" ver_width "s  ", substr("-------", 1, ver_width));
            }
            if (op_ver_len > 0) {
                fmt = fmt "%-" op_ver_width "s\n";
                header = header sprintf("%-" op_ver_width "s\n", "OPERATOR_VERSION");
                separator = separator sprintf("%-" op_ver_width "s\n", substr("----------------", 1, op_ver_width));
            }

            # Print header
            printf "%s", header;
            printf "%s", separator;

            # Print all rows
            for (i = 1; i <= NR; i++) {
                row = "";
                if (id_len > 0) row = row sprintf("%-" id_width "s  ", row_id[i]);
                if (name_len > 0) row = row sprintf("%-" name_width "s  ", row_name[i]);
                if (has_cluster_version && ver_len > 0) row = row sprintf("%-" ver_width "s  ", row_version[i]);
                if (op_ver_len > 0) row = row sprintf("%-" op_ver_width "s", row_op_version[i]);
                printf "%s\n", row;
            }
        }'
elif [ "$has_cluster_name" = true ] && [ "$has_operator_version" = true ]; then
    # CSV has cluster_name and operator_version columns - use awk to calculate column widths and print
    echo "$csv_data" | \
        awk -F',' -v id_len="$ID_LEN" -v name_len="$NAME_LEN" -v ver_len="$VER_LEN" -v op_ver_len="$OP_VER_LEN" -v has_op_col="$has_operator_column" '
        BEGIN {
            # Initialize min column widths based on headers
            id_width = (id_len > 0) ? length("ID") : 0;
            name_width = (name_len > 0) ? length("NAME") : 0;
            ver_width = (ver_len > 0) ? length("VERSION") : 0;
            op_ver_width = (op_ver_len > 0) ? length("OP_VERSION") : 0;
            cpu_width = length("CPU");
            mem_width = length("MEMORY");
        }
        {
            # Skip malformed lines (wrong number of fields)
            if (has_op_col == "true" && NF != 19) next;
            if (has_op_col != "true" && NF != 18) next;

            if (has_op_col == "true") {
                # With operator column: operator,cluster_id,cluster_name,cluster_version,operator_version,...
                cluster_id = $2;
                cluster_name = $3;
                version = $4;
                operator_version = $5;
                cpu_val = $15;
                mem_bytes = $18;
            } else {
                # Without operator column: cluster_id,cluster_name,cluster_version,operator_version,...
                cluster_id = $1;
                cluster_name = $2;
                version = $3;
                operator_version = $4;
                cpu_val = $14;
                mem_bytes = $17;
            }

            # Truncate cluster ID if needed and add ".*" suffix
            if (id_len > 0 && length(cluster_id) > id_len) {
                cluster_id = substr(cluster_id, 1, id_len) ".*";
            }

            # Truncate cluster name if needed and add ".*" suffix
            if (name_len > 0 && length(cluster_name) > name_len) {
                cluster_name = substr(cluster_name, 1, name_len) ".*";
            }

            # Truncate version if needed and add ".*" suffix
            if (ver_len > 0 && length(version) > ver_len) {
                version = substr(version, 1, ver_len) ".*";
            }

            # Truncate operator version if needed and add ".*" suffix
            if (op_ver_len > 0 && length(operator_version) > op_ver_len) {
                operator_version = substr(operator_version, 1, op_ver_len) ".*";
            }

            # CPU formatting
            if (cpu_val < 1) {
                cpu_display = sprintf("%.0f (m)", cpu_val * 1000);
            } else {
                cpu_display = sprintf("%.4f (cores)", cpu_val);
            }

            # Memory formatting (binary units)
            if (mem_bytes >= 1099511627776) {
                mem_display = sprintf("%.2f (Ti)", mem_bytes / 1099511627776);
            } else if (mem_bytes >= 1073741824) {
                mem_display = sprintf("%.2f (Gi)", mem_bytes / 1073741824);
            } else if (mem_bytes >= 1048576) {
                mem_display = sprintf("%.0f (Mi)", mem_bytes / 1048576);
            } else {
                mem_display = sprintf("%.0f (bytes)", mem_bytes);
            }

            # Store row data in separate arrays
            row_id[NR] = cluster_id;
            row_name[NR] = cluster_name;
            row_version[NR] = version;
            row_op_version[NR] = operator_version;
            row_cpu[NR] = cpu_display;
            row_mem[NR] = mem_display;

            # Update max widths
            if (id_len > 0 && length(cluster_id) > id_width) id_width = length(cluster_id);
            if (name_len > 0 && length(cluster_name) > name_width) name_width = length(cluster_name);
            if (ver_len > 0 && length(version) > ver_width) ver_width = length(version);
            if (op_ver_len > 0 && length(operator_version) > op_ver_width) op_ver_width = length(operator_version);
            if (length(cpu_display) > cpu_width) cpu_width = length(cpu_display);
            if (length(mem_display) > mem_width) mem_width = length(mem_display);
        }
        END {
            # Build format string with 2-space padding between columns
            fmt = "";
            sep = "";
            header = "";
            separator = "";

            if (id_len > 0) {
                fmt = fmt "%-" id_width "s  ";
                header = header sprintf("%-" id_width "s  ", "ID");
                separator = separator sprintf("%-" id_width "s  ", substr("----------", 1, id_width));
            }
            if (name_len > 0) {
                fmt = fmt "%-" name_width "s  ";
                header = header sprintf("%-" name_width "s  ", "NAME");
                separator = separator sprintf("%-" name_width "s  ", substr("------------", 1, name_width));
            }
            if (ver_len > 0) {
                fmt = fmt "%-" ver_width "s  ";
                header = header sprintf("%-" ver_width "s  ", "VERSION");
                separator = separator sprintf("%-" ver_width "s  ", substr("-------", 1, ver_width));
            }
            if (op_ver_len > 0) {
                fmt = fmt "%-" op_ver_width "s  ";
                header = header sprintf("%-" op_ver_width "s  ", "OP_VERSION");
                separator = separator sprintf("%-" op_ver_width "s  ", substr("----------", 1, op_ver_width));
            }
            fmt = fmt "%-" cpu_width "s  %-" mem_width "s\n";
            header = header sprintf("%-" cpu_width "s  %-" mem_width "s\n", "CPU", "MEMORY");
            separator = separator sprintf("%-" cpu_width "s  %-" mem_width "s\n", substr("---", 1, cpu_width), substr("------", 1, mem_width));

            # Print header
            printf "%s", header;
            printf "%s", separator;

            # Print all rows - show all enabled columns
            for (i = 1; i <= NR; i++) {
                row = "";
                if (id_len > 0) row = row sprintf("%-" id_width "s  ", row_id[i]);
                if (name_len > 0) row = row sprintf("%-" name_width "s  ", row_name[i]);
                if (ver_len > 0) row = row sprintf("%-" ver_width "s  ", row_version[i]);
                if (op_ver_len > 0) row = row sprintf("%-" op_ver_width "s  ", row_op_version[i]);
                row = row sprintf("%-" cpu_width "s  %-" mem_width "s", row_cpu[i], row_mem[i]);
                printf "%s\n", row;
            }
        }'
elif [ "$has_cluster_name" = true ]; then
    # CSV has cluster_name but not operator_version - old format
    echo "$csv_data" | \
        awk -F',' -v id_len="$ID_LEN" -v name_len="$NAME_LEN" -v ver_len="$VER_LEN" '
        BEGIN {
            # Initialize min column widths based on headers
            id_width = (id_len > 0) ? length("ID") : 0;
            name_width = (name_len > 0) ? length("NAME") : 0;
            ver_width = (ver_len > 0) ? length("VERSION") : 0;
            cpu_width = length("CPU");
            mem_width = length("MEMORY");
        }
        {
            cluster_id = $1;
            cluster_name = $2;
            version = $3;
            cpu_val = $13;
            mem_bytes = $16;

            # Truncate cluster ID if needed and add ".*" suffix
            if (id_len > 0 && length(cluster_id) > id_len) {
                cluster_id = substr(cluster_id, 1, id_len) ".*";
            }

            # Truncate cluster name if needed and add ".*" suffix
            if (name_len > 0 && length(cluster_name) > name_len) {
                cluster_name = substr(cluster_name, 1, name_len) ".*";
            }

            # Truncate version if needed and add ".*" suffix
            if (ver_len > 0 && length(version) > ver_len) {
                version = substr(version, 1, ver_len) ".*";
            }

            # CPU formatting
            if (cpu_val < 1) {
                cpu_display = sprintf("%.0f (m)", cpu_val * 1000);
            } else {
                cpu_display = sprintf("%.4f (cores)", cpu_val);
            }

            # Memory formatting (binary units)
            if (mem_bytes >= 1099511627776) {
                mem_display = sprintf("%.2f (Ti)", mem_bytes / 1099511627776);
            } else if (mem_bytes >= 1073741824) {
                mem_display = sprintf("%.2f (Gi)", mem_bytes / 1073741824);
            } else if (mem_bytes >= 1048576) {
                mem_display = sprintf("%.0f (Mi)", mem_bytes / 1048576);
            } else {
                mem_display = sprintf("%.0f (bytes)", mem_bytes);
            }

            # Store row data in separate arrays
            row_id[NR] = cluster_id;
            row_name[NR] = cluster_name;
            row_version[NR] = version;
            row_cpu[NR] = cpu_display;
            row_mem[NR] = mem_display;

            # Update max widths
            if (id_len > 0 && length(cluster_id) > id_width) id_width = length(cluster_id);
            if (name_len > 0 && length(cluster_name) > name_width) name_width = length(cluster_name);
            if (ver_len > 0 && length(version) > ver_width) ver_width = length(version);
            if (length(cpu_display) > cpu_width) cpu_width = length(cpu_display);
            if (length(mem_display) > mem_width) mem_width = length(mem_display);
        }
        END {
            # Build format string with 2-space padding between columns
            fmt = "";
            sep = "";
            header = "";
            separator = "";

            if (id_len > 0) {
                fmt = fmt "%-" id_width "s  ";
                header = header sprintf("%-" id_width "s  ", "ID");
                separator = separator sprintf("%-" id_width "s  ", substr("----------", 1, id_width));
            }
            if (name_len > 0) {
                fmt = fmt "%-" name_width "s  ";
                header = header sprintf("%-" name_width "s  ", "NAME");
                separator = separator sprintf("%-" name_width "s  ", substr("------------", 1, name_width));
            }
            if (ver_len > 0) {
                fmt = fmt "%-" ver_width "s  ";
                header = header sprintf("%-" ver_width "s  ", "VERSION");
                separator = separator sprintf("%-" ver_width "s  ", substr("-------", 1, ver_width));
            }
            fmt = fmt "%-" cpu_width "s  %-" mem_width "s\n";
            header = header sprintf("%-" cpu_width "s  %-" mem_width "s\n", "CPU", "MEMORY");
            separator = separator sprintf("%-" cpu_width "s  %-" mem_width "s\n", substr("---", 1, cpu_width), substr("------", 1, mem_width));

            # Print header
            printf "%s", header;
            printf "%s", separator;

            # Print all rows
            for (i = 1; i <= NR; i++) {
                if (id_len > 0 && name_len > 0 && ver_len > 0) {
                    printf fmt, row_id[i], row_name[i], row_version[i], row_cpu[i], row_mem[i];
                } else if (id_len > 0 && name_len > 0) {
                    printf "%-" id_width "s  %-" name_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_id[i], row_name[i], row_cpu[i], row_mem[i];
                } else if (id_len > 0 && ver_len > 0) {
                    printf "%-" id_width "s  %-" ver_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_id[i], row_version[i], row_cpu[i], row_mem[i];
                } else if (name_len > 0 && ver_len > 0) {
                    printf "%-" name_width "s  %-" ver_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_name[i], row_version[i], row_cpu[i], row_mem[i];
                } else if (id_len > 0) {
                    printf "%-" id_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_id[i], row_cpu[i], row_mem[i];
                } else if (name_len > 0) {
                    printf "%-" name_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_name[i], row_cpu[i], row_mem[i];
                } else if (ver_len > 0) {
                    printf "%-" ver_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_version[i], row_cpu[i], row_mem[i];
                } else {
                    printf "%-" cpu_width "s  %-" mem_width "s\n",
                           row_cpu[i], row_mem[i];
                }
            }
        }'
else
    # CSV doesn't have cluster_name column (old format) - fetch from OCM
    echo "Note: CSV file does not contain cluster names. Fetching from OCM..." >&2

    # Use awk to process the data similar to the first branch
    echo "$csv_data" | \
        awk -F',' -v id_len="$ID_LEN" -v name_len="$NAME_LEN" -v ver_len="$VER_LEN" '
        BEGIN {
            # Initialize min column widths based on headers
            id_width = (id_len > 0) ? length("ID") : 0;
            name_width = (name_len > 0) ? length("NAME") : 0;
            ver_width = (ver_len > 0) ? length("VERSION") : 0;
            cpu_width = length("CPU");
            mem_width = length("MEMORY");
        }
        {
            cluster_id = $1;
            version = $2;
            max_24h_cpu = $12;
            max_24h_mem = $15;

            # Fetch cluster name from OCM if needed (stored for later use)
            if (name_len > 0) {
                cmd = "ocm get cluster " cluster_id " 2>/dev/null | jq -r \".name // \\\"unknown\\\"\" || echo unknown";
                cmd | getline cluster_name;
                close(cmd);

                # Truncate cluster name if needed and add ".*" suffix
                if (length(cluster_name) > name_len) {
                    cluster_name = substr(cluster_name, 1, name_len) ".*";
                }
            }

            # Truncate cluster ID if needed and add ".*" suffix
            if (id_len > 0 && length(cluster_id) > id_len) {
                cluster_id = substr(cluster_id, 1, id_len) ".*";
            }

            # Truncate version if needed and add ".*" suffix
            if (ver_len > 0 && length(version) > ver_len) {
                version = substr(version, 1, ver_len) ".*";
            }

            # CPU formatting
            cpu_val = max_24h_cpu;
            if (cpu_val < 1 && cpu_val > 0) {
                cpu_display = sprintf("%.0f (m)", cpu_val * 1000);
            } else if (cpu_val >= 1) {
                cpu_display = sprintf("%.4f (cores)", cpu_val);
            } else {
                cpu_display = "0 (m)";
            }

            # Memory formatting
            mem_bytes = max_24h_mem;
            if (mem_bytes >= 1099511627776) {
                cmd = "echo \"scale=2; " mem_bytes " / 1099511627776\" | bc";
                cmd | getline mem_val;
                close(cmd);
                mem_display = mem_val " (Ti)";
            } else if (mem_bytes >= 1073741824) {
                cmd = "echo \"scale=2; " mem_bytes " / 1073741824\" | bc";
                cmd | getline mem_val;
                close(cmd);
                mem_display = mem_val " (Gi)";
            } else if (mem_bytes >= 1048576) {
                cmd = "echo \"" mem_bytes " / 1048576\" | bc";
                cmd | getline mem_val;
                close(cmd);
                mem_display = mem_val " (Mi)";
            } else if (mem_bytes > 0) {
                mem_display = mem_bytes " (bytes)";
            } else {
                mem_display = "0 (Mi)";
            }

            # Store row data in separate arrays
            row_id[NR] = cluster_id;
            row_name[NR] = cluster_name;
            row_version[NR] = version;
            row_cpu[NR] = cpu_display;
            row_mem[NR] = mem_display;

            # Update max widths
            if (id_len > 0 && length(cluster_id) > id_width) id_width = length(cluster_id);
            if (name_len > 0 && length(cluster_name) > name_width) name_width = length(cluster_name);
            if (ver_len > 0 && length(version) > ver_width) ver_width = length(version);
            if (length(cpu_display) > cpu_width) cpu_width = length(cpu_display);
            if (length(mem_display) > mem_width) mem_width = length(mem_display);
        }
        END {
            # Build format string with 2-space padding between columns
            fmt = "";
            header = "";
            separator = "";

            if (id_len > 0) {
                fmt = fmt "%-" id_width "s  ";
                header = header sprintf("%-" id_width "s  ", "ID");
                separator = separator sprintf("%-" id_width "s  ", substr("----------", 1, id_width));
            }
            if (name_len > 0) {
                fmt = fmt "%-" name_width "s  ";
                header = header sprintf("%-" name_width "s  ", "NAME");
                separator = separator sprintf("%-" name_width "s  ", substr("------------", 1, name_width));
            }
            if (ver_len > 0) {
                fmt = fmt "%-" ver_width "s  ";
                header = header sprintf("%-" ver_width "s  ", "VERSION");
                separator = separator sprintf("%-" ver_width "s  ", substr("-------", 1, ver_width));
            }
            fmt = fmt "%-" cpu_width "s  %-" mem_width "s\n";
            header = header sprintf("%-" cpu_width "s  %-" mem_width "s\n", "CPU", "MEMORY");
            separator = separator sprintf("%-" cpu_width "s  %-" mem_width "s\n", substr("---", 1, cpu_width), substr("------", 1, mem_width));

            # Print header
            printf "%s", header;
            printf "%s", separator;

            # Print all rows
            for (i = 1; i <= NR; i++) {
                if (id_len > 0 && name_len > 0 && ver_len > 0) {
                    printf fmt, row_id[i], row_name[i], row_version[i], row_cpu[i], row_mem[i];
                } else if (id_len > 0 && name_len > 0) {
                    printf "%-" id_width "s  %-" name_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_id[i], row_name[i], row_cpu[i], row_mem[i];
                } else if (id_len > 0 && ver_len > 0) {
                    printf "%-" id_width "s  %-" ver_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_id[i], row_version[i], row_cpu[i], row_mem[i];
                } else if (name_len > 0 && ver_len > 0) {
                    printf "%-" name_width "s  %-" ver_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_name[i], row_version[i], row_cpu[i], row_mem[i];
                } else if (id_len > 0) {
                    printf "%-" id_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_id[i], row_cpu[i], row_mem[i];
                } else if (name_len > 0) {
                    printf "%-" name_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_name[i], row_cpu[i], row_mem[i];
                } else if (ver_len > 0) {
                    printf "%-" ver_width "s  %-" cpu_width "s  %-" mem_width "s\n",
                           row_version[i], row_cpu[i], row_mem[i];
                } else {
                    printf "%-" cpu_width "s  %-" mem_width "s\n",
                           row_cpu[i], row_mem[i];
                }
            }
        }'
fi

done  # End of operator loop

echo ""
