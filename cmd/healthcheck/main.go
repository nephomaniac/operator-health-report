package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/kube"
	"github.com/openshift/operator-health-report/pkg/logging"
)

var version = "dev"

func main() {
	var (
		clusterList string
		reason      string
		operators   stringSlice
		noElevate   bool
		cacheDir    string
		replay      bool
		outputFile  string
		noHTML      bool
		logLevel    string
		logDir      string
	)

	flag.StringVar(&clusterList, "cluster-list", "", "File with cluster IDs (one per line)")
	flag.StringVar(&reason, "reason", "", "OCM elevation reason (JIRA ticket)")
	flag.Var(&operators, "oper", "Operator to check: camo, rmo, ome (repeatable)")
	flag.BoolVar(&noElevate, "no-elevate", false, "Skip all backplane elevation commands")
	flag.StringVar(&cacheDir, "cache-dir", "", "Save/read oc outputs for offline replay")
	flag.BoolVar(&replay, "replay", false, "Read from cache instead of running commands")
	flag.StringVar(&outputFile, "output", "", "Output JSON file (default: health_TIMESTAMP.json)")
	flag.BoolVar(&noHTML, "no-html", false, "Skip HTML report generation")
	flag.StringVar(&logLevel, "log-level", "info", "Log level: debug, info, warn, error")
	flag.StringVar(&logDir, "log-dir", "", "Directory for debug log file (captures all levels)")
	flag.Parse()

	// Configure logging
	logging.SetLevel(logLevel)
	if logDir != "" {
		logPath, err := logging.EnableDebugFile(logDir)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to create debug log: %v\n", err)
		} else {
			defer logging.CloseDebugFile()
			logging.Log.Infof("Debug log: %s", logPath)
		}
	}

	_ = logging.Log

	if clusterList == "" {
		fmt.Fprintln(os.Stderr, "Error: --cluster-list is required")
		flag.Usage()
		os.Exit(1)
	}

	if reason == "" {
		reason = "operator health check"
	}

	// Default to all operators if none specified
	if len(operators) == 0 {
		operators = []string{"camo", "rmo", "ome"}
	}

	// Resolve operator configs
	var opConfigs []checks.OperatorConfig
	for _, op := range operators {
		cfg, ok := checks.AllOperators[op]
		if !ok {
			fmt.Fprintf(os.Stderr, "Error: unknown operator %q (valid: camo, rmo, ome)\n", op)
			os.Exit(1)
		}
		opConfigs = append(opConfigs, cfg)
	}

	// Detect production environment
	if !noElevate {
		ocmURL := detectOCMEnv()
		if strings.Contains(ocmURL, "api.openshift.com") || strings.Contains(ocmURL, "production") {
			fmt.Fprintln(os.Stderr, "")
			fmt.Fprintln(os.Stderr, "================================================================================")
			fmt.Fprintln(os.Stderr, "⚠  PRODUCTION ENVIRONMENT DETECTED — defaulting to --no-elevate")
			fmt.Fprintln(os.Stderr, "================================================================================")
			fmt.Fprintln(os.Stderr, "")
			noElevate = true
		}
	}

	// Read cluster IDs
	clusterIDs, err := readClusterList(clusterList)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading cluster list: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "Clusters: %d, Operators: %v, No-elevate: %v\n", len(clusterIDs), operators, noElevate)

	// Output file
	if outputFile == "" {
		outputFile = fmt.Sprintf("health_%s.json", time.Now().Format("20060102_150405"))
	}

	// Process each cluster
	var allOutputs []checks.ClusterOutput
	var mu sync.Mutex

	for i, clusterID := range clusterIDs {
		fmt.Fprintf(os.Stderr, "\n[%d/%d] Processing cluster: %s\n", i+1, len(clusterIDs), clusterID)

		// Login
		loginResult := loginToCluster(clusterID)
		if loginResult.ExitCode != 0 {
			fmt.Fprintf(os.Stderr, "✗ Failed to login to %s: %s\n", clusterID, loginResult.Stderr)
			continue
		}
		fmt.Fprintf(os.Stderr, "✓ Logged in to %s\n", clusterID)

		// Detect cluster info
		clusterName := detectClusterName()
		clusterVersion := detectClusterVersion()
		clusterType := detectClusterType(clusterName)
		hiveShard := detectHiveShard(clusterID)

		// Run operators in parallel
		var wg sync.WaitGroup
		for _, opCfg := range opConfigs {
			wg.Add(1)
			go func(op checks.OperatorConfig) {
				defer wg.Done()

				client := kube.NewClientConfig(reason)
				client.NoElevate = noElevate
				client.CacheDir = cacheDir
				client.Replay = replay

				cc := &checks.ClusterContext{
					ClusterID:      clusterID,
					ClusterName:    clusterName,
					ClusterVersion: clusterVersion,
					ClusterType:    clusterType,
					HiveShard:      hiveShard,
					Client:         client,
					Operator:       op,
				}

				ctx := context.Background()
				checks.RunAllCommonChecks(ctx, cc)

				output := cc.ToOutput(version)
				output.OperatorVersion = detectOperatorVersion(ctx, client, op)

				mu.Lock()
				allOutputs = append(allOutputs, output)
				mu.Unlock()

				fmt.Fprintf(os.Stderr, "  ✓ %s: %s (%d checks)\n",
					strings.ToUpper(op.ShortName), cc.OverallStatus(), len(cc.Results))
			}(opCfg)
		}
		wg.Wait()

		// Logout
		logoutFromCluster()
	}

	// Write JSON output
	data, err := json.MarshalIndent(allOutputs, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error marshaling JSON: %v\n", err)
		os.Exit(1)
	}
	if err := os.WriteFile(outputFile, data, 0644); err != nil {
		fmt.Fprintf(os.Stderr, "Error writing output: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "\nResults written to: %s (%d entries)\n", outputFile, len(allOutputs))

	// Generate HTML using the bash script (reuse existing HTML generation)
	if !noHTML {
		htmlFile := strings.TrimSuffix(outputFile, ".json") + ".html"
		htmlClient := kube.NewClientConfig("")
		htmlResult := htmlClient.ExecCommand(context.Background(), "Generate HTML report",
			"bash", "lib/generate_html_report.sh", outputFile, htmlFile)
		if htmlResult.ExitCode == 0 {
			fmt.Fprintf(os.Stderr, "HTML report: %s\n", htmlFile)
		}
	}
}

// Helper types and functions

type stringSlice []string

func (s *stringSlice) String() string { return strings.Join(*s, ",") }
func (s *stringSlice) Set(v string) error {
	*s = append(*s, v)
	return nil
}

func readClusterList(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Handle lines with "ID NAME ..." format — take first field
		fields := strings.Fields(line)
		if len(fields) > 0 {
			ids = append(ids, fields[0])
		}
	}
	return ids, nil
}

