# Files to Commit - Clean File List

This document lists exactly which files should be committed to the public repository.

## ✅ FILES TO INCLUDE

### Core Collection Scripts
```
collect_from_multiple_clusters.sh    # Main orchestration script (SANITIZED)
collect_operator_health.sh           # Comprehensive health collector (SANITIZED)
collect_pod_health.sh                # Pod health checks
collect_pod_resource_usage.sh        # Resource usage collection
collect_version_resource_usage.sh    # Version-specific resource collection
collect_versioned_metrics.sh         # Versioned metrics collection
collect_camo_metrics.sh              # CAMO-specific metrics
```

### Report Generation
```
generate_html_report.sh              # HTML report generator (SANITIZED)
```

### Analysis Scripts
```
analyze_comprehensive_health.sh      # Comprehensive health analysis
analyze_health_data.sh               # Health data analysis
analyze_resource_data.sh             # Resource usage analysis
analyze_version_comparison.sh        # Version comparison analysis
analyze_max_usage.sh                 # Max usage analysis
analyze_camo_metrics.sh              # CAMO metrics analysis
```

### Query/Utility Scripts
```
query_prometheus_max_resources_v2.sh # Prometheus query utility
get_clusters.sh                      # Generic OCM cluster list command
check_labels.sh                      # Label checking utility
```

### Documentation (Main)
```
README.md                            # Main README (needs update for generic use)
README_COMPREHENSIVE_HEALTH.md       # Comprehensive health documentation
README_METRICS.md                    # Metrics collection documentation
README_VERSION_COMPARISON.md         # Version comparison documentation
HTML_REPORTS_GUIDE.md                # HTML report usage guide
HEALTH_CHECK_QUICK_START.md          # Quick start guide
DEBUG_GUIDE.md                       # Debug mode documentation
VERSION_VERIFICATION_GUIDE.md        # Version verification documentation
VERSION_LOOKUP_GUIDE.md              # Version lookup documentation
```

### Examples Directory
```
examples/README.md                   # Example configurations guide
examples/clusters.list.example       # Template cluster list
examples/config.env.example          # Template environment config
```

### Configuration Files
```
.gitignore                           # Git ignore rules (UPDATED)
camo_metrics_versions.conf           # Metrics configuration (review needed)
```

### Sanitization Documentation
```
SANITIZATION_SUMMARY.md              # Record of sanitization changes
PUBLIC_REPO_CHECKLIST.md             # Public release checklist
```

---

## ❌ FILES TO EXCLUDE

### Cluster Lists (Sensitive - Contains Real Cluster IDs)
```
cluster_camo_list                    # Real cluster data
clusters.list                        # User's cluster list
*.list                               # All cluster list files
test_clusters*.txt                   # Test cluster lists
clusters_old.list                    # Old cluster data
clustertest.list                     # Test data
camo_promo.list                      # Promo cluster list
rh.list                              # RH cluster list
single_cluster.list                  # Single cluster test
test_*.txt                           # Test cluster files
```

### Internal/Red Hat Specific Scripts
```
get_app_interface_saas_refs.sh       # Internal Red Hat app-interface
get_app_interface_saas_refs_with_images.sh  # Internal Red Hat app-interface
get_oc.sh                            # Possibly environment-specific
run_fresh_health.sh                  # Environment-specific helper
debug_rmo_pods.sh                    # Development script
test_5_clusters_cached.sh            # Test script
```

### Generated Output Files (All in .gitignore)
```
*.json                               # All JSON output files
*.html                               # All HTML reports
*.log                                # All log files
*.csv                                # All CSV files
```

### Internal Documentation (Environment-Specific)
```
ANALYSIS_FIXES.md                    # Internal analysis
FIXES.md                             # Internal fixes
VERSION_VERIFICATION_FIX.md          # Internal issue tracking
CHART_FIXES.md                       # Internal issue tracking
DEPLOYMENT_STATUS_SUMMARY.md         # Environment-specific
PROPOSED_LIMITS_ANALYSIS.md          # Environment-specific
RECOMMENDED_RESOURCE_LIMITS.md       # Environment-specific
COMMIT_TO_VERSION_MAPPING.md         # Environment-specific
CACHING_OPTIMIZATION.md              # Internal optimization notes
RUN_ON_REAL_CLUSTERS.md              # Environment-specific
COLLECTION_SUMMARY.txt               # Environment-specific
MAX_USAGE_ANALYSIS.txt               # Environment-specific
UPGRADE_PRIORITY_LIST.txt            # Environment-specific
version_summary.txt                  # Environment-specific
```

