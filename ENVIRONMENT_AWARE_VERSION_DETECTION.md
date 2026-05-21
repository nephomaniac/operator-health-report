# Environment-Aware Version Detection

## Overview

The operator health check script now automatically detects the OCM environment (integration/stage/production) and uses the appropriate SAAS file and target for version verification.

## How It Works

### 1. OCM Environment Detection

The script detects which OCM environment you're logged into:

```bash
ocm config get url
# https://api.integration.openshift.com → integration
# https://api.stage.openshift.com → stage
# https://api.openshift.com → production
```

### 2. Environment-to-SAAS Mapping

Based on the detected environment, the script automatically selects:

| Environment | SAAS File | Target Name | Notes |
|-------------|-----------|-------------|-------|
| **integration** | `saas-configure-alertmanager-operator-pko.yaml` | `camo-pko-integration` | Uses PKO (OLM is deprecated) |
| **stage** | `saas-configure-alertmanager-operator.yaml` | `camo-hive-stage-01` | Uses OLM |
| **production** | `saas-configure-alertmanager-operator.yaml` | `production` | Uses OLM |

### 3. Version Verification Logic

The script now handles two types of refs:

#### Commit Hash Refs (Stage/Production)
- **Example:** `0fd5305f6c2c` (specific commit)
- **Behavior:** Exact version match required
- **Status:** PASS or FAIL

#### Branch Refs (Integration)
- **Example:** `master` (branch name)
- **Behavior:** Cannot verify exact commit without git access
- **Status:** SKIP (with informational message)
- **Rationale:** Integration uses moving `master` branch, so deployed commit will always differ from "master" string

## Example Output

### Integration Environment (Branch Ref)

```
CHECK 1: Version Verification Against Integration Environment Target
================================================================================
OCM Environment: integration
Target Name: camo-pko-integration
SAAS File: saas-configure-alertmanager-operator-pko.yaml

Fetching expected version from app-interface...
  Target: camo-pko-integration
  Expected Git Ref: master
  Expected Image Tag: branch:master

  ℹ Note: Target uses branch 'master' (not a specific commit)
  Version verification will check if deployed image is from this branch

  ℹ Skipping exact version match (target uses branch 'master')
    Deployed commit: 81d9d24
    Note: Cannot verify commit is from branch without git repository access
  ℹ Version check result: SKIP (branch-based target)
```

### Stage Environment (Commit Hash)

```
CHECK 1: Version Verification Against Stage Environment Target
================================================================================
OCM Environment: stage
Target Name: camo-hive-stage-01
SAAS File: saas-configure-alertmanager-operator.yaml

Fetching expected version from app-interface...
  Target: camo-hive-stage-01
  Expected Git Ref: 0fd5305f6c2c
  Expected Image Tag: v0.1.824-g0fd5305

  ✓ Version matches expected stage target version
```

## JSON Output

The health check JSON now includes environment context:

```json
{
  "check": "version_verification",
  "status": "SKIP",
  "severity": "warning",
  "message": "Version check skipped - integration target uses branch ref 'master' (deployed: 81d9d24)",
  "details": {
    "ocm_environment": "integration",
    "target_name": "camo-pko-integration",
    "saas_file": "saas-configure-alertmanager-operator-pko.yaml",
    "current_version": "81d9d24",
    "current_image_sha": "unknown",
    "expected_version": "master",
    "expected_image_tag": "branch:master",
    "match_method": "branch_ref_skip"
  }
}
```

## Migration Timeline

### CAMO OLM → PKO Migration

| Environment | Status | SAAS File | Notes |
|-------------|--------|-----------|-------|
| Integration | ✅ Migrated | PKO only | OLM target has `delete: true` |
| Stage | ⏳ Pending | OLM only | Will migrate to PKO |
| Production | ⏳ Pending | OLM only | Will migrate to PKO |

As environments migrate from OLM to PKO, update the environment mapping in `collect_operator_health.sh`:

```bash
case "$OCM_ENV" in
    integration)
        DEFAULT_SAAS_FILE="saas-configure-alertmanager-operator-pko.yaml"
        DEFAULT_TARGET_NAME="camo-pko-integration"
        ;;
    stage)
        # After stage migrates to PKO, update these:
        DEFAULT_SAAS_FILE="saas-configure-alertmanager-operator-pko.yaml"
        DEFAULT_TARGET_NAME="camo-pko-stage"
        ;;
    # ...
esac
```

## Override Behavior

You can override the automatic detection:

```bash
# Force specific SAAS file
SAAS_FILE="saas-configure-alertmanager-operator.yaml" \
./collect_operator_health.sh --reason "SREP-1234"

# Force specific target
TARGET_NAME="custom-target" \
./collect_operator_health.sh --reason "SREP-1234"
```

## Benefits

1. **Automatic environment detection** - No need to manually specify saas file
2. **Correct target selection** - Always uses the right target for your environment
3. **PKO migration aware** - Handles transition from OLM to PKO
4. **Branch ref support** - Gracefully handles branch-based targets (integration)
5. **Commit ref support** - Exact version matching for commit-based targets (stage/production)

## Future Enhancements

- [ ] Git repository access for branch verification (optional)
- [ ] Automatic PKO/OLM detection per environment
- [ ] Multi-target support (check multiple targets)
- [ ] Image tag verification via Quay API

---

**Last Updated:** 2026-03-28
**Related:** SREP-3848 (CAMO migration to PKO)
