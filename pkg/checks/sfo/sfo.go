package sfo

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

func init() {
	checks.Register(&SFOChecker{})
}

type SFOChecker struct{}

func (c *SFOChecker) Name() string { return "sfo" }

const (
	// The operator runs in its own namespace but manages resources in openshift-security
	securityNamespace = "openshift-security"
)

var (
	splunkForwarderGVR = schema.GroupVersionResource{
		Group: "splunkforwarder.managed.openshift.io", Version: "v1alpha1", Resource: "splunkforwarders",
	}
	serviceMonitorGVR = schema.GroupVersionResource{
		Group: "monitoring.coreos.com", Version: "v1", Resource: "servicemonitors",
	}
	prometheusRuleGVR = schema.GroupVersionResource{
		Group: "monitoring.coreos.com", Version: "v1", Resource: "prometheusrules",
	}
)

func (c *SFOChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	checkControllerAvailability(ctx, cc)
	hasCR := checkSplunkForwarderCR(ctx, cc)
	checkSecrets(ctx, cc, hasCR)
	checkDaemonSetHealth(ctx, cc, hasCR)
	checkForwarderPods(ctx, cc, hasCR)
	checkConfigMaps(ctx, cc, hasCR)
	checkAuditExporter(ctx, cc)
	checkForwarderMetrics(ctx, cc, hasCR)
	checkServiceMonitor(ctx, cc)
	checkPrometheusRule(ctx, cc)
}

// checkControllerAvailability checks the operator deployment Available condition
func checkControllerAvailability(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "sfo_controller_availability"

	r := checks.Result{
		Check:    "sfo_controller_availability",
		Severity: checks.SeverityCritical,
		Details:  map[string]any{},
	}

	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	cc.RecordError("Get SFO deployment", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("Cannot access deployment %s/%s: %v", cc.Operator.Namespace, cc.Operator.Deployment, err)
			cc.AddResult(r)
		}
		return
	}

	available := ""
	for _, cond := range deploy.Status.Conditions {
		if string(cond.Type) == "Available" {
			available = string(cond.Status)
			break
		}
	}

	r.Details["deployment"] = fmt.Sprintf("%s/%s", cc.Operator.Namespace, cc.Operator.Deployment)
	r.Details["available"] = available

	if available == "True" {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Controller %s/%s is available", cc.Operator.Namespace, cc.Operator.Deployment)
	} else {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Controller %s/%s not available", cc.Operator.Namespace, cc.Operator.Deployment)
	}

	cc.AddResult(r)
}

// checkSplunkForwarderCR verifies the SplunkForwarder CR exists in openshift-security.
// Returns true if at least one CR was found.
func checkSplunkForwarderCR(ctx context.Context, cc *checks.ClusterContext) bool {
	cc.CurrentCheck = "sfo_splunkforwarder_cr"

	r := checks.Result{
		Check:    "sfo_splunkforwarder_cr",
		Severity: checks.SeverityWarning,
		Details:  map[string]any{},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return false
	}

	// CR is deployed in openshift-security, not the operator namespace
	list, err := cc.Client.ListResources(ctx, splunkForwarderGVR, securityNamespace, true)
	cc.RecordError("List SplunkForwarder CRs", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusSkip
			r.Message = fmt.Sprintf("Could not query SplunkForwarder CRs in %s: %v", securityNamespace, err)
			cc.AddResult(r)
		}
		return false
	}

	crCount := len(list.Items)
	r.Details["cr_count"] = crCount
	r.Details["namespace"] = securityNamespace

	if crCount == 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("No SplunkForwarder CR in %s — CR is deployed via SSS, absence may indicate a Hive ClusterSync issue", securityNamespace)
		r.Details["investigation"] = "The SplunkForwarder CR is bundled in the operator's SSS template. If the operator namespace exists but the CR is missing, check Hive ClusterSync status."
		cc.AddResult(r)
		return false
	}

	cr := list.Items[0]
	crName := cr.GetName()

	image, _, _ := unstructured.NestedString(cr.Object, "spec", "image")
	imageDigest, _, _ := unstructured.NestedString(cr.Object, "spec", "imageDigest")
	clusterID, _, _ := unstructured.NestedString(cr.Object, "spec", "clusterID")
	licenseAccepted, _, _ := unstructured.NestedBool(cr.Object, "spec", "splunkLicenseAccepted")
	useHeavy, _, _ := unstructured.NestedBool(cr.Object, "spec", "useHeavyForwarder")
	inputs, _, _ := unstructured.NestedSlice(cr.Object, "spec", "splunkInputs")
	filters, _, _ := unstructured.NestedSlice(cr.Object, "spec", "filters")

	r.Details["cr_name"] = fmt.Sprintf("%s/%s", securityNamespace, crName)
	r.Details["image"] = image
	if imageDigest != "" {
		r.Details["image_digest"] = truncate(imageDigest, 19)
	}
	r.Details["cluster_id"] = clusterID
	r.Details["license_accepted"] = licenseAccepted
	r.Details["use_heavy_forwarder"] = useHeavy
	r.Details["input_count"] = len(inputs)
	r.Details["filter_count"] = len(filters)

	r.Status = checks.StatusPass
	r.Message = fmt.Sprintf("SplunkForwarder CR %s/%s configured (%d inputs, heavy=%v)",
		securityNamespace, crName, len(inputs), useHeavy)

	cc.AddResult(r)
	return true
}

