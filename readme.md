# OpenShift Cluster Collector

A comprehensive tool for collecting, analyzing, and reporting on OpenShift cluster configurations and resources.

## Overview

The OpenShift Cluster Collector is a Bash script that gathers detailed information about an OpenShift cluster and generates an interactive HTML report. This tool is designed to help administrators, developers, and support teams quickly understand the state and configuration of an OpenShift cluster.

## Features

- **Comprehensive Data Collection**: Gathers information about all major OpenShift components and resources
- **Interactive HTML Report**: Generates a modern, responsive web interface to browse collected data
- **Resource Visualization**: Presents tabular data in searchable, sortable tables
- **Syntax Highlighting**: Properly formats YAML, JSON, and log files for easy reading
- **Parallel Processing**: Efficiently collects data using parallel jobs to minimize execution time
- **Error Handling**: Robust error detection and reporting for failed commands
- **Minimal Dependencies**: Requires only standard tools available in most Linux environments
- **Category Index Pages**: Generates index pages for each resource category for easier navigation
- **Global Search**: Builds a JSON search index for fast, full-text search across all collected files and HTML pages
- **Breadcrumb Navigation**: Adds breadcrumbs to HTML pages for improved usability
- **File Metadata**: Shows last modified date and file size in detail views
- **Download & Copy Tools**: Each detail page includes buttons to copy file content or download the raw file
- **Automatic README**: Generates a README in the output directory describing the report contents

## Prerequisites

- Bash 4.0 or newer (for associative arrays)
- OpenShift CLI (`oc`) installed and authenticated to the cluster
- Standard Unix utilities: `xargs`, `awk`, `grep`, `sort`, `head`, `cut`, `base64`, `openssl`, `jq`, `tree`, `mktemp`, `find`, `sed`, `dirname`, `basename`

## Usage

```bash
# Basic usage with default settings
./openshiftcollector.sh

# Specify custom output directory
OUTPUT_DIR=my_cluster_report ./openshiftcollector.sh

# Adjust log collection settings
LOG_LINES=500 COLLECT_LOGS=true ./openshiftcollector.sh

# Control parallel execution
PARALLEL_JOBS=8 ./openshiftcollector.sh
```

## Configuration Options

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `OUTPUT_DIR` | `ocp_cluster_report_YYYYMMDD_HHMMSS` | Directory where report files will be stored |
| `COLLECT_LOGS` | `true` | Whether to collect logs from key components |
| `LOG_LINES` | `200` | Number of log lines to collect per container |
| `MAX_LOG_LINES` | `1000` | Maximum number of log lines to collect |
| `PARALLEL_JOBS` | `4` | Number of parallel collection jobs to run |

## Data Collection

The script collects information about the following OpenShift components and resources:

### Cluster Core
- Basic cluster information and version
- Cluster version history
- Node details and status
- Operator status and configuration
- etcd health and configuration
- API resources

### Workloads & Configuration
- Namespaces/projects
- Namespace-scoped resources (deployments, services, etc.)
- Cluster-wide resources
- Custom Resource Definitions (CRDs)
- Builds and image streams

### Infrastructure
- Network configuration
- Storage resources
- Machine API resources

### Operations
- Security settings and certificates
- RBAC configuration
- Metrics and resource usage
- Autoscalers
- Events
- Logs from critical components
- Audit configuration

## Output Structure

The script generates a structured output directory containing:

1. **Raw Data Files**: Organized by category in subdirectories
2. **HTML Report**: Interactive web interface for browsing collected data
3. **Compressed Archive**: A `.tar.gz` file containing all collected data
4. **README.txt**: Automatically generated summary of the report contents

The HTML report includes:

- Dashboard with cluster health overview
- Navigation sidebar for all resource categories
- Category index pages for each resource type
- Interactive tables for resource listings
- Syntax-highlighted code views
- Search functionality (powered by a generated JSON search index)
- Export options (CSV, Excel, PDF)
- Breadcrumb navigation for all pages
- File metadata and download/copy tools

## HTML Report Features

The generated HTML report provides:

- **Dashboard**: Overview of cluster health with key metrics
- **Resource Navigation**: Categorized sidebar for easy navigation
- **Category Index Pages**: Lists all files in each resource category
- **Data Tables**: Sortable, searchable tables for resource listings
- **Code Viewing**: Syntax highlighting for YAML, JSON, and logs
- **Search**: Global search across all collected resources and HTML pages
- **Export Options**: Export data to various formats (CSV, Excel, PDF)
- **Responsive Design**: Works on desktop and mobile devices
- **Breadcrumbs**: Easy navigation back to category or dashboard
- **File Tools**: Copy file content or download raw files directly from the report

## Troubleshooting

- **Authentication Issues**: Ensure you're logged into the OpenShift cluster with `oc login`
- **Permission Issues**: The script requires cluster-admin privileges for comprehensive data collection
- **Bash Version**: Check your Bash version with `bash --version` - must be 4.0 or newer
- **Missing Dependencies**: Install any missing utilities reported during script execution
- **Large Clusters**: For very large clusters, increase `PARALLEL_JOBS` for faster collection

## Examples

### Basic Collection

```bash
./openshiftcollector.sh
```

This will create a timestamped directory with all collected data and generate an HTML report.

### Custom Collection

```bash
OUTPUT_DIR=prod_cluster_audit PARALLEL_JOBS=8 LOG_LINES=500 ./openshiftcollector.sh
```

This will:
- Save output to `prod_cluster_audit/`
- Use 8 parallel jobs for faster collection
- Collect 500 lines of logs per container

## Security Considerations

- The script collects sensitive information about your cluster
- Secret data is redacted in the output
- Handle the generated report securely as it contains cluster configuration details
- Consider removing sensitive information before sharing reports

## License

This tool is provided as-is with no warranty. Use at your own risk.
