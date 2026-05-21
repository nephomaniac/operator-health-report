package saas

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/openshift/operator-health-report/pkg/logging"
	"gopkg.in/yaml.v3"
)

const (
	gitlabBaseURL = "https://gitlab.cee.redhat.com/service/app-interface/-/raw/master/data/services/osd-operators/cicd/saas"
	quayBaseURL   = "https://quay.io/api/v1/repository/app-sre"
)

var httpClient = &http.Client{Timeout: 30 * time.Second}

// Target represents a SAAS deployment target
type Target struct {
	Name        string   `json:"target"`
	Version     string   `json:"version"`
	ImageTag    string   `json:"image_tag"`
	SaasFile    string   `json:"saas_file"`
	Method      string   `json:"method"`       // PKO or OLM
	Auto        bool     `json:"auto"`          // auto-promotion enabled
	SoakDays    *int     `json:"soak_days"`     // soak period before promotion
	Publish     []string `json:"publish"`       // channels this target publishes to
	Subscribe   []string `json:"subscribe"`     // channels this target subscribes to
	HiveCluster string   `json:"hive_cluster"`  // hive cluster name from namespace ref
}

// saasFile is the YAML structure of an app-interface SAAS file
type saasFile struct {
	ResourceTemplates []resourceTemplate `yaml:"resourceTemplates"`
}

type resourceTemplate struct {
	Name       string            `yaml:"name"`
	Targets    []saasTarget      `yaml:"targets"`
	Parameters map[string]string `yaml:"parameters"`
}

type saasTarget struct {
	Name       string            `yaml:"name"`
	Ref        string            `yaml:"ref"`
	Delete     bool              `yaml:"delete"`
	Disable    bool              `yaml:"disable"`
	Promotion  saasPromotion     `yaml:"promotion"`
	Parameters map[string]string `yaml:"parameters"`
	Namespace  saasNamespace     `yaml:"namespace"`
}

type saasNamespace struct {
	Ref string `yaml:"$ref"`
}

type saasPromotion struct {
	SoakDays  *int     `yaml:"soakDays"`
	Auto      bool     `yaml:"auto"`
	Publish   []string `yaml:"publish"`
	Subscribe []string `yaml:"subscribe"`
}

// quayTagResponse is the Quay.io tag list API response
type quayTagResponse struct {
	Tags []quayTag `json:"tags"`
}

type quayTag struct {
	Name         string `json:"name"`
	LastModified string `json:"last_modified"`
}

// ResolveTarget finds the SAAS target for an operator on a given hive shard.
func ResolveTarget(ctx context.Context, hiveShard, ocmEnv, pkoSaas, olmSaas, targetPrefix string) (*Target, error) {
	log := logging.Log

	// Try PKO SAAS first
	if pkoSaas != "" {
		log.WithField("saas_file", pkoSaas).Debug("Resolving PKO SAAS target")
		targets, err := fetchTargets(ctx, pkoSaas)
		if err == nil && len(targets) > 0 {
			if t := matchTarget(targets, hiveShard, targetPrefix, pkoSaas, "PKO"); t != nil {
				log.WithField("target", t.Name).Info("Resolved PKO target")
				return t, nil
			}
		}
	}

	// Fall back to OLM SAAS
	if olmSaas != "" {
		log.WithField("saas_file", olmSaas).Debug("Falling back to OLM SAAS target")
		targets, err := fetchTargets(ctx, olmSaas)
		if err == nil && len(targets) > 0 {
			if t := matchTarget(targets, hiveShard, targetPrefix, olmSaas, "OLM"); t != nil {
				log.WithField("target", t.Name).Info("Resolved OLM target")
				return t, nil
			}
		}
	}

	return nil, fmt.Errorf("no SAAS target found for shard %s (prefix: %s)", hiveShard, targetPrefix)
}

func matchTarget(targets []Target, hiveShard, targetPrefix, saasFile, method string) *Target {
	simplified := strings.TrimPrefix(hiveShard, "hive-")
	candidates := []string{
		fmt.Sprintf("%s-pko-%s", targetPrefix, simplified),
		fmt.Sprintf("%s-pko-%s", targetPrefix, hiveShard),
		fmt.Sprintf("%s-%s", targetPrefix, hiveShard),
	}

	for _, candidate := range candidates {
		for i := range targets {
			if targets[i].Name == candidate {
				targets[i].SaasFile = saasFile
				targets[i].Method = method
				return &targets[i]
			}
		}
	}

	// Fuzzy match by shard number
	shardNum := extractNumber(hiveShard)
	if shardNum != "" {
		for i := range targets {
			tNum := extractNumber(targets[i].Name)
			if tNum == shardNum && strings.HasPrefix(targets[i].Name, targetPrefix+"-pko-") {
				targets[i].SaasFile = saasFile
				targets[i].Method = method
				return &targets[i]
			}
		}
	}

	return nil
}

