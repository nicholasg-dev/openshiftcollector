#!/usr/bin/env bash

# Script to regenerate the search index for an existing OpenShift Collector report
# Usage: ./regenerate_search_index.sh [report_directory]

# Get the report directory from command line or use default
REPORT_DIR="${1:-ocp_cluster_report_20250417_132051}"

if [ ! -d "$REPORT_DIR" ]; then
    echo "Error: Report directory '$REPORT_DIR' not found."
    exit 1
fi

echo "Regenerating search index for $REPORT_DIR..."

# Source the categories from the original script
source <(grep -A 50 "declare -A CATEGORIES=" openshiftcollector.sh | grep -B 50 "export DATATABLE_FILES")

# Function to generate search index (copied from openshiftcollector.sh)
generate_search_index() {
    local index_file="${REPORT_DIR}/search_index.json"

    # Start the JSON array
    echo "[" > "$index_file"

    # Add dashboard entry
    cat >> "$index_file" << EOF
  {
    "title": "Dashboard",
    "path": "index.html",
    "category": "pages",
    "type": "html",
    "filename": "index.html",
    "content": "OpenShift Cluster Report Dashboard"
  },
EOF

    # Add category index pages
    for category in "${!CATEGORIES[@]}"; do
        if [ "$category" != "dashboard" ]; then
            cat >> "$index_file" << EOF
  {
    "title": "${CATEGORIES[$category]}",
    "path": "${category}_index.html",
    "category": "pages",
    "type": "html",
    "filename": "${category}_index.html",
    "content": "${CATEGORIES[$category]} - OpenShift Cluster Report"
  },
EOF
        fi
    done

    # Add all HTML files
    find "${REPORT_DIR}" -type f -name "*.html" | sort | while read -r file; do
        # Skip index pages which we've already added
        if [[ "$(basename "$file")" == *_index.html || "$(basename "$file")" == "index.html" ]]; then
            continue
        fi

        local rel_path
        rel_path="${file#\""${REPORT_DIR}"\/\"}"
        local filename
        filename=$(basename "$file")
        local category
        category=$(dirname "$rel_path" | cut -d'/' -f1)
        local display_category="${CATEGORIES[$category]:-$category}"
        local title="$filename"

        # Extract content for search (first 1000 characters)
        local content
        content=$(grep -v "<script\|<style\|<link\|<!DOCTYPE\|<html\|<head\|<body\|<div\|<span\|<a\|<i\|<button" "$file" |
                      sed 's/<[^>]*>//g' | tr -d '\n' | sed 's/\s\+/ /g' | head -c 1000)

        # Add entry to search index
        cat >> "$index_file" << EOF
  {
    "title": "$title",
    "path": "$rel_path",
    "category": "$display_category",
    "type": "html",
    "filename": "$filename",
    "content": "$content"
  },
EOF
    done

    # Remove trailing comma from the last entry
    mv "$index_file" "${index_file}.tmp"
    sed '$ s/,$//' "${index_file}.tmp" > "$index_file"
    rm "${index_file}.tmp"

    # Close the JSON array
    echo "]" >> "$index_file"

    echo "Search index regenerated: $index_file"
}

# Call the function
generate_search_index

echo "Done. Please refresh your browser to test the search functionality."
