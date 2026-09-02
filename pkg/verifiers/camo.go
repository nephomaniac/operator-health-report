package verifiers

import (
	"context"
	"fmt"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const (
	camoNamespace  = "openshift-monitoring"
	camoDeployment = "configure-alertmanager-operator"
)

// CAMO check metadata for filtering and documentation.
var (
	MetaCAMODeploymentHealthy = CheckMeta{
		Name:         "camo_deployment_healthy",
		Description:  "Validates the configure-alertmanager-operator deployment is running with desired replicas. CAMO generates the Alertmanager configuration that routes alerts to PagerDuty and Dead Man's Snitch. If CAMO is down, configuration changes won't be reconciled.",
		PassCriteria: "PASS: all replicas ready. FAIL: zero ready replicas. WARNING: partial readiness.",
		Severity:     "critical",
		AccessMode:   AccessReadOnly,
		Elevation:    ElevationNone,
		ClusterTypes: []string{ClusterTypeStandard, ClusterTypeMC, ClusterTypeSC},
		Operator:     "configure-alertmanager-operator",
	}

	MetaCAMOAlertmanagerRunning = CheckMeta{
		Name:         "camo_alertmanager_running",
		Description:  "Validates Alertmanager pods are running and ready in openshift-monitoring. Alertmanager is the component that routes firing alerts to PagerDuty and Dead Man's Snitch. If Alertmanager pods are not running, alert notifications will be lost.",
		PassCriteria: "PASS: all AM pods running and ready. FAIL: no AM pods or none ready. WARNING: partial readiness.",
		Severity:     "critical",
		AccessMode:   AccessReadOnly,
		Elevation:    ElevationNone,
		ClusterTypes: []string{ClusterTypeStandard, ClusterTypeMC, ClusterTypeSC},
		Operator:     "configure-alertmanager-operator",
	}

	MetaCAMOSecretExists = CheckMeta{
		Name:         "camo_alertmanager_secret",
		Description:  "Validates the alertmanager-main secret exists in openshift-monitoring. This secret contains the rendered Alertmanager configuration. Without it, Alertmanager cannot start and alert routing is completely broken.",
		PassCriteria: "PASS: secret exists. FAIL: secret not found.",
		Severity:     "critical",
		AccessMode:   AccessReadOnly,
		Elevation:    ElevationRequired,
		ClusterTypes: []string{ClusterTypeStandard, ClusterTypeMC, ClusterTypeSC},
		Operator:     "configure-alertmanager-operator",
	}

	MetaCAMOWatchdogFiring = CheckMeta{
		Name:         "camo_watchdog_firing",
		Description:  "Verifies the Watchdog alert is actively firing. Watchdog is a heartbeat alert that fires continuously when Prometheus and Alertmanager are healthy. CAMO configures Alertmanager to forward Watchdog to Dead Man's Snitch. If Watchdog stops firing, DMS will time out and page.",
		PassCriteria: "PASS: Watchdog alert is firing. FAIL: Watchdog not firing.",
		Severity:     "critical",
		AccessMode:   AccessReadOnly,
		Elevation:    ElevationNone,
		ClusterTypes: []string{ClusterTypeStandard, ClusterTypeMC, ClusterTypeSC},
		Operator:     "configure-alertmanager-operator",
		TriageLinks:  []string{"SOP: https://github.com/openshift/ops-sop/blob/master/v4/alerts/Watchdog.md"},
	}

	MetaCAMOPDSecretExists = CheckMeta{
		Name:         "camo_pd_secret_exists",
		Description:  "Validates the pd-secret exists in openshift-monitoring. This secret contains the PagerDuty integration key. CAMO uses it to configure the PagerDuty receiver in Alertmanager. Without it, critical alerts won't page the on-call engineer.",
		PassCriteria: "PASS: pd-secret exists. WARNING: pd-secret not found (PD notifications disabled).",
		Severity:     "warning",
		AccessMode:   AccessReadOnly,
		Elevation:    ElevationRequired,
		ClusterTypes: []string{ClusterTypeStandard, ClusterTypeMC, ClusterTypeSC},
		Operator:     "configure-alertmanager-operator",
	}

	MetaCAMODMSSecretExists = CheckMeta{
		Name:         "camo_dms_secret_exists",
		Description:  "Validates the dms-secret exists in openshift-monitoring. This secret contains the Dead Man's Snitch check-in URL. CAMO uses it to configure the Watchdog webhook receiver. Without it, DMS heartbeat monitoring is disabled.",
		PassCriteria: "PASS: dms-secret exists. WARNING: dms-secret not found.",
		Severity:     "warning",
		AccessMode:   AccessReadOnly,
		Elevation:    ElevationRequired,
		ClusterTypes: []string{ClusterTypeStandard, ClusterTypeMC, ClusterTypeSC},
		Operator:     "configure-alertmanager-operator",
	}
)

// VerifyCAMODeploymentHealthy checks that the CAMO deployment has ready replicas.
func VerifyCAMODeploymentHealthy(ctx context.Context, client kubernetes.Interface) CheckResult {
	deploy, err := client.AppsV1().Deployments(camoNamespace).Get(ctx, camoDeployment, metav1.GetOptions{})
	if err != nil {
		return Error(fmt.Errorf("CAMO deployment not found in %s: %w", camoNamespace, err))
	}

	desired := int32(1)
	if deploy.Spec.Replicas != nil {
		desired = *deploy.Spec.Replicas
	}
	ready := deploy.Status.ReadyReplicas

	details := map[string]any{
		"ready_replicas":   ready,
		"desired_replicas": desired,
	}

	if ready == 0 {
		return Fail(fmt.Sprintf("CAMO has 0/%d ready replicas", desired)).WithDetails(details)
	}
	if ready < desired {
		return Warn(fmt.Sprintf("CAMO degraded — %d/%d ready", ready, desired)).WithDetails(details)
	}
	return Pass(fmt.Sprintf("CAMO healthy — %d/%d ready", ready, desired)).WithDetails(details)
}

// VerifyAlertmanagerRunning checks that Alertmanager pods are running and ready.
func VerifyAlertmanagerRunning(ctx context.Context, client kubernetes.Interface) CheckResult {
	pods, err := client.CoreV1().Pods(camoNamespace).List(ctx, metav1.ListOptions{
		LabelSelector: "app.kubernetes.io/name=alertmanager",
	})
	if err != nil {
		return Error(fmt.Errorf("listing Alertmanager pods: %w", err))
	}

	if len(pods.Items) == 0 {
		return Fail("No Alertmanager pods found in " + camoNamespace)
	}

	totalPods := len(pods.Items)
	readyPods := 0
	totalRestarts := int32(0)

	for _, pod := range pods.Items {
		podReady := false
		for _, cond := range pod.Status.Conditions {
			if cond.Type == "Ready" && cond.Status == "True" {
				podReady = true
				break
			}
		}
		if podReady {
			readyPods++
		}
		for _, cs := range pod.Status.ContainerStatuses {
			totalRestarts += cs.RestartCount
		}
	}

	details := map[string]any{
		"total_pods":     totalPods,
		"ready_pods":     readyPods,
		"total_restarts": totalRestarts,
	}

	if readyPods == 0 {
		return Fail(fmt.Sprintf("All %d Alertmanager pods are not ready", totalPods)).WithDetails(details)
	}
	if readyPods < totalPods {
		return Warn(fmt.Sprintf("Alertmanager degraded — %d/%d pods ready", readyPods, totalPods)).WithDetails(details)
	}
	if totalRestarts > 3 {
		return Warn(fmt.Sprintf("Alertmanager running but %d total restarts", totalRestarts)).WithDetails(details)
	}
	return Pass(fmt.Sprintf("Alertmanager healthy — %d/%d pods ready", readyPods, totalPods)).WithDetails(details)
}

// VerifyAlertmanagerSecretExists checks that the alertmanager-main secret exists.
// Requires elevated access to read secrets.
func VerifyAlertmanagerSecretExists(ctx context.Context, client kubernetes.Interface) CheckResult {
	_, err := client.CoreV1().Secrets(camoNamespace).Get(ctx, "alertmanager-main", metav1.GetOptions{})
	if err != nil {
		return Fail(fmt.Sprintf("alertmanager-main secret not found: %v", err))
	}
	return Pass("alertmanager-main secret exists")
}

// VerifyCAMOSecretsExist checks that the expected CAMO-managed secrets exist.
// Returns details about which secrets are present/missing.
// Requires elevated access to read secrets.
func VerifyCAMOSecretsExist(ctx context.Context, client kubernetes.Interface) CheckResult {
	secrets := []struct {
		name     string
		required bool
		desc     string
	}{
		{"alertmanager-main", true, "AM configuration"},
		{"pd-secret", false, "PagerDuty integration key"},
		{"dms-secret", false, "Dead Man's Snitch URL"},
		{"goalert-secret", false, "GoAlert integration"},
	}

	details := map[string]any{}
	var missing []string
	var present []string
	requiredMissing := false

	for _, s := range secrets {
		_, err := client.CoreV1().Secrets(camoNamespace).Get(ctx, s.name, metav1.GetOptions{})
		if err != nil {
			details[s.name] = false
			missing = append(missing, s.name+" ("+s.desc+")")
			if s.required {
				requiredMissing = true
			}
		} else {
			details[s.name] = true
			present = append(present, s.name)
		}
	}

	details["present"] = strings.Join(present, ", ")
	details["missing"] = strings.Join(missing, ", ")

	if requiredMissing {
		return Fail(fmt.Sprintf("Required secret(s) missing: %s", strings.Join(missing, ", "))).WithDetails(details)
	}
	if len(missing) > 0 {
		return Warn(fmt.Sprintf("Optional secret(s) missing: %s", strings.Join(missing, ", "))).WithDetails(details)
	}
	return Pass(fmt.Sprintf("All CAMO secrets present: %s", strings.Join(present, ", "))).WithDetails(details)
}

// MetricsQuerier abstracts Prometheus metric queries for portability.
// In operator-health-report: implemented by ClusterClient.QueryMetrics
// In rosa-e2e: implemented by the framework's metrics client
type MetricsQuerier interface {
	QueryMetrics(ctx context.Context, query string) (string, error)
}

// VerifyWatchdogFiring checks that the Watchdog alert is actively firing.
// Uses MetricsQuerier to abstract the Prometheus access method.
func VerifyWatchdogFiring(ctx context.Context, querier MetricsQuerier) CheckResult {
	body, err := querier.QueryMetrics(ctx, `ALERTS{alertname="Watchdog",alertstate="firing"}`)
	if err != nil {
		return Skip(fmt.Sprintf("Cannot query Watchdog alert: %v", err))
	}

	if body == "" || !strings.Contains(body, `"result":[{`) {
		return Fail("Watchdog alert not firing — DMS heartbeat stopped")
	}
	return Pass("Watchdog alert is firing — DMS heartbeat active")
}
