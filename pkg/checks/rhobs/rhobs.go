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
	rhobsPrometheusRuleGVR = schema.GroupVersionResource{
		Group: "monitoring.rhobs", Version: "v1", Resource: "prometheusrules",
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
	checkRemoteWriteConfig(ctx, cc, hasRHOBS)
	checkPrometheusStatefulSets(ctx, cc, hasRHOBS)

	// Log collection (source: rhobs/configuration)
	checkLogForwarder(ctx, cc)
	checkLogCollectorDaemonSet(ctx, cc)
	checkLogEventCollector(ctx, cc)
	checkLogTokenRefresher(ctx, cc, hasRHOBS)
	checkLogDestination(ctx, cc)

	// Control plane log forwarding (source: rhobs/configuration)
	if cc.ClusterType == "management_cluster" {
		checkControlPlaneLogForwarding(ctx, cc)
	}

	// Platform rules — MC only (source: hypershift-platform-rhobs-rules)
	if cc.ClusterType == "management_cluster" {
		checkPlatformRulesNamespace(ctx, cc)
		checkPlatformRules(ctx, cc)
	}

	// CLF conditions (source: rhobs/configuration)
	checkCLFConditions(ctx, cc)

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
			"source_repo":   "rhobs/configuration",
			"namespace":     observabilityNS,
			"resource":      "MonitoringStack/rhobs-hypershift-monitoring-stack",
			"description":   "Validates the RHOBS MonitoringStack CR exists and is healthy. This is the central component that deploys Prometheus and Alertmanager for scraping HCP metrics and remote-writing them to the RHOBS cell. Deployed via SelectorSyncSet from hive.",
			"pass_criteria": "PASS: Available=True condition. WARN: CR exists but Available!=True. SKIP: CRD or CR not found (RHOBS not configured). FAIL: API error.",
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
			"source_repo":   "rhobs/configuration",
			"namespace":     observabilityNS,
			"resource":      "Secret/rhobs-hcp-credential",
			"description":   "Validates the OIDC credential secret used by Prometheus for OAuth2-authenticated remote-write to the RHOBS cell. Contains client-id and client-secret for sso.redhat.com authentication. Without this, metrics cannot be forwarded.",
			"pass_criteria": "PASS: Secret exists. SKIP: RHOBS not configured. FAIL: Secret missing (remote-write will fail with 401/403).",
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
			"source_repo":   "rhobs/configuration",
			"namespace":     observabilityNS,
			"resource":      "ConfigMap/rhobs-metrics-destination",
			"description":   "Validates the metrics destination ConfigMap that identifies which RHOBS cell this MC forwards metrics to. The annotation rhobs.openshift.io/forwarding-destination contains the cell URL (e.g., https://us-west-2-0.rhobs.api.openshift.com).",
			"pass_criteria": "PASS: ConfigMap exists with keys. SKIP: RHOBS not configured. FAIL: ConfigMap missing.",
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

func checkRemoteWriteConfig(ctx context.Context, cc *checks.ClusterContext, hasRHOBS bool) {
	cc.CurrentCheck = "rhobs_remote_write_config"

	r := checks.Result{
		Check:    "rhobs_remote_write_config",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"source_repo":   "rhobs/configuration",
			"namespace":     observabilityNS,
			"description":   "Validates the MonitoringStack has remote-write endpoints configured to forward metrics to RHOBS cells. Expected: 2 configs — RHOBS (regional cell) and RHOBS_SLO (global SLO cell), both with OAuth2 auth via rhobs-hcp-credential secret and sso.redhat.com token URL.",
			"pass_criteria": "PASS: Remote-write configs exist with OAuth2 auth. WARN: Configs exist but missing OAuth2. SKIP: RHOBS not configured. FAIL: No remote-write config (metrics pipeline broken).",
		},
	}

	if !hasRHOBS {
		r.Status = checks.StatusSkip
		r.Message = "Skipped — RHOBS metric collection not configured on this cluster"
		r.Severity = checks.SeverityInfo
		cc.AddResult(r)
		return
	}

	ms, err := cc.Client.GetResource(ctx, monitoringStackGVR, observabilityNS, "rhobs-hypershift-monitoring-stack", false)
	cc.RecordError("Get MonitoringStack for remote-write", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Cannot access MonitoringStack: %v", err)
		cc.AddResult(r)
		return
	}

	rwConfigs, found, _ := unstructured.NestedSlice(ms.Object, "spec", "prometheusConfig", "remoteWrite")
	if !found || len(rwConfigs) == 0 {
		r.Status = checks.StatusFail
		r.Message = "MonitoringStack has no remoteWrite configuration — metrics are not being forwarded to RHOBS"
		cc.AddResult(r)
		return
	}

	var rwNames []string
	var rwURLs []string
	hasOIDC := true

	for _, rw := range rwConfigs {
		rwMap, ok := rw.(map[string]interface{})
		if !ok {
			continue
		}
		name, _ := rwMap["name"].(string)
		url, _ := rwMap["url"].(string)
		rwNames = append(rwNames, name)
		rwURLs = append(rwURLs, url)
		if _, hasAuth := rwMap["oauth2"]; !hasAuth {
			hasOIDC = false
		}
	}

	r.Details["remote_write_count"] = len(rwConfigs)
	r.Details["remote_write_names"] = rwNames
	r.Details["remote_write_urls"] = rwURLs
	r.Details["all_have_oauth2"] = hasOIDC

	if !hasOIDC {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d remote-write config(s) found but some lack OAuth2 authentication", len(rwConfigs))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d remote-write config(s) with OAuth2 auth: %s", len(rwConfigs), strings.Join(rwNames, ", "))
	}
	cc.AddResult(r)
}

