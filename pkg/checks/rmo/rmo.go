package rmo

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/logging"
	"github.com/openshift/operator-health-report/pkg/thanos"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// GVR definitions for custom resources
var (
	routeMonitorGVR      = schema.GroupVersionResource{Group: "monitoring.openshift.io", Version: "v1alpha1", Resource: "routemonitors"}
	clusterUrlMonitorGVR = schema.GroupVersionResource{Group: "monitoring.openshift.io", Version: "v1alpha1", Resource: "clusterurlmonitors"}
	prometheusRuleGVR    = schema.GroupVersionResource{Group: "monitoring.coreos.com", Version: "v1", Resource: "prometheusrules"}
	hostedControlPlaneGVR = schema.GroupVersionResource{Group: "hypershift.openshift.io", Version: "v1beta1", Resource: "hostedcontrolplanes"}
	clusterPackageGVR    = schema.GroupVersionResource{Group: "package-operator.run", Version: "v1alpha1", Resource: "clusterpackages"}
)

func serviceMonitorGVR(apiGroup string) schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: apiGroup, Version: "v1", Resource: "servicemonitors"}
}

func init() {
	checks.Register(&RMOChecker{})
}

type RMOChecker struct{}

func (c *RMOChecker) Name() string { return "rmo" }

func (c *RMOChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	checkControllerManager(ctx, cc)

	// Fetch CRs once (shared by multiple checks, requires elevation)
	rmList, cumList := fetchMonitorCRs(ctx, cc)

	checkBlackboxExporter(ctx, cc, rmList, cumList)
	checkRouteMonitorStatus(ctx, cc, rmList, cumList)
	checkSREProbeExpectations(ctx, cc, rmList, cumList)
	checkProbeHealth(ctx, cc, rmList, cumList)
	checkServiceMonitorHealth(ctx, cc, rmList, cumList)
	checkPrometheusRuleHealth(ctx, cc, rmList, cumList)
	checkOperatorMetrics(ctx, cc)
	checkConfig(ctx, cc)

	if cc.ClusterType == "management_cluster" {
		checkHCPCoverage(ctx, cc)
		checkHCPProbeCoverage(ctx, cc)
		checkHCPState(ctx, cc)
		checkRHOBSAPIHealth(ctx, cc)
		checkProbeDisagreement(ctx, cc)
	}

	checkRHOBSIntegration(ctx, cc)

	if cc.ClusterType != "management_cluster" {
		checkLimitedSupportDisagreement(ctx, cc)
	}
}

// fetchMonitorCRs retrieves RouteMonitor and ClusterUrlMonitor CRs with elevation
func fetchMonitorCRs(ctx context.Context, cc *checks.ClusterContext) (*unstructured.UnstructuredList, *unstructured.UnstructuredList) {
	if !cc.Client.CanElevate() {
		return nil, nil
	}

	rmList, err := cc.Client.ListResources(ctx, routeMonitorGVR, "", true)
	cc.RecordError("Get RouteMonitor CRs", err)
	if err != nil {
		rmList = nil
	}

	cumList, err := cc.Client.ListResources(ctx, clusterUrlMonitorGVR, "", true)
	cc.RecordError("Get ClusterUrlMonitor CRs", err)
	if err != nil {
		cumList = nil
	}

	return rmList, cumList
}

func countItems(list *unstructured.UnstructuredList) int {
	if list == nil {
		return 0
	}
	return len(list.Items)
}

// checkControllerManager verifies the RMO controller pod status
func checkControllerManager(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rmo_controller_manager")

	r := checks.Result{
		Check:    "rmo_controller_manager",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Validates the RMO controller-manager pod is running and stable. This is the core controller that reconciles RouteMonitor and ClusterUrlMonitor CRs into blackbox exporter probes. If the controller is down or crash-looping, no probes will be created or updated, leaving endpoint monitoring blind.",
			"pass_criteria": "PASS: pod is Running with <= 5 restarts and no OOMKill. WARN: 6-10 restarts or last termination was OOMKilled. FAIL: pod not Running or > 10 restarts.",
		},
	}

	podList, err := cc.Client.GetPods(ctx, cc.Operator.Namespace, "control-plane=controller-manager")
	cc.RecordError("Get RMO controller pods", err)

	if err != nil || len(podList.Items) == 0 {
		r.Status = checks.StatusFail
		r.Message = "No controller-manager pod found"
		cc.AddResult(r)
		return
	}

	pod := podList.Items[0]
	podName := pod.Name
	phase := string(pod.Status.Phase)

	restarts := 0
	termReason := ""
	blackboxImage := ""

	for _, cs := range pod.Status.ContainerStatuses {
		if cs.Name == "manager" {
			restarts = int(cs.RestartCount)
			if cs.LastTerminationState.Terminated != nil {
				termReason = cs.LastTerminationState.Terminated.Reason
			}
		}
	}

	// Extract BLACKBOX_IMAGE env var
	for _, container := range pod.Spec.Containers {
		if container.Name == "manager" {
			for _, env := range container.Env {
				if env.Name == "BLACKBOX_IMAGE" {
					blackboxImage = env.Value
				}
			}
		}
	}

	r.Details["pod_name"] = podName
	r.Details["phase"] = phase
	r.Details["restart_count"] = restarts
	r.Details["last_termination_reason"] = termReason
	r.Details["blackbox_image"] = blackboxImage

	switch {
	case phase != "Running":
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Controller-manager pod is %s (expected Running)", phase)
	case restarts > 10:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Excessive restarts (%d)", restarts)
	case restarts > 5:
		r.Status = checks.StatusWarning
		r.Severity = checks.SeverityWarning
		r.Message = fmt.Sprintf("Elevated restarts (%d)", restarts)
	case termReason == "OOMKilled":
		r.Status = checks.StatusWarning
		r.Severity = checks.SeverityWarning
		r.Message = "Last termination was OOMKilled"
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Controller-manager healthy (%s, %d restarts)", podName, restarts)
	}

	cc.AddResult(r)
}

