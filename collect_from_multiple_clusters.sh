#!/usr/bin/env bash
#
# Collect Resource Usage from Multiple Clusters
#
# This script collects resource usage data from multiple clusters
# and aggregates it into a single CSV file for analysis.
#
# Usage:
#   ./collect_from_multiple_clusters.sh [OPTIONS]
#
# Set OCM config (optional - defaults to your current OCM configuration)
# To use a specific OCM config, set OCM_CONFIG environment variable before running:
#   export OCM_CONFIG="${HOME}/.config/ocm/ocm.prod.json"
# Or uncomment and modify the line below:
# export OCM_CONFIG="${HOME}/.config/ocm/ocm.json"

# Check bash version (need 4.0+ for associative arrays)
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Error: This script requires Bash 4.0 or later (you have ${BASH_VERSION})" >&2
    echo "On macOS, install bash via Homebrew: brew install bash" >&2
    exit 1
fi

set -uo pipefail
# Note: NOT using set -e (exit on error) to allow graceful error handling per cluster

# Flag to track if script should exit
INTERRUPTED=false

# Interrupt handler for Ctrl-C
interrupt_handler() {
    echo ""
    echo ""
    echo "================================================================================"
    echo "INTERRUPTED BY USER (Ctrl-C)"
    echo "================================================================================"
    echo "Stopping cluster collection..."
    INTERRUPTED=true
}

# Cleanup function to ensure logout on exit
cleanup() {
    local exit_code=$?
    if [ "$INTERRUPTED" = true ]; then
        echo ""
        echo "Collection interrupted. Partial results saved to: $OUTPUT_FILE"
    elif [ $exit_code -ne 0 ]; then
        echo ""
        echo "Script exiting with error code: $exit_code"
    fi
    echo "Cleaning up: logging out from backplane..."
    ocm backplane logout &> /dev/null || true

    # Clean up cache if it was initialized
    if [ "$COMPREHENSIVE_HEALTH" = true ] && type cleanup_cache &>/dev/null; then
        echo "Cleaning up cache..."
        cache_stats >&2
        cleanup_cache
    fi
}

# Set trap to handle interrupts and cleanup on exit
trap interrupt_handler INT
trap cleanup EXIT TERM

# Default values
REASON="Checking CAMO operator health"
OUTPUT_FILE=""  # Will be set after parsing arguments
DEPLOYMENT="configure-alertmanager-operator"
NAMESPACE="openshift-monitoring"
CLUSTER_LIST=""
MAX_CLUSTERS=""
OP_VER_ONLY=false
HEALTH_CHECK=false
COMPREHENSIVE_HEALTH=false
METRICS_CHECK=false
VERSION_COMPARE=false
CHECK_HCP_CONTROLLERS=false
CHECK_SECRETS=false
OPERATORS_TO_COLLECT=()

# Operator configurations
# Format: name:namespace:deployment
declare -A OPERATOR_CONFIGS
OPERATOR_CONFIGS["camo"]="configure-alertmanager-operator:openshift-monitoring:configure-alertmanager-operator"
OPERATOR_CONFIGS["rmo"]="route-monitor-operator:openshift-route-monitor-operator:route-monitor-operator-controller-manager"

# All supported operators (for default behavior)
ALL_OPERATORS=("camo" "rmo")

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Collect resource usage from multiple clusters

OPTIONS:
    --reason, -r REASON         JIRA ticket for OCM elevation
                                If not provided, will prompt interactively (default: "Checking CAMO operator health")
    --output, -o FILE           Output CSV file
                                Default: resource_usage_TIMESTAMP.csv (or health_check_TIMESTAMP.csv with --health)
    --deployment, -d DEPLOY     Deployment name (default: configure-alertmanager-operator)
    --namespace, -n NAMESPACE   Namespace (default: openshift-monitoring)
    --cluster-list, -c FILE     File with cluster IDs (one per line)
    --max-clusters, -m NUM      Maximum number of clusters to process
    --op-ver                    Only fetch operator version (cluster ID, name, operator version)
    --health                    Perform health checks for production readiness (pod uptime, errors)
    --comprehensive-health      Comprehensive health check (version verification, memory leaks, log errors)
    --secrets                   Enable extended secret-based health checks (requires backplane elevation)
                                Checks: alertmanager-main secret, CAMO ConfigMap, PagerDuty secret
    --metrics                   Collect CAMO Prometheus metrics (secrets, configmaps, validation status)
    --version-compare           Collect resource metrics for both previous and current operator versions
    --oper OPERATOR             Operator to collect (camo, rmo). Can be specified multiple times.
                                Default: collect all supported operators (camo, rmo)
    --check-hcp-controllers     Include HyperShift infrastructure clusters (hs-mc-*, hs-sc-*)
                                By default, these clusters are EXCLUDED from health checks
    --help, -h                  Show this help message

