package muo

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/logging"
	"github.com/openshift/operator-health-report/pkg/thanos"

	"gopkg.in/yaml.v3"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func init() {
	checks.Register(&MUOChecker{})
}

type MUOChecker struct{}

func (c *MUOChecker) Name() string { return "muo" }

func (c *MUOChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	checkControllerAvailability(ctx, cc)
	checkConfigMapHealth(ctx, cc)
	checkServiceMonitor(ctx, cc)
	checkUpgradeConfigStatus(ctx, cc)
	checkUpgradeConfigSync(ctx, cc)
	checkValidationStatus(ctx, cc)
	checkControlPlaneTimeout(ctx, cc)
	checkWorkerTimeout(ctx, cc)
	checkNodeDrainFailures(ctx, cc)
	checkScalingStatus(ctx, cc)
	checkWindowBreach(ctx, cc)
	checkNotificationHealth(ctx, cc)
	checkHealthCheckStatus(ctx, cc)
	checkUpgradeHistory(ctx, cc)
	checkUpgradeResult(ctx, cc)
	checkFeatureGates(ctx, cc)
}

var (
	upgradeConfigGVR = schema.GroupVersionResource{
		Group: "upgrade.managed.openshift.io", Version: "v1alpha1", Resource: "upgradeconfigs",
	}
	clusterVersionGVR = schema.GroupVersionResource{
		Group: "config.openshift.io", Version: "v1", Resource: "clusterversions",
	}
	serviceMonitorGVR = schema.GroupVersionResource{
		Group: "monitoring.coreos.com", Version: "v1", Resource: "servicemonitors",
	}
)

const muoNamespace = "openshift-managed-upgrade-operator"

func checkControllerAvailability(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_controller_availability")

	r := checks.Result{
		Check:    "muo_controller_availability",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks whether the MUO deployment has an Available=True condition. MUO is the controller that manages cluster upgrades by syncing UpgradeConfig from OCM and orchestrating the upgrade lifecycle.",
			"pass_criteria": "PASS: deployment Available=True. FAIL: deployment not available or not found.",
		},
	}

	deploy, err := cc.Client.Clientset().AppsV1().Deployments(muoNamespace).Get(ctx, "managed-upgrade-operator", metav1.GetOptions{})
	cc.RecordError("Get MUO deployment", err)
	if err != nil {
		if checks.IsAccessError(err) {
			r.Status = checks.StatusAccessDenied
			r.Message = "Cannot access MUO deployment — insufficient permissions"
		} else {
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("MUO deployment not found: %v", err)
		}
		cc.AddResult(r)
		return
	}

	available := false
	for _, c := range deploy.Status.Conditions {
		if c.Type == "Available" {
			available = c.Status == "True"
			r.Details["available"] = string(c.Status)
			r.Details["available_message"] = c.Message
			break
		}
	}

	r.Details["ready_replicas"] = deploy.Status.ReadyReplicas
	r.Details["desired_replicas"] = *deploy.Spec.Replicas

	if available {
		r.Status = checks.StatusPass
		r.Message = "Controller is available"
	} else {
		r.Status = checks.StatusFail
		r.Message = "Controller not available"
	}

	cc.AddResult(r)
}

func checkConfigMapHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_configmap_health")

	r := checks.Result{
		Check:    "muo_configmap_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates the managed-upgrade-operator-config ConfigMap exists and contains valid configuration. Checks for critical config fields: upgradeType, configManager source, OCM base URL, node drain timeouts, and health check settings.",
			"pass_criteria": "PASS: ConfigMap exists with valid config.yaml containing required fields. WARN: ConfigMap exists but missing key fields. FAIL: ConfigMap not found.",
		},
	}

	cm, err := cc.Client.Clientset().CoreV1().ConfigMaps(muoNamespace).Get(ctx, "managed-upgrade-operator-config", metav1.GetOptions{})
	cc.RecordError("Get MUO ConfigMap", err)
	if err != nil {
		if checks.IsAccessError(err) {
			r.Status = checks.StatusAccessDenied
			r.Message = "Cannot access MUO ConfigMap — insufficient permissions"
		} else {
			r.Status = checks.StatusFail
			r.Message = "managed-upgrade-operator-config ConfigMap not found"
		}
		cc.AddResult(r)
		return
	}

	configYAML, ok := cm.Data["config.yaml"]
	if !ok || configYAML == "" {
		r.Status = checks.StatusFail
		r.Message = "ConfigMap exists but config.yaml key is empty or missing"
		cc.AddResult(r)
		return
	}

	r.Details["config_size_bytes"] = len(configYAML)

	var config map[string]any
	if jsonErr := parseYAMLConfig(configYAML, &config); jsonErr != nil {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("ConfigMap config.yaml is not valid YAML: %v", jsonErr)
		cc.AddResult(r)
		return
	}

	issues := []string{}

	upgradeType, _ := config["upgradeType"].(string)
	r.Details["upgrade_type"] = upgradeType
	if upgradeType == "" {
		issues = append(issues, "missing upgradeType")
	}

	if cm, ok := config["configManager"].(map[string]any); ok {
		source, _ := cm["source"].(string)
		r.Details["config_source"] = source
		if source == "" {
			issues = append(issues, "missing configManager.source")
		}
		ocmURL, _ := cm["ocmBaseUrl"].(string)
		r.Details["ocm_base_url"] = ocmURL
	} else {
		issues = append(issues, "missing configManager section")
	}

	if nd, ok := config["nodeDrain"].(map[string]any); ok {
		if timeout, ok := nd["timeOut"]; ok {
			r.Details["node_drain_timeout_min"] = timeout
		}
	}

	if hc, ok := config["healthCheck"].(map[string]any); ok {
		if ic, ok := hc["ignoredCriticals"].([]any); ok {
			r.Details["ignored_criticals_count"] = len(ic)
		}
	}

	if fg, ok := config["featureGate"].(map[string]any); ok {
		if enabled, ok := fg["enabled"].([]any); ok {
			gates := make([]string, 0, len(enabled))
			for _, g := range enabled {
				if s, ok := g.(string); ok {
					gates = append(gates, s)
				}
			}
			r.Details["feature_gates"] = gates
		}
	}

	if len(issues) > 0 {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("ConfigMap present but %s", strings.Join(issues, ", "))
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("ConfigMap valid (type=%s, source=%s)", upgradeType, r.Details["config_source"])
	}

	cc.AddResult(r)
}

func checkServiceMonitor(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_servicemonitor")

	r := checks.Result{
		Check:    "muo_servicemonitor",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates that a ServiceMonitor exists for MUO in the openshift-managed-upgrade-operator namespace. Without it, Prometheus cannot scrape MUO's upgrade metrics (sync timestamp, timeouts, failures) and SRE alerts will not fire.",
			"pass_criteria": "PASS: ServiceMonitor exists. FAIL: ServiceMonitor not found.",
		},
	}

	list, err := cc.Client.ListResources(ctx, serviceMonitorGVR, muoNamespace, false)
	cc.RecordError("List MUO ServiceMonitors", err)
	if err != nil {
		if checks.IsAccessError(err) {
			r.Status = checks.StatusAccessDenied
			r.Message = "Cannot access ServiceMonitors — insufficient permissions"
		} else {
			r.Status = checks.StatusSkip
			r.Message = fmt.Sprintf("Cannot list ServiceMonitors: %v", err)
		}
		cc.AddResult(r)
		return
	}

	if len(list.Items) == 0 {
		r.Status = checks.StatusFail
		r.Message = "No ServiceMonitor found — MUO metrics are not being scraped by Prometheus"
		cc.AddResult(r)
		return
	}

	names := make([]string, 0, len(list.Items))
	for _, item := range list.Items {
		names = append(names, item.GetName())
	}

	r.Details["servicemonitor_names"] = names
	r.Details["count"] = len(names)
	r.Status = checks.StatusPass
	r.Message = fmt.Sprintf("ServiceMonitor present: %s", strings.Join(names, ", "))

	cc.AddResult(r)
}

