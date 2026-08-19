# Operator Health Report Skill

Guide users through running operator health checks, interpreting results, debugging failures, triaging findings, and extending the tool.

## Running Health Checks

### Build
```bash
cd ~/sandbox/operator-health-report
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

# Hive clusters (production PDO, etc.)
./healthcheck --cluster-list hive.list --oper pdo --hive-ocm-url production
```

### Config file
Users can create `.healthcheck.yaml` for persistent defaults:
```yaml
operators: [camo, rmo, ome]
exclude: "osde2e|^ci-|^qe-|^tf-|playwright|scorecard"
parallel: 8
reason: "SREP-operator-health-check"
```

### Supported operators
| Key | Operator | Cluster Types |
|-----|----------|---------------|
| camo | configure-alertmanager-operator | All managed |
| rmo | route-monitor-operator | All managed |
| ome | osd-metrics-exporter | All managed |
| sfo | splunk-forwarder-operator | All managed |
| rhobs | rhobs-observability | MC/SC only |
| rlr | rosa-log-router | MC + HCP |
| pdo | pagerduty-operator | Hive only |
| muo | managed-upgrade-operator | All managed |
| mnmo | managed-node-metadata-operator | All managed |
| cluster | cluster/node health | All managed |
| hcp | HCP serving nodes | MC only |
| byoc | Bring Your Own Check | All (opt-in) |

## BYOC (Bring Your Own Check)

Run arbitrary commands against each cluster with structured pass/fail evaluation.

### Single ad-hoc command
```bash
# Exit code determines pass/fail (0 = PASS, nonzero = FAIL)
./healthcheck --cluster-list clusters.list --byoc "oc get co --no-headers | grep -v 'True.*False.*False'"

# Combine with specific operators
./healthcheck --cluster-list clusters.list --oper camo --byoc "oc get secret -n openshift-monitoring alertmanager-main -o jsonpath='{.data}' | base64 -d | grep pagerduty"
```

### Check definitions file (--byof)
```bash
./healthcheck --cluster-list clusters.list --byof checks.json
```

**checks.json format:**
```json
[
  {
    "name": "etcd_pods_running",
    "command": "oc get pods -n openshift-etcd -l app=etcd --no-headers | wc -l",
    "expected_exit_code": 0,
    "output_regex": "^[3-9]",
    "severity": "critical",
    "description": "Verify at least 3 etcd pods are running",
    "timeout_seconds": 15
  },
  {
    "name": "no_crashlooping_pods",
    "command": "oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers | head -20",
    "expected_exit_code": 0,
    "output_not_regex": "CrashLoopBackOff",
    "severity": "warning",
    "description": "Check for CrashLoopBackOff pods across the cluster"
  },
  {
    "name": "api_server_health",
    "command": "oc get --raw /healthz",
    "expected_exit_code": 0,
    "output_regex": "^ok$",
    "description": "Verify API server healthz endpoint returns ok",
    "timeout_seconds": 10
  }
]
```

**Check definition fields:**
| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| name | No | byoc_check_N | Check identifier (alphanumeric + underscore) |
| command | Yes | — | Shell command (bash -c) — oc/kubectl have cluster context |
| expected_exit_code | No | 0 | Expected return code |
| output_regex | No | — | Regex that stdout MUST match for PASS |
| output_not_regex | No | — | Regex that stdout must NOT match (FAIL if matched) |
| severity | No | warning | critical, warning, or info |
| description | No | — | Human-readable purpose of the check |
| timeout_seconds | No | 30 | Per-command timeout |

### Compact results extraction (--byoc-brief)

Post-process an existing results JSON file to extract jq-friendly BYOC output:

```bash
# Run checks and save results
./healthcheck --cluster-list clusters.list --byoc "oc get co" -o results.json

# Extract compact BYOC results
./healthcheck --byoc-brief results.json | jq .

# Filter to failed clusters
./healthcheck --byoc-brief results.json | jq 'to_entries[] | select(.value.checks[].status == "FAIL")'

# Get command output per cluster
./healthcheck --byoc-brief results.json | jq 'to_entries[] | {cluster: .value.name, output: .value.checks[].output}'

# List clusters where a regex didn't match
./healthcheck --byoc-brief results.json | jq 'to_entries[] | select(.value.checks[].status == "FAIL") | {id: .key, name: .value.name, msg: .value.checks[].message}'
```

**Brief output format:**
```json
{
  "cluster-id-abc": {
    "name": "my-cluster",
    "version": "4.17.3",
    "type": "rosa",
    "region": "us-east-1",
    "status": "PASS",
    "checks": {
      "etcd_pods_running": {
        "status": "PASS",
        "message": "OK (exit 0): 3",
        "exit_code": 0,
        "output": "3",
        "duration_ms": 245,
        "command": "oc get pods -n openshift-etcd -l app=etcd --no-headers | wc -l"
      }
    }
  }
}
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
| ℹ | INFO | Informational | Expected state, no action needed |

### Reading JSON results
```bash
# Overall status per operator
jq '.[] | select(.cluster_id != null) | {cluster: .cluster_name, op: .operator_name, status: .health_summary.overall_status}' results.json