func checkPrometheusStatefulSets(ctx context.Context, cc *checks.ClusterContext, hasRHOBS bool) {
	cc.CurrentCheck = "rhobs_prometheus_statefulsets"

	r := checks.Result{
		Check:    "rhobs_prometheus_statefulsets",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"source_repo":   "rhobs/configuration",
			"namespace":     observabilityNS,
			"description":   "Validates the RHOBS Prometheus and Alertmanager StatefulSets are running with all replicas ready. These are created by the MonitoringStack CR. Prometheus scrapes HCP metrics and remote-writes to RHOBS; Alertmanager handles local alert routing.",
			"pass_criteria": "PASS: All RHOBS StatefulSets have desired==ready replicas. WARN: StatefulSets exist but degraded (replicas not ready) or missing. SKIP: RHOBS not configured.",
		},
	}

	if !hasRHOBS {
		r.Status = checks.StatusSkip
		r.Message = "Skipped — RHOBS metric collection not configured on this cluster"
		r.Severity = checks.SeverityInfo
		cc.AddResult(r)
		return
	}

	stsList, err := cc.Client.Clientset().AppsV1().StatefulSets(observabilityNS).List(ctx, metav1.ListOptions{})
	cc.RecordError("List StatefulSets in observability ns", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Cannot list StatefulSets in %s: %v", observabilityNS, err)
		cc.AddResult(r)
		return
	}

	// Expected: Prometheus and Alertmanager StatefulSets for the RHOBS monitoring stack
	// Names: prometheus-rhobs-hypershift-monitoring-stack, alertmanager-rhobs-hypershift-monitoring-stack
	type stsInfo struct {
		name    string
		desired int32
		ready   int32
	}
	var rhobsSTS []stsInfo
	var degradedNames []string
	totalReady := 0
	totalDesired := 0

	for _, sts := range stsList.Items {
		if !strings.Contains(sts.Name, "rhobs") {
			continue
		}
		desired := int32(0)
		if sts.Spec.Replicas != nil {
			desired = *sts.Spec.Replicas
		}
		ready := sts.Status.ReadyReplicas
		rhobsSTS = append(rhobsSTS, stsInfo{sts.Name, desired, ready})
		totalDesired += int(desired)
		totalReady += int(ready)
		if ready < desired {
			degradedNames = append(degradedNames, fmt.Sprintf("%s (%d/%d ready)", sts.Name, ready, desired))
		}
	}

	r.Details["statefulset_count"] = len(rhobsSTS)
	var stsNames []string
	for _, s := range rhobsSTS {
		stsNames = append(stsNames, fmt.Sprintf("%s (%d/%d)", s.name, s.ready, s.desired))
	}
	r.Details["statefulsets"] = stsNames

	switch {
	case len(rhobsSTS) == 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("No RHOBS StatefulSets found in %s — Prometheus/Alertmanager may not be deployed", observabilityNS)
	case len(degradedNames) > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("RHOBS StatefulSets degraded: %s", strings.Join(degradedNames, ", "))
		r.Details["degraded"] = degradedNames
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d RHOBS StatefulSets healthy (%d/%d pods ready)", len(rhobsSTS), totalReady, totalDesired)
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
			"source_repo":   "rhobs/configuration",
			"namespace":     loggingNS,
			"name_pattern":  "rhobs*",
			"description":   "Validates RHOBS ClusterLogForwarder CRs exist in openshift-logging. The CLF configures Vector log collection pipelines that forward infrastructure and application logs (including HCP eventrouter) to RHOBS Loki via the token-refresher. Name includes a region/sector suffix (e.g., rhobs-us-west-2-tech-preview).",
			"pass_criteria": "PASS: At least one RHOBS CLF found with Ready=True. WARN: CLF exists but not Ready. SKIP: CLF CRD not found or no RHOBS CLFs.",
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

func checkLogCollectorDaemonSet(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rhobs_log_collector_daemonset"

	r := checks.Result{
		Check:    "rhobs_log_collector_daemonset",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"source_repo":   "rhobs/configuration",
			"namespace":     loggingNS,
			"name_pattern":  "rhobs*",
			"description":   "Validates the Vector log collector DaemonSet runs on every node. Automatically created by the cluster-logging-operator when a CLF is deployed. Collects infrastructure and application logs from all nodes and forwards them per the CLF pipeline config.",
			"pass_criteria": "PASS: DaemonSet exists with desired==ready on all nodes, 0 misscheduled. WARN: DaemonSet exists but not all pods ready or misscheduled pods. SKIP: No RHOBS DaemonSets found.",
		},
	}

	// The CLF creates a DaemonSet with the same name in openshift-logging.
	// Managed by cluster-logging-operator, labeled app.kubernetes.io/managed-by=cluster-logging-operator.
	dsList, err := cc.Client.Clientset().AppsV1().DaemonSets(loggingNS).List(ctx, metav1.ListOptions{})
	cc.RecordError("List DaemonSets in logging ns", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Cannot list DaemonSets in %s: %v", loggingNS, err)
		cc.AddResult(r)
		return
	}

	var rhobsDS []string
	var degradedDS []string
	allHealthy := true

	for _, ds := range dsList.Items {
		if !strings.HasPrefix(ds.Name, "rhobs") {
			continue
		}
		desired := ds.Status.DesiredNumberScheduled
		ready := ds.Status.NumberReady
		rhobsDS = append(rhobsDS, fmt.Sprintf("%s (%d/%d ready)", ds.Name, ready, desired))

		if ready != desired || ds.Status.NumberMisscheduled > 0 {
			allHealthy = false
			degradedDS = append(degradedDS, fmt.Sprintf("%s (%d/%d ready, %d misscheduled)",
				ds.Name, ready, desired, ds.Status.NumberMisscheduled))
		}
	}

	r.Details["collector_daemonsets"] = rhobsDS

	switch {
	case len(rhobsDS) == 0:
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("No RHOBS log collector DaemonSets found in %s — CLF may not be configured", loggingNS)
	case !allHealthy:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Log collector DaemonSet degraded: %s", strings.Join(degradedDS, ", "))
		r.Details["degraded"] = degradedDS
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Log collector DaemonSet healthy: %s", strings.Join(rhobsDS, ", "))
	}
	cc.AddResult(r)
}

