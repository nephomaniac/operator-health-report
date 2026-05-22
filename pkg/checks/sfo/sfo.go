package sfo

import (
	"context"
	"fmt"
	"strings"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/logging"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func init() {
	checks.Register(&SFOChecker{})
}

type SFOChecker struct{}

func (c *SFOChecker) Name() string { return "sfo" }

var (
	splunkForwarderGVR = schema.GroupVersionResource{
		Group: "splunkforwarder.managed.openshift.io", Version: "v1alpha1", Resource: "splunkforwarders",
	}
)

func (c *SFOChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	checkControllerAvailability(ctx, cc)

	// The dependency chain is: Secret → CR → Operator reconciles → DaemonSet → Pods
	// If no CR exists, DaemonSet and pods won't exist — that's expected.
	hasCR := checkSplunkForwarderCR(ctx, cc)
	checkSecrets(ctx, cc, hasCR)

	if hasCR {
		checkDaemonSetHealth(ctx, cc)
		checkForwarderPods(ctx, cc)
	} else {
		// No CR — skip DaemonSet/pod checks with clear explanation
		cc.CurrentCheck = "sfo_daemonset_health"
		cc.AddResult(checks.Result{
			Check:    "sfo_daemonset_health",
			Status:   checks.StatusSkip,
			Severity: checks.SeverityInfo,
			Message:  fmt.Sprintf("Skipped — no SplunkForwarder CR in %s (DaemonSet is created by operator from CR)", cc.Operator.Namespace),
		})
		cc.CurrentCheck = "sfo_forwarder_pods"
		cc.AddResult(checks.Result{
			Check:    "sfo_forwarder_pods",
			Status:   checks.StatusSkip,
			Severity: checks.SeverityInfo,
			Message:  fmt.Sprintf("Skipped — no SplunkForwarder CR in %s (pods are created by DaemonSet from CR)", cc.Operator.Namespace),
		})
	}
}

// checkDaemonSetHealth verifies the splunk forwarder DaemonSet exists and is healthy
func checkDaemonSetHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "sfo_daemonset_health"

	r := checks.Result{
		Check:    "sfo_daemonset_health",
		Severity: checks.SeverityCritical,
		Details:  map[string]any{},
	}

	// The operator creates DaemonSets in its namespace with label name=splunk-forwarder
	dsList, err := cc.Client.Clientset().AppsV1().DaemonSets(cc.Operator.Namespace).List(ctx, metav1.ListOptions{})
	cc.RecordError("List DaemonSets", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("Could not list DaemonSets: %v", err)
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
		available := int(ds.Status.NumberAvailable)

		dsInfo := map[string]any{
			"name":      fmt.Sprintf("%s/%s", cc.Operator.Namespace, ds.Name),
			"desired":   desired,
			"ready":     ready,
			"available": available,
		}

		if ds.Status.NumberUnavailable > 0 {
			dsInfo["unavailable"] = int(ds.Status.NumberUnavailable)
		}

		splunkDS = append(splunkDS, dsInfo)
	}

	r.Details["daemonsets"] = splunkDS
	r.Details["count"] = len(splunkDS)

	switch {
	case len(splunkDS) == 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("No splunk forwarder DaemonSet found in %s — operator may not have reconciled yet", cc.Operator.Namespace)
	default:
		allHealthy := true
		var issues []string
		for _, ds := range splunkDS {
			desired := ds["desired"].(int)
			ready := ds["ready"].(int)
			name := ds["name"].(string)
			if ready != desired {
				allHealthy = false
				issues = append(issues, fmt.Sprintf("%s: %d/%d ready", name, ready, desired))
			}
		}
		if allHealthy {
			r.Status = checks.StatusPass
			total := 0
			for _, ds := range splunkDS {
				total += ds["desired"].(int)
			}
			r.Message = fmt.Sprintf("%d DaemonSet(s) healthy (%d pods scheduled)", len(splunkDS), total)
		} else {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("DaemonSet not fully ready: %s", strings.Join(issues, "; "))
		}
	}

	cc.AddResult(r)
}

// checkForwarderPods verifies forwarder pods are running on nodes
func checkForwarderPods(ctx context.Context, cc *checks.ClusterContext) {
	cc.CurrentCheck = "sfo_forwarder_pods"

	r := checks.Result{
		Check:    "sfo_forwarder_pods",
		Severity: checks.SeverityWarning,
		Details:  map[string]any{},
	}

	pods, err := cc.Client.GetPods(ctx, cc.Operator.Namespace, "name=splunk-forwarder")
	cc.RecordError("Get forwarder pods", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusSkip
			r.Message = "Could not retrieve forwarder pods"
			cc.AddResult(r)
		}
		return
	}

	podCount := len(pods.Items)
	notRunning := 0
	totalRestarts := 0
	var podIssues []map[string]any

	for _, pod := range pods.Items {
		if pod.Status.Phase != "Running" {
			notRunning++
			issue := map[string]any{
				"pod":   fmt.Sprintf("%s/%s", cc.Operator.Namespace, pod.Name),
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
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("No forwarder pods (label: name=splunk-forwarder) in %s", cc.Operator.Namespace)
	case notRunning > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d forwarder pod(s) not running", notRunning, podCount)
	case totalRestarts > 10:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d forwarder pods running (%d total restarts)", podCount, totalRestarts)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d forwarder pods running on %d nodes (%d restarts)", podCount, podCount, totalRestarts)
	}

	cc.AddResult(r)
}

