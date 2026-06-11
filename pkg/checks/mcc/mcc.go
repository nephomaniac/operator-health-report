package mcc

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
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
	checks.Register(&MCCChecker{})
}

type MCCChecker struct{}

func (c *MCCChecker) Name() string { return "cluster" }

var (
	machineSetGVR = schema.GroupVersionResource{
		Group: "machine.openshift.io", Version: "v1beta1", Resource: "machinesets",
	}
	machineGVR = schema.GroupVersionResource{
		Group: "machine.openshift.io", Version: "v1beta1", Resource: "machines",
	}
	machineConfigurationGVR = schema.GroupVersionResource{
		Group: "operator.openshift.io", Version: "v1", Resource: "machineconfigurations",
	}
)

const (
	machineAPINamespace = "openshift-machine-api"
	allowedAMIsURL      = "https://raw.githubusercontent.com/openshift/machine-config-operator/main/pkg/controller/bootimage/ami.go"
)

var (
	allowedAMIs     map[string]bool
	allowedAMIsOnce sync.Once
	allowedAMIsErr  error
	amiPattern      = regexp.MustCompile(`"(ami-[a-f0-9]+)"`)
)

// isAllowedAMI checks if an AMI is in the MCO AllowedAMIs list.
// Lazy-loads the list from GitHub on first call.
func isAllowedAMI(amiID string) (allowed bool, listAvailable bool) {
	allowedAMIsOnce.Do(func() {
		log := logging.Log
		log.Debug("Fetching MCO AllowedAMIs list from GitHub")
		client := &http.Client{Timeout: 15 * time.Second}
		resp, err := client.Get(allowedAMIsURL)
		if err != nil {
			allowedAMIsErr = err
			log.WithError(err).Debug("Failed to fetch AllowedAMIs")
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			allowedAMIsErr = fmt.Errorf("GitHub returned %d", resp.StatusCode)
			log.WithField("status", resp.StatusCode).Debug("Failed to fetch AllowedAMIs")
			return
		}
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			allowedAMIsErr = err
			return
		}
		matches := amiPattern.FindAllStringSubmatch(string(body), -1)
		allowedAMIs = make(map[string]bool, len(matches))
		for _, m := range matches {
			allowedAMIs[m[1]] = true
		}
		log.WithField("count", len(allowedAMIs)).Debug("Loaded MCO AllowedAMIs list")
	})
	if allowedAMIsErr != nil || allowedAMIs == nil {
		return false, false
	}
	return allowedAMIs[amiID], true
}

func (c *MCCChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	checkNodeHealth(ctx, cc)
	checkNodeResources(ctx, cc)
	checkNodeCounts(ctx, cc)
	checkNodePodFailures(ctx, cc)

	checkNodeMetricsTrends(ctx, cc)
	checkMachineAPILogs(ctx, cc)

	if cc.Metadata != nil && strings.EqualFold(cc.Metadata.Provider, "aws") {
		checkMachineHealth(ctx, cc)
		checkManagedBootImages(ctx, cc)
		checkAMIConsistency(ctx, cc)
	}
}

func nodeRole(node *corev1.Node) string {
	roles := map[string]bool{}
	for label := range node.Labels {
		if strings.HasPrefix(label, "node-role.kubernetes.io/") {
			roles[strings.TrimPrefix(label, "node-role.kubernetes.io/")] = true
		}
	}
	// Priority: master/control-plane > infra > worker
	if roles["master"] || roles["control-plane"] {
		return "master"
	}
	if roles["infra"] {
		return "infra"
	}
	if roles["worker"] {
		return "worker"
	}
	if len(roles) > 0 {
		for r := range roles {
			return r
		}
	}
	return "worker"
}

func checkNodeHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("mcc_node_health")

	r := checks.Result{
		Check:    "mcc_node_health",
		Severity: checks.SeverityCritical,
		Details: map[string]any{
			"description":   "Checks all cluster nodes for Ready condition, pressure conditions (MemoryPressure, DiskPressure, PIDPressure, NetworkUnavailable), and unschedulable (cordoned) state.",
			"pass_criteria": "PASS: All nodes Ready with no pressure conditions. WARN: Any node not Ready or has pressure. FAIL: Multiple nodes not Ready.",
		},
	}

	nodes, err := cc.Client.Clientset().CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	cc.RecordError("List nodes", err)
	if err != nil {
		if checks.IsAccessError(err) {
			r.Status = checks.StatusAccessDenied
			r.Severity = checks.SeverityInfo
			r.Message = "Cannot list nodes — insufficient permissions"
		} else {
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("Failed to list nodes: %v", err)
		}
		cc.AddResult(r)
		return
	}

	totalNodes := len(nodes.Items)
	readyCount := 0
	notReadyNodes := []string{}
	pressureNodes := []string{}
	cordonedNodes := []string{}

	type nodeSummary struct {
		Name        string `json:"name"`
		Role        string `json:"role"`
		Ready       bool   `json:"ready"`
		Cordoned    bool   `json:"cordoned"`
		Pressures   []string `json:"pressures,omitempty"`
	}
	var summaries []nodeSummary

	for i := range nodes.Items {
		node := &nodes.Items[i]
		role := nodeRole(node)
		ns := nodeSummary{
			Name: node.Name,
			Role: role,
		}

		if node.Spec.Unschedulable {
			cordonedNodes = append(cordonedNodes, node.Name)
			ns.Cordoned = true
		}

		for _, cond := range node.Status.Conditions {
			switch cond.Type {
			case corev1.NodeReady:
				if cond.Status == corev1.ConditionTrue {
					readyCount++
					ns.Ready = true
				} else {
					notReadyNodes = append(notReadyNodes, node.Name)
				}
			case corev1.NodeMemoryPressure, corev1.NodeDiskPressure, corev1.NodePIDPressure, corev1.NodeNetworkUnavailable:
				if cond.Status == corev1.ConditionTrue {
					pressureNodes = append(pressureNodes, fmt.Sprintf("%s(%s)", node.Name, cond.Type))
					ns.Pressures = append(ns.Pressures, string(cond.Type))
				}
			}
		}
		summaries = append(summaries, ns)
	}

	r.Details["total_nodes"] = totalNodes
	r.Details["ready"] = readyCount
	r.Details["not_ready"] = len(notReadyNodes)
	r.Details["cordoned"] = len(cordonedNodes)
	r.Details["pressure_count"] = len(pressureNodes)
	if len(notReadyNodes) > 0 {
		r.Details["not_ready_nodes"] = notReadyNodes
	}
	if len(pressureNodes) > 0 {
		r.Details["pressure_nodes"] = pressureNodes
	}
	if len(cordonedNodes) > 0 {
		r.Details["cordoned_nodes"] = cordonedNodes
	}
	r.Details["nodes"] = summaries

	switch {
	case len(notReadyNodes) > 1:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("%d/%d nodes not Ready: %s", len(notReadyNodes), totalNodes, strings.Join(notReadyNodes, ", "))
	case len(notReadyNodes) == 1:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("1/%d nodes not Ready: %s", totalNodes, notReadyNodes[0])
	case len(pressureNodes) > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("All %d nodes Ready but %d have pressure conditions", totalNodes, len(pressureNodes))
	case len(cordonedNodes) > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("All %d nodes Ready, %d cordoned", totalNodes, len(cordonedNodes))
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("All %d nodes Ready", totalNodes)
	}

	cc.AddResult(r)
}

