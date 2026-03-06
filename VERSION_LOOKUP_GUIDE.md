# CAMO Version Lookup Guide

## How to Map Git Commit Hash to Version Tag

### Understanding the Version Formats

Your data shows two types of version identifiers:

1. **Semantic Versions** (with git hash suffix):
   - Format: `0.1.798-g038acc6`
   - Pattern: `MAJOR.MINOR.PATCH-gCOMMITHASH`
   - The `-g` prefix indicates git commit
   - `038acc6` is the short git commit hash
   - These come from tagged releases

2. **SHA-only Images** (untagged commits):
   - Format: `c8136eec250e`, `565879041ea1`, `22a46cad50a3`
   - These are commit hashes from development builds
   - No corresponding version tag (built from intermediate commits)

### Method 1: Query Quay.io Image Registry

The CAMO images are published to:
**https://quay.io/repository/app-sre/configure-alertmanager-operator**

To find version for a commit hash:

```bash
# Example: Find what version corresponds to commit hash c8136eec250e
COMMIT_HASH="c8136eec250e"

# Search Quay.io tags (requires authentication)
skopeo list-tags docker://quay.io/app-sre/configure-alertmanager-operator | \
  jq -r '.Tags[]' | grep -E "^[0-9]|${COMMIT_HASH}"
```

Or browse the web UI:
https://quay.io/repository/app-sre/configure-alertmanager-operator?tab=tags

### Method 2: Check Running Cluster

Get the full image path from a running cluster:

```bash
# Login to cluster
ocm backplane login <cluster-id>

# Get the full image specification
oc get deployment -n openshift-monitoring configure-alertmanager-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Example output:
# quay.io/app-sre/configure-alertmanager-operator:0.1.798-g038acc6
# quay.io/app-sre/configure-alertmanager-operator@sha256:565879041ea1...
```

### Method 3: Git Repository Tag Lookup

If you have the CAMO git repo locally:

```bash
cd /path/to/configure-alertmanager-operator

# Update all tags
git fetch --all --tags

# Find tag containing a specific commit
git describe --tags <commit-hash>

# Or search for commit in tag history
git tag --contains <commit-hash>

# List recent version tags
git tag -l "v0.1.*" | sort -V | tail -10

# Find commit for a known version
git rev-parse v0.1.798  # Returns full commit hash
```

### Method 4: Reverse Lookup (from semver to commit)

For versions like `0.1.798-g038acc6`:
- The commit hash is: `038acc6` (short form)
- To get full hash: `git rev-parse 038acc6`

### Practical Examples

#### Example 1: What version is commit c8136eec250e?

```bash
# Option A: Check in git repo
cd /path/to/configure-alertmanager-operator
git describe --tags c8136eec250e
# Output: v0.1.XXX-YYY-gc8136ee (if tagged)

# Option B: Search Quay.io
# Browse: https://quay.io/repository/app-sre/configure-alertmanager-operator?tab=tags
# Search for: c8136eec250e
```

#### Example 2: What commits are in version 0.1.798-g038acc6?

The commit hash is part of the version: `038acc6`

```bash
# Full commit hash
git rev-parse 038acc6

# See what's in this version
git show 038acc6
```

#### Example 3: What version was running on a specific cluster?

From your CSV data:
```bash
# Check version_compare CSV
grep "cluster-id" version_compare_20260217_154619.csv

# Output shows both version identifiers:
# - operator_version column has the version
# - Can be semver (0.1.798-g038acc6) or SHA (c8136eec250e)
```

### Image Registry Details

**Primary Registry**: Quay.io
- URL: https://quay.io/repository/app-sre/configure-alertmanager-operator
- Organization: app-sre
- Public read access
- Tags include both version numbers and SHA digests

**Tag Naming Convention**:
- `0.1.798-g038acc6` - Version with commit hash
- `latest` - Latest build (use with caution)
- SHA digests - Immutable references

### Script to Lookup Multiple Hashes

```bash
#!/bin/bash
# lookup_camo_versions.sh

REPO_DIR="/path/to/configure-alertmanager-operator"

for hash in c8136eec250e c9a0553c1eb5 565879041ea1 22a46cad50a3; do
    echo "Commit: $hash"
    cd "$REPO_DIR"
    git fetch --all --tags 2>/dev/null
    version=$(git describe --tags "$hash" 2>/dev/null || echo "No tag found")
    echo "  Version: $version"
    echo ""
done
```

### Common Version Mappings (from your data)

Based on clusters in your collection:

| Commit Hash  | Version Tag      | Clusters | Notes |
|--------------|------------------|----------|-------|
| 038acc6      | 0.1.798-g038acc6 | 42       | Latest, good memory profile |
| eab01dd      | 0.1.781-geab01dd | 11       | High memory usage |
| c7d7013      | 0.1.760-gc7d7013 | 1        | Older version |
| c8136eec250e | Unknown/Untagged | 15       | Development build |
| 565879041ea1 | Unknown/Untagged | 13       | Development build |
| c9a0553c1eb5 | Unknown/Untagged | 8        | Development build |

### Recommendations

1. **For Production**: Use semantic version tags (e.g., 0.1.798-g038acc6)
   - These are official releases
   - Easier to track and compare
   - Better for troubleshooting

2. **Avoid**: SHA-only images in production
   - Harder to track what version/features are included
   - May be intermediate/untested builds
   - Difficult to correlate with release notes

3. **For Metrics Collection**: Update script to parse both formats
   - Your script already handles both (good!)
   - Semver is preferred in reports

### Getting Image Information from Cluster

```bash
# Get current CAMO image
oc get deployment -n openshift-monitoring configure-alertmanager-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Get image digest (immutable reference)
oc get deployment -n openshift-monitoring configure-alertmanager-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | \
  grep -oP '@sha256:\K.*'

# Get both tag and digest
oc get pods -n openshift-monitoring -l name=configure-alertmanager-operator \
  -o jsonpath='{.items[0].status.containerStatuses[0].image}'
```

### Additional Resources

- CAMO Repository: https://github.com/openshift/configure-alertmanager-operator
- Quay.io Registry: https://quay.io/repository/app-sre/configure-alertmanager-operator
- Release Notes: Check git tags in repository
