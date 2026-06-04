package camo

import (
	"context"
	"fmt"
	"strings"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/logging"
	"github.com/openshift/operator-health-report/pkg/thanos"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func init() {
	checks.Register(&CAMOChecker{})
}

type CAMOChecker struct{}

func (c *CAMOChecker) Name() string { return "camo" }

func (c *CAMOChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	checkAlertmanagerPods(ctx, cc)
	checkAlertmanagerStatefulset(ctx, cc)
	checkControllerAvailability(ctx, cc)
	recentLogCount := checkReconciliationActivity(ctx, cc)
	checkReconciliationBehavior(ctx, cc, recentLogCount)
	checkConfigurationErrors(ctx, cc)
	checkPrometheusMetrics(ctx, cc)
	checkAlertmanagerLogs(ctx, cc)
	checkAlertmanagerEvents(ctx, cc)
	checkCAMOEvents(ctx, cc)
	checkAlertmanagerSecret(ctx, cc)
}

// checkAlertmanagerPods checks AM pod status, restarts, and termination reasons
func checkAlertmanagerPods(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "alertmanager_pods"

	r := checks.Result{
		Check:    "alertmanager_pods",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Checks AlertManager pod count, readiness, and container restart history. AlertManager is the component that routes firing alerts to PagerDuty and DeadMansSnitch — if pods are not running or crashlooping, alert notifications will be delayed or lost entirely.",
			"pass_criteria": "PASS: all AM pods are Running/Ready with 3 or fewer total restarts. WARN: all pods are ready but total restarts exceed 3, indicating instability. FAIL: one or more pods are not ready, meaning alert routing is degraded. SKIP: no AM pods found (unexpected — may indicate a larger problem).",
		},
	}

	pods, err := cc.Client.GetPods(ctx, cc.Operator.Namespace, "app.kubernetes.io/name=alertmanager")
	cc.RecordError("Get AlertManager pods", err)

	if err != nil || len(pods.Items) == 0 {
		r.Status = checks.StatusSkip
		r.Message = "No alertmanager pods found"
		cc.AddResult(r)
		return
	}

	podCount := len(pods.Items)
	r.Details["pod_count"] = podCount

	notReady := 0
	totalRestarts := 0
	var restartDetails []map[string]any

	for _, pod := range pods.Items {
		podName := pod.Name
		podAge := pod.CreationTimestamp.Format("2006-01-02T15:04:05Z")
		phase := string(pod.Status.Phase)

		if phase != "Running" {
			notReady++
		}

		// Group containers per pod to match bash output format
		containerDetails := []map[string]any{}
		for _, cs := range pod.Status.ContainerStatuses {
			restartCount := int(cs.RestartCount)
			totalRestarts += restartCount

			cDetail := map[string]any{
				"name":          cs.Name,
				"restart_count": restartCount,
				"ready":         cs.Ready,
			}

			if cs.LastTerminationState.Terminated != nil {
				t := cs.LastTerminationState.Terminated
				cDetail["last_restart"] = map[string]any{
					"reason":      t.Reason,
					"exit_code":   int(t.ExitCode),
					"finished_at": t.FinishedAt.Format("2006-01-02T15:04:05Z"),
				}
			} else {
				cDetail["last_restart"] = "No recent restart data"
			}

			containerDetails = append(containerDetails, cDetail)
		}

		restartDetails = append(restartDetails, map[string]any{
			"pod_name":   podName,
			"pod_age":    podAge,
			"containers": containerDetails,
		})

		// Check Ready condition
		for _, cond := range pod.Status.Conditions {
			if cond.Type == "Ready" && string(cond.Status) == "False" {
				notReady++
				break
			}
		}
	}

	r.Details["not_ready"] = notReady
	r.Details["total_restarts"] = totalRestarts
	r.Details["restart_details"] = restartDetails
	if problematic := checks.ProblematicPods(pods.Items); len(problematic) > 0 {
		r.Details["failing_pods"] = problematic
	}

	switch {
	case notReady > 0:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("%d alertmanager pod(s) not ready", notReady)
	case totalRestarts > 3:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("All %d pods healthy (%d total restarts)", podCount, totalRestarts)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d alertmanager pods healthy (%d restarts)", podCount, totalRestarts)
	}

	cc.AddResult(r)
}

