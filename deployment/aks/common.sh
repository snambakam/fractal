#!/bin/bash

#
# Shared settings and helpers for the AKS scripts. Source this file; do not run it.
#
# Settings are resolved in this order, highest priority first:
#   1. Environment variables, for example:
#        AKS_CLUSTER_NAME=my-cluster AKS_NODE_VM_SIZE=Standard_DC4as_v5 ./create-cluster.sh
#   2. The config file ~/.aks/config (or the file named by AKS_CONFIG_FILE).
#      See config.example in this directory.
#   3. The defaults below.
#

AKS_SETTINGS=(
    AKS_RESOURCE_GROUP
    AKS_CLUSTER_NAME
    AKS_LOCATION
    AKS_NODE_COUNT
    AKS_NODE_VM_SIZE
    AKS_OS_SKU
    AKS_KUBERNETES_VERSION
    AKS_SUBSCRIPTION
)

AKS_CONFIG_FILE="${AKS_CONFIG_FILE:-$HOME/.aks/config}"

load_config_file() {
    [ -f "$AKS_CONFIG_FILE" ] || return 0

    # Keep environment values so the config file cannot override them.
    local -A from_env=()
    local name
    for name in "${AKS_SETTINGS[@]}"; do
        [ -n "${!name+x}" ] && from_env[$name]="${!name}"
    done

    # shellcheck disable=SC1090
    source "$AKS_CONFIG_FILE"

    for name in "${!from_env[@]}"; do
        printf -v "$name" '%s' "${from_env[$name]}"
    done

    echo "Loaded settings from $AKS_CONFIG_FILE"
}

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

    echo "Subscription: $(az account show --query '[name, id]' -o tsv | tr -d '\r' | paste -sd' ' -)"
}

#
# Main
#

load_config_file

AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-fractal-rg}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-fractal-aks}"
AKS_LOCATION="${AKS_LOCATION:-westus3}"
AKS_NODE_COUNT="${AKS_NODE_COUNT:-3}"
AKS_NODE_VM_SIZE="${AKS_NODE_VM_SIZE:-Standard_D4s_v5}"
AKS_OS_SKU="${AKS_OS_SKU:-AzureLinux}"
AKS_KUBERNETES_VERSION="${AKS_KUBERNETES_VERSION:-}"
AKS_SUBSCRIPTION="${AKS_SUBSCRIPTION:-}"
