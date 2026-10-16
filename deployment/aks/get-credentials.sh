#!/bin/bash

set -e
set -o pipefail

#
# Merge the AKS cluster credentials into the local kubeconfig and show the nodes.
#
# The credentials are fetched to stdout and merged here, rather than letting az
# write the file itself. When az is the Windows binary (WSL interop) it would
# otherwise write to C:\Users\<user>\.kube\config instead of ~/.kube/config.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

merge_kubeconfig() {
    local fetched merged context
    fetched="$(mktemp)"
    merged="$(mktemp)"
    trap 'rm -f "$fetched" "$merged"' RETURN

    az aks get-credentials \
        --resource-group "$AKS_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --file - | tr -d '\r' > "$fetched"

    context="$(KUBECONFIG="$fetched" kubectl config current-context)"

    mkdir -p "$(dirname "$KUBECONFIG_TARGET")"
    if [ -s "$KUBECONFIG_TARGET" ]; then
        # Entries from the freshly fetched file take precedence over existing ones.
        KUBECONFIG="$fetched:$KUBECONFIG_TARGET" kubectl config view --flatten > "$merged"
    else
        cp "$fetched" "$merged"
    fi

    install -m 600 "$merged" "$KUBECONFIG_TARGET"
    KUBECONFIG="$KUBECONFIG_TARGET" kubectl config use-context "$context"
}

#
# Main
#

KUBECONFIG_TARGET="${KUBECONFIG:-$HOME/.kube/config}"
KUBECONFIG_TARGET="${KUBECONFIG_TARGET%%:*}"

ensure_az_login
require_tool kubectl

merge_kubeconfig
echo "Updated $KUBECONFIG_TARGET"

kubectl get nodes -o wide
