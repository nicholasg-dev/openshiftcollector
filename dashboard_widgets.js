/**
 * OpenShift Cluster Report Dashboard Widgets
 * This script handles the dashboard widgets and charts for the OpenShift Cluster Report
 */

// Initialize dashboard widgets when the document is ready
document.addEventListener('DOMContentLoaded', function() {
    // Initialize all widgets
    initClusterStatusWidget();
    initNodeStatusWidget();
    initOperatorStatusWidget();
    initResourceUsageWidget();
    initNodeReadinessChart();
    initEventSummaryWidget();
    initFailedPodsWidget();
});

/**
 * Cluster Status Widget
 * Shows overall cluster health status
 */
function initClusterStatusWidget() {
    const widget = document.getElementById('clusterStatusWidget');
    if (!widget) return;

    // Try to load cluster version data
    fetch('clusterversion.yaml.html')
        .then(response => {
            if (!response.ok) {
                throw new Error('Failed to load cluster version data');
            }
            return response.text();
        })
        .then(html => {
            // Extract status from the HTML content
            const parser = new DOMParser();
            const doc = parser.parseFromString(html, 'text/html');
            const codeContent = doc.querySelector('code').textContent;
            
            // Simple check for cluster health based on available/progressing/degraded conditions
            let status = 'Unknown';
            let statusClass = 'bg-secondary';
            
            if (codeContent.includes('type: Available') && codeContent.includes('status: "True"')) {
                status = 'Healthy';
                statusClass = 'bg-success';
            } else if (codeContent.includes('type: Degraded') && codeContent.includes('status: "True"')) {
                status = 'Degraded';
                statusClass = 'bg-danger';
            } else if (codeContent.includes('type: Progressing') && codeContent.includes('status: "True"')) {
                status = 'Updating';
                statusClass = 'bg-warning';
            }
            
            // Extract version if available
            let version = 'Unknown';
            const versionMatch = codeContent.match(/desired:\s*\n\s*version:\s*([^\n]+)/);
            if (versionMatch && versionMatch[1]) {
                version = versionMatch[1].trim();
            }
            
            // Update widget content
            widget.querySelector('.status-value').textContent = status;
            widget.querySelector('.status-badge').className = `status-badge badge ${statusClass}`;
            widget.querySelector('.version-value').textContent = version;
        })
        .catch(error => {
            console.error('Error loading cluster status:', error);
            widget.querySelector('.card-body').innerHTML = `
                <div class="alert alert-warning">
                    <i class="fas fa-exclamation-triangle me-2"></i>
                    Could not load cluster status data
                </div>
            `;
        });
}

/**
 * Node Status Widget
 * Shows summary of node health
 */
function initNodeStatusWidget() {
    const widget = document.getElementById('nodeStatusWidget');
    if (!widget) return;

    // Try to load node data
    fetch('nodes/nodes_wide.txt.html')
        .then(response => {
            if (!response.ok) {
                throw new Error('Failed to load node data');
            }
            return response.text();
        })
        .then(html => {
            // Extract node status from the HTML content
            const parser = new DOMParser();
            const doc = parser.parseFromString(html, 'text/html');
            const codeContent = doc.querySelector('code').textContent;
            
            // Parse the node status table
            const lines = codeContent.split('\n').filter(line => line.trim().length > 0);
            
            // Skip header line
            const nodeLines = lines.slice(1);
            
            // Count nodes by status
            let readyCount = 0;
            let notReadyCount = 0;
            let totalNodes = nodeLines.length;
            
            nodeLines.forEach(line => {
                const columns = line.trim().split(/\s+/);
                if (columns.length > 1) {
                    const status = columns[1]; // Status is typically the second column
                    if (status === 'Ready') {
                        readyCount++;
                    } else {
                        notReadyCount++;
                    }
                }
            });
            
            // Update widget content
            widget.querySelector('.total-nodes').textContent = totalNodes;
            widget.querySelector('.ready-nodes').textContent = readyCount;
            widget.querySelector('.not-ready-nodes').textContent = notReadyCount;
            
            // Update status indicator
            const statusIndicator = widget.querySelector('.status-indicator');
            if (notReadyCount === 0) {
                statusIndicator.className = 'status-indicator status-good';
                widget.querySelector('.status-text').textContent = 'Healthy';
            } else if (notReadyCount < totalNodes / 2) {
                statusIndicator.className = 'status-indicator status-warning';
                widget.querySelector('.status-text').textContent = 'Warning';
            } else {
                statusIndicator.className = 'status-indicator status-error';
                widget.querySelector('.status-text').textContent = 'Critical';
            }
        })
        .catch(error => {
            console.error('Error loading node status:', error);
            widget.querySelector('.card-body').innerHTML = `
                <div class="alert alert-warning">
                    <i class="fas fa-exclamation-triangle me-2"></i>
                    Could not load node status data
                </div>
            `;
        });
}

