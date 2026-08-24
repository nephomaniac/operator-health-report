package fleet

import (
	"context"
	"strings"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/kube"
	"github.com/openshift/operator-health-report/pkg/logging"
	"github.com/openshift/operator-health-report/pkg/saas"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

var (
	clusterDeploymentGVR = schema.GroupVersionResource{
		Group: "hive.openshift.io", Version: "v1", Resource: "clusterdeployments",
	}
	clusterSyncGVR = schema.GroupVersionResource{
		Group: "hiveinternal.openshift.io", Version: "v1alpha1", Resource: "clustersync",
	}
)

// HiveClusterInfo represents a cluster discovered from a hive shard's ClusterDeployments
type HiveClusterInfo struct {
	OCMID       string `json:"ocm_id"`
	Name        string `json:"name"`
	Namespace   string `json:"namespace"`
	Sector      string `json:"sector,omitempty"`
	ClusterType string `json:"cluster_type,omitempty"`
	Installed   bool   `json:"installed"`
	Platform    string `json:"platform,omitempty"`
	Region      string `json:"region,omitempty"`
}

// ClusterSyncStatus holds per-SelectorSyncSet/SyncSet apply status for a cluster
type ClusterSyncStatus struct {
	Failed           bool              `json:"failed"`
	FailedCount      int               `json:"failed_count"`
	SelectorSyncSets []SyncSetStatus   `json:"selector_sync_sets,omitempty"`
	SyncSets         []SyncSetStatus   `json:"sync_sets,omitempty"`
}

// SyncSetStatus represents the apply result for one SSS or SS
type SyncSetStatus struct {
	Name               string `json:"name"`
	Result             string `json:"result"`
	FailureMessage     string `json:"failure_message,omitempty"`
	LastTransitionTime string `json:"last_transition_time,omitempty"`
	FirstSuccessTime   string `json:"first_success_time,omitempty"`
}

// DiscoverClustersFromHive lists all ClusterDeployments on a hive shard and
// extracts cluster metadata from labels. Uses standard backplane access (no elevation).
func DiscoverClustersFromHive(ctx context.Context, client *kube.ClusterClient) ([]HiveClusterInfo, error) {
	log := logging.Log

	list, err := client.ListResources(ctx, clusterDeploymentGVR, "", false)
	if err != nil {
		return nil, err
	}

	var clusters []HiveClusterInfo
	for _, item := range list.Items {
		labels := item.GetLabels()

		installed := false
		if spec, ok := item.Object["spec"].(map[string]any); ok {
			if v, ok := spec["installed"].(bool); ok {
				installed = v
			}
		}

		// Skip uninstalled clusters (deprovisioning, initializing, etc.)
		if !installed {
			continue
		}

		ocmID := labels["api.openshift.com/id"]
		if ocmID == "" {
			continue
		}

		name := labels["api.openshift.com/name"]
		if name == "" {
			name = item.GetName()
		}

		ci := HiveClusterInfo{
			OCMID:       ocmID,
			Name:        name,
			Namespace:   item.GetNamespace(),
			Sector:      labels["ext-hypershift.openshift.io/cluster-sector"],
			ClusterType: labels["ext-hypershift.openshift.io/cluster-type"],
			Installed:   installed,
			Platform:    labels["ext-hypershift.openshift.io/cluster-provider"],
			Region:      labels["ext-hypershift.openshift.io/cluster-region"],
		}

		clusters = append(clusters, ci)
	}

	log.WithField("count", len(clusters)).WithField("total", len(list.Items)).
		Debug("Discovered clusters from hive ClusterDeployments")

	return clusters, nil
}

// CollectClusterSync lists ClusterSync resources on a hive shard and returns
// per-cluster SSS/SS apply status. Keyed by namespace (matches CD namespace).
// Returns nil map (not error) if RBAC denies access.
func CollectClusterSync(ctx context.Context, client *kube.ClusterClient) (map[string]*ClusterSyncStatus, error) {
	log := logging.Log

	list, err := client.ListResources(ctx, clusterSyncGVR, "", false)
	if err != nil {
		if checks.IsAccessError(err) {
			log.Debug("ClusterSync access denied — skipping")
			return nil, nil
		}
		return nil, err
	}

	result := map[string]*ClusterSyncStatus{}

	for _, item := range list.Items {
		ns := item.GetNamespace()
		cs := &ClusterSyncStatus{}

		status, _ := item.Object["status"].(map[string]any)
		if status == nil {
			continue
		}

		// Check conditions for overall failed status
		if conditions, ok := status["conditions"].([]any); ok {
			for _, c := range conditions {
				cond, _ := c.(map[string]any)
				if cond == nil {
					continue
				}
				if cond["type"] == "Failed" && cond["status"] == "True" {
					cs.Failed = true
				}
			}
		}

		// Parse SelectorSyncSets
		cs.SelectorSyncSets = parseSyncStatuses(status["selectorSyncSets"])
		cs.SyncSets = parseSyncStatuses(status["syncSets"])

		for _, ss := range cs.SelectorSyncSets {
			if ss.Result == "Failure" {
				cs.FailedCount++
			}
		}
		for _, ss := range cs.SyncSets {
			if ss.Result == "Failure" {
				cs.FailedCount++
			}
		}

		result[ns] = cs
	}

	log.WithField("clusters", len(result)).Debug("Collected ClusterSync data")
	return result, nil
}

func parseSyncStatuses(raw any) []SyncSetStatus {
	items, ok := raw.([]any)
	if !ok {
		return nil
	}

	var statuses []SyncSetStatus
	for _, item := range items {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}

		ss := SyncSetStatus{
			Name:   strVal(m, "name"),
			Result: strVal(m, "result"),
		}

		if ss.Result == "Failure" {
			ss.FailureMessage = strVal(m, "failureMessage")
		}
		ss.LastTransitionTime = strVal(m, "lastTransitionTime")
		ss.FirstSuccessTime = strVal(m, "firstSuccessTime")

		statuses = append(statuses, ss)
	}

	return statuses
}