func checkUpgradeConfigStatus(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_upgradeconfig_status")

	r := checks.Result{
		Check:    "muo_upgradeconfig_status",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the UpgradeConfig custom resource in the MUO namespace. Reports upgrade phase, target version, conditions, and timing. An active UpgradeConfig means an upgrade is scheduled or in progress.",
			"pass_criteria": "PASS: no UpgradeConfig (no upgrade scheduled) or upgrade in Upgraded/Pending phase. WARN: upgrade in progress (Upgrading/New). FAIL: upgrade in Failed phase.",
		},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	list, err := cc.Client.ListResources(ctx, upgradeConfigGVR, muoNamespace, true)
	cc.RecordError("List UpgradeConfigs", err)
	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
			return
		}
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot list UpgradeConfigs: %v", err)
		cc.AddResult(r)
		return
	}

	if len(list.Items) == 0 {
		r.Status = checks.StatusPass
		r.Message = "No UpgradeConfig present — no upgrade scheduled"
		r.Details["upgrade_configs"] = 0
		cc.AddResult(r)
		return
	}

	r.Details["upgrade_configs"] = len(list.Items)

	for _, item := range list.Items {
		name := item.GetName()
		spec, _, _ := unstructured.NestedMap(item.Object, "spec")
		status, _, _ := unstructured.NestedMap(item.Object, "status")

		targetVersion := ""
		if desired, ok := spec["desired"].(map[string]any); ok {
			targetVersion, _ = desired["version"].(string)
		}
		upgradeAt, _, _ := unstructured.NestedString(item.Object, "spec", "upgradeAt")
		pdbTimeout, _, _ := unstructured.NestedInt64(item.Object, "spec", "PDBForceDrainTimeout")

		r.Details["name"] = name
		r.Details["target_version"] = targetVersion
		r.Details["upgrade_at"] = upgradeAt
		r.Details["pdb_force_drain_timeout"] = pdbTimeout

		histories, _, _ := unstructured.NestedSlice(status, "history")
		if len(histories) > 0 {
			latest, _ := histories[len(histories)-1].(map[string]any)
			phase, _ := latest["phase"].(string)
			version, _ := latest["version"].(string)
			startTime, _ := latest["startTime"].(string)
			completeTime, _ := latest["completeTime"].(string)

			r.Details["phase"] = phase
			r.Details["history_version"] = version
			r.Details["start_time"] = startTime
			r.Details["complete_time"] = completeTime

			conditions, _ := latest["conditions"].([]any)
			if len(conditions) > 0 {
				condSummary := make([]map[string]any, 0, len(conditions))
				for _, c := range conditions {
					cond, _ := c.(map[string]any)
					condSummary = append(condSummary, map[string]any{
						"type":    cond["type"],
						"status":  cond["status"],
						"message": cond["message"],
					})
				}
				r.Details["conditions"] = condSummary
			}

			switch phase {
			case "Failed":
				r.Status = checks.StatusFail
				r.Severity = checks.SeverityCritical
				r.Message = fmt.Sprintf("Upgrade to %s FAILED", version)
			case "Upgrading":
				r.Status = checks.StatusWarning
				r.Message = fmt.Sprintf("Upgrade to %s in progress (started: %s)", version, startTime)
			case "Upgraded":
				r.Status = checks.StatusPass
				r.Message = fmt.Sprintf("Upgrade to %s completed (finished: %s)", version, completeTime)
			case "Pending", "New":
				r.Status = checks.StatusInfo
				r.Message = fmt.Sprintf("Upgrade to %s scheduled at %s (phase: %s)", targetVersion, upgradeAt, phase)
			default:
				r.Status = checks.StatusInfo
				r.Message = fmt.Sprintf("UpgradeConfig present — phase: %s, target: %s", phase, targetVersion)
			}
		} else {
			r.Status = checks.StatusInfo
			r.Message = fmt.Sprintf("UpgradeConfig present for %s at %s — no history yet", targetVersion, upgradeAt)
		}
	}

	cc.AddResult(r)
}

