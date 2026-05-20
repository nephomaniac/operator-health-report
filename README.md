# Operator Health Report

Comprehensive health monitoring for SRE-managed OpenShift operators (CAMO, RMO, OME) across multiple clusters. Runs health checks, generates interactive HTML reports with charts, and detects deployment issues, resource leaks, and configuration mismatches.

## Architecture

```
                                    run.sh
                                  (entry point)
                                      |
                    +-----------------+-----------------+
                    |                                   |
              --local flag                     container mode (default)
                    |                                   |
                    v                           +-------+-------+
          lib/collect_from_                     |   Containerfile  |
          multiple_clusters.sh                  |  (ocm-container  |
                    |                           |   + yq/skopeo)  |
                    |                           +-------+-------+
                    |                                   |
                    |                     --parallel N splits clusters
                    |                     across N containers, each running:
                    |                                   |
                    +-----------------------------------+
                    |
          Per cluster, runs operators in parallel:
          +----+----+----+
          |    |    |    |
        CAMO  RMO  OME  ...
          |    |    |    |
          +----+----+----+
                    |
          lib/collect_operator_health.sh
          (per operator, per cluster)
                    |
          +--------+--------+--------+--------+
          |        |        |        |        |
       Namespace  Version  Pod/     Operator  Prometheus
       Status     Check    Deploy   Specific  Metrics
                  (SAAS)   Health   Checks    (Thanos)
                    |
                    v
              JSON output (per cluster per operator)
                    |
                    v
          lib/generate_html_report.sh
                    |
                    v
          Interactive HTML Report
          (dark theme, charts, per-operator tabs,
           SAAS target summary, inline errors)
```

## Quick Start

```bash
# Container mode (default) — isolated, reproducible
./run.sh -- --cluster-list clusters.list --reason "SREP-1234" --oper camo --oper rmo --oper ome

# Parallel containers — 4 workers splitting the cluster list
./run.sh --parallel 4 -- --cluster-list clusters.list --reason "SREP-1234" --oper camo --oper rmo --oper ome

# Local mode — uses host tools directly
./run.sh --local -- --cluster-list clusters.list --reason "SREP-1234" --oper rmo

# Single operator, single cluster
./run.sh --local -- --cluster-list <(echo "CLUSTER_ID") --reason "debugging" --oper ome
```

## Supported Operators

| Operator | Short Name | Namespace | Operator-Specific Checks |
|----------|-----------|-----------|-------------------------|
| configure-alertmanager-operator | `camo` | openshift-monitoring | AlertManager health, secrets, PD integration, reconciliation |
| route-monitor-operator | `rmo` | openshift-route-monitor-operator | RouteMonitor CRs, probe health, HCP coverage, RHOBS API, limited support detection |
| osd-metrics-exporter | `ome` | openshift-osd-metrics | Per-metric trigger validation, pull secret, proxy CA, ServiceMonitor |

## General Checks (all operators)

| Check | What It Detects |
|-------|----------------|
| Namespace Status | Namespace missing or Terminating |
| Version Verification | Deployed version vs SAAS target (with mid-run refresh) |
| Pod Status & Restarts | Crashloops, OOM kills, pods not running |
| Leader Election | Stale lease, holder mismatch |
| Resource Leak Detection | CPU/memory trends over 7 days with absolute thresholds |
| Resource Limits | Missing limits/requests on deployment |
| Log Analysis | Error/warning counts in operator logs |
| OLM/PKO Health | Dual installation, stuck ClusterPackage, adoption refusal |
| PKO Job Health | Hung/failed OLM cleanup jobs |
| Image Pull Status | ImagePullBackOff detection |
| Orphaned Resources | Leftover OLM artifacts on PKO clusters |

## HTML Report Features

- Dark "mission control" theme with IBM Plex fonts
- Per-operator tabs with colored status badges (ok/warn/crit)
- SAAS target summary table showing all targets, deployment method (PKO/OLM), expected versions
- Per-shard grouping with expected version display
- CPU/memory timeseries charts with version change annotations
- Per-endpoint probe success rate and latency charts
- OME per-metric table with trigger resource validation
- Inline API/script errors under each check
- Click-to-navigate from table status icons to check details
- Summary overview with cluster counts by status

## Project Structure

```
run.sh                    # Main entry point (container or --local)
Containerfile             # Builds from ocm-container, adds yq/skopeo/wget
CLAUDE.md                 # Operator context and enhancement notes
lib/
  collect_operator_health.sh          # Single-cluster health check (all checks)
  collect_from_multiple_clusters.sh   # Multi-cluster orchestrator
  generate_html_report.sh            # JSON → interactive HTML report
  get_app_interface_saas_refs.sh      # SAAS target resolution (basic)
  get_app_interface_saas_refs_with_images.sh  # SAAS targets with image tags
```

## Configuration

### run.sh Options (before `--`)

| Flag | Description |
|------|-------------|
| `--local` | Run without container (uses host oc/ocm/jq) |
| `--build` | Force rebuild container image |
| `--parallel N` | Run N containers concurrently |
| `--engine ENGINE` | Container engine: podman or docker (auto-detected) |
| `--ocm-config FILE` | Path to OCM config |
| `--bp-config FILE` | Path to backplane config (proxy settings) |

### Health Check Options (after `--`)

| Flag | Description |
|------|-------------|
| `--cluster-list FILE` | File with cluster IDs (one per line) |
| `--reason TEXT` | OCM elevation reason (JIRA ticket) |
| `--oper OPERATOR` | Operator to check: camo, rmo, ome (repeatable) |
| `--secrets` | Enable extended secret-based checks |
| `--no-html` | Skip HTML report generation |
| `--max-clusters N` | Limit to first N clusters |
| `--cache-dir DIR` | Save oc outputs for offline replay |
| `--replay` | Read from cache instead of running commands |

## Requirements

### Container Mode (default)
- podman or docker
- OCM config (`~/.config/ocm/ocm.json` or set `OCM_CONFIG`)
- Backplane config (`~/.config/backplane/config.json` for VPN proxy)

### Local Mode (`--local`)
- bash 4.0+
- oc, ocm (with backplane plugin), jq, yq, skopeo, wget, curl, bc

## Cache & Replay

For iterating on checks without re-logging into clusters:

```bash
# Collect with cache
./run.sh --local -- --cluster-list test.list --reason "debug" --oper rmo --cache-dir /tmp/cache

# Replay from cache (instant, no cluster access needed)
./run.sh --local -- --cluster-list test.list --reason "debug" --oper rmo --cache-dir /tmp/cache --replay
```

## Error Handling

All `oc`, `ocm`, `curl`, `skopeo` commands go through `_run_oc()` which:
- Captures stderr and exit codes
- Logs errors with command, check context, and error type (API vs script)
- Associates errors with the health check that triggered them
- Reports errors inline under each check in the HTML report

Expected "not found" responses (e.g., OLM subscription on PKO clusters) use `_run_oc_optional()` which suppresses expected absence from error reporting.
