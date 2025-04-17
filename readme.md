# OpenShift Cluster Collector

A comprehensive tool for collecting, analyzing, and reporting on OpenShift cluster configurations and resources.

## Overview

The OpenShift Cluster Collector is a Bash script that gathers detailed information about an OpenShift cluster and generates an interactive HTML report. This tool is designed to help administrators, developers, and support teams quickly understand the state and configuration of an OpenShift cluster.

## Features

- **Comprehensive Data Collection**: Gathers information about all major OpenShift components and resources
- **Interactive HTML Report**: Generates a modern, responsive web interface to browse collected data
- **Interactive Dashboard**: Features dynamic widgets showing cluster health and resource usage
- **Data Visualization**: Includes charts and graphs for resource trends and status
- **Resource Visualization**: Presents tabular data in searchable, sortable tables
- **Syntax Highlighting**: Properly formats YAML, JSON, and log files for easy reading
- **Parallel Processing**: Efficiently collects data using parallel jobs to minimize execution time
- **Error Handling**: Robust error detection and reporting for failed commands
- **Global Search**: Search functionality across all collected resources
- **Minimal Dependencies**: Requires only standard tools available in most Linux environments

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

The HTML report includes:

- Interactive dashboard with dynamic widgets and charts
- Real-time cluster health and status indicators
- Resource usage visualizations with Chart.js
- Navigation sidebar for all resource categories
- Interactive tables for resource listings
- Syntax-highlighted code views
- Global search functionality
- Export options (CSV, Excel, PDF)

## HTML Report Features

The generated HTML report provides:

- **Interactive Dashboard**: Dynamic overview of cluster health with real-time widgets
- **Status Widgets**: Visual indicators for cluster, node, and operator health
- **Resource Usage Charts**: Visual representation of CPU and memory usage
- **Node Readiness Trends**: Chart showing node readiness over time
- **Event Monitoring**: Recent events and warnings at a glance
- **Failed Pods Summary**: Quick view of problematic workloads
- **Resource Navigation**: Categorized sidebar for easy navigation
- **Data Tables**: Sortable, searchable tables for resource listings
- **Code Viewing**: Syntax highlighting for YAML, JSON, and logs
- **Search**: Global search across all collected resources
- **Export Options**: Export data to various formats (CSV, Excel, PDF)
- **Responsive Design**: Works on desktop and mobile devices

## Troubleshooting

- **Authentication Issues**: Ensure you're logged into the OpenShift cluster with `oc login`
- **Permission Issues**: The script requires cluster-admin privileges for comprehensive data collection
- **Bash Version**: Check your Bash version with `bash --version` - must be 4.0 or newer
- **Missing Dependencies**: Install any missing utilities reported during script execution
- **Large Clusters**: For very large clusters, increase `PARALLEL_JOBS` for faster collection
- **Path Issues**: The script creates symbolic links to handle path resolution issues when viewing the report through a web server
- **CORS Issues**: Use the included `serve_report.sh` script to avoid CORS issues when viewing the report locally

## Examples

### Basic Collection

```bash
./openshiftcollector.sh
```

This will create a timestamped directory with all collected data and generate an HTML report.

To view the report, use the included server script:

```bash
cd <report_directory>
./serve_report.sh
```

Then open your browser and navigate to http://localhost:8000/

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

## Dashboard Widgets

The dashboard includes the following interactive widgets:

1. **Cluster Status Widget**
   - Shows overall cluster health status
   - Displays OpenShift version information
   - Indicates if the cluster is healthy, degraded, or updating

2. **Node Status Widget**
   - Displays total node count
   - Shows ready vs. not ready nodes
   - Visual health indicator

3. **Operator Status Widget**
   - Shows total operator count
   - Displays available, degraded, and progressing operators
   - Visual health indicator

4. **Resource Usage Widget**
   - Shows CPU and memory usage across the cluster
   - Visual progress bars with percentage indicators
   - Color-coded based on utilization levels

5. **Node Readiness Chart**
   - Trend chart showing node readiness over time
   - Visualizes cluster stability

6. **Event Summary Widget**
   - Shows recent cluster events
   - Highlights warnings and normal events
   - Quick access to full event logs

7. **Failed Pods Widget**
   - Lists pods in failed state
   - Shows failure reasons
   - Quick access to namespace details

## Adding Dashboard Widgets to Existing Reports

If you have an existing report generated before this feature was added, you can add the dashboard widgets using the provided utility script:

```bash
./add_dashboard_widgets.sh <report_directory>
```

This will:
1. Add the necessary widget containers to the dashboard
2. Add Chart.js for data visualization
3. Include the dashboard_widgets.js script

## License

This tool is provided as-is with no warranty. Use at your own risk.
