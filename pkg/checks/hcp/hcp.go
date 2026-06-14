package hcp

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/thanos"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func init() {
	checks.Register(&HCPChecker{})
}

type HCPChecker struct{}

func (c *HCPChecker) Name() string { return "hcp" }

var hostedClusterGVR = schema.GroupVersionResource{
	Group: "hypershift.openshift.io", Version: "v1beta1", Resource: "hostedclusters",
}

// concerningPod holds details for a pod with concerning behavior.
type concerningPod struct {
	Namespace     string `json:"namespace"`
	Pod           string `json:"pod"`
	Container     string `json:"container,omitempty"`
	Phase         string `json:"phase"`
	Reason        string `json:"reason,omitempty"`
	Restarts      int    `json:"restarts"`
	MemMB         int    `json:"mem_mb,omitempty"`
	MemRequestMB  int    `json:"mem_request_mb,omitempty"`
	MemRatio      string `json:"mem_ratio,omitempty"`
	CPUm          int    `json:"cpu_millicores,omitempty"`
	OOMKilled     bool   `json:"oomkilled,omitempty"`
	CrashLooping  bool   `json:"crashlooping,omitempty"`
	NotReady      bool   `json:"not_ready,omitempty"`
}

func (c *HCPChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	if cc.ClusterType != "management_cluster" {
		cc.AddResult(checks.Result{
			Check:    "hcp_cluster_type",
			Status:   checks.StatusInfo,
			Severity: checks.SeverityInfo,
			Message:  fmt.Sprintf("HCP checks not applicable on %s clusters — only management clusters", cc.ClusterType),
		})
		return
	}

	hcpNamespaces := discoverHCPNamespaces(ctx, cc)
	concerningPods := checkPodHealth(ctx, cc, hcpNamespaces)
	checkDeploymentHealth(ctx, cc, hcpNamespaces)
	checkResourceTrends(ctx, cc, concerningPods)
	checkMetricsCoverage(ctx, cc, hcpNamespaces)
	checkPodLogs(ctx, cc, concerningPods)
}