func detectOCMEnv() string {
	r := execSimple("ocm", "config", "get", "url")
	return strings.TrimSpace(r)
}

func loginToCluster(clusterID string) *kube.ExecResult {
	client := kube.NewClientConfig("")
	return client.ExecCommand(context.Background(), "backplane login",
		"ocm", "backplane", "login", clusterID)
}

func logoutFromCluster() {
	client := kube.NewClientConfig("")
	client.ExecCommand(context.Background(), "backplane logout", "ocm", "backplane", "logout")
}

func detectClusterName() string {
	r := execSimple("ocm", "backplane", "status")
	for _, line := range strings.Split(r, "\n") {
		if strings.Contains(line, "Cluster Name:") {
			parts := strings.Fields(line)
			if len(parts) >= 3 {
				return parts[len(parts)-1]
			}
		}
	}
	return "unknown"
}

func detectClusterVersion() string {
	r := execSimple("oc", "get", "clusterversion", "version", "-o", "jsonpath={.status.desired.version}")
	if r == "" {
		return "unknown"
	}
	return strings.TrimSpace(r)
}

func detectClusterType(name string) string {
	switch {
	case strings.HasPrefix(name, "hs-mc-"):
		return "management_cluster"
	case strings.HasPrefix(name, "hs-sc-"):
		return "service_cluster"
	default:
		return "standard"
	}
}

func detectHiveShard(clusterID string) string {
	r := execSimple("ocm", "get", fmt.Sprintf("/api/clusters_mgmt/v1/clusters/%s/provision_shard", clusterID))
	var shard map[string]interface{}
	if err := json.Unmarshal([]byte(r), &shard); err == nil {
		if hive, ok := shard["hive_config"].(map[string]interface{}); ok {
			if server, ok := hive["server"].(string); ok {
				// Extract shard name: https://api.hive-stage-01.xxx -> hive-stage-01
				parts := strings.Split(server, ".")
				if len(parts) > 1 {
					return strings.TrimPrefix(parts[0], "https://api")
					// Actually extract properly
				}
				for _, p := range parts {
					if strings.HasPrefix(p, "hive") {
						return p
					}
				}
			}
		}
	}
	return "unknown"
}

func detectOperatorVersion(ctx context.Context, client *kube.ClientConfig, op checks.OperatorConfig) string {
	result := client.ExecOC(ctx, "Get operator image",
		"get", "deployment", "-n", op.Namespace, op.Deployment,
		"-o", "jsonpath={.spec.template.spec.containers[0].image}")
	if result.ExitCode != 0 || result.Stdout == "" {
		return "unknown"
	}
	image := strings.TrimSpace(result.Stdout)
	// Extract version from image tag: quay.io/app-sre/operator:v0.1.100-gabcdef -> abcdef
	if idx := strings.LastIndex(image, ":"); idx >= 0 {
		tag := image[idx+1:]
		if gIdx := strings.LastIndex(tag, "-g"); gIdx >= 0 {
			return tag[gIdx+2:]
		}
		return tag
	}
	if idx := strings.LastIndex(image, "@"); idx >= 0 {
		return image[idx+1 : min(idx+13, len(image))]
	}
	return "unknown"
}

func execSimple(args ...string) string {
	client := kube.NewClientConfig("")
	result := client.ExecCommand(context.Background(), "detect", args...)
	return result.Stdout
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