func checkUpgradeConfigSync(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_upgradeconfig_sync")
	log := logging.WithCheck("muo_upgradeconfig_sync")

	r := checks.Result{
		Check:    "muo_upgradeconfig_sync",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the upgradeoperator_upgradeconfig_sync_timestamp metric to verify MUO is successfully syncing UpgradeConfig with OCM. A stale sync timestamp (>4h) means the cluster may miss scheduled upgrades or have an outdated upgrade policy. This is the pre-alert version of UpgradeConfigSyncFailureOver4HrSRE.",
			"pass_criteria": "PASS: sync within last 1h. WARN: sync between 1-4h ago. FAIL: sync >4h ago or metric absent (matches alert threshold).",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx, `upgradeoperator_upgradeconfig_sync_timestamp`)
	cc.RecordError("Query sync timestamp", err)

	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot query sync metric: %v", err)
		cc.AddResult(r)
		return
	}

	if body == "" || !thanos.HasResults(body) {
		controllerDown := false
		for _, prev := range cc.Results {
			if prev.Check == "muo_controller_availability" && prev.Status == checks.StatusFail {
				controllerDown = true
				break
			}
			if prev.Check == "pod_status_and_restarts" && prev.Status == checks.StatusFail {
				controllerDown = true
				break
			}
		}
		if controllerDown {
			r.Status = checks.StatusInfo
			r.Message = "Sync metric absent — MUO controller is down (see controller_availability)"
		} else {
			r.Status = checks.StatusWarning
			r.Message = "Sync timestamp metric absent — MUO may not have synced yet or metrics not being scraped"
		}
		cc.AddResult(r)
		return
	}

	val, _, ok := thanos.InstantValue(body)
	if !ok {
		r.Status = checks.StatusSkip
		r.Message = "Could not parse sync timestamp value"
		cc.AddResult(r)
		return
	}

	ts, parseErr := strconv.ParseFloat(val, 64)
	if parseErr != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Invalid sync timestamp: %s", val)
		cc.AddResult(r)
		return
	}

	syncTime := time.Unix(int64(ts), 0).UTC()
	age := time.Since(syncTime)
	ageHours := age.Hours()

	r.Details["sync_timestamp"] = ts
	r.Details["sync_time"] = syncTime.Format(time.RFC3339)
	r.Details["sync_age_hours"] = math.Round(ageHours*10) / 10

	log.WithField("sync_age_hours", ageHours).Debug("MUO sync age")

	switch {
	case ageHours > 4:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("Sync stale — last sync %.1fh ago (alert threshold: 4h)", ageHours)
	case ageHours > 1:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Sync aging — last sync %.1fh ago", ageHours)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Sync healthy — last sync %.0fm ago", age.Minutes())
	}

	cc.AddResult(r)
}

func checkGaugeMetric(ctx context.Context, cc *checks.ClusterContext, checkName, query, description, passCriteria, metricLabel, failMsg, passMsg string) {
	cc.SetCheck(checkName)

	r := checks.Result{
		Check:    checkName,
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   description,
			"pass_criteria": passCriteria,
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx, query)
	cc.RecordError("Query "+metricLabel, err)

	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot query %s: %v", metricLabel, err)
		cc.AddResult(r)
		return
	}

	if body == "" || !thanos.HasResults(body) {
		r.Status = checks.StatusPass
		r.Message = passMsg
		r.Details["metric_present"] = false
		cc.AddResult(r)
		return
	}

	val, labels, _ := thanos.InstantValue(body)
	r.Details["value"] = val
	r.Details["metric_present"] = true

	for k, v := range labels {
		if k != "__name__" && k != "job" && k != "instance" && k != "name" {
			r.Details[k] = v
		}
	}

	if val == "1" {
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical

		labelParts := []string{}
		for k, v := range labels {
			if k == "version" || k == "node_name" || k == "upgradeconfig_name" || k == "state" || k == "reason" || k == "event" {
				labelParts = append(labelParts, fmt.Sprintf("%s=%s", k, v))
			}
		}
		if len(labelParts) > 0 {
			r.Message = fmt.Sprintf("%s (%s)", failMsg, strings.Join(labelParts, ", "))
		} else {
			r.Message = failMsg
		}
	} else {
		r.Status = checks.StatusPass
		r.Message = passMsg
	}

	cc.AddResult(r)
}

