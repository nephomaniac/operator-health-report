#!/usr/bin/env bash
#
# Test image tag to SHA resolution
#
# Requires bash 4.0+ for associative arrays

# Check bash version
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Error: This script requires bash 4.0 or later (found ${BASH_VERSION})" >&2
    exit 1
fi

declare -A image_sha_cache

# Check if skopeo is available
if ! command -v skopeo &>/dev/null; then
    echo "Error: skopeo is not installed" >&2
    echo "Install with: brew install skopeo (macOS) or yum/apt install skopeo (Linux)" >&2
    exit 1
fi

# Test function to resolve image tag to SHA
resolve_image_sha() {
    local operator_image="$1"
    local current_image_sha=""
    local current_image_sha_short=""

    if [[ "$operator_image" == *"@sha256:"* ]]; then
        # Image already uses SHA reference - extract it directly
        current_image_sha=$(echo "$operator_image" | grep -oE 'sha256:[a-f0-9]{64}' | head -1)
        current_image_sha_short=$(echo "$current_image_sha" | cut -c8-19)
        echo "SHA-based reference (extracted): $current_image_sha_short"
    elif [ -n "$operator_image" ]; then
        # Image uses tag reference - resolve to SHA via registry (with caching)
        if [ -n "${image_sha_cache[$operator_image]:-}" ]; then
            # Use cached SHA
            current_image_sha="${image_sha_cache[$operator_image]}"
            current_image_sha_short=$(echo "$current_image_sha" | cut -c8-19)
            echo "Tag-based reference (cached): $current_image_sha_short"
        else
            # Query registry and cache result
            echo "Tag-based reference (querying registry): $operator_image"
            resolved_sha=$(skopeo inspect --no-tags "docker://${operator_image}" 2>/dev/null | jq -r '.Digest // empty' 2>/dev/null)
            if [ -n "$resolved_sha" ] && [ "$resolved_sha" != "null" ]; then
                image_sha_cache[$operator_image]="$resolved_sha"
                current_image_sha="$resolved_sha"
                current_image_sha_short=$(echo "$current_image_sha" | cut -c8-19)
                echo "  Resolved SHA: $current_image_sha_short (full: $current_image_sha)"
            else
                echo "  Failed to resolve SHA"
            fi
        fi
    fi

    echo ""
}

echo "Testing SHA resolution with caching"
echo "===================================="
echo ""

# Test 1: Tag-based reference (first time - should query)
echo "Test 1: First query for tag-based reference"
resolve_image_sha "quay.io/redhat-services-prod/openshift/configure-alertmanager-operator:fd1b002"

# Test 2: Same tag-based reference (should use cache)
echo "Test 2: Same image again (should use cache)"
resolve_image_sha "quay.io/redhat-services-prod/openshift/configure-alertmanager-operator:fd1b002"

# Test 3: SHA-based reference (should extract directly)
echo "Test 3: SHA-based reference"
resolve_image_sha "quay.io/app-sre/configure-alertmanager-operator@sha256:abc123def456789012345678901234567890123456789012345678901234"

echo "Cache contents:"
for key in "${!image_sha_cache[@]}"; do
    echo "  $key -> ${image_sha_cache[$key]}"
done
