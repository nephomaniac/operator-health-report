package sae

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/thanos"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func init() {
	checks.Register(&SAEChecker{})
}

type SAEChecker struct{}

func (c *SAEChecker) Name() string { return "sae" }

const securityNS = "openshift-security"

func (c *SAEChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	// Applicable common checks (SAE is a DaemonSet, not a Deployment)
	checks.CheckNamespace(ctx, cc)
	if len(cc.Results) > 0 && cc.Results[0].Status == checks.StatusFail {
		return
	}
	checks.CheckImagePull(ctx, cc)
	checks.CheckEvents(ctx, cc)

	// SAE-specific checks
	checkDaemonSetHealth(ctx, cc)
	checkAuditPolicy(ctx, cc)
	checkTLSCerts(ctx, cc)
	checkEventFlow(ctx, cc)
	checkFilterErrors(ctx, cc)
	checkQueueDepth(ctx, cc)
	checkDedupCache(ctx, cc)
	checkFilterDecisions(ctx, cc)
	checkLogErrors(ctx, cc)
	checkResourceTrends(ctx, cc)
}

func checkDaemonSetHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("sae_daemonset_health")

	r := checks.Result{
		Check:    "sae_daemonset_health",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"namespace":     securityNS,
			"daemonset":     "audit-exporter",
			"description":   "Validates the audit-exporter DaemonSet health on master nodes. Filters KAS audit logs before forwarding to Splunk. Runs on master nodes only via toleration/nodeSelector. Deployed via SelectorSyncSet from its own SAAS pipeline (saas-sae).",
			"pass_criteria": "PASS: All pods ready, restarts <=10. WARN: Elevated restarts. FAIL: Pods not ready, crashlooping, or ImagePullBackOff.",
		},
	}

	ds, err := cc.Client.Clientset().AppsV1().DaemonSets(securityNS).Get(ctx, "audit-exporter", metav1.GetOptions{})
	cc.RecordError("Get audit-exporter DaemonSet", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("audit-exporter DaemonSet not found in %s — SSS deployment may have failed or SAE is not configured for this cluster", securityNS)
			cc.AddResult(r)
		}
		return
	}

	desired := int(ds.Status.DesiredNumberScheduled)
	ready := int(ds.Status.NumberReady)
	misscheduled := int(ds.Status.NumberMisscheduled)

	r.Details["desired"] = desired
	r.Details["ready"] = ready
	r.Details["misscheduled"] = misscheduled
	r.Details["updated"] = int(ds.Status.UpdatedNumberScheduled)

	podSelector := ""
	if ds.Spec.Selector != nil {
		if sel, selErr := metav1.LabelSelectorAsSelector(ds.Spec.Selector); selErr == nil {
			podSelector = sel.String()
		}
	}
	pods, podErr := cc.Client.GetPods(ctx, securityNS, podSelector)

	totalRestarts := 0
	crashlooping := 0
	imagePullErrors := 0
	if podErr == nil {
		for _, pod := range pods.Items {
			for _, cs := range pod.Status.ContainerStatuses {
				totalRestarts += int(cs.RestartCount)
				if cs.State.Waiting != nil {
					switch cs.State.Waiting.Reason {
					case "CrashLoopBackOff":
						crashlooping++
					case "ImagePullBackOff", "ErrImagePull":
						imagePullErrors++
					}
				}
			}
		}
		r.Details["pod_count"] = len(pods.Items)
		r.Details["total_restarts"] = totalRestarts
		r.Details["crashlooping"] = crashlooping
		r.Details["image_pull_errors"] = imagePullErrors
		if problematic := checks.ProblematicPods(pods.Items); len(problematic) > 0 {
			r.Details["failing_pods"] = problematic
		}
	}

	// Image availability check for pull failures
	if imagePullErrors > 0 && podErr == nil {
		failingImages := map[string]bool{}
		for _, pod := range pods.Items {
			for _, cs := range pod.Status.ContainerStatuses {
				if cs.State.Waiting != nil && (cs.State.Waiting.Reason == "ImagePullBackOff" || cs.State.Waiting.Reason == "ErrImagePull") {
					failingImages[cs.Image] = true
				}
			}
		}
		var imageChecks []map[string]any
		for img := range failingImages {
			check := map[string]any{"image": img}
			available, regErr := checks.CheckImageInRegistry(img)
			if regErr != nil {
				check["registry_check"] = fmt.Sprintf("error: %v", regErr)
			} else if available {
				check["registry_check"] = "image exists in registry — pull failure may be auth/network issue"
			} else {
				check["registry_check"] = "image NOT found in registry — tag or repo may not exist"
			}
			check["available"] = available
			imageChecks = append(imageChecks, check)
		}
		r.Details["image_checks"] = imageChecks
	}

	switch {
	case imagePullErrors > 0:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("audit-exporter %d pod(s) with ImagePullBackOff (%d/%d ready)", imagePullErrors, ready, desired)
	case crashlooping > 0:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("audit-exporter %d pod(s) crashlooping (%d/%d ready, %d restarts)", crashlooping, ready, desired, totalRestarts)
	case ready != desired:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("audit-exporter not fully ready (%d/%d on master nodes, %d restarts)", ready, desired, totalRestarts)
	case totalRestarts > 10:
		r.Status = checks.StatusWarning
		r.Severity = checks.SeverityWarning
		r.Message = fmt.Sprintf("audit-exporter ready (%d/%d) but elevated restarts (%d)", ready, desired, totalRestarts)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("audit-exporter healthy (%d/%d master nodes, %d restarts)", ready, desired, totalRestarts)
	}

	cc.AddResult(r)
}