func checkNodeResources(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("mcc_node_resources")

	r := checks.Result{
		Check:    "mcc_node_resources",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Reports node capacity, allocatable resources, kubelet version distribution, and node age. Flags mixed kubelet versions (upgrade in progress) and old nodes.",
			"pass_criteria": "PASS: All nodes on same kubelet version. WARN: Mixed versions or nodes older than 90 days. INFO: Resource summary.",
		},
	}

	nodes, err := cc.Client.Clientset().CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = "Could not list nodes"
		cc.AddResult(r)
		return
	}

	kubeletVersions := map[string]int{}
	roleCounts := map[string]int{}
	var oldestAge, newestAge time.Duration
	now := time.Now()

	type nodeResourceInfo struct {
		Name      string `json:"name"`
		Role      string `json:"role"`
		Kubelet   string `json:"kubelet"`
		AgeDays   int    `json:"age_days"`
		CPUCap    string `json:"cpu_capacity"`
		MemCapGB  string `json:"mem_capacity_gb"`
		CPUPct    int    `json:"cpu_pct,omitempty"`
		MemPct    int    `json:"mem_pct,omitempty"`
	}

	// Query current CPU and memory utilization via metrics API (oc adm top nodes equivalent)
	cpuByNode := map[string]int{}
	memByNode := map[string]int{}
	metricsData, metricsErr := cc.Client.Clientset().Discovery().RESTClient().Get().
		AbsPath("/apis/metrics.k8s.io/v1beta1/nodes").DoRaw(ctx)
	if metricsErr == nil {
		var nodeMetrics struct {
			Items []struct {
				Metadata struct{ Name string } `json:"metadata"`
				Usage    struct {
					CPU    string `json:"cpu"`
					Memory string `json:"memory"`
				} `json:"usage"`
			} `json:"items"`
		}
		if json.Unmarshal(metricsData, &nodeMetrics) == nil {
			for _, nm := range nodeMetrics.Items {
				// Parse CPU (e.g., "1234567890n" nanocores → percentage of capacity)
				cpuUsageNano := int64(0)
				cpuStr := strings.TrimSuffix(nm.Usage.CPU, "n")
				fmt.Sscanf(cpuStr, "%d", &cpuUsageNano)

				// Parse Memory (e.g., "12345Ki" → bytes)
				memUsageBytes := int64(0)
				memStr := nm.Usage.Memory
				if strings.HasSuffix(memStr, "Ki") {
					var ki int64
					fmt.Sscanf(strings.TrimSuffix(memStr, "Ki"), "%d", &ki)
					memUsageBytes = ki * 1024
				} else if strings.HasSuffix(memStr, "Mi") {
					var mi int64
					fmt.Sscanf(strings.TrimSuffix(memStr, "Mi"), "%d", &mi)
					memUsageBytes = mi * 1024 * 1024
				} else if strings.HasSuffix(memStr, "Gi") {
					var gi int64
					fmt.Sscanf(strings.TrimSuffix(memStr, "Gi"), "%d", &gi)
					memUsageBytes = gi * 1024 * 1024 * 1024
				}

				// Find matching node for capacity
				for j := range nodes.Items {
					if nodes.Items[j].Name == nm.Metadata.Name {
						cpuCapMillis := nodes.Items[j].Status.Capacity.Cpu().MilliValue()
						if cpuCapMillis > 0 {
							cpuByNode[nm.Metadata.Name] = int((cpuUsageNano / 1000000) * 100 / cpuCapMillis)
						}
						memCapBytes := nodes.Items[j].Status.Capacity.Memory().Value()
						if memCapBytes > 0 {
							memByNode[nm.Metadata.Name] = int(memUsageBytes * 100 / memCapBytes)
						}
						break
					}
				}
			}
		}
	}

	var nodeInfos []nodeResourceInfo

	for i := range nodes.Items {
		node := &nodes.Items[i]
		role := nodeRole(node)
		roleCounts[role]++

		ver := node.Status.NodeInfo.KubeletVersion
		kubeletVersions[ver]++

		age := now.Sub(node.CreationTimestamp.Time)
		if oldestAge == 0 || age > oldestAge {
			oldestAge = age
		}
		if newestAge == 0 || age < newestAge {
			newestAge = age
		}

		cpuCap := node.Status.Capacity.Cpu().String()
		memBytes := node.Status.Capacity.Memory().Value()
		memGB := fmt.Sprintf("%.1f", float64(memBytes)/(1024*1024*1024))

		ni := nodeResourceInfo{
			Name:     node.Name,
			Role:     role,
			Kubelet:  ver,
			AgeDays:  int(age.Hours() / 24),
			CPUCap:   cpuCap,
			MemCapGB: memGB + " GB",
		}
		if pct, ok := cpuByNode[node.Name]; ok {
			ni.CPUPct = pct
		}
		if pct, ok := memByNode[node.Name]; ok {
			ni.MemPct = pct
		}
		nodeInfos = append(nodeInfos, ni)
	}

	// Build per-role utilization summaries for table columns
	type roleUtil struct {
		CPUs []int `json:"cpu_pcts"`
		Mems []int `json:"mem_pcts"`
	}
	roleUtils := map[string]*roleUtil{}
	for _, ni := range nodeInfos {
		role := ni.Role
		if role == "control-plane" {
			role = "master"
		}
		if roleUtils[role] == nil {
			roleUtils[role] = &roleUtil{}
		}
		roleUtils[role].CPUs = append(roleUtils[role].CPUs, ni.CPUPct)
		roleUtils[role].Mems = append(roleUtils[role].Mems, ni.MemPct)
	}
	r.Details["role_utilization"] = roleUtils

	r.Details["node_count"] = len(nodes.Items)
	r.Details["role_counts"] = roleCounts
	r.Details["kubelet_versions"] = kubeletVersions
	r.Details["oldest_node_days"] = int(oldestAge.Hours() / 24)
	r.Details["newest_node_days"] = int(newestAge.Hours() / 24)
	r.Details["node_resources"] = nodeInfos

	switch {
	case len(kubeletVersions) > 1:
		versions := make([]string, 0, len(kubeletVersions))
		for v, c := range kubeletVersions {
			versions = append(versions, fmt.Sprintf("%s(%d)", v, c))
		}
		r.Status = checks.StatusWarning
		r.Severity = checks.SeverityWarning
		r.Message = fmt.Sprintf("Mixed kubelet versions (upgrade in progress?): %s", strings.Join(versions, ", "))
	case int(oldestAge.Hours()/24) > 90:
		r.Status = checks.StatusInfo
		r.Message = fmt.Sprintf("%d nodes, oldest %d days, kubelet %s",
			len(nodes.Items), int(oldestAge.Hours()/24), firstKey(kubeletVersions))
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d nodes, kubelet %s, age %d-%d days",
			len(nodes.Items), firstKey(kubeletVersions), int(newestAge.Hours()/24), int(oldestAge.Hours()/24))
	}

	cc.AddResult(r)
}

