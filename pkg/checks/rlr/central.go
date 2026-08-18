package rlr

import (
	"bufio"
	"context"
	"fmt"
	"math"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/apigateway"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	sqstypes "github.com/aws/aws-sdk-go-v2/service/sqs/types"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/config"
	"github.com/openshift/operator-health-report/pkg/logging"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Central pipeline checks run once per environment, not per cluster.
// Results are cached and replayed on subsequent MCs in the same environment.
var (
	centralMu      sync.Mutex
	centralResults = map[string][]checks.Result{} // keyed by env (integration/staging/production)
	centralOnce    = map[string]*sync.Once{}
)

func getCentralOnce(env string) *sync.Once {
	centralMu.Lock()
	defer centralMu.Unlock()
	if _, ok := centralOnce[env]; !ok {
		centralOnce[env] = &sync.Once{}
	}
	return centralOnce[env]
}

func storeCentralResults(env string, results []checks.Result) {
	centralMu.Lock()
	defer centralMu.Unlock()
	centralResults[env] = results
}

func getCentralResults(env string) ([]checks.Result, bool) {
	centralMu.Lock()
	defer centralMu.Unlock()
	r, ok := centralResults[env]
	return r, ok
}

// runCentralPipelineChecks runs central pipeline checks once per environment,
// replaying cached results for subsequent MCs in the same environment.
func runCentralPipelineChecks(ctx context.Context, cc *checks.ClusterContext) {
	if cc.Config == nil || cc.Config.RLR == nil {
		return
	}

	envCfg := cc.Config.RLREnvForOCMURL(cc.OCMEnv)
	if envCfg == nil {
		return
	}

	envKey := resolveEnvKey(cc.OCMEnv)

	once := getCentralOnce(envKey)
	once.Do(func() {
		results := executeCentralChecks(ctx, cc, envCfg, envKey)
		storeCentralResults(envKey, results)
	})

	if cached, ok := getCentralResults(envKey); ok {
		for _, r := range cached {
			cc.AddResult(r)
		}
	}
}

func resolveEnvKey(ocmEnv string) string {
	lower := strings.ToLower(ocmEnv)
	switch {
	case strings.Contains(lower, "integration"):
		return "integration"
	case strings.Contains(lower, "stage"):
		return "staging"
	default:
		return "production"
	}
}

func executeCentralChecks(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, envKey string) []checks.Result {
	log := logging.WithCheck("rlr_central_pipeline")

	awsCfg, err := acquireAWSCredentials(ctx, envCfg, envKey)
	if err != nil {
		log.WithField("env", envKey).Warnf("Cannot acquire AWS credentials: %v", err)
		r := checks.Result{
			Check:    "rlr_central_credentials",
			Status:   checks.StatusInfo,
			Severity: checks.SeverityInfo,
			Message:  fmt.Sprintf("Central pipeline checks skipped — AWS credentials unavailable for %s: %v", envKey, err),
			Details: map[string]any{
				"description":   "Acquires AWS credentials for the central RLR account to query SQS, Lambda, DynamoDB, and API Gateway. Uses osdctl account cli or falls back to AWS profile from config.",
				"pass_criteria": "PASS: credentials acquired. INFO: credentials unavailable — central checks skipped.",
				"environment":   envKey,
			},
		}
		return []checks.Result{r}
	}

	var results []checks.Result
	collect := func(r checks.Result) { results = append(results, r) }

	// SQS checks — run across all regions
	for _, region := range envCfg.Regions {
		regionalCfg := awsCfg.Copy()
		regionalCfg.Region = region

		collect(checkSQSQueueDepth(ctx, cc, envCfg, regionalCfg, region))
		collect(checkSQSDLQMessages(ctx, cc, envCfg, regionalCfg, region))
		collect(checkSQSOldestMessage(ctx, cc, envCfg, regionalCfg, region))
	}

	// Lambda checks — run across all regions
	for _, region := range envCfg.Regions {
		regionalCfg := awsCfg.Copy()
		regionalCfg.Region = region

		collect(checkLambdaErrors(ctx, cc, envCfg, regionalCfg, region))
		collect(checkLambdaInvocations(ctx, cc, envCfg, regionalCfg, region))
		collect(checkLambdaRecursiveDrops(ctx, cc, envCfg, regionalCfg, region))
		collect(checkLambdaThrottles(ctx, cc, envCfg, regionalCfg, region))
		collect(checkLambdaDuration(ctx, cc, envCfg, regionalCfg, region))
	}

	// Delivery checks — use first region for DynamoDB (single-region table)
	if len(envCfg.Regions) > 0 {
		primaryCfg := awsCfg.Copy()
		primaryCfg.Region = envCfg.Regions[0]
		collect(checkEnrolledTenantCount(ctx, cc, envCfg, primaryCfg))
	}

	// Delivery success rate — CloudWatch custom metrics, per region
	for _, region := range envCfg.Regions {
		regionalCfg := awsCfg.Copy()
		regionalCfg.Region = region
		collect(checkDeliverySuccessRate(ctx, cc, envCfg, regionalCfg, region))
	}

	// API Gateway checks — per region
	for _, region := range envCfg.Regions {
		regionalCfg := awsCfg.Copy()
		regionalCfg.Region = region

		collect(checkAPIHealth(ctx, envCfg, region))
		collect(checkAPIDataTraceDisabled(ctx, cc, envCfg, regionalCfg, region))
		collect(checkAuthorizerCacheDisabled(ctx, cc, envCfg, regionalCfg, region))
	}

	// Vector batch config is MC-side, not AWS
	collect(checkVectorBatchConfig(ctx, cc))

	return results
}

// acquireAWSCredentials gets temporary credentials for the central RLR account.
func acquireAWSCredentials(ctx context.Context, envCfg *config.RLREnvConfig, envKey string) (aws.Config, error) {
	log := logging.WithCheck("rlr_central_credentials")

	if envCfg.CentralAccountID == "" {
		return aws.Config{}, fmt.Errorf("central_account_id not configured for %s", envKey)
	}

	// Try osdctl account cli first
	cmd := exec.CommandContext(ctx, "osdctl", "account", "cli", "-i", envCfg.CentralAccountID, "-o", "env")
	cmd.Env = cleanAWSEnv(os.Environ())
	output, err := cmd.Output()

	if err == nil {
		creds, region, parseErr := parseEnvOutput(string(output))
		if parseErr == nil {
			log.Debugf("Acquired credentials via osdctl for account %s", envCfg.CentralAccountID)
			if region == "" && len(envCfg.Regions) > 0 {
				region = envCfg.Regions[0]
			}
			return awsconfig.LoadDefaultConfig(ctx,
				awsconfig.WithRegion(region),
				awsconfig.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(
					creds.accessKeyID, creds.secretAccessKey, creds.sessionToken,
				)),
			)
		}
		log.Debugf("osdctl output parse failed: %v", parseErr)
	} else {
		log.Debugf("osdctl failed: %v", err)
	}

	// Fallback: AWS profile from config
	if envCfg.AWSProfile != "" {
		log.Debugf("Falling back to AWS profile: %s", envCfg.AWSProfile)
		region := ""
		if len(envCfg.Regions) > 0 {
			region = envCfg.Regions[0]
		}
		return awsconfig.LoadDefaultConfig(ctx,
			awsconfig.WithSharedConfigProfile(envCfg.AWSProfile),
			awsconfig.WithRegion(region),
		)
	}

	return aws.Config{}, fmt.Errorf("osdctl failed and no aws_profile configured for %s", envKey)
}

