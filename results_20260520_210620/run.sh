#!/bin/bash
cd /opt/health-report
bash collect_from_multiple_clusters.sh '--cluster-list' '/data/test_noe_container.list' '--reason' 'test no-elevate' '--oper' 'rmo' '--no-elevate' '--no-html' 
cp -v health_*.json health_*.html /results/ 2>/dev/null || true
