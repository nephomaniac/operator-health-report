#!/usr/bin/env bash
#
# Run operator health checks inside a container for isolation.
#
# Usage:
#   ./run-in-container.sh [OPTIONS] -- [HEALTH CHECK OPTIONS]
#
# Container options (before --):
#   --build              Force rebuild the container image
#   --parallel N         Run N clusters concurrently (default: 1)
#   --engine ENGINE      Container engine: podman or docker (auto-detected)
#   --image IMAGE        Container image (default: operator-health-report:latest)
#
# Everything after -- is passed to collect_from_multiple_clusters.sh
#
# Examples:
#   ./run-in-container.sh -- --cluster-list stage_clusters.list --oper camo --oper rmo
#   ./run-in-container.sh --parallel 4 -- --cluster-list stage_clusters.list --oper camo --oper rmo --oper ome
#   ./run-in-container.sh --build -- --cluster-list test.list --oper rmo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="operator-health-report:latest"
PARALLEL=1
FORCE_BUILD=false
ENGINE=""

# Auto-detect container engine
detect_engine() {
    if command -v podman &>/dev/null; then
        echo "podman"
    elif command -v docker &>/dev/null; then
        echo "docker"
    else
        echo "Error: No container engine found. Install podman or docker." >&2
        exit 1
    fi
}

# Parse container options (before --)
HEALTH_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --build) FORCE_BUILD=true; shift ;;
        --parallel) PARALLEL="$2"; shift 2 ;;
        --engine) ENGINE="$2"; shift 2 ;;
        --image) IMAGE_NAME="$2"; shift 2 ;;
        --) shift; HEALTH_ARGS=("$@"); break ;;
        *) echo "Unknown container option: $1 (use -- to separate from health check options)" >&2; exit 1 ;;
    esac
done

[ -z "$ENGINE" ] && ENGINE=$(detect_engine)
echo "Container engine: $ENGINE"

# Build image if needed
image_exists=$($ENGINE images -q "$IMAGE_NAME" 2>/dev/null | head -1)
if [ -z "$image_exists" ] || [ "$FORCE_BUILD" = true ]; then
    echo "Building container image: $IMAGE_NAME"
    $ENGINE build -t "$IMAGE_NAME" "$SCRIPT_DIR"
else
    echo "Using existing image: $IMAGE_NAME"
fi

# Detect OCM config location
OCM_CONFIG="${OCM_CONFIG:-$HOME/.config/ocm/ocm.json}"
if [ ! -f "$OCM_CONFIG" ]; then
    # Try common locations
    for cfg in "$HOME/.ocm.json" "$HOME/.config/ocm/ocm.staging.json" "$HOME/.config/ocm/ocm.prod.json"; do
        if [ -f "$cfg" ]; then
            OCM_CONFIG="$cfg"
            break
        fi
    done
fi

if [ ! -f "$OCM_CONFIG" ]; then
    echo "Error: OCM config not found. Set OCM_CONFIG or run 'ocm login' first." >&2
    exit 1
fi
echo "OCM config: $OCM_CONFIG"

# Create results directory
RESULTS_DIR="$SCRIPT_DIR/results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"
echo "Results dir: $RESULTS_DIR"

# Resolve cluster list path (needs to be absolute for mount)
CLUSTER_LIST=""
for i in "${!HEALTH_ARGS[@]}"; do
    if [ "${HEALTH_ARGS[$i]}" = "--cluster-list" ] || [ "${HEALTH_ARGS[$i]}" = "-c" ]; then
        next=$((i + 1))
        if [ -n "${HEALTH_ARGS[$next]:-}" ]; then
            CLUSTER_LIST=$(cd "$(dirname "${HEALTH_ARGS[$next]}")" && pwd)/$(basename "${HEALTH_ARGS[$next]}")
            HEALTH_ARGS[$next]="/data/$(basename "$CLUSTER_LIST")"
        fi
    fi
done