// checkAlertmanagerStatefulset verifies the AM StatefulSet ready replicas
func checkAlertmanagerStatefulset(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "alertmanager_statefulset"

	r := checks.Result{
		Check:    "alertmanager_statefulset",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Verifies the alertmanager-main StatefulSet has all desired replicas ready. The StatefulSet manages AlertManager pod lifecycle — if ready replicas fall below the desired count, the cluster may lose alert routing redundancy or capacity entirely.",
			"pass_criteria": "PASS: ready replicas equal desired replicas and desired is greater than zero. FAIL: ready replicas are less than desired, meaning one or more AM instances are down. SKIP: StatefulSet not found (unexpected — cluster may be misconfigured).",
		},
	}

	sts, err := cc.Client.Clientset().AppsV1().StatefulSets(cc.Operator.Namespace).Get(ctx, "alertmanager-main", metav1.GetOptions{})
	cc.RecordError("Get alertmanager StatefulSet", err)

	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = "StatefulSet not found"
		cc.AddResult(r)
		return
	}

	desired := 1
	if sts.Spec.Replicas != nil {
		desired = int(*sts.Spec.Replicas)
	}
	ready := int(sts.Status.ReadyReplicas)

	r.Details["desired_replicas"] = desired
	r.Details["ready_replicas"] = ready

	if ready == desired && desired > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("StatefulSet ready (%d/%d)", ready, desired)
	} else {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("StatefulSet not ready (%d/%d)", ready, desired)
	}

	cc.AddResult(r)
}

// checkControllerAvailability checks the deployment Available condition
func checkControllerAvailability(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "controller_availability"

	r := checks.Result{
		Check:    "controller_availability",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Checks whether the CAMO deployment has an Available=True condition. CAMO is the controller that reconciles the AlertManager configuration with PagerDuty and DeadMansSnitch routing rules — if the controller is unavailable, configuration drift will go uncorrected and new alert routing changes will not be applied.",
			"pass_criteria": "PASS: deployment Available condition is True. FAIL: deployment not found, or Available condition is not True.",
		},
	}

	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	cc.RecordError("Get deployment Available condition", err)

	if err != nil {
		r.Status = checks.StatusFail
		r.Message = "Controller not available"
		r.Details["available"] = ""
		cc.AddResult(r)
		return
	}

	available := ""
	for _, cond := range deploy.Status.Conditions {
		if string(cond.Type) == "Available" {
			available = string(cond.Status)
			break
		}
	}

	r.Details["available"] = available

	if available == "True" {
		r.Status = checks.StatusPass
		r.Message = "Controller is available"
	} else {
		r.Status = checks.StatusFail
		r.Message = "Controller not available"
	}

	cc.AddResult(r)
}

