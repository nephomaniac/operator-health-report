#!/bin/bash
#
# Quick test of PKO health check validation
# Run this while logged into an integration cluster with PKO
#

DEPLOYMENT="configure-alertmanager-operator"

echo "Testing PKO ClusterPackage health validation..."
echo ""

echo "1. Check ClusterPackage exists:"
oc get clusterpackage "$DEPLOYMENT" 2>&1
echo ""

echo "2. Test new condition queries:"
echo "   Available:"
available=$(oc get clusterpackage "$DEPLOYMENT" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")
echo "   Result: $available"
echo ""

echo "   Progressing:"
progressing=$(oc get clusterpackage "$DEPLOYMENT" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "unknown")
echo "   Result: $progressing"
echo ""

echo "   Unpacked:"
unpacked=$(oc get clusterpackage "$DEPLOYMENT" -o jsonpath='{.status.conditions[?(@.type=="Unpacked")].status}' 2>/dev/null || echo "unknown")
echo "   Result: $unpacked"
echo ""

echo "3. Health evaluation:"
if [ "$available" = "True" ] && [ "$progressing" = "False" ] && [ "$unpacked" = "True" ]; then
    echo "   ✓ PKO ClusterPackage is HEALTHY"
    echo "   (Available=True, Progressing=False, Unpacked=True)"
elif [ "$available" = "False" ]; then
    echo "   ✗ CRITICAL: ClusterPackage not available"
elif [ "$progressing" = "True" ]; then
    echo "   ⚠ WARNING: ClusterPackage update in progress"
elif [ "$unpacked" = "False" ]; then
    echo "   ✗ CRITICAL: ClusterPackage not unpacked"
else
    echo "   ⚠ WARNING: Unexpected state"
    echo "   Available=$available, Progressing=$progressing, Unpacked=$unpacked"
fi
echo ""

echo "4. Run actual health check on this cluster:"
echo "   ./collect_operator_health.sh --reason 'Test PKO validation' --format json | jq '.health_checks[] | select(.check_name | contains(\"PKO\"))'"
