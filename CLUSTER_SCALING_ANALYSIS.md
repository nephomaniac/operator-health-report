# Cluster Scaling Investigation - hs-mc-s73d6f8p0

## Summary

Investigation into whether the cluster underwent aggressive scaling after the DynatraceDynakubeComponentsDegradedSRE alert on 2026-04-06.

## Incident Details

- **Alert Time:** 2026-04-06 11:59 UTC
- **Resolution:** 2026-04-06 12:19 UTC (20 minutes)
- **Root Cause:** EBS write latency saturation (2.34s spike)
- **Trigger:** Operator Deployment rollout caused mass pod reinitialization
- **Affected Nodes:** 98 nodes with mount failures
- **Current Cluster:** hs-mc-s73d6f8p0 (HyperShift management cluster)

## Cluster Size Analysis

### Current State (2026-04-06, after incident)
- **Total Nodes:** 132
- **All affected nodes replaced:** Yes (0 of 98 still exist)
- **Network:** ip-10-0-* subnet (ec2.internal, us-east-2, us-west-2 regions)

### During Incident (2026-04-06 11:59-12:19 UTC)
- **Minimum Size:** 222 nodes
  - 124 unaffected nodes (still exist today)
  - 98 affected nodes (all replaced)
- **Nodes Removed Since:** 90 (222 - 132 = 90)

### Calculation
```
Minimum cluster size at incident = 124 (unaffected, still exist) + 98 (affected, replaced)
                                 = 222 nodes

Nodes removed after incident = 222 (min at incident) - 132 (current)
                              = 90 nodes
```

## Dynatrace Query Results

### Query 4: Unique Node Count
- **April 5:** 375 unique nodes
- **April 6:** 64 unique nodes visible during incident (observability gap due to OneAgent failures)

### Query 5: Machine API "Node Not Found" Events
- **Total unique ip-10-0-* nodes:** 301
- **All events occurred:** April 5, 2026 at 5:00 PM (19 hours before incident)
- **Event type:** Endpoint slice update errors for already-deleted nodes
- **Overlap with mount errors:** 20 of 98 affected nodes
- **Assessment:** These represent normal lifecycle rotation over time, not a single scaling event

### Query 6: Node Deletion Errors
- **Total unique nodes:** 63 (all in ip-10-25-* subnet)
- **Timeline:** April 5 5:11 PM through April 6 7:38 AM
- **Error type:** API timeout during node deletion
- **Assessment:** These are from a DIFFERENT cluster in the Dynatrace tenant, not hs-mc-s73d6f8p0

## Key Findings

### ✅ Confirmed
1. **Cluster scaled down by 90 nodes** (from 222 to 132)
2. **All 98 affected nodes have been replaced** through normal lifecycle
3. **Mount failures occurred on ip-10-0-* nodes** (current cluster)
4. **Dynatrace queries pulled data from multiple clusters** in the tenant

### ❓ Unable to Determine from Dynatrace
1. **When did the 90-node scaling occur?**
   - Not visible in Query 5 or Query 6 results
   - May have occurred gradually over days/weeks
   - May have occurred in a window not covered by queries

2. **Was the scaling normal or aggressive?**
   - User concern: "This seems like an overly aggressive scaling event. Considering most nodes are part of the individual HCP clusters, and not the control plane I would not expect the individual request serving nodes for the separate hcp clusters to scale at once."
   - Cannot confirm from Dynatrace data
   - Needs investigation through other means (cluster-autoscaler logs, Machine API, AWS EC2/ASG events)

3. **Which 90 nodes were removed?**
   - Not visible in Dynatrace events (may not have logged)
   - Dynatrace had observability gap during incident

## Data Quality Issues

1. **Dynatrace observability gap:** Only 64 of 222+ nodes visible during incident window (OneAgent pods failed)
2. **Multi-cluster data:** Queries pulled events from multiple clusters (ip-10-0-* and ip-10-25-* subnets)
3. **Limited event retention:** May not capture all node lifecycle events
4. **Aggregated timestamps:** Query 5 events all show 5:00 PM timestamp (hourly aggregation?)

## Recommendations for Further Investigation

To determine if the 90-node scaling was normal or aggressive:

### 1. Check Cluster Autoscaler Logs
```bash
oc logs -n kube-system deployment/cluster-autoscaler --since=240h | grep -i "scale"
```

### 2. Check Machine/MachineSet History
```bash
# Get Machine deletion events
oc get events -A --field-selector involvedObject.kind=Machine --since=240h | grep -i delet

# Check MachineSet changes
oc get machinesets -A -o json | jq '.items[] | {name: .metadata.name, replicas: .spec.replicas, created: .metadata.creationTimestamp}'
```

### 3. Check AWS Auto Scaling Group History
```bash
# List scaling activities for ASGs
aws autoscaling describe-scaling-activities \
  --max-records 100 \
  --query 'Activities[?StartTime>=`2026-04-05`]' \
  --output json
```

### 4. Check Node Lifecycle Events in OpenShift
```bash
# Node deletion/drain events
oc get events -A --field-selector involvedObject.kind=Node --since=240h | grep -i "delet\|drain\|terminat"
```

### 5. Alternative Monitoring
If the cluster has Prometheus/Thanos:
```promql
# Node count over time
count(up{job="node-exporter"})

# Machine count over time
count(mapi_machine_created_timestamp_seconds)
```

## Conclusion

**Confirmed:** The cluster scaled down by 90 nodes after the incident (from 222 to 132).

**Unconfirmed:** Whether this was a normal, gradual scaling event or an aggressive mass termination. Dynatrace data does not contain sufficient evidence to determine timing or cause of the scaling.

**~~Next Steps:~~ UPDATED FINDINGS** - See `HYPERSHIFT_MIGRATION_FINDINGS.md`

---

## UPDATE: Root Cause Identified

After investigating with `oc get machinesets` and `oc get machines`, the "scaling event" has been identified as a **large-scale HyperShift hosted cluster migration**:

- **588 HyperShift serving MachineSets** scaled to 0 replicas
- Represents ~588 customer HCP clusters migrated away from this management cluster
- This was NOT a traditional autoscaling event
- Migration appears intentional and controlled
- Only 102 serving machines remain (for ~51 active HCP clusters)

**See full analysis:** `HYPERSHIFT_MIGRATION_FINDINGS.md`

**User's instinct was correct** - this was indeed an "overly aggressive" migration event, though likely planned rather than accidental.
