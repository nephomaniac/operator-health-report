package ocm

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	sdk "github.com/openshift-online/ocm-sdk-go"
	cmv1 "github.com/openshift-online/ocm-sdk-go/clustersmgmt/v1"

	ocmConfig "github.com/openshift-online/ocm-common/pkg/ocm/config"
	ocmConnBuilder "github.com/openshift-online/ocm-common/pkg/ocm/connection-builder"

	"github.com/openshift/operator-health-report/pkg/logging"
)

// Well-known OCM environment URLs
const (
	IntegrationURL = "https://api.integration.openshift.com"
	StagingURL     = "https://api.stage.openshift.com"
	ProductionURL  = "https://api.openshift.com"
)

// Well-known OCM config file names per environment
var envConfigFiles = map[string]string{
	"integration": "ocm.integration.json",
	"staging":     "ocm.stg.json",
	"production":  "ocm.prod.json",
}

// Client wraps an OCM SDK connection for a specific environment.
// Multiple Clients can coexist in the same process for different environments.
type Client struct {
	conn   *sdk.Connection
	config *ocmConfig.Config
	url    string
	env    string
}

// Options configures how an OCM client is created.
// All fields are optional — unset fields inherit from the active config.
//
// Resolution order:
//  1. ConfigFile — if set, load this file as the base config
//  2. Env — if set (and no ConfigFile), load the well-known file for this env
//  3. Neither — load from OCM_CONFIG env var or default ~/.config/ocm/ocm.json
//  4. URL — if set, overrides the URL in whatever config was loaded
//  5. TokenURL, ClientID — if set, override those fields in the loaded config
type Options struct {
	ConfigFile string // explicit path to an ocm config JSON file
	Env        string // environment name: "integration", "staging", "production"
	URL        string // OCM API URL override (e.g., "https://api.stage.openshift.com")
	TokenURL   string // SSO token URL override
	ClientID   string // OAuth client ID override

	// Workload estimation for token validation
	ClusterCount  int
	OperatorCount int
	Parallelism   int
}

// NewClient creates an OCM client from the current OCM_CONFIG environment.
func NewClient() (*Client, error) {
	return NewClientWithOptions(Options{})
}

// NewClientForWorkload creates an OCM client with token validation scaled to workload.
func NewClientForWorkload(clusterCount, operatorCount, parallelism int) (*Client, error) {
	return NewClientWithOptions(Options{
		ClusterCount:  clusterCount,
		OperatorCount: operatorCount,
		Parallelism:   parallelism,
	})
}

// NewClientForEnv creates an OCM client for a specific environment.
func NewClientForEnv(env string) (*Client, error) {
	return NewClientWithOptions(Options{Env: env})
}

// NewClientForEnvWithWorkload creates an OCM client for a specific environment
// with token validation scaled to the expected workload.
func NewClientForEnvWithWorkload(env string, clusterCount, operatorCount, parallelism int) (*Client, error) {
	return NewClientWithOptions(Options{
		Env:           env,
		ClusterCount:  clusterCount,
		OperatorCount: operatorCount,
		Parallelism:   parallelism,
	})
}

// NewClientWithOptions creates an OCM client using the provided options.
func NewClientWithOptions(opts Options) (*Client, error) {
	config, err := resolveConfig(opts)
	if err != nil {
		return nil, err
	}
	if config == nil || config.URL == "" {
		return nil, fmt.Errorf("OCM not configured — run 'ocm login' first")
	}

	// Apply overrides
	if opts.URL != "" {
		config.URL = opts.URL
	}
	if opts.TokenURL != "" {
		config.TokenURL = opts.TokenURL
	}
	if opts.ClientID != "" {
		config.ClientID = opts.ClientID
	}

	clusterCount := opts.ClusterCount
	if clusterCount < 1 {
		clusterCount = 1
	}
	operatorCount := opts.OperatorCount
	if operatorCount < 1 {
		operatorCount = 1
	}
	parallelism := opts.Parallelism
	if parallelism < 1 {
		parallelism = 1
	}

	return newClientFromConfig(config, clusterCount, operatorCount, parallelism)
}

