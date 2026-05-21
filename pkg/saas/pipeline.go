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
	Name       string   `json:"name"`
	Type       string   `json:"type"`       // "deploy" or "e2e"
	Env        string   `json:"env"`        // "integration", "stage", "prod-canary", "prod-2", "prod-3"
	Ref        string   `json:"ref"`
	ImageTag   string   `json:"image_tag"`
	Method     string   `json:"method"`     // PKO, OLM, or e2e
	Auto       bool     `json:"auto"`
	SoakDays   *int     `json:"soak_days"`
	Publish    []string `json:"publish"`
	Subscribe  []string `json:"subscribe"`
	SaasFile   string   `json:"saas_file"`
	TestImage  string   `json:"test_image,omitempty"`
	TestConfig string   `json:"test_config,omitempty"`
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

// Pipeline represents the complete promotion DAG for an operator
type Pipeline struct {
	OperatorName string          `json:"operator_name"`
	Nodes        []PipelineNode  `json:"nodes"`
	Edges        []PipelineEdge  `json:"edges"`
	Stages       []PipelineStage `json:"stages"`
}

// BuildPipeline constructs the full promotion pipeline for an operator
// by fetching deploy SAAS files and e2e test SAAS files, then connecting
// them via publish/subscribe channels.
func BuildPipeline(ctx context.Context, operatorName, pkoSaas, olmSaas string) (*Pipeline, error) {
	log := logging.Log

	p := &Pipeline{OperatorName: operatorName}

	// Fetch deploy targets from PKO and OLM SAAS files
	if pkoSaas != "" {
		targets, err := fetchTargets(ctx, pkoSaas)
		if err == nil {
			for _, t := range targets {
				p.Nodes = append(p.Nodes, PipelineNode{
					Name:      t.Name,
					Type:      "deploy",
					Env:       classifyEnv(t.Name),
					Ref:       t.Version,
					ImageTag:  t.ImageTag,
					Method:    "PKO",
					Auto:      t.Auto,
					SoakDays:  t.SoakDays,
					Publish:   t.Publish,
					Subscribe: t.Subscribe,
					SaasFile:  pkoSaas,
				})
			}
		}
	}

	if olmSaas != "" {
		targets, err := fetchTargets(ctx, olmSaas)
		if err == nil {
			for _, t := range targets {
				p.Nodes = append(p.Nodes, PipelineNode{
					Name:      t.Name,
					Type:      "deploy",
					Env:       classifyEnv(t.Name),
					Ref:       t.Version,
					ImageTag:  t.ImageTag,
					Method:    "OLM",
					Auto:      t.Auto,
					SoakDays:  t.SoakDays,
					Publish:   t.Publish,
					Subscribe: t.Subscribe,
					SaasFile:  olmSaas,
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
			testImage := rt.Parameters["TEST_IMAGE"]
			testConfig := rt.Parameters["OSDE2E_CONFIGS"]
			// Target-level parameters override template-level
			if v, ok := st.Parameters["TEST_IMAGE"]; ok {
				testImage = v
			}
			if v, ok := st.Parameters["OSDE2E_CONFIGS"]; ok {
				testConfig = v
			}

			nodes = append(nodes, PipelineNode{
				Name:       st.Name,
				Type:       "e2e",
				Env:        classifyEnv(st.Name),
				Ref:        st.Ref,
				Method:     "e2e",
				Auto:       st.Promotion.Auto,
				SoakDays:   st.Promotion.SoakDays,
				Publish:    st.Promotion.Publish,
				Subscribe:  st.Promotion.Subscribe,
				SaasFile:   e2ePath,
				TestImage:  testImage,
				TestConfig: testConfig,
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

// stageOrder defines the canonical promotion pipeline order.
// Nodes are placed into stages by their environment and type.
var stageOrder = []struct {
	name  string
	env   string
	isE2E bool
}{
	{"Integration", "integration", false},
	{"Int E2E", "integration", true},
	{"Stage", "stage", false},
	{"Stage E2E", "stage", true},
	{"Prod Canary", "prod-canary", false},
	{"Prod Phase 2", "production", false},  // first wave (no subscribe or subscribes to canary)
	{"Prod Phase 3", "production", false},  // second wave (subscribes to phase-2)
}

// buildStages groups nodes into the canonical promotion pipeline order
func buildStages(nodes []PipelineNode, edges []PipelineEdge) []PipelineStage {
	// Index subscribe channels per node for phase-2 vs phase-3 distinction
	nodeByName := map[string]*PipelineNode{}
	for i := range nodes {
		nodeByName[nodes[i].Name] = &nodes[i]
	}

	// For production nodes, distinguish phase-2 (subscribes to canary or nothing)
	// from phase-3 (subscribes to phase-2 deploy channels)
	prodPhase := map[string]int{} // 2 or 3
	for _, n := range nodes {
		if n.Env != "production" || n.Type == "e2e" {
			continue
		}
		if len(n.Subscribe) == 0 {
			prodPhase[n.Name] = 2
		} else {
			// Check if subscribing to canary channels or phase-2 channels
			subscribesToCanary := false
			for _, ch := range n.Subscribe {
				if strings.Contains(ch, "canary") || strings.Contains(ch, "p03") || strings.Contains(ch, "p04") {
					subscribesToCanary = true
				}
			}
			if subscribesToCanary {
				prodPhase[n.Name] = 2
			} else {
				prodPhase[n.Name] = 3
			}
		}
	}

	// Build stages in canonical order
	var stages []PipelineStage
	for _, so := range stageOrder {
		var stageNodes []string
		for _, n := range nodes {
			isE2E := n.Type == "e2e"
			if n.Env != so.env || isE2E != so.isE2E {
				continue
			}
			// For production, match phase
			if so.env == "production" && so.name == "Prod Phase 2" && prodPhase[n.Name] != 2 {
				continue
			}
			if so.env == "production" && so.name == "Prod Phase 3" && prodPhase[n.Name] != 3 {
				continue
			}
			stageNodes = append(stageNodes, n.Name)
		}
		if len(stageNodes) > 0 {
			stages = append(stages, PipelineStage{
				Name:  so.name,
				Nodes: stageNodes,
			})
		}
	}

	return stages
}


// classifyEnv determines the environment from a target name
func classifyEnv(name string) string {
	lower := strings.ToLower(name)
	switch {
	case strings.Contains(lower, "int"):
		return "integration"
	case strings.Contains(lower, "stage") || strings.Contains(lower, "hives0"):
		return "stage"
	case strings.Contains(lower, "prod-canary"):
		return "prod-canary"
	case strings.Contains(lower, "hivep"):
		// Distinguish phase-2 vs phase-3 by name patterns
		// Phase-2 canaries: hivep03, hivep04
		// Phase-2 non-canary: hivep06, hivep07
		// Phase-3: hivep05, hivep08, hivep01, hivep02
		if strings.Contains(lower, "canary") {
			return "prod-canary"
		}
		return "production"
	default:
		return "unknown"
	}
}

