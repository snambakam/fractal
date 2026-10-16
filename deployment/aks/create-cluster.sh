#!/bin/bash

set -e

#
# Create an AKS cluster (and its resource group if needed), then fetch
# credentials for kubectl. Safe to re-run: existing resources are reused.
#
# See common.sh for the settings that can be overridden.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

#
# Main
#

ensure_az_login

if [ "$(az group exists --name "$AKS_RESOURCE_GROUP" | tr -d '\r')" = "true" ]; then
    echo "Resource group exists: $AKS_RESOURCE_GROUP"
else
    echo "Creating resource group $AKS_RESOURCE_GROUP in $AKS_LOCATION"
    az group create --name "$AKS_RESOURCE_GROUP" --location "$AKS_LOCATION" --output none
fi

if az aks show --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" >/dev/null 2>&1; then
    echo "Cluster already exists: $AKS_CLUSTER_NAME"
else
    args=(
        --resource-group "$AKS_RESOURCE_GROUP"
        --name "$AKS_CLUSTER_NAME"
        --location "$AKS_LOCATION"
        --node-count "$AKS_NODE_COUNT"
        --node-vm-size "$AKS_NODE_VM_SIZE"
        --os-sku "$AKS_OS_SKU"
        --generate-ssh-keys
        --enable-managed-identity
    )
    [ -n "$AKS_KUBERNETES_VERSION" ] && args+=(--kubernetes-version "$AKS_KUBERNETES_VERSION")

    echo "Creating cluster $AKS_CLUSTER_NAME ($AKS_NODE_COUNT x $AKS_NODE_VM_SIZE, $AKS_OS_SKU)"
    az aks create "${args[@]}" --output none
fi

"$SCRIPT_DIR/get-credentials.sh"

echo "Done. Cluster $AKS_CLUSTER_NAME is ready."
