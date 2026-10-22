#!/bin/bash

set -e
set -o pipefail

#
# Create and wire up the Azure resources the Keylime chart needs to read its PostgreSQL
# connection URLs from Azure Key Vault. Every step checks the current state first, so the
# script is safe to run again at any time, for example to repair or to rotate the URLs.
#
# Usage: setup-azure.sh [--list] [step ...]
#
#   With no steps, all steps run in order. Name one or more steps to run only those.
#
# Steps:
#   workload-identity  Enable workload identity and the Key Vault CSI add-on on the AKS cluster.
#   keyvault-admin     Grant the signed-in user "Key Vault Secrets Officer" on the vault.
#   identity           Create a managed identity with "Key Vault Secrets User" on the vault, and
#                      federated credentials for the registrar and verifier service accounts.
#   postgres           Create an Azure Database for PostgreSQL Flexible Server (public access,
#                      firewalled to the AKS egress IPs) and the two databases. The generated admin
#                      password is stored in Key Vault and is never printed.
#   database-urls      Build the two SQLAlchemy URLs and store them in Key Vault.
#   helm-values        Write the Helm values that point the chart at the vault.
#
# Settings come from the environment, ~/.aks/config or the defaults in ../aks/common.sh.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../aks/common.sh"

STEPS=(workload-identity keyvault-admin identity postgres database-urls helm-values)

#
# Helpers
#

# az output captured for use in the script. Windows az (WSL interop) ends lines with a carriage return.
azq() {
    az "$@" | tr -d '\r'
}

