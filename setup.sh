#!/usr/bin/env bash
# Microsoft Sentinel Solution for Freshservice — Setup Script (Bash)
# Usage: ./setup.sh --subscription-id <id> --resource-group <rg> ...
# Run ./setup.sh --help for full options

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
LOCATION="eastus"
WORKSPACE_NAME=""
FS_DOMAIN=""
FS_API_KEY=""
REQUESTER_EMAIL="soc-automation@yourcompany.com"
KV_NAME=""
SYNC_SEVERITY='["High","Medium"]'
TAG_FILTER=""
POLLING_INTERVAL=5
APP_REG_NAME="SentinelFreshserviceConnector"
TEMPLATE_BASE_URI="https://raw.githubusercontent.com/soshk-csu/sentinel-freshservice-solution/main"

usage() {
  cat <<EOF
Usage: $0 [options]

Required:
  --subscription-id         Azure Subscription ID
  --resource-group          Resource group name
  --workspace-name          Sentinel Log Analytics workspace name
  --freshservice-domain     e.g. yourcompany.freshservice.com
  --freshservice-api-key    Freshservice API key
  --keyvault-name           Key Vault name (globally unique, 3-24 chars)
  --requester-email         Default ticket requester email

Optional:
  --location                Azure region (default: eastus)
  --sync-severity           JSON array of severities (default: ["High","Medium"])
  --tag-filter              Incident tag filter (default: none)
  --polling-interval        Poller interval minutes (default: 5)
  --template-base-uri       Base URI for ARM templates
  --help                    Show this message
EOF
  exit 0
}

step() { echo -e "\n\033[0;36m==> $1\033[0m"; }
ok()   { echo -e "    \033[0;32m[OK] $1\033[0m"; }
warn() { echo -e "    \033[0;33m[WARN] $1\033[0m"; }
err()  { echo -e "    \033[0;31m[ERR] $1\033[0m"; exit 1; }

# ─── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --subscription-id)    SUBSCRIPTION_ID="$2";    shift 2 ;;
    --resource-group)     RESOURCE_GROUP="$2";     shift 2 ;;
    --location)           LOCATION="$2";           shift 2 ;;
    --workspace-name)     WORKSPACE_NAME="$2";     shift 2 ;;
    --freshservice-domain) FS_DOMAIN="$2";         shift 2 ;;
    --freshservice-api-key) FS_API_KEY="$2";       shift 2 ;;
    --requester-email)    REQUESTER_EMAIL="$2";    shift 2 ;;
    --keyvault-name)      KV_NAME="$2";            shift 2 ;;
    --sync-severity)      SYNC_SEVERITY="$2";      shift 2 ;;
    --tag-filter)         TAG_FILTER="$2";         shift 2 ;;
    --polling-interval)   POLLING_INTERVAL="$2";   shift 2 ;;
    --template-base-uri)  TEMPLATE_BASE_URI="$2";  shift 2 ;;
    --help)               usage ;;
    *) err "Unknown option: $1. Run --help for usage." ;;
  esac
done

for v in SUBSCRIPTION_ID RESOURCE_GROUP WORKSPACE_NAME FS_DOMAIN FS_API_KEY KV_NAME REQUESTER_EMAIL; do
  [[ -z "${!v}" ]] && err "Missing required parameter: --$(echo $v | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
done

# ─── 0. Prerequisites ─────────────────────────────────────────────────────────
step "Checking prerequisites"
command -v az >/dev/null || err "Azure CLI not found. Install: https://docs.microsoft.com/cli/azure/install-azure-cli"
az account show >/dev/null 2>&1 || { az login; }
ok "Azure CLI ready"

# ─── 1. Set subscription ──────────────────────────────────────────────────────
step "Setting Azure context"
az account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID=$(az account show --query tenantId -o tsv)
DEPLOYER_OID=$(az ad signed-in-user show --query id -o tsv)
ok "Subscription: $SUBSCRIPTION_ID | Tenant: $TENANT_ID | Deployer: $DEPLOYER_OID"

# ─── 2. Resource group ────────────────────────────────────────────────────────
step "Ensuring resource group: $RESOURCE_GROUP"
if ! az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" >/dev/null
  ok "Resource group created"
else
  ok "Resource group exists"
fi

# ─── 3. Workspace ID ──────────────────────────────────────────────────────────
step "Looking up workspace"
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$WORKSPACE_NAME" \
  --query id -o tsv 2>/dev/null) || err "Workspace '$WORKSPACE_NAME' not found in '$RESOURCE_GROUP'"
