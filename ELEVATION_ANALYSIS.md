# Elevation Analysis for CAMO Health Checks

## Current Usage of `ocm backplane elevate`

Total occurrences: **11**

### 1. Get Deployment (3 uses)

**Lines:** 261, 355, 650

**What it does:**
```bash
ocm backplane elevate "${REASON}" -- get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json
```

**Purpose:**
- Get operator image and version
- Get deployment status (replicas, availability)
- Get build annotations

**Alternative (NO ELEVATION NEEDED):**
```bash
oc get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o json
```
**Note:** Regular `oc get` doesn't require elevation - only reads cluster state.

---

### 2. Get ClusterServiceVersion (CSV)

**Line:** 277

**What it does:**
```bash
ocm backplane elevate "${REASON}" -- get csv -n "$NAMESPACE" -o json
```

**Purpose:**
- Get operator version from CSV

**Alternative (NO ELEVATION NEEDED):**
```bash
oc get csv.operators.coreos.com -n "$NAMESPACE" -o json
```

---

### 3. Get Pods

**Line:** 672

**What it does:**
```bash
ocm backplane elevate "${REASON}" -- get pods -n "$NAMESPACE" -l "name=$DEPLOYMENT" -o json
```

**Purpose:**
- Get pod status, restart counts

**Alternative (NO ELEVATION NEEDED):**
```bash
oc get pods -n "$NAMESPACE" -l "name=$DEPLOYMENT" -o json
```

---

### 4. Exec into Thanos for Prometheus Queries (3 uses)

**Lines:** 827, 834, 1468

**What it does:**
```bash
ocm backplane elevate "${REASON}" -- exec -n openshift-monitoring deployment/thanos-querier -c thanos-query -- \
    wget -q -O- "http://localhost:9090/api/v1/query?query=..."
```

**Purpose:**
- Query Prometheus for memory/CPU metrics
- Query CAMO-specific metrics

**Alternative (NO ELEVATION NEEDED - use port-forward):**
```bash
# Start port-forward (in background or separate terminal)
oc port-forward -n openshift-monitoring svc/thanos-querier 9090:9091 &

# Query via local port
curl -s --data-urlencode "query=..." 'http://localhost:9090/api/v1/query'

# Or port-forward to prometheus-k8s directly
oc port-forward -n openshift-monitoring prometheus-k8s-0 9090:9090 &
```

---

### 5. Get Pod Logs

**Line:** 979

**What it does:**
```bash
ocm backplane elevate "${REASON}" -- logs -n "$NAMESPACE" "$pod_name" --tail=500
```

**Purpose:**
- Analyze logs for errors/warnings

**Alternative (NO ELEVATION NEEDED):**
```bash
oc logs -n "$NAMESPACE" "$pod_name" --tail=500
```
**Note:** Reading logs doesn't require elevation.

---

### 6. Get Secrets (3 uses) - **REQUIRES ELEVATION**

**Lines:** 2083, 2140, and others in `--secrets` flag section

**What it does:**
```bash
ocm backplane elevate "${REASON}" -- get secret alertmanager-main -n "$NAMESPACE" -o json
ocm backplane elevate "${REASON}" -- get secret pd-secret -n "$NAMESPACE"
```

**Purpose:**
- Verify secrets exist
- Check secret contents

**Alternative:** 
**❌ NO ALTERNATIVE - Secrets REQUIRE elevation**

However, we can use **Prometheus metrics** instead:
```promql
am_secret_exists{namespace="openshift-monitoring"}
pd_secret_exists{namespace="openshift-monitoring"}
dms_secret_exists{namespace="openshift-monitoring"}
```

These metrics are exposed by CAMO and tell us if secrets exist without needing to read them.

---

## Summary: What Requires Elevation vs. What Doesn't

### ❌ **DOES NOT REQUIRE ELEVATION** (10 out of 11 uses)

1. ✅ `get deployment` - Regular read operation
2. ✅ `get csv` - Regular read operation
3. ✅ `get pods` - Regular read operation
4. ✅ `logs` - Reading logs
5. ✅ `exec ... thanos-querier` - Can use port-forward instead