// checkBlackboxExporter verifies the blackbox-exporter deployment
func checkBlackboxExporter(ctx context.Context, cc *checks.ClusterContext, rmList, cumList *unstructured.UnstructuredList) {
	cc.SetCheck("rmo_blackbox_exporter")

	r := checks.Result{
		Check:    "rmo_blackbox_exporter",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Verifies the blackbox-exporter deployment, Service, and ConfigMap exist and are healthy. The blackbox exporter is the component that actually executes HTTP probes against monitored endpoints. Without it, RouteMonitor and ClusterUrlMonitor CRs exist but no probe_success metrics are produced.",
			"pass_criteria": "PASS: deployment fully ready and Service exists. WARN: not fully ready, Service missing, or monitors exist but blackbox-exporter is absent. INFO: no blackbox-exporter and no monitors configured (expected state).",
		},
	}

	totalMonitors := countItems(rmList) + countItems(cumList)
	hasMonitors := totalMonitors > 0

	bbDeploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, "blackbox-exporter", metav1.GetOptions{})

	if err != nil {
		if hasMonitors {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("Blackbox exporter missing but %d monitor(s) exist — probes cannot run", totalMonitors)
		} else {
			r.Status = checks.StatusInfo
			r.Message = "No blackbox-exporter (expected — no monitors configured)"
		}
		r.Details["monitors_present"] = hasMonitors
		r.Details["total_monitors"] = totalMonitors
		cc.AddResult(r)
		return
	}

	desired := 1
	if bbDeploy.Spec.Replicas != nil {
		desired = int(*bbDeploy.Spec.Replicas)
	}
	ready := int(bbDeploy.Status.ReadyReplicas)

	// Check companion resources
	_, svcErr := cc.Client.Clientset().CoreV1().Services(cc.Operator.Namespace).Get(ctx, "blackbox-exporter", metav1.GetOptions{})
	svcExists := svcErr == nil

	_, cmErr := cc.Client.Clientset().CoreV1().ConfigMaps(cc.Operator.Namespace).Get(ctx, "blackbox-exporter", metav1.GetOptions{})
	cmExists := cmErr == nil

	r.Details["desired_replicas"] = desired
	r.Details["ready_replicas"] = ready
	r.Details["service_exists"] = svcExists
	r.Details["configmap_exists"] = cmExists
	r.Details["total_monitors"] = totalMonitors

	switch {
	case ready != desired:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Blackbox exporter not fully ready (%d/%d)", ready, desired)
	case !svcExists:
		r.Status = checks.StatusWarning
		r.Message = "Blackbox exporter Service missing"
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Blackbox exporter healthy (%d/%d ready)", ready, desired)
	}

	cc.AddResult(r)
}

// checkRouteMonitorStatus validates RouteMonitor and ClusterUrlMonitor CRs
func checkRouteMonitorStatus(ctx context.Context, cc *checks.ClusterContext, rmList, cumList *unstructured.UnstructuredList) {
	cc.SetCheck("rmo_routemonitor_status")

	r := checks.Result{
		Check:    "rmo_routemonitor_status",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates all RouteMonitor and ClusterUrlMonitor custom resources. Checks that expected SRE probes (console RouteMonitor and api ClusterUrlMonitor) are present, that CRs have no errorStatus, that RouteMonitors have resolved routeURLs, and that ServiceMonitor references are populated. Missing or broken CRs mean endpoints are not being probed.",
			"pass_criteria": "PASS: all expected CRs present, no errors, all URLs resolved, all ServiceMonitor refs populated. WARN: expected CRs missing, errorStatus set, routeURL empty, or ServiceMonitor ref missing.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	rmCount := countItems(rmList)
	cumCount := countItems(cumList)
	totalCount := rmCount + cumCount

	// Check for MCC-expected resources
	consoleRMExists := false
	apiCUMExists := false
	rmErrors := 0
	rmMissingURL := 0
	rmMissingSM := 0

	if rmList != nil {
		for _, item := range rmList.Items {
			name := item.GetName()
			ns := item.GetNamespace()

			if name == "console" && ns == "openshift-route-monitor-operator" {
				consoleRMExists = true
			}

			errStatus, _, _ := unstructured.NestedString(item.Object, "status", "errorStatus")
			if errStatus != "" {
				rmErrors++
			}
			routeURL, _, _ := unstructured.NestedString(item.Object, "status", "routeURL")
			if routeURL == "" {
				rmMissingURL++
			}
			smRef, _, _ := unstructured.NestedMap(item.Object, "status", "serviceMonitorRef")
			smName, _ := smRef["name"].(string)
			if smName == "" {
				rmMissingSM++
			}
		}
	}

	if cumList != nil {
		for _, item := range cumList.Items {
			name := item.GetName()
			ns := item.GetNamespace()

			if name == "api" && ns == "openshift-route-monitor-operator" {
				apiCUMExists = true
			}

			errStatus, _, _ := unstructured.NestedString(item.Object, "status", "errorStatus")
			if errStatus != "" {
				rmErrors++
			}
		}
	}

	// Validate MCC expectations
	var mccIssues []string
	if cc.ClusterType == "management_cluster" {
		if !apiCUMExists {
			mccIssues = append(mccIssues, "ClusterUrlMonitor 'api' missing")
		}
	} else {
		if !consoleRMExists {
			mccIssues = append(mccIssues, "RouteMonitor 'console' missing")
		}
		if !apiCUMExists {
			mccIssues = append(mccIssues, "ClusterUrlMonitor 'api' missing")
		}
	}

	r.Details["routemonitor_count"] = rmCount
	r.Details["clusterurlmonitor_count"] = cumCount
	r.Details["console_routemonitor_present"] = consoleRMExists
	r.Details["api_clusterurlmonitor_present"] = apiCUMExists
	r.Details["error_count"] = rmErrors
	r.Details["missing_url_count"] = rmMissingURL
	r.Details["missing_servicemonitor_count"] = rmMissingSM

	switch {
	case totalCount == 0:
		r.Status = checks.StatusWarning
		r.Message = "No RouteMonitor or ClusterUrlMonitor CRs found"
		if len(mccIssues) > 0 {
			r.Message += " — " + strings.Join(mccIssues, ", ")
		}
	case len(mccIssues) > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%s (%d RouteMonitor(s), %d ClusterUrlMonitor(s) present)",
			strings.Join(mccIssues, ", "), rmCount, cumCount)
	case rmErrors > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d monitor(s) have errorStatus", rmErrors)
	case rmMissingURL > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d RouteMonitor(s) missing routeURL", rmMissingURL)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d RouteMonitor(s), %d ClusterUrlMonitor(s) — all healthy", rmCount, cumCount)
	}

	cc.AddResult(r)
}

