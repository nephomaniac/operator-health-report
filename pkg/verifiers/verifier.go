// Package verifiers provides shared health check functions usable by both
// the operator-health-report tool and the rosa-e2e nightly framework.
//
// Each verifier is a standalone function that takes standard k8s/OCM clients
// and returns a CheckResult with rich metadata. Consumers map the result to
// their framework:
//   - rosa-e2e: maps to Ginkgo pass/fail/skip assertions
//   - operator-health-report: maps to the full Result struct with visualization
//
// Verifiers are tagged with metadata enabling safety-aware filtering:
//   - AccessMode: read-only vs write vs destructive
//   - Elevation: none, optional, required
//   - ClusterTypes: which cluster types the check applies to
package verifiers

// CheckResult is the output of a shared verifier function.
type CheckResult struct {
	// Status is the check outcome: pass, fail, warning, info, skip
	Status string

	// Message is a human-readable summary of the result
	Message string

	// Details carries structured data for visualization and AI consumption
	Details map[string]any

	// Err is set when the check encountered an unexpected error (not a check failure)
	Err error
}

// CheckMeta describes a verifier's properties for filtering and documentation.
type CheckMeta struct {
	// Name is the check identifier (e.g., "camo_watchdog_firing")
	Name string

	// Description explains what this check does and why it matters
	Description string

	// PassCriteria documents what each status means for this check
	PassCriteria string

	// Severity is the impact level: critical, warning, info
	Severity string

	// AccessMode describes the check's cluster interaction: read-only, write, destructive
	AccessMode string

	// Elevation describes whether backplane elevation is needed: none, optional, required
	Elevation string

	// ClusterTypes lists which cluster types this check applies to
	ClusterTypes []string

	// MinVersion is the minimum OCP version required (empty = all versions)
	MinVersion string

	// Operator is the operator this check belongs to
	Operator string

	// TriageLinks are URLs to dashboards, SOPs, or runbooks for investigating results
	TriageLinks []string
}

const (
	StatusPass    = "pass"
	StatusFail    = "fail"
	StatusWarning = "warning"
	StatusInfo    = "info"
	StatusSkip    = "skip"

	AccessReadOnly    = "read-only"
	AccessWrite       = "write"
	AccessDestructive = "destructive"

	ElevationNone     = "none"
	ElevationOptional = "optional"
	ElevationRequired = "required"

	ClusterTypeStandard  = "standard"
	ClusterTypeMC        = "management_cluster"
	ClusterTypeSC        = "service_cluster"
	ClusterTypeHive      = "hive"
	ClusterTypeClassic   = "classic"
	ClusterTypeROSAHCP   = "rosa_hcp"
)

// Pass returns a passing CheckResult.
func Pass(msg string) CheckResult {
	return CheckResult{Status: StatusPass, Message: msg}
}

// Fail returns a failing CheckResult.
func Fail(msg string) CheckResult {
	return CheckResult{Status: StatusFail, Message: msg}
}

// Warn returns a warning CheckResult.
func Warn(msg string) CheckResult {
	return CheckResult{Status: StatusWarning, Message: msg}
}

// Info returns an informational CheckResult.
func Info(msg string) CheckResult {
	return CheckResult{Status: StatusInfo, Message: msg}
}

// Skip returns a skipped CheckResult.
func Skip(msg string) CheckResult {
	return CheckResult{Status: StatusSkip, Message: msg}
}

// Error returns a CheckResult wrapping an unexpected error.
func Error(err error) CheckResult {
	return CheckResult{Status: StatusFail, Message: err.Error(), Err: err}
}

// WithDetails adds structured details to a CheckResult.
func (r CheckResult) WithDetails(details map[string]any) CheckResult {
	r.Details = details
	return r
}

// ToError converts a CheckResult to an error for rosa-e2e compatibility.
// Returns nil for pass/info/skip, error for fail/warning.
func (r CheckResult) ToError() error {
	if r.Err != nil {
		return r.Err
	}
	if r.Status == StatusFail || r.Status == StatusWarning {
		return &CheckError{Result: r}
	}
	return nil
}

// CheckError wraps a CheckResult as an error for framework compatibility.
type CheckError struct {
	Result CheckResult
}

func (e *CheckError) Error() string {
	return e.Result.Message
}
