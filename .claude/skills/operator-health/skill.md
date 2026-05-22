# Operator Health Report Skill

Guide users through running operator health checks, interpreting results, debugging failures, and extending the tool.

## Running Health Checks

### Build
```bash
make build
```

### List available clusters
```bash
# All managed clusters (ROSA classic + OSD including MCs/SCs)
./healthcheck --list-clusters managed

# With exclusions
./healthcheck --list-clusters managed --exclude "osde2e|^ci-|^qe-|^tf-|playwright"

# Save to file
./healthcheck --list-clusters managed --exclude "osde2e" > clusters.list
```

### Run checks
```bash
# All operators, 8 parallel
./healthcheck --cluster-list clusters.list --oper camo --oper rmo --oper ome --parallel 8

# Single operator
./healthcheck --cluster-list clusters.list --oper rmo

# SAAS pipeline only (no cluster connections)
./healthcheck --saas-only --oper camo --oper rmo --oper ome

# With explicit OCM config
./healthcheck --ocm-config ~/.config/ocm/ocm.stg.json --cluster-list clusters.list
```

### Config file
Users can create `.healthcheck.yaml` for persistent defaults:
```yaml
operators: [camo, rmo, ome]
exclude: "osde2e|^ci-|^qe-|^tf-|playwright|scorecard"
parallel: 8
reason: "SREP-operator-health-check"
```

## Interpreting Results

### Status icons
| Icon | Status | Meaning | Action |
|------|--------|---------|--------|
| ✓ | PASS | Healthy | None |
| ⚠ | WARNING | Degraded | Investigate if persistent |
| ❗ | FAIL | Operator/cluster issue | Investigate — real problem |
| 🔧 | ERROR | Check errored (API problem) | Retry or check connectivity |
| 🚫 | ACCESS_DENIED | RBAC/access request needed | Run `ocm-backplane accessrequest create` |
| - | SKIP | Not applicable | Expected on some cluster types |

### Reading JSON results
```bash
# Overall status per operator
jq '.[] | select(.cluster_id != null) | {cluster: .cluster_name, op: .operator_name, status: .health_summary.overall_status}' results.json

# All failing checks
jq '.[] | select(.cluster_id != null) | .health_checks[] | select(.status == "FAIL") | {check, message}' results.json

# API errors
jq '.[] | select(.cluster_id != null) | select(.api_errors | length > 0) | {cluster: .cluster_name, errors: .api_errors}' results.json

# Cluster metadata
jq '.[] | select(.cluster_id != null) | .cluster_metadata | {name, state, product, region, owner_org}' results.json

# SAAS targets
jq '.[] | select(.type == "saas_targets") | {op: .operator_name, targets: [.targets[].target]}' results.json
```

## Debugging Failures

### Common failure patterns

**namespace_status FAIL**: Operator not installed on this cluster type (e.g., OME not on MCs).

**pod_status_and_restarts WARNING**: Check `details.pod_issues` for termination reasons (OOMKilled, CrashLoopBackOff).

**pko_clusterpackage_health FAIL**: Check `details.available_message` and `details.progressing_message` for PKO adoption/immutability errors.

**version_verification WARNING**: Deployed version doesn't match SAAS target. Check if SAAS was updated during the run.

**resource_leak_detection WARNING**: CPU or memory increased >50% over 7 days. Check the timeseries data in details.

**ome_metrics_health query_error**: Thanos query failed — check elevation status and cluster access.

### Connecting to a cluster
```bash
ocm backplane login <cluster_id>
oc get pods -n <operator_namespace>
oc logs -n <operator_namespace> deployment/<deployment_name> --tail=100
```

## Extending the Tool

### Adding a new operator

1. Create `pkg/checks/<key>/<key>.go` implementing `OperatorChecker`:
```go
package newop
import (
    "context"
    "github.com/openshift/operator-health-report/pkg/checks"
)
func init() { checks.Register(&Checker{}) }
type Checker struct{}
func (c *Checker) Name() string { return "newop" }
func (c *Checker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
    // Add operator-specific checks here
}
```

2. Add config to `pkg/checks/types.go` AllOperators map
3. Import in `cmd/healthcheck/main.go`: `_ "pkg/checks/newop"`
4. Add check name formatting in `pkg/report/template_suffix.html`

### Adding a new check
- Common (all operators): add to `pkg/checks/common.go`, wire in `RunAllCommonChecks()`
- Operator-specific: add to the operator's checker file
- Use `cc.Client.Clientset()` for k8s API, `cc.Client.QueryThanos()` for Prometheus
- Use `cc.RecordError()` for API errors, `checks.IsAccessError()` for RBAC detection

### HTML template changes
- CSS: `pkg/report/template_prefix.html`
- JavaScript: `pkg/report/template_suffix.html`
- After changes: `make build` embeds the updated templates

## Important Directives

- **NEVER** include details from internal GitLab repos (e.g., splunk-audit-exporter) in this public repository
- **NEVER** suggest removing production safety checks
- **NEVER** connect to production clusters without explicit user authorization
- When adding checks for operators with internal components, use only publicly available information
