package checks

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/openshift/operator-health-report/pkg/logging"
	"github.com/openshift/operator-health-report/pkg/saas"
	"github.com/openshift/operator-health-report/pkg/thanos"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

const memoryLeakThresholdPercent = 50.0

// PodSummary returns an oc-get-pod-wide style summary for a pod.
func PodSummary(pod corev1.Pod) map[string]any {
	totalRestarts := int32(0)
	readyContainers := 0
	totalContainers := len(pod.Spec.Containers)
	var waitReason, termReason string

	for _, cs := range pod.Status.ContainerStatuses {
		totalRestarts += cs.RestartCount
		if cs.Ready {
			readyContainers++
		}
		if cs.State.Waiting != nil && cs.State.Waiting.Reason != "" {
			waitReason = cs.State.Waiting.Reason
		}
		if cs.State.Terminated != nil && cs.State.Terminated.Reason != "" {
			termReason = cs.State.Terminated.Reason
		}
	}

	status := string(pod.Status.Phase)
	if waitReason != "" {
		status = waitReason
	} else if termReason != "" {
		status = termReason
	}

	age := time.Since(pod.CreationTimestamp.Time).Truncate(time.Minute).String()

	summary := map[string]any{
		"name":     pod.Name,
		"ready":    fmt.Sprintf("%d/%d", readyContainers, totalContainers),
		"status":   status,
		"restarts": totalRestarts,
		"age":      age,
		"node":     pod.Spec.NodeName,
	}
	if pod.Status.PodIP != "" {
		summary["ip"] = pod.Status.PodIP
	}
	return summary
}

// ProblematicPods filters a pod list to those with issues and returns summaries.
func ProblematicPods(pods []corev1.Pod) []map[string]any {
	var result []map[string]any
	for _, pod := range pods {
		if isPodProblematic(pod) {
			result = append(result, PodSummary(pod))
		}
	}
	return result
}

func isPodProblematic(pod corev1.Pod) bool {
	if pod.Status.Phase != corev1.PodRunning {
		return true
	}
	for _, cs := range pod.Status.ContainerStatuses {
		if !cs.Ready {
			return true
		}
		if cs.RestartCount > 5 {
			return true
		}
		if cs.State.Waiting != nil && cs.State.Waiting.Reason != "" {
			return true
		}
	}
	return false
}

// CheckNamespace verifies the operator namespace exists and is Active
func CheckNamespace(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("namespace_status")

	phase, err := cc.Client.GetNamespacePhase(ctx, cc.Operator.Namespace)
	cc.RecordError("Get namespace phase", err)

	r := Result{
		Check:    "namespace_status",
		Severity: SeverityCritical,
		Details: map[string]any{
			"description":   "Checks the operator namespace exists and is in Active phase. The namespace is a prerequisite for all other checks — if it does not exist or is Terminating, the operator cannot function and remaining checks are skipped.",
			"pass_criteria": "PASS: Namespace exists and phase is Active. FAIL: Namespace does not exist, is Terminating, or API error (non-RBAC). ACCESS_DENIED: Cannot read namespace due to insufficient permissions. SKIP: n/a.",
			"namespace":     cc.Operator.Namespace,
			"phase":         phase,
		},
	}

	switch {
	case err != nil && IsAccessError(err):
		r.Status = StatusAccessDenied
		r.Severity = SeverityInfo
		r.Message = fmt.Sprintf("Cannot access namespace %s: %v", cc.Operator.Namespace, err)
	case err != nil || phase == "":
		r.Status = StatusFail
		r.Message = fmt.Sprintf("Namespace %s does not exist", cc.Operator.Namespace)
		if err != nil {
			r.Message += fmt.Sprintf(" (%v)", err)
		}
	case phase == "Terminating":
		r.Status = StatusFail
		r.Message = fmt.Sprintf("Namespace %s is Terminating", cc.Operator.Namespace)
	default:
		r.Status = StatusPass
		r.Message = fmt.Sprintf("Namespace %s is %s", cc.Operator.Namespace, phase)
	}

	cc.AddResult(r)
}