func discoverHCPNamespaces(ctx context.Context, cc *checks.ClusterContext) []string {
	cc.SetCheck("hcp_namespace_health")

	r := checks.Result{
		Check:    "hcp_namespace_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Discovers Hosted Control Plane namespaces by listing HostedCluster CRs. Reports HCP status including Available, Degraded, Progressing conditions, deletion state, and version. Excludes deleting/degraded HCPs from downstream checks.",
			"pass_criteria": "PASS: All HCPs available. WARN: Degraded, stuck deleting, or unavailable HCPs. INFO: HCPs being deleted normally.",
		},
	}

	hcList, err := cc.Client.ListResources(ctx, hostedClusterGVR, "", false)
	if err != nil && checks.IsAccessError(err) && cc.Client.CanElevate() {
		hcList, err = cc.Client.ListResources(ctx, hostedClusterGVR, "", true)
	}
	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Could not list HostedClusters: %v", err)
		cc.AddResult(r)
		return nil
	}

	type hcpStatus struct {
		Name        string `json:"name"`
		Namespace   string `json:"namespace"`
		HCPNamespace string `json:"hcp_namespace"`
		Version     string `json:"version"`
		Available   string `json:"available"`
		Degraded    string `json:"degraded"`
		Progressing string `json:"progressing"`
		Deleting    bool   `json:"deleting,omitempty"`
		DeletingAge string `json:"deleting_age,omitempty"`
		State       string `json:"state"`
	}

	var namespaces []string
	var allHCPs []hcpStatus
	activeCount := 0
	deletingCount := 0
	degradedCount := 0
	unavailableCount := 0
	var issues []string

	for _, hc := range hcList.Items {
		hcName := hc.GetName()
		hcNS := hc.GetNamespace()
		cpNS := hcNS + "-" + hcName

		hs := hcpStatus{
			Name:         hcName,
			Namespace:    hcNS,
			HCPNamespace: cpNS,
		}

		// Extract version
		history, _, _ := unstructured.NestedSlice(hc.Object, "status", "version", "history")
		if len(history) > 0 {
			if entry, ok := history[0].(map[string]any); ok {
				hs.Version, _ = entry["version"].(string)
			}
		}

		// Check deletion state
		delTS := hc.GetDeletionTimestamp()
		if delTS != nil {
			hs.Deleting = true
			age := time.Since(delTS.Time)
			hs.DeletingAge = age.Round(time.Minute).String()
			deletingCount++
			if age > time.Hour {
				hs.State = "stuck-deleting"
				issues = append(issues, fmt.Sprintf("%s: deleting for %s (possibly stuck)", hcName, hs.DeletingAge))
			} else {
				hs.State = "deleting"
			}
			allHCPs = append(allHCPs, hs)
			continue // Don't include in downstream checks
		}

		// Extract conditions
		conditions, _, _ := unstructured.NestedSlice(hc.Object, "status", "conditions")
		for _, cond := range conditions {
			condMap, ok := cond.(map[string]any)
			if !ok {
				continue
			}
			condType, _ := condMap["type"].(string)
			condStatus, _ := condMap["status"].(string)
			switch condType {
			case "Available":
				hs.Available = condStatus
			case "Degraded":
				hs.Degraded = condStatus
			case "ClusterVersionProgressing":
				hs.Progressing = condStatus
			}
		}

		// Determine state
		switch {
		case hs.Degraded == "True":
			hs.State = "degraded"
			degradedCount++
			issues = append(issues, fmt.Sprintf("%s (v%s): Degraded", hcName, hs.Version))
		case hs.Available != "True":
			hs.State = "unavailable"
			unavailableCount++
			issues = append(issues, fmt.Sprintf("%s (v%s): Not Available", hcName, hs.Version))
		default:
			hs.State = "healthy"
			activeCount++
			namespaces = append(namespaces, cpNS)
		}

		allHCPs = append(allHCPs, hs)
	}

	r.Details["total_hcps"] = len(hcList.Items)
	r.Details["healthy"] = activeCount
	r.Details["degraded"] = degradedCount
	r.Details["unavailable"] = unavailableCount
	r.Details["deleting"] = deletingCount
	r.Details["hcp_status"] = allHCPs
	if len(issues) > 0 {
		r.Details["issues"] = issues
	}

	switch {
	case len(hcList.Items) == 0:
		r.Status = checks.StatusInfo
		r.Severity = checks.SeverityInfo
		r.Message = "No HostedClusters found on this MC"
	case degradedCount > 0 || unavailableCount > 0:
		r.Status = checks.StatusWarning
		parts := []string{fmt.Sprintf("%d healthy", activeCount)}
		if degradedCount > 0 {
			parts = append(parts, fmt.Sprintf("%d degraded", degradedCount))
		}
		if unavailableCount > 0 {
			parts = append(parts, fmt.Sprintf("%d unavailable", unavailableCount))
		}
		if deletingCount > 0 {
			parts = append(parts, fmt.Sprintf("%d deleting", deletingCount))
		}
		r.Message = fmt.Sprintf("%d HCPs: %s", len(hcList.Items), strings.Join(parts, ", "))
	case len(issues) > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d HCPs, %d issues: %s", len(hcList.Items), len(issues), strings.Join(issues, "; "))
	default:
		r.Status = checks.StatusPass
		if deletingCount > 0 {
			r.Message = fmt.Sprintf("%d HCPs: %d healthy, %d deleting (normal)", len(hcList.Items), activeCount, deletingCount)
		} else {
			r.Message = fmt.Sprintf("%d HCPs, all healthy", len(hcList.Items))
		}
	}

	cc.AddResult(r)
	return namespaces
}