func checkNodeCounts(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("mcc_node_counts")

	r := checks.Result{
		Check:    "mcc_node_counts",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates that the cluster has the expected number of master, infra, and worker nodes based on cluster type and availability zone configuration. Masters should always be 3 for HA. Infra minimum is 2 (single-AZ) or 3 (multi-AZ). Worker minimum is 2 (single-AZ) or 3 (multi-AZ).",
			"pass_criteria": "PASS: All role counts meet minimums. WARN: Below minimum for any role. FAIL: Missing masters.",
		},
	}

	nodes, err := cc.Client.Clientset().CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = "Could not list nodes"
		cc.AddResult(r)
		return
	}

	roleCounts := map[string]int{}
	for i := range nodes.Items {
		role := nodeRole(&nodes.Items[i])
		roleCounts[role]++
	}

	masterCount := roleCounts["master"] + roleCounts["control-plane"]
	infraCount := roleCounts["infra"]
	workerCount := roleCounts["worker"]

	multiAZ := false
	if cc.Metadata != nil {
		multiAZ = cc.Metadata.MultiAZ
	}

	// MC/SC clusters have different expectations
	isMCSC := cc.ClusterType == "management_cluster" || cc.ClusterType == "service_cluster"

	expectedMasters := 3
	expectedInfraMin := 2
	expectedWorkerMin := 2
	if multiAZ {
		expectedInfraMin = 3
		expectedWorkerMin = 3
	}
	if isMCSC {
		expectedWorkerMin = 3
	}

	r.Details["master_count"] = masterCount
	r.Details["infra_count"] = infraCount
	r.Details["worker_count"] = workerCount
	r.Details["multi_az"] = multiAZ
	r.Details["cluster_type"] = cc.ClusterType
	r.Details["expected_masters"] = expectedMasters
	r.Details["expected_infra_min"] = expectedInfraMin
	r.Details["expected_worker_min"] = expectedWorkerMin

	var issues []string

	if masterCount < expectedMasters {
		issues = append(issues, fmt.Sprintf("masters: %d/%d", masterCount, expectedMasters))
	}
	if infraCount < expectedInfraMin && !isMCSC {
		issues = append(issues, fmt.Sprintf("infra: %d (min %d)", infraCount, expectedInfraMin))
	}
	if workerCount < expectedWorkerMin {
		issues = append(issues, fmt.Sprintf("workers: %d (min %d)", workerCount, expectedWorkerMin))
	}

	switch {
	case masterCount < expectedMasters:
		r.Status = checks.StatusFail
		r.Message = fmt.Sprintf("Node count issue — %s", strings.Join(issues, ", "))
	case len(issues) > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Node count below minimum — %s", strings.Join(issues, ", "))
	default:
		azLabel := "single-AZ"
		if multiAZ {
			azLabel = "multi-AZ"
		}
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d master, %d infra, %d worker (%s)", masterCount, infraCount, workerCount, azLabel)
	}

	cc.AddResult(r)
}