func checkValidationStatus(ctx context.Context, cc *checks.ClusterContext) {
	checkGaugeMetric(ctx, cc,
		"muo_validation_status",
		`upgradeoperator_upgradeconfig_validation_failed`,
		"Checks the upgradeoperator_upgradeconfig_validation_failed metric. When set to 1, the UpgradeConfig has failed validation — the upgrade cannot proceed until the config is corrected. This is the pre-alert version of UpgradeConfigValidationFailedSRE.",
		"PASS: metric absent or 0 (validation passing). FAIL: metric=1 (validation failed).",
		"validation_failed",
		"UpgradeConfig validation FAILED — upgrade cannot proceed",
		"UpgradeConfig validation passing",
	)
}

func checkControlPlaneTimeout(ctx context.Context, cc *checks.ClusterContext) {
	checkGaugeMetric(ctx, cc,
		"muo_controlplane_timeout",
		`upgradeoperator_controlplane_timeout`,
		"Checks the upgradeoperator_controlplane_timeout metric. When set to 1, the control plane upgrade has exceeded its timeout window. This is the pre-alert version of UpgradeControlPlaneUpgradeTimeoutSRE.",
		"PASS: metric absent or 0 (no timeout). FAIL: metric=1 (control plane upgrade timed out).",
		"controlplane_timeout",
		"Control plane upgrade TIMED OUT",
		"No control plane timeout",
	)
}

func checkWorkerTimeout(ctx context.Context, cc *checks.ClusterContext) {
	checkGaugeMetric(ctx, cc,
		"muo_worker_timeout",
		`upgradeoperator_worker_timeout`,
		"Checks the upgradeoperator_worker_timeout metric. When set to 1, worker node upgrades have exceeded their timeout window. This is the pre-alert version of UpgradeNodeUpgradeTimeoutSRE.",
		"PASS: metric absent or 0 (no timeout). FAIL: metric=1 (worker upgrade timed out).",
		"worker_timeout",
		"Worker node upgrade TIMED OUT",
		"No worker node timeout",
	)
}

func checkNodeDrainFailures(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_node_drain_failures")

	r := checks.Result{
		Check:    "muo_node_drain_failures",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the upgradeoperator_node_drain_timeout metric. When set to 1, a node could not be drained in time during upgrade (not caused by PDB). May indicate workloads with long shutdown times or stuck finalizers. This is the pre-alert version of UpgradeNodeDrainFailedSRE.",
			"pass_criteria": "PASS: metric absent or 0 (no drain failures). FAIL: metric=1 with affected node name.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx, `upgradeoperator_node_drain_timeout`)
	cc.RecordError("Query node drain timeout", err)

	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot query node drain metric: %v", err)
		cc.AddResult(r)
		return
	}

	if body == "" || !thanos.HasResults(body) {
		r.Status = checks.StatusPass
		r.Message = "No node drain failures"
		r.Details["metric_present"] = false
		cc.AddResult(r)
		return
	}

	resp, parseErr := thanos.Parse(body)
	if parseErr != nil {
		r.Status = checks.StatusSkip
		r.Message = "Could not parse node drain metric"
		cc.AddResult(r)
		return
	}

	failedNodes := []string{}
	for _, res := range resp.Data.Result {
		if len(res.Value) >= 2 {
			if v, ok := res.Value[1].(string); ok && v == "1" {
				nodeName := res.Metric["node_name"]
				if nodeName != "" {
					failedNodes = append(failedNodes, nodeName)
				}
			}
		}
	}

	r.Details["metric_present"] = true
	r.Details["failed_nodes"] = failedNodes

	if len(failedNodes) > 0 {
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("Node drain FAILED on %d node(s): %s", len(failedNodes), strings.Join(failedNodes, ", "))
	} else {
		r.Status = checks.StatusPass
		r.Message = "No node drain failures (metric present but value=0)"
	}

	cc.AddResult(r)
}

