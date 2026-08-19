package kube

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/openshift/operator-health-report/pkg/logging"
	"github.com/openshift/operator-health-report/pkg/rhobs"

	sdk "github.com/openshift-online/ocm-sdk-go"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"
	bplogin "github.com/openshift/backplane-cli/cmd/ocm-backplane/login"
	bpconfig "github.com/openshift/backplane-cli/pkg/cli/config"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	"k8s.io/kubectl/pkg/scheme"
)

// ClusterClient provides native k8s access to a cluster via backplane.
type ClusterClient struct {
	ClusterID     string
	Reason        string
	NoElevate     bool
	OCMConfigPath string

	restConfig     *rest.Config
	elevatedConfig *rest.Config
	clientset      kubernetes.Interface
	elevatedClient kubernetes.Interface
	dynamicClient  dynamic.Interface
	elevatedDynamic dynamic.Interface

	elevationBroken      bool
	elevationDeniedReason string // "access_request", "forbidden", or ""

	rhobsClient *rhobs.Client

	pfSession       *portForwardSession
	pfSetupOnce     sync.Once
	pfSetupErr      error
	rhobsPfSession  *portForwardSession
	rhobsPfOnce     sync.Once
	rhobsPfErr      error

	// Elevation audit
	ElevatedCallCount int64
	ElevatedOps       []string
	elevMu            sync.Mutex
	CurrentCheck      string // set by check framework for audit tagging

	// Cached active alerts (shared across operators for same cluster)
	alertsOnce   sync.Once
	alertsResult string
	alertsErr    error

	// Temporary kubeconfig for external command execution (BYOC)
	kubeconfigPath string
	kubeconfigOnce sync.Once
}

// portForwardSession manages a port-forward to a Thanos/Prometheus pod.
type portForwardSession struct {
	localPort uint16
	stopChan  chan struct{}
	fw        *portforward.PortForwarder
}

const (
	maxRetries    = 3
	baseBackoff   = 2 * time.Second
	maxBackoff    = 15 * time.Second
)

// isRetryable returns true for transient errors that should be retried
func isRetryable(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "429") ||
		strings.Contains(msg, "Too Many Requests") ||
		strings.Contains(msg, "Rate limit") ||
		strings.Contains(msg, "too many requests") ||
		strings.Contains(msg, "Try again later") ||
		strings.Contains(msg, "500") ||
		strings.Contains(msg, "502") ||
		strings.Contains(msg, "503") ||
		strings.Contains(msg, "504") ||
		strings.Contains(msg, "server is currently unable") ||
		strings.Contains(msg, "connection refused") ||
		strings.Contains(msg, "connection reset") ||
		strings.Contains(msg, "i/o timeout") ||
		strings.Contains(msg, "TLS handshake timeout") ||
		strings.Contains(msg, "unexpected EOF")
}

// isAuthError returns true for errors that indicate auth/permission failures (not retryable)
func isAuthError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "Forbidden") ||
		strings.Contains(msg, "Unauthorized") ||
		strings.Contains(msg, "401") ||
		strings.Contains(msg, "403")
}