func checkNodePodFailures(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("mcc_node_pod_failures")

	r := checks.Result{
		Check:    "mcc_node_pod_failures",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Counts failed and pending pods per node to detect nodes with systemic issues (disk full, network problems, kubelet issues).",
			"pass_criteria": "PASS: No failed pods. WARN: Failed or stuck pending pods detected on any node.",
		},
	}

	pods, err := cc.Client.Clientset().CoreV1().Pods("").List(ctx, metav1.ListOptions{
		FieldSelector: "status.phase!=Running,status.phase!=Succeeded",
	})
	cc.RecordError("List non-running pods", err)
	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = "Could not list pods"
		cc.AddResult(r)
		return
	}

	failedByNode := map[string]int{}
	pendingByNode := map[string]int{}
	for i := range pods.Items {
		pod := &pods.Items[i]
		nodeName := pod.Spec.NodeName
		if nodeName == "" {
			nodeName = "(unscheduled)"
		}
		switch pod.Status.Phase {
		case corev1.PodFailed:
			failedByNode[nodeName]++
		case corev1.PodPending:
			pendingByNode[nodeName]++
		}
	}

	totalFailed := 0
	for _, c := range failedByNode {
		totalFailed += c
	}
	totalPending := 0
	for _, c := range pendingByNode {
		totalPending += c
	}

	r.Details["failed_pods_total"] = totalFailed
	r.Details["pending_pods_total"] = totalPending
	if totalFailed > 0 {
		r.Details["failed_by_node"] = failedByNode
	}
	if totalPending > 0 {
		r.Details["pending_by_node"] = pendingByNode
	}

	switch {
	case totalFailed > 0:
		r.Status = checks.StatusWarning
		nodes := make([]string, 0, len(failedByNode))
		for n, c := range failedByNode {
			nodes = append(nodes, fmt.Sprintf("%s(%d)", n, c))
		}
		r.Message = fmt.Sprintf("%d failed pods across %d node(s): %s", totalFailed, len(failedByNode), strings.Join(nodes, ", "))
	case totalPending > 5:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d pending pods", totalPending)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("No failed pods, %d pending", totalPending)
	}

	cc.AddResult(r)
}

func checkMachineHealth(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("mcc_machine_health")

	r := checks.Result{
		Check:    "mcc_machine_health",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     machineAPINamespace,
			"description":   "Checks Machine and MachineSet resources for health: MachineSet replica counts, Machine phases (Running/Provisioning/Failed/Deleting), and AMI IDs.",
			"pass_criteria": "PASS: All MachineSets at desired count, all Machines Running. WARN: Machines not Running or replicas mismatched.",
		},
	}

	msList, msErr := cc.Client.ListResources(ctx, machineSetGVR, machineAPINamespace, false)
	if msErr != nil && checks.IsAccessError(msErr) && cc.Client.CanElevate() {
		msList, msErr = cc.Client.ListResources(ctx, machineSetGVR, machineAPINamespace, true)
	}
	cc.RecordError("List MachineSets", msErr)
	if msErr != nil {
		if checks.IsAccessError(msErr) {
			r.Status = checks.StatusAccessDenied
			r.Severity = checks.SeverityInfo
			r.Message = "Cannot list MachineSets — insufficient permissions"
		} else {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("Failed to list MachineSets: %v", msErr)
		}
		cc.AddResult(r)
		return
	}

	type machineSetInfo struct {
		Name     string `json:"name"`
		Desired  int64  `json:"desired"`
		Ready    int64  `json:"ready"`
		AMI      string `json:"ami,omitempty"`
	}
	var msInfos []machineSetInfo
	totalDesired := int64(0)
	totalReady := int64(0)

	for _, item := range msList.Items {
		name := item.GetName()
		desired, _, _ := unstructured.NestedInt64(item.Object, "spec", "replicas")
		ready, _, _ := unstructured.NestedInt64(item.Object, "status", "readyReplicas")
		ami, _, _ := unstructured.NestedString(item.Object, "spec", "template", "spec", "providerSpec", "value", "ami", "id")

		totalDesired += desired
		totalReady += ready
		msInfos = append(msInfos, machineSetInfo{Name: name, Desired: desired, Ready: ready, AMI: ami})
	}

	// List Machines for phase info
	machineList, mErr := cc.Client.ListResources(ctx, machineGVR, machineAPINamespace, false)
	if mErr != nil && checks.IsAccessError(mErr) && cc.Client.CanElevate() {
		machineList, mErr = cc.Client.ListResources(ctx, machineGVR, machineAPINamespace, true)
	}

	phaseCounts := map[string]int{}
	if mErr == nil {
		for _, item := range machineList.Items {
			phase, _, _ := unstructured.NestedString(item.Object, "status", "phase")
			if phase == "" {
				phase = "Unknown"
			}
			phaseCounts[phase]++
		}
	}

	r.Details["machinesets"] = msInfos
	r.Details["total_desired"] = totalDesired
	r.Details["total_ready"] = totalReady
	r.Details["machine_phases"] = phaseCounts

	failedMachines := phaseCounts["Failed"]
	provisioningMachines := phaseCounts["Provisioning"]

	switch {
	case failedMachines > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d MachineSets, %d/%d ready, %d machines Failed", len(msInfos), totalReady, totalDesired, failedMachines)
	case totalReady < totalDesired:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d MachineSets, %d/%d ready (%d provisioning)", len(msInfos), totalReady, totalDesired, provisioningMachines)
	default:
		r.Status = checks.StatusPass
		r.Message = fmt.Sprintf("%d MachineSets, %d/%d machines ready", len(msInfos), totalReady, totalDesired)
	}

	cc.AddResult(r)
}

