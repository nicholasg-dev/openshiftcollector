#!/usr/bin/env bash

# Ensure the script is run with Bash
if [ -z "$BASH_VERSION" ]; then
  exec bash "$0" "$@"
fi

# Ensure Bash version is at least 4.0 for associative arrays
if ((BASH_VERSINFO[0] < 4)); then
  # Attempt to find and switch to Bash 4+ installed via Homebrew
  for brew_bash in /usr/local/bin/bash /opt/homebrew/bin/bash; do
    if [ -x "$brew_bash" ]; then
      ver=$("$brew_bash" -c "echo \\${BASH_VERSINFO[0]}")
      if ((ver >= 4)); then
        exec "$brew_bash" "$0" "$@"
      fi
    fi
  done
  echo "This script requires Bash 4.0 or newer (associative arrays are not supported in Bash 3.x)."
  exit 1
fi

# OpenShift Cluster Collector Script
# Collects configuration & settings, then generates a comprehensive HTML report.
# Usage: [env OUTPUT_DIR=...] [env LOG_LINES=...] [env PARALLEL_JOBS=...] ./openshiftcollector.sh
#
# Note: This script generates a report with proper relative links to ensure all resources
# can be accessed correctly when viewed locally or via a web server.

# --- Configurable variables ---
OUTPUT_DIR="${OUTPUT_DIR:-ocp_cluster_report_$(date +%Y%m%d_%H%M%S)}"
COLLECT_LOGS=${COLLECT_LOGS:-true}
LOG_LINES=${LOG_LINES:-200}
PARALLEL_JOBS=${PARALLEL_JOBS:-4}
MAX_LOG_LINES=${MAX_LOG_LINES:-1000}

# --- HTML Structure Configuration ---
# Define categories for HTML sidebar navigation and organization
# Key: Internal category ID used for directory names and linking
# Value: Display Name for the sidebar
declare -A CATEGORIES=(
    ["dashboard"]="Dashboard" # Special case for the main index
    ["basic"]="Basic Info"
    ["clusterversion_history"]="Version History"
    ["nodes"]="Nodes"
    ["operators"]="Operators"
    ["etcd"]="etcd"
    ["api_resources"]="API Resources"
    ["namespaces"]="Namespaces"
    ["namespace_resources"]="Namespace Details"
    ["cluster_resources"]="Cluster Resources"
    ["crd_instances"]="CRD Instances"
    ["builds"]="Builds & Images"
    ["network"]="Networking"
    ["storage"]="Storage"
    ["machine_api"]="Machine API"
    ["security"]="Security"
    ["rbac"]="RBAC"
    ["metrics"]="Metrics"
    ["autoscalers"]="Autoscalers"
    ["events"]="Events"
    ["logs"]="Logs"
    ["audit"]="Audit Config"
)

# Files suitable for DataTables rendering
# Key: Basename of the source file (relative to category dir)
# Value: "LinkColumnIndex,DetailFileSuffix"
#   - LinkColumnIndex: 1-based index of the column whose value is used for linking. 0 or empty means no link.
#   - DetailFileSuffix: Suffix to append to the linked value to form the detail file name (e.g., _describe.txt). Empty means link to a directory/page named after the value.
declare -A DATATABLE_FILES=(
    # Nodes
    ["nodes_wide.txt"]="1,_describe.txt.html" # Column 1 (NAME) links to {NAME}_describe.txt.html
    # Operators
    ["clusteroperators.txt"]="1,_describe.txt.html" # Column 1 (NAME) links to {NAME}_describe.txt.html (Note: describe CO not collected by default)
    ["olm/subscriptions.txt"]="2," # Column 2 (NAME), no specific detail file, link to default view maybe? (Needs refinement if specific detail exists)
    ["olm/install_plans.txt"]="2,"
    ["olm/catalogsources.txt"]="2,"
    # Namespaces
    ["projects.txt"]="1,../namespace_resources/%s/index.html" # Column 1 (NAME) links to namespace detail index page
    # Network
    ["netnamespaces.txt"]="1," # Needs detail page definition if applicable
    ["hostsubnets.txt"]="1," # Needs detail page definition if applicable
    # Metrics
    ["node_usage.txt"]="1," # Link to node detail? Maybe nodes_index.html#node-<name>
    ["pod_usage.txt"]="2," # Link to pod detail? Complex.
    # Logs
    ["high_restart_pods.txt"]="2," # Link to pod log?
    # Security
    ["cert_expiry.txt"]="2," # Link to secret details? Maybe security_index.html#secret-<ns>-<name>
)
export DATATABLE_FILES

set -uo pipefail
# Consider adding 'set -e' after initial debugging

# --- Logging and progress functions ---
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Track progress for display
TOTAL_STEPS=15
CURRENT_STEP=0

show_progress() {
    local step_name="$1"
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local percent=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local bar_length=50
    local filled_length=$((bar_length * CURRENT_STEP / TOTAL_STEPS))

    # Create the progress bar
    local bar=""
    for ((i=0; i<filled_length; i++)); do
        bar="${bar}#"
    done
    for ((i=filled_length; i<bar_length; i++)); do
        bar="${bar}-"
    done

    # Print the progress bar
    printf "\r[%3d%%] [%s] %s" "$percent" "$bar" "$step_name"

    # Print a newline if we're done
    if [ "$CURRENT_STEP" -eq "$TOTAL_STEPS" ]; then
        echo ""
    fi
}

# --- Dependency checks ---
for bin in oc xargs awk grep sort head cut base64 openssl jq tree mktemp find sed dirname basename; do
    if ! command -v "$bin" &>/dev/null; then
        echo "Error: '$bin' command not found. Please install it."
        exit 1
    fi
done

if ! oc whoami &>/dev/null; then
    echo "Error: Not logged in to OpenShift cluster."
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
log "Collecting OpenShift cluster details to ${OUTPUT_DIR}"