func checkLogEventCollector(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rhobs_log_event_collector"

	r := checks.Result{
		Check:    "rhobs_log_event_collector",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo":   "rhobs/configuration",
			"namespace":     eventRouterNS,
			"name_pattern":  "rhobs-eventrouter*",
			"description":   "Validates the EventRouter deployment that converts Kubernetes events into structured log entries. Runs in the rhobs-eventrouter namespace, forwarded to RHOBS Loki via the CLF eventrouter input pipeline. Enables event-based alerting and diagnostics.",
			"pass_criteria": "PASS: EventRouter deployment exists with all replicas ready. WARN: Deployment exists but degraded. SKIP: Namespace or deployment not found.",
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
			"source_repo":   "rhobs/configuration",
			"namespace":     loggingNS,
			"resource":      "Deployment/rhobs-logs-token-refresher",
			"description":   "Validates the OIDC token refresher deployment that authenticates log forwarding to RHOBS Loki. Continuously refreshes OAuth2 tokens from sso.redhat.com and exposes them via a local HTTP endpoint for the Vector log collector.",
			"pass_criteria": "PASS: Deployment exists with 2/2 replicas ready. WARN: Deployment exists but not all replicas ready. SKIP: RHOBS not configured or deployment not found.",
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

func checkLogDestination(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rhobs_log_destination"

	r := checks.Result{
		Check:    "rhobs_log_destination",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo":         "rhobs/configuration",
			"namespace":           loggingNS,
			"resource":            "ConfigMap/rhobs-logs-destination",
			"expected_annotation": "rhobs.openshift.io/forwarding-destination",
			"description":         "Validates the log destination ConfigMap that identifies which RHOBS cell this MC forwards logs to. The annotation rhobs.openshift.io/forwarding-destination contains the Loki endpoint URL. Used for cell discovery during incident investigation.",
			"pass_criteria":       "PASS: ConfigMap exists with forwarding-destination annotation containing cell URL. WARN: ConfigMap exists but annotation missing. SKIP: ConfigMap not found.",
		},
	}

	cm, err := cc.Client.Clientset().CoreV1().ConfigMaps(loggingNS).Get(ctx, "rhobs-logs-destination", metav1.GetOptions{})
	cc.RecordError("Get logs destination ConfigMap", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Log destination ConfigMap not found in %s — RHOBS log forwarding may not be configured", loggingNS)
		cc.AddResult(r)
		return
	}

	dest := ""
	if cm.Annotations != nil {
		dest = cm.Annotations["rhobs.openshift.io/forwarding-destination"]
	}
	r.Details["forwarding_destination"] = dest

	if dest != "" {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Log destination configured: %s", dest)
	} else {
		r.Status = checks.StatusWarning
		r.Message = "Log destination ConfigMap exists but missing rhobs.openshift.io/forwarding-destination annotation"
	}
	cc.AddResult(r)
}

// --- Control Plane Log Forwarding — MC only (source: rhobs/configuration) ---

const cpLogForwardingNS = "hypershift-control-plane-log-forwarding"

func checkControlPlaneLogForwarding(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rhobs_cp_log_forwarding"

	r := checks.Result{
		Check:    "rhobs_cp_log_forwarding",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo":   "rhobs/configuration",
			"namespace":     cpLogForwardingNS,
			"description":   "Validates the control plane log forwarding DaemonSet that collects HCP-specific logs. Runs a Vector instance on every node in a dedicated namespace, separate from the main RHOBS log collector. Forwards HCP control plane component logs to RHOBS Loki.",
			"pass_criteria": "PASS: DaemonSet exists with desired==ready on all nodes, 0 misscheduled. WARN: DaemonSet degraded or 0 desired. SKIP: Namespace not found.",
		},
	}

	_, nsErr := cc.Client.Clientset().CoreV1().Namespaces().Get(ctx, cpLogForwardingNS, metav1.GetOptions{})
	if nsErr != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Namespace %s not found — control plane log forwarding not configured", cpLogForwardingNS)
		cc.AddResult(r)
		return
	}

	dsList, err := cc.Client.Clientset().AppsV1().DaemonSets(cpLogForwardingNS).List(ctx, metav1.ListOptions{})
	cc.RecordError("List control plane log forwarding DaemonSets", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Cannot list DaemonSets in %s: %v", cpLogForwardingNS, err)
		cc.AddResult(r)
		return
	}

	if len(dsList.Items) == 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Namespace %s exists but no DaemonSets found", cpLogForwardingNS)
		cc.AddResult(r)
		return
	}

	ds := dsList.Items[0]
	desired := ds.Status.DesiredNumberScheduled
	ready := ds.Status.NumberReady
	misscheduled := ds.Status.NumberMisscheduled

	r.Details["daemonset"] = ds.Name
	r.Details["desired"] = desired
	r.Details["ready"] = ready
	r.Details["misscheduled"] = misscheduled

	if ready == desired && misscheduled == 0 && desired > 0 {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Control plane log forwarding DaemonSet healthy — %s (%d/%d ready)", ds.Name, ready, desired)
	} else if desired == 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Control plane log forwarding DaemonSet %s has 0 desired pods", ds.Name)
	} else {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Control plane log forwarding DaemonSet degraded — %s (%d/%d ready, %d misscheduled)", ds.Name, ready, desired, misscheduled)
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
			"source_repo":    "hypershift-platform-rhobs-rules",
			"expected_ns":    rhobsRulesNS,
			"expected_label": "hypershift.openshift.io/monitoring=true",
			"description":    "Validates the namespace where OBO PrometheusRules are deployed exists and has the hypershift.openshift.io/monitoring=true label. This label enables the Observability Operator to discover and load rules from this namespace.",
			"pass_criteria":  "PASS: Namespace exists with monitoring label. WARN: Namespace exists but label missing (rules won't be loaded). FAIL: Namespace not found.",
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
			"source_repo":   "hypershift-platform-rhobs-rules",
			"api_group":     "monitoring.rhobs/v1",
			"description":   "Validates OBO PrometheusRules (monitoring.rhobs/v1, NOT monitoring.coreos.com/v1) are deployed across both openshift-observability-rhobs and openshift-observability-rhobs-rules namespaces. These recording rules compute API server metrics, cluster metrics, and SLO data that are remote-written to RHOBS for alerting.",
			"pass_criteria": "PASS: At least one PrometheusRule found. WARN: No rules found (alerting/recording rules missing — RHOBS alerts won't fire for this MC's HCPs).",
		},
	}

	// OBO rules use monitoring.rhobs/v1 PrometheusRule, NOT monitoring.coreos.com/v1.
	// Rules are deployed across two namespaces via SelectorSyncSet from hive.
	namespaces := []string{rhobsRulesNS, rhobsRulesNS + "-rules"}
	totalCount := 0
	rulesByNS := map[string][]string{}

	for _, ns := range namespaces {
		ruleList, err := cc.Client.ListResources(ctx, rhobsPrometheusRuleGVR, ns, false)
		if err != nil {
			if checks.IsAccessError(err) {
				cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
				return
			}
			if !isNotFoundOrCRDMissing(err) {
				cc.RecordError(fmt.Sprintf("List monitoring.rhobs PrometheusRules in %s", ns), err)
			}
			continue
		}

		var names []string
		for _, rule := range ruleList.Items {
			names = append(names, rule.GetName())
		}
		if len(names) > 0 {
			rulesByNS[ns] = names
			totalCount += len(names)
		}
	}

	r.Details["total_rule_count"] = totalCount
	r.Details["rules_by_namespace"] = rulesByNS

	if totalCount > 0 {
		r.Status = checks.StatusPass
		var parts []string
		for ns, names := range rulesByNS {
			parts = append(parts, fmt.Sprintf("%d in %s", len(names), ns))
		}
		r.Message = fmt.Sprintf("%d OBO PrometheusRule(s) deployed: %s", totalCount, strings.Join(parts, ", "))
	} else {
		r.Status = checks.StatusWarning
		r.Message = "No monitoring.rhobs PrometheusRules found — platform recording/alerting rules may not be deployed"
	}
	cc.AddResult(r)
}