func checkManagedBootImages(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("mcc_managed_boot_images")

	r := checks.Result{
		Check:    "mcc_managed_boot_images",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Validates MachineConfiguration managed boot images state against expected configuration based on cluster product, provider, and version. OSD AWS 4.19+ should have managed boot images enabled; ROSA and OSD AWS 4.18 should have them disabled.",
			"pass_criteria": "PASS: State matches expected. WARN: State doesn't match expected. INFO: Not applicable for this cluster type/version.",
		},
	}

	product := ""
	version := ""
	if cc.Metadata != nil {
		product = strings.ToLower(cc.Metadata.Product)
		version = cc.ClusterVersion
	}

	// Determine expected state
	type expectedState int
	const (
		stateNA       expectedState = iota
		stateDisabled
		stateEnabled
	)

	expected := stateNA
	reason := ""

	major, minor := parseVersion(version)
	switch {
	case major < 4 || (major == 4 && minor < 18):
		expected = stateNA
		reason = fmt.Sprintf("version %s is below 4.18", version)
	case product == "rosa":
		expected = stateDisabled
		reason = "ROSA clusters keep managed boot images disabled"
	case major == 4 && minor == 18:
		expected = stateDisabled
		reason = "OSD AWS 4.18 is transitional — disabled"
	case major == 4 && minor >= 19:
		expected = stateEnabled
		reason = "OSD AWS 4.19+ should have managed boot images enabled"
	}

	r.Details["product"] = product
	r.Details["version"] = version
	r.Details["expected_reason"] = reason

	if expected == stateNA {
		r.Status = checks.StatusInfo
		r.Severity = checks.SeverityInfo
		r.Message = fmt.Sprintf("Managed boot images not applicable — %s", reason)
		cc.AddResult(r)
		return
	}

	mcRes, mcErr := cc.Client.GetResource(ctx, machineConfigurationGVR, "", "cluster", false)
	if mcErr != nil && checks.IsAccessError(mcErr) && cc.Client.CanElevate() {
		mcRes, mcErr = cc.Client.GetResource(ctx, machineConfigurationGVR, "", "cluster", true)
	}
	cc.RecordError("Get MachineConfiguration/cluster", mcErr)
	if mcErr != nil {
		if checks.IsAccessError(mcErr) {
			r.Status = checks.StatusAccessDenied
			r.Severity = checks.SeverityInfo
			r.Message = "Cannot read MachineConfiguration — insufficient permissions"
		} else {
			r.Status = checks.StatusSkip
			r.Message = fmt.Sprintf("Could not read MachineConfiguration: %v", mcErr)
		}
		cc.AddResult(r)
		return
	}

	managers, found, _ := unstructured.NestedSlice(mcRes.Object, "spec", "managedBootImages", "machineManagers")
	isEnabled := found && len(managers) > 0
	r.Details["managed_boot_images_enabled"] = isEnabled
	r.Details["machine_managers_count"] = len(managers)
	r.Details["resource"] = "MachineConfiguration/cluster (operator.openshift.io/v1)"
	r.Details["field_path"] = ".spec.managedBootImages.machineManagers"

	if isEnabled && len(managers) > 0 {
		r.Details["machine_managers"] = managers
	} else {
		r.Details["machine_managers"] = "[] (empty — managed boot images disabled)"
	}

	// MCO status conditions for boot image updates
	conditions, _, _ := unstructured.NestedSlice(mcRes.Object, "status", "conditions")
	for _, cond := range conditions {
		condMap, ok := cond.(map[string]any)
		if !ok {
			continue
		}
		condType, _ := condMap["type"].(string)
		condStatus, _ := condMap["status"].(string)
		condMsg, _ := condMap["message"].(string)
		switch condType {
		case "BootImageUpdateProgressing":
			r.Details["boot_image_progressing"] = condStatus
			r.Details["boot_image_progressing_message"] = condMsg
		case "BootImageUpdateDegraded":
			r.Details["boot_image_degraded"] = condStatus
			if condStatus == "True" {
				r.Details["boot_image_degraded_message"] = condMsg
			}
		}
	}

	// Read coreos-bootimages ConfigMap for expected AMI
	expectedAMI := resolveExpectedAMI(ctx, cc)
	if expectedAMI != "" {
		r.Details["expected_ami"] = expectedAMI
	}

	// Compare MachineSet AMIs against expected
	if expectedAMI != "" {
		msList, msErr := cc.Client.ListResources(ctx, machineSetGVR, machineAPINamespace, false)
		if msErr == nil {
			matchCount := 0
			mismatchCount := 0
			for _, item := range msList.Items {
				ami, _, _ := unstructured.NestedString(item.Object, "spec", "template", "spec", "providerSpec", "value", "ami", "id")
				if ami == expectedAMI {
					matchCount++
				} else if ami != "" {
					mismatchCount++
				}
			}
			r.Details["machinesets_on_expected_ami"] = matchCount
			r.Details["machinesets_on_old_ami"] = mismatchCount
			if mismatchCount > 0 && isEnabled {
				r.Details["boot_image_update_pending"] = true
			}
		}
	}

	expectedLabel := "disabled"
	if expected == stateEnabled {
		expectedLabel = "enabled"
	}
	r.Details["expected_state"] = expectedLabel
	r.Details["actual_state"] = map[bool]string{true: "enabled", false: "disabled"}[isEnabled]

	switch expected {
	case stateEnabled:
		if isEnabled {
			degraded, _ := r.Details["boot_image_degraded"].(string)
			if degraded == "True" {
				r.Status = checks.StatusWarning
				r.Message = "Managed boot images enabled but MCO reports BootImageUpdateDegraded"
			} else {
				r.Status = checks.StatusPass
				r.Message = fmt.Sprintf("Managed boot images enabled as expected — %s", reason)
			}
		} else {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("Managed boot images disabled but expected enabled — %s", reason)
		}
	case stateDisabled:
		if !isEnabled {
			r.Status = checks.StatusPass
			r.Message = fmt.Sprintf("Managed boot images disabled as expected — %s", reason)
		} else {
			r.Status = checks.StatusWarning
			r.Message = fmt.Sprintf("Managed boot images enabled but expected disabled — %s", reason)
		}
	}

	cc.AddResult(r)
}