# --- Helper to run oc commands with retry logic ---
run_oc() {
    local outfile="$1"
    local errfile="$2"
    local optional_resource=${3:-false} # Pass true as 3rd arg if resource might not exist
    shift 3 # Shift past outfile, errfile, optional_flag
    local cmd_display="oc $*"
    local max_retries=3
    local retry_count=0
    local retry_delay=2

    log "  [CMD] Running: $cmd_display"

    # Ensure target directory exists
    mkdir -p "$(dirname "$outfile")"

    # Retry loop for transient errors
    while [ $retry_count -lt $max_retries ]; do
        if oc "$@" > "$outfile" 2> "$errfile"; then
            log "    [SUCCESS] Command succeeded: $cmd_display"
            # Remove error file only if it's empty
            [ -s "$errfile" ] || rm -f "$errfile"
            return 0
        else
            local rc=$?
            # Check if this is a "not found" for an optional resource
            if [[ "$optional_resource" == true ]] && grep -qE "(NotFound|doesn't have a resource type|the server could not find the requested resource)" "$errfile"; then
                log "    [INFO] Optional resource not found (rc=$rc): $cmd_display"
                echo "Resource not found or API not present." > "$outfile" # Overwrite outfile with info
                # Keep the error file for reference if it contains more than just the 'not found' message
                if ! grep -qE '^[[:space:]]*(NotFound|doesn'"'"'t have a resource type|the server could not find the requested resource)[[:space:]]*$' "$errfile"; then
                     log "    [INFO] Keeping non-empty error file: $errfile"
                else
                    rm -f "$errfile" # Remove simple 'not found' error file
                fi
                return 0
            fi

            # Check for transient errors that we should retry
            if grep -qE "(connection refused|timeout|TLS handshake|temporarily unavailable|too many requests)" "$errfile"; then
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    local wait_time=$((retry_delay * retry_count))
                    log "    [RETRY] Command failed with transient error (rc=$rc), retrying in ${wait_time}s (attempt $retry_count/$max_retries): $cmd_display"
                    sleep $wait_time
                    continue
                fi
            fi

            # If we get here, it's a non-retryable error or we've exhausted retries
            log "    [ERROR] Command failed (rc=$rc): $cmd_display"
            # Prepend error message to the output file instead of replacing it entirely
            local tmp_out; tmp_out=$(mktemp)
            {
                echo "[ERROR] Command failed (rc=$rc): $cmd_display"
                echo "--- Error Output (stderr) ---"
                cat "$errfile"
                echo "--- End Error Output ---"
                echo "--- Original Output (stdout, if any) ---"
                cat "$outfile" # Append original stdout if any exists
            } > "$tmp_out"
            mv "$tmp_out" "$outfile"
            # Don't remove the error file in case of failure
            break
        fi
    done

    # We only get here if all retries failed or it was a non-retryable error
    if [ $retry_count -ge 1 ]; then
        log "    [WARN] Command failed after $retry_count retries: $cmd_display"
    fi

    # Ensure the function always returns success for the script flow
    return 0
}

# Base collection functions
collect_basic() {
    log "[PROGRESS] Collecting basic cluster info..."
    run_oc "${OUTPUT_DIR}/oc_version.txt" "${OUTPUT_DIR}/oc_version.err" false version
    run_oc "${OUTPUT_DIR}/clusterversion.yaml" "${OUTPUT_DIR}/clusterversion.err" false get clusterversion -o yaml
    run_oc "${OUTPUT_DIR}/clusterversion_describe.txt" "${OUTPUT_DIR}/clusterversion_describe.err" false describe clusterversion
    run_oc "${OUTPUT_DIR}/cluster_info.txt" "${OUTPUT_DIR}/cluster_info.err" false cluster-info
    run_oc "${OUTPUT_DIR}/infrastructure.yaml" "${OUTPUT_DIR}/infrastructure.err" false get infrastructure cluster -o yaml
    log "[DONE] Basic cluster info collected."
}

collect_nodes() {
    log "[PROGRESS] Collecting node details..."
    mkdir -p "${OUTPUT_DIR}/nodes"
    run_oc "${OUTPUT_DIR}/nodes/nodes_wide.txt" "${OUTPUT_DIR}/nodes/nodes_wide.err" false get nodes -o wide
    local NODES
    NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
    for node in $NODES; do
        log "  [NODE] Collecting details for $node..."
        run_oc "${OUTPUT_DIR}/nodes/${node}_describe.txt" "${OUTPUT_DIR}/nodes/${node}_describe.err" false describe node "$node" &
        if (( $(jobs -r -p | wc -l) >= PARALLEL_JOBS )); then wait; fi
    done
    wait
    log "[DONE] Node details collected."
}

collect_operators() {
    log "[PROGRESS] Collecting operator details..."
    mkdir -p "${OUTPUT_DIR}/operators"
    run_oc "${OUTPUT_DIR}/operators/clusteroperators.txt" "${OUTPUT_DIR}/operators/clusteroperators.err" false get clusteroperators -o wide
    run_oc "${OUTPUT_DIR}/operators/cluster_service_versions.txt" "${OUTPUT_DIR}/operators/cluster_service_versions.err" false get csv --all-namespaces -o wide
    mkdir -p "${OUTPUT_DIR}/operators/olm"
    run_oc "${OUTPUT_DIR}/operators/olm/subscriptions.txt" "${OUTPUT_DIR}/operators/olm/subscriptions.err" false get subscriptions --all-namespaces -o wide
    run_oc "${OUTPUT_DIR}/operators/olm/install_plans.txt" "${OUTPUT_DIR}/operators/olm/install_plans.err" false get installplans --all-namespaces -o wide
    run_oc "${OUTPUT_DIR}/operators/olm/catalogsources.txt" "${OUTPUT_DIR}/operators/olm/catalogsources.err" false get catalogsources --all-namespaces -o wide
    log "[DONE] Operator details collected."
}

collect_network() {
    log "[PROGRESS] Collecting network configuration..."
    mkdir -p "${OUTPUT_DIR}/network"
    run_oc "${OUTPUT_DIR}/network/network_config.yaml" "${OUTPUT_DIR}/network/network_config.err" false get network.config/cluster -o yaml
    if run_oc "${OUTPUT_DIR}/network/netnamespace.txt" "${OUTPUT_DIR}/network/netnamespace.err" true api-resources | grep -q netnamespace; then
        run_oc "${OUTPUT_DIR}/network/netnamespaces.txt" "${OUTPUT_DIR}/network/netnamespaces.err" false get netnamespace -o wide
    fi
    if run_oc "${OUTPUT_DIR}/network/hostsubnet.txt" "${OUTPUT_DIR}/network/hostsubnet.err" true api-resources | grep -q hostsubnet; then
        run_oc "${OUTPUT_DIR}/network/hostsubnets.txt" "${OUTPUT_DIR}/network/hostsubnets.err" false get hostsubnet -o wide
    fi
    run_oc "${OUTPUT_DIR}/network/connectivity_check.txt" "${OUTPUT_DIR}/network/connectivity_check.err" true run connectivity-test --image=busybox --rm -i --restart=Never -- sh -c 'echo DNS Test:  && nslookup kubernetes.default && echo \nHTTP Connectivity: && wget -qO- http://google.com'
    if grep -q 'Error from server' "${OUTPUT_DIR}/network/connectivity_check.err"; then
      echo "WARNING: Could not run connectivity test pod. This may be due to cluster security policies or missing image permissions." >> "${OUTPUT_DIR}/network/connectivity_check.txt"
    fi
    log "[DONE] Network configuration collected."
}