// checkSREProbeExpectations verifies SRE probe-missing PrometheusRules
func checkSREProbeExpectations(ctx context.Context, cc *checks.ClusterContext, rmList, cumList *unstructured.UnstructuredList) {
	cc.SetCheck("rmo_sre_probe_expectations")

	r := checks.Result{
		Check:    "rmo_sre_probe_expectations",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Verifies consistency between SRE probe-missing PrometheusRules and actual probe CRs. SRE deploys PrometheusRules (sre-route-monitor-operator-probe-missing-api/console) that fire alerts when probes disappear. If these rules exist but no probes are configured, route monitoring is completely absent and the probe-missing alerts will fire.",
			"pass_criteria": "PASS: SRE probe-missing rules exist and matching monitor CRs are present. FAIL: probe-missing rules exist but zero monitors found — route monitoring absent. INFO: no SRE probe-missing PrometheusRules found.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Check for SRE probe-missing PrometheusRules
	_, apiErr := cc.Client.GetResource(ctx, prometheusRuleGVR, "openshift-monitoring",
		"sre-route-monitor-operator-probe-missing-api", true)
	apiRuleExists := apiErr == nil

	consoleRuleExists := false
	if cc.ClusterType != "management_cluster" {
		_, consoleErr := cc.Client.GetResource(ctx, prometheusRuleGVR, "openshift-monitoring",
			"sre-route-monitor-operator-probe-missing-console", true)
		consoleRuleExists = consoleErr == nil
	}

	totalCRs := countItems(rmList) + countItems(cumList)
	sreExpectsProbes := apiRuleExists || consoleRuleExists

	r.Details["sre_probe_missing_api_rule"] = apiRuleExists
	r.Details["sre_probe_missing_console_rule"] = consoleRuleExists
	r.Details["sre_expects_probes"] = sreExpectsProbes

	switch {
	case sreExpectsProbes && totalCRs == 0:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = "SRE probe-missing alerts exist but no probes found — route monitoring absent"
	case sreExpectsProbes:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("SRE probe expectations met (%d monitors active)", totalCRs)
	default:
		r.Status = checks.StatusInfo
		r.Message = "No SRE probe-missing PrometheusRules found"
	}

	cc.AddResult(r)
}

// checkProbeHealth verifies blackbox probe_success metrics
func checkProbeHealth(ctx context.Context, cc *checks.ClusterContext, rmList, cumList *unstructured.UnstructuredList) {
	cc.SetCheck("rmo_probe_health")

	r := checks.Result{
		Check:    "rmo_probe_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Queries probe_success metrics from platform Thanos to verify that blackbox exporter probes are actively succeeding. This is the real-time health signal for monitored endpoints (console, API). On management clusters, only ClusterUrlMonitor probes appear in platform Thanos; HCP RouteMonitor probes are checked separately via RHOBS in rmo_hcp_probe_coverage.",
			"pass_criteria": "PASS: all probes returning probe_success=1 and probe count matches expected monitors. WARN: any probe returning probe_success=0 (endpoint down) or probe count mismatch. SKIP: no monitors configured.",
		},
	}

	totalCRs := countItems(rmList) + countItems(cumList)
	if totalCRs == 0 {
		r.Status = checks.StatusSkip
		r.Message = "No monitors configured — no probes to check"
		cc.AddResult(r)
		return
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	rawQuery := `probe_success{namespace=~"openshift-route-monitor-operator|ocm-.*"}`
	probeData, err := cc.Client.QueryMetrics(ctx, rawQuery)
	cc.RecordError("Probe success instant query", err)

	if err != nil || !thanos.HasResults(probeData) {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("No probe metrics found but %d monitors exist", totalCRs)
		cc.AddResult(r)
		return
	}

	resp, _ := thanos.Parse(probeData)
	probeTotal := len(resp.Data.Result)
	failing := 0
	var failingTargets []string

	for _, result := range resp.Data.Result {
		val := ""
		if len(result.Value) >= 2 {
			val = fmt.Sprintf("%v", result.Value[1])
		}
		if val == "0" {
			failing++
			probeURL := result.Metric["probe_url"]
			label := classifyProbeURL(probeURL)
			failingTargets = append(failingTargets, label)
		}
	}

	// On MCs, only ClusterUrlMonitor probes are visible in platform Thanos.
	// HCP RouteMonitor probes are scraped by RHOBS (checked in rmo_hcp_probe_coverage).
	expectedVisible := totalCRs
	if cc.ClusterType == "management_cluster" {
		expectedVisible = countItems(cumList)
	}

	r.Details["active_probes"] = probeTotal
	r.Details["expected_visible_probes"] = expectedVisible
	r.Details["total_monitors"] = totalCRs
	r.Details["failing_probes"] = failing
	r.Details["failing_targets"] = strings.Join(failingTargets, ", ")

	if cc.ClusterType == "management_cluster" {
		r.Details["note"] = "HCP probes in RHOBS stack — see rmo_hcp_probe_coverage check"
	}

	switch {
	case failing > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Failing endpoint(s): %s (%d/%d failing)",
			strings.Join(failingTargets, ", "), failing, probeTotal)
	case probeTotal < expectedVisible:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Probe count mismatch: %d active but %d expected in platform Thanos", probeTotal, expectedVisible)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All local endpoints healthy (%d/%d)", probeTotal, expectedVisible)
	}

	cc.AddResult(r)
}

// checkServiceMonitorHealth verifies ServiceMonitors referenced by monitors exist
func checkServiceMonitorHealth(ctx context.Context, cc *checks.ClusterContext, rmList, cumList *unstructured.UnstructuredList) {
	cc.SetCheck("rmo_servicemonitor_health")

	r := checks.Result{
		Check:    "rmo_servicemonitor_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates that ServiceMonitor resources referenced in RouteMonitor and ClusterUrlMonitor status fields actually exist. ServiceMonitors tell Prometheus how to scrape probe_success metrics from the blackbox exporter. If a ServiceMonitor is missing, Prometheus will not collect probe data, and probe-missing alerts will fire even though the probes may be running.",
			"pass_criteria": "PASS: all referenced ServiceMonitors found. WARN: one or more referenced ServiceMonitors missing or no ServiceMonitors referenced despite monitors existing. SKIP: no monitors configured.",
		},
	}

	totalCRs := countItems(rmList) + countItems(cumList)
	if totalCRs == 0 {
		r.Status = checks.StatusSkip
		r.Message = "Skipped — no monitors configured"
		cc.AddResult(r)
		return
	}
	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Collect serviceMonitorRefs from both monitor types
	type smRef struct {
		apiGroup  string
		namespace string
		name      string
	}
	var refs []smRef

	extractRefs := func(list *unstructured.UnstructuredList) {
		if list == nil {
			return
		}
		for _, item := range list.Items {
			apiGroup, _, _ := unstructured.NestedString(item.Object, "spec", "serviceMonitorType")
			if apiGroup == "" {
				apiGroup = "monitoring.coreos.com"
			}
			smRefMap, _, _ := unstructured.NestedMap(item.Object, "status", "serviceMonitorRef")
			name, _ := smRefMap["name"].(string)
			ns, _ := smRefMap["namespace"].(string)
			if name != "" && ns != "" {
				refs = append(refs, smRef{apiGroup: apiGroup, namespace: ns, name: name})
			}
		}
	}

	extractRefs(rmList)
	extractRefs(cumList)

	found := 0
	missing := 0

	for _, ref := range refs {
		gvr := serviceMonitorGVR(ref.apiGroup)
		_, err := cc.Client.GetResource(ctx, gvr, ref.namespace, ref.name, true)
		if err == nil {
			found++
		} else {
			missing++
		}
	}

	r.Details["found_servicemonitors"] = found
	r.Details["missing_servicemonitors"] = missing
	r.Details["expected_monitors"] = totalCRs

	switch {
	case missing > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d ServiceMonitor(s) missing (%d/%d found)", missing, found, len(refs))
	case found == 0 && totalCRs > 0:
		r.Status = checks.StatusWarning
		r.Message = "No ServiceMonitors referenced in monitor status"
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d ServiceMonitor(s) verified", found)
	}

	cc.AddResult(r)
}

