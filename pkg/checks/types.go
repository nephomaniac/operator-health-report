package checks

import (
	"strings"
	"time"

	"github.com/openshift/operator-health-report/pkg/kube"
)

// Status represents the outcome of a health check
type Status string

const (
	StatusPass         Status = "PASS"
	StatusFail         Status = "FAIL"
	StatusWarning      Status = "WARNING"
	StatusInfo         Status = "INFO"
	StatusSkip         Status = "SKIP"
	StatusUnknown      Status = "UNKNOWN"
	StatusAccessDenied Status = "ACCESS_DENIED"
)

// Severity indicates the importance of a check failure
type Severity string

const (
	SeverityCritical Severity = "critical"
	SeverityWarning  Severity = "warning"
	SeverityInfo     Severity = "info"
)

// Result is the output of a single health check
type Result struct {
	Check       string                 `json:"check"`
	Status      Status                 `json:"status"`
	Severity    Severity               `json:"severity"`
	Message     string                 `json:"message"`
	Description string                 `json:"description,omitempty"`
	Details     map[string]interface{} `json:"details,omitempty"`
}

// APIError records a failed API call with context for debugging
type APIError struct {
	Operation    string `json:"operation"`
	ErrorMessage string `json:"error_message"`
	Command      string `json:"command"`
	Check        string `json:"check"`
	ErrorType    string `json:"error_type"`
	ExitCode     int    `json:"exit_code"`
	Timestamp    string `json:"timestamp"`
}

// OperatorConfig defines an operator to check
type OperatorConfig struct {
	Name             string `json:"name"`
	ShortName        string `json:"short_name"`
	Namespace        string `json:"namespace"`
	Deployment       string `json:"deployment"`
	PKOSaas          string `json:"pko_saas"`
	OLMSaas          string `json:"olm_saas"`
	SkipCommonChecks bool   `json:"skip_common_checks,omitempty"`
}

// ClusterMetadata holds OCM cluster properties for display in reports
type ClusterMetadata struct {
	ID              string `json:"id"`
	ExternalID      string `json:"external_id"`
	Name            string `json:"name"`
	State           string `json:"state"`
	APIListening    string `json:"api_listening"`
	Product         string `json:"product"`
	Provider        string `json:"provider"`
	Version         string `json:"version"`
	Region          string `json:"region"`
	MultiAZ         bool   `json:"multi_az"`
	CNIType         string `json:"cni_type"`
	PrivateLink     bool   `json:"privatelink"`
	STS             bool   `json:"sts"`
	CCS             bool   `json:"ccs"`
	Hypershift      bool   `json:"hypershift"`
	ExistingVPC     bool   `json:"existing_vpc"`
	ChannelGroup    string `json:"channel_group"`
	LimitedSupport  bool   `json:"limited_support"`
	Shard           string `json:"shard"`
	OwnerOrg        string            `json:"owner_org,omitempty"`
	OwnerEmail      string            `json:"owner_email,omitempty"`
	Labels          map[string]string `json:"labels,omitempty"`
	Environment     string            `json:"environment,omitempty"`
}

// ClusterOutput is the JSON output for a single cluster+operator check
type ClusterOutput struct {
	ScriptVersion   string           `json:"script_version"`
	ClusterID       string           `json:"cluster_id"`
	ClusterName     string           `json:"cluster_name"`
	ClusterType     string           `json:"cluster_type"`
	HiveShard       string           `json:"hive_shard"`
	ClusterVersion  string           `json:"cluster_version"`
	OperatorName    string           `json:"operator_name"`
	OperatorVersion string           `json:"operator_version"`
	OperatorImage   string           `json:"operator_image"`
	Namespace       string           `json:"namespace"`
	Deployment      string           `json:"deployment"`
	Timestamp       string           `json:"timestamp"`
	ClusterMetadata *ClusterMetadata `json:"cluster_metadata"`
	HealthSummary   HealthSummary    `json:"health_summary"`
	HealthChecks    []Result         `json:"health_checks"`
	APIErrors       []APIError       `json:"api_errors"`
}

// HealthSummary aggregates check results
type HealthSummary struct {
	OverallStatus string `json:"overall_status"`
	CriticalCount int    `json:"critical_count"`
	WarningCount  int    `json:"warning_count"`
}

// ClusterContext holds the runtime context for checks on a single cluster
type ClusterContext struct {
	ClusterID      string
	ClusterName    string
	ClusterVersion string
	ClusterType    string
	HiveShard      string
	OCMEnv         string
	Metadata       *ClusterMetadata

	Client   *kube.ClusterClient
	Operator OperatorConfig

	CurrentCheck  string
	Results       []Result
	APIErrors     []APIError
	CriticalCount int
	WarningCount  int
}

// AddResult appends a check result
func (cc *ClusterContext) AddResult(r Result) {
	cc.Results = append(cc.Results, r)
	switch r.Status {
	case StatusFail:
		cc.CriticalCount++
	case StatusWarning:
		cc.WarningCount++
	}
}

// RecordError logs an API error for the current check
func (cc *ClusterContext) RecordError(operation string, err error) {
	if err == nil {
		return
	}
	errMsg := err.Error()
	errType := "api_error"
	lower := strings.ToLower(errMsg)
	if strings.Contains(lower, "command not found") || strings.Contains(lower, "no such file") {
		errType = "script_error"
	}
	cc.APIErrors = append(cc.APIErrors, APIError{
		Operation:    operation,
		ErrorMessage: errMsg,
		Command:      "",
		Check:        cc.CurrentCheck,
		ErrorType:    errType,
		ExitCode:     1,
		Timestamp:    time.Now().UTC().Format(time.RFC3339),
	})
}

