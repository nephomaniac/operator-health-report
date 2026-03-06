# Version Verification Guide

## Overview

The comprehensive health check verifies that CAMO operators on clusters are running the expected version by comparing against staging hive clusters.

## How Version Verification Works

### Step 1: Fetch Staging Versions

The script queries app-interface to get the deployed versions on three staging hives:
- `camo-hive-stage-01`
- `camo-hives02ue1`
- `camo-hives03ue1`

This is done by calling:
```bash
~/.get_app_interface_saas_refs.sh saas-configure-alertmanager-operator.yaml
```

### Step 2: Verify Staging Consistency

The script checks if all three staging hives are running the **same version**.

#### Scenario A: All Staging Versions Match ✅

```
Fetching expected staging versions from app-interface...
  camo-hive-stage-01: 01fde38a9d0a
  camo-hives02ue1: 01fde38a9d0a
  camo-hives03ue1: 01fde38a9d0a

  ✓ All staging clusters running same version: 01fde38a9d0a
```

The script uses `01fde38a9d0a` as the canonical expected version.

#### Scenario B: Staging Versions Mismatch ⚠️

```
Fetching expected staging versions from app-interface...
  camo-hive-stage-01: 01fde38a9d0a
  camo-hives02ue1: abc123def456
  camo-hives03ue1: 01fde38a9d0a

  ✗✗✗ CRITICAL: Staging clusters have version MISMATCH! ✗✗✗

  Staging cluster versions:
    camo-hive-stage-01: 01fde38a9d0a
    camo-hives02ue1: abc123def456
    camo-hives03ue1: 01fde38a9d0a

  This indicates an inconsistent deployment state in staging.
  Please verify which version is correct before proceeding.

===============================================================================
STAGING VERSION MISMATCH DETECTED
===============================================================================

The following staging clusters are running DIFFERENT versions:
  1. camo-hive-stage-01: 01fde38a9d0a
  2. camo-hives02ue1: abc123def456
  3. camo-hives03ue1: 01fde38a9d0a

Enter the number of the CORRECT version to use for validation (1-3), or 'q' to skip version check:
```

**User Options:**
- Enter `1`, `2`, or `3` to select which staging version is correct
- Enter `q` to skip version verification
- Invalid input will skip version verification

### Step 3: Compare Cluster Version

Once the canonical version is determined, the script compares it against the cluster's running version.

**Version extraction logic:**
- Gets the deployment image from: `oc get deployment -n openshift-monitoring configure-alertmanager-operator`
- Extracts version from image tag (e.g., `v0.1.798-g038acc6`)
- Falls back to SHA hash if no version tag

**Matching logic:**
- Compares first 12 characters of the commit hash
- Checks if the canonical version is contained in the operator version or image
- Supports both full and short hash formats

## JSON Output

The health check JSON includes detailed version information:

```json
{
  "check": "version_verification",
  "status": "PASS",
  "severity": "warning",
  "message": "Version matches staging deployment (01fde38a9d0a)",
  "details": {
    "current_version": "01fde38a9d0a",
    "expected_version": "01fde38a9d0a",
    "staging_versions": [
      "01fde38a9d0a",
      "01fde38a9d0a",
      "01fde38a9d0a"
    ]
  }
}
```

### Status Values

- **PASS**: Cluster version matches expected staging version
- **FAIL**: Cluster version does NOT match expected version (may indicate installation error)
- **UNKNOWN**: Unable to determine expected version (staging data unavailable or user skipped)

## Common Scenarios

### 1. Successful Deployment ✅

**Cluster Running:** `01fde38a9d0a`
**Staging Versions:** `01fde38a9d0a` (all three match)
**Result:** PASS

```
✓ Version matches expected staging version
```

### 2. Installation Error ❌

**Cluster Running:** `abc123def456`
**Staging Versions:** `01fde38a9d0a` (all three match)
**Result:** FAIL