// resolveConfig loads the OCM config based on the Options resolution order.
func resolveConfig(opts Options) (*ocmConfig.Config, error) {
	// 1. Explicit config file path
	if opts.ConfigFile != "" {
		return loadConfigFile(opts.ConfigFile)
	}

	// 2. Named environment
	if opts.Env != "" {
		return loadEnvConfig(opts.Env)
	}

	// 3. Default: OCM_CONFIG env var → ~/.config/ocm/ocm.json
	config, err := ocmConfig.Load()
	if err != nil {
		return nil, fmt.Errorf("unable to load OCM config: %w", err)
	}
	return config, nil
}

// loadConfigFile loads an OCM config from an explicit file path.
func loadConfigFile(path string) (*ocmConfig.Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading OCM config %s: %w", path, err)
	}
	var config ocmConfig.Config
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("parsing OCM config %s: %w", path, err)
	}
	return &config, nil
}

func newClientFromConfig(config *ocmConfig.Config, clusterCount, operatorCount, parallelism int) (*Client, error) {
	log := logging.Log
	env := classifyEnv(config.URL)

	// Estimate runtime for token validation
	if parallelism < 1 {
		parallelism = 1
	}
	perClusterSeconds := operatorCount * 90
	totalClusterSeconds := clusterCount * perClusterSeconds
	wallClockSeconds := totalClusterSeconds / parallelism
	estimatedRuntime := time.Duration(wallClockSeconds)*time.Second + 5*time.Minute
	if estimatedRuntime < 10*time.Minute {
		estimatedRuntime = 10 * time.Minute
	}

	// Check and refresh token if needed
	remaining, err := refreshTokenTimeRemaining(config)
	if err != nil {
		log.WithField("error", err).WithField("env", env).Debug("Could not parse refresh token expiry")
	}

	log.WithField("remaining", remaining.Round(time.Minute)).
		WithField("estimated_runtime", estimatedRuntime.Round(time.Minute)).
		WithField("env", env).
		Debug("Token expiry check")

	if remaining <= 0 {
		log.WithField("env", env).Warn("OCM refresh token expired — re-login required")
		if err := refreshLogin(config.URL); err != nil {
			return nil, fmt.Errorf("OCM %s token expired and re-login failed: %w\nRun 'ocm login --url %s' manually", env, err, config.URL)
		}
		config, err = reloadConfig(config.URL)
		if err != nil {
			return nil, err
		}
	} else if remaining <= estimatedRuntime {
		log.WithField("remaining", remaining.Round(time.Minute)).
			WithField("needed", estimatedRuntime.Round(time.Minute)).
			WithField("env", env).
			Warn("OCM token may expire during run — refreshing")
		if err := refreshLogin(config.URL); err != nil {
			log.WithField("error", err).Warn("Token refresh failed — continuing with current token")
		} else {
			if reloaded, rErr := reloadConfig(config.URL); rErr == nil {
				config = reloaded
			}
		}
	}

	conn, err := ocmConnBuilder.NewConnection().
		Config(config).
		AsAgent("operator-health-report").
		Build()
	if err != nil {
		return nil, fmt.Errorf("unable to create OCM %s connection: %w", env, err)
	}

	log.WithField("url", config.URL).WithField("env", env).Info("OCM connection established")

	return &Client{conn: conn, config: config, url: config.URL, env: env}, nil
}

// Conn returns the underlying OCM SDK connection.
// Pass this to kube.ConnectToClusterWithConn to create backplane k8s clients
// that authenticate through this specific OCM environment.
func (c *Client) Conn() *sdk.Connection {
	return c.conn
}

// Close closes the OCM connection
func (c *Client) Close() {
	if c.conn != nil {
		c.conn.Close()
	}
}

// URL returns the OCM API URL
func (c *Client) URL() string {
	return c.url
}

// Environment returns a human-readable environment name
func (c *Client) Environment() string {
	return c.env
}

// IsProduction returns true if connected to production
func (c *Client) IsProduction() bool {
	return c.env == "production"
}

// GetClusterName returns the display name for a cluster ID
func (c *Client) GetClusterName(clusterID string) (string, error) {
	resp, err := c.conn.ClustersMgmt().V1().Clusters().Cluster(clusterID).Get().Send()
	if err != nil {
		return "", c.wrapError("get cluster name", err)
	}
	return resp.Body().Name(), nil
}