func checkPodHealth(ctx context.Context, cc *checks.ClusterContext, hcpNamespaces []string) []concerningPod {
	cc.SetCheck("hcp_pod_health")

	r := checks.Result{
		Check:    "hcp_pod_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Scans all pods in HCP namespaces for concerning behavior: memory >5x request, >5 restarts, OOMKilled containers, or pods not Running/Ready. Only stores details for concerning pods to avoid bloat.",
			"pass_criteria": "PASS: No concerning pods. WARN: Elevated restarts or memory. FAIL: OOMKilled or memory >10x request.",
		},
	}

	if len(hcpNamespaces) == 0 {
		r.Status = checks.StatusInfo
		r.Severity = checks.SeverityInfo
		r.Message = "No HCP namespaces to check"
		cc.AddResult(r)
		return nil
	}

	// Get pod metrics via metrics API
	podMetrics := fetchPodMetrics(ctx, cc)

	totalPods := 0
	var concerning []concerningPod
	oomCount := 0
	restartCount := 0
	highMemCount := 0
	notReadyCount := 0

	for _, ns := range hcpNamespaces {
		pods, err := cc.Client.Clientset().CoreV1().Pods(ns).List(ctx, metav1.ListOptions{})
		if err != nil {
			continue
		}
		totalPods += len(pods.Items)

		for i := range pods.Items {
			pod := &pods.Items[i]
			cp := analyzePod(pod, podMetrics)
			if cp != nil {
				concerning = append(concerning, *cp)
				if cp.OOMKilled {
					oomCount++
				}
				if cp.Restarts > 5 {
					restartCount++
				}
				if cp.MemRatio != "" {
					highMemCount++
				}
				if cp.NotReady {
					notReadyCount++
				}
			}
		}
	}

	r.Details["total_pods_scanned"] = totalPods
	r.Details["concerning_count"] = len(concerning)
	r.Details["oomkilled_count"] = oomCount
	r.Details["high_restart_count"] = restartCount
	r.Details["high_memory_count"] = highMemCount
	r.Details["not_ready_count"] = notReadyCount

	// Sort by memory descending, limit to top 20
	sort.Slice(concerning, func(i, j int) bool { return concerning[i].MemMB > concerning[j].MemMB })
	if len(concerning) > 20 {
		r.Details["concerning_pods"] = concerning[:20]
		r.Details["truncated"] = true
	} else if len(concerning) > 0 {
		r.Details["concerning_pods"] = concerning
	}

	switch {
	case oomCount > 0:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("%d concerning pods out of %d (%d OOMKilled, %d high-mem, %d high-restarts)", len(concerning), totalPods, oomCount, highMemCount, restartCount)
	case highMemCount > 0 || notReadyCount > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d concerning pods out of %d (%d high-mem, %d not-ready, %d high-restarts)", len(concerning), totalPods, highMemCount, notReadyCount, restartCount)
	case restartCount > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d pods with elevated restarts out of %d scanned", restartCount, totalPods)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d pods healthy across %d HCP namespaces", totalPods, len(hcpNamespaces))
	}

	cc.AddResult(r)
	return concerning
}

func analyzePod(pod *corev1.Pod, podMetrics map[string]podMetric) *concerningPod {
	// Completed Jobs (Succeeded phase) are not concerning
	if pod.Status.Phase == corev1.PodSucceeded {
		return nil
	}

	isConcerning := false
	cp := &concerningPod{
		Namespace: pod.Namespace,
		Pod:       pod.Name,
		Phase:     string(pod.Status.Phase),
	}

	// Check if pod is Running and Ready
	if pod.Status.Phase != corev1.PodRunning {
		cp.NotReady = true
		isConcerning = true
	} else {
		allReady := true
		for _, cond := range pod.Status.Conditions {
			if cond.Type == corev1.PodReady && cond.Status != corev1.ConditionTrue {
				allReady = false
			}
		}
		if !allReady {
			cp.NotReady = true
			isConcerning = true
		}
	}

	// Check container statuses for restarts and OOMKilled
	for _, cs := range pod.Status.ContainerStatuses {
		cp.Restarts += int(cs.RestartCount)
		if cs.LastTerminationState.Terminated != nil {
			if cs.LastTerminationState.Terminated.Reason == "OOMKilled" {
				cp.OOMKilled = true
				cp.Container = cs.Name
				cp.Reason = "OOMKilled"
				isConcerning = true
			}
		}
		if cs.State.Waiting != nil && cs.State.Waiting.Reason == "CrashLoopBackOff" {
			cp.CrashLooping = true
			cp.Container = cs.Name
			cp.Reason = "CrashLoopBackOff"
			isConcerning = true
		}
	}

	if cp.Restarts > 5 {
		isConcerning = true
	}

	// Check memory usage vs request
	key := pod.Namespace + "/" + pod.Name
	if m, ok := podMetrics[key]; ok {
		cp.MemMB = int(m.memBytes / (1024 * 1024))
		cp.CPUm = int(m.cpuNano / 1000000)

		// Calculate total memory request across containers
		totalRequestBytes := int64(0)
		for _, c := range pod.Spec.Containers {
			if req, ok := c.Resources.Requests[corev1.ResourceMemory]; ok {
				totalRequestBytes += req.Value()
			}
		}
		if totalRequestBytes > 0 {
			cp.MemRequestMB = int(totalRequestBytes / (1024 * 1024))
			ratio := float64(m.memBytes) / float64(totalRequestBytes)
			if ratio > 5.0 {
				cp.MemRatio = fmt.Sprintf("%.1fx", ratio)
				isConcerning = true
			}
		}
	}

	if !isConcerning {
		return nil
	}
	return cp
}

