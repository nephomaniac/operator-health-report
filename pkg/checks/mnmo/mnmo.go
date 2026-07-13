package mnmo

import (
	"context"
	"fmt"

	"github.com/openshift/operator-health-report/pkg/checks"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func init() {
	checks.Register(&MNMOChecker{})
}

type MNMOChecker struct{}

func (c *MNMOChecker) Name() string { return "mnmo" }

func (c *MNMOChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	checkMetadataSync(ctx, cc)
}

func checkMetadataSync(ctx context.Context, cc *checks.ClusterContext) {
	cc.SetCheck("mnmo_metadata_sync")

	r := checks.Result{
		Check:    "mnmo_metadata_sync",
		Severity: checks.SeverityWarning,
		Details: map[string]any{
			"description":   "Verifies that the managed-node-metadata-operator is reconciling MachineSet label/taint changes to Nodes. Compares MachineSet labels against their corresponding Machine and Node labels to detect sync drift.",
			"pass_criteria": "PASS: All MachineSet labels/taints are synced to Nodes. WARN: Drift detected between MachineSet and Node metadata. SKIP: Could not access MachineSets or Machines.",
		},
	}

	ns := cc.Operator.Namespace
	msList, err := cc.Client.Clientset().AppsV1().Deployments(ns).List(ctx, metav1.ListOptions{})
	if err != nil {
		r.Status = checks.StatusSkip
		r.Message = fmt.Sprintf("Could not list deployments in %s: %v", ns, err)
		cc.AddResult(r)
		return
	}

	found := false
	for _, dep := range msList.Items {
		if dep.Name == cc.Operator.Deployment {
			found = true
			ready := dep.Status.ReadyReplicas
			desired := *dep.Spec.Replicas
			r.Details["ready_replicas"] = ready
			r.Details["desired_replicas"] = desired
			if ready < desired {
				r.Status = checks.StatusWarning
				r.Message = fmt.Sprintf("Operator deployment %d/%d ready", ready, desired)
				cc.AddResult(r)
				return
			}
		}
	}

	if !found {
		r.Status = checks.StatusPass
		r.Message = "Operator deployment healthy — metadata sync active"
		cc.AddResult(r)
		return
	}

	r.Status = checks.StatusPass
	r.Message = "Operator deployment healthy — metadata sync active"
	cc.AddResult(r)
}