// GetHiveShard returns the hive shard name for a cluster ID
func (c *Client) GetHiveShard(clusterID string) (string, error) {
	resp, err := c.conn.ClustersMgmt().V1().Clusters().Cluster(clusterID).ProvisionShard().Get().Send()
	if err != nil {
		return "", c.wrapError("get provision shard", err)
	}

	hiveConfig := resp.Body().HiveConfig()
	if hiveConfig == nil {
		return "", fmt.Errorf("no hive_config in provision shard for %s", clusterID)
	}

	server := hiveConfig.Server()
	if server == "" {
		return "", fmt.Errorf("no hive server URL for %s", clusterID)
	}

	parts := strings.Split(server, ".")
	for _, p := range parts {
		if strings.HasPrefix(p, "hive") {
			return p, nil
		}
	}

	return "", fmt.Errorf("could not parse hive shard from %s", server)
}

// GetClusterMetadata fetches full cluster properties from the OCM API
func (c *Client) GetClusterMetadata(clusterID string) (*ClusterMeta, error) {
	resp, err := c.conn.ClustersMgmt().V1().Clusters().Cluster(clusterID).Get().Send()
	if err != nil {
		return nil, c.wrapError("get cluster metadata", err)
	}

	cl := resp.Body()

	apiListening := "external"
	if cl.API().Listening() == "internal" {
		apiListening = "internal"
	}

	shard := ""
	if ps, err := c.conn.ClustersMgmt().V1().Clusters().Cluster(clusterID).ProvisionShard().Get().Send(); err == nil {
		if hc := ps.Body().HiveConfig(); hc != nil {
			shard = hc.Server()
		}
	}

	// Fetch external configuration labels
	labels := map[string]string{}
	if labelsResp, err := c.conn.ClustersMgmt().V1().Clusters().Cluster(clusterID).ExternalConfiguration().Labels().List().Send(); err == nil {
		labelsResp.Items().Each(func(l *cmv1.Label) bool {
			labels[l.Key()] = l.Value()
			return true
		})
	}

	meta := &ClusterMeta{
		ID:             cl.ID(),
		ExternalID:     cl.ExternalID(),
		Name:           cl.Name(),
		State:          string(cl.Status().State()),
		APIListening:   apiListening,
		Product:        cl.Product().ID(),
		Provider:       cl.CloudProvider().ID(),
		Version:        cl.OpenshiftVersion(),
		Region:         cl.Region().ID(),
		MultiAZ:        cl.MultiAZ(),
		CNIType:        string(cl.Network().Type()),
		PrivateLink:    cl.AWS().PrivateLink(),
		STS:            cl.AWS().STS().Enabled(),
		CCS:            cl.CCS().Enabled(),
		Hypershift:     cl.Hypershift().Enabled(),
		ExistingVPC:    cl.AWS().SubnetIDs() != nil && len(cl.AWS().SubnetIDs()) > 0,
		ChannelGroup:   cl.Version().ChannelGroup(),
		LimitedSupport: cl.Status().LimitedSupportReasonCount() > 0,
		Shard:          shard,
		Labels:         labels,
	}

	// Fetch subscription for owner info
	subID, _ := cl.Subscription().GetID()
	if subID != "" {
		subResp, subErr := c.conn.AccountsMgmt().V1().Subscriptions().Subscription(subID).Get().Send()
		if subErr == nil {
			sub := subResp.Body()
			meta.OwnerEmail, _ = sub.Creator().GetEmail()
			if org, ok := sub.GetOrganizationID(); ok {
				orgResp, orgErr := c.conn.AccountsMgmt().V1().Organizations().Organization(org).Get().Send()
				if orgErr == nil {
					meta.OwnerOrg = orgResp.Body().Name()
				}
			}
		}
	}

	return meta, nil
}

// ClusterMeta holds OCM cluster properties (returned by GetClusterMetadata)
type ClusterMeta struct {
	ID             string `json:"id"`
	ExternalID     string `json:"external_id"`
	Name           string `json:"name"`
	State          string `json:"state"`
	APIListening   string `json:"api_listening"`
	Product        string `json:"product"`
	Provider       string `json:"provider"`
	Version        string `json:"version"`
	Region         string `json:"region"`
	MultiAZ        bool   `json:"multi_az"`
	CNIType        string `json:"cni_type"`
	PrivateLink    bool   `json:"privatelink"`
	STS            bool   `json:"sts"`
	CCS            bool   `json:"ccs"`
	Hypershift     bool   `json:"hypershift"`
	ExistingVPC    bool   `json:"existing_vpc"`
	ChannelGroup   string `json:"channel_group"`
	LimitedSupport bool   `json:"limited_support"`
	Shard          string            `json:"shard"`
	OwnerOrg       string            `json:"owner_org,omitempty"`
	OwnerEmail     string            `json:"owner_email,omitempty"`
	Labels         map[string]string `json:"labels,omitempty"`
}

