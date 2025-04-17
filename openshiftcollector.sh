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
      ver=$("$brew_bash" -c 'echo ${BASH_VERSINFO[0]}')
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

set -uo pipefail
# Consider adding 'set -e' after initial debugging

# --- Logging function ---
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
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

# --- Helper to run oc commands ---
run_oc() {
    local outfile="$1"
    local errfile="$2"
    local optional_resource=${3:-false} # Pass true as 3rd arg if resource might not exist
    shift 3 # Shift past outfile, errfile, optional_flag
    local cmd_display="oc $*"
    log "  [CMD] Running: $cmd_display"

    # Ensure target directory exists
    mkdir -p "$(dirname "$outfile")"

    if oc "$@" > "$outfile" 2> "$errfile"; then
        log "    [SUCCESS] Command succeeded: $cmd_display"
        # Remove error file only if it's empty
        [ -s "$errfile" ] || rm -f "$errfile"
    else
        local rc=$?
        if [[ "$optional_resource" == true ]] && grep -qE "(NotFound|doesn't have a resource type|the server could not find the requested resource)" "$errfile"; then
            log "    [INFO] Optional resource not found (rc=$rc): $cmd_display"
            echo "Resource not found or API not present." > "$outfile" # Overwrite outfile with info
            # Keep the error file for reference if it contains more than just the 'not found' message
            if ! grep -qE '^[[:space:]]*(NotFound|doesn'\''t have a resource type|the server could not find the requested resource)[[:space:]]*$' "$errfile"; then
                 log "    [INFO] Keeping non-empty error file: $errfile"
            else
                rm -f "$errfile" # Remove simple 'not found' error file
            fi
        else
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
        fi
        # Ensure the function always returns success for the script flow unless we want it to exit
        return 0 # Make sure the script continues even if a command fails
    fi
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
        NS=$(echo "$line" | cut -d'|' -f1)
        NAME=$(echo "$line" | cut -d'|' -f2)
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
    local etcd_pod=$(oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$etcd_pod" ]]; then
        # Run etcd health check
        run_oc "${OUTPUT_DIR}/etcd/health.txt" "${OUTPUT_DIR}/etcd/health.err" false rsh -n openshift-etcd $etcd_pod etcdctl endpoint health 2>&1

        # Run etcd member list
        run_oc "${OUTPUT_DIR}/etcd/members.txt" "${OUTPUT_DIR}/etcd/members.err" false rsh -n openshift-etcd $etcd_pod etcdctl member list -w table 2>&1
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
            pods=$(oc get pods -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

            if [[ -n "$pods" ]]; then
                for pod in $pods; do
                    log "    [POD] Getting logs from $pod..."
                    # Create a directory for each pod
                    mkdir -p "${OUTPUT_DIR}/logs/$NS/$pod"

                    # Get containers in the pod
                    containers=$(oc get pod "$pod" -n "$NS" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)

                    if [[ -n "$containers" ]]; then
                        for container in $containers; do
                            log "      [CONTAINER] Getting logs from $container..."
                            # Limit log size to avoid excessive file sizes
                            run_oc "${OUTPUT_DIR}/logs/$NS/$pod/${container}.log" "${OUTPUT_DIR}/logs/$NS/$pod/${container}.err" false logs "$pod" -n "$NS" -c "$container" --tail=$MAX_LOG_LINES 2>&1
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
            run_oc "${OUTPUT_DIR}/namespaces/${NS}/all_resources.txt" "${OUTPUT_DIR}/namespaces/${NS}/all_resources.err" false get all -n ${NS} -o wide
            run_oc "${OUTPUT_DIR}/namespaces/${NS}/pods.yaml" "${OUTPUT_DIR}/namespaces/${NS}/pods.err" false get pods -n ${NS} -o yaml
            run_oc "${OUTPUT_DIR}/namespaces/${NS}/deployments.yaml" "${OUTPUT_DIR}/namespaces/${NS}/deployments.err" false get deployments -n ${NS} -o yaml
            run_oc "${OUTPUT_DIR}/namespaces/${NS}/configmaps.yaml" "${OUTPUT_DIR}/namespaces/${NS}/configmaps.err" false get configmap -n ${NS} -o yaml
            run_oc "${OUTPUT_DIR}/namespaces/${NS}/secrets_redacted.yaml" "${OUTPUT_DIR}/namespaces/${NS}/secrets_redacted.err" false get secret -n ${NS} -o yaml | grep -v 'data:'
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
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/resourcequotas.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/resourcequotas.err" false get resourcequotas -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/limitranges.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/limitranges.err" false get limitranges -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/pdb.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/pdb.err" false get pdb -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/networkpolicies.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/networkpolicies.err" false get networkpolicies -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/ingresses.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/ingresses.err" false get ingresses -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/routes.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/routes.err" false get routes -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/serviceaccounts.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/serviceaccounts.err" false get serviceaccounts -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/imagestreams.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/imagestreams.err" false get imagestreams -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/events.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/events.err" false get events -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/buildconfigs.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/buildconfigs.err" false get buildconfigs -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/builds.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/builds.err" false get builds -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/cronjobs.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/cronjobs.err" false get cronjobs -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/jobs.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/jobs.err" false get jobs -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/hpa.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/hpa.err" false get hpa -n ${NS} -o yaml

                # Additional resources to collect
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/services.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/services.err" false get services -n ${NS} -o yaml
                run_oc "${OUTPUT_DIR}/namespace_resources/${NS}/persistentvolumeclaims.yaml" "${OUTPUT_DIR}/namespace_resources/${NS}/persistentvolumeclaims.err" false get persistentvolumeclaims -n ${NS} -o yaml
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

# --- Additional Suggested Collection Functions ---
collect_audit_logs() {
    log "[PROGRESS] Collecting audit logs..."
    mkdir -p "${OUTPUT_DIR}/audit"
    run_oc "${OUTPUT_DIR}/audit/kube-apiserver-audit.log" "${OUTPUT_DIR}/audit/kube-apiserver-audit.err" false adm node-logs --role=master -u kube-apiserver
    log "[DONE] Audit logs collected."
}

collect_rbac() {
    log "[PROGRESS] Collecting RBAC resources..."
    mkdir -p "${OUTPUT_DIR}/rbac"
    run_oc "${OUTPUT_DIR}/rbac/users.yaml" "${OUTPUT_DIR}/rbac/users.err" false get users -o yaml
    run_oc "${OUTPUT_DIR}/rbac/groups.yaml" "${OUTPUT_DIR}/rbac/groups.err" false get groups -o yaml
    run_oc "${OUTPUT_DIR}/rbac/clusterroles.yaml" "${OUTPUT_DIR}/rbac/clusterroles.err" false get clusterroles -o yaml
    run_oc "${OUTPUT_DIR}/rbac/clusterrolebindings.yaml" "${OUTPUT_DIR}/rbac/clusterrolebindings.err" false get clusterrolebindings -o yaml
    run_oc "${OUTPUT_DIR}/rbac/roles.yaml" "${OUTPUT_DIR}/rbac/roles.err" false get roles --all-namespaces -o yaml
    run_oc "${OUTPUT_DIR}/rbac/rolebindings.yaml" "${OUTPUT_DIR}/rbac/rolebindings.err" false get rolebindings --all-namespaces -o yaml
    log "[DONE] RBAC resources collected."
}

collect_crd_instances() {
    log "[PROGRESS] Collecting CRD instances..."
    mkdir -p "${OUTPUT_DIR}/crd_instances"
    run_oc "${OUTPUT_DIR}/crd_instances/crds.txt" "${OUTPUT_DIR}/crd_instances/crds.err" false get crds -o name | while read -r crd; do
        crd_name=$(echo $crd | cut -d'/' -f2)
        log "  [CRD] Collecting $crd_name..."
        run_oc "${OUTPUT_DIR}/crd_instances/${crd_name}.yaml" "${OUTPUT_DIR}/crd_instances/${crd_name}.err" false get $crd -o yaml
    done
    log "[DONE] CRD instances collected."
}

collect_storage() {
    log "[PROGRESS] Collecting storage resources..."
    mkdir -p "${OUTPUT_DIR}/storage"
    run_oc "${OUTPUT_DIR}/storage/persistent_volumes.yaml" "${OUTPUT_DIR}/storage/persistent_volumes.err" false get pv -o yaml
    run_oc "${OUTPUT_DIR}/storage/persistent_volume_claims.yaml" "${OUTPUT_DIR}/storage/persistent_volume_claims.err" false get pvc --all-namespaces -o yaml
    run_oc "${OUTPUT_DIR}/storage/storage_classes.yaml" "${OUTPUT_DIR}/storage/storage_classes.err" false get storageclass -o yaml
    log "[DONE] Storage resources collected."
}

collect_events() {
    log "[PROGRESS] Collecting cluster events..."
    mkdir -p "${OUTPUT_DIR}/events"
    run_oc "${OUTPUT_DIR}/events/events.yaml" "${OUTPUT_DIR}/events/events.err" false get events --all-namespaces -o yaml
    log "[DONE] Cluster events collected."
}

collect_imagestreams_buildconfigs() {
    log "[PROGRESS] Collecting ImageStreams and BuildConfigs..."
    mkdir -p "${OUTPUT_DIR}/builds"
    run_oc "${OUTPUT_DIR}/builds/imagestreams.yaml" "${OUTPUT_DIR}/builds/imagestreams.err" false get imagestreams --all-namespaces -o yaml
    run_oc "${OUTPUT_DIR}/builds/buildconfigs.yaml" "${OUTPUT_DIR}/builds/buildconfigs.err" false get buildconfigs --all-namespaces -o yaml
    log "[DONE] ImageStreams and BuildConfigs collected."
}

collect_machine_api() {
    log "[PROGRESS] Collecting Machine API resources..."
    mkdir -p "${OUTPUT_DIR}/machine_api"
    run_oc "${OUTPUT_DIR}/machine_api/machinesets.yaml" "${OUTPUT_DIR}/machine_api/machinesets.err" false get machinesets -A -o yaml
    run_oc "${OUTPUT_DIR}/machine_api/machineconfigs.yaml" "${OUTPUT_DIR}/machine_api/machineconfigs.err" false get machineconfigs -A -o yaml
    log "[DONE] Machine API resources collected."
}

collect_api_resources() {
    log "[PROGRESS] Collecting API resources..."
    run_oc "${OUTPUT_DIR}/api_resources.txt" "${OUTPUT_DIR}/api_resources.err" false api-resources
    log "[DONE] API resources collected."
}

collect_autoscalers() {
    log "[PROGRESS] Collecting autoscalers..."
    mkdir -p "${OUTPUT_DIR}/autoscalers"
    run_oc "${OUTPUT_DIR}/autoscalers/clusterautoscaler.yaml" "${OUTPUT_DIR}/autoscalers/clusterautoscaler.err" true get clusterautoscaler -o yaml
    run_oc "${OUTPUT_DIR}/autoscalers/hpa.yaml" "${OUTPUT_DIR}/autoscalers/hpa.err" false get hpa --all-namespaces -o yaml
    run_oc "${OUTPUT_DIR}/autoscalers/vpa.yaml" "${OUTPUT_DIR}/autoscalers/vpa.err" true get vpa --all-namespaces -o yaml
    log "[DONE] Autoscalers collected."
}

collect_clusterversion_history() {
    log "[PROGRESS] Collecting cluster version history..."
    mkdir -p "${OUTPUT_DIR}/version"

    # First get the raw clusterversion data
    run_oc "${OUTPUT_DIR}/version/clusterversion.json" "${OUTPUT_DIR}/version/clusterversion.err" false get clusterversion -o json

    # Then process it with jq safely
    if [[ -s "${OUTPUT_DIR}/version/clusterversion.json" ]]; then
        # Extract just the history portion
        if command -v jq &>/dev/null; then
            jq '.items[0].status.history' "${OUTPUT_DIR}/version/clusterversion.json" > "${OUTPUT_DIR}/version/history.json" 2> "${OUTPUT_DIR}/version/jq.err"

            # If jq failed, log an error
            if [[ ! -s "${OUTPUT_DIR}/version/history.json" ]]; then
                log "  [ERROR] Failed to parse version history with jq"
                echo "JQ parsing error - see jq.err for details" > "${OUTPUT_DIR}/version/history.json"
            else
                # Create a more human-readable version
                jq -r '.[] | "Version: \(.version) - State: \(.state) - Started: \(.startedTime)"' "${OUTPUT_DIR}/version/history.json" > "${OUTPUT_DIR}/version/history.txt" 2>> "${OUTPUT_DIR}/version/jq.err"
            fi
        else
            log "  [WARN] jq not available, skipping version history parsing"
            echo "JQ not installed - install jq to parse version history" > "${OUTPUT_DIR}/version/history.json"
        fi
    else
        log "  [ERROR] Failed to get cluster version data"
    fi

    log "[DONE] Cluster version history collected."
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

# Generate a DataTable HTML page from a tabular file (space/tab delimited)
generate_datatable_page() {
    local title="$1"
    local data_file="$2"
    local output_html="$3"
    local category="$4"
    local link_config="${5:-}" # Format: "column_index,detail_suffix"

    local column_index=0
    local detail_suffix=""

    if [[ -n "$link_config" ]]; then
      column_index=$(echo "$link_config" | cut -d',' -f1)
      detail_suffix=$(echo "$link_config" | cut -d',' -f2)
    fi

    generate_html_header "$title" "${category}_index" > "$output_html"

    # Add breadcrumb navigation
    echo '<nav aria-label="breadcrumb">' >> "$output_html"
    echo '  <ol class="breadcrumb">' >> "$output_html"
    echo '    <li class="breadcrumb-item"><a href="index.html">Dashboard</a></li>' >> "$output_html"
    if [[ -n "$category" ]]; then
      echo '    <li class="breadcrumb-item"><a href="'"${category}_index.html"'">'${CATEGORIES[$category]}'</a></li>' >> "$output_html"
    fi
    echo '    <li class="breadcrumb-item active" aria-current="page">'$title'</li>' >> "$output_html"
    echo '  </ol>' >> "$output_html"
    echo '</nav>' >> "$output_html"

    echo '<div class="card">' >> "$output_html"
    echo '<div class="card-header card-header-accent">' >> "$output_html"
    echo '<i class="fas fa-table me-2"></i>'$title'</span>' >> "$output_html"
    echo '</div>' >> "$output_html"
    echo '<div class="card-body">' >> "$output_html"

    echo '<div class="table-responsive">' >> "$output_html"
    echo '<table class="table table-striped table-hover datatable" id="datatable-'$(echo "$title" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')'">' >> "$output_html"

    # Process the header
    local header_line=$(head -n 1 "$data_file")
    echo '<thead><tr>' >> "$output_html"
    local column=1
    for field in $header_line; do
      echo '<th>'$field'</th>' >> "$output_html"
      column=$((column + 1))
    done
    echo '</tr></thead><tbody>' >> "$output_html"

    # Process data rows
    tail -n +2 "$data_file" | while read -r line; do
      echo '<tr>' >> "$output_html"

      local col=1
      for field in $line; do
        if [[ "$col" -eq "$column_index" && -n "$detail_suffix" ]]; then
          local link_target
          if [[ "$detail_suffix" == "../"* ]]; then
            # This is a relative path format string
            # shellcheck disable=SC2059
            link_target=$(printf "$detail_suffix" "$field")
          else
            # This is a simple suffix
            link_target="${field}${detail_suffix}"
          fi
          echo '<td><a href="'$link_target'">'$field'</a></td>' >> "$output_html"
        else
          # Add status indicator based on certain known fields
          case "$field" in
            Running|True|Active|Ready|Successful|Succeeded)
              echo '<td><span class="status-indicator status-good"></span>'$field'</td>' >> "$output_html"
              ;;
            Error*|Failed|False|NotReady|CrashLoopBackOff|Terminating|InvalidImageName|DeadlineExceeded)
              echo '<td><span class="status-indicator status-error"></span>'$field'</td>' >> "$output_html"
              ;;
            Pending|Unknown|Warning|Provisioning|ContainerCreating|PodInitializing|SchedulingDisabled|Degraded)
              echo '<td><span class="status-indicator status-warning"></span>'$field'</td>' >> "$output_html"
              ;;
            *)
              echo '<td>'$field'</td>' >> "$output_html"
              ;;
          esac
        fi
        col=$((col + 1))
      done

      echo '</tr>' >> "$output_html"
    done

    echo '</tbody></table>' >> "$output_html"
    echo '</div>' >> "$output_html"
    echo '</div>' >> "$output_html"
    echo '</div>' >> "$output_html"

    generate_html_footer >> "$output_html"
}

