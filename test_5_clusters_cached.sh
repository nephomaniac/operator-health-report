#!/bin/bash
set -euo pipefail

export OCM_CONFIG=~/.config/ocm/ocm.prod.json

echo "=========================================="
echo "Testing Caching on 5 Real Clusters"
echo "=========================================="
echo ""

# Time the run
START_TIME=$(date +%s)

./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper camo \
  -c test_clusters.list \
  -m 5 \
  -o cached_health_test_$(date +%Y%m%d_%H%M%S).json \
  -r "TESTING caching system performance"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo "=========================================="
echo "Test Complete!"
echo "Total runtime: ${MINUTES}m ${SECONDS}s"
echo "=========================================="
echo ""

# Find the output file
OUTPUT_FILE=$(ls -t cached_health_test_*.json 2>/dev/null | head -1)

if [ -n "$OUTPUT_FILE" ]; then
    echo "Generating HTML report..."
    ./generate_html_report.sh "$OUTPUT_FILE" "cached_test_report.html"
    
    echo ""
    echo "Opening report..."
    open cached_test_report.html
    
    echo ""
    echo "Files generated:"
    echo "  Data: $OUTPUT_FILE"
    echo "  Report: cached_test_report.html"
else
    echo "Error: No output file found"
    exit 1
fi
