#!/bin/bash

# Input files (active cluster lists from filter_active_clusters.sh)
INPUT_FILES=("warn_clusters_recheck.list")
NAMESPACE="openshift-route-monitor-operator"

for INPUT_FILE in "${INPUT_FILES[@]}"; do
    # Check if input file exists
    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "Warning: $INPUT_FILE not found, skipping..."
        continue
    fi

    # Derive output filename based on input
    BASE_NAME="${INPUT_FILE%_active.list}"
    OUTPUT_FILE="rmo_${BASE_NAME}_audit.txt"

    # Initialize output file with header
    cat > "$OUTPUT_FILE" << EOF
================================================================================
RMO Namespace Status Report - ${BASE_NAME}
Generated: $(date)
================================================================================

CLUSTER ID                               | OLM-CLEANUP | CONTROLLER-MGR | NO CSV | STATUS
-----------------------------------------|-------------|----------------|--------|--------
EOF

    echo ""
    echo "======================================"
    echo "Processing: $INPUT_FILE"
    echo "Output: $OUTPUT_FILE"
    echo "======================================"
    echo ""
    echo "CLUSTER ID                               | OLM-CLEANUP | CONTROLLER-MGR | NO CSV | STATUS"
    echo "-----------------------------------------|-------------|----------------|--------|--------"

    # Counters
    total=0
    successful=0
    failed=0

    while read -r cluster_id; do
        # Skip empty lines
        if [[ -z "$cluster_id" ]]; then
            continue
        fi

        ((total++))

        # Initialize check results
        olm_cleanup="❌"
        controller_mgr="❌"
        no_csv="❌"
        status="OK"

        # Try to login to cluster
        login_output=$(ocm backplane login $cluster_id 2>&1)
        login_exit=$?

        if [[ $login_exit -ne 0 ]]; then
            # Extract status code if present
            if echo "$login_output" | grep -q "Status Code:"; then
                status_code=$(echo "$login_output" | grep -o "Status Code: [0-9]*" | grep -o "[0-9]*")
                status="LOGIN_FAIL_${status_code}"
            elif echo "$login_output" | grep -q "could not login"; then
                status="LOGIN_FAIL"
            else
                status="LOGIN_ERROR"
            fi
            ((failed++))
            # Show first line of error for debugging
            error_msg=$(echo "$login_output" | head -1)
            printf "%-40s | %-11s | %-14s | %-6s | %s\n" "$cluster_id" "N/A" "N/A" "N/A" "$status"
            printf "%-40s | %-11s | %-14s | %-6s | %s - %s\n" "$cluster_id" "N/A" "N/A" "N/A" "$status" "$error_msg" >> "$OUTPUT_FILE"
            continue
        fi

        # Check if namespace exists and is not terminating
        ns_status=$(oc get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>&1)
        ns_exit=$?

        if [[ $ns_exit -ne 0 ]]; then
            status="NS_MISSING"
            ((failed++))
            printf "%-40s | %-11s | %-14s | %-6s | %s\n" "$cluster_id" "N/A" "N/A" "N/A" "$status"
            printf "%-40s | %-11s | %-14s | %-6s | %s\n" "$cluster_id" "N/A" "N/A" "N/A" "$status" >> "$OUTPUT_FILE"
            continue
        fi

        if [[ "$ns_status" == "Terminating" ]]; then
            status="NS_TERMINATING"
            ((failed++))
            printf "%-40s | %-11s | %-14s | %-6s | %s\n" "$cluster_id" "N/A" "N/A" "N/A" "$status"
            printf "%-40s | %-11s | %-14s | %-6s | %s\n" "$cluster_id" "N/A" "N/A" "N/A" "$status" >> "$OUTPUT_FILE"
            continue
        fi

        # Check for olm-cleanup job
        if oc get job -n "$NAMESPACE" 2>/dev/null | grep -q "olm-cleanup"; then
            olm_cleanup="✅"
        fi

        # Check for controller-manager pod running
        controller_pod=$(oc get po -n "$NAMESPACE" -o json 2>/dev/null | \
            jq -r '.items[] | select(.metadata.name | contains("route-monitor-operator-controller-manager")) | select(.status.phase == "Running") | .metadata.name' | head -1)

        if [[ -n "$controller_pod" ]]; then
            controller_mgr="✅"
        fi

        # Check that NO route-monitor-operator CSV exists, and get state if it does
        csv_info=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | \
            jq -r '.items[] | select(.metadata.name | contains("route-monitor-operator")) | "\(.metadata.name):\(.status.phase)"')

        csv_details=""
        if [[ -z "$csv_info" ]]; then
            no_csv="✅"
        else
            no_csv="❌"
            csv_name=$(echo "$csv_info" | cut -d':' -f1)
            csv_phase=$(echo "$csv_info" | cut -d':' -f2)
            csv_details=" [CSV: $csv_name ($csv_phase)]"
        fi

        # Determine overall status
        if [[ "$olm_cleanup" == "✅" && "$controller_mgr" == "✅" && "$no_csv" == "✅" ]]; then
            status="✅ PASS"
            ((successful++))
        else
            status="⚠️ WARN"
            ((failed++))
        fi

        # Output results
        printf "%-40s | %-11s | %-14s | %-6s | %s%s\n" "$cluster_id" "$olm_cleanup" "$controller_mgr" "$no_csv" "$status" "$csv_details"
        printf "%-40s | %-11s | %-14s | %-6s | %s%s\n" "$cluster_id" "$olm_cleanup" "$controller_mgr" "$no_csv" "$status" "$csv_details" >> "$OUTPUT_FILE"

    done < "$INPUT_FILE"

    # Summary for this file
    echo ""
    echo "================================================================================"
    echo "SUMMARY for ${BASE_NAME}"
    echo "================================================================================"
    echo "Total clusters checked: $total"
    echo "Successful (all checks passed): $successful"
    echo "Failed or warnings: $failed"
    echo ""
    echo "Detailed report saved to: $OUTPUT_FILE"

    # Add summary to report file
    cat >> "$OUTPUT_FILE" << EOF

================================================================================
SUMMARY
================================================================================
Total clusters checked: $total
Successful (all checks passed): $successful
Failed or warnings: $failed

Legend:
  OLM-CLEANUP: olm-cleanup job exists
  CONTROLLER-MGR: route-monitor-operator-controller-manager pod is Running
  NO CSV: No route-monitor-operator CSV found (should be absent)

Status Codes:
  ✅ PASS: All checks passed
  ⚠️ WARN: Some checks failed (CSV details shown if present)
  LOGIN_FAIL: Could not login to cluster
  LOGIN_FAIL_XXX: Login failed with HTTP status code XXX (e.g., 500, 404, etc.)
  LOGIN_ERROR: Other login error
  NS_MISSING: Namespace does not exist
  NS_TERMINATING: Namespace is in Terminating state

CSV Phase Values (when CSV exists):
  Succeeded: CSV installed successfully
  Failed: CSV installation failed
  Pending: CSV waiting for dependencies
  Installing: CSV currently installing
  Replacing: CSV being replaced by newer version
  Deleting: CSV being deleted
EOF

done

echo ""
echo "======================================"
echo "All RMO status checks complete!"
echo "======================================"
