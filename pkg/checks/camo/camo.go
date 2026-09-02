package camo

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

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
	checkClusterReadiness(ctx, cc)
	checkAlertmanagerReloadHealth(ctx, cc)
	checkAlertmanagerConfigCompatibility(ctx, cc)
	checkAlertmanagerLogs(ctx, cc)
	checkAlertmanagerEvents(ctx, cc)
	checkCAMOEvents(ctx, cc)
	checkAlertmanagerSecret(ctx, cc)
	checkDMSWatchdog(ctx, cc)
	checkDMSHeartbeatDelivery(ctx, cc)
}

// checkAlertmanagerPods checks AM pod status, restarts, and termination reasons
func checkAlertmanagerPods(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("alertmanager_pods")

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
	cc.SetCheck("alertmanager_statefulset")

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
	cc.SetCheck("controller_availability")

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
	cc.SetCheck("reconciliation_activity")
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
	cc.SetCheck("reconciliation_behavior")

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
	cc.SetCheck("alertmanager_secret")

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
	cc.Client.RecordElevatedOp(fmt.Sprintf("[%s] ", cc.CurrentCheck) + fmt.Sprintf("get secrets/alertmanager-main in %s", cc.Operator.Namespace))
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
			cc.Client.RecordElevatedOp(fmt.Sprintf("[%s] ", cc.CurrentCheck) + fmt.Sprintf("get secrets/%s in %s", res.name, cc.Operator.Namespace))
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
	cc.SetCheck("configuration_errors")

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
	cc.SetCheck("camo_alerting_config")
	log := logging.WithCheck("camo_alerting_config")

	r := checks.Result{
		Check:    "camo_alerting_config",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Queries 10 CAMO-specific Prometheus metrics that reflect the health of alert routing configuration. These metrics are emitted by CAMO itself and cover: config validation status, existence of the AM secret, PagerDuty/DeadMansSnitch/GoAlert secrets, namespace configmaps, and whether the AM secret contains the expected receiver configurations. These are the primary signals for detecting silent alerting failures.",
			"pass_criteria": "PASS: all metrics report healthy values (config validation not failed, AM secret exists, configmaps present). FAIL: config validation failed or AM secret missing — these are critical because alerts will not be delivered. WARN: namespace configmaps missing — alert routing may be incomplete but core delivery is functional. SKIP: metrics not available.",
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

	// queryMetric returns the metric value, or "" if the query failed or returned no data.
	queryMetric := func(name string) string {
		rawQuery := fmt.Sprintf(`%s{namespace="%s"}`, name, cc.Operator.Namespace)
		result, err := cc.Client.QueryMetrics(ctx, rawQuery)
		cc.RecordError("CAMO metric: "+name, err)
		if err == nil && result != "" {
			if val, _, ok := thanos.InstantValue(result); ok {
				return val
			}
		}
		return ""
	}

	issues := []string{}
	metricValues := map[string]string{}
	queryFailures := 0

	for _, m := range metrics {
		val := queryMetric(m.name)
		metricValues[m.name] = val
		if val == "" {
			queryFailures++
			r.Details[m.name] = "unavailable"
		} else {
			r.Details[m.name] = val
		}
	}

	// If all metrics failed to query, report as INFO rather than false failures
	if queryFailures == len(metrics) {
		r.Status = checks.StatusInfo
		r.Severity = checks.SeverityInfo
		r.Message = "CAMO alerting metrics not available — operator may not be emitting metrics yet"
		cc.AddResult(r)
		return
	}

	// Critical: config validation failed
	if metricValues["alertmanager_config_validation_failed"] == "1" {
		issues = append(issues, "Config validation failed")
	}
	// Critical: AM secret missing (only flag if metric was actually queried)
	if metricValues["am_secret_exists"] != "" && metricValues["am_secret_exists"] != "1" {
		issues = append(issues, "AM secret missing")
	}
	// Warning: ConfigMaps missing (only flag if metric was actually queried)
	if metricValues["managed_namespaces_configmap_exists"] != "" && metricValues["managed_namespaces_configmap_exists"] != "1" {
		issues = append(issues, "Managed namespaces ConfigMap missing")
	}
	if metricValues["ocp_namespaces_configmap_exists"] != "" && metricValues["ocp_namespaces_configmap_exists"] != "1" {
		issues = append(issues, "OCP namespaces ConfigMap missing")
	}

	log.WithField("issues", len(issues)).Debug("CAMO alerting config metrics evaluated")

	hasCritical := metricValues["alertmanager_config_validation_failed"] == "1" ||
		(metricValues["am_secret_exists"] != "" && metricValues["am_secret_exists"] != "1")

	switch {
	case hasCritical:
		r.Status = checks.StatusFail
		r.Message = strings.Join(issues, "; ")
	case len(issues) > 0:
		r.Status = checks.StatusWarning
		r.Message = strings.Join(issues, "; ")
	default:
		r.Status = checks.StatusPass
		if queryFailures > 0 {
			r.Message = fmt.Sprintf("Available metrics healthy (%d of %d metrics unavailable)", queryFailures, len(metrics))
		} else {
			r.Message = "All alerting config metrics healthy"
		}
	}

	cc.AddResult(r)
}

// checkClusterReadiness validates that CAMO has completed PagerDuty configuration.
// CAMO gates PD/GoAlert setup on cluster readiness (all ClusterOperators healthy or
// cluster age > 90min). On established clusters, am_secret_contains_pd=0 indicates
// a real problem. On new clusters, it's expected during the readiness window.
// This check replaces the former osd-cluster-ready Job (ROSAENG-1342).
func checkClusterReadiness(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("camo_cluster_readiness")
	log := logging.WithCheck("camo_cluster_readiness")

	r := checks.Result{
		Check:    "camo_cluster_readiness",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates that CAMO has completed PagerDuty configuration for this cluster. CAMO gates PD/GoAlert activation on cluster readiness: all ClusterOperators must be Available=true, Progressing=false, Degraded=false, or the cluster must be older than 90 minutes (fallback). Until ready, PD is not configured and alerts won't page. This replaced the former osd-cluster-ready Job (ROSAENG-1342). DMS (DeadMansSnitch) is always configured regardless of readiness.",
			"pass_criteria": "PASS: PD configured (am_secret_contains_pd=1). INFO: cluster <90min old and PD not yet configured (expected during readiness window). WARN: cluster >90min old but PD not configured — readiness may be stuck. FAIL: cluster >4h old and PD not configured — PD configuration has failed.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Check if PD is configured
	pdBody, err := cc.Client.QueryMetrics(ctx, fmt.Sprintf(`am_secret_contains_pd{namespace="%s"}`, cc.Operator.Namespace))
	cc.RecordError("Query am_secret_contains_pd", err)

	pdConfigured := false
	if err == nil && pdBody != "" {
		if val, _, ok := thanos.InstantValue(pdBody); ok {
			r.Details["am_secret_contains_pd"] = val
			pdConfigured = val == "1"
		}
	}

	if pdConfigured {
		r.Status = checks.StatusPass
		r.Message = "PagerDuty configured — cluster readiness complete"
		cc.AddResult(r)
		return
	}

	// PD not configured — determine cluster age to assess severity
	// Use cluster_version{type="initial"} (same metric CAMO uses for readiness)
	var clusterAgeHours float64
	ageSource := ""

	cvBody, cvErr := cc.Client.QueryMetrics(ctx, `cluster_version{type="initial"}`)
	if cvErr == nil && cvBody != "" {
		if val, _, ok := thanos.InstantValue(cvBody); ok {
			if ts, parseErr := strconv.ParseFloat(val, 64); parseErr == nil && ts > 0 {
				clusterAgeHours = time.Since(time.Unix(int64(ts), 0)).Hours()
				ageSource = "cluster_version_metric"
			}
		}
	}

	// Fallback: use OCM metadata creation time
	if clusterAgeHours == 0 && cc.Metadata != nil {
		if created, parseErr := time.Parse(time.RFC3339, cc.Metadata.CreatedAt); parseErr == nil {
			clusterAgeHours = time.Since(created).Hours()
			ageSource = "ocm_metadata"
		}
	}

	r.Details["cluster_age_hours"] = fmt.Sprintf("%.1f", clusterAgeHours)
	r.Details["age_source"] = ageSource

	log.WithField("cluster_age_hours", clusterAgeHours).WithField("pd_configured", pdConfigured).Debug("Cluster readiness assessment")

	switch {
	case clusterAgeHours == 0:
		r.Status = checks.StatusWarning
		r.Message = "PagerDuty NOT configured — cannot determine cluster age to assess severity"
	case clusterAgeHours < 1.5:
		r.Status = checks.StatusInfo
		r.Severity = checks.SeverityInfo
		r.Message = fmt.Sprintf("PagerDuty not yet configured — cluster is %.0fm old (readiness window is 90m)", clusterAgeHours*60)
	case clusterAgeHours < 4:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("PagerDuty NOT configured — cluster is %.1fh old (past 90m readiness window) — CAMO readiness check may be stuck", clusterAgeHours)
	default:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("PagerDuty NOT configured — cluster is %.0fh old — alerts are NOT paging (ROSAENG-1342)", clusterAgeHours)
	}

	// Also check DMS (should always be configured regardless of readiness)
	dmsBody, dmsErr := cc.Client.QueryMetrics(ctx, fmt.Sprintf(`am_secret_contains_dms{namespace="%s"}`, cc.Operator.Namespace))
	if dmsErr == nil && dmsBody != "" {
		if val, _, ok := thanos.InstantValue(dmsBody); ok {
			r.Details["am_secret_contains_dms"] = val
			if val != "1" {
				r.Details["dms_issue"] = "DMS not configured — should be present regardless of cluster readiness"
			}
		}
	}

	cc.AddResult(r)
}

// checkAlertmanagerReloadHealth queries Alertmanager's native Prometheus metrics
// to verify the config CAMO wrote was actually loaded successfully. This catches
// issues where CAMO's own validation passes but Alertmanager rejects the config
// (e.g., toJson template function not supported on older AM versions).
func checkAlertmanagerReloadHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("alertmanager_reload_health")
	log := logging.WithCheck("alertmanager_reload_health")

	r := checks.Result{
		Check:    "alertmanager_reload_health",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Queries Alertmanager's native Prometheus metrics to verify the configuration was loaded successfully. alertmanager_config_last_reload_successful=0 means the last reload FAILED — Alertmanager is running with stale config and alerts may not be delivered. This catches issues that CAMO's own validation misses (e.g., template functions unsupported by the cluster's Alertmanager version).",
			"pass_criteria": "PASS: All AM instances report reload successful. FAIL: Any instance reports reload failed. WARN: Reload succeeded but config is stale (>24h since last reload). SKIP: Metrics unavailable.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Check reload success status per AM pod
	reloadQuery := fmt.Sprintf(`alertmanager_config_last_reload_successful{namespace="%s"}`, cc.Operator.Namespace)
	reloadBody, reloadErr := cc.Client.QueryMetrics(ctx, reloadQuery)
	cc.RecordError("Query AM reload status", reloadErr)

	if reloadErr != nil {
		if checks.IsAccessError(reloadErr) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusSkip
		r.Message = "Alertmanager reload metrics not available"
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(reloadBody) {
		r.Status = checks.StatusSkip
		r.Message = "No alertmanager_config_last_reload_successful metric found"
		cc.AddResult(r)
		return
	}

	resp, _ := thanos.Parse(reloadBody)
	totalInstances := 0
	failedInstances := 0
	var failedPods []string

	for _, result := range resp.Data.Result {
		val, ok := thanos.ToFloat(result)
		if !ok {
			continue
		}
		totalInstances++
		pod := result.Metric["pod"]
		if pod == "" {
			pod = result.Metric["instance"]
		}
		if val == 0 {
			failedInstances++
			failedPods = append(failedPods, pod)
		}
	}

	r.Details["total_instances"] = totalInstances
	r.Details["failed_instances"] = failedInstances
	if len(failedPods) > 0 {
		r.Details["failed_pods"] = failedPods
	}

	// Check when the last successful reload happened
	timestampQuery := fmt.Sprintf(`alertmanager_config_last_reload_success_timestamp_seconds{namespace="%s"}`, cc.Operator.Namespace)
	tsBody, tsErr := cc.Client.QueryMetrics(ctx, timestampQuery)
	if tsErr == nil && thanos.HasResults(tsBody) {
		tsResp, _ := thanos.Parse(tsBody)
		var oldestReload float64
		for _, result := range tsResp.Data.Result {
			val, ok := thanos.ToFloat(result)
			if !ok {
				continue
			}
			if oldestReload == 0 || val < oldestReload {
				oldestReload = val
			}
		}
		if oldestReload > 0 {
			reloadTime := time.Unix(int64(oldestReload), 0)
			age := time.Since(reloadTime)
			r.Details["oldest_reload_time"] = reloadTime.UTC().Format(time.RFC3339)
			r.Details["oldest_reload_age_hours"] = thanos.Round(age.Hours(), 1)
		}
	}

	// Check config hash for consistency across instances
	hashQuery := fmt.Sprintf(`alertmanager_config_hash{namespace="%s"}`, cc.Operator.Namespace)
	hashBody, hashErr := cc.Client.QueryMetrics(ctx, hashQuery)
	if hashErr == nil && thanos.HasResults(hashBody) {
		hashResp, _ := thanos.Parse(hashBody)
		hashes := map[string][]string{}
		for _, result := range hashResp.Data.Result {
			val, ok := thanos.ToFloat(result)
			if !ok {
				continue
			}
			hashStr := fmt.Sprintf("%.0f", val)
			pod := result.Metric["pod"]
			if pod == "" {
				pod = result.Metric["instance"]
			}
			hashes[hashStr] = append(hashes[hashStr], pod)
		}
		r.Details["config_hash_count"] = len(hashes)
		if len(hashes) > 1 {
			r.Details["config_hash_mismatch"] = true
			r.Details["config_hashes"] = hashes
		}
	}

	// Check notification failure metrics
	notifFailQuery := fmt.Sprintf(`sum(rate(alertmanager_notifications_failed_total{namespace="%s"}[5m]))`, cc.Operator.Namespace)
	notifBody, notifErr := cc.Client.QueryMetrics(ctx, notifFailQuery)
	if notifErr == nil && thanos.HasResults(notifBody) {
		if rate, ok := thanos.InstantFloat(notifBody); ok {
			r.Details["notification_failure_rate"] = thanos.Round(rate, 4)
		}
	}

	log.WithField("failed", failedInstances).WithField("total", totalInstances).Debug("AM reload health evaluated")

	switch {
	case failedInstances > 0:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Alertmanager config reload FAILED on %d/%d instance(s): %s — running stale config, alerts may not be delivered",
			failedInstances, totalInstances, strings.Join(failedPods, ", "))
	case r.Details["config_hash_mismatch"] != nil:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Config hash mismatch across %d AM instances — possible split-brain or partial reload", totalInstances)
	default:
		ageHours, _ := r.Details["oldest_reload_age_hours"].(float64)
		if ageHours > 24 {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("Reload successful on %d instances but config is %.0fh old — CAMO may not be reconciling", totalInstances, ageHours)
		} else {
			r.Status = checks.StatusPass
			r.Message = fmt.Sprintf("Config reload successful on all %d AM instance(s)", totalInstances)
		}
	}

	cc.AddResult(r)
}

// Template functions that require a minimum Alertmanager version.
// Functions not listed here are baseline functions available in all supported AM versions.
var templateFuncMinVersion = map[string]string{
	// AM 0.28.0 (OCP 4.19)
	"since":            "0.28.0",
	"humanizeDuration": "0.28.0",
	"date":             "0.28.0",
	"tz":               "0.28.0",
	// AM 0.30.0 (OCP 4.22)
	"toJson": "0.30.0",
	// AM 0.32.0 (future)
	"list":       "0.32.0",
	"dict":       "0.32.0",
	"append":     "0.32.0",
	"now":        "0.32.0",
	"toDate":     "0.32.0",
	"mustToDate": "0.32.0",
}

// Maps OCP minor version to the Alertmanager version shipped with that release.
var ocpToAMVersion = map[int]string{
	16: "0.26.0",
	17: "0.27.0",
	18: "0.27.0",
	19: "0.28.0",
	20: "0.28.1",
	21: "0.29.0",
	22: "0.31.1",
}

var templateExprRe = regexp.MustCompile(`\{\{-?\s*(.+?)\s*-?\}\}`)

func semverComponents(v string) (int, int, int) {
	v = strings.TrimPrefix(v, "v")
	parts := strings.SplitN(v, ".", 3)
	major, _ := strconv.Atoi(parts[0])
	minor := 0
	patch := 0
	if len(parts) > 1 {
		minor, _ = strconv.Atoi(parts[1])
	}
	if len(parts) > 2 {
		p := parts[2]
		if idx := strings.IndexAny(p, "-+"); idx >= 0 {
			p = p[:idx]
		}
		patch, _ = strconv.Atoi(p)
	}
	return major, minor, patch
}

func semverLessThan(a, b string) bool {
	aMaj, aMin, aPat := semverComponents(a)
	bMaj, bMin, bPat := semverComponents(b)
	if aMaj != bMaj {
		return aMaj < bMaj
	}
	if aMin != bMin {
		return aMin < bMin
	}
	return aPat < bPat
}

var amVersionRe = regexp.MustCompile(`\bv?(\d+\.\d+\.\d+)\b`)

func detectAMVersion(ctx context.Context, cc *checks.ClusterContext) (string, string) {
	// Strategy 1: Parse semver from StatefulSet image tag
	sts, err := cc.Client.Clientset().AppsV1().StatefulSets(cc.Operator.Namespace).Get(ctx, "alertmanager-main", metav1.GetOptions{})
	if err == nil && sts != nil {
		for _, c := range sts.Spec.Template.Spec.Containers {
			if c.Name == "alertmanager" || strings.Contains(c.Image, "alertmanager") {
				if m := amVersionRe.FindString(c.Image); m != "" {
					return strings.TrimPrefix(m, "v"), "image_tag"
				}
			}
		}
	}

	// Strategy 2: Parse semver from running pod image
	pods, podErr := cc.Client.GetPods(ctx, cc.Operator.Namespace, "app.kubernetes.io/name=alertmanager")
	if podErr == nil {
		for _, pod := range pods.Items {
			for _, cs := range pod.Status.ContainerStatuses {
				if strings.Contains(cs.Image, "alertmanager") {
					if m := amVersionRe.FindString(cs.Image); m != "" {
						return strings.TrimPrefix(m, "v"), "pod_image"
					}
				}
			}
		}
	}

	// Strategy 3: Map from OCP version
	if cc.ClusterVersion != "" {
		var minor int
		fmt.Sscanf(cc.ClusterVersion, "4.%d", &minor)
		if amVer, ok := ocpToAMVersion[minor]; ok {
			return amVer, "ocp_mapping"
		}
	}

	return "", "unknown"
}

func checkAlertmanagerConfigCompatibility(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("alertmanager_config_compatibility")

	r := checks.Result{
		Check:    "alertmanager_config_compatibility",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Proactively checks whether the Alertmanager config CAMO wrote uses template functions that the cluster's Alertmanager version doesn't support. Catches incompatibilities like toJson (requires AM 0.30.0+) on clusters running older AM versions BEFORE they cause notification failures. Works on any cluster regardless of OCP version by comparing config content against the detected AM version.",
			"pass_criteria": "PASS: All template functions compatible. FAIL: Config uses functions unsupported by this AM version. WARN: Can't determine AM version. SKIP: Elevation unavailable or AM not deployed.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Detect AM version
	amVersion, amSource := detectAMVersion(ctx, cc)
	r.Details["ocp_version"] = cc.ClusterVersion

	if amVersion == "" {
		r.Status = checks.StatusWarning
		r.Message = "Cannot determine Alertmanager version — unable to validate config compatibility"
		cc.AddResult(r)
		return
	}

	r.Details["am_version"] = amVersion
	r.Details["am_version_source"] = amSource

	// Read the alertmanager-main secret
	cc.Client.RecordElevatedOp(fmt.Sprintf("[%s] get secrets/alertmanager-main in %s", cc.CurrentCheck, cc.Operator.Namespace))
	secret, err := cc.Client.ElevatedClientset().CoreV1().Secrets(cc.Operator.Namespace).Get(ctx, "alertmanager-main", metav1.GetOptions{})
	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = "Cannot read alertmanager-main secret"
		cc.AddResult(r)
		return
	}

	configBytes, ok := secret.Data["alertmanager.yaml"]
	if !ok {
		r.Status = checks.StatusSkip
		r.Message = "alertmanager.yaml key not found in alertmanager-main secret"
		cc.AddResult(r)
		return
	}

	configStr := string(configBytes)
	r.Details["config_size_bytes"] = len(configBytes)

	// Scan for template expressions and check function compatibility
	expressions := templateExprRe.FindAllStringSubmatch(configStr, -1)
	r.Details["template_blocks_parsed"] = len(expressions)

	type incompatFunc struct {
		Function   string `json:"function"`
		RequiresAM string `json:"requires_am"`
		ClusterAM  string `json:"cluster_am"`
		Expression string `json:"expression"`
	}

	// Known AM baseline template functions (available in all supported versions)
	baselineFunctions := map[string]bool{
		"toUpper": true, "toLower": true, "title": true, "trimSpace": true,
		"join": true, "match": true, "safeHtml": true, "safeUrl": true,
		"reReplaceAll": true, "stringSlice": true, "urlUnescape": true,
	}
	// Go template builtins and keywords to ignore
	ignoreWords := map[string]bool{
		"if": true, "else": true, "end": true, "range": true, "with": true,
		"define": true, "template": true, "block": true, "nil": true, "not": true,
		"and": true, "or": true, "eq": true, "ne": true, "lt": true, "le": true,
		"gt": true, "ge": true, "len": true, "index": true, "call": true,
		"print": true, "printf": true, "println": true, "html": true, "js": true,
		"urlquery": true, "slice": true, "default": true,
		"Alerts": true, "Firing": true, "Resolved": true, "Labels": true,
		"Annotations": true, "Status": true, "CommonLabels": true,
		"CommonAnnotations": true, "ExternalURL": true, "GroupLabels": true,
		"GroupKey": true, "Receiver": true, "StartsAt": true, "EndsAt": true,
		"GeneratorURL": true, "SortedPairs": true, "Values": true,
		"Names": true, "Remove": true,
		"pagerduty": true, "severity": true, "alertname": true,
	}

	var incompatible []incompatFunc
	trackedFunctions := map[string]bool{}
	baselineFound := map[string]bool{}
	unknownFunctions := map[string]bool{}

	for _, match := range expressions {
		if len(match) < 2 {
			continue
		}
		expr := match[1]

		words := regexp.MustCompile(`\b([a-zA-Z][a-zA-Z0-9]*)\b`).FindAllString(expr, -1)
		for _, word := range words {
			if ignoreWords[word] {
				continue
			}
			if baselineFunctions[word] {
				baselineFound[word] = true
				continue
			}

			minVer, tracked := templateFuncMinVersion[word]
			if tracked {
				if trackedFunctions[word] {
					continue
				}
				trackedFunctions[word] = true
				if semverLessThan(amVersion, minVer) {
					incompatible = append(incompatible, incompatFunc{
						Function:   word,
						RequiresAM: minVer,
						ClusterAM:  amVersion,
						Expression: truncate(match[0], 80),
					})
				}
			} else if len(word) > 1 && word[0] >= 'a' && word[0] <= 'z' {
				unknownFunctions[word] = true
			}
		}
	}

	// Build function inventory for the report
	type funcInventoryItem struct {
		Function string `json:"function"`
		Category string `json:"category"`
		MinAM    string `json:"min_am,omitempty"`
		Status   string `json:"status"`
	}
	var inventory []funcInventoryItem
	for f := range baselineFound {
		inventory = append(inventory, funcInventoryItem{f, "baseline", "", "compatible"})
	}
	for f := range trackedFunctions {
		minVer := templateFuncMinVersion[f]
		status := "compatible"
		if semverLessThan(amVersion, minVer) {
			status = "INCOMPATIBLE"
		}
		inventory = append(inventory, funcInventoryItem{f, "version-gated", minVer, status})
	}
	r.Details["function_inventory"] = inventory
	r.Details["baseline_functions_found"] = len(baselineFound)

	if len(trackedFunctions) > 0 {
		funcList := make([]string, 0, len(trackedFunctions))
		for f := range trackedFunctions {
			funcList = append(funcList, f)
		}
		r.Details["non_baseline_functions"] = funcList
	}

	// Also check for fleet-wide risk: functions that work on THIS cluster but
	// would break on older OCP versions still in support
	oldestSupportedAM := "0.27.0" // OCP 4.17 — oldest currently supported
	var fleetRisk []incompatFunc
	for fn := range trackedFunctions {
		minVer := templateFuncMinVersion[fn]
		if !semverLessThan(amVersion, minVer) && semverLessThan(oldestSupportedAM, minVer) {
			fleetRisk = append(fleetRisk, incompatFunc{
				Function:   fn,
				RequiresAM: minVer,
				ClusterAM:  amVersion,
			})
		}
	}
	if len(fleetRisk) > 0 {
		r.Details["fleet_risk_functions"] = fleetRisk
	}

	if len(incompatible) > 0 {
		r.Details["incompatible_functions"] = incompatible
		r.Status = checks.StatusFail
		funcNames := make([]string, len(incompatible))
		for i, f := range incompatible {
			funcNames[i] = fmt.Sprintf("%s (requires AM %s+)", f.Function, f.RequiresAM)
		}
		r.Message = fmt.Sprintf("Config uses template functions unsupported by AM %s (OCP %s): %s — PD notifications will fail on this cluster",
			amVersion, cc.ClusterVersion, strings.Join(funcNames, ", "))
	} else if len(fleetRisk) > 0 {
		r.Status = checks.StatusWarning
		funcNames := make([]string, len(fleetRisk))
		for i, f := range fleetRisk {
			funcNames[i] = fmt.Sprintf("%s (requires AM %s+, oldest supported OCP has AM %s)", f.Function, f.RequiresAM, oldestSupportedAM)
		}
		r.Message = fmt.Sprintf("Config works on this cluster (AM %s) but uses functions incompatible with older supported OCP versions: %s",
			amVersion, strings.Join(funcNames, ", "))
	} else if len(expressions) == 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("No template expressions in AM config (AM %s)", amVersion)
	} else {
		r.Status = checks.StatusPass
		funcCount := len(baselineFound) + len(trackedFunctions)
		r.Message = fmt.Sprintf("All %d template functions compatible with AM %s (OCP %s, %d template blocks parsed)", funcCount, amVersion, cc.ClusterVersion, len(expressions))
	}

	cc.AddResult(r)
}

// checkAlertmanagerLogs analyzes AM pod logs with DNS warning filtering
func checkAlertmanagerLogs(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("alertmanager_logs")

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
	templateErrors := 0
	notifyFailures := 0
	reloadFailures := 0
	var errorSamples []string

	for _, pod := range pods.Items {
		logOutput, lErr := cc.Client.GetPodLogs(ctx, cc.Operator.Namespace, pod.Name, 1000)
		if lErr != nil {
			continue
		}

		for _, line := range strings.Split(logOutput, "\n") {
			lower := strings.ToLower(line)
			if strings.Contains(lower, "level=error") || strings.Contains(lower, "level=\"error\"") {
				totalErrors++

				// Detect specific critical patterns
				if strings.Contains(lower, "failed to template") || strings.Contains(lower, "not defined") {
					templateErrors++
				}
				if strings.Contains(lower, "notify for alerts failed") || strings.Contains(lower, "notify retry canceled") {
					notifyFailures++
				}
				if strings.Contains(lower, "loading configuration") || strings.Contains(lower, "reload") && strings.Contains(lower, "fail") {
					reloadFailures++
				}

				if len(errorSamples) < 5 {
					errorSamples = append(errorSamples, fmt.Sprintf("[%s] %s", pod.Name, truncate(line, 200)))
				}
			}
			if strings.Contains(lower, "level=warn") || strings.Contains(lower, "level=\"warn\"") {
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
	r.Details["template_errors"] = templateErrors
	r.Details["notify_failures"] = notifyFailures
	r.Details["reload_failures"] = reloadFailures
	r.Details["error_samples"] = errorSamples

	switch {
	case templateErrors > 0:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("Template errors in AlertManager logs (%d) — CAMO config uses template functions unsupported by this AM version (e.g., toJson). PagerDuty notifications are failing.", templateErrors)
	case notifyFailures > 0:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("Notification failures in AlertManager logs (%d) — alerts are not being delivered to PagerDuty", notifyFailures)
	case reloadFailures > 0:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("Config reload failures in AlertManager logs (%d) — running stale configuration", reloadFailures)
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
	cc.SetCheck("alertmanager_events")

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
	cc.SetCheck("camo_events")

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

// --- DMS (Dead Man's Snitch) checks on managed clusters ---

func checkDMSWatchdog(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("dms_watchdog_firing")

	r := checks.Result{
		Check:    "dms_watchdog_firing",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Verifies the Watchdog alert is actively firing. Watchdog is a heartbeat alert that fires continuously when Prometheus and Alertmanager are healthy. CAMO configures Alertmanager to forward Watchdog to Dead Man's Snitch via the dms-secret URL. If Watchdog stops firing, DMS will time out and page — but if Watchdog was never firing, DMS provides no protection.",
			"pass_criteria": "PASS: Watchdog alert is firing. FAIL: Watchdog alert not found in firing alerts. SKIP: cannot query metrics.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		r.Status = checks.StatusSkip
		r.Message = "Metrics unavailable"
		cc.AddResult(r)
		return
	}

	query := `ALERTS{alertname="Watchdog",alertstate="firing"}`
	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query Watchdog alert", err)

	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot query Watchdog alert: %v", err)
		cc.AddResult(r)
		return
	}

	if thanos.HasResults(body) {
		r.Status = checks.StatusPass
		r.Message = "Watchdog alert is firing — DMS heartbeat active"
	} else {
		r.Status = checks.StatusFail
		r.Message = "Watchdog alert not firing — DMS heartbeat stopped, snitch will time out and page"
	}
	cc.AddResult(r)
}

func checkDMSHeartbeatDelivery(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("dms_heartbeat_delivery")

	r := checks.Result{
		Check:    "dms_heartbeat_delivery",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks Alertmanager notification metrics for the DMS/Watchdog webhook receiver. Queries alertmanager_notifications_total and alertmanager_notifications_failed_total for the watchdog integration to verify heartbeats are being delivered to the Dead Man's Snitch endpoint. Failed deliveries mean DMS will time out even though Watchdog is firing.",
			"pass_criteria": "PASS: notifications being sent with zero or low failure rate. WARN: notification failures detected. FAIL: all notifications failing. INFO: no notification metrics found (DMS may not be configured).",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		r.Status = checks.StatusSkip
		r.Message = "Metrics unavailable"
		cc.AddResult(r)
		return
	}

	// AM uses integration name "webhook" for generic webhook receivers (DMS uses webhook)
	// The receiver name is typically "watchdog" or "make-it-warning"
	successQuery := `sum(rate(alertmanager_notifications_total{integration="webhook"}[1h]))`
	failQuery := `sum(rate(alertmanager_notifications_failed_total{integration="webhook"}[1h]))`

	successBody, sErr := cc.Client.QueryMetrics(ctx, successQuery)
	failBody, fErr := cc.Client.QueryMetrics(ctx, failQuery)

	if sErr != nil && fErr != nil {
		r.Status = checks.StatusInfo
		r.Message = "AM webhook notification metrics not available"
		cc.AddResult(r)
		return
	}

	successRate := 0.0
	failRate := 0.0
	if sErr == nil && thanos.HasResults(successBody) {
		if v, ok := thanos.InstantFloat(successBody); ok {
			successRate = v
		}
	}
	if fErr == nil && thanos.HasResults(failBody) {
		if v, ok := thanos.InstantFloat(failBody); ok {
			failRate = v
		}
	}

	r.Details["success_rate_per_sec"] = thanos.Round(successRate, 4)
	r.Details["fail_rate_per_sec"] = thanos.Round(failRate, 4)

	totalRate := successRate + failRate

	switch {
	case totalRate == 0:
		r.Status = checks.StatusInfo
		r.Message = "No webhook notifications in the last hour — DMS receiver may not be configured"
	case successRate == 0 && failRate > 0:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("All webhook notifications failing (%.4f/s) — DMS heartbeat not being delivered", failRate)
	case failRate > 0:
		failRatio := failRate / totalRate
		r.Details["fail_ratio"] = thanos.Round(failRatio, 4)
		if failRatio > 0.1 {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("Webhook notification failures: %.0f%% failing (%.4f/s success, %.4f/s fail)", failRatio*100, successRate, failRate)
		} else {
			r.Status = checks.StatusPass
			r.Message = fmt.Sprintf("DMS heartbeat delivery healthy with minor errors — %.4f/s success, %.4f/s fail", successRate, failRate)
		}
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("DMS heartbeat delivery healthy — %.4f notifications/s", successRate)
	}
	cc.AddResult(r)
}