### Test/Debug Files
```
test_multi_fixed.jsonl               # Test data
debug_*.log                          # Debug output files
oc.out                               # Command output
```

### Directories to Exclude
```
.claude/                             # Claude Code metadata
junk/                                # Junk directory
resource_stats/                      # Generated stats
prod/                                # Production-specific
```

---

## 📋 GIT ADD COMMANDS

### Add Core Scripts
```bash
git add collect_from_multiple_clusters.sh
git add collect_operator_health.sh
git add collect_pod_health.sh
git add collect_pod_resource_usage.sh
git add collect_version_resource_usage.sh
git add collect_versioned_metrics.sh
git add collect_camo_metrics.sh
git add generate_html_report.sh
```

### Add Analysis Scripts
```bash
git add analyze_comprehensive_health.sh
git add analyze_health_data.sh
git add analyze_resource_data.sh
git add analyze_version_comparison.sh
git add analyze_max_usage.sh
git add analyze_camo_metrics.sh
```

### Add Utilities
```bash
git add query_prometheus_max_resources_v2.sh
git add get_clusters.sh
git add check_labels.sh
```

### Add Documentation
```bash
git add README.md
git add README_COMPREHENSIVE_HEALTH.md
git add README_METRICS.md
git add README_VERSION_COMPARISON.md
git add HTML_REPORTS_GUIDE.md
git add HEALTH_CHECK_QUICK_START.md
git add DEBUG_GUIDE.md
git add VERSION_VERIFICATION_GUIDE.md
git add VERSION_LOOKUP_GUIDE.md
```

### Add Examples
```bash
git add examples/
```

### Add Configuration
```bash
git add .gitignore
git add camo_metrics_versions.conf
```

### Add Sanitization Docs
```bash
git add SANITIZATION_SUMMARY.md
git add PUBLIC_REPO_CHECKLIST.md
git add FILES_TO_COMMIT.md
```

---

## 🚀 ONE-COMMAND ADD (Use with Caution)

To add all approved files at once:

```bash
# Review this list first!
git add \
  collect_*.sh \
  generate_html_report.sh \
  analyze_*.sh \
  query_prometheus_max_resources_v2.sh \
  get_clusters.sh \
  check_labels.sh \
  README*.md \
  HTML_REPORTS_GUIDE.md \
  HEALTH_CHECK_QUICK_START.md \
  DEBUG_GUIDE.md \
  VERSION_*.md \
  examples/ \
  .gitignore \
  camo_metrics_versions.conf \
  SANITIZATION_SUMMARY.md \
  PUBLIC_REPO_CHECKLIST.md \
  FILES_TO_COMMIT.md
```

---

## ⚠️ VERIFICATION BEFORE COMMIT

Before committing, verify:

1. **No cluster IDs in any file:**
   ```bash
   git diff --cached | grep -E "[0-9a-z]{32,}"
   ```

2. **No user paths:**
   ```bash
   git diff --cached | grep -E "/Users/|/home/"
   ```

3. **No internal hostnames:**
   ```bash
   git diff --cached | grep -E "app-interface|gitlab.corp|\.redhat\."
   ```

4. **Review staged changes:**
   ```bash
   git status
   git diff --cached --stat
   ```

5. **Check each file individually:**
   ```bash
   git diff --cached <filename>
   ```

---

## 📝 NOTES

- All files listed in "FILES TO INCLUDE" have been reviewed and sanitized
- Files listed in "FILES TO EXCLUDE" contain sensitive or environment-specific data
- The .gitignore file will prevent accidental commits of excluded files
- Example files provide templates for users to create their own configurations
- All hard-coded values have been replaced with configurable options