# Enhanced detail page with syntax highlighting and better formatting
generate_detail_page() {
    local title="$1"
    local content_file="$2"
    local output_html="$3"
    local lang="${4:-text}"
    local category="${5:-}"

    generate_html_header "$title" "${category}_index" > "$output_html"

    # Add breadcrumb navigation
    echo '<nav aria-label="breadcrumb">' >> "$output_html"
    echo '  <ol class="breadcrumb">' >> "$output_html"
    echo '    <li class="breadcrumb-item"><a href="index.html">Dashboard</a></li>' >> "$output_html"
    if [[ -n "$category" ]]; then
      echo '    <li class="breadcrumb-item"><a href="'"${category}_index.html"'">'${CATEGORIES[$category]}'</a></li>' >> "$output_html"
    fi
    echo '    <li class="breadcrumb-item active" aria-current="page">'$title'</li>' >> "$output_html"
    echo '  </ol>' >> "$output_html"
    echo '</nav>' >> "$output_html"

    echo '<div class="card">' >> "$output_html"
    echo '<div class="card-header card-header-accent">' >> "$output_html"
    echo '<i class="fas fa-file-alt me-2"></i>'$title'' >> "$output_html"

    # If this is an error file, show an alert
    if [[ "$title" == *".err" || "$title" == *"error"* ]]; then
      echo '<span class="badge bg-danger ms-2">Error</span>' >> "$output_html"
    fi

    # Show metadata about the file
    local file_date=$(date -r "$content_file" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "N/A")
    local file_size=$(du -h "$content_file" | cut -f1 2>/dev/null || echo "N/A")
    echo '<div class="mt-2 text-muted small">Last modified: '$file_date' | Size: '$file_size'</div>' >> "$output_html"

    echo '</div>' >> "$output_html"
    echo '<div class="card-body p-0">' >> "$output_html"

    # Check if this is an error file
    if [[ "$title" == *".err" || "$title" == *"error"* ]]; then
      echo '<div class="alert alert-danger m-3">' >> "$output_html"
      echo '<i class="fas fa-exclamation-triangle me-2"></i>This file contains error output.' >> "$output_html"
      echo '</div>' >> "$output_html"
    fi

    # If it's a long file, add a message
    if [[ $(wc -l < "$content_file") -gt 1000 ]]; then
      echo '<div class="alert alert-info m-3">' >> "$output_html"
      echo '<i class="fas fa-info-circle me-2"></i>This is a large file with '$(wc -l < "$content_file")' lines.' >> "$output_html"
      echo '</div>' >> "$output_html"
    fi

    # File tools section
    echo '<div class="d-flex justify-content-end p-3">' >> "$output_html"
    echo '<button class="btn btn-sm btn-outline-primary me-2" id="copyBtn" title="Copy to clipboard"><i class="fas fa-copy me-1"></i>Copy</button>' >> "$output_html"
    echo '<a href="'$(basename "$content_file")'" class="btn btn-sm btn-outline-secondary" download title="Download raw file"><i class="fas fa-download me-1"></i>Download</a>' >> "$output_html"
    echo '</div>' >> "$output_html"

    # Display the code with proper syntax highlighting
    echo '<div class="code-header"><span>' >> "$output_html"
    echo $(basename "$content_file") >> "$output_html"
    echo '</span><button class="btn btn-sm btn-dark copy-button" title="Copy to clipboard"><i class="fas fa-copy"></i></button></div>' >> "$output_html"
    echo '<pre class="line-numbers" data-filename="'$(basename "$content_file")'"><code class="language-'$lang'">' >> "$output_html"
    cat "$content_file" | escape_html >> "$output_html"
    echo '</code></pre>' >> "$output_html"

    echo '</div>' >> "$output_html"
    echo '</div>' >> "$output_html"

    generate_html_footer >> "$output_html"
}

