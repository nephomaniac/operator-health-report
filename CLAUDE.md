# Operator Health Report — Claude Directives

## Overview

Single Go binary for comprehensive health monitoring of SRE-managed OpenShift operators across multiple clusters. No bash dependencies — all connections (OCM SDK, backplane k8s client, Thanos queries, SAAS resolution, HTML generation) are native Go.

**Entry point:** `./healthcheck` (build with `make build`)
**Config:** `.healthcheck.yaml` for persistent defaults

## Supported Operators

| Operator | Key | Namespace | Deployment | Cluster Types |
|----------|-----|-----------|------------|---------------|
| configure-alertmanager-operator | `camo` | `openshift-monitoring` | `configure-alertmanager-operator` | All managed |
| route-monitor-operator | `rmo` | `openshift-route-monitor-operator` | `route-monitor-operator-controller-manager` | All managed |
| osd-metrics-exporter | `ome` | `openshift-osd-metrics` | `osd-metrics-exporter` | All managed |
| splunk-forwarder-operator | `sfo` | `openshift-splunk-forwarder-operator` | `splunk-forwarder-operator` | All managed |
| rhobs-observability | `rhobs` | `openshift-observability-operator` | — | MC/SC only |
| rosa-log-router | `rlr` | `hypershift-control-plane-log-forwarding` | — | MC only |
| pagerduty-operator | `pdo` | `pagerduty-operator` | `pagerduty-operator` | Hive only |

## Architecture

```
cmd/healthcheck/main.go        CLI, cluster loop, parallel processing, config
pkg/ocm/ocm.go                 OCM SDK — multi-env, token lifecycle, labels
pkg/kube/client.go              Backplane k8s client — elevation, retry, unified metrics
pkg/config/config.go            Config file loading (.healthcheck.yaml)
pkg/rhobs/client.go             RHOBS remote API — vault auth, SSO token, metrics queries
pkg/checks/
  types.go                      Result, ClusterContext, OperatorConfig, status types
  operator.go                   OperatorChecker interface + registry
  common.go                     13 common checks + PodSummary/ProblematicPods helpers
  camo/camo.go                  CAMO-specific checks (11 checks)
  rmo/rmo.go                    RMO-specific checks (16 checks)
  ome/ome.go                    OME-specific checks (5 checks)
  sfo/sfo.go                    SFO-specific checks
  rhobs/rhobs.go                RHOBS-specific checks (16 checks, SkipCommonChecks)
  rlr/rlr.go                    RLR-specific checks (18 checks, SkipCommonChecks)
  pdo/pdo.go                    PDO-specific checks (8 checks, SkipCommonChecks)
pkg/saas/
  resolver.go                   SAAS target resolution (GitLab + Quay + GitHub)
  pipeline.go                   Promotion pipeline DAG (deploy + e2e targets)
pkg/thanos/thanos.go           Prometheus/Thanos response parsing (NaN/Inf safe)
pkg/report/
  report.go                     HTML generation (embedded templates)
  template_prefix.html          HTML/CSS
  template_suffix.html          JavaScript (charts, tables, pipeline rendering)
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
OCM Client (per environment, token lifecycle, cluster labels)
  └── Backplane ClusterClient (per cluster)
       ├── Standard k8s client (pods, deployments, namespaces)
       ├── Elevated k8s client (impersonation as backplane-cluster-admin)
       │    ├── Custom resources (RouteMonitors, ServiceMonitors, etc.)
       │    ├── Secrets (elevated read)
       │    └── Pod exec (Thanos queries — int/staging only)
       ├── Dynamic client (ClusterPackages, Subscriptions, CSVs)
       ├── RHOBS remote client (production metrics via Observatorium API)
       │    └── Vault-based OAuth2 → SSO token → RHOBS cell API
       └── Unified QueryMetrics (tries Thanos exec → RHOBS remote fallback)
```

Multi-env: `ocm.NewClientWithOptions(ocm.Options{URL: "https://api.openshift.com"})`
Per-cluster: `kube.ConnectToClusterWithConn(ctx, clusterID, reason, noElevate, ocmClient.Conn())`