type podMetric struct {
	cpuNano  int64
	memBytes int64
}

func fetchPodMetrics(ctx context.Context, cc *checks.ClusterContext) map[string]podMetric {
	result := map[string]podMetric{}

	data, err := cc.Client.Clientset().Discovery().RESTClient().Get().
		AbsPath("/apis/metrics.k8s.io/v1beta1/pods").DoRaw(ctx)
	if err != nil {
		return result
	}

	var pm struct {
		Items []struct {
			Metadata struct {
				Name      string `json:"name"`
				Namespace string `json:"namespace"`
			} `json:"metadata"`
			Containers []struct {
				Usage struct {
					CPU    string `json:"cpu"`
					Memory string `json:"memory"`
				} `json:"usage"`
			} `json:"containers"`
		} `json:"items"`
	}
	if json.Unmarshal(data, &pm) != nil {
		return result
	}

	for _, item := range pm.Items {
		key := item.Metadata.Namespace + "/" + item.Metadata.Name
		var totalCPU, totalMem int64
		for _, c := range item.Containers {
			cpuQ, err := resource.ParseQuantity(c.Usage.CPU)
			if err == nil {
				totalCPU += cpuQ.MilliValue() * 1000000 // to nanocores
			}
			memQ, err := resource.ParseQuantity(c.Usage.Memory)
			if err == nil {
				totalMem += memQ.Value()
			}
		}
		result[key] = podMetric{cpuNano: totalCPU, memBytes: totalMem}
	}
	return result
}

type nsDeployHealth struct {
	Namespace       string   `json:"namespace"`
	Total           int      `json:"total"`
	Healthy         int      `json:"healthy"`
	Degraded        int      `json:"degraded"`
	DegradedNames   []string `json:"degraded_names,omitempty"`
	AllDown         bool     `json:"all_down,omitempty"`
}

func checkDeploymentHealth(ctx context.Context, cc *checks.ClusterContext, hcpNamespaces []string) {
	cc.SetCheck("hcp_deployment_health")

	r := checks.Result{
		Check:    "hcp_deployment_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Checks Deployments in each HCP namespace for replica health, grouped by namespace. Distinguishes between a single HCP with all deployments down (likely hibernated/deprovisioning) vs scattered degradation across multiple HCPs.",
			"pass_criteria": "PASS: All Deployments at desired replicas. WARN: Partial degradation in some HCPs. FAIL: Multiple HCPs with scattered degradation.",
		},
	}

	if len(hcpNamespaces) == 0 {
		r.Status = checks.StatusInfo
		r.Severity = checks.SeverityInfo
		r.Message = "No HCP namespaces to check"
		cc.AddResult(r)
		return
	}

	totalDeploys := 0
	healthyDeploys := 0
	var nsHealthList []nsDeployHealth
	degradedNSCount := 0
	allDownNSCount := 0

	for _, ns := range hcpNamespaces {
		deploys, err := cc.Client.Clientset().AppsV1().Deployments(ns).List(ctx, metav1.ListOptions{})
		if err != nil {
			continue
		}

		nsh := nsDeployHealth{Namespace: ns}
		for i := range deploys.Items {
			d := &deploys.Items[i]
			nsh.Total++
			totalDeploys++
			desired := int32(1)
			if d.Spec.Replicas != nil {
				desired = *d.Spec.Replicas
			}
			if d.Status.ReadyReplicas >= desired {
				nsh.Healthy++
				healthyDeploys++
			} else {
				nsh.Degraded++
				nsh.DegradedNames = append(nsh.DegradedNames, fmt.Sprintf("%s (%d/%d)", d.Name, d.Status.ReadyReplicas, desired))
			}
		}

		if nsh.Degraded > 0 {
			degradedNSCount++
			if nsh.Healthy == 0 && nsh.Total > 0 {
				nsh.AllDown = true
				allDownNSCount++
			}
		}

		// Only include namespaces with issues in the detail list
		if nsh.Degraded > 0 {
			// Truncate degraded names list per namespace
			if len(nsh.DegradedNames) > 10 {
				nsh.DegradedNames = append(nsh.DegradedNames[:10], fmt.Sprintf("... and %d more", len(nsh.DegradedNames)-10))
			}
			nsHealthList = append(nsHealthList, nsh)
		}
	}

	r.Details["total_deployments"] = totalDeploys
	r.Details["healthy_deployments"] = healthyDeploys
	r.Details["total_namespaces"] = len(hcpNamespaces)
	r.Details["degraded_namespaces"] = degradedNSCount
	r.Details["all_down_namespaces"] = allDownNSCount
	if len(nsHealthList) > 0 {
		r.Details["namespace_health"] = nsHealthList
	}

	totalDegraded := totalDeploys - healthyDeploys

	switch {
	case degradedNSCount == 0:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d Deployments healthy across %d HCPs", totalDeploys, len(hcpNamespaces))
	case allDownNSCount == degradedNSCount:
		// All degradation is from HCPs with everything down — likely hibernated/deprovisioning
		r.Status = checks.StatusInfo
		r.Severity = checks.SeverityInfo
		r.Message = fmt.Sprintf("%d HCP(s) with all deployments down (likely hibernated or deprovisioning), %d healthy HCPs", allDownNSCount, len(hcpNamespaces)-degradedNSCount)
	case degradedNSCount > 3:
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("%d degraded Deployments across %d HCPs (%d all-down)", totalDegraded, degradedNSCount, allDownNSCount)
	default:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d degraded Deployments across %d HCP(s) (%d all-down, %d partial)", totalDegraded, degradedNSCount, allDownNSCount, degradedNSCount-allDownNSCount)
	}

	cc.AddResult(r)
}

