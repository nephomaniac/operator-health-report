package saas

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/openshift/operator-health-report/pkg/logging"
	"gopkg.in/yaml.v3"
)

// PipelineNode represents one target in the promotion chain
type PipelineNode struct {
	Name        string   `json:"name"`
	Type        string   `json:"type"`         // "deploy" or "e2e"
	Env         string   `json:"env"`          // "integration", "stage", "prod-canary", "prod-2", "prod-3"
	Ref         string   `json:"ref"`
	ImageTag    string   `json:"image_tag"`
	Method      string   `json:"method"`       // PKO, OLM, or e2e
	Auto        bool     `json:"auto"`
	SoakDays    *int     `json:"soak_days"`
	Publish     []string `json:"publish"`
	Subscribe   []string `json:"subscribe"`
	SaasFile    string   `json:"saas_file"`
	HiveCluster string   `json:"hive_cluster,omitempty"`
	QuayRepo    string   `json:"quay_repo,omitempty"`
	RepoURL     string   `json:"repo_url,omitempty"`
	TestImage       string `json:"test_image,omitempty"`
	TestConfig      string `json:"test_config,omitempty"`
	ResolvedSHA     string `json:"resolved_sha,omitempty"`
	PipelineRunsURL string `json:"pipeline_runs_url,omitempty"`
}

// PipelineEdge represents a channel connection between two nodes
type PipelineEdge struct {
	Channel string `json:"channel"`
	From    string `json:"from"`
	To      string `json:"to"`
}

// PipelineStage groups nodes by promotion phase for rendering
type PipelineStage struct {
	Name  string   `json:"name"`
	Nodes []string `json:"nodes"`
}

// PipelineInfo holds Tekton pipeline cluster and namespace details
type PipelineInfo struct {
	Cluster      string `json:"cluster"`
	Namespace    string `json:"namespace"`
	ConsoleURL   string `json:"console_url,omitempty"`
	PipelineRunsURL string `json:"pipeline_runs_url,omitempty"`
}

// Pipeline represents the complete promotion DAG for an operator
type Pipeline struct {
	OperatorName string          `json:"operator_name"`
	RepoURL      string         `json:"repo_url,omitempty"`
	Tekton       *PipelineInfo  `json:"tekton,omitempty"`
	Nodes        []PipelineNode  `json:"nodes"`
	Edges        []PipelineEdge  `json:"edges"`
	Stages       []PipelineStage `json:"stages"`
}

// ConsoleURLResolver resolves an OCM cluster name to its OpenShift console URL.
// Pass nil to skip console URL resolution.
type ConsoleURLResolver func(clusterName string) (string, error)

