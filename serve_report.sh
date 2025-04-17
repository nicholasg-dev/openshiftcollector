#!/usr/bin/env bash

# Script to serve an OpenShift Collector report using Python's HTTP server
# Usage: ./serve_report.sh [report_directory] [port]

# Get the report directory from command line or use default
REPORT_DIR="${1:-ocp_cluster_report_20250417_132051}"
PORT="${2:-8000}"

if [ ! -d "$REPORT_DIR" ]; then
    echo "Error: Report directory '$REPORT_DIR' not found."
    exit 1
fi

echo "Starting HTTP server for $REPORT_DIR on port $PORT..."
echo "Open your browser and navigate to: http://localhost:$PORT/"
echo "Press Ctrl+C to stop the server."

# Change to the report directory
cd "$REPORT_DIR" || exit 1

# Check Python version and start the appropriate server
if command -v python3 &>/dev/null; then
    python3 -m http.server "$PORT"
elif command -v python &>/dev/null; then
    # Check if this is Python 3
    if python --version 2>&1 | grep -q "Python 3"; then
        python -m http.server "$PORT"
    else
        # Python 2
        python -m SimpleHTTPServer "$PORT"
    fi
else
    echo "Error: Python not found. Please install Python to use this script."
    exit 1
fi
