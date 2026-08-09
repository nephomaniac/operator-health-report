# RLR Central Pipeline Health Checks — Implementation Plan

## Context

The existing RLR checker (`pkg/checks/rlr/rlr.go`) covers the MC-side Vector collector and HCP-side log collectors well (26 MC checks, 4 HCP checks). However, it has zero visibility into the central pipeline (Lambda, SQS, DynamoDB, API Gateway) — the most common source of delivery failures observed in production.

This plan adds central pipeline checks and fills gaps identified during production triage sessions (August 2026).

## Branch

`rlr-central-pipeline-checks` — config structure already added, checks not yet implemented.

## What's Already Done

1. **Config structure** (`pkg/config/config.go`): Added `RLRConfig` and `RLREnvConfig` types with per-environment AWS resource identifiers (account ID, Lambda names, SQS queue names, DynamoDB table, API endpoint pattern, regions). Added `RLREnvForOCMURL()` helper to resolve env from the active OCM URL.

2. **Example config** (`rlr-config.example.yaml`): Template with all fields for int/stage/prod. Account IDs left blank — user fills from their own credentials.

3. **Gitignore**: `.healthcheck.yaml` and `.healthcheck.yml` added to prevent accidental commit of sensitive config.

## What Needs to Be Built

### Step 1: Thread Config to the RLR Checker

The `Config` object from `pkg/config` is loaded in `cmd/healthcheck/main.go` but not passed to `ClusterContext`. Two options:

**Option A (minimal):** Add a `Config *config.Config` field to `ClusterContext` in `pkg/checks/types.go`. Set it in `main.go` when creating each `ClusterContext`. The RLR checker reads `cc.Config.RLR` directly.

**Option B (interface):** Add an `OperatorConfigProvider` interface that checkers can implement to receive config. More extensible but heavier.

Recommend Option A — it's consistent with how `Metadata` is already passed.

### Step 2: AWS Client Setup

The central pipeline checks need an AWS SDK client authenticated to the central account. The RLR checker should:

1. Read the `RLREnvConfig` for the current OCM environment
2. Use `osdctl account cli -i <account_id> -o env` (or `rh-aws-saml-login` — see note below) to get temporary credentials
3. Create an AWS session scoped to the check execution
4. Clean up credentials after checks complete

**Important:** The `aws_profile` field exists for backward compatibility but `-p` flag usage is deprecated. The tool should try without `-p` first (assumes `rh-aws-saml-login` was used), then fall back to `-p` if that fails. See memory note `feedback_osdctl-aws-auth.md` for details.

The central checks should run **once per environment**, not once per cluster. Consider adding a `runCentralChecks()` method that runs before or after the per-cluster loop, keyed by OCM environment.

### Step 3: Implement Central Pipeline Checks

Each check follows the existing pattern: `cc.SetCheck("name")`, create `checks.Result`, query AWS, set status, `cc.AddResult(r)`.

#### SQS Pipeline Checks

```go
// rlr_sqs_queue_depth
// Query: aws sqs get-queue-attributes --attribute-names All
// Pass criteria: ApproximateNumberOfMessages < 10000
// Warning: >= 10000 (processing backlog)
// Fail: >= 100000 (severe backlog)
func checkSQSQueueDepth(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)

// rlr_sqs_dlq_messages
// Query: aws sqs get-queue-attributes on DLQ
// Pass criteria: ApproximateNumberOfMessages == 0
// Warning: > 0 (some deliveries failed permanently)
// Fail: > 100 (systemic delivery failure)
// NOTE: Use attribute name "ApproximateNumberOfMessages" NOT "ApproximateNumberOfMessagesVisible"
//       (the latter doesn't exist — this was a bug we found in verify-rlr-delivery.sh)
func checkSQSDLQMessages(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)

// rlr_sqs_oldest_message
// Query: ApproximateAgeOfOldestMessage from queue attributes
// Pass: < 3600 (1 hour)
// Warning: >= 3600 (processing stalled)
// Fail: >= 86400 (1 day — severe stall)
func checkSQSOldestMessage(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)
```

#### Lambda Processor Checks

