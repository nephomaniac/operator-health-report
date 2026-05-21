#!/bin/bash
# Commands to investigate cluster scaling event (MC/SC compatible)
# Created: 2026-04-06
# Note: oc logs disabled on MC/SC clusters, using events and resource inspection only

echo "==================================================================="
echo "Investigating 90-Node Scaling Event"
echo "==================================================================="
echo ""

echo "[1] Checking Machine deletion events..."
echo "Command: oc get events -A --field-selector involvedObject.kind=Machine --since=240h"
echo ""
oc get events -A --field-selector involvedObject.kind=Machine --since=240h \
  > machine-events-240h.txt 2>&1
echo "✓ Saved to: machine-events-240h.txt"
echo ""

echo "[2] Checking Node lifecycle events (deletion/drain/termination)..."
echo "Command: oc get events -A --field-selector involvedObject.kind=Node --since=240h"
echo ""
oc get events -A --field-selector involvedObject.kind=Node --since=240h \
  > node-events-240h.txt 2>&1
echo "✓ Saved to: node-events-240h.txt"
echo ""

echo "[3] Checking all events in openshift-machine-api namespace..."
echo "Command: oc get events -n openshift-machine-api --since=240h"
echo ""
oc get events -n openshift-machine-api --since=240h \
  > machine-api-events-240h.txt 2>&1
echo "✓ Saved to: machine-api-events-240h.txt"
echo ""

echo "[4] Checking current MachineSet configurations..."
echo "Command: oc get machinesets -A -o json"
echo ""
oc get machinesets -A -o json > machinesets-current.json 2>&1
echo "✓ Saved to: machinesets-current.json"
echo ""

echo "[5] Checking Machine history..."
echo "Command: oc get machines -A -o json"
echo ""
oc get machines -A -o json > machines-current.json 2>&1
echo "✓ Saved to: machines-current.json"
echo ""

echo "[6] Checking MachineSet replica counts..."
echo "Command: oc get machinesets -A -o custom-columns"
echo ""
oc get machinesets -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas,AVAILABLE:.status.availableReplicas,CREATED:.metadata.creationTimestamp \
  > machinesets-replica-counts.txt 2>&1
echo "✓ Saved to: machinesets-replica-counts.txt"
echo ""

echo "==================================================================="
echo "Data collection complete!"
echo "==================================================================="
echo ""
echo "Next: Analyze the following files:"
echo "  - machine-events-240h.txt (Machine lifecycle events)"
echo "  - node-events-240h.txt (Node lifecycle events)"
echo "  - machine-api-events-240h.txt (Machine API events)"
echo "  - machinesets-current.json (current MachineSet state)"
echo "  - machines-current.json (current Machine state)"
echo "  - machinesets-replica-counts.txt (replica counts summary)"
echo ""
echo "Look for:"
echo "  - Mass Machine deletion events between April 5-7"
echo "  - Node drain/deletion events around incident time"
echo "  - MachineSet replica count changes"
echo "  - Patterns indicating 90-node removal"
echo ""
echo "Note: Cluster autoscaler logs not available (oc logs disabled on MC/SC clusters)"
echo ""
