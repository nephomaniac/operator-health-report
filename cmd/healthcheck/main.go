package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/openshift/operator-health-report/pkg/checks"
	"github.com/openshift/operator-health-report/pkg/config"
	"github.com/openshift/operator-health-report/pkg/fleet"
	"github.com/openshift/operator-health-report/pkg/kube"
	"github.com/openshift/operator-health-report/pkg/logging"
	"github.com/openshift/operator-health-report/pkg/ocm"
	"github.com/openshift/operator-health-report/pkg/report"
	"github.com/openshift/operator-health-report/pkg/rhobs"
	"github.com/openshift/operator-health-report/pkg/saas"

	cmv1 "github.com/openshift-online/ocm-sdk-go/clustersmgmt/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	// Import operator checkers for init() registration
	"github.com/openshift/operator-health-report/pkg/checks/byoc"
	_ "github.com/openshift/operator-health-report/pkg/checks/camo"
	_ "github.com/openshift/operator-health-report/pkg/checks/hcp"
	_ "github.com/openshift/operator-health-report/pkg/checks/mcc"
	_ "github.com/openshift/operator-health-report/pkg/checks/mnmo"
	_ "github.com/openshift/operator-health-report/pkg/checks/muo"
	_ "github.com/openshift/operator-health-report/pkg/checks/ome"
	_ "github.com/openshift/operator-health-report/pkg/checks/pdo"
	_ "github.com/openshift/operator-health-report/pkg/checks/rhobs"
	"github.com/openshift/operator-health-report/pkg/checks/rlr"
	_ "github.com/openshift/operator-health-report/pkg/checks/rmo"
	_ "github.com/openshift/operator-health-report/pkg/checks/sae"
	_ "github.com/openshift/operator-health-report/pkg/checks/sfo"
)

// version is set at build time via:
//   go build -ldflags "-X main.version=$(git describe --always --dirty)" ./cmd/healthcheck/
var version = "dev"