// checkSecrets verifies splunk auth and HEC token secrets in openshift-security
func checkSecrets(ctx context.Context, cc *checks.ClusterContext, hasCR bool) {
	cc.CurrentCheck = "sfo_secrets"
	log := logging.WithCheck("sfo_secrets")

	r := checks.Result{
		Check:    "sfo_secrets",
		Severity: checks.SeverityWarning,
		Details:  map[string]any{"namespace": securityNamespace},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	secrets := []struct {
		name     string
		required bool
		desc     string
	}{
		{"splunk-auth", true, "mTLS certificate for Splunk connection"},
		{"splunk-hec-token", false, "HTTP Event Collector token (alternative to mTLS)"},
	}

	found := 0
	var missing []string

	for _, s := range secrets {
		ref := fmt.Sprintf("%s/%s", securityNamespace, s.name)
		_, err := cc.Client.ElevatedClientset().CoreV1().Secrets(securityNamespace).Get(ctx, s.name, metav1.GetOptions{})
		if err == nil {
			found++
			r.Details[s.name] = "present"
		} else {
			r.Details[s.name] = "missing"
			if s.required {
				missing = append(missing, ref)
			}
		}
	}

	log.WithField("found", found).Debug("SFO secrets check")

	switch {
	case len(missing) > 0 && hasCR:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("Required secret(s) missing: %s — operator cannot reconcile without auth credentials", strings.Join(missing, ", "))
	case len(missing) > 0 && !hasCR:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Secret(s) missing: %s (CR also missing — possible SSS sync issue)", strings.Join(missing, ", "))
		r.Details["investigation"] = "Both secrets and CR are deployed via SSS. Check Hive ClusterSync."
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d auth secret(s) present in %s", found, securityNamespace)
	}

	cc.AddResult(r)
}

// checkDaemonSetHealth verifies the splunk forwarder DaemonSet in openshift-security
func checkDaemonSetHealth(ctx context.Context, cc *checks.ClusterContext, hasCR bool) {
	cc.CurrentCheck = "sfo_daemonset_health"

	r := checks.Result{
		Check:    "sfo_daemonset_health",
		Severity: checks.SeverityCritical,
		Details:  map[string]any{"namespace": securityNamespace},
	}

	if !hasCR {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Skipped — no SplunkForwarder CR in %s", securityNamespace)
		r.Details["dependency"] = "SplunkForwarder CR → operator reconcile → DaemonSet creation"
		cc.AddResult(r)
		return
	}

	dsList, err := cc.Client.Clientset().AppsV1().DaemonSets(securityNamespace).List(ctx, metav1.ListOptions{})
	cc.RecordError("List DaemonSets in "+securityNamespace, err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("Could not list DaemonSets in %s: %v", securityNamespace, err)
			cc.AddResult(r)
		}
		return
	}

	var splunkDS []map[string]any
	for _, ds := range dsList.Items {
		if !strings.Contains(ds.Name, "splunk") {
			continue
		}
		desired := int(ds.Status.DesiredNumberScheduled)
		ready := int(ds.Status.NumberReady)

		dsInfo := map[string]any{
			"name":    fmt.Sprintf("%s/%s", securityNamespace, ds.Name),
			"desired": desired,
			"ready":   ready,
		}
		if ds.Status.NumberUnavailable > 0 {
			dsInfo["unavailable"] = int(ds.Status.NumberUnavailable)
		}
		splunkDS = append(splunkDS, dsInfo)
	}

	r.Details["daemonsets"] = splunkDS

	switch {
	case len(splunkDS) == 0:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("No splunk DaemonSet found in %s — operator reconciliation may have failed", securityNamespace)
		r.Details["investigation"] = "CR exists but no DaemonSet was created. Check operator logs for reconciliation errors."
	default:
		allHealthy := true
		var issues []string
		totalPods := 0
		for _, ds := range splunkDS {
			desired := ds["desired"].(int)
			ready := ds["ready"].(int)
			totalPods += desired
			if ready != desired {
				allHealthy = false
				issues = append(issues, fmt.Sprintf("%s: %d/%d ready", ds["name"], ready, desired))
			}
		}
		if allHealthy {
			r.Status = checks.StatusPass
			r.Message = fmt.Sprintf("%d DaemonSet(s) healthy (%d pods across all nodes)", len(splunkDS), totalPods)
		} else {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("DaemonSet not fully ready: %s", strings.Join(issues, "; "))
		}
	}

	cc.AddResult(r)
}

