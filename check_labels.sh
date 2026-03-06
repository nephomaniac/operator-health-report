#!/bin/bash
echo "=== Deployment Labels ==="
oc get deployment -n openshift-monitoring configure-alertmanager-operator -o json | jq '.spec.selector.matchLabels'

echo ""
echo "=== Pod Labels ==="
oc get pods -n openshift-monitoring -l name=configure-alertmanager-operator -o json | jq '.items[0].metadata.labels'
