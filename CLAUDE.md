# Operator Health Report — Claude Directives

## Overview

Single Go binary for comprehensive health monitoring of SRE-managed OpenShift operators across multiple clusters. No bash dependencies — all connections (OCM SDK, backplane k8s client, Thanos queries, SAAS resolution, HTML generation) are native Go.

**Entry point:** `./healthcheck` (build with `make build`)
**Config:** `.healthcheck.yaml` for persistent defaults

## Supported Operators

| Operator | Key | Namespace | Deployment |
|----------|-----|-----------|------------|
| configure-alertmanager-operator | `camo` | `openshift-monitoring` | `configure-alertmanager-operator` |
| route-monitor-operator | `rmo` | `openshift-route-monitor-operator` | `route-monitor-operator-controller-manager` |
| osd-metrics-exporter | `ome` | `openshift-osd-metrics` | `osd-metrics-exporter` |

## Architecture

```
cmd/healthcheck/main.go        CLI, cluster loop, parallel processing, config
pkg/ocm/ocm.go                 OCM SDK — multi-env, token lifecycle, Options{}
pkg/kube/client.go              Backplane k8s client — impersonation elevation, retry
pkg/config/config.go            Config file loading (.healthcheck.yaml)
pkg/checks/
  types.go                      Result, ClusterContext, OperatorConfig, status types
  operator.go                   OperatorChecker interface + registry
  common.go                     13 common checks (all operators inherit)
  camo/camo.go                  CAMO-specific checks (13 checks)
  rmo/rmo.go                    RMO-specific checks (16 checks)
  ome/ome.go                    OME-specific checks (5 checks)
pkg/saas/
  resolver.go                   SAAS target resolution (GitLab + Quay HTTP)
  pipeline.go                   Promotion pipeline DAG (deploy + e2e targets)
pkg/thanos/thanos.go           Prometheus/Thanos response parsing
pkg/report/
  report.go                     HTML generation (embedded templates)
  template_prefix.html          HTML/CSS (525 lines)
  template_suffix.html          JavaScript (1900+ lines)
pkg/logging/logger.go           Structured logging (logrus)
Makefile                        Build with version from git
```

## Adding a New Operator

1. Create `pkg/checks/<shortname>/<shortname>.go`:

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
    // Common checks already ran. Add operator-specific checks here.
    checkCustomThing(ctx, cc)
}
```

2. Add to `pkg/checks/types.go`:
```go
NewOpConfig = OperatorConfig{
    Name: "new-operator", ShortName: "newop",
    Namespace: "openshift-new-operator",
    Deployment: "new-operator-controller-manager",
    PKOSaas: "saas-new-operator-pko.yaml",
    OLMSaas: "saas-new-operator.yaml",
}
// Add to AllOperators map
```

3. Import in `cmd/healthcheck/main.go`:
```go
_ "github.com/openshift/operator-health-report/pkg/checks/newop"
```

4. Add check name formatting in `pkg/report/template_suffix.html` (JavaScript `formatCheckName` function).

## Adding New Checks

### Common checks (all operators)

Add to `pkg/checks/common.go` and wire in `RunAllCommonChecks()`.

### Operator-specific checks

Add to the operator's checker file. Use `ClusterContext` for:
- `cc.Client.Clientset()` — standard k8s API (pods, deployments, logs)
- `cc.Client.ElevatedClientset()` — elevated (secrets, custom resources)
- `cc.Client.CanElevate()` — check if elevation is available
- `cc.Client.QueryThanos(ctx, query)` — Prometheus queries
- `cc.Client.GetResource(ctx, gvr, ns, name, elevated)` — dynamic client
- `cc.RecordError(operation, err)` — record API errors
- `cc.AddResult(Result{...})` — add check result

### Check result format

```go
r := checks.Result{
    Check:    "check_name",
    Status:   checks.StatusPass,      // PASS, FAIL, WARNING, SKIP, INFO, UNKNOWN, ACCESS_DENIED
    Severity: checks.SeverityWarning, // critical, warning, info
    Message:  "Human-readable summary",
    Details:  map[string]any{"key": "value"},
}
cc.AddResult(r)
```

### Access error handling

Use `checks.IsAccessError(err)` to detect RBAC/Forbidden errors:
```go
if err != nil {
    if IsAccessError(err) {
        r.Status = StatusAccessDenied
        r.Message = "Cannot access resource — insufficient permissions"
    } else {
        r.Status = StatusFail
        r.Message = fmt.Sprintf("Resource not found: %v", err)
    }
}
```

## Common Checks (13)

namespace_status, pod_status_and_restarts, pko_clusterpackage_health,
dual_installation_check, orphaned_olm_artifacts, version_verification,
resource_leak_detection, resource_limits_validation, leader_election,
image_pull_status, pko_job_health, log_error_analysis, operator_events

## Connection Architecture

```
OCM Client (per environment, token lifecycle)
  └── Backplane ClusterClient (per cluster)
       ├── Standard k8s client (pods, deployments, namespaces)
       ├── Elevated k8s client (impersonation as backplane-cluster-admin)
       │    ├── Custom resources (RouteMonitors, ServiceMonitors, etc.)
       │    ├── Secrets (elevated read)
       │    └── Pod exec (Thanos/RHOBS queries)
       └── Dynamic client (ClusterPackages, Subscriptions, CSVs)
```

Multi-env: `ocm.NewClientWithOptions(ocm.Options{URL: "https://api.openshift.com"})`
Per-cluster: `kube.ConnectToClusterWithConn(ctx, clusterID, reason, noElevate, ocmClient.Conn())`

## Key Patterns

- **Retry**: All k8s API calls retry on 429/5xx via HTTP transport wrapper + `withRetry` helper
- **Elevation detection**: First Forbidden error sets `elevationBroken`, subsequent checks SKIP/ACCESS_DENIED
- **Viper thread safety**: Backplane config loading serialized with `bpConfigMu` mutex
- **Token lifecycle**: Refresh token expiry checked against estimated runtime, refreshed proactively
- **SAAS pipeline**: Walks deploy + e2e SAAS files, connects via pub/sub channels, resolves Tekton cluster console URL via prod OCM

## Production Safety — CRITICAL

- Production auto-detected from OCM URL → `--no-elevate` enforced
- `--reason` with JIRA ticket required for production
- Limited support and non-ready clusters automatically skipped
- Claude should NEVER suggest removing production safety checks

## Sensitive Repos — CRITICAL

- `splunk-audit-exporter` (gitlab.cee.redhat.com) is **internal**. NEVER include its config details, internal URLs, or implementation patterns in this public repo.
- When adding checks for operators with internal components, use only public GitHub sources and generic k8s resource queries.

## Testing

```bash
make build
./healthcheck --saas-only --oper camo                    # Quick SAAS test
./healthcheck --cluster-list test.list --oper rmo         # Single operator
./healthcheck --list-clusters managed | tee clusters.list # Generate list
go vet ./... && go build ./...                            # Lint + build
```