// checkPrometheusRuleHealth verifies PrometheusRules referenced by monitors
func checkPrometheusRuleHealth(ctx context.Context, cc *checks.ClusterContext, rmList, cumList *unstructured.UnstructuredList) {
	cc.SetCheck("rmo_prometheusrule_health")

	r := checks.Result{
		Check:    "rmo_prometheusrule_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates that PrometheusRule resources referenced in monitor CR status fields exist. RMO creates PrometheusRules that define alerting thresholds (e.g., RouteMonitorAvailabilitySRE) based on probe_success metrics. Missing PrometheusRules mean no alerts will fire when endpoints go down, breaking the SRE alerting chain.",
			"pass_criteria": "PASS: all referenced PrometheusRules found. WARN: one or more referenced PrometheusRules missing. INFO: no PrometheusRules expected (all monitors have skipPrometheusRule set). SKIP: no monitors configured.",
		},
	}

	totalCRs := countItems(rmList) + countItems(cumList)
	if totalCRs == 0 {
		r.Status = checks.StatusSkip
		r.Message = "Skipped — no monitors configured"
		cc.AddResult(r)
		return
	}
	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	type prRef struct {
		namespace string
		name      string
	}
	var refs []prRef

	extractPRRefs := func(list *unstructured.UnstructuredList) {
		if list == nil {
			return
		}
		for _, item := range list.Items {
			skipPR, _, _ := unstructured.NestedBool(item.Object, "spec", "skipPrometheusRule")
			if skipPR {
				continue
			}
			refMap, _, _ := unstructured.NestedMap(item.Object, "status", "prometheusRuleRef")
			name, _ := refMap["name"].(string)
			ns, _ := refMap["namespace"].(string)
			if name != "" && ns != "" {
				refs = append(refs, prRef{namespace: ns, name: name})
			}
		}
	}

	extractPRRefs(rmList)
	extractPRRefs(cumList)

	found := 0
	missing := 0

	for _, ref := range refs {
		_, err := cc.Client.GetResource(ctx, prometheusRuleGVR, ref.namespace, ref.name, true)
		if err == nil {
			found++
		} else {
			missing++
		}
	}

	r.Details["total_prometheusrules"] = found
	r.Details["expected_prometheusrules"] = len(refs)

	switch {
	case len(refs) == 0:
		r.Status = checks.StatusInfo
		r.Message = "No PrometheusRules expected"
	case missing > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d PrometheusRule(s) missing (%d/%d found)", missing, found, len(refs))
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d PrometheusRule(s) verified", found)
	}

	cc.AddResult(r)
}

// checkOperatorMetrics queries RMO-specific Prometheus metrics
func checkOperatorMetrics(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rmo_operator_metrics")
	log := logging.WithCheck("rmo_operator_metrics")

	r := checks.Result{
		Check:    "rmo_operator_metrics",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Queries RMO's own operator-level Prometheus metrics (rhobs_route_monitor_operator_info, api_requests_total, probe_deletion_timeout_total) from platform Thanos. These metrics reveal the operator's internal health: whether its RHOBS API calls are succeeding, whether probe deletions are timing out, and what version is running.",
			"pass_criteria": "PASS: no probe deletion timeouts and RHOBS API calls have at least some successes. WARN: probe deletion timeouts detected or all RHOBS API requests failing with zero successes.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		r.Status = checks.StatusSkip
		r.Message = "Metrics unavailable — no port-forward, elevation, or RHOBS remote configured"
		cc.AddResult(r)
		return
	}

	queryMetric := func(name string) string {
		rawQuery := fmt.Sprintf(`%s{namespace="%s"}`, name, cc.Operator.Namespace)
		data, err := cc.Client.QueryMetrics(ctx, rawQuery)
		cc.RecordError("RMO metric: "+name, err)
		return data
	}

	// Info metric
	infoVersion := ""
	infoData := queryMetric("rhobs_route_monitor_operator_info")
	if thanos.HasResults(infoData) {
		_, labels, ok := thanos.InstantValue(infoData)
		if ok {
			infoVersion = labels["version"]
		}
	}
	r.Details["info_version"] = infoVersion

	// API requests
	apiData := queryMetric("rhobs_route_monitor_operator_api_requests_total")
	apiSuccess := 0.0
	apiErrors := 0.0
	if resp, err := thanos.Parse(apiData); err == nil {
		for _, result := range resp.Data.Result {
			val, ok := thanos.ToFloat(result)
			if !ok {
				continue
			}
			if result.Metric["status"] == "success" {
				apiSuccess += val
			} else if result.Metric["status"] == "error" {
				apiErrors += val
			}
		}
	}
	r.Details["api_success_count"] = int(apiSuccess)
	r.Details["api_error_count"] = int(apiErrors)

	// Probe deletion timeouts
	timeoutData := queryMetric("rhobs_route_monitor_operator_probe_deletion_timeout_total")
	timeouts := 0.0
	if f, ok := thanos.InstantFloat(timeoutData); ok {
		timeouts = f
	}
	r.Details["probe_deletion_timeouts"] = int(timeouts)

	log.WithField("version", infoVersion).Debug("RMO metrics")

	switch {
	case timeouts > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%.0f probe deletion timeout(s) detected", timeouts)
	case apiErrors > 0 && apiSuccess == 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("All RHOBS API requests failing (%.0f errors, 0 success)", apiErrors)
	default:
		r.Status = checks.StatusPass
		r.Message = "RMO metrics healthy"
	}

	cc.AddResult(r)
}

// checkConfig validates the RMO ConfigMap
func checkConfig(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rmo_config")

	r := checks.Result{
		Check:    "rmo_config",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Reads the RMO ConfigMap to surface operator configuration settings such as probe-api-url (RHOBS synthetics endpoint), only-public-clusters flag, and skip-infrastructure-health-check flag. This is informational — it reports the active configuration so operators can verify settings match expectations for the cluster type.",
			"pass_criteria": "PASS: ConfigMap found and settings reported. INFO: no ConfigMap found (operator uses defaults).",
		},
	}

	// Try both possible ConfigMap names
	configNames := []string{
		"route-monitor-operator-manager-config",
		"route-monitor-operator-config",
	}

	var configMap *corev1.ConfigMap
	for _, name := range configNames {
		cm, err := cc.Client.Clientset().CoreV1().ConfigMaps(cc.Operator.Namespace).Get(ctx, name, metav1.GetOptions{})
		if err == nil {
			configMap = cm
			break
		}
	}

	if configMap == nil {
		r.Status = checks.StatusInfo
		r.Message = "No ConfigMap found (using defaults)"
		cc.AddResult(r)
		return
	}

	r.Details["probe_api_url"] = configMap.Data["probe-api-url"]
	r.Details["only_public_clusters"] = configMap.Data["only-public-clusters"]
	r.Details["skip_infrastructure_health_check"] = configMap.Data["skip-infrastructure-health-check"]

	r.Status = checks.StatusPass
	r.Message = "ConfigMap present"

	cc.AddResult(r)
}

