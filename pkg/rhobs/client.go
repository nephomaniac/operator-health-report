package rhobs

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/openshift/operator-health-report/pkg/logging"
)

const (
	ssoURL          = "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
	tenant          = "hcp"
	tokenMargin     = 30 * time.Second
	httpTimeout     = 30 * time.Second
	vaultAddrKey    = "vault_address"
	vaultPathFmt    = "rhobs_%s_vault_path"
	configPath      = ".config/osdctl"
)

// Client queries the RHOBS Observatorium API for metrics and logs.
type Client struct {
	cellURL     string
	environment string

	mu          sync.Mutex
	token       string
	tokenExpiry time.Time
	clientID    string
	clientSecret string
	vaultAddr   string
}

// NewClient creates a RHOBS client for the given cell URL and OCM environment.
// cellURL is the RHOBS cell endpoint (e.g., "https://rhobs-cell.example.com").
// environment is "production", "staging", or "integration".
func NewClient(cellURL, environment string) (*Client, error) {
	if cellURL == "" {
		return nil, fmt.Errorf("RHOBS cell URL is empty")
	}
	if !strings.HasPrefix(cellURL, "https://") {
		cellURL = "https://" + cellURL
	}

	vaultAddr, vaultPath, err := readOsdctlConfig(environment)
	if err != nil {
		return nil, fmt.Errorf("reading osdctl config for RHOBS: %w", err)
	}

	clientID, clientSecret, err := getCredsFromVault(vaultAddr, vaultPath)
	if err != nil {
		return nil, fmt.Errorf("fetching RHOBS credentials from vault: %w", err)
	}

	return &Client{
		cellURL:      cellURL,
		environment:  environment,
		clientID:     clientID,
		clientSecret: clientSecret,
		vaultAddr:    vaultAddr,
	}, nil
}

// QueryInstant runs a PromQL instant query and returns the raw JSON response
// (Prometheus API format, compatible with pkg/thanos parsers).
func (c *Client) QueryInstant(query string) (string, error) {
	token, err := c.getToken()
	if err != nil {
		return "", err
	}

	apiURL := fmt.Sprintf("%s/api/metrics/v1/%s/api/v1/query?query=%s",
		c.cellURL, tenant, url.QueryEscape(query))

	return c.doGet(apiURL, token)
}

// QueryRange runs a PromQL range query and returns the raw JSON response.
func (c *Client) QueryRange(query string, start, end int64, step int) (string, error) {
	token, err := c.getToken()
	if err != nil {
		return "", err
	}

	apiURL := fmt.Sprintf("%s/api/metrics/v1/%s/api/v1/query_range?query=%s&start=%d&end=%d&step=%d",
		c.cellURL, tenant, url.QueryEscape(query), start, end, step)

	return c.doGet(apiURL, token)
}

func (c *Client) doGet(apiURL, token string) (string, error) {
	req, err := http.NewRequest("GET", apiURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+token)

	client := &http.Client{Timeout: httpTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("RHOBS API request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("reading RHOBS response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("RHOBS API returned %d: %s", resp.StatusCode, truncate(string(body), 200))
	}

	return string(body), nil
}

func (c *Client) getToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.token != "" && time.Now().Before(c.tokenExpiry.Add(-tokenMargin)) {
		return c.token, nil
	}

	data := url.Values{
		"grant_type":    {"client_credentials"},
		"scope":         {"profile"},
		"client_id":     {c.clientID},
		"client_secret": {c.clientSecret},
	}

	resp, err := http.PostForm(ssoURL, data)
	if err != nil {
		return "", fmt.Errorf("SSO token request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("reading SSO response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("SSO returned %d: %s", resp.StatusCode, truncate(string(body), 200))
	}

	var tokenResp struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		return "", fmt.Errorf("parsing SSO response: %w", err)
	}

	if tokenResp.AccessToken == "" {
		return "", fmt.Errorf("SSO returned empty access token")
	}

	c.token = tokenResp.AccessToken
	expiresIn := tokenResp.ExpiresIn
	if expiresIn <= 0 {
		expiresIn = 300
	}
	c.tokenExpiry = time.Now().Add(time.Duration(expiresIn) * time.Second)

	log := logging.WithCheck("rhobs_remote")
	log.Debug("RHOBS token acquired, expires in ", expiresIn, "s")

	return c.token, nil
}

// readOsdctlConfig reads vault_address and rhobs_{env}_vault_path from ~/.config/osdctl
func readOsdctlConfig(environment string) (vaultAddr, vaultPath string, err error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", fmt.Errorf("cannot determine home directory: %w", err)
	}

	configFile := home + "/" + configPath
	data, err := os.ReadFile(configFile)
	if err != nil {
		return "", "", fmt.Errorf("cannot read %s: %w", configFile, err)
	}

	config := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		val = strings.Trim(val, "\"'")
		config[key] = val
	}

	vaultAddr = config[vaultAddrKey]
	if vaultAddr == "" {
		return "", "", fmt.Errorf("%s not set in %s — run 'osdctl setup' or add it manually", vaultAddrKey, configFile)
	}

	pathKey := fmt.Sprintf(vaultPathFmt, environment)
	vaultPath = config[pathKey]
	if vaultPath == "" {
		return "", "", fmt.Errorf("%s not set in %s — add this key to enable RHOBS remote metrics for %s clusters (e.g., %s: \"osd-sre/rhobs/sd-sre-%s-creds\")",
			pathKey, configFile, environment, pathKey, environment)
	}

	return vaultAddr, vaultPath, nil
}

// getCredsFromVault fetches client_id and client_secret from HashiCorp Vault
func getCredsFromVault(vaultAddr, vaultPath string) (clientID, clientSecret string, err error) {
	if err := os.Setenv("VAULT_ADDR", vaultAddr); err != nil {
		return "", "", fmt.Errorf("setting VAULT_ADDR: %w", err)
	}

	// Check vault token validity, login if needed
	checkCmd := exec.Command("vault", "token", "lookup")
	checkCmd.Stdout = nil
	checkCmd.Stderr = nil
	if err := checkCmd.Run(); err != nil {
		loginCmd := exec.Command("vault", "login", "-method=oidc", "-no-print")
		loginCmd.Stdout = os.Stderr
		loginCmd.Stderr = os.Stderr
		if err := loginCmd.Run(); err != nil {
			return "", "", fmt.Errorf("vault login failed: %w", err)
		}
	}

	output, err := exec.Command("vault", "kv", "get", "-format=json", vaultPath).Output()
	if err != nil {
		return "", "", fmt.Errorf("vault kv get %s: %w", vaultPath, err)
	}

	var vaultResp struct {
		Data struct {
			Data map[string]string `json:"data"`
		} `json:"data"`
	}
	if err := json.Unmarshal(output, &vaultResp); err != nil {
		return "", "", fmt.Errorf("parsing vault response: %w", err)
	}

	clientID = vaultResp.Data.Data["client_id"]
	if clientID == "" {
		return "", "", fmt.Errorf("no client_id in vault secret %s", vaultPath)
	}
	clientSecret = vaultResp.Data.Data["client_secret"]
	if clientSecret == "" {
		return "", "", fmt.Errorf("no client_secret in vault secret %s", vaultPath)
	}

	return clientID, clientSecret, nil
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
