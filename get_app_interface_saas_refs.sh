#!/bin/bash
saas_file="${1}"

if [ -z "${saas_file}" ]; then
  echo "Please provide a saas-file to fetch/curl from app-interface" 
  echo "(note must be logged into VPN for gitlab access)."
  echo ""
  echo "Examples..."
  echo """
  ls -1 app-interface/data/services/osd-operators/cicd/saas/ | grep yaml
  saas-aws-account-operator.yaml
  saas-certman-operator.yaml
  saas-cloud-ingress-operator.yaml
  saas-compliance-monkey.yaml
  saas-configure-alertmanager-operator.yaml
  saas-custom-domains-operator.yaml
  saas-deadmanssnitch-operator.yaml
  saas-deployment-validation-operator.yaml
  saas-dynatrace-activegate.yaml
  saas-gcp-project-operator.yaml
  saas-hypershift-dataplane-metrics-forwarder.yaml
  saas-hypershift-platform-rhobs-rules.yaml
  saas-managed-cluster-config.yaml
  saas-managed-cluster-validating-webhooks.yaml
  saas-managed-node-metadata-operator-stage.yaml
  saas-managed-node-metadata-operator.yaml
  saas-managed-upgrade-operator.yaml
  saas-managed-velero-operator.yaml
  saas-must-gather-operator.yaml
  saas-observability-operator.yaml
  saas-ocm-agent-operator.yaml
  saas-ocm-agent.yaml
  saas-osd-example-operator.yaml
  saas-osd-metrics-exporter.yaml
  saas-osd-rhobs-rules-and-dashboards.yaml
  saas-pagerduty-operator.yaml
  saas-rbac-permissions-operator.yaml
  saas-route-monitor-operator.yaml
  saas-splunk-audit-exporter.yaml
  saas-splunk-forwarder-operator.yaml
  """
  exit 1
fi

#echo "Sample command:"
#echo "curl -s https://gitlab.cee.redhat.com/service/app-interface/-/raw/master/data/services/osd-operators/cicd/saas/${saas_file}\?ref_type\=heads | yq '[[\"TARGET\", \"REF\", \"SOAKDAYS\"], [\"-----------\",\"-----------\",      \"-----------\"],(.resourceTemplates[] | select(.name = \"managed-cluster-config-production\") | .targets[] | [.name, .ref, .promotion.soakDays])] | @tsv' | column -ts $'\t'"

# Derive operator name from saas filename: saas-<operator-name>[-pko].yaml -> <operator-name>
operator_name=$(echo "$saas_file" | sed 's/^saas-//;s/-pko\.yaml$/.yaml/;s/\.yaml$//')

curl -s https://gitlab.cee.redhat.com/service/app-interface/-/raw/master/data/services/osd-operators/cicd/saas/${saas_file}\?ref_type\=heads |  yq "[[ \"TARGET\", \"REF\", \"SOAKDAYS\"], [\"-----------\",\"-----------\", \"-----------\"],(.resourceTemplates[] | select(.name == \"${operator_name}\") | .targets[] | [.name, .ref, .promotion.soakDays])] | @tsv" | column -ts $'\t'

