package rlr

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/thanos"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func init() {
	checks.Register(&RLRChecker{})
}

type RLRChecker struct{}

func (c *RLRChecker) Name() string { return "rlr" }

const (
	vectorNS        = "hypershift-control-plane-log-forwarding"
	loggingNS       = "logging"
	vectorDS        = "control-plane-log-forwarding"
	heartbeatDeploy = "vector-heartbeat"
	processorDeploy = "log-processor"
	bufferMaxBytes  = 10737418240 // 10 GB
	bufferWarnBytes = 7516192768  // 7 GB (70%)
	bufferCritBytes = 10200547328 // 9.5 GB (95%)
)

// ExpectedVectorImage is the expected Vector container image from the OSDFM
// deploy config, set once per run by main.go. Empty if unavailable.
var ExpectedVectorImage string

var (
	prometheusRuleGVR = schema.GroupVersionResource{
		Group: "monitoring.coreos.com", Version: "v1", Resource: "prometheusrules",
	}
	hostedClusterGVR = schema.GroupVersionResource{
		Group: "hypershift.openshift.io", Version: "v1beta1", Resource: "hostedclusters",
	}
)

func (c *RLRChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	if cc.ClusterType == "management_cluster" {
		c.runMCChecks(ctx, cc)
	} else if cc.Metadata != nil && cc.Metadata.Hypershift {
		c.runHCPChecks(ctx, cc)
	}
}

func (c *RLRChecker) runHCPChecks(ctx context.Context, cc *checks.ClusterContext) {
	checkHCPLogForwardingStatus(ctx, cc)
	checkHCPLogCollector(ctx, cc)
	checkHCPLogCollectorPods(ctx, cc)
	checkHCPLogDeliveryMetrics(ctx, cc)
}

func (c *RLRChecker) runMCChecks(ctx context.Context, cc *checks.ClusterContext) {

	// Vector Collector
	checkVectorNamespace(ctx, cc)
	checkVectorDaemonSetHealth(ctx, cc)
	checkVectorVersionVerification(ctx, cc)
	checkVectorPodRestarts(ctx, cc)
	checkVectorMetricsPresent(ctx, cc)
	checkVectorIngestionRate(ctx, cc)
	checkVectorS3Delivery(ctx, cc)
	checkVectorBufferUsage(ctx, cc)
	checkVectorErrorRate(ctx, cc)
	checkVectorEventLoss(ctx, cc)
	checkVectorPipelineRatio(ctx, cc)

	// Vector Config & Pipeline Analysis
	checkVectorConfigTracking(ctx, cc)
	checkVectorDaemonSetRollout(ctx, cc)
	checkVectorBufferEvents(ctx, cc)
	checkVectorComponentThroughput(ctx, cc)
	checkVectorComponentUtilization(ctx, cc)
	checkVectorIngestionBalance(ctx, cc)
	checkVectorS3RequestLatency(ctx, cc)

	// Heartbeat
	checkHeartbeatDeployment(ctx, cc)
	checkHeartbeatPodHealth(ctx, cc)

	// Log Processor
	checkProcessorDeployment(ctx, cc)
	checkProcessorPodHealth(ctx, cc)

	// PrometheusRule & Alerts
	checkPrometheusRuleExists(ctx, cc)
	checkPrometheusRuleAlerts(ctx, cc)
	checkActiveAlerts(ctx, cc)

	// Timeseries (7-day trends for charts)
	collectVectorTimeseries(ctx, cc)
}

func sanitizeFloat(f float64) float64 {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return 0
	}
	return f
}

// --- Vector Collector Checks ---

func checkVectorNamespace(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_namespace")

	r := checks.Result{
		Check:    "rlr_vector_namespace",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Validates the HCP log forwarding namespace exists and is Active. This namespace hosts the Vector DaemonSet that collects HCP control plane logs and writes them to the central S3 bucket for rosa-log-router delivery. Separate from the RHOBS Vector in openshift-logging.",
			"pass_criteria": "PASS: Namespace Active. FAIL: Not found or Terminating.",
		},
	}

	phase, err := cc.Client.GetNamespacePhase(ctx, vectorNS)
	cc.RecordError("Get Vector namespace", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Namespace %s not found — Vector log forwarding not deployed", vectorNS)
		cc.AddResult(r)
		return
	}

	r.Details["phase"] = phase
	if phase == "Active" {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Namespace %s is Active", vectorNS)
	} else {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Namespace %s is %s", vectorNS, phase)
	}
	cc.AddResult(r)
}

func checkVectorDaemonSetHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_daemonset_health")

	r := checks.Result{
		Check:    "rlr_vector_daemonset_health",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"namespace":     vectorNS,
			"daemonset":     vectorDS,
			"description":   "Validates the HCP log forwarding Vector DaemonSet is healthy with all pods scheduled and ready. Each pod has its own disk buffer, S3 sink, and backpressure state. Separate from the RHOBS Vector in openshift-logging.",
			"pass_criteria": "PASS: desired==ready, 0 misscheduled, no CrashLoopBackOff. WARN: Not all ready or crashlooping pods. FAIL: DaemonSet not found.",
		},
	}

	// Try known DaemonSet names — OSDFM uses "control-plane-log-forwarding", standalone uses "vector-logs"
	var ds *appsv1.DaemonSet
	dsNames := []string{vectorDS, "vector-logs"}
	for _, name := range dsNames {
		candidate, err := cc.Client.Clientset().AppsV1().DaemonSets(vectorNS).Get(ctx, name, metav1.GetOptions{})
		if err == nil {
			ds = candidate
			break
		}
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
	}

	if ds == nil {
		// Try listing all DaemonSets in the namespace as fallback
		dsList, listErr := cc.Client.Clientset().AppsV1().DaemonSets(vectorNS).List(ctx, metav1.ListOptions{})
		cc.RecordError("List Vector DaemonSets", listErr)
		if listErr == nil && len(dsList.Items) > 0 {
			ds = &dsList.Items[0]
		}
	}

	if ds == nil {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("No DaemonSets found in %s", vectorNS)
		cc.AddResult(r)
		return
	}

	r.Details["daemonset"] = ds.Name

	desired := ds.Status.DesiredNumberScheduled
	ready := ds.Status.NumberReady
	misscheduled := ds.Status.NumberMisscheduled

	r.Details["desired"] = desired
	r.Details["ready"] = ready
	r.Details["misscheduled"] = misscheduled
	r.Details["updated"] = ds.Status.UpdatedNumberScheduled

	// Check for crashlooping pods
	pods, podErr := cc.Client.GetPods(ctx, vectorNS, "")
	crashlooping := 0
	if podErr == nil {
		for _, pod := range pods.Items {
			for _, cs := range pod.Status.ContainerStatuses {
				if cs.State.Waiting != nil && cs.State.Waiting.Reason == "CrashLoopBackOff" {
					crashlooping++
				}
			}
		}
		if problematic := checks.ProblematicPods(pods.Items); len(problematic) > 0 {
			r.Details["failing_pods"] = problematic
		}
	}
	r.Details["crashlooping_pods"] = crashlooping

	if ready == desired && misscheduled == 0 && desired > 0 && crashlooping == 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Vector DaemonSet healthy — %d/%d ready", ready, desired)
	} else if desired == 0 {
		r.Status = checks.StatusWarning
		r.Severity = checks.SeverityWarning
		r.Message = fmt.Sprintf("Vector DaemonSet has 0 desired pods")
	} else {
		r.Status = checks.StatusWarning
		r.Severity = checks.SeverityWarning
		parts := []string{fmt.Sprintf("%d/%d ready", ready, desired)}
		if misscheduled > 0 {
			parts = append(parts, fmt.Sprintf("%d misscheduled", misscheduled))
		}
		if crashlooping > 0 {
			parts = append(parts, fmt.Sprintf("%d crashlooping", crashlooping))
		}
		r.Message = fmt.Sprintf("Vector DaemonSet degraded — %s", strings.Join(parts, ", "))
	}
	cc.AddResult(r)
}

func checkVectorVersionVerification(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_version_verification")

	r := checks.Result{
		Check:    "rlr_version_verification",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Compares the running Vector container image against the expected version from the OSDFM deploy config in app-interface. A mismatch means the cluster is running an unexpected version — either a rollout is in progress, OSDFM hasn't reconciled, or the DaemonSet was manually modified.",
			"pass_criteria": "PASS: deployed image matches expected. WARN: version mismatch. INFO: expected version unavailable (GitLab fetch failed).",
		},
	}

	// Fetch the DaemonSet to get the running image
	var ds *appsv1.DaemonSet
	for _, name := range []string{vectorDS, "vector-logs"} {
		candidate, err := cc.Client.Clientset().AppsV1().DaemonSets(vectorNS).Get(ctx, name, metav1.GetOptions{})
		if err == nil {
			ds = candidate
			break
		}
	}

	deployedImage := ""
	if ds != nil && len(ds.Spec.Template.Spec.Containers) > 0 {
		deployedImage = ds.Spec.Template.Spec.Containers[0].Image
	}
	r.Details["deployed_image"] = deployedImage

	if deployedImage == "" {
		r.Status = checks.StatusSkip
		r.Message = "Could not determine deployed Vector image"
		cc.AddResult(r)
		return
	}

	if ExpectedVectorImage == "" {
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("Running %s — expected version unavailable (OSDFM config not fetched)", deployedImage)
		cc.AddResult(r)
		return
	}

	r.Details["expected_image"] = ExpectedVectorImage

	if deployedImage == ExpectedVectorImage {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Image matches OSDFM config: %s", deployedImage)
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Image mismatch — running %s, expected %s", deployedImage, ExpectedVectorImage)
	}

	cc.AddResult(r)
}