### ✅ **REQUIRES ELEVATION** (1 use case)

1. ❌ `get secret` - Reading secrets requires special permissions

**BUT:** We can avoid secrets entirely by using CAMO's Prometheus metrics which report secret existence.

---

## Proposed Implementation Plan

### Add `--no-elevate` flag (or keep `--secrets` flag as is)

```bash
# Default behavior: NO secret checks, NO elevation required
./collect_operator_health.sh --reason "Health check"

# With secrets: Requires elevation
./collect_operator_health.sh --reason "SREP-123" --secrets
```

### Changes Needed

#### 1. Replace `ocm backplane elevate -- <cmd>` with `oc <cmd>`

**For all non-secret commands:**
- Line 261: `oc get deployment` instead of elevated
- Line 277: `oc get csv.operators.coreos.com` instead of elevated
- Line 355: `oc get deployment` instead of elevated
- Line 650: `oc get deployment` instead of elevated
- Line 672: `oc get pods` instead of elevated
- Line 979: `oc logs` instead of elevated

#### 2. Replace Thanos exec with port-forward queries

**Add port-forward wrapper function:**
```bash
query_prometheus() {
    local query="$1"
    local endpoint="${2:-query}"  # query or query_range
    
    # Check if port-forward is already running
    if ! curl -s http://localhost:9090/api/v1/status/config >/dev/null 2>&1; then
        echo "Error: Prometheus port-forward not available" >&2
        echo "Please run: oc port-forward -n openshift-monitoring prometheus-k8s-0 9090:9090" >&2
        return 1
    fi
    
    curl -s --data-urlencode "query=${query}" "http://localhost:9090/api/v1/${endpoint}"
}
```

**Use in script:**
```bash
# Instead of exec to thanos
memory_data=$(query_prometheus "$memory_query" "query_range&start=${start_time}&end=${end_time}&step=300")
```

#### 3. Keep `--secrets` flag for optional secret checks

When `--secrets` is NOT specified:
- Skip direct secret reads (lines 2083, 2140, etc.)
- Use Prometheus metrics instead:
  - `am_secret_exists`
  - `pd_secret_exists`
  - `dms_secret_exists`

When `--secrets` IS specified:
- Require `--reason` for elevation justification
- Use `ocm backplane elevate` for secret operations

#### 4. Add prerequisite check

```bash
# At start of script
if [ "$SECRETS_ENABLED" != "true" ]; then
    # Check if port-forward is available
    if ! curl -s http://localhost:9090/api/v1/status/config >/dev/null 2>&1; then
        echo "WARNING: Prometheus port-forward not detected."
        echo "Some health checks will be skipped."
        echo "To enable full checks, run in another terminal:"
        echo "  oc port-forward -n openshift-monitoring prometheus-k8s-0 9090:9090"
    fi
fi
```

---

## Benefits of No-Elevation Mode

1. ✅ **Faster** - No elevation approval needed
2. ✅ **Self-service** - Engineers can run without SRE approval
3. ✅ **Auditable** - No elevated operations in audit logs
4. ✅ **Safer** - No risk of accidental destructive operations
5. ✅ **Works everywhere** - Even when backplane elevation is unavailable

---

## Testing Plan

1. **Test without elevation:**
   ```bash
   # Start port-forward
   oc port-forward -n openshift-monitoring prometheus-k8s-0 9090:9090 &
   
   # Run health check (no --secrets flag)
   ./collect_operator_health.sh --reason "Test"
   ```

2. **Test with elevation (secrets enabled):**
   ```bash
   ./collect_operator_health.sh --reason "SREP-123" --secrets
   ```

3. **Compare results** - Ensure no-elevation mode provides equivalent information via metrics

---

## Next Steps

1. Create `query_prometheus()` helper function
2. Replace all 10 non-secret elevation uses with regular `oc` commands
3. Add port-forward prerequisite check
4. Test on a live cluster
5. Update documentation
