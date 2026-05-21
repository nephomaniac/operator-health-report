oc get replicasets -n openshift-monitoring --show-labels | grep configure-alertmanager
oc get replicasets -n openshift-monitoring -o wide | grep configure-alertmanager
oc get replicasets -n openshift-monitoring -o json | jq '.items[] | select(.metadata.name | contains("configure-alertmanager")) | {name: .metadata.name, labels: .metadata.labels}'