type awsCreds struct {
	accessKeyID     string
	secretAccessKey string
	sessionToken    string
}

func parseEnvOutput(output string) (awsCreds, string, error) {
	var creds awsCreds
	var region string

	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		line = strings.TrimPrefix(line, "export ")
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.Trim(strings.TrimSpace(parts[1]), "'\"")
		switch key {
		case "AWS_ACCESS_KEY_ID":
			creds.accessKeyID = val
		case "AWS_SECRET_ACCESS_KEY":
			creds.secretAccessKey = val
		case "AWS_SESSION_TOKEN":
			creds.sessionToken = val
		case "AWS_DEFAULT_REGION", "AWS_REGION":
			region = val
		}
	}

	if creds.accessKeyID == "" || creds.secretAccessKey == "" {
		return creds, region, fmt.Errorf("missing required credentials in osdctl output")
	}
	return creds, region, nil
}

// cleanAWSEnv removes existing AWS credential env vars to prevent leakage.
func cleanAWSEnv(env []string) []string {
	filtered := make([]string, 0, len(env))
	for _, e := range env {
		key := strings.SplitN(e, "=", 2)[0]
		switch key {
		case "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
			"AWS_DEFAULT_REGION", "AWS_REGION":
			continue
		}
		filtered = append(filtered, e)
	}
	return filtered
}

// --- SQS Checks ---

