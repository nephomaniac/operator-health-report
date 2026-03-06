# Version Verification - Image SHA Matching Fix

## Problem

The version verification check was comparing git commits extracted from image labels, which can be incorrect or outdated. This caused **false positives** where clusters running the correct version were flagged as mismatches.

### Example Scenario

- **Staging clusters**: Running commit `01fde38a9d0a` (tagged as `v0.1.810-g01fde38`)
- **Production cluster**: Running image `@sha256:ae6e064a909f...`
- **Git commit from labels**: `0ced2bbee24d` (incorrect/outdated)
- **Actual image SHA**: `ae6e064a909f` (which corresponds to `01fde38a9d0a`)

**Result**: Version check FAILS even though the cluster IS running the correct version.

## Solution

The health check now includes the **image SHA** in the version verification details, allowing you to manually verify correctness even when git commit comparison fails.

### What Changed

1. **Image SHA Extraction**: The script now extracts and displays the first 12 characters of the image SHA digest
2. **Enhanced Details**: Version verification now includes:
   - `current_version`: Git commit from image labels
   - `current_image_sha`: First 12 chars of SHA (e.g., `ae6e064a909f`)
   - `expected_version`: Expected git commit from staging
   - `match_method`: How the match was determined (if matched)

3. **Manual Verification**: You can now cross-reference the image SHA against staging to verify correctness

## How to Use

### In the HTML Report

When you expand the **Version Verification** health check, you'll now see:

```
current_version: 0ced2bbee24d
current_image_sha: ae6e064a909f
expected_version: 01fde38a9d0a
staging_versions: ["01fde38a9d0a", "01fde38a9d0a", "01fde38a9d0a"]
match_method: none
```

### Verifying a Mismatch

If you see a version mismatch (FAIL status), verify manually:

#### Option 1: Check Image SHA Against Staging

```bash
# Get the staging image tag
bash ~/.get_app_interface_saas_refs.sh saas-configure-alertmanager-operator.yaml | grep camo-hive-stage-01

# Output shows:
# camo-hive-stage-01  01fde38a9d0a  null  v0.1.810-g01fde38  2026-02-27 09:22

# Query the staging image to get its SHA
skopeo inspect --no-tags docker://quay.io/app-sre/configure-alertmanager-operator:v0.1.810-g01fde38 | \
  jq -r '.Digest'

# Compare SHA with cluster's image SHA
```

#### Option 2: Query Cluster Image for its Tags

```bash
# If cluster is using @sha256:ae6e064a909f..., query what tags point to this SHA
IMAGE="quay.io/app-sre/configure-alertmanager-operator@sha256:ae6e064a909f80d8b32a3e70bf5e1e4183c2c23c187e861d9f22b266a07614da"

skopeo inspect --no-tags "docker://$IMAGE" | jq -r '.RepoTags[]' | grep -E 'v0\.1\.'

# If output includes v0.1.810-g01fde38, the cluster IS on the correct version
```

#### Option 3: One-Liner SHA Verification

```bash
# Get current image SHA from cluster
CLUSTER_SHA=$(oc get deployment configure-alertmanager-operator -n openshift-monitoring \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -oE 'sha256:[a-f0-9]{64}')

# Get staging image tag
STAGING_TAG=$(bash ~/.get_app_interface_saas_refs.sh saas-configure-alertmanager-operator.yaml | \
  grep camo-hive-stage-01 | awk '{print $4}')

# Query staging image SHA
STAGING_SHA=$(skopeo inspect --no-tags \
  "docker://quay.io/app-sre/configure-alertmanager-operator:$STAGING_TAG" | jq -r '.Digest')

# Compare
if [ "$CLUSTER_SHA" = "$STAGING_SHA" ]; then
    echo "✓ Cluster is on correct version (SHA matches)"
else
    echo "✗ Cluster has wrong version (SHA mismatch)"
fi
```

## When to Investigate Further

### True Mismatch (Action Required)
- Git commit doesn't match **AND** image SHA doesn't match
- This indicates the cluster is actually on a different version
- **Action**: Investigate why the cluster isn't on the expected version

### False Positive (Can Ignore)
- Git commit doesn't match **BUT** image SHA matches staging
- This indicates incorrect image label metadata
- **Action**: No action needed - cluster is on correct version

### Unknown SHA
- `current_image_sha: unknown`
- This means the cluster is using a tagged image (not SHA-based)
- **Action**: Check if image tag matches staging tag

## Future Enhancements

Planned improvements:
- [ ] Automatic SHA comparison (query staging image SHA during check)
- [ ] Cache staging image SHAs to avoid repeated queries
- [ ] Flag false positives automatically in the report
- [ ] Add "Verify SHA" button in HTML report that runs verification

## Example Output

### Before Fix (Misleading)
```json
{
  "check": "version_verification",
  "status": "FAIL",
  "message": "Version mismatch",
  "details": {
    "current_version": "0ced2bbee24d",
    "expected_version": "01fde38a9d0a"
  }
}
```
**Problem**: No way to verify if this is a real mismatch or false positive

### After Fix (Verifiable)
```json
{
  "check": "version_verification",
  "status": "FAIL",
  "message": "Version mismatch - git commit from labels doesn't match",
  "details": {
    "current_version": "0ced2bbee24d",
    "current_image_sha": "ae6e064a909f",
    "expected_version": "01fde38a9d0a",
    "staging_versions": ["01fde38a9d0a"],
    "match_method": "none"
  }
}
```
**Benefit**: You can now verify the SHA against staging to confirm if it's a false positive

## Quick Reference

### Check if Version Mismatch is False Positive

```bash
# 1. Note the current_image_sha from the report (e.g., ae6e064a909f)

# 2. Get staging image tag
STAGING_TAG=$(bash ~/.get_app_interface_saas_refs.sh saas-configure-alertmanager-operator.yaml | \
  grep camo-hive-stage-01 | awk '{print $4}')

# 3. Check if SHA corresponds to this tag
skopeo inspect --no-tags docker://quay.io/app-sre/configure-alertmanager-operator:$STAGING_TAG | \
  jq -r '.Digest' | grep -q ae6e064a909f && \
  echo "✓ FALSE POSITIVE - cluster is on correct version" || \
  echo "✗ TRUE MISMATCH - cluster is on wrong version"
```

## Related Documentation

- [VERSION_VERIFICATION_GUIDE.md](VERSION_VERIFICATION_GUIDE.md) - Complete version verification guide
- [README_COMPREHENSIVE_HEALTH.md](README_COMPREHENSIVE_HEALTH.md) - Full health check documentation
- [RUN_ON_REAL_CLUSTERS.md](RUN_ON_REAL_CLUSTERS.md) - Running health checks on production