func main() {
	// Load config file defaults (CLI flags override)
	var configFile string
	// Pre-scan for --config flag before full flag parsing
	for i, arg := range os.Args[1:] {
		if arg == "--config" && i+1 < len(os.Args[1:])-1 {
			configFile = os.Args[i+2]
		}
	}
	cfg, cfgPath, cfgErr := config.Load(configFile)
	if cfgErr != nil {
		fmt.Fprintf(os.Stderr, "Error loading config: %v\n", cfgErr)
		os.Exit(1)
	}

	var (
		clusterList    string
		reason         string
		operators      stringSlice
		noElevate      bool
		elevate        bool
		parallel       int
		outputFile     string
		noHTML         bool
		logLevel       string
		logDir         string
		ocmConfigPath  string
		ocmURL         string
		listClusters   string
		excludePattern string
		includePattern string
		saasOnly       bool
		hiveOCMURL     string
		byocCommand    string
		byocFile       string
		byocBrief      string
		byHive         string
		ownerDomain    string
		sector         string
	)

	flag.StringVar(&clusterList, "cluster-list", cfg.ClusterList, "File with cluster IDs (one per line)")
	flag.StringVar(&reason, "reason", cfg.Reason, "Elevation reason (JIRA ticket or PD incident — required with --elevate)")
	flag.Var(&operators, "oper", "Operator to check: camo, rmo, ome, sfo, rhobs (repeatable, default: all)")
	flag.BoolVar(&noElevate, "no-elevate", cfg.NoElevate, "Explicitly disable elevation (overrides --elevate)")
	flag.BoolVar(&elevate, "elevate", false, "Enable backplane elevation (requires --reason)")
	flag.IntVar(&parallel, "parallel", max(cfg.Parallel, 1), "Number of clusters to process concurrently")
	flag.StringVar(&outputFile, "output", "", "Output JSON file (default: health_TIMESTAMP.json)")
	flag.BoolVar(&noHTML, "no-html", cfg.NoHTML, "Skip HTML report generation")
	flag.StringVar(&logLevel, "log-level", orDefault(cfg.LogLevel, "info"), "Log level: debug, info, warn, error")
	flag.StringVar(&logDir, "log-dir", cfg.LogDir, "Directory for debug log file (captures all levels)")
	flag.StringVar(&ocmConfigPath, "ocm-config", cfg.OCMConfig, "Path to OCM config file (default: $OCM_CONFIG or ~/.config/ocm/ocm.json)")
	flag.StringVar(&ocmURL, "ocm-url", cfg.OCMURL, "OCM API URL override")
	flag.StringVar(&listClusters, "list-clusters", cfg.ListClusters, "List clusters and exit (all, rosa, osd, hypershift, managed)")
	flag.StringVar(&excludePattern, "exclude", cfg.Exclude, "Regex to exclude clusters by name")
	flag.StringVar(&includePattern, "include", cfg.Include, "Regex to include only clusters matching by name")
	flag.BoolVar(&saasOnly, "saas-only", cfg.SaasOnly, "Show SAAS targets and pipeline only (no cluster checks)")
	flag.StringVar(&hiveOCMURL, "hive-ocm-url", "", "OCM API URL for hive cluster connections (default: auto-detect or production)")
	flag.StringVar(&configFile, "config", "", "Path to config file (default: .healthcheck.yaml)")
	flag.StringVar(&byocCommand, "byoc", "", "Bring Your Own Check: ad-hoc command to run on each cluster (exit 0 = PASS)")
	flag.StringVar(&byocFile, "byof", "", "Bring Your Own File: JSON file with check definitions to run on each cluster")
	flag.StringVar(&byocBrief, "byoc-brief", "", "Extract compact BYOC results from a results JSON file to stdout (jq-friendly)")
	flag.StringVar(&byHive, "by-hive", "", "Discover clusters from hive shard(s) — name, pattern, or 'all' (e.g., hive-stage-01, stage, canary, all)")
	flag.StringVar(&ownerDomain, "owner-domain", "", "Filter clusters by owner email domain (e.g., redhat.com)")
	flag.StringVar(&sector, "sector", "", "Filter MC/SC clusters by HCP sector (e.g., canary, main, perf)")
	flag.Parse()

	if cfgPath != "" {
		fmt.Fprintf(os.Stderr, "Config: %s\n", cfgPath)
	}

	// Apply operators from config if none provided via CLI
	if len(operators) == 0 && len(cfg.Operators) > 0 {
		operators = cfg.Operators
	}

	// Load BYOC check definitions
	if byocFile != "" {
		defs, loadErr := byoc.LoadCheckDefs(byocFile)
		if loadErr != nil {
			fmt.Fprintf(os.Stderr, "Error loading --byof: %v\n", loadErr)
			os.Exit(1)
		}
		byoc.CheckDefs = defs
		fmt.Fprintf(os.Stderr, "BYOC: loaded %d check(s) from %s\n", len(defs), byocFile)
	}
	if byocCommand != "" {
		byoc.CheckDefs = append(byoc.CheckDefs, byoc.SingleCommandDef(byocCommand))
		fmt.Fprintf(os.Stderr, "BYOC: added ad-hoc command\n")
	}
	if len(byoc.CheckDefs) > 0 {
		hasBYOC := false
		for _, op := range operators {
			if op == "byoc" {
				hasBYOC = true
				break
			}
		}
		if !hasBYOC {
			if len(operators) == 0 {
				operators = stringSlice{"byoc"}
			} else {
				operators = append(operators, "byoc")
			}
		}
	}

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

	// BYOC brief mode — extract compact results from existing JSON and exit
	if byocBrief != "" {
		if err := runBYOCBrief(byocBrief); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		os.Exit(0)
	}

	// List clusters mode — query OCM and exit
	if listClusters != "" {
		ocmClient, err := ocm.NewClientWithOptions(ocm.Options{ConfigFile: ocmConfigPath, URL: ocmURL})
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

	// Default to all registered operators if none specified (excluding byoc — opt-in only)
	if len(operators) == 0 {
		for name := range checks.AllOperators {
			if name == "byoc" {
				continue
			}
			operators = append(operators, name)
		}
		sort.Strings(operators)
	}

	// Resolve operator configs
	var opConfigs []checks.OperatorConfig
	for _, op := range operators {
		cfg, ok := checks.AllOperators[op]
		if !ok {
			valid := make([]string, 0, len(checks.AllOperators))
			for name := range checks.AllOperators {
				valid = append(valid, name)
			}
			sort.Strings(valid)
			fmt.Fprintf(os.Stderr, "Error: unknown operator %q (valid: %s)\n", op, strings.Join(valid, ", "))
			os.Exit(1)
		}
		opConfigs = append(opConfigs, cfg)
	}

	// Check if any selected operators need managed clusters
	needsManagedClusters := false
	for _, op := range opConfigs {
		if op.ClusterScope != checks.ScopeHive {
			needsManagedClusters = true
			break
		}
	}

	if clusterList == "" && byHive == "" && !saasOnly && needsManagedClusters {
		fmt.Fprintln(os.Stderr, "Error: --cluster-list or --by-hive is required (or use --saas-only)")
		flag.Usage()
		os.Exit(1)
	}

	// Read cluster IDs (skip if saas-only mode or no managed operators)
	var clusterIDs []string
	var rawIDs []string
	clusterNames := map[string]string{} // ID → name from list file (for sector filtering)
	if !saasOnly && clusterList != "" {
		var readErr error
		rawIDs, clusterNames, readErr = readClusterList(clusterList)
		if readErr != nil {
			fmt.Fprintf(os.Stderr, "Error reading cluster list: %v\n", readErr)
			os.Exit(1)
		}
		clusterIDs = rawIDs
	}

	if parallel < 1 {
		parallel = 1
	}
	if len(clusterIDs) > 0 && parallel > len(clusterIDs) {
		parallel = len(clusterIDs)
	}

	// Create OCM SDK connection — checks token validity based on workload size and concurrency
	ocmClient, err := ocm.NewClientWithOptions(ocm.Options{
		ConfigFile:    ocmConfigPath,
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

	// Resolve any external IDs, names, or UUIDs to internal OCM IDs
	if len(rawIDs) > 0 {
		needsResolve := false
		for _, id := range rawIDs {
			if !ocm.IsInternalID(id) {
				needsResolve = true
				break
			}
		}
		if needsResolve {
			var resolved []string
			seen := map[string]bool{}
			for _, raw := range rawIDs {
				id, err := ocmClient.ResolveClusterID(raw)
				if err != nil {
					fmt.Fprintf(os.Stderr, "⚠ Skipping '%s': %v\n", raw, err)
					continue
				}
				if !seen[id] {
					seen[id] = true
					resolved = append(resolved, id)
				}
			}
			if len(resolved) < len(rawIDs) {
				fmt.Fprintf(os.Stderr, "Resolved %d of %d cluster identifiers (%d skipped)\n", len(resolved), len(rawIDs), len(rawIDs)-len(resolved))
			}
			clusterIDs = resolved
		}
	}

	ocmEnv := ocmClient.URL()
	isProd := ocmClient.IsProduction()

	// Elevation logic:
	// --no-elevate always wins (explicit disable)
	// --elevate --reason TICKET: explicit enable (required for production)
	// Neither flag on staging/integration: auto-elevate with default reason
	// Neither flag on production: no elevation
	// Hive clusters are always production — only elevate with explicit --elevate --reason
	explicitElevate := elevate
	if noElevate {
		elevate = false
	} else if elevate {
		if reason == "" || reason == "operator health check" || reason == cfg.Reason {
			fmt.Fprintln(os.Stderr, "Error: --elevate requires --reason with a JIRA ticket or PD incident (e.g., --reason SREP-1234)")
			os.Exit(1)
		}
		if isProd {
			fmt.Fprintln(os.Stderr, "")
			fmt.Fprintln(os.Stderr, "================================================================================")
			fmt.Fprintln(os.Stderr, "⚠  ELEVATION ENABLED ON PRODUCTION — all operations are read-only")
			fmt.Fprintln(os.Stderr, "    Reason:", reason)
			fmt.Fprintln(os.Stderr, "================================================================================")
			fmt.Fprintln(os.Stderr, "")
		}
	} else if !isProd {
		elevate = true
		if reason == "" || reason == cfg.Reason {
			reason = "SREP-operator-health-check"
		}
	}
	noElevate = !elevate

	if reason == "" {
		reason = "operator health check"
	}

	fmt.Fprintf(os.Stderr, "Clusters: %d, Operators: %v, Elevation: %v, OCM: %s\n",
		len(clusterIDs), operators, elevate, ocmClient.Environment())

	// Output file — default to results/ directory
	if outputFile == "" {
		if err := os.MkdirAll("results", 0755); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: cannot create results directory: %v\n", err)
		}
		outputFile = fmt.Sprintf("results/health_report_%s.json", time.Now().Format("2006-01-02_1504"))
	}

	// Fetch SAAS targets and build promotion pipeline for all operators
	type saasTargetMeta struct {
		Type         string         `json:"type"`
		OperatorName string         `json:"operator_name"`
		OCMEnv       string         `json:"ocm_environment"`
		Version      string         `json:"script_version"`
		Targets      []saas.Target  `json:"targets"`
		Pipeline     *saas.Pipeline `json:"pipeline,omitempty"`
	}
	// Create a prod OCM client for resolving pipeline cluster console URLs.
	// Uses the same SSO token — no separate login needed.
	var resolveConsoleURL saas.ConsoleURLResolver
	prodClient, prodErr := ocm.NewClientWithOptions(ocm.Options{URL: "https://api.openshift.com"})
	if prodErr == nil {
		defer prodClient.Close()
		// Cache resolved console URLs to avoid redundant API calls
		consoleCache := map[string]string{}
		var cacheMu sync.Mutex
		resolveConsoleURL = func(clusterName string) (string, error) {
			cacheMu.Lock()
			if url, ok := consoleCache[clusterName]; ok {
				cacheMu.Unlock()
				return url, nil
			}
			cacheMu.Unlock()

			resp, err := prodClient.Conn().ClustersMgmt().V1().Clusters().List().
				Search(fmt.Sprintf("name='%s'", clusterName)).Size(1).Send()
			if err != nil {
				return "", err
			}
			if resp.Total() == 0 {
				return "", fmt.Errorf("cluster %s not found in prod OCM", clusterName)
			}
			consoleURL := resp.Items().Get(0).Console().URL()
			cacheMu.Lock()
			consoleCache[clusterName] = consoleURL
			cacheMu.Unlock()
			return consoleURL, nil
		}
		fmt.Fprintf(os.Stderr, "Prod OCM: connected for pipeline cluster resolution\n")
	} else {
		fmt.Fprintf(os.Stderr, "Prod OCM: skipping pipeline URL resolution (%v)\n", prodErr)
	}

	// Fetch fleet topology (MC/SC sectors, parent relationships).
	// Use the primary OCM client so cluster IDs match the current environment.
	var fleetTopo *fleet.Topology
	{
		topo, topoErr := fleet.FetchTopology(context.Background(), ocmClient.Conn())
		if topoErr == nil && topo != nil {
			fleetTopo = topo
			fmt.Fprintf(os.Stderr, "Fleet topology: %s\n", topo.String())
		}
	}

	var saasMetadata []saasTargetMeta
	for _, op := range opConfigs {
		ctx := context.Background()
		targets, err := saas.FetchAllTargets(ctx, op.PKOSaas, op.OLMSaas)
		if err == nil && len(targets) > 0 {
			fmt.Fprintf(os.Stderr, "SAAS targets: %s — %d active targets\n", strings.ToUpper(op.ShortName), len(targets))
		}

		pipeline, pipeErr := saas.BuildPipeline(ctx, op.Name, op.PKOSaas, op.OLMSaas, resolveConsoleURL)
		if pipeErr == nil && pipeline != nil {
			fmt.Fprintf(os.Stderr, "Pipeline: %s — %d nodes, %d edges, %d stages\n",
				strings.ToUpper(op.ShortName), len(pipeline.Nodes), len(pipeline.Edges), len(pipeline.Stages))
		}

		saasMetadata = append(saasMetadata, saasTargetMeta{
			Type:         "saas_targets",
			OperatorName: op.Name,
			OCMEnv:       ocmEnv,
			Version:      version,
			Targets:      targets,
			Pipeline:     pipeline,
		})
	}

	// Track skipped and failed clusters for the summary
	type skippedCluster struct {
		Type      string `json:"type"`
		ClusterID string `json:"cluster_id"`
		Name      string `json:"cluster_name"`
		Reason    string `json:"reason"`
		Status    string `json:"skip_status"` // "limited_support", "not_ready", "connection_failed", "metadata_failed"
	}

	// Fetch OSDFM deploy config for RLR expected Vector image
	if vectorImage, osdfmErr := saas.FetchOSDFMVectorImage(context.Background(), ocmClient.Environment()); osdfmErr == nil {
		rlr.ExpectedVectorImage = vectorImage
		fmt.Fprintf(os.Stderr, "OSDFM Vector image (%s): %s\n", ocmClient.Environment(), vectorImage)
	} else {
		logging.Log.WithError(osdfmErr).Debug("Could not fetch OSDFM Vector image — RLR version check will report INFO")
	}

	// Shared hive OCM client — lazily created, used by both --by-hive discovery
	// and hive operator processing. Hive clusters are always in production OCM.
	var hiveOCM *ocm.Client
	getHiveOCM := func() *ocm.Client {
		if hiveOCM != nil {
			return hiveOCM
		}
		hiveURL := hiveOCMURL
		if hiveURL == "" {
			hiveURL = "https://api.openshift.com"
		}
		hiveClient, hiveErr := ocm.NewClientWithOptions(ocm.Options{URL: hiveURL})
		if hiveErr != nil {
			fmt.Fprintf(os.Stderr, "⚠ Cannot connect to hive OCM (%s): %v\n", hiveURL, hiveErr)
			return nil
		}
		hiveOCM = hiveClient
		return hiveOCM
	}
	defer func() {
		if hiveOCM != nil {
			hiveOCM.Close()
		}
	}()

	// Hive-based cluster discovery: connect to hive shards, list ClusterDeployments
	var hiveSyncData map[string]*fleet.ClusterSyncStatus // OCM ID → sync status
	if byHive != "" && !saasOnly {
		hiveConn := getHiveOCM()
		if hiveConn == nil {
			fmt.Fprintf(os.Stderr, "Error: --by-hive requires hive OCM connection\n")
			os.Exit(1)
		}
		_ = hiveConn // used below via hiveOCM
		// Collect all SAAS targets to resolve hive patterns
		var allTargets []saas.Target
		for _, op := range opConfigs {
			targets, tErr := saas.FetchAllTargets(context.Background(), op.PKOSaas, op.OLMSaas)
			if tErr == nil {
				allTargets = append(allTargets, targets...)
			}
		}

		hiveNames := fleet.ResolveHivePattern(byHive, allTargets, ocmClient.Environment())
		if len(hiveNames) == 0 {
			fmt.Fprintf(os.Stderr, "Error: --by-hive %q matched no hive shards for %s\n", byHive, ocmClient.Environment())
			os.Exit(1)
		}
		sort.Strings(hiveNames)
		fmt.Fprintf(os.Stderr, "Hive discovery: %s → %s\n", byHive, strings.Join(hiveNames, ", "))

		discoveredIDs := map[string]bool{}
		discoveredNames := map[string]string{} // ID → name
		hiveSyncData = map[string]*fleet.ClusterSyncStatus{}

		for _, hiveName := range hiveNames {
			hiveID, resolveErr := hiveOCM.ResolveClusterByName(hiveName)
			if resolveErr != nil {
				fmt.Fprintf(os.Stderr, "  ✗ Cannot find hive %s: %v\n", hiveName, resolveErr)
				continue
			}

			hiveNoElev := !explicitElevate
			client, connErr := kube.ConnectToClusterWithConn(context.Background(), hiveID, reason, hiveNoElev, hiveOCM.Conn())
			if connErr != nil {
				fmt.Fprintf(os.Stderr, "  ✗ Cannot connect to hive %s: %v\n", hiveName, connErr)
				continue
			}

			clusters, discErr := fleet.DiscoverClustersFromHive(context.Background(), client)
			if discErr != nil {
				fmt.Fprintf(os.Stderr, "  ✗ Cannot list ClusterDeployments on %s: %v\n", hiveName, discErr)
				client.Disconnect()
				continue
			}

			for _, ci := range clusters {
				discoveredIDs[ci.OCMID] = true
				discoveredNames[ci.OCMID] = ci.Name
			}

			syncData, syncErr := fleet.CollectClusterSync(context.Background(), client)
			if syncErr != nil {
				fmt.Fprintf(os.Stderr, "  ⚠ ClusterSync collection failed on %s: %v\n", hiveName, syncErr)
			} else if syncData != nil {
				nsToID := map[string]string{}
				for _, ci := range clusters {
					nsToID[ci.Namespace] = ci.OCMID
				}
				for ns, cs := range syncData {
					if ocmID, ok := nsToID[ns]; ok {
						hiveSyncData[ocmID] = cs
					}
				}
			}

			client.Disconnect()
			fmt.Fprintf(os.Stderr, "  ✓ %s: %d clusters discovered", hiveName, len(clusters))
			if syncData != nil {
				failCount := 0
				for _, cs := range syncData {
					if cs.Failed {
						failCount++
					}
				}
				if failCount > 0 {
					fmt.Fprintf(os.Stderr, " (%d with sync failures)", failCount)
				}
			}
			fmt.Fprintln(os.Stderr)
		}

		if clusterList != "" {
			filtered := make([]string, 0, len(clusterIDs))
			for _, id := range clusterIDs {
				if discoveredIDs[id] {
					filtered = append(filtered, id)
				}
			}
			fmt.Fprintf(os.Stderr, "Hive filter: %d of %d clusters match\n", len(filtered), len(clusterIDs))
			clusterIDs = filtered
		} else {
			clusterIDs = make([]string, 0, len(discoveredIDs))
			for id := range discoveredIDs {
				clusterIDs = append(clusterIDs, id)
			}
			sort.Strings(clusterIDs)
			fmt.Fprintf(os.Stderr, "Discovered %d clusters from hive\n", len(clusterIDs))
		}

		// Merge discovered names into clusterNames for downstream filters
		for id, name := range discoveredNames {
			clusterNames[id] = name
		}
	}

	// Owner domain filter — post-filter using batch subscriptions API
	if ownerDomain != "" && len(clusterIDs) > 0 {
		filtered, filterErr := ocmClient.FilterByOwnerDomain(context.Background(), clusterIDs, ownerDomain)
		if filterErr != nil {
			fmt.Fprintf(os.Stderr, "⚠ Owner domain filter failed: %v\n", filterErr)
		} else {
			fmt.Fprintf(os.Stderr, "Owner domain filter (@%s): %d of %d clusters match\n",
				strings.TrimPrefix(ownerDomain, "@"), len(filtered), len(clusterIDs))
			clusterIDs = filtered
		}
	}

	// Sector filter — keep only MC/SC clusters in the specified sector
	if sector != "" && len(clusterIDs) > 0 && fleetTopo != nil {
		sectorFCs := fleetTopo.BySector[sector]
		if len(sectorFCs) == 0 {
			fmt.Fprintf(os.Stderr, "⚠ Sector %q not found in fleet topology (known: %s)\n", sector, strings.Join(fleetTopo.Sectors(), ", "))
		} else {
			allowedByID := map[string]bool{}
			allowedByName := map[string]bool{}
			for _, fc := range sectorFCs {
				if fc.ClusterID != "" {
					allowedByID[fc.ClusterID] = true
				}
				if fc.Name != "" {
					allowedByName[fc.Name] = true
				}
			}
			var filtered []string
			for _, id := range clusterIDs {
				if allowedByID[id] {
					filtered = append(filtered, id)
				} else if name := clusterNames[id]; name != "" && allowedByName[name] {
					filtered = append(filtered, id)
				}
			}
			fmt.Fprintf(os.Stderr, "Sector filter (%s): %d of %d clusters match\n", sector, len(filtered), len(clusterIDs))
			clusterIDs = filtered
		}
	}

	// Name regex filter (--exclude, --include) — applied to all discovery paths
	if len(clusterIDs) > 0 && (excludePattern != "" || includePattern != "") {
		var excludeRe, includeRe *regexp.Regexp
		if excludePattern != "" {
			var err error
			excludeRe, err = regexp.Compile(excludePattern)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: invalid --exclude regex %q: %v\n", excludePattern, err)
				os.Exit(1)
			}
		}
		if includePattern != "" {
			var err error
			includeRe, err = regexp.Compile(includePattern)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: invalid --include regex %q: %v\n", includePattern, err)
				os.Exit(1)
			}
		}
		before := len(clusterIDs)
		var filtered []string
		for _, id := range clusterIDs {
			name := clusterNames[id]
			if name == "" {
				name = id
			}
			if excludeRe != nil && excludeRe.MatchString(name) {
				continue
			}
			if includeRe != nil && !includeRe.MatchString(name) {
				continue
			}
			filtered = append(filtered, id)
		}
		if len(filtered) != before {
			fmt.Fprintf(os.Stderr, "Name filter: %d of %d clusters match\n", len(filtered), before)
		}
		clusterIDs = filtered
	}

	// Signal handling — graceful shutdown on ctrl-c
	rootCtx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	// writeResults dumps current results to JSON and HTML (used for both normal exit and signal)
	writeResults := func(allOutputs []checks.ClusterOutput, skippedClusters []skippedCluster, interrupted bool, elevatedCalls int64, clustersElev int) {
		var combined []any
		for _, meta := range saasMetadata {
			combined = append(combined, meta)
		}
		combined = append(combined, map[string]any{
			"type":                     "elevation_audit",
			"elevated_api_calls":      elevatedCalls,
			"clusters_with_elevation":  clustersElev,
			"total_clusters_processed": len(allOutputs),
			"no_elevate_flag":          noElevate,
			"environment":              ocmClient.Environment(),
		})
		for _, sc := range skippedClusters {
			combined = append(combined, sc)
		}
		for _, out := range allOutputs {
			combined = append(combined, out)
		}

		data, err := json.MarshalIndent(combined, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error marshaling JSON: %v\n", err)
			return
		}
		if err := os.WriteFile(outputFile, data, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Error writing output: %v\n", err)
			return
		}

		label := ""
		if interrupted {
			label = " (PARTIAL — interrupted)"
		}
		fmt.Fprintf(os.Stderr, "\nResults written to: %s (%d cluster entries, %d SAAS metadata)%s\n",
			outputFile, len(allOutputs), len(saasMetadata), label)

		if !noHTML {
			htmlFile := strings.TrimSuffix(outputFile, ".json") + ".html"
			if err := report.GenerateHTML(data, htmlFile); err != nil {
				fmt.Fprintf(os.Stderr, "HTML generation failed: %v\n", err)
			} else {
				fmt.Fprintf(os.Stderr, "HTML report: %s\n", htmlFile)
			}
		}
	}

	// Discover hive clusters from SAAS targets for hive-scoped operators
	hiveClusterNames := map[string]bool{}
	hasHiveOperators := false
	for _, op := range opConfigs {
		if op.ClusterScope == checks.ScopeHive || op.ClusterScope == checks.ScopeBoth {
			hasHiveOperators = true
			targets, tErr := saas.FetchAllTargets(context.Background(), op.PKOSaas, op.OLMSaas)
			if tErr == nil {
				for _, t := range targets {
					if t.HiveCluster != "" {
						env := t.OCMEnv
						if env == "" {
							env = classifyHiveEnv(t.HiveCluster)
						}
						if envMatch(env, ocmClient.Environment()) {
							hiveClusterNames[t.HiveCluster] = true
						}
					}
				}
			}
		}
	}
	if len(hiveClusterNames) > 0 {
		names := make([]string, 0, len(hiveClusterNames))
		for n := range hiveClusterNames {
			names = append(names, n)
		}
		sort.Strings(names)
		fmt.Fprintf(os.Stderr, "Hive clusters (%s): %s\n", ocmClient.Environment(), strings.Join(names, ", "))
	}

	// Split operators by scope
	var managedOps, hiveOps []checks.OperatorConfig
	for _, op := range opConfigs {
		if op.ClusterScope == checks.ScopeHive {
			hiveOps = append(hiveOps, op)
		} else {
			managedOps = append(managedOps, op)
			if op.ClusterScope == checks.ScopeBoth {
				hiveOps = append(hiveOps, op)
			}
		}
	}

	// Process clusters — concurrently up to --parallel limit
	var allOutputs []checks.ClusterOutput
	var skippedClusters []skippedCluster
	if parallel < 1 {
		parallel = 1
	}
	if len(clusterIDs) > 0 && parallel > len(clusterIDs) {
		parallel = len(clusterIDs)
	}

	var mu sync.Mutex
	sem := make(chan struct{}, parallel)
	var clusterWg sync.WaitGroup
	var totalElevatedCalls int64
	var clustersWithElevation int

	for i, clusterID := range clusterIDs {
		// Check for cancellation before starting new clusters
		select {
		case <-rootCtx.Done():
			fmt.Fprintf(os.Stderr, "\n⚠ Interrupted — waiting for %d in-flight cluster(s) to finish...\n", parallel)
			goto waitAndWrite
		default:
		}

		clusterWg.Add(1)
		sem <- struct{}{} // acquire semaphore slot

		go func(idx int, cid string) {
			defer clusterWg.Done()
			defer func() { <-sem }() // release semaphore slot

			ctx := rootCtx

			// Fetch cluster metadata from OCM first — skip non-ready and limited-support clusters
			meta, metaErr := ocmClient.GetClusterMetadata(cid)
			if metaErr != nil {
				fmt.Fprintf(os.Stderr, "\n[%d/%d] ✗ %s: failed to fetch metadata: %v\n", idx+1, len(clusterIDs), cid, metaErr)
				mu.Lock()
				skippedClusters = append(skippedClusters, skippedCluster{
					Type: "skipped_cluster", ClusterID: cid, Name: cid,
					Reason: fmt.Sprintf("Failed to fetch metadata: %v", metaErr), Status: "metadata_failed",
				})
				mu.Unlock()
				return
			}

			if meta.State != "ready" {
				fmt.Fprintf(os.Stderr, "\n[%d/%d] ⏭ %s (%s): skipping — state is %s\n", idx+1, len(clusterIDs), meta.Name, cid, meta.State)
				mu.Lock()
				skippedClusters = append(skippedClusters, skippedCluster{
					Type: "skipped_cluster", ClusterID: cid, Name: meta.Name,
					Reason: "Cluster state: " + meta.State, Status: "not_ready",
				})
				mu.Unlock()
				return
			}
			if meta.LimitedSupport {
				fmt.Fprintf(os.Stderr, "\n[%d/%d] ⏭ %s (%s): skipping — limited support\n", idx+1, len(clusterIDs), meta.Name, cid)
				mu.Lock()
				skippedClusters = append(skippedClusters, skippedCluster{
					Type: "skipped_cluster", ClusterID: cid, Name: meta.Name,
					Reason: "Limited support", Status: "limited_support",
				})
				mu.Unlock()
				return
			}

			fmt.Fprintf(os.Stderr, "\n[%d/%d] Processing: %s (%s, %s, %s)\n", idx+1, len(clusterIDs), meta.Name, meta.Product, meta.Provider, meta.Region)

			client, err := kube.ConnectToClusterWithConn(ctx, cid, reason, noElevate, ocmClient.Conn())
			if err != nil {
				fmt.Fprintf(os.Stderr, "  ✗ Failed to connect to %s: %v\n", meta.Name, err)
				mu.Lock()
				skippedClusters = append(skippedClusters, skippedCluster{
					Type: "skipped_cluster", ClusterID: cid, Name: meta.Name,
					Reason: fmt.Sprintf("Connection failed: %v", err), Status: "connection_failed",
				})
				mu.Unlock()
				return
			}
			defer client.Disconnect()
			client.OCMConfigPath = ocmConfigPath

			// Initialize RHOBS remote client if cell URL is available
			if cellURL := meta.Labels["ext-hypershift.openshift.io/rhobs-cell"]; cellURL != "" {
				rhobsClient, rhobsErr := rhobs.NewClient(cellURL, meta.Environment)
				if rhobsErr != nil {
					logging.WithCheck("rhobs_init").WithField("cluster", meta.Name).Warn("RHOBS remote metrics unavailable (Thanos queries will require elevation): ", rhobsErr)
				} else {
					client.SetRHOBSClient(rhobsClient)
					logging.WithCheck("rhobs_init").WithField("cluster", meta.Name).Debug("RHOBS remote configured (cell: ", cellURL, ")")
				}
			}

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
				Sector:         enrichSector(fleetTopo, cid, clusterName),
				CreatedAt:      meta.CreatedAt,
				OwnerOrg:       meta.OwnerOrg,
				OwnerEmail:     maskedEmail,
				Labels:         meta.Labels,
				Environment:    meta.Environment,
			}

			// Copy log forwarder metadata for HCP clusters
			for _, lf := range meta.LogForwarders {
				clusterMeta.LogForwarders = append(clusterMeta.LogForwarders, checks.LogForwarderInfo{
					ID:     lf.ID,
					Type:   lf.Type,
					Status: lf.Status,
					Groups: lf.Groups,
				})
			}

			var wg sync.WaitGroup
			for _, opCfg := range managedOps {
				if checks.Cancelled(ctx) {
					break
				}
				wg.Add(1)
				go func(op checks.OperatorConfig) {
					defer wg.Done()

					cc := &checks.ClusterContext{
						ClusterID:      cid,
						ClusterName:    clusterName,
						ClusterVersion: clusterVersion,
						ClusterType:    clusterType,
						HiveShard:      hiveShard,
						Sector:         clusterMeta.Sector,
						OCMEnv:         ocmEnv,
						Metadata:       clusterMeta,
						Client:         client,
						Config:         cfg,
						Operator:       op,
					}

					checks.RunOperatorChecks(ctx, cc)

					output := cc.ToOutput(version)
					output.OperatorVersion = detectOperatorVersion(ctx, client, op)

					if hiveSyncData != nil {
						if syncStatus, ok := hiveSyncData[cid]; ok {
							output.SyncStatus = syncStatus
						}
					}

					mu.Lock()
					allOutputs = append(allOutputs, output)
					mu.Unlock()

					fmt.Fprintf(os.Stderr, "  ✓ %s/%s: %s (%d checks)\n",
						clusterName, strings.ToUpper(op.ShortName), cc.OverallStatus(), len(cc.Results))
				}(opCfg)
			}
			wg.Wait()

			// Attach elevated ops to all outputs for this cluster
			if len(client.ElevatedOps) > 0 {
				mu.Lock()
				for i := range allOutputs {
					if allOutputs[i].ClusterID == cid && len(allOutputs[i].ElevatedOps) == 0 {
						allOutputs[i].ElevatedOps = client.ElevatedOps
					}
				}
				mu.Unlock()
			}

			// Elevation audit
			if client.ElevatedCallCount > 0 {
				mu.Lock()
				totalElevatedCalls += client.ElevatedCallCount
				clustersWithElevation++
				mu.Unlock()
				if noElevate {
					fmt.Fprintf(os.Stderr, "  ⚠ AUDIT: %d elevated API calls on %s despite --no-elevate!\n",
						client.ElevatedCallCount, clusterName)
				}
			}
		}(i, clusterID)
	}

	// Wait for managed cluster processing to complete before starting hive
	clusterWg.Wait()

	// Process hive clusters for hive-scoped operators (reuses shared hiveOCM client)
	if hasHiveOperators && len(hiveClusterNames) > 0 && rootCtx.Err() == nil && getHiveOCM() != nil {
		fmt.Fprintf(os.Stderr, "\nProcessing %d hive cluster(s) for %d operator(s)...\n", len(hiveClusterNames), len(hiveOps))
		{

			for hiveName := range hiveClusterNames {
				if checks.Cancelled(rootCtx) {
					break
				}

				hiveID, resolveErr := hiveOCM.ResolveClusterByName(hiveName)
				if resolveErr != nil {
					fmt.Fprintf(os.Stderr, "  ✗ Cannot find hive cluster %s: %v\n", hiveName, resolveErr)
					mu.Lock()
					skippedClusters = append(skippedClusters, skippedCluster{
						Type: "skipped_cluster", ClusterID: hiveName, Name: hiveName,
						Reason: fmt.Sprintf("Hive cluster not found: %v", resolveErr), Status: "metadata_failed",
					})
					mu.Unlock()
					continue
				}

				meta, metaErr := hiveOCM.GetClusterMetadata(hiveID)
				if metaErr != nil {
					fmt.Fprintf(os.Stderr, "  ✗ Cannot get metadata for %s: %v\n", hiveName, metaErr)
					continue
				}

				fmt.Fprintf(os.Stderr, "\n[hive] Processing: %s (%s, %s, %s)\n", meta.Name, meta.Product, meta.Provider, meta.Region)

				// Hive clusters are always production — only elevate with explicit --elevate --reason
				hiveNoElevate := !explicitElevate

				client, connErr := kube.ConnectToClusterWithConn(rootCtx, hiveID, reason, hiveNoElevate, hiveOCM.Conn())
				if connErr != nil {
					fmt.Fprintf(os.Stderr, "  ✗ Failed to connect to %s: %v\n", hiveName, connErr)
					mu.Lock()
					skippedClusters = append(skippedClusters, skippedCluster{
						Type: "skipped_cluster", ClusterID: hiveID, Name: hiveName,
						Reason: fmt.Sprintf("Connection failed: %v", connErr), Status: "connection_failed",
					})
					mu.Unlock()
					continue
				}
				client.OCMConfigPath = ocmConfigPath

				fmt.Fprintf(os.Stderr, "  ✓ Connected to %s\n", hiveName)

				// Initialize RHOBS remote if available
				if cellURL := meta.Labels["ext-hypershift.openshift.io/rhobs-cell"]; cellURL != "" {
					rhobsClient, rhobsErr := rhobs.NewClient(cellURL, meta.Environment)
					if rhobsErr == nil {
						client.SetRHOBSClient(rhobsClient)
					}
				}

				clusterType := "hive"
				clusterMeta := &checks.ClusterMetadata{
					ID: meta.ID, ExternalID: meta.ExternalID, Name: meta.Name,
					State: meta.State, Product: meta.Product, Provider: meta.Provider,
					Version: meta.Version, Region: meta.Region, STS: meta.STS,
					Hypershift: meta.Hypershift, Labels: meta.Labels,
					CreatedAt: meta.CreatedAt, Environment: meta.Environment,
				}

				for _, op := range hiveOps {
					if checks.Cancelled(rootCtx) {
						break
					}

					cc := &checks.ClusterContext{
						ClusterID: hiveID, ClusterName: meta.Name,
						ClusterVersion: meta.Version, ClusterType: clusterType,
						HiveShard: meta.Name, // for hive clusters, the shard is the cluster name
						OCMEnv: hiveOCM.Environment(),
						Metadata: clusterMeta, Client: client, Config: cfg, Operator: op,
					}

					checks.RunOperatorChecks(rootCtx, cc)

					output := cc.ToOutput(version)
					mu.Lock()
					allOutputs = append(allOutputs, output)
					mu.Unlock()

					fmt.Fprintf(os.Stderr, "  ✓ %s/%s: %s (%d checks)\n",
						meta.Name, strings.ToUpper(op.ShortName), cc.OverallStatus(), len(cc.Results))
				}

				// Elevation audit for hive cluster
				if client.ElevatedCallCount > 0 {
					mu.Lock()
					totalElevatedCalls += client.ElevatedCallCount
					clustersWithElevation++
					for i := range allOutputs {
						if allOutputs[i].ClusterID == hiveID && len(allOutputs[i].ElevatedOps) == 0 {
							allOutputs[i].ElevatedOps = client.ElevatedOps
						}
					}
					mu.Unlock()
				}

				client.Disconnect()
			}
		}
	}