if [ "$PARALLEL" -le 1 ]; then
    # Single container run
    echo ""
    echo "Running health checks in container..."
    $ENGINE run --rm \
        -v "$OCM_CONFIG:/root/.config/ocm/ocm.json:ro" \
        -v "$RESULTS_DIR:/results" \
        ${CLUSTER_LIST:+-v "$CLUSTER_LIST:/data/$(basename "$CLUSTER_LIST"):ro"} \
        -e "OCM_CONFIG=/root/.config/ocm/ocm.json" \
        "$IMAGE_NAME" \
        -c "cd /opt/health-report && bash collect_from_multiple_clusters.sh ${HEALTH_ARGS[*]} && cp -v health_*.json health_*.html /results/ 2>/dev/null || true"

    echo ""
    echo "Results saved to: $RESULTS_DIR"
    ls -la "$RESULTS_DIR"

    # Generate HTML locally if JSON exists (in case container didn't have all rendering deps)
    json_file=$(ls -t "$RESULTS_DIR"/*.json 2>/dev/null | head -1)
    if [ -n "$json_file" ]; then
        echo ""
        echo "Generating HTML report locally..."
        bash "$SCRIPT_DIR/generate_html_report.sh" "$json_file" "$RESULTS_DIR/health_report.html" 2>&1
    fi
else
    # Parallel: split cluster list and run N containers
    if [ -z "$CLUSTER_LIST" ]; then
        echo "Error: --parallel requires --cluster-list in health check options" >&2
        exit 1
    fi

    total_clusters=$(grep -c . "$CLUSTER_LIST")
    per_worker=$(( (total_clusters + PARALLEL - 1) / PARALLEL ))
    echo ""
    echo "Parallel mode: $PARALLEL workers, $total_clusters clusters, ~$per_worker per worker"

    # Split cluster list
    split -l "$per_worker" -d -a 2 "$CLUSTER_LIST" "$RESULTS_DIR/split_"

    # Start containers
    declare -a worker_pids=()
    worker_idx=0
    for split_file in "$RESULTS_DIR"/split_*; do
        worker_dir="$RESULTS_DIR/worker_${worker_idx}"
        mkdir -p "$worker_dir"
        split_name=$(basename "$split_file")
        count=$(wc -l < "$split_file" | tr -d ' ')

        echo "  Worker $worker_idx: $count clusters"
        $ENGINE run --rm \
            -v "$OCM_CONFIG:/root/.config/ocm/ocm.json:ro" \
            -v "$worker_dir:/results" \
            -v "$split_file:/data/clusters.list:ro" \
            -e "OCM_CONFIG=/root/.config/ocm/ocm.json" \
            "$IMAGE_NAME" \
            -c "cd /opt/health-report && bash collect_from_multiple_clusters.sh --cluster-list /data/clusters.list ${HEALTH_ARGS[*]/--cluster-list*/} && cp -v health_*.json /results/ 2>/dev/null || true" \
            > "$worker_dir/stdout.log" 2>&1 &
        worker_pids+=($!)
        worker_idx=$((worker_idx + 1))
    done

    # Wait for all workers
    echo ""
    echo "Waiting for $worker_idx workers..."
    all_ok=true
    for i in "${!worker_pids[@]}"; do
        if wait "${worker_pids[$i]}"; then
            echo "  Worker $i completed"
        else
            echo "  Worker $i failed (exit code: $?)"
            all_ok=false
        fi
    done

    # Merge results
    echo ""
    echo "Merging results..."
    merged_json="$RESULTS_DIR/health_merged.json"
    cat "$RESULTS_DIR"/worker_*/health_*.json 2>/dev/null | jq -s '{
        saas_targets: [.[][] | select(type == "object" and .type == "saas_targets")],
        clusters: [.[][] | select(type == "object" and .cluster_id != null)]
    } | .saas_targets as $meta | .clusters + $meta' > "$merged_json" 2>/dev/null

    entry_count=$(jq '[.[] | select(.cluster_id != null)] | length' "$merged_json" 2>/dev/null || echo "0")
    echo "Merged: $entry_count cluster entries"

    # Generate HTML
    echo "Generating HTML report..."
    bash "$SCRIPT_DIR/generate_html_report.sh" "$merged_json" "$RESULTS_DIR/health_report.html" 2>&1

    # Cleanup split files
    rm -f "$RESULTS_DIR"/split_*

    echo ""
    echo "Results saved to: $RESULTS_DIR"
    echo "  JSON: $merged_json"
    echo "  HTML: $RESULTS_DIR/health_report.html"
fi