```go
// rlr_lambda_errors
// Query: CloudWatch GetMetricStatistics for AWS/Lambda Errors metric, per region
// Pass: Sum == 0 over last 15 minutes
// Fail: Sum > 0
// Details: include per-region breakdown
func checkLambdaErrors(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)

// rlr_lambda_invocations
// Query: CloudWatch GetMetricStatistics for AWS/Lambda Invocations, per region
// Pass: Sum > 0 (pipeline is active)
// Warning: Sum == 0 (no processing happening)
// Details: include per-region counts for baseline comparison
func checkLambdaInvocations(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)

// rlr_lambda_recursive_drops
// Query: CloudWatch GetMetricStatistics for AWS/Lambda RecursiveInvocationsDropped, per region
// Pass: Sum == 0
// Fail: Sum > 0 (recursive loop detection is actively dropping messages — ROSAENG-14340)
// This is the single most important Lambda check — non-zero means data loss
func checkLambdaRecursiveDrops(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)

// rlr_lambda_throttles
// Query: CloudWatch Throttles metric
// Pass: Sum == 0
// Warning: Sum > 0 (concurrency limits being hit)
func checkLambdaThrottles(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)

// rlr_lambda_duration
// Query: CloudWatch Duration metric (P99, P50)
// Pass: P99 < 30s AND P50 < 10s
// Warning: P99 >= 30s (approaching Lambda timeout)
func checkLambdaDuration(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)
```

#### Delivery Metrics Checks

```go
// rlr_delivery_success_rate
// Query: CloudWatch HCPLF/LogForwarding metrics for each enrolled tenant
//   - LogCount/cloudwatch/successful_delivery vs failed_delivery
//   - LogCount/s3/successful_delivery vs failed_delivery
// Pass: failure rate < 5% per tenant
// Warning: failure rate >= 5%
// Fail: failure rate >= 20%
// NOTE: Query requires the Tenant dimension — list tenants from DynamoDB first
func checkDeliverySuccessRate(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)

// rlr_enrolled_tenant_count
// Query: DynamoDB Scan with Select=COUNT on tenant config table
// Info: report count of enrolled tenants and their delivery types
// This is informational — no pass/fail, but useful for tracking enrollment growth
func checkEnrolledTenantCount(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)
```

#### API Gateway Checks

```go
// rlr_api_health
// Query: HTTP GET to ${api_endpoint_pattern}/api/v1/health for each region
// Pass: returns {"status": "healthy"}
// Fail: non-200 response or unhealthy status
// NOTE: Requires network access to devshift.net (VPN)
func checkAPIHealth(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)

// rlr_api_data_trace_disabled
// Query: aws apigateway get-stage, check methodSettings.*/*.dataTraceEnabled
// Pass: dataTraceEnabled == false
// Fail: dataTraceEnabled == true (ROSAENG-61269 security violation)
func checkAPIDataTraceDisabled(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)

// rlr_authorizer_cache_disabled
// Query: aws apigateway get-authorizer, check authorizerResultTtlInSeconds
// Pass: TTL == 0
// Fail: TTL > 0 (ROSAENG-61267 — requests may bypass body validation)
func checkAuthorizerCacheDisabled(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig)
```

#### Vector Config Validation (MC-side addition)

```go
// rlr_vector_batch_config
// Query: Read Vector ConfigMap, parse batch settings
// Pass: timeout_secs >= 60 AND max_bytes >= 10485760 (10MB)
// Warning: timeout_secs < 60 (cost risk — see July 2026 S3 cost spike incident)
// Details: report current batch.max_bytes, batch.timeout_secs, concurrency settings
// This catches batch size reductions that caused a 3.7x S3 cost increase
func checkVectorBatchConfig(ctx context.Context, cc *checks.ClusterContext)
```

### Step 4: Wire Checks into RunChecks

In `rlr.go`, add a new section after the MC checks:

```go
func (c *RLRChecker) runMCChecks(ctx context.Context, cc *checks.ClusterContext) {
    // ... existing MC checks ...

    // Central Pipeline (requires AWS credentials for central account)
    if cc.Config != nil && cc.Config.RLR != nil {
        env := cc.Config.RLREnvForOCMURL(cc.OCMEnv)
        if env != nil {
            c.runCentralChecks(ctx, cc, env)
        }
    }
}

func (c *RLRChecker) runCentralChecks(ctx context.Context, cc *checks.ClusterContext, env *config.RLREnvConfig) {
    // SQS
    checkSQSQueueDepth(ctx, cc, env)
    checkSQSDLQMessages(ctx, cc, env)
    checkSQSOldestMessage(ctx, cc, env)

    // Lambda
    checkLambdaErrors(ctx, cc, env)
    checkLambdaInvocations(ctx, cc, env)
    checkLambdaRecursiveDrops(ctx, cc, env)
    checkLambdaThrottles(ctx, cc, env)
    checkLambdaDuration(ctx, cc, env)

    // Delivery
    checkDeliverySuccessRate(ctx, cc, env)
    checkEnrolledTenantCount(ctx, cc, env)

    // API Gateway
    checkAPIHealth(ctx, cc, env)
    checkAPIDataTraceDisabled(ctx, cc, env)
    checkAuthorizerCacheDisabled(ctx, cc, env)
}
```

