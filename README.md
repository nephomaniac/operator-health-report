# Operator Health Report

Single Go binary that runs 60+ health checks per operator across OpenShift managed clusters. Connects natively via backplane-cli and OCM SDK, queries Prometheus/Thanos, and generates interactive HTML reports with promotion pipeline diagrams.

## Quick Start

```bash
# Build
make build

# Run against staging clusters
./healthcheck \
  --ocm-config ~/.config/ocm/ocm.json \
  --list-clusters managed --exclude "osde2e|^ci-|^qe-" \
  | tee stage_clusters.list

./healthcheck \
  --ocm-config ~/.config/ocm/ocm.json \
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

| Operator | Key | Namespace | Cluster Types |
|----------|-----|-----------|---------------|
| configure-alertmanager-operator | `camo` | `openshift-monitoring` | All managed |
| route-monitor-operator | `rmo` | `openshift-route-monitor-operator` | All managed |
| osd-metrics-exporter | `ome` | `openshift-osd-metrics` | All managed |
| splunk-forwarder-operator | `sfo` | `openshift-splunk-forwarder-operator` | All managed |
| managed-upgrade-operator | `muo` | `openshift-managed-upgrade-operator` | All managed |
| managed-node-metadata-operator | `mnmo` | `openshift-managed-node-metadata-operator` | All managed |
| rhobs-observability | `rhobs` | `openshift-observability-operator` | MC/SC only |
| rosa-log-router | `rlr` | `hypershift-control-plane-log-forwarding` | MC + HCP |
| pagerduty-operator | `pdo` | `pagerduty-operator` | Hive only |
| cluster/node health | `cluster` | — | All managed |
| HCP serving nodes | `hcp` | — | MC only |
| Bring Your Own Check | `byoc` | — | All (opt-in) |

## BYOC (Bring Your Own Check)

Run arbitrary commands against each cluster with structured pass/fail evaluation.

### Ad-hoc command

```bash
# Single command — exit code 0 = PASS, nonzero = FAIL
./healthcheck --cluster-list clusters.list \
  --byoc "oc get co --no-headers | awk '{if (\$3!=\"True\" || \$4!=\"False\" || \$5!=\"False\") print \$1, \$3, \$4, \$5}'"
```

### Check definitions file

```bash
./healthcheck --cluster-list clusters.list --byof checks.json
```

**checks.json:**

```json
[
  {
    "name": "cluster_operators_health",
    "command": "oc get co --no-headers 2>&1 | awk '{if ($3!=\"True\" || $4!=\"False\" || $5!=\"False\") print $1, $3, $4, $5}'",
    "expected_exit_code": 0,
    "output_not_regex": ".+",
    "severity": "critical",
    "description": "All ClusterOperators must be Available=True, Progressing=False, Degraded=False",
    "timeout_seconds": 15
  },
  {
    "name": "api_server_healthz",
    "command": "oc get --raw /healthz 2>&1",
    "expected_exit_code": 0,
    "output_regex": "^ok$",
    "severity": "critical",
    "description": "API server healthz endpoint must return ok",
    "timeout_seconds": 10
  },
  {
    "name": "node_readiness",
    "command": "oc get nodes --no-headers 2>&1 | awk '{print $1, $2}' | grep -v ' Ready' || echo 'all_ready'",
    "expected_exit_code": 0,
    "output_regex": "all_ready",
    "severity": "critical",
    "description": "All nodes must be in Ready state",
    "timeout_seconds": 10
  },
  {
    "name": "etcd_health",
    "command": "oc get pods -n openshift-etcd -l app=etcd --no-headers 2>&1 | awk '{print $1, $2, $3, $5}'",
    "expected_exit_code": 0,
    "output_regex": "Running",
    "severity": "critical",
    "description": "Etcd pods must be running",
    "timeout_seconds": 10
  },
  {
    "name": "active_upgrade_check",
    "command": "oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type==\"Progressing\")].status}' 2>&1",
    "expected_exit_code": 0,
    "output_not_regex": "^True$",
    "severity": "warning",
    "description": "Check if cluster is actively upgrading"
  }
]
```

**Check definition fields:**

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | No | `byoc_check_N` | Check identifier |
| `command` | Yes | — | Shell command (bash -c) with cluster context |
| `expected_exit_code` | No | `0` | Expected return code |
| `output_regex` | No | — | Regex stdout MUST match for PASS |
| `output_not_regex` | No | — | Regex stdout must NOT match |
| `severity` | No | `warning` | `critical`, `warning`, or `info` |
| `description` | No | — | Human-readable purpose |
| `timeout_seconds` | No | `30` | Per-command timeout |

### Compact results extraction

Post-process existing results JSON into jq-friendly output:

```bash
# Extract compact BYOC results
./healthcheck --byoc-brief results.json | jq .