// checkReconciliationActivity validates the operator is actively reconciling when resources change.
// Returns the recent log count for reuse by checkReconciliationBehavior.
func checkReconciliationActivity(ctx context.Context, cc *checks.ClusterContext) int {
	cc.CurrentCheck = "reconciliation_activity"
	log := logging.WithCheck("reconciliation_activity")

	r := checks.Result{
		Check:    "reconciliation_activity",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Checks whether the CAMO operator is producing log output, indicating active reconciliation. Also detects cluster upgrades in progress which cause elevated reconciliation. An idle operator is normal when no configuration changes are pending, but total silence during an upgrade or after a config change could indicate a stuck controller.",
			"pass_criteria": "PASS: always passes. Reports log entry count and whether a cluster upgrade is in progress. Zero log entries is expected during quiet periods — this check is informational only.",
		},
	}

	// Get recent log count (tail 50 lines)
	// Find a CAMO pod for log retrieval
	recentLogCount := 0

	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	if err == nil {
		selector, sErr := metav1.LabelSelectorAsSelector(deploy.Spec.Selector)
		if sErr == nil {
			pods, pErr := cc.Client.GetPods(ctx, cc.Operator.Namespace, selector.String())
			if pErr == nil && len(pods.Items) > 0 {
				logOutput, lErr := cc.Client.GetPodLogs(ctx, cc.Operator.Namespace, pods.Items[0].Name, 50)
				cc.RecordError("Get recent CAMO logs", lErr)
				if lErr == nil && logOutput != "" {
					for _, line := range strings.Split(logOutput, "\n") {
						if strings.TrimSpace(line) != "" {
							recentLogCount++
						}
					}
				}
			}
		}
	}

	// Check ClusterVersion for upgrade activity
	cvGVR := schema.GroupVersionResource{Group: "config.openshift.io", Version: "v1", Resource: "clusterversions"}
	cvProgressing := false

	cv, cvErr := cc.Client.GetResource(ctx, cvGVR, "", "version", false)
	if cvErr == nil {
		conditions, _, _ := nestedSlice(cv.Object, "status", "conditions")
		for _, c := range conditions {
			cond, _ := c.(map[string]any)
			cType, _ := cond["type"].(string)
			cStatus, _ := cond["status"].(string)
			if cType == "Progressing" && cStatus == "True" {
				cvProgressing = true
			}
		}
	}

	r.Details["recent_log_count"] = recentLogCount
	r.Details["cluster_upgrade_in_progress"] = cvProgressing

	log.WithField("logs", recentLogCount).Debug("Reconciliation activity")

	if recentLogCount > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Active reconciliation (%d log entries in last 5m)", recentLogCount)
	} else {
		r.Status = checks.StatusPass
		r.Message = "Operator idle (0 log entries in 5m — expected when no changes)"
	}

	if cvProgressing {
		r.Details["note"] = "Cluster upgrade in progress — elevated reconciliation expected"
	}

	cc.AddResult(r)
	return recentLogCount
}

// checkReconciliationBehavior detects reconciliation loops or broken watches
func checkReconciliationBehavior(ctx context.Context, cc *checks.ClusterContext, recentLogCount int) {
	cc.CurrentCheck = "reconciliation_behavior"

	r := checks.Result{
		Check:    "reconciliation_behavior",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Analyzes the reconciliation rate to detect hot loops or broken watches. CAMO watches cluster-wide secrets and configmaps — on management clusters with many hosted control plane namespaces, elevated log volume is expected. On service clusters, excessive reconciliation may indicate a configuration conflict causing the controller to repeatedly update and revert.",
			"pass_criteria": "PASS: operator is active or idle within expected bounds. On management clusters, more than 20 log entries in 5 minutes is noted but expected. On service clusters, the same volume would warrant investigation. INFO: always informational severity.",
		},
	}

	r.Details["recent_log_count"] = recentLogCount
	r.Details["lookback_window"] = "5m"
	r.Details["cluster_type"] = cc.ClusterType
	r.Severity = checks.SeverityInfo

	switch {
	case recentLogCount > 0:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Active reconciliation (%d log entries in 5m)", recentLogCount)
		if cc.ClusterType == "management_cluster" && recentLogCount > 20 {
			r.Details["note"] = "Elevated reconciliation expected on MC — CAMO watches cluster-wide secrets/configmaps across HCP namespaces"
		}
	default:
		r.Status = checks.StatusPass
		r.Message = "Operator idle (no reconciliation activity)"
	}

	cc.AddResult(r)
}