collect_security() {
    log "[PROGRESS] Collecting security details..."
    mkdir -p "${OUTPUT_DIR}/security"
    run_oc "${OUTPUT_DIR}/security/secrets.txt" "${OUTPUT_DIR}/security/secrets.err" false get secrets --all-namespaces -o jsonpath='{range .items[?(@.type=="kubernetes.io/tls")]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' | \
      while read -r line; do
        local NS
        NS=$(echo "$line" | cut -d'|' -f1)
        local NAME
        NAME=$(echo "$line" | cut -d'|' -f2)
        local CRT_B64
        CRT_B64=$(oc get secret -n "$NS" "$NAME" -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
        if [[ -n "$CRT_B64" ]]; then
          echo "$CRT_B64" | base64 -d 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | \
            awk -v ns="$NS" -v name="$NAME" '{print ns,"|",name,"|",$0}' >> "${OUTPUT_DIR}/security/cert_expiry.txt"
        fi
      done
    run_oc "${OUTPUT_DIR}/security/scc.yaml" "${OUTPUT_DIR}/security/scc.err" false get scc -o yaml
    run_oc "${OUTPUT_DIR}/security/oauth_cluster.yaml" "${OUTPUT_DIR}/security/oauth_cluster.err" false get oauth cluster -o yaml
    log "[DONE] Security details collected."
}

collect_metrics() {
    log "[PROGRESS] Collecting metrics..."
    mkdir -p "${OUTPUT_DIR}/metrics"
    run_oc "${OUTPUT_DIR}/metrics/node_usage.txt" "${OUTPUT_DIR}/metrics/node_usage.err" false adm top nodes --no-headers
    run_oc "${OUTPUT_DIR}/metrics/pod_usage.txt" "${OUTPUT_DIR}/metrics/pod_usage.err" false adm top pods --all-namespaces --no-headers
    run_oc "${OUTPUT_DIR}/metrics/cluster_capacity.txt" "${OUTPUT_DIR}/metrics/cluster_capacity.err" false get nodes -o jsonpath='{range .items[*]}{.status.capacity}{\"\n\"}{end}'
    log "[DONE] Metrics collected."
}

collect_etcd() {
    log "[PROGRESS] Collecting etcd details..."
    mkdir -p "${OUTPUT_DIR}/etcd"

    # Get etcd pod name first
    local etcd_pod
    etcd_pod=$(oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$etcd_pod" ]]; then
        # Run etcd health check
        run_oc "${OUTPUT_DIR}/etcd/health.txt" "${OUTPUT_DIR}/etcd/health.err" false rsh -n openshift-etcd "$etcd_pod" etcdctl endpoint health 2>&1

        # Run etcd member list
        run_oc "${OUTPUT_DIR}/etcd/members.txt" "${OUTPUT_DIR}/etcd/members.err" false rsh -n openshift-etcd "$etcd_pod" etcdctl member list -w table 2>&1
    else
        echo "No etcd pods found" > "${OUTPUT_DIR}/etcd/pods.txt"
        log "  [WARN] No etcd pods found"
    fi

    log "[DONE] etcd details collected."
}

collect_logs() {
    log "[PROGRESS] Collecting logs..."
    if [ "$COLLECT_LOGS" = true ]; then
        mkdir -p "${OUTPUT_DIR}/logs"
        for NS in openshift-apiserver openshift-etcd openshift-kube-apiserver; do
            log "  [LOGS] Collecting logs for $NS..."
            mkdir -p "${OUTPUT_DIR}/logs/$NS"

            # Get pods in the namespace
            local pods
            pods=$(oc get pods -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

            if [[ -n "$pods" ]]; then
                for pod in $pods; do
                    log "    [POD] Getting logs from $pod..."
                    # Create a directory for each pod
                    mkdir -p "${OUTPUT_DIR}/logs/$NS/$pod"

                    # Get containers in the pod
                    local containers
                    containers=$(oc get pod "$pod" -n "$NS" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)

                    if [[ -n "$containers" ]]; then
                        for container in $containers; do
                            log "      [CONTAINER] Getting logs from $container..."
                            # Limit log size to avoid excessive file sizes
                            run_oc "${OUTPUT_DIR}/logs/$NS/$pod/${container}.log" "${OUTPUT_DIR}/logs/$NS/$pod/${container}.err" false logs "$pod" -n "$NS" -c "$container" --tail="$MAX_LOG_LINES"
                        done
                    else
                        echo "No containers found in pod $pod" > "${OUTPUT_DIR}/logs/$NS/$pod/no_containers.txt"
                    fi
                done
            else
                echo "No pods found in namespace $NS" > "${OUTPUT_DIR}/logs/$NS/no_pods.txt"
                log "    [WARN] No pods found in namespace $NS"
            fi
        done
    else
        log "  [SKIP] Log collection disabled"
    fi
    log "[DONE] Logs collected."
}

collect_namespaces() {
    log "[PROGRESS] Collecting namespaces and basic resources..."
    mkdir -p "${OUTPUT_DIR}/namespaces"
    run_oc "${OUTPUT_DIR}/namespaces/projects.txt" "${OUTPUT_DIR}/namespaces/projects.err" false get projects -o wide

    # Create a clean file with just the namespace names
    oc get namespaces -o name | sed 's|namespace/||' > "${OUTPUT_DIR}/namespaces/namespace_list.txt"

    # Loop through each namespace from the file
    while IFS= read -r NS; do
        log "  [NAMESPACE] Collecting for $NS..."
        mkdir -p "${OUTPUT_DIR}/namespaces/${NS}"

        (
            run_oc "${OUTPUT_DIR}/namespaces/${NS}/all_resources.txt" "${OUTPUT_DIR}/namespaces/${NS}/all_resources.err" false get all -n "${NS}" -o wide
            run_oc "${OUTPUT_DIR}/namespaces/${NS}/pods.yaml" "${OUTPUT_DIR}/namespaces/${NS}/pods.err" false get pods -n "${NS}" -o yaml
            run_oc "${OUTPUT_DIR}/namespaces/${NS}/deployments.yaml" "${OUTPUT_DIR}/namespaces/${NS}/deployments.err" false get deployments -n "${NS}" -o yaml
            run_oc "${OUTPUT_DIR}/namespaces/${NS}/configmaps.yaml" "${OUTPUT_DIR}/namespaces/${NS}/configmaps.err" false get configmap -n "${NS}" -o yaml
            run_oc "${OUTPUT_DIR}/namespaces/${NS}/secrets_redacted.yaml" "${OUTPUT_DIR}/namespaces/${NS}/secrets_redacted.err" false get secret -n "${NS}" -o yaml | grep -v 'data:'
        ) &
        if (( $(jobs -r -p | wc -l) >= PARALLEL_JOBS )); then wait; fi
    done < "${OUTPUT_DIR}/namespaces/namespace_list.txt"

    wait
    log "[DONE] Namespace collection complete."
}

collect_namespace_resources() {
    log "[PROGRESS] Collecting namespace-scoped resources..."
    mkdir -p "${OUTPUT_DIR}/namespace_resources"

    # Use the same clean namespace list we created in collect_namespaces
    if [[ -f "${OUTPUT_DIR}/namespaces/namespace_list.txt" ]]; then
        log "  [INFO] Using existing namespace list"
    else
        log "  [INFO] Creating namespace list"
        # Create it if it doesn't exist (in case this function is called directly)
        oc get namespaces -o name | sed 's|namespace/||' > "${OUTPUT_DIR}/namespaces/namespace_list.txt"
    fi

    # Loop through namespaces from the file
    while IFS= read -r NS; do
        if [[ -n "$NS" ]]; then
            log "  [NAMESPACE] Collecting resources for $NS..."
            mkdir -p "${OUTPUT_DIR}/namespace_resources/${NS}"

            (
                # Key namespace-scoped resources
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/resourcequotas.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/resourcequotas.err" false get resourcequotas -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/limitranges.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/limitranges.err" false get limitranges -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/pdb.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/pdb.err" false get pdb -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/networkpolicies.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/networkpolicies.err" false get networkpolicies -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/ingresses.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/ingresses.err" false get ingresses -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/routes.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/routes.err" false get routes -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/serviceaccounts.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/serviceaccounts.err" false get serviceaccounts -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/imagestreams.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/imagestreams.err" false get imagestreams -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/events.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/events.err" false get events -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/buildconfigs.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/buildconfigs.err" false get buildconfigs -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/builds.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/builds.err" false get builds -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/cronjobs.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/cronjobs.err" false get cronjobs -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/jobs.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/jobs.err" false get jobs -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/hpa.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/hpa.err" false get hpa -n "${NS}" -o yaml

                # Additional resources to collect
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/services.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/services.err" false get services -n "${NS}" -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/persistentvolumeclaims.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/persistentvolumeclaims.err" false get persistentvolumeclaims -n "${NS}" -o yaml
            ) &

            if (( $(jobs -r -p | wc -l) >= PARALLEL_JOBS )); then wait; fi
        else
            log "  [WARN] Skipping resource collection: empty namespace"
        fi
    done < "${OUTPUT_DIR}/namespaces/namespace_list.txt"

    wait
    log "[DONE] Namespace-scoped resource collection complete."
}

collect_cluster_resources() {
    log "[PROGRESS] Collecting cluster-wide resources..."
    mkdir -p "${OUTPUT_DIR}/cluster_resources"
    run_oc "${OUTPUT_DIR}/cluster_resources/clusterroles.yaml" "${OUTPUT_DIR}/cluster_resources/clusterroles.err" false get clusterroles -o yaml
    run_oc "${OUTPUT_DIR}/cluster_resources/clusterrolebindings.yaml" "${OUTPUT_DIR}/cluster_resources/clusterrolebindings.err" false get clusterrolebindings -o yaml
    run_oc "${OUTPUT_DIR}/cluster_resources/crds.yaml" "${OUTPUT_DIR}/cluster_resources/crds.err" false get crd -o yaml
    run_oc "${OUTPUT_DIR}/cluster_resources/apiservices.yaml" "${OUTPUT_DIR}/cluster_resources/apiservices.err" false get apiservices -o yaml
    run_oc "${OUTPUT_DIR}/cluster_resources/persistentvolumes.yaml" "${OUTPUT_DIR}/cluster_resources/persistentvolumes.err" false get pv -o yaml
    run_oc "${OUTPUT_DIR}/cluster_resources/storageclasses.yaml" "${OUTPUT_DIR}/cluster_resources/storageclasses.err" false get storageclass -o yaml
    run_oc "${OUTPUT_DIR}/cluster_resources/componentstatuses.yaml" "${OUTPUT_DIR}/cluster_resources/componentstatuses.err" false get componentstatuses -o yaml
    run_oc "${OUTPUT_DIR}/cluster_resources/machineconfigpools.yaml" "${OUTPUT_DIR}/cluster_resources/machineconfigpools.err" false get machineconfigpools -o yaml
    run_oc "${OUTPUT_DIR}/cluster_resources/imagepruner.yaml" "${OUTPUT_DIR}/cluster_resources/imagepruner.err" true get imagepruner -o yaml
    run_oc "${OUTPUT_DIR}/cluster_resources/clusterautoscaler.yaml" "${OUTPUT_DIR}/cluster_resources/clusterautoscaler.err" true get clusterautoscaler -o yaml
    run_oc "${OUTPUT_DIR}/cluster_resources/clusterversion.yaml" "${OUTPUT_DIR}/cluster_resources/clusterversion.err" false get clusterversion -o yaml
    log "[DONE] Cluster-wide resources collected."
}

# --- Dashboard Data Collection Enhancements ---
# Collect failed pods for dashboard summary
gather_failed_pods_summary() {
    log "[DASHBOARD] Collecting failed pods summary..."
    run_oc "${OUTPUT_DIR}/summary_failed_pods.txt" "${OUTPUT_DIR}/summary_failed_pods.err" false get pods --all-namespaces --field-selector=status.phase=Failed -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,REASON:.status.reason,AGE:.status.startTime'
}

# Collect recent events for dashboard summary
gather_recent_events() {
    log "[DASHBOARD] Collecting recent events..."
    if [ -f "${OUTPUT_DIR}/events/all_events.txt" ]; then
        tail -n 20 "${OUTPUT_DIR}/events/all_events.txt" > "${OUTPUT_DIR}/summary_recent_events.txt"
    fi
}

# Collect node readiness trend for dashboard summary
gather_node_readiness_trend() {
    log "[DASHBOARD] Collecting node readiness trend..."
    local now_ts
    now_ts=$(date +"%Y-%m-%d %H:%M:%S")
    if [ -f "${OUTPUT_DIR}/nodes/nodes_wide.txt" ]; then
        local total
        total=$(awk 'NR>1' "${OUTPUT_DIR}/nodes/nodes_wide.txt" | wc -l)
        local ready
        ready=$(awk 'NR>1 && $2=="Ready"' "${OUTPUT_DIR}/nodes/nodes_wide.txt" | wc -l)
        echo "$now_ts,$ready,$total" >> "${OUTPUT_DIR}/trend_node_readiness.csv"
    fi
}

# Update collect_dashboard_summaries to use the new helper functions
collect_dashboard_summaries() {
    log "[PROGRESS] Collecting dashboard summary data..."
    # 1. Cluster Name/ID
    run_oc "${OUTPUT_DIR}/cluster_name.txt" "${OUTPUT_DIR}/cluster_name.err" false get infrastructure cluster -o jsonpath='{.status.infrastructureName}'

    # 2. Top Warnings from Events
    run_oc "${OUTPUT_DIR}/events/all_events.txt" "${OUTPUT_DIR}/events/all_events.err" false get events --all-namespaces --sort-by=.lastTimestamp
    # Summarize top warning reasons
    awk '$5=="Warning" {print $6}' "${OUTPUT_DIR}/events/all_events.txt" | sort | uniq -c | sort -nr | head -10 > "${OUTPUT_DIR}/summary_top_warnings.txt"

    # 3. Failed Pods Summary
    gather_failed_pods_summary

    # 4. Recent Events (last 20)
    gather_recent_events

    # 5. Node Readiness Trend (append to CSV)
    gather_node_readiness_trend

    log "[DONE] Dashboard summary data collected."
}

# --- HTML Generation Functions (Bootstrap 5 + PrismJS) ---

# Helper to escape HTML characters
escape_html() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'
}

generate_html_header() {
    local title="$1"
    local current_page_id="$2" # e.g., "dashboard", "nodes_index", etc.
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title} - OpenShift Cluster Report</title>
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
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "dashboard" ]] && echo 'active')" href="index.html"><i class="fas fa-tachometer-alt fa-fw me-2"></i>Dashboard</a></li>
      <li class="nav-header">Cluster Core</li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "basic_index" ]] && echo 'active')" href="basic_index.html"><i class="fas fa-info-circle fa-fw me-2"></i>Basic Info</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "clusterversion_history_index" ]] && echo 'active')" href="clusterversion_history_index.html"><i class="fas fa-history fa-fw me-2"></i>Version History</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "nodes_index" ]] && echo 'active')" href="nodes_index.html"><i class="fas fa-server fa-fw me-2"></i>Nodes</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "operators_index" ]] && echo 'active')" href="operators_index.html"><i class="fas fa-cogs fa-fw me-2"></i>Operators</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "etcd_index" ]] && echo 'active')" href="etcd_index.html"><i class="fas fa-database fa-fw me-2"></i>etcd</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "api_resources_index" ]] && echo 'active')" href="api_resources_index.html"><i class="fas fa-stream fa-fw me-2"></i>API Resources</a></li>
      <li class="nav-header">Workloads & Config</li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "namespaces_index" ]] && echo 'active')" href="namespaces_index.html"><i class="fas fa-project-diagram fa-fw me-2"></i>Namespaces</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "namespace_resources_index" ]] && echo 'active')" href="namespace_resources_index.html"><i class="fas fa-boxes fa-fw me-2"></i>Namespace Details</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "cluster_resources_index" ]] && echo 'active')" href="cluster_resources_index.html"><i class="fas fa-globe fa-fw me-2"></i>Cluster Resources</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "crd_instances_index" ]] && echo 'active')" href="crd_instances_index.html"><i class="fas fa-puzzle-piece fa-fw me-2"></i>CRD Instances</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "builds_index" ]] && echo 'active')" href="builds_index.html"><i class="fas fa-images fa-fw me-2"></i>Builds & Images</a></li>
      <li class="nav-header">Infrastructure</li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "network_index" ]] && echo 'active')" href="network_index.html"><i class="fas fa-network-wired fa-fw me-2"></i>Networking</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "storage_index" ]] && echo 'active')" href="storage_index.html"><i class="fas fa-hdd fa-fw me-2"></i>Storage</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "machine_api_index" ]] && echo 'active')" href="machine_api_index.html"><i class="fas fa-robot fa-fw me-2"></i>Machine API</a></li>
      <li class="nav-header">Operations</li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "security_index" ]] && echo 'active')" href="security_index.html"><i class="fas fa-shield-alt fa-fw me-2"></i>Security</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "rbac_index" ]] && echo 'active')" href="rbac_index.html"><i class="fas fa-users-cog fa-fw me-2"></i>RBAC</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "metrics_index" ]] && echo 'active')" href="metrics_index.html"><i class="fas fa-chart-line fa-fw me-2"></i>Metrics</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "autoscalers_index" ]] && echo 'active')" href="autoscalers_index.html"><i class="fas fa-arrows-alt-h fa-fw me-2"></i>Autoscalers</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "events_index" ]] && echo 'active')" href="events_index.html"><i class="fas fa-bell fa-fw me-2"></i>Events</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "logs_index" ]] && echo 'active')" href="logs_index.html"><i class="fas fa-file-alt fa-fw me-2"></i>Logs</a></li>
      <li class="nav-item"><a class="nav-link $([[ "$current_page_id" == "audit_index" ]] && echo 'active')" href="audit_index.html"><i class="fas fa-user-secret fa-fw me-2"></i>Audit Config</a></li>
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
EOF
}