# Windows az cannot read Linux paths, so translate them when az is the Windows binary.
az_path() {
    local az_bin
    az_bin="$(command -v az)"
    if [[ "$az_bin" == /mnt/* ]] && command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1"
    else
        echo "$1"
    fi
}

# Chart-generated service account name: <release>-<chart>, or just <release> when the release
# name already contains the chart name.
service_account_name() {
    local chart="$1"
    if [[ "$AZ_HELM_RELEASE" == *"$chart"* ]]; then
        echo "$AZ_HELM_RELEASE"
    else
        echo "$AZ_HELM_RELEASE-$chart"
    fi
}

vault_id() {
    azq keyvault show --name "$AZ_KEYVAULT_NAME" --resource-group "$AKS_RESOURCE_GROUP" --query id --output tsv
}

kv_get_secret() {
    local name="$1" err_file out attempt
    err_file="$(mktemp)"

    for attempt in $(seq 1 12); do
        if out="$(azq keyvault secret show --vault-name "$AZ_KEYVAULT_NAME" --name "$name" --query value --output tsv 2>"$err_file")"; then
            rm -f "$err_file"
            printf '%s' "$out"
            return 0
        fi
        # Only a missing secret counts as empty; any other error must not be mistaken for "not there".
        if grep -qiE "SecretNotFound|was not found" "$err_file"; then
            rm -f "$err_file"
            return 0
        fi
        if grep -qiE "forbidden|not authorized" "$err_file"; then
            echo "Key Vault read not permitted yet; role assignments can take a few minutes to propagate. Retrying ($attempt/12)..." >&2
            sleep 15
            continue
        fi
        break
    done

    cat "$err_file" >&2
    rm -f "$err_file"
    return 1
}

# The value goes through a file, not the command line: arguments pass through cmd.exe when az is
# the Windows binary, which mangles characters such as % in URLs.
kv_set_secret() {
    local name="$1" value="$2" file attempt
    file="$(mktemp)"
    chmod 600 "$file"
    printf '%s' "$value" > "$file"

    for attempt in $(seq 1 12); do
        if az keyvault secret set --vault-name "$AZ_KEYVAULT_NAME" --name "$name" \
            --file "$(az_path "$file")" --output none 2>"$file.err"; then
            rm -f "$file" "$file.err"
            return 0
        fi
        if ! grep -qiE "forbidden|not authorized" "$file.err"; then
            break
        fi
        echo "Key Vault write not permitted yet; role assignments can take a few minutes to propagate. Retrying ($attempt/12)..." >&2
        sleep 15
    done

    cat "$file.err" >&2
    rm -f "$file" "$file.err"
    return 1
}

url_encode() {
    printf '%s' "$1" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))'
}

generate_password() {
    python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)))'
}

ensure_role() {
    local object_id="$1" role="$2" scope="$3" principal_type="$4" count attempt

    count="$(azq role assignment list --assignee "$object_id" --role "$role" --scope "$scope" --query "length(@)" --output tsv)"
    if [ "$count" != "0" ]; then
        echo "Role already assigned: $role"
        return 0
    fi

    # A newly created principal can take a moment to replicate before it can be assigned a role.
    for attempt in $(seq 1 6); do
        if az role assignment create --assignee-object-id "$object_id" --assignee-principal-type "$principal_type" \
            --role "$role" --scope "$scope" --output none 2>/dev/null; then
            echo "Assigned role: $role"
            return 0
        fi
        echo "Role assignment not accepted yet; retrying ($attempt/6)..." >&2
        sleep 10
    done

    az role assignment create --assignee-object-id "$object_id" --assignee-principal-type "$principal_type" \
        --role "$role" --scope "$scope" --output none
}

step_workload_identity() {
    local state oidc workload_identity addon
    state="$(azq aks show --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" \
        --query "[oidcIssuerProfile.enabled, securityProfile.workloadIdentity.enabled, addonProfiles.azureKeyvaultSecretsProvider.enabled]" \
        --output tsv | tr '[:upper:]' '[:lower:]')"
    read -r oidc workload_identity addon <<<"$state"

    if [ "$oidc" = "true" ] && [ "$workload_identity" = "true" ]; then
        echo "OIDC issuer and workload identity already enabled"
    else
        echo "Enabling the OIDC issuer and workload identity on $AKS_CLUSTER_NAME"
        az aks update --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" \
            --enable-oidc-issuer --enable-workload-identity --output none
    fi

    if [ "$addon" = "true" ]; then
        echo "Key Vault CSI add-on already enabled"
    else
        echo "Enabling the azure-keyvault-secrets-provider add-on"
        az aks enable-addons --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" \
            --addons azure-keyvault-secrets-provider --output none
    fi
}

step_keyvault_admin() {
    local rbac object_id
    rbac="$(azq keyvault show --name "$AZ_KEYVAULT_NAME" --resource-group "$AKS_RESOURCE_GROUP" \
        --query properties.enableRbacAuthorization --output tsv | tr '[:upper:]' '[:lower:]')"
    if [ "$rbac" != "true" ]; then
        echo "Error: vault $AZ_KEYVAULT_NAME does not use Azure RBAC authorization, so role assignments have no effect." >&2
        exit 1
    fi

    object_id="$AZ_KEYVAULT_ADMIN_OBJECT_ID"
    if [ -z "$object_id" ]; then
        object_id="$(azq ad signed-in-user show --query id --output tsv)" || true
    fi
    if [ -z "$object_id" ]; then
        echo "Error: could not determine the signed-in user. Set AZ_KEYVAULT_ADMIN_OBJECT_ID to your object ID." >&2
        exit 1
    fi

    ensure_role "$object_id" "Key Vault Secrets Officer" "$(vault_id)" User
}

step_identity() {
    local principal_id issuer chart subject current

    if az identity show --resource-group "$AKS_RESOURCE_GROUP" --name "$AZ_IDENTITY_NAME" >/dev/null 2>&1; then
        echo "Managed identity exists: $AZ_IDENTITY_NAME"
    else
        echo "Creating managed identity $AZ_IDENTITY_NAME"
        az identity create --resource-group "$AKS_RESOURCE_GROUP" --name "$AZ_IDENTITY_NAME" \
            --location "$AKS_LOCATION" --output none
    fi

    principal_id="$(azq identity show --resource-group "$AKS_RESOURCE_GROUP" --name "$AZ_IDENTITY_NAME" \
        --query principalId --output tsv)"
    ensure_role "$principal_id" "Key Vault Secrets User" "$(vault_id)" ServicePrincipal

    issuer="$(azq aks show --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" \
        --query oidcIssuerProfile.issuerUrl --output tsv)"
    if [ -z "$issuer" ] || [ "$issuer" = "None" ]; then
        echo "Error: the cluster has no OIDC issuer. Run the 'workload-identity' step first." >&2
        exit 1
    fi

    for chart in keylime-registrar keylime-verifier; do
        subject="system:serviceaccount:$AZ_K8S_NAMESPACE:$(service_account_name "$chart")"
        current="$(azq identity federated-credential show --resource-group "$AKS_RESOURCE_GROUP" \
            --identity-name "$AZ_IDENTITY_NAME" --name "$chart" --query subject --output tsv 2>/dev/null || true)"

        if [ "$current" = "$subject" ]; then
            echo "Federated credential up to date: $chart ($subject)"
        elif [ -n "$current" ]; then
            echo "Updating federated credential $chart: $current -> $subject"
            az identity federated-credential update --resource-group "$AKS_RESOURCE_GROUP" \
                --identity-name "$AZ_IDENTITY_NAME" --name "$chart" --issuer "$issuer" \
                --subject "$subject" --audiences api://AzureADTokenExchange --output none
        else
            echo "Creating federated credential $chart ($subject)"
            az identity federated-credential create --resource-group "$AKS_RESOURCE_GROUP" \
                --identity-name "$AZ_IDENTITY_NAME" --name "$chart" --issuer "$issuer" \
                --subject "$subject" --audiences api://AzureADTokenExchange --output none
        fi
    done
}

postgres_firewall_rules() {
    local ids id ip count=0 rule

    ids="$(azq aks show --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" \
        --query "networkProfile.loadBalancerProfile.effectiveOutboundIPs[].id" --output tsv)"

    if [ -z "$ids" ]; then
        echo "Warning: could not find the AKS egress IPs; set AZ_POSTGRES_ALLOWED_IPS so the cluster can reach the server." >&2
    fi

    for id in $ids; do
        ip="$(azq network public-ip show --ids "$id" --query ipAddress --output tsv)"
        count=$((count + 1))
        rule="aks-egress-$count"
        echo "Allowing AKS egress IP $ip ($rule)"
        az postgres flexible-server firewall-rule create --resource-group "$AKS_RESOURCE_GROUP" \
            --name "$AZ_POSTGRES_SERVER" --rule-name "$rule" \
            --start-ip-address "$ip" --end-ip-address "$ip" --output none
    done

    count=0
    for ip in $AZ_POSTGRES_ALLOWED_IPS; do
        count=$((count + 1))
        rule="extra-$count"
        echo "Allowing IP $ip ($rule)"
        az postgres flexible-server firewall-rule create --resource-group "$AKS_RESOURCE_GROUP" \
            --name "$AZ_POSTGRES_SERVER" --rule-name "$rule" \
            --start-ip-address "$ip" --end-ip-address "$ip" --output none
    done
}

postgres_server_exists() {
    local err
    if err="$(az postgres flexible-server show --resource-group "$AKS_RESOURCE_GROUP" --name "$AZ_POSTGRES_SERVER" 2>&1 >/dev/null)"; then
        return 0
    fi
    if grep -qiE "ResourceNotFound|could not be found|was not found" <<<"$err"; then
        return 1
    fi
    echo "Error: could not check whether PostgreSQL server $AZ_POSTGRES_SERVER exists:" >&2
    echo "$err" >&2
    exit 1
}

step_postgres() {
    local password db

    if postgres_server_exists; then
        echo "PostgreSQL server exists: $AZ_POSTGRES_SERVER"
        if [ -z "$(kv_get_secret "$AZ_KV_ADMIN_PASSWORD_SECRET")" ]; then
            echo "Error: the server exists but Key Vault secret $AZ_KV_ADMIN_PASSWORD_SECRET is missing." >&2
            echo "Reset the admin password with 'az postgres flexible-server update --admin-password' and store it in that secret." >&2
            exit 1
        fi
    else
        # Never overwrite a stored password: it may belong to a server that an earlier run only partly created.
        password="$(kv_get_secret "$AZ_KV_ADMIN_PASSWORD_SECRET")"
        if [ -n "$password" ]; then
            echo "Reusing the admin password already stored in Key Vault"
        else
            # Store the password first so it cannot be lost if server creation succeeds but the write fails.
            password="$(generate_password)"
            kv_set_secret "$AZ_KV_ADMIN_PASSWORD_SECRET" "$password"
        fi
        echo "Creating PostgreSQL server $AZ_POSTGRES_SERVER (this takes several minutes)"
        az postgres flexible-server create --resource-group "$AKS_RESOURCE_GROUP" --name "$AZ_POSTGRES_SERVER" \
            --location "$AKS_LOCATION" --admin-user "$AZ_POSTGRES_ADMIN_USER" --admin-password "$password" \
            --version "$AZ_POSTGRES_VERSION" --tier "$AZ_POSTGRES_TIER" --sku-name "$AZ_POSTGRES_SKU" \
            --storage-size "$AZ_POSTGRES_STORAGE_GB" --public-access None --high-availability Disabled \
            --yes --output none
    fi

    postgres_firewall_rules

    for db in "$AZ_POSTGRES_REGISTRAR_DB" "$AZ_POSTGRES_VERIFIER_DB"; do
        if az postgres flexible-server db show --resource-group "$AKS_RESOURCE_GROUP" \
            --server-name "$AZ_POSTGRES_SERVER" --database-name "$db" >/dev/null 2>&1; then
            echo "Database exists: $db"
        else
            echo "Creating database $db"
            az postgres flexible-server db create --resource-group "$AKS_RESOURCE_GROUP" \
                --server-name "$AZ_POSTGRES_SERVER" --database-name "$db" --output none
        fi
    done
}

step_database_urls() {
    local password host user name database url

    password="$(kv_get_secret "$AZ_KV_ADMIN_PASSWORD_SECRET")"
    if [ -z "$password" ]; then
        echo "Error: Key Vault secret $AZ_KV_ADMIN_PASSWORD_SECRET not found. Run the 'postgres' step first." >&2
        exit 1
    fi

    host="$(azq postgres flexible-server show --resource-group "$AKS_RESOURCE_GROUP" --name "$AZ_POSTGRES_SERVER" \
        --query fullyQualifiedDomainName --output tsv)"
    user="$(url_encode "$AZ_POSTGRES_ADMIN_USER")"

    for name in "$AZ_KV_REGISTRAR_URL_SECRET:$AZ_POSTGRES_REGISTRAR_DB" "$AZ_KV_VERIFIER_URL_SECRET:$AZ_POSTGRES_VERIFIER_DB"; do
        database="${name#*:}"
        name="${name%%:*}"
        url="postgresql+psycopg2://$user:$(url_encode "$password")@$host:5432/$database?sslmode=require"

        if [ "$(kv_get_secret "$name")" = "$url" ]; then
            echo "Key Vault secret up to date: $name"
        else
            echo "Storing Key Vault secret: $name"
            kv_set_secret "$name" "$url"
        fi
    done
}

step_helm_values() {
    local tenant_id client_id

    tenant_id="$(azq account show --query tenantId --output tsv)"
    client_id="$(azq identity show --resource-group "$AKS_RESOURCE_GROUP" --name "$AZ_IDENTITY_NAME" \
        --query clientId --output tsv)"

    mkdir -p "$(dirname "$AZ_HELM_VALUES_FILE")"
    cat > "$AZ_HELM_VALUES_FILE" <<EOF
# Generated by setup-azure.sh. Contains no secrets.
global:
  database:
    postgres:
      external: true
      keyVault:
        enabled: true
        name: $AZ_KEYVAULT_NAME
        tenantId: $tenant_id
        clientId: $client_id
        registrarUrlSecretName: $AZ_KV_REGISTRAR_URL_SECRET
        verifierUrlSecretName: $AZ_KV_VERIFIER_URL_SECRET
EOF
    echo "Wrote Helm values to $AZ_HELM_VALUES_FILE"
    echo "Install the chart in namespace $AZ_K8S_NAMESPACE with release name $AZ_HELM_RELEASE and: -f $AZ_HELM_VALUES_FILE"
}

usage() {
    echo "Usage: $0 [--list] [step ...]" >&2
    echo "Steps: ${STEPS[*]}" >&2
}

#
# Main
#

selected=()
for arg in "$@"; do
    case "$arg" in
        --list)
            printf '%s\n' "${STEPS[@]}"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ " ${STEPS[*]} " != *" $arg "* ]]; then
                echo "Error: unknown step '$arg'." >&2
                usage
                exit 1
            fi
            selected+=("$arg")
            ;;
    esac
done

if [ ${#selected[@]} -eq 0 ]; then
    selected=("${STEPS[@]}")
fi

ensure_az_login
require_tool python3

# Run the selected steps in their defined order, whatever order they were named in.
for step in "${STEPS[@]}"; do
    if [[ " ${selected[*]} " == *" $step "* ]]; then
        echo
        echo "==> $step"
        "step_${step//-/_}"
    fi
done

echo
echo "Done."