// checkForwarderPods verifies forwarder pods are running on nodes
func checkForwarderPods(ctx context.Context, cc *checks.ClusterContext, hasCR bool) {
	cc.CurrentCheck = "sfo_forwarder_pods"

	r := checks.Result{
		Check:    "sfo_forwarder_pods",
		Severity: checks.SeverityWarning,
		Details:  map[string]any{"namespace": securityNamespace},
	}

	if !hasCR {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Skipped — no SplunkForwarder CR in %s", securityNamespace)
		r.Details["dependency"] = "SplunkForwarder CR → DaemonSet → forwarder pods"
		cc.AddResult(r)
		return
	}

	pods, err := cc.Client.GetPods(ctx, securityNamespace, "name=splunk-forwarder")
	cc.RecordError("Get forwarder pods in "+securityNamespace, err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusSkip
			r.Message = fmt.Sprintf("Could not retrieve forwarder pods in %s", securityNamespace)
			cc.AddResult(r)
		}
		return
	}

	podCount := len(pods.Items)
	notRunning := 0
	totalRestarts := 0
	var podIssues []map[string]any

	for _, pod := range pods.Items {
		if pod.Status.Phase != corev1.PodRunning {
			notRunning++
			issue := map[string]any{
				"pod":   fmt.Sprintf("%s/%s", securityNamespace, pod.Name),
				"phase": string(pod.Status.Phase),
				"node":  pod.Spec.NodeName,
			}
			for _, cs := range pod.Status.ContainerStatuses {
				if cs.State.Waiting != nil {
					issue["waiting_reason"] = cs.State.Waiting.Reason
				}
				if cs.State.Terminated != nil {
					issue["terminated_reason"] = cs.State.Terminated.Reason
					issue["exit_code"] = cs.State.Terminated.ExitCode
				}
			}
			podIssues = append(podIssues, issue)
		}
		for _, cs := range pod.Status.ContainerStatuses {
			totalRestarts += int(cs.RestartCount)
		}
	}

	r.Details["pod_count"] = podCount
	r.Details["not_running"] = notRunning
	r.Details["total_restarts"] = totalRestarts
	if len(podIssues) > 0 {
		r.Details["pod_issues"] = podIssues
	}

	switch {
	case podCount == 0:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("No forwarder pods (label: name=splunk-forwarder) in %s — DaemonSet may have failed", securityNamespace)
	case notRunning > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d forwarder pod(s) not running in %s", notRunning, podCount, securityNamespace)
	case totalRestarts > 10:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d forwarder pods (%d total restarts) in %s", podCount, totalRestarts, securityNamespace)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d forwarder pods running across nodes (%d restarts)", podCount, totalRestarts)
	}

	cc.AddResult(r)
}