func checkVectorPodRestarts(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_pod_restarts")

	r := checks.Result{
		Check:    "rlr_vector_pod_restarts",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Checks cumulative restart count across all Vector pods. High restarts may indicate OOM kills, configuration errors, or S3 connectivity issues.",
			"pass_criteria": "PASS: total restarts <=10. WARN: >10 restarts. SKIP: no pods found.",
		},
	}

	pods, err := cc.Client.GetPods(ctx, vectorNS, "")
	cc.RecordError("List Vector pods", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot list pods in %s: %v", vectorNS, err)
		cc.AddResult(r)
		return
	}

	totalRestarts := int32(0)
	podCount := 0
	maxRestartPod := ""
	maxRestarts := int32(0)

	for _, pod := range pods.Items {
		podCount++
		for _, cs := range pod.Status.ContainerStatuses {
			totalRestarts += cs.RestartCount
			if cs.RestartCount > maxRestarts {
				maxRestarts = cs.RestartCount
				maxRestartPod = pod.Name
			}
		}
	}

	r.Details["total_restarts"] = totalRestarts
	r.Details["pod_count"] = podCount
	if maxRestartPod != "" {
		r.Details["max_restart_pod"] = maxRestartPod
		r.Details["max_restart_count"] = maxRestarts
	}
	if problematic := checks.ProblematicPods(pods.Items); len(problematic) > 0 {
		r.Details["failing_pods"] = problematic
	}

	if podCount == 0 {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("No pods found in %s", vectorNS)
	} else if totalRestarts <= 10 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d total restarts across %d pods", totalRestarts, podCount)
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d total restarts across %d pods (max: %s with %d)", totalRestarts, podCount, maxRestartPod, maxRestarts)
	}
	cc.AddResult(r)
}