// withRetry executes fn with exponential backoff on retryable errors.
// Auth errors are returned immediately without retry.
func withRetry(ctx context.Context, description string, fn func() error) error {
	log := logging.Log
	var lastErr error
	for attempt := 0; attempt <= maxRetries; attempt++ {
		lastErr = fn()
		if lastErr == nil {
			return nil
		}
		if isAuthError(lastErr) || !isRetryable(lastErr) {
			return lastErr
		}
		if attempt < maxRetries {
			backoff := baseBackoff * time.Duration(1<<uint(attempt))
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
			jitter := time.Duration(rand.Int63n(int64(backoff / 4)))
			wait := backoff + jitter
			log.WithField("attempt", attempt+1).
				WithField("wait", wait.Round(100*time.Millisecond)).
				WithField("operation", description).
				Warn("Rate limited — retrying")
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}
	return fmt.Errorf("after %d retries: %w", maxRetries, lastErr)
}

// withRetryResult executes fn with retry, returning a value and error.
func withRetryResult[T any](ctx context.Context, description string, fn func() (T, error)) (T, error) {
	var result T
	err := withRetry(ctx, description, func() error {
		var fnErr error
		result, fnErr = fn()
		return fnErr
	})
	return result, err
}

// retryTransport wraps an HTTP transport to retry on 429 and 5xx responses.
// This ensures ALL k8s API calls (including direct Clientset() usage in
// operator checkers) get automatic retry with backoff.
func retryTransport(rt http.RoundTripper) http.RoundTripper {
	return &retryRoundTripper{delegate: rt}
}

type retryRoundTripper struct {
	delegate http.RoundTripper
}

func (r *retryRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	var resp *http.Response
	var err error

	for attempt := 0; attempt <= maxRetries; attempt++ {
		// Clone request body for retry (body may be consumed on first attempt)
		var bodyClone io.ReadCloser
		if req.Body != nil && req.GetBody != nil {
			bodyClone, _ = req.GetBody()
			req.Body = bodyClone
		}

		resp, err = r.delegate.RoundTrip(req)
		if err != nil {
			// Network errors — check if retryable
			if isRetryable(err) && attempt < maxRetries {
				backoff := baseBackoff * time.Duration(1<<uint(attempt))
				if backoff > maxBackoff {
					backoff = maxBackoff
				}
				jitter := time.Duration(rand.Int63n(int64(backoff / 4)))
				time.Sleep(backoff + jitter)
				continue
			}
			return resp, err
		}

		// HTTP-level retry on 429 and 5xx
		if resp.StatusCode == 429 || resp.StatusCode >= 500 {
			if attempt < maxRetries {
				resp.Body.Close()
				backoff := baseBackoff * time.Duration(1<<uint(attempt))
				if backoff > maxBackoff {
					backoff = maxBackoff
				}
				jitter := time.Duration(rand.Int63n(int64(backoff / 4)))
				logging.Log.WithField("status", resp.StatusCode).
					WithField("attempt", attempt+1).
					WithField("wait", (backoff + jitter).Round(100*time.Millisecond)).
					Warn("HTTP retry on server error")
				time.Sleep(backoff + jitter)
				continue
			}
		}

		return resp, err
	}

	return resp, err
}

// bpConfigMu serializes calls to backplane-cli's GetBackplaneConfiguration
// which uses viper internally and is not goroutine-safe.
var bpConfigMu sync.Mutex

// ConnectToCluster establishes a backplane connection using the default OCM config.
// For multi-environment use, prefer ConnectToClusterWithConn.
func ConnectToCluster(ctx context.Context, clusterID, reason string, noElevate bool) (*ClusterClient, error) {
	return ConnectToClusterWithConn(ctx, clusterID, reason, noElevate, nil)
}

// ConnectToClusterWithConn establishes a backplane connection using a specific OCM SDK connection.
// If ocmConn is nil, uses the default backplane configuration.
// This allows connecting to clusters across different OCM environments in the same process.
func ConnectToClusterWithConn(ctx context.Context, clusterID, reason string, noElevate bool, ocmConn *sdk.Connection) (*ClusterClient, error) {
	log := logging.Log

	// Serialize backplane config loading — viper is not goroutine-safe
	bpConfigMu.Lock()
	var bp bpconfig.BackplaneConfiguration
	var err error
	if ocmConn != nil {
		bp, err = bpconfig.GetBackplaneConfigurationWithConn(ocmConn)
	} else {
		bp, err = bpconfig.GetBackplaneConfiguration()
	}
	bpConfigMu.Unlock()
	if err != nil {
		return nil, fmt.Errorf("failed to load backplane config: %w", err)
	}

	log.WithField("cluster_id", clusterID).Info("Connecting to cluster via backplane")

	var cfg *rest.Config
	cfg, err = withRetryResult(ctx, "backplane login "+clusterID, func() (*rest.Config, error) {
		if ocmConn != nil {
			return bplogin.GetRestConfigWithConn(bp, ocmConn, clusterID)
		}
		return bplogin.GetRestConfig(bp, clusterID)
	})
	if err != nil {
		return nil, fmt.Errorf("backplane login failed: %w", err)
	}
	cfg.Timeout = 30 * time.Second
	// Enable client-go's built-in retry on 429/5xx with backoff
	cfg.Wrap(retryTransport)

	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create k8s client: %w", err)
	}

	dynClient, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create dynamic client: %w", err)
	}

	cc := &ClusterClient{
		ClusterID:     clusterID,
		Reason:        reason,
		NoElevate:     noElevate,
		restConfig:    cfg,
		clientset:     clientset,
		dynamicClient: dynClient,
	}

	// Create elevated clients if elevation is enabled
	if !noElevate && reason != "" {
		elevCfg, err := withRetryResult(ctx, "elevated login "+clusterID, func() (*rest.Config, error) {
			if ocmConn != nil {
				return bplogin.GetRestConfigAsUserWithConn(bp, ocmConn, clusterID, "backplane-cluster-admin", reason)
			}
			return bplogin.GetRestConfigAsUser(bp, clusterID, "backplane-cluster-admin", reason)
		})
		if err != nil {
			log.WithField("error", err).Warn("Failed to create elevated config — elevation will be unavailable")
			cc.elevationBroken = true
		} else {
			elevCfg.Timeout = 30 * time.Second
			elevCfg.Wrap(retryTransport)
			elevClient, err := kubernetes.NewForConfig(elevCfg)
			if err != nil {
				log.WithField("error", err).Warn("Failed to create elevated k8s client")
				cc.elevationBroken = true
			} else {
				cc.elevatedConfig = elevCfg
				cc.elevatedClient = elevClient
				cc.elevatedDynamic, _ = dynamic.NewForConfig(elevCfg)
			}
		}
	}

	return cc, nil
}

