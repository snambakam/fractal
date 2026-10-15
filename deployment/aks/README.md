# AKS cluster scripts

Scripts for launching and tearing down an Azure Kubernetes Service (AKS) cluster. They require the Azure CLI (`az`) and a prior `az login`.

| Script | Purpose |
|---|---|
| `create-cluster.sh` | Creates the resource group and cluster if missing, then fetches credentials. Safe to re-run. |
| `get-credentials.sh` | Merges the cluster credentials into your kubeconfig and lists the nodes. |
| `delete-cluster.sh` | Deletes the cluster. `--delete-resource-group` removes the whole group; `--yes` skips the prompt. |
| `common.sh` | Shared defaults and helpers (sourced, not run). |
| `config.example` | Template for the `~/.aks/config` settings file. |

## Usage

```bash
az login
./create-cluster.sh
kubectl get nodes
./delete-cluster.sh
```

## Settings

Settings are resolved in this order, highest priority first:

1. Environment variables.
2. The config file `~/.aks/config` (override the location with `AKS_CONFIG_FILE`).
3. The defaults below.

To create your config file:

```bash
mkdir -p ~/.aks && cp config.example ~/.aks/config
```

The config file lives outside the repository so personal values such as your subscription ID are not committed.

| Variable | Default |
|---|---|
| `AKS_RESOURCE_GROUP` | `fractal-rg` |
| `AKS_CLUSTER_NAME` | `fractal-aks` |
| `AKS_LOCATION` | `westus3` |
| `AKS_NODE_COUNT` | `3` |
| `AKS_NODE_VM_SIZE` | `Standard_D4s_v5` |
| `AKS_OS_SKU` | `AzureLinux` |
| `AKS_KUBERNETES_VERSION` | AKS default |
| `AKS_SUBSCRIPTION` | current `az` subscription |

Example:

```bash
AKS_CLUSTER_NAME=dev AKS_NODE_COUNT=1 ./create-cluster.sh
```