// checkSplunkForwarderCR verifies the SplunkForwarder custom resource exists.
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

	list, err := cc.Client.ListResources(ctx, splunkForwarderGVR, cc.Operator.Namespace, true)
	cc.RecordError("List SplunkForwarder CRs", err)

	if err != nil {
		if checks.IsAccessError(err) {
			cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		} else {
			r.Status = checks.StatusSkip
			r.Message = fmt.Sprintf("Could not query SplunkForwarder CRs: %v", err)
			cc.AddResult(r)
		}
		return false
	}

	crCount := len(list.Items)
	r.Details["cr_count"] = crCount

	if crCount == 0 {
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("No SplunkForwarder CR in %s — forwarder not configured on this cluster", cc.Operator.Namespace)
		cc.AddResult(r)
		return false
	}

	// Extract key fields from the first CR
	cr := list.Items[0]
	crName := cr.GetName()

	image, _, _ := unstructured.NestedString(cr.Object, "spec", "image")
	imageDigest, _, _ := unstructured.NestedString(cr.Object, "spec", "imageDigest")
	clusterID, _, _ := unstructured.NestedString(cr.Object, "spec", "clusterID")
	licenseAccepted, _, _ := unstructured.NestedBool(cr.Object, "spec", "splunkLicenseAccepted")
	useHeavy, _, _ := unstructured.NestedBool(cr.Object, "spec", "useHeavyForwarder")

	inputs, _, _ := unstructured.NestedSlice(cr.Object, "spec", "splunkInputs")

	r.Details["cr_name"] = fmt.Sprintf("%s/%s", cc.Operator.Namespace, crName)
	r.Details["image"] = image
	if imageDigest != "" {
		r.Details["image_digest"] = imageDigest[:min(len(imageDigest), 19)]
	}
	r.Details["cluster_id"] = clusterID
	r.Details["license_accepted"] = licenseAccepted
	r.Details["use_heavy_forwarder"] = useHeavy
	r.Details["input_count"] = len(inputs)

	r.Status = checks.StatusPass
	r.Message = fmt.Sprintf("SplunkForwarder CR '%s/%s' configured (%d inputs, image: %s)",
		cc.Operator.Namespace, crName, len(inputs), truncateImage(image, imageDigest))

	cc.AddResult(r)
	return true
}

// checkSecrets verifies the splunk auth and HEC token secrets exist.
// If hasCR is false, missing secrets are INFO (not configured) rather than FAIL.
func checkSecrets(ctx context.Context, cc *checks.ClusterContext, hasCR bool) {
	cc.CurrentCheck = "sfo_secrets"
	log := logging.WithCheck("sfo_secrets")

	r := checks.Result{
		Check:    "sfo_secrets",
		Severity: checks.SeverityWarning,
		Details:  map[string]any{},
	}

	if !cc.Client.CanElevate() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	secrets := []struct {
		name     string
		required bool
	}{
		{"splunk-auth", true},
		{"splunk-hec-token", false},
	}

	found := 0
	missing := []string{}

	for _, s := range secrets {
		secretRef := fmt.Sprintf("%s/%s", cc.Operator.Namespace, s.name)
		_, err := cc.Client.ElevatedClientset().CoreV1().Secrets(cc.Operator.Namespace).Get(ctx, s.name, metav1.GetOptions{})
		if err == nil {
			found++
			r.Details[s.name] = "present"
		} else {
			r.Details[s.name] = "missing"
			if s.required {
				missing = append(missing, secretRef)
			}
		}
	}

	log.WithField("found", found).WithField("missing", len(missing)).Debug("SFO secrets check")

	switch {
	case len(missing) > 0 && hasCR:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Required secret(s) missing: %s — operator cannot reconcile SplunkForwarder CR without this", strings.Join(missing, ", "))
	case len(missing) > 0 && !hasCR:
		r.Status = checks.StatusInfo
		r.Severity = checks.SeverityInfo
		r.Message = fmt.Sprintf("Secret(s) not present: %s (expected — no SplunkForwarder CR configured)", strings.Join(missing, ", "))
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d secret(s) present", found)
	}

	cc.AddResult(r)
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
			r.Message = fmt.Sprintf("Cannot access deployment: %v", err)
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

	r.Details["available"] = available

	r.Details["deployment"] = fmt.Sprintf("%s/%s", cc.Operator.Namespace, cc.Operator.Deployment)

	if available == "True" {
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("Controller %s/%s is available", cc.Operator.Namespace, cc.Operator.Deployment)
	} else {
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Controller %s/%s not available", cc.Operator.Namespace, cc.Operator.Deployment)
	}

	cc.AddResult(r)
}

func truncateImage(image, digest string) string {
	if digest != "" {
		if len(digest) > 12 {
			return digest[:12]
		}
		return digest
	}
	parts := strings.Split(image, "/")
	return parts[len(parts)-1]
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