// checkConfigMaps verifies the splunk configuration ConfigMaps in openshift-security
func checkConfigMaps(ctx context.Context, cc *checks.ClusterContext, hasCR bool) {
	cc.CurrentCheck = "sfo_configmaps"

	r := checks.Result{
		Check:    "sfo_configmaps",
		Severity: checks.SeverityWarning,
		Details:  map[string]any{"namespace": securityNamespace},
	}

	if !hasCR {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Skipped — no SplunkForwarder CR in %s", securityNamespace)
		r.Details["dependency"] = "SplunkForwarder CR → operator reconcile → ConfigMap creation"
		cc.AddResult(r)
		return
	}

	expectedCMs := []struct {
		name string
		desc string
	}{
		{"osd-monitored-logs-local", "Splunk input configuration (inputs.conf, props.conf)"},
		{"osd-monitored-logs-metadata", "Splunk app metadata (local.meta)"},
	}

	found := 0
	var missing []string
	var cmDetails []map[string]any

	for _, cm := range expectedCMs {
		ref := fmt.Sprintf("%s/%s", securityNamespace, cm.name)
		obj, err := cc.Client.Clientset().CoreV1().ConfigMaps(securityNamespace).Get(ctx, cm.name, metav1.GetOptions{})
		if err == nil {
			found++
			detail := map[string]any{
				"name":   ref,
				"status": "present",
				"keys":   len(obj.Data),
			}
			cmDetails = append(cmDetails, detail)
		} else {
			missing = append(missing, ref)
			cmDetails = append(cmDetails, map[string]any{
				"name":   ref,
				"status": "missing",
				"desc":   cm.desc,
			})
		}
	}

	r.Details["configmaps"] = cmDetails

	switch {
	case len(missing) > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("ConfigMap(s) missing: %s — operator may not have reconciled", strings.Join(missing, ", "))
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d configuration ConfigMap(s) present in %s", found, securityNamespace)
	}

	cc.AddResult(r)
}

// checkAuditExporter verifies the audit-exporter DaemonSet runs on master nodes
func checkAuditExporter(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "sfo_audit_exporter"

	r := checks.Result{
		Check:    "sfo_audit_exporter",
		Severity: checks.SeverityWarning,
		Details:  map[string]any{"namespace": securityNamespace},
	}

	ds, err := cc.Client.Clientset().AppsV1().DaemonSets(securityNamespace).Get(ctx, "audit-exporter", metav1.GetOptions{})
	cc.RecordError("Get audit-exporter DaemonSet", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("audit-exporter DaemonSet not found in %s — audit log filtering not active", securityNamespace)
			r.Details["investigation"] = "audit-exporter is deployed via SSS to filter KAS audit logs before forwarding to Splunk."
			cc.AddResult(r)
		}
		return
	}

	desired := int(ds.Status.DesiredNumberScheduled)
	ready := int(ds.Status.NumberReady)

	r.Details["daemonset"] = fmt.Sprintf("%s/audit-exporter", securityNamespace)
	r.Details["desired"] = desired
	r.Details["ready"] = ready

	// Check audit policy ConfigMap
	_, policyErr := cc.Client.Clientset().CoreV1().ConfigMaps(securityNamespace).Get(ctx, "osd-audit-policy", metav1.GetOptions{})
	r.Details["audit_policy_configmap"] = policyErr == nil

	switch {
	case ready != desired:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("audit-exporter %s/audit-exporter not fully ready (%d/%d on master nodes)", securityNamespace, ready, desired)
	case policyErr != nil:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("audit-exporter running (%d/%d) but %s/osd-audit-policy ConfigMap missing", ready, desired, securityNamespace)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("audit-exporter healthy (%d/%d master nodes), audit policy configured", ready, desired)
	}

	cc.AddResult(r)
}