ok "Workspace ID: $WORKSPACE_ID"

# ─── 4. App Registration ──────────────────────────────────────────────────────
step "Creating App Registration: $APP_REG_NAME"
CLIENT_ID=$(az ad app list --display-name "$APP_REG_NAME" --query "[0].appId" -o tsv 2>/dev/null)
if [[ -z "$CLIENT_ID" ]]; then
  CLIENT_ID=$(az ad app create \
    --display-name "$APP_REG_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  ok "App Registration created: $CLIENT_ID"
else
  warn "App Registration already exists: $CLIENT_ID"
fi

# Create service principal
if ! az ad sp show --id "$CLIENT_ID" >/dev/null 2>&1; then
  az ad sp create --id "$CLIENT_ID" >/dev/null
  ok "Service Principal created"
  sleep 15
fi

# Create client secret
step "Creating client secret"
CLIENT_SECRET=$(az ad app credential reset \
  --id "$CLIENT_ID" \
  --append \
  --display-name "SentinelFreshserviceSecret" \
  --years 2 \
  --query password -o tsv)
ok "Client secret created"

# ─── 5. Sentinel Responder role ───────────────────────────────────────────────
step "Assigning Microsoft Sentinel Responder role"
SP_OID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv)
RG_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"

if ! az role assignment list --assignee "$SP_OID" --role "Microsoft Sentinel Responder" --scope "$RG_SCOPE" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
  az role assignment create \
    --assignee "$SP_OID" \
    --role "Microsoft Sentinel Responder" \
    --scope "$RG_SCOPE" >/dev/null
  ok "Sentinel Responder role assigned"
else
  warn "Role already assigned"
fi

# ─── 6. Deploy ARM ────────────────────────────────────────────────────────────
step "Deploying ARM solution (3-5 minutes)..."
DEPLOY_OUTPUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-uri "$TEMPLATE_BASE_URI/azuredeploy/orchestrator.json" \
  --parameters \
    location="$LOCATION" \
    workspaceName="$WORKSPACE_NAME" \
    workspaceId="$WORKSPACE_ID" \
    clientId="$CLIENT_ID" \
    clientSecret="$CLIENT_SECRET" \
    freshserviceDomain="$FS_DOMAIN" \
    freshserviceApiKey="$FS_API_KEY" \
    defaultRequesterEmail="$REQUESTER_EMAIL" \
    keyVaultName="$KV_NAME" \
    deployerObjectId="$DEPLOYER_OID" \
    syncOnSeverity="$SYNC_SEVERITY" \
    incidentTagFilter="$TAG_FILTER" \
    pollingIntervalMinutes="$POLLING_INTERVAL" \
  --query "properties.outputs" \
  -o json)

WEBHOOK_URL=$(echo "$DEPLOY_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['webhookReceiverUrl']['value'])")
KV_URI=$(echo "$DEPLOY_OUTPUT"      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['keyVaultUri']['value'])")

echo "$DEPLOY_OUTPUT" > deployment-outputs.json
ok "Deployment succeeded. Outputs saved to deployment-outputs.json"

# ─── 7. Summary ───────────────────────────────────────────────────────────────
cat <<EOF

╔══════════════════════════════════════════════════════════════════╗
║    DEPLOYMENT COMPLETE — POST-DEPLOYMENT STEPS REQUIRED          ║
╚══════════════════════════════════════════════════════════════════╝

✅ Resource Group:    $RESOURCE_GROUP
✅ Key Vault URI:     $KV_URI
✅ App Registration:  $APP_REG_NAME ($CLIENT_ID)

📋 NEXT STEPS:

1. FRESHSERVICE CUSTOM FIELDS (Admin > Ticket Fields):
   Add to Incident type: sentinel_incident_id, sentinel_incident_number,
   sentinel_severity, sentinel_workspace

2. FRESHSERVICE WEBHOOK (Admin > Workflow Automator):
   Event: Ticket Updated | Condition: sentinel_incident_id not empty
   Webhook URL: $WEBHOOK_URL

3. AUTHORIZE API CONNECTIONS:
   Portal > Logic Apps > Sentinel-Freshservice-CreateTicket
   > API connections > azuresentinel > Authorize

4. VERIFY AUTOMATION RULE:
   Sentinel > Automation > 'Create Freshservice Ticket' is Enabled

5. TEST:
   Create a test Sentinel incident, confirm FS ticket appears within 60s

EOF
