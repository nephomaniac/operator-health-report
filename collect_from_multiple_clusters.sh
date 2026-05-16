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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
CLUSTER_FILTER="all"
MAX_CLUSTERS=""
OP_VER_ONLY=false
HEALTH_CHECK=false
COMPREHENSIVE_HEALTH=true
METRICS_CHECK=false
VERSION_COMPARE=false
CHECK_HCP_CONTROLLERS=false
CHECK_SECRETS=false
GENERATE_HTML=true
HIVE_SHARD_FILTER=""
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
                                If not provided, clusters are fetched from OCM using --cluster-filter
    --cluster-filter FILTER     OCM cluster filter (default: all)
                                Options:
                                  all              - All ready ROSA/OSD clusters (includes MC/SC)
                                  no-hcp           - Exclude HyperShift management/service clusters
                                  custom:QUERY     - Custom OCM search query
                                Ignored if --cluster-list is provided
    --max-clusters, -m NUM      Maximum number of clusters to process
    --op-ver                    Only fetch operator version (cluster ID, name, operator version)
    --health                    Full health check (default mode): version, resources, logs, operator-specific checks
                                Automatically generates HTML report unless --no-html is specified
    --no-html                   Skip HTML report generation (only output JSON)
    --secrets                   Enable extended secret-based health checks (requires backplane elevation)
                                Checks: alertmanager-main secret, CAMO ConfigMap, PagerDuty secret
    --metrics                   Collect CAMO Prometheus metrics (secrets, configmaps, validation status)
    --version-compare           Collect resource metrics for both previous and current operator versions
    --oper OPERATOR             Operator to collect (camo, rmo). Can be specified multiple times.
                                Default: collect all supported operators (camo, rmo)
    --check-hcp-controllers     Include HyperShift infrastructure clusters (hs-mc-*, hs-sc-*)
                                By default, these clusters are EXCLUDED from health checks
    --hive-shard SHARD          Only process clusters managed by this Hive shard
                                Accepts a Hive cluster name (e.g., hive-stage-01) or provision shard ID
                                Clusters not matching the shard are skipped
    --help, -h                  Show this help message

EXAMPLES:
    # Interactive mode (will prompt for reason)
    $0 --comprehensive-health

    # Collect from all operators with specific reason (fetches all ready clusters from OCM)
    $0 --reason "SREP-12345 capacity planning"

    # Fetch clusters excluding HyperShift MC/SC clusters
    $0 -r "SREP-12345" --cluster-filter no-hcp

    # Use custom OCM query
    $0 -r "SREP-12345" --cluster-filter "custom:product.id='rosa' and region.id='us-east-1'"

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

