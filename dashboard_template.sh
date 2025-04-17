#!/usr/bin/env bash

# This file contains modified HTML generation functions for the OpenShift Collector
# to include dashboard widgets and Chart.js

# Modified generate_html_header function for the dashboard page
generate_dashboard_html() {
    local title="Cluster Dashboard"
    local current_page_id="dashboard"
    
    # Generate the standard header
    generate_html_header "$title" "$current_page_id"
    
    # Add dashboard-specific content
    cat <<EOF
<div class="row row-cols-1 row-cols-md-3 g-4 mb-4">
  <!-- Cluster Status Widget -->
  <div class="col">
    <div class="card h-100 shadow-sm" id="clusterStatusWidget">
      <div class="card-header card-header-accent">
        <i class="fas fa-server me-2"></i>Cluster Status
      </div>
      <div class="card-body">
        <div class="d-flex align-items-center mb-3">
          <div class="status-indicator me-2"></div>
          <h5 class="status-text mb-0">Loading...</h5>
          <span class="status-badge badge bg-secondary ms-auto">Unknown</span>
        </div>
        <div class="row">
          <div class="col">
            <div class="text-muted small">Version</div>
            <div class="version-value fw-bold">Loading...</div>
          </div>
          <div class="col">
            <div class="text-muted small">Last Updated</div>
            <div class="update-value fw-bold">-</div>
          </div>
        </div>
      </div>
      <div class="card-footer bg-transparent">
        <a href="clusterversion.yaml.html" class="btn btn-sm btn-outline-primary">View Details</a>
      </div>
    </div>
  </div>

  <!-- Node Status Widget -->
  <div class="col">
    <div class="card h-100 shadow-sm" id="nodeStatusWidget">
      <div class="card-header card-header-accent">
        <i class="fas fa-hdd me-2"></i>Node Status
      </div>
      <div class="card-body">
        <div class="d-flex align-items-center mb-3">
          <div class="status-indicator me-2"></div>
          <h5 class="status-text mb-0">Loading...</h5>
        </div>
        <div class="row text-center">
          <div class="col">
            <div class="display-6 total-nodes">-</div>
            <div class="text-muted small">Total</div>
          </div>
          <div class="col">
            <div class="display-6 text-success ready-nodes">-</div>
            <div class="text-muted small">Ready</div>
          </div>
          <div class="col">
            <div class="display-6 text-danger not-ready-nodes">-</div>
            <div class="text-muted small">Not Ready</div>
          </div>
        </div>
      </div>
      <div class="card-footer bg-transparent">
        <a href="nodes_index.html" class="btn btn-sm btn-outline-primary">View Nodes</a>
      </div>
    </div>
  </div>

  <!-- Operator Status Widget -->
  <div class="col">
    <div class="card h-100 shadow-sm" id="operatorStatusWidget">
      <div class="card-header card-header-accent">
        <i class="fas fa-cogs me-2"></i>Operators
      </div>
      <div class="card-body">
        <div class="d-flex align-items-center mb-3">
          <div class="status-indicator me-2"></div>
          <h5 class="status-text mb-0">Loading...</h5>
        </div>
        <div class="row text-center">
          <div class="col">
            <div class="display-6 total-operators">-</div>
            <div class="text-muted small">Total</div>
          </div>
          <div class="col">
            <div class="display-6 text-success available-operators">-</div>
            <div class="text-muted small">Available</div>
          </div>
          <div class="col">
            <div class="display-6 text-danger degraded-operators">-</div>
            <div class="text-muted small">Degraded</div>
          </div>
        </div>
        <div class="text-center mt-2">
          <span class="badge bg-warning progressing-operators">-</span>
          <span class="text-muted small ms-1">Progressing</span>
        </div>
      </div>
      <div class="card-footer bg-transparent">
        <a href="operators_index.html" class="btn btn-sm btn-outline-primary">View Operators</a>
      </div>
    </div>
  </div>
</div>

<!-- Resource Usage and Node Readiness Row -->
<div class="row g-4 mb-4">
  <!-- Resource Usage Widget -->
  <div class="col-md-6">
    <div class="card shadow-sm" id="resourceUsageWidget">
      <div class="card-header card-header-accent">
        <i class="fas fa-microchip me-2"></i>Resource Usage
      </div>
      <div class="card-body">
        <div class="mb-3">
          <div class="d-flex justify-content-between mb-1">
            <span><i class="fas fa-tachometer-alt me-2"></i>CPU</span>
            <span class="cpu-usage">Loading...</span>
          </div>
          <div class="progress">
            <div class="progress-bar cpu-progress" role="progressbar" style="width: 0%" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100">
              <span class="cpu-percent">0%</span>
            </div>
          </div>
        </div>
        <div>
          <div class="d-flex justify-content-between mb-1">
            <span><i class="fas fa-memory me-2"></i>Memory</span>
            <span class="memory-usage">Loading...</span>
          </div>
          <div class="progress">
            <div class="progress-bar memory-progress" role="progressbar" style="width: 0%" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100">
              <span class="memory-percent">0%</span>
            </div>
          </div>
        </div>
      </div>
      <div class="card-footer bg-transparent">
        <a href="metrics_index.html" class="btn btn-sm btn-outline-primary">View Metrics</a>
      </div>
    </div>
  </div>

  <!-- Node Readiness Chart -->
  <div class="col-md-6">
    <div class="card shadow-sm">
      <div class="card-header card-header-accent">
        <i class="fas fa-chart-line me-2"></i>Node Readiness Trend
      </div>
      <div class="card-body">
        <div style="height: 250px;">
          <canvas id="nodeReadinessChart"></canvas>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- Events and Failed Pods Row -->
<div class="row g-4 mb-4">
  <!-- Recent Events Widget -->
  <div class="col-md-6">
    <div class="card shadow-sm" id="eventSummaryWidget">
      <div class="card-header card-header-accent">
        <i class="fas fa-bell me-2"></i>Recent Events
      </div>
      <div class="card-body">
        <div class="text-center py-3">
          <div class="spinner-border text-primary" role="status">
            <span class="visually-hidden">Loading...</span>
          </div>
          <p class="mt-2 text-muted">Loading events...</p>
        </div>
      </div>
      <div class="card-footer bg-transparent">
        <a href="events_index.html" class="btn btn-sm btn-outline-primary">View All Events</a>
      </div>
    </div>
  </div>

  <!-- Failed Pods Widget -->
  <div class="col-md-6">
    <div class="card shadow-sm" id="failedPodsWidget">
      <div class="card-header card-header-accent">
        <i class="fas fa-exclamation-circle me-2"></i>Failed Pods
      </div>
      <div class="card-body">
        <div class="text-center py-3">
          <div class="spinner-border text-primary" role="status">
            <span class="visually-hidden">Loading...</span>
          </div>
          <p class="mt-2 text-muted">Loading failed pods...</p>
        </div>
      </div>
      <div class="card-footer bg-transparent">
        <a href="namespaces_index.html" class="btn btn-sm btn-outline-primary">View All Namespaces</a>
      </div>
    </div>
  </div>
</div>

<!-- Quick Links Section -->
<div class="card mb-4 shadow-sm">
  <div class="card-header card-header-accent">
    <i class="fas fa-link me-2"></i>Quick Access
  </div>
  <div class="card-body">
    <div class="row">
      <div class="col-md-4 mb-3">
        <h6><i class="fas fa-server me-2 text-success"></i>Infrastructure</h6>
        <ul class="list-unstyled ms-3">
          <li><a href="nodes_index.html">Nodes</a></li>
          <li><a href="infrastructure.yaml.html">Cluster Infrastructure</a></li>
          <li><a href="machine_api_index.html">Machine API</a></li>
        </ul>
      </div>
      <div class="col-md-4 mb-3">
        <h6><i class="fas fa-shield-alt me-2 text-danger"></i>Security & Access</h6>
        <ul class="list-unstyled ms-3">
          <li><a href="rbac_index.html">RBAC Configuration</a></li>
          <li><a href="security_index.html">Security Context Constraints</a></li>
          <li><a href="security/oauth_cluster.yaml.html">Authentication</a></li>
        </ul>
      </div>
      <div class="col-md-4 mb-3">
        <h6><i class="fas fa-network-wired me-2 text-primary"></i>Network & Storage</h6>
        <ul class="list-unstyled ms-3">
          <li><a href="network_index.html">Network Configuration</a></li>
          <li><a href="storage_index.html">Storage Resources</a></li>
          <li><a href="network/network_config.yaml.html">Cluster Network</a></li>
        </ul>
      </div>
    </div>
  </div>
</div>
EOF

    # Generate the standard footer with additional scripts
    generate_dashboard_html_footer
}

