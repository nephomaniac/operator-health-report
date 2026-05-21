package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/kube"
	"github.com/openshift/operator-health-report/pkg/logging"
	"github.com/openshift/operator-health-report/pkg/ocm"
	"github.com/openshift/operator-health-report/pkg/saas"

	cmv1 "github.com/openshift-online/ocm-sdk-go/clustersmgmt/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	// Import operator checkers for init() registration
	_ "github.com/openshift/operator-health-report/pkg/checks/camo"
	_ "github.com/openshift/operator-health-report/pkg/checks/ome"
	_ "github.com/openshift/operator-health-report/pkg/checks/rmo"
)

var version = "dev"

func main() {
	var (
		clusterList  string
		reason       string
		operators    stringSlice
		noElevate    bool
		parallel     int
		outputFile   string
		noHTML       bool
		logLevel     string
		logDir       string
		ocmConfig      string
		ocmURL         string
		listClusters   string
		excludePattern string
		includePattern string
	)

	flag.StringVar(&clusterList, "cluster-list", "", "File with cluster IDs (one per line)")
	flag.StringVar(&reason, "reason", "", "OCM elevation reason (JIRA ticket)")
	flag.Var(&operators, "oper", "Operator to check: camo, rmo, ome (repeatable)")
	flag.BoolVar(&noElevate, "no-elevate", false, "Skip all backplane elevation commands")
	flag.IntVar(&parallel, "parallel", 1, "Number of clusters to process concurrently")
	flag.StringVar(&outputFile, "output", "", "Output JSON file (default: health_TIMESTAMP.json)")
	flag.BoolVar(&noHTML, "no-html", false, "Skip HTML report generation")
	flag.StringVar(&logLevel, "log-level", "info", "Log level: debug, info, warn, error")
	flag.StringVar(&logDir, "log-dir", "", "Directory for debug log file (captures all levels)")
	flag.StringVar(&ocmConfig, "ocm-config", "", "Path to OCM config file (default: $OCM_CONFIG or ~/.config/ocm/ocm.json)")
	flag.StringVar(&ocmURL, "ocm-url", "", "OCM API URL override (e.g., https://api.stage.openshift.com)")
	flag.StringVar(&listClusters, "list-clusters", "", "List clusters and exit (all, rosa, osd, hypershift, or custom OCM search)")
	flag.StringVar(&excludePattern, "exclude", "", "Regex to exclude clusters by name (e.g., 'osde2e|cse2e')")
	flag.StringVar(&includePattern, "include", "", "Regex to include only clusters matching by name")
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

	// List clusters mode — query OCM and exit
	if listClusters != "" {
		ocmClient, err := ocm.NewClientWithOptions(ocm.Options{ConfigFile: ocmConfig, URL: ocmURL})
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		defer ocmClient.Close()
		if err := runListClusters(ocmClient, listClusters, excludePattern, includePattern); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		os.Exit(0)
	}

	if clusterList == "" {
		fmt.Fprintln(os.Stderr, "Error: --cluster-list is required")
		flag.Usage()
		os.Exit(1)
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

	// Read cluster IDs first so we can estimate runtime for token check
	clusterIDs, err := readClusterList(clusterList)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading cluster list: %v\n", err)
		os.Exit(1)
	}

	if parallel < 1 {
		parallel = 1
	}
	if parallel > len(clusterIDs) {
		parallel = len(clusterIDs)
	}

	// Create OCM SDK connection — checks token validity based on workload size and concurrency
	ocmClient, err := ocm.NewClientWithOptions(ocm.Options{
		ConfigFile:    ocmConfig,
		URL:           ocmURL,
		ClusterCount:  len(clusterIDs),
		OperatorCount: len(opConfigs),
		Parallelism:   parallel,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: failed to connect to OCM: %v\n", err)
		os.Exit(1)
	}
	defer ocmClient.Close()

	ocmEnv := ocmClient.URL()
	isProd := ocmClient.IsProduction()

	if isProd && !noElevate {
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "================================================================================")
		fmt.Fprintln(os.Stderr, "⚠  PRODUCTION ENVIRONMENT DETECTED — defaulting to --no-elevate")
		fmt.Fprintln(os.Stderr, "================================================================================")
		fmt.Fprintln(os.Stderr, "")
		noElevate = true
	}

	if reason == "" {
		if isProd {
			fmt.Fprintln(os.Stderr, "Error: --reason is required for production environments (provide a JIRA ticket)")
			os.Exit(1)
		}
		reason = "operator health check"
	}

	fmt.Fprintf(os.Stderr, "Clusters: %d, Operators: %v, No-elevate: %v, OCM: %s\n",
		len(clusterIDs), operators, noElevate, ocmClient.Environment())

	// Output file
	if outputFile == "" {
		outputFile = fmt.Sprintf("health_report_%s.json", time.Now().Format("2006-01-02_1504"))
	}

	// Fetch SAAS targets for all operators (metadata for the HTML report)
	type saasTargetMeta struct {
		Type         string        `json:"type"`
		OperatorName string        `json:"operator_name"`
		OCMEnv       string        `json:"ocm_environment"`
		Targets      []saas.Target `json:"targets"`
	}
	var saasMetadata []saasTargetMeta
	for _, op := range opConfigs {
		ctx := context.Background()
		targets, err := saas.FetchAllTargets(ctx, op.PKOSaas, op.OLMSaas)
		if err == nil && len(targets) > 0 {
			fmt.Fprintf(os.Stderr, "SAAS targets: %s — %d active targets\n", strings.ToUpper(op.ShortName), len(targets))
		}
		saasMetadata = append(saasMetadata, saasTargetMeta{
			Type:         "saas_targets",
			OperatorName: op.Name,
			OCMEnv:       ocmEnv,
			Targets:      targets,
		})
	}

	// Process clusters — concurrently up to --parallel limit
	var allOutputs []checks.ClusterOutput
	var mu sync.Mutex
	sem := make(chan struct{}, parallel)
	var clusterWg sync.WaitGroup

	for i, clusterID := range clusterIDs {
		clusterWg.Add(1)
		sem <- struct{}{} // acquire semaphore slot

		go func(idx int, cid string) {
			defer clusterWg.Done()
			defer func() { <-sem }() // release semaphore slot

			ctx := context.Background()

			// Fetch cluster metadata from OCM first — skip non-ready and limited-support clusters
			meta, metaErr := ocmClient.GetClusterMetadata(cid)
			if metaErr != nil {
				fmt.Fprintf(os.Stderr, "\n[%d/%d] ✗ %s: failed to fetch metadata: %v\n", idx+1, len(clusterIDs), cid, metaErr)
				return
			}

			if meta.State != "ready" {
				fmt.Fprintf(os.Stderr, "\n[%d/%d] ⏭ %s (%s): skipping — state is %s\n", idx+1, len(clusterIDs), meta.Name, cid, meta.State)
				return
			}
			if meta.LimitedSupport {
				fmt.Fprintf(os.Stderr, "\n[%d/%d] ⏭ %s (%s): skipping — limited support\n", idx+1, len(clusterIDs), meta.Name, cid)
				return
			}

			fmt.Fprintf(os.Stderr, "\n[%d/%d] Processing: %s (%s, %s, %s)\n", idx+1, len(clusterIDs), meta.Name, meta.Product, meta.Provider, meta.Region)

			client, err := kube.ConnectToClusterWithConn(ctx, cid, reason, noElevate, ocmClient.Conn())
			if err != nil {
				fmt.Fprintf(os.Stderr, "  ✗ Failed to connect to %s: %v\n", meta.Name, err)
				return
			}
			defer client.Disconnect()

			fmt.Fprintf(os.Stderr, "  ✓ Connected to %s\n", meta.Name)

			clusterVersion := meta.Version
			clusterName := meta.Name
			clusterType := kube.DetectClusterType(clusterName)

			hiveShard := "unknown"
			if meta.Shard != "" {
				parts := strings.Split(meta.Shard, ".")
				for _, p := range parts {
					if strings.HasPrefix(p, "hive") {
						hiveShard = p
						break
					}
				}
			}

			// Mask email prefix for privacy
			maskedEmail := meta.OwnerEmail
			if at := strings.Index(maskedEmail, "@"); at > 0 {
				maskedEmail = "xxxx" + maskedEmail[at:]
			}

			// Convert OCM metadata to checks.ClusterMetadata
			clusterMeta := &checks.ClusterMetadata{
				ID:             meta.ID,
				ExternalID:     meta.ExternalID,
				Name:           meta.Name,
				State:          meta.State,
				APIListening:   meta.APIListening,
				Product:        meta.Product,
				Provider:       meta.Provider,
				Version:        meta.Version,
				Region:         meta.Region,
				MultiAZ:        meta.MultiAZ,
				CNIType:        meta.CNIType,
				PrivateLink:    meta.PrivateLink,
				STS:            meta.STS,
				CCS:            meta.CCS,
				Hypershift:     meta.Hypershift,
				ExistingVPC:    meta.ExistingVPC,
				ChannelGroup:   meta.ChannelGroup,
				LimitedSupport: meta.LimitedSupport,
				Shard:          meta.Shard,
				OwnerOrg:       meta.OwnerOrg,
				OwnerEmail:     maskedEmail,
			}

			var wg sync.WaitGroup
			for _, opCfg := range opConfigs {
				wg.Add(1)
				go func(op checks.OperatorConfig) {
					defer wg.Done()

					cc := &checks.ClusterContext{
						ClusterID:      cid,
						ClusterName:    clusterName,
						ClusterVersion: clusterVersion,
						ClusterType:    clusterType,
						HiveShard:      hiveShard,
						OCMEnv:         ocmEnv,
						Metadata:       clusterMeta,
						Client:         client,
						Operator:       op,
					}

					checks.RunOperatorChecks(ctx, cc)

					output := cc.ToOutput(version)
					output.OperatorVersion = detectOperatorVersion(ctx, client, op)

					mu.Lock()
					allOutputs = append(allOutputs, output)
					mu.Unlock()

					fmt.Fprintf(os.Stderr, "  ✓ %s/%s: %s (%d checks)\n",
						clusterName, strings.ToUpper(op.ShortName), cc.OverallStatus(), len(cc.Results))
				}(opCfg)
			}
			wg.Wait()
		}(i, clusterID)
	}
	clusterWg.Wait()

	// Write JSON output — mixed array of saas_targets metadata + cluster data
	var combined []any
	for _, meta := range saasMetadata {
		combined = append(combined, meta)
	}
	for _, out := range allOutputs {
		combined = append(combined, out)
	}

	data, err := json.MarshalIndent(combined, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error marshaling JSON: %v\n", err)
		os.Exit(1)
	}
	if err := os.WriteFile(outputFile, data, 0644); err != nil {
		fmt.Fprintf(os.Stderr, "Error writing output: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "\nResults written to: %s (%d cluster entries, %d SAAS metadata)\n",
		outputFile, len(allOutputs), len(saasMetadata))

	// Generate HTML using the bash script (reuse existing HTML generation)
	if !noHTML {
		htmlFile := strings.TrimSuffix(outputFile, ".json") + ".html"
		cmd := exec.Command("bash", "lib/generate_html_report.sh", outputFile, htmlFile)
		if output, err := cmd.CombinedOutput(); err != nil {
			fmt.Fprintf(os.Stderr, "HTML generation failed: %v\n%s\n", err, output)
		} else {
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
		fields := strings.Fields(line)
		if len(fields) > 0 {
			ids = append(ids, fields[0])
		}
	}
	return ids, nil
}

func detectOperatorVersion(ctx context.Context, client *kube.ClusterClient, op checks.OperatorConfig) string {
	deploy, err := client.Clientset().AppsV1().Deployments(op.Namespace).Get(ctx, op.Deployment, metav1.GetOptions{})
	if err != nil || len(deploy.Spec.Template.Spec.Containers) == 0 {
		return "unknown"
	}
	image := deploy.Spec.Template.Spec.Containers[0].Image
	if idx := strings.LastIndex(image, ":"); idx >= 0 {
		tag := image[idx+1:]
		if gIdx := strings.LastIndex(tag, "-g"); gIdx >= 0 {
			return tag[gIdx+2:]
		}
		return tag
	}
	if idx := strings.LastIndex(image, "@"); idx >= 0 {
		end := idx + 13
		if end > len(image) {
			end = len(image)
		}
		return image[idx+1 : end]
	}
	return "unknown"
}

func runListClusters(ocmClient *ocm.Client, filter, exclude, include string) error {
	var searches []string
	switch filter {
	case "all":
		searches = []string{"managed='true' and state='ready'"}
	case "rosa":
		searches = []string{"managed='true' and state='ready' and product.id='rosa'"}
	case "rosa-classic":
		searches = []string{"hypershift.enabled='false' and managed='true' and state='ready' and product.id='rosa'"}
	case "osd":
		searches = []string{"managed='true' and state='ready' and product.id='osd'"}
	case "hypershift":
		searches = []string{"managed='true' and state='ready' and hypershift.enabled='true'"}
	case "managed":
		// ROSA classic + OSD (includes MCs/SCs, excludes HCP ROSA) — matches original get_clusters.sh
		searches = []string{
			"hypershift.enabled='false' and managed='true' and state='ready' and product.id='rosa'",
			"managed='true' and state='ready' and product.id='osd'",
		}
	default:
		searches = []string{filter}
	}

	var excludeRe, includeRe *regexp.Regexp
	if exclude != "" {
		var err error
		excludeRe, err = regexp.Compile(exclude)
		if err != nil {
			return fmt.Errorf("invalid --exclude regex %q: %w", exclude, err)
		}
	}
	if include != "" {
		var err error
		includeRe, err = regexp.Compile(include)
		if err != nil {
			return fmt.Errorf("invalid --include regex %q: %w", include, err)
		}
	}

	conn := ocmClient.Conn()
	seen := map[string]bool{}
	printed := 0
	filtered := 0
	total := 0

	for _, search := range searches {
		resp, err := conn.ClustersMgmt().V1().Clusters().List().
			Search(search).
			Size(1000).
			Send()
		if err != nil {
			return fmt.Errorf("cluster search failed: %w", err)
		}
		total += resp.Total()

		resp.Items().Each(func(cluster *cmv1.Cluster) bool {
			if seen[cluster.ID()] {
				return true
			}
			seen[cluster.ID()] = true

			name := cluster.Name()
			if excludeRe != nil && excludeRe.MatchString(name) {
				filtered++
				return true
			}
			if includeRe != nil && !includeRe.MatchString(name) {
				filtered++
				return true
			}

			hcp := "false"
			if cluster.Hypershift().Enabled() {
				hcp = "true"
			}
			fmt.Printf("%-36s  %-40s  %-20s  %-6s  %-5s  %s\n",
				cluster.ID(),
				cluster.Name(),
				cluster.OpenshiftVersion(),
				cluster.Status().State(),
				hcp,
				cluster.CreationTimestamp().Format("2006-01-02T15:04:05Z"),
			)
			printed++
			return true
		})
	}

	fmt.Fprintf(os.Stderr, "Listed %d clusters (%d filtered, %d total from %d queries, %s)\n",
		printed, filtered, total, len(searches), ocmClient.Environment())

	return nil
}