// checkHCPCoverage checks HCP RouteMonitor coverage on management clusters
func checkHCPCoverage(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rmo_hcp_coverage")

	r := checks.Result{
		Check:    "rmo_hcp_coverage",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "On management clusters, compares the number of HostedControlPlane resources against the number of unique cluster IDs with probe_success metrics in RHOBS Prometheus. Each HCP should have probe coverage via RHOBS synthetics. Unmonitored HCPs represent hosted clusters whose endpoint availability is not being tracked.",
			"pass_criteria": "PASS: all HCPs have probe coverage in RHOBS. WARN: one or more HCPs without probe coverage. SKIP: cannot retrieve HCP resources or elevation unavailable. INFO: no HCPs found on this management cluster.",
		},
	}

	hcpList, err := cc.Client.ListResources(ctx, hostedControlPlaneGVR, "", false)
	cc.RecordError("Get HostedControlPlane CRs", err)

	if err != nil || len(hcpList.Items) == 0 {
		if err != nil {
			r.Status = checks.StatusSkip
			r.Message = "Could not retrieve HostedControlPlane resources"
		} else {
			r.Status = checks.StatusInfo
			r.Message = "No HostedControlPlane resources found"
			r.Details["hcp_count"] = 0
		}
		cc.AddResult(r)
		return
	}

	hcpCount := len(hcpList.Items)
	r.Details["hcp_count"] = hcpCount

	// Build HCP metadata map (keyed by cluster ID)
	type hcpInfo struct {
		Name      string `json:"name"`
		Namespace string `json:"namespace"`
		ClusterID string `json:"cluster_id"`
		Created   string `json:"created"`
		Version   string `json:"version"`
	}
	hcpByID := map[string]hcpInfo{}
	for _, hcp := range hcpList.Items {
		cid, _, _ := unstructured.NestedString(hcp.Object, "spec", "clusterID")
		ver, _, _ := unstructured.NestedString(hcp.Object, "spec", "release", "image")
		if idx := strings.LastIndex(ver, ":"); idx >= 0 {
			ver = ver[idx+1:]
		}
		info := hcpInfo{
			Name:      hcp.GetName(),
			Namespace: hcp.GetNamespace(),
			ClusterID: cid,
			Created:   hcp.GetCreationTimestamp().Format("2006-01-02T15:04:05Z"),
			Version:   ver,
		}
		if cid != "" {
			hcpByID[cid] = info
		} else {
			hcpByID[hcp.GetNamespace()] = info
		}
	}

	// Check how many have RouteMonitors via RHOBS Prometheus
	if !cc.Client.CanElevate() {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("%d HCP(s) found — probe coverage check requires elevation", hcpCount)
		cc.AddResult(r)
		return
	}

	// Query RHOBS Prometheus for HCP probe metrics
	probeData, err := cc.Client.QueryRHOBSPrometheus(ctx, thanos.EncodeQuery("probe_success"))
	cc.RecordError("HCP probe metrics", err)

	monitoredIDs := map[string]bool{}
	if err == nil && thanos.HasResults(probeData) {
		resp, _ := thanos.Parse(probeData)
		for _, result := range resp.Data.Result {
			id := result.Metric["_id"]
			if id != "" {
				monitoredIDs[id] = true
			}
		}
	}

	monitored := len(monitoredIDs)
	r.Details["hcp_monitored"] = monitored
	unmonitored := hcpCount - monitored
	if unmonitored < 0 {
		unmonitored = 0
	}
	r.Details["hcp_unmonitored"] = unmonitored

	// Identify which HCPs lack coverage
	if unmonitored > 0 {
		var uncoveredHCPs []hcpInfo
		for id, info := range hcpByID {
			if !monitoredIDs[id] {
				uncoveredHCPs = append(uncoveredHCPs, info)
			}
		}
		r.Details["uncovered_hcps"] = uncoveredHCPs
	}

	switch {
	case unmonitored > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d HCP(s) without probe coverage", unmonitored, hcpCount)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d HCP(s) have probe coverage", hcpCount)
	}

	cc.AddResult(r)
}

// checkHCPProbeCoverage queries RHOBS Prometheus for actual HCP probe health (MC only)
func checkHCPProbeCoverage(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rmo_hcp_probe_coverage")

	r := checks.Result{
		Check:    "rmo_hcp_probe_coverage",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Queries RHOBS Prometheus for all HCP probe_success metrics and checks whether each probe is succeeding. Unlike rmo_probe_health (which checks platform Thanos for local probes), this check covers HCP-specific probes that are scraped by the RHOBS monitoring stack on management clusters. Failing probes indicate hosted cluster endpoints that are unreachable.",
			"pass_criteria": "PASS: all HCP probes returning probe_success=1. WARN: one or more HCP probes failing (probe_success=0) or no probes found in RHOBS.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	query := thanos.EncodeQuery("probe_success")
	probeData, err := cc.Client.QueryRHOBSPrometheus(ctx, query)
	cc.RecordError("HCP probe_success (all)", err)

	if err != nil || !thanos.HasResults(probeData) {
		r.Status = checks.StatusWarning
		r.Message = "No HCP probes found in RHOBS Prometheus"
		cc.AddResult(r)
		return
	}

	resp, _ := thanos.Parse(probeData)
	totalProbes := len(resp.Data.Result)
	probesOK := 0
	probesFailing := 0
	var failingURLs []string

	for _, result := range resp.Data.Result {
		val := ""
		if len(result.Value) >= 2 {
			val = fmt.Sprintf("%v", result.Value[1])
		}
		if val == "1" {
			probesOK++
		} else {
			probesFailing++
			failingURLs = append(failingURLs, result.Metric["probe_url"])
		}
	}

	r.Details["total_probes"] = totalProbes
	r.Details["probes_succeeding"] = probesOK
	r.Details["probes_failing"] = probesFailing
	r.Details["failing_probe_urls"] = strings.Join(failingURLs, ", ")
	r.Details["data_source"] = "RHOBS Prometheus"

	switch {
	case probesFailing > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d HCP probe(s) failing", probesFailing, totalProbes)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d HCP probes succeeding", totalProbes)
	}

	cc.AddResult(r)
}