// BuildPipeline constructs the full promotion pipeline for an operator
// by fetching deploy SAAS files and e2e test SAAS files, then connecting
// them via publish/subscribe channels.
func BuildPipeline(ctx context.Context, operatorName, pkoSaas, olmSaas string, resolveConsoleURL ConsoleURLResolver) (*Pipeline, error) {
	log := logging.Log

	p := &Pipeline{OperatorName: operatorName}

	// Extract pipeline provider info from the primary SAAS file
	primarySaas := pkoSaas
	if primarySaas == "" {
		primarySaas = olmSaas
	}
	if primarySaas != "" {
		sf, sfErr := fetchSaasFile(ctx, primarySaas)
		if sfErr == nil && sf != nil {
			if len(sf.ResourceTemplates) > 0 {
				p.RepoURL = sf.ResourceTemplates[0].URL
			}
			tektonInfo := parsePipelineProvider(sf.PipelinesProvider.Ref)
			if tektonInfo != nil && resolveConsoleURL != nil {
				consoleURL, err := resolveConsoleURL(tektonInfo.Cluster)
				if err == nil && consoleURL != "" {
					tektonInfo.ConsoleURL = consoleURL
					tektonInfo.PipelineRunsURL = fmt.Sprintf("%s/k8s/ns/%s/tekton.dev~v1~PipelineRun",
						strings.TrimRight(consoleURL, "/"), tektonInfo.Namespace)
				}
				p.Tekton = tektonInfo
			}
		}
	}

	// Fetch deploy targets from PKO and OLM SAAS files
	if pkoSaas != "" {
		targets, err := fetchTargets(ctx, pkoSaas)
		if err == nil {
			for _, t := range targets {
				p.Nodes = append(p.Nodes, PipelineNode{
					Name:        t.Name,
					Type:        "deploy",
					Env:         resolveEnv(t.OCMEnv, t.Name),
					Ref:         t.Version,
					ImageTag:    t.ImageTag,
					Method:      "PKO",
					Auto:        t.Auto,
					SoakDays:    t.SoakDays,
					Publish:     t.Publish,
					Subscribe:   t.Subscribe,
					SaasFile:    pkoSaas,
					HiveCluster: t.HiveCluster,
					QuayRepo:    t.QuayRepo,
					RepoURL:     t.RepoURL,
					ResolvedSHA: t.ResolvedSHA,
				})
			}
		}
	}

	if olmSaas != "" {
		targets, err := fetchTargets(ctx, olmSaas)
		if err == nil {
			for _, t := range targets {
				p.Nodes = append(p.Nodes, PipelineNode{
					Name:        t.Name,
					Type:        "deploy",
					Env:         resolveEnv(t.OCMEnv, t.Name),
					Ref:         t.Version,
					ImageTag:    t.ImageTag,
					Method:      "OLM",
					Auto:        t.Auto,
					SoakDays:    t.SoakDays,
					Publish:     t.Publish,
					Subscribe:   t.Subscribe,
					SaasFile:    olmSaas,
					HiveCluster: t.HiveCluster,
					QuayRepo:    t.QuayRepo,
					RepoURL:     t.RepoURL,
					ResolvedSHA: t.ResolvedSHA,
				})
			}
		}
	}

	// Fetch e2e test targets
	e2ePath := deriveE2EPath(pkoSaas, olmSaas)
	if e2ePath != "" {
		e2eTargets, err := fetchE2ETargets(ctx, e2ePath)
		if err != nil {
			log.WithField("path", e2ePath).WithField("error", err).Debug("Could not fetch e2e SAAS file")
		} else {
			for _, t := range e2eTargets {
				p.Nodes = append(p.Nodes, t)
			}
			log.WithField("count", len(e2eTargets)).Debug("Fetched e2e pipeline targets")
		}
	}

	// Add pipeline run URLs to all nodes
	if p.Tekton != nil && p.Tekton.PipelineRunsURL != "" {
		for i := range p.Nodes {
			p.Nodes[i].PipelineRunsURL = p.Tekton.PipelineRunsURL
		}
	}

	// Build edges by matching publish → subscribe channels
	p.Edges = buildEdges(p.Nodes)

	// Classify nodes into ordered stages
	p.Stages = buildStages(p.Nodes, p.Edges)

	log.WithField("operator", operatorName).
		WithField("nodes", len(p.Nodes)).
		WithField("edges", len(p.Edges)).
		WithField("stages", len(p.Stages)).
		Debug("Pipeline built")

	return p, nil
}

// deriveE2EPath figures out the e2e SAAS file path from the deploy SAAS filename.
// Pattern: saas-{operator}-pko.yaml → saas-{operator}/osde2e-focus-test.yaml
func deriveE2EPath(pkoSaas, olmSaas string) string {
	base := pkoSaas
	if base == "" {
		base = olmSaas
	}
	if base == "" {
		return ""
	}
	// Strip -pko.yaml or .yaml suffix to get the operator directory name
	dir := strings.TrimSuffix(base, ".yaml")
	dir = strings.TrimSuffix(dir, "-pko")
	return dir + "/osde2e-focus-test.yaml"
}

