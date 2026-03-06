# Public Repository Preparation Checklist

## Files to Include

### Core Scripts ✓
- `collect_from_multiple_clusters.sh` - Needs sanitization (see below)
- `collect_operator_health.sh` - Needs sanitization (see below)
- `collect_pod_health.sh`
- `collect_pod_resource_usage.sh`
- `generate_html_report.sh`
- `analyze_comprehensive_health.sh`
- `analyze_health_data.sh`
- `analyze_resource_data.sh`
- `query_prometheus_max_resources_v2.sh`

### Documentation ✓
- `README.md` - Updated for generic use
- `README_COMPREHENSIVE_HEALTH.md`
- `HTML_REPORTS_GUIDE.md`
- `HEALTH_CHECK_QUICK_START.md`
- `DEBUG_GUIDE.md`
- `VERSION_VERIFICATION_GUIDE.md`
- `VERSION_LOOKUP_GUIDE.md`

### Optional Utilities ✓
- `get_clusters.sh` - Generic OCM commands (OK to include)
- `.gitignore` - Already configured

## Files to EXCLUDE (Sensitive Data)

### Cluster Lists
- `cluster_camo_list` - Contains real cluster IDs
- `clusters.list` - Contains real cluster IDs
- `*.list` files - All contain environment-specific data

### Test/Debug Scripts
- `test_*.sh` - Internal testing scripts
- `debug_rmo_pods.sh` - Environment-specific
- `run_fresh_health.sh` - Environment-specific
- `test_multi_fixed.jsonl` - Test data

### Internal-Only Scripts
- `get_app_interface_saas_refs.sh` - References internal Red Hat app-interface
- `get_app_interface_saas_refs_with_images.sh` - References internal Red Hat app-interface

### Configuration Files with Specific Data
- `camo_metrics_versions.conf` - May contain specific configs

### Analysis/Fix Documentation (Internal)
- `ANALYSIS_FIXES.md` - Internal analysis
- `FIXES.md` - Internal fixes
- `VERSION_VERIFICATION_FIX.md` - Internal issue tracking
- `CHART_FIXES.md` - Internal issue tracking
- `DEPLOYMENT_STATUS_SUMMARY.md` - Environment-specific
- `PROPOSED_LIMITS_ANALYSIS.md` - Environment-specific
- `RECOMMENDED_RESOURCE_LIMITS.md` - Environment-specific
- `COMMIT_TO_VERSION_MAPPING.md` - Environment-specific
- `CACHING_OPTIMIZATION.md` - Internal optimization notes
- `RUN_ON_REAL_CLUSTERS.md` - Environment-specific

## Required Sanitization

### collect_operator_health.sh

**Line 30: STAGING_CLUSTERS**
```bash
# Current (specific):
STAGING_CLUSTERS=("camo-hive-stage-01" "camo-hives02ue1" "camo-hives03ue1")

# Replace with:
STAGING_CLUSTERS=("${STAGING_CLUSTERS[@]}")  # Allow override via environment
# Default: STAGING_CLUSTERS=("staging-cluster-1" "staging-cluster-2" "staging-cluster-3")
```

**Line 357: app-interface reference**
```bash
# Current (internal dependency):
staging_refs=$(bash "$HOME/.get_app_interface_saas_refs.sh" "$SAAS_FILE" 2>/dev/null)

# Replace with:
# Option 1: Make optional
if [ -f "$HOME/.get_app_interface_saas_refs.sh" ]; then
    staging_refs=$(bash "$HOME/.get_app_interface_saas_refs.sh" "$SAAS_FILE" 2>/dev/null)
else
    echo "  Note: app-interface integration not configured (optional)"
fi

# Option 2: Document as optional external dependency
# Option 3: Provide alternative version check method
```

### collect_from_multiple_clusters.sh

**Check for:**
- Default cluster lists
- Hard-coded OCM endpoints
- User-specific paths

### generate_html_report.sh

**Check for:**
- Hard-coded operator names (make configurable)
- Specific CVE data (make generic or remove)

## Example Configurations to Add

### examples/clusters.list.example
```
# Example cluster list file
# One cluster ID per line
# cluster-id-1
# cluster-id-2
# cluster-id-3
```

### examples/staging_clusters.conf.example
```bash
# Example staging clusters configuration
# Source this file or set environment variables

STAGING_CLUSTERS=(
    "staging-cluster-1"
    "staging-cluster-2"
    "staging-cluster-3"
)
```

## Documentation Updates Needed

### README.md
- [ ] Add prerequisites section with OCM CLI, backplane setup
- [ ] Add example cluster list format
- [ ] Document optional app-interface integration
- [ ] Add configuration examples
- [ ] Add troubleshooting section
- [ ] Remove references to specific environments

### New Documentation to Add
- [ ] `CONFIGURATION.md` - How to configure for different operators
- [ ] `CONTRIBUTING.md` - Contribution guidelines
- [ ] `LICENSE` - Choose appropriate license
- [ ] `examples/` directory with sample configurations

## Generic Placeholders to Use

Replace specific references with:
- Cluster names: `cluster-1`, `cluster-2`, etc.
- Operator names: Use `OPERATOR_NAME` variable
- Namespace: Use `NAMESPACE` variable (already done)
- Deployment: Use `DEPLOYMENT` variable (already done)
- SAAS file: Use `SAAS_FILE` variable (already done)

## Testing Before Release

- [ ] Test with generic cluster list
- [ ] Test without app-interface integration
- [ ] Verify no hard-coded paths remain
- [ ] Verify no sensitive data in any file
- [ ] Test all documentation examples work
- [ ] Add CI/CD if desired (shellcheck, etc.)

## Recommended .gitignore Additions

Already configured, but verify:
```
# Output files
*.json
*.html
*.log
*.csv
*.txt

# Cluster lists
*.list
clusters*.txt

# User-specific configs
*_local.sh
.env
```
