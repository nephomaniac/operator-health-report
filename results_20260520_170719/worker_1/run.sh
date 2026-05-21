#!/bin/bash
cd /opt/health-report
bash collect_from_multiple_clusters.sh --cluster-list /data/clusters.list '--reason' 'investigating operator health' '--oper' 'camo' '--oper' 'rmo' '--oper' 'ome' '--no-elevate' 
cp -v health_*.json health_*.html /results/ 2>/dev/null || true