// ElevationSkipResult returns a Result for checks that can't run due to elevation issues.
// Uses ACCESS_DENIED for access-request and forbidden clusters, SKIP when elevation is
// simply disabled via --no-elevate.
func (cc *ClusterContext) ElevationSkipResult(checkName string) Result {
	r := Result{
		Check:    checkName,
		Severity: SeverityInfo,
		Details:  map[string]any{},
	}
	reason := cc.Client.ElevationDeniedReason()
	switch reason {
	case "access_request":
		r.Status = StatusAccessDenied
		r.Message = "Access request required — run 'ocm-backplane accessrequest create'"
	case "forbidden":
		r.Status = StatusAccessDenied
		r.Message = "Elevation denied — insufficient permissions on this cluster"
	default:
		r.Status = StatusSkip
		r.Message = "Skipped — elevation not enabled (use --reason to enable)"
	}
	return r
}

// IsAccessError returns true if the error is an RBAC/auth/forbidden issue
func IsAccessError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "forbidden") ||
		strings.Contains(msg, "Forbidden") ||
		strings.Contains(msg, "Unauthorized") ||
		strings.Contains(msg, "cannot get resource") ||
		strings.Contains(msg, "cannot list resource") ||
		strings.Contains(msg, "access request")
}

// OverallStatus returns CRITICAL, WARNING, or HEALTHY
func (cc *ClusterContext) OverallStatus() string {
	for _, r := range cc.Results {
		if r.Status == StatusFail {
			return "CRITICAL"
		}
	}
	for _, r := range cc.Results {
		if r.Status == StatusWarning {
			return "WARNING"
		}
	}
	return "HEALTHY"
}

// ToOutput converts the context to the final JSON output structure
func (cc *ClusterContext) ToOutput(version string) ClusterOutput {
	return ClusterOutput{
		ScriptVersion:   version,
		ClusterID:       cc.ClusterID,
		ClusterName:     cc.ClusterName,
		ClusterType:     cc.ClusterType,
		HiveShard:       cc.HiveShard,
		ClusterVersion:  cc.ClusterVersion,
		OperatorName:    cc.Operator.Name,
		Namespace:       cc.Operator.Namespace,
		Deployment:      cc.Operator.Deployment,
		Timestamp:       time.Now().UTC().Format(time.RFC3339),
		ClusterMetadata: cc.Metadata,
		HealthSummary: HealthSummary{
			OverallStatus: cc.OverallStatus(),
			CriticalCount: cc.CriticalCount,
			WarningCount:  cc.WarningCount,
		},
		HealthChecks: cc.Results,
		APIErrors:    cc.APIErrors,
	}
}

// Predefined operator configs
var (
	CAMOConfig = OperatorConfig{
		Name:       "configure-alertmanager-operator",
		ShortName:  "camo",
		Namespace:  "openshift-monitoring",
		Deployment: "configure-alertmanager-operator",
		PKOSaas:    "saas-configure-alertmanager-operator-pko.yaml",
		OLMSaas:    "saas-configure-alertmanager-operator.yaml",
	}
	RMOConfig = OperatorConfig{
		Name:       "route-monitor-operator",
		ShortName:  "rmo",
		Namespace:  "openshift-route-monitor-operator",
		Deployment: "route-monitor-operator-controller-manager",
		PKOSaas:    "saas-route-monitor-operator-pko.yaml",
		OLMSaas:    "saas-route-monitor-operator.yaml",
	}
	OMEConfig = OperatorConfig{
		Name:       "osd-metrics-exporter",
		ShortName:  "ome",
		Namespace:  "openshift-osd-metrics",
		Deployment: "osd-metrics-exporter",
		PKOSaas:    "saas-osd-metrics-exporter-pko.yaml",
		OLMSaas:    "saas-osd-metrics-exporter.yaml",
	}

	SFOConfig = OperatorConfig{
		Name:       "splunk-forwarder-operator",
		ShortName:  "sfo",
		Namespace:  "openshift-splunk-forwarder-operator",
		Deployment: "splunk-forwarder-operator",
		PKOSaas:    "saas-splunk-forwarder-operator-pko.yaml",
		OLMSaas:    "saas-splunk-forwarder-operator.yaml",
	}

	RHOBSConfig = OperatorConfig{
		Name:             "rhobs-observability",
		ShortName:        "rhobs",
		Namespace:        "openshift-observability-operator",
		Deployment:       "",
		SkipCommonChecks: true,
	}

	RLRConfig = OperatorConfig{
		Name:             "rosa-log-router",
		ShortName:        "rlr",
		Namespace:        "hypershift-control-plane-log-forwarding",
		Deployment:       "",
		SkipCommonChecks: true,
	}

	PDOConfig = OperatorConfig{
		Name:             "pagerduty-operator",
		ShortName:        "pdo",
		Namespace:        "pagerduty-operator",
		Deployment:       "pagerduty-operator",
		PKOSaas:          "saas-pagerduty-operator-pko.yaml",
		OLMSaas:          "saas-pagerduty-operator.yaml",
		SkipCommonChecks: true,
	}

	AllOperators = map[string]OperatorConfig{
		"camo":  CAMOConfig,
		"rmo":   RMOConfig,
		"ome":   OMEConfig,
		"sfo":   SFOConfig,
		"rhobs": RHOBSConfig,
		"rlr":   RLRConfig,
		"pdo":   PDOConfig,
	}
)
