# CAMO Deployment Status Summary

## Current Deployment Status (from app-interface)

### Stage Environments
```
Version: v0.1.800-gc66d6e6
Date:    2026-02-17 15:53 (pushed TODAY!)
Commit:  c66d6e658285
Targets: camo-hive-stage-01, camo-hives02ue1, camo-hives03ue1
```

### Production Environments  
```
Version: v0.1.791-g4babac1
Date:    2026-01-26 17:07 (22 days old)
Commit:  4babac14dcfb
Targets: All hivep* production hives
Soak:    1 day
```

## Version Timeline

```
2026-01-26  v0.1.791-g4babac1  <-- Current PRODUCTION
    |
    v
2026-02-??  v0.1.781-geab01dd  <-- PROBLEMATIC (900 MB memory!)
    |                              (11 clusters affected)
    v  
2026-02-??  v0.1.798-g038acc6  <-- Previous "latest" in cluster data
    |                              (42 clusters, 107 MB peak memory)
    v
2026-02-17  v0.1.800-gc66d6e6  <-- Current STAGE (pushed today)
```

## Key Findings

### Memory Issue Version (0.1.781-geab01dd)
- **Not in production pipeline** - Good!
- Likely a development/intermediate build
- 11 clusters still running this version
- Peak memory: 900 MB (outlier)
- **Action**: Prioritize upgrading these 11 clusters

### Current Production (0.1.791-g4babac1)
- Deployed: January 26, 2026
- Age: 22 days in production
- Status: Stable, no known issues
- **Note**: OLDER than the problematic 0.1.781 version

### Current Stage (0.1.800-gc66d6e6)
- Deployed: February 17, 2026 (TODAY - just pushed!)
- Latest version in pipeline
- Will promote to production after soak period
- Expected: Better memory profile based on 0.1.798 data

## Recommendations

### Immediate (This Week)
1. **Upgrade 11 clusters from 0.1.781-geab01dd**
   - See UPGRADE_PRIORITY_LIST.txt
   - Critical: hs-sc-a8p1rblbg (900 MB peak)
   - Target version: 0.1.798-g038acc6 or newer

2. **Monitor v0.1.800 in stage**
   - Just deployed today
   - Verify memory usage remains good
   - Compare to 0.1.798 baseline

### Short Term (Next 1-2 Weeks)
1. **Track production promotion**
   - v0.1.791 → v0.1.800 (or next stable version)
   - Verify 1-day soak period completes successfully

2. **Weekly collection runs**
   - Monitor cluster upgrades
   - Verify memory improvements on upgraded clusters
   - Track any new versions deployed

### Ongoing
1. **Version tracking**
   - Use enhanced script weekly to track deployments
   - Compare against cluster data collection
   - Flag any clusters lagging behind production version

## Version Comparison Script Usage

To see current deployment status with dates:
```bash
./get_app_interface_saas_refs_with_images.sh saas-configure-alertmanager-operator.yaml
```

To collect cluster metrics:
```bash
./collect_from_multiple_clusters.sh \
    --reason "Weekly CAMO checks" \
    --version-compare \
    --oper camo \
    --cluster-list clusters.list
```

To analyze results:
```bash
./analyze_max_usage.sh version_compare_<timestamp>.csv
```

## Files Reference

- `get_app_interface_saas_refs_with_images.sh` - Shows deployment pipeline with image dates
- `version_compare_20260217_154619.csv` - Latest cluster collection results  
- `MAX_USAGE_ANALYSIS.txt` - Peak resource usage analysis
- `UPGRADE_PRIORITY_LIST.txt` - 11 clusters to upgrade
- `COMMIT_TO_VERSION_MAPPING.md` - How to map commits to versions

