#!/usr/bin/env bash
#
# Get the container image tags for OneAgent and ActiveGate
# Check against current tags and suggest upgrades.
# Needs an API token set as $DT_TOKEN with the DataExport and InstallerDownload scopes in the tenant we are checking

set -e
set -o pipefail

cd "$(dirname $BASH_SOURCE)/.."

while getopts ":e:t:g:" options;do
  case "${options}" in
  t)
    export TENANT_ID=${OPTARG}
    ;;
  *)

  esac
done

if [[ -z "$DT_TOKEN" ]]; then
  echo "DT_TOKEN needs to be set to a token with the DataExport and InstallerDownload scopes"
  exit
fi

if [ -z "$TENANT_ID" ]; then
  TENANT_ID="ddl70254"
fi

API_URL="https://${TENANT_ID}.live.dynatrace.com/api/v1"
ONEAGENT_VERSION_PATH="/deployment/installer/agent/versions/unix/default"
ACTIVE_VERSION_PATH="/deployment/installer/gateway/versions/unix"
SASS_VERSION_PATH="/config/clusterversion"

function dt_api_curl {
    method=$1;
    api_path=$2;
    curl -s -L -X "${method}" "${API_URL}${api_path}" -H "Authorization: Api-Token ${DT_TOKEN}" -H "Content-Type: application/json"
}


ONE_AGENT_VERSION=$(dt_api_curl GET "${ONEAGENT_VERSION_PATH}" | jq '.availableVersions | sort |last')

ACTIVE_GATE_VERSION=$(dt_api_curl GET "${ACTIVE_VERSION_PATH}" | jq '.availableVersions | sort |last')

TENNANT_SASS_VERSION=$(dt_api_curl GET "${SASS_VERSION_PATH}" | jq .version )

echo "SaaS version in ${TENANT_ID} Tenant: ${TENNANT_SASS_VERSION}"
echo "Latest One Agent version in ${TENANT_ID} Tenant: ${ONE_AGENT_VERSION}"
echo "Latest Active Gate version in ${TENANT_ID} Tenant: ${ACTIVE_GATE_VERSION}"