func checkScalingStatus(ctx context.Context, cc *checks.ClusterContext) {
	checkGaugeMetric(ctx, cc,
		"muo_scaling_status",
		`upgradeoperator_scaling_failed`,
		"Checks the upgradeoperator_scaling_failed metric. When set to 1, MUO failed to scale up extra worker nodes before starting the upgrade. Capacity reservation ensures upgrade safety by providing spare capacity for workload rescheduling.",
		"PASS: metric absent or 0 (scaling succeeded or not required). FAIL: metric=1 (worker scaling failed).",
		"scaling_failed",
		"Worker node scaling FAILED — upgrade may lack capacity headroom",
		"No scaling failures",
	)
}

func checkWindowBreach(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_window_breach")

	r := checks.Result{
		Check:    "muo_window_breach",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the upgradeoperator_upgrade_window_breached metric. When set to 1, the upgrade could not start within its scheduled maintenance window. The cluster will attempt the upgrade in the next window.",
			"pass_criteria": "PASS: metric absent or 0 (upgrade started within window). WARN: metric=1 (window breached).",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx, `upgradeoperator_upgrade_window_breached`)
	cc.RecordError("Query window breached", err)

	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot query window breach metric: %v", err)
		cc.AddResult(r)
		return
	}

	if body == "" || !thanos.HasResults(body) {
		r.Status = checks.StatusPass
		r.Message = "No upgrade window breaches"
		cc.AddResult(r)
		return
	}

	val, _, _ := thanos.InstantValue(body)
	r.Details["value"] = val
	r.Details["metric_present"] = true

	if val == "1" {
		r.Status = checks.StatusWarning
		r.Message = "Upgrade window BREACHED — upgrade did not start in scheduled window"
	} else {
		r.Status = checks.StatusPass
		r.Message = "No upgrade window breaches"
	}

	cc.AddResult(r)
}

func checkNotificationHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_notification_health")

	r := checks.Result{
		Check:    "muo_notification_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the upgrade_notification_failed metric. When set to 1, MUO failed to send an upgrade state notification (e.g., UpgradeStarted, UpgradeCompleted) to OCM. This is the pre-alert version of UpgradeStateNotificationFailureSRE.",
			"pass_criteria": "PASS: metric absent or 0 (notifications working). FAIL: metric=1 with failed event type.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx, `upgrade_notification_failed`)
	cc.RecordError("Query notification failed", err)

	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot query notification metric: %v", err)
		cc.AddResult(r)
		return
	}

	if body == "" || !thanos.HasResults(body) {
		r.Status = checks.StatusPass
		r.Message = "No notification failures"
		r.Details["metric_present"] = false
		cc.AddResult(r)
		return
	}

	resp, parseErr := thanos.Parse(body)
	if parseErr != nil {
		r.Status = checks.StatusSkip
		r.Message = "Could not parse notification metric"
		cc.AddResult(r)
		return
	}

	failedEvents := []string{}
	for _, res := range resp.Data.Result {
		if len(res.Value) >= 2 {
			if v, ok := res.Value[1].(string); ok && v == "1" {
				event := res.Metric["event"]
				if event != "" {
					failedEvents = append(failedEvents, event)
				}
			}
		}
	}

	r.Details["metric_present"] = true
	r.Details["failed_events"] = failedEvents

	if len(failedEvents) > 0 {
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("Notification FAILED for event(s): %s", strings.Join(failedEvents, ", "))
	} else {
		r.Status = checks.StatusPass
		r.Message = "Notifications healthy (metric present but value=0)"
	}

	cc.AddResult(r)
}