// Disconnect cleans up the connection (no-op for backplane — session is per-request)
func (cc *ClusterClient) Disconnect() {
	cc.closePortForward()
	cc.cleanupKubeconfig()
	log := logging.Log.WithField("cluster_id", cc.ClusterID)
	if cc.ElevatedCallCount > 0 {
		log.WithField("elevated_calls", cc.ElevatedCallCount).Info("Cluster disconnected (elevated operations used)")
	} else {
		log.Debug("Cluster disconnected (no elevated operations)")
	}
}

// KubeconfigPath returns a path to a temporary kubeconfig file for this cluster.
// Created via `ocm backplane login` on first call, cleaned up on Disconnect.
// Used by BYOC to give shell commands (oc, kubectl) cluster context.
func (cc *ClusterClient) KubeconfigPath() string {
	cc.kubeconfigOnce.Do(func() {
		if cc.ClusterID == "" {
			return
		}
		f, err := os.CreateTemp("", "healthcheck-kubeconfig-*.yaml")
		if err != nil {
			logging.Log.WithField("cluster_id", cc.ClusterID).Warnf("Failed to create temp kubeconfig: %v", err)
			return
		}
		f.Close()
		tmpPath := f.Name()

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		cmd := exec.CommandContext(ctx, "ocm", "backplane", "login", cc.ClusterID)
		env := append(os.Environ(), "KUBECONFIG="+tmpPath)
		if cc.OCMConfigPath != "" {
			env = append(env, "OCM_CONFIG="+cc.OCMConfigPath)
		}
		cmd.Env = env
		out, loginErr := cmd.CombinedOutput()
		if loginErr != nil {
			logging.Log.WithField("cluster_id", cc.ClusterID).Warnf("BYOC kubeconfig login failed: %v: %s", loginErr, string(out))
			os.Remove(tmpPath)
			return
		}
		cc.kubeconfigPath = tmpPath
		logging.Log.WithField("cluster_id", cc.ClusterID).Debug("BYOC kubeconfig created")
	})
	return cc.kubeconfigPath
}

func (cc *ClusterClient) cleanupKubeconfig() {
	if cc.kubeconfigPath != "" {
		os.Remove(cc.kubeconfigPath)
		cc.kubeconfigPath = ""
	}
}

// CanElevate returns true if elevation is available and working
func (cc *ClusterClient) CanElevate() bool {
	return !cc.NoElevate && !cc.elevationBroken && cc.elevatedClient != nil
}

// ElevationDeniedReason returns the reason elevation is broken, if any.
// "access_request" means the cluster requires an explicit access request.
// "forbidden" means elevation was rejected by the API server.
// "" means elevation is available.
func (cc *ClusterClient) ElevationDeniedReason() string {
	return cc.elevationDeniedReason
}

// checkElevatedError inspects an error from an elevated API call. If it's a
// Forbidden/unknown/access-request error, marks elevation as broken.
func (cc *ClusterClient) checkElevatedError(err error) {
	if err == nil {
		return
	}
	msg := err.Error()

	if strings.Contains(msg, "access request") || strings.Contains(msg, "accessrequest") {
		if !cc.elevationBroken {
			cc.elevationBroken = true
			cc.elevationDeniedReason = "access_request"
			logging.Log.Warn("Cluster requires access request — disabling elevation")
		}
		return
	}

	if strings.Contains(msg, "Forbidden") || strings.Contains(msg, "unknown (get") || strings.Contains(msg, "unknown (list") {
		if !cc.elevationBroken {
			cc.elevationBroken = true
			cc.elevationDeniedReason = "forbidden"
			logging.Log.Warn("Elevated API call failed — disabling elevation for remaining checks on this cluster")
		}
	}
}

func (cc *ClusterClient) recordElevatedOp(op string) {
	cc.elevMu.Lock()
	cc.ElevatedCallCount++
	if cc.CurrentCheck != "" && !strings.HasPrefix(op, "[") {
		op = fmt.Sprintf("[%s] %s", cc.CurrentCheck, op)
	}
	cc.ElevatedOps = append(cc.ElevatedOps, op)
	cc.elevMu.Unlock()
}

// Clientset returns the standard (non-elevated) k8s client
func (cc *ClusterClient) Clientset() kubernetes.Interface {
	return cc.clientset
}

// ElevatedClientset returns the elevated k8s client, or nil if unavailable.
// Callers should use RecordElevatedOp to describe the operation they perform.
func (cc *ClusterClient) ElevatedClientset() kubernetes.Interface {
	if !cc.CanElevate() {
		return nil
	}
	return cc.elevatedClient
}

// RecordElevatedOp logs an elevated operation for audit purposes.
// Call this when using ElevatedClientset() to describe the specific operation.
func (cc *ClusterClient) RecordElevatedOp(op string) {
	cc.recordElevatedOp(op)
}