func checkAuditPolicy(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("sae_audit_policy")

	r := checks.Result{
		Check:    "sae_audit_policy",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     securityNS,
			"configmap":     "osd-audit-policy",
			"description":   "Validates the osd-audit-policy ConfigMap exists. Contains the YAML policy rules that define which KAS audit events to forward and which to drop. Without this ConfigMap, SAE cannot start (exits immediately).",
			"pass_criteria": "PASS: ConfigMap present. FAIL: Missing — SAE pods will crashloop on startup.",
		},
	}

	cm, err := cc.Client.Clientset().CoreV1().ConfigMaps(securityNS).Get(ctx, "osd-audit-policy", metav1.GetOptions{})
	cc.RecordError("Get osd-audit-policy ConfigMap", err)

	if err != nil {
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = "osd-audit-policy ConfigMap missing — SAE pods will fail to start without filtering policy"
	} else {
		keyCount := len(cm.Data)
		r.Details["data_keys"] = keyCount
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("osd-audit-policy ConfigMap present (%d data keys)", keyCount)
	}

	cc.AddResult(r)
}

func checkTLSCerts(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("sae_tls_certs")

	r := checks.Result{
		Check:    "sae_tls_certs",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     securityNS,
			"secret":        "audit-exporter-certs",
			"description":   "Validates the audit-exporter-certs Secret exists. Contains TLS certificates for the /metrics HTTPS endpoint on port 9090. Without this secret, the metrics endpoint is disabled and Prometheus cannot scrape SAE health metrics.",
			"pass_criteria": "PASS: Secret exists. WARN: Secret missing — metrics endpoint disabled.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	cc.Client.RecordElevatedOp(fmt.Sprintf("[%s] get secrets/audit-exporter-certs in %s", cc.CurrentCheck, securityNS))
	_, err := cc.Client.ElevatedClientset().CoreV1().Secrets(securityNS).Get(ctx, "audit-exporter-certs", metav1.GetOptions{})

	if err != nil {
		r.Status = checks.StatusWarning
		r.Message = "audit-exporter-certs Secret missing — SAE metrics endpoint may be disabled"
	} else {
		r.Status = checks.StatusPass
		r.Message = "audit-exporter-certs Secret present — metrics endpoint TLS configured"
	}

	cc.AddResult(r)
}

func checkEventFlow(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("sae_event_flow")

	r := checks.Result{
		Check:    "sae_event_flow",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"namespace":     securityNS,
			"description":   "Verifies KAS audit events are flowing through SAE by checking the splunkforwarder_audit_filter_events_total counter rate. Zero events means SAE is not reading audit logs — either pods aren't running, audit log files don't exist, or file watchers are broken.",
			"pass_criteria": "PASS: events/sec > 0. FAIL: 0 events flowing. SKIP: Metrics unavailable.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx,
		fmt.Sprintf(`sum(rate(splunkforwarder_audit_filter_events_total{namespace="%s"}[5m]))`, securityNS))
	cc.RecordError("Query SAE event rate", err)

	if err != nil || !thanos.HasResults(body) {
		r.Status = checks.StatusWarning
		r.Message = "SAE event metrics not found — pods may not be running or metrics endpoint is down"
		cc.AddResult(r)
		return
	}

	rate, ok := thanos.InstantFloat(body)
	if !ok {
		r.Status = checks.StatusUnknown
		r.Message = "Could not parse event rate"
		cc.AddResult(r)
		return
	}

	r.Details["events_per_sec"] = thanos.Round(rate, 2)

	if rate > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Audit events flowing — %.1f events/sec", rate)
	} else {
		r.Status = checks.StatusFail
		r.Message = "No audit events flowing — SAE not reading KAS audit logs"
	}

	cc.AddResult(r)
}