# Function to discover Hive cluster managing a service cluster via OCM
# Returns the SAAS target name (e.g., "camo-<hive-cluster-name>")
discover_hive_target() {
    local cluster_id="$1"
    local ocm_env="$2"

    # For integration environment, return raw name
    if [ "$ocm_env" = "integration" ]; then
        echo "pko-integration"
        return 0
    fi

    # Query OCM for provision_shard to get Hive cluster info
    local provision_shard
    provision_shard=$(ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/provision_shard" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$provision_shard" ]; then
        # Fallback to environment-based defaults if OCM query fails
        case "$ocm_env" in
            stage) echo "staging" ;;
            production) echo "production" ;;
            *) echo "unknown" ;;
        esac
        return 1
    fi

    # Extract Hive cluster name from server URL
    # Example: https://api.hive-stage-01.n1u3.p1.openshiftapps.com:6443 -> hive-stage-01
    local hive_cluster
    hive_cluster=$(echo "$provision_shard" | jq -r '.hive_config.server // empty' | sed -n 's|https://api\.\([^.]*\)\..*|\1|p')

    if [ -z "$hive_cluster" ]; then
        # Fallback if extraction fails
        case "$ocm_env" in
            stage) echo "staging" ;;
            production) echo "production" ;;
            *) echo "unknown" ;;
        esac
        return 1
    fi

    # Return raw hive cluster name — target resolution happens in collect_operator_health.sh
    echo "${hive_cluster}"
    return 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --reason|-r) REASON="$2"; shift 2 ;;
        --output|-o) OUTPUT_FILE="$2"; shift 2 ;;
        --deployment|-d) DEPLOYMENT="$2"; shift 2 ;;
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        --cluster-list|-c) CLUSTER_LIST="$2"; shift 2 ;;
        --cluster-filter) CLUSTER_FILTER="$2"; shift 2 ;;
        --max-clusters|-m) MAX_CLUSTERS="$2"; shift 2 ;;
        --op-ver) OP_VER_ONLY=true; shift ;;
        --health|--comprehensive-health) COMPREHENSIVE_HEALTH=true; shift ;;
        --no-html) GENERATE_HTML=false; shift ;;
        --secrets) CHECK_SECRETS=true; shift ;;
        --metrics) METRICS_CHECK=true; shift ;;
        --version-compare) VERSION_COMPARE=true; shift ;;
        --check-hcp-controllers) CHECK_HCP_CONTROLLERS=true; shift ;;
        --hive-shard) HIVE_SHARD_FILTER="$2"; shift 2 ;;
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
    if [ "$COMPREHENSIVE_HEALTH" = true ]; then
        OUTPUT_FILE="health_$(date +%Y%m%d_%H%M%S).json"
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
if [ "$COMPREHENSIVE_HEALTH" = true ]; then
    echo "MULTI-CLUSTER HEALTH CHECK"
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
elif [ "$COMPREHENSIVE_HEALTH" = true ]; then
    echo "Mode:        Health check (version, resources, logs, operator-specific checks)"
elif [ "$METRICS_CHECK" = true ]; then
    echo "Mode:        Prometheus metrics collection"
elif [ "$VERSION_COMPARE" = true ]; then
    echo "Mode:        Version comparison (previous vs current)"
fi
if [ -n "$HIVE_SHARD_FILTER" ]; then
    echo "Hive Shard:  $HIVE_SHARD_FILTER (clusters not matching will be skipped)"
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

        # Detect OCM environment for caching
        OCM_ENV_CACHE=$(ocm config get url 2>/dev/null | grep -oE '(integration|stage|production)' | head -1)
        if [ -z "$OCM_ENV_CACHE" ]; then
            if [[ "$(ocm config get url 2>/dev/null)" == "https://api.openshift.com" ]]; then
                OCM_ENV_CACHE="production"
            else
                OCM_ENV_CACHE="unknown"
            fi
        fi

        # Pre-fetch and cache versions for all operators
        for op in "${OPERATORS_TO_COLLECT[@]}"; do
            # Set environment-aware saas file
            if [ "$op" = "camo" ]; then
                case "$OCM_ENV_CACHE" in
                    integration)
                        saas_file="saas-configure-alertmanager-operator-pko.yaml"
                        ;;
                    stage|production)
                        saas_file="saas-configure-alertmanager-operator.yaml"
                        ;;
                    *)
                        saas_file="saas-configure-alertmanager-operator.yaml"
                        ;;
                esac
            elif [ "$op" = "rmo" ]; then
                saas_file="saas-route-monitor-operator.yaml"
            fi

            # TODO: Implement version caching functions
            # NOTE: target_name discovery is now per-cluster (see discover_hive_target function)
            # because different Hive clusters in the same environment may run different versions
            # during progressive rollouts. Pre-caching a single version is not appropriate.
            # if [ -n "${saas_file:-}" ]; then
            #     echo "Pre-caching staging versions for $op..."
            #     canonical_version=$(get_canonical_staging_version "$saas_file" "$staging_clusters" 2>/dev/null || echo "")
            #     canonical_image_tag=$(get_canonical_staging_image_tag "$saas_file" "$staging_clusters" 2>/dev/null || echo "")
            #     if [ -n "$canonical_version" ]; then
            #         echo "  Cached: $canonical_version (tag: $canonical_image_tag)"
            #         # Export for use in sub-shells
            #         export "CACHED_STAGING_VERSION_${op}=$canonical_version"
            #         export "CACHED_STAGING_IMAGE_TAG_${op}=$canonical_image_tag"
            #     fi
            # fi
        done
        echo ""
    fi