// GetResource fetches a single resource using the dynamic client.
// Uses elevated client when elevated=true and elevation is available.
func (cc *ClusterClient) GetResource(ctx context.Context, gvr schema.GroupVersionResource, namespace, name string, elevated bool) (*unstructured.Unstructured, error) {
	client := cc.dynamicClient
	if elevated && cc.CanElevate() {
		cc.recordElevatedOp(fmt.Sprintf("get %s/%s in %s", gvr.Resource, name, namespace))
		client = cc.elevatedDynamic
	}

	obj, err := withRetryResult(ctx, "get "+gvr.Resource+"/"+name, func() (*unstructured.Unstructured, error) {
		if namespace != "" {
			return client.Resource(gvr).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
		}
		return client.Resource(gvr).Get(ctx, name, metav1.GetOptions{})
	})
	if elevated {
		cc.checkElevatedError(err)
	}
	return obj, err
}

// ListResources lists resources using the dynamic client.
func (cc *ClusterClient) ListResources(ctx context.Context, gvr schema.GroupVersionResource, namespace string, elevated bool) (*unstructured.UnstructuredList, error) {
	client := cc.dynamicClient
	if elevated && cc.CanElevate() {
		cc.recordElevatedOp(fmt.Sprintf("list %s in %s", gvr.Resource, namespace))
		client = cc.elevatedDynamic
	}

	list, err := withRetryResult(ctx, "list "+gvr.Resource, func() (*unstructured.UnstructuredList, error) {
		if namespace != "" {
			return client.Resource(gvr).Namespace(namespace).List(ctx, metav1.ListOptions{})
		}
		return client.Resource(gvr).List(ctx, metav1.ListOptions{})
	})
	if elevated {
		cc.checkElevatedError(err)
	}
	return list, err
}

// GetNamespacePhase returns the phase of a namespace
func (cc *ClusterClient) GetNamespacePhase(ctx context.Context, name string) (string, error) {
	return withRetryResult(ctx, "get namespace "+name, func() (string, error) {
		ns, err := cc.clientset.CoreV1().Namespaces().Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return "", err
		}
		return string(ns.Status.Phase), nil
	})
}

// GetDeployment returns a deployment as JSON-like map
func (cc *ClusterClient) GetDeployment(ctx context.Context, namespace, name string) (map[string]any, error) {
	deploy, err := cc.clientset.AppsV1().Deployments(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, err
	}
	data, err := json.Marshal(deploy)
	if err != nil {
		return nil, err
	}
	var result map[string]any
	json.Unmarshal(data, &result)
	return result, nil
}

// GetPods returns pods matching a label selector
func (cc *ClusterClient) GetPods(ctx context.Context, namespace, labelSelector string) (*corev1.PodList, error) {
	return withRetryResult(ctx, "get pods "+namespace, func() (*corev1.PodList, error) {
		return cc.clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
			LabelSelector: labelSelector,
		})
	})
}

// GetPodLogs returns the last N lines of logs from a deployment
func (cc *ClusterClient) GetPodLogs(ctx context.Context, namespace, podName string, tailLines int64) (string, error) {
	return withRetryResult(ctx, "get logs "+podName, func() (string, error) {
		req := cc.clientset.CoreV1().Pods(namespace).GetLogs(podName, &corev1.PodLogOptions{
			TailLines: &tailLines,
		})
		stream, err := req.Stream(ctx)
		if err != nil {
			return "", err
		}
		defer stream.Close()
		buf := new(bytes.Buffer)
		_, err = io.Copy(buf, stream)
		return buf.String(), err
	})
}

// GetContainerLogs returns the last N lines from a specific container in a pod.
func (cc *ClusterClient) GetContainerLogs(ctx context.Context, namespace, podName, container string, tailLines int64) (string, error) {
	return withRetryResult(ctx, "get logs "+podName+"/"+container, func() (string, error) {
		req := cc.clientset.CoreV1().Pods(namespace).GetLogs(podName, &corev1.PodLogOptions{
			Container: container,
			TailLines: &tailLines,
		})
		stream, err := req.Stream(ctx)
		if err != nil {
			return "", err
		}
		defer stream.Close()
		buf := new(bytes.Buffer)
		_, err = io.Copy(buf, stream)
		return buf.String(), err
	})
}

// GetEvents returns events for a specific object
func (cc *ClusterClient) GetEvents(ctx context.Context, namespace, objectName string) (*corev1.EventList, error) {
	return withRetryResult(ctx, "get events "+objectName, func() (*corev1.EventList, error) {
		return cc.clientset.CoreV1().Events(namespace).List(ctx, metav1.ListOptions{
			FieldSelector: fmt.Sprintf("involvedObject.name=%s", objectName),
		})
	})
}

// ExecInPod executes a command inside a pod and returns stdout.
// This is used for Thanos/Prometheus queries via pod exec.
// Retries on transient errors (5xx, connection reset, timeout).
func (cc *ClusterClient) ExecInPod(ctx context.Context, namespace, podName, container string, command []string, elevated bool) (string, error) {
	return withRetryResult(ctx, "exec "+podName, func() (string, error) {
		return cc.execInPodOnce(ctx, namespace, podName, container, command, elevated)
	})
}