func checkFilterErrors(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("sae_filter_errors")

	r := checks.Result{
		Check:    "sae_filter_errors",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     securityNS,
			"description":   "Checks the splunkforwarder_audit_filter_errors_total counter for JSON decode/encode errors. These indicate malformed audit events that SAE cannot process.",
			"pass_criteria": "PASS: Error rate is 0. WARN: Errors detected. SKIP: Metrics unavailable.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx,
		fmt.Sprintf(`sum(rate(splunkforwarder_audit_filter_errors_total{namespace="%s"}[5m]))`, securityNS))

	if err != nil || !thanos.HasResults(body) {
		// No data = no errors (healthy)
		r.Status = checks.StatusPass
		r.Message = "No filter errors detected"
		cc.AddResult(r)
		return
	}

	rate, ok := thanos.InstantFloat(body)
	if !ok || rate == 0 {
		r.Status = checks.StatusPass
		r.Message = "No filter errors detected"
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Audit filter errors: %.4f/sec — malformed events being dropped", rate)
		r.Details["error_rate"] = thanos.Round(rate, 4)
	}

	cc.AddResult(r)
}

func checkQueueDepth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("sae_queue_depth")

	r := checks.Result{
		Check:    "sae_queue_depth",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     securityNS,
			"description":   "Checks the internal processing queue depths (filter, decode, encode channels). High queue depth indicates a pipeline bottleneck — events are arriving faster than SAE can process them.",
			"pass_criteria": "PASS: Queue depth < 100. WARN: Queue depth >= 100 (backlog building). SKIP: Metrics unavailable.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx,
		fmt.Sprintf(`max(splunkforwarder_audit_filter_queue_depth{namespace="%s"})`, securityNS))

	if err != nil || !thanos.HasResults(body) {
		r.Status = checks.StatusWarning
		r.Message = "Queue depth metrics not found — SAE may not be running"
		cc.AddResult(r)
		return
	}

	depth, ok := thanos.InstantFloat(body)
	if !ok {
		r.Status = checks.StatusWarning
		r.Message = "Could not parse queue depth"
		cc.AddResult(r)
		return
	}

	r.Details["max_queue_depth"] = int(depth)

	if depth >= 100 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Queue depth elevated (%d) — processing backlog building", int(depth))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Queue depth healthy (%d)", int(depth))
	}

	cc.AddResult(r)
}

func checkDedupCache(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("sae_dedup_cache")

	r := checks.Result{
		Check:    "sae_dedup_cache",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"namespace":     securityNS,
			"description":   "Checks the deduplication LRU cache size. SAE uses an LRU cache (max 1000 entries, 48h TTL) to detect and drop duplicate update events. Near-capacity (1000) indicates cache thrashing — dedup effectiveness may be reduced.",
			"pass_criteria": "PASS: Cache size < 900. WARN: Cache near capacity (>= 900). INFO: Metrics unavailable.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx,
		fmt.Sprintf(`max(splunkforwarder_audit_filter_cached_objects{namespace="%s"})`, securityNS))

	if err != nil || !thanos.HasResults(body) {
		r.Status = checks.StatusWarning
		r.Message = "Dedup cache metrics not found — SAE may not be running"
		cc.AddResult(r)
		return
	}

	size, ok := thanos.InstantFloat(body)
	if !ok {
		r.Status = checks.StatusWarning
		r.Message = "Could not parse cache size"
		cc.AddResult(r)
		return
	}

	r.Details["cache_size"] = int(size)
	r.Details["cache_max"] = 1000

	if size >= 900 {
		r.Status = checks.StatusWarning
		r.Severity = checks.SeverityWarning
		r.Message = fmt.Sprintf("Dedup cache near capacity (%d/1000) — may be thrashing", int(size))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Dedup cache healthy (%d/1000)", int(size))
	}

	cc.AddResult(r)
}