# Generate a category index page with links to all files in the category
generate_category_index() {
    local category_id="$1"
    local category_name="$2"
    local category_dir="$3"
    local output_html="$4"

    generate_html_header "$category_name" "${category_id}_index" > "$output_html"

    # Add breadcrumb navigation
    echo '<nav aria-label="breadcrumb">' >> "$output_html"
    echo '  <ol class="breadcrumb">' >> "$output_html"
    echo '    <li class="breadcrumb-item"><a href="index.html">Dashboard</a></li>' >> "$output_html"
    echo '    <li class="breadcrumb-item active" aria-current="page">'$category_name'</li>' >> "$output_html"
    echo '  </ol>' >> "$output_html"
    echo '</nav>' >> "$output_html"

    echo '<div class="card">' >> "$output_html"
    echo '<div class="card-header card-header-accent">' >> "$output_html"
    echo '<i class="fas fa-folder-open me-2"></i>'$category_name'</div>' >> "$output_html"
    echo '<div class="card-body">' >> "$output_html"

    echo '<div class="list-group">' >> "$output_html"

    # Find all files in the category directory
    if [[ -d "$category_dir" ]]; then
        find "$category_dir" -type f -not -name "*.html" | sort | while read -r file; do
            local filename=$(basename "$file")
            local file_path="${file#$OUTPUT_DIR/}"
            local file_icon="fa-file-alt"

            # Set appropriate icon based on file extension
            case "${filename##*.}" in
                yaml|yml) file_icon="fa-file-code" ;;
                json) file_icon="fa-file-code" ;;
                log) file_icon="fa-file-alt" ;;
                txt) file_icon="fa-file-alt" ;;
                err) file_icon="fa-exclamation-triangle" ;;
                *) file_icon="fa-file" ;;
            esac

            # Add file size
            local file_size=$(du -h "$file" | cut -f1 2>/dev/null || echo "N/A")

            echo '<a href="'$file_path'.html" class="list-group-item list-group-item-action">' >> "$output_html"
            echo '<i class="fas '$file_icon' me-2"></i>'$filename >> "$output_html"
            echo '<span class="badge bg-secondary float-end">'$file_size'</span>' >> "$output_html"
            echo '</a>' >> "$output_html"
        done
    else
        echo '<div class="alert alert-info">No files found in this category.</div>' >> "$output_html"
    fi

    echo '</div>' >> "$output_html"
    echo '</div>' >> "$output_html"
    echo '</div>' >> "$output_html"

    generate_html_footer >> "$output_html"
}

