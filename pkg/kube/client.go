package kube

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/openshift/operator-health-report/pkg/logging"

	// Native SDK imports — will replace exec-based approach incrementally
	// sdk "github.com/openshift-online/ocm-sdk-go"
	// bpconfig "github.com/openshift/backplane-cli/pkg/backplaneapi"
	// bplogin "github.com/openshift/backplane-cli/pkg/login"
	// "k8s.io/client-go/kubernetes"
	// "k8s.io/client-go/rest"
	// ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"
)

// ClusterConnection holds all connections needed to interact with a cluster.
// Supports multiple OCM environments (e.g., staging cluster + production hive).
// TODO: Migrate from exec-based to native OCM SDK + backplane-cli connections.
// When migrated, this will hold:
//   - OCMConn *sdk.Connection — for the cluster's OCM environment
//   - RestConfig *rest.Config — k8s REST config via backplane
//   - K8sClient kubernetes.Interface — typed k8s client
//   - HiveOCMConn *sdk.Connection — for hive's OCM environment (may differ)
//   - HiveRestConfig/HiveK8sClient — for hive cluster access
type ClusterConnection struct {
	ClusterID        string
	ElevationReasons []string
	Elevated         bool
}

// ExecResult holds the output of a CLI command execution (for oc/kubectl fallback)
type ExecResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
	Command  string // the equivalent CLI command for reproduction
	Duration time.Duration
	Cached   bool
}

// Error returns a formatted error if the command failed
func (r *ExecResult) Error() error {
	if r.ExitCode == 0 {
		return nil
	}
	return fmt.Errorf("command failed (rc=%d): %s\n  stderr: %s\n  reproduce with: %s",
		r.ExitCode, r.Stdout, r.Stderr, r.Command)
}

// ClientConfig holds settings for creating clients
type ClientConfig struct {
	Reason     string
	CacheDir   string
	Replay     bool
	NoElevate  bool
	cacheSeq   map[string]int
}

// NewClientConfig creates a new client configuration
func NewClientConfig(reason string) *ClientConfig {
	return &ClientConfig{
		Reason:   reason,
		cacheSeq: make(map[string]int),
	}
}

// ExecCommand runs a CLI command with caching and error logging.
// Use this for commands that don't have native Go SDK equivalents,
// or when you want the user to see the exact command they can reproduce.
func (c *ClientConfig) ExecCommand(ctx context.Context, description string, args ...string) *ExecResult {
	command := strings.Join(args, " ")

	log := logging.Log

	// Check no-elevate
	if c.NoElevate && strings.Contains(command, "backplane elevate") {
		log.WithField("command", command).Debug("Skipped — no-elevate mode")
		return &ExecResult{Command: command}
	}

	// Try cache/replay
	if c.CacheDir != "" {
		if c.Replay {
			return c.readCache(description, command)
		}
	}

	// Execute
	log.WithFields(map[string]interface{}{
		"description": description,
		"command":     command,
	}).Debug("Executing command")

	start := time.Now()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	var stdoutBuf, stderrBuf strings.Builder
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf
	err := cmd.Run()

	result := &ExecResult{
		Stdout:   stdoutBuf.String(),
		Stderr:   stderrBuf.String(),
		ExitCode: 0,
		Command:  command,
		Duration: time.Since(start),
	}

	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			result.ExitCode = exitErr.ExitCode()
		} else {
			result.ExitCode = 1
			result.Stderr = err.Error()
		}
		log.WithFields(map[string]interface{}{
			"description": description,
			"exit_code":   result.ExitCode,
			"stderr":      strings.TrimSpace(result.Stderr),
			"command":     command,
			"duration":    result.Duration.String(),
		}).Warn("Command failed")
	} else {
		log.WithFields(map[string]interface{}{
			"description":   description,
			"duration":      result.Duration.String(),
			"stdout_length": len(result.Stdout),
		}).Debug("Command succeeded")
	}

	// Cache the result
	if c.CacheDir != "" {
		c.writeCache(description, result)
	}

	return result
}

// ExecOC runs an oc command (not elevated)
func (c *ClientConfig) ExecOC(ctx context.Context, description string, args ...string) *ExecResult {
	fullArgs := append([]string{"oc"}, args...)
	return c.ExecCommand(ctx, description, fullArgs...)
}

