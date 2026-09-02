package dms

import (
	"context"
	"fmt"
	"strings"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/logging"
	"github.com/openshift/operator-health-report/pkg/thanos"
	"k8s.io/apimachinery/pkg/runtime/schema"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func init() { checks.Register(&DMSChecker{}) }

type DMSChecker struct{}

func (c *DMSChecker) Name() string { return "dms" }

var (
	dmsiGVR = schema.GroupVersionResource{
		Group: "deadmanssnitch.managed.openshift.io", Version: "v1alpha1", Resource: "deadmanssnitchintegrations",
	}
	clusterDeploymentGVR = schema.GroupVersionResource{
		Group: "hive.openshift.io", Version: "v1", Resource: "clusterdeployments",
	}
	clusterSyncGVR = schema.GroupVersionResource{
		Group: "hiveinternal.openshift.io", Version: "v1alpha1", Resource: "clustersyncs",
	}
)

func (c *DMSChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	checkControllerAvailability(ctx, cc)
	checkDMSIntegrations(ctx, cc)
	checkSnitchAPIHealth(ctx, cc)
	checkDMSCoverage(ctx, cc)
}

func checkControllerAvailability(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("dms_controller_availability")

	r := checks.Result{
		Check:    "dms_controller_availability",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Validates the deadmanssnitch-operator deployment is running and healthy on the hive cluster. If the operator is down, no new snitches will be created and existing snitches won't be reconciled for cluster lifecycle events (install, deprovision, limited support transitions).",
			"pass_criteria": "PASS: deployment has desired ready replicas. FAIL: zero ready replicas.",
		},
	}

	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	if err != nil {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Deployment %s/%s not found: %v", cc.Operator.Namespace, cc.Operator.Deployment, err)
		cc.AddResult(r)
		return
	}

	desired := int32(1)
	if deploy.Spec.Replicas != nil {
		desired = *deploy.Spec.Replicas
	}
	ready := deploy.Status.ReadyReplicas

	r.Details["ready_replicas"] = ready
	r.Details["desired_replicas"] = desired

	if ready == 0 {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("DMS operator has 0/%d ready replicas — snitch management stopped", desired)
	} else if ready < desired {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("DMS operator degraded — %d/%d ready", ready, desired)
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("DMS operator running — %d/%d ready", ready, desired)
	}
	cc.AddResult(r)
}