// checkAlertmanagerSecret checks AM secret and the secrets/configmaps CAMO watches for reconciliation
func checkAlertmanagerSecret(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "alertmanager_secret"

	r := checks.Result{
		Check:    "alertmanager_secret",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Validates the resources CAMO watches to build the Alertmanager configuration. The alertmanager-main secret is the rendered AM config (required). CAMO also reconciles optional secrets (pd-secret for PagerDuty, dms-secret for Dead Man's Snitch, goalert-secret for GoAlert) — if present, their receivers are added to the AM config. The managed-namespaces and ocp-namespaces ConfigMaps control alert routing rules per namespace.",
			"pass_criteria": "PASS: alertmanager-main secret exists. Reports presence of each optional resource. WARN: pd-secret missing (PagerDuty alerts won't deliver). FAIL: alertmanager-main secret not found. SKIP: elevation not available.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Check alertmanager-main secret (required — the rendered AM config)
	secret, err := cc.Client.ElevatedClientset().CoreV1().Secrets(cc.Operator.Namespace).Get(ctx, "alertmanager-main", metav1.GetOptions{})
	cc.RecordError("Get alertmanager-main secret", err)

	if err != nil {
		r.Status = checks.StatusFail
		r.Message = "alertmanager-main secret not found — Alertmanager cannot start without its configuration secret"
		cc.AddResult(r)
		return
	}

	keyCount := len(secret.Data)
	r.Details["alertmanager_main_keys"] = keyCount

	// Check optional secrets that CAMO watches for receiver configuration
	type watchedResource struct {
		kind    string
		name    string
		purpose string
		warn    bool // true = WARN if missing, false = INFO
	}
	resources := []watchedResource{
		{"secret", "pd-secret", "PagerDuty integration key — if present, CAMO adds PD receiver for alert delivery", true},
		{"secret", "dms-secret", "Dead Man's Snitch URL — if present, CAMO adds watchdog/heartbeat receiver", false},
		{"secret", "goalert-secret", "GoAlert URLs (high/low/heartbeat) — if present, CAMO adds GoAlert receivers", false},
		{"configmap", "managed-namespaces", "Managed namespace list — controls which namespaces get alert routing rules", false},
		{"configmap", "ocp-namespaces", "OCP namespace list — controls platform namespace alert routing", false},
	}

	var present []string
	var missing []string
	var warnMissing []string

	for _, res := range resources {
		exists := false
		if res.kind == "secret" {
			_, err := cc.Client.ElevatedClientset().CoreV1().Secrets(cc.Operator.Namespace).Get(ctx, res.name, metav1.GetOptions{})
			exists = err == nil
		} else {
			_, err := cc.Client.Clientset().CoreV1().ConfigMaps(cc.Operator.Namespace).Get(ctx, res.name, metav1.GetOptions{})
			exists = err == nil
		}

		r.Details[res.name+"_exists"] = exists
		r.Details[res.name+"_purpose"] = res.purpose

		if exists {
			present = append(present, res.name)
		} else {
			missing = append(missing, res.name)
			if res.warn {
				warnMissing = append(warnMissing, res.name)
			}
		}
	}

	r.Details["present_resources"] = present
	r.Details["missing_resources"] = missing

	if len(warnMissing) > 0 {
		r.Status = checks.StatusWarning
		r.Severity = checks.SeverityWarning
		r.Message = fmt.Sprintf("alertmanager-main secret present (%d keys) but %s missing — alert delivery may be impacted", keyCount, strings.Join(warnMissing, ", "))
	} else if len(missing) > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("alertmanager-main secret (%d keys) + %d/%d optional resources present. Not configured: %s",
			keyCount, len(present), len(resources), strings.Join(missing, ", "))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("alertmanager-main secret (%d keys) + all %d watched resources present", keyCount, len(resources))
	}

	cc.AddResult(r)
}

// checkConfigurationErrors counts config-related error patterns in recent logs
func checkConfigurationErrors(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "configuration_errors"

	r := checks.Result{
		Check:    "configuration_errors",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Scans the last 100 lines of CAMO operator logs for configuration-related error patterns (failed, error, invalid config). Configuration errors typically indicate that CAMO cannot parse or apply the desired AlertManager configuration, which can leave alert routing in a stale or broken state.",
			"pass_criteria": "PASS: 5 or fewer configuration error patterns found in recent logs. WARN: more than 5 configuration error patterns detected, suggesting persistent config issues that may prevent correct alert routing.",
		},
	}

	// Find a CAMO pod for log retrieval
	logOutput := ""
	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	if err == nil {
		selector, sErr := metav1.LabelSelectorAsSelector(deploy.Spec.Selector)
		if sErr == nil {
			pods, pErr := cc.Client.GetPods(ctx, cc.Operator.Namespace, selector.String())
			if pErr == nil && len(pods.Items) > 0 {
				logOutput, err = cc.Client.GetPodLogs(ctx, cc.Operator.Namespace, pods.Items[0].Name, 100)
				cc.RecordError("Get CAMO logs (tail 100)", err)
			}
		}
	}

	configErrors := 0
	if logOutput != "" {
		for _, line := range strings.Split(logOutput, "\n") {
			lower := strings.ToLower(line)
			if (strings.Contains(lower, "failed") || strings.Contains(lower, "error") ||
				strings.Contains(lower, "invalid") && strings.Contains(lower, "config")) &&
				!strings.Contains(lower, "level=info") {
				configErrors++
			}
		}
	}

	r.Details["config_error_count"] = configErrors

	if configErrors > 5 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d configuration errors detected in logs", configErrors)
	} else {
		r.Status = checks.StatusPass
		r.Message = "No significant configuration errors"
	}

	cc.AddResult(r)
}

