#!/bin/bash

# Input files
INPUT_FILES=("hivep03uw1Namespaces" "hivep04ew2Namespaces")

echo "Filtering active clusters..."
echo ""

for INPUT_FILE in "${INPUT_FILES[@]}"; do
    # Derive output filename
    OUTPUT_FILE="${INPUT_FILE}_active.list"

    # Clear output file if it exists
    > "$OUTPUT_FILE"

    echo "======================================"
    echo "Processing: $INPUT_FILE"
    echo "======================================"

    # Read cluster IDs from input file
    while read -r cluster_id rest; do
        # Skip empty lines
        if [[ -z "$cluster_id" ]]; then
            continue
        fi

        echo "Checking cluster: $cluster_id"

        # Run ocm describe cluster and capture output and exit code
        output=$(ocm describe cluster "$cluster_id" 2>&1)
        exit_code=$?

        # Check if command failed (404 error)
        if [[ $exit_code -ne 0 ]] || echo "$output" | grep -q "404\|not found"; then
            echo "  ❌ Skipped (404 - not found)"
            continue
        fi

        # Check if state is pending
        if echo "$output" | grep -q "^State:[[:space:]]*pending"; then
            echo "  ❌ Skipped (pending)"
            continue
        fi

        # Check if cluster is HCP (Hosted Control Plane) - these don't have RMO
        if echo "$output" | grep -q "^HCP:[[:space:]]*true"; then
            echo "  ❌ Skipped (HCP cluster - no RMO)"
            continue
        fi

        # If we got here, cluster is active and not HCP
        echo "  ✅ Active - added to list"
        echo "$cluster_id" >> "$OUTPUT_FILE"

    done < "$INPUT_FILE"

    echo ""
    echo "Active clusters saved to: $OUTPUT_FILE"
    echo "Total active clusters: $(wc -l < "$OUTPUT_FILE")"
    echo ""
done

echo "======================================"
echo "Filtering complete for all files!"
echo "======================================"