// FetchAllTargets returns all active targets from both PKO and OLM SAAS files
func FetchAllTargets(ctx context.Context, pkoSaas, olmSaas string) ([]Target, error) {
	var all []Target

	if pkoSaas != "" {
		targets, err := fetchTargets(ctx, pkoSaas)
		if err == nil {
			for i := range targets {
				targets[i].SaasFile = pkoSaas
				targets[i].Method = "PKO"
			}
			all = append(all, targets...)
		}
	}

	if olmSaas != "" {
		targets, err := fetchTargets(ctx, olmSaas)
		if err == nil {
			for i := range targets {
				targets[i].SaasFile = olmSaas
				targets[i].Method = "OLM"
			}
			all = append(all, targets...)
		}
	}

	return all, nil
}

// fetchTargets fetches targets from a SAAS file via GitLab API and enriches with Quay image tags
func fetchTargets(ctx context.Context, saasFileName string) ([]Target, error) {
	log := logging.Log

	// Fetch SAAS YAML from GitLab
	url := fmt.Sprintf("%s/%s?ref_type=heads", gitlabBaseURL, saasFileName)
	log.WithField("url", url).Debug("Fetching SAAS file from GitLab")

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("creating request: %w", err)
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetching SAAS file: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("GitLab returned %d for %s", resp.StatusCode, saasFileName)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading response: %w", err)
	}

	// Parse YAML
	var sf saasFile
	if err := yaml.Unmarshal(body, &sf); err != nil {
		return nil, fmt.Errorf("parsing SAAS YAML: %w", err)
	}

	// Derive Quay repo name from SAAS filename
	quayRepo := deriveQuayRepo(saasFileName)

	// Fetch Quay tags for image tag enrichment
	quayTags := fetchQuayTags(ctx, quayRepo)

	// Extract active targets
	var targets []Target
	for _, rt := range sf.ResourceTemplates {
		if !strings.Contains(rt.Name, quayRepo) {
			continue
		}
		for _, st := range rt.Targets {
			if st.Delete || st.Disable {
				continue
			}

			t := Target{
				Name:        st.Name,
				Version:     st.Ref,
				Auto:        st.Promotion.Auto,
				SoakDays:    st.Promotion.SoakDays,
				Publish:     st.Promotion.Publish,
				Subscribe:   st.Promotion.Subscribe,
				HiveCluster: extractHiveFromRef(st.Namespace.Ref),
			}

			// Resolve image tag from Quay
			t.ImageTag = resolveImageTag(st.Ref, quayTags)

			targets = append(targets, t)
		}
	}

	log.WithField("saas_file", saasFileName).WithField("count", len(targets)).Debug("Parsed SAAS targets")
	return targets, nil
}

// deriveQuayRepo extracts the Quay repo name from a SAAS filename
// e.g., "saas-configure-alertmanager-operator-pko.yaml" -> "configure-alertmanager-operator"
func deriveQuayRepo(saasFileName string) string {
	name := strings.TrimPrefix(saasFileName, "saas-")
	name = strings.TrimSuffix(name, ".yaml")
	name = strings.TrimSuffix(name, "-pko")
	return name
}

// fetchQuayTags fetches recent image tags from Quay.io
func fetchQuayTags(ctx context.Context, repo string) []quayTag {
	log := logging.Log

	url := fmt.Sprintf("%s/%s/tag/?limit=200&page=1", quayBaseURL, repo)
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		log.WithField("error", err).Debug("Failed to create Quay request")
		return nil
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		log.WithField("error", err).Debug("Failed to fetch Quay tags")
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		log.WithField("status", resp.StatusCode).Debug("Quay returned non-200")
		return nil
	}

	var tagResp quayTagResponse
	if err := json.NewDecoder(resp.Body).Decode(&tagResp); err != nil {
		log.WithField("error", err).Debug("Failed to parse Quay tags")
		return nil
	}

	return tagResp.Tags
}

// resolveImageTag maps a git ref to its Quay image tag
func resolveImageTag(ref string, tags []quayTag) string {
	if len(ref) != 40 {
		return "branch:" + ref
	}

	shortCommit := ref[:7]
	suffix := "-g" + shortCommit

	for _, tag := range tags {
		if strings.HasSuffix(tag.Name, suffix) {
			return tag.Name
		}
	}

	return "sha:" + shortCommit
}

// extractHiveFromRef extracts the hive cluster name from a namespace $ref path
// e.g., "/services/osd-operators/namespaces/hives02ue1/cluster-scope.yml" → "hives02ue1"
func extractHiveFromRef(ref string) string {
	if ref == "" {
		return ""
	}
	parts := strings.Split(ref, "/")
	for i, p := range parts {
		if p == "namespaces" && i+1 < len(parts) {
			return parts[i+1]
		}
	}
	return ""
}

// extractNumber returns the first numeric sequence from a string
func extractNumber(s string) string {
	var num strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			num.WriteRune(r)
		} else if num.Len() > 0 {
			break
		}
	}
	return num.String()
}