func (cc *ClusterClient) execInPodOnce(ctx context.Context, namespace, podName, container string, command []string, elevated bool) (string, error) {
	config := cc.restConfig
	client := cc.clientset
	if elevated && cc.CanElevate() {
		cc.recordElevatedOp(fmt.Sprintf("exec %s/%s", namespace, podName))
		config = cc.elevatedConfig
		client = cc.elevatedClient
	}

	req := client.CoreV1().RESTClient().Post().
		Resource("pods").
		Name(podName).
		Namespace(namespace).
		SubResource("exec")

	req.VersionedParams(&corev1.PodExecOptions{
		Container: container,
		Command:   command,
		Stdout:    true,
		Stderr:    true,
	}, scheme.ParameterCodec)

	exec, err := remotecommand.NewSPDYExecutor(config, http.MethodPost, req.URL())
	if err != nil {
		return "", fmt.Errorf("creating executor: %w", err)
	}

	var stdout, stderr bytes.Buffer
	err = exec.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdout: &stdout,
		Stderr: &stderr,
	})
	if err != nil {
		if stderr.Len() > 0 {
			return "", fmt.Errorf("%w: %s", err, stderr.String())
		}
		return "", err
	}

	return stdout.String(), nil
}

// QueryThanos runs a PromQL instant query against the Thanos querier pod.
// Uses regular client for pod discovery, elevated client for exec.
func (cc *ClusterClient) QueryThanos(ctx context.Context, query string) (string, error) {
	log := logging.Log

	pods, err := withRetryResult(ctx, "list thanos pods", func() (*corev1.PodList, error) {
		return cc.clientset.CoreV1().Pods("openshift-monitoring").List(ctx, metav1.ListOptions{
			LabelSelector: "app.kubernetes.io/name=thanos-query",
		})
	})
	if err != nil {
		return "", fmt.Errorf("listing thanos pods: %w", err)
	}
	if len(pods.Items) == 0 {
		return "", fmt.Errorf("no thanos-querier pods found")
	}

	podName := pods.Items[0].Name
	log.WithField("pod", podName).Debug("Querying Thanos")

	// Exec into pod requires elevation
	result, err := cc.ExecInPod(ctx, "openshift-monitoring", podName, "thanos-query",
		[]string{"wget", "-q", "-T", "30", "-O-",
			fmt.Sprintf("http://localhost:9090/api/v1/query?query=%s", query)},
		true)
	cc.checkElevatedError(err)
	return result, err
}

// QueryThanosRange runs a PromQL range query against the Thanos querier pod.
func (cc *ClusterClient) QueryThanosRange(ctx context.Context, query string, start, end int64, step int) (string, error) {
	pods, err := withRetryResult(ctx, "list thanos pods", func() (*corev1.PodList, error) {
		return cc.clientset.CoreV1().Pods("openshift-monitoring").List(ctx, metav1.ListOptions{
			LabelSelector: "app.kubernetes.io/name=thanos-query",
		})
	})
	if err != nil {
		return "", fmt.Errorf("listing thanos pods: %w", err)
	}
	if len(pods.Items) == 0 {
		return "", fmt.Errorf("no thanos-querier pods found")
	}

	result, err := cc.ExecInPod(ctx, "openshift-monitoring", pods.Items[0].Name, "thanos-query",
		[]string{"wget", "-q", "-T", "30", "-O-",
			fmt.Sprintf("http://localhost:9090/api/v1/query_range?query=%s&start=%d&end=%d&step=%d",
				query, start, end, step)},
		true)
	cc.checkElevatedError(err)
	return result, err
}

// setupRHOBSPortForward establishes a port-forward to the RHOBS Prometheus pod.
func (cc *ClusterClient) setupRHOBSPortForward(ctx context.Context) error {
	log := logging.WithCheck("port_forward_rhobs")

	pods, err := cc.clientset.CoreV1().Pods("openshift-observability-operator").List(ctx, metav1.ListOptions{
		LabelSelector: "app.kubernetes.io/name=prometheus",
	})
	if err != nil || len(pods.Items) == 0 {
		return fmt.Errorf("no RHOBS prometheus pods found for port-forward: %v", err)
	}

	podName := pods.Items[0].Name
	log.WithField("pod", podName).Debug("Setting up RHOBS Prometheus port-forward")

	reqURL := cc.clientset.CoreV1().RESTClient().Post().
		Resource("pods").
		Namespace("openshift-observability-operator").
		Name(podName).
		SubResource("portforward").
		URL()

	transport, upgrader, err := spdy.RoundTripperFor(cc.restConfig)
	if err != nil {
		return fmt.Errorf("creating SPDY transport: %w", err)
	}

	dialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, "POST", reqURL)

	stopChan := make(chan struct{})
	readyChan := make(chan struct{})

	fw, err := portforward.New(dialer, []string{"0:9090"}, stopChan, readyChan, io.Discard, io.Discard)
	if err != nil {
		return fmt.Errorf("creating port-forwarder: %w", err)
	}

	errChan := make(chan error, 1)
	go func() { errChan <- fw.ForwardPorts() }()

	select {
	case <-readyChan:
	case err := <-errChan:
		return fmt.Errorf("port-forward failed: %w", err)
	case <-time.After(15 * time.Second):
		close(stopChan)
		return fmt.Errorf("port-forward timed out after 15s")
	}

	ports, err := fw.GetPorts()
	if err != nil || len(ports) == 0 {
		close(stopChan)
		return fmt.Errorf("no forwarded ports: %v", err)
	}

	localPort := ports[0].Local
	log.WithField("pod", podName).WithField("local_port", localPort).Debug("RHOBS port-forward established")

	cc.rhobsPfSession = &portForwardSession{
		localPort: localPort,
		stopChan:  stopChan,
		fw:        fw,
	}
	return nil
}