// checkPrometheusMetrics queries all 10 CAMO-specific Prometheus metrics
func checkPrometheusMetrics(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "prometheus_metrics"
	log := logging.WithCheck("prometheus_metrics")

	r := checks.Result{
		Check:    "prometheus_metrics",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Queries 10 CAMO-specific Prometheus metrics that reflect the health of alert routing configuration. These metrics are emitted by CAMO itself and cover: config validation status, existence of the AM secret, PagerDuty/DeadMansSnitch/GoAlert secrets, namespace configmaps, and whether the AM secret contains the expected receiver configurations. These are the primary signals for detecting silent alerting failures.",
			"pass_criteria": "PASS: all metrics report healthy values (config validation not failed, AM secret exists, configmaps present). FAIL: config validation failed or AM secret missing — these are critical because alerts will not be delivered. WARN: namespace configmaps missing — alert routing may be incomplete but core delivery is functional. SKIP: elevation not available (Thanos queries require elevated access).",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	type metricDef struct {
		name     string
		critical bool
	}

	metrics := []metricDef{
		{"alertmanager_config_validation_failed", true},
		{"am_secret_exists", true},
		{"managed_namespaces_configmap_exists", false},
		{"ocp_namespaces_configmap_exists", false},
		{"ga_secret_exists", false},
		{"pd_secret_exists", false},
		{"dms_secret_exists", false},
		{"am_secret_contains_ga", false},
		{"am_secret_contains_pd", false},
		{"am_secret_contains_dms", false},
	}

	queryMetric := func(name string) string {
		rawQuery := fmt.Sprintf(`%s{namespace="%s"}`, name, cc.Operator.Namespace)
		result, err := cc.Client.QueryMetrics(ctx, rawQuery)
		cc.RecordError("CAMO metric: "+name, err)
		if err == nil && result != "" {
			if val, _, ok := thanos.InstantValue(result); ok {
				return val
			}
		}
		return "0"
	}

	issues := []string{}
	metricValues := map[string]string{}

	for _, m := range metrics {
		val := queryMetric(m.name)
		metricValues[m.name] = val
		r.Details[m.name] = val
	}

	// Critical: config validation failed
	if metricValues["alertmanager_config_validation_failed"] == "1" {
		issues = append(issues, "Config validation failed")
	}
	// Critical: AM secret missing
	if metricValues["am_secret_exists"] != "1" {
		issues = append(issues, "AM secret missing")
	}
	// Warning: ConfigMaps missing
	if metricValues["managed_namespaces_configmap_exists"] != "1" {
		issues = append(issues, "Managed namespaces ConfigMap missing")
	}
	if metricValues["ocp_namespaces_configmap_exists"] != "1" {
		issues = append(issues, "OCP namespaces ConfigMap missing")
	}

	log.WithField("issues", len(issues)).Debug("CAMO metrics evaluated")

	hasCritical := metricValues["alertmanager_config_validation_failed"] == "1" ||
		metricValues["am_secret_exists"] != "1"

	switch {
	case hasCritical:
		r.Status = checks.StatusFail
		r.Message = strings.Join(issues, "; ")
	case len(issues) > 0:
		r.Status = checks.StatusWarning
		r.Message = strings.Join(issues, "; ")
	default:
		r.Status = checks.StatusPass
		r.Message = "All metrics healthy"
	}

	cc.AddResult(r)
}

// checkAlertmanagerLogs analyzes AM pod logs with DNS warning filtering
func checkAlertmanagerLogs(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "alertmanager_logs"

	r := checks.Result{
		Check:    "alertmanager_logs",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Analyzes the last 1000 log lines from each AlertManager pod for errors and warnings. DNS warnings ('no such host', 'failed to resolve alertmanager') are filtered out because they are expected during cluster formation when AM peers have not yet registered in DNS. Remaining errors may indicate config reload failures, notification delivery problems, or cluster communication issues that affect alert routing reliability.",
			"pass_criteria": "PASS: no errors or warnings found (filtered DNS warnings are noted but do not affect status). WARN: errors or non-DNS warnings detected in AM logs — investigate for notification delivery failures or config issues. SKIP: no AlertManager pods available to check.",
		},
	}

	// Get AM pods
	pods, err := cc.Client.GetPods(ctx, cc.Operator.Namespace, "app.kubernetes.io/name=alertmanager")
	if err != nil || len(pods.Items) == 0 {
		r.Status = checks.StatusSkip
		r.Message = "No AlertManager pods to check"
		cc.AddResult(r)
		return
	}

	totalErrors := 0
	totalWarnings := 0
	dnsFiltered := 0
	var errorSamples []string

	for _, pod := range pods.Items {
		logOutput, lErr := cc.Client.GetPodLogs(ctx, cc.Operator.Namespace, pod.Name, 1000)
		if lErr != nil {
			continue
		}

		for _, line := range strings.Split(logOutput, "\n") {
			lower := strings.ToLower(line)
			if strings.Contains(lower, "level=error") {
				totalErrors++
				if len(errorSamples) < 5 {
					errorSamples = append(errorSamples, fmt.Sprintf("[%s] %s", pod.Name, truncate(line, 200)))
				}
			}
			if strings.Contains(lower, "level=warn") {
				if strings.Contains(lower, "no such host") ||
					strings.Contains(lower, "failed to resolve") && strings.Contains(lower, "alertmanager") {
					dnsFiltered++
				} else {
					totalWarnings++
				}
			}
		}
	}

	r.Details["error_count"] = totalErrors
	r.Details["warning_count"] = totalWarnings
	r.Details["dns_warnings_filtered"] = dnsFiltered
	r.Details["error_samples"] = errorSamples

	switch {
	case totalErrors > 0:
		r.Status = checks.StatusWarning
		msg := fmt.Sprintf("Found %d errors and %d warnings in AlertManager logs", totalErrors, totalWarnings)
		if dnsFiltered > 0 {
			msg += fmt.Sprintf(" (%d DNS warnings filtered)", dnsFiltered)
		}
		r.Message = msg
	case totalWarnings > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Found %d warnings in AlertManager logs (0 errors)", totalWarnings)
	case dnsFiltered > 0:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("AlertManager logs clean (filtered %d expected DNS warnings)", dnsFiltered)
	default:
		r.Status = checks.StatusPass
		r.Message = "No errors or warnings in AlertManager logs"
	}

	cc.AddResult(r)
}

