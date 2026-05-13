#!/bin/bash
#
# Enhanced SAAS refs script that shows image tags and dates from Quay.io
#

saas_file="${1}"

if [ -z "${saas_file}" ]; then
  echo "Please provide a saas-file to fetch/curl from app-interface" 
  echo "(note must be logged into VPN for gitlab access)."
  echo ""
  echo "Example: ./get_app_interface_saas_refs_with_images.sh saas-configure-alertmanager-operator.yaml"
  exit 1
fi

# Fetch saas configuration
echo "Fetching SAAS deployment configuration..." >&2
saas_data=$(curl -s "https://gitlab.cee.redhat.com/service/app-interface/-/raw/master/data/services/osd-operators/cicd/saas/${saas_file}?ref_type=heads")

# Cache Quay.io API response (to avoid repeated calls)
echo "Fetching image metadata from Quay.io..." >&2
# Derive Quay repo name from SAAS filename (e.g., saas-configure-alertmanager-operator.yaml -> configure-alertmanager-operator)
quay_repo=$(echo "$saas_file" | sed 's/^saas-//;s/-pko\.yaml$/.yaml/;s/\.yaml$//')
quay_tags=$(curl -s "https://quay.io/api/v1/repository/app-sre/${quay_repo}/tag/?limit=200&page=1" 2>/dev/null)

# Print header
printf "%-30s %-12s %-10s %-25s %-20s\n" "TARGET" "GIT_REF" "SOAK_DAYS" "IMAGE_TAG" "IMAGE_DATE"
printf "%-30s %-12s %-10s %-25s %-20s\n" "------" "-------" "---------" "---------" "----------"

# Parse and display
echo "$saas_data" | yq -r '
  .resourceTemplates[] | 
  select(.name | test("'"${quay_repo}"'")) |
  .targets[] | 
  [.name, .ref, (.promotion.soakDays // "null")] | 
  @tsv
' | while IFS=$'\t' read -r target ref soakdays; do
  
  # Get short hash for display
  short_ref="${ref:0:12}"
  
  # Try to find matching image tag from Quay.io
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    # It's a full commit hash - look for matching tag
    # Tags follow pattern: v0.1.XXX-gCOMMIT where COMMIT is first 7 chars
    short_commit="${ref:0:7}"
    
    # Search for tag containing this commit hash and extract both name and date
    image_tag=$(echo "$quay_tags" | jq -r ".tags[] | select(.name | test(\"-g${short_commit}\")) | .name" 2>/dev/null | head -1)
    
    if [ -n "$image_tag" ]; then
      # Get the date for this specific tag
      last_modified=$(echo "$quay_tags" | jq -r ".tags[] | select(.name == \"${image_tag}\") | .last_modified" 2>/dev/null | head -1)
      
      # Convert from "Day, DD Mon YYYY HH:MM:SS -0000" to "YYYY-MM-DD HH:MM"
      if [ -n "$last_modified" ] && [ "$last_modified" != "null" ]; then
        # BSD date (macOS)
        image_date=$(date -j -f "%a, %d %b %Y %H:%M:%S %z" "$last_modified" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "${last_modified:5:11}")
      else
        image_date="unknown"
      fi
    else
      image_tag="sha:${short_commit}"
      image_date="unknown"
    fi
  else
    # It's a branch name like "master"
    image_tag="branch:${ref}"
    image_date="N/A"
  fi
  
  printf "%-30s %-12s %-10s %-25s %-20s\n" "$target" "$short_ref" "$soakdays" "$image_tag" "$image_date"
done

echo ""
echo "Image Tag Format: v0.1.XXX-gCOMMITHASH"
echo "  - Example: v0.1.798-g038acc6"
echo "  - Image Date: When the image was pushed to Quay.io"
echo ""
echo "Quay.io Repository: https://quay.io/repository/app-sre/${quay_repo}"
