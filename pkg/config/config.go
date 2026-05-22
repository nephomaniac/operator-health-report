package config

import (
	"fmt"
	"os"
	"path/filepath"

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