fi

# Get cluster list and metadata
clusters=()
declare -A cluster_names
declare -A cluster_versions
declare -A cluster_creation_dates
declare -A cluster_hypershift

# Cache for Hive targets to avoid repeated OCM queries
# Key: cluster_id, Value: discovered target name (e.g., "camo-<hive-name>")
declare -A hive_target_cache

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

        # Build search query: id in ('id1', 'id2', 'id3') OR name in ('name1', 'name2', 'name3')
        # This handles both cluster IDs and cluster names
        id_list=$(printf "'%s'," "${batch_ids[@]}" | sed 's/,$//')
        search_query="id in ($id_list) or name in ($id_list)"

        echo "  Fetching batch $((i/batch_size + 1)): clusters $((i+1))-${batch_end} of ${total_to_fetch}..."

        # Fetch batch
        batch_data=$(ocm get clusters --parameter search="$search_query" 2>/dev/null)

        if [ -n "$batch_data" ]; then
            # Parse batch results
            while IFS=$'\t' read -r id name version created hypershift; do
                if [ -n "$id" ] && [ "$id" != "null" ]; then
                    # Store by ID (for ID-based lookups)
                    cluster_names["$id"]="$name"
                    cluster_versions["$id"]="$version"
                    cluster_creation_dates["$id"]="$created"
                    cluster_hypershift["$id"]="${hypershift:-false}"
                    # Also store by name (for name-based lookups)
                    cluster_names["$name"]="$name"
                    cluster_versions["$name"]="$version"
                    cluster_creation_dates["$name"]="$created"
                    cluster_hypershift["$name"]="${hypershift:-false}"
                fi
            done < <(echo "$batch_data" | jq -r '.items[]? | [.id, .name, .openshift_version, .creation_timestamp, (.hypershift.enabled // false)] | @tsv')
        fi
    done

    echo "✓ Batch fetch complete"