func strVal(m map[string]any, key string) string {
	v, _ := m[key].(string)
	return v
}

// ResolveHivePattern resolves a --by-hive pattern to a list of hive cluster names.
// Patterns:
//   - exact name: "hivep01ue1" or "hive-stage-01"
//   - shorthand: "stage-01" matches "hive-stage-01"
//   - all: "all" returns all hive shards for the current OCM environment
func ResolveHivePattern(pattern string, targets []saas.Target, ocmEnv string) []string {
	if pattern == "" {
		return nil
	}

	seen := map[string]bool{}
	var all []string

	for _, t := range targets {
		if t.HiveCluster == "" {
			continue
		}
		env := t.OCMEnv
		if env == "" {
			env = classifyHiveEnvLocal(t.HiveCluster)
		}
		if !envMatch(env, ocmEnv) {
			continue
		}
		if !seen[t.HiveCluster] {
			seen[t.HiveCluster] = true
			all = append(all, t.HiveCluster)
		}
	}

	if strings.ToLower(pattern) == "all" {
		return all
	}

	var matched []string
	lower := strings.ToLower(pattern)
	for _, hive := range all {
		hiveLower := strings.ToLower(hive)
		if hiveLower == lower ||
			hiveLower == "hive-"+lower ||
			hiveLower == "hive"+lower ||
			strings.Contains(hiveLower, lower) {
			matched = append(matched, hive)
		}
	}

	return matched
}

// envMatch compares OCM environment strings, normalizing "stage"/"staging" equivalence.
func envMatch(a, b string) bool {
	return normalizeEnv(a) == normalizeEnv(b)
}

func normalizeEnv(env string) string {
	if env == "stage" || env == "staging" {
		return "staging"
	}
	return env
}

func classifyHiveEnvLocal(hiveName string) string {
	switch {
	case strings.HasPrefix(hiveName, "hivei"):
		return "integration"
	case strings.HasPrefix(hiveName, "hives") || strings.HasPrefix(hiveName, "hive-stage"):
		return "staging"
	case strings.HasPrefix(hiveName, "hivep"):
		return "production"
	default:
		return "unknown"
	}
}