// checkHCPState queries RHOBS for HCP state breakdown (MC only, informational)
func checkHCPState(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rmo_hcp_state")

	r := checks.Result{
		Check:    "rmo_hcp_state",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Queries RHOBS Prometheus for hypershift_cluster_* metrics to provide a breakdown of HostedControlPlane states on a management cluster: provisioned, ready, limited support, deleting, and waiting for initial availability. This is informational context that helps interpret probe coverage gaps — e.g., HCPs in limited support or deleting state may legitimately lack probes.",
			"pass_criteria": "INFO: always informational. Reports the state distribution of HCPs on the management cluster.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	queryScalar := func(desc, q string) int {
		query := thanos.EncodeQuery(q)
		data, err := cc.Client.QueryRHOBSPrometheus(ctx, query)
		cc.RecordError(desc, err)
		if f, ok := thanos.InstantFloat(data); ok {
			return int(f)
		}
		return 0
	}

	provisioned := queryScalar("HCP provisioned", "count(hypershift_cluster_vcpus > 0)")
	limited := queryScalar("HCP limited support", "count(hypershift_cluster_limited_support_enabled == 1)")
	deleting := queryScalar("HCP deleting", "count(hypershift_cluster_deleting_duration_seconds)")
	waiting := queryScalar("HCP waiting", "count(hypershift_cluster_waiting_initial_availability_duration_seconds)")
	ready := queryScalar("HCP ready", `count(hypershift_cluster_vcpus > 0 unless on(_id) hypershift_cluster_limited_support_enabled == 1 unless on(_id) hypershift_cluster_waiting_initial_availability_duration_seconds unless on(_id) hypershift_cluster_deleting_duration_seconds)`)

	r.Details["provisioned"] = provisioned
	r.Details["ready"] = ready
	r.Details["limited_support"] = limited
	r.Details["deleting"] = deleting
	r.Details["waiting_availability"] = waiting
	r.Details["data_source"] = "RHOBS Prometheus hypershift_cluster_* metrics"

	r.Status = checks.StatusInfo
	r.Message = fmt.Sprintf("%d provisioned HCPs: %d ready, %d limited support, %d deleting, %d waiting",
		provisioned, ready, limited, deleting, waiting)

	cc.AddResult(r)
}

// checkRHOBSAPIHealth queries RHOBS for per-operation API request metrics (MC only)
func checkRHOBSAPIHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rmo_rhobs_api_health")

	r := checks.Result{
		Check:    "rmo_rhobs_api_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Queries RHOBS Prometheus for per-operation RMO API request metrics (get_probe, create_probe, delete_probe, update_probe_labels), OIDC token refresh counters, and probe deletion timeouts. This check validates the operator's ability to communicate with the RHOBS synthetics API on management clusters. API failures prevent probe lifecycle management for HCP endpoints.",
			"pass_criteria": "PASS: API calls succeeding with zero errors and OIDC refreshes healthy. WARN: some API errors or probe deletion timeouts. FAIL: all API calls failing or OIDC token refresh completely broken.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// API requests by operation from RHOBS Prometheus
	apiQuery := thanos.EncodeQuery("rhobs_route_monitor_operator_api_requests_total")
	apiData, err := cc.Client.QueryRHOBSPrometheus(ctx, apiQuery)
	cc.RecordError("RMO API requests", err)

	type opCounts struct{ success, errors int }
	ops := map[string]*opCounts{
		"get_probe":           {},
		"create_probe":        {},
		"delete_probe":        {},
		"update_probe_labels": {},
	}

	if resp, parseErr := thanos.Parse(apiData); parseErr == nil {
		for _, result := range resp.Data.Result {
			op := result.Metric["operation"]
			status := result.Metric["status"]
			val, ok := thanos.ToFloat(result)
			if !ok {
				continue
			}
			c, exists := ops[op]
			if !exists {
				c = &opCounts{}
				ops[op] = c
			}
			if status == "success" {
				c.success += int(val)
			} else if status == "error" {
				c.errors += int(val)
			}
		}
	}

	totalSuccess := 0
	totalErrors := 0
	for op, c := range ops {
		r.Details[op+"_success"] = c.success
		r.Details[op+"_error"] = c.errors
		totalSuccess += c.success
		totalErrors += c.errors
	}

	// OIDC token refresh
	oidcQuery := thanos.EncodeQuery("rhobs_route_monitor_operator_oidc_token_refresh_total")
	oidcData, err := cc.Client.QueryRHOBSPrometheus(ctx, oidcQuery)
	cc.RecordError("RMO OIDC token refresh", err)

	oidcSuccess := 0
	oidcErrors := 0
	if resp, parseErr := thanos.Parse(oidcData); parseErr == nil {
		for _, result := range resp.Data.Result {
			val, ok := thanos.ToFloat(result)
			if !ok {
				continue
			}
			if result.Metric["status"] == "success" {
				oidcSuccess += int(val)
			} else {
				oidcErrors += int(val)
			}
		}
	}
	r.Details["oidc_refresh_success"] = oidcSuccess
	r.Details["oidc_refresh_error"] = oidcErrors

	// Probe deletion timeouts
	timeoutQuery := thanos.EncodeQuery("rhobs_route_monitor_operator_probe_deletion_timeout_total")
	timeoutData, err := cc.Client.QueryRHOBSPrometheus(ctx, timeoutQuery)
	cc.RecordError("RMO probe deletion timeouts", err)

	deletionTimeouts := 0
	if f, ok := thanos.InstantFloat(timeoutData); ok {
		deletionTimeouts = int(f)
	}
	r.Details["probe_deletion_timeouts"] = deletionTimeouts

	// RMO version from RHOBS
	infoQuery := thanos.EncodeQuery("rhobs_route_monitor_operator_info")
	infoData, _ := cc.Client.QueryRHOBSPrometheus(ctx, infoQuery)
	rmoVersion := "unknown"
	if _, labels, ok := thanos.InstantValue(infoData); ok {
		if v := labels["version"]; v != "" {
			rmoVersion = v
		}
	}
	r.Details["rmo_version"] = rmoVersion
	r.Details["data_source"] = "RHOBS Prometheus rhobs_route_monitor_operator_* metrics"

	switch {
	case totalErrors > 0 && totalSuccess == 0:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("All RHOBS API calls failing (%d errors, 0 success)", totalErrors)
	case oidcErrors > 0 && oidcSuccess == 0:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("OIDC token refresh failing (%d errors, 0 success)", oidcErrors)
	case deletionTimeouts > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d probe deletion timeout(s)", deletionTimeouts)
	case totalErrors > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Some RHOBS API errors: %d errors out of %d total calls", totalErrors, totalSuccess+totalErrors)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("RHOBS API healthy: %d API calls, %d OIDC refreshes, 0 errors", totalSuccess, oidcSuccess)
	}

	cc.AddResult(r)
}