generate_html_footer() {
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
<script src="https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js"></script>
<script src="dashboard_widgets.js"></script>
<script src="embedded_search_index.js"></script>
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

      // Try to use the embedded search index first (to avoid CORS issues)
      if (typeof performEmbeddedSearch === 'function') {
        var results = performEmbeddedSearch(query);
        displaySearchResults(results, query);
      } else {
        // Fall back to AJAX if embedded search is not available
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

            displaySearchResults(results, query);
          },
          error: function() {
            \$('#searchResults').html('<div class="alert alert-danger">Error loading search index. Please try again.</div>');
          }
        });
      }

      // Function to display search results
      function displaySearchResults(results, query) {
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

            // Ensure path doesn't have duplicate directory references
            var cleanPath = result.path.replace(new RegExp(window.location.pathname.split('/').pop() + '/' + window.location.pathname.split('/').pop(), 'g'), window.location.pathname.split('/').pop());
            resultsHtml += '<a href="' + cleanPath + '" class="list-group-item list-group-item-action">' +
                          '<i class="fas ' + icon + ' me-2"></i>' + result.title +
                          '<span class="badge bg-secondary float-end">' + result.category + '</span></a>';
          }
          resultsHtml += '</div>';
        } else {
          resultsHtml = '<div class="alert alert-warning">No results found for "' + query + '"</div>';
        }

        \$('#searchResults').removeClass('d-none').html(resultsHtml);
      }
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