func checkFilterDecisions(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("sae_filter_decisions")

	r := checks.Result{
		Check:    "sae_filter_decisions",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"namespace":     securityNS,
			"description":   "Reports the forward vs drop ratio from SAE filter decisions. A healthy SAE should drop a significant percentage of events (noisy system reads). If the drop rate is very low, the filter policy may not be working correctly.",
			"pass_criteria": "INFO: Reports forward/drop rates. WARN: Drop rate < 50% of total (policy may not be effective).",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	fwdBody, _ := cc.Client.QueryMetrics(ctx,
		fmt.Sprintf(`sum(rate(splunkforwarder_audit_filter_events_processed_total{namespace="%s",decision="forward"}[5m]))`, securityNS))
	dropBody, _ := cc.Client.QueryMetrics(ctx,
		fmt.Sprintf(`sum(rate(splunkforwarder_audit_filter_events_processed_total{namespace="%s",decision="drop"}[5m]))`, securityNS))

	fwdRate, fwdOK := thanos.InstantFloat(fwdBody)
	dropRate, dropOK := thanos.InstantFloat(dropBody)

	if !fwdOK && !dropOK {
		r.Status = checks.StatusWarning
		r.Message = "Filter decision metrics not found — SAE may not be processing events"
		cc.AddResult(r)
		return
	}

	totalRate := fwdRate + dropRate
	r.Details["forward_rate"] = thanos.Round(fwdRate, 2)
	r.Details["drop_rate"] = thanos.Round(dropRate, 2)
	r.Details["total_rate"] = thanos.Round(totalRate, 2)

	if totalRate > 0 {
		dropPct := (dropRate / totalRate) * 100
		r.Details["drop_percent"] = thanos.Round(dropPct, 1)
		r.Details["forward_percent"] = thanos.Round(100-dropPct, 1)

		if dropPct < 50 {
			r.Status = checks.StatusWarning
			r.Severity = checks.SeverityWarning
			r.Message = fmt.Sprintf("Low drop rate (%.0f%%) — policy may not be filtering effectively (fwd: %.1f/s, drop: %.1f/s)",
				dropPct, fwdRate, dropRate)
		} else {
			r.Status = checks.StatusPass
			r.Message = fmt.Sprintf("Filter effective — %.0f%% dropped (fwd: %.1f/s, drop: %.1f/s)", dropPct, fwdRate, dropRate)
		}
	} else {
		r.Status = checks.StatusWarning
		r.Message = "No events being processed — SAE may not be running or KAS audit logging is disabled"
	}

	cc.AddResult(r)
}

func checkLogErrors(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("sae_log_errors")

	r := checks.Result{
		Check:    "sae_log_errors",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     securityNS,
			"description":   "Scans recent audit-exporter logs for error patterns: policy loading failures, file read errors, inotify watcher issues, and CloudWatch failures.",
			"pass_criteria": "PASS: No critical errors. WARN: Errors detected. SKIP: Cannot retrieve logs.",
		},
	}

	pods, err := cc.Client.GetPods(ctx, securityNS, "name=audit-exporter")
	if err != nil || len(pods.Items) == 0 {
		// Try broader selector
		ds, dsErr := cc.Client.Clientset().AppsV1().DaemonSets(securityNS).Get(ctx, "audit-exporter", metav1.GetOptions{})
		if dsErr == nil && ds.Spec.Selector != nil {
			if sel, selErr := metav1.LabelSelectorAsSelector(ds.Spec.Selector); selErr == nil {
				pods, err = cc.Client.GetPods(ctx, securityNS, sel.String())
			}
		}
	}

	if err != nil || pods == nil || len(pods.Items) == 0 {
		r.Status = checks.StatusWarning
		r.Message = "No audit-exporter pods found — cannot analyze logs"
		cc.AddResult(r)
		return
	}

	// Find a running pod to get logs from
	var logOutput string
	for _, pod := range pods.Items {
		if string(pod.Status.Phase) == "Running" {
			logOutput, _ = cc.Client.GetPodLogs(ctx, securityNS, pod.Name, 100)
			if logOutput != "" {
				break
			}
		}
	}

	if logOutput == "" {
		r.Status = checks.StatusWarning
		r.Message = "Could not retrieve logs — pods may not be running"
		cc.AddResult(r)
		return
	}

	criticalPatterns := []string{
		"couldn't load policy",
		"error reading file",
		"could not instantiate watcher",
		"could not establish a new watch",
	}
	warningPatterns := []string{
		"ERROR",
		"CloudWatch.*failed",
		"AssumeRoleWithWebIdentity",
		"failed to create log",
	}

	criticalCount := 0
	warningCount := 0
	var errorSamples []string

	for _, line := range strings.Split(logOutput, "\n") {
		lower := strings.ToLower(line)
		for _, p := range criticalPatterns {
			if strings.Contains(lower, strings.ToLower(p)) {
				criticalCount++
				if len(errorSamples) < 5 {
					sample := strings.TrimSpace(line)
					if len(sample) > 200 {
						sample = sample[:200] + "..."
					}
					errorSamples = append(errorSamples, sample)
				}
				break
			}
		}
		for _, p := range warningPatterns {
			if strings.Contains(lower, strings.ToLower(p)) {
				warningCount++
				break
			}
		}
	}

	r.Details["critical_errors"] = criticalCount
	r.Details["warning_errors"] = warningCount
	if len(errorSamples) > 0 {
		r.Details["error_samples"] = errorSamples
	}

	switch {
	case criticalCount > 0:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("%d critical error(s) in SAE logs (policy/file/watcher failures)", criticalCount)
	case warningCount > 5:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d warning-level errors in recent logs", warningCount)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("SAE logs clean (%d warnings)", warningCount)
	}

	cc.AddResult(r)
}

