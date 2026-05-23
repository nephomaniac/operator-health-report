package rhobs

import (
	"context"
	"fmt"
	"strings"

	"github.com/openshift/operator-health-report/pkg/checks"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func init() {
	checks.Register(&RHOBSChecker{})
}

type RHOBSChecker struct{}

func (c *RHOBSChecker) Name() string { return "rhobs" }

const (
	observabilityNS = "openshift-observability-operator"
	loggingNS       = "openshift-logging"
	eventRouterNS   = "rhobs-eventrouter"
	rhobsRulesNS    = "openshift-observability-rhobs"
)

var (
	monitoringStackGVR = schema.GroupVersionResource{
		Group: "monitoring.rhobs", Version: "v1alpha1", Resource: "monitoringstacks",
	}
	clusterLogForwarderGVR = schema.GroupVersionResource{
		Group: "observability.openshift.io", Version: "v1", Resource: "clusterlogforwarders",
	}
	prometheusRuleGVR = schema.GroupVersionResource{
		Group: "monitoring.coreos.com", Version: "v1", Resource: "prometheusrules",
	}
	hostedClusterGVR = schema.GroupVersionResource{
		Group: "hypershift.openshift.io", Version: "v1beta1", Resource: "hostedclusters",
	}
)

func (c *RHOBSChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	if cc.ClusterType != "management_cluster" && cc.ClusterType != "service_cluster" {
		cc.AddResult(checks.Result{
			Check:    "rhobs_cluster_type",
			Status:   checks.StatusInfo,
			Severity: checks.SeverityInfo,
			Message:  fmt.Sprintf("RHOBS observability checks not applicable on %s clusters — only MC/SC", cc.ClusterType),
			Details:  map[string]any{"cluster_type": cc.ClusterType},
		})
		return
	}

	// Metric collection (source: rhobs/configuration)
	// MonitoringStack is the anchor — if the CRD doesn't exist, RHOBS isn't configured on this MC.
	hasRHOBS := checkMonitoringStack(ctx, cc)
	checkMonitoringCredentials(ctx, cc, hasRHOBS)
	checkMetricsDestination(ctx, cc, hasRHOBS)

	// Log collection (source: rhobs/configuration)
	checkLogForwarder(ctx, cc)
	checkLogEventCollector(ctx, cc)
	checkLogTokenRefresher(ctx, cc, hasRHOBS)

	// Platform rules — MC only (source: hypershift-platform-rhobs-rules)
	if cc.ClusterType == "management_cluster" {
		checkPlatformRulesNamespace(ctx, cc)
		checkPlatformRules(ctx, cc)
	}

	// Metrics forwarder — MC only (source: hypershift-dataplane-metrics-forwarder)
	if cc.ClusterType == "management_cluster" {
		checkMetricsForwarder(ctx, cc)
	}
}

// --- Metric Collection (rhobs/configuration) ---

func checkMonitoringStack(ctx context.Context, cc *checks.ClusterContext) bool {
	cc.CurrentCheck = "rhobs_monitoring_stack"

	r := checks.Result{
		Check:    "rhobs_monitoring_stack",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"source_repo": "rhobs/configuration",
			"namespace":   observabilityNS,
			"resource":    "MonitoringStack/rhobs-hypershift-monitoring-stack",
		},
	}

	ms, err := cc.Client.GetResource(ctx, monitoringStackGVR, observabilityNS, "rhobs-hypershift-monitoring-stack", false)
	cc.RecordError("Get MonitoringStack", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return false
		}
		if isNotFoundOrCRDMissing(err) {
			r.Status = checks.StatusSkip
			r.Message = fmt.Sprintf("MonitoringStack CRD or resource not found in %s — RHOBS metric collection not configured on this cluster", observabilityNS)
		} else {
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("Cannot access MonitoringStack: %v", err)
		}
		cc.AddResult(r)
		return false
	}

	conditions, _, _ := unstructuredConditions(ms)
	r.Details["conditions"] = conditions

	available := false
	for _, c := range conditions {
		if c["type"] == "Available" && c["status"] == "True" {
			available = true
		}
	}

	if available {
		r.Status = checks.StatusPass
		r.Message = "MonitoringStack rhobs-hypershift-monitoring-stack is Available"
	} else {
		r.Status = checks.StatusWarning
		r.Message = "MonitoringStack exists but Available condition is not True"
	}
	cc.AddResult(r)
	return true
}