// resolveExpectedAMI reads the coreos-bootimages ConfigMap to find the expected AMI for this cluster's region.
func resolveExpectedAMI(ctx context.Context, cc *checks.ClusterContext) string {
	cm, err := cc.Client.Clientset().CoreV1().ConfigMaps("openshift-machine-config-operator").Get(ctx, "coreos-bootimages", metav1.GetOptions{})
	if err != nil {
		return ""
	}
	streamData, ok := cm.Data["stream"]
	if !ok || streamData == "" {
		return ""
	}

	region := ""
	if cc.Metadata != nil {
		region = cc.Metadata.Region
	}
	if region == "" {
		return ""
	}

	var stream struct {
		Architectures map[string]struct {
			Images struct {
				AWS struct {
					Regions map[string]struct {
						Image string `json:"image"`
					} `json:"regions"`
				} `json:"aws"`
			} `json:"images"`
		} `json:"architectures"`
	}

	if err := json.Unmarshal([]byte(streamData), &stream); err != nil {
		return ""
	}

	if arch, ok := stream.Architectures["x86_64"]; ok {
		if regionData, ok := arch.Images.AWS.Regions[region]; ok {
			return regionData.Image
		}
	}
	if arch, ok := stream.Architectures["aarch64"]; ok {
		if regionData, ok := arch.Images.AWS.Regions[region]; ok {
			return regionData.Image
		}
	}

	return ""
}

func checkAMIConsistency(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("mcc_ami_consistency")

	r := checks.Result{
		Check:    "mcc_ami_consistency",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Compares AMI IDs across MachineSets and Machines against the expected boot image from the coreos-bootimages ConfigMap. Flags MachineSets on old AMIs and Machines that don't match their MachineSet.",
			"pass_criteria": "PASS: All AMIs match expected. WARN: Mixed AMIs or old boot images detected.",
		},
	}

	expectedAMI := resolveExpectedAMI(ctx, cc)
	if expectedAMI != "" {
		r.Details["expected_ami"] = expectedAMI
	}

	msList, msErr := cc.Client.ListResources(ctx, machineSetGVR, machineAPINamespace, false)
	if msErr != nil && checks.IsAccessError(msErr) && cc.Client.CanElevate() {
		msList, msErr = cc.Client.ListResources(ctx, machineSetGVR, machineAPINamespace, true)
	}
	if msErr != nil {
		r.Status = checks.StatusSkip
		r.Message = "Could not list MachineSets"
		cc.AddResult(r)
		return
	}

	amiCounts := map[string]int{}
	msAMIs := map[string]string{}
	for _, item := range msList.Items {
		ami, _, _ := unstructured.NestedString(item.Object, "spec", "template", "spec", "providerSpec", "value", "ami", "id")
		if ami != "" {
			amiCounts[ami]++
			msAMIs[item.GetName()] = ami
		}
	}

	r.Details["unique_amis"] = len(amiCounts)
	r.Details["ami_distribution"] = amiCounts
	r.Details["machineset_amis"] = msAMIs

	// Check Machines for AMI mismatch against their MachineSet
	machineList, mErr := cc.Client.ListResources(ctx, machineGVR, machineAPINamespace, false)
	if mErr != nil && checks.IsAccessError(mErr) && cc.Client.CanElevate() {
		machineList, mErr = cc.Client.ListResources(ctx, machineGVR, machineAPINamespace, true)
	}

	machineAMIMismatch := 0
	if mErr == nil {
		for _, item := range machineList.Items {
			machineAMI, _, _ := unstructured.NestedString(item.Object, "spec", "providerSpec", "value", "ami", "id")
			owners, _, _ := unstructured.NestedSlice(item.Object, "metadata", "ownerReferences")
			for _, owner := range owners {
				ownerMap, ok := owner.(map[string]any)
				if !ok {
					continue
				}
				ownerName, _ := ownerMap["name"].(string)
				if msAMI, exists := msAMIs[ownerName]; exists && machineAMI != msAMI {
					machineAMIMismatch++
				}
			}
		}
	}
	r.Details["machine_ami_mismatches"] = machineAMIMismatch

	// Determine product type for AMI context
	isROSA := cc.Metadata != nil && strings.EqualFold(cc.Metadata.Product, "rosa")

	// Count MachineSets on expected vs old vs custom AMI
	onExpected := 0
	onOld := 0
	customAMIs := 0
	rosaAMIs := 0 // AMIs not in AllowedAMIs but on a ROSA cluster (expected)
	if expectedAMI != "" {
		for _, ami := range msAMIs {
			if ami == expectedAMI {
				onExpected++
			} else {
				onOld++
				// Lazy-load AllowedAMIs only when we find a mismatch
				if allowed, listAvail := isAllowedAMI(ami); listAvail && !allowed {
					if isROSA {
						rosaAMIs++
					} else {
						customAMIs++
					}
				}
			}
		}
		r.Details["machinesets_on_expected_ami"] = onExpected
		r.Details["machinesets_on_old_ami"] = onOld
		if customAMIs > 0 {
			r.Details["machinesets_on_custom_ami"] = customAMIs
		}
		if rosaAMIs > 0 {
			r.Details["machinesets_on_rosa_ami"] = rosaAMIs
		}
	}

	switch {
	case len(amiCounts) == 0:
		r.Status = checks.StatusSkip
		r.Message = "No AMI information found on MachineSets"
	case customAMIs > 0 && !isROSA:
		// OSD cluster using non-RHCOS AMI — could be a ROSA AMI on an OSD cluster
		r.Status = checks.StatusFail
		r.Severity = checks.SeverityCritical
		r.Message = fmt.Sprintf("%d MachineSet(s) using non-RHCOS AMI (not in MCO AllowedAMIs). This may be a ROSA AMI (from ClusterImageSets) on an OSD cluster — verify this is intentional. ROSA AMIs may incur additional fees. MCO will not auto-update these.", customAMIs)
	case rosaAMIs > 0 && isROSA:
		// ROSA cluster using ROSA AMI — normal, worker MachineSets use ClusterImageSet AMIs
		if onExpected > 0 {
			r.Status = checks.StatusPass
			r.Message = fmt.Sprintf("%d MachineSets on RHCOS AMI (infra/master), %d on ROSA AMI (workers) — expected for ROSA clusters", onExpected, rosaAMIs)
		} else {
			r.Status = checks.StatusPass
			r.Message = fmt.Sprintf("All %d MachineSets on ROSA AMI (from ClusterImageSets)", rosaAMIs)
		}
	case expectedAMI != "" && onOld > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d/%d MachineSets on expected AMI, %d on old RHCOS AMI (expected: %s)", onExpected, len(msAMIs), onOld, expectedAMI)
	case machineAMIMismatch > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d machines using different AMI than their MachineSet (rollout pending)", machineAMIMismatch)
	case len(amiCounts) > 1 && !isROSA:
		r.Status = checks.StatusWarning
		amis := make([]string, 0, len(amiCounts))
		for ami, count := range amiCounts {
			amis = append(amis, fmt.Sprintf("%s(%d)", ami, count))
		}
		r.Message = fmt.Sprintf("Mixed AMIs across MachineSets: %s", strings.Join(amis, ", "))
	default:
		if expectedAMI != "" && onExpected == len(msAMIs) {
			r.Status = checks.StatusPass
			r.Message = fmt.Sprintf("All %d MachineSets on expected boot image (%s)", len(msAMIs), expectedAMI)
		} else {
			r.Status = checks.StatusPass
			r.Message = fmt.Sprintf("All %d MachineSets using same AMI", len(msAMIs))
		}
	}

	cc.AddResult(r)
}