# Generate a search index for all files in the report
generate_search_index() {
    log "Generating search index..."
    local search_index="${OUTPUT_DIR}/search_index.json"

    # Create a temporary file for building the index
    local temp_index=$(mktemp)

    # Start the JSON array
    echo '[' > "$temp_index"

    # Find all text files and add them to the index
    local first_entry=true
    find "${OUTPUT_DIR}" -type f \( -name "*.yaml" -o -name "*.json" -o -name "*.log" -o -name "*.txt" \) | sort | while read -r file; do
        # Skip empty files
        if [[ ! -s "$file" ]]; then
            continue
        fi

        local filename=$(basename "$file")
        local file_path="${file#$OUTPUT_DIR/}"
        local category=$(dirname "$file" | sed "s|${OUTPUT_DIR}/||")
        local title="$filename"

        # Extract a sample of content for search (limit to 1000 chars to avoid huge index)
        local content=$(head -n 20 "$file" | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c 1-1000)

        # Add comma before entry if not the first one
        if [ "$first_entry" = true ]; then
            first_entry=false
        else
            echo ',' >> "$temp_index"
        fi

        # Write the entry to the search index
        cat << EOF >> "$temp_index"
{
  "title": "$title",
  "path": "$file_path.html",
  "category": "$category",
  "content": "$content"
}
EOF
    done

    # Close the JSON array
    echo ']' >> "$temp_index"

    # Move the temp file to the final location
    mv "$temp_index" "$search_index"
    log "Search index generated: $search_index"
}