// QueryRHOBSPrometheus runs a PromQL query against the RHOBS Prometheus on MCs.
// Tries port-forward first, falls back to exec.
func (cc *ClusterClient) QueryRHOBSPrometheus(ctx context.Context, query string) (string, error) {
	// Try port-forward first
	cc.rhobsPfOnce.Do(func() {
		cc.rhobsPfErr = cc.setupRHOBSPortForward(ctx)
	})

	if cc.rhobsPfErr == nil {
		reqURL := fmt.Sprintf("http://127.0.0.1:%d/api/v1/query?query=%s",
			cc.rhobsPfSession.localPort, query) // query is already URL-encoded by callers
		client := &http.Client{Timeout: 30 * time.Second}
		resp, err := client.Get(reqURL)
		if err == nil {
			defer resp.Body.Close()
			body, readErr := io.ReadAll(resp.Body)
			if readErr == nil && resp.StatusCode == 200 {
				return string(body), nil
			}
		}
	}

	// Fall back to exec
	if !cc.CanElevate() {
		return "", fmt.Errorf("RHOBS prometheus unavailable: port-forward failed (%v), elevation not available", cc.rhobsPfErr)
	}

	pods, err := withRetryResult(ctx, "list RHOBS prometheus pods", func() (*corev1.PodList, error) {
		return cc.clientset.CoreV1().Pods("openshift-observability-operator").List(ctx, metav1.ListOptions{
			LabelSelector: "app.kubernetes.io/name=prometheus",
		})
	})
	if err != nil || len(pods.Items) == 0 {
		return "", fmt.Errorf("no RHOBS prometheus pods found: %v", err)
	}

	result, err := cc.ExecInPod(ctx, "openshift-observability-operator", pods.Items[0].Name, "prometheus",
		[]string{"curl", "-sf", "--max-time", "30",
			fmt.Sprintf("http://localhost:9090/api/v1/query?query=%s", query)},
		true)
	cc.checkElevatedError(err)
	return result, err
}

// QueryRHOBSPrometheusRange runs a PromQL range query against the RHOBS Prometheus on MCs.
func (cc *ClusterClient) QueryRHOBSPrometheusRange(ctx context.Context, query string, start, end int64, step int) (string, error) {
	cc.rhobsPfOnce.Do(func() {
		cc.rhobsPfErr = cc.setupRHOBSPortForward(ctx)
	})

	if cc.rhobsPfErr == nil {
		reqURL := fmt.Sprintf("http://127.0.0.1:%d/api/v1/query_range?query=%s&start=%d&end=%d&step=%d",
			cc.rhobsPfSession.localPort, query, start, end, step)
		client := &http.Client{Timeout: 30 * time.Second}
		resp, err := client.Get(reqURL)
		if err == nil {
			defer resp.Body.Close()
			body, readErr := io.ReadAll(resp.Body)
			if readErr == nil && resp.StatusCode == 200 {
				return string(body), nil
			}
		}
	}

	if !cc.CanElevate() {
		return "", fmt.Errorf("RHOBS prometheus unavailable: port-forward failed (%v), elevation not available", cc.rhobsPfErr)
	}

	pods, err := withRetryResult(ctx, "list RHOBS prometheus pods", func() (*corev1.PodList, error) {
		return cc.clientset.CoreV1().Pods("openshift-observability-operator").List(ctx, metav1.ListOptions{
			LabelSelector: "app.kubernetes.io/name=prometheus",
		})
	})
	if err != nil || len(pods.Items) == 0 {
		return "", fmt.Errorf("no RHOBS prometheus pods found: %v", err)
	}

	result, err := cc.ExecInPod(ctx, "openshift-observability-operator", pods.Items[0].Name, "prometheus",
		[]string{"curl", "-sf", "--max-time", "30",
			fmt.Sprintf("http://localhost:9090/api/v1/query_range?query=%s&start=%d&end=%d&step=%d", query, start, end, step)},
		true)
	cc.checkElevatedError(err)
	return result, err
}

// SetRHOBSClient configures the RHOBS remote client for out-of-band metrics access.
func (cc *ClusterClient) SetRHOBSClient(client *rhobs.Client) {
	cc.rhobsClient = client
}

// HasRHOBSRemote returns true if the RHOBS remote client is configured.
func (cc *ClusterClient) HasRHOBSRemote() bool {
	return cc.rhobsClient != nil
}

// CanQueryMetrics returns true if any metrics source is potentially available:
// elevation (exec), RHOBS remote, or port-forward (always attempted as fallback).
func (cc *ClusterClient) CanQueryMetrics() bool {
	return true
}

