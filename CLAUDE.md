# Operator Health Report — Claude Directives

## Overview

This repo provides comprehensive health monitoring for SRE-managed OpenShift operators across multiple clusters. It runs checks against live clusters, collects data via `oc`/`ocm`/Prometheus, and generates interactive HTML reports.

**Entry point:** `run.sh` — runs in containers by default (`--local` for direct execution)
**Scripts:** all in `lib/` — `collect_operator_health.sh` (single cluster), `collect_from_multiple_clusters.sh` (orchestrator), `generate_html_report.sh` (HTML report)

## Supported Operators

| Operator | Key | Namespace | Deployment |
|----------|-----|-----------|------------|
| configure-alertmanager-operator | `camo` | `openshift-monitoring` | `configure-alertmanager-operator` |
| route-monitor-operator | `rmo` | `openshift-route-monitor-operator` | `route-monitor-operator-controller-manager` |
| osd-metrics-exporter | `ome` | `openshift-osd-metrics` | `osd-metrics-exporter` |

## Architecture Patterns

### Adding New Checks

- **General checks** (all operators): Add to the main flow in `collect_operator_health.sh` between namespace check and operator-specific sections. Use `$NAMESPACE`, `$DEPLOYMENT`, `$OPERATOR_NAME`, `$PACKAGE_NAME` variables.
- **Operator-specific checks**: Add inside the `if [[ "$OPERATOR_NAME" == *"operator-name"* ]]` blocks at the end of the script.
- **Set `CURRENT_CHECK`** before each check section so API errors are associated with the right check.
- **Use `_run_oc`** for all `oc`/`ocm`/`curl`/`skopeo` commands — it captures errors, supports cache/replay, and logs to `api_errors`.
- **Use `_run_oc_optional`** for existence checks where "not found" is an expected result (e.g., OLM subscription on PKO clusters).
- **Use `jq_int`** instead of `jq '... | length'` for any value used in integer comparisons — prevents multiline jq output from crashing bash.

### JSON Output

Each check appends to the `health_checks` array via `health_checks+=("$(cat <<EOF ... EOF)")`. The final JSON output includes all checks, API errors, events, and cluster metadata.

**Critical**: Never use `$(...)` subshells inside heredoc JSON that modify global variables (like `api_errors`). Pre-compute values before the heredoc.

### Error Handling

- Every external command goes through `_run_oc()` → `_exec_or_replay()` → captures stderr, exit code, logs errors
- API errors include: operation description, actual command, check context, error type (api_error vs script_error)
- Errors are displayed inline under their parent check in the HTML report
- `set -uo pipefail` is used but NOT `set -e` — errors are handled per-cluster gracefully

### Cache/Replay System

`_exec_or_replay()` supports `--cache-dir` (save outputs) and `--replay` (read from cache). All oc/exec/curl commands go through this. Use for development iteration:
```bash
# Collect once
./run.sh --local -- --cluster-list test.list --reason "test" --oper rmo --cache-dir /tmp/cache
# Iterate on code changes
./run.sh --local -- --cluster-list test.list --reason "test" --oper rmo --cache-dir /tmp/cache --replay
```

### Container Support

`run.sh` builds from `Containerfile` (based on `ocm-container`). Mounts OCM config and backplane config as read-only volumes. `--parallel N` splits cluster list across N containers.

### SAAS Target Resolution

Version verification uses `resolve_saas_target()` which:
1. Tries PKO SAAS file first (`saas-*-pko.yaml`)
2. Falls back to OLM SAAS file (`saas-*.yaml`)
3. Uses fuzzy shard number matching for non-standard hive names (e.g., `hives02ue1` → `camo-pko-stage-02`)
4. Re-fetches SAAS refs on version mismatch to detect mid-run updates

### HTML Report

`generate_html_report.sh` produces a single-file HTML with embedded JavaScript/CSS. Key patterns:
- Data injected as `healthDataRaw` variable
- `saas_targets` metadata entries separated from cluster data
- Per-operator tabs with independent table rendering
- Custom renderers for OME metrics table, API errors, preconditions
- Charts use Chart.js with deferred rendering (created on first expand)

## Testing

When making changes:
1. Test against at least one cluster of each type: standard, SC, MC
2. Use `--cache-dir` to collect once, then `--replay` to iterate
3. Verify JSON output: `jq '.[0].health_checks | length'`
4. Verify HTML renders: `bash lib/generate_html_report.sh results.json report.html && open report.html`
5. Check for bash errors: `bash -n lib/collect_operator_health.sh`

## Production Safety — CRITICAL

**NEVER run `ocm backplane elevate` commands against production clusters without explicit user authorization.**

The script auto-detects the OCM environment. In production:
- `--no-elevate` is applied automatically (safe subset of checks only)
- `--prod-elevate` is required to explicitly acknowledge elevation in production
- Claude should NEVER suggest or execute `--prod-elevate` — only the user can decide this

When `NO_ELEVATE=true`:
- All `ocm backplane elevate` commands are silently skipped (return empty, rc=0)
- Checks that depend on elevated data report as SKIP or show empty results
- Safe checks still run: namespace, version, deployment/pod health, PKO/OLM status, logs, events

## Known Patterns and Pitfalls

- **Multiline jq output**: `jq '... | length'` can produce multiple values if input has multiple JSON objects. Always use `jq_int` for integer comparisons.
- **Heredoc JSON**: Variables expanded inside `cat <<EOF` must be single-line. Use `jq -cs` or `tr -d '\n'` for variables that might contain newlines.
- **Subshell variable loss**: `$(...)` creates a subshell. Don't call `log_api_error()` inside `$(...)` — the `api_errors` array modification is lost.
- **Elevation required**: Custom resources (RouteMonitor, ClusterUrlMonitor, ServiceMonitor, PrometheusRule) need `ocm backplane elevate` on managed clusters.
- **Two Prometheus stacks on MCs**: Platform Thanos (`openshift-monitoring`) sees MC-local probes. RHOBS Prometheus (`openshift-observability-operator`) sees HCP probes. Use `query_rhobs_prometheus()` for HCP data.
- **OLM-to-PKO migration**: Check for `collision-protection: IfNoController` annotation on resources that exist from OLM deployments. Missing annotation causes "refusing adoption" errors.