**Deduplication concern:** Central checks should run once per environment, not once per MC. Add a `centralChecksRun` flag or run them on the first MC encountered, then skip on subsequent MCs in the same env.

### Step 5: Add AWS SDK Dependencies

```bash
cd ~/sandbox/operator-health-report
go get github.com/aws/aws-sdk-go-v2
go get github.com/aws/aws-sdk-go-v2/config
go get github.com/aws/aws-sdk-go-v2/service/sqs
go get github.com/aws/aws-sdk-go-v2/service/cloudwatch
go get github.com/aws/aws-sdk-go-v2/service/dynamodb
go get github.com/aws/aws-sdk-go-v2/service/apigateway
go get github.com/aws/aws-sdk-go-v2/service/lambda
```

### Step 6: Update HTML Report

The report template (`pkg/report/template_suffix.html`) needs:
- A "Central Pipeline" section for RLR showing SQS depth, Lambda health, delivery rates
- Check name formatting entries for all new checks (lines ~505-541)

## Known Issues / Gotchas

1. **SQS attribute name**: Use `ApproximateNumberOfMessages`, NOT `ApproximateNumberOfMessagesVisible`. The latter doesn't exist and causes `InvalidAttributeName` errors silently when `2>/dev/null` is used. We found and fixed this bug in `verify-rlr-delivery.sh` during this session.

2. **Central checks run once, not per-MC**: The central account resources (Lambda, SQS, DynamoDB) are shared across all MCs. Running checks per-MC would produce duplicate results. Use a dedup mechanism.

3. **AWS credential lifecycle**: Central account creds are temporary (1 hour STS). If the health check runs longer, creds may expire mid-run. Handle gracefully.

4. **Prometheus staleness at "now"**: When querying RHOBS metrics like `count by (tenant)`, use `last_over_time(...[15m])` to avoid the trailing-edge staleness artifact that makes tenant counts appear to drop. We investigated this in detail — see memory `project_vector-enrollment-filtering.md`.

5. **Region iteration**: Production has 5 regions (us-east-1, us-east-2, us-west-2, eu-west-1, ap-southeast-1). Lambda and SQS checks must iterate all regions. Some resources (DynamoDB, API Gateway) may exist in fewer regions.

6. **osdctl auth deprecation**: `-p rhcontrol` flag for osdctl is deprecated in favor of `rh-aws-saml-login`. The tool should handle both until the migration is complete. See memory `feedback_osdctl-aws-auth.md`.

## Test Plan

### Unit Tests

For each new check function, test:
- Happy path (all metrics within bounds → PASS)
- Threshold boundaries (exact boundary values → correct status)
- AWS API errors (permission denied, timeout → ACCESS_DENIED/UNKNOWN, not panic)
- Missing config (no RLR config → checks skipped gracefully)
- Empty responses (no metrics data → appropriate UNKNOWN/INFO)

### Integration Testing

1. **With LocalStack**: Mock SQS, DynamoDB, CloudWatch for local testing
2. **Against staging**: Run with staging config, verify checks produce meaningful results
3. **Against production**: Read-only validation, compare output with manual verification script (`verify-rlr-delivery.sh`)

### Validation Checklist

After implementation, verify each check against known states:
- [ ] `rlr_sqs_dlq_messages`: confirm 0 in staging, check prod for known DLQ messages
- [ ] `rlr_lambda_recursive_drops`: confirm >0 in ap-southeast-1 (known issue ROSAENG-14340)
- [ ] `rlr_lambda_errors`: confirm 0 across all regions
- [ ] `rlr_api_health`: confirm "healthy" in all regions
- [ ] `rlr_api_data_trace_disabled`: confirm false (ROSAENG-61269)
- [ ] `rlr_authorizer_cache_disabled`: confirm TTL=0 (ROSAENG-61267)
- [ ] `rlr_delivery_success_rate`: compare with `verify-rlr-delivery.sh` output
- [ ] `rlr_vector_batch_config`: confirm batch settings match expected values

## References

- [RLR Architecture Touchpoints](memory: reference_rlr-architecture-touchpoints.md) — all 7 config/deployment layers
- [S3 Cost Spike July 2026](memory: project_s3-cost-spike-july2026.md) — batch size incident
- [Recursive Loop Finding](memory: project_recursive-loop-finding.md) — Lambda recursive loop detection
- [Prod Rollout Handover](memory: project_prod-rollout-handover.md) — SREPHOA ticket pattern
- [verify-rlr-delivery.sh](~/make_cluster/verify-rlr-delivery.sh) — manual verification script (reference implementation for many of these checks)
- [SREPHOA-102](https://redhat.atlassian.net/browse/SREPHOA-102) — empty message alert handover