/**
 * Operator Status Widget
 * Shows summary of operator health
 */
function initOperatorStatusWidget() {
    const widget = document.getElementById('operatorStatusWidget');
    if (!widget) return;

    // Try to load operator data
    fetch('operators/clusteroperators.txt.html')
        .then(response => {
            if (!response.ok) {
                throw new Error('Failed to load operator data');
            }
            return response.text();
        })
        .then(html => {
            // Extract operator status from the HTML content
            const parser = new DOMParser();
            const doc = parser.parseFromString(html, 'text/html');
            const codeContent = doc.querySelector('code').textContent;
            
            // Parse the operator status table
            const lines = codeContent.split('\n').filter(line => line.trim().length > 0);
            
            // Skip header line
            const operatorLines = lines.slice(1);
            
            // Count operators by status
            let availableCount = 0;
            let degradedCount = 0;
            let progressingCount = 0;
            let totalOperators = operatorLines.length;
            
            operatorLines.forEach(line => {
                const columns = line.trim().split(/\s+/);
                if (columns.length > 3) {
                    // Typically format is: NAME VERSION AVAILABLE PROGRESSING DEGRADED
                    const available = columns[2];
                    const progressing = columns[3];
                    const degraded = columns[4];
                    
                    if (available === 'True') availableCount++;
                    if (progressing === 'True') progressingCount++;
                    if (degraded === 'True') degradedCount++;
                }
            });
            
            // Update widget content
            widget.querySelector('.total-operators').textContent = totalOperators;
            widget.querySelector('.available-operators').textContent = availableCount;
            widget.querySelector('.degraded-operators').textContent = degradedCount;
            widget.querySelector('.progressing-operators').textContent = progressingCount;
            
            // Update status indicator
            const statusIndicator = widget.querySelector('.status-indicator');
            if (degradedCount > 0) {
                statusIndicator.className = 'status-indicator status-error';
                widget.querySelector('.status-text').textContent = 'Degraded';
            } else if (progressingCount > 0) {
                statusIndicator.className = 'status-indicator status-warning';
                widget.querySelector('.status-text').textContent = 'Updating';
            } else if (availableCount === totalOperators) {
                statusIndicator.className = 'status-indicator status-good';
                widget.querySelector('.status-text').textContent = 'Healthy';
            } else {
                statusIndicator.className = 'status-indicator status-unknown';
                widget.querySelector('.status-text').textContent = 'Unknown';
            }
        })
        .catch(error => {
            console.error('Error loading operator status:', error);
            widget.querySelector('.card-body').innerHTML = `
                <div class="alert alert-warning">
                    <i class="fas fa-exclamation-triangle me-2"></i>
                    Could not load operator status data
                </div>
            `;
        });
}

/**
 * Resource Usage Widget
 * Shows cluster resource usage
 */