func checkVectorMetricsPresent(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_metrics_present")

	r := checks.Result{
		Check:    "rlr_vector_metrics_present",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Validates that Vector metrics are being scraped by Prometheus. Checks the 'up' metric for the Vector scrape job.",
			"pass_criteria": "PASS: Metrics found. WARN: No metrics scraped. SKIP: Elevation unavailable.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := `up{job=~".*control-plane-log-forwarding.*"}`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query Vector up metric", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if thanos.HasResults(body) {
		resp, _ := thanos.Parse(body)
		upCount := 0
		downCount := 0
		for _, result := range resp.Data.Result {
			val, ok := thanos.ToFloat(result)
			if ok && val == 1 {
				upCount++
			} else {
				downCount++
			}
		}
		r.Details["targets_up"] = upCount
		r.Details["targets_down"] = downCount
		if downCount == 0 && upCount > 0 {
			r.Status = checks.StatusPass
			r.Message = fmt.Sprintf("Vector metrics scraped — %d targets up", upCount)
		} else if upCount > 0 {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("Vector metrics partially scraped — %d up, %d down", upCount, downCount)
		} else {
			r.Status = checks.StatusWarning
			r.Message = "Vector scrape targets found but all report down"
		}
	} else {
		r.Status = checks.StatusWarning
		r.Message = "No Vector scrape targets found — metrics may not be configured"
	}
	cc.AddResult(r)
}

func checkVectorIngestionRate(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_ingestion_rate")

	r := checks.Result{
		Check:    "rlr_vector_ingestion_rate",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Checks the Vector log ingestion rate using the vector:logs:ingestion_rate recording rule. Zero ingestion with active HCPs indicates Vector is not collecting logs.",
			"pass_criteria": "PASS: >0 events/sec (or 0 with 0 HCPs). WARN: 0 events/sec with HCPs present. SKIP: Recording rule not found or elevation unavailable.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := `vector:logs:ingestion_rate`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query Vector ingestion rate", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(body) {
		r.Status = checks.StatusSkip
		r.Message = "Recording rule vector:logs:ingestion_rate not found — PrometheusRule may not be deployed"
		cc.AddResult(r)
		return
	}

	rate, ok := thanos.InstantFloat(body)
	if !ok {
		r.Status = checks.StatusUnknown
		r.Message = "Could not parse ingestion rate value"
		cc.AddResult(r)
		return
	}

	r.Details["ingestion_rate_events_per_sec"] = thanos.Round(sanitizeFloat(rate), 2)

	// Count HCPs to contextualize zero ingestion
	hcpCount := 0
	hcpList, hcpErr := cc.Client.ListResources(ctx, hostedClusterGVR, "", true)
	if hcpErr == nil && hcpList != nil {
		hcpCount = len(hcpList.Items)
	}
	r.Details["hosted_cluster_count"] = hcpCount

	if rate > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Ingesting %.1f events/sec across %d HCPs", rate, hcpCount)
	} else if hcpCount == 0 {
		r.Status = checks.StatusPass
		r.Message = "Zero ingestion rate — expected with 0 hosted clusters"
	} else {
		r.Status = checks.StatusWarning
		r.Severity = checks.SeverityWarning
		r.Message = fmt.Sprintf("Zero ingestion rate with %d hosted clusters — Vector may not be collecting logs", hcpCount)
	}
	cc.AddResult(r)
}

func checkVectorS3Delivery(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_s3_delivery")

	r := checks.Result{
		Check:    "rlr_vector_s3_delivery",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Checks the Vector S3 sink write ratio. A value of 1.0 means Vector is keeping up with log delivery. Below 1.0 indicates backpressure — logs are buffering faster than they're being written to S3.",
			"pass_criteria": "PASS: write_ratio >=0.99. WARN: <0.99 (backpressure). SKIP: Recording rule not found.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := `vector:s3_sink:write_ratio`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query Vector S3 write ratio", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(body) {
		r.Status = checks.StatusSkip
		r.Message = "Recording rule vector:s3_sink:write_ratio not found"
		cc.AddResult(r)
		return
	}

	ratio, ok := thanos.InstantFloat(body)
	if !ok {
		r.Status = checks.StatusUnknown
		r.Message = "Could not parse write ratio value"
		cc.AddResult(r)
		return
	}

	r.Details["write_ratio"] = thanos.Round(sanitizeFloat(ratio), 4)

	if ratio >= 0.99 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("S3 write ratio %.4f — Vector keeping up with delivery", ratio)
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("S3 write ratio %.4f — backpressure detected, logs buffering", ratio)
	}
	cc.AddResult(r)
}

func checkVectorBufferUsage(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_buffer_usage")

	r := checks.Result{
		Check:    "rlr_vector_buffer_usage",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":      vectorNS,
			"max_bytes":      bufferMaxBytes,
			"warn_threshold": bufferWarnBytes,
			"description":    "Checks the Vector disk buffer size for HCP logs. Buffer grows when S3 delivery is slower than ingestion. At capacity (10GB), logs are dropped.",
			"pass_criteria":  "PASS: <7GB (70%). WARN: >=7GB. FAIL: >=9.5GB (95%). SKIP: Metric not found.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := `max(vector_buffer_byte_size{buffer_id="hcp_logs"})`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query Vector buffer size", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(body) {
		r.Status = checks.StatusSkip
		r.Message = "Buffer metric vector_buffer_byte_size not found"
		cc.AddResult(r)
		return
	}

	bytes, ok := thanos.InstantFloat(body)
	if !ok {
		r.Status = checks.StatusUnknown
		r.Message = "Could not parse buffer size value"
		cc.AddResult(r)
		return
	}

	usagePct := (bytes / float64(bufferMaxBytes)) * 100
	r.Details["current_bytes"] = int64(bytes)
	r.Details["usage_percent"] = thanos.Round(sanitizeFloat(usagePct), 1)

	mb := bytes / (1024 * 1024)
	if bytes >= bufferCritBytes {
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("Buffer critically full — %.0f MB (%.1f%%) — log loss imminent", mb, usagePct)
	} else if bytes >= float64(bufferWarnBytes) {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Buffer elevated — %.0f MB (%.1f%%) of 10 GB", mb, usagePct)
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Buffer healthy — %.0f MB (%.1f%%) of 10 GB", mb, usagePct)
	}
	cc.AddResult(r)
}

func checkVectorErrorRate(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_error_rate")

	r := checks.Result{
		Check:    "rlr_vector_error_rate",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Checks Vector S3 API error rate and VRL transform error rate. Non-zero rates indicate delivery failures or log parsing issues.",
			"pass_criteria": "PASS: Both rates ==0. WARN: Either rate >0. SKIP: Recording rules not found.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	s3Query := `vector:s3:error_rate`
	s3Body, s3Err := cc.Client.QueryMetrics(ctx, s3Query)
	cc.RecordError("Query Vector S3 error rate", s3Err)

	transformQuery := `sum(vector:transform:error_rate:by_component)`
	transformBody, transformErr := cc.Client.QueryMetrics(ctx, transformQuery)
	cc.RecordError("Query Vector transform error rate", transformErr)

	if s3Err != nil && transformErr != nil {
		if checks.IsAccessError(s3Err) || checks.IsAccessError(transformErr) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = "Thanos queries failed for error rates"
		cc.AddResult(r)
		return
	}

	s3Rate := 0.0
	transformRate := 0.0

	// Empty results from error rate queries means zero errors (healthy).
	// The PromQL expressions evaluate to empty when error counters are 0.
	if s3Err == nil && thanos.HasResults(s3Body) {
		if v, ok := thanos.InstantFloat(s3Body); ok {
			s3Rate = v
		}
	}
	if transformErr == nil && thanos.HasResults(transformBody) {
		if v, ok := thanos.InstantFloat(transformBody); ok {
			transformRate = v
		}
	}

	r.Details["s3_error_rate"] = thanos.Round(sanitizeFloat(s3Rate), 4)
	r.Details["transform_error_rate"] = thanos.Round(sanitizeFloat(transformRate), 4)

	if s3Rate == 0 && transformRate == 0 {
		r.Status = checks.StatusPass
		r.Message = "No S3 or transform errors"
	} else {
		r.Status = checks.StatusWarning
		parts := []string{}
		if s3Rate > 0 {
			parts = append(parts, fmt.Sprintf("S3 errors: %.4f/sec", s3Rate))
		}
		if transformRate > 0 {
			parts = append(parts, fmt.Sprintf("transform errors: %.4f/sec", transformRate))
		}
		r.Message = fmt.Sprintf("Errors detected — %s", strings.Join(parts, ", "))
	}
	cc.AddResult(r)
}

func checkVectorEventLoss(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_event_loss")

	r := checks.Result{
		Check:    "rlr_vector_event_loss",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Checks for active event loss in the Vector pipeline. A positive loss rate means customer logs are being dropped between ingestion and S3 delivery.",
			"pass_criteria": "PASS: Loss rate <=0. FAIL: Loss rate >0 (logs being dropped). SKIP: Recording rule not found.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := `max(clamp_min(vector:hcp_logs:event_loss_rate:by_pod, 0))`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query Vector event loss rate", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(body) {
		r.Status = checks.StatusSkip
		r.Message = "Recording rule vector:hcp_logs:event_loss_rate:by_pod not found"
		cc.AddResult(r)
		return
	}

	lossRate, ok := thanos.InstantFloat(body)
	if !ok {
		r.Status = checks.StatusUnknown
		r.Message = "Could not parse event loss rate value"
		cc.AddResult(r)
		return
	}

	r.Details["event_loss_rate"] = thanos.Round(sanitizeFloat(lossRate), 4)

	if lossRate <= 0 {
		r.Status = checks.StatusPass
		r.Message = "No event loss detected"
	} else {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Active event loss — %.4f events/sec being dropped", lossRate)
	}
	cc.AddResult(r)
}

func checkVectorPipelineRatio(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_pipeline_ratio")

	r := checks.Result{
		Check:    "rlr_vector_pipeline_ratio",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Checks the per-cluster pipeline ratio (events out / events in). Values near 1.0 mean the transform pipeline is processing without loss. Below 0.99 indicates transform errors or filtering anomalies.",
			"pass_criteria": "PASS: min ratio >=0.99. WARN: any cluster <0.99. SKIP: Recording rule not found.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := `vector:log_delivery:pipeline_ratio:by_cluster`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query Vector pipeline ratio", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(body) {
		r.Status = checks.StatusSkip
		r.Message = "Recording rule vector:log_delivery:pipeline_ratio:by_cluster not found"
		cc.AddResult(r)
		return
	}

	resp, _ := thanos.Parse(body)
	minRatio := 1.0
	clusterCount := 0
	degradedClusters := []string{}

	for _, result := range resp.Data.Result {
		val, ok := thanos.ToFloat(result)
		if !ok {
			continue
		}
		clusterCount++
		if val < minRatio {
			minRatio = val
		}
		if val < 0.99 {
			clusterID := result.Metric["cluster_id"]
			if clusterID == "" {
				clusterID = "unknown"
			}
			degradedClusters = append(degradedClusters, fmt.Sprintf("%s (%.4f)", clusterID, val))
		}
	}

	r.Details["cluster_count"] = clusterCount
	r.Details["min_ratio"] = thanos.Round(sanitizeFloat(minRatio), 4)
	if len(degradedClusters) > 0 {
		r.Details["degraded_clusters"] = degradedClusters
	}

	if minRatio >= 0.99 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Pipeline healthy — min ratio %.4f across %d clusters", minRatio, clusterCount)
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Pipeline degraded — %d clusters below 0.99 (min: %.4f)", len(degradedClusters), minRatio)
	}
	cc.AddResult(r)
}

// --- Vector Config & Pipeline Analysis Checks ---

func checkVectorConfigTracking(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_config_tracking")

	r := checks.Result{
		Check:    "rlr_vector_config_tracking",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Tracks the deployed Vector ConfigMap content hash and key configuration parameters. Enables before/after comparison when OSDFM deploys config changes (e.g., concurrency limits, buffer settings, transform optimizations).",
			"pass_criteria": "PASS: ConfigMap found with content hash. WARN: ConfigMap empty. SKIP: ConfigMap not found.",
		},
	}

	configMapNames := []string{"control-plane-log-forwarding", "vector-config", "control-plane-log-forwarding-config"}
	var cm *corev1.ConfigMap

	for _, name := range configMapNames {
		candidate, err := cc.Client.Clientset().CoreV1().ConfigMaps(vectorNS).Get(ctx, name, metav1.GetOptions{})
		if err == nil {
			cm = candidate
			break
		}
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
	}

	if cm == nil {
		r.Status = checks.StatusSkip
		r.Message = "Vector ConfigMap not found — OSDFM may inject config via DaemonSet spec"
		cc.AddResult(r)
		return
	}

	r.Details["configmap_name"] = cm.Name
	r.Details["resource_version"] = cm.ResourceVersion

	keys := make([]string, 0, len(cm.Data))
	totalSize := 0
	var contentBuilder strings.Builder
	for k, v := range cm.Data {
		keys = append(keys, k)
		totalSize += len(v)
		contentBuilder.WriteString(v)
	}
	sort.Strings(keys)
	r.Details["data_keys"] = keys
	r.Details["config_size_bytes"] = totalSize

	if totalSize == 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("ConfigMap %s exists but has no data", cm.Name)
		cc.AddResult(r)
		return
	}

	hash := sha256.Sum256([]byte(contentBuilder.String()))
	r.Details["config_hash"] = hex.EncodeToString(hash[:])

	// Extract key config parameters via simple pattern matching
	fullConfig := contentBuilder.String()
	concurrencyRe := regexp.MustCompile(`(?:max_)?concurrency(?:_limit)?\s*[:=]\s*(\d+)`)
	if m := concurrencyRe.FindStringSubmatch(fullConfig); len(m) > 1 {
		r.Details["s3_concurrency"] = m[1]
	}
	if strings.Contains(fullConfig, "oldest_first") {
		oldestFirstRe := regexp.MustCompile(`oldest_first\s*[:=]\s*(true|false)`)
		if m := oldestFirstRe.FindStringSubmatch(fullConfig); len(m) > 1 {
			r.Details["oldest_first"] = m[1]
		}
	}
	bufferMaxRe := regexp.MustCompile(`max_size\s*[:=]\s*(\d+)`)
	if m := bufferMaxRe.FindStringSubmatch(fullConfig); len(m) > 1 {
		r.Details["buffer_max_size"] = m[1]
	}

	r.Status = checks.StatusPass
	r.Message = fmt.Sprintf("ConfigMap %s tracked — hash %s, %d bytes", cm.Name, hex.EncodeToString(hash[:8]), totalSize)
	cc.AddResult(r)
}

func checkVectorDaemonSetRollout(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_daemonset_rollout")

	r := checks.Result{
		Check:    "rlr_vector_daemonset_rollout",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Detects whether a Vector DaemonSet rollout is in progress or stuck by comparing generation vs observedGeneration and updated vs desired pod counts. After config changes, all pods must pick up the new config.",
			"pass_criteria": "PASS: Rollout complete (generation matches, all pods updated). WARN: Rollout in progress or possibly stuck.",
		},
	}

	var ds *appsv1.DaemonSet
	for _, name := range []string{vectorDS, "vector-logs"} {
		candidate, err := cc.Client.Clientset().AppsV1().DaemonSets(vectorNS).Get(ctx, name, metav1.GetOptions{})
		if err == nil {
			ds = candidate
			break
		}
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
	}

	if ds == nil {
		r.Status = checks.StatusSkip
		r.Message = "Vector DaemonSet not found"
		cc.AddResult(r)
		return
	}

	gen := ds.Generation
	observedGen := ds.Status.ObservedGeneration
	desired := ds.Status.DesiredNumberScheduled
	updated := ds.Status.UpdatedNumberScheduled
	ready := ds.Status.NumberReady

	r.Details["daemonset"] = ds.Name
	r.Details["generation"] = gen
	r.Details["observed_generation"] = observedGen
	r.Details["desired"] = desired
	r.Details["updated"] = updated
	r.Details["ready"] = ready
	r.Details["pods_pending_update"] = desired - updated

	genMatch := gen == observedGen
	allUpdated := updated == desired && desired > 0
	r.Details["generation_match"] = genMatch

	if genMatch && allUpdated {
		r.Details["rollout_status"] = "complete"
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Rollout complete — %d/%d pods updated, generation %d", updated, desired, gen)
	} else if !genMatch {
		r.Details["rollout_status"] = "in_progress"
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Rollout in progress — generation %d, observed %d, %d/%d updated", gen, observedGen, updated, desired)
	} else {
		r.Details["rollout_status"] = "in_progress"
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Rollout in progress — %d/%d pods updated (%d pending)", updated, desired, desired-updated)
	}
	cc.AddResult(r)
}

func checkVectorBufferEvents(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_buffer_events")

	r := checks.Result{
		Check:    "rlr_vector_buffer_events",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Checks the number of events buffered in Vector's disk buffer (not just byte size). High event counts indicate delivery lag — events are queuing faster than S3 can drain them. Complements the byte-based buffer check with a throughput perspective.",
			"pass_criteria": "PASS: <100k buffered events. WARN: >=100k. FAIL: >=500k. SKIP: Metric not found.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := `sum by (pod) (vector_buffer_events{buffer_id="hcp_logs"})`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query Vector buffer events", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(body) {
		r.Status = checks.StatusSkip
		r.Message = "Metric vector_buffer_events not found — may not be scraped"
		cc.AddResult(r)
		return
	}

	resp, _ := thanos.Parse(body)
	totalEvents := 0.0
	maxPod := ""
	maxEvents := 0.0
	podCount := 0

	for _, result := range resp.Data.Result {
		val, ok := thanos.ToFloat(result)
		if !ok {
			continue
		}
		podCount++
		totalEvents += val
		if val > maxEvents {
			maxEvents = val
			maxPod = result.Metric["pod"]
		}
	}

	r.Details["total_buffered_events"] = int64(totalEvents)
	r.Details["pod_count"] = podCount
	if maxPod != "" {
		r.Details["max_buffered_pod"] = maxPod
		r.Details["max_buffered_events"] = int64(maxEvents)
	}

	if totalEvents >= 500000 {
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("Severe event backlog — %d events buffered across %d pods", int64(totalEvents), podCount)
	} else if totalEvents >= 100000 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Event backlog building — %d events buffered across %d pods", int64(totalEvents), podCount)
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Buffer healthy — %d events across %d pods", int64(totalEvents), podCount)
	}
	cc.AddResult(r)
}

func checkVectorComponentThroughput(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_component_throughput")

	r := checks.Result{
		Check:    "rlr_vector_component_throughput",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Measures per-component event throughput through Vector's transform pipeline. A sent/received ratio below 1.0 indicates events being dropped within a transform stage. Directly validates transform optimizations like the early-exit timestamp regex guard.",
			"pass_criteria": "PASS: All components ratio >=0.99. WARN: Any component <0.99. SKIP: Metrics not scraped.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	sentQuery := `sum by (component_id) (rate(vector_component_sent_events_total[5m]))`
	sentBody, sentErr := cc.Client.QueryMetrics(ctx, sentQuery)
	cc.RecordError("Query Vector component sent events", sentErr)

	if sentErr != nil {
		if checks.IsAccessError(sentErr) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", sentErr)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(sentBody) {
		r.Status = checks.StatusSkip
		r.Message = "Metric vector_component_sent_events_total not found — may not be scraped by ServiceMonitor"
		cc.AddResult(r)
		return
	}

	receivedQuery := `sum by (component_id) (rate(vector_component_received_events_total[5m]))`
	receivedBody, receivedErr := cc.Client.QueryMetrics(ctx, receivedQuery)
	cc.RecordError("Query Vector component received events", receivedErr)

	sentResp, _ := thanos.Parse(sentBody)
	sentMap := make(map[string]float64)
	for _, result := range sentResp.Data.Result {
		val, ok := thanos.ToFloat(result)
		if !ok {
			continue
		}
		sentMap[result.Metric["component_id"]] = val
	}

	receivedMap := make(map[string]float64)
	if receivedErr == nil && thanos.HasResults(receivedBody) {
		receivedResp, _ := thanos.Parse(receivedBody)
		for _, result := range receivedResp.Data.Result {
			val, ok := thanos.ToFloat(result)
			if !ok {
				continue
			}
			receivedMap[result.Metric["component_id"]] = val
		}
	}

	type componentStats struct {
		Sent     float64 `json:"sent_rate"`
		Received float64 `json:"received_rate"`
		Ratio    float64 `json:"ratio"`
	}
	components := make(map[string]componentStats)
	degraded := []string{}

	allIDs := make(map[string]bool)
	for id := range sentMap {
		allIDs[id] = true
	}
	for id := range receivedMap {
		allIDs[id] = true
	}

	// Sinks, sources, and metrics exporters naturally have different in/out ratios —
	// only flag ratio degradation for transform (remap) components
	isTransform := func(id string) bool {
		skip := []string{"prometheus", "output_", "input_", "hcp_logs", "pipeline_"}
		for _, prefix := range skip {
			if strings.HasPrefix(id, prefix) || strings.Contains(id, prefix) {
				return false
			}
		}
		return true
	}

	for id := range allIDs {
		sent := sentMap[id]
		received := receivedMap[id]
		ratio := 1.0
		if received > 0 {
			ratio = sent / received
		}
		cs := componentStats{
			Sent:     thanos.Round(sanitizeFloat(sent), 2),
			Received: thanos.Round(sanitizeFloat(received), 2),
			Ratio:    thanos.Round(sanitizeFloat(ratio), 4),
		}
		components[id] = cs
		if ratio < 0.99 && received > 0 && isTransform(id) {
			degraded = append(degraded, fmt.Sprintf("%s (%.4f)", id, ratio))
		}
	}

	r.Details["components"] = components
	r.Details["component_count"] = len(components)
	if len(degraded) > 0 {
		r.Details["degraded_components"] = degraded
	}

	if len(degraded) > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d component(s) with event loss: %s", len(degraded), strings.Join(degraded, ", "))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d components healthy — no event loss in transforms", len(components))
	}
	cc.AddResult(r)
}