func checkMonitoringCredentials(ctx context.Context, cc *checks.ClusterContext, hasRHOBS bool) {
	cc.CurrentCheck = "rhobs_monitoring_credentials"

	r := checks.Result{
		Check:    "rhobs_monitoring_credentials",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"source_repo": "rhobs/configuration",
			"namespace":   observabilityNS,
			"resource":    "Secret/rhobs-hcp-credential",
		},
	}

	if !hasRHOBS {
		r.Status = checks.StatusSkip
		r.Message = "Skipped — RHOBS metric collection not configured on this cluster"
		r.Severity = checks.SeverityInfo
		cc.AddResult(r)
		return
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	_, err := cc.Client.ElevatedClientset().CoreV1().Secrets(observabilityNS).Get(ctx, "rhobs-hcp-credential", metav1.GetOptions{})
	cc.RecordError("Get RHOBS credential secret", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("RHOBS credential secret not found in %s: %v", observabilityNS, err)
		cc.AddResult(r)
		return
	}

	r.Status = checks.StatusPass
	r.Message = "RHOBS credential secret exists"
	cc.AddResult(r)
}

func checkMetricsDestination(ctx context.Context, cc *checks.ClusterContext, hasRHOBS bool) {
	cc.CurrentCheck = "rhobs_metrics_destination"

	r := checks.Result{
		Check:    "rhobs_metrics_destination",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo": "rhobs/configuration",
			"namespace":   observabilityNS,
			"resource":    "ConfigMap/rhobs-metrics-destination",
		},
	}

	if !hasRHOBS {
		r.Status = checks.StatusSkip
		r.Message = "Skipped — RHOBS metric collection not configured on this cluster"
		r.Severity = checks.SeverityInfo
		cc.AddResult(r)
		return
	}

	cm, err := cc.Client.Clientset().CoreV1().ConfigMaps(observabilityNS).Get(ctx, "rhobs-metrics-destination", metav1.GetOptions{})
	cc.RecordError("Get metrics destination ConfigMap", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Metrics destination ConfigMap not found in %s: %v", observabilityNS, err)
		cc.AddResult(r)
		return
	}

	r.Status = checks.StatusPass
	r.Message = "Metrics destination ConfigMap exists"
	if cm.Data != nil {
		r.Details["keys"] = mapKeys(cm.Data)
	}
	cc.AddResult(r)
}

// --- Log Collection (rhobs/configuration) ---

func checkLogForwarder(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rhobs_log_forwarder"

	r := checks.Result{
		Check:    "rhobs_log_forwarder",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo":  "rhobs/configuration",
			"namespace":    loggingNS,
			"name_pattern": "rhobs*",
		},
	}

	// CLF name includes a region/sector suffix (e.g., rhobs-us-west-2-tech-preview)
	// so we list all CLFs in the logging namespace and filter by prefix.
	clfList, err := cc.Client.ListResources(ctx, clusterLogForwarderGVR, loggingNS, false)
	cc.RecordError("List ClusterLogForwarders", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		if isNotFoundOrCRDMissing(err) {
			r.Status = checks.StatusSkip
			r.Message = fmt.Sprintf("ClusterLogForwarder CRD not found — log forwarding not available on this cluster")
		} else {
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("Cannot list ClusterLogForwarders: %v", err)
		}
		cc.AddResult(r)
		return
	}

	var rhobsCLFs []string
	var readyCount int
	var notReadyCLFs []string

	for _, clf := range clfList.Items {
		name := clf.GetName()
		if !strings.HasPrefix(name, "rhobs") {
			continue
		}
		rhobsCLFs = append(rhobsCLFs, name)

		conditions, _, _ := unstructuredConditions(&clf)
		ready := false
		for _, c := range conditions {
			if c["type"] == "Ready" && c["status"] == "True" {
				ready = true
			}
		}
		if ready {
			readyCount++
		} else {
			notReadyCLFs = append(notReadyCLFs, name)
		}
	}

	r.Details["rhobs_clf_count"] = len(rhobsCLFs)
	r.Details["rhobs_clf_names"] = rhobsCLFs
	r.Details["ready_count"] = readyCount

	switch {
	case len(rhobsCLFs) == 0:
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("No RHOBS ClusterLogForwarders found in %s", loggingNS)
	case len(notReadyCLFs) > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d RHOBS ClusterLogForwarder(s) not Ready: %s",
			len(notReadyCLFs), len(rhobsCLFs), strings.Join(notReadyCLFs, ", "))
		r.Details["not_ready"] = notReadyCLFs
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d RHOBS ClusterLogForwarder(s) Ready: %s",
			len(rhobsCLFs), strings.Join(rhobsCLFs, ", "))
	}
	cc.AddResult(r)
}

