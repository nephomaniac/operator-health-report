# CAMO Git Commit to Image Version Mapping

## Quick Answer

**Yes!** Use Quay.io repository to map commit hashes to image tags:
https://quay.io/repository/app-sre/configure-alertmanager-operator?tab=tags

## Mapping Format

Git commits in CAMO are tagged with semantic versions following this pattern:

```
v0.1.798-g038acc6
  |      | └─ Git commit hash (first 7 chars)
  |      └─ "g" prefix indicates git
  └─ Semantic version
```

Full commit: `038acc67a2f0b42682bc69642c5395d5c30ceedf`
Short form: `038acc6`
Image tag: `v0.1.798-g038acc6` or `0.1.798-g038acc6`

## Real Examples from Your Data

From the version comparison collection:

| Commit Hash (from cluster) | Image Tag         | Clusters |
|----------------------------|-------------------|----------|
| 038acc6                    | 0.1.798-g038acc6  | 42       |
| eab01dd                    | 0.1.781-geab01dd  | 11       |
| c7d7013                    | 0.1.760-gc7d7013  | 1        |

## Current Deployment Status (from app-interface)

Stage environments:
  - Commit: 038acc67a2f0b42682bc69642c5395d5c30ceedf
  - Image: v0.1.798-g038acc6
  
Production environments:
  - Commit: 4babac14dcfb72d48c3e6683d50d13f67a3b8dde
  - Image: v0.1.791-g4babac1

## Method 1: Use Enhanced Script

```bash
./get_app_interface_saas_refs_with_images.sh saas-configure-alertmanager-operator.yaml
```

Output shows:
- TARGET: Deployment environment
- GIT_REF: Git commit (first 12 chars)
- SOAK_DAYS: Promotion soak period
- IMAGE_TAG: Quay.io image tag (auto-looked up!)

## Method 2: Manual Quay.io Lookup

### Via Web UI:
1. Go to: https://quay.io/repository/app-sre/configure-alertmanager-operator?tab=tags
2. Search for your commit hash (e.g., "038acc6")
3. Find matching tag (e.g., "0.1.798-g038acc6")

### Via API:
```bash
# Find image tag for commit 038acc6
curl -s "https://quay.io/api/v1/repository/app-sre/configure-alertmanager-operator/tag/?limit=100" | \
  jq -r '.tags[] | select(.name | test("038acc6")) | .name'
  
# Output: v0.1.798-g038acc6
```

### Via skopeo (if installed):
```bash
skopeo list-tags docker://quay.io/app-sre/configure-alertmanager-operator | \
  jq -r '.Tags[]' | grep "038acc6"
  
# Output: 0.1.798-g038acc6
```

## Method 3: Reverse Lookup (Image Tag → Commit)

If you know the version tag, extract the commit:

```bash
IMAGE_TAG="0.1.798-g038acc6"

# Extract commit hash (remove "v" prefix if present, take part after "-g")
COMMIT_SHORT=$(echo "$IMAGE_TAG" | sed 's/^v//' | grep -oP '(?<=-g)[0-9a-f]+')

echo "Commit: $COMMIT_SHORT"
# Output: 038acc6

# Get full commit from git repo
cd /Users/maclark/sandbox/configure-alertmanager-operator
git rev-parse ${COMMIT_SHORT}
# Output: 038acc67a2f0b42682bc69642c5395d5c30ceedf
```

## Mapping Untagged SHA Images

Some clusters show SHA-only images (no version tag):

```
c8136eec250e
565879041ea1
c9a0553c1eb5
```

These are either:
1. Development/intermediate builds (not tagged releases)
2. Images built from commits without version tags
3. SHA256 digest references (immutable)

To find their version:
```bash
# Check if they exist in Quay.io tags
for sha in c8136eec250e 565879041ea1 c9a0553c1eb5; do
  echo "Checking: $sha"
  curl -s "https://quay.io/api/v1/repository/app-sre/configure-alertmanager-operator/tag/?limit=200" | \
    jq -r ".tags[] | select(.name | test(\"${sha:0:7}\")) | .name"
done
```

## Quick Reference Commands

### Get version for commit in your CSV data:
```bash
# Extract unique versions from CSV
tail -n +2 version_compare_20260217_154619.csv | \
  awk -F',' '{print $5}' | sort -u

# Map each to full version via Quay.io
for ver in $(tail -n +2 version_compare_20260217_154619.csv | awk -F',' '{print $5}' | sort -u); do
  if [[ ! "$ver" =~ ^0\.1\. ]]; then
    # It's a SHA hash, lookup in Quay
    echo -n "$ver -> "
    curl -s "https://quay.io/api/v1/repository/app-sre/configure-alertmanager-operator/tag/?limit=100" | \
      jq -r ".tags[] | select(.name | test(\"${ver:0:7}\")) | .name" | head -1
  else
    echo "$ver -> Already versioned"
  fi
done
```

### Get current production version:
```bash
./get_app_interface_saas_refs_with_images.sh saas-configure-alertmanager-operator.yaml | \
  grep "prod" | head -1
```

### Check what's in master branch:
```bash
./get_app_interface_saas_refs_with_images.sh saas-configure-alertmanager-operator.yaml | \
  grep "master"
```

## Important Notes

1. **Quay.io is the source of truth** for CAMO images
2. **Image tags include commit hash** making correlation easy
3. **Production uses tagged releases** (v0.1.XXX-gCOMMIT)
4. **Stage/Integration may use master branch** (latest builds)
5. **Some cluster images are SHA-only** (need manual lookup)

## Best Practice

When analyzing cluster data:
1. Use the enhanced script to see current deployments
2. Map SHA hashes to versions via Quay.io API
3. Update your analysis scripts to include version tags
4. Track which clusters are on which versions

## Files Created

- `get_app_interface_saas_refs_with_images.sh` - Enhanced script with Quay.io lookup
- `VERSION_LOOKUP_GUIDE.md` - Complete version lookup reference
- `COMMIT_TO_VERSION_MAPPING.md` - This file