// checkRHOBSIntegration verifies RHOBS synthetics config and OIDC token health (all cluster types)
func checkRHOBSIntegration(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rmo_rhobs_integration")

	r := checks.Result{
		Check:    "rmo_rhobs_integration",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks whether RHOBS synthetics integration is configured on the RMO controller by inspecting PROBE_API_URL and OIDC_CLIENT_ID environment variables, then validates OIDC token refresh health via platform Thanos metrics. On management and service clusters, RHOBS integration enables centralized probe management for HCP endpoints. On standard clusters, RHOBS is not applicable.",
			"pass_criteria": "PASS: RHOBS enabled, OIDC configured, and token refreshes succeeding. WARN: OIDC token refresh failing or RHOBS enabled without OIDC configuration. INFO: RHOBS not configured (expected on standard clusters). SKIP: RHOBS enabled but elevation required for OIDC check.",
		},
	}

	// Check if RHOBS is enabled via env vars on the controller-manager
	podList, err := cc.Client.GetPods(ctx, cc.Operator.Namespace, "control-plane=controller-manager")

	rhobsEnabled := false
	oidcConfigured := false

	if err == nil && len(podList.Items) > 0 {
		pod := podList.Items[0]
		for _, container := range pod.Spec.Containers {
			if container.Name == "manager" {
				for _, env := range container.Env {
					if env.Name == "PROBE_API_URL" && env.Value != "" {
						rhobsEnabled = true
					}
					if env.Name == "OIDC_CLIENT_ID" && env.Value != "" {
						oidcConfigured = true
					}
				}
			}
		}
	}

	r.Details["rhobs_enabled"] = rhobsEnabled
	r.Details["oidc_configured"] = oidcConfigured
	r.Details["cluster_type"] = cc.ClusterType

	if !rhobsEnabled {
		r.Status = checks.StatusInfo
		if cc.ClusterType == "management_cluster" || cc.ClusterType == "service_cluster" {
			r.Message = fmt.Sprintf("RHOBS synthetics not configured on this %s (probe-api-url not set)", cc.ClusterType)
		} else {
			r.Message = "RHOBS synthetics not applicable (standard cluster)"
		}
		cc.AddResult(r)
		return
	}

	// Check OIDC token refresh metrics
	oidcQueryRaw := fmt.Sprintf(`rhobs_route_monitor_operator_oidc_token_refresh_total{namespace="%s"}`, cc.Operator.Namespace)
	oidcData, err := cc.Client.QueryMetrics(ctx, oidcQueryRaw)
	cc.RecordError("OIDC token refresh", err)

	oidcSuccess := 0.0
	oidcErrors := 0.0
	if resp, parseErr := thanos.Parse(oidcData); parseErr == nil {
		for _, result := range resp.Data.Result {
			val, ok := thanos.ToFloat(result)
			if !ok {
				continue
			}
			if result.Metric["status"] == "success" {
				oidcSuccess += val
			} else {
				oidcErrors += val
			}
		}
	}

	r.Details["oidc_refresh_success"] = int(oidcSuccess)
	r.Details["oidc_refresh_errors"] = int(oidcErrors)

	switch {
	case oidcErrors > 0 && oidcSuccess == 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("OIDC token refresh failing (%.0f errors, 0 success)", oidcErrors)
	case rhobsEnabled && !oidcConfigured:
		r.Status = checks.StatusWarning
		r.Message = "RHOBS enabled but OIDC not configured"
	default:
		r.Status = checks.StatusPass
		r.Message = "RHOBS synthetics healthy"
	}

	cc.AddResult(r)
}

// checkDualInstallation detects both OLM and PKO installed
// checkLimitedSupportDisagreement detects when HCP labels and Prometheus metrics disagree
func checkLimitedSupportDisagreement(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rmo_limited_support_disagreement")
	log := logging.WithCheck("rmo_limited_support_disagreement")

	r := checks.Result{
		Check:       "rmo_limited_support_disagreement",
		Description: "Checks if the HCP limited-support label and the Prometheus limited_support metric agree",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Compares the HCP limited-support label (api.openshift.com/limited-support) with the Prometheus limited_support metric for the cluster. When these disagree, RMO may make incorrect decisions about probe lifecycle — e.g., deleting probes for a cluster that is not actually in limited support, or maintaining probes for one that is. This check only runs on non-management clusters.",
			"pass_criteria": "PASS: HCP label and Prometheus metric agree (both indicate limited support or both indicate fully supported). WARN: label and metric disagree — one says limited support while the other does not.",
		},
	}

	// Get label from HCP — list all HCPs across namespaces and take the first
	labelValue := ""
	if cc.Client.CanElevate() {
		hcpList, err := cc.Client.ListResources(ctx, hostedControlPlaneGVR, "", true)
		if err == nil && len(hcpList.Items) > 0 {
			labels := hcpList.Items[0].GetLabels()
			labelValue = labels["api.openshift.com/limited-support"]
		}
	}
	r.Details["hcp_label_value"] = labelValue

	// Get metric from Thanos
	rawQuery := fmt.Sprintf(`limited_support{_id="%s"}`, cc.ClusterID)
	metricData, err := cc.Client.QueryMetrics(ctx, rawQuery)
	cc.RecordError("Query limited_support metric", err)

	metricValue := ""
	if err == nil && thanos.HasResults(metricData) {
		val, _, ok := thanos.InstantValue(metricData)
		if ok {
			metricValue = val
		}
	}
	r.Details["metric_value"] = metricValue

	if !cc.Client.CanElevate() {
		// Without elevation we can't read HCP labels — report metric only
		metricLS := metricValue == "1"
		r.Status = checks.StatusInfo
		if metricLS {
			r.Message = "Cluster in limited support (metric only — HCP label requires elevation)"
		} else {
			r.Message = "Cluster not in limited support (metric only — HCP label requires elevation)"
		}
		r.Details["degraded"] = "HCP label comparison unavailable without elevation"
		cc.AddResult(r)
		return
	}

	labelLS := labelValue == "true"
	metricLS := metricValue == "1"

	log.WithField("label_ls", labelLS).WithField("metric_ls", metricLS).Debug("LS check")

	if labelLS != metricLS {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Limited support disagreement — HCP label=%s, Prometheus metric=%s", labelValue, metricValue)
	} else {
		r.Status = checks.StatusPass
		if labelLS {
			r.Message = "Cluster is in limited support (label and metric agree)"
		} else {
			r.Message = "Cluster is fully supported (label and metric agree)"
		}
	}

	cc.AddResult(r)
}

func classifyProbeURL(url string) string {
	switch {
	case strings.Contains(url, "console"):
		return "console"
	case strings.Contains(url, "api") || strings.Contains(url, "livez"):
		return "api"
	case url != "":
		parts := strings.Split(url, "/")
		return parts[len(parts)-1]
	default:
		return "unknown"
	}
}