func checkSQSQueueDepth(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_sqs_queue_depth_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the approximate number of messages in the RLR SQS delivery queue. A growing queue indicates the Lambda processor cannot keep up with incoming S3 event notifications.",
			"pass_criteria": "PASS: <10,000 messages. WARN: >=10,000 (backlog). FAIL: >=100,000 (severe backlog).",
			"region":        region,
			"queue":         envCfg.SQSQueueName,
		},
	}

	client := sqs.NewFromConfig(awsCfg)

	queueURL, err := resolveQueueURL(ctx, client, envCfg.SQSQueueName)
	if err != nil {
		cc.RecordError("Resolve SQS queue URL: "+envCfg.SQSQueueName, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot resolve queue URL: %v", region, err)
		return r
	}

	attrs, err := client.GetQueueAttributes(ctx, &sqs.GetQueueAttributesInput{
		QueueUrl:       &queueURL,
		AttributeNames: []sqstypes.QueueAttributeName{"ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"},
	})
	if err != nil {
		cc.RecordError("SQS GetQueueAttributes: "+envCfg.SQSQueueName, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot query queue attributes: %v", region, err)
		return r
	}

	visible := parseAttrInt(attrs.Attributes, "ApproximateNumberOfMessages")
	inFlight := parseAttrInt(attrs.Attributes, "ApproximateNumberOfMessagesNotVisible")

	r.Details["approximate_messages"] = visible
	r.Details["in_flight_messages"] = inFlight

	switch {
	case visible >= 100000:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("[%s] Severe queue backlog — %d messages (processing may be stalled)", region, visible)
	case visible >= 10000:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("[%s] Queue backlog building — %d messages", region, visible)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] Queue healthy — %d messages, %d in-flight", region, visible, inFlight)
	}
	return r
}

func checkSQSDLQMessages(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_sqs_dlq_messages_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the dead-letter queue for permanently failed deliveries. Any messages here represent logs that could not be processed after all retry attempts.",
			"pass_criteria": "PASS: 0 messages. WARN: >0 (some failures). FAIL: >100 (systemic failure).",
			"region":        region,
			"queue":         envCfg.SQSDLQName,
		},
	}

	client := sqs.NewFromConfig(awsCfg)

	queueURL, err := resolveQueueURL(ctx, client, envCfg.SQSDLQName)
	if err != nil {
		cc.RecordError("Resolve SQS DLQ URL: "+envCfg.SQSDLQName, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot resolve DLQ URL: %v", region, err)
		return r
	}

	// Use "ApproximateNumberOfMessages" — NOT "ApproximateNumberOfMessagesVisible" which doesn't exist
	attrs, err := client.GetQueueAttributes(ctx, &sqs.GetQueueAttributesInput{
		QueueUrl:       &queueURL,
		AttributeNames: []sqstypes.QueueAttributeName{"ApproximateNumberOfMessages"},
	})
	if err != nil {
		cc.RecordError("SQS GetQueueAttributes DLQ: "+envCfg.SQSDLQName, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot query DLQ attributes: %v", region, err)
		return r
	}

	count := parseAttrInt(attrs.Attributes, "ApproximateNumberOfMessages")
	r.Details["dlq_messages"] = count

	switch {
	case count > 100:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("[%s] DLQ has %d messages — systemic delivery failure", region, count)
	case count > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("[%s] DLQ has %d message(s) — some deliveries failed permanently", region, count)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] DLQ empty — no permanent delivery failures", region)
	}
	return r
}

func checkSQSOldestMessage(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_sqs_oldest_message_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the age of the oldest message in the SQS queue. A very old message indicates processing has stalled — the Lambda consumer is not draining the queue.",
			"pass_criteria": "PASS: <1 hour. WARN: >=1 hour (stalled). FAIL: >=24 hours (severe stall).",
			"region":        region,
			"queue":         envCfg.SQSQueueName,
		},
	}

	client := sqs.NewFromConfig(awsCfg)

	queueURL, err := resolveQueueURL(ctx, client, envCfg.SQSQueueName)
	if err != nil {
		cc.RecordError("Resolve SQS queue URL for age: "+envCfg.SQSQueueName, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot resolve queue URL: %v", region, err)
		return r
	}

	attrs, err := client.GetQueueAttributes(ctx, &sqs.GetQueueAttributesInput{
		QueueUrl:       &queueURL,
		AttributeNames: []sqstypes.QueueAttributeName{"ApproximateAgeOfOldestMessage"},
	})
	if err != nil {
		cc.RecordError("SQS oldest message age: "+envCfg.SQSQueueName, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot query oldest message age: %v", region, err)
		return r
	}

	ageSec := parseAttrInt(attrs.Attributes, "ApproximateAgeOfOldestMessage")
	r.Details["oldest_message_seconds"] = ageSec
	r.Details["oldest_message_human"] = humanDuration(time.Duration(ageSec) * time.Second)

	switch {
	case ageSec >= 86400:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("[%s] Oldest message is %s old — processing severely stalled", region, humanDuration(time.Duration(ageSec)*time.Second))
	case ageSec >= 3600:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("[%s] Oldest message is %s old — processing stalled", region, humanDuration(time.Duration(ageSec)*time.Second))
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] Queue current — oldest message %s old", region, humanDuration(time.Duration(ageSec)*time.Second))
	}
	return r
}