func checkDMSIntegrations(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("dms_integrations")

	r := checks.Result{
		Check:    "dms_integrations",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Lists DeadMansSnitchIntegration custom resources on the hive cluster. Each DMSI defines a DMS API key and snitch configuration template. At least one DMSI should exist for the operator to create snitches for ClusterDeployments.",
			"pass_criteria": "PASS: at least one DMSI present. WARN: no DMSIs found.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	list, err := cc.Client.ListResources(ctx, dmsiGVR, "", true)
	cc.RecordError("List DeadMansSnitchIntegrations", err)

	if err != nil {
		if checks.IsAccessError(err) {
			r.Status = checks.StatusAccessDenied
			r.Message = "Cannot list DeadMansSnitchIntegrations — insufficient permissions"
		} else {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("Cannot list DeadMansSnitchIntegrations: %v", err)
		}
		cc.AddResult(r)
		return
	}

	count := len(list.Items)
	r.Details["count"] = count

	var names []string
	for _, item := range list.Items {
		names = append(names, item.GetNamespace()+"/"+item.GetName())
	}
	r.Details["integrations"] = strings.Join(names, ", ")

	if count == 0 {
		r.Status = checks.StatusWarning
		r.Message = "No DeadMansSnitchIntegrations found — DMS snitches will not be created"
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d DeadMansSnitchIntegration(s) configured", count)
	}
	cc.AddResult(r)
}

func checkSnitchAPIHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("dms_snitch_api_health")
	log := logging.WithCheck("dms_snitch_api_health")

	r := checks.Result{
		Check:    "dms_snitch_api_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Queries DMS operator metrics for snitch API call errors and latency. The operator calls the Dead Man's Snitch API to create/delete/check-in snitches. API errors prevent snitch lifecycle management — clusters may not get DMS coverage or stale snitches won't be cleaned up.",
			"pass_criteria": "PASS: zero API errors. WARN: API errors detected. INFO: metrics not available.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		r.Status = checks.StatusSkip
		r.Message = "Metrics unavailable"
		cc.AddResult(r)
		return
	}

	// First check if DMS metrics are being scraped by querying the reconcile histogram
	// (always increments, unlike error counters which may be zero)
	reconcileQuery := fmt.Sprintf(`dms_operator_reconcile_duration_seconds_count{namespace="%s"}`, cc.Operator.Namespace)
	reconcileBody, reconcileErr := cc.Client.QueryMetrics(ctx, reconcileQuery)

	if reconcileErr != nil || !thanos.HasResults(reconcileBody) {
		r.Status = checks.StatusInfo
		r.Message = "DMS operator metrics not found in Prometheus — operator may lack a ServiceMonitor or metrics haven't been scraped yet"
		cc.AddResult(r)
		return
	}

	reconcileCount := 0.0
	if v, ok := thanos.InstantFloat(reconcileBody); ok {
		reconcileCount = v
	}
	r.Details["reconcile_count"] = int(reconcileCount)

	// Check reconcile rate (are reconciliations happening?)
	reconcileRateQuery := fmt.Sprintf(`rate(dms_operator_reconcile_duration_seconds_count{namespace="%s"}[1h])`, cc.Operator.Namespace)
	if rateBody, rateErr := cc.Client.QueryMetrics(ctx, reconcileRateQuery); rateErr == nil {
		if v, ok := thanos.InstantFloat(rateBody); ok {
			r.Details["reconcile_rate_per_sec"] = thanos.Round(v, 4)
		}
	}

	// Check snitch API errors (counter, may be zero/absent if no errors)
	errorCount := 0.0
	errorQuery := fmt.Sprintf(`dms_operator_snitch_api_call_error{namespace="%s"}`, cc.Operator.Namespace)
	if errorBody, err := cc.Client.QueryMetrics(ctx, errorQuery); err == nil && thanos.HasResults(errorBody) {
		if v, ok := thanos.InstantFloat(errorBody); ok {
			errorCount = v
		}
	}
	r.Details["snitch_api_errors"] = int(errorCount)

	// Check error rate
	errorRate := 0.0
	errorRateQuery := fmt.Sprintf(`rate(dms_operator_snitch_api_call_error{namespace="%s"}[1h])`, cc.Operator.Namespace)
	if rateBody, rateErr := cc.Client.QueryMetrics(ctx, errorRateQuery); rateErr == nil {
		if v, ok := thanos.InstantFloat(rateBody); ok {
			errorRate = v
			r.Details["error_rate_per_sec"] = thanos.Round(v, 4)
		}
	}

	// Check API call duration
	durationQuery := fmt.Sprintf(`histogram_quantile(0.99, rate(dms_operator_snitch_api_call_duration_seconds_bucket{namespace="%s"}[1h]))`, cc.Operator.Namespace)
	if durBody, durErr := cc.Client.QueryMetrics(ctx, durationQuery); durErr == nil {
		if v, ok := thanos.InstantFloat(durBody); ok {
			r.Details["p99_duration_seconds"] = thanos.Round(v, 3)
			log.WithField("p99", v).Debug("Snitch API p99 latency")
		}
	}

	switch {
	case errorRate > 0.01:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("DMS snitch API errors active — %.0f total, rate %.4f/s (%d reconciliations)", errorCount, errorRate, int(reconcileCount))
	case reconcileCount == 0:
		r.Status = checks.StatusWarning
		r.Message = "DMS operator has zero reconciliations — may not be processing ClusterDeployments"
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("DMS operator healthy — %d reconciliations, %d API errors", int(reconcileCount), int(errorCount))
	}
	cc.AddResult(r)
}

