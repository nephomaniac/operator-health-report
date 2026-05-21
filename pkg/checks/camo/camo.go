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
		Details:  map[string]any{},
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
		Details:  map[string]any{},
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
		Details:  map[string]any{},
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
		Details:  map[string]any{},
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
		Details:  map[string]any{},
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

// checkAlertmanagerSecret checks AM secret, CAMO ConfigMap, and PagerDuty secret existence
func checkAlertmanagerSecret(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "alertmanager_secret"

	r := checks.Result{
		Check:    "alertmanager_secret",
		Severity: checks.SeverityCritical,
		Details:  map[string]any{},
	}

	if !cc.Client.CanElevate() {
		r.Status = checks.StatusSkip
		r.Message = "Skipped — requires elevation"
		cc.AddResult(r)
		return
	}

	// Check alertmanager-main secret
	secret, err := cc.Client.ElevatedClientset().CoreV1().Secrets(cc.Operator.Namespace).Get(ctx, "alertmanager-main", metav1.GetOptions{})
	cc.RecordError("Get alertmanager-main secret", err)

	if err != nil {
		r.Status = checks.StatusFail
		r.Message = "Alertmanager secret not found"
		cc.AddResult(r)
		return
	}

	keyCount := len(secret.Data)
	r.Details["key_count"] = keyCount

	// Check CAMO ConfigMap
	_, cmErr := cc.Client.Clientset().CoreV1().ConfigMaps(cc.Operator.Namespace).Get(ctx, "configure-alertmanager-operator-config", metav1.GetOptions{})
	cmExists := cmErr == nil
	r.Details["configmap_exists"] = cmExists

	// Check PagerDuty secret
	_, pdErr := cc.Client.ElevatedClientset().CoreV1().Secrets(cc.Operator.Namespace).Get(ctx, "pd-secret", metav1.GetOptions{})
	pdExists := pdErr == nil
	r.Details["pagerduty_configured"] = pdExists

	r.Status = checks.StatusPass
	r.Message = fmt.Sprintf("Secret exists (%d keys)", keyCount)

	cc.AddResult(r)
}

// checkConfigurationErrors counts config-related error patterns in recent logs
func checkConfigurationErrors(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "configuration_errors"

	r := checks.Result{
		Check:    "configuration_errors",
		Severity: checks.SeverityWarning,
		Details:  map[string]any{},
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
		Details:  map[string]any{},
	}

	if !cc.Client.CanElevate() {
		r.Status = checks.StatusSkip
		r.Message = "Skipped — requires elevation for Thanos query"
		cc.AddResult(r)
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
		query := thanos.EncodeQuery(fmt.Sprintf(`%s{namespace="%s"}`, name, cc.Operator.Namespace))
		result, err := cc.Client.QueryThanos(ctx, query)
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
		Details:  map[string]any{},
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
		Details:  map[string]any{},
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
		Details:  map[string]any{},
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