// checkForwarderMetrics queries Prometheus for splunk forwarder health and throughput metrics
func checkForwarderMetrics(ctx context.Context, cc *checks.ClusterContext, hasCR bool) {
	cc.CurrentCheck = "sfo_forwarder_metrics"

	r := checks.Result{
		Check:    "sfo_forwarder_metrics",
		Severity: checks.SeverityWarning,
		Details:  map[string]any{},
	}

	if !hasCR {
		r.Status = checks.StatusSkip
		r.Message = "Skipped — no SplunkForwarder CR configured"
		cc.AddResult(r)
		return
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// --- Instant: component health ---
	query := thanos.EncodeQuery(`splunk_forwarder_component_unhealthy`)
	body, err := cc.Client.QueryThanos(ctx, query)
	cc.RecordError("Query splunk forwarder health", err)

	unhealthyCount := 0
	var unhealthyComponents []string

	if err == nil && thanos.HasResults(body) {
		resp, _ := thanos.Parse(body)
		r.Details["total_component_metrics"] = len(resp.Data.Result)
		for _, result := range resp.Data.Result {
			if len(result.Value) >= 2 && fmt.Sprintf("%v", result.Value[1]) == "1" {
				unhealthyCount++
				if c := result.Metric["component"]; c != "" {
					unhealthyComponents = append(unhealthyComponents, c)
				}
			}
		}
	}

	r.Details["unhealthy_count"] = unhealthyCount
	if len(unhealthyComponents) > 0 {
		r.Details["unhealthy_components"] = unhealthyComponents
	}

	// --- Timeseries: errors over 7 days (30min intervals, errors only) ---
	now := timeNow()
	start := now - 604800
	step := 1800 // 30 min intervals

	// Forwarder component unhealthy over time — only store error points (value > 0)
	// An empty timeseries means "healthy for the entire period"
	unhealthyTS := thanos.EncodeQuery(`max(splunk_forwarder_component_unhealthy) by (component)`)
	tsData, tsErr := cc.Client.QueryThanosRange(ctx, unhealthyTS, start, now, step)
	if tsErr == nil {
		points, _ := thanos.Timeseries(tsData)
		errorPoints := thanos.FilterNonZero(points)
		r.Details["component_unhealthy_timeseries"] = thanos.PointsToJSON(errorPoints)
		r.Details["component_unhealthy_error_count"] = len(errorPoints)
	}

	// Audit filter errors over time — only store non-zero error rates
	errRateQuery := thanos.EncodeQuery(`rate(splunkforwarder_audit_filter_errors_total[30m])`)
	errData, errErr := cc.Client.QueryThanosRange(ctx, errRateQuery, start, now, step)
	if errErr == nil {
		points, _ := thanos.Timeseries(errData)
		errorPoints := thanos.FilterNonZero(points)
		r.Details["audit_errors_timeseries"] = thanos.PointsToJSON(errorPoints)
		r.Details["audit_errors_error_count"] = len(errorPoints)
	}

	// Audit filter forwarded events rate (events/sec averaged over 1h intervals)
	fwdQuery := thanos.EncodeQuery(`sum(rate(splunkforwarder_audit_filter_events_processed_total{decision="forward"}[1h]))`)
	fwdData, fwdErr := cc.Client.QueryThanosRange(ctx, fwdQuery, start, now, 3600) // 1h intervals
	if fwdErr == nil {
		points, _ := thanos.Timeseries(fwdData)
		r.Details["audit_forward_rate_timeseries"] = thanos.PointsToJSON(points)
	}

	// Audit filter total event throughput (events/sec over 1h)
	totalQuery := thanos.EncodeQuery(`sum(rate(splunkforwarder_audit_filter_events_total[1h]))`)
	totalData, totalErr := cc.Client.QueryThanosRange(ctx, totalQuery, start, now, 3600)
	if totalErr == nil {
		points, _ := thanos.Timeseries(totalData)
		r.Details["audit_total_rate_timeseries"] = thanos.PointsToJSON(points)
	}

	// --- Instant: current forwarding rate ---
	fwdInstant := thanos.EncodeQuery(`sum(rate(splunkforwarder_audit_filter_events_processed_total{decision="forward"}[5m]))`)
	fwdNow, fwdNowErr := cc.Client.QueryThanos(ctx, fwdInstant)
	if fwdNowErr == nil {
		if val, _, ok := thanos.InstantValue(fwdNow); ok {
			r.Details["current_forward_rate"] = val + " events/sec"
		}
	}

	// --- Instant: current error rate ---
	errInstant := thanos.EncodeQuery(`sum(rate(splunkforwarder_audit_filter_errors_total[5m]))`)
	errNow, errNowErr := cc.Client.QueryThanos(ctx, errInstant)
	currentErrRate := 0.0
	if errNowErr == nil {
		if f, ok := thanos.InstantFloat(errNow); ok {
			currentErrRate = f
			r.Details["current_error_rate"] = fmt.Sprintf("%.4f errors/sec", f)
		}
	}

	// --- Verdict ---
	switch {
	case err != nil && checks.IsAccessError(err):
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	case unhealthyCount > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d unhealthy forwarder component(s): %s", unhealthyCount, strings.Join(unhealthyComponents, ", "))
	case currentErrRate > 0.01:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Audit filter errors detected (%.4f errors/sec)", currentErrRate)
	case err != nil:
		r.Status = checks.StatusSkip
		r.Message = "Could not query splunk forwarder metrics"
	default:
		r.Status = checks.StatusPass
		r.Message = "All forwarder components healthy, audit filter operating normally"
	}

	cc.AddResult(r)
}

func timeNow() int64 {
	return time.Now().Unix()
}

// checkServiceMonitor verifies the splunk forwarder ServiceMonitor exists
func checkServiceMonitor(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "sfo_servicemonitor"

	r := checks.Result{
		Check:    "sfo_servicemonitor",
		Severity: checks.SeverityInfo,
		Details:  map[string]any{"namespace": securityNamespace},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Check for splunk-forwarder ServiceMonitor
	_, smErr := cc.Client.GetResource(ctx, serviceMonitorGVR, securityNamespace, "splunk-forwarder", true)
	sfSM := smErr == nil

	// Check for audit-exporter ServiceMonitor
	_, aeErr := cc.Client.GetResource(ctx, serviceMonitorGVR, securityNamespace, "audit-exporter", true)
	aeSM := aeErr == nil

	r.Details["splunk_forwarder_sm"] = sfSM
	r.Details["audit_exporter_sm"] = aeSM

	if sfSM && aeSM {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Both ServiceMonitors present in %s (splunk-forwarder, audit-exporter)", securityNamespace)
	} else if sfSM || aeSM {
		r.Status = checks.StatusInfo
		present := "splunk-forwarder"
		if !sfSM {
			present = "audit-exporter"
		}
		r.Message = fmt.Sprintf("Partial: %s ServiceMonitor present, other missing in %s", present, securityNamespace)
	} else {
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("No ServiceMonitors found in %s — metrics may not be scraped", securityNamespace)
	}

	cc.AddResult(r)
}

// checkPrometheusRule verifies the SplunkForwarderComponentUnhealthy alert rule exists
func checkPrometheusRule(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "sfo_prometheusrule"

	r := checks.Result{
		Check:    "sfo_prometheusrule",
		Severity: checks.SeverityInfo,
		Details:  map[string]any{},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// The PrometheusRule is typically in openshift-security
	_, err := cc.Client.GetResource(ctx, prometheusRuleGVR, securityNamespace, "splunk-forwarder-component-unhealthy", true)
	if err == nil {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("PrometheusRule %s/splunk-forwarder-component-unhealthy exists — SplunkForwarderComponentUnhealthy alert configured", securityNamespace)
		r.Details["prometheusrule"] = fmt.Sprintf("%s/splunk-forwarder-component-unhealthy", securityNamespace)
	} else {
		// Try openshift-monitoring as fallback
		_, err2 := cc.Client.GetResource(ctx, prometheusRuleGVR, "openshift-monitoring", "splunk-forwarder-component-unhealthy", true)
		if err2 == nil {
			r.Status = checks.StatusPass
			r.Message = "PrometheusRule openshift-monitoring/splunk-forwarder-component-unhealthy exists"
			r.Details["prometheusrule"] = "openshift-monitoring/splunk-forwarder-component-unhealthy"
		} else {
			r.Status = checks.StatusInfo
			r.Message = "No SplunkForwarderComponentUnhealthy PrometheusRule found — alert not configured"
		}
	}

	cc.AddResult(r)
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}