// QueryActiveAlerts returns cached firing alerts for this cluster.
// The query runs once and is shared across all operators on the same cluster.
func (cc *ClusterClient) QueryActiveAlerts(ctx context.Context) (string, error) {
	cc.alertsOnce.Do(func() {
		cc.alertsResult, cc.alertsErr = cc.QueryMetrics(ctx, `ALERTS{alertstate="firing",severity=~"critical|warning"}`)
	})
	return cc.alertsResult, cc.alertsErr
}

// QueryMetrics runs a PromQL instant query using the best available method:
// 1. Port-forward to Thanos (preferred — no elevation needed)
// 2. Thanos exec (fallback — requires elevation)
// 3. RHOBS remote API (out-of-band, for production MC/SC)
// The query parameter is raw PromQL — encoding is handled internally.
func (cc *ClusterClient) QueryMetrics(ctx context.Context, rawQuery string) (string, error) {
	log := logging.WithCheck("query_metrics")

	var pfErr, execErr error

	// Try 1: Port-forward to Thanos (no elevation needed)
	result, err := cc.QueryThanosViaPortForward(ctx, rawQuery)
	if err == nil {
		return result, nil
	}
	if cc.pfSetupErr != nil {
		pfErr = cc.pfSetupErr
		log.WithField("error", pfErr).Debug("Port-forward unavailable, trying exec")
	} else {
		pfErr = err
		log.WithField("error", err).Debug("Port-forward query failed, trying exec")
	}

	// Try 2: Thanos exec (requires elevation)
	if cc.CanElevate() {
		encoded := url.QueryEscape(rawQuery)
		result, err := cc.QueryThanos(ctx, encoded)
		if err == nil {
			return result, nil
		}
		execErr = err
		log.WithField("error", err).Debug("Thanos exec failed, trying RHOBS remote")
	}

	// Try 3: RHOBS remote API (out-of-band, requires vault credentials)
	if cc.rhobsClient != nil {
		return cc.rhobsClient.QueryInstant(rawQuery)
	}

	// Build descriptive error with each method's failure reason
	parts := []string{fmt.Sprintf("port-forward: %v", pfErr)}
	if cc.CanElevate() {
		parts = append(parts, fmt.Sprintf("exec: %v", execErr))
	} else {
		parts = append(parts, "exec: elevation not available")
	}
	parts = append(parts, "RHOBS remote: not configured")
	return "", fmt.Errorf("metrics unavailable — %s", strings.Join(parts, " | "))
}

// QueryMetricsRange runs a PromQL range query using the best available method.
// Same fallback chain as QueryMetrics: port-forward → exec → RHOBS remote.
func (cc *ClusterClient) QueryMetricsRange(ctx context.Context, rawQuery string, start, end int64, step int) (string, error) {
	log := logging.WithCheck("query_metrics_range")

	var pfErr, execErr error

	// Try 1: Port-forward
	result, err := cc.QueryThanosRangeViaPortForward(ctx, rawQuery, start, end, step)
	if err == nil {
		return result, nil
	}
	if cc.pfSetupErr != nil {
		pfErr = cc.pfSetupErr
	} else {
		pfErr = err
	}

	// Try 2: Thanos exec
	if cc.CanElevate() {
		encoded := url.QueryEscape(rawQuery)
		result, err := cc.QueryThanosRange(ctx, encoded, start, end, step)
		if err == nil {
			return result, nil
		}
		execErr = err
		log.WithField("error", err).Debug("Thanos exec range failed, trying RHOBS remote")
	}

	// Try 3: RHOBS remote
	if cc.rhobsClient != nil {
		return cc.rhobsClient.QueryRange(rawQuery, start, end, step)
	}

	parts := []string{fmt.Sprintf("port-forward: %v", pfErr)}
	if cc.CanElevate() {
		parts = append(parts, fmt.Sprintf("exec: %v", execErr))
	} else {
		parts = append(parts, "exec: elevation not available")
	}
	parts = append(parts, "RHOBS remote: not configured")
	return "", fmt.Errorf("metrics unavailable — %s", strings.Join(parts, " | "))
}