func checkResourceTrends(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("sae_resource_trends")

	r := checks.Result{
		Check:    "sae_resource_trends",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":      securityNS,
			"description":    "7-day CPU and memory timeseries for audit-exporter pods. Detects resource leaks, OOM trends, or capacity issues. SAE has tight limits (128Mi memory, 50m CPU) — resource exhaustion causes audit log loss. 0 peak = pods not running.",
			"pass_criteria":  "PASS: Resources stable. WARN: Trend increasing >50% or 0 peak (not running). SKIP: Metrics unavailable.",
			"lookback_hours": 168.0,
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	now := time.Now().Unix()
	start := now - 604800
	step := 1800

	memQuery := fmt.Sprintf(`sum(container_memory_working_set_bytes{namespace="%s",pod=~"audit-exporter-.*",container!=""})`, securityNS)
	memData, _ := cc.Client.QueryMetricsRange(ctx, memQuery, start, now, step)

	cpuQuery := fmt.Sprintf(`sum(rate(container_cpu_usage_seconds_total{namespace="%s",pod=~"audit-exporter-.*",container!=""}[5m]))`, securityNS)
	cpuData, _ := cc.Client.QueryMetricsRange(ctx, cpuQuery, start, now, step)

	memPoints, _ := thanos.Timeseries(memData)
	cpuPoints, _ := thanos.Timeseries(cpuData)

	if len(memPoints) == 0 && len(cpuPoints) == 0 {
		r.Status = checks.StatusWarning
		r.Message = "No audit-exporter resource metrics — pods may not be running (check sae_daemonset_health)"
		cc.AddResult(r)
		return
	}

	seriesCollected := 0

	if len(memPoints) > 0 {
		r.Details["memory_timeseries"] = thanos.PointsToJSON(memPoints)
		peak := thanos.Peak(memPoints)
		r.Details["peak_memory_mb"] = thanos.Round(peak/(1024*1024), 1)
		_, _, memPct := thanos.Trend(memPoints)
		r.Details["memory_increase_percent"] = thanos.Round(memPct, 2)
		r.Details["memory_trend"] = "stable"
		if memPct > 50 && peak/(1024*1024) > 50 {
			r.Details["memory_trend"] = "increasing"
		}
		seriesCollected++
	}

	if len(cpuPoints) > 0 {
		r.Details["cpu_timeseries"] = thanos.PointsToJSON(cpuPoints)
		peak := thanos.Peak(cpuPoints)
		r.Details["peak_cpu_millicores"] = thanos.Round(peak*1000, 0)
		_, _, cpuPct := thanos.Trend(cpuPoints)
		r.Details["cpu_increase_percent"] = thanos.Round(cpuPct, 2)
		seriesCollected++
	}

	r.Details["series_collected"] = seriesCollected

	memTrend, _ := r.Details["memory_trend"].(string)
	peakMem, _ := r.Details["peak_memory_mb"].(float64)
	peakCPU, _ := r.Details["peak_cpu_millicores"].(float64)

	switch {
	case peakMem == 0 && peakCPU == 0:
		r.Status = checks.StatusWarning
		r.Message = "audit-exporter resource metrics are 0 — pods not consuming resources (likely not running)"
	case memTrend == "increasing":
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("audit-exporter memory trend increasing (peak: %.0f MB)", peakMem)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("audit-exporter resources stable (peak: %.0f MB, %.0fm CPU)", peakMem, peakCPU)
	}

	cc.AddResult(r)
}
