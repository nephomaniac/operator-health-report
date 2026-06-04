package rlr

import (
	"context"
	"fmt"
	"math"
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

var (
	prometheusRuleGVR = schema.GroupVersionResource{
		Group: "monitoring.coreos.com", Version: "v1", Resource: "prometheusrules",
	}
	hostedClusterGVR = schema.GroupVersionResource{
		Group: "hypershift.openshift.io", Version: "v1beta1", Resource: "hostedclusters",
	}
)

func (c *RLRChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	if cc.ClusterType != "management_cluster" {
		cc.AddResult(checks.Result{
			Check:    "rlr_cluster_type",
			Status:   checks.StatusInfo,
			Severity: checks.SeverityInfo,
			Message:  fmt.Sprintf("RLR checks not applicable on %s clusters — only management clusters", cc.ClusterType),
			Details:  map[string]any{"cluster_type": cc.ClusterType},
		})
		return
	}

	// Vector Collector
	checkVectorNamespace(ctx, cc)
	checkVectorDaemonSetHealth(ctx, cc)
	checkVectorPodRestarts(ctx, cc)
	checkVectorMetricsPresent(ctx, cc)
	checkVectorIngestionRate(ctx, cc)
	checkVectorS3Delivery(ctx, cc)
	checkVectorBufferUsage(ctx, cc)
	checkVectorErrorRate(ctx, cc)
	checkVectorEventLoss(ctx, cc)
	checkVectorPipelineRatio(ctx, cc)

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
	cc.CurrentCheck = "rlr_vector_namespace"

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
	cc.CurrentCheck = "rlr_vector_daemonset_health"

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

func checkVectorPodRestarts(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rlr_vector_pod_restarts"

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
	cc.CurrentCheck = "rlr_vector_metrics_present"

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
	cc.CurrentCheck = "rlr_vector_ingestion_rate"

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
	cc.CurrentCheck = "rlr_vector_s3_delivery"

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
	cc.CurrentCheck = "rlr_vector_buffer_usage"

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
	cc.CurrentCheck = "rlr_vector_error_rate"

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
	cc.CurrentCheck = "rlr_vector_event_loss"

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
	cc.CurrentCheck = "rlr_vector_pipeline_ratio"

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

// --- Heartbeat Checks ---

func checkHeartbeatDeployment(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rlr_heartbeat_deployment"

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
	cc.CurrentCheck = "rlr_heartbeat_pod_health"

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
	cc.CurrentCheck = "rlr_processor_deployment"

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
	cc.CurrentCheck = "rlr_processor_pod_health"

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
	cc.CurrentCheck = "rlr_prometheusrule_exists"

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
	cc.CurrentCheck = "rlr_prometheusrule_alerts"

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
	cc.CurrentCheck = "rlr_active_alerts"

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
	cc.CurrentCheck = "rlr_vector_trends"

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

	// Vector pod memory (aggregate across all pods)
	memQuery := (fmt.Sprintf(
		`sum(container_memory_working_set_bytes{namespace="%s",container!=""})`, vectorNS))
	if memData, err := cc.Client.QueryMetricsRange(ctx, memQuery, start, now, step); err == nil {
		if points, _ := thanos.Timeseries(memData); len(points) > 0 {
			r.Details["memory_timeseries"] = thanos.PointsToJSON(points)
			peak := thanos.Peak(points)
			r.Details["peak_memory_mb"] = thanos.Round(sanitizeFloat(peak/(1024*1024)), 0)
			_, last, pctChange := thanos.Trend(points)
			r.Details["memory_increase_percent"] = thanos.Round(sanitizeFloat(pctChange), 2)
			r.Details["memory_trend"] = "stable"
			if pctChange > 50 && last/(1024*1024) > 100 {
				r.Details["memory_trend"] = "increasing"
			}
			seriesCollected++
		}
	}

	// Vector pod CPU (aggregate across all pods)
	cpuQuery := (fmt.Sprintf(
		`sum(rate(container_cpu_usage_seconds_total{namespace="%s",container!=""}[5m]))`, vectorNS))
	if cpuData, err := cc.Client.QueryMetricsRange(ctx, cpuQuery, start, now, step); err == nil {
		if points, _ := thanos.Timeseries(cpuData); len(points) > 0 {
			r.Details["cpu_timeseries"] = thanos.PointsToJSON(points)
			peak := thanos.Peak(points)
			r.Details["peak_cpu_millicores"] = thanos.Round(sanitizeFloat(peak*1000), 0)
			_, _, pctChange := thanos.Trend(points)
			r.Details["cpu_increase_percent"] = thanos.Round(sanitizeFloat(pctChange), 2)
			seriesCollected++
		}
	}

	r.Details["series_collected"] = seriesCollected
	r.Status = checks.StatusInfo
	r.Message = fmt.Sprintf("Collected %d timeseries for trending", seriesCollected)
	cc.AddResult(r)
}