// setupPortForward establishes a port-forward to a Prometheus-compatible pod.
// Tries thanos-query first (federated view), falls back to prometheus-k8s.
// Called once per cluster via sync.Once. The session is cleaned up in Disconnect().
func (cc *ClusterClient) setupPortForward(ctx context.Context) error {
	log := logging.WithCheck("port_forward")

	// Try thanos-query first, then prometheus-k8s
	selectors := []struct {
		label string
		port  string
	}{
		{"app.kubernetes.io/name=thanos-query", "9090"},
		{"app.kubernetes.io/name=prometheus,app.kubernetes.io/component=prometheus", "9090"},
		{"app=prometheus,prometheus=k8s", "9090"},
	}

	var podName, targetPort string
	for _, s := range selectors {
		pods, err := cc.clientset.CoreV1().Pods("openshift-monitoring").List(ctx, metav1.ListOptions{
			LabelSelector: s.label,
		})
		if err == nil && len(pods.Items) > 0 {
			podName = pods.Items[0].Name
			targetPort = s.port
			log.WithField("pod", podName).WithField("selector", s.label).Debug("Found Prometheus-compatible pod")
			break
		}
	}

	if podName == "" {
		return fmt.Errorf("no thanos-query or prometheus pods found for port-forward")
	}

	restConfig := cc.restConfig

	reqURL := cc.clientset.CoreV1().RESTClient().Post().
		Resource("pods").
		Namespace("openshift-monitoring").
		Name(podName).
		SubResource("portforward").
		URL()

	transport, upgrader, err := spdy.RoundTripperFor(restConfig)
	if err != nil {
		return fmt.Errorf("creating SPDY transport: %w", err)
	}

	dialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, "POST", reqURL)

	stopChan := make(chan struct{})
	readyChan := make(chan struct{})

	fw, err := portforward.New(dialer, []string{"0:" + targetPort}, stopChan, readyChan, io.Discard, io.Discard)
	if err != nil {
		return fmt.Errorf("creating port-forwarder: %w", err)
	}

	errChan := make(chan error, 1)
	go func() {
		errChan <- fw.ForwardPorts()
	}()

	select {
	case <-readyChan:
	case err := <-errChan:
		return fmt.Errorf("port-forward failed: %w", err)
	case <-time.After(15 * time.Second):
		close(stopChan)
		return fmt.Errorf("port-forward timed out after 15s")
	}

	ports, err := fw.GetPorts()
	if err != nil || len(ports) == 0 {
		close(stopChan)
		return fmt.Errorf("no forwarded ports: %v", err)
	}

	localPort := ports[0].Local
	log.WithField("pod", podName).WithField("local_port", localPort).Debug("Port-forward established")

	cc.pfSession = &portForwardSession{
		localPort: localPort,
		stopChan:  stopChan,
		fw:        fw,
	}
	return nil
}

// closePortForward shuts down all port-forward sessions.
func (cc *ClusterClient) closePortForward() {
	if cc.pfSession != nil {
		close(cc.pfSession.stopChan)
		cc.pfSession = nil
	}
	if cc.rhobsPfSession != nil {
		close(cc.rhobsPfSession.stopChan)
		cc.rhobsPfSession = nil
	}
}

// QueryThanosViaPortForward runs a PromQL instant query via port-forward.
func (cc *ClusterClient) QueryThanosViaPortForward(ctx context.Context, query string) (string, error) {
	cc.pfSetupOnce.Do(func() {
		cc.pfSetupErr = cc.setupPortForward(ctx)
	})
	if cc.pfSetupErr != nil {
		return "", cc.pfSetupErr
	}

	url := fmt.Sprintf("http://127.0.0.1:%d/api/v1/query?query=%s",
		cc.pfSession.localPort, url.QueryEscape(query))

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return "", fmt.Errorf("port-forward query failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("reading port-forward response: %w", err)
	}

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("thanos returned %d via port-forward: %s", resp.StatusCode, truncateStr(string(body), 200))
	}

	return string(body), nil
}

// QueryThanosRangeViaPortForward runs a PromQL range query via port-forward.
func (cc *ClusterClient) QueryThanosRangeViaPortForward(ctx context.Context, query string, start, end int64, step int) (string, error) {
	cc.pfSetupOnce.Do(func() {
		cc.pfSetupErr = cc.setupPortForward(ctx)
	})
	if cc.pfSetupErr != nil {
		return "", cc.pfSetupErr
	}

	reqURL := fmt.Sprintf("http://127.0.0.1:%d/api/v1/query_range?query=%s&start=%d&end=%d&step=%d",
		cc.pfSession.localPort, url.QueryEscape(query), start, end, step)

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(reqURL)
	if err != nil {
		return "", fmt.Errorf("port-forward range query failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("reading port-forward response: %w", err)
	}

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("thanos returned %d via port-forward: %s", resp.StatusCode, truncateStr(string(body), 200))
	}

	return string(body), nil
}

func truncateStr(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// GetClusterVersion returns the desired cluster version string.
func (cc *ClusterClient) GetClusterVersion(ctx context.Context) (string, error) {
	return withRetryResult(ctx, "get clusterversion", func() (string, error) {
		gvr := schema.GroupVersionResource{Group: "config.openshift.io", Version: "v1", Resource: "clusterversions"}
		cv, err := cc.dynamicClient.Resource(gvr).Get(ctx, "version", metav1.GetOptions{})
		if err != nil {
			return "", err
		}
		version, _, _ := unstructured.NestedString(cv.Object, "status", "desired", "version")
		return version, nil
	})
}

// DetectClusterType returns the cluster type based on the cluster name prefix.
func DetectClusterType(clusterName string) string {
	switch {
	case strings.HasPrefix(clusterName, "hs-mc-"):
		return "management_cluster"
	case strings.HasPrefix(clusterName, "hs-sc-"):
		return "service_cluster"
	default:
		return "standard"
	}
}