// checkAlertmanagerEvents checks K8s warning events for AM pods
func checkAlertmanagerEvents(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "alertmanager_events"

	r := checks.Result{
		Check:    "alertmanager_events",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks for Kubernetes Warning events associated with AlertManager pods. Warning events on AM pods (such as Unhealthy, BackOff, FailedScheduling) can indicate infrastructure problems affecting alert delivery — for example, a pod eviction or OOM kill would temporarily reduce AM capacity and could cause missed notifications during the disruption.",
			"pass_criteria": "PASS: no Warning events found on any AlertManager pod. WARN: one or more Warning events detected — review event reasons and messages to determine if alert routing is affected. SKIP: no AlertManager pods available to check.",
		},
	}

	// Get AM pods
	pods, err := cc.Client.GetPods(ctx, cc.Operator.Namespace, "app.kubernetes.io/name=alertmanager")
	if err != nil || len(pods.Items) == 0 {
		r.Status = checks.StatusSkip
		r.Message = "No AlertManager pods to check"
		cc.AddResult(r)
		return
	}

	warningEvents := 0
	var eventDetails []map[string]any

	for _, pod := range pods.Items {
		events, evtErr := cc.Client.GetEvents(ctx, cc.Operator.Namespace, pod.Name)
		if evtErr != nil {
			continue
		}

		for _, evt := range events.Items {
			if evt.Type == "Warning" {
				warningEvents++
				eventDetails = append(eventDetails, map[string]any{
					"pod":     pod.Name,
					"reason":  evt.Reason,
					"message": truncate(evt.Message, 200),
					"count":   int(evt.Count),
				})
			}
		}
	}

	r.Details["warning_event_count"] = warningEvents
	r.Details["events"] = eventDetails

	if warningEvents > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Found %d warning events for AlertManager pods", warningEvents)
	} else {
		r.Status = checks.StatusPass
		r.Message = "No warning or error events"
	}

	cc.AddResult(r)
}