// --- Lambda Checks ---

func checkLambdaErrors(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_lambda_errors_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks Lambda error count over the last 15 minutes. Errors indicate the log distributor function is failing to process SQS messages.",
			"pass_criteria": "PASS: 0 errors. FAIL: >0 errors.",
			"region":        region,
			"function":      envCfg.LambdaFunctionName,
		},
	}

	cwClient := cloudwatch.NewFromConfig(awsCfg)
	sum, err := getLambdaMetricSum(ctx, cwClient, envCfg.LambdaFunctionName, "Errors", region, 15)
	if err != nil {
		cc.RecordError("CloudWatch Lambda Errors: "+region, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot query Lambda errors: %v", region, err)
		return r
	}

	r.Details["error_count_15m"] = int64(sum)

	if sum > 0 {
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("[%s] Lambda errors: %d in last 15m", region, int64(sum))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] No Lambda errors in last 15m", region)
	}
	return r
}

func checkLambdaInvocations(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_lambda_invocations_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks Lambda invocation count over the last 15 minutes. Zero invocations means the pipeline is not processing any messages — either no logs are flowing or the SQS trigger is disconnected.",
			"pass_criteria": "PASS: >0 invocations. WARN: 0 invocations (pipeline idle).",
			"region":        region,
			"function":      envCfg.LambdaFunctionName,
		},
	}

	cwClient := cloudwatch.NewFromConfig(awsCfg)
	sum, err := getLambdaMetricSum(ctx, cwClient, envCfg.LambdaFunctionName, "Invocations", region, 15)
	if err != nil {
		cc.RecordError("CloudWatch Lambda Invocations: "+region, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot query Lambda invocations: %v", region, err)
		return r
	}

	r.Details["invocation_count_15m"] = int64(sum)

	if sum > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] Lambda active — %d invocations in last 15m", region, int64(sum))
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("[%s] Lambda idle — 0 invocations in last 15m", region)
	}
	return r
}

func checkLambdaRecursiveDrops(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_lambda_recursive_drops_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Checks for Lambda recursive invocation drops (ROSAENG-14340). When AWS detects a recursive loop (Lambda → SQS → Lambda), it drops messages to break the cycle. Non-zero means active data loss.",
			"pass_criteria": "PASS: 0 drops. FAIL: >0 drops (data loss).",
			"region":        region,
			"function":      envCfg.LambdaFunctionName,
		},
	}

	cwClient := cloudwatch.NewFromConfig(awsCfg)
	sum, err := getLambdaMetricSum(ctx, cwClient, envCfg.LambdaFunctionName, "RecursiveInvocationsDropped", region, 15)
	if err != nil {
		cc.RecordError("CloudWatch Lambda RecursiveInvocationsDropped: "+region, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot query recursive drops: %v", region, err)
		return r
	}

	r.Details["recursive_drops_15m"] = int64(sum)

	if sum > 0 {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("[%s] RECURSIVE LOOP DETECTED — %d messages dropped (ROSAENG-14340)", region, int64(sum))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] No recursive invocation drops", region)
	}
	return r
}

func checkLambdaThrottles(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_lambda_throttles_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks Lambda throttle count. Throttles mean concurrent execution limits are being hit — messages will retry but delivery latency increases.",
			"pass_criteria": "PASS: 0 throttles. WARN: >0 throttles.",
			"region":        region,
			"function":      envCfg.LambdaFunctionName,
		},
	}

	cwClient := cloudwatch.NewFromConfig(awsCfg)
	sum, err := getLambdaMetricSum(ctx, cwClient, envCfg.LambdaFunctionName, "Throttles", region, 15)
	if err != nil {
		cc.RecordError("CloudWatch Lambda Throttles: "+region, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot query Lambda throttles: %v", region, err)
		return r
	}

	r.Details["throttle_count_15m"] = int64(sum)

	if sum > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("[%s] Lambda throttled %d times in last 15m — concurrency limit hit", region, int64(sum))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] No Lambda throttles", region)
	}
	return r
}

