# Operator Health Report — Claude Directives

## Overview

Go binary that runs comprehensive health checks against SRE-managed OpenShift operators across multiple clusters. Connects to clusters via native backplane-cli and OCM SDK (no shell-outs to `oc` or `ocm`), queries Prometheus/Thanos via pod exec, and produces JSON + HTML reports.

**Entry point:** `./healthcheck` — single binary, no containers required
**HTML report:** `lib/generate_html_report.sh` — reads JSON output, produces interactive single-file HTML

## Supported Operators

| Operator | Key | Namespace | Deployment |
|----------|-----|-----------|------------|
| configure-alertmanager-operator | `camo` | `openshift-monitoring` | `configure-alertmanager-operator` |
| route-monitor-operator | `rmo` | `openshift-route-monitor-operator` | `route-monitor-operator-controller-manager` |
| osd-metrics-exporter | `ome` | `openshift-osd-metrics` | `osd-metrics-exporter` |

## Usage

```bash
# Single cluster, all operators
./healthcheck --cluster-list clusters.list --reason "SREP-1234" --oper camo --oper rmo --oper ome

# 10 clusters, 4 concurrent, staging
./healthcheck --cluster-list stage.list --reason "SREP-1234" --parallel 4

# Specific OCM config file
./healthcheck --ocm-config ~/.config/ocm/ocm.stg.json --cluster-list clusters.list

# No elevation (safe subset of checks only)
./healthcheck --cluster-list clusters.list --no-elevate

# Debug logging to file
./healthcheck --cluster-list clusters.list --log-level debug --log-dir /tmp/debug
```

## Architecture

```
cmd/healthcheck/main.go     CLI entry point, cluster loop, parallel processing
pkg/ocm/ocm.go              OCM SDK client — multi-env, token lifecycle management
pkg/kube/client.go           Backplane k8s client — native connection, elevation
pkg/checks/
  types.go                   Result, ClusterContext, OperatorConfig types
  operator.go                OperatorChecker interface + registry
  common.go                  13 common checks (all operators get these)
  camo/camo.go               CAMO-specific checks
  rmo/rmo.go                 RMO-specific checks
  ome/ome.go                 OME-specific checks
pkg/saas/resolver.go         SAAS target resolution (GitLab + Quay APIs)
pkg/thanos/thanos.go         Prometheus/Thanos response parsing
pkg/logging/logger.go        Structured logging (logrus)
lib/generate_html_report.sh  HTML report generator (reads JSON output)
```

## Adding a New Operator

1. Create `pkg/checks/<short_name>/<short_name>.go`
2. Implement the `OperatorChecker` interface:

```go
package newop

import (
    "context"
    "github.com/openshift/operator-health-report/pkg/checks"
)

func init() {
    checks.Register(&NewOpChecker{})
}

type NewOpChecker struct{}

func (c *NewOpChecker) Name() string { return "newop" }

func (c *NewOpChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
    // Common checks (namespace, deployment, PKO, version, resources, etc.)
    // already ran before this is called — add operator-specific checks here
    checkCustomThing(ctx, cc)
}
```

3. Add operator config to `pkg/checks/types.go`:

```go
NewOpConfig = OperatorConfig{
    Name:       "new-operator",
    ShortName:  "newop",
    Namespace:  "openshift-new-operator",
    Deployment: "new-operator-controller-manager",
    PKOSaas:    "saas-new-operator-pko.yaml",
    OLMSaas:    "saas-new-operator.yaml",
}
```

Add to `AllOperators` map.

4. Import in `cmd/healthcheck/main.go`:

```go
_ "github.com/openshift/operator-health-report/pkg/checks/newop"
```

5. Add check names to `lib/generate_html_report.sh` `checkOrder` and `formatCheckName()`.

## Adding New Checks

### Common checks (all operators)

Add to `pkg/checks/common.go`. Every operator gets these automatically:
- Use `cc.Client.Clientset()` for standard k8s API calls
- Use `cc.Client.GetResource(ctx, gvr, ns, name, elevated)` for custom resources
- Use `cc.Client.QueryThanos(ctx, query)` for Prometheus queries (requires elevation)
- Use `cc.RecordError(operation, err)` to record API errors
- Set `cc.CurrentCheck = "check_name"` before each check

### Operator-specific checks

Add to the operator's checker file. The `ClusterContext` provides:
- `cc.Client` — `*kube.ClusterClient` with Clientset(), ElevatedClientset(), CanElevate()
- `cc.ClusterID`, `cc.ClusterName`, `cc.ClusterType`, `cc.HiveShard`
- `cc.Operator` — OperatorConfig with Name, Namespace, Deployment, etc.
- `cc.AddResult(r)` — append a check result
- `cc.RecordError(op, err)` — record an API error under the current check

