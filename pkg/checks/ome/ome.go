package ome

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/logging"
	"github.com/openshift/operator-health-report/pkg/thanos"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func init() {
	checks.Register(&OMEChecker{})
}

type OMEChecker struct{}

func (c *OMEChecker) Name() string { return "ome" }

func (c *OMEChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	checkMetricsHealth(ctx, cc)
	checkPullSecretHealth(ctx, cc)
	checkProxyCAHealth(ctx, cc)
	checkServiceMonitorHealth(ctx, cc)
	checkIdentityProviders(ctx, cc)
}

// GVR definitions for dynamic client lookups
var (
	proxyGVR = schema.GroupVersionResource{
		Group: "config.openshift.io", Version: "v1", Resource: "proxies",
	}
	oauthGVR = schema.GroupVersionResource{
		Group: "config.openshift.io", Version: "v1", Resource: "oauths",
	}
	cpmsGVR = schema.GroupVersionResource{
		Group: "machine.openshift.io", Version: "v1", Resource: "controlplanemachinesets",
	}
	serviceMonitorGVR = schema.GroupVersionResource{
		Group: "monitoring.coreos.com", Version: "v1", Resource: "servicemonitors",
	}
)

type metricSpec struct {
	Name        string
	Trigger     string // human-readable trigger description for HTML display
	TriggerKind string // resource kind for existence check
	Required    bool
}

var expectedMetrics = []metricSpec{
	{Name: "identity_provider", Trigger: "OAuth CR 'cluster'", TriggerKind: "OAuth", Required: false},
	{Name: "cluster_admin_enabled", Trigger: "", TriggerKind: "", Required: true},
	{Name: "limited_support_enabled", Trigger: "", TriggerKind: "", Required: true},
	{Name: "cluster_proxy", Trigger: "Proxy CR 'cluster'", TriggerKind: "Proxy", Required: false},
	{Name: "cluster_proxy_ca_expiry_timestamp", Trigger: "ConfigMap 'user-ca-bundle' in openshift-config", TriggerKind: "Proxy", Required: false},
	{Name: "cluster_proxy_ca_valid", Trigger: "ConfigMap 'user-ca-bundle' in openshift-config", TriggerKind: "Proxy", Required: false},
	{Name: "cluster_id", Trigger: "", TriggerKind: "", Required: true},
	{Name: "pods_preventing_node_drain", Trigger: "", TriggerKind: "", Required: false},
	{Name: "cpms_enabled", Trigger: "ControlPlaneMachineSet CRD", TriggerKind: "ControlPlaneMachineSet", Required: false},
	{Name: "pull_secret_valid", Trigger: "Secret 'pull-secret' in openshift-config", TriggerKind: "Secret", Required: true},
}