func checkLambdaDuration(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_lambda_duration_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks Lambda execution duration percentiles. High p99 approaching the Lambda timeout (default 30s) means some invocations are nearly timing out.",
			"pass_criteria": "PASS: p99 <30s AND p50 <10s. WARN: p99 >=30s (approaching timeout).",
			"region":        region,
			"function":      envCfg.LambdaFunctionName,
		},
	}

	cwClient := cloudwatch.NewFromConfig(awsCfg)
	now := time.Now()
	start := now.Add(-15 * time.Minute)

	input := &cloudwatch.GetMetricStatisticsInput{
		Namespace:  aws.String("AWS/Lambda"),
		MetricName: aws.String("Duration"),
		Dimensions: []cwtypes.Dimension{{
			Name:  aws.String("FunctionName"),
			Value: aws.String(envCfg.LambdaFunctionName),
		}},
		StartTime:  &start,
		EndTime:    &now,
		Period:     aws.Int32(900),
		Statistics: []cwtypes.Statistic{cwtypes.StatisticAverage, cwtypes.StatisticMaximum},
		ExtendedStatistics: []string{"p99", "p50"},
	}

	resp, err := cwClient.GetMetricStatistics(ctx, input)
	if err != nil {
		cc.RecordError("CloudWatch Lambda Duration: "+region, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot query Lambda duration: %v", region, err)
		return r
	}

	if len(resp.Datapoints) == 0 {
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("[%s] No Lambda duration data — function may not have been invoked", region)
		return r
	}

	dp := resp.Datapoints[0]
	var p99ms, p50ms float64

	if dp.ExtendedStatistics != nil {
		if v, ok := dp.ExtendedStatistics["p99"]; ok {
			p99ms = v
		}
		if v, ok := dp.ExtendedStatistics["p50"]; ok {
			p50ms = v
		}
	}

	avgMs := 0.0
	maxMs := 0.0
	if dp.Average != nil {
		avgMs = *dp.Average
	}
	if dp.Maximum != nil {
		maxMs = *dp.Maximum
	}

	r.Details["p99_ms"] = math.Round(p99ms*100) / 100
	r.Details["p50_ms"] = math.Round(p50ms*100) / 100
	r.Details["avg_ms"] = math.Round(avgMs*100) / 100
	r.Details["max_ms"] = math.Round(maxMs*100) / 100

	p99sec := p99ms / 1000
	p50sec := p50ms / 1000

	if p99sec >= 30 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("[%s] Lambda p99 duration %.1fs — approaching timeout", region, p99sec)
	} else if p50sec >= 10 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("[%s] Lambda p50 duration %.1fs — elevated processing time", region, p50sec)
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] Lambda duration healthy — p99: %.1fs, p50: %.1fs", region, p99sec, p50sec)
	}
	return r
}

// --- Delivery Metrics Checks ---

func checkDeliverySuccessRate(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_delivery_success_rate_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the log delivery success rate using custom CloudWatch metrics emitted by the Lambda distributor. Compares successful vs failed deliveries across CloudWatch and S3 destination types.",
			"pass_criteria": "PASS: failure rate <5%. WARN: >=5%. FAIL: >=20%.",
			"region":        region,
			"namespace":     envCfg.MetricsNamespace,
		},
	}

	if envCfg.MetricsNamespace == "" {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] No metrics_namespace configured — cannot query delivery metrics", region)
		return r
	}

	cwClient := cloudwatch.NewFromConfig(awsCfg)
	now := time.Now()
	start := now.Add(-15 * time.Minute)

	successTotal := 0.0
	failureTotal := 0.0

	for _, destType := range []string{"cloudwatch", "s3"} {
		for _, outcome := range []string{"successful_delivery", "failed_delivery"} {
			metricName := fmt.Sprintf("LogCount/%s/%s", destType, outcome)
			input := &cloudwatch.GetMetricStatisticsInput{
				Namespace:  aws.String(envCfg.MetricsNamespace),
				MetricName: aws.String(metricName),
				StartTime:  &start,
				EndTime:    &now,
				Period:     aws.Int32(900),
				Statistics: []cwtypes.Statistic{cwtypes.StatisticSum},
			}

			resp, err := cwClient.GetMetricStatistics(ctx, input)
			if err != nil {
				continue
			}

			for _, dp := range resp.Datapoints {
				if dp.Sum != nil {
					if strings.Contains(outcome, "successful") {
						successTotal += *dp.Sum
					} else {
						failureTotal += *dp.Sum
					}
				}
			}
		}
	}

	total := successTotal + failureTotal
	r.Details["successful_deliveries"] = int64(successTotal)
	r.Details["failed_deliveries"] = int64(failureTotal)
	r.Details["total_deliveries"] = int64(total)

	if total == 0 {
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("[%s] No delivery metrics in last 15m — no enrolled tenants or no logs flowing", region)
		return r
	}

	failureRate := (failureTotal / total) * 100
	r.Details["failure_rate_percent"] = math.Round(failureRate*100) / 100

	switch {
	case failureRate >= 20:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("[%s] Delivery failure rate %.1f%% — %d/%d failed", region, failureRate, int64(failureTotal), int64(total))
	case failureRate >= 5:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("[%s] Delivery failure rate %.1f%% — %d/%d failed", region, failureRate, int64(failureTotal), int64(total))
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] Delivery healthy — %.1f%% success (%d delivered)", region, 100-failureRate, int64(successTotal))
	}
	return r
}