func checkVectorComponentUtilization(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_component_utilization")

	r := checks.Result{
		Check:    "rlr_vector_component_utilization",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Checks Vector component utilization (0.0=idle, 1.0=saturated). Saturated components are pipeline bottlenecks. Directly measures whether transform optimizations, round-robin reading, or S3 concurrency changes relieve bottlenecks.",
			"pass_criteria": "PASS: All <0.80. WARN: Any >=0.80. FAIL: Any >=0.95. SKIP: Metric not found.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := `max by (component_id) (vector_utilization)`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query Vector component utilization", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(body) {
		r.Status = checks.StatusSkip
		r.Message = "Metric vector_utilization not found — may not be exposed by this Vector version"
		cc.AddResult(r)
		return
	}

	resp, _ := thanos.Parse(body)
	utilMap := make(map[string]float64)
	maxUtil := 0.0
	maxComponent := ""
	saturated := []string{}
	critical := []string{}

	for _, result := range resp.Data.Result {
		val, ok := thanos.ToFloat(result)
		if !ok {
			continue
		}
		id := result.Metric["component_id"]
		utilMap[id] = thanos.Round(sanitizeFloat(val), 4)
		if val > maxUtil {
			maxUtil = val
			maxComponent = id
		}
		if val >= 0.95 {
			critical = append(critical, fmt.Sprintf("%s (%.2f)", id, val))
		} else if val >= 0.80 {
			saturated = append(saturated, fmt.Sprintf("%s (%.2f)", id, val))
		}
	}

	r.Details["utilization"] = utilMap
	r.Details["component_count"] = len(utilMap)
	r.Details["max_utilization"] = thanos.Round(sanitizeFloat(maxUtil), 4)
	r.Details["max_component"] = maxComponent
	if len(saturated) > 0 {
		r.Details["saturated_components"] = saturated
	}
	if len(critical) > 0 {
		r.Details["critical_components"] = critical
	}

	if len(critical) > 0 {
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("%d component(s) at critical utilization (>=0.95): %s", len(critical), strings.Join(critical, ", "))
	} else if len(saturated) > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d component(s) approaching saturation (>=0.80): %s", len(saturated), strings.Join(saturated, ", "))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d components below 0.80 utilization (max: %s at %.2f)", len(utilMap), maxComponent, maxUtil)
	}
	cc.AddResult(r)
}

func checkVectorIngestionBalance(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_ingestion_balance")

	r := checks.Result{
		Check:    "rlr_vector_ingestion_balance",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Analyzes per-HCP ingestion rate distribution to detect noisy neighbor scenarios. Uses coefficient of variation (CV) and max share to measure fairness. Round-robin file reading should produce more balanced ingestion vs oldest-first.",
			"pass_criteria": "PASS: CV <1.5. WARN: CV >=1.5 AND top cluster >40% share. SKIP: <3 clusters.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := `vector:cluster:ingestion_rate`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query per-cluster ingestion rate", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(body) {
		r.Status = checks.StatusSkip
		r.Message = "Recording rule vector:cluster:ingestion_rate not found"
		cc.AddResult(r)
		return
	}

	resp, _ := thanos.Parse(body)
	var rates []float64
	var maxRate float64
	var maxCluster string
	var minRate = math.MaxFloat64
	var minCluster string
	total := 0.0

	for _, result := range resp.Data.Result {
		val, ok := thanos.ToFloat(result)
		if !ok || val <= 0 {
			continue
		}
		rates = append(rates, val)
		total += val
		ns := result.Metric["pod_namespace"]
		if ns == "" {
			ns = result.Metric["namespace"]
		}
		if val > maxRate {
			maxRate = val
			maxCluster = ns
		}
		if val < minRate {
			minRate = val
			minCluster = ns
		}
	}

	if len(rates) < 3 {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Only %d clusters reporting — too few for distribution analysis", len(rates))
		cc.AddResult(r)
		return
	}

	mean := total / float64(len(rates))
	var sumSquares float64
	for _, v := range rates {
		sumSquares += (v - mean) * (v - mean)
	}
	stddev := math.Sqrt(sumSquares / float64(len(rates)))
	cv := stddev / mean
	maxSharePct := (maxRate / total) * 100

	r.Details["cluster_count"] = len(rates)
	r.Details["mean_rate"] = thanos.Round(sanitizeFloat(mean), 2)
	r.Details["stddev"] = thanos.Round(sanitizeFloat(stddev), 2)
	r.Details["coefficient_of_variation"] = thanos.Round(sanitizeFloat(cv), 4)
	r.Details["max_rate_cluster"] = maxCluster
	r.Details["max_rate"] = thanos.Round(sanitizeFloat(maxRate), 2)
	r.Details["max_share_percent"] = thanos.Round(sanitizeFloat(maxSharePct), 1)
	r.Details["min_rate_cluster"] = minCluster
	r.Details["min_rate"] = thanos.Round(sanitizeFloat(minRate), 2)

	if cv >= 1.5 && maxSharePct > 40 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Ingestion skewed — %s consumes %.1f%% of total (CV: %.2f across %d clusters)", maxCluster, maxSharePct, cv, len(rates))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Ingestion balanced — CV %.2f across %d clusters (max share: %.1f%%)", cv, len(rates), maxSharePct)
	}
	cc.AddResult(r)
}