// ExecElevated runs an elevated oc command via ocm backplane elevate
func (c *ClientConfig) ExecElevated(ctx context.Context, description string, args ...string) *ExecResult {
	fullArgs := append([]string{"ocm", "backplane", "elevate", c.Reason, "--"}, args...)
	return c.ExecCommand(ctx, description, fullArgs...)
}

// ExecThanos runs a PromQL query against Thanos via exec into the pod.
// Logs the equivalent oc command for the user to reproduce.
func (c *ClientConfig) ExecThanos(ctx context.Context, description, query string) *ExecResult {
	return c.ExecElevated(ctx, description,
		"exec", "-n", "openshift-monitoring",
		"deployment/thanos-querier", "-c", "thanos-query", "--",
		"wget", "-q", "-T", "30", "-O-",
		fmt.Sprintf("http://localhost:9090/api/v1/query?query=%s", query),
	)
}

// ExecRHOBSPrometheus runs a PromQL query against the RHOBS Prometheus on MCs
func (c *ClientConfig) ExecRHOBSPrometheus(ctx context.Context, description, query string) *ExecResult {
	return c.ExecElevated(ctx, description,
		"exec", "-n", "openshift-observability-operator",
		"statefulset/prometheus-rhobs-hypershift-monitoring-stack", "-c", "prometheus", "--",
		"curl", "-sf", "--max-time", "30",
		fmt.Sprintf("http://localhost:9090/api/v1/query?query=%s", query),
	)
}

// Cache operations

func (c *ClientConfig) cacheKey(description string) string {
	safe := strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
			return r
		}
		return '_'
	}, description)
	if len(safe) > 80 {
		safe = safe[:80]
	}
	seq := c.cacheSeq[safe]
	c.cacheSeq[safe] = seq + 1
	return fmt.Sprintf("%s_%d", safe, seq)
}

func (c *ClientConfig) writeCache(description string, result *ExecResult) {
	key := c.cacheKey(description)
	os.WriteFile(filepath.Join(c.CacheDir, key+".out"), []byte(result.Stdout), 0644)
	os.WriteFile(filepath.Join(c.CacheDir, key+".err"), []byte(result.Stderr), 0644)
	os.WriteFile(filepath.Join(c.CacheDir, key+".rc"), []byte(fmt.Sprintf("%d", result.ExitCode)), 0644)
	os.WriteFile(filepath.Join(c.CacheDir, key+".cmd"), []byte(result.Command), 0644)
}

func (c *ClientConfig) readCache(description, command string) *ExecResult {
	key := c.cacheKey(description)
	dir := c.CacheDir

	stdout, err := os.ReadFile(filepath.Join(dir, key+".out"))
	if err != nil {
		return &ExecResult{
			ExitCode: 1,
			Stderr:   fmt.Sprintf("cache miss: %s", description),
			Command:  command,
			Cached:   true,
		}
	}

	stderr, _ := os.ReadFile(filepath.Join(dir, key+".err"))
	rcBytes, _ := os.ReadFile(filepath.Join(dir, key+".rc"))
	rc := 0
	fmt.Sscanf(string(rcBytes), "%d", &rc)

	hash := fmt.Sprintf("%x", sha256.Sum256([]byte(key)))
	os.WriteFile(filepath.Join(dir, key+".consumed"), []byte(hash), 0644)

	return &ExecResult{
		Stdout:   string(stdout),
		Stderr:   string(stderr),
		ExitCode: rc,
		Command:  command,
		Cached:   true,
	}
}

// Placeholder for native OCM/backplane connection functions.
// These will replace the ExecCommand-based approach for production use.
// For now, the ExecCommand approach works and logs the exact CLI commands.

// TODO: ConnectToCluster — native OCM SDK + backplane-cli connection
// Will replace exec-based approach. See osdctl pkg/k8s/client.go for patterns:
//   - NewWithConn(clusterID, options, ocmConn) for standard connection
//   - NewAsBackplaneClusterAdminWithConn(clusterID, options, ocmConn, reasons...) for elevated
//   - GetHiveBPClientForCluster(clusterID, options, reason, hiveOCMURL) for cross-env hive