function initResourceUsageWidget() {
    const widget = document.getElementById('resourceUsageWidget');
    if (!widget) return;

    // Try to load resource usage data
    fetch('metrics/node_usage.txt.html')
        .then(response => {
            if (!response.ok) {
                throw new Error('Failed to load resource usage data');
            }
            return response.text();
        })
        .then(html => {
            // Extract resource usage from the HTML content
            const parser = new DOMParser();
            const doc = parser.parseFromString(html, 'text/html');
            const codeContent = doc.querySelector('code').textContent;
            
            // Parse the resource usage table
            const lines = codeContent.split('\n').filter(line => line.trim().length > 0);
            
            // Calculate total and used resources
            let totalCPU = 0;
            let usedCPU = 0;
            let totalMemory = 0;
            let usedMemory = 0;
            
            lines.forEach(line => {
                const columns = line.trim().split(/\s+/);
                if (columns.length >= 5) {
                    // Format: NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%
                    const cpuCores = parseFloat(columns[1]);
                    const cpuPercent = parseFloat(columns[2]);
                    const memoryBytes = parseFloat(columns[3]);
                    const memoryPercent = parseFloat(columns[4]);
                    
                    if (!isNaN(cpuCores) && !isNaN(cpuPercent)) {
                        usedCPU += cpuCores;
                        totalCPU += (cpuCores / (cpuPercent / 100));
                    }
                    
                    if (!isNaN(memoryBytes) && !isNaN(memoryPercent)) {
                        usedMemory += memoryBytes;
                        totalMemory += (memoryBytes / (memoryPercent / 100));
                    }
                }
            });
            
            // Format values for display
            const formatCPU = (cores) => {
                return cores.toFixed(2) + ' cores';
            };
            
            const formatMemory = (bytes) => {
                const units = ['B', 'KB', 'MB', 'GB', 'TB'];
                let size = bytes;
                let unitIndex = 0;
                
                while (size >= 1024 && unitIndex < units.length - 1) {
                    size /= 1024;
                    unitIndex++;
                }
                
                return size.toFixed(2) + ' ' + units[unitIndex];
            };
            
            // Calculate percentages
            const cpuPercent = (usedCPU / totalCPU) * 100 || 0;
            const memoryPercent = (usedMemory / totalMemory) * 100 || 0;
            
            // Update widget content
            widget.querySelector('.cpu-usage').textContent = formatCPU(usedCPU) + ' / ' + formatCPU(totalCPU);
            widget.querySelector('.memory-usage').textContent = formatMemory(usedMemory) + ' / ' + formatMemory(totalMemory);
            
            // Update progress bars
            widget.querySelector('.cpu-progress').style.width = cpuPercent.toFixed(1) + '%';
            widget.querySelector('.cpu-progress').setAttribute('aria-valuenow', cpuPercent.toFixed(1));
            widget.querySelector('.cpu-percent').textContent = cpuPercent.toFixed(1) + '%';
            
            widget.querySelector('.memory-progress').style.width = memoryPercent.toFixed(1) + '%';
            widget.querySelector('.memory-progress').setAttribute('aria-valuenow', memoryPercent.toFixed(1));
            widget.querySelector('.memory-percent').textContent = memoryPercent.toFixed(1) + '%';
            
            // Set progress bar colors based on usage
            if (cpuPercent > 90) {
                widget.querySelector('.cpu-progress').classList.add('bg-danger');
            } else if (cpuPercent > 75) {
                widget.querySelector('.cpu-progress').classList.add('bg-warning');
            }
            
            if (memoryPercent > 90) {
                widget.querySelector('.memory-progress').classList.add('bg-danger');
            } else if (memoryPercent > 75) {
                widget.querySelector('.memory-progress').classList.add('bg-warning');
            }
        })
        .catch(error => {
            console.error('Error loading resource usage:', error);
            widget.querySelector('.card-body').innerHTML = `
                <div class="alert alert-warning">
                    <i class="fas fa-exclamation-triangle me-2"></i>
                    Could not load resource usage data
                </div>
            `;
        });
}

/**
 * Node Readiness Chart
 * Shows node readiness over time
 */
function initNodeReadinessChart() {
    const chartContainer = document.getElementById('nodeReadinessChart');
    if (!chartContainer) return;

    // Try to load node readiness trend data
    fetch('trend_node_readiness.csv')
        .then(response => {
            if (!response.ok) {
                throw new Error('Failed to load node readiness trend data');
            }
            return response.text();
        })
        .then(csv => {
            // Parse CSV data
            const lines = csv.split('\n').filter(line => line.trim().length > 0);
            const labels = [];
            const readyData = [];
            const totalData = [];
            
            lines.forEach(line => {
                const [timestamp, ready, total] = line.split(',');
                if (timestamp && ready && total) {
                    // Format timestamp for display
                    const date = new Date(timestamp);
                    const formattedTime = date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
                    
                    labels.push(formattedTime);
                    readyData.push(parseInt(ready, 10));
                    totalData.push(parseInt(total, 10));
                }
            });
            
            // Create chart
            const ctx = chartContainer.getContext('2d');
            new Chart(ctx, {
                type: 'line',
                data: {
                    labels: labels,
                    datasets: [
                        {
                            label: 'Ready Nodes',
                            data: readyData,
                            borderColor: '#4caf50',
                            backgroundColor: 'rgba(76, 175, 80, 0.1)',
                            borderWidth: 2,
                            fill: true,
                            tension: 0.1
                        },
                        {
                            label: 'Total Nodes',
                            data: totalData,
                            borderColor: '#3949ab',
                            backgroundColor: 'rgba(57, 73, 171, 0.1)',
                            borderWidth: 2,
                            borderDash: [5, 5],
                            fill: false,
                            tension: 0.1
                        }
                    ]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: {
                            position: 'top',
                        },
                        tooltip: {
                            mode: 'index',
                            intersect: false,
                        }
                    },
                    scales: {
                        y: {
                            beginAtZero: true,
                            ticks: {
                                precision: 0
                            }
                        }
                    }
                }
            });
        })
        .catch(error => {
            console.error('Error loading node readiness chart:', error);
            chartContainer.parentElement.innerHTML = `
                <div class="alert alert-warning">
                    <i class="fas fa-exclamation-triangle me-2"></i>
                    Could not load node readiness trend data
                </div>
            `;
        });
}

/**
 * Event Summary Widget
 * Shows recent cluster events
 */