// checkProbeDisagreement analyzes RHOBS synthetic probe availability over 7 days per HCP
// and compares against internal pod health to detect external path issues (ROSAENG-60340).
// RHOBS probes hit the API through the external path (NLB → Router → KAS via backplane/VPCE),
// while internal health checks probe the service directly. When external probes fail but
// internal health is fine, the NLB/Router path is broken — api-EBB alerts fire correctly
// but the issue is in the external path, not the API itself. Restarting router pods typically fixes it.
func checkProbeDisagreement(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("rmo_probe_disagreement")

	r := checks.Result{
		Check:    "rmo_probe_disagreement",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Analyzes RHOBS synthetic probe success rate over 7 days per HCP and compares against kube-apiserver pod health. RHOBS probes hit the API through the external path (NLB → Router → KAS). When probes fail but pods are healthy, the external path (NLB/Router) is likely broken — api-EBB alerts fire correctly but the root cause is the external path, not the API itself. Common cause: OVN/Router issues on 4.21 MCs (ROSAENG-60340). Fix: restart router pods.",
			"pass_criteria": "PASS: All HCP probes at 100% over 7d. WARN: External path failures with healthy pods — investigate NLB/Router. FAIL: Both external probes and pods failing — real API issue.",
			"lookback_hours": 168.0,
		},
	}

	// Query 7-day probe success rate per HCP via RHOBS Prometheus range query
	now := time.Now().Unix()
	start := now - 604800
	step := 3600

	probeQuery := thanos.EncodeQuery(`avg_over_time(probe_success[1h])`)
	rangeData, rangeErr := cc.Client.QueryRHOBSPrometheusRange(ctx, probeQuery, start, now, step)
	cc.RecordError("RHOBS probe_success 7d range", rangeErr)

	if rangeErr != nil {
		r.Status = checks.StatusSkip
		r.Message = "Could not query RHOBS probe history"
		cc.AddResult(r)
		return
	}

	type hcpProbeAnalysis struct {
		HCPNamespace string  `json:"hcp_namespace"`
		ProbeURL     string  `json:"probe_url"`
		AvgSuccess   float64 `json:"avg_success_rate"`
		MinSuccess   float64 `json:"min_success_rate"`
		FailureHours int     `json:"failure_hours"`
		PodHealthy   string  `json:"pod_healthy"`
		Verdict      string  `json:"verdict"`
	}

	// Parse range data per probe URL, extract HCP namespace
	type probeHistory struct {
		url       string
		namespace string
		values    [][2]float64
	}

	probesByNS := map[string]*probeHistory{}

	if series, err := thanos.PerSeriesTimeseries(rangeData, func(m map[string]string) string {
		return m["probe_url"]
	}); err == nil {
		for _, s := range series {
			// Extract HCP namespace from probe URL
			ns := ""
			for _, part := range strings.Split(s.Label, ".") {
				if strings.HasPrefix(part, "ocm-") || strings.HasPrefix(part, "clusters-") {
					ns = part
					break
				}
			}
			if ns == "" {
				continue
			}
			if _, exists := probesByNS[ns]; !exists {
				probesByNS[ns] = &probeHistory{url: s.Label, namespace: ns, values: s.Values}
			}
		}
	}

	r.Details["hcp_probes_tracked"] = len(probesByNS)

	if len(probesByNS) == 0 {
		r.Status = checks.StatusSkip
		r.Message = "No per-HCP probe history available"
		cc.AddResult(r)
		return
	}

	// Analyze each HCP's probe history
	var analyses []hcpProbeAnalysis
	falsePositives := 0
	realFailures := 0
	perfectProbes := 0

	for ns, ph := range probesByNS {
		if len(ph.values) == 0 {
			continue
		}

		// Calculate avg and min success rate, count failure hours
		sum := 0.0
		minVal := 1.0
		failureHours := 0
		for _, v := range ph.values {
			sum += v[1]
			if v[1] < minVal {
				minVal = v[1]
			}
			if v[1] < 0.99 {
				failureHours++
			}
		}
		avg := sum / float64(len(ph.values))

		if failureHours == 0 {
			perfectProbes++
			continue
		}

		entry := hcpProbeAnalysis{
			HCPNamespace: ns,
			ProbeURL:     ph.url,
			AvgSuccess:   thanos.Round(avg*100, 2),
			MinSuccess:   thanos.Round(minVal*100, 2),
			FailureHours: failureHours,
		}

		// Check current kube-apiserver pod health
		pods, err := cc.Client.GetPods(ctx, ns, "app=kube-apiserver")
		if err != nil {
			entry.PodHealthy = "unknown"
			entry.Verdict = fmt.Sprintf("%.1f%% probe success, %dh failures, pod health unknown", avg*100, failureHours)
		} else {
			allRunning := true
			podCount := 0
			for _, pod := range pods.Items {
				podCount++
				if pod.Status.Phase != corev1.PodRunning {
					allRunning = false
				}
				for _, cs := range pod.Status.ContainerStatuses {
					if !cs.Ready {
						allRunning = false
					}
				}
			}

			if podCount == 0 {
				entry.PodHealthy = "no pods"
				entry.Verdict = fmt.Sprintf("%.1f%% probe success, %dh failures — HCP may be hibernated/deleted", avg*100, failureHours)
			} else if allRunning {
				entry.PodHealthy = fmt.Sprintf("healthy (%d pods)", podCount)
				entry.Verdict = fmt.Sprintf("EXTERNAL PATH ISSUE — %.1f%% probe success over 7d but kube-apiserver healthy (check NLB/Router)", avg*100)
				falsePositives++
			} else {
				entry.PodHealthy = fmt.Sprintf("unhealthy (%d pods)", podCount)
				entry.Verdict = fmt.Sprintf("API ISSUE — %.1f%% probe success and pods unhealthy", avg*100)
				realFailures++
			}
		}

		analyses = append(analyses, entry)
	}

	r.Details["perfect_probes"] = perfectProbes
	r.Details["external_path_issues"] = falsePositives
	r.Details["api_failures"] = realFailures
	if len(analyses) > 0 {
		r.Details["failing_hcp_analysis"] = analyses
	}

	// Also check if api-ErrorBudgetBurn is currently firing
	alertBody, alertErr := cc.Client.QueryActiveAlerts(ctx)
	ebbFiring := false
	if alertErr == nil {
		ebbFiring = strings.Contains(alertBody, "ErrorBudgetBurn")
	}
	r.Details["ebb_currently_firing"] = ebbFiring

	switch {
	case falsePositives > 0 && ebbFiring:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("api-EBB firing + %d HCP(s) with external path failures but healthy pods — investigate NLB/Router (ROSAENG-60340, try restarting router pods)", falsePositives)
	case falsePositives > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d HCP(s) had external path availability dips over 7d but pods are healthy — NLB/Router path was likely disrupted", falsePositives)
	case realFailures > 0:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("%d HCP(s) with both external probe failures and unhealthy pods — real API issue", realFailures)
	case perfectProbes == len(probesByNS):
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d HCP probes at 100%% over 7 days", perfectProbes)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d/%d HCP probes at 100%%, no current issues", perfectProbes, len(probesByNS))
	}

	cc.AddResult(r)
}