waitAndWrite:
	interrupted := rootCtx.Err() != nil
	if interrupted {
		// Give in-flight goroutines a short window to finish current API call and record partial results
		done := make(chan struct{})
		go func() {
			clusterWg.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			fmt.Fprintf(os.Stderr, "⚠ Timed out waiting for in-flight checks — writing partial results\n")
		}
	} else {
		clusterWg.Wait()
	}

	mu.Lock()
	writeResults(allOutputs, skippedClusters, interrupted, totalElevatedCalls, clustersWithElevation)
	mu.Unlock()

	// Elevation audit summary
	if totalElevatedCalls > 0 {
		fmt.Fprintf(os.Stderr, "Elevation audit: %d elevated API calls across %d cluster(s)\n",
			totalElevatedCalls, clustersWithElevation)
	} else {
		fmt.Fprintf(os.Stderr, "Elevation audit: 0 elevated API calls (all checks used standard access or port-forward)\n")
	}

	if interrupted {
		os.Exit(130)
	}
}

// Helper types and functions

type stringSlice []string

func (s *stringSlice) String() string { return strings.Join(*s, ",") }
func (s *stringSlice) Set(v string) error {
	*s = append(*s, v)
	return nil
}

// readClusterList reads cluster identifiers from a file (one per line, first field).
// Also returns a map of ID → name when the second column is present.
func readClusterList(path string) ([]string, map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	var ids []string
	names := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) > 0 {
			ids = append(ids, fields[0])
			if len(fields) > 1 {
				names[fields[0]] = fields[1]
			}
		}
	}
	return ids, names, nil
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