func checkVectorS3RequestLatency(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_s3_request_latency")

	r := checks.Result{
		Check:    "rlr_vector_s3_request_latency",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     vectorNS,
			"description":   "Monitors S3 API request latency percentiles. High latency indicates S3 throttling (possibly from increased concurrency) or regional issues. Root cause indicator for write ratio degradation and buffer growth.",
			"pass_criteria": "PASS: p99 <5s AND p50 <1s. WARN: p99 >=5s or p50 >=1s. FAIL: p99 >=15s. SKIP: HTTP client histogram not found.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Try multiple histogram metric names — Vector versions vary
	histogramNames := []string{
		"vector_http_client_response_rtt_seconds_bucket",
		"vector_http_client_responses_duration_seconds_bucket",
	}

	var p99, p50 float64
	var foundMetric string

	for _, metricName := range histogramNames {
		p99Query := fmt.Sprintf(`histogram_quantile(0.99, sum by (le) (rate(%s[5m])))`, metricName)
		p99Body, err := cc.Client.QueryMetrics(ctx, p99Query)
		if err != nil {
			if checks.IsAccessError(err) {
				cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
				return
			}
			continue
		}
		if !thanos.HasResults(p99Body) {
			continue
		}

		val, ok := thanos.InstantFloat(p99Body)
		if !ok {
			continue
		}
		p99 = val
		foundMetric = metricName

		p50Query := fmt.Sprintf(`histogram_quantile(0.50, sum by (le) (rate(%s[5m])))`, metricName)
		p50Body, p50Err := cc.Client.QueryMetrics(ctx, p50Query)
		if p50Err == nil && thanos.HasResults(p50Body) {
			if v, ok := thanos.InstantFloat(p50Body); ok {
				p50 = v
			}
		}
		break
	}

	if foundMetric == "" {
		r.Status = checks.StatusSkip
		r.Message = "HTTP client histogram metrics not found — Vector may not expose S3 request latency"
		cc.AddResult(r)
		return
	}

	r.Details["metric"] = foundMetric
	r.Details["p99_seconds"] = thanos.Round(sanitizeFloat(p99), 3)
	r.Details["p50_seconds"] = thanos.Round(sanitizeFloat(p50), 3)

	if p99 >= 15 {
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("S3 latency critical — p99: %.1fs, p50: %.3fs (likely throttling)", p99, p50)
	} else if p99 >= 5 || p50 >= 1 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("S3 latency elevated — p99: %.1fs, p50: %.3fs", p99, p50)
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("S3 latency healthy — p99: %.3fs, p50: %.3fs", p99, p50)
	}
	cc.AddResult(r)
}

// --- Heartbeat Checks ---

func checkHeartbeatDeployment(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_heartbeat_deployment")

	r := checks.Result{
		Check:    "rlr_heartbeat_deployment",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     loggingNS,
			"deployment":    heartbeatDeploy,
			"description":   "Validates the Vector heartbeat deployment exists and has available replicas. The heartbeat emits structured JSON every 2 minutes to verify Vector is collecting logs.",
			"pass_criteria": "PASS: Replicas available. WARN: Not all ready. SKIP: Deployment not found (may not be deployed yet).",
		},
	}

	// Check both the logging and vectorNS namespaces for heartbeat
	var deploy *appsv1.Deployment
	for _, ns := range []string{loggingNS, vectorNS} {
		candidate, err := cc.Client.Clientset().AppsV1().Deployments(ns).Get(ctx, heartbeatDeploy, metav1.GetOptions{})
		if err == nil {
			deploy = candidate
			r.Details["found_namespace"] = ns
			break
		}
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
	}

	if deploy == nil {
		r.Status = checks.StatusInfo
		r.Message = "Heartbeat not deployed — this MC uses OSDFM-managed Vector without a dedicated heartbeat. Pipeline health is monitored via Vector metrics and PrometheusRule alerts instead."
		cc.AddResult(r)
		return
	}

	desired := int32(0)
	if deploy.Spec.Replicas != nil {
		desired = *deploy.Spec.Replicas
	}
	available := deploy.Status.AvailableReplicas
	ready := deploy.Status.ReadyReplicas

	r.Details["desired_replicas"] = desired
	r.Details["available_replicas"] = available
	r.Details["ready_replicas"] = ready

	if available == desired && desired > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Heartbeat deployment healthy — %d/%d available", available, desired)
	} else if desired == 0 {
		r.Status = checks.StatusWarning
		r.Message = "Heartbeat deployment scaled to 0"
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Heartbeat deployment degraded — %d/%d available", available, desired)
	}
	cc.AddResult(r)
}

func checkHeartbeatPodHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_heartbeat_pod_health")

	r := checks.Result{
		Check:    "rlr_heartbeat_pod_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     loggingNS,
			"description":   "Checks heartbeat pod is running and not crashlooping. The heartbeat is a lightweight container (8Mi memory) that emits JSON logs every 2 minutes.",
			"pass_criteria": "PASS: Running, restarts <=5. WARN: Restarts >5 or not running. SKIP: No pods found.",
		},
	}

	// Search both namespaces for heartbeat pods
	var allPods []corev1.Pod
	for _, ns := range []string{loggingNS, vectorNS} {
		pods, err := cc.Client.GetPods(ctx, ns, fmt.Sprintf("app=%s", heartbeatDeploy))
		if err != nil {
			if checks.IsAccessError(err) {
				cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
				return
			}
			continue
		}
		allPods = append(allPods, pods.Items...)
	}

	if len(allPods) == 0 {
		r.Status = checks.StatusInfo
		r.Message = "Heartbeat not deployed — pipeline health monitored via Vector metrics instead"
		cc.AddResult(r)
		return
	}

	totalRestarts := int32(0)
	running := 0
	crashlooping := 0

	for _, pod := range allPods {
		if pod.Status.Phase == "Running" {
			running++
		}
		for _, cs := range pod.Status.ContainerStatuses {
			totalRestarts += cs.RestartCount
			if cs.State.Waiting != nil && cs.State.Waiting.Reason == "CrashLoopBackOff" {
				crashlooping++
			}
		}
	}

	r.Details["pod_count"] = len(allPods)
	r.Details["running"] = running
	r.Details["total_restarts"] = totalRestarts
	r.Details["crashlooping"] = crashlooping
	if problematic := checks.ProblematicPods(allPods); len(problematic) > 0 {
		r.Details["failing_pods"] = problematic
	}

	if running == len(allPods) && totalRestarts <= 5 && crashlooping == 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Heartbeat pod healthy — %d running, %d restarts", running, totalRestarts)
	} else if crashlooping > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Heartbeat pod crashlooping — %d restarts", totalRestarts)
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Heartbeat pod issues — %d/%d running, %d restarts", running, len(allPods), totalRestarts)
	}
	cc.AddResult(r)
}

// --- Log Processor Checks ---

func checkProcessorDeployment(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_processor_deployment")

	r := checks.Result{
		Check:    "rlr_processor_deployment",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     loggingNS,
			"deployment":    processorDeploy,
			"description":   "Validates the log-processor deployment exists and has available replicas. The processor polls SQS and delivers logs to customer S3/CloudWatch destinations.",
			"pass_criteria": "PASS: Replicas available. WARN: Not all ready. INFO: Not deployed (processor runs as AWS Lambda on OSDFM-managed MCs).",
		},
	}

	// Check both namespaces
	var deploy *appsv1.Deployment
	for _, ns := range []string{loggingNS, vectorNS} {
		candidate, err := cc.Client.Clientset().AppsV1().Deployments(ns).Get(ctx, processorDeploy, metav1.GetOptions{})
		if err == nil {
			deploy = candidate
			r.Details["found_namespace"] = ns
			break
		}
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
	}

	if deploy == nil {
		r.Status = checks.StatusInfo
		r.Message = "Log processor not deployed as k8s workload — runs as AWS Lambda on this MC. Customer log delivery health is monitored via CloudWatch metrics."
		cc.AddResult(r)
		return
	}

	desired := int32(0)
	if deploy.Spec.Replicas != nil {
		desired = *deploy.Spec.Replicas
	}
	available := deploy.Status.AvailableReplicas

	r.Details["desired_replicas"] = desired
	r.Details["available_replicas"] = available
	r.Details["ready_replicas"] = deploy.Status.ReadyReplicas

	if available == desired && desired > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Processor deployment healthy — %d/%d available", available, desired)
	} else if desired == 0 {
		r.Status = checks.StatusWarning
		r.Message = "Processor deployment scaled to 0"
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Processor deployment degraded — %d/%d available", available, desired)
	}
	cc.AddResult(r)
}

func checkProcessorPodHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_processor_pod_health")

	r := checks.Result{
		Check:    "rlr_processor_pod_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     loggingNS,
			"description":   "Checks log-processor pod is running and not crashlooping.",
			"pass_criteria": "PASS: Running, restarts <=5. WARN: Restarts >5 or not running. INFO: Not deployed (runs as Lambda).",
		},
	}

	// Search both namespaces
	var allPods []corev1.Pod
	for _, ns := range []string{loggingNS, vectorNS} {
		pods, err := cc.Client.GetPods(ctx, ns, fmt.Sprintf("app=%s", processorDeploy))
		if err != nil {
			if checks.IsAccessError(err) {
				cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
				return
			}
			continue
		}
		allPods = append(allPods, pods.Items...)
	}

	if len(allPods) == 0 {
		r.Status = checks.StatusInfo
		r.Message = "Log processor runs as AWS Lambda — no k8s pods expected"
		cc.AddResult(r)
		return
	}

	totalRestarts := int32(0)
	running := 0
	crashlooping := 0

	for _, pod := range allPods {
		if pod.Status.Phase == "Running" {
			running++
		}
		for _, cs := range pod.Status.ContainerStatuses {
			totalRestarts += cs.RestartCount
			if cs.State.Waiting != nil && cs.State.Waiting.Reason == "CrashLoopBackOff" {
				crashlooping++
			}
		}
	}

	r.Details["pod_count"] = len(allPods)
	r.Details["running"] = running
	r.Details["total_restarts"] = totalRestarts
	if problematic := checks.ProblematicPods(allPods); len(problematic) > 0 {
		r.Details["failing_pods"] = problematic
	}

	if running == len(allPods) && totalRestarts <= 5 && crashlooping == 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Processor pod healthy — %d running, %d restarts", running, totalRestarts)
	} else if crashlooping > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Processor pod crashlooping — %d restarts", totalRestarts)
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Processor pod issues — %d/%d running, %d restarts", running, len(allPods), totalRestarts)
	}
	cc.AddResult(r)
}

// --- PrometheusRule & Alert Checks ---

func checkPrometheusRuleExists(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_prometheusrule_exists")

	r := checks.Result{
		Check:    "rlr_prometheusrule_exists",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     "openshift-monitoring",
			"resource":      "PrometheusRule/sre-vector-log-forwarding",
			"description":   "Validates the Vector log forwarding PrometheusRule exists in openshift-monitoring. This rule defines 10 alerts and 14 recording rules for monitoring the log pipeline.",
			"pass_criteria": "PASS: PrometheusRule found. WARN: Not found. ACCESS_DENIED: Insufficient permissions.",
		},
	}

	pr, err := cc.Client.GetResource(ctx, prometheusRuleGVR, "openshift-monitoring", "sre-vector-log-forwarding", false)
	cc.RecordError("Get Vector PrometheusRule", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusWarning
		r.Message = "PrometheusRule sre-vector-log-forwarding not found in openshift-monitoring"
		cc.AddResult(r)
		return
	}

	// Count groups and rules
	groups, _, _ := unstructured.NestedSlice(pr.Object, "spec", "groups")
	ruleCount := 0
	alertCount := 0
	for _, g := range groups {
		gMap, ok := g.(map[string]any)
		if !ok {
			continue
		}
		rules, _, _ := unstructured.NestedSlice(gMap, "rules")
		for _, rule := range rules {
			rMap, ok := rule.(map[string]any)
			if !ok {
				continue
			}
			ruleCount++
			if _, hasAlert := rMap["alert"]; hasAlert {
				alertCount++
			}
		}
	}

	r.Details["group_count"] = len(groups)
	r.Details["total_rules"] = ruleCount
	r.Details["alert_rules"] = alertCount
	r.Details["recording_rules"] = ruleCount - alertCount

	r.Status = checks.StatusPass
	r.Message = fmt.Sprintf("PrometheusRule found — %d groups, %d alerts, %d recording rules", len(groups), alertCount, ruleCount-alertCount)
	cc.AddResult(r)
}

func checkPrometheusRuleAlerts(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_prometheusrule_alerts")

	r := checks.Result{
		Check:    "rlr_prometheusrule_alerts",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     "openshift-monitoring",
			"description":   "Validates the expected Vector alerts are defined in the PrometheusRule. Checks for the 10 known alert definitions.",
			"pass_criteria": "PASS: All expected alerts found. WARN: Some missing. SKIP: PrometheusRule not found.",
		},
	}

	pr, err := cc.Client.GetResource(ctx, prometheusRuleGVR, "openshift-monitoring", "sre-vector-log-forwarding", false)
	cc.RecordError("Get Vector PrometheusRule for alert check", err)

	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = "PrometheusRule not found — skipping alert validation"
		cc.AddResult(r)
		return
	}

	expectedAlerts := map[string]bool{
		"VectorPodDownSRE":                 false,
		"VectorMetricsAbsentSRE":           false,
		"VectorClusterIngestionFailureSRE": false,
		"VectorNoLogsIngestedSRE":          false,
		"VectorS3WritesStoppedSRE":         false,
		"VectorMissingClusterIDSRE":        false,
		"VectorClusterPipelineEBBFastSRE":  false,
		"VectorClusterPipelineEBBSlowSRE":  false,
		"VectorS3DeliveryEBBSRE":           false,
		"VectorBufferNearCapacitySRE":      false,
	}

	groups, _, _ := unstructured.NestedSlice(pr.Object, "spec", "groups")
	for _, g := range groups {
		gMap, ok := g.(map[string]any)
		if !ok {
			continue
		}
		rules, _, _ := unstructured.NestedSlice(gMap, "rules")
		for _, rule := range rules {
			rMap, ok := rule.(map[string]any)
			if !ok {
				continue
			}
			alertName, _, _ := unstructured.NestedString(rMap, "alert")
			if _, expected := expectedAlerts[alertName]; expected {
				expectedAlerts[alertName] = true
			}
		}
	}

	found := []string{}
	missing := []string{}
	for name, present := range expectedAlerts {
		if present {
			found = append(found, name)
		} else {
			missing = append(missing, name)
		}
	}

	r.Details["found_alerts"] = found
	r.Details["missing_alerts"] = missing

	if len(missing) == 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d expected Vector alerts defined", len(expectedAlerts))
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d expected alerts found — missing: %s", len(found), len(expectedAlerts), strings.Join(missing, ", "))
	}
	cc.AddResult(r)
}

func checkActiveAlerts(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_active_alerts")

	r := checks.Result{
		Check:    "rlr_active_alerts",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks for any actively firing Vector alerts via Thanos. Firing alerts indicate ongoing issues with the log forwarding pipeline.",
			"pass_criteria": "PASS: No Vector alerts firing. WARN: Alerts firing (listed in message). SKIP: Elevation unavailable.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := `ALERTS{alertname=~"Vector.*SRE",alertstate="firing"}`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query firing Vector alerts", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Thanos query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(body) {
		r.Status = checks.StatusPass
		r.Message = "No Vector alerts currently firing"
		cc.AddResult(r)
		return
	}

	resp, _ := thanos.Parse(body)
	firingAlerts := []string{}
	for _, result := range resp.Data.Result {
		name := result.Metric["alertname"]
		if name != "" {
			firingAlerts = append(firingAlerts, name)
		}
	}

	r.Details["firing_alerts"] = firingAlerts
	r.Details["firing_count"] = len(firingAlerts)
	r.Status = checks.StatusWarning
	r.Message = fmt.Sprintf("%d Vector alert(s) firing: %s", len(firingAlerts), strings.Join(firingAlerts, ", "))
	cc.AddResult(r)
}

// --- HCP Data Plane Log Forwarding Checks ---

const hcpLoggingNS = "openshift-logging"

func checkHCPLogForwardingStatus(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_hcp_log_forwarding_status")

	r := checks.Result{
		Check:    "rlr_hcp_log_forwarding_status",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks if ROSA HCP log forwarding is configured via the OCM API (control_plane/log_forwarders). ROSA log forwarding routes HCP control plane logs from the MC Vector pipeline through S3/Lambda to customer CloudWatch or S3 destinations. The entire pipeline runs on the MC — no components are deployed on the HCP data plane.",
			"pass_criteria": "PASS: Log forwarder(s) configured with status 'ready'. WARN: Log forwarder(s) configured but not ready. INFO: No log forwarders configured.",
		},
	}

	if cc.Metadata == nil || len(cc.Metadata.LogForwarders) == 0 {
		r.Status = checks.StatusInfo
		r.Message = "No ROSA log forwarders configured — HCP log forwarding not enabled"
		cc.AddResult(r)
		return
	}

	forwarders := cc.Metadata.LogForwarders
	r.Details["forwarder_count"] = len(forwarders)

	var lfDetails []map[string]any
	readyCount := 0
	notReady := []string{}

	for _, lf := range forwarders {
		detail := map[string]any{
			"id":     lf.ID,
			"type":   lf.Type,
			"status": lf.Status,
			"groups": lf.Groups,
		}
		lfDetails = append(lfDetails, detail)

		if lf.Status == "ready" {
			readyCount++
		} else {
			notReady = append(notReady, fmt.Sprintf("%s (%s: %s)", lf.ID, lf.Type, lf.Status))
		}
	}

	r.Details["log_forwarders"] = lfDetails
	r.Details["ready_count"] = readyCount

	// Summarize types
	types := map[string]int{}
	for _, lf := range forwarders {
		types[lf.Type]++
	}
	var typeSummary []string
	for t, c := range types {
		typeSummary = append(typeSummary, fmt.Sprintf("%d %s", c, t))
	}
	r.Details["type_summary"] = strings.Join(typeSummary, ", ")

	if len(notReady) > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d log forwarder(s) not ready: %s", len(notReady), len(forwarders), strings.Join(notReady, ", "))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d log forwarder(s) configured and ready (%s)", len(forwarders), strings.Join(typeSummary, ", "))
	}
	cc.AddResult(r)
}

