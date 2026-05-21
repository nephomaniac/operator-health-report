package checks

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

)

// CheckNamespace verifies the operator namespace exists and is Active
func CheckNamespace(ctx context.Context, cc *ClusterContext) {
	cc.CurrentCheck = "namespace_status"

	result := cc.Client.RunOC(ctx, "Get namespace phase",
		"get", "namespace", cc.Operator.Namespace, "-o", "jsonpath={.status.phase}")
	cc.RunAndRecord("Get namespace phase", result)

	phase := strings.TrimSpace(result.Stdout)

	r := Result{
		Check:    "namespace_status",
		Severity: SeverityCritical,
		Details:  map[string]interface{}{"namespace": cc.Operator.Namespace, "phase": phase},
	}

	switch {
	case result.ExitCode != 0 || phase == "":
		r.Status = StatusFail
		r.Message = fmt.Sprintf("Namespace %s does not exist", cc.Operator.Namespace)
		if result.Stderr != "" {
			r.Message += fmt.Sprintf(" (error: %s)", strings.TrimSpace(result.Stderr))
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
	cc.CurrentCheck = "pod_status_and_restarts"

	result := cc.Client.RunOC(ctx, "Get deployment status",
		"get", "deployment", "-n", cc.Operator.Namespace, cc.Operator.Deployment, "-o", "json")
	cc.RunAndRecord("Get deployment status", result)

	r := Result{
		Check:    "pod_status_and_restarts",
		Severity: SeverityWarning,
		Details:  map[string]interface{}{},
	}

	if result.ExitCode != 0 || result.Stdout == "" {
		r.Status = StatusFail
		r.Severity = SeverityCritical
		r.Message = fmt.Sprintf("Deployment %s/%s not found", cc.Operator.Namespace, cc.Operator.Deployment)
		cc.AddResult(r)
		return
	}

	var deploy map[string]interface{}
	if err := json.Unmarshal([]byte(result.Stdout), &deploy); err != nil {
		r.Status = StatusFail
		r.Message = fmt.Sprintf("Failed to parse deployment JSON: %v", err)
		cc.AddResult(r)
		return
	}

	// Extract replica counts safely
	spec, _ := deploy["spec"].(map[string]interface{})
	status, _ := deploy["status"].(map[string]interface{})
	desired := jsonInt(spec, "replicas")
	ready := jsonInt(status, "readyReplicas")
	available := jsonInt(status, "availableReplicas")

	r.Details["desired_replicas"] = desired
	r.Details["ready_replicas"] = ready
	r.Details["available_replicas"] = available

	// Get pod selector from deployment
	selector := ""
	if specSel, ok := spec["selector"].(map[string]interface{}); ok {
		if matchLabels, ok := specSel["matchLabels"].(map[string]interface{}); ok {
			parts := []string{}
			for k, v := range matchLabels {
				parts = append(parts, fmt.Sprintf("%s=%v", k, v))
			}
			selector = strings.Join(parts, ",")
		}
	}
	if selector == "" {
		selector = fmt.Sprintf("name=%s", cc.Operator.Deployment)
	}

	// Get pods
	podResult := cc.Client.RunOC(ctx, "Get operator pods",
		"get", "pods", "-n", cc.Operator.Namespace, "-l", selector, "-o", "json")
	cc.RunAndRecord("Get operator pods", podResult)

	totalRestarts := 0
	podCount := 0
	podsNotRunning := 0

	if podResult.ExitCode == 0 && podResult.Stdout != "" {
		var podList map[string]interface{}
		if err := json.Unmarshal([]byte(podResult.Stdout), &podList); err == nil {
			items, _ := podList["items"].([]interface{})
			podCount = len(items)
			for _, item := range items {
				pod, _ := item.(map[string]interface{})
				podStatus, _ := pod["status"].(map[string]interface{})
				phase, _ := podStatus["phase"].(string)
				if phase != "Running" {
					podsNotRunning++
				}
				containers, _ := podStatus["containerStatuses"].([]interface{})
				for _, c := range containers {
					cs, _ := c.(map[string]interface{})
					restarts := jsonInt(cs, "restartCount")
					totalRestarts += restarts
				}
			}
		}
	}

	r.Details["pod_count"] = podCount
	r.Details["total_restarts"] = totalRestarts
	r.Details["pods_not_running"] = podsNotRunning

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
	cc.CurrentCheck = "pko_clusterpackage_health"

	packageName := cc.Operator.Name
	if strings.Contains(packageName, "controller-manager") {
		packageName = strings.TrimSuffix(packageName, "-controller-manager")
	}

	result := cc.Client.RunOC(ctx, "Check ClusterPackage",
		"get", "clusterpackage", packageName, "-o", "json")

	r := Result{
		Check:    "pko_clusterpackage_health",
		Severity: SeverityCritical,
		Details:  map[string]interface{}{"package_name": packageName},
	}

	if result.ExitCode != 0 {
		// ClusterPackage not found — check OLM subscription instead
		r.Status = StatusSkip
		r.Message = "No ClusterPackage found"
		cc.AddResult(r)
		checkOLMSubscription(ctx, cc, packageName)
		return
	}

	var pkg map[string]interface{}
	if err := json.Unmarshal([]byte(result.Stdout), &pkg); err != nil {
		r.Status = StatusFail
		r.Message = fmt.Sprintf("Failed to parse ClusterPackage JSON: %v", err)
		cc.AddResult(r)
		return
	}

	status, _ := pkg["status"].(map[string]interface{})
	conditions, _ := status["conditions"].([]interface{})

	available := conditionStatus(conditions, "Available")
	progressing := conditionStatus(conditions, "Progressing")
	unpacked := conditionStatus(conditions, "Unpacked")
	progressingMsg := conditionMessage(conditions, "Progressing")
	availableMsg := conditionMessage(conditions, "Available")

	r.Details["available"] = available
	r.Details["progressing"] = progressing
	r.Details["unpacked"] = unpacked
	r.Details["cluster_package_exists"] = true

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
			r.Message = "PKO ClusterPackage stuck: spec.template field is immutable — OLM-to-PKO migration Job name collision"
		} else if strings.Contains(progressingMsg, "refusing adoption") || strings.Contains(progressingMsg, "not owned by previous revision") {
			r.Status = StatusFail
			r.Message = fmt.Sprintf("PKO refusing adoption: %s", progressingMsg)
		} else {
			r.Status = StatusWarning
			r.Message = fmt.Sprintf("PKO ClusterPackage progressing: %s", progressingMsg)
		}
	default:
		r.Status = StatusWarning
		r.Message = fmt.Sprintf("PKO ClusterPackage state unclear (Available=%s, Progressing=%s, Unpacked=%s)", available, progressing, unpacked)
	}

	cc.AddResult(r)
}