function initEventSummaryWidget() {
    const widget = document.getElementById('eventSummaryWidget');
    if (!widget) return;

    // Try to load event summary data
    fetch('summary_recent_events.txt.html')
        .then(response => {
            if (!response.ok) {
                // Try alternative location
                return fetch('events/all_events.txt.html');
            }
            return response;
        })
        .then(response => {
            if (!response.ok) {
                throw new Error('Failed to load event data');
            }
            return response.text();
        })
        .then(html => {
            // Extract events from the HTML content
            const parser = new DOMParser();
            const doc = parser.parseFromString(html, 'text/html');
            const codeContent = doc.querySelector('code').textContent;
            
            // Parse the events
            const lines = codeContent.split('\n').filter(line => line.trim().length > 0);
            
            // Take the most recent events (up to 5)
            const recentEvents = lines.slice(-5);
            
            // Format events for display
            let eventsHtml = '';
            
            recentEvents.forEach(event => {
                const columns = event.trim().split(/\s+/);
                if (columns.length >= 5) {
                    const namespace = columns[0];
                    const name = columns[1];
                    const type = columns[4]; // Normal or Warning
                    const reason = columns[5];
                    const message = columns.slice(6).join(' ');
                    
                    const typeClass = type === 'Warning' ? 'text-warning' : 'text-success';
                    const icon = type === 'Warning' ? 'fa-exclamation-triangle' : 'fa-info-circle';
                    
                    eventsHtml += `
                        <div class="event-item mb-2 pb-2 border-bottom">
                            <div class="d-flex align-items-center">
                                <i class="fas ${icon} ${typeClass} me-2"></i>
                                <strong class="${typeClass}">${reason}</strong>
                                <small class="text-muted ms-auto">${namespace}</small>
                            </div>
                            <div class="small text-muted">${message}</div>
                        </div>
                    `;
                }
            });
            
            // Update widget content
            if (eventsHtml) {
                widget.querySelector('.card-body').innerHTML = eventsHtml;
            } else {
                widget.querySelector('.card-body').innerHTML = `
                    <div class="alert alert-info">
                        <i class="fas fa-info-circle me-2"></i>
                        No recent events found
                    </div>
                `;
            }
        })
        .catch(error => {
            console.error('Error loading event summary:', error);
            widget.querySelector('.card-body').innerHTML = `
                <div class="alert alert-warning">
                    <i class="fas fa-exclamation-triangle me-2"></i>
                    Could not load event data
                </div>
            `;
        });
}

/**
 * Failed Pods Widget
 * Shows summary of failed pods
 */
function initFailedPodsWidget() {
    const widget = document.getElementById('failedPodsWidget');
    if (!widget) return;

    // Try to load failed pods data
    fetch('summary_failed_pods.txt.html')
        .then(response => {
            if (!response.ok) {
                throw new Error('Failed to load failed pods data');
            }
            return response.text();
        })
        .then(html => {
            // Extract failed pods from the HTML content
            const parser = new DOMParser();
            const doc = parser.parseFromString(html, 'text/html');
            const codeContent = doc.querySelector('code').textContent;
            
            // Parse the failed pods
            const lines = codeContent.split('\n').filter(line => line.trim().length > 0);
            
            // Skip header line if present
            const podLines = lines.length > 0 && lines[0].includes('NAMESPACE') ? lines.slice(1) : lines;
            
            // Format pods for display
            let podsHtml = '';
            
            podLines.forEach(pod => {
                const columns = pod.trim().split(/\s+/);
                if (columns.length >= 3) {
                    const namespace = columns[0];
                    const name = columns[1];
                    const reason = columns[2];
                    
                    podsHtml += `
                        <div class="pod-item mb-2 pb-2 border-bottom">
                            <div class="d-flex align-items-center">
                                <i class="fas fa-exclamation-circle text-danger me-2"></i>
                                <strong>${name}</strong>
                                <span class="badge bg-secondary ms-2">${reason}</span>
                                <small class="text-muted ms-auto">${namespace}</small>
                            </div>
                        </div>
                    `;
                }
            });
            
            // Update widget content
            if (podsHtml) {
                widget.querySelector('.card-body').innerHTML = podsHtml;
            } else {
                widget.querySelector('.card-body').innerHTML = `
                    <div class="alert alert-success">
                        <i class="fas fa-check-circle me-2"></i>
                        No failed pods found
                    </div>
                `;
            }
        })
        .catch(error => {
            console.error('Error loading failed pods:', error);
            widget.querySelector('.card-body').innerHTML = `
                <div class="alert alert-warning">
                    <i class="fas fa-exclamation-triangle me-2"></i>
                    Could not load failed pods data
                </div>
            `;
        });
}