else
    # Fetch clusters from OCM based on filter
    custom_query=""
    rosa_query=""
    osd_query=""

    case "$CLUSTER_FILTER" in
        all)
            echo "Fetching all ready ROSA/OSD clusters from OCM..."
            # Fetch all ROSA clusters (classic + HCP)
            rosa_query="managed='true' and state='ready' and product.id='rosa'"
            # Fetch all OSD clusters
            osd_query="managed='true' and state='ready' and product.id='osd'"
            ;;
        no-hcp)
            echo "Fetching ready ROSA/OSD clusters from OCM (excluding HyperShift MC/SC)..."
            # Fetch only ROSA classic (exclude HCP)
            rosa_query="hypershift.enabled='false' and managed='true' and state='ready' and product.id='rosa'"
            # Fetch all OSD clusters
            osd_query="managed='true' and state='ready' and product.id='osd'"
            ;;
        custom:*)
            # Extract custom query after "custom:"
            custom_query="${CLUSTER_FILTER#custom:}"
            echo "Fetching clusters from OCM with custom query: $custom_query"
            ;;
        *)
            echo "Error: Unknown cluster filter: $CLUSTER_FILTER" >&2
            echo "Supported filters: all, no-hcp, custom:QUERY" >&2
            exit 1
            ;;
    esac

    # Execute OCM queries
    if [ -n "$custom_query" ]; then
        # Use custom query
        cluster_data=$(ocm get clusters --parameter search="$custom_query" 2>/dev/null)
        if [ -n "$cluster_data" ]; then
            while IFS=$'\t' read -r id name version created; do
                if [ -n "$id" ] && [ "$id" != "null" ]; then
                    clusters+=("$id")
                    cluster_names["$id"]="$name"
                    cluster_versions["$id"]="$version"
                    cluster_creation_dates["$id"]="$created"
                fi
            done < <(echo "$cluster_data" | jq -r '.items[]? | [.id, .name, .openshift_version, .creation_timestamp, (.hypershift.enabled // false)] | @tsv')
        fi
    else
        # Fetch ROSA clusters
        if [ -n "$rosa_query" ]; then
            rosa_data=$(ocm get clusters --parameter search="$rosa_query" 2>/dev/null)
            if [ -n "$rosa_data" ]; then
                while IFS=$'\t' read -r id name version created; do
                    if [ -n "$id" ] && [ "$id" != "null" ]; then
                        clusters+=("$id")
                        cluster_names["$id"]="$name"
                        cluster_versions["$id"]="$version"
                        cluster_creation_dates["$id"]="$created"
                    fi
                done < <(echo "$rosa_data" | jq -r '.items[]? | [.id, .name, .openshift_version, .creation_timestamp, (.hypershift.enabled // false)] | @tsv')
            fi
        fi

        # Fetch OSD clusters
        if [ -n "$osd_query" ]; then
            osd_data=$(ocm get clusters --parameter search="$osd_query" 2>/dev/null)
            if [ -n "$osd_data" ]; then
                while IFS=$'\t' read -r id name version created; do
                    if [ -n "$id" ] && [ "$id" != "null" ]; then
                        clusters+=("$id")
                        cluster_names["$id"]="$name"
                        cluster_versions["$id"]="$version"
                        cluster_creation_dates["$id"]="$created"
                    fi
                done < <(echo "$osd_data" | jq -r '.items[]? | [.id, .name, .openshift_version, .creation_timestamp, (.hypershift.enabled // false)] | @tsv')
            fi
        fi
    fi

    # Display cluster table
    echo ""
    echo "Fetched clusters from OCM:"
    echo ""
    printf "%-32s  %-25s  %-8s  %-7s  %-26s\n" "ID" "NAME" "VERSION" "STATUS" "CREATED"
    printf "%-32s  %-25s  %-8s  %-7s  %-26s\n" "--------------------------------" "-------------------------" "--------" "-------" "--------------------------"
    for cluster_id in "${clusters[@]}"; do
        cluster_name="${cluster_names[$cluster_id]:-unknown}"
        cluster_version="${cluster_versions[$cluster_id]:-unknown}"
        cluster_created="${cluster_creation_dates[$cluster_id]:-unknown}"
        printf "%-32s  %-25s  %-8s  %-7s  %-26s\n" "$cluster_id" "$cluster_name" "$cluster_version" "ready" "$cluster_created"
    done
    echo ""

    # Ask for user approval (only in interactive mode)
    if [ -t 0 ]; then
        read -p "Proceed with these ${#clusters[@]} clusters? [Y/n] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n $REPLY ]]; then
            echo "Aborted by user."
            exit 0
        fi
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

