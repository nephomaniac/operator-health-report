# Operator Health Report

Comprehensive health monitoring and reporting tools for OpenShift operators, with specialized support for Configure Alertmanager Operator (CAMO) and Route Monitor Operator (RMO).

## Scripts

### collect_from_multiple_clusters.sh

Main script for collecting data from multiple clusters. Supports three modes:

1. **Resource Usage Collection** (default): Collects CPU and memory usage metrics
2. **Operator Version Only** (`--op-ver`): Collects only operator versions
3. **Health Check** (`--health`): Performs production readiness health checks

### collect_pod_resource_usage.sh

Single-cluster resource usage collection script. Called by `collect_from_multiple_clusters.sh`.

### collect_pod_health.sh

Single-cluster health check script. Collects:
- Pod uptime
- Restart counts
- Error events
- Pod status
- Deployment health

### analyze_resource_data.sh

Analyzes resource usage data collected across multiple clusters.

### analyze_health_data.sh

Analyzes health check data and provides production readiness assessment.

## Usage

### Health Check (Production Readiness)

Perform health checks on all supported operators (CAMO and RMO):

```bash
./collect_from_multiple_clusters.sh --reason "SREP-12345 pre-release health check" --health
```

Health check specific operator only:

```bash
./collect_from_multiple_clusters.sh --reason "SREP-12345" --health --oper camo
```

Analyze health check results:

```bash
./analyze_health_data.sh health_check_20250101_120000.csv
```

### Resource Usage Collection

Collect resource usage from all operators:

```bash
./collect_from_multiple_clusters.sh --reason "SREP-12345 capacity planning"
```

Collect from specific operator:

```bash
./collect_from_multiple_clusters.sh --reason "SREP-12345" --oper camo
```

Analyze resource usage:

```bash
./analyze_resource_data.sh resource_usage_20250101_120000.csv
```

### Operator Version Collection

Collect only operator versions (faster):

```bash
./collect_from_multiple_clusters.sh --reason "SREP-12345" --op-ver
```

### Additional Options

Limit to specific clusters:

```bash
./collect_from_multiple_clusters.sh --reason "SREP-12345" --cluster-list clusters.txt
```

Limit to first N clusters:

```bash
./collect_from_multiple_clusters.sh --reason "SREP-12345" --max-clusters 10
```

## Health Check Metrics

The health check feature collects the following metrics:

- **Health Status**: HEALTHY, WARNING, or CRITICAL
- **Pod Uptime**: Minimum, maximum, and average pod uptime
- **Restart Counts**: Total pod restarts across all pods
- **Error Events**: Count of error and warning events
- **Deployment Status**: Desired vs ready vs available replicas
- **Pod Status**: Count of pods and their states

### Health Status Criteria

- **HEALTHY**: All checks pass
  - All replicas ready
  - Low restart count (≤5)
  - Low error events (≤10)
  - All pods in Running state
  - Pod uptime > 1 hour

- **WARNING**: Minor issues detected
  - Not all replicas ready
  - Moderate restarts (6-10)
  - Some pods not running
  - Recent pod restarts (< 1 hour uptime)

- **CRITICAL**: Major issues detected
  - High error event count (>10)

### Production Readiness Assessment

The `analyze_health_data.sh` script provides an overall assessment:

- **NOT READY**: Any cluster has CRITICAL status
- **REVIEW REQUIRED**: >50% of clusters have warnings
- **READY WITH CAUTION**: Some clusters have warnings (<50%)
- **READY FOR PRODUCTION**: All clusters are HEALTHY

## Requirements

- `ocm` - OpenShift Cluster Manager CLI
- `oc` - OpenShift CLI
- `jq` - JSON processor
- `bc` - Basic calculator (for resource calculations)
- Bash 4.0+ (for associative arrays)

## Example Workflow

1. Perform health check before release:
   ```bash
   ./collect_from_multiple_clusters.sh --reason "SREP-12345 CAMO v1.2.3 release" --health --oper camo
   ```

2. Analyze results:
   ```bash
   ./analyze_health_data.sh health_check_*.csv
   ```

3. Review clusters with issues (if any are reported)

4. Make release decision based on health assessment

## Output Files

All scripts generate timestamped CSV files:

- `resource_usage_YYYYMMDD_HHMMSS.csv` - Resource usage data
- `health_check_YYYYMMDD_HHMMSS.csv` - Health check data (when using `--health`)

CSV files can be opened in spreadsheet applications or processed with standard Unix tools.