func checkResourceTrends(ctx context.Context, cc *checks.ClusterContext, concerningPods []concerningPod) {
	cc.SetCheck("hcp_resource_trends")

	r := checks.Result{
		Check:    "hcp_resource_trends",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Queries 7-day memory and CPU timeseries for the top resource consumers in HCP namespaces. Only charts pods with concerning behavior to avoid bloating results with healthy pod data.",
			"pass_criteria": "INFO: Timeseries data collected for charting. SKIP: No concerning pods or metrics unavailable.",
			"lookback_hours": 168.0,
		},
	}

	if len(concerningPods) == 0 {
		r.Status = checks.StatusPass
		r.Message = "No concerning pods — resource trend charting not needed"
		cc.AddResult(r)
		return
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	now := time.Now().Unix()
	start := now - 604800
	step := 3600

	// Query per-pod, then aggregate by workload name in Go
	// The kube_pod_owner join approach fails with "duplicate series" errors
	memQuery := `sum by (namespace, pod) (container_memory_working_set_bytes{namespace=~"clusters-.*|ocm-.*",container!=""}) / 1048576`
	memData, memErr := cc.Client.QueryMetricsRange(ctx, memQuery, start, now, step)
	cc.RecordError("HCP pod memory trends", memErr)

	cpuQuery := `sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{namespace=~"clusters-.*|ocm-.*",container!=""}[5m])) * 1000`
	cpuData, cpuErr := cc.Client.QueryMetricsRange(ctx, cpuQuery, start, now, step)
	cc.RecordError("HCP pod CPU trends", cpuErr)

	workloadLabel := func(m map[string]string) string {
		if pod := m["pod"]; pod != "" {
			return podToWorkload(m["namespace"] + "/" + pod)
		}
		return "unknown"
	}

	seriesCount := 0

	aggregateByWorkload := func(allSeries []thanos.LabeledTimeseries) []thanos.LabeledTimeseries {
		workloadSeries := map[string]*thanos.LabeledTimeseries{}
		for _, s := range allSeries {
			wl := s.Label
			if existing, ok := workloadSeries[wl]; ok {
				existing.Values = sumTimeseries(existing.Values, s.Values)
			} else {
				cp := s
				workloadSeries[wl] = &cp
			}
		}
		result := make([]thanos.LabeledTimeseries, 0, len(workloadSeries))
		for _, s := range workloadSeries {
			result = append(result, *s)
		}
		sort.Slice(result, func(i, j int) bool {
			return thanos.Peak(result[i].Values) > thanos.Peak(result[j].Values)
		})
		if len(result) > 15 {
			result = result[:15]
		}
		return result
	}

	if memErr == nil && memData != "" {
		if allSeries, _ := thanos.PerSeriesTimeseries(memData, workloadLabel); len(allSeries) > 0 {
			aggregated := aggregateByWorkload(allSeries)
			if len(aggregated) > 0 {
				r.Details["memory_timeseries"] = aggregated
				seriesCount += len(aggregated)
			}
		}
	}

	if cpuErr == nil && cpuData != "" {
		if allSeries, _ := thanos.PerSeriesTimeseries(cpuData, workloadLabel); len(allSeries) > 0 {
			aggregated := aggregateByWorkload(allSeries)
			if len(aggregated) > 0 {
				r.Details["cpu_timeseries"] = aggregated
				seriesCount += len(aggregated)
			}
		}
	}

	// Query restart events for overlay on charts
	restartQuery := `changes(kube_pod_container_status_restarts_total{namespace=~"clusters-.*|ocm-.*"}[1h])`
	restartData, restartErr := cc.Client.QueryMetricsRange(ctx, restartQuery, start, now, step)
	if restartErr == nil && restartData != "" {
		type restartEvent struct {
			Timestamp int64  `json:"timestamp"`
			Workload  string `json:"workload"`
		}
		restartPodLabel := func(m map[string]string) string {
			return m["namespace"] + "/" + m["pod"]
		}
		var events []restartEvent
		if allSeries, _ := thanos.PerSeriesTimeseries(restartData, restartPodLabel); len(allSeries) > 0 {
			for _, s := range allSeries {
				wl := podToWorkload(s.Label)
				for _, pt := range s.Values {
					if pt[1] > 0 {
						events = append(events, restartEvent{Timestamp: int64(pt[0]), Workload: wl})
					}
				}
			}
		}
		if len(events) > 0 {
			// Deduplicate by workload+hour
			seen := map[string]bool{}
			var deduped []restartEvent
			for _, e := range events {
				key := fmt.Sprintf("%s-%d", e.Workload, e.Timestamp/3600)
				if !seen[key] {
					seen[key] = true
					deduped = append(deduped, e)
				}
			}
			if len(deduped) > 50 {
				deduped = deduped[:50]
			}
			r.Details["restart_events"] = deduped
			seriesCount += len(deduped)
		}
	}

	if seriesCount == 0 {
		r.Status = checks.StatusSkip
		r.Message = "No HCP resource timeseries available"
	} else {
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("Collected %d resource timeseries for %d concerning pods", seriesCount, len(concerningPods))
	}

	cc.AddResult(r)
}

