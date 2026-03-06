# Example Configurations

This directory contains example configuration files to help you get started with the operator health report tools.

## Files

### clusters.list.example
Example cluster list file showing the format for specifying which clusters to check.

**Usage:**
```bash
cp examples/clusters.list.example clusters.list
# Edit clusters.list with your actual cluster IDs
./collect_from_multiple_clusters.sh --cluster-list clusters.list -r "TICKET-123"
```

### config.env.example
Example environment configuration file with all configurable options.

**Usage:**
```bash
cp examples/config.env.example config.env
# Edit config.env with your settings
source config.env
./collect_from_multiple_clusters.sh -r "TICKET-123" --comprehensive-health
```

## Configuration Options

### Required
- **Cluster List**: File containing cluster IDs (one per line)
- **Reason**: JIRA ticket or reason for the health check (for audit trail)

### Optional
- **OCM Config**: Path to OCM configuration file (defaults to current OCM session)
- **Staging Clusters**: List of staging/reference clusters for version comparison
- **Expected Version**: Known-good version to compare against (alternative to staging clusters)
- **Debug Mode**: Enable detailed logging for troubleshooting
- **Namespace/Deployment**: Customize which operator to check (defaults to CAMO)

## Quick Start

### Basic Health Check
```bash
# Get cluster list from OCM
./get_clusters.sh > clusters.list

# Run health check
./collect_from_multiple_clusters.sh \
    --cluster-list clusters.list \
    -r "TICKET-123 monthly health check" \
    --comprehensive-health

# Generate HTML report
./generate_html_report.sh output.json report.html
```

### Custom Operator Check
```bash
# Configure for your operator
export NAMESPACE="my-namespace"
export DEPLOYMENT="my-operator"
export OPERATOR_NAME="my-operator"

# Run check
./collect_from_multiple_clusters.sh \
    --cluster-list clusters.list \
    -r "TICKET-123" \
    --comprehensive-health \
    --oper custom
```

## Notes

- Never commit actual `clusters.list` or `config.env` files (they're in .gitignore)
- Always use example files as templates
- Cluster IDs and configuration are environment-specific
