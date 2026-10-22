# Azure setup for Keylime (Key Vault, workload identity, PostgreSQL)

`setup-azure.sh` creates and wires up the Azure resources the Keylime Helm chart needs to read its PostgreSQL connection URLs from Azure Key Vault. It assumes the AKS cluster ([../aks](../aks)) and the Key Vault already exist, and that the vault uses Azure RBAC authorization.

Every step checks the current state first, so the script is safe to run again at any time, for example after a failure or to rotate the stored URLs. It requires the Azure CLI, a prior `az login`, and `python3`.

## Usage

```bash
./setup-azure.sh              # run all steps in order
./setup-azure.sh --list       # show the steps
./setup-azure.sh postgres database-urls   # run only some steps
```

Steps always run in the order below, whatever order you name them in.

| Step | What it does |
|---|---|
| `workload-identity` | Enables the OIDC issuer, workload identity and the `azure-keyvault-secrets-provider` add-on on the cluster. This updates the existing cluster in place. |
| `keyvault-admin` | Grants the signed-in user `Key Vault Secrets Officer` on the vault, so the script can write secrets. |
| `identity` | Creates a user-assigned managed identity with `Key Vault Secrets User` on the vault, and federated credentials for the registrar and verifier service accounts. |
| `postgres` | Creates an Azure Database for PostgreSQL Flexible Server and the two databases. The generated admin password goes straight into Key Vault and is never printed. |
| `database-urls` | Builds the two SQLAlchemy URLs (password percent-encoded) and stores them in Key Vault. Skips a secret whose value is already current. |
| `helm-values` | Writes the Helm values file that points the chart at the vault. It contains no secrets. |

## Settings

Settings are resolved the same way as for the AKS scripts: environment variables, then `~/.aks/config`, then defaults. See [../aks/config.example](../aks/config.example).

| Variable | Default |
|---|---|
| `AZ_KEYVAULT_NAME` | `<resource group without -rg>-kv` |
| `AZ_KEYVAULT_ADMIN_OBJECT_ID` | the signed-in user |
| `AZ_IDENTITY_NAME` | `<cluster name>-keylime` |
| `AZ_K8S_NAMESPACE` | `keylime` |
| `AZ_HELM_RELEASE` | `keylime` |
| `AZ_HELM_VALUES_FILE` | `~/.aks/keylime-values.yaml` |
| `AZ_POSTGRES_SERVER` | `<resource group without -rg>-pg` |
| `AZ_POSTGRES_ADMIN_USER` | `keylime` |
| `AZ_POSTGRES_VERSION` | `16` |
| `AZ_POSTGRES_TIER` / `AZ_POSTGRES_SKU` | `Burstable` / `Standard_B2s` |
| `AZ_POSTGRES_STORAGE_GB` | `32` |
| `AZ_POSTGRES_ALLOWED_IPS` | none (space-separated extra IPs allowed through the firewall) |
| `AZ_POSTGRES_REGISTRAR_DB` / `AZ_POSTGRES_VERIFIER_DB` | `keylime_registrar` / `keylime_verifier` |
| `AZ_KV_ADMIN_PASSWORD_SECRET` | `keylime-postgres-admin-password` |
| `AZ_KV_REGISTRAR_URL_SECRET` / `AZ_KV_VERIFIER_URL_SECRET` | `keylime-registrar-database-url` / `keylime-verifier-database-url` |

The vault and the PostgreSQL server must be in the AKS resource group (`AKS_RESOURCE_GROUP`). Server names are globally unique, so set `AZ_POSTGRES_SERVER` if the default is taken.

`AZ_K8S_NAMESPACE` and `AZ_HELM_RELEASE` must match how you install the chart. The federated credentials are bound to the service accounts `<release>-keylime-registrar` and `<release>-keylime-verifier` in that namespace (the release name alone when it already contains `keylime-registrar` or `keylime-verifier`). If you change them, run the `identity` and `helm-values` steps again.

## Behavior to know about

- **Network access.** The server uses public access with TLS required. Its firewall allows only the AKS egress IPs (and `AZ_POSTGRES_ALLOWED_IPS`). Private access through a VNet is not set up. Re-run the `postgres` step if the cluster's egress IPs change.
- **Admin login.** The chart connects with the server admin login. A dedicated least-privilege role would need a direct SQL connection to the server, which this script does not make.
- **Never overwrites the admin password.** If the password is already in Key Vault, it is reused. The script stops, rather than guessing, if it cannot tell whether the server exists.
- **Propagation delay.** A new role assignment can take a few minutes to take effect, so reads and writes to the vault are retried for up to about three minutes.
- **Windows `az`.** When `az` is the Windows binary under WSL, secret values are passed through a file instead of the command line, because `cmd.exe` mangles characters such as `%`.

## Installing the chart afterwards

Install the chart in `AZ_K8S_NAMESPACE` with release name `AZ_HELM_RELEASE`, passing the generated values file with `-f`.
