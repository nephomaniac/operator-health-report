# CAMO Resource Limits Recommendation
## For Versions Newer Than v0.1.791-g4babac1

Based on collected data from 42 clusters running v0.1.798-g038acc6

## Observed Usage Data

### Peak Usage (Worst Case Across All Clusters)
```
CPU:    5.93 millicores (0.005925 cores)
Memory: 107.29 MB
```

### Average Peak Usage
```
CPU:    1.64 millicores (0.001641 cores)
Memory: 47.06 MB
```

### Usage Range
```
CPU:    0.39 - 5.93 millicores
Memory: 30 - 107 MB
```

## Recommended Resource Configuration

### With 50% Safety Pad

#### Option 1: Conservative (Recommended)
```yaml
resources:
  requests:
    cpu: 5m          # ~3x average peak, below observed peak
    memory: 64Mi     # ~1.4x average peak
  limits:
    cpu: 10m         # 1.5x observed peak + rounded
    memory: 160Mi    # 1.5x observed peak + rounded
```

**Rationale:**
- CPU limit: 10m = 5.93m * 1.5 (50% pad), rounded to 10m
- Memory limit: 160Mi = 107.29 MB * 1.5 (50% pad), rounded to 160Mi
- Requests set lower to allow better cluster packing
- Sufficient headroom for peak usage + safety margin

#### Option 2: Generous (Extra Safety)
```yaml
resources:
  requests:
    cpu: 10m         # Matches limit, guaranteed resources
    memory: 96Mi     # 2x average peak
  limits:
    cpu: 20m         # 2x recommended limit (100% pad)
    memory: 256Mi    # 2.4x observed peak (140% pad)
```

**Rationale:**
- Extra safety margin for unexpected spikes
- Requests = limits prevents throttling
- Suitable for critical production clusters

#### Option 3: Efficient (Tighter)
```yaml
resources:
  requests:
    cpu: 2m          # Slightly above average peak
    memory: 48Mi     # ~1x average peak
  limits:
    cpu: 8m          # 1.35x observed peak
    memory: 128Mi    # 1.2x observed peak
```

**Rationale:**
- Optimized for cluster efficiency
- Still provides 20-35% safety margin
- Suitable if resource pressure is a concern

## Comparison Table

| Configuration  | CPU Request | CPU Limit | Memory Request | Memory Limit | Safety Margin       |
|---------------|-------------|-----------|----------------|--------------|---------------------|
| Conservative   | 5m          | 10m       | 64Mi           | 160Mi        | 50% pad (recommended) |
| Generous       | 10m         | 20m       | 96Mi           | 256Mi        | 100%+ pad           |
| Efficient      | 2m          | 8m        | 48Mi           | 128Mi        | 20-35% pad          |
| **Observed Peak** | **-**   | **5.93m** | **-**          | **107.29MB** | **Actual usage**    |
| **Observed Avg**  | **-**   | **1.64m** | **-**          | **47.06MB**  | **Actual usage**    |

## Kubernetes YAML Example (Conservative - Recommended)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: configure-alertmanager-operator
  namespace: openshift-monitoring
spec:
  template:
    spec:
      containers:
      - name: configure-alertmanager-operator
        image: quay.io/app-sre/configure-alertmanager-operator:v0.1.798-g038acc6
        resources:
          requests:
            cpu: 5m
            memory: 64Mi
          limits:
            cpu: 10m
            memory: 160Mi
```

## Current State

Based on collected data, **most clusters have NO resource limits set**:
- requests_cpu: not set
- requests_memory: not set
- limits_cpu: not set
- limits_memory: not set

**Risk:** Without limits, CAMO could potentially consume unlimited resources during memory leaks or bugs.

## Recommendations by Version

### For v0.1.798-g038acc6 (Current Latest in Cluster Data)
- **Use Conservative limits** (10m CPU, 160Mi memory)
- Based on observed peak of 107 MB across 42 clusters
- Provides 50% safety margin

### For v0.1.800-gc66d6e6 (Current Stage - Just Deployed)
- **Start with Conservative limits** (10m CPU, 160Mi memory)
- Monitor after deployment to production
- Adjust if usage patterns differ from v0.1.798

### For Future Versions (> v0.1.800)
- Re-evaluate limits after 1-2 weeks of production usage
- Run collection script to gather new peak usage data
- Adjust limits if usage increases by >25%

## Action Items

### Immediate
1. **Apply Conservative limits to all clusters** running v0.1.798 or newer
   - CPU: 10m limit, 5m request
   - Memory: 160Mi limit, 64Mi request

2. **Monitor clusters with existing limits**
   - Check if any are hitting limits (CPU throttling or OOM kills)
   - Adjust if needed

### Short-Term (1-2 weeks)
1. **Monitor v0.1.800 in stage**
   - Collect metrics after clusters upgrade
   - Compare to v0.1.798 baseline
   - Adjust limits if significantly different

2. **Review clusters still on v0.1.781**
   - These 11 clusters have high memory usage (up to 900 MB)
   - DO NOT use these limits for v0.1.781
   - Upgrade clusters to v0.1.798+ before applying new limits

### Ongoing
1. **Monthly review**
   - Run collection script monthly
   - Check if peak usage is increasing
   - Adjust limits if peak approaches 80% of limit

2. **Alert on limit hits**
   - Monitor for CPU throttling
   - Monitor for OOM kills
   - Increase limits if repeatedly hitting them

## Validation Commands

### Check current limits
```bash
oc get deployment -n openshift-monitoring configure-alertmanager-operator \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'
```

### Apply new limits
```bash
oc set resources deployment/configure-alertmanager-operator \
  -n openshift-monitoring \
  --requests=cpu=5m,memory=64Mi \
  --limits=cpu=10m,memory=160Mi
```

### Monitor resource usage after applying limits
```bash
# Check if hitting CPU limits (throttling)
oc adm top pod -n openshift-monitoring -l name=configure-alertmanager-operator

# Check for OOM kills
oc get events -n openshift-monitoring | grep OOM
```

## Notes

1. **Why 50% pad?**
   - Provides safety margin for unexpected spikes
   - Accounts for measurement variance
   - Industry standard for production workloads

2. **Why separate requests and limits?**
   - Lower requests allow better cluster bin-packing
   - Limits prevent runaway resource consumption
   - CPU throttling acceptable for CAMO (not latency-sensitive)

3. **What about v0.1.781 (problematic version)?**
   - DO NOT use these limits for v0.1.781-geab01dd
   - That version has memory leak (900 MB peak)
   - Upgrade to v0.1.798+ before applying limits

4. **QoS Class**
   - Conservative config → Burstable QoS (requests < limits)
   - Generous config → Guaranteed QoS (requests = limits)
   - Burstable recommended for CAMO workload

## Summary

**RECOMMENDED (Conservative with 50% Safety Pad):**
```
CPU:    10m limit, 5m request
Memory: 160Mi limit, 64Mi request
```

**Based on:**
- 42 clusters running v0.1.798-g038acc6
- Peak usage: 5.93m CPU, 107.29 MB memory
- 50% safety margin applied
- Kubernetes-friendly rounding