func checkLogEventCollector(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rhobs_log_event_collector"

	r := checks.Result{
		Check:    "rhobs_log_event_collector",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo":  "rhobs/configuration",
			"namespace":    eventRouterNS,
			"name_pattern": "rhobs-eventrouter*",
		},
	}

	// Check if the eventrouter namespace exists first
	_, nsErr := cc.Client.Clientset().CoreV1().Namespaces().Get(ctx, eventRouterNS, metav1.GetOptions{})
	if nsErr != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Namespace %s not found — event collector not configured on this cluster", eventRouterNS)
		cc.AddResult(r)
		return
	}

	// Deployment name includes a suffix (e.g., rhobs-eventrouter-us-west-2-tech-preview)
	deployList, err := cc.Client.Clientset().AppsV1().Deployments(eventRouterNS).List(ctx, metav1.ListOptions{})
	cc.RecordError("List event collector deployments", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Cannot list deployments in %s: %v", eventRouterNS, err)
		cc.AddResult(r)
		return
	}

	var erNames []string
	var degradedNames []string
	healthy := 0

	for _, d := range deployList.Items {
		if !strings.HasPrefix(d.Name, "rhobs-eventrouter") {
			continue
		}
		erNames = append(erNames, d.Name)
		if d.Status.ReadyReplicas > 0 && d.Status.ReadyReplicas == d.Status.Replicas {
			healthy++
		} else {
			degradedNames = append(degradedNames, fmt.Sprintf("%s (%d/%d ready)", d.Name, d.Status.ReadyReplicas, d.Status.Replicas))
		}
	}

	r.Details["eventrouter_count"] = len(erNames)
	r.Details["eventrouter_names"] = erNames

	switch {
	case len(erNames) == 0:
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("No RHOBS EventRouter deployments found in %s", eventRouterNS)
	case len(degradedNames) > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d EventRouter(s) degraded: %s", len(degradedNames), len(erNames), strings.Join(degradedNames, ", "))
		r.Details["degraded"] = degradedNames
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d EventRouter(s) healthy: %s", len(erNames), strings.Join(erNames, ", "))
	}
	cc.AddResult(r)
}

func checkLogTokenRefresher(ctx context.Context, cc *checks.ClusterContext, hasRHOBS bool) {
	cc.CurrentCheck = "rhobs_log_token_refresher"

	r := checks.Result{
		Check:    "rhobs_log_token_refresher",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo": "rhobs/configuration",
			"namespace":   loggingNS,
			"resource":    "Deployment/rhobs-logs-token-refresher",
		},
	}

	if !hasRHOBS {
		r.Status = checks.StatusSkip
		r.Message = "Skipped — RHOBS metric collection not configured on this cluster"
		r.Severity = checks.SeverityInfo
		cc.AddResult(r)
		return
	}

	deploy, err := cc.Client.Clientset().AppsV1().Deployments(loggingNS).Get(ctx, "rhobs-logs-token-refresher", metav1.GetOptions{})
	cc.RecordError("Get token refresher deployment", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Token refresher deployment not found in %s — may not be configured", loggingNS)
		cc.AddResult(r)
		return
	}

	r.Details["desired_replicas"] = deploy.Status.Replicas
	r.Details["ready_replicas"] = deploy.Status.ReadyReplicas

	if deploy.Status.ReadyReplicas > 0 && deploy.Status.ReadyReplicas == deploy.Status.Replicas {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Token refresher healthy — %d/%d replicas ready", deploy.Status.ReadyReplicas, deploy.Status.Replicas)
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Token refresher degraded — %d/%d replicas ready", deploy.Status.ReadyReplicas, deploy.Status.Replicas)
	}
	cc.AddResult(r)
}