func checkDMSCoverage(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("dms_coverage")

	r := checks.Result{
		Check:    "dms_coverage",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Compares installed managed ClusterDeployments against ClusterSync data for DMS SyncSet apply status. Each managed cluster should have a DMS SyncSet that pushes dms-secret to the cluster. Uses ClusterSync (hiveinternal API) which shows per-SyncSet apply results without needing direct SyncSet list access.",
			"pass_criteria": "PASS: DMS SyncSets applied successfully to all eligible clusters. WARN: missing or failing DMS SyncSets. SKIP: ClusterSync data unavailable.",
		},
	}

	// Count installed managed ClusterDeployments and build namespace set
	cdList, err := cc.Client.ListResources(ctx, clusterDeploymentGVR, "", false)
	cc.RecordError("List ClusterDeployments", err)

	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot list ClusterDeployments: %v", err)
		cc.AddResult(r)
		return
	}

	eligible := 0
	eligibleNS := map[string]string{} // namespace → cluster name
	for _, item := range cdList.Items {
		spec, _ := item.Object["spec"].(map[string]any)
		if spec == nil {
			continue
		}
		installed, _ := spec["installed"].(bool)
		if !installed {
			continue
		}
		labels := item.GetLabels()
		if labels["api.openshift.com/managed"] != "true" {
			continue
		}
		eligible++
		name := labels["api.openshift.com/name"]
		if name == "" {
			name = item.GetName()
		}
		eligibleNS[item.GetNamespace()] = name
	}

	r.Details["eligible_clusters"] = eligible

	// Check ClusterSync per eligible namespace for DMS SyncSet apply status.
	// Requires elevation — hiveinternal.openshift.io resources are restricted.
	elevated := cc.Client.CanElevate()
	hasDMS := 0
	dmsSuccess := 0
	dmsFailing := 0
	csChecked := 0
	var failingClusters []string

	for ns, clusterName := range eligibleNS {
		csList, csErr := cc.Client.ListResources(ctx, clusterSyncGVR, ns, elevated)
		if csErr != nil {
			continue
		}
		csChecked++

		for _, item := range csList.Items {
			status, _ := item.Object["status"].(map[string]any)
			if status == nil {
				continue
			}

			// Check syncSets for DMS — DMSO creates per-cluster SyncSets
			syncSets, _ := status["syncSets"].([]any)
			for _, ss := range syncSets {
				ssMap, _ := ss.(map[string]any)
				if ssMap == nil {
					continue
				}
				ssName, _ := ssMap["name"].(string)
				if !strings.Contains(ssName, "dms") && !strings.Contains(ssName, "deadmanssnitch") {
					continue
				}
				hasDMS++
				result, _ := ssMap["result"].(string)
				if result == "Success" {
					dmsSuccess++
				} else {
					dmsFailing++
					failMsg, _ := ssMap["failureMessage"].(string)
					entry := clusterName
					if failMsg != "" {
						entry += ": " + truncate(failMsg, 80)
					}
					failingClusters = append(failingClusters, entry)
				}
			}
		}
	}

	if csChecked == 0 {
		if !elevated {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusSkip
			r.Message = "Could not read ClusterSync for any eligible cluster"
			cc.AddResult(r)
		}
		return
	}

	r.Details["clusters_with_dms_syncset"] = hasDMS
	r.Details["dms_syncset_success"] = dmsSuccess
	r.Details["dms_syncset_failing"] = dmsFailing
	if len(failingClusters) > 0 {
		r.Details["failing_clusters"] = strings.Join(failingClusters, "; ")
	}

	switch {
	case hasDMS == 0 && eligible > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("No DMS SyncSets found in ClusterSync for %d eligible clusters", eligible)
	case dmsFailing > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("DMS SyncSet failures on %d cluster(s) — %d/%d successful", dmsFailing, dmsSuccess, hasDMS)
	case hasDMS < eligible:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("DMS coverage gap — %d SyncSets for %d eligible clusters", hasDMS, eligible)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("DMS coverage healthy — %d/%d clusters with successful DMS SyncSet", dmsSuccess, eligible)
	}
	cc.AddResult(r)
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}
