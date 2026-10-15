#!/bin/bash

set -e

#
# Delete the AKS cluster. Pass --delete-resource-group to remove the whole
# resource group, and --yes to skip the confirmation prompt.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

delete_group=false
assume_yes=false
for arg in "$@"; do
    case "$arg" in
        --delete-resource-group) delete_group=true ;;
        --yes) assume_yes=true ;;
        *)
            echo "Usage: $0 [--delete-resource-group] [--yes]" >&2
            exit 1
            ;;
    esac
done

#
# Main
#

ensure_az_login

if $delete_group; then
    target="resource group $AKS_RESOURCE_GROUP (and everything in it)"
else
    target="cluster $AKS_CLUSTER_NAME in resource group $AKS_RESOURCE_GROUP"
fi

if ! $assume_yes; then
    read -r -p "Delete $target? [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 1 ;;
    esac
fi

if $delete_group; then
    az group delete --name "$AKS_RESOURCE_GROUP" --yes
else
    az aks delete --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --yes
fi

echo "Deleted $target."