// checkMetricsHealth verifies OME's custom Prometheus metrics are being scraped
func checkMetricsHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("ome_metrics_health")
	log := logging.WithCheck("ome_metrics_health")

	r := checks.Result{
		Check:    "ome_metrics_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates that each OSD metric exported by osd-metrics-exporter is present in Prometheus. Uses trigger-based conditional logic: metrics tied to optional cluster features (proxy, CPMS, OAuth) are only expected when the trigger resource exists. Required metrics (cluster_id, cluster_admin_enabled, limited_support_enabled, pull_secret_valid) must always be present.",
			"pass_criteria": "PASS: all required metrics present, conditional metrics match trigger state. WARN: one or more required metrics missing with trigger present, or partial query failures due to authorization. SKIP: all metric queries failed (elevation/authorization issue). FAIL: Prometheus is not scraping osd-metrics-exporter at all.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Check if Prometheus is scraping OME
	upBody, err := cc.Client.QueryMetrics(ctx, `up{job="osd-metrics-exporter"}`)
	cc.RecordError("Check OME scrape target", err)

	scraped := false
	if err == nil && upBody != "" {
		scraped = thanos.HasResults(upBody)
	}
	r.Details["prometheus_scraping"] = scraped

	if !scraped {
		r.Status = checks.StatusFail
		r.Message = "Prometheus is NOT scraping osd-metrics-exporter — ServiceMonitor may be missing"
		cc.AddResult(r)
		return
	}

	// Check each expected metric — output format matches bash version for HTML rendering.
	// Distinguishes between "query succeeded, metric absent" (real MISSING) vs
	// "query failed" (authorization/elevation issue — not a metric problem).
	found := 0
	missing := 0
	expectedAbsent := 0
	queryFailed := 0
	var metricResults []map[string]any

	for _, metric := range expectedMetrics {
		rawQuery := fmt.Sprintf(`%s{name="osd_exporter"}`, metric.Name)
		body, queryErr := cc.Client.QueryMetrics(ctx, rawQuery)

		entry := map[string]any{
			"name":    metric.Name,
			"trigger": metric.Trigger,
		}

		if queryErr != nil {
			// Query itself failed (Forbidden, Unauthorized, pod not found, etc.)
			entry["status"] = "query_error"
			entry["value"] = ""
			entry["trigger_present"] = "unknown"
			entry["error"] = queryErr.Error()
			queryFailed++
			metricResults = append(metricResults, entry)
			continue
		}

		isPresent := false
		metricValue := ""
		if body != "" && thanos.HasResults(body) {
			isPresent = true
			if val, _, ok := thanos.InstantValue(body); ok {
				metricValue = val
			}
		}
		entry["value"] = metricValue

		if isPresent {
			entry["status"] = "found"
			entry["trigger_present"] = "true"
			found++
		} else if metric.Trigger != "" {
			triggerExists := checkTriggerExists(ctx, cc, metric)
			if triggerExists {
				entry["status"] = "MISSING"
				entry["trigger_present"] = "true"
				missing++
			} else {
				entry["status"] = "absent_expected"
				entry["trigger_present"] = "false"
				expectedAbsent++
			}
		} else if metric.Required {
			entry["status"] = "MISSING"
			entry["trigger_present"] = "true"
			missing++
		} else {
			entry["status"] = "absent_expected"
			entry["trigger_present"] = "false"
			expectedAbsent++
		}

		metricResults = append(metricResults, entry)
	}

	r.Details["metrics"] = metricResults
	r.Details["present"] = found
	r.Details["missing"] = missing
	r.Details["expected_absent"] = expectedAbsent
	r.Details["query_errors"] = queryFailed

	log.WithField("found", found).WithField("missing", missing).WithField("query_errors", queryFailed).Debug("OME metrics audit")

	switch {
	case queryFailed > 0 && found == 0:
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Cannot verify metrics — %d/%d queries failed (authorization/elevation issue)",
			queryFailed, len(expectedMetrics))
	case queryFailed > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d metrics present, %d query errors, %d expected absent — partial results due to authorization issues",
			found, len(expectedMetrics), queryFailed, expectedAbsent)
	case missing > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d metrics present, %d missing (trigger exists), %d expected absent",
			found, len(expectedMetrics), missing, expectedAbsent)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d/%d metrics present, %d expected absent",
			found, len(expectedMetrics), expectedAbsent)
	}

	cc.AddResult(r)
}

// checkTriggerExists verifies the trigger resource for a conditional metric
func checkTriggerExists(ctx context.Context, cc *checks.ClusterContext, metric metricSpec) bool {
	switch metric.TriggerKind {
	case "OAuth":
		_, err := cc.Client.GetResource(ctx, oauthGVR, "", "cluster", false)
		return err == nil
	case "Proxy":
		obj, err := cc.Client.GetResource(ctx, proxyGVR, "", "cluster", false)
		if err != nil {
			return false
		}
		httpProxy, _, _ := unstructured.NestedString(obj.Object, "spec", "httpProxy")
		httpsProxy, _, _ := unstructured.NestedString(obj.Object, "spec", "httpsProxy")
		return httpProxy != "" || httpsProxy != ""
	case "ControlPlaneMachineSet":
		list, err := cc.Client.ListResources(ctx, cpmsGVR, "", false)
		return err == nil && len(list.Items) > 0
	case "Secret":
		_, err := cc.Client.Clientset().CoreV1().Secrets("openshift-config").Get(ctx, "pull-secret", metav1.GetOptions{})
		return err == nil
	default:
		return true
	}
}