func checkEnrolledTenantCount(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config) checks.Result {
	r := checks.Result{
		Check:    "rlr_enrolled_tenant_count",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Reports the number of enrolled tenants in the RLR DynamoDB config table. Informational — useful for tracking enrollment growth and validating that the table is accessible.",
			"pass_criteria": "INFO: always informational. Reports tenant count.",
			"table":         envCfg.DynamoDBTable,
		},
	}

	if envCfg.DynamoDBTable == "" {
		r.Status = checks.StatusSkip
		r.Message = "No dynamodb_table configured — cannot query tenant count"
		return r
	}

	ddbClient := dynamodb.NewFromConfig(awsCfg)

	desc, err := ddbClient.DescribeTable(ctx, &dynamodb.DescribeTableInput{
		TableName: aws.String(envCfg.DynamoDBTable),
	})
	if err != nil {
		cc.RecordError("DynamoDB DescribeTable: "+envCfg.DynamoDBTable, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot describe DynamoDB table: %v", err)
		return r
	}

	count := int64(0)
	if desc.Table != nil && desc.Table.ItemCount != nil {
		count = *desc.Table.ItemCount
	}

	r.Details["tenant_count"] = count
	r.Details["table_status"] = ""
	if desc.Table != nil {
		r.Details["table_status"] = string(desc.Table.TableStatus)
	}

	r.Status = checks.StatusInfo
	r.Message = fmt.Sprintf("DynamoDB table %s has %d enrolled tenants (status: %s)", envCfg.DynamoDBTable, count, r.Details["table_status"])
	return r
}

// --- API Gateway Checks ---

func checkAPIHealth(ctx context.Context, envCfg *config.RLREnvConfig, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_api_health_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the RLR API health endpoint. A healthy response confirms the API Gateway, Lambda authorizer, and routing are all functional.",
			"pass_criteria": "PASS: HTTP 200 with healthy status. FAIL: Non-200 or unhealthy. SKIP: Endpoint not configured.",
			"region":        region,
		},
	}

	if envCfg.APIEndpointPattern == "" {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] No api_endpoint_pattern configured", region)
		return r
	}

	endpoint := strings.ReplaceAll(envCfg.APIEndpointPattern, "${region}", region)
	healthURL := endpoint + "/api/v1/health"
	r.Details["url"] = healthURL

	httpClient := &http.Client{Timeout: 10 * time.Second}
	req, reqErr := http.NewRequestWithContext(ctx, "GET", healthURL, nil)
	if reqErr != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Invalid health URL: %v", region, reqErr)
		return r
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("[%s] API health check failed: %v", region, err)
		return r
	}
	defer resp.Body.Close()

	r.Details["status_code"] = resp.StatusCode

	if resp.StatusCode == 200 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] API healthy (HTTP %d)", region, resp.StatusCode)
	} else {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("[%s] API unhealthy — HTTP %d", region, resp.StatusCode)
	}
	return r
}