EXAMPLES:
    # Interactive mode (will prompt for reason)
    $0 --comprehensive-health

    # Collect from all operators with specific reason
    $0 --reason "SREP-12345 capacity planning"

    # Collect only from CAMO operator
    $0 -r "SREP-12345" --oper camo

    # Collect only from RMO operator
    $0 -r "SREP-12345" --oper rmo

    # Collect from multiple specific operators
    $0 -r "SREP-12345" --oper camo --oper rmo

    # Perform health checks for production readiness
    $0 -r "SREP-12345" --health

    # Comprehensive health check (includes version verification, memory leaks, log errors)
    $0 -r "SREP-12345" --comprehensive-health --oper camo

    # Health check specific operator
    $0 -r "SREP-12345" --health --oper camo

    # Collect CAMO Prometheus metrics
    $0 -r "SREP-12345" --metrics --oper camo

    # Compare resource usage between operator versions
    $0 -r "SREP-12345" --version-compare --oper camo

    # Collect from specific cluster list
    $0 -r "SREP-12345" -c cluster_list.txt

    # Limit to first 10 clusters
    $0 -r "SREP-12345" -m 10

    # Only collect operator versions for all operators
    $0 -r "SREP-12345" --op-ver

    # Only collect operator versions for specific operator
    $0 -r "SREP-12345" --op-ver --oper rmo

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --reason|-r) REASON="$2"; shift 2 ;;
        --output|-o) OUTPUT_FILE="$2"; shift 2 ;;
        --deployment|-d) DEPLOYMENT="$2"; shift 2 ;;
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        --cluster-list|-c) CLUSTER_LIST="$2"; shift 2 ;;
        --max-clusters|-m) MAX_CLUSTERS="$2"; shift 2 ;;
        --op-ver) OP_VER_ONLY=true; shift ;;
        --health) HEALTH_CHECK=true; shift ;;
        --comprehensive-health) COMPREHENSIVE_HEALTH=true; shift ;;
        --secrets) CHECK_SECRETS=true; shift ;;
        --metrics) METRICS_CHECK=true; shift ;;
        --version-compare) VERSION_COMPARE=true; shift ;;
        --check-hcp-controllers) CHECK_HCP_CONTROLLERS=true; shift ;;
        --oper)
            # Validate operator name
            if [[ ! " ${!OPERATOR_CONFIGS[@]} " =~ " $2 " ]]; then
                echo "Error: Unknown operator: $2" >&2
                echo "Supported operators: ${!OPERATOR_CONFIGS[@]}" >&2
                exit 1
            fi
            OPERATORS_TO_COLLECT+=("$2")
            shift 2
            ;;
        --help|-h) usage ;;
        *) echo "Error: Unknown option: $1" >&2; usage ;;
    esac
done