// --- Platform Rules (hypershift-platform-rhobs-rules) — MC only ---

func checkPlatformRulesNamespace(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rhobs_platform_rules_namespace"

	r := checks.Result{
		Check:    "rhobs_platform_rules_namespace",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo":      "hypershift-platform-rhobs-rules",
			"expected_ns":      rhobsRulesNS,
			"expected_label":   "hypershift.openshift.io/monitoring=true",
		},
	}

	ns, err := cc.Client.Clientset().CoreV1().Namespaces().Get(ctx, rhobsRulesNS, metav1.GetOptions{})
	cc.RecordError("Get RHOBS rules namespace", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Namespace %s not found — platform rules cannot be deployed", rhobsRulesNS)
		cc.AddResult(r)
		return
	}

	hasLabel := ns.Labels["hypershift.openshift.io/monitoring"] == "true"
	r.Details["has_monitoring_label"] = hasLabel

	if hasLabel {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Namespace %s exists with monitoring label", rhobsRulesNS)
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Namespace %s exists but missing hypershift.openshift.io/monitoring=true label", rhobsRulesNS)
	}
	cc.AddResult(r)
}

func checkPlatformRules(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rhobs_platform_rules"

	r := checks.Result{
		Check:    "rhobs_platform_rules",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo": "hypershift-platform-rhobs-rules",
			"namespace":   rhobsRulesNS,
		},
	}

	ruleList, err := cc.Client.ListResources(ctx, prometheusRuleGVR, rhobsRulesNS, false)
	cc.RecordError("List PrometheusRules in RHOBS rules ns", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Cannot list PrometheusRules in %s: %v", rhobsRulesNS, err)
		cc.AddResult(r)
		return
	}

	ruleCount := len(ruleList.Items)
	r.Details["rule_count"] = ruleCount

	var ruleNames []string
	for _, rule := range ruleList.Items {
		ruleNames = append(ruleNames, rule.GetName())
	}
	r.Details["rules"] = ruleNames

	if ruleCount > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d PrometheusRule(s) deployed in %s", ruleCount, rhobsRulesNS)
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("No PrometheusRules found in %s — platform alerting/recording rules may be missing", rhobsRulesNS)
	}
	cc.AddResult(r)
}

// --- Metrics Forwarder (hypershift-dataplane-metrics-forwarder) — MC only ---