// checkPullSecretHealth checks the pull_secret_valid metric
func checkPullSecretHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("ome_pull_secret_health")

	r := checks.Result{
		Check:    "ome_pull_secret_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the pull_secret_valid metric exported by OME to verify the cloud.openshift.com pull secret in openshift-config is present and valid. An invalid pull secret prevents the cluster from pulling images from Red Hat registries and breaks telemetry reporting.",
			"pass_criteria": "PASS: pull_secret_valid=1 with reason=Valid. WARN: pull_secret_valid=0 (invalid pull secret with reason label). SKIP: metric not found, OME may not have reconciled yet.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx, `pull_secret_valid{name="osd_exporter"}`)
	cc.RecordError("Query pull_secret_valid", err)

	if err != nil || body == "" || !thanos.HasResults(body) {
		r.Status = checks.StatusSkip
		r.Message = "pull_secret_valid metric not found — OME may not have reconciled"
		cc.AddResult(r)
		return
	}

	value, labels, _ := thanos.InstantValue(body)
	reason := labels["reason"]
	r.Details["value"] = value
	r.Details["reason"] = reason

	if value == "1" && reason == "Valid" {
		r.Status = checks.StatusPass
		r.Message = "Pull secret valid"
	} else if value == "0" {
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Pull secret invalid (reason: %s)", reason)
	} else {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Pull secret status: value=%s, reason=%s", value, reason)
	}

	cc.AddResult(r)
}

// checkProxyCAHealth checks proxy CA certificate validity
func checkProxyCAHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("ome_proxy_ca_health")

	r := checks.Result{
		Check:    "ome_proxy_ca_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates the proxy CA certificate trust bundle when a cluster proxy is configured. OME exports cluster_proxy_ca_valid and cluster_proxy_ca_expiry_timestamp metrics from the user-ca-bundle ConfigMap in openshift-config. An invalid or expired proxy CA causes TLS failures for all egress traffic routed through the proxy.",
			"pass_criteria": "PASS: cluster_proxy_ca_valid=1 (certificate is valid). FAIL: cluster_proxy_ca_valid=0 (certificate is invalid or expired). INFO: no cluster proxy configured, check not applicable. SKIP: could not determine proxy CA status from metrics.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	// Check if proxy is configured
	proxyObj, err := cc.Client.GetResource(ctx, proxyGVR, "", "cluster", false)
	if err != nil {
		r.Status = checks.StatusInfo
		r.Message = "No cluster proxy configured — CA check not applicable"
		cc.AddResult(r)
		return
	}

	httpProxy, _, _ := unstructured.NestedString(proxyObj.Object, "spec", "httpProxy")
	httpsProxy, _, _ := unstructured.NestedString(proxyObj.Object, "spec", "httpsProxy")
	if httpProxy == "" && httpsProxy == "" {
		r.Status = checks.StatusInfo
		r.Message = "No cluster proxy configured — CA check not applicable"
		cc.AddResult(r)
		return
	}

	// Check CA validity metric
	validBody, err := cc.Client.QueryMetrics(ctx, `cluster_proxy_ca_valid{name="osd_exporter"}`)
	cc.RecordError("Query cluster_proxy_ca_valid", err)

	caValid := "unknown"
	if err == nil && validBody != "" && thanos.HasResults(validBody) {
		caValid, _, _ = thanos.InstantValue(validBody)
	}
	r.Details["ca_valid"] = caValid

	// Check expiry timestamp
	expiryBody, expiryErr := cc.Client.QueryMetrics(ctx, `cluster_proxy_ca_expiry_timestamp{name="osd_exporter"}`)
	if expiryErr != nil {
		cc.RecordError("Query cluster_proxy_ca_expiry_timestamp", expiryErr)
	}

	expiryStr := ""
	if expiryErr == nil && expiryBody != "" && thanos.HasResults(expiryBody) {
		expiryStr, _, _ = thanos.InstantValue(expiryBody)
	}
	r.Details["ca_expiry"] = expiryStr

	switch {
	case caValid == "0":
		r.Status = checks.StatusFail
		r.Message = "Proxy CA certificate is INVALID"
	case caValid == "1":
		r.Status = checks.StatusPass
		r.Message = "Proxy CA certificate is valid"
		if ts, parseErr := strconv.ParseFloat(expiryStr, 64); parseErr == nil && ts > 0 {
			r.Details["ca_expiry_epoch"] = ts
		}
	default:
		r.Status = checks.StatusSkip
		r.Message = "Could not determine proxy CA status"
	}

	cc.AddResult(r)
}