func orDefault(val, def string) string {
	if val != "" {
		return val
	}
	return def
}

func envMatch(a, b string) bool {
	return normalizeEnv(a) == normalizeEnv(b)
}

func normalizeEnv(env string) string {
	if env == "stage" || env == "staging" {
		return "staging"
	}
	return env
}

func enrichSector(topo *fleet.Topology, clusterID, clusterName string) string {
	if topo == nil {
		return ""
	}
	if fc := topo.EnrichCluster(clusterID); fc != nil {
		return fc.Sector
	}
	if fc := topo.EnrichByName(clusterName); fc != nil {
		return fc.Sector
	}
	return ""
}

func classifyHiveEnv(hiveName string) string {
	switch {
	case strings.HasPrefix(hiveName, "hivei"):
		return "integration"
	case strings.HasPrefix(hiveName, "hives") || strings.HasPrefix(hiveName, "hive-stage"):
		return "staging"
	case strings.HasPrefix(hiveName, "hivep"):
		return "production"
	default:
		return "unknown"
	}
}

// runBYOCBrief reads a results JSON file and emits compact BYOC results to stdout.
func runBYOCBrief(resultsFile string) error {
	data, err := os.ReadFile(resultsFile)
	if err != nil {
		return fmt.Errorf("reading %s: %w", resultsFile, err)
	}

	var outputs []checks.ClusterOutput
	if err := json.Unmarshal(data, &outputs); err != nil {
		return fmt.Errorf("parsing %s: %w", resultsFile, err)
	}

	type briefCheck struct {
		Status     string `json:"status"`
		Message    string `json:"message"`
		ExitCode   any    `json:"exit_code,omitempty"`
		Output     string `json:"output,omitempty"`
		Stderr     string `json:"stderr,omitempty"`
		DurationMs any    `json:"duration_ms,omitempty"`
		Command    string `json:"command,omitempty"`
	}

	type briefCluster struct {
		Name    string                `json:"name"`
		Version string                `json:"version"`
		Type    string                `json:"type"`
		Region  string                `json:"region,omitempty"`
		Status  string                `json:"status"`
		Checks  map[string]briefCheck `json:"checks"`
	}

	result := map[string]briefCluster{}

	for _, out := range outputs {
		if out.OperatorName != "byoc" || out.ClusterID == "" {
			continue
		}

		cluster := briefCluster{
			Name:    out.ClusterName,
			Version: out.ClusterVersion,
			Type:    out.ClusterType,
			Status:  out.HealthSummary.OverallStatus,
			Checks:  map[string]briefCheck{},
		}
		if out.ClusterMetadata != nil {
			cluster.Region = out.ClusterMetadata.Region
		}

		for _, hc := range out.HealthChecks {
			bc := briefCheck{
				Status:  string(hc.Status),
				Message: hc.Message,
			}
			if hc.Details != nil {
				if v, ok := hc.Details["exit_code"]; ok {
					bc.ExitCode = v
				}
				if v, ok := hc.Details["stdout"].(string); ok && v != "" {
					bc.Output = v
				}
				if v, ok := hc.Details["stderr"].(string); ok && v != "" {
					bc.Stderr = v
				}
				if v, ok := hc.Details["duration_ms"]; ok {
					bc.DurationMs = v
				}
				if v, ok := hc.Details["command"].(string); ok {
					bc.Command = v
				}
			}
			cluster.Checks[hc.Check] = bc
		}

		result[out.ClusterID] = cluster
	}

	if len(result) == 0 {
		return fmt.Errorf("no BYOC results found in %s", resultsFile)
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(result)
}