# Orchestrate the entire HTML report generation
generate_report() {
    log "Generating HTML Report..."
    generate_main_index

    # Function to check if directory exists and has files
    has_content() {
        local dir="$1"
        [[ -d "$dir" ]] && [[ $(find "$dir" -type f | wc -l) -gt 0 ]]
    }

    # Generate all category index pages referenced in the sidebar
    # This ensures we have all the pages that are linked in the navigation
    generate_category_index "basic" "Basic Info" "${OUTPUT_DIR}" "${OUTPUT_DIR}/basic_index.html"
    generate_category_index "clusterversion_history" "Version History" "${OUTPUT_DIR}/version" "${OUTPUT_DIR}/clusterversion_history_index.html"
    generate_category_index "nodes" "Nodes" "${OUTPUT_DIR}/nodes" "${OUTPUT_DIR}/nodes_index.html"
    generate_category_index "operators" "Operators" "${OUTPUT_DIR}/operators" "${OUTPUT_DIR}/operators_index.html"
    generate_category_index "etcd" "etcd" "${OUTPUT_DIR}/etcd" "${OUTPUT_DIR}/etcd_index.html"
    generate_category_index "api_resources" "API Resources" "${OUTPUT_DIR}" "${OUTPUT_DIR}/api_resources_index.html"
    generate_category_index "namespaces" "Namespaces" "${OUTPUT_DIR}/namespaces" "${OUTPUT_DIR}/namespaces_index.html"
    generate_category_index "namespace_resources" "Namespace Details" "${OUTPUT_DIR}/namespace_resources" "${OUTPUT_DIR}/namespace_resources_index.html"
    generate_category_index "cluster_resources" "Cluster Resources" "${OUTPUT_DIR}/cluster_resources" "${OUTPUT_DIR}/cluster_resources_index.html"
    generate_category_index "crd_instances" "CRD Instances" "${OUTPUT_DIR}/crd_instances" "${OUTPUT_DIR}/crd_instances_index.html"
    generate_category_index "builds" "Builds & Images" "${OUTPUT_DIR}/builds" "${OUTPUT_DIR}/builds_index.html"
    generate_category_index "network" "Networking" "${OUTPUT_DIR}/network" "${OUTPUT_DIR}/network_index.html"
    generate_category_index "storage" "Storage" "${OUTPUT_DIR}/storage" "${OUTPUT_DIR}/storage_index.html"
    generate_category_index "machine_api" "Machine API" "${OUTPUT_DIR}/machine_api" "${OUTPUT_DIR}/machine_api_index.html"
    generate_category_index "security" "Security" "${OUTPUT_DIR}/security" "${OUTPUT_DIR}/security_index.html"
    generate_category_index "rbac" "RBAC" "${OUTPUT_DIR}/rbac" "${OUTPUT_DIR}/rbac_index.html"
    generate_category_index "metrics" "Metrics" "${OUTPUT_DIR}/metrics" "${OUTPUT_DIR}/metrics_index.html"
    generate_category_index "autoscalers" "Autoscalers" "${OUTPUT_DIR}/autoscalers" "${OUTPUT_DIR}/autoscalers_index.html"
    generate_category_index "events" "Events" "${OUTPUT_DIR}/events" "${OUTPUT_DIR}/events_index.html"
    generate_category_index "logs" "Logs" "${OUTPUT_DIR}/logs" "${OUTPUT_DIR}/logs_index.html"
    generate_category_index "audit" "Audit Config" "${OUTPUT_DIR}/audit" "${OUTPUT_DIR}/audit_index.html"

    # DataTable pages for tabular data - only generate if file exists
    if [ -f "${OUTPUT_DIR}/nodes/nodes_wide.txt" ]; then
      generate_datatable_page "Nodes Table" "${OUTPUT_DIR}/nodes/nodes_wide.txt" "${OUTPUT_DIR}/nodes_table.html" "nodes" "${DATATABLE_FILES["nodes_wide.txt"]}"
    fi
    if [ -f "${OUTPUT_DIR}/operators/clusteroperators.txt" ]; then
      generate_datatable_page "Operators Table" "${OUTPUT_DIR}/operators/clusteroperators.txt" "${OUTPUT_DIR}/operators_table.html" "operators" "${DATATABLE_FILES["clusteroperators.txt"]}"
    fi

    # Generic detail pages (YAML, JSON, log, txt)
    for f in $(find "${OUTPUT_DIR}" -type f \( -name "*.yaml" -o -name "*.json" -o -name "*.log" -o -name "*.txt" -o -name "*.err" \)); do
      # Skip empty files
      if [[ ! -s "$f" ]]; then
        log "  [SKIP] Empty file: $f"
        continue
      fi

      ext="${f##*.}"
      case "$ext" in
        yaml|yml) lang="yaml" ;;
        json) lang="json" ;;
        log) lang="log" ;;
        txt) lang="text" ;;
        err) lang="text" ;;
        *) lang="text" ;;
      esac
      category=$(dirname "$f" | sed "s|${OUTPUT_DIR}/||")
      generate_detail_page "$(basename "$f")" "$f" "$f.html" "$lang" "$category"
    done

    # Generate search index for global search functionality
    generate_search_index

    # Create a simple README file in the output directory
    cat << EOF > "${OUTPUT_DIR}/README.txt"
