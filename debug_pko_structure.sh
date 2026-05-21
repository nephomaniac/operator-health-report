#!/bin/bash
#
# Debug PKO ClusterPackage structure to fix validation queries
#

DEPLOYMENT="configure-alertmanager-operator"

echo "=================================================="
echo "PKO ClusterPackage Debug - $DEPLOYMENT"
echo "=================================================="
echo ""

echo "1. Check if ClusterPackage exists:"
oc get clusterpackage "$DEPLOYMENT" 2>&1
echo ""

echo "2. Get full ClusterPackage YAML:"
oc get clusterpackage "$DEPLOYMENT" -o yaml 2>&1
echo ""

echo "3. Get ClusterPackage status in JSON:"
oc get clusterpackage "$DEPLOYMENT" -o json 2>&1 | jq '.status'
echo ""

echo "4. Test current jsonpath queries:"
echo "   Phase query:"
oc get clusterpackage "$DEPLOYMENT" -o jsonpath='{.status.phase}' 2>&1
echo ""
echo ""

echo "   Ready condition query:"
oc get clusterpackage "$DEPLOYMENT" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1
echo ""
echo ""

echo "5. List all conditions:"
oc get clusterpackage "$DEPLOYMENT" -o json 2>&1 | jq '.status.conditions'
echo ""

echo "6. Check alternative status fields:"
echo "   .status:"
oc get clusterpackage "$DEPLOYMENT" -o jsonpath='{.status}' 2>&1 | jq '.'
echo ""