// CheckDeployment verifies the operator deployment health
func CheckDeployment(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("pod_status_and_restarts")

	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	cc.RecordError("Get deployment status", err)

	r := Result{
		Check:    "pod_status_and_restarts",
		Severity: SeverityWarning,
		Details: map[string]any{
			"description":   "Checks the operator Deployment health in the operator namespace, including replica readiness, pod Running status, container restart counts, and container state details (Waiting/Terminated reasons). A degraded deployment means the operator cannot reconcile its managed resources.",
			"pass_criteria": "PASS: All desired replicas ready, all pods Running, restarts <= 10. WARN: Not all replicas ready, restarts > 10, or pods not in Running state. FAIL: No pods found or deployment missing. ACCESS_DENIED: Cannot read deployment due to insufficient permissions.",
		},
	}

	if err != nil {
		if IsAccessError(err) {
			r.Status = StatusAccessDenied
			r.Severity = SeverityInfo
			r.Message = fmt.Sprintf("Cannot access deployment %s/%s: %v", cc.Operator.Namespace, cc.Operator.Deployment, err)
		} else {
			r.Status = StatusFail
			r.Severity = SeverityCritical
			r.Message = fmt.Sprintf("Deployment %s/%s not found: %v", cc.Operator.Namespace, cc.Operator.Deployment, err)
		}
		cc.AddResult(r)
		return
	}

	desired := 1
	if deploy.Spec.Replicas != nil {
		desired = int(*deploy.Spec.Replicas)
	}
	ready := int(deploy.Status.ReadyReplicas)
	available := int(deploy.Status.AvailableReplicas)

	r.Details["desired_replicas"] = desired
	r.Details["ready_replicas"] = ready
	r.Details["available_replicas"] = available

	// Get pods via label selector
	selector, err := metav1.LabelSelectorAsSelector(deploy.Spec.Selector)
	podSelector := ""
	if err == nil {
		podSelector = selector.String()
	} else {
		podSelector = fmt.Sprintf("name=%s", cc.Operator.Deployment)
	}

	pods, err := cc.Client.GetPods(ctx, cc.Operator.Namespace, podSelector)
	cc.RecordError("Get operator pods", err)

	totalRestarts := 0
	podCount := 0
	podsNotRunning := 0

	var podIssues []map[string]any
	if err == nil {
		podCount = len(pods.Items)
		for _, pod := range pods.Items {
			if pod.Status.Phase != corev1.PodRunning {
				podsNotRunning++
				issue := map[string]any{
					"pod":   fmt.Sprintf("%s/%s", cc.Operator.Namespace, pod.Name),
					"phase": string(pod.Status.Phase),
				}
				for _, cs := range pod.Status.ContainerStatuses {
					if cs.State.Waiting != nil {
						issue["waiting_reason"] = cs.State.Waiting.Reason
						issue["waiting_message"] = cs.State.Waiting.Message
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
	}

	r.Details["pod_count"] = podCount
	r.Details["total_restarts"] = totalRestarts
	r.Details["pods_not_running"] = podsNotRunning
	if len(podIssues) > 0 {
		r.Details["pod_issues"] = podIssues
	}
	if err == nil {
		if problematic := ProblematicPods(pods.Items); len(problematic) > 0 {
			r.Details["failing_pods"] = problematic
		}
	}

	switch {
	case podCount == 0:
		r.Status = StatusFail
		r.Severity = SeverityCritical
		r.Message = fmt.Sprintf("No pods found for %s/%s", cc.Operator.Namespace, cc.Operator.Deployment)
	case ready != desired:
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("Deployment not fully ready (%d/%d)", ready, desired)
	case totalRestarts > 10:
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("Elevated restart count: %d", totalRestarts)
	case podsNotRunning > 0:
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("%d pod(s) not in Running state", podsNotRunning)
	default:
		r.Status = StatusPass
		r.Message = fmt.Sprintf("%s/%s pod healthy (%d restarts)", cc.Operator.Namespace, cc.Operator.Deployment, totalRestarts)
	}

	cc.AddResult(r)
}

// CheckPKOHealth verifies ClusterPackage status
func CheckPKOHealth(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("pko_clusterpackage_health")

	packageName := cc.Operator.Name
	if strings.Contains(packageName, "controller-manager") {
		packageName = strings.TrimSuffix(packageName, "-controller-manager")
	}

	gvr := clusterPackageGVR()
	pkg, err := cc.Client.GetResource(ctx, gvr, "", packageName, false)

	r := Result{
		Check:    "pko_clusterpackage_health",
		Severity: SeverityCritical,
		Details: map[string]any{
			"description":   "Checks the PKO ClusterPackage status conditions (Available, Progressing, Unpacked) for the operator. PKO is the primary deployment mechanism — a failed ClusterPackage means the operator will not receive updates and may be running a stale or broken version. If no ClusterPackage exists, falls back to checking OLM Subscription.",
			"pass_criteria": "PASS: Available=True, Progressing=False, Unpacked=True. WARN: Progressing=True (rollout in progress). FAIL: Available=False, or stuck due to immutable fields / adoption conflicts. SKIP: No ClusterPackage found (falls back to OLM check).",
			"package_name":  packageName,
		},
	}

	if err != nil {
		r.Status = StatusSkip
		r.Message = "No ClusterPackage found"
		cc.AddResult(r)
		checkOLMSubscription(ctx, cc, packageName)
		return
	}

	conditions, _, _ := unstructuredNestedSlice(pkg.Object, "status", "conditions")

	available := conditionStatus(conditions, "Available")
	progressing := conditionStatus(conditions, "Progressing")
	unpacked := conditionStatus(conditions, "Unpacked")
	progressingMsg := conditionMessage(conditions, "Progressing")
	availableMsg := conditionMessage(conditions, "Available")

	r.Details["package"] = fmt.Sprintf("clusterpackage/%s", packageName)
	r.Details["available"] = available
	r.Details["progressing"] = progressing
	r.Details["unpacked"] = unpacked
	r.Details["cluster_package_exists"] = true
	if availableMsg != "" {
		r.Details["available_message"] = availableMsg
	}
	if progressingMsg != "" {
		r.Details["progressing_message"] = progressingMsg
	}

	switch {
	case available == "True" && progressing == "False" && unpacked == "True":
		r.Status = StatusPass
		r.Message = "PKO ClusterPackage healthy (Available=True, Progressing=False, Unpacked=True)"
	case available == "False":
		r.Status = StatusFail
		if strings.Contains(availableMsg, "refusing adoption") || strings.Contains(availableMsg, "not owned by previous revision") {
			r.Message = fmt.Sprintf("PKO refusing adoption of pre-existing resource from OLM: %s", availableMsg)
		} else {
			r.Message = fmt.Sprintf("PKO ClusterPackage not available: %s", availableMsg)
		}
	case progressing == "True":
		if strings.Contains(progressingMsg, "immutable") {
			r.Status = StatusFail
			r.Message = "PKO ClusterPackage stuck: spec.template field is immutable"
		} else if strings.Contains(progressingMsg, "refusing adoption") {
			r.Status = StatusFail
			r.Message = fmt.Sprintf("PKO refusing adoption: %s", progressingMsg)
		} else {
			r.Status = StatusWarning
			r.Message = fmt.Sprintf("PKO ClusterPackage progressing: %s", progressingMsg)
		}
	default:
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("PKO state unclear (Available=%s, Progressing=%s, Unpacked=%s)", available, progressing, unpacked)
	}

	cc.AddResult(r)
}

func checkOLMSubscription(ctx context.Context, cc *ClusterContext, packageName string) {
	cc.SetCheck("olm_subscription_health")

	gvr := subscriptionGVR()
	_, err := cc.Client.GetResource(ctx, gvr, cc.Operator.Namespace, packageName, false)

	r := Result{
		Check:    "olm_subscription_health",
		Severity: SeverityCritical,
		Details: map[string]any{
			"description":   "Checks for an OLM Subscription in the operator namespace as a fallback when no PKO ClusterPackage is found. The Subscription is the legacy deployment mechanism — if neither OLM nor PKO is present, the operator is not deployed at all.",
			"pass_criteria": "PASS: OLM Subscription exists. FAIL: Neither OLM Subscription nor PKO ClusterPackage found — operator not deployed.",
			"package_name":  packageName,
		},
	}

	if err != nil {
		r.Status = StatusFail
		r.Message = "No OLM Subscription or PKO ClusterPackage found — operator not deployed"
	} else {
		r.Status = StatusPass
		r.Message = "OLM subscription exists"
	}

	cc.AddResult(r)
}

// CheckResourceLeakDetection queries Thanos for CPU/memory timeseries
func CheckResourceLeakDetection(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("resource_leak_detection")
	log := logging.WithCheck("resource_leak_detection")

	r := Result{
		Check:    "resource_leak_detection",
		Severity: SeverityWarning,
		Details: map[string]any{
			"description":   "Queries Prometheus/Thanos for 7-day CPU and memory timeseries of the operator container to detect resource leaks. Compares first and last values to calculate percentage change. A sustained increase indicates a potential memory leak or unbounded CPU growth that could eventually cause OOMKills or throttling.",
			"pass_criteria": fmt.Sprintf("PASS: Both CPU and memory trend stable (increase < %.0f%% or absolute values below noise threshold). WARN: CPU or memory increased > %.0f%% over 7 days. UNKNOWN: No metrics data available. ACCESS_DENIED: Cannot query Prometheus. SKIP: Elevation not available (required for Thanos query).", memoryLeakThresholdPercent, memoryLeakThresholdPercent),
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult("resource_leak_detection"))
		return
	}

	containerName := cc.Operator.Deployment
	if strings.Contains(containerName, "controller-manager") {
		containerName = "manager"
	}
	r.Details["container_name"] = containerName

	now := time.Now().Unix()
	start := now - 604800
	step := 1800

	// Memory query
	memQueryRaw := fmt.Sprintf(
		`container_memory_working_set_bytes{namespace="%s",pod=~"%s-.*",container="%s"}`,
		cc.Operator.Namespace, cc.Operator.Deployment, containerName)

	memData, memErr := cc.Client.QueryMetricsRange(ctx, memQueryRaw, start, now, step)
	cc.RecordError("Memory timeseries query", memErr)
	memPoints, _ := thanos.Timeseries(memData)

	// CPU query
	cpuQueryRaw := fmt.Sprintf(
		`rate(container_cpu_usage_seconds_total{namespace="%s",pod=~"%s-.*",container="%s"}[5m])`,
		cc.Operator.Namespace, cc.Operator.Deployment, containerName)

	cpuData, cpuErr := cc.Client.QueryMetricsRange(ctx, cpuQueryRaw, start, now, step)
	cc.RecordError("CPU timeseries query", cpuErr)
	cpuPoints, _ := thanos.Timeseries(cpuData)

	memFirst, memLast, memPctChange := thanos.Trend(memPoints)
	peakMemBytes := thanos.Peak(memPoints)
	peakMemMB := thanos.Round(peakMemBytes/1048576, 2)
	lastMemMB := thanos.Round(memLast/1048576, 1)

	r.Details["memory_timeseries"] = thanos.PointsToJSON(memPoints)
	r.Details["peak_memory_bytes"] = peakMemBytes
	r.Details["peak_memory_mb"] = peakMemMB
	r.Details["memory_increase_percent"] = thanos.Round(memPctChange, 2)

	memTrend := "stable"
	if memPctChange > memoryLeakThresholdPercent && lastMemMB > 20 {
		memTrend = "increasing"
	}
	r.Details["memory_trend"] = memTrend

	cpuFirst, cpuLast, cpuPctChange := thanos.Trend(cpuPoints)
	peakCPU := thanos.Peak(cpuPoints)
	peakCPUMillicores := thanos.Round(peakCPU*1000, 0)
	lastCPUMillicores := thanos.Round(cpuLast*1000, 1)

	r.Details["cpu_timeseries"] = thanos.PointsToJSON(cpuPoints)
	r.Details["peak_cpu_cores"] = peakCPU
	r.Details["peak_cpu_millicores"] = peakCPUMillicores
	r.Details["cpu_increase_percent"] = thanos.Round(cpuPctChange, 2)

	cpuTrend := "stable"
	if cpuPctChange > memoryLeakThresholdPercent && lastCPUMillicores > 1 {
		cpuTrend = "increasing"
	}
	r.Details["cpu_trend"] = cpuTrend
	r.Details["lookback_hours"] = 168.0
	r.Details["threshold_percent"] = memoryLeakThresholdPercent

	log.WithField("mem_pct", memPctChange).WithField("cpu_pct", cpuPctChange).Debug("Resource trend analysis")

	switch {
	case len(memPoints) == 0 && len(cpuPoints) == 0:
		if IsAccessError(memErr) || IsAccessError(cpuErr) {
			r.Status = StatusAccessDenied
			r.Message = "Cannot query resource metrics — access denied"
		} else {
			r.Status = StatusUnknown
			r.Message = "Unable to query resource metrics from Prometheus"
		}
	case memTrend == "increasing" && cpuTrend == "increasing":
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("Both CPU and memory increased >%.0f%% (CPU: %.1f%%, Mem: %.1f%%)",
			memoryLeakThresholdPercent, cpuPctChange, memPctChange)
	case memTrend == "increasing":
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("Memory increased %.1f%% over 7d (%.1f→%.1f MB, peak: %.1f MB)",
			memPctChange, memFirst/1048576, memLast/1048576, peakMemMB)
	case cpuTrend == "increasing":
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("CPU increased %.1f%% over 7d (%.1f→%.1fm, peak: %.0fm)",
			cpuPctChange, cpuFirst*1000, cpuLast*1000, peakCPUMillicores)
	default:
		r.Status = StatusPass
		r.Message = fmt.Sprintf("CPU and memory stable (peak: %.1f MB / %.0fm)", peakMemMB, peakCPUMillicores)
	}

	cc.AddResult(r)
}

// CheckVersionVerification compares the deployed operator version against the SAAS target
func CheckVersionVerification(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("version_verification")
	log := logging.WithCheck("version_verification")

	r := Result{
		Check:    "version_verification",
		Severity: SeverityWarning,
		Details: map[string]any{
			"description":   "Compares the running operator container image tag/SHA against the expected version from the SAAS target file (resolved via hive shard and OCM environment). A mismatch means the cluster is running an unexpected version — either a rollout is in progress, a promotion failed, or the cluster was missed during deployment.",
			"pass_criteria": "PASS: Deployed image tag/SHA matches the SAAS target version. WARN: Version mismatch between deployed and expected, or deployed image could not be determined. SKIP: Hive shard unknown, SAAS target resolution failed, or no expected version in SAAS target.",
		},
	}

	if cc.HiveShard == "" || cc.HiveShard == "unknown" {
		r.Status = StatusSkip
		r.Message = "Hive shard unknown — cannot resolve SAAS target"
		cc.AddResult(r)
		return
	}

	target, err := saas.ResolveTarget(ctx, cc.HiveShard, cc.OCMEnv,
		cc.Operator.PKOSaas, cc.Operator.OLMSaas, cc.Operator.ShortName)
	if err != nil {
		log.WithField("error", err).Debug("SAAS target resolution failed")
		r.Status = StatusSkip
		r.Message = fmt.Sprintf("Could not resolve SAAS target: %v", err)
		cc.AddResult(r)
		return
	}

	displayVersion := target.ImageTag
	if displayVersion == "" || strings.HasPrefix(displayVersion, "sha:") || strings.HasPrefix(displayVersion, "branch:") {
		if len(target.Version) > 7 {
			displayVersion = target.Version[:7]
		} else {
			displayVersion = target.Version
		}
	}

	r.Details["saas_target"] = target.Name
	r.Details["expected_version"] = displayVersion
	r.Details["expected_ref"] = target.Version
	r.Details["expected_image_tag"] = target.ImageTag
	r.Details["saas_file"] = target.SaasFile
	r.Details["deploy_method"] = target.Method

	// Get the deployed image
	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	cc.RecordError("Get operator image", err)

	deployedImage := ""
	if err == nil && len(deploy.Spec.Template.Spec.Containers) > 0 {
		deployedImage = deploy.Spec.Template.Spec.Containers[0].Image
	}
	r.Details["deployed_image"] = deployedImage

	if deployedImage == "" {
		r.Status = StatusWarning
		r.Message = "Could not determine deployed image"
		cc.AddResult(r)
		return
	}

	deployedVersion := extractVersionFromImage(deployedImage)
	r.Details["deployed_version"] = deployedVersion

	if target.Version == "" {
		r.Status = StatusSkip
		r.Message = "No expected version in SAAS target"
		cc.AddResult(r)
		return
	}

	shortRef := target.Version
	if len(shortRef) > 7 {
		shortRef = shortRef[:7]
	}

	match := false
	if strings.Contains(deployedImage, shortRef) {
		match = true
	}
	if target.ImageTag != "" && strings.Contains(deployedImage, target.ImageTag) {
		match = true
	}
	if strings.HasPrefix(deployedVersion, shortRef) || strings.HasPrefix(shortRef, deployedVersion) {
		match = true
	}

	if match {
		r.Status = StatusPass
		r.Message = fmt.Sprintf("Version matches SAAS target %s (%s via %s)", target.Name, displayVersion, target.Method)
	} else {
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("Version mismatch — expected %s (SAAS target %s via %s), deployed %s",
			displayVersion, target.Name, target.Method, deployedVersion)
	}

	cc.AddResult(r)
}

// CheckResourceLimits shows resource limit/request configuration and compares against actual usage.
// Never fails for missing limits — presents values clearly and warns only if usage approaches or exceeds limits.
func CheckResourceLimits(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("resource_limits_validation")

	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	cc.RecordError("Get deployment resources", err)

	r := Result{
		Check:    "resource_limits_validation",
		Severity: SeverityInfo,
		Details: map[string]any{
			"description":   "Checks CPU and memory resource requests/limits on the operator Deployment's primary container and compares peak 7-day usage (from resource_leak_detection) against configured limits. Missing limits risk unbounded resource consumption; usage near limits risks OOMKills or CPU throttling.",
			"pass_criteria": "PASS: Limits are set and peak usage is below 80% of limits, or no limits configured (informational). WARN: Peak usage >= 80% of a configured limit, or peak usage exceeds a limit. SKIP: Deployment not found or has no containers.",
		},
	}

	if err != nil || len(deploy.Spec.Template.Spec.Containers) == 0 {
		r.Status = StatusSkip
		r.Message = "Could not retrieve deployment"
		cc.AddResult(r)
		return
	}

	container := deploy.Spec.Template.Spec.Containers[0]
	limits := container.Resources.Limits
	requests := container.Resources.Requests

	hasCPULimit := limits.Cpu() != nil && !limits.Cpu().IsZero()
	hasMemLimit := limits.Memory() != nil && !limits.Memory().IsZero()
	hasCPURequest := requests.Cpu() != nil && !requests.Cpu().IsZero()
	hasMemRequest := requests.Memory() != nil && !requests.Memory().IsZero()

	// Always present all 4 values — "None" for unset (HTML renders "None" in red)
	if hasCPULimit {
		r.Details["cpu_limit"] = limits.Cpu().String()
	} else {
		r.Details["cpu_limit"] = "None"
	}
	if hasMemLimit {
		r.Details["memory_limit"] = limits.Memory().String()
	} else {
		r.Details["memory_limit"] = "None"
	}
	if hasCPURequest {
		r.Details["cpu_request"] = requests.Cpu().String()
	} else {
		r.Details["cpu_request"] = "None"
	}
	if hasMemRequest {
		r.Details["memory_request"] = requests.Memory().String()
	} else {
		r.Details["memory_request"] = "None"
	}

	// Recommendations for missing values
	var recommendations []string
	if !hasCPULimit {
		recommendations = append(recommendations, "cpu limit")
	}
	if !hasMemLimit {
		recommendations = append(recommendations, "memory limit")
	}
	if !hasCPURequest {
		recommendations = append(recommendations, "cpu request")
	}
	if !hasMemRequest {
		recommendations = append(recommendations, "memory request")
	}
	if len(recommendations) > 0 {
		r.Details["recommendations"] = fmt.Sprintf("Consider setting: %s", strings.Join(recommendations, ", "))
	}

	// Compare actual usage against limits using data from resource_leak_detection
	var peakMemMB, peakCPUMillicores float64
	for _, result := range cc.Results {
		if result.Check == "resource_leak_detection" && result.Details != nil {
			if v, ok := result.Details["peak_memory_mb"].(float64); ok {
				peakMemMB = v
			}
			if v, ok := result.Details["peak_cpu_millicores"].(float64); ok {
				peakCPUMillicores = v
			}
		}
	}
	r.Details["peak_memory_mb"] = peakMemMB
	r.Details["peak_cpu_millicores"] = peakCPUMillicores

	// Check if usage is close to or exceeding limits
	var alerts []string

	if hasMemLimit && peakMemMB > 0 {
		limitBytes := limits.Memory().Value()
		limitMB := float64(limitBytes) / 1048576
		pct := (peakMemMB / limitMB) * 100
		r.Details["memory_usage_percent"] = fmt.Sprintf("%.0f%%", pct)
		if peakMemMB >= limitMB {
			alerts = append(alerts, fmt.Sprintf("Memory EXCEEDED limit (peak %.1f MB >= %s)", peakMemMB, limits.Memory().String()))
		} else if pct >= 80 {
			alerts = append(alerts, fmt.Sprintf("Memory at %.0f%% of limit (peak %.1f MB / %s)", pct, peakMemMB, limits.Memory().String()))
		}
	}

	if hasCPULimit && peakCPUMillicores > 0 {
		limitMillicores := float64(limits.Cpu().MilliValue())
		pct := (peakCPUMillicores / limitMillicores) * 100
		r.Details["cpu_usage_percent"] = fmt.Sprintf("%.0f%%", pct)
		if peakCPUMillicores >= limitMillicores {
			alerts = append(alerts, fmt.Sprintf("CPU EXCEEDED limit (peak %.0fm >= %s)", peakCPUMillicores, limits.Cpu().String()))
		} else if pct >= 80 {
			alerts = append(alerts, fmt.Sprintf("CPU at %.0f%% of limit (peak %.0fm / %s)", pct, peakCPUMillicores, limits.Cpu().String()))
		}
	}

	// Build message
	switch {
	case len(alerts) > 0:
		r.Status = StatusWarning
		r.Severity = SeverityWarning
		r.Message = strings.Join(alerts, "; ")
	default:
		r.Status = StatusPass
		parts := []string{}
		if hasCPULimit {
			parts = append(parts, fmt.Sprintf("CPU: %s", limits.Cpu().String()))
		}
		if hasMemLimit {
			parts = append(parts, fmt.Sprintf("Mem: %s", limits.Memory().String()))
		}
		if len(parts) > 0 && peakMemMB > 0 {
			r.Message = fmt.Sprintf("Limits: %s (peak usage: %.1f MB / %.0fm)", strings.Join(parts, ", "), peakMemMB, peakCPUMillicores)
		} else if len(parts) > 0 {
			r.Message = fmt.Sprintf("Limits: %s", strings.Join(parts, ", "))
		} else {
			r.Message = "No resource limits configured"
		}
	}

	cc.AddResult(r)
}

// CheckLeaderElection verifies the leader lease
func CheckLeaderElection(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("leader_election")

	leaseNames := []string{
		cc.Operator.Deployment + "-lock",
		cc.Operator.Name + "-lock",
		cc.Operator.Deployment + "-leader-election",
	}

	r := Result{
		Check:    "leader_election",
		Severity: SeverityInfo,
		Details: map[string]any{
			"description":   "Validates that a leader election Lease exists in the operator namespace and has an active holder. Searches for common lease name patterns (<deployment>-lock, <name>-lock, <deployment>-leader-election). A missing or stale lease can indicate the operator is not running or is stuck in leader election contention.",
			"pass_criteria": "PASS: Leader lease found with an active holder identity. SKIP: No leader lease found (single replica or leader election not used by this operator).",
		},
	}

	for _, leaseName := range leaseNames {
		lease, err := cc.Client.Clientset().CoordinationV1().Leases(cc.Operator.Namespace).Get(ctx, leaseName, metav1.GetOptions{})
		if err == nil && lease != nil {
			holder := ""
			if lease.Spec.HolderIdentity != nil {
				holder = *lease.Spec.HolderIdentity
			}
			r.Details["lease_name"] = leaseName
			r.Details["holder_identity"] = holder
			r.Status = StatusPass
			r.Message = fmt.Sprintf("Leader lease %s held by %s", leaseName, holder)
			cc.AddResult(r)
			return
		}
	}

	r.Status = StatusSkip
	r.Message = "No leader lease found (single replica or leader election disabled)"
	cc.AddResult(r)
}

// CheckImagePull verifies no ImagePullBackOff on operator pods
func CheckImagePull(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("image_pull_status")

	pods, err := cc.Client.GetPods(ctx, cc.Operator.Namespace, "")
	cc.RecordError("Get pod status", err)

	r := Result{
		Check:    "image_pull_status",
		Severity: SeverityCritical,
		Details: map[string]any{
			"description":   "Checks all pods in the operator namespace for ImagePullBackOff or ErrImagePull container states (both init and regular containers). Image pull failures prevent the operator from starting and typically indicate a missing image, wrong tag, registry authentication failure, or network connectivity issue.",
			"pass_criteria": "PASS: No pods have image pull errors. FAIL: One or more pods have ImagePullBackOff or ErrImagePull. SKIP: Could not retrieve pod list.",
		},
	}

	if err != nil {
		r.Status = StatusSkip
		r.Message = "Could not retrieve pod status"
		cc.AddResult(r)
		return
	}

	pullErrors := 0
	failingImages := map[string]string{} // image → waiting reason
	for _, pod := range pods.Items {
		for _, cs := range append(pod.Status.ContainerStatuses, pod.Status.InitContainerStatuses...) {
			if cs.State.Waiting != nil {
				reason := cs.State.Waiting.Reason
				if reason == "ImagePullBackOff" || reason == "ErrImagePull" {
					pullErrors++
					failingImages[cs.Image] = reason
				}
			}
		}
	}

	r.Details["image_pull_errors"] = pullErrors
	if pullErrors > 0 {
		if problematic := ProblematicPods(pods.Items); len(problematic) > 0 {
			r.Details["failing_pods"] = problematic
		}

		// Verify image availability via registry API
		var imageChecks []map[string]any
		for image, reason := range failingImages {
			check := map[string]any{
				"image":  image,
				"reason": reason,
			}
			available, regErr := CheckImageInRegistry(image)
			if regErr != nil {
				check["registry_check"] = fmt.Sprintf("error: %v", regErr)
			} else if available {
				check["registry_check"] = "image exists in registry — pull failure may be auth/network issue"
			} else {
				check["registry_check"] = "image NOT found in registry — tag or repo may not exist"
			}
			check["available"] = available
			imageChecks = append(imageChecks, check)
		}
		r.Details["image_checks"] = imageChecks
	}

	if pullErrors > 0 {
		r.Status = StatusFail
		var imageSummaries []string
		for _, ic := range r.Details["image_checks"].([]map[string]any) {
			img := ic["image"].(string)
			if idx := strings.LastIndex(img, "/"); idx >= 0 {
				img = img[idx+1:]
			}
			if len(img) > 40 {
				img = img[:37] + "..."
			}
			regResult := ic["registry_check"].(string)
			imageSummaries = append(imageSummaries, fmt.Sprintf("%s (%s)", img, regResult))
		}
		r.Message = fmt.Sprintf("%d pod(s) with image pull errors in %s — %s",
			pullErrors, cc.Operator.Namespace, strings.Join(imageSummaries, "; "))
	} else {
		r.Status = StatusPass
		r.Message = "No image pull errors"
	}

	cc.AddResult(r)
}

// checkImageInRegistry verifies if an image exists in its registry via API.
// Supports quay.io and generic registries via HEAD on the manifest endpoint.
func CheckImageInRegistry(imageRef string) (bool, error) {
	// Parse image reference: registry/repo:tag or registry/repo@sha256:digest
	ref := imageRef
	tag := "latest"
	if atIdx := strings.Index(ref, "@"); atIdx >= 0 {
		tag = ref[atIdx+1:]
		ref = ref[:atIdx]
	} else if colonIdx := strings.LastIndex(ref, ":"); colonIdx >= 0 && !strings.Contains(ref[colonIdx:], "/") {
		tag = ref[colonIdx+1:]
		ref = ref[:colonIdx]
	}

	// Quay.io: use Quay API
	if strings.HasPrefix(ref, "quay.io/") {
		repo := strings.TrimPrefix(ref, "quay.io/")
		apiURL := fmt.Sprintf("https://quay.io/api/v1/repository/%s/tag/?specificTag=%s&limit=1", repo, tag)
		client := &http.Client{Timeout: 10 * time.Second}
		resp, err := client.Get(apiURL)
		if err != nil {
			return false, fmt.Errorf("quay API request failed: %w", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode == 404 {
			return false, nil
		}
		if resp.StatusCode != 200 {
			return false, fmt.Errorf("quay API returned %d", resp.StatusCode)
		}
		var result struct {
			Tags []struct{ Name string `json:"name"` } `json:"tags"`
		}
		body, _ := io.ReadAll(resp.Body)
		if err := json.Unmarshal(body, &result); err != nil {
			return false, fmt.Errorf("parsing quay response: %w", err)
		}
		return len(result.Tags) > 0, nil
	}

	// Generic registry: try HEAD on /v2/{repo}/manifests/{tag}
	registry := "https://" + strings.Split(ref, "/")[0]
	repoPath := strings.SplitN(ref, "/", 2)
	if len(repoPath) < 2 {
		return false, fmt.Errorf("cannot parse registry from %s", imageRef)
	}
	manifestURL := fmt.Sprintf("%s/v2/%s/manifests/%s", registry, repoPath[1], tag)
	client := &http.Client{Timeout: 10 * time.Second}
	req, err := http.NewRequest("HEAD", manifestURL, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json")
	resp, err := client.Do(req)
	if err != nil {
		return false, fmt.Errorf("registry request failed: %w", err)
	}
	defer resp.Body.Close()
	return resp.StatusCode == 200, nil
}

// CheckPKOJobHealth verifies PKO cleanup jobs are healthy
func CheckPKOJobHealth(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("pko_job_health")

	jobs, err := cc.Client.Clientset().BatchV1().Jobs(cc.Operator.Namespace).List(ctx, metav1.ListOptions{})
	cc.RecordError("Get PKO jobs", err)

	r := Result{
		Check:    "pko_job_health",
		Severity: SeverityWarning,
		Details: map[string]any{
			"description":   "Checks PKO-related cleanup Jobs (olm-cleanup, pko) in the operator namespace for failures or hung state. These jobs run during OLM-to-PKO migration to clean up legacy OLM resources. Hung or failed jobs can block the migration and leave the operator in a broken state with conflicting deployment methods.",
			"pass_criteria": "PASS: All cleanup jobs completed successfully or no jobs present. WARN: Jobs still active (potentially hung), jobs failed, or more than 3 stale cleanup jobs remain. SKIP: Could not retrieve job list.",
		},
	}

	if err != nil {
		r.Status = StatusSkip
		r.Message = "Could not retrieve jobs"
		cc.AddResult(r)
		return
	}

	hungJobs := 0
	failedJobs := 0
	totalJobs := 0
	var jobDetails []map[string]any

	for _, job := range jobs.Items {
		if !strings.Contains(job.Name, "olm-cleanup") && !strings.Contains(job.Name, "pko") {
			continue
		}
		totalJobs++

		isHung := job.Status.Active > 0
		isFailed := job.Status.Failed > 0 && job.Status.Succeeded == 0

		if !isHung && !isFailed {
			continue
		}

		if isHung {
			hungJobs++
		}
		if isFailed {
			failedJobs++
		}

		detail := map[string]any{
			"name":      fmt.Sprintf("%s/%s", cc.Operator.Namespace, job.Name),
			"active":    job.Status.Active,
			"failed":    job.Status.Failed,
			"succeeded": job.Status.Succeeded,
		}

		// Capture conditions for failure reason
		for _, cond := range job.Status.Conditions {
			if cond.Type == "Failed" && cond.Status == "True" {
				detail["failure_reason"] = cond.Reason
				detail["failure_message"] = cond.Message
			}
		}

		// Try to get logs from the most recent failed pod
		if isFailed {
			pods, podErr := cc.Client.GetPods(ctx, cc.Operator.Namespace, fmt.Sprintf("job-name=%s", job.Name))
			if podErr == nil && len(pods.Items) > 0 {
				for _, pod := range pods.Items {
					if pod.Status.Phase == corev1.PodFailed || pod.Status.Phase == corev1.PodSucceeded {
						logs, logErr := cc.Client.GetPodLogs(ctx, cc.Operator.Namespace, pod.Name, 20)
						if logErr == nil && logs != "" {
							detail["pod_name"] = pod.Name
							detail["pod_phase"] = string(pod.Status.Phase)
							// Truncate to last 500 chars
							if len(logs) > 500 {
								logs = "..." + logs[len(logs)-500:]
							}
							detail["pod_logs"] = logs
						}
						// Get termination reason from container status
						for _, cs := range pod.Status.ContainerStatuses {
							if cs.State.Terminated != nil {
								detail["exit_code"] = cs.State.Terminated.ExitCode
								detail["termination_reason"] = cs.State.Terminated.Reason
							}
						}
						break
					}
				}
			}
		}

		jobDetails = append(jobDetails, detail)
	}

	r.Details["total_cleanup_jobs"] = totalJobs
	r.Details["hung_jobs"] = hungJobs
	r.Details["failed_jobs"] = failedJobs
	if len(jobDetails) > 0 {
		r.Details["job_details"] = jobDetails
	}

	// Build message with job names
	jobNames := make([]string, len(jobDetails))
	for i, d := range jobDetails {
		jobNames[i] = d["name"].(string)
	}

	switch {
	case hungJobs > 0:
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("%d PKO cleanup job(s) still active (may be hung): %s", hungJobs, strings.Join(jobNames, ", "))
	case failedJobs > 0:
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("%d PKO cleanup job(s) failed: %s", failedJobs, strings.Join(jobNames, ", "))
	case totalJobs > 3:
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("%d stale cleanup jobs", totalJobs)
	default:
		r.Status = StatusPass
		r.Message = fmt.Sprintf("%d cleanup jobs, all healthy", totalJobs)
	}

	cc.AddResult(r)
}

// CheckLogErrors analyzes operator logs for errors
func CheckLogErrors(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("log_error_analysis")

	// Get deployment to find pods
	deploy, err := cc.Client.Clientset().AppsV1().Deployments(cc.Operator.Namespace).Get(ctx, cc.Operator.Deployment, metav1.GetOptions{})
	logCheckDesc := "Analyzes the last 500 lines of the operator pod logs for error and warning patterns. Counts lines containing 'error' (excluding info-level) and 'warning'. Elevated error counts can indicate reconciliation failures, API connectivity issues, or resource conflicts. Note: on managed clusters in production, log retrieval requires elevation (backplane-cluster-admin impersonation)."
	logCheckCriteria := "PASS: Errors <= 10 (within normal threshold) or no errors found. WARN: More than 10 errors detected in recent logs. SKIP: Could not retrieve deployment, no pods found, or log retrieval failed."

	if err != nil {
		cc.AddResult(Result{Check: "log_error_analysis", Status: StatusSkip, Severity: SeverityWarning,
			Message: "Could not retrieve deployment for log analysis",
			Details: map[string]any{"description": logCheckDesc, "pass_criteria": logCheckCriteria}})
		return
	}

	selector, _ := metav1.LabelSelectorAsSelector(deploy.Spec.Selector)
	pods, err := cc.Client.GetPods(ctx, cc.Operator.Namespace, selector.String())
	if err != nil || len(pods.Items) == 0 {
		cc.AddResult(Result{Check: "log_error_analysis", Status: StatusSkip, Severity: SeverityWarning,
			Message: "No pods found for log analysis",
			Details: map[string]any{"description": logCheckDesc, "pass_criteria": logCheckCriteria}})
		return
	}

	podName := pods.Items[0].Name
	logOutput, err := cc.Client.GetPodLogs(ctx, cc.Operator.Namespace, podName, 500)
	cc.RecordError("Get operator logs", err)

	r := Result{
		Check:    "log_error_analysis",
		Severity: SeverityWarning,
		Details: map[string]any{
			"description":   "Analyzes the last 500 lines of the operator pod logs for error and warning patterns. Counts lines containing 'error' (excluding info-level) and 'warning'. Elevated error counts can indicate reconciliation failures, API connectivity issues, or resource conflicts. Note: on managed clusters in production, log retrieval requires elevation (backplane-cluster-admin impersonation).",
			"pass_criteria": "PASS: Errors <= 10 (within normal threshold) or no errors found. WARN: More than 10 errors detected in recent logs. SKIP: Could not retrieve deployment, no pods found, or log retrieval failed.",
		},
	}

	if err != nil || logOutput == "" {
		r.Status = StatusSkip
		r.Message = "Could not retrieve logs"
		cc.AddResult(r)
		return
	}

	lines := strings.Split(logOutput, "\n")
	errorCount := 0
	warningCount := 0
	for _, line := range lines {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "error") && !strings.Contains(lower, "level=info") {
			errorCount++
		}
		if strings.Contains(lower, "warning") {
			warningCount++
		}
	}

	r.Details["error_count"] = errorCount
	r.Details["warning_count"] = warningCount
	r.Details["total_lines"] = len(lines)

	switch {
	case errorCount > 10:
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("Found %d errors and %d warnings in logs", errorCount, warningCount)
	case errorCount > 0:
		r.Status = StatusPass
		r.Message = fmt.Sprintf("Found %d errors and %d warnings in logs (within threshold)", errorCount, warningCount)
	default:
		r.Status = StatusPass
		r.Message = fmt.Sprintf("No errors in logs (%d warnings)", warningCount)
	}

	cc.AddResult(r)
}

// CheckEvents collects Kubernetes warning events for the operator deployment
func CheckEvents(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("operator_events")

	events, err := cc.Client.GetEvents(ctx, cc.Operator.Namespace, cc.Operator.Deployment)
	cc.RecordError("Get deployment events", err)

	r := Result{
		Check:    "operator_events",
		Severity: SeverityWarning,
		Details: map[string]any{
			"description":   "Checks for Warning-type Kubernetes events associated with the operator deployment in the operator namespace. Warning events indicate issues such as failed scheduling, liveness probe failures, OOMKills, or failed mounts that may affect operator availability.",
			"pass_criteria": "PASS: No Warning events found for the operator deployment. WARN: One or more Warning events detected.",
		},
	}

	warningCount := 0
	var eventDetails []map[string]any

	if err == nil {
		for _, evt := range events.Items {
			if evt.Type == "Warning" {
				warningCount++
				eventDetails = append(eventDetails, map[string]any{
					"reason":  evt.Reason,
					"message": evt.Message,
					"count":   evt.Count,
				})
			}
		}
	}

	r.Details["warning_event_count"] = warningCount
	r.Details["events"] = eventDetails

	if warningCount > 0 {
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("%d warning event(s) for %s", warningCount, cc.Operator.Deployment)
	} else {
		r.Status = StatusPass
		r.Message = "No warning events"
	}

	cc.AddResult(r)
}

// CheckDualInstallation detects both OLM and PKO deployed for the same operator
func CheckDualInstallation(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("dual_installation_check")

	r := Result{
		Check:    "dual_installation_check",
		Severity: SeverityCritical,
		Details: map[string]any{
			"description":   "Detects whether both OLM (Subscription) and PKO (ClusterPackage) deployment methods exist simultaneously for the same operator. Dual installations cause resource conflicts — both systems attempt to manage the same Deployment, leading to rollback loops, version flapping, and reconciliation errors.",
			"pass_criteria": "PASS: Exactly one deployment method found (PKO only or OLM only). FAIL: Both OLM Subscription and PKO ClusterPackage exist (conflicting deployment), or neither exists (operator not deployed).",
		},
	}

	packageName := cc.Operator.Name
	if strings.Contains(packageName, "controller-manager") {
		packageName = strings.TrimSuffix(packageName, "-controller-manager")
	}

	_, pkoErr := cc.Client.GetResource(ctx, clusterPackageGVR(), "", packageName, false)
	hasPKO := pkoErr == nil

	subList, subErr := cc.Client.ListResources(ctx, subscriptionGVR(), cc.Operator.Namespace, false)
	hasOLM := false
	if subErr == nil {
		for _, sub := range subList.Items {
			if strings.Contains(sub.GetName(), packageName) {
				hasOLM = true
				break
			}
		}
	}

	r.Details["has_pko"] = hasPKO
	r.Details["has_olm"] = hasOLM
	r.Details["deploy_method"] = "unknown"

	switch {
	case hasPKO && hasOLM:
		r.Status = StatusFail
		r.Message = "Both OLM Subscription and PKO ClusterPackage exist — conflicting deployment methods"
		r.Details["deploy_method"] = "CONFLICT"
	case hasPKO:
		r.Status = StatusPass
		r.Message = "Deployed via PKO only"
		r.Details["deploy_method"] = "PKO"
	case hasOLM:
		r.Status = StatusPass
		r.Message = "Deployed via OLM only"
		r.Details["deploy_method"] = "OLM"
	default:
		r.Status = StatusFail
		r.Message = "Neither OLM nor PKO deployment found"
	}

	cc.AddResult(r)
}

// CheckOrphanedOLM checks for orphaned OLM artifacts (CSVs) on PKO-deployed clusters
func CheckOrphanedOLM(ctx context.Context, cc *ClusterContext) {
	cc.SetCheck("orphaned_olm_artifacts")

	r := Result{
		Check:    "orphaned_olm_artifacts",
		Severity: SeverityCritical,
		Details: map[string]any{
			"description":   "Detects orphaned OLM ClusterServiceVersions (CSVs) in the operator namespace on clusters that have migrated to PKO. Orphaned CSVs indicate an incomplete OLM-to-PKO migration — the OLM cleanup job may have failed, leaving stale resources that can cause confusion during troubleshooting or interfere with future upgrades.",
			"pass_criteria": "PASS: No orphaned OLM CSVs found (clean PKO migration). FAIL: Orphaned OLM CSVs detected on a PKO-deployed cluster. SKIP: Operator not deployed via PKO (check not applicable).",
		},
	}

	packageName := cc.Operator.Name
	if strings.Contains(packageName, "controller-manager") {
		packageName = strings.TrimSuffix(packageName, "-controller-manager")
	}

	// Only relevant if deployed via PKO
	_, pkoErr := cc.Client.GetResource(ctx, clusterPackageGVR(), "", packageName, false)
	hasPKO := pkoErr == nil

	if !hasPKO {
		r.Status = StatusSkip
		r.Message = "Not deployed via PKO — orphan check not applicable"
		cc.AddResult(r)
		return
	}

	csvGVR := schema.GroupVersionResource{Group: "operators.coreos.com", Version: "v1alpha1", Resource: "clusterserviceversions"}
	csvList, csvErr := cc.Client.ListResources(ctx, csvGVR, cc.Operator.Namespace, false)

	var orphanedCSVs []string
	if csvErr == nil {
		for _, item := range csvList.Items {
			if strings.Contains(item.GetName(), packageName) {
				orphanedCSVs = append(orphanedCSVs, item.GetName())
			}
		}
	}

	r.Details["orphaned_csvs"] = orphanedCSVs
	r.Details["deployed_via_pko"] = hasPKO

	if len(orphanedCSVs) > 0 {
		r.Status = StatusFail
		r.Message = fmt.Sprintf("Orphaned OLM CSVs on PKO cluster: %s — incomplete OLM-to-PKO migration",
			strings.Join(orphanedCSVs, ", "))
	} else {
		r.Status = StatusPass
		r.Message = "No orphaned OLM artifacts"
	}

	cc.AddResult(r)
}

// RunAllCommonChecks runs all general checks applicable to any operator
func RunAllCommonChecks(ctx context.Context, cc *ClusterContext) {
	CheckNamespace(ctx, cc)

	if len(cc.Results) > 0 && cc.Results[0].Status == StatusFail {
		return
	}

	checks := []func(context.Context, *ClusterContext){
		CheckDeployment,
		CheckPKOHealth,
		CheckDualInstallation,
		CheckOrphanedOLM,
		CheckVersionVerification,
		CheckResourceLeakDetection,
		CheckResourceLimits,
		CheckLeaderElection,
		CheckImagePull,
		CheckPKOJobHealth,
		CheckLogErrors,
		CheckEvents,
	}
	for _, check := range checks {
		if Cancelled(ctx) {
			return
		}
		check(ctx, cc)
	}
}

// Helper functions

func extractVersionFromImage(image string) string {
	if idx := strings.LastIndex(image, ":"); idx >= 0 {
		tag := image[idx+1:]
		if gIdx := strings.LastIndex(tag, "-g"); gIdx >= 0 {
			return tag[gIdx+2:]
		}
		return tag
	}
	if idx := strings.LastIndex(image, "@"); idx >= 0 {
		end := idx + 13
		if end > len(image) {
			end = len(image)
		}
		return image[idx+1 : end]
	}
	return "unknown"
}

// GVR helpers for custom resources
func clusterPackageGVR() schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: "package-operator.run", Version: "v1alpha1", Resource: "clusterpackages"}
}

func subscriptionGVR() schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: "operators.coreos.com", Version: "v1alpha1", Resource: "subscriptions"}
}

func unstructuredNestedSlice(obj map[string]any, fields ...string) ([]any, bool, error) {
	val, found, err := nestedField(obj, fields...)
	if !found || err != nil {
		return nil, found, err
	}
	slice, ok := val.([]any)
	return slice, ok, nil
}

func nestedField(obj map[string]any, fields ...string) (any, bool, error) {
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
	return current, true, nil
}

func conditionStatus(conditions []any, condType string) string {
	for _, c := range conditions {
		cond, _ := c.(map[string]any)
		if t, _ := cond["type"].(string); t == condType {
			s, _ := cond["status"].(string)
			return s
		}
	}
	return "Unknown"
}

func conditionMessage(conditions []any, condType string) string {
	for _, c := range conditions {
		cond, _ := c.(map[string]any)
		if t, _ := cond["type"].(string); t == condType {
			s, _ := cond["message"].(string)
			return s
		}
	}
	return ""
}

