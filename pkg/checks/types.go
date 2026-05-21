package checks

import (
	"strings"
	"time"

	"github.com/openshift/operator-health-report/pkg/kube"
)

// Status represents the outcome of a health check
type Status string

const (
	StatusPass    Status = "PASS"
	StatusFail    Status = "FAIL"
	StatusWarning Status = "WARNING"
	StatusInfo    Status = "INFO"
	StatusSkip    Status = "SKIP"
	StatusUnknown Status = "UNKNOWN"
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
	Name       string `json:"name"`
	ShortName  string `json:"short_name"`
	Namespace  string `json:"namespace"`
	Deployment string `json:"deployment"`
	PKOSaas    string `json:"pko_saas"`
	OLMSaas    string `json:"olm_saas"`
}

// ClusterOutput is the JSON output for a single cluster+operator check
type ClusterOutput struct {
	ScriptVersion  string                 `json:"script_version"`
	ClusterID      string                 `json:"cluster_id"`
	ClusterName    string                 `json:"cluster_name"`
	ClusterType    string                 `json:"cluster_type"`
	HiveShard      string                 `json:"hive_shard"`
	ClusterVersion string                 `json:"cluster_version"`
	OperatorName   string                 `json:"operator_name"`
	OperatorVersion string               `json:"operator_version"`
	OperatorImage  string                 `json:"operator_image"`
	Namespace      string                 `json:"namespace"`
	Deployment     string                 `json:"deployment"`
	Timestamp      string                 `json:"timestamp"`
	ClusterMetadata map[string]interface{} `json:"cluster_metadata"`
	BackplaneLogin  map[string]interface{} `json:"backplane_login"`
	HealthSummary   HealthSummary          `json:"health_summary"`
	HealthChecks    []Result               `json:"health_checks"`
	APIErrors       []APIError             `json:"api_errors"`
	Events          map[string]interface{} `json:"events"`
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

	Client   *kube.Client
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

// RunAndRecord executes a kube command and records any error
func (cc *ClusterContext) RunAndRecord(description string, result *kube.Result) {
	if result.ExitCode != 0 {
		errType := "api_error"
		lower := strings.ToLower(result.Stderr)
		if strings.Contains(lower, "command not found") || strings.Contains(lower, "no such file") {
			errType = "script_error"
		}
		cc.APIErrors = append(cc.APIErrors, APIError{
			Operation:    description,
			ErrorMessage: strings.TrimSpace(result.Stderr),
			Command:      result.Command,
			Check:        cc.CurrentCheck,
			ErrorType:    errType,
			ExitCode:     result.ExitCode,
			Timestamp:    time.Now().UTC().Format(time.RFC3339),
		})
	}
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
		ScriptVersion:  version,
		ClusterID:      cc.ClusterID,
		ClusterName:    cc.ClusterName,
		ClusterType:    cc.ClusterType,
		HiveShard:      cc.HiveShard,
		ClusterVersion: cc.ClusterVersion,
		OperatorName:   cc.Operator.Name,
		Namespace:      cc.Operator.Namespace,
		Deployment:     cc.Operator.Deployment,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
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

	AllOperators = map[string]OperatorConfig{
		"camo": CAMOConfig,
		"rmo":  RMOConfig,
		"ome":  OMEConfig,
	}
)