## Key Patterns

- **Retry**: All k8s API calls retry on 429/5xx via HTTP transport wrapper + `withRetry` helper
- **Elevation detection**: First Forbidden error sets `elevationBroken`, subsequent checks SKIP/ACCESS_DENIED
- **Viper thread safety**: Backplane config loading serialized with `bpConfigMu` mutex
- **Token lifecycle**: Refresh token expiry checked against estimated runtime, refreshed proactively
- **SAAS pipeline**: Walks deploy + e2e SAAS files, connects via pub/sub channels, resolves Tekton cluster console URL via prod OCM

## Security & Safety Directives — CRITICAL

### No Sensitive Data in Repo
- NEVER commit hardcoded cluster IDs, API tokens, secrets, email addresses, vault paths, AWS ARNs, or personal usernames
- NEVER commit real cluster names or organization names — use generic examples
- Config values that vary by environment (vault paths, OCM URLs) must be loaded from config files at runtime, never hardcoded
- File paths must use dynamic resolution (`os.UserHomeDir()`, `os.UserConfigDir()`) — never hardcode `/Users/`, `/home/`, or `~/`
- If file paths are required, provide them via config with sane generic defaults

### Read-Only Operations Only
- ALL cluster operations MUST be read-only: GET, LIST, WATCH only
- NEVER add k8s Create, Update, Patch, Delete operations
- NEVER modify cluster state, resources, or configurations
- Pod exec is acceptable only for read-only queries (wget/curl to localhost Prometheus endpoints)
- The only files this tool writes are local result files (JSON/HTML reports, debug logs)

### Production & Hive Safety
- Production auto-detected from OCM URL → `--no-elevate` enforced automatically
- `--reason` with JIRA ticket required for production
- Limited support and non-ready clusters automatically skipped
- Hive clusters are production infrastructure — same restrictions apply
- NEVER suggest removing production safety checks
- All elevation-dependent checks MUST be gated by `cc.Client.CanElevate()` or `cc.Client.HasRHOBSRemote()`
- When elevation is unavailable, checks MUST degrade gracefully (SKIP/INFO with explanation)

### Metrics Access Strategy
- **Managed clusters (int/staging)**: Use Thanos exec (elevation required) or RHOBS remote API
- **Managed clusters (production)**: RHOBS remote API only (no elevation available)
- **Hive clusters (production)**: Port-forward to Prometheus service (no exec, no RHOBS) — TODO
- **MC/SC clusters (int/staging)**: Thanos exec (elevation available)
- **MC/SC clusters (production)**: No exec/logs/debug — use RHOBS remote API
- Unified `QueryMetrics`/`QueryMetricsRange` methods handle fallback automatically

### Elevation Auditing & Testing
- Every elevated API call (ElevatedClientset, elevated GetResource/ListResources/ExecInPod) increments `ClusterClient.ElevatedCallCount`
- On disconnect, elevated call count is logged; a warning is printed if elevation was used with `--no-elevate`
- **To simulate production restrictions in staging**: use `--no-elevate` flag — this disables all elevation, forcing port-forward and RHOBS remote fallbacks
- **Unit tests** in `pkg/kube/elevation_test.go` verify:
  - `NoElevate=true` blocks all elevated operations and counter stays at 0
  - `elevationBroken=true` blocks subsequent elevated operations
  - `CanQueryMetrics()` always returns true (port-forward is always attempted)
- When adding new checks that use elevation, ensure they are gated by `CanElevate()` (for secrets/CRD access) or `CanQueryMetrics()` (for metrics queries)
- Run `go test ./pkg/kube/ -v` to verify elevation safety before committing

### Environment Variable Safety
- NEVER use `os.Setenv()` to modify the process environment — pass env vars via `cmd.Env` on subprocesses
- Vault CLI commands must use `cmd.Env` with `VAULT_ADDR` set per-command

### Sensitive Repos
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