func checkHCPLogCollector(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_hcp_log_collector")

	r := checks.Result{
		Check:    "rlr_hcp_log_collector",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"namespace":     hcpLoggingNS,
			"description":   "Checks the log collector DaemonSet health on the HCP cluster. The collector (Vector or Fluentd) is deployed by the cluster-logging-operator when a ClusterLogForwarder is configured. All worker nodes should have a collector pod.",
			"pass_criteria": "PASS: Collector DS found, all pods ready. WARN: Degraded (not all ready). SKIP: No collector DS found.",
		},
	}

	dsList, err := cc.Client.Clientset().AppsV1().DaemonSets(hcpLoggingNS).List(ctx, metav1.ListOptions{})
	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot list DaemonSets in %s: %v", hcpLoggingNS, err)
		cc.AddResult(r)
		return
	}

	var collectorDS *appsv1.DaemonSet
	collectorPatterns := []string{"collector", "vector", "fluentd"}
	for i := range dsList.Items {
		dsName := strings.ToLower(dsList.Items[i].Name)
		for _, pattern := range collectorPatterns {
			if strings.Contains(dsName, pattern) {
				collectorDS = &dsList.Items[i]
				break
			}
		}
		if collectorDS != nil {
			break
		}
	}

	if collectorDS == nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("No log collector DaemonSet found in %s — CLF may not be configured", hcpLoggingNS)
		cc.AddResult(r)
		return
	}

	desired := collectorDS.Status.DesiredNumberScheduled
	ready := collectorDS.Status.NumberReady
	misscheduled := collectorDS.Status.NumberMisscheduled

	r.Details["daemonset"] = collectorDS.Name
	r.Details["desired"] = desired
	r.Details["ready"] = ready
	r.Details["misscheduled"] = misscheduled

	if ready == desired && misscheduled == 0 && desired > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Log collector %s healthy — %d/%d ready", collectorDS.Name, ready, desired)
	} else if desired == 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Log collector %s has 0 desired pods", collectorDS.Name)
	} else {
		r.Status = checks.StatusWarning
		parts := []string{fmt.Sprintf("%d/%d ready", ready, desired)}
		if misscheduled > 0 {
			parts = append(parts, fmt.Sprintf("%d misscheduled", misscheduled))
		}
		r.Message = fmt.Sprintf("Log collector %s degraded — %s", collectorDS.Name, strings.Join(parts, ", "))
	}
	cc.AddResult(r)
}

func checkHCPLogCollectorPods(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_hcp_log_collector_pods")

	r := checks.Result{
		Check:    "rlr_hcp_log_collector_pods",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     hcpLoggingNS,
			"description":   "Checks individual log collector pod health — restarts, OOM kills, crashlooping containers. High restarts may indicate configuration errors, resource limits, or destination connectivity issues.",
			"pass_criteria": "PASS: All pods running, restarts <=10. WARN: High restarts or crashlooping. SKIP: No collector pods.",
		},
	}

	pods, err := cc.Client.GetPods(ctx, hcpLoggingNS, "")
	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot list pods in %s: %v", hcpLoggingNS, err)
		cc.AddResult(r)
		return
	}

	// Filter to collector pods
	var collectorPods []corev1.Pod
	for _, pod := range pods.Items {
		name := strings.ToLower(pod.Name)
		if strings.Contains(name, "collector") || strings.Contains(name, "vector") || strings.Contains(name, "fluentd") {
			collectorPods = append(collectorPods, pod)
		}
	}

	if len(collectorPods) == 0 {
		r.Status = checks.StatusSkip
		r.Message = "No log collector pods found"
		cc.AddResult(r)
		return
	}

	totalRestarts := int32(0)
	crashlooping := 0
	maxRestartPod := ""
	maxRestarts := int32(0)

	for _, pod := range collectorPods {
		for _, cs := range pod.Status.ContainerStatuses {
			totalRestarts += cs.RestartCount
			if cs.RestartCount > maxRestarts {
				maxRestarts = cs.RestartCount
				maxRestartPod = pod.Name
			}
			if cs.State.Waiting != nil && cs.State.Waiting.Reason == "CrashLoopBackOff" {
				crashlooping++
			}
		}
	}

	r.Details["pod_count"] = len(collectorPods)
	r.Details["total_restarts"] = totalRestarts
	r.Details["crashlooping"] = crashlooping
	if maxRestartPod != "" {
		r.Details["max_restart_pod"] = maxRestartPod
		r.Details["max_restart_count"] = maxRestarts
	}
	if problematic := checks.ProblematicPods(collectorPods); len(problematic) > 0 {
		r.Details["failing_pods"] = problematic
	}

	if crashlooping > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Log collector crashlooping — %d pod(s), %d total restarts", crashlooping, totalRestarts)
	} else if totalRestarts > 10 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Log collector high restarts — %d across %d pods (max: %s with %d)", totalRestarts, len(collectorPods), maxRestartPod, maxRestarts)
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Log collector pods healthy — %d pods, %d restarts", len(collectorPods), totalRestarts)
	}
	cc.AddResult(r)
}

func checkHCPLogDeliveryMetrics(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_hcp_log_delivery_metrics")

	r := checks.Result{
		Check:    "rlr_hcp_log_delivery_metrics",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     hcpLoggingNS,
			"description":   "Checks log delivery health via Vector component metrics on the HCP cluster. Validates that logs are being collected and forwarded to configured destinations without excessive errors or buffer growth.",
			"pass_criteria": "PASS: Events flowing, error rate <1%. WARN: High error rate, zero throughput, or buffer growth. SKIP: Metrics not available.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	outputQuery := fmt.Sprintf(`sum(rate(vector_component_sent_events_total{namespace="%s",component_type="sink"}[5m]))`, hcpLoggingNS)
	outputBody, outputErr := cc.Client.QueryMetrics(ctx, outputQuery)

	errorQuery := fmt.Sprintf(`sum(rate(vector_component_errors_total{namespace="%s"}[5m]))`, hcpLoggingNS)
	errorBody, errorErr := cc.Client.QueryMetrics(ctx, errorQuery)

	if outputErr != nil && errorErr != nil {
		if checks.IsAccessError(outputErr) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusSkip
		r.Message = "Log delivery metrics not available"
		cc.AddResult(r)
		return
	}

	outputRate := 0.0
	errorRate := 0.0
	if outputErr == nil && thanos.HasResults(outputBody) {
		outputRate, _ = thanos.InstantFloat(outputBody)
	}
	if errorErr == nil && thanos.HasResults(errorBody) {
		errorRate, _ = thanos.InstantFloat(errorBody)
	}

	r.Details["output_rate_per_sec"] = thanos.Round(sanitizeFloat(outputRate), 2)
	r.Details["error_rate_per_sec"] = thanos.Round(sanitizeFloat(errorRate), 4)

	errorPct := 0.0
	if outputRate > 0 {
		errorPct = (errorRate / outputRate) * 100
	}
	r.Details["error_percent"] = thanos.Round(sanitizeFloat(errorPct), 2)

	// Check buffer usage
	bufferQuery := fmt.Sprintf(`max(vector_buffer_byte_size{namespace="%s"})`, hcpLoggingNS)
	bufferBody, bufferErr := cc.Client.QueryMetrics(ctx, bufferQuery)
	bufferBytes := 0.0
	if bufferErr == nil && thanos.HasResults(bufferBody) {
		bufferBytes, _ = thanos.InstantFloat(bufferBody)
	}
	r.Details["buffer_bytes"] = int64(sanitizeFloat(bufferBytes))
	r.Details["buffer_mb"] = thanos.Round(sanitizeFloat(bufferBytes/(1024*1024)), 1)

	switch {
	case outputRate == 0 && errorRate == 0 && bufferBytes == 0:
		r.Status = checks.StatusSkip
		r.Message = "No log delivery metrics found — collector may not expose Vector metrics"
	case outputRate == 0 && (errorRate > 0 || bufferBytes > 0):
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Zero output rate but errors present (%.4f/sec) or buffer growing (%.1f MB)", errorRate, bufferBytes/(1024*1024))
	case errorPct > 5:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Log delivery errors elevated — %.0f events/sec output, %.2f%% error rate", outputRate, errorPct)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Log delivery healthy — %.0f events/sec, %.2f%% error rate, %.1f MB buffered", outputRate, errorPct, bufferBytes/(1024*1024))
	}
	cc.AddResult(r)
}

func topNSeriesByPeak(series []thanos.LabeledTimeseries, n int) []thanos.LabeledTimeseries {
	if len(series) <= n {
		return series
	}
	type scored struct {
		idx  int
		peak float64
	}
	scores := make([]scored, len(series))
	for i, s := range series {
		var peak float64
		for _, p := range s.Values {
			if p[1] > peak {
				peak = p[1]
			}
		}
		scores[i] = scored{i, peak}
	}
	// Simple selection sort for top N (N is small)
	for i := 0; i < n && i < len(scores); i++ {
		maxIdx := i
		for j := i + 1; j < len(scores); j++ {
			if scores[j].peak > scores[maxIdx].peak {
				maxIdx = j
			}
		}
		scores[i], scores[maxIdx] = scores[maxIdx], scores[i]
	}
	result := make([]thanos.LabeledTimeseries, n)
	for i := 0; i < n; i++ {
		result[i] = series[scores[i].idx]
	}
	return result
}

func topNSeriesByWorstRatio(series []thanos.LabeledTimeseries, n int) []thanos.LabeledTimeseries {
	if len(series) <= n {
		return series
	}
	type scored struct {
		idx    int
		minVal float64
	}
	scores := make([]scored, len(series))
	for i, s := range series {
		minVal := 1.0
		for _, p := range s.Values {
			if p[1] < minVal {
				minVal = p[1]
			}
		}
		scores[i] = scored{i, minVal}
	}
	for i := 0; i < n && i < len(scores); i++ {
		minIdx := i
		for j := i + 1; j < len(scores); j++ {
			if scores[j].minVal < scores[minIdx].minVal {
				minIdx = j
			}
		}
		scores[i], scores[minIdx] = scores[minIdx], scores[i]
	}
	result := make([]thanos.LabeledTimeseries, n)
	for i := 0; i < n; i++ {
		result[i] = series[scores[i].idx]
	}
	return result
}

const maxChartSeries = 10

// --- Timeseries Collection (7-day trends for charts) ---

