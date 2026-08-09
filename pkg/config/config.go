package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config holds default settings loaded from a config file.
// CLI flags override any values set here.
type Config struct {
	// Cluster selection
	ClusterList string   `yaml:"cluster_list"`
	ListClusters string  `yaml:"list_clusters"`
	Exclude     string   `yaml:"exclude"`
	Include     string   `yaml:"include"`

	// Operators
	Operators   []string `yaml:"operators"`

	// Execution
	Reason      string   `yaml:"reason"`
	Parallel    int      `yaml:"parallel"`
	NoElevate   bool     `yaml:"no_elevate"`
	SaasOnly    bool     `yaml:"saas_only"`
	NoHTML      bool     `yaml:"no_html"`

	// OCM
	OCMConfig   string   `yaml:"ocm_config"`
	OCMURL      string   `yaml:"ocm_url"`

	// Logging
	LogLevel    string   `yaml:"log_level"`
	LogDir      string   `yaml:"log_dir"`

	// Operator-specific configuration
	RLR         *RLRConfig `yaml:"rlr,omitempty"`
}

// RLRConfig holds per-environment configuration for rosa-log-router
// central pipeline checks. Values are sensitive (AWS account IDs, queue
// names) and must NOT be committed to the codebase — load from a local
// config file only.
type RLRConfig struct {
	Environments map[string]RLREnvConfig `yaml:"environments"`
}

// RLREnvConfig holds AWS resource identifiers for one RLR environment.
type RLREnvConfig struct {
	CentralAccountID     string `yaml:"central_account_id"`
	AWSProfile           string `yaml:"aws_profile"`
	LambdaFunctionName   string `yaml:"lambda_function_name"`
	AuthorizerFunctionName string `yaml:"authorizer_function_name"`
	SQSQueueName         string `yaml:"sqs_queue_name"`
	SQSDLQName           string `yaml:"sqs_dlq_name"`
	DynamoDBTable        string `yaml:"dynamodb_table"`
	APIEndpointPattern   string `yaml:"api_endpoint_pattern"`
	MetricsNamespace     string `yaml:"metrics_namespace"`
	Regions              []string `yaml:"regions"`
}

// RLREnvForOCMURL returns the RLR environment config matching the OCM URL.
func (c *Config) RLREnvForOCMURL(ocmURL string) *RLREnvConfig {
	if c.RLR == nil {
		return nil
	}
	var envKey string
	switch {
	case strings.Contains(ocmURL, "integration"):
		envKey = "integration"
	case strings.Contains(ocmURL, "stage"):
		envKey = "staging"
	default:
		envKey = "production"
	}
	if env, ok := c.RLR.Environments[envKey]; ok {
		return &env
	}
	return nil
}

// Load reads the config file from the search path.
// Search order: --config flag, ./.healthcheck.yaml, ~/.config/healthcheck/config.yaml
// Returns an empty config (no error) if no file is found.
func Load(explicitPath string) (*Config, string, error) {
	paths := []string{}

	if explicitPath != "" {
		paths = append(paths, explicitPath)
	} else {
		// Current directory
		paths = append(paths, ".healthcheck.yaml")
		paths = append(paths, ".healthcheck.yml")

		// User config dir
		if configDir, err := os.UserConfigDir(); err == nil {
			paths = append(paths, filepath.Join(configDir, "healthcheck", "config.yaml"))
			paths = append(paths, filepath.Join(configDir, "healthcheck", "config.yml"))
		}

		// Home directory
		if home, err := os.UserHomeDir(); err == nil {
			paths = append(paths, filepath.Join(home, ".healthcheck.yaml"))
		}
	}

	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var cfg Config
		if err := yaml.Unmarshal(data, &cfg); err != nil {
			return nil, path, fmt.Errorf("parsing config %s: %w", path, err)
		}
		return &cfg, path, nil
	}

	return &Config{}, "", nil
}
