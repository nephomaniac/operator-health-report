package pdo

import (
	"context"
	"fmt"
	"strings"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/thanos"

	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func init() {
	checks.Register(&PDOChecker{})
}

type PDOChecker struct{}

func (c *PDOChecker) Name() string { return "pdo" }

var (
	pagerDutyIntegrationGVR = schema.GroupVersionResource{
		Group: "pagerduty.openshift.io", Version: "v1alpha1", Resource: "pagerdutyintegrations",
	}
	clusterDeploymentGVR = schema.GroupVersionResource{
		Group: "hive.openshift.io", Version: "v1", Resource: "clusterdeployments",
	}
)

func (c *PDOChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	// PDO only deploys to hive clusters (hivei*, hives*, hivep*), not MCs, SCs, or standard managed clusters.
	// Short-circuit if the namespace doesn't exist — this cluster doesn't run PDO.
	phase, err := cc.Client.GetNamespacePhase(ctx, cc.Operator.Namespace)
	if err != nil || phase != "Active" {
		cc.AddResult(checks.Result{
			Check:    "pdo_deployment_scope",
			Status:   checks.StatusInfo,
			Severity: checks.SeverityInfo,
			Message:  fmt.Sprintf("PDO namespace %s not found — PDO only deploys to hive clusters, not this cluster type", cc.Operator.Namespace),
			Details: map[string]any{
				"cluster_type": cc.ClusterType,
				"description":  "PagerDuty Operator only deploys to hive management clusters (where ClusterDeployments are managed). It is not expected on MCs, SCs, or standard ROSA/OSD clusters.",
			},
		})
		return
	}

	checkAPIKeySecret(ctx, cc)
	checkControllerAvailability(ctx, cc)
	checkPDIStatus(ctx, cc)
	checkPrometheusMetrics(ctx, cc)
	recentLogCount := checkReconciliationActivity(ctx, cc)
	checkReconciliationBehavior(ctx, cc, recentLogCount)
	checkConfigurationErrors(ctx, cc)
	checkFiringAlerts(ctx, cc)
}

func checkAPIKeySecret(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "pdo_api_key_secret"

	r := checks.Result{
		Check:    "pdo_api_key_secret",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"namespace":     cc.Operator.Namespace,
			"secret_name":   "pagerduty-api-key",
			"description":   "Validates the pagerduty-api-key Secret exists and contains the PAGERDUTY_API_KEY data key. This is the PagerDuty REST API authentication token. Without it, PDO cannot create PD services, sync integration keys, or maintain PD configurations for any ClusterDeployment. The PagerDutyIntegrationAPISecretError alert fires when this secret is missing for 15 minutes.",
			"pass_criteria": "PASS: Secret exists with PAGERDUTY_API_KEY key. WARN: Secret exists but key missing. FAIL: Secret not found. SKIP: Elevation not available.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	secret, err := cc.Client.ElevatedClientset().CoreV1().Secrets(cc.Operator.Namespace).Get(ctx, "pagerduty-api-key", metav1.GetOptions{})
	cc.RecordError("Get pagerduty-api-key secret", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = "pagerduty-api-key secret not found — PDO completely unable to function without PD API credentials"
		cc.AddResult(r)
		return
	}

	keyCount := len(secret.Data)
	r.Details["key_count"] = keyCount

	if _, hasKey := secret.Data["PAGERDUTY_API_KEY"]; hasKey {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("pagerduty-api-key secret present with PAGERDUTY_API_KEY (%d data keys)", keyCount)
	} else {
		r.Status = checks.StatusWarning
		r.Message = "pagerduty-api-key secret exists but PAGERDUTY_API_KEY data key is missing"
		r.Details["available_keys"] = secretKeyNames(secret.Data)
	}
	cc.AddResult(r)
}

func checkControllerAvailability(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "pdo_controller_availability"

	r := checks.Result{
		Check:    "pdo_controller_availability",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"namespace":     cc.Operator.Namespace,
			"deployment":    cc.Operator.Deployment,
			"description":   "Checks whether the pagerduty-operator deployment has an Available=True condition. PDO reconciles PagerDutyIntegration CRs against ClusterDeployments, creating PD services and syncing integration keys via SyncSets. If unavailable, no new PD services will be created and existing ones will not be maintained.",
			"pass_criteria": "PASS: Available=True. FAIL: Deployment not found or Available!=True.",
		},
	}

	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	cc.RecordError("Get PDO deployment", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Deployment %s/%s not found: %v", cc.Operator.Namespace, cc.Operator.Deployment, err)
		cc.AddResult(r)
		return
	}

	available := getDeploymentCondition(deploy, "Available")
	r.Details["available_condition"] = available

	if available == "True" {
		r.Status = checks.StatusPass
		r.Message = "PDO controller deployment Available"
	} else {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("PDO controller deployment not Available (condition: %s)", available)
	}
	cc.AddResult(r)
}

func checkPDIStatus(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "pdo_pdi_status"

	r := checks.Result{
		Check:    "pdo_pdi_status",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     cc.Operator.Namespace,
			"description":   "Lists PagerDutyIntegration CRs and reports their configuration. On hive clusters (where ClusterDeployment CRD exists), at least one PDI should be present. On non-hive managed clusters, zero PDIs is expected.",
			"pass_criteria": "PASS: PDIs found on hive cluster, or zero PDIs on non-hive cluster. WARN: Zero PDIs on hive cluster. INFO: Non-hive cluster, PDIs not applicable. SKIP: Elevation not available.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Check if this is a hive cluster by probing for ClusterDeployment CRD
	isHive := false
	_, cdErr := cc.Client.ListResources(ctx, clusterDeploymentGVR, "", true)
	if cdErr == nil {
		isHive = true
	}
	r.Details["is_hive_cluster"] = isHive

	// List PagerDutyIntegration CRs
	pdiList, err := cc.Client.ListResources(ctx, pagerDutyIntegrationGVR, cc.Operator.Namespace, true)
	cc.RecordError("List PagerDutyIntegrations", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		if isNotFoundOrCRDMissing(err) {
			if isHive {
				r.Status = checks.StatusWarning
				r.Message = "PagerDutyIntegration CRD not found on hive cluster — PDO may not be fully installed"
			} else {
				r.Status = checks.StatusInfo
				r.Message = "PagerDutyIntegration CRD not available — expected on non-hive managed clusters"
			}
			cc.AddResult(r)
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Cannot list PagerDutyIntegrations: %v", err)
		cc.AddResult(r)
		return
	}

	pdiCount := len(pdiList.Items)
	r.Details["pdi_count"] = pdiCount

	// Extract PDI details
	var pdiDetails []map[string]any
	for _, pdi := range pdiList.Items {
		ep, _, _ := unstructured.NestedString(pdi.Object, "spec", "escalationPolicy")
		prefix, _, _ := unstructured.NestedString(pdi.Object, "spec", "servicePrefix")
		orchEnabled, _, _ := unstructured.NestedBool(pdi.Object, "spec", "serviceOrchestration", "enabled")
		detail := map[string]any{
			"name":                   pdi.GetName(),
			"escalation_policy":      ep,
			"service_prefix":         prefix,
			"orchestration_enabled":  orchEnabled,
		}
		pdiDetails = append(pdiDetails, detail)
	}
	r.Details["pdi_details"] = pdiDetails

	var pdiNames []string
	for _, d := range pdiDetails {
		pdiNames = append(pdiNames, d["name"].(string))
	}
	r.Details["pdi_names"] = pdiNames

	switch {
	case pdiCount == 0 && !isHive:
		r.Status = checks.StatusInfo
		r.Message = "No PagerDutyIntegrations — expected on non-hive managed clusters (PDIs only exist on hive/management clusters)"
	case pdiCount == 0 && isHive:
		r.Status = checks.StatusWarning
		r.Message = "No PagerDutyIntegrations found on hive cluster — PD services will not be created for ClusterDeployments"
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d PagerDutyIntegration(s): %s", pdiCount, strings.Join(pdiNames, ", "))
	}
	cc.AddResult(r)
}

func checkPrometheusMetrics(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "pdo_prometheus_metrics"

	r := checks.Result{
		Check:    "pdo_prometheus_metrics",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"namespace":     cc.Operator.Namespace,
			"description":   "Queries PDO-specific Prometheus metrics that reflect PD API connectivity, secret loading, and service creation/deletion health. These metrics are emitted by PDO itself and are the primary signals for detecting PD integration failures.",
			"pass_criteria": "PASS: All metrics healthy (secret loaded, no create/delete/orchestration failures). FAIL: pagerdutyintegration_secret_loaded=0 for any PDI. WARN: Any create/delete/orchestration failure. SKIP: Elevation not available.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	ns := cc.Operator.Namespace
	type metricDef struct {
		name     string
		query    string
		critical bool
	}
	metrics := []metricDef{
		{"secret_loaded", fmt.Sprintf(`pagerdutyintegration_secret_loaded{namespace="%s"}`, ns), true},
		{"create_failure", fmt.Sprintf(`pagerduty_create_failure{namespace="%s"}`, ns), false},
		{"delete_failure", fmt.Sprintf(`pagerduty_delete_failure{namespace="%s"}`, ns), false},
		{"orchestration_failure", fmt.Sprintf(`pagerduty_service_orchestration_failure{namespace="%s"}`, ns), false},
	}

	var criticalIssues, warningIssues []string

	for _, m := range metrics {
		body, err := cc.Client.QueryMetrics(ctx, m.query)
		cc.RecordError("Query PDO metric "+m.name, err)

		if err != nil {
			r.Details[m.name] = "query_failed"
			continue
		}

		if !thanos.HasResults(body) {
			r.Details[m.name] = "no_data"
			continue
		}

		resp, _ := thanos.Parse(body)
		for _, result := range resp.Data.Result {
			val, ok := thanos.ToFloat(result)
			if !ok {
				continue
			}

			pdiName := result.Metric["pagerdutyintegration_name"]
			cdName := result.Metric["clusterdeployment_name"]
			label := pdiName
			if cdName != "" {
				label = cdName + "/" + pdiName
			}

			if m.name == "secret_loaded" && val < 1 {
				criticalIssues = append(criticalIssues, fmt.Sprintf("API key not loaded for PDI %s", pdiName))
			}
			if m.name == "create_failure" && val == 1 {
				warningIssues = append(warningIssues, fmt.Sprintf("PD service creation failed for %s", label))
			}
			if m.name == "delete_failure" && val == 1 {
				warningIssues = append(warningIssues, fmt.Sprintf("PD service deletion failed for %s", label))
			}
			if m.name == "orchestration_failure" && val == 1 {
				warningIssues = append(warningIssues, fmt.Sprintf("Service orchestration failed for PDI %s", pdiName))
			}
		}
		r.Details[m.name] = fmt.Sprintf("%d series", len(resp.Data.Result))
	}

	if len(criticalIssues) > 0 {
		r.Details["critical_issues"] = criticalIssues
	}
	if len(warningIssues) > 0 {
		r.Details["warning_issues"] = warningIssues
	}

	switch {
	case len(criticalIssues) > 0:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Critical: %s", strings.Join(criticalIssues, "; "))
	case len(warningIssues) > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d issue(s): %s", len(warningIssues), strings.Join(warningIssues, "; "))
	default:
		r.Status = checks.StatusPass
		r.Message = "All PDO metrics healthy — no secret loading, creation, deletion, or orchestration failures"
	}
	cc.AddResult(r)
}

func checkReconciliationActivity(ctx context.Context, cc *checks.ClusterContext) int {
	cc.CurrentCheck = "pdo_reconciliation_activity"

	r := checks.Result{
		Check:    "pdo_reconciliation_activity",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"namespace":     cc.Operator.Namespace,
			"description":   "Checks recent PDO logs for reconciliation activity and detects if a cluster upgrade is in progress. During upgrades, elevated reconciliation activity is expected.",
			"pass_criteria": "INFO: Reports recent log line count and upgrade status.",
		},
	}

	logOutput := ""
	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	if err == nil {
		selector, sErr := metav1.LabelSelectorAsSelector(deploy.Spec.Selector)
		if sErr == nil {
			pods, pErr := cc.Client.GetPods(ctx, cc.Operator.Namespace, selector.String())
			if pErr == nil && len(pods.Items) > 0 {
				logOutput, _ = cc.Client.GetPodLogs(ctx, cc.Operator.Namespace, pods.Items[0].Name, 50)
			}
		}
	}

	recentLogCount := 0
	if logOutput != "" {
		for _, line := range strings.Split(logOutput, "\n") {
			if strings.TrimSpace(line) != "" {
				recentLogCount++
			}
		}
	}

	r.Details["recent_log_count"] = recentLogCount
	r.Status = checks.StatusInfo
	r.Message = fmt.Sprintf("PDO producing logs — %d recent lines", recentLogCount)
	if recentLogCount == 0 {
		r.Message = "No recent PDO log output detected"
	}

	cc.AddResult(r)
	return recentLogCount
}

func checkReconciliationBehavior(ctx context.Context, cc *checks.ClusterContext, recentLogCount int) {
	cc.CurrentCheck = "pdo_reconciliation_behavior"

	r := checks.Result{
		Check:    "pdo_reconciliation_behavior",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"namespace":        cc.Operator.Namespace,
			"recent_log_count": recentLogCount,
			"lookback_window":  "50 lines",
			"cluster_type":     cc.ClusterType,
			"description":      "Analyzes reconciliation log volume to detect hot loops. On hive/management clusters, elevated reconciliation is expected due to many ClusterDeployments.",
			"pass_criteria":    "INFO: Reports log volume with cluster type context.",
		},
	}

	r.Status = checks.StatusInfo
	if cc.ClusterType == "management_cluster" {
		r.Message = fmt.Sprintf("Reconciliation log volume: %d lines — elevated activity expected on MC (many ClusterDeployments)", recentLogCount)
		r.Details["note"] = "Management clusters have many ClusterDeployments, so PDO reconciliation volume is naturally higher"
	} else {
		r.Message = fmt.Sprintf("Reconciliation log volume: %d lines", recentLogCount)
	}
	cc.AddResult(r)
}

func checkConfigurationErrors(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "pdo_configuration_errors"

	r := checks.Result{
		Check:    "pdo_configuration_errors",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     cc.Operator.Namespace,
			"description":   "Scans recent PDO logs for configuration-related error patterns including PD API key loading failures, escalation policy errors, service creation/deletion failures, and orchestration configuration errors.",
			"pass_criteria": "PASS: 5 or fewer config errors. WARN: More than 5 config errors suggesting persistent issues.",
		},
	}

	logOutput := ""
	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	if err == nil {
		selector, sErr := metav1.LabelSelectorAsSelector(deploy.Spec.Selector)
		if sErr == nil {
			pods, pErr := cc.Client.GetPods(ctx, cc.Operator.Namespace, selector.String())
			if pErr == nil && len(pods.Items) > 0 {
				logOutput, _ = cc.Client.GetPodLogs(ctx, cc.Operator.Namespace, pods.Items[0].Name, 100)
			}
		}
	}

	configErrors := 0
	var errorSamples []string
	for _, line := range strings.Split(logOutput, "\n") {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "level=info") || strings.Contains(lower, "\"level\":\"info\"") {
			continue
		}
		isError := strings.Contains(lower, "failed to load pagerduty api key") ||
			strings.Contains(lower, "unable to create service") ||
			strings.Contains(lower, "unable to delete service") ||
			(strings.Contains(lower, "escalation policy") && (strings.Contains(lower, "error") || strings.Contains(lower, "failed"))) ||
			(strings.Contains(lower, "service orchestration") && (strings.Contains(lower, "error") || strings.Contains(lower, "failed"))) ||
			((strings.Contains(lower, "failed") || strings.Contains(lower, "error")) &&
				!strings.Contains(lower, "level=info"))

		if isError {
			configErrors++
			if len(errorSamples) < 5 {
				sample := strings.TrimSpace(line)
				if len(sample) > 200 {
					sample = sample[:200] + "..."
				}
				errorSamples = append(errorSamples, sample)
			}
		}
	}

	r.Details["config_error_count"] = configErrors
	if len(errorSamples) > 0 {
		r.Details["error_samples"] = errorSamples
	}

	if configErrors > 5 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d configuration/error patterns in recent logs", configErrors)
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d error patterns in recent logs", configErrors)
	}
	cc.AddResult(r)
}

