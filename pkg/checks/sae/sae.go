package sae

import (
	"context"
	"fmt"
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
	checkDaemonSetHealth(ctx, cc)
	checkAuditPolicy(ctx, cc)
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
			"description":   "Validates the audit-exporter DaemonSet health on master nodes. The audit-exporter filters Kubernetes API server audit logs, removing noisy entries before forwarding to Splunk. Runs on master nodes only. Deployed via SelectorSyncSet from its own SAAS pipeline (saas-sae).",
			"pass_criteria": "PASS: All pods ready, restarts <=10. WARN: Elevated restarts. FAIL: Pods not ready, crashlooping, or ImagePullBackOff. SKIP: DaemonSet not found.",
		},
	}

	ds, err := cc.Client.Clientset().AppsV1().DaemonSets(securityNS).Get(ctx, "audit-exporter", metav1.GetOptions{})
	cc.RecordError("Get audit-exporter DaemonSet", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusSkip
			r.Severity = checks.SeverityInfo
			r.Message = fmt.Sprintf("audit-exporter DaemonSet not found in %s", securityNS)
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

	// Get pod details using DaemonSet's label selector
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
			"description":   "Validates the osd-audit-policy ConfigMap exists. This ConfigMap defines the audit log filtering rules that the audit-exporter uses to decide which KAS audit events to forward to Splunk and which to drop.",
			"pass_criteria": "PASS: ConfigMap present. WARN: ConfigMap missing — audit-exporter may forward all logs unfiltered.",
		},
	}

	_, err := cc.Client.Clientset().CoreV1().ConfigMaps(securityNS).Get(ctx, "osd-audit-policy", metav1.GetOptions{})
	cc.RecordError("Get osd-audit-policy ConfigMap", err)

	if err != nil {
		r.Status = checks.StatusWarning
		r.Message = "osd-audit-policy ConfigMap missing — audit-exporter may forward all logs unfiltered"
	} else {
		r.Status = checks.StatusPass
		r.Message = "osd-audit-policy ConfigMap present"
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
			"description":    "7-day CPU and memory timeseries for audit-exporter pods. Detects resource leaks, OOM trends, or capacity issues. The audit-exporter runs on master nodes and processes all KAS audit logs — resource exhaustion causes audit log loss.",
			"pass_criteria":  "PASS: Resources stable or pods not running (0 metrics = not running, see daemonset check). WARN: Resource trend increasing >50%. SKIP: Metrics unavailable.",
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
		r.Severity = checks.SeverityWarning
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