// fetchE2ETargets fetches and parses targets from an e2e SAAS file
func fetchE2ETargets(ctx context.Context, e2ePath string) ([]PipelineNode, error) {
	url := fmt.Sprintf("%s/%s?ref_type=heads", gitlabBaseURL, e2ePath)

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, err
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("GitLab returned %d for %s", resp.StatusCode, e2ePath)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var sf saasFile
	if err := yaml.Unmarshal(body, &sf); err != nil {
		return nil, fmt.Errorf("parsing e2e SAAS YAML: %w", err)
	}

	var nodes []PipelineNode
	for _, rt := range sf.ResourceTemplates {
		for _, st := range rt.Targets {
			if st.Delete || st.Disable {
				continue
			}

			// Extract test-specific parameters
			testImage, _ := rt.Parameters["TEST_IMAGE"].(string)
			testConfig, _ := rt.Parameters["OSDE2E_CONFIGS"].(string)
			if v, ok := st.Parameters["TEST_IMAGE"].(string); ok {
				testImage = v
			}
			if v, ok := st.Parameters["OSDE2E_CONFIGS"].(string); ok {
				testConfig = v
			}

			ocmEnv := ResolveHiveEnv(ctx, st.Namespace.Ref)

			nodes = append(nodes, PipelineNode{
				Name:        st.Name,
				Type:        "e2e",
				Env:         resolveEnv(ocmEnv, st.Name),
				Ref:         st.Ref,
				Method:      "e2e",
				Auto:        st.Promotion.Auto,
				SoakDays:    st.Promotion.SoakDays,
				Publish:     st.Promotion.Publish,
				Subscribe:   st.Promotion.Subscribe,
				SaasFile:    e2ePath,
				HiveCluster: extractHiveFromRef(st.Namespace.Ref),
				TestImage:   testImage,
				TestConfig:  testConfig,
			})
		}
	}

	return nodes, nil
}

// buildEdges creates edges by matching publish channels to subscribe channels
func buildEdges(nodes []PipelineNode) []PipelineEdge {
	// Index: channel → publishing node name
	publishers := map[string]string{}
	for _, n := range nodes {
		for _, ch := range n.Publish {
			publishers[ch] = n.Name
		}
	}

	var edges []PipelineEdge
	seen := map[string]bool{}

	for _, n := range nodes {
		for _, ch := range n.Subscribe {
			from, ok := publishers[ch]
			if !ok {
				continue
			}
			key := from + "→" + n.Name + ":" + ch
			if seen[key] {
				continue
			}
			seen[key] = true
			edges = append(edges, PipelineEdge{
				Channel: ch,
				From:    from,
				To:      n.Name,
			})
		}
	}

	return edges
}

// buildStages derives pipeline stages from the topological order of the
// publish/subscribe DAG. Nodes with no subscriptions come first (roots),
// then each subsequent wave of subscribers forms the next stage. Within
// each topological level, nodes are grouped by environment+type to create
// named stages (e.g., "Integration", "Int E2E", "Stage", "Stage E2E").
func buildStages(nodes []PipelineNode, edges []PipelineEdge) []PipelineStage {
	// Build adjacency: for each node, which nodes depend on it (subscribe to its publish channels)
	inDegree := map[string]int{}
	dependsOn := map[string]map[string]bool{} // node → set of nodes it depends on
	for _, n := range nodes {
		if _, ok := inDegree[n.Name]; !ok {
			inDegree[n.Name] = 0
		}
	}
	for _, e := range edges {
		if _, ok := dependsOn[e.To]; !ok {
			dependsOn[e.To] = map[string]bool{}
		}
		if !dependsOn[e.To][e.From] {
			dependsOn[e.To][e.From] = true
			inDegree[e.To]++
		}
	}

	// Topological sort by levels (BFS)
	nodeByName := map[string]*PipelineNode{}
	for i := range nodes {
		nodeByName[nodes[i].Name] = &nodes[i]
	}

	placed := map[string]bool{}
	var levels [][]string

	// Seed: nodes with no incoming edges
	var queue []string
	for _, n := range nodes {
		if inDegree[n.Name] == 0 {
			queue = append(queue, n.Name)
		}
	}

	for len(queue) > 0 {
		levels = append(levels, queue)
		for _, name := range queue {
			placed[name] = true
		}
		var next []string
		for _, n := range nodes {
			if placed[n.Name] {
				continue
			}
			ready := true
			for dep := range dependsOn[n.Name] {
				if !placed[dep] {
					ready = false
					break
				}
			}
			if ready {
				next = append(next, n.Name)
			}
		}
		queue = next
	}

	// Any nodes not placed (disconnected or cycles) go at the end
	for _, n := range nodes {
		if !placed[n.Name] {
			levels = append(levels, []string{n.Name})
			placed[n.Name] = true
		}
	}

	// Within each topological level, group by (env, isE2E) to create named stages.
	// envOrder ensures consistent ordering within a level.
	envOrder := []string{"integration", "stage", "production"}

	var stages []PipelineStage
	for _, level := range levels {
		// Group nodes in this level by (env, isE2E)
		type groupKey struct {
			env   string
			isE2E bool
		}
		groups := map[groupKey][]string{}
		for _, name := range level {
			n := nodeByName[name]
			if n == nil {
				continue
			}
			k := groupKey{env: n.Env, isE2E: n.Type == "e2e"}
			groups[k] = append(groups[k], name)
		}

		// Emit stages in env order within this level
		for _, env := range envOrder {
			for _, isE2E := range []bool{false, true} {
				k := groupKey{env: env, isE2E: isE2E}
				members, ok := groups[k]
				if !ok {
					continue
				}
				stages = append(stages, PipelineStage{
					Name:  stageName(env, isE2E),
					Nodes: members,
				})
				delete(groups, k)
			}
		}
		// Emit any remaining envs not in envOrder
		for k, members := range groups {
			stages = append(stages, PipelineStage{
				Name:  stageName(k.env, k.isE2E),
				Nodes: members,
			})
		}
	}

	// Disambiguate repeated stage names (e.g., multiple "Production" waves)
	nameCounts := map[string]int{}
	for _, s := range stages {
		nameCounts[s.Name]++
	}
	nameIdx := map[string]int{}
	for i, s := range stages {
		if nameCounts[s.Name] > 1 {
			nameIdx[s.Name]++
			stages[i].Name = fmt.Sprintf("%s (Wave %d)", s.Name, nameIdx[s.Name])
		}
	}

	return stages
}

