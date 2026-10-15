#!/bin/bash

#
# Shared settings and helpers for the AKS scripts. Source this file; do not run it.
#
# Every setting can be overridden through the environment, for example:
#   AKS_CLUSTER_NAME=my-cluster AKS_NODE_VM_SIZE=Standard_DC4as_v5 ./create-cluster.sh
#

AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-fractal-rg}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-fractal-aks}"
AKS_LOCATION="${AKS_LOCATION:-westus3}"
AKS_NODE_COUNT="${AKS_NODE_COUNT:-3}"
AKS_NODE_VM_SIZE="${AKS_NODE_VM_SIZE:-Standard_D4s_v5}"
AKS_OS_SKU="${AKS_OS_SKU:-AzureLinux}"
AKS_KUBERNETES_VERSION="${AKS_KUBERNETES_VERSION:-}"
AKS_SUBSCRIPTION="${AKS_SUBSCRIPTION:-}"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: '$1' is required but not installed." >&2
        exit 1
    fi
}

ensure_az_login() {
    require_tool az

    if ! az account show >/dev/null 2>&1; then
        echo "Error: not logged in to Azure. Run 'az login' first." >&2
        exit 1
    fi

    if [ -n "$AKS_SUBSCRIPTION" ]; then
        az account set --subscription "$AKS_SUBSCRIPTION"
    fi

    echo "Subscription: $(az account show --query '[name, id]' -o tsv | paste -sd' ' -)"
}