```
✗ Version does NOT match expected staging version
  Current: abc123def456
  Expected: 01fde38a9d0a
```

**Likely causes:**
- CAMO installation failed to update
- Manual intervention occurred
- Deployment pipeline error

### 3. Incomplete Staging Rollout ⚠️

**Cluster Running:** `01fde38a9d0a`
**Staging Versions:** Mixed (`01fde38a9d0a`, `abc123def456`, `01fde38a9d0a`)
**Result:** Depends on user selection

This indicates staging is mid-rollout or has a problem. User must decide which version is correct.

### 4. Unknown Version ⚠️

**Cluster Running:** `unknown` (couldn't extract version from image)
**Staging Versions:** `01fde38a9d0a` (all three match)
**Result:** FAIL

```
✗ Version does NOT match expected staging version
  Current: unknown
  Expected: 01fde38a9d0a
```

**Likely causes:**
- Image uses SHA-only reference (no version tag)
- Deployment uses non-standard image
- Unable to query deployment

## Troubleshooting

### Can't fetch staging versions

**Error:**
```
⚠ Warning: Could not fetch staging versions
```

**Causes:**
- Not connected to VPN
- `~/.get_app_interface_saas_refs.sh` not found
- app-interface unavailable

**Solution:**
1. Connect to VPN
2. Verify script exists: `ls -l ~/.get_app_interface_saas_refs.sh`
3. Test manually: `~/.get_app_interface_saas_refs.sh saas-configure-alertmanager-operator.yaml`

### Version shows as "unknown"

**Causes:**
- Image doesn't have version tag (uses SHA only)
- Script couldn't parse image reference
- Deployment not found

**Solution:**
1. Check deployment exists: `oc get deployment -n openshift-monitoring configure-alertmanager-operator`
2. Check image reference: `oc get deployment -n openshift-monitoring configure-alertmanager-operator -o jsonpath='{.spec.template.spec.containers[0].image}'`
3. If using SHA reference, the version extraction may not work - this is expected

### Staging version mismatch

**Causes:**
- Rollout in progress
- Failed deployment on one hive
- Intentional staging of different versions for testing

**Solution:**
1. Verify with team which version is correct
2. Check app-interface commits for recent changes
3. Check staging cluster status manually
4. Select the correct version when prompted, or skip if unsure

## Best Practices

1. **Always check staging consistency first** - If staging versions don't match, investigate before validating production
2. **Document version selection** - If you manually select a version during mismatch, note why in your JIRA ticket
3. **Monitor version drift** - Regularly check that production clusters match staging
4. **Automate remediation** - If many clusters show FAIL status, consider automated rollout to fix
5. **Investigate "unknown" versions** - These may indicate image tagging issues

## For RMO Operator

The same logic applies to RMO, but uses:
- SAAS file: `saas-route-monitor-operator.yaml`
- Staging clusters: (would need to be defined in the script)
- Namespace: `openshift-route-monitor-operator`
- Deployment: `route-monitor-operator-controller-manager`

## Multi-Cluster Analysis

When analyzing results across many clusters:

```bash
# Check how many clusters have version mismatches
jq -s '[.[] | .health_checks[] | select(.check == "version_verification" and .status == "FAIL")] | length' comprehensive_health_*.json

# List clusters with mismatches
jq -s -r '.[] | select(.health_checks[] | select(.check == "version_verification" and .status == "FAIL")) | .cluster_name' comprehensive_health_*.json

# Get version distribution
jq -s -r '.[] | .health_checks[] | select(.check == "version_verification") | .details.current_version' comprehensive_health_*.json | sort | uniq -c | sort -rn
```

## Related Files

- `collect_operator_health.sh` - Single-cluster health check (lines 165-290)
- `~/.get_app_interface_saas_refs.sh` - Fetches staging versions from app-interface
- `analyze_comprehensive_health.sh` - Parses and reports on health check results