func checkAPIDataTraceDisabled(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_api_data_trace_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Validates that API Gateway data trace is disabled (ROSAENG-61269). When enabled, full request/response bodies including customer log data are written to CloudWatch Logs — a security violation.",
			"pass_criteria": "PASS: dataTraceEnabled=false. FAIL: dataTraceEnabled=true (security violation).",
			"region":        region,
		},
	}

	agClient := apigateway.NewFromConfig(awsCfg)

	apis, err := agClient.GetRestApis(ctx, &apigateway.GetRestApisInput{})
	if err != nil {
		cc.RecordError("API Gateway GetRestApis: "+region, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot list API Gateway REST APIs: %v", region, err)
		return r
	}

	// Find the RLR API by name pattern
	var apiID string
	for _, api := range apis.Items {
		if api.Name != nil && strings.Contains(strings.ToLower(*api.Name), "hcp-log") {
			apiID = *api.Id
			r.Details["api_name"] = *api.Name
			r.Details["api_id"] = apiID
			break
		}
	}

	if apiID == "" {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] No RLR API Gateway found", region)
		return r
	}

	stages, err := agClient.GetStages(ctx, &apigateway.GetStagesInput{
		RestApiId: aws.String(apiID),
	})
	if err != nil {
		cc.RecordError("API Gateway GetStages: "+region, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot get API stages: %v", region, err)
		return r
	}

	dataTraceFound := false
	for _, stage := range stages.Item {
		if stage.MethodSettings != nil {
			for path, settings := range stage.MethodSettings {
				if settings.DataTraceEnabled {
					dataTraceFound = true
					r.Details["violating_stage"] = *stage.StageName
					r.Details["violating_path"] = path
				}
			}
		}
	}

	if dataTraceFound {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("[%s] DATA TRACE ENABLED — customer log data being written to CloudWatch (ROSAENG-61269)", region)
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] Data trace disabled — no security violation", region)
	}
	return r
}

func checkAuthorizerCacheDisabled(ctx context.Context, cc *checks.ClusterContext, envCfg *config.RLREnvConfig, awsCfg aws.Config, region string) checks.Result {
	checkName := fmt.Sprintf("rlr_authorizer_cache_%s", region)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates that the API Gateway authorizer cache TTL is 0 (ROSAENG-61267). A non-zero TTL means subsequent requests may bypass body validation, allowing invalid payloads through.",
			"pass_criteria": "PASS: TTL=0 (no caching). FAIL: TTL>0 (requests bypass validation).",
			"region":        region,
		},
	}

	agClient := apigateway.NewFromConfig(awsCfg)

	apis, err := agClient.GetRestApis(ctx, &apigateway.GetRestApisInput{})
	if err != nil {
		cc.RecordError("API Gateway GetRestApis for authorizer: "+region, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot list API Gateway REST APIs: %v", region, err)
		return r
	}

	var apiID string
	for _, api := range apis.Items {
		if api.Name != nil && strings.Contains(strings.ToLower(*api.Name), "hcp-log") {
			apiID = *api.Id
			break
		}
	}

	if apiID == "" {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] No RLR API Gateway found", region)
		return r
	}

	authorizers, err := agClient.GetAuthorizers(ctx, &apigateway.GetAuthorizersInput{
		RestApiId: aws.String(apiID),
	})
	if err != nil {
		cc.RecordError("API Gateway GetAuthorizers: "+region, err)
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] Cannot get authorizers: %v", region, err)
		return r
	}

	cacheViolation := false
	for _, auth := range authorizers.Items {
		ttl := int32(0)
		if auth.AuthorizerResultTtlInSeconds != nil {
			ttl = *auth.AuthorizerResultTtlInSeconds
		}
		r.Details["authorizer_name"] = *auth.Name
		r.Details["authorizer_ttl_seconds"] = ttl

		if ttl > 0 {
			cacheViolation = true
			r.Details["violating_authorizer"] = *auth.Name
		}
	}

	if cacheViolation {
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("[%s] Authorizer cache ENABLED (TTL>0) — requests bypass body validation (ROSAENG-61267)", region)
	} else if len(authorizers.Items) == 0 {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("[%s] No authorizers found on the API", region)
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("[%s] Authorizer cache disabled (TTL=0)", region)
	}
	return r
}

// --- Vector Batch Config (MC-side) ---