func checkMetricsCoverage(ctx context.Context, cc *checks.ClusterContext, hcpNamespaces []string) {
	cc.SetCheck("hcp_metrics_coverage")

	r := checks.Result{
		Check:    "hcp_metrics_coverage",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Compares running pods in HCP namespaces against pods with Prometheus metrics to identify gaps in monitoring coverage. Pods without metrics are invisible to resource trending and alerting.",
			"pass_criteria": "PASS: All pods have metrics. WARN: Some pods missing metrics. INFO: Metrics unavailable.",
		},
	}

	if len(hcpNamespaces) == 0 || !cc.Client.CanQueryMetrics() {
		r.Status = checks.StatusSkip
		r.Message = "No HCP namespaces or metrics unavailable"
		cc.AddResult(r)
		return
	}

	// Collect all running pods from k8s API
	k8sPods := map[string]bool{}
	for _, ns := range hcpNamespaces {
		pods, err := cc.Client.Clientset().CoreV1().Pods(ns).List(ctx, metav1.ListOptions{
			FieldSelector: "status.phase=Running",
		})
		if err != nil {
			continue
		}
		for i := range pods.Items {
			key := pods.Items[i].Namespace + "/" + pods.Items[i].Name
			k8sPods[key] = true
		}
	}

	if len(k8sPods) == 0 {
		r.Status = checks.StatusSkip
		r.Message = "No running pods found in HCP namespaces"
		cc.AddResult(r)
		return
	}

	// Query Prometheus for pods with memory metrics
	metricsQuery := `count by (namespace, pod) (container_memory_working_set_bytes{namespace=~"clusters-.*|ocm-.*",container!=""})`
	metricsData, metricsErr := cc.Client.QueryMetrics(ctx, metricsQuery)
	cc.RecordError("HCP metrics coverage query", metricsErr)

	if metricsErr != nil || metricsData == "" {
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("%d running pods — could not verify metrics coverage", len(k8sPods))
		cc.AddResult(r)
		return
	}

	promPods := map[string]bool{}
	if resp, parseErr := thanos.Parse(metricsData); parseErr == nil {
		for _, result := range resp.Data.Result {
			ns := result.Metric["namespace"]
			pod := result.Metric["pod"]
			if ns != "" && pod != "" {
				promPods[ns+"/"+pod] = true
			}
		}
	}

	// Find pods without metrics
	var missing []string
	for pod := range k8sPods {
		if !promPods[pod] {
			missing = append(missing, pod)
		}
	}

	// Group missing by workload
	missingWorkloads := map[string]int{}
	for _, pod := range missing {
		wl := podToWorkload(pod)
		missingWorkloads[wl]++
	}

	r.Details["k8s_pod_count"] = len(k8sPods)
	r.Details["prometheus_pod_count"] = len(promPods)
	r.Details["missing_count"] = len(missing)
	if len(missingWorkloads) > 0 {
		r.Details["missing_workloads"] = missingWorkloads
	}

	coveragePct := 0
	if len(k8sPods) > 0 {
		coveragePct = (len(k8sPods) - len(missing)) * 100 / len(k8sPods)
	}
	r.Details["coverage_pct"] = coveragePct

	switch {
	case len(missing) == 0:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d HCP pods have Prometheus metrics (100%% coverage)", len(k8sPods))
	case coveragePct >= 90:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d/%d HCP pods have metrics (%d%% coverage), %d missing", len(k8sPods)-len(missing), len(k8sPods), coveragePct, len(missing))
	default:
		r.Status = checks.StatusWarning
		wlList := make([]string, 0, len(missingWorkloads))
		for wl, count := range missingWorkloads {
			wlList = append(wlList, fmt.Sprintf("%s(%d)", wl, count))
		}
		r.Message = fmt.Sprintf("%d/%d HCP pods missing metrics (%d%% coverage): %s", len(missing), len(k8sPods), coveragePct, strings.Join(wlList, ", "))
	}

	cc.AddResult(r)
}