var timeNow = func() int64 { return time.Now().Unix() }

func checkMachineAPILogs(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("mcc_machine_api_logs")

	r := checks.Result{
		Check:    "mcc_machine_api_logs",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"namespace":     machineAPINamespace,
			"description":   "Analyzes machine-api-controllers logs for failure patterns: provisioning errors, drain failures, PDB violations, EC2/AWS errors, and permission issues. These indicate infrastructure problems that prevent node lifecycle operations.",
			"pass_criteria": "PASS: No error patterns found. WARN: Error patterns detected in recent logs.",
		},
	}

	// Get machine-api-controllers pods
	pods, podErr := cc.Client.GetPods(ctx, machineAPINamespace, "api=clusterapi")
	if podErr != nil || len(pods.Items) == 0 {
		// Try listing all pods and finding machine-api-controllers
		allPods, allErr := cc.Client.GetPods(ctx, machineAPINamespace, "")
		if allErr != nil || len(allPods.Items) == 0 {
			r.Status = checks.StatusSkip
			r.Message = "Could not find machine-api-controllers pods"
			cc.AddResult(r)
			return
		}
		for i := range allPods.Items {
			if strings.HasPrefix(allPods.Items[i].Name, "machine-api-controllers-") {
				pods = allPods
				break
			}
		}
		if pods == nil {
			r.Status = checks.StatusSkip
			r.Message = "No machine-api-controllers pod found"
			cc.AddResult(r)
			return
		}
	}

	// Find the machine-api-controllers pod
	var controllerPod string
	for _, pod := range pods.Items {
		if strings.HasPrefix(pod.Name, "machine-api-controllers-") {
			controllerPod = pod.Name
			break
		}
	}
	if controllerPod == "" {
		r.Status = checks.StatusSkip
		r.Message = "No machine-api-controllers pod found"
		cc.AddResult(r)
		return
	}

	// Check logs from key containers
	containers := []string{"machine-controller", "machineset-controller", "machine-healthcheck-controller"}
	type logCategory struct {
		count   int
		samples []string
	}
	categories := map[string]*logCategory{
		"provision_errors":  {},
		"drain_failures":    {},
		"pdb_violations":    {},
		"aws_errors":        {},
		"permission_errors": {},
		"general_errors":    {},
	}

	for _, container := range containers {
		logOutput, logErr := cc.Client.GetContainerLogs(ctx, machineAPINamespace, controllerPod, container, 200)
		if logErr != nil {
			continue
		}

		for _, line := range strings.Split(logOutput, "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			lower := strings.ToLower(line)

			// Skip info-level lines
			if strings.Contains(lower, "level=info") || strings.Contains(lower, `"level":"info"`) {
				continue
			}

			truncated := line
			if len(truncated) > 200 {
				truncated = truncated[:200] + "..."
			}

			switch {
			case strings.Contains(lower, "failed to create instance") || strings.Contains(lower, "failed to launch") || strings.Contains(lower, "error creating machine"):
				cat := categories["provision_errors"]
				cat.count++
				if len(cat.samples) < 3 {
					cat.samples = append(cat.samples, truncated)
				}
			case strings.Contains(lower, "failed to drain") || strings.Contains(lower, "drain failed") || strings.Contains(lower, "error draining"):
				cat := categories["drain_failures"]
				cat.count++
				if len(cat.samples) < 3 {
					cat.samples = append(cat.samples, truncated)
				}
			case strings.Contains(lower, "poddisruptionbudget") || strings.Contains(lower, "pdb") || strings.Contains(lower, "disruptionallowed"):
				cat := categories["pdb_violations"]
				cat.count++
				if len(cat.samples) < 3 {
					cat.samples = append(cat.samples, truncated)
				}
			case strings.Contains(lower, "ec2") || strings.Contains(lower, "aws") || strings.Contains(lower, "amazonaws"):
				if strings.Contains(lower, "error") || strings.Contains(lower, "fail") || strings.Contains(lower, "denied") {
					cat := categories["aws_errors"]
					cat.count++
					if len(cat.samples) < 3 {
						cat.samples = append(cat.samples, truncated)
					}
				}
			case strings.Contains(lower, "forbidden") || strings.Contains(lower, "unauthorized") || strings.Contains(lower, "accessdenied") || strings.Contains(lower, "permission"):
				cat := categories["permission_errors"]
				cat.count++
				if len(cat.samples) < 3 {
					cat.samples = append(cat.samples, truncated)
				}
			case strings.Contains(lower, "error") || strings.Contains(lower, `"level":"error"`):
				cat := categories["general_errors"]
				cat.count++
				if len(cat.samples) < 3 {
					cat.samples = append(cat.samples, truncated)
				}
			}
		}
	}

	totalIssues := 0
	var issues []string
	for name, cat := range categories {
		if cat.count > 0 {
			totalIssues += cat.count
			r.Details[name] = cat.count
			if len(cat.samples) > 0 {
				r.Details[name+"_samples"] = cat.samples
			}
			issues = append(issues, fmt.Sprintf("%s(%d)", name, cat.count))
		}
	}

	criticalIssues := categories["provision_errors"].count + categories["drain_failures"].count +
		categories["aws_errors"].count + categories["permission_errors"].count

	switch {
	case criticalIssues > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("Machine API issues detected: %s", strings.Join(issues, ", "))
	case totalIssues > 0:
		r.Status = checks.StatusWarning
		r.Message = fmt.Sprintf("%d errors in machine-api logs: %s", totalIssues, strings.Join(issues, ", "))
	default:
		r.Status = checks.StatusPass
		r.Message = "No machine-api error patterns in recent logs"
	}

	cc.AddResult(r)
}