# Function to generate HTML for a text file
generate_file_html() {
    local source_file="$1"
    local html_file="${source_file}.html"
    local filename
    filename=$(basename "$source_file")
    local category
    category=$(dirname "$source_file" | sed "s|${OUTPUT_DIR}/||")

    # Skip if HTML file already exists
    if [ -f "$html_file" ]; then
        return
    fi

    # Determine the file type and language for syntax highlighting
    local ext
    ext="${filename##*.}"
    local lang="text"
    case "$ext" in
        yaml|yml) lang="yaml" ;;
        json) lang="json" ;;
        log) lang="log" ;;
        txt) lang="text" ;;
        err) lang="text" ;;
        *) lang="text" ;;
    esac

    log "  [HTML] Generating HTML for: $source_file"

    # Create HTML file
    generate_html_header "$(basename "$source_file")" "${category}_index" > "$html_file"

    # Add breadcrumb navigation
    # Calculate relative path to root based on directory depth
    local depth=$(echo "$category" | tr -cd '/' | wc -c)
    local rel_path=""
    for ((i=0; i<=depth; i++)); do
        rel_path="${rel_path}../"
    done

    cat >> "$html_file" << EOF
<nav aria-label="breadcrumb">
  <ol class="breadcrumb">
    <li class="breadcrumb-item"><a href="${rel_path}index.html">Dashboard</a></li>
    <li class="breadcrumb-item"><a href="${rel_path}${category}_index.html">${CATEGORIES[${category%%/*}]:-${category%%/*}}</a></li>
    <li class="breadcrumb-item active" aria-current="page">$(basename "$source_file")</li>
  </ol>
</nav>
<div class="card">
<div class="card-header card-header-accent">
<i class="fas fa-file-code me-2"></i>$(basename "$source_file")</div>
<div class="card-body">
<pre><code class="language-${lang}">
EOF

    # Add file content, escaping HTML characters
    { escape_html < "$source_file"; } >> "$html_file"

    # Close the HTML structure
    cat >> "$html_file" << EOF
</code></pre>
</div>
</div>
EOF

    # Add error file content if it exists
    local errfile="${source_file}.err"
    if [ -f "$errfile" ]; then
        cat >> "$html_file" << EOF
<div class="error-file mt-3">
<h5><i class="fas fa-exclamation-triangle me-2"></i>Error Output</h5>
<pre><code class="language-text">
EOF
        { escape_html < "$errfile"; } >> "$html_file"
        cat >> "$html_file" << EOF
</code></pre>
</div>
EOF
    fi

    # Add footer
    generate_html_footer >> "$html_file"
}

# Function to generate category index pages
generate_category_index() {
    local category="$1"
    local display_name="$2"
    local index_file="${OUTPUT_DIR}/${category}_index.html"
    local category_dir="${OUTPUT_DIR}/${category}"

    # Skip dashboard as it's handled separately
    if [ "$category" == "dashboard" ]; then
        return
    fi

    # Create HTML header
    generate_html_header "$display_name" "${category}_index" > "$index_file"

    # Add breadcrumb navigation
    cat >> "$index_file" << EOF
<nav aria-label="breadcrumb">
  <ol class="breadcrumb">
    <li class="breadcrumb-item"><a href="index.html">Dashboard</a></li>
    <li class="breadcrumb-item active" aria-current="page">$display_name</li>
  </ol>
</nav>
<div class="card">
<div class="card-header card-header-accent">
<i class="fas fa-folder-open me-2"></i>$display_name</div>
<div class="card-body">
<div class="list-group">
EOF

    # Add files in the category directory
    if [ -d "$category_dir" ]; then
        find "$category_dir" -type f -name "*.html" -o -name "*.yaml" -o -name "*.json" -o -name "*.log" -o -name "*.txt" | sort | while read -r file; do
            # Skip HTML files that were generated from other files
            if [[ "$file" == *.html && -f "${file%.html}" ]]; then
                continue
            fi

            local filename
            filename=$(basename "$file")
            local filesize
            filesize=$(du -h "$file" | cut -f1)
            local icon="fa-file-alt"

            # Set appropriate icon based on file extension
            if [[ "$filename" == *.yaml || "$filename" == *.yml ]]; then
                icon="fa-file-code"
            elif [[ "$filename" == *.json ]]; then
                icon="fa-file-code"
            elif [[ "$filename" == *.log ]]; then
                icon="fa-file-alt"
            elif [[ "$filename" == *.err ]]; then
                icon="fa-exclamation-triangle"
            fi

            # Add link to the file
            { echo "<a href=\"${file#\""${OUTPUT_DIR}"\/\"}\" class=\"list-group-item list-group-item-action\">"; echo "<i class=\"fas ${icon} me-2\"></i>$filename"; echo "<span class=\"badge bg-secondary float-end\">$filesize</span></a>"; } >> "$index_file"
        done
    else
        echo "<div class=\"alert alert-info\">No files found in this category.</div>" >> "$index_file"
    fi

    # Close the HTML structure
    cat >> "$index_file" << EOF
</div>
</div>
</div>
EOF

    # Add footer
    generate_html_footer >> "$index_file"
}

# Function to generate search index
generate_search_index() {
    local index_file="${OUTPUT_DIR}/search_index.json"

    # Also create an embedded version to avoid CORS issues
    local embedded_file="${OUTPUT_DIR}/embedded_search_index.js"

    # Start the JSON array
    echo "[" > "$index_file"

    # Start the embedded JS version
    echo "// Embedded search index to avoid CORS issues" > "$embedded_file"
    echo "var searchIndexData = [" >> "$embedded_file"

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

    # Also add to embedded JS file
    cat >> "$embedded_file" << EOF
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
            # Also add to embedded JS file
            cat >> "$embedded_file" << EOF
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
    find "${OUTPUT_DIR}" -type f -name "*.html" | sort | while read -r file; do
        # Skip index pages which we've already added
        if [[ "$(basename "$file")" == *_index.html || "$(basename "$file")" == "index.html" ]]; then
            continue
        fi

        local rel_path
        rel_path="${file#\""${OUTPUT_DIR}"\/\"}"
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
        # Also add to embedded JS file
        cat >> "$embedded_file" << EOF
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

    # Do the same for the embedded JS file
    mv "$embedded_file" "${embedded_file}.tmp"
    sed '$ s/,$//' "${embedded_file}.tmp" > "$embedded_file"
    rm "${embedded_file}.tmp"

    # Close the JSON array
    echo "]" >> "$index_file"

    # Close the JS array and add usage function
    echo "];" >> "$embedded_file"

    # Add a function to use the embedded data
    cat >> "$embedded_file" << 'EOF'

// Function to perform search using the embedded data
function performEmbeddedSearch(query) {
  if (query.length < 2) return [];

  query = query.toLowerCase();
  var results = [];
  var maxResults = 20; // Limit number of results

  // Filter the data based on the search query
  for (var i = 0; i < searchIndexData.length; i++) {
    var item = searchIndexData[i];
    if (item.title.toLowerCase().includes(query) ||
        item.content.toLowerCase().includes(query) ||
        item.category.toLowerCase().includes(query)) {
      results.push(item);
      if (results.length >= maxResults) break;
    }
  }

  return results;
}

// Replace the AJAX search with embedded search when the page loads
document.addEventListener('DOMContentLoaded', function() {
  // Override the search function to use embedded data instead of AJAX
  if (typeof $ !== 'undefined') {
    $('#globalSearchBtn').off('click').on('click', function() {
      var query = $('#globalSearch').val().trim();
      displaySearchResults(performEmbeddedSearch(query), query);
    });

    $('#globalSearch').off('keypress').on('keypress', function(e) {
      if (e.which == 13) {
        var query = $(this).val().trim();
        displaySearchResults(performEmbeddedSearch(query), query);
      }
    });
  }

  // Function to display search results
  function displaySearchResults(results, query) {
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

    $('#searchResults').removeClass('d-none').html(resultsHtml);
  }
});
EOF

    log "  [INFO] Search index generated: $index_file"
    log "  [INFO] Embedded search index generated: $embedded_file"
}

# Function to generate the dashboard HTML (index.html)
generate_dashboard_html() {
    local index_file="${OUTPUT_DIR}/index.html"
    log "  [HTML] Generating Dashboard: ${index_file}..."

    # Generate Header for Dashboard
    generate_html_header "Dashboard" "dashboard" > "$index_file"

    # --- Dashboard Content Start ---
    cat >> "$index_file" <<EOF
<div class="container-fluid">
  <h1 class="h3 mb-4 text-gray-800">OpenShift Cluster Report Dashboard</h1>

  <div class="row">
    <!-- Cluster Info Card -->
    <div class="col-xl-4 col-md-6 mb-4">
      <div class="card border-left-primary shadow h-100 py-2">
        <div class="card-body">
          <div class="row no-gutters align-items-center">
            <div class="col mr-2">
              <div class="text-xs font-weight-bold text-primary text-uppercase mb-1">
                Cluster Name</div>
              <div class="h5 mb-0 font-weight-bold text-gray-800">
                $(< "${OUTPUT_DIR}/cluster_name.txt" escape_html || echo "N/A")
              </div>
              <hr class="my-1">
              <div class="text-xs font-weight-bold text-primary text-uppercase mb-1">
                Version</div>
              <div class="h5 mb-0 font-weight-bold text-gray-800">
                $(oc version -o json | jq -r '.openshiftVersion // "N/A"' 2>/dev/null || echo "N/A")
              </div>
            </div>
            <div class="col-auto">
              <i class="fas fa-server fa-2x text-gray-300"></i>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Node Status Card -->
    <div class="col-xl-4 col-md-6 mb-4">
       <div class="card border-left-success shadow h-100 py-2">
        <div class="card-body">
            <div class="row no-gutters align-items-center">
            <div class="col mr-2">
                <div class="text-xs font-weight-bold text-success text-uppercase mb-1">Nodes Status</div>
EOF
    # Get Node Counts
    local total_nodes=0
    local ready_nodes=0
    if [[ -f "${OUTPUT_DIR}/nodes/nodes_wide.txt" ]]; then
        total_nodes=$(awk 'NR>1' "${OUTPUT_DIR}/nodes/nodes_wide.txt" | wc -l | xargs) # xargs to trim whitespace
        ready_nodes=$(awk 'NR>1 && $2=="Ready"' "${OUTPUT_DIR}/nodes/nodes_wide.txt" | wc -l | xargs)
    fi
    cat >> "$index_file" <<EOF
                <div class="h5 mb-0 font-weight-bold text-gray-800">${ready_nodes} / ${total_nodes} Ready</div>
                <a href="nodes_index.html" class="stretched-link"></a> <!-- Make card clickable -->
            </div>
            <div class="col-auto">
                <i class="fas fa-network-wired fa-2x text-gray-300"></i>
            </div>
            </div>
        </div>
       </div>
    </div>

    <!-- Operator Status Card -->
    <div class="col-xl-4 col-md-6 mb-4">
       <div class="card border-left-info shadow h-100 py-2">
        <div class="card-body">
            <div class="row no-gutters align-items-center">
            <div class="col mr-2">
                <div class="text-xs font-weight-bold text-info text-uppercase mb-1">Cluster Operators</div>
EOF
    # Get Operator Counts
    local total_ops=0
    local available_ops=0
    local progressing_ops=0
    local degraded_ops=0
     if [[ -f "${OUTPUT_DIR}/operators/clusteroperators.txt" ]]; then
        total_ops=$(awk 'NR>1' "${OUTPUT_DIR}/operators/clusteroperators.txt" | wc -l)
        available_ops=$(awk 'NR>1 && $3=="True"' "${OUTPUT_DIR}/operators/clusteroperators.txt" | wc -l)
        progressing_ops=$(awk 'NR>1 && $4=="True"' "${OUTPUT_DIR}/operators/clusteroperators.txt" | wc -l)
        degraded_ops=$(awk 'NR>1 && $5=="True"' "${OUTPUT_DIR}/operators/clusteroperators.txt" | wc -l)
    fi
    local op_status_color="success"
    [[ "$progressing_ops" -gt 0 ]] && op_status_color="warning"
    [[ "$degraded_ops" -gt 0 ]] && op_status_color="danger"

    cat >> "$index_file" <<EOF
                <div class="h5 mb-0 font-weight-bold text-gray-800">${available_ops} Available / ${total_ops} Total</div>
                <div>
                    <span class="badge bg-${op_status_color} me-1">${degraded_ops} Degraded</span>
                    <span class="badge bg-warning text-dark">${progressing_ops} Progressing</span>
                </div>
                <a href="operators_index.html" class="stretched-link"></a>
            </div>
            <div class="col-auto">
                <i class="fas fa-cogs fa-2x text-gray-300"></i>
            </div>
            </div>
        </div>
       </div>
    </div>

  </div> <!-- /.row -->

  <div class="row">
    <!-- Failed Pods Summary -->
    <div class="col-lg-6 mb-4">
        <div class="card shadow mb-4">
            <div class="card-header py-3">
                <h6 class="m-0 font-weight-bold text-danger"><i class="fas fa-exclamation-circle me-2"></i>Failed Pods Summary</h6>
            </div>
            <div class="card-body">
                <div class="table-responsive">
                    <table class="table table-sm table-striped table-hover small">
                        <thead><tr><th>Namespace</th><th>Name</th><th>Reason</th><th>Start Time</th></tr></thead>
                        <tbody>
EOF
    if [[ -s "${OUTPUT_DIR}/summary_failed_pods.txt" ]]; then
         # Skip header line (NR>1), limit to 10 entries (head), format into table rows
         { awk 'NR>1 {gsub(/</,"<"); gsub(/>/,">"); printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", $1,$2,$3,$4}' "${OUTPUT_DIR}/summary_failed_pods.txt" | head -n 10; } >> "$index_file"
    else
        echo '<tr><td colspan="4" class="text-center">No failed pods found.</td></tr>' >> "$index_file"
    fi
    cat >> "$index_file" <<EOF
                        </tbody>
                    </table>
                </div>
                <a href="logs_index.html">View Logs »</a>
            </div>
        </div>
    </div>

    <!-- Top Warning Events -->
    <div class="col-lg-6 mb-4">
        <div class="card shadow mb-4">
            <div class="card-header py-3">
                <h6 class="m-0 font-weight-bold text-warning"><i class="fas fa-bell me-2"></i>Top Warning Events (by Reason)</h6>
            </div>
            <div class="card-body">
                 <div class="table-responsive">
                    <table class="table table-sm table-striped small">
                        <thead><tr><th>Count</th><th>Reason</th></tr></thead>
                        <tbody>
EOF
    if [[ -s "${OUTPUT_DIR}/summary_top_warnings.txt" ]]; then
         # Format into table rows
         { awk '{gsub(/</,"<"); gsub(/>/,">"); printf "<tr><td>%s</td><td>%s</td></tr>\n", $1, $2}' "${OUTPUT_DIR}/summary_top_warnings.txt"; } >> "$index_file"
    else
        echo '<tr><td colspan="2" class="text-center">No warning events summary found.</td></tr>' >> "$index_file"
    fi
    cat >> "$index_file" <<EOF
                        </tbody>
                    </table>
                </div>
                <a href="events_index.html">View All Events »</a>
            </div>
        </div>
    </div>

  </div> <!-- /.row -->

  <div class="row">
    <!-- Recent Events -->
    <div class="col-lg-12 mb-4">
        <div class="card shadow mb-4">
            <div class="card-header py-3">
                <h6 class="m-0 font-weight-bold text-info"><i class="fas fa-history me-2"></i>Most Recent Events</h6>
            </div>
            <div class="card-body">
                <div class="table-responsive">
                 <table class="table table-sm table-striped table-hover small">
                    <thead><tr><th>Last Seen</th><th>Type</th><th>Reason</th><th>Object</th><th>Message</th></tr></thead>
                     <tbody>
EOF
    if [[ -s "${OUTPUT_DIR}/summary_recent_events.txt" ]]; then
         # Format into table rows (assuming standard 'oc get events' output format)
         # Note: This parsing might need adjustment based on exact 'oc get events' output columns
         { awk 'NR>1 {
                $1=$1; # Rebuild record to normalize spaces
                last_seen=$1" "$2;
                type=$3;
                reason=$4;
                object=$5;
                # Combine remaining fields for message
                message=""; for(i=6; i<=NF; i++) message = message $i " ";
                gsub(/</,"<", message); gsub(/>/,">", message); # Escape message
                printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", last_seen, type, reason, object, message;
             }' "${OUTPUT_DIR}/summary_recent_events.txt"; } >> "$index_file"
    else
        echo '<tr><td colspan="5" class="text-center">No recent events summary found.</td></tr>' >> "$index_file"
    fi
    cat >> "$index_file" <<EOF
                        </tbody>
                    </table>
                </div>
                 <a href="events_index.html">View All Events »</a>
            </div>
        </div>
     </div>
    </div> <!-- /.row -->

</div> <!-- /.container-fluid -->
EOF
    # --- Dashboard Content End ---

    # Generate Footer
    generate_html_footer >> "$index_file"

    # Add jq dependency check (used in this dashboard function)
    if ! command -v jq &>/dev/null; then
         log "[WARN] 'jq' command not found. Some dashboard elements might be missing data."
         # Optionally add a placeholder message to the HTML if jq is missing
         sed -i.bak '/jq -r/s/".*"/"N\/A (jq not found)"/' "$index_file" && rm -f "${index_file}.bak"
    fi

    log "  [HTML] Finished Dashboard: ${index_file}"
}

# Fix potential path issues in the report
fix_path_issues() {
    log "[PROGRESS] Fixing potential path issues in the report..."

    # Extract the directory name without path
    local dir_name=$(basename "${OUTPUT_DIR}")
    log "  [INFO] Report directory name: $dir_name"

    # Create a .htaccess file to handle directory browsing
    cat > "${OUTPUT_DIR}/.htaccess" << EOF
Options +Indexes
DirectoryIndex index.html
EOF

    # Fix any absolute paths in HTML files
    log "  [INFO] Fixing absolute paths in HTML files"
    find "${OUTPUT_DIR}" -type f -name "*.html" | while read -r html_file; do
        # 1. Fix duplicated directory references
        # This replaces patterns like: ocp_cluster_report_20250417_134502/ocp_cluster_report_20250417_134502/
        # with just: ocp_cluster_report_20250417_134502/
        sed -i.bak "s|${dir_name}/${dir_name}/|${dir_name}/|g" "$html_file"
        rm -f "${html_file}.bak"

        # 2. Remove the report directory name from links for HTTP server compatibility
        # This replaces patterns like: href="ocp_cluster_report_20250417_134502/
        # with just: href="
        sed -i.bak "s|href=\"${dir_name}/|href=\"|g" "$html_file"
        rm -f "${html_file}.bak"

        # 3. Fix links to raw text files (not HTML)
        # This replaces patterns like: href="file.txt"
        # with: href="file.txt.html"
        sed -i.bak "s|href=\"\([^\"]*\)\.\(txt\|yaml\|json\|log\|err\)\(\"|\)\(\s\)|href=\"\1.\2.html\3\4|g" "$html_file"
        rm -f "${html_file}.bak"
    done

    # Create a README file with instructions for viewing the report
    cat > "${OUTPUT_DIR}/README.txt" << EOF
OpenShift Cluster Report
======================

This report contains information collected from your OpenShift cluster.

To view the report:

1. Using the included web server (recommended):
   - Open a terminal in this directory
   - Run: ./serve_report.sh
   - Open your browser to: http://localhost:8000/

2. Using file:// URLs (some features may not work):
   - Open index.html directly in your browser

Note: Using the web server is recommended to avoid CORS issues and ensure all links work correctly.
EOF

    log "[DONE] Path issues fixed."
}

# Main function to run the collection and report generation
main() {
    # Create output directory
    mkdir -p "${OUTPUT_DIR}"
    log "Collecting OpenShift cluster details to ${OUTPUT_DIR}"

    # Collect data
    collect_basic
    collect_nodes
    collect_operators
    collect_network
    collect_security
    collect_metrics
    collect_etcd
    collect_logs
    collect_namespaces
    collect_namespace_resources
    collect_cluster_resources
    collect_dashboard_summaries

    # Generate HTML report
    log "[PROGRESS] Generating HTML report..."

    # Generate the dashboard (index.html) first
    generate_dashboard_html

    # Create HTML files for each category (except dashboard)
    for category in "${!CATEGORIES[@]}"; do
        # Skip dashboard as it's handled by generate_dashboard_html
        if [ "$category" != "dashboard" ]; then
            log "  [HTML] Generating ${category}_index.html..."
            generate_category_index "$category" "${CATEGORIES[$category]}"
        fi
    done

    # Generate HTML files for text files
    log "  [HTML] Generating HTML files for text files..."
    find "${OUTPUT_DIR}" -type f \( -name "*.yaml" -o -name "*.json" -o -name "*.log" -o -name "*.txt" -o -name "*.err" \) | while read -r file; do
        generate_file_html "$file"
    done

    # Generate search index
    log "  [HTML] Generating search index..."
    generate_search_index

    # Copy dashboard_widgets.js to the output directory if it exists
    if [ -f "dashboard_widgets.js" ]; then
        log "  [HTML] Copying dashboard_widgets.js to output directory..."
        cp "dashboard_widgets.js" "${OUTPUT_DIR}/"
    else
        log "  [WARN] dashboard_widgets.js not found, dashboard widgets will not function"
        # Create a minimal version to prevent errors
        cat > "${OUTPUT_DIR}/dashboard_widgets.js" << EOF
/**
 * Minimal dashboard widgets script to prevent errors
 */
document.addEventListener('DOMContentLoaded', function() {
    console.log('Dashboard widgets not available');
});
EOF
    fi

    # Create a simple HTML server script in the output directory
    log "  [HTML] Creating server script in output directory..."
    cat > "${OUTPUT_DIR}/serve_report.sh" << 'EOF'
#!/usr/bin/env bash

# Simple HTTP server for viewing the OpenShift Collector report
# This helps avoid CORS issues when viewing the report locally

PORT="${1:-8000}"

echo "Starting HTTP server on port $PORT..."
echo "Open your browser and navigate to: http://localhost:$PORT/"
echo "Press Ctrl+C to stop the server."

# Create a symbolic link to fix any remaining path issues
dir_name=$(basename "$(pwd)")
find . -type f -not -path "*/\.*" | while read -r file; do
    # Skip the serve_report.sh script itself
    if [[ "$file" == "./serve_report.sh" ]]; then
        continue
    fi

    # Create a symbolic link without the directory prefix
    target_file="${file#./}"
    if [[ "$target_file" == $dir_name/* ]]; then
        link_name="${target_file#$dir_name/}"
        if [[ ! -e "$link_name" && "$link_name" != "$target_file" ]]; then
            mkdir -p "$(dirname "$link_name")"
            ln -sf "$target_file" "$link_name"
        fi
    fi
done

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
EOF
    chmod +x "${OUTPUT_DIR}/serve_report.sh"

    # Fix potential path issues in the report
    log "  [HTML] Fixing potential path issues in the report..."
    fix_path_issues

    log "[DONE] HTML report generation complete."
    log "Report is available at: ${OUTPUT_DIR}/index.html"
    log "To avoid CORS issues, run: cd ${OUTPUT_DIR} && ./serve_report.sh"
}

# Call the main function
main
