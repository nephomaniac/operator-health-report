package checks

import "context"

// OperatorChecker is the interface that operator-specific check modules implement.
// Adding a new operator only requires implementing this interface and registering it.
type OperatorChecker interface {
	// Name returns the operator's short name (e.g., "camo", "rmo", "ome")
	Name() string

	// RunChecks executes operator-specific health checks.
	// Common checks (namespace, pod, PKO, logs) are already run before this is called.
	RunChecks(ctx context.Context, cc *ClusterContext)
}

// Registry maps operator short names to their checker implementations
var registry = map[string]OperatorChecker{}

// Register adds an operator checker to the registry
func Register(checker OperatorChecker) {
	registry[checker.Name()] = checker
}

// GetChecker returns the operator-specific checker, or nil if none registered
func GetChecker(shortName string) OperatorChecker {
	return registry[shortName]
}

// RunOperatorChecks runs common checks then operator-specific checks
func RunOperatorChecks(ctx context.Context, cc *ClusterContext) {
	// Common checks first (all operators)
	RunAllCommonChecks(ctx, cc)

	// Operator-specific checks (if registered)
	if checker := GetChecker(cc.Operator.ShortName); checker != nil {
		checker.RunChecks(ctx, cc)
	}
}