func checkMetricsForwarder(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rhobs_metrics_forwarder"

	r := checks.Result{
		Check:    "rhobs_metrics_forwarder",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo": "hypershift-dataplane-metrics-forwarder",
			"match_label": "app=metrics-forwarder",
		},
	}

	hcList, err := cc.Client.ListResources(ctx, hostedClusterGVR, "", false)
	cc.RecordError("List HostedClusters", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		if isNotFoundOrCRDMissing(err) {
			r.Status = checks.StatusSkip
			r.Message = "HostedCluster CRD not found — not an MC or HyperShift not installed"
		} else {
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("Cannot list HostedClusters: %v", err)
		}
		cc.AddResult(r)
		return
	}

	hcpCount := len(hcList.Items)
	r.Details["hcp_count"] = hcpCount

	if hcpCount == 0 {
		r.Status = checks.StatusInfo
		r.Message = "No HostedClusters found on this MC"
		cc.AddResult(r)
		return
	}

	// Deployed via ACM policy → PKO Package → ObjectDeployment in each HCP namespace.
	// HCP control plane namespace = {HostedCluster.namespace}-{HostedCluster.name}.
	// If no PKO ObjectDeployment exists for the forwarder, ACM policy doesn't target this MC.
	// When managed by PKO: deployment uses label app=metrics-forwarder, expects 2 replicas.

	objectDeploymentGVR := schema.GroupVersionResource{
		Group: "package-operator.run", Version: "v1alpha1", Resource: "objectdeployments",
	}

	managed := 0    // HCPs with PKO ObjectDeployment for the forwarder
	healthy := 0    // forwarder deployment running 2/2
	degraded := 0   // forwarder deployment exists but not all replicas ready
	unmanaged := 0  // no PKO ObjectDeployment — forwarder not expected
	var degradedExamples []string
	var healthyExamples []string

	for _, hc := range hcList.Items {
		hcpNS := hc.GetNamespace() + "-" + hc.GetName()

		// Check if PKO manages a metrics-forwarder in this HCP namespace
		odList, odErr := cc.Client.ListResources(ctx, objectDeploymentGVR, hcpNS, false)
		hasPKO := false
		if odErr == nil {
			for _, od := range odList.Items {
				if strings.Contains(od.GetName(), "metrics-forwarder") {
					hasPKO = true
					break
				}
			}
		}

		if !hasPKO {
			unmanaged++
			continue
		}

		managed++
		deployList, listErr := cc.Client.Clientset().AppsV1().Deployments(hcpNS).List(ctx, metav1.ListOptions{
			LabelSelector: "app=metrics-forwarder",
		})
		if listErr != nil || len(deployList.Items) == 0 {
			degraded++
			degradedExamples = append(degradedExamples, fmt.Sprintf("%s: PKO managed but no deployment found", hcpNS))
			continue
		}

		d := deployList.Items[0]
		if d.Status.ReadyReplicas >= 2 && d.Status.ReadyReplicas == d.Status.Replicas {
			healthy++
			if len(healthyExamples) < 3 {
				healthyExamples = append(healthyExamples, fmt.Sprintf("%s/%s (%d/%d ready)",
					hcpNS, d.Name, d.Status.ReadyReplicas, d.Status.Replicas))
			}
		} else {
			degraded++
			degradedExamples = append(degradedExamples, fmt.Sprintf("%s/%s (%d/%d ready)",
				hcpNS, d.Name, d.Status.ReadyReplicas, d.Status.Replicas))
		}
	}

	r.Details["hcp_managed_by_pko"] = managed
	r.Details["hcp_not_managed"] = unmanaged
	r.Details["hcp_forwarder_healthy"] = healthy
	r.Details["hcp_forwarder_degraded"] = degraded
	if len(degradedExamples) > 0 {
		r.Details["degraded_forwarders"] = degradedExamples
	}
	if len(healthyExamples) > 0 {
		r.Details["healthy_examples"] = healthyExamples
	}

	switch {
	case managed == 0:
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("Metrics forwarder not PKO-managed in any of %d HCP namespaces — ACM policy does not target this MC", hcpCount)
	case managed > 0 && degraded == 0:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Metrics forwarder healthy in all %d PKO-managed HCPs (2/2 ready); %d HCPs not managed", managed, unmanaged)
	case degraded > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Metrics forwarder: %d healthy, %d degraded out of %d PKO-managed HCPs", healthy, degraded, managed)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Metrics forwarder deployed in %d PKO-managed HCPs", managed)
	}
	cc.AddResult(r)
}

// --- Helpers ---

func unstructuredConditions(obj *unstructured.Unstructured) ([]map[string]string, bool, error) {
	conditions, found, err := unstructured.NestedSlice(obj.Object, "status", "conditions")
	if err != nil || !found {
		return nil, false, err
	}

	var result []map[string]string
	for _, c := range conditions {
		cMap, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		entry := map[string]string{}
		for _, key := range []string{"type", "status", "reason", "message"} {
			if v, ok := cMap[key].(string); ok {
				entry[key] = v
			}
		}
		result = append(result, entry)
	}
	return result, true, nil
}

func isNotFoundOrCRDMissing(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "not found") ||
		strings.Contains(msg, "the server could not find the requested resource") ||
		strings.Contains(msg, "no matches for kind")
}

func mapKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}
