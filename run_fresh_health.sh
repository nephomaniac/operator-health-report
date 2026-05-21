#!/bin/bash
set -euo pipefail

export OCM_CONFIG=~/.config/ocm/ocm.prod.json

# Create a small test cluster list (only non-HCP clusters)
cat > fresh_test_clusters.list << LIST
27fd1e14gi4pkct19qo1jgbsodv22n5i
2ol2kdks4b99g7fvn4tvkcimgvo0a26n
2onr1cusvgqrhc7l5jku6la0rvmkh2im
LIST

echo "Running fresh health check on 3 ROSA Classic clusters..."

./collect_from_multiple_clusters.sh \
  --comprehensive-health \
  --oper camo \
  -c fresh_test_clusters.list \
  -o fresh_health_$(date +%Y%m%d_%H%M%S).json \
  -r "TESTING fresh health check with charts"

# Find the output file
OUTPUT_FILE=$(ls -t fresh_health_*.json 2>/dev/null | head -1)

if [ -n "$OUTPUT_FILE" ]; then
    echo ""
    echo "✓ Health check complete: $OUTPUT_FILE"
    echo "Generating HTML report..."
    
    ./generate_html_report.sh "$OUTPUT_FILE" "fresh_health_report.html"
    
    echo ""
    echo "✓ HTML report generated: fresh_health_report.html"
    echo ""
    echo "Opening report..."
    open fresh_health_report.html
else
    echo "Error: No output file found"
    exit 1
fi