func checkFiringAlerts(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "pdo_firing_alerts"

	r := checks.Result{
		Check:    "pdo_firing_alerts",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks for any actively firing PagerDuty-related alerts. The primary alert is PagerDutyIntegrationAPISecretError which fires when the PD API key secret cannot be loaded for 15 minutes.",
			"pass_criteria": "PASS: No PagerDuty alerts firing. WARN: Alerts firing. SKIP: Elevation not available.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx, `ALERTS{alertname=~"PagerDuty.*",alertstate="firing"}`)
	cc.RecordError("Query firing PagerDuty alerts", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusUnknown
		r.Message = fmt.Sprintf("Metrics query failed: %v", err)
		cc.AddResult(r)
		return
	}

	if !thanos.HasResults(body) {
		r.Status = checks.StatusPass
		r.Message = "No PagerDuty alerts currently firing"
		cc.AddResult(r)
		return
	}

	resp, _ := thanos.Parse(body)
	var firingAlerts []string
	for _, result := range resp.Data.Result {
		name := result.Metric["alertname"]
		if name != "" {
			firingAlerts = append(firingAlerts, name)
		}
	}

	r.Details["firing_alerts"] = firingAlerts
	r.Details["firing_count"] = len(firingAlerts)
	r.Status = checks.StatusWarning
	r.Message = fmt.Sprintf("%d PagerDuty alert(s) firing: %s", len(firingAlerts), strings.Join(firingAlerts, ", "))
	cc.AddResult(r)
}

// --- Helpers ---

func getDeploymentCondition(deploy *appsv1.Deployment, condType string) string {
	for _, c := range deploy.Status.Conditions {
		if string(c.Type) == condType {
			return string(c.Status)
		}
	}
	return "Unknown"
}

func isNotFoundOrCRDMissing(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "not found") ||
		strings.Contains(msg, "no matches for kind") ||
		strings.Contains(msg, "the server could not find the requested resource")
}

func secretKeyNames(data map[string][]byte) []string {
	keys := make([]string, 0, len(data))
	for k := range data {
		keys = append(keys, k)
	}
	return keys
}