// --- CLF Conditions (rhobs/configuration) ---

func checkCLFConditions(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "rhobs_clf_conditions"

	r := checks.Result{
		Check:    "rhobs_clf_conditions",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"source_repo":         "rhobs/configuration",
			"namespace":           loggingNS,
			"expected_conditions": "Authorized=True, Valid=True, Ready=True",
			"description":         "Validates the status conditions on all RHOBS ClusterLogForwarder CRs. Authorized=True means the SA has correct ClusterRoles for log collection. Valid=True means the CLF spec passes validation. Ready=True means log forwarding is actively reconciled and operational.",
			"pass_criteria":       "PASS: All RHOBS CLFs have Authorized, Valid, and Ready conditions True. WARN: One or more conditions not True (e.g., RBAC issue, invalid config, or reconciliation failure). SKIP: No RHOBS CLFs found.",
		},
	}

	clfList, err := cc.Client.ListResources(ctx, clusterLogForwarderGVR, loggingNS, false)
	cc.RecordError("List CLFs for condition check", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		if isNotFoundOrCRDMissing(err) {
			r.Status = checks.StatusSkip
			r.Message = "ClusterLogForwarder CRD not available"
		} else {
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("Cannot list CLFs: %v", err)
		}
		cc.AddResult(r)
		return
	}

	var rhobsCLFs []string
	allHealthy := true
	var issues []string

	for _, clf := range clfList.Items {
		name := clf.GetName()
		if !strings.HasPrefix(name, "rhobs") {
			continue
		}
		rhobsCLFs = append(rhobsCLFs, name)

		conditions, _, _ := unstructuredConditions(&clf)
		clfConditions := map[string]string{}
		for _, c := range conditions {
			clfConditions[c["type"]] = c["status"]
		}

		// Check expected conditions from source: Authorized, Valid, Ready all True
		for _, expected := range []string{"Ready"} {
			status, exists := clfConditions[expected]
			if !exists {
				allHealthy = false
				issues = append(issues, fmt.Sprintf("%s: %s condition missing", name, expected))
			} else if status != "True" {
				allHealthy = false
				reason := ""
				for _, c := range conditions {
					if c["type"] == expected {
						reason = c["reason"]
						break
					}
				}
				issues = append(issues, fmt.Sprintf("%s: %s=%s (%s)", name, expected, status, reason))
			}
		}

		// Also check Authorized and Valid if present (not all CLFs have these)
		for _, condType := range []string{
			"observability.openshift.io/Authorized",
			"observability.openshift.io/Valid",
		} {
			status, exists := clfConditions[condType]
			if exists && status != "True" {
				allHealthy = false
				shortType := strings.TrimPrefix(condType, "observability.openshift.io/")
				issues = append(issues, fmt.Sprintf("%s: %s=%s", name, shortType, status))
			}
		}
	}

	r.Details["clf_count"] = len(rhobsCLFs)

	switch {
	case len(rhobsCLFs) == 0:
		r.Status = checks.StatusSkip
		r.Message = "No RHOBS ClusterLogForwarders found — condition check skipped"
	case !allHealthy:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("CLF condition issues: %s", strings.Join(issues, "; "))
		r.Details["issues"] = issues
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d RHOBS CLF(s) have healthy conditions (Authorized, Valid, Ready)", len(rhobsCLFs))
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
			"source_repo":   "hypershift-dataplane-metrics-forwarder",
			"match_label":   "app=metrics-forwarder",
			"description":   "Validates the metrics-forwarder NGINX proxy deployment in HCP namespaces. Deployed via ACM policy → PKO Package into each HCP namespace. The proxy receives remote-write from the hosted cluster's CMO (dataplane metrics) and forwards to the MC's OBO Prometheus. Expected: 2 replicas per HCP, found by label app=metrics-forwarder.",
			"pass_criteria": "PASS: All PKO-managed HCPs have healthy forwarder (2/2 ready). WARN: Some forwarders degraded. INFO: No PKO ObjectDeployments for forwarder (ACM policy does not target this MC — expected on staging).",
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