# Modified generate_html_footer function for the dashboard page
generate_dashboard_html_footer() {
    cat <<EOF
  </main>
</div>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
<script src="https://code.jquery.com/jquery-3.7.1.min.js"></script>
<script src="https://cdn.datatables.net/1.13.7/js/jquery.dataTables.min.js"></script>
<script src="https://cdn.datatables.net/1.13.7/js/dataTables.bootstrap5.min.js"></script>
<script src="https://cdn.datatables.net/responsive/2.5.0/js/dataTables.responsive.min.js"></script>
<script src="https://cdn.datatables.net/responsive/2.5.0/js/responsive.bootstrap5.min.js"></script>
<script src="https://cdn.datatables.net/buttons/2.4.2/js/dataTables.buttons.min.js"></script>
<script src="https://cdn.datatables.net/buttons/2.4.2/js/buttons.bootstrap5.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/pdfmake/0.1.53/pdfmake.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/pdfmake/0.1.53/vfs_fonts.js"></script>
<script src="https://cdn.datatables.net/buttons/2.4.2/js/buttons.html5.min.js"></script>
<script src="https://cdn.datatables.net/buttons/2.4.2/js/buttons.print.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/prism.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/plugins/autoloader/prism-autoloader.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/plugins/line-numbers/prism-line-numbers.min.js"></script>
<!-- Add Chart.js for dashboard widgets -->
<script src="https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js"></script>
<!-- Add dashboard widgets script -->
<script src="dashboard_widgets.js"></script>
<script>
  \$(document).ready(function() {
    // Initialize DataTables with improved features
    var dataTable = \$('table.datatable').DataTable({
      responsive: true,
      dom: 'Bfrtip',
      buttons: [
        {
          extend: 'copyHtml5',
          text: '<i class="fas fa-copy"></i>',
          titleAttr: 'Copy to clipboard',
          className: 'btn btn-sm btn-outline-secondary me-1'
        },
        {
          extend: 'csvHtml5',
          text: '<i class="fas fa-file-csv"></i>',
          titleAttr: 'Export as CSV',
          className: 'btn btn-sm btn-outline-secondary me-1'
        },
        {
          extend: 'excelHtml5',
          text: '<i class="fas fa-file-excel"></i>',
          titleAttr: 'Export as Excel',
          className: 'btn btn-sm btn-outline-secondary me-1'
        },
        {
          extend: 'pdfHtml5',
          text: '<i class="fas fa-file-pdf"></i>',
          titleAttr: 'Export as PDF',
          className: 'btn btn-sm btn-outline-secondary me-1'
        },
        {
          extend: 'print',
          text: '<i class="fas fa-print"></i>',
          titleAttr: 'Print table',
          className: 'btn btn-sm btn-outline-secondary'
        }
      ]
    });

    // Sidebar toggle functionality for responsive design
    \$('#sidebarToggle').on('click', function() {
      \$('#sidebar').toggleClass('active');
      \$('#content').toggleClass('sidebar-active');
    });

    // Sidebar menu filter
    \$('#sidebarSearch').on('keyup', function() {
      var value = \$(this).val().toLowerCase();
      \$('.sidebar .nav-item:not(:first-child)').filter(function() {
        var matches = \$(this).text().toLowerCase().indexOf(value) > -1;
        \$(this).toggle(matches);
      });

      // Hide/show section headers based on if their items are visible
      \$('.sidebar .nav-header').each(function() {
        var header = \$(this);
        var hasVisibleItems = header.nextUntil('.nav-header').filter(':visible').length > 0;
        header.toggle(hasVisibleItems);
      });
    });

    // Global search functionality
    \$('#globalSearchBtn').on('click', function() {
      performGlobalSearch();
    });

    \$('#globalSearch').on('keypress', function(e) {
      if (e.which == 13) {
        performGlobalSearch();
      }
    });

    function performGlobalSearch() {
      var query = \$('#globalSearch').val().trim().toLowerCase();
      if (query.length < 2) return;

      \$('#searchResults').removeClass('d-none').html(
        '<div class="d-flex justify-content-center"><div class="spinner-border text-primary" role="status"><span class="visually-hidden">Searching...</span></div></div>'
      );

      // Load the search index and perform the search
      \$.ajax({
        url: 'search_index.json',
        dataType: 'json',
        success: function(data) {
          var results = [];
          var maxResults = 20; // Limit number of results to display

          // Filter the data based on the search query
          for (var i = 0; i < data.length; i++) {
            var item = data[i];
            if (item.title.toLowerCase().includes(query) ||
                item.content.toLowerCase().includes(query) ||
                item.category.toLowerCase().includes(query)) {
              results.push(item);
              if (results.length >= maxResults) break;
            }
          }

          // Display the results
          var resultsHtml = '';
          if (results.length > 0) {
            resultsHtml += '<div class="list-group">';
            for (var j = 0; j < results.length; j++) {
              var result = results[j];
              var icon = 'fa-file-alt';

              // Set appropriate icon based on file extension
              if (result.path.endsWith('.yaml.html') || result.path.endsWith('.yml.html')) {
                icon = 'fa-file-code';
              } else if (result.path.endsWith('.json.html')) {
                icon = 'fa-file-code';
              } else if (result.path.endsWith('.log.html')) {
                icon = 'fa-file-alt';
              } else if (result.path.endsWith('.err.html')) {
                icon = 'fa-exclamation-triangle';
              }

              resultsHtml += '<a href="' + result.path + '" class="list-group-item list-group-item-action">' +
                            '<i class="fas ' + icon + ' me-2"></i>' + result.title +
                            '<span class="badge bg-secondary float-end">' + result.category + '</span></a>';
            }
            resultsHtml += '</div>';
          } else {
            resultsHtml = '<div class="alert alert-warning">No results found for "' + query + '"</div>';
          }

          \$('#searchResults').html(resultsHtml);
        },
        error: function() {
          \$('#searchResults').html('<div class="alert alert-danger">Error loading search index. Please try again.</div>');
        }
      });
    }

    // Add clipboard copy functionality to code blocks
    \$('pre code').each(function() {
      var codeBlock = \$(this);
      var pre = codeBlock.parent();

      // Only add if not already added
      if (pre.parent('.code-toolbar').length === 0) {
        var toolbar = \$('<div class="code-header"><span>' + (pre.data('filename') || 'Code') + '</span><button class="btn btn-sm btn-dark copy-button"><i class="fas fa-copy"></i></button></div>');
        pre.before(toolbar);

        toolbar.find('.copy-button').on('click', function() {
          var text = codeBlock.text();
          navigator.clipboard.writeText(text).then(function() {
            var button = \$(this);
            button.html('<i class="fas fa-check"></i>');
            setTimeout(function() {
              button.html('<i class="fas fa-copy"></i>');
            }, 2000);
          }.bind(this));
        });
      }
    });
  });
</script>
</body>
</html>
EOF
}

# Function to generate the dashboard index.html
generate_dashboard_index() {
    log "[HTML] Generating dashboard index.html..."
    
    # Create the dashboard index.html file
    generate_dashboard_html > "${OUTPUT_DIR}/index.html"
    
    # Copy the dashboard_widgets.js file to the output directory
    if [ -f "dashboard_widgets.js" ]; then
        cp "dashboard_widgets.js" "${OUTPUT_DIR}/"
        log "  [INFO] Copied dashboard_widgets.js to output directory"
    else
        log "  [WARN] dashboard_widgets.js not found, dashboard widgets will not function"
    fi
    
    log "[DONE] Dashboard index.html generated."
}

# Instructions for using these functions:
# 1. Copy this file to your OpenShift Collector directory
# 2. Source this file in your main script or in fix_html_files.sh:
#    source ./dashboard_template.sh
# 3. Call generate_dashboard_index after generating all other HTML files
