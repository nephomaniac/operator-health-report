#!/usr/bin/env bash
#
# Test that the skopeo warning works correctly
#

# Test with skopeo available (comment out to test without skopeo)
PATH_BACKUP="$PATH"
# export PATH="/usr/bin:/bin"  # Uncomment to simulate missing skopeo

# Simulate the skopeo check logic from collect_operator_health.sh
SKOPEO_AVAILABLE=false
SKOPEO_WARNING_SHOWN=false
if command -v skopeo &>/dev/null; then
    SKOPEO_AVAILABLE=true
fi

echo "SKOPEO_AVAILABLE: $SKOPEO_AVAILABLE"
echo ""

# Simulate processing 3 tag-based images
for i in 1 2 3; do
    operator_image="quay.io/example/operator:v1.0.$i"

    echo "Processing image $i: $operator_image"

    if [[ "$operator_image" == *"@sha256:"* ]]; then
        echo "  SHA-based reference"
    elif [ -n "$operator_image" ] && [ "$SKOPEO_AVAILABLE" = true ]; then
        echo "  Tag-based reference - would resolve with skopeo"
    elif [ -n "$operator_image" ] && [ "$SKOPEO_AVAILABLE" = false ] && [ "$SKOPEO_WARNING_SHOWN" = false ]; then
        echo "Warning: skopeo not installed - cannot resolve image tags to SHAs" >&2
        SKOPEO_WARNING_SHOWN=true
        echo "  Tag-based reference - skopeo not available (warned)"
    elif [ -n "$operator_image" ] && [ "$SKOPEO_AVAILABLE" = false ]; then
        echo "  Tag-based reference - skopeo not available (already warned)"
    fi
    echo ""
done

# Restore PATH
export PATH="$PATH_BACKUP"
