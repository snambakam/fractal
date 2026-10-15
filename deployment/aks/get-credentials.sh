#!/bin/bash

set -e

#
# Merge the AKS cluster credentials into the local kubeconfig and show the nodes.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

#
# Main
#

ensure_az_login

az aks get-credentials \
    --resource-group "$AKS_RESOURCE_GROUP" \
    --name "$AKS_CLUSTER_NAME" \
    --overwrite-existing

if command -v kubectl >/dev/null 2>&1; then
    kubectl get nodes -o wide
else
    echo "kubectl not found; install it with 'az aks install-cli' to inspect the cluster."
fi