func checkOLMSubscription(ctx context.Context, cc *ClusterContext, packageName string) {
	cc.CurrentCheck = "olm_subscription_health"

	result := cc.Client.RunOC(ctx, "Check OLM subscription",
		"get", "subscription.operators.coreos.com", packageName, "-n", cc.Operator.Namespace)

	r := Result{
		Check:    "olm_subscription_health",
		Severity: SeverityCritical,
		Details:  map[string]interface{}{"package_name": packageName},
	}

	if result.ExitCode != 0 {
		r.Status = StatusFail
		r.Message = "No OLM Subscription or PKO ClusterPackage found — operator not deployed"
	} else {
		r.Status = StatusPass
		r.Message = "OLM subscription exists"
	}

	cc.AddResult(r)
}

// CheckLogErrors analyzes operator logs for errors
func CheckLogErrors(ctx context.Context, cc *ClusterContext) {
	cc.CurrentCheck = "log_error_analysis"

	result := cc.Client.RunOC(ctx, "Get operator logs",
		"logs", "-n", cc.Operator.Namespace, fmt.Sprintf("deployment/%s", cc.Operator.Deployment), "--tail=500")
	cc.RunAndRecord("Get operator logs", result)

	r := Result{
		Check:    "log_error_analysis",
		Severity: SeverityWarning,
		Details:  map[string]interface{}{},
	}

	if result.ExitCode != 0 || result.Stdout == "" {
		r.Status = StatusSkip
		r.Message = "Could not retrieve logs"
		cc.AddResult(r)
		return
	}

	lines := strings.Split(result.Stdout, "\n")
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

// RunAllCommonChecks runs all general checks applicable to any operator
func RunAllCommonChecks(ctx context.Context, cc *ClusterContext) {
	CheckNamespace(ctx, cc)

	// If namespace doesn't exist, skip remaining checks
	if len(cc.Results) > 0 && cc.Results[0].Status == StatusFail {
		return
	}

	CheckDeployment(ctx, cc)
	CheckPKOHealth(ctx, cc)
	CheckLogErrors(ctx, cc)
}

// Helper functions

func jsonInt(m map[string]interface{}, key string) int {
	if m == nil {
		return 0
	}
	v, ok := m[key]
	if !ok {
		return 0
	}
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	default:
		return 0
	}
}

func conditionStatus(conditions []interface{}, condType string) string {
	for _, c := range conditions {
		cond, _ := c.(map[string]interface{})
		if t, _ := cond["type"].(string); t == condType {
			s, _ := cond["status"].(string)
			return s
		}
	}
	return "Unknown"
}

func conditionMessage(conditions []interface{}, condType string) string {
	for _, c := range conditions {
		cond, _ := c.(map[string]interface{})
		if t, _ := cond["type"].(string); t == condType {
			s, _ := cond["message"].(string)
			return s
		}
	}
	return ""
}