func checkHealthCheckStatus(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_health_check_status")

	r := checks.Result{
		Check:    "muo_health_check_status",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the upgradeoperator_healthcheck_failed metric. When set to 1, MUO's pre-upgrade or post-upgrade health check has failed — the upgrade is blocked until the cluster health issue is resolved. Reports the failure reason (CriticalAlertsFiring, ClusterOperatorsDegraded, etc.).",
			"pass_criteria": "PASS: metric absent or 0 (health checks passing). FAIL: metric=1 with state and reason.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx, `upgradeoperator_healthcheck_failed`)
	cc.RecordError("Query health check failed", err)

	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot query health check metric: %v", err)
		cc.AddResult(r)
		return
	}

	if body == "" || !thanos.HasResults(body) {
		r.Status = checks.StatusPass
		r.Message = "No health check failures"
		r.Details["metric_present"] = false
		cc.AddResult(r)
		return
	}

	resp, parseErr := thanos.Parse(body)
	if parseErr != nil {
		r.Status = checks.StatusSkip
		r.Message = "Could not parse health check metric"
		cc.AddResult(r)
		return
	}

	failures := []map[string]string{}
	for _, res := range resp.Data.Result {
		if len(res.Value) >= 2 {
			if v, ok := res.Value[1].(string); ok && v == "1" {
				entry := map[string]string{}
				for _, key := range []string{"state", "reason", "version"} {
					if val, ok := res.Metric[key]; ok {
						entry[key] = val
					}
				}
				failures = append(failures, entry)
			}
		}
	}

	r.Details["metric_present"] = true

	if len(failures) > 0 {
		r.Details["failures"] = failures
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical

		parts := make([]string, 0, len(failures))
		for _, f := range failures {
			part := fmt.Sprintf("%s/%s", f["state"], f["reason"])
			if v, ok := f["version"]; ok && v != "" {
				part += " (v" + v + ")"
			}
			parts = append(parts, part)
		}
		r.Message = fmt.Sprintf("Health check FAILED: %s", strings.Join(parts, "; "))
	} else {
		r.Status = checks.StatusPass
		r.Message = "Health checks passing (metric present but value=0)"
	}

	cc.AddResult(r)
}

func checkUpgradeHistory(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_upgrade_history")

	r := checks.Result{
		Check:    "muo_upgrade_history",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Reads the ClusterVersion resource to report recent upgrade history. Shows completed and in-progress upgrades from the cluster's perspective (independent of MUO's UpgradeConfig). Useful for correlating MUO state with actual cluster version transitions.",
			"pass_criteria": "INFO: always informational. Reports current version, channel, and recent update history from ClusterVersion conditions.",
		},
	}

	cvObj, err := cc.Client.GetResource(ctx, clusterVersionGVR, "", "version", false)
	cc.RecordError("Get ClusterVersion", err)
	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot read ClusterVersion: %v", err)
		cc.AddResult(r)
		return
	}

	desiredVersion, _, _ := unstructured.NestedString(cvObj.Object, "status", "desired", "version")
	channel, _, _ := unstructured.NestedString(cvObj.Object, "spec", "channel")

	r.Details["current_version"] = desiredVersion
	r.Details["channel"] = channel

	conditions, _, _ := unstructured.NestedSlice(cvObj.Object, "status", "conditions")
	progressing := "Unknown"
	available := "Unknown"
	for _, c := range conditions {
		cond, _ := c.(map[string]any)
		switch cond["type"] {
		case "Progressing":
			progressing, _ = cond["status"].(string)
			r.Details["progressing"] = progressing
			if msg, ok := cond["message"].(string); ok {
				r.Details["progressing_message"] = msg
			}
		case "Available":
			available, _ = cond["status"].(string)
			r.Details["available"] = available
		case "Failing":
			failing, _ := cond["status"].(string)
			r.Details["failing"] = failing
			if failing == "True" {
				if msg, ok := cond["message"].(string); ok {
					r.Details["failing_message"] = msg
				}
			}
		}
	}

	histories, _, _ := unstructured.NestedSlice(cvObj.Object, "status", "history")
	if len(histories) > 0 {
		recentHistory := []map[string]any{}
		limit := 5
		if len(histories) < limit {
			limit = len(histories)
		}
		for i := 0; i < limit; i++ {
			h, _ := histories[i].(map[string]any)
			entry := map[string]any{
				"version":    h["version"],
				"state":      h["state"],
				"start_time": h["startedTime"],
			}
			if ct, ok := h["completionTime"]; ok {
				entry["completion_time"] = ct
			}
			recentHistory = append(recentHistory, entry)
		}
		r.Details["recent_history"] = recentHistory
	}

	switch {
	case progressing == "True":
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("Cluster upgrading to %s (channel: %s)", desiredVersion, channel)
	default:
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("Cluster on %s (channel: %s)", desiredVersion, channel)
	}

	cc.AddResult(r)
}