func checkPodLogs(ctx context.Context, cc *checks.ClusterContext, concerningPods []concerningPod) {
	cc.SetCheck("hcp_pod_logs")

	r := checks.Result{
		Check:    "hcp_pod_logs",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Analyzes recent logs from concerning HCP pods for error patterns: OOM messages, connection failures, auth errors, crash indicators. Only checks pods flagged as concerning by hcp_pod_health. In production, logs may not be accessible — degrades to INFO.",
			"pass_criteria": "PASS: No error patterns in logs. WARN: Errors detected. INFO: Logs unavailable (production).",
		},
	}

	if len(concerningPods) == 0 {
		r.Status = checks.StatusPass
		r.Message = "No concerning pods to analyze logs for"
		cc.AddResult(r)
		return
	}

	// Limit to top 5 most concerning pods to avoid excessive log fetching
	logTargets := concerningPods
	if len(logTargets) > 5 {
		logTargets = logTargets[:5]
	}

	type logFinding struct {
		Pod    string   `json:"pod"`
		Errors int      `json:"errors"`
		Sample []string `json:"samples,omitempty"`
	}
	var findings []logFinding
	logsUnavailable := 0
	logFailReasons := map[string]int{}

	for _, cp := range logTargets {
		container := cp.Container

		// If no specific container, try default first, then pick first container on multi-container error
		var logOutput string
		var logErr error
		if container != "" {
			logOutput, logErr = cc.Client.GetContainerLogs(ctx, cp.Namespace, cp.Pod, container, 100)
		} else {
			logOutput, logErr = cc.Client.GetPodLogs(ctx, cp.Namespace, cp.Pod, 100)
			if logErr != nil && strings.Contains(logErr.Error(), "container name must be specified") {
				// Multi-container pod — look up pod and try the first non-init container
				pod, podErr := cc.Client.Clientset().CoreV1().Pods(cp.Namespace).Get(ctx, cp.Pod, metav1.GetOptions{})
				if podErr == nil && len(pod.Spec.Containers) > 0 {
					container = pod.Spec.Containers[0].Name
					logOutput, logErr = cc.Client.GetContainerLogs(ctx, cp.Namespace, cp.Pod, container, 100)
				}
			}
		}

		if logErr != nil {
			logsUnavailable++
			errMsg := logErr.Error()
			var reason string
			switch {
			case strings.Contains(errMsg, "Forbidden") || strings.Contains(errMsg, "forbidden"):
				reason = "RBAC denied"
			case strings.Contains(errMsg, "Unauthorized") || strings.Contains(errMsg, "401"):
				reason = "unauthorized"
			case strings.Contains(errMsg, "not found") || strings.Contains(errMsg, "NotFound"):
				reason = "pod not found"
			case strings.Contains(errMsg, "container name must be specified"):
				reason = "multi-container pod (no default)"
			case strings.Contains(errMsg, "container") && strings.Contains(errMsg, "not found"):
				reason = "container not found"
			case strings.Contains(errMsg, "timeout") || strings.Contains(errMsg, "Timeout"):
				reason = "timeout"
			default:
				reason = errMsg
				if len(reason) > 100 {
					reason = reason[:100] + "..."
				}
			}
			if logFailReasons[reason] == 0 {
				logFailReasons[reason] = 0
			}
			logFailReasons[reason]++
			continue
		}

		errorCount := 0
		var samples []string
		for _, line := range strings.Split(logOutput, "\n") {
			lower := strings.ToLower(line)
			if strings.Contains(lower, "error") || strings.Contains(lower, "oomkilled") ||
				strings.Contains(lower, "fatal") || strings.Contains(lower, "panic") ||
				strings.Contains(lower, "connection refused") || strings.Contains(lower, "timeout") {
				if !strings.Contains(lower, "level=info") && !strings.Contains(lower, `"level":"info"`) {
					errorCount++
					if len(samples) < 3 {
						truncated := line
						if len(truncated) > 200 {
							truncated = truncated[:200] + "..."
						}
						samples = append(samples, truncated)
					}
				}
			}
		}

		if errorCount > 0 {
			findings = append(findings, logFinding{
				Pod:    cp.Namespace + "/" + cp.Pod,
				Errors: errorCount,
				Sample: samples,
			})
		}
	}

	r.Details["pods_analyzed"] = len(logTargets)
	r.Details["logs_unavailable"] = logsUnavailable
	if len(findings) > 0 {
		r.Details["findings"] = findings
	}
	if len(logFailReasons) > 0 {
		r.Details["log_access_failures"] = logFailReasons
	}

	switch {
	case logsUnavailable == len(logTargets):
		r.Status = checks.StatusInfo
		r.Severity = checks.SeverityInfo
		reasons := make([]string, 0, len(logFailReasons))
		for reason, count := range logFailReasons {
			reasons = append(reasons, fmt.Sprintf("%s(%d)", reason, count))
		}
		r.Message = fmt.Sprintf("Pod logs unavailable for %d pod(s): %s", logsUnavailable, strings.Join(reasons, ", "))
	case len(findings) > 0:
		totalErrors := 0
		for _, f := range findings {
			totalErrors += f.Errors
		}
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d errors in logs from %d/%d concerning pods", totalErrors, len(findings), len(logTargets))
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("No error patterns in logs from %d concerning pods", len(logTargets))
	}

	cc.AddResult(r)
}

