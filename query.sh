#!/bin/bash
#
# CAMO (Configure AlertManager Operator) Health Check via Prometheus Metrics
#
# This script queries Prometheus to check the health status of CAMO by examining
# metrics that the operator exposes about its configuration and integrations.
#
# WHAT THIS CHECKS:
# - AlertManager configuration validation status
# - Required secrets and ConfigMaps existence
# - Integration status (PagerDuty, Dead Man's Snitch, Google Analytics)
#
# METRICS EXPLAINED:
# ✅ CRITICAL (must be healthy for CAMO to function):
#   - alertmanager_config_validation_failed: 0 = validation passing (good)
#   - am_secret_exists: 1 = alertmanager-main secret present
#   - managed_namespaces_configmap_exists: 1 = ConfigMap with managed namespaces exists
#   - ocp_namespaces_configmap_exists: 1 = ConfigMap with OCP namespaces exists
#
# ✅ IMPORTANT (expected on production clusters):
#   - pd_secret_exists: 1 = PagerDuty secret configured
#   - dms_secret_exists: 1 = Dead Man's Snitch secret configured
#   - am_secret_contains_pd: 1 = PagerDuty integration in AM secret
#   - am_secret_contains_dms: 1 = DMS integration in AM secret
#
# ❌ OPTIONAL (not required for core functionality):
#   - ga_secret_exists: Google Analytics integration (rarely used)
#   - am_secret_contains_ga: GA configuration in AM secret
#
# PREREQUISITES:
#   Port-forward to Prometheus: oc port-forward -n openshift-monitoring prometheus-k8s-0 9090:9090
#
# USAGE:
#   ./query.sh

curl -s --data-urlencode 'query={__name__=~"alertmanager_config_validation_failed|am_secret_exists|managed_namespaces_configmap_exists|ocp_namespaces_configmap_exists|ga_secret_exists|pd_secret_exists|dms_secret_exists|am_secret_contains_ga|am_secret_contains_pd|am_secret_contains_dms",namespace="openshift-monitoring"}' \
  'http://localhost:9090/api/v1/query' \
  | jq -r '.data.result[]? |
    # Determine if metric is optional (Google Analytics integration)
    (if (.metric.__name__ | test("_ga|ga_")) then " (optional)" else "" end) as $optional |
    if (.metric.__name__ | test("failed")) then
      # For "failed" metrics: 0 = good, 1 = bad
      (if .value[1] == "0" then "✅" elif .value[1] == "1" then "❌" else "❓" end) + " " + .metric.__name__ + $optional
    else
      # For "exists" and "contains" metrics: 1 = good, 0 = bad
      (if .value[1] == "1" then "✅" elif .value[1] == "0" then "❌" else "❓" end) + " " + .metric.__name__ + $optional
    end'