# All failing checks
jq '.[] | select(.cluster_id != null) | .health_checks[] | select(.status == "FAIL") | {check, message}' results.json

# All warnings
jq '.[] | select(.cluster_id != null) | .health_checks[] | select(.status == "WARNING") | {cluster: (input_filename // ""), check, message}' results.json

# API errors
jq '.[] | select(.cluster_id != null) | select(.api_errors | length > 0) | {cluster: .cluster_name, errors: .api_errors}' results.json

# Cluster metadata
jq '.[] | select(.cluster_id != null) | .cluster_metadata | {name, state, product, region, owner_org}' results.json

# SAAS targets
jq '.[] | select(.type == "saas_targets") | {op: .operator_name, targets: [.targets[].target]}' results.json

# Group failures by check name (find systemic issues)
jq '[.[] | select(.cluster_id != null) | .health_checks[] | select(.status == "FAIL")] | group_by(.check) | map({check: .[0].check, count: length}) | sort_by(-.count)' results.json

# Find clusters with critical failures
jq '.[] | select(.cluster_id != null) | select(.health_summary.critical_count > 0) | {cluster: .cluster_name, op: .operator_name, criticals: .health_summary.critical_count}' results.json
```

## Triage Workflow

When using the health report to triage fleet issues, follow this workflow:

### 1. Run a broad scan
```bash
./healthcheck --list-clusters managed --exclude "osde2e|^ci-|^qe-|^tf-|playwright" > clusters.list
./healthcheck --cluster-list clusters.list --parallel 8 -o results.json
```

### 2. Identify systemic issues (same failure across many clusters)
```bash
# Count failures by check name
jq '[.[] | .health_checks[]? | select(.status == "FAIL")] | group_by(.check) | map({check: .[0].check, count: length, sample_msg: .[0].message}) | sort_by(-.count)' results.json

# If a check fails on >50% of clusters, it's likely a systemic issue (SAAS deploy, platform change)
# If a check fails on 1-2 clusters, it's likely cluster-specific
```

### 3. Classify failures
- **Expected/known**: Check the message for known patterns (staging alert noise, pending upgrades, new clusters in readiness window)
- **SAAS version mismatch**: Compare staging vs production SHA — may indicate a pending promotion or rollback
- **Operator-level**: Pod crashes, config errors, reconciliation failures — investigate the specific operator
- **Platform-level**: ClusterOperator degradation, node issues, API server problems — escalate or check for known incidents

### 4. Investigate specific clusters
```bash
# Login to a failing cluster
ocm backplane login <cluster_id>

# Check operator pods
oc get pods -n <operator_namespace>
oc logs -n <operator_namespace> deployment/<deployment> --tail=100

# Check events
oc get events -n <operator_namespace> --sort-by=.lastTimestamp | tail -20

# Always logout when done
ocm backplane logout
```

### 5. BYOC for targeted fleet investigation
When triage reveals a pattern, use BYOC to verify across the fleet:
```bash
# Example: check if a specific secret exists on all clusters
./healthcheck --cluster-list clusters.list --byoc "oc get secret -n openshift-monitoring alertmanager-main -o name 2>&1"

# Example: verify a specific pod version fleet-wide
./healthcheck --cluster-list clusters.list --byoc "oc get deployment -n openshift-route-monitor-operator route-monitor-operator-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}'"

# Extract and filter results
./healthcheck --byoc-brief results.json | jq 'to_entries[] | select(.value.checks[].status == "FAIL") | .value.name'
```

## Debugging Failures

### Common failure patterns

**namespace_status FAIL**: Operator not installed on this cluster type (e.g., OME not on MCs).

**pod_status_and_restarts WARNING/FAIL**: Check `details.pod_issues` for termination reasons (OOMKilled, CrashLoopBackOff). FAIL means 0/1 ready.

**pko_clusterpackage_health FAIL**: Check `details.available_message` and `details.progressing_message` for PKO adoption/immutability errors.

**version_verification WARNING**: Deployed version doesn't match SAAS target. Check if SAAS was updated during the run.

**resource_leak_detection WARNING**: CPU or memory increased >50% over 7 days. Check the timeseries data in details.

**camo_cluster_readiness FAIL**: PagerDuty not configured on a cluster >4h old. Alerts are NOT paging. Investigate CAMO readiness logic.

**alertmanager_config_compatibility FAIL**: Config uses functions unsupported by the cluster's AM version. Cross-version fleet risk.

**muo_upgradeconfig_sync FAIL**: MUO hasn't synced with OCM in >4h. Cluster may miss scheduled upgrades.

**rlr_lambda_recursive_drops FAIL**: Active data loss — Lambda recursive loop detection is dropping messages (ROSAENG-14340).

**rlr_sqs_dlq_messages WARNING/FAIL**: Permanently failed log deliveries in the dead-letter queue.

### Connecting to a cluster
```bash
ocm backplane login <cluster_id>
oc get pods -n <operator_namespace>
oc logs -n <operator_namespace> deployment/<deployment_name> --tail=100
# Always logout when done
ocm backplane logout
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
- **NEVER** modify cluster state — all operations are read-only (GET, LIST, WATCH)
- When adding checks for operators with internal components, use only publicly available information
- Always `ocm backplane logout` after investigating a cluster
