package byoc

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/logging"
)

func init() {
	checks.Register(&BYOCChecker{})
}

// CheckDef defines a single BYOC check loaded from --byof or synthesized from --byoc.
type CheckDef struct {
	Name            string `json:"name"`
	Command         string `json:"command"`
	ExpectedExit    *int   `json:"expected_exit_code,omitempty"`
	OutputRegex     string `json:"output_regex,omitempty"`
	OutputNotRegex  string `json:"output_not_regex,omitempty"`
	Severity        string `json:"severity,omitempty"`
	Description     string `json:"description,omitempty"`
	TimeoutSeconds  int    `json:"timeout_seconds,omitempty"`
}

// CheckDefs holds the loaded check definitions, set by main.go before checks run.
var CheckDefs []CheckDef

// LoadCheckDefs loads check definitions from a JSON file.
func LoadCheckDefs(path string) ([]CheckDef, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	var defs []CheckDef
	if err := json.Unmarshal(data, &defs); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	for i := range defs {
		if defs[i].Name == "" {
			defs[i].Name = fmt.Sprintf("byoc_check_%d", i+1)
		}
		if defs[i].TimeoutSeconds == 0 {
			defs[i].TimeoutSeconds = 30
		}
	}
	return defs, nil
}

// SingleCommandDef creates a CheckDef from a --byoc command string.
func SingleCommandDef(cmd string) CheckDef {
	return CheckDef{
		Name:           "byoc_command",
		Command:        cmd,
		Description:    "Ad-hoc command via --byoc",
		TimeoutSeconds: 30,
	}
}

type BYOCChecker struct{}

func (c *BYOCChecker) Name() string { return "byoc" }

func (c *BYOCChecker) RunChecks(ctx context.Context, cc *checks.ClusterContext) {
	if len(CheckDefs) == 0 {
		return
	}

	for _, def := range CheckDefs {
		if checks.Cancelled(ctx) {
			return
		}
		runCheck(ctx, cc, def)
	}
}

func runCheck(ctx context.Context, cc *checks.ClusterContext, def CheckDef) {
	checkName := sanitizeCheckName(def.Name)
	cc.SetCheck(checkName)
	log := logging.WithCheck(checkName)

	severity := checks.SeverityWarning
	switch strings.ToLower(def.Severity) {
	case "critical":
		severity = checks.SeverityCritical
	case "info":
		severity = checks.SeverityInfo
	}

	r := checks.Result{
		Check:    checkName,
		Severity: severity,
		Details: map[string]any{
			"command": def.Command,
		},
	}
	if def.Description != "" {
		r.Details["description"] = def.Description
	}

	timeout := time.Duration(def.TimeoutSeconds) * time.Second
	cmdCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(cmdCtx, "bash", "-c", def.Command)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}

	// Set KUBECONFIG so oc/kubectl commands target the connected cluster
	if cc.Client != nil {
		if kcPath := cc.Client.KubeconfigPath(); kcPath != "" {
			cmd.Env = append(os.Environ(), "KUBECONFIG="+kcPath)
		}
	}

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	startTime := time.Now()
	err := cmd.Run()
	duration := time.Since(startTime)

	r.Details["duration_ms"] = duration.Milliseconds()
	r.Details["stdout"] = truncateOutput(stdout.String(), 4096)
	if stderr.Len() > 0 {
		r.Details["stderr"] = truncateOutput(stderr.String(), 2048)
	}

	exitCode := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else if cmdCtx.Err() == context.DeadlineExceeded {
			r.Status = checks.StatusFail
			r.Severity = checks.SeverityCritical
			r.Message = fmt.Sprintf("Command timed out after %ds", def.TimeoutSeconds)
			r.Details["exit_code"] = -1
			r.Details["timed_out"] = true
			cc.AddResult(r)
			return
		} else {
			cc.RecordError("BYOC exec: "+def.Name, err)
			r.Status = checks.StatusFail
			r.Message = fmt.Sprintf("Command failed to execute: %v", err)
			r.Details["exit_code"] = -1
			cc.AddResult(r)
			return
		}
	}

	r.Details["exit_code"] = exitCode
	log.WithField("exit_code", exitCode).WithField("duration_ms", duration.Milliseconds()).Debug("Command completed")

	// Evaluate against criteria
	issues := []string{}

	// Exit code check
	expectedExit := 0
	if def.ExpectedExit != nil {
		expectedExit = *def.ExpectedExit
	}
	if exitCode != expectedExit {
		issues = append(issues, fmt.Sprintf("exit code %d (expected %d)", exitCode, expectedExit))
	}

	// Trim stdout for regex matching (wc, awk etc. may add leading/trailing whitespace)
	trimmedOut := strings.TrimSpace(stdout.String())

	// Output regex match
	if def.OutputRegex != "" {
		re, compileErr := regexp.Compile(def.OutputRegex)
		if compileErr != nil {
			issues = append(issues, fmt.Sprintf("invalid output_regex %q: %v", def.OutputRegex, compileErr))
		} else if !re.MatchString(trimmedOut) {
			issues = append(issues, fmt.Sprintf("output did not match regex %q", def.OutputRegex))
			r.Details["regex_matched"] = false
		} else {
			r.Details["regex_matched"] = true
		}
	}

	// Output not-regex match
	if def.OutputNotRegex != "" {
		re, compileErr := regexp.Compile(def.OutputNotRegex)
		if compileErr != nil {
			issues = append(issues, fmt.Sprintf("invalid output_not_regex %q: %v", def.OutputNotRegex, compileErr))
		} else if re.MatchString(trimmedOut) {
			issues = append(issues, fmt.Sprintf("output matched exclusion regex %q", def.OutputNotRegex))
			r.Details["not_regex_violated"] = true
		}
	}

	if len(issues) > 0 {
		r.Status = checks.StatusFail
		r.Message = strings.Join(issues, "; ")
	} else {
		r.Status = checks.StatusPass
		outPreview := truncateOutput(strings.TrimSpace(stdout.String()), 120)
		if outPreview != "" {
			r.Message = fmt.Sprintf("OK (exit %d): %s", exitCode, outPreview)
		} else {
			r.Message = fmt.Sprintf("OK (exit %d)", exitCode)
		}
	}

	cc.AddResult(r)
}

func sanitizeCheckName(name string) string {
	name = strings.ToLower(name)
	name = strings.ReplaceAll(name, " ", "_")
	name = strings.ReplaceAll(name, "-", "_")
	safe := strings.Builder{}
	for _, c := range name {
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' {
			safe.WriteRune(c)
		}
	}
	result := safe.String()
	if result == "" {
		return "byoc_unnamed"
	}
	return result
}

func truncateOutput(s string, maxLen int) string {
	s = strings.TrimSpace(s)
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "... (truncated)"
}
