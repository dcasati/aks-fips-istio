#!/usr/bin/env bash
# shfmt -i 2 -ci -w
set -Eo pipefail

trap exit SIGINT SIGTERM

################################################################################
# AKS FIPS + Istio Setup
# Creates AKS with Azure CNI Overlay, FIPS node pool, Istio add-on, and Istio CNI.

################################################################################
# Default configuration
CLUSTER_NAME=${CLUSTER_NAME:-my-fips-istio}
RESOURCE_GROUP=${RESOURCE_GROUP:-my-fips-istio}
LOCATION=${LOCATION:-westus2}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.36.1}
SYSTEM_NODE_SIZE=${SYSTEM_NODE_SIZE:-Standard_DS4_v2}
SYSTEM_NODE_COUNT=${SYSTEM_NODE_COUNT:-3}
FIPS_POOL_NAME=${FIPS_POOL_NAME:-fipspool}
FIPS_NODE_SIZE=${FIPS_NODE_SIZE:-Standard_D4ds_v5}
FIPS_NODE_COUNT=${FIPS_NODE_COUNT:-3}
KUBECONFIG=${KUBECONFIG:-${PWD}/cluster.config}
################################################################################

PROVIDER_LIST="
Microsoft.ContainerService
Microsoft.Compute
Microsoft.Network
Microsoft.ManagedIdentity
Microsoft.OperationalInsights
Microsoft.Insights
Microsoft.AlertsManagement
Microsoft.Monitor
Microsoft.Authorization
Microsoft.Resources
Microsoft.Dashboard
Microsoft.KeyVault
Microsoft.ContainerRegistry
Microsoft.Kubernetes
Microsoft.KubernetesConfiguration
"

__usage="
    -x  action to be executed.

Possible verbs are:
    install           Full deployment flow.
    register          Register required resource providers.
    create-rg         Create or update the resource group.
    create-aks        Create AKS cluster (Azure CNI Overlay + Istio add-on).
    add-fips-pool     Add FIPS-enabled user node pool.
    get-credentials   Pull kubeconfig for the cluster.
    enable-istio-cni  Enable Istio CNI chaining.
    verify            Validate nodes and Istio control plane.
    check-deps        Check required tools and Azure login.
    show              Show current settings and cluster status.

Environment variables (with defaults):
    CLUSTER_NAME=${CLUSTER_NAME}
    RESOURCE_GROUP=${RESOURCE_GROUP}
    LOCATION=${LOCATION}
    KUBERNETES_VERSION=${KUBERNETES_VERSION}
    SYSTEM_NODE_SIZE=${SYSTEM_NODE_SIZE}
    SYSTEM_NODE_COUNT=${SYSTEM_NODE_COUNT}
    FIPS_POOL_NAME=${FIPS_POOL_NAME}
    FIPS_NODE_SIZE=${FIPS_NODE_SIZE}
    FIPS_NODE_COUNT=${FIPS_NODE_COUNT}
    KUBECONFIG=${KUBECONFIG}
"

usage() {
  echo "usage: ${0##*/} [options]"
  echo "${__usage/[[:space:]]/}"
  exit 1
}

print_header() {
  echo ""
  echo "AKS FIPS + Istio Setup"
  echo "=========================================="
  echo ""
  echo "Cluster Name:      $CLUSTER_NAME"
  echo "Resource Group:    $RESOURCE_GROUP"
  echo "Location:          $LOCATION"
  echo "AKS Version:       $KUBERNETES_VERSION"
  echo "System Node Size:  $SYSTEM_NODE_SIZE"
  echo "System Node Count: $SYSTEM_NODE_COUNT"
  echo "FIPS Pool Name:    $FIPS_POOL_NAME"
  echo "FIPS Node Size:    $FIPS_NODE_SIZE"
  echo "FIPS Node Count:   $FIPS_NODE_COUNT"
  echo "Kubeconfig:        $KUBECONFIG"
  echo ""
}

log() {
  echo "[$(date +"%r")] $*"
}

check_dependencies() {
  log "Checking dependencies..."
  local _needed="az kubectl"
  local _dep_flag=false

  for i in ${_needed}; do
    if hash "$i" 2>/dev/null; then
      log "  $i: OK"
    else
      log "  $i: NOT FOUND"
      _dep_flag=true
    fi
  done

  if ! az account show >/dev/null 2>&1; then
    log "  az login: REQUIRED"
    _dep_flag=true
  else
    log "  az login: OK"
  fi

  if [[ "${_dep_flag}" == "true" ]]; then
    log "Dependencies missing. Please fix before proceeding"
    exit 1
  fi

  log "All dependencies satisfied"
}

