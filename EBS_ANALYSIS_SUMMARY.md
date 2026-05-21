# EBS Metrics Analysis Summary

## Instance Analyzed
- **Instance ID**: i-0bfb68ed870cba722
- **Node Name**: ip-10-0-0-215.ec2.internal (hs-mc-s73d6f8p0-wqn9x-worker-us-east-1a-fksmg)
- **Region**: us-east-1
- **Had Mount Errors**: ❌ NO (this node was NOT affected by the incident)

## Volumes Analyzed (6 total)
All volumes are gp3 type with 3000 IOPS and 125 MB/s throughput provisioned.

| Volume ID | Size | Device | Max Write Latency | Avg Write Latency |
|-----------|------|--------|-------------------|-------------------|
| vol-0f23d7b8b496c75cb | 300GB | /dev/xvda (root) | **2.34s** | 1.01s |
| vol-04dfb5afc2e2f1890 | 30GB | /dev/xvdab | 0.98s | 0.89s |
| vol-010c56a59c8afacc6 | 30GB | /dev/xvdac | 0.93s | 0.93s |
| vol-0b4215f3682a409fc | 30GB | /dev/xvdad | 0.89s | 0.87s |
| vol-05861de0e934b7a21 | 30GB | /dev/xvdae | 0.88s | 0.86s |
| vol-03e54bc22b9aaa157 | 30GB | /dev/xvdaa | 0.87s | 0.86s |

## Key Findings

### 1. IOPS Throttling
**Result**: ❌ **NO IOPS throttling detected during incident window (10:00-14:00 UTC)**
- All 6 volumes: VolumeIOPSExceededCheck = 0.0 throughout incident
- Only one throttling event found: 05:01 UTC (5.5 hours BEFORE incident)

### 2. Write Latency Spikes
**Result**: ⚠️  **HIGH latency detected on root volume**
- **vol-0f23d7b8b496c75cb (root volume)**: 
  - Peak: **2.34 seconds** at **11:00 UTC** (exactly when mount errors started!)
  - Additional spikes: 1.93s, 1.89s, 1.72s, 1.53s during incident
  - **2-3x higher** than other volumes (~0.87s average)

### 3. Timing Correlation
- **11:00 UTC**: Root volume max latency spike (2.34s)
- **11:01 UTC**: First mount errors began
- **11:59 UTC**: Alert fired
- **12:19 UTC**: Alert resolved

### 4. Critical Limitation
**This node did NOT experience mount errors**, so these metrics represent an **unaffected node**.

## Interpretation

### What This Tells Us:
1. **No IOPS saturation** - Volumes were not hitting their 3000 IOPS limit
2. **High write latency observed** - Even on unaffected nodes, root volume had 2.34s latency spikes
3. **Timing matches perfectly** - Latency spike at 11:00 UTC, mount errors at 11:01 UTC
4. **Root volume affected most** - 300GB root volume had worse latency than 30GB data volumes

### What This Suggests:
If an **unaffected node** experienced 2.34s write latency, affected nodes likely had **even worse latency**. The high write latency on the root filesystem (where OneAgent writes configuration files) would directly cause "mount: write error" messages.

### Root Cause Hypothesis:
**EBS write latency saturation** (not IOPS saturation) during the operator reconciliation event:
1. Operator reconciliation at 10:30 UTC triggered mass OneAgent reinitialization
2. ~100 pods simultaneously writing to root volumes caused EBS latency saturation
3. Write latency spiked to 2.3+ seconds across the cluster
4. OneAgent initialization timeouts led to "mount: write error" failures
5. Pods failed readiness checks for 60+ minutes until write pressure subsided

### Why Not IOPS Throttling:
- Average write ops: 700-900 per 5-min (30-47% of 3000 IOPS limit)
- VolumeIOPSExceededCheck: 0.0 throughout incident
- The issue was **latency**, not **throughput**

### Next Steps to Confirm:
1. Check EBS write latency metrics from **affected nodes** (if any still exist)
2. Verify if EBS service had a latency issue in us-east-1/us-east-2 on 2026-04-06
3. Check AWS Service Health Dashboard for the incident timeframe