func checkUpgradeResult(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_upgrade_result")

	r := checks.Result{
		Check:    "muo_upgrade_result",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Checks the upgradeoperator_upgrade_result metric which records alerts that fired during the most recent upgrade. Reports preceding version, target version, stream, and which alerts were active. Useful for post-upgrade analysis and identifying recurring upgrade-time issues.",
			"pass_criteria": "INFO: always informational. Reports upgrade result data when available. WARN: alerts fired during upgrade.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx, `upgradeoperator_upgrade_result`)
	cc.RecordError("Query upgrade result", err)

	if err != nil || body == "" || !thanos.HasResults(body) {
		r.Status = checks.StatusPass
		r.Message = "No upgrade result data (no recent upgrade)"
		cc.AddResult(r)
		return
	}

	resp, parseErr := thanos.Parse(body)
	if parseErr != nil {
		r.Status = checks.StatusSkip
		r.Message = "Could not parse upgrade result metric"
		cc.AddResult(r)
		return
	}

	for _, res := range resp.Data.Result {
		version := res.Metric["version"]
		precedingVersion := res.Metric["preceding_version"]
		alerts := res.Metric["alerts"]
		stream := res.Metric["stream"]

		r.Details["version"] = version
		r.Details["preceding_version"] = precedingVersion
		r.Details["stream"] = stream
		r.Details["alerts"] = alerts

		if alerts != "" && alerts != "none" {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("Upgrade %s→%s completed with alerts: %s", precedingVersion, version, alerts)
		} else {
			r.Status = checks.StatusInfo
			r.Message = fmt.Sprintf("Upgrade %s→%s completed cleanly", precedingVersion, version)
		}
	}

	cc.AddResult(r)
}

func checkFeatureGates(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("muo_feature_gates")

	r := checks.Result{
		Check:    "muo_feature_gates",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Reports MUO feature gate configuration from the ConfigMap. Known gates: PreHealthCheck (validates cluster health before starting upgrade), ServiceLogNotification (sends service log notifications for upgrade events). Feature gates affect upgrade behavior and safety checks.",
			"pass_criteria": "INFO: always informational. Reports which feature gates are enabled.",
		},
	}

	cm, err := cc.Client.Clientset().CoreV1().ConfigMaps(muoNamespace).Get(ctx, "managed-upgrade-operator-config", metav1.GetOptions{})
	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = "Cannot read ConfigMap for feature gates"
		cc.AddResult(r)
		return
	}

	configYAML := cm.Data["config.yaml"]
	var config map[string]any
	if parseErr := parseYAMLConfig(configYAML, &config); parseErr != nil {
		r.Status = checks.StatusSkip
		r.Message = "Cannot parse config.yaml for feature gates"
		cc.AddResult(r)
		return
	}

	gates := []string{}
	if fg, ok := config["featureGate"].(map[string]any); ok {
		if enabled, ok := fg["enabled"].([]any); ok {
			for _, g := range enabled {
				if s, ok := g.(string); ok {
					gates = append(gates, s)
				}
			}
		}
	}

	r.Details["feature_gates"] = gates
	r.Details["count"] = len(gates)
	r.Status = checks.StatusInfo

	if len(gates) == 0 {
		r.Message = "No feature gates enabled"
	} else {
		r.Message = fmt.Sprintf("Feature gates enabled: %s", strings.Join(gates, ", "))
	}

	cc.AddResult(r)
}

func parseYAMLConfig(yamlStr string, out *map[string]any) error {
	return yaml.Unmarshal([]byte(yamlStr), out)
}