func collectVectorTimeseries(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rlr_vector_trends")

	r := checks.Result{
		Check:    "rlr_vector_trends",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "7-day timeseries trends for Vector pipeline health: buffer usage, ingestion rate, event loss, S3 write ratio, and Vector pod CPU/memory. Used to render charts in the HTML report.",
			"pass_criteria": "INFO: Timeseries data collected for charting. SKIP: Elevation unavailable.",
			"lookback_hours": 168.0,
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	now := time.Now().Unix()
	start := now - 604800 // 7 days
	step := 1800          // 30-minute intervals

	seriesCollected := 0
	podLabel := func(m map[string]string) string {
		p := m["pod"]
		if len(p) > 40 {
			p = p[:37] + "..."
		}
		return p
	}
	clusterLabel := func(m map[string]string) string {
		ns := m["pod_namespace"]
		if ns == "" {
			ns = m["namespace"]
		}
		if len(ns) > 40 {
			ns = ns[:37] + "..."
		}
		return ns
	}

	// Buffer saturation per pod (0-1, fraction of 10GB max) — top N by peak
	saturationQuery := `vector:s3_sink:buffer_saturation:by_pod`
	if satData, err := cc.Client.QueryMetricsRange(ctx, saturationQuery, start, now, step); err == nil {
		if series, _ := thanos.PerSeriesTimeseries(satData, podLabel); len(series) > 0 {
			r.Details["buffer_saturation_total_pods"] = len(series)
			r.Details["buffer_saturation_timeseries_by_pod"] = topNSeriesByPeak(series, maxChartSeries)
			seriesCollected++
		}
	}

	// Ingestion rate — aggregate + top N clusters by volume
	ingestionQuery := `vector:logs:ingestion_rate`
	if ingestionData, err := cc.Client.QueryMetricsRange(ctx, ingestionQuery, start, now, step); err == nil {
		if points, _ := thanos.Timeseries(ingestionData); len(points) > 0 {
			r.Details["ingestion_timeseries"] = thanos.PointsToJSON(points)
			peak := thanos.Peak(points)
			r.Details["ingestion_peak_events_per_sec"] = thanos.Round(sanitizeFloat(peak), 0)
			seriesCollected++
		}
	}
	clusterIngestionQuery := `vector:cluster:ingestion_rate`
	if clusterData, err := cc.Client.QueryMetricsRange(ctx, clusterIngestionQuery, start, now, step); err == nil {
		if series, _ := thanos.PerSeriesTimeseries(clusterData, clusterLabel); len(series) > 0 {
			r.Details["ingestion_total_clusters"] = len(series)
			r.Details["ingestion_timeseries_by_cluster"] = topNSeriesByPeak(series, maxChartSeries)
			seriesCollected++
		}
	}

	// Event loss — aggregate (clamp negative to 0) + top N pods with most loss
	lossQuery := `clamp_min(vector:hcp_logs:event_loss_rate:by_pod, 0)`
	if lossData, err := cc.Client.QueryMetricsRange(ctx, lossQuery, start, now, step); err == nil {
		if points, _ := thanos.Timeseries(lossData); len(points) > 0 {
			errorPoints := thanos.FilterNonZero(points)
			r.Details["event_loss_timeseries"] = thanos.PointsToJSON(points)
			r.Details["event_loss_error_count"] = len(errorPoints)
		}
		if series, _ := thanos.PerSeriesTimeseries(lossData, podLabel); len(series) > 0 {
			r.Details["event_loss_total_pods"] = len(series)
			r.Details["event_loss_timeseries_by_pod"] = topNSeriesByPeak(series, maxChartSeries)
			seriesCollected++
		}
	}

	// Write ratio — aggregate + top N worst pods (lowest ratio = most backpressure)
	writeQuery := `vector:s3_sink:write_ratio`
	if writeData, err := cc.Client.QueryMetricsRange(ctx, writeQuery, start, now, step); err == nil {
		if points, _ := thanos.Timeseries(writeData); len(points) > 0 {
			r.Details["write_ratio_timeseries"] = thanos.PointsToJSON(points)
			seriesCollected++
		}
	}
	writeByPodQuery := `vector:logs:write_ratio:by_pod`
	if writeData, err := cc.Client.QueryMetricsRange(ctx, writeByPodQuery, start, now, step); err == nil {
		if series, _ := thanos.PerSeriesTimeseries(writeData, podLabel); len(series) > 0 {
			r.Details["write_ratio_total_pods"] = len(series)
			r.Details["write_ratio_timeseries_by_pod"] = topNSeriesByWorstRatio(series, maxChartSeries)
			seriesCollected++
		}
	}

	// Per-node timeseries for interactive charts (one vector pod per node)
	nodeLabel := func(m map[string]string) string {
		return m["node"]
	}
	memQuery := fmt.Sprintf(`sum by (node) (container_memory_working_set_bytes{namespace="%s",container!=""})`, vectorNS)
	if memData, err := cc.Client.QueryMetricsRange(ctx, memQuery, start, now, step); err == nil {
		if series, _ := thanos.PerSeriesTimeseries(memData, nodeLabel); len(series) > 0 {
			sort.Slice(series, func(i, j int) bool {
				return thanos.Peak(series[i].Values) > thanos.Peak(series[j].Values)
			})
			if len(series) > 15 {
				series = series[:15]
			}
			r.Details["memory_timeseries"] = series
			r.Details["vector_node_count"] = len(series)
			seriesCollected += len(series)
		}
	}

	cpuQuery := fmt.Sprintf(`sum by (node) (rate(container_cpu_usage_seconds_total{namespace="%s",container!=""}[5m]))`, vectorNS)
	if cpuData, err := cc.Client.QueryMetricsRange(ctx, cpuQuery, start, now, step); err == nil {
		if series, _ := thanos.PerSeriesTimeseries(cpuData, nodeLabel); len(series) > 0 {
			sort.Slice(series, func(i, j int) bool {
				return thanos.Peak(series[i].Values) > thanos.Peak(series[j].Values)
			})
			if len(series) > 15 {
				series = series[:15]
			}
			r.Details["cpu_timeseries"] = series
			seriesCollected += len(series)
		}
	}

	// Aggregate queries for summary stats
	aggMemQuery := fmt.Sprintf(`sum(container_memory_working_set_bytes{namespace="%s",container!=""})`, vectorNS)
	if aggMemData, err := cc.Client.QueryMetricsRange(ctx, aggMemQuery, start, now, step); err == nil {
		if points, _ := thanos.Timeseries(aggMemData); len(points) > 0 {
			peak := thanos.Peak(points)
			r.Details["peak_memory_mb"] = thanos.Round(sanitizeFloat(peak/(1024*1024)), 0)
			_, last, pctChange := thanos.Trend(points)
			r.Details["memory_increase_percent"] = thanos.Round(sanitizeFloat(pctChange), 2)
			r.Details["memory_trend"] = "stable"
			if pctChange > 50 && last/(1024*1024) > 100 {
				r.Details["memory_trend"] = "increasing"
			}
		}
	}
	aggCpuQuery := fmt.Sprintf(`sum(rate(container_cpu_usage_seconds_total{namespace="%s",container!=""}[5m]))`, vectorNS)
	if aggCpuData, err := cc.Client.QueryMetricsRange(ctx, aggCpuQuery, start, now, step); err == nil {
		if points, _ := thanos.Timeseries(aggCpuData); len(points) > 0 {
			peak := thanos.Peak(points)
			r.Details["peak_cpu_millicores"] = thanos.Round(sanitizeFloat(peak*1000), 0)
			_, _, pctChange := thanos.Trend(points)
			r.Details["cpu_increase_percent"] = thanos.Round(sanitizeFloat(pctChange), 2)
		}
	}

	// Component utilization over time — shows before/after impact of transform optimizations
	utilizationQuery := `avg by (component_id) (vector_utilization)`
	if utilData, err := cc.Client.QueryMetricsRange(ctx, utilizationQuery, start, now, step); err == nil {
		componentLabel := func(m map[string]string) string { return m["component_id"] }
		if series, _ := thanos.PerSeriesTimeseries(utilData, componentLabel); len(series) > 0 {
			r.Details["utilization_total_components"] = len(series)
			r.Details["utilization_timeseries_by_component"] = topNSeriesByPeak(series, maxChartSeries)
			seriesCollected++
		}
	}

	// Buffer event count over time — shows S3 concurrency drain effectiveness
	bufferEventsQuery := `sum(vector_buffer_events{buffer_id="hcp_logs"})`
	if bufEvtData, err := cc.Client.QueryMetricsRange(ctx, bufferEventsQuery, start, now, step); err == nil {
		if points, _ := thanos.Timeseries(bufEvtData); len(points) > 0 {
			r.Details["buffer_events_timeseries"] = thanos.PointsToJSON(points)
			peak := thanos.Peak(points)
			r.Details["buffer_events_peak"] = int64(sanitizeFloat(peak))
			seriesCollected++
		}
	}

	// Per-component throughput over time — most directly shows config change impact
	componentRateQuery := `sum by (component_id) (rate(vector_component_sent_events_total[5m]))`
	if compData, err := cc.Client.QueryMetricsRange(ctx, componentRateQuery, start, now, step); err == nil {
		componentLabel := func(m map[string]string) string { return m["component_id"] }
		if series, _ := thanos.PerSeriesTimeseries(compData, componentLabel); len(series) > 0 {
			r.Details["component_throughput_total"] = len(series)
			r.Details["component_throughput_timeseries"] = topNSeriesByPeak(series, maxChartSeries)
			seriesCollected++
		}
	}

	r.Details["series_collected"] = seriesCollected
	r.Status = checks.StatusInfo
	r.Message = fmt.Sprintf("Collected %d timeseries for trending", seriesCollected)
	cc.AddResult(r)
}
