# Operator Health Report

Single Go binary that runs 60+ health checks per operator across OpenShift managed clusters. Connects natively via backplane-cli and OCM SDK, queries Prometheus/Thanos, and generates interactive HTML reports with promotion pipeline diagrams.

## Quick Start

```bash
# Build
make build

# Run against staging clusters (all 3 operators, 8 parallel)
./healthcheck \
  --list-clusters managed --exclude "osde2e|^ci-|^qe-" \
  | tee stage_clusters.list

./healthcheck \
  --cluster-list stage_clusters.list \
  --oper camo --oper rmo --oper ome \
  --parallel 8

# View SAAS promotion pipeline only (no cluster checks)
./healthcheck --saas-only --oper camo --oper rmo --oper ome

# Use config file for persistent defaults
cat > .healthcheck.yaml << 'EOF'
operators: [camo, rmo, ome]
exclude: "osde2e|^ci-|^qe-|^tf-|playwright|scorecard"
parallel: 8
reason: "SREP-operator-health-check"
EOF
./healthcheck --list-clusters managed | tee clusters.list
./healthcheck --cluster-list clusters.list
```

## Supported Operators

| Operator | Key | Namespace |
|----------|-----|-----------|
| configure-alertmanager-operator | `camo` | `openshift-monitoring` |
| route-monitor-operator | `rmo` | `openshift-route-monitor-operator` |
| osd-metrics-exporter | `ome` | `openshift-osd-metrics` |

## Architecture

```
healthcheck binary (single self-contained executable)
├── OCM SDK connection (multi-env, token lifecycle)
│   ├── Cluster metadata (name, state, provider, region, owner)
│   ├── SAAS target resolution (GitLab + Quay APIs)
│   └── Promotion pipeline walker (deploy + e2e targets)
├── Backplane k8s client (native impersonation elevation)
│   ├── Standard client (pods, deployments, logs, events)
│   ├── Elevated client (custom resources, secrets, Thanos exec)
│   └── HTTP retry transport (429/5xx backoff)
├── Health checks
│   ├── 13 common checks (all operators inherit)
│   └── Operator-specific checks (plug-and-play via OperatorChecker)
├── Config file support (.healthcheck.yaml)
└── Embedded HTML report (no bash dependency)
```

## CLI Options

```
--cluster-list FILE    Cluster IDs file (one per line)
--list-clusters PRESET List clusters: all, rosa, osd, hypershift, managed
--oper KEY             Operator: camo, rmo, ome (repeatable, default: all)
--parallel N           Concurrent clusters (default: 1)
--reason TEXT          Elevation reason (required for production)
--no-elevate           Skip elevated checks
--saas-only            SAAS targets + pipeline only (no cluster checks)
--exclude REGEX        Exclude clusters by name regex
--include REGEX        Include only matching clusters
--ocm-config FILE      OCM config file path
--ocm-url URL          OCM API URL override
--output FILE          JSON output (default: health_report_TIMESTAMP.json)
--no-html              Skip HTML generation
--config FILE          Config file (default: .healthcheck.yaml)
--log-level LEVEL      debug, info, warn, error
--log-dir DIR          Debug log file directory
```

## Config File

Create `.healthcheck.yaml` for persistent defaults (CLI flags override):

```yaml
operators: [camo, rmo, ome]
exclude: "osde2e|^ci-|^qe-|^tf-|playwright|scorecard"
parallel: 8
reason: "SREP-operator-health-check"
log_level: info
```

Search order: `./.healthcheck.yaml` → `~/.config/healthcheck/config.yaml` → `~/.healthcheck.yaml`

## What It Checks

### Common Checks (all operators)

| Check | Description |
|-------|-------------|
| namespace_status | Namespace exists and is Active |
| pod_status_and_restarts | Deployment health, restarts, pod issues |
| pko_clusterpackage_health | PKO conditions with condition messages |
| dual_installation_check | OLM + PKO conflict detection |
| orphaned_olm_artifacts | CSVs remaining after PKO migration |
| version_verification | Version matches app-interface SAAS target |
| resource_leak_detection | CPU/memory trends over 7d via Thanos |
| resource_limits_validation | Limits/requests with peak usage comparison |
| leader_election | Lease health |
| image_pull_status | ImagePullBackOff detection |
| pko_job_health | Cleanup jobs with failure logs |
| log_error_analysis | Error/warning counts |
| operator_events | K8s warning events |

### Status Icons

| Icon | Status | Meaning |
|------|--------|---------|
| ✓ | PASS | Healthy |
| ⚠ | WARNING | Degraded but functional |
| ❗ | FAIL | Real operator/cluster health issue |
| 🔧 | ERROR | Check errored (API/script problem) |
| 🚫 | ACCESS_DENIED | RBAC forbidden / access request needed |
| - | SKIP | Not applicable or disabled |

## HTML Report Features

- Per-operator tabs with sortable cluster tables
- Expandable cluster detail panels with all check results
- CPU/memory trend charts (Chart.js)
- SAAS promotion pipeline flow diagram
  - Clickable nodes with target details
  - Quay.io and GitHub commit links
  - Tekton pipeline runs link (resolved via prod OCM)
  - Auto/manual promotion badges
  - Pub/sub channel chain
- SAAS target table with promotion info
- Collapsible hive shard groups
- Collapsible skipped/unreachable clusters section
- Cluster metadata (provider, region, owner, limited support)

## Production Safety

- Production OCM auto-detected → `--no-elevate` applied automatically
- `--reason` with JIRA ticket required for production elevation
- Clusters in limited support or non-ready state are automatically skipped
- OCM token is checked against estimated runtime and refreshed proactively

## Adding a New Operator

See [CLAUDE.md](CLAUDE.md) for detailed instructions. Summary:

1. Create `pkg/checks/<key>/<key>.go` implementing `OperatorChecker` interface
2. Add `OperatorConfig` to `pkg/checks/types.go` and `AllOperators` map
3. Import in `cmd/healthcheck/main.go` for init() registration
4. Add HTML check name formatting in `pkg/report/template_suffix.html`

## Development

```bash
make build              # Build with git version
go vet ./...            # Lint
go build ./...          # Build all packages
./healthcheck --saas-only --oper camo   # Quick SAAS test (no clusters)
```