// stageName generates a human-readable stage name from environment and type.
func stageName(env string, isE2E bool) string {
	if isE2E {
		switch env {
		case "integration":
			return "Int E2E"
		case "stage":
			return "Stage E2E"
		case "production":
			return "Prod E2E"
		default:
			return env + " E2E"
		}
	}
	switch env {
	case "integration":
		return "Integration"
	case "stage":
		return "Stage"
	case "production":
		return "Production"
	default:
		return env
	}
}


// parsePipelineProvider extracts the Tekton cluster and namespace from a pipelinesProvider $ref.
// Example ref: /services/osd-operators/configure-alertmanager-operator/pipelines/tekton-configure-alertmanager-operator-pipelines.appsrep09ue1.yaml
// → cluster: appsrep09ue1, namespace: configure-alertmanager-operator-pipelines
func parsePipelineProvider(ref string) *PipelineInfo {
	if ref == "" {
		return nil
	}

	// Extract filename from path
	parts := strings.Split(ref, "/")
	filename := parts[len(parts)-1]
	// Remove .yaml extension
	filename = strings.TrimSuffix(filename, ".yaml")

	// Pattern: tekton-{namespace}.{cluster}
	// e.g., tekton-configure-alertmanager-operator-pipelines.appsrep09ue1
	if !strings.HasPrefix(filename, "tekton-") {
		return nil
	}
	filename = strings.TrimPrefix(filename, "tekton-")

	// Split on the last dot to separate namespace from cluster
	dotIdx := strings.LastIndex(filename, ".")
	if dotIdx <= 0 {
		return nil
	}

	namespace := filename[:dotIdx]
	cluster := filename[dotIdx+1:]

	return &PipelineInfo{
		Cluster:   cluster,
		Namespace: namespace,
	}
}

// resolveEnv returns the environment for a pipeline node. Uses the
// app-interface resolved OCM environment as the source of truth; falls
// back to name-based heuristics only when resolution returned empty.
func resolveEnv(ocmEnv, name string) string {
	if ocmEnv != "" {
		return ocmEnv
	}
	lower := strings.ToLower(name)
	switch {
	case strings.Contains(lower, "int"):
		return "integration"
	case strings.Contains(lower, "stage"):
		return "stage"
	case strings.Contains(lower, "prod"):
		return "production"
	default:
		return "unknown"
	}
}