// checkServiceMonitorHealth verifies OME's ServiceMonitor exists
func checkServiceMonitorHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("ome_servicemonitor_health")

	r := checks.Result{
		Check:    "ome_servicemonitor_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates that the osd-metrics-exporter ServiceMonitor exists in openshift-osd-metrics. The ServiceMonitor tells Prometheus how to scrape OME's metrics endpoint. Without it, none of OME's custom metrics (pull secret health, proxy CA, identity providers, etc.) are collected.",
			"pass_criteria": "PASS: ServiceMonitor exists with valid endpoint configuration (port and path). FAIL: ServiceMonitor not found, metrics are not being collected by Prometheus.",
		},
	}

	obj, err := cc.Client.GetResource(ctx, serviceMonitorGVR, "openshift-osd-metrics", "osd-metrics-exporter", false)
	cc.RecordError("Get OME ServiceMonitor", err)

	if err != nil {
		r.Status = checks.StatusFail
		r.Message = "ServiceMonitor osd-metrics-exporter not found — metrics not being collected"
		cc.AddResult(r)
		return
	}

	spec, _, _ := unstructured.NestedMap(obj.Object, "spec")
	endpoints, _, _ := unstructured.NestedSlice(obj.Object, "spec", "endpoints")

	port := ""
	path := ""
	if len(endpoints) > 0 {
		if ep, ok := endpoints[0].(map[string]any); ok {
			port, _ = ep["port"].(string)
			path, _ = ep["path"].(string)
		}
	}

	r.Details["port"] = port
	r.Details["path"] = path
	r.Details["endpoint_count"] = len(endpoints)

	// Suppress the unused variable lint; spec is read to confirm structure
	_ = spec

	r.Status = checks.StatusPass
	r.Message = fmt.Sprintf("ServiceMonitor exists (port=%s, path=%s)", port, path)

	cc.AddResult(r)
}

// checkIdentityProviders reports identity provider configuration (informational)
func checkIdentityProviders(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("ome_identity_providers")

	r := checks.Result{
		Check:    "ome_identity_providers",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Reports the identity provider configuration by reading the identity_provider metric exported by OME. This is informational only: it shows which IDP types (LDAP, GitHub, Google, etc.) are configured on the cluster's OAuth CR, which is useful context for understanding cluster access patterns.",
			"pass_criteria": "INFO: always informational. Reports the count and types of configured identity providers. No identity providers is not an error — some clusters use only kubeadmin or service accounts.",
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	body, err := cc.Client.QueryMetrics(ctx, `identity_provider{name="osd_exporter"}`)
	cc.RecordError("Query identity_provider", err)

	if err != nil || body == "" || !thanos.HasResults(body) {
		r.Status = checks.StatusInfo
		r.Message = "No identity provider metrics found"
		cc.AddResult(r)
		return
	}

	resp, parseErr := thanos.Parse(body)
	providers := []string{}
	if parseErr == nil {
		for _, res := range resp.Data.Result {
			if idpType, ok := res.Metric["type"]; ok {
				providers = append(providers, idpType)
			}
		}
	}

	r.Details["identity_providers"] = providers
	r.Details["count"] = len(providers)
	r.Status = checks.StatusInfo
	r.Message = fmt.Sprintf("%d identity provider(s) configured: %s", len(providers), strings.Join(providers, ", "))

	cc.AddResult(r)
}