### Check result format

```go
r := checks.Result{
    Check:    "check_name",           // unique identifier
    Status:   checks.StatusPass,      // PASS, FAIL, WARNING, SKIP, INFO, UNKNOWN
    Severity: checks.SeverityWarning, // critical, warning, info
    Message:  "Human-readable summary",
    Details:  map[string]any{         // displayed in expandable detail grid
        "key": "value",
    },
}
cc.AddResult(r)
```

## Common Checks (13 — all operators inherit)

| Check | Description |
|-------|-------------|
| `namespace_status` | Namespace exists and is Active |
| `pod_status_and_restarts` | Deployment health, pod count, restarts |
| `pko_clusterpackage_health` | PKO conditions (Available/Progressing/Unpacked) |
| `dual_installation_check` | Detects OLM + PKO conflict |
| `orphaned_olm_artifacts` | Orphaned CSVs on PKO clusters |
| `version_verification` | Deployed version matches SAAS target |
| `resource_leak_detection` | CPU/memory trend over 7d via Thanos |
| `resource_limits_validation` | Limits/requests with peak usage comparison |
| `leader_election` | Lease health |
| `image_pull_status` | ImagePullBackOff detection |
| `pko_job_health` | Cleanup job status |
| `log_error_analysis` | Error/warning counts in logs |
| `operator_events` | K8s warning events |

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `github.com/openshift/backplane-cli` | Backplane connection + elevation via k8s impersonation |
| `github.com/openshift-online/ocm-sdk-go` | OCM API (cluster metadata, provision shards) |
| `k8s.io/client-go` | Native k8s API calls (typed + dynamic) |
| `github.com/sirupsen/logrus` | Structured logging |
| `gopkg.in/yaml.v3` | SAAS file YAML parsing |

## Connection Architecture

```
OCM SDK Connection (per environment)
  ├── Cluster metadata (name, version, hive shard)
  ├── SAAS target resolution (GitLab API)
  └── Backplane k8s clients (per cluster)
       ├── Standard client — pods, deployments, namespaces, logs, events
       ├── Elevated client — k8s impersonation as backplane-cluster-admin
       │    ├── Custom resources (RouteMonitors, ServiceMonitors, PrometheusRules)
       │    ├── Secrets (alertmanager-main, pd-secret)
       │    └── Pod exec (Thanos/RHOBS Prometheus queries)
       └── Dynamic client — ClusterPackages, Subscriptions, CSVs, HCPs
```

Multi-environment: create separate `ocm.Client` per env, pass `ocmClient.Conn()` to `kube.ConnectToClusterWithConn()`.

## Production Safety — CRITICAL

- Production environment is auto-detected from OCM URL
- `--no-elevate` is applied automatically in production
- `--reason` with a JIRA ticket is required for production elevation
- Claude should NEVER suggest removing production safety checks

## Elevation Handling

- Uses native k8s impersonation (`backplane-cluster-admin`) — not CLI `ocm backplane elevate`
- If elevation fails (Forbidden), `elevationBroken` flag is set and all subsequent elevated checks SKIP
- Standard k8s API calls (pods, deployments, namespaces) work without elevation
- Elevated calls needed for: custom resources, secrets, pod exec (Thanos queries)

## Testing

```bash
# Build
go build -o healthcheck ./cmd/healthcheck/

# Run against one staging cluster
./healthcheck --cluster-list test.list --reason "test" --oper rmo --no-html

# Verify JSON
jq '.[].health_summary' results.json

# Generate HTML
bash lib/generate_html_report.sh results.json report.html && open report.html

# Run all checks
go vet ./... && go build ./...
```

## Known Patterns

- **Two Prometheus stacks on MCs**: Platform Thanos (`openshift-monitoring`) sees MC-local probes. RHOBS Prometheus (`openshift-observability-operator`) sees HCP probes. Use `cc.Client.QueryRHOBSPrometheus()` for HCP data.
- **MC probe count**: On MCs, only ClusterUrlMonitor probes appear in platform Thanos. HCP RouteMonitor probes are in RHOBS. The `rmo_probe_health` check accounts for this.
- **OLM-to-PKO migration**: Check for orphaned CSVs and competing Subscription + ClusterPackage.
- **Viper thread safety**: `backplane-cli` uses viper which isn't goroutine-safe. Connection creation is serialized with a mutex.
- **OCM token lifecycle**: Refresh token expiry is checked before connecting. If token will expire during the estimated runtime, it's refreshed proactively.
