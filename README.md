# Operator Health Report

Comprehensive health monitoring for SRE-managed OpenShift operators across multiple clusters. Runs 60+ health checks per cluster, generates interactive HTML reports, and detects deployment issues, resource leaks, version mismatches, and configuration problems.

## Quick Start

```bash
# Build
go build -o healthcheck ./cmd/healthcheck/

# Run against staging clusters
./healthcheck \
  --cluster-list stage_clusters.list \
  --reason "SREP-1234" \
  --oper camo --oper rmo --oper ome \
  --parallel 4

# Run with specific OCM config
./healthcheck \
  --ocm-config ~/.config/ocm/ocm.stg.json \
  --cluster-list clusters.list \
  --reason "SREP-1234"
```

## Supported Operators

| Operator | Key | Namespace |
|----------|-----|-----------|
| configure-alertmanager-operator | `camo` | `openshift-monitoring` |
| route-monitor-operator | `rmo` | `openshift-route-monitor-operator` |
| osd-metrics-exporter | `ome` | `openshift-osd-metrics` |

## Architecture

```
healthcheck binary
├── OCM SDK connection (token lifecycle, multi-env support)
│   ├── Cluster metadata (name, version, hive shard)
│   └── SAAS target resolution (GitLab + Quay APIs)
├── Backplane k8s clients (native connection per cluster)
│   ├── Standard client (pods, deployments, logs, events)
│   ├── Elevated client (k8s impersonation for custom resources, Thanos)
│   └── Dynamic client (ClusterPackages, RouteMonitors, etc.)
├── 13 common checks (all operators)
├── Operator-specific checks (CAMO: 11, RMO: 16, OME: 5)
└── JSON output → HTML report generator
```

## CLI Options

```
--cluster-list FILE    File with cluster IDs (one per line)
--reason TEXT          Elevation reason (JIRA ticket — required for production)
--oper KEY             Operator to check: camo, rmo, ome (repeatable, default: all)
--parallel N           Clusters to process concurrently (default: 1)
--no-elevate           Skip elevated checks (secrets, Thanos queries, custom resources)
--ocm-config FILE      OCM config file path (default: $OCM_CONFIG)
--ocm-url URL          Override OCM API URL
--output FILE          JSON output file (default: health_TIMESTAMP.json)
--no-html              Skip HTML report generation
--log-level LEVEL      debug, info, warn, error (default: info)
--log-dir DIR          Write debug-level logs to file
```

## What It Checks

### Common Checks (all operators)

- Namespace status, deployment health, pod restarts
- PKO ClusterPackage conditions (Available, Progressing, Unpacked)
- Competing deployment methods (OLM + PKO conflict detection)
- Orphaned OLM artifacts (CSVs remaining after PKO migration)
- Version verification against app-interface SAAS targets
- Resource usage trends over 7 days (CPU/memory via Thanos)
- Resource limits validation with peak usage comparison
- Leader election, image pull status, PKO cleanup jobs
- Log error analysis, Kubernetes warning events

### CAMO Checks

- AlertManager pod status, StatefulSet health, restarts with termination reasons
- Controller availability condition
- Reconciliation activity and behavior analysis
- 10 CAMO-specific Prometheus metrics (config validation, secret existence, integrations)
- AlertManager log analysis with DNS warning filtering
- AlertManager and CAMO deployment events
- AlertManager secret and PagerDuty integration verification

### RMO Checks

- Controller-manager pod health with BLACKBOX_IMAGE env detection
- Blackbox exporter deployment, service, and configmap validation
- RouteMonitor/ClusterUrlMonitor CR validation against MCC expectations
- SRE probe-missing PrometheusRule verification
- Probe health (probe_success metrics from Thanos)
- ServiceMonitor and PrometheusRule child resource validation
- Operator metrics (API request counts, probe deletion timeouts)
- ConfigMap configuration (probe-api-url, RHOBS settings)
- HCP probe coverage and state breakdown (MC only, via RHOBS Prometheus)
- RHOBS API health (per-operation success/error, OIDC token refresh)
- Limited support disagreement (HCP label vs Prometheus metric)

### OME Checks

- 10 expected Prometheus metrics with trigger-based validation
- Pull secret validity (pull_secret_valid metric)
- Proxy CA certificate health and expiry
- ServiceMonitor existence
- Identity provider configuration (informational)

## HTML Report

The report is a single-file HTML with embedded JavaScript/CSS:
- Per-operator tabs with sortable tables
- Expandable cluster detail panels with check results
- CPU/memory trend charts (Chart.js, rendered on demand)
- SAAS target summary per operator with PKO/OLM badges
- Inline API error display under each check

```bash
# Generate from existing JSON
bash lib/generate_html_report.sh results.json report.html
open report.html
```

## Production Safety

- Production OCM environment is auto-detected
- `--no-elevate` is applied automatically in production
- `--reason` with a valid JIRA ticket is required for production elevation
- Elevated checks gracefully SKIP when elevation is unavailable

## Adding a New Operator

See [CLAUDE.md](CLAUDE.md) for detailed instructions. Summary:

1. Create `pkg/checks/<key>/<key>.go` implementing `OperatorChecker` interface
2. Add `OperatorConfig` to `pkg/checks/types.go`
3. Import package in `cmd/healthcheck/main.go` for init() registration
4. Update HTML report check ordering in `lib/generate_html_report.sh`

## Legacy Bash Version

The original bash implementation is preserved on the `bash-legacy` branch for reference. It includes:
- `lib/collect_operator_health.sh` — single-cluster check script
- `lib/collect_from_multiple_clusters.sh` — multi-cluster orchestrator
- `run.sh` — container-based execution with `--parallel N`