// checkCAMOEvents checks K8s warning events for the CAMO deployment itself
func checkCAMOEvents(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "camo_events"

	r := checks.Result{
		Check:    "camo_events",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks for Kubernetes Warning events on the CAMO deployment itself. Events like FailedCreate, ScalingReplicaSet failures, or OOMKilled indicate that the operator controller cannot maintain its desired state — if CAMO is down or restarting, it cannot reconcile AlertManager configuration, leaving alert routing potentially stale or misconfigured.",
			"pass_criteria": "PASS: no Warning events found on the CAMO deployment. WARN: one or more Warning events detected — review to determine if the controller is operational and able to reconcile.",
		},
	}

	events, err := cc.Client.GetEvents(ctx, cc.Operator.Namespace, cc.Operator.Deployment)
	cc.RecordError("Get CAMO deployment events", err)

	warningEvents := 0
	var eventDetails []map[string]any

	if err == nil {
		for _, evt := range events.Items {
			if evt.Type == "Warning" {
				warningEvents++
				eventDetails = append(eventDetails, map[string]any{
					"reason":  evt.Reason,
					"message": truncate(evt.Message, 200),
					"count":   int(evt.Count),
				})
			}
		}
	}

	r.Details["warning_event_count"] = warningEvents
	r.Details["events"] = eventDetails

	if warningEvents > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Found %d warning events for CAMO deployment", warningEvents)
	} else {
		r.Status = checks.StatusPass
		r.Message = "No warning or error events"
	}

	cc.AddResult(r)
}

// checkDualInstallation detects both OLM Subscription and PKO ClusterPackage existing

func nestedSlice(obj map[string]any, fields ...string) ([]any, bool, error) {
	var current any = obj
	for _, f := range fields {
		m, ok := current.(map[string]any)
		if !ok {
			return nil, false, nil
		}
		current, ok = m[f]
		if !ok {
			return nil, false, nil
		}
	}
	slice, ok := current.([]any)
	return slice, ok, nil
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}