install_aks_preview_extension() {
  log "Ensuring aks-preview extension is installed and updated..."
  az extension add --name aks-preview --allow-preview true --upgrade --only-show-errors
}

register_providers() {
  log "Registering Azure resource providers..."
  for ns in ${PROVIDER_LIST}; do
    log "  Registering ${ns}"
    az provider register --namespace "${ns}" --only-show-errors >/dev/null
  done
}

wait_for_provider_registration() {
  log "Waiting for provider registrations to complete..."
  for ns in ${PROVIDER_LIST}; do
    log "  Waiting for ${ns}"
    while [[ "$(az provider show --namespace "${ns}" --query registrationState -o tsv 2>/dev/null)" != "Registered" ]]; do
      sleep 10
    done
    log "  ${ns}: Registered"
  done
}

do_register() {
  install_aks_preview_extension
  register_providers
  wait_for_provider_registration
}

do_create_rg() {
  log "Creating resource group ${RESOURCE_GROUP} in ${LOCATION}"
  az group create \
    --name "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --only-show-errors >/dev/null
  log "Resource group is ready"
}

do_create_aks() {
  log "Creating AKS cluster ${CLUSTER_NAME}"
  az aks create \
    --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --node-count "${SYSTEM_NODE_COUNT}" \
    --node-vm-size "${SYSTEM_NODE_SIZE}" \
    --node-osdisk-size 128 \
    --node-osdisk-type Ephemeral \
    --max-pods 250 \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --pod-cidr 10.244.0.0/16 \
    --service-cidr 10.0.0.0/16 \
    --dns-service-ip 10.0.0.10 \
    --load-balancer-sku standard \
    --generate-ssh-keys \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --enable-azure-service-mesh \
    --revision asm-1-29 \
    --only-show-errors
}

do_add_fips_pool() {
  log "Adding FIPS-enabled node pool ${FIPS_POOL_NAME}"
  az aks nodepool add \
    --cluster-name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${FIPS_POOL_NAME}" \
    --node-vm-size "${FIPS_NODE_SIZE}" \
    --node-count "${FIPS_NODE_COUNT}" \
    --node-osdisk-size 128 \
    --node-osdisk-type Ephemeral \
    --max-pods 110 \
    --mode User \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --enable-fips-image \
    --only-show-errors
}

do_get_credentials() {
  log "Fetching kubeconfig to ${KUBECONFIG}"
  az aks get-credentials \
    --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --file "${KUBECONFIG}" \
    --overwrite-existing \
    --only-show-errors
}

do_enable_istio_cni() {
  log "Enabling Istio CNI chaining"
  az aks mesh enable-istio-cni \
    --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --only-show-errors
}

do_verify() {
  log "Nodes"
  kubectl get nodes -o wide
  log "Istio control plane pods"
  kubectl get pods -n aks-istio-system
}

do_show() {
  print_header
  log "Cluster service mesh profile"
  az aks show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --query serviceMeshProfile \
    -o yaml 2>/dev/null || log "Cluster not found yet"
}

do_install() {
  check_dependencies
  do_register
  do_create_rg
  do_create_aks
  do_add_fips_pool
  do_get_credentials
  do_enable_istio_cni
  do_verify
  log "Done"
  log "Sidecar label command:"
  log "  REVISION=\$(az aks show -g ${RESOURCE_GROUP} -n ${CLUSTER_NAME} --query 'serviceMeshProfile.istio.revisions[0]' -o tsv)"
  log "  kubectl label namespace <your-namespace> istio.io/rev=\${REVISION} --overwrite"
}

exec_case() {
  local _opt=$1

  case ${_opt} in
  install)           do_install ;;
  register)          do_register ;;
  create-rg)         do_create_rg ;;
  create-aks)        do_create_aks ;;
  add-fips-pool)     do_add_fips_pool ;;
  get-credentials)   do_get_credentials ;;
  enable-istio-cni)  do_enable_istio_cni ;;
  verify)            do_verify ;;
  check-deps)        check_dependencies ;;
  show)              do_show ;;
  *)                 usage ;;
  esac
  unset _opt
}

################################################################################
# Entry point
main() {
  while getopts "x:" opt; do
    case $opt in
      x)
        exec_flag=true
        EXEC_OPT="${OPTARG}"
        ;;
      *) usage ;;
    esac
  done
  shift $((OPTIND - 1))

  if [ "${OPTIND}" = 1 ]; then
    print_header
    usage
    exit 0
  fi

  if [[ "${exec_flag}" == "true" ]]; then
    exec_case "${EXEC_OPT}"
  fi
}

main "$@"
exit 0