func checkNodeMetricsTrends(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("mcc_node_metrics")

	r := checks.Result{
		Check:    "mcc_node_metrics",
		Severity: checks.SeverityInfo,
		Details: map[string]any{
			"description":   "Queries 7-day average CPU utilization and memory usage per node role (master, infra, worker). Shows aggregated trends for capacity planning and correlating with infrastructure changes like AMI updates.",
			"pass_criteria": "INFO: Reports timeseries data for charting. SKIP: Metrics unavailable.",
			"lookback_hours": 168.0,
		},
	}

	if !cc.Client.CanQueryMetrics() {
		cc.AddResult(cc.ElevationSkipResult(cc.CurrentCheck))
		return
	}

	now := timeNow()
	start := now - 604800 // 7 days
	step := 3600          // 1 hour

	nodeLabel := func(m map[string]string) string {
		node := m["node"]
		if node == "" {
			node = m["instance"]
		}
		return node
	}

	// Query all nodes, then split by role in Go using the node list
	cpuQuery := `100 - (avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)`
	cpuData, cpuErr := cc.Client.QueryMetricsRange(ctx, cpuQuery, start, now, step)
	cc.RecordError("Node CPU metrics", cpuErr)

	memQuery := `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100`
	memData, memErr := cc.Client.QueryMetricsRange(ctx, memQuery, start, now, step)
	cc.RecordError("Node memory metrics", memErr)

	// Build node-to-role map from the node list
	nodeRoleMap := map[string]string{}
	nodes, nodeErr := cc.Client.Clientset().CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if nodeErr == nil {
		for i := range nodes.Items {
			nodeRoleMap[nodes.Items[i].Name] = nodeRole(&nodes.Items[i])
		}
	}

	seriesCount := 0

	// Split timeseries by role
	splitByRole := func(allSeries []thanos.LabeledTimeseries) map[string][]thanos.LabeledTimeseries {
		byRole := map[string][]thanos.LabeledTimeseries{}
		for _, s := range allSeries {
			role := nodeRoleMap[s.Label]
			if role == "" || role == "control-plane" {
				role = "master"
			}
			byRole[role] = append(byRole[role], s)
		}
		return byRole
	}

	// Average a set of timeseries into a single series
	avgSeries := func(series []thanos.LabeledTimeseries, label string) thanos.LabeledTimeseries {
		if len(series) == 1 {
			return series[0]
		}
		// Collect all timestamps, average values at each
		byTS := map[float64][]float64{}
		for _, s := range series {
			for _, v := range s.Values {
				byTS[v[0]] = append(byTS[v[0]], v[1])
			}
		}
		var points [][2]float64
		for ts, vals := range byTS {
			sum := 0.0
			for _, v := range vals {
				sum += v
			}
			points = append(points, [2]float64{ts, sum / float64(len(vals))})
		}
		return thanos.LabeledTimeseries{Label: label, Values: points}
	}

	if cpuErr == nil && cpuData != "" {
		if allSeries, _ := thanos.PerSeriesTimeseries(cpuData, nodeLabel); len(allSeries) > 0 {
			byRole := splitByRole(allSeries)
			for role, series := range byRole {
				if role == "worker" && len(series) > 5 {
					// Aggregate workers into single avg line
					r.Details["cpu_timeseries_"+role] = []thanos.LabeledTimeseries{avgSeries(series, "worker (avg)")}
				} else {
					r.Details["cpu_timeseries_"+role] = series
				}
				seriesCount += len(series)
			}
		}
	}

	if memErr == nil && memData != "" {
		if allSeries, _ := thanos.PerSeriesTimeseries(memData, nodeLabel); len(allSeries) > 0 {
			byRole := splitByRole(allSeries)
			for role, series := range byRole {
				if role == "worker" && len(series) > 5 {
					r.Details["memory_timeseries_"+role] = []thanos.LabeledTimeseries{avgSeries(series, "worker (avg)")}
				} else {
					r.Details["memory_timeseries_"+role] = series
				}
				seriesCount += len(series)
			}
		}
	}

	if seriesCount == 0 {
		r.Status = checks.StatusSkip
		r.Message = "No node CPU/memory metrics available"
		cc.AddResult(r)
		return
	}

	r.Status = checks.StatusInfo
	r.Message = fmt.Sprintf("Collected %d node metric timeseries for trending", seriesCount)
	cc.AddResult(r)
}

func parseVersion(version string) (int, int) {
	var major, minor int
	fmt.Sscanf(version, "%d.%d", &major, &minor)
	return major, minor
}

func firstKey(m map[string]int) string {
	for k := range m {
		return k
	}
	return ""
}