// podToWorkload extracts the workload name from a "namespace/pod-name" string.
// Strips Deployment replicaset hash and pod hash suffixes:
//
//	"clusters-foo/metrics-proxy-75fb766969-4qmtv" → "metrics-proxy"
//	"clusters-foo/kube-apiserver-abc123def-xyz" → "kube-apiserver"
func podToWorkload(nsPod string) string {
	parts := strings.SplitN(nsPod, "/", 2)
	podName := nsPod
	if len(parts) == 2 {
		podName = parts[1]
	}

	segments := strings.Split(podName, "-")
	if len(segments) >= 3 {
		last := segments[len(segments)-1]
		secondLast := segments[len(segments)-2]
		// Deployment: name-<replicaset-hash>-<pod-hash>
		if looksLikeHash(last) && looksLikeHash(secondLast) {
			return strings.Join(segments[:len(segments)-2], "-")
		}
		// Single hash suffix (DaemonSet, Job)
		if looksLikeHash(last) {
			return strings.Join(segments[:len(segments)-1], "-")
		}
	}
	if len(segments) >= 2 {
		last := segments[len(segments)-1]
		// StatefulSet ordinal: name-0, name-1, name-2
		isOrdinal := true
		for _, c := range last {
			if c < '0' || c > '9' {
				isOrdinal = false
				break
			}
		}
		if isOrdinal {
			return strings.Join(segments[:len(segments)-1], "-")
		}
	}
	return podName
}

func looksLikeHash(s string) bool {
	if len(s) < 4 {
		return false
	}
	for _, c := range s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z')) {
			return false
		}
	}
	return true
}

// sumTimeseries adds two timeseries together by matching timestamps.
func sumTimeseries(a, b [][2]float64) [][2]float64 {
	byTS := map[float64]float64{}
	for _, p := range a {
		byTS[p[0]] = p[1]
	}
	for _, p := range b {
		byTS[p[0]] += p[1]
	}
	result := make([][2]float64, 0, len(byTS))
	for ts, val := range byTS {
		result = append(result, [2]float64{ts, val})
	}
	sort.Slice(result, func(i, j int) bool { return result[i][0] < result[j][0] })
	return result
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