# Warn about HCP infrastructure clusters when --check-hcp-controllers is not set
if [ "$CHECK_HCP_CONTROLLERS" = false ]; then
    declare -a hcp_clusters=()
    hcp_count=0

    for cluster_id in "${clusters[@]}"; do
        cluster_name="${cluster_names[$cluster_id]:-unknown}"
        if [[ "$cluster_name" == hs-mc-* ]] || [[ "$cluster_name" == hs-sc-* ]]; then
            hcp_clusters+=("$cluster_name")
            ((hcp_count++)) || true
        fi
    done

    if [ $hcp_count -gt 0 ]; then
        echo ""
        echo "================================================================================"
        echo "WARNING: $hcp_count HCP infrastructure cluster(s) detected in the cluster list"
        echo "================================================================================"
        echo "These clusters (hs-mc-*/hs-sc-*) may run different CAMO versions for HCP"
        echo "control plane management. Use --check-hcp-controllers to suppress this warning."
        echo ""
        for name in "${hcp_clusters[@]}"; do
            echo "  - $name"
        done
        echo "================================================================================"
        echo ""
    fi
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

    # Filter by Hive shard if --hive-shard was specified
    if [ -n "$HIVE_SHARD_FILTER" ]; then
        echo "Checking provision shard for cluster $cluster_id..."
        shard_data=$(ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/provision_shard" 2>/dev/null)
        shard_server=$(echo "$shard_data" | jq -r '.hive_config.server // ""' 2>/dev/null)
        shard_id=$(echo "$shard_data" | jq -r '.id // ""' 2>/dev/null)

        # Cache the hive shard name from this early lookup
        if [ -n "$shard_server" ]; then
            hive_name=$(echo "$shard_server" | sed -n 's|https://api\.\([^.]*\)\..*|\1|p')
            hive_target_cache[$cluster_id]="${hive_name}"
        fi

        if [[ "$shard_server" == *"$HIVE_SHARD_FILTER"* ]] || [[ "$shard_id" == "$HIVE_SHARD_FILTER" ]]; then
            echo "  ✓ Matches hive shard: $HIVE_SHARD_FILTER (server: $shard_server)"
        else
            echo "  ✗ Shard mismatch (got: $shard_server), skipping..."
            ((skipped++)) || true
            echo ""
            continue
        fi
    fi

    # Skip HCP guest clusters (MC and SC clusters are still checked)
    is_hypershift="${cluster_hypershift[$cluster_id]:-false}"
    if [ "$is_hypershift" = "true" ] && [[ "$cluster_name" != hs-mc-* ]] && [[ "$cluster_name" != hs-sc-* ]]; then
        echo "  ✗ Skipping HCP guest cluster (operators managed at MC/SC level)"
        ((skipped++)) || true
        echo ""
        continue
    fi

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
  "cluster_type": "$(case "$cluster_name" in hs-mc-*) echo "management_cluster" ;; hs-sc-*) echo "service_cluster" ;; *) echo "standard" ;; esac)",
  "hive_shard": "${hive_target_cache[$cluster_id]:-unknown}",
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

    # Additional check for error-level log messages even if exit code is 0
    # Backplane CLI uses logrus: level=error for actual failures, level=warning for non-fatal issues
    # Warnings like "Could not fetch latest version from GitHub" are safe to ignore
    if echo "$login_output" | grep -q 'level=error'; then
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
        # Fetch metadata individually (when batch fetch failed)
        echo "Fetching cluster metadata..."
        # Try fetching by ID first
        cluster_data=$(ocm get cluster "$cluster_id" 2>/dev/null)

        # If not found, try searching by name (for SC/MC clusters)
        if [ -z "$cluster_data" ] || echo "$cluster_data" | jq -e '.kind == "Error"' &>/dev/null; then
            cluster_data=$(ocm get clusters --parameter search="name = '$cluster_id'" 2>/dev/null | jq -r '.items[0] // empty')
        fi

        cluster_name=$(echo "$cluster_data" | jq -r '.name // "unknown"')
        cluster_version=$(echo "$cluster_data" | jq -r '.openshift_version // "unknown"')
        cluster_created=$(echo "$cluster_data" | jq -r '.creation_timestamp // "unknown"')
        echo "Cluster: $cluster_name"
        echo "Version: $cluster_version"
        echo "Created: $cluster_created"
    fi
    echo ""

    # Discover and cache Hive target for this cluster
    # This avoids repeated OCM queries when multiple operators are collected
    if [ -z "${hive_target_cache[$cluster_id]:-}" ]; then
        # Detect OCM environment
        ocm_env=$(ocm config get url 2>/dev/null | grep -oE '(integration|stage|production)' | head -1)
        if [ -z "$ocm_env" ]; then
            if [[ "$(ocm config get url 2>/dev/null)" == "https://api.openshift.com" ]]; then
                ocm_env="production"
            else
                ocm_env="unknown"
            fi
        fi

        # Discover Hive target and cache it
        discovered_target=$(discover_hive_target "$cluster_id" "$ocm_env")
        hive_target_cache[$cluster_id]="$discovered_target"
        echo "Discovered Hive target for this cluster: $discovered_target (cached for reuse)"
    else
        echo "Using cached Hive target: ${hive_target_cache[$cluster_id]}"
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

        if [ "$COMPREHENSIVE_HEALTH" = true ]; then
            # Perform comprehensive health check
            health_cmd="\"$SCRIPT_DIR/collect_operator_health.sh\" \
                --namespace \"$op_namespace\" \
                --deployment \"$op_deployment\" \
                --cluster-id \"$cluster_id\" \
                --cluster-name \"$cluster_name\" \
                --cluster-version \"$cluster_version\" \
                --reason \"$REASON\" \
                --operator-name \"$op_name\""

            # Pass cached Hive target to avoid re-discovery
            if [ -n "${hive_target_cache[$cluster_id]:-}" ]; then
                health_cmd="$health_cmd --target-name \"${hive_target_cache[$cluster_id]}\""
            fi

            # Add --secrets flag if enabled
            if [ "$CHECK_SECRETS" = true ]; then
                health_cmd="$health_cmd --secrets"
            fi

            eval "$health_cmd" >> "$OUTPUT_FILE"
        elif [ "$METRICS_CHECK" = true ]; then
            # Collect Prometheus metrics (CAMO only)
            if [ "$op" = "camo" ]; then
                "$SCRIPT_DIR/collect_camo_metrics.sh" \
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
            "$SCRIPT_DIR/collect_versioned_metrics.sh" \
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
            "$SCRIPT_DIR/collect_pod_resource_usage.sh" \
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
            "$SCRIPT_DIR/collect_pod_resource_usage.sh" \
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
    # The output file contains concatenated JSON objects (multi-line, not JSONL)
    # jq --slurp reads all top-level values and wraps them in an array
    if jq -s '[.[] | select(type == "object" and .cluster_id != null)]' "$OUTPUT_FILE" > "$temp_file" 2>/dev/null && [ -s "$temp_file" ]; then
        mv "$temp_file" "$OUTPUT_FILE"
        entry_count=$(jq 'length' "$OUTPUT_FILE")
        echo "✓ Converted to JSON array format ($entry_count entries)"
    else
        echo "✗ JSON conversion failed — output may need manual cleanup"
        rm -f "$temp_file"
    fi
    echo ""

    # Generate HTML report (unless --no-html was specified)
    if [ "$GENERATE_HTML" = true ]; then
        echo "Generating HTML report..."
        HTML_FILE="${OUTPUT_FILE%.json}.html"

        if [ -x "$SCRIPT_DIR/generate_html_report.sh" ]; then
            if "$SCRIPT_DIR/generate_html_report.sh" "$OUTPUT_FILE" "$HTML_FILE"; then
                echo "✓ HTML report generated: $HTML_FILE"
                echo ""
            else
                echo "⚠ Warning: HTML report generation failed (JSON data still available)"
                echo ""
            fi
        else
            echo "⚠ Warning: generate_html_report.sh not found or not executable"
            echo ""
        fi
    fi
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
    elif [ "$COMPREHENSIVE_HEALTH" = true ]; then
        echo "  JSON data: $OUTPUT_FILE"
        if [ "$GENERATE_HTML" = true ] && [ -f "${OUTPUT_FILE%.json}.html" ]; then
            echo "  HTML report: ${OUTPUT_FILE%.json}.html"
            echo "  Open with: open ${OUTPUT_FILE%.json}.html"
        fi
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