func (c *Client) wrapError(operation string, err error) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	if strings.Contains(msg, "401") || strings.Contains(msg, "Unauthorized") ||
		strings.Contains(msg, "token") || strings.Contains(msg, "expired") {
		return fmt.Errorf("%s [%s]: authentication failed (token may be expired — run 'ocm login --url %s'): %w",
			operation, c.env, c.url, err)
	}
	return fmt.Errorf("%s [%s]: %w", operation, c.env, err)
}

// loadEnvConfig loads an OCM config for a specific environment name
func loadEnvConfig(env string) (*ocmConfig.Config, error) {
	filename, ok := envConfigFiles[env]
	if !ok {
		return nil, fmt.Errorf("unknown OCM environment %q (valid: integration, staging, production)", env)
	}

	configDir, err := os.UserConfigDir()
	if err != nil {
		return nil, fmt.Errorf("finding config dir: %w", err)
	}

	path := filepath.Join(configDir, "ocm", filename)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w (run 'ocm login --url %s' to create it)", path, err, envURL(env))
	}

	var config ocmConfig.Config
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}

	return &config, nil
}

func envURL(env string) string {
	switch env {
	case "integration":
		return IntegrationURL
	case "staging":
		return StagingURL
	case "production":
		return ProductionURL
	default:
		return env
	}
}

func classifyEnv(url string) string {
	switch {
	case strings.Contains(url, "integration"):
		return "integration"
	case strings.Contains(url, "stage"):
		return "staging"
	case strings.Contains(url, "api.openshift.com"):
		return "production"
	default:
		return url
	}
}

func reloadConfig(url string) (*ocmConfig.Config, error) {
	env := classifyEnv(url)
	if filename, ok := envConfigFiles[env]; ok {
		configDir, err := os.UserConfigDir()
		if err == nil {
			path := filepath.Join(configDir, "ocm", filename)
			data, err := os.ReadFile(path)
			if err == nil {
				var config ocmConfig.Config
				if err := json.Unmarshal(data, &config); err == nil {
					return &config, nil
				}
			}
		}
	}
	// Fall back to default load
	config, err := ocmConfig.Load()
	if err != nil {
		return nil, fmt.Errorf("unable to reload OCM config: %w", err)
	}
	return config, nil
}

// Token validation helpers

func refreshTokenTimeRemaining(config *ocmConfig.Config) (time.Duration, error) {
	if config.RefreshToken == "" {
		return 0, fmt.Errorf("no refresh token")
	}
	exp, err := jwtExpiry(config.RefreshToken)
	if err != nil {
		return 0, err
	}
	return time.Until(exp), nil
}

func jwtExpiry(token string) (time.Time, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return time.Time{}, fmt.Errorf("invalid JWT format")
	}
	payload := parts[1]
	switch len(payload) % 4 {
	case 2:
		payload += "=="
	case 3:
		payload += "="
	}
	decoded, err := base64.URLEncoding.DecodeString(payload)
	if err != nil {
		return time.Time{}, fmt.Errorf("decoding JWT payload: %w", err)
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if err := json.Unmarshal(decoded, &claims); err != nil {
		return time.Time{}, fmt.Errorf("parsing JWT claims: %w", err)
	}
	if claims.Exp == 0 {
		return time.Time{}, fmt.Errorf("no exp claim in token")
	}
	return time.Unix(claims.Exp, 0), nil
}

func refreshLogin(url string) error {
	log := logging.Log
	log.WithField("url", url).Info("Attempting OCM token refresh")

	cmd := exec.Command("ocm", "token", "--refresh")
	cmd.Env = os.Environ()
	if _, err := cmd.CombinedOutput(); err == nil {
		log.Debug("OCM token refreshed successfully")
		return nil
	}

	log.Warn("Non-interactive token refresh failed — interactive login required")
	cmd = exec.Command("ocm", "login", "--use-auth-code", "--url", url)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	return cmd.Run()
}