func checkVectorBatchConfig(ctx context.Context, cc *checks.ClusterContext) checks.Result {
	r := checks.Result{
		Check:    "rlr_vector_batch_config",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Reads Vector ConfigMap batch settings. A timeout_secs <60 or max_bytes <10MB can cause a 3.7x S3 cost spike (July 2026 incident) due to excessive small object writes.",
			"pass_criteria": "PASS: timeout_secs >=60 AND max_bytes >=10MB. WARN: below thresholds (cost risk). SKIP: ConfigMap not found.",
		},
	}

	configMapNames := []string{"control-plane-log-forwarding", "vector-config", "control-plane-log-forwarding-config"}
	var configData string

	for _, name := range configMapNames {
		cm, err := cc.Client.Clientset().CoreV1().ConfigMaps(vectorNS).Get(ctx, name, metav1.GetOptions{})
		if err == nil {
			for _, v := range cm.Data {
				configData = v
				r.Details["configmap_name"] = name
				break
			}
			break
		}
		if checks.IsAccessError(err) {
			r.Status = checks.StatusAccessDenied
			r.Message = "Cannot access Vector ConfigMap — insufficient permissions"
			return r
		}
	}

	if configData == "" {
		r.Status = checks.StatusSkip
		r.Message = "Vector ConfigMap not found or empty"
		return r
	}

	issues := []string{}

	// Extract batch.timeout_secs
	timeoutSecs := extractConfigInt(configData, "timeout_secs")
	if timeoutSecs > 0 {
		r.Details["batch_timeout_secs"] = timeoutSecs
		if timeoutSecs < 60 {
			issues = append(issues, fmt.Sprintf("timeout_secs=%d (<60 — cost risk)", timeoutSecs))
		}
	}

	// Extract batch.max_bytes
	maxBytes := extractConfigInt(configData, "max_bytes")
	if maxBytes > 0 {
		r.Details["batch_max_bytes"] = maxBytes
		r.Details["batch_max_mb"] = maxBytes / (1024 * 1024)
		if maxBytes < 10485760 {
			issues = append(issues, fmt.Sprintf("max_bytes=%d (<10MB — cost risk)", maxBytes))
		}
	}

	// Extract max_size (buffer)
	maxSize := extractConfigInt(configData, "max_size")
	if maxSize > 0 {
		r.Details["buffer_max_size"] = maxSize
	}

	if len(issues) > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Batch config concerns: %s", strings.Join(issues, "; "))
	} else if timeoutSecs > 0 || maxBytes > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Batch config healthy — timeout_secs=%d, max_bytes=%d", timeoutSecs, maxBytes)
	} else {
		r.Status = checks.StatusInfo
		r.Message = "Batch config values not found in ConfigMap — may use defaults"
	}
	return r
}

// --- Helpers ---

func resolveQueueURL(ctx context.Context, client *sqs.Client, queueName string) (string, error) {
	out, err := client.GetQueueUrl(ctx, &sqs.GetQueueUrlInput{
		QueueName: aws.String(queueName),
	})
	if err != nil {
		return "", err
	}
	if out.QueueUrl == nil {
		return "", fmt.Errorf("queue URL is nil for %s", queueName)
	}
	return *out.QueueUrl, nil
}

func parseAttrInt(attrs map[string]string, key string) int64 {
	v, ok := attrs[key]
	if !ok {
		return 0
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0
	}
	return n
}

func getLambdaMetricSum(ctx context.Context, cwClient *cloudwatch.Client, funcName, metricName, region string, windowMinutes int) (float64, error) {
	now := time.Now()
	start := now.Add(-time.Duration(windowMinutes) * time.Minute)

	input := &cloudwatch.GetMetricStatisticsInput{
		Namespace:  aws.String("AWS/Lambda"),
		MetricName: aws.String(metricName),
		Dimensions: []cwtypes.Dimension{{
			Name:  aws.String("FunctionName"),
			Value: aws.String(funcName),
		}},
		StartTime:  &start,
		EndTime:    &now,
		Period:     aws.Int32(int32(windowMinutes * 60)),
		Statistics: []cwtypes.Statistic{cwtypes.StatisticSum},
	}

	resp, err := cwClient.GetMetricStatistics(ctx, input)
	if err != nil {
		return 0, err
	}

	var total float64
	for _, dp := range resp.Datapoints {
		if dp.Sum != nil {
			total += *dp.Sum
		}
	}
	return total, nil
}

func humanDuration(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
	hours := d.Hours()
	if hours < 24 {
		return fmt.Sprintf("%.1fh", hours)
	}
	return fmt.Sprintf("%.1fd", hours/24)
}

func extractConfigInt(config, key string) int64 {
	lines := strings.Split(config, "\n")
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, key) {
			parts := strings.SplitN(trimmed, ":", 2)
			if len(parts) == 2 {
				val := strings.TrimSpace(parts[1])
				if n, err := strconv.ParseInt(val, 10, 64); err == nil {
					return n
				}
			}
			parts = strings.SplitN(trimmed, "=", 2)
			if len(parts) == 2 {
				val := strings.TrimSpace(parts[1])
				if n, err := strconv.ParseInt(val, 10, 64); err == nil {
					return n
				}
			}
		}
	}
	return 0
}