# Filter to failed clusters
./healthcheck --byoc-brief results.json \
  | jq 'to_entries[] | select(.value.checks[].status == "FAIL") | {id: .key, name: .value.name}'

# Get command output per cluster
./healthcheck --byoc-brief results.json \
  | jq 'to_entries[] | {cluster: .value.name, output: .value.checks[].output}'

# Summary: pass/fail counts per cluster
./healthcheck --byoc-brief results.json \
  | jq 'to_entries[] | {
      cluster: .value.name,
      passed: [.value.checks | to_entries[] | select(.value.status == "PASS")] | length,
      failed: [.value.checks | to_entries[] | select(.value.status == "FAIL")] | length
    }'
```

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
│   ├── RHOBS remote client (Observatorium API, vault auth)
│   ├── Port-forward client (Prometheus on hive/MC clusters)
│   └── HTTP retry transport (429/5xx backoff)
├── Health checks
│   ├── 13 common checks (all operators inherit)
│   ├── Operator-specific checks (plug-and-play via OperatorChecker)
│   └── BYOC dynamic checks (user-defined commands)
├── Config file support (.healthcheck.yaml)
└── Embedded HTML report (no bash dependency)
```

## CLI Options

```
--cluster-list FILE    Cluster IDs file (one per line)
--list-clusters PRESET List clusters: all, rosa, osd, hypershift, managed
--oper KEY             Operator to check (repeatable, default: all)
--parallel N           Concurrent clusters (default: 1)
--reason TEXT          Elevation reason (required for production)
--no-elevate           Skip elevated checks
--elevate              Enable backplane elevation
--saas-only            SAAS targets + pipeline only (no cluster checks)
--exclude REGEX        Exclude clusters by name regex
--include REGEX        Include only matching clusters
--ocm-config FILE      OCM config file path
--ocm-url URL          OCM API URL override
--hive-ocm-url URL     OCM URL for hive cluster connections
--output FILE          JSON output (default: health_report_TIMESTAMP.json)
--no-html              Skip HTML generation
--config FILE          Config file (default: .healthcheck.yaml)
--log-level LEVEL      debug, info, warn, error
--log-dir DIR          Debug log file directory
--byoc COMMAND         Ad-hoc command to run on each cluster (exit 0 = PASS)
--byof FILE            JSON file with check definitions
--byoc-brief FILE      Extract compact BYOC results from results JSON
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
| ℹ | INFO | Informational — expected state |

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
- BYOC command output in monospace pre blocks

## Production Safety

- Production OCM auto-detected → `--no-elevate` applied automatically
- `--reason` with JIRA ticket required for production elevation
- Clusters in limited support or non-ready state are automatically skipped
- OCM token is checked against estimated runtime and refreshed proactively
- All cluster operations are read-only (GET, LIST, WATCH only)
- BYOC commands run with standard backplane permissions (or elevated if --elevate)

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
go test ./pkg/kube/ -v  # Elevation safety tests
./healthcheck --saas-only --oper camo   # Quick SAAS test (no clusters)
```