# If no operators specified, collect from all supported operators
if [ ${#OPERATORS_TO_COLLECT[@]} -eq 0 ]; then
    OPERATORS_TO_COLLECT=("${ALL_OPERATORS[@]}")
    echo "No operators specified, collecting from all supported operators: ${OPERATORS_TO_COLLECT[@]}"
    echo ""
fi

# Set default output filename based on mode if not specified
if [ -z "$OUTPUT_FILE" ]; then
    if [ "$HEALTH_CHECK" = true ]; then
        OUTPUT_FILE="health_check_$(date +%Y%m%d_%H%M%S).csv"
    elif [ "$COMPREHENSIVE_HEALTH" = true ]; then
        OUTPUT_FILE="comprehensive_health_$(date +%Y%m%d_%H%M%S).json"
    elif [ "$METRICS_CHECK" = true ]; then
        OUTPUT_FILE="camo_metrics_$(date +%Y%m%d_%H%M%S).csv"
    elif [ "$VERSION_COMPARE" = true ]; then
        OUTPUT_FILE="version_compare_$(date +%Y%m%d_%H%M%S).csv"
    else
        OUTPUT_FILE="resource_usage_$(date +%Y%m%d_%H%M%S).csv"
    fi
fi

# Validate reason (prompt if not provided and running interactively)
if [ -z "$REASON" ]; then
    DEFAULT_REASON="Checking CAMO operator health"

    # Check if running interactively (stdin is a terminal)
    if [ -t 0 ]; then
        echo ""
        echo "OCM Elevation Reason"
        echo "-------------------"
        echo "Default: $DEFAULT_REASON"
        echo ""
        read -p "Press Enter to use default, or type custom reason: " user_input

        if [ -z "$user_input" ]; then
            REASON="$DEFAULT_REASON"
            echo "Using default reason: $REASON"
        else
            REASON="$user_input"
            echo "Using custom reason: $REASON"
        fi
        echo ""
    else
        # Non-interactive mode (piped input or automation)
        REASON="$DEFAULT_REASON"
        echo "Note: Using default reason: $REASON" >&2
    fi
fi

# Check required tools
for cmd in ocm oc jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: Required command '$cmd' not found" >&2
        exit 1
    fi
done

echo "================================================================================"
if [ "$HEALTH_CHECK" = true ]; then
    echo "MULTI-CLUSTER HEALTH CHECK"
elif [ "$COMPREHENSIVE_HEALTH" = true ]; then
    echo "MULTI-CLUSTER COMPREHENSIVE HEALTH CHECK"
elif [ "$METRICS_CHECK" = true ]; then
    echo "MULTI-CLUSTER METRICS COLLECTION"
elif [ "$VERSION_COMPARE" = true ]; then
    echo "MULTI-CLUSTER VERSION COMPARISON"
else
    echo "MULTI-CLUSTER RESOURCE COLLECTION"
fi
echo "================================================================================"
echo "Operators:   ${OPERATORS_TO_COLLECT[@]}"
echo "Output:      $OUTPUT_FILE"
echo "Reason:      $REASON"
if [ "$OP_VER_ONLY" = true ]; then
    echo "Mode:        Operator version only"
elif [ "$HEALTH_CHECK" = true ]; then
    echo "Mode:        Health check (production readiness)"
elif [ "$COMPREHENSIVE_HEALTH" = true ]; then
    echo "Mode:        Comprehensive health check (version verification, memory leaks, log analysis)"
elif [ "$METRICS_CHECK" = true ]; then
    echo "Mode:        Prometheus metrics collection"
elif [ "$VERSION_COMPARE" = true ]; then
    echo "Mode:        Version comparison (previous vs current)"
fi
echo "================================================================================"
echo ""

# Initialize cache for comprehensive health checks
if [ "$COMPREHENSIVE_HEALTH" = true ]; then
    # Source cache helper functions
    CACHE_HELPER="$(dirname "${BASH_SOURCE[0]}")/.health_check_cache.sh"
    if [ -f "$CACHE_HELPER" ]; then
        source "$CACHE_HELPER"
        echo "Cache initialized: $CACHE_DIR"

        # Pre-fetch and cache staging versions for all operators
        for op in "${OPERATORS_TO_COLLECT[@]}"; do
            if [ "$op" = "camo" ]; then
                saas_file="saas-configure-alertmanager-operator.yaml"
                # Use environment variable or default staging clusters
                staging_clusters="${CAMO_STAGING_CLUSTERS:-staging-cluster-1,staging-cluster-2,staging-cluster-3}"
            elif [ "$op" = "rmo" ]; then
                saas_file="saas-route-monitor-operator.yaml"
                # Use environment variable or default staging clusters
                staging_clusters="${RMO_STAGING_CLUSTERS:-staging-cluster-1,staging-cluster-2,staging-cluster-3}"
            fi

            if [ -n "${saas_file:-}" ]; then
                echo "Pre-caching staging versions for $op..."
                canonical_version=$(get_canonical_staging_version "$saas_file" "$staging_clusters" 2>/dev/null || echo "")
                canonical_image_tag=$(get_canonical_staging_image_tag "$saas_file" "$staging_clusters" 2>/dev/null || echo "")
                if [ -n "$canonical_version" ]; then
                    echo "  Cached: $canonical_version (tag: $canonical_image_tag)"
                    # Export for use in sub-shells
                    export "CACHED_STAGING_VERSION_${op}=$canonical_version"
                    export "CACHED_STAGING_IMAGE_TAG_${op}=$canonical_image_tag"
                fi
            fi
        done
        echo ""
    fi
fi

# Get cluster list and metadata
clusters=()
declare -A cluster_names
declare -A cluster_versions
declare -A cluster_creation_dates

if [ -n "$CLUSTER_LIST" ]; then
    if [ ! -f "$CLUSTER_LIST" ]; then
        echo "Error: Cluster list file not found: $CLUSTER_LIST" >&2
        exit 1
    fi
    while IFS= read -r line; do
        # Skip empty lines
        if [ -n "$line" ]; then
            clusters+=("$line")
        fi
    done < "$CLUSTER_LIST"
    echo "Using cluster list from: $CLUSTER_LIST"
    echo "Batch-fetching cluster metadata from OCM..."

    # Batch fetch cluster metadata (OCM supports up to 100 clusters per request)
    # Split into batches of 50 to be safe
    batch_size=50
    total_to_fetch=${#clusters[@]}

    for ((i=0; i<total_to_fetch; i+=batch_size)); do
        # Get batch of cluster IDs
        batch_end=$((i + batch_size))
        if [ $batch_end -gt $total_to_fetch ]; then
            batch_end=$total_to_fetch
        fi

        batch_ids=("${clusters[@]:$i:$batch_size}")

        # Build search query: id in ('id1', 'id2', 'id3')
        search_query="id in ($(printf "'%s'," "${batch_ids[@]}" | sed 's/,$//'))"

        echo "  Fetching batch $((i/batch_size + 1)): clusters $((i+1))-${batch_end} of ${total_to_fetch}..."

        # Fetch batch
        batch_data=$(ocm get clusters --parameter search="$search_query" 2>/dev/null)

        if [ -n "$batch_data" ]; then
            # Parse batch results
            while IFS=$'\t' read -r id name version created; do
                if [ -n "$id" ] && [ "$id" != "null" ]; then
                    cluster_names["$id"]="$name"
                    cluster_versions["$id"]="$version"
                    cluster_creation_dates["$id"]="$created"
                fi
            done < <(echo "$batch_data" | jq -r '.items[]? | [.id, .name, .openshift_version, .creation_timestamp] | @tsv')
        fi
    done

    echo "✓ Batch fetch complete"
else
    echo "Fetching OSD and ROSA classic clusters from OCM (state='ready')..."

    # Fetch ROSA classic clusters (hypershift.enabled='false')
    rosa_data=$(ocm get clusters --parameter search="hypershift.enabled='false' and managed='true' and state='ready' and product.id='rosa'" 2>/dev/null)

    # Fetch OSD clusters
    osd_data=$(ocm get clusters --parameter search="managed='true' and state='ready' and product.id='osd'" 2>/dev/null)

    # Parse ROSA classic clusters
    if [ -n "$rosa_data" ]; then
        while IFS=$'\t' read -r id name version created; do
            if [ -n "$id" ] && [ "$id" != "null" ]; then
                clusters+=("$id")
                cluster_names["$id"]="$name"
                cluster_versions["$id"]="$version"
                cluster_creation_dates["$id"]="$created"
            fi
        done < <(echo "$rosa_data" | jq -r '.items[]? | [.id, .name, .openshift_version, .creation_timestamp] | @tsv')
    fi

    # Parse OSD clusters
    if [ -n "$osd_data" ]; then
        while IFS=$'\t' read -r id name version created; do
            if [ -n "$id" ] && [ "$id" != "null" ]; then
                clusters+=("$id")
                cluster_names["$id"]="$name"
                cluster_versions["$id"]="$version"
                cluster_creation_dates["$id"]="$created"
            fi
        done < <(echo "$osd_data" | jq -r '.items[]? | [.id, .name, .openshift_version, .creation_timestamp] | @tsv')
    fi
fi

total_clusters=${#clusters[@]}
echo "Found $total_clusters clusters"

# Limit clusters if requested
if [ -n "$MAX_CLUSTERS" ] && [ "$MAX_CLUSTERS" -lt "$total_clusters" ]; then
    clusters=("${clusters[@]:0:$MAX_CLUSTERS}")
    total_clusters=$MAX_CLUSTERS
    echo "Limited to first $total_clusters clusters"
fi

echo ""

# Identify HCP infrastructure clusters (unless --check-hcp-controllers is set)
if [ "$CHECK_HCP_CONTROLLERS" = false ]; then
    echo "Identifying HyperShift infrastructure clusters..."

    declare -a hcp_clusters=()
    declare -a workload_clusters=()

    for cluster_id in "${clusters[@]}"; do
        # Get cluster name from batch-fetched metadata
        cluster_name="${cluster_names[$cluster_id]:-unknown}"

        # Check if HCP infrastructure cluster (management or service cluster)
        if [[ "$cluster_name" == hs-mc-* ]] || [[ "$cluster_name" == hs-sc-* ]]; then
            hcp_clusters+=("$cluster_id:$cluster_name")
        else
            workload_clusters+=("$cluster_id")
        fi
    done

    # Display summary
    echo ""
    echo "================================================================================"
    echo "CLUSTER FILTERING SUMMARY"
    echo "================================================================================"
    echo "Total clusters in list:           $total_clusters"
    echo "HCP infrastructure clusters:      ${#hcp_clusters[@]} (will be EXCLUDED)"
    echo "ROSA Classic/OSD clusters:        ${#workload_clusters[@]} (will be checked)"
    echo "================================================================================"
    echo ""

    # Show which clusters will be excluded
    if [ ${#hcp_clusters[@]} -gt 0 ]; then
        echo ""
        echo "The following HyperShift infrastructure clusters will be EXCLUDED:"
        for hcp_entry in "${hcp_clusters[@]}"; do
            cluster_name="${hcp_entry#*:}"
            echo "  - $cluster_name"
        done
        echo ""
        echo "These clusters may run different CAMO versions for HCP control plane management."
        echo "Use --check-hcp-controllers flag to include them in health checks."
    fi

    # Check if any clusters remain
    if [ ${#workload_clusters[@]} -eq 0 ]; then
        echo "ERROR: No workload clusters to check after filtering HCP infrastructure clusters."
        echo "Use --check-hcp-controllers to include HCP infrastructure clusters."
        exit 1
    fi

    # Prompt user to continue ONLY if HCP clusters were excluded (only in interactive mode)
    if [ ${#hcp_clusters[@]} -gt 0 ]; then
        echo "================================================================================"
        if [ -t 0 ]; then
            # Interactive mode - prompt for confirmation
            read -p "Continue with health checks on ${#workload_clusters[@]} cluster(s)? (y/n): " user_confirm
            echo "================================================================================"

            if [ "$user_confirm" != "y" ] && [ "$user_confirm" != "Y" ]; then
                echo ""
                echo "Health check cancelled by user."
                exit 0
            fi
        else
            # Non-interactive mode - auto-continue
            echo "Non-interactive mode: Proceeding with health checks on ${#workload_clusters[@]} cluster(s)..."
            echo "================================================================================"
        fi
    fi

    # Update clusters array to only include workload clusters
    clusters=("${workload_clusters[@]}")
    total_clusters=${#clusters[@]}

    echo ""
    echo "Proceeding with health checks on $total_clusters cluster(s)..."
    echo ""
fi

# Initialize output file with header
if [ "$OP_VER_ONLY" = true ]; then
    echo "operator,cluster_id,cluster_name,cluster_version,operator_version" > "$OUTPUT_FILE"
elif [ "$HEALTH_CHECK" = true ]; then
    echo "operator,cluster_id,cluster_name,cluster_version,operator_version,namespace,deployment,health_status,health_issues,desired_replicas,ready_replicas,available_replicas,unavailable_replicas,pod_count,total_restarts,error_events,min_uptime_seconds,max_uptime_seconds,avg_uptime_seconds,error_summary,timestamp" > "$OUTPUT_FILE"
elif [ "$COMPREHENSIVE_HEALTH" = true ]; then
    # JSON Lines format (one JSON object per line)
    echo '{"health_checks":[]}' | jq -c '.health_checks = []' > "$OUTPUT_FILE"
    # Actually, just create empty file - we'll append JSON objects
    > "$OUTPUT_FILE"
elif [ "$METRICS_CHECK" = true ]; then
    echo "cluster_id,cluster_name,cluster_version,operator_version,namespace,health_status,health_issues,ga_secret_exists,pd_secret_exists,dms_secret_exists,am_secret_exists,am_secret_contains_ga,am_secret_contains_pd,am_secret_contains_dms,managed_namespaces_configmap_exists,ocp_namespaces_configmap_exists,alertmanager_config_validation_failed,timestamp" > "$OUTPUT_FILE"
elif [ "$VERSION_COMPARE" = true ]; then
    echo "operator,cluster_id,cluster_name,cluster_version,operator_version,version_period,namespace,deployment,replicas,requests_cpu,requests_memory,limits_cpu,limits_memory,max_cpu_cores,avg_cpu_cores,max_memory_bytes,avg_memory_bytes,period_start,period_end,timestamp" > "$OUTPUT_FILE"
else
    echo "operator,cluster_id,cluster_name,cluster_version,operator_version,namespace,deployment,replicas,requests_cpu,requests_memory,limits_cpu,limits_memory,current_cpu_cores,max_1h_cpu_cores,max_24h_cpu_cores,current_memory_bytes,max_1h_memory_bytes,max_24h_memory_bytes,timestamp" > "$OUTPUT_FILE"
fi

# Process each cluster
successful=0
failed=0
skipped=0

for i in "${!clusters[@]}"; do
    # Check if user interrupted the script
    if [ "$INTERRUPTED" = true ]; then
        echo "Exiting loop due to interrupt..."
        break
    fi

    cluster_id="${clusters[$i]}"
    current=$((i + 1))

    echo "================================================================================"
    echo "[$current/$total_clusters] Processing cluster: $cluster_id"
    echo "================================================================================"

    # Set cluster metadata early (with defaults) for use in error records
    # These will be updated with actual values after successful login
    cluster_name="${cluster_names[$cluster_id]:-unknown}"
    cluster_version="${cluster_versions[$cluster_id]:-unknown}"
    cluster_created="${cluster_creation_dates[$cluster_id]:-unknown}"

    # Logout from any previous session to ensure clean state
    echo "Logging out from any previous session..."
    ocm backplane logout &> /dev/null || true

    # Try to login to cluster
    echo "Logging in to cluster $cluster_id..."

    # Run login and capture output and exit code
    set +e  # Temporarily disable exit on error for this command
    login_output=$(ocm backplane login "$cluster_id" 2>&1)
    login_status=$?
    set -e  # Re-enable if needed (though we don't use -e globally anymore)

    # Display the login output
    echo "$login_output"

    # Check if login was successful (primarily use exit code)
    if [ $login_status -ne 0 ]; then
        echo ""
        echo "✗ Failed to login to cluster $cluster_id (exit code: $login_status), skipping..."
        ((skipped++)) || true
        echo ""

        # For comprehensive health checks, write a failure record to JSON
        if [ "$COMPREHENSIVE_HEALTH" = true ]; then
            # Create minimal health record indicating login failure
            cat >> "$OUTPUT_FILE" <<EOF
{
  "cluster_id": "$cluster_id",
  "cluster_name": "$cluster_name",
  "cluster_version": "$cluster_version",
  "operator_name": "unknown",
  "operator_version": "unknown",
  "operator_image": "",
  "namespace": "unknown",
  "deployment": "unknown",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "backplane_login": {
    "status": "FAILED",
    "exit_code": $login_status,
    "error_message": $(echo "$login_output" | jq -Rs .)
  },
  "health_summary": {
    "overall_status": "NO_ACCESS",
    "critical_count": 0,
    "warning_count": 0
  },
  "health_checks": [],
  "events": {
    "pod_restarts": [],
    "version_changes": []
  }
}
EOF
        fi

        continue
    fi

    # Additional check for error messages in output even if exit code is 0
    if echo "$login_output" | grep -iq -E "error|failed|unable|denied"; then
        echo ""
        echo "✗ Login to cluster $cluster_id appears to have failed (error detected in output), skipping..."
        ((skipped++)) || true
        echo ""
        continue
    fi

    echo ""
    echo "✓ Backplane login successful for cluster $cluster_id"
    echo ""

    # Get cluster metadata (name, version, creation date)
    # Use cached data from OCM if available, otherwise fetch individually
    if [ -n "${cluster_names[$cluster_id]:-}" ]; then
        # Use metadata from OCM cluster list
        cluster_name="${cluster_names[$cluster_id]}"
        cluster_version="${cluster_versions[$cluster_id]}"
        cluster_created="${cluster_creation_dates[$cluster_id]}"
        echo "Using cached cluster metadata:"
        echo "  Name: $cluster_name"
        echo "  Version: $cluster_version"
        echo "  Created: $cluster_created"
    else
        # Fetch metadata individually (when using --cluster-list)
        echo "Fetching cluster metadata..."
        cluster_data=$(ocm get cluster "$cluster_id" 2>/dev/null)
        cluster_name=$(echo "$cluster_data" | jq -r '.name // "unknown"')
        cluster_version=$(echo "$cluster_data" | jq -r '.openshift_version // "unknown"')
        cluster_created=$(echo "$cluster_data" | jq -r '.creation_timestamp // "unknown"')
        echo "Cluster: $cluster_name"
        echo "Version: $cluster_version"
        echo "Created: $cluster_created"
    fi
    echo ""

    # Collect data from this cluster
    # Note: Script outputs CSV to stdout (captured to file) and messages to stderr (shown to user)
    set +e  # Temporarily disable exit on error

    # Collect from each operator
    collection_status=0
    for op in "${OPERATORS_TO_COLLECT[@]}"; do
        # Parse operator configuration (format: name:namespace:deployment)
        IFS=':' read -r op_name op_namespace op_deployment <<< "${OPERATOR_CONFIGS[$op]}"

        # Set display label
        op_label="${op^^}"  # Convert to uppercase for display

        echo ""
        echo "Collecting data for $op_label..."

        if [ "$HEALTH_CHECK" = true ]; then
            # Perform health check
            ./collect_pod_health.sh \
                --namespace "$op_namespace" \
                --deployment "$op_deployment" \
                --cluster-id "$cluster_id" \
                --cluster-name "$cluster_name" \
                --cluster-version "$cluster_version" \
                --reason "$REASON" \
                --format csv \
                --operator-name "$op_name" >> "$OUTPUT_FILE"
        elif [ "$COMPREHENSIVE_HEALTH" = true ]; then
            # Perform comprehensive health check
            health_cmd="./collect_operator_health.sh \
                --namespace \"$op_namespace\" \
                --deployment \"$op_deployment\" \
                --cluster-id \"$cluster_id\" \
                --cluster-name \"$cluster_name\" \
                --cluster-version \"$cluster_version\" \
                --reason \"$REASON\" \
                --format json \
                --operator-name \"$op_name\""

            # Add --secrets flag if enabled
            if [ "$CHECK_SECRETS" = true ]; then
                health_cmd="$health_cmd --secrets"
            fi

            eval "$health_cmd" >> "$OUTPUT_FILE"
        elif [ "$METRICS_CHECK" = true ]; then
            # Collect Prometheus metrics (CAMO only)
            if [ "$op" = "camo" ]; then
                ./collect_camo_metrics.sh \
                    --namespace "$op_namespace" \
                    --deployment "$op_deployment" \
                    --cluster-id "$cluster_id" \
                    --cluster-name "$cluster_name" \
                    --cluster-version "$cluster_version" \
                    --reason "$REASON" \
                    --format csv >> "$OUTPUT_FILE"
            else
                echo "  ℹ Metrics collection not available for $op_label (CAMO only)"
            fi
        elif [ "$VERSION_COMPARE" = true ]; then
            # Collect version comparison metrics with debug logging
            ./collect_versioned_metrics.sh \
                --namespace "$op_namespace" \
                --deployment "$op_deployment" \
                --cluster-id "$cluster_id" \
                --cluster-name "$cluster_name" \
                --cluster-version "$cluster_version" \
                --reason "$REASON" \
                --operator-name "$op_name" \
                --format csv \
                --debug >> "$OUTPUT_FILE"
        elif [ "$OP_VER_ONLY" = true ]; then
            ./collect_pod_resource_usage.sh \
                --namespace "$op_namespace" \
                --deployment "$op_deployment" \
                --cluster-id "$cluster_id" \
                --cluster-name "$cluster_name" \
                --cluster-version "$cluster_version" \
                --reason "$REASON" \
                --format csv \
                --operator-name "$op_name" \
                --op-ver-only >> "$OUTPUT_FILE"
        else
            ./collect_pod_resource_usage.sh \
                --namespace "$op_namespace" \
                --deployment "$op_deployment" \
                --cluster-id "$cluster_id" \
                --cluster-name "$cluster_name" \
                --cluster-version "$cluster_version" \
                --reason "$REASON" \
                --format csv \
                --operator-name "$op_name" >> "$OUTPUT_FILE"
        fi

        if [ $? -ne 0 ]; then
            collection_status=1
            echo "✗ Failed to collect data for $op_label"
        else
            echo "✓ Successfully collected data for $op_label"
        fi
    done

    set -e  # Re-enable if needed

    if [ $collection_status -eq 0 ]; then
        echo ""
        echo "✓ Successfully collected data from $cluster_id"
        ((successful++)) || true
    else
        echo ""
        echo "✗ Failed to collect data from $cluster_id (exit code: $collection_status)"
        ((failed++)) || true
    fi

    echo ""

    # Small delay to avoid rate limiting
    sleep 2
done

# Convert JSONL to JSON array for comprehensive health checks (for HTML report compatibility)
if [ "$COMPREHENSIVE_HEALTH" = true ] && [ "$successful" -gt 0 ]; then
    echo "Converting output to JSON array format..."
    temp_file="${OUTPUT_FILE}.tmp"
    jq -s '.' "$OUTPUT_FILE" > "$temp_file" && mv "$temp_file" "$OUTPUT_FILE"
    echo "✓ Converted to JSON array format"
    echo ""
fi

echo "================================================================================"
if [ "$INTERRUPTED" = true ]; then
    echo "COLLECTION SUMMARY (INTERRUPTED)"
else
    echo "COLLECTION SUMMARY"
fi
echo "================================================================================"
echo "Total clusters:    $total_clusters"
echo "Successful:        $successful"
echo "Failed:            $failed"
echo "Skipped:           $skipped"
if [ "$INTERRUPTED" = true ]; then
    echo "Interrupted:       Yes (partial results)"
fi
echo "Output file:       $OUTPUT_FILE"
echo "================================================================================"
echo ""

if [ "$successful" -gt 0 ]; then
    if [ "$INTERRUPTED" = true ]; then
        echo "Partial data collection saved. Analyze with:"
    else
        echo "Data collection complete. Analyze with:"
    fi
    if [ "$HEALTH_CHECK" = true ]; then
        echo "  Review the health check results in: $OUTPUT_FILE"
        echo "  You can also use: ./analyze_health_data.sh $OUTPUT_FILE (if available)"
    else
        echo "  ./analyze_resource_data.sh $OUTPUT_FILE"
    fi
    echo ""
else
    echo "No data collected successfully."
    if [ "$INTERRUPTED" = false ]; then
        exit 1
    fi
fi

# Exit with error code if interrupted
if [ "$INTERRUPTED" = true ]; then
    exit 130  # Standard exit code for SIGINT (128 + 2)
fi