OpenShift Cluster Report
=======================

This report contains information collected from an OpenShift cluster.
To view the report, open the index.html file in a web browser.

The report includes:
- Cluster configuration
- Node information
- Operator status
- Network configuration
- Storage resources
- Security settings
- And more...

Use the global search feature to search across all files in the report.
EOF

    log "HTML Report generation complete: ${OUTPUT_DIR}/index.html"
}

# Create the main index/dashboard page with cluster summary
generate_main_index() {
    local out_file="${OUTPUT_DIR}/index.html"
    local current_date=$(date +"%Y-%m-%d %H:%M:%S")

    # Dynamic status calculation for nodes and operators
    local node_total=$(awk 'NR>1' "${OUTPUT_DIR}/nodes/nodes_wide.txt" | wc -l)
    local node_ready=$(awk 'NR>1 && $2=="Ready"' "${OUTPUT_DIR}/nodes/nodes_wide.txt" | wc -l)
    local node_ready_percent=$((node_ready * 100 / (node_total > 0 ? node_total : 1)))

    local operator_total=$(awk 'NR>1' "${OUTPUT_DIR}/operators/clusteroperators.txt" | wc -l)
    local operator_available=$(awk 'NR>1 && $3=="True"' "${OUTPUT_DIR}/operators/clusteroperators.txt" | wc -l)
    local operator_available_percent=$((operator_available * 100 / (operator_total > 0 ? operator_total : 1)))

    # Extract cluster version from the collected data
    local cluster_version="Unknown"
    local version_status="Unknown"
    if [ -f "${OUTPUT_DIR}/clusterversion.yaml" ]; then
        cluster_version=$(grep -A1 'version:' "${OUTPUT_DIR}/clusterversion.yaml" | grep -v 'version:' | tr -d ' ' || echo "Unknown")
        version_status=$(grep -A1 "type: Available" "${OUTPUT_DIR}/clusterversion.yaml" | grep "status:" | awk '{print $2}' || echo "Unknown")
    fi

    # Generate HTML header with the custom dashboard layout
    generate_html_header "Cluster Dashboard" "dashboard" > "$out_file"

    # Page header with cluster name and report timestamp
    cat << EOF >> "$out_file"
<div class="p-3 bg-light rounded-3 mb-4">
  <div class="container-fluid">
    <div class="row align-items-center">
      <div class="col-md-8">
        <h1 class="display-5 fw-bold">OpenShift Cluster Report</h1>
        <p class="fs-4">Comprehensive analysis of cluster configuration and resources</p>
        <p class="text-muted">Generated on: ${current_date}</p>
      </div>
      <div class="col-md-4 text-end">
        <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMDAgMTAwIj48ZGVmcz48c3R5bGU+LmNsc3QtMXtmaWxsOiNkYTI5MmU7fS5jbHN0LTJ7ZmlsbDojYzkyMjI3O30uY2xzdC0ze2ZpbGw6I2VlMGEwYTt9LmNsc3QtNHtmaWxsOiNmZmZmZmY7fTwvc3R5bGU+PC9kZWZzPjxwYXRoIGQ9Ik03Mi4yNzcsMTguOTE1bC0xNC43MzYsMTVjLS41MjEuNTIxLTEuMDQyLjc4MS0xLjU2My43ODFoLTIuMzQ0YTEuNTUsMS41NSwwLDAsMC0xLjU2My0xLjU2M0g0Ni4zMzZWMjcuNGE1LjMyNCw1LjMyNCwwLDAsMCwxLjU2My0uMjYxTDYzLjQ3NCwxMS4xOTJBNDkuODEsNDkuODEsMCwwLDAsNTAsOWE0MSw0MSwwLDEsMCw0MSw0MUE0OS4yOTQsNDkuMjk0LDAsMCwwLDcyLjI3NywxOC45MTV6IiBjbGFzcz0iY2xzdC0xIi8+PHBhdGggZD0iTTc2LjYyMyw1OS44OWwtMTYuMy0xMS40NThjLTEuMDQyLS43ODEtMi4zNDQtMS4zMDItMy42NDYtMS4zMDJIMzIuMTIxdjcuMDI5YTEuNjc1LDEuNjc1LDAsMCwxLTEuNTYzLDEuNTYzSDIxLjE4NWMtLjc4MSwwLTEuMzAyLS41MjEtMS41NjMtMS4zMDJsLTIuODY1LTcuODEtMi44NjUsNy41NDdjLS4yNjEuNzgxLS43ODEsMS41NjMtMS41NjMsMS41NjNoLTkuMTFjLS41MjEsMC0xLjA0Mi0uMjYxLTEuMzAyLS43ODEtLjI2MS0uNTIxLS41MjEtMS4wNDIsMC0xLjU2M0wxMS44MTQsNDAuODM1LDIuMTg1LDI3LjQxYy0uNTIxLS41MjEtLjI2MS0xLjMwMiwwLTEuNTYzLjI2MS0uNTIxLjc4MS0uNzgxLDEuMzAyLS43ODFoOS4xMWMuNzgxLDAsMS4zMDIuNTIxLDEuNTYzLDEuMzAybDIuODY1LDcuNTQ5LDIuODY1LTcuODFjLjI2MS0uNzgxLjc4MS0xLjMwMiwxLjU2My0xLjMwMmg5LjYzMWMuNzgxLDAsMS41NjMuNzgxLDEuNTYzLDEuNTYzVjMzLjM2M2gyNC41NTVjMS4zMDIsMCwyLjYwNC0uNTIxLDMuNjQ2LTEuMzAybDE2LjMtMTEuNDU4YTQxLjQ5MSw0MS40OTEsMCwwLDEsMi42MDQsMTQuNTgzQTM4LjA4LDM4LjA4LDAsMCwxLDc2LjYyMyw1OS44OVoiIGNsYXNzPSJjbHN0LTIiLz48cGF0aCBkPSJNNDkuMTM0LDMzLjM2MywzMi44MzQsNDcuMDY1YTQuODA4LDQuODA4LDAsMCwwLTEuNTYzLDMuNjQ2VjgwLjMwOEE0MS4zNDMsNDEuMzQzLDAsMCwwLDUwLDkxYTM3LjYzLDM3LjYzLDAsMCwwLDE2LjAzNy0zLjM4NVY0Ny4wNjVBNC44MDgsNC44MDgsMCwwLDAsNjQuNDc0LDQzLjQyTDQ4LjY5MiwyOS4yLDMwLjU1OSw0OC4xMDdBMS43NTYsMS43NTYsMCwwLDEsMjksMzMuMWMuNTIxLS43ODEsMS4zMDItLjUyMSwyLjA4MywwTDQzLjk5LDIwLjIxN2ExLjgsMS44LDAsMCwxLDIuNjA0LDBsMi4wODMsMi4wODNWMjcuNGgzLjkwN3YyLjYwNEw2Mi42LDIwLjIxN2EzLjc2NCwzLjc2NCwwLDAsMSwyLjYwNCwwbDEzLjY5NCwxMy40MzNjLjc4MS43ODEsMS4zMDIsMSwuNTIxLDEuNTYzcy0yLjA4My41MjEtMi44NjUsMGwtMTIuMTMxLTExLjg3MVoiIGNsYXNzPSJjbHN0LTMiLz48L3N2Zz4=" alt="OpenShift Logo" style="height: 100px;">
      </div>
    </div>
  </div>
</div>

<!-- Status cards row -->
<div class="row mb-4">
  <!-- Cluster Version Card -->
  <div class="col-md-4 mb-4">
    <div class="card h-100 border-0 shadow-sm">
      <div class="card-body">
        <div class="d-flex align-items-center mb-3">
          <i class="fas fa-tag fs-4 text-primary me-3"></i>
          <h5 class="card-title m-0">Cluster Version</h5>
        </div>
        <h2 class="display-6 fw-bold">${cluster_version}</h2>
        <div class="mt-3">
          <span class="badge ${version_status == "True" ? "bg-success" : "bg-warning"} p-2">
            ${version_status == "True" ? "Up to date" : "Version status: ${version_status}"}
          </span>
        </div>
        <a href="clusterversion.yaml.html" class="btn btn-outline-primary btn-sm mt-3">
          <i class="fas fa-info-circle me-1"></i>View Details
        </a>
      </div>
    </div>
  </div>

  <!-- Node Status Card -->
  <div class="col-md-4 mb-4">
    <div class="card h-100 border-0 shadow-sm">
      <div class="card-body">
        <div class="d-flex align-items-center mb-3">
          <i class="fas fa-server fs-4 text-success me-3"></i>
          <h5 class="card-title m-0">Node Status</h5>
        </div>
        <div class="progress mb-3" style="height: 15px;">
          <div class="progress-bar bg-success" role="progressbar" style="width: ${node_ready_percent}%;"
               aria-valuenow="${node_ready_percent}" aria-valuemin="0" aria-valuemax="100">${node_ready_percent}%</div>
        </div>
        <p class="card-text fs-5">${node_ready} of ${node_total} nodes ready</p>
        <a href="nodes_table.html" class="btn btn-outline-success btn-sm mt-1">
          <i class="fas fa-list me-1"></i>View Nodes
        </a>
      </div>
    </div>
  </div>

  <!-- Operator Health Card -->
  <div class="col-md-4 mb-4">
    <div class="card h-100 border-0 shadow-sm">
      <div class="card-body">
        <div class="d-flex align-items-center mb-3">
          <i class="fas fa-cogs fs-4 text-info me-3"></i>
          <h5 class="card-title m-0">Operator Health</h5>
        </div>
        <div class="progress mb-3" style="height: 15px;">
          <div class="progress-bar bg-info" role="progressbar" style="width: ${operator_available_percent}%;"
               aria-valuenow="${operator_available_percent}" aria-valuemin="0" aria-valuemax="100">${operator_available_percent}%</div>
        </div>
        <p class="card-text fs-5">${operator_available} of ${operator_total} operators available</p>
        <a href="operators_table.html" class="btn btn-outline-info btn-sm mt-1">
          <i class="fas fa-list me-1"></i>View Operators
        </a>
      </div>
    </div>
  </div>
</div>

<!-- Navigation Category Cards -->
<div class="row mb-4">
  <div class="col-12">
    <h4 class="mb-3">Report Categories</h4>
  </div>
EOF

    # Generate category cards (using the CATEGORIES array)
    echo '<div class="row row-cols-1 row-cols-md-3 g-4 mb-4">' >> "$out_file"

    # Define a fixed set of icons and colors for categories
    declare -A category_icons=(
        ["basic"]="fa-info-circle,text-primary"
        ["clusterversion_history"]="fa-history,text-primary"
        ["nodes"]="fa-server,text-success"
        ["operators"]="fa-cogs,text-info"
        ["etcd"]="fa-database,text-danger"
        ["api_resources"]="fa-code,text-secondary"
        ["namespaces"]="fa-project-diagram,text-primary"
        ["namespace_resources"]="fa-cubes,text-primary"
        ["cluster_resources"]="fa-cloud,text-info"
        ["crd_instances"]="fa-puzzle-piece,text-warning"
        ["builds"]="fa-hammer,text-secondary"
        ["network"]="fa-network-wired,text-primary"
        ["storage"]="fa-hdd,text-info"
        ["machine_api"]="fa-robot,text-secondary"
        ["security"]="fa-shield-alt,text-danger"
        ["rbac"]="fa-users-cog,text-warning"
        ["metrics"]="fa-chart-line,text-success"
        ["autoscalers"]="fa-expand-arrows-alt,text-info"
        ["events"]="fa-exclamation-circle,text-warning"
        ["logs"]="fa-file-alt,text-secondary"
        ["audit"]="fa-file-signature,text-info"
    )

    # Skip 'dashboard' which is this page
    for category in "${!CATEGORIES[@]}"; do
        if [[ "$category" == "dashboard" ]]; then
            continue
        fi

        # Skip categories that don't have content
        local category_dir="${OUTPUT_DIR}/${category//_//}"  # Replace underscores with slashes
        if [[ ! -d "$category_dir" ]] || [[ $(find "$category_dir" -type f | wc -l) -eq 0 ]]; then
            log "  [SKIP] Empty category in dashboard: $category"
            continue
        fi

        # Only show categories that have generated index pages
        if [[ ! -f "${OUTPUT_DIR}/${category}_index.html" ]]; then
            log "  [SKIP] Missing index page in dashboard: $category"
            continue
        fi

        # Get icon and color for this category, default if not found
        icon_info="${category_icons[$category]:-fa-folder,text-secondary}"
        icon_class=$(echo "$icon_info" | cut -d ',' -f1)
        color_class=$(echo "$icon_info" | cut -d ',' -f2)

        # Create category card
        cat << EOF >> "$out_file"
<div class="col">
  <div class="card h-100 shadow-sm">
    <div class="card-body">
      <div class="d-flex align-items-center mb-3">
        <i class="fas ${icon_class} fs-4 ${color_class} me-3"></i>
        <h5 class="card-title m-0">${CATEGORIES[$category]}</h5>
      </div>
      <p class="card-text">Browse ${CATEGORIES[$category]} information and configuration.</p>
    </div>
    <div class="card-footer bg-transparent border-0">
      <a href="${category}_index.html" class="btn btn-primary">View Details</a>
    </div>
  </div>
</div>
EOF
    done

    echo '</div>' >> "$out_file"  # Close row of category cards

    # Add a section for common actions or quick links
    cat << EOF >> "$out_file"
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
EOF

    generate_html_footer >> "$out_file"
}

# --- Main Execution (after collection) ---
collect_basic
collect_nodes
collect_operators
collect_network
collect_security
collect_metrics
collect_etcd
collect_logs
collect_namespaces
collect_cluster_resources
collect_namespace_resources
collect_audit_logs
collect_rbac
collect_crd_instances
collect_storage
collect_events
collect_imagestreams_buildconfigs
collect_machine_api
collect_api_resources
collect_autoscalers
collect_clusterversion_history

# --- Enhanced HTML Report Generation ---
generate_report

tar czf "${OUTPUT_DIR}.tar.gz" "${OUTPUT_DIR}" && log "Output compressed: ${OUTPUT_DIR}.tar.gz"

echo "Collection complete. Final report: ${OUTPUT_DIR}/index.html"
