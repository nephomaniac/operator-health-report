package kube

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Result holds the output of a command execution
type Result struct {
	Stdout   string
	Stderr   string
	ExitCode int
	Command  string // the equivalent oc/ocm CLI command
	Duration time.Duration
	Cached   bool
}

// Error returns a formatted error if the command failed
func (r *Result) Error() error {
	if r.ExitCode == 0 {
		return nil
	}
	return fmt.Errorf("command failed (rc=%d): %s\n  stderr: %s\n  reproduce with: %s",
		r.ExitCode, r.Stdout, r.Stderr, r.Command)
}

// Client wraps oc/ocm command execution with caching, elevation control, and CLI logging
type Client struct {
	Reason     string
	CacheDir   string
	Replay     bool
	NoElevate  bool
	cacheSeq   map[string]int
}

// NewClient creates a new kube client
func NewClient(reason string) *Client {
	return &Client{
		Reason:   reason,
		cacheSeq: make(map[string]int),
	}
}

// Run executes a command and returns the result.
// The description is used for logging and cache keys.
// The command parts are joined into a shell command string.
func (c *Client) Run(ctx context.Context, description string, args ...string) *Result {
	command := strings.Join(args, " ")

	// Check no-elevate
	if c.NoElevate && strings.Contains(command, "backplane elevate") {
		return &Result{
			Command: command,
			Cached:  false,
		}
	}

	// Try cache/replay
	if c.CacheDir != "" {
		if c.Replay {
			return c.readCache(description, command)
		}
	}

	// Execute
	start := time.Now()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()

	result := &Result{
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
		ExitCode: 0,
		Command:  command,
		Duration: time.Since(start),
	}

	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			result.ExitCode = exitErr.ExitCode()
		} else {
			result.ExitCode = 1
		}
	}

	// Cache the result
	if c.CacheDir != "" {
		c.writeCache(description, result)
	}

	return result
}

// RunOC runs an oc command (not elevated)
func (c *Client) RunOC(ctx context.Context, description string, args ...string) *Result {
	fullArgs := append([]string{"oc"}, args...)
	return c.Run(ctx, description, fullArgs...)
}

// RunElevated runs an elevated oc command via ocm backplane elevate
func (c *Client) RunElevated(ctx context.Context, description string, args ...string) *Result {
	fullArgs := append([]string{"ocm", "backplane", "elevate", c.Reason, "--"}, args...)
	return c.Run(ctx, description, fullArgs...)
}

// RunOCM runs an ocm API command
func (c *Client) RunOCM(ctx context.Context, description string, args ...string) *Result {
	fullArgs := append([]string{"ocm"}, args...)
	return c.Run(ctx, description, fullArgs...)
}

// ExecThanos runs a query against Thanos via exec into the thanos-querier pod
func (c *Client) ExecThanos(ctx context.Context, description, query string) *Result {
	encodedQuery := query // caller should URL-encode if needed
	return c.RunElevated(ctx, description,
		"exec", "-n", "openshift-monitoring",
		"deployment/thanos-querier", "-c", "thanos-query", "--",
		"wget", "-q", "-T", "30", "-O-",
		fmt.Sprintf("http://localhost:9090/api/v1/query?query=%s", encodedQuery),
	)
}

// ExecRHOBSPrometheus runs a query against the RHOBS Prometheus on MCs
func (c *Client) ExecRHOBSPrometheus(ctx context.Context, description, query string) *Result {
	return c.RunElevated(ctx, description,
		"exec", "-n", "openshift-observability-operator",
		"statefulset/prometheus-rhobs-hypershift-monitoring-stack", "-c", "prometheus", "--",
		"curl", "-sf", "--max-time", "30",
		fmt.Sprintf("http://localhost:9090/api/v1/query?query=%s", query),
	)
}

// cacheKey generates a filesystem-safe cache key from description
func (c *Client) cacheKey(description string) string {
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

func (c *Client) writeCache(description string, result *Result) {
	key := c.cacheKey(description)
	dir := c.CacheDir
	os.WriteFile(filepath.Join(dir, key+".out"), []byte(result.Stdout), 0644)
	os.WriteFile(filepath.Join(dir, key+".err"), []byte(result.Stderr), 0644)
	os.WriteFile(filepath.Join(dir, key+".rc"), []byte(fmt.Sprintf("%d", result.ExitCode)), 0644)
	os.WriteFile(filepath.Join(dir, key+".cmd"), []byte(result.Command), 0644)
}

func (c *Client) readCache(description, command string) *Result {
	key := c.cacheKey(description)
	dir := c.CacheDir

	stdout, err := os.ReadFile(filepath.Join(dir, key+".out"))
	if err != nil {
		return &Result{
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

	// Hash-based dedup tracking
	hash := fmt.Sprintf("%x", sha256.Sum256([]byte(key)))
	os.WriteFile(filepath.Join(dir, key+".consumed"), []byte(hash), 0644)

	return &Result{
		Stdout:   string(stdout),
		Stderr:   string(stderr),
		ExitCode: rc,
		Command:  command,
		Cached:   true,
	}
}
