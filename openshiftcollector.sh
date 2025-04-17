<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Cluster Dashboard - OpenShift Cluster Report</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
  <link href="https://cdn.datatables.net/1.13.7/css/dataTables.bootstrap5.min.css" rel="stylesheet">
  <link href="https://cdn.datatables.net/responsive/2.5.0/css/responsive.bootstrap5.min.css" rel="stylesheet">
  <link href="https://cdn.datatables.net/buttons/2.4.2/css/buttons.bootstrap5.min.css" rel="stylesheet">
  <link href="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/themes/prism-tomorrow.min.css" rel="stylesheet" />
  <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" rel="stylesheet">
  <style>
    :root {
      --primary-color: #3949ab;
      --secondary-color: #5c6bc0;
      --accent-color: #1a237e;
      --sidebar-bg: #1a237e;
      --sidebar-text: #e8eaf6;
      --light-bg: #f5f7ff;
      --card-shadow: 0 4px 6px rgba(0,0,0,0.1);
    }
    body { background: var(--light-bg); font-family: 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif; }
    .wrapper { display: flex; min-height: 100vh; }
    .sidebar {
      width: 280px;
      background: var(--sidebar-bg);
      color: var(--sidebar-text);
      padding: 1.5rem 1rem 1rem 1rem;
      position: fixed;
      height: 100vh;
      overflow-y: auto;
      transition: all 0.3s;
      z-index: 1000;
    }
    .sidebar-toggler {
      position: fixed;
      top: 10px;
      left: 10px;
      z-index: 1001;
      background: var(--sidebar-bg);
      color: white;
      border: none;
      border-radius: 4px;
      padding: 5px 10px;
      display: none;
    }
    .sidebar h4 { color: white; margin-bottom: 2rem; }
    .sidebar .nav-link { color: rgba(255,255,255,0.8); border-radius: 0.25rem; margin-bottom: 0.25rem; padding: 0.5rem 1rem; transition: all 0.2s; }
    .sidebar .nav-link.active, .sidebar .nav-link:hover { background: rgba(255,255,255,0.15); color: white; }
    .sidebar .nav-header { color: rgba(255,255,255,0.6); font-size: 0.85rem; text-transform: uppercase; margin-top: 1.5rem; margin-bottom: 0.5rem; font-weight: 600; letter-spacing: 0.5px; }
    .main-content { margin-left: 280px; padding: 2.5rem 2rem 2rem 2rem; transition: all 0.3s; width: calc(100% - 280px); }
    .card {
      box-shadow: var(--card-shadow);
      border-radius: .75rem;
      margin-bottom: 2rem;
      border: none;
      transition: transform 0.2s, box-shadow 0.2s;
    }
    .card:hover {
      transform: translateY(-3px);
      box-shadow: 0 6px 12px rgba(0,0,0,0.15);
    }
    .card-header {
      background: white;
      border-bottom: 1px solid rgba(0,0,0,0.05);
      font-weight: 600;
      font-size: 1.1rem;
      border-top-left-radius: .75rem !important;
      border-top-right-radius: .75rem !important;
      padding: 1rem 1.25rem;
    }
    .card-header-accent {
      border-left: 4px solid var(--primary-color);
    }
    .badge { font-size: 0.9em; font-weight: 500; padding: 0.5em 0.85em; }
    .badge-lg { font-size: 1em; padding: 0.6em 1em; }
    .category-section { margin-bottom: 2.5rem; }
    .table-responsive { margin-top: 1rem; }

    /* DataTables styling */
    table.dataTable {
      border-collapse: separate !important;
      border-spacing: 0;
      width: 100% !important;
    }
    .dataTables_wrapper .row:first-child {
      margin-bottom: 1rem;
      align-items: center;
    }
    .dataTables_filter {
      margin-bottom: 0.5rem;
    }
    .dataTables_filter input {
      border-radius: 4px;
      border: 1px solid #ced4da;
      padding: 0.375rem 0.75rem;
    }
    table.dataTable thead th {
      position: relative;
      background: #f1f3ff;
      font-weight: 600;
      padding: 12px 10px;
    }
    table.dataTable tbody tr.even {
      background-color: #f8f9ff;
    }
    table.dataTable tbody tr:hover {
      background-color: #eef0ff !important;
    }

    /* Breadcrumb and navigation */
    .breadcrumb {
      margin-bottom: 1.5rem;
      background: rgba(255,255,255,0.8);
      border-radius: 0.4rem;
      padding: 0.75rem 1.25rem;
      box-shadow: 0 1px 3px rgba(0,0,0,0.05);
    }

    /* Source code */
    pre, code[class*="language-"] { font-size: 0.95em; border-radius: 0.5rem; overflow: auto; }
    pre { background: #2d2d2d; color: #f8f8f2; padding: 1.25rem; margin-top: 1rem; box-shadow: var(--card-shadow); }
    .code-toolbar {
      position: relative;
    }
    .code-header {
      display: flex;
      justify-content: space-between;
      padding: 0.5rem 1rem;
      background: #1a1a1a;
      border-top-left-radius: 0.5rem;
      border-top-right-radius: 0.5rem;
      color: #eee;
      font-family: monospace;
      font-size: 0.8rem;
    }
    .code-header + pre {
      border-top-left-radius: 0;
      border-top-right-radius: 0;
      margin-top: 0;
    }

    /* Status indicators */
    .status-indicator {
      width: 12px;
      height: 12px;
      border-radius: 50%;
      display: inline-block;
      margin-right: 5px;
    }
    .status-good { background-color: #4caf50; }
    .status-warning { background-color: #ff9800; }
    .status-error { background-color: #f44336; }
    .status-unknown { background-color: #9e9e9e; }

    /* Error messages */
    .error-file {
      border: 1px solid #ffcdd2;
      background-color: #ffebee;
      color: #c62828;
      padding: 12px 16px;
      margin-top: 12px;
      border-radius: 6px;
    }

    /* Loading spinner */
    .spinner-border.text-primary { color: var(--primary-color) !important; }

    /* Search box */
    .global-search {
      position: sticky;
      top: 0;
      padding: 1rem;
      margin-bottom: 1.5rem;
      background: rgba(255,255,255,0.95);
      z-index: 100;
      border-radius: 0.5rem;
      box-shadow: 0 2px 8px rgba(0,0,0,0.1);
    }

    /* Resource detail section */
    .resource-detail {
      padding: 1rem;
      background: white;
      border-radius: 0.5rem;
      margin-bottom: 1.5rem;
      box-shadow: var(--card-shadow);
    }

    /* Responsive rules */
    @media (max-width: 991.98px) {
      .sidebar {
        margin-left: -280px;
      }
      .sidebar.active {
        margin-left: 0;
      }
      .main-content {
        margin-left: 0;
        width: 100%;
      }
      .sidebar-toggler {
        display: block;
      }
      .main-content.sidebar-active {
        margin-left: 280px;
        width: calc(100% - 280px);
      }
    }
  </style>
</head>
<body>
<button class="sidebar-toggler" id="sidebarToggle">
  <i class="fas fa-bars"></i>
</button>
<div class="wrapper">
  <nav class="sidebar" id="sidebar">
    <h4 class="mb-4"><i class="fas fa-cubes me-2"></i>OpenShift Report</h4>
    <div class="input-group mb-3">
      <input type="text" class="form-control form-control-sm" id="sidebarSearch" placeholder="Filter menu..." aria-label="Filter menu">
      <span class="input-group-text"><i class="fas fa-search"></i></span>
    </div>
    <ul class="nav flex-column">
      <li class="nav-item"><a class="nav-link active" href="index.html"><i class="fas fa-tachometer-alt fa-fw me-2"></i>Dashboard</a></li>
      <li class="nav-header">Cluster Core</li>
      <li class="nav-item"><a class="nav-link " href="basic_index.html"><i class="fas fa-info-circle fa-fw me-2"></i>Basic Info</a></li>
      <li class="nav-item"><a class="nav-link " href="clusterversion_history_index.html"><i class="fas fa-history fa-fw me-2"></i>Version History</a></li>
      <li class="nav-item"><a class="nav-link " href="nodes_index.html"><i class="fas fa-server fa-fw me-2"></i>Nodes</a></li>
      <li class="nav-item"><a class="nav-link " href="operators_index.html"><i class="fas fa-cogs fa-fw me-2"></i>Operators</a></li>
      <li class="nav-item"><a class="nav-link " href="etcd_index.html"><i class="fas fa-database fa-fw me-2"></i>etcd</a></li>
      <li class="nav-item"><a class="nav-link " href="api_resources_index.html"><i class="fas fa-stream fa-fw me-2"></i>API Resources</a></li>
      <li class="nav-header">Workloads & Config</li>
      <li class="nav-item"><a class="nav-link " href="namespaces_index.html"><i class="fas fa-project-diagram fa-fw me-2"></i>Namespaces</a></li>
      <li class="nav-item"><a class="nav-link " href="namespace_resources_index.html"><i class="fas fa-boxes fa-fw me-2"></i>Namespace Details</a></li>
      <li class="nav-item"><a class="nav-link " href="cluster_resources_index.html"><i class="fas fa-globe fa-fw me-2"></i>Cluster Resources</a></li>
      <li class="nav-item"><a class="nav-link " href="crd_instances_index.html"><i class="fas fa-puzzle-piece fa-fw me-2"></i>CRD Instances</a></li>
      <li class="nav-item"><a class="nav-link " href="builds_index.html"><i class="fas fa-images fa-fw me-2"></i>Builds & Images</a></li>
      <li class="nav-header">Infrastructure</li>
      <li class="nav-item"><a class="nav-link " href="network_index.html"><i class="fas fa-network-wired fa-fw me-2"></i>Networking</a></li>
      <li class="nav-item"><a class="nav-link " href="storage_index.html"><i class="fas fa-hdd fa-fw me-2"></i>Storage</a></li>
      <li class="nav-item"><a class="nav-link " href="machine_api_index.html"><i class="fas fa-robot fa-fw me-2"></i>Machine API</a></li>
      <li class="nav-header">Operations</li>
      <li class="nav-item"><a class="nav-link " href="security_index.html"><i class="fas fa-shield-alt fa-fw me-2"></i>Security</a></li>
      <li class="nav-item"><a class="nav-link " href="rbac_index.html"><i class="fas fa-users-cog fa-fw me-2"></i>RBAC</a></li>
      <li class="nav-item"><a class="nav-link " href="metrics_index.html"><i class="fas fa-chart-line fa-fw me-2"></i>Metrics</a></li>
      <li class="nav-item"><a class="nav-link " href="autoscalers_index.html"><i class="fas fa-arrows-alt-h fa-fw me-2"></i>Autoscalers</a></li>
      <li class="nav-item"><a class="nav-link " href="events_index.html"><i class="fas fa-bell fa-fw me-2"></i>Events</a></li>
      <li class="nav-item"><a class="nav-link " href="logs_index.html"><i class="fas fa-file-alt fa-fw me-2"></i>Logs</a></li>
      <li class="nav-item"><a class="nav-link " href="audit_index.html"><i class="fas fa-user-secret fa-fw me-2"></i>Audit Config</a></li>
    </ul>
  </nav>
  <main class="main-content" id="content">
    <div class="global-search mb-4">
      <div class="input-group">
        <span class="input-group-text bg-primary text-white"><i class="fas fa-search"></i></span>
        <input type="text" class="form-control" id="globalSearch" placeholder="Search across all resources and files..." aria-label="Global search">
        <button class="btn btn-primary" type="button" id="globalSearchBtn">Search</button>
      </div>
      <div id="searchResults" class="mt-2 d-none">
        <!-- Search results will appear here -->
      </div>
    </div>
<div class="row row-cols-1 row-cols-md-3 g-4 mb-4">
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
          <li><a href="nodes_table.html">Nodes</a></li>
          <li><a href="infrastructure.yaml.html">Cluster Infrastructure</a></li>
          <li><a href="machine_api_index.html">Machine API</a></li>
        </ul>
      </div>
      <div class="col-md-4 mb-3">
        <h6><i class="fas fa-shield-alt me-2 text-danger"></i>Security & Access</h6>
        <ul class="list-unstyled ms-3">
          <li><a href="rbac_index.html">RBAC Configuration</a></li>
          <li><a href="security_index.html">Security Context Constraints</a></li>
          <li><a href="security/oauth.yaml.html">Authentication</a></li>
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
<script>
  $(document).ready(function() {
    // Initialize DataTables with improved features
    var dataTable = $('table.datatable').DataTable({
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
    $('#sidebarToggle').on('click', function() {
      $('#sidebar').toggleClass('active');
      $('#content').toggleClass('sidebar-active');
    });

    // Sidebar menu filter
    $('#sidebarSearch').on('keyup', function() {
      var value = $(this).val().toLowerCase();
      $('.sidebar .nav-item:not(:first-child)').filter(function() {
        var matches = $(this).text().toLowerCase().indexOf(value) > -1;
        $(this).toggle(matches);
      });

      // Hide/show section headers based on if their items are visible
      $('.sidebar .nav-header').each(function() {
        var header = $(this);
        var hasVisibleItems = header.nextUntil('.nav-header').filter(':visible').length > 0;
        header.toggle(hasVisibleItems);
      });
    });

    // Global search functionality
    $('#globalSearchBtn').on('click', function() {
      performGlobalSearch();
    });

    $('#globalSearch').on('keypress', function(e) {
      if (e.which == 13) {
        performGlobalSearch();
      }
    });

    function performGlobalSearch() {
      var query = $('#globalSearch').val().trim().toLowerCase();
      if (query.length < 2) return;

      $('#searchResults').removeClass('d-none').html(
        '<div class="d-flex justify-content-center"><div class="spinner-border text-primary" role="status"><span class="visually-hidden">Searching...</span></div></div>'
      );

      // Load the search index and perform the search
      $.ajax({
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

          $('#searchResults').html(resultsHtml);
        },
        error: function() {
          $('#searchResults').html('<div class="alert alert-danger">Error loading search index. Please try again.</div>');
        }
      });
    }

    // Add clipboard copy functionality to code blocks
    $('pre code').each(function() {
      var codeBlock = $(this);
      var pre = codeBlock.parent();

      // Only add if not already added
      if (pre.parent('.code-toolbar').length === 0) {
        var toolbar = $('<div class="code-header"><span>' + (pre.data('filename') || 'Code') + '</span><button class="btn btn-sm btn-dark copy-button"><i class="fas fa-copy"></i></button></div>');
        pre.before(toolbar);

        toolbar.find('.copy-button').on('click', function() {
          var text = codeBlock.text();
          navigator.clipboard.writeText(text).then(function() {
            var button = $(this);
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
