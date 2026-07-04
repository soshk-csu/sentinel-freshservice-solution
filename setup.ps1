#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Microsoft Sentinel Solution for Freshservice — Complete Setup Script
    Covers all pre-deployment and post-deployment steps.

.DESCRIPTION
    This script:
      1. Creates an Azure AD App Registration with the correct API permissions
      2. Assigns the Microsoft Sentinel Responder role to the App Registration
      3. Deploys the complete ARM solution (Key Vault + 4 Logic Apps + Automation Rules + Workbook)
      4. Grants Key Vault Secrets User RBAC to all Logic App Managed Identities
      5. Outputs the Freshservice webhook URL for the final manual step

.PARAMETER SubscriptionId       Azure Subscription ID
.PARAMETER ResourceGroupName    Resource group for all resources (created if not exists)
.PARAMETER Location             Azure region (e.g. eastus, westeurope)
.PARAMETER WorkspaceName        Existing Sentinel Log Analytics workspace name
.PARAMETER FreshserviceDomain   e.g. yourcompany.freshservice.com
.PARAMETER FreshserviceApiKey   Freshservice API key
.PARAMETER DefaultRequesterEmail Email for auto-created tickets
.PARAMETER KeyVaultName         Key Vault name (must be globally unique, 3-24 chars)
.PARAMETER SyncOnSeverity       Comma-separated severities, e.g. "High,Medium"
.PARAMETER TemplateBaseUri      Base URI for ARM templates (GitHub raw or Storage Account)

.EXAMPLE
    ./setup.ps1 `
      -SubscriptionId "00000000-0000-0000-0000-000000000000" `
      -ResourceGroupName "rg-sentinel-freshservice" `
      -Location "eastus" `
      -WorkspaceName "my-sentinel-workspace" `
      -FreshserviceDomain "acme.freshservice.com" `
      -FreshserviceApiKey "your-api-key" `
      -DefaultRequesterEmail "soc@acme.com" `
      -KeyVaultName "kv-sentfs-acme"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [Parameter(Mandatory)][string]$FreshserviceDomain,
    [Parameter(Mandatory)][string]$FreshserviceApiKey,
    [Parameter(Mandatory)][string]$DefaultRequesterEmail,
    [Parameter(Mandatory)][string]$KeyVaultName,
    [string]$SyncOnSeverity = "High,Medium",
    [string]$IncidentTagFilter = "",
    [int]$PollingIntervalMinutes = 5,
    [string]$TemplateBaseUri = "https://raw.githubusercontent.com/soshk-csu/sentinel-freshservice-solution/main",
    [string]$AppRegistrationName = "SentinelFreshserviceConnector"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }

# ─── 0. Prerequisites ─────────────────────────────────────────────────────────
Write-Step "Checking prerequisites"
foreach ($cmd in @("az")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required tool '$cmd' not found. Install Azure CLI: https://docs.microsoft.com/cli/azure/install-azure-cli"
    }
}

# ─── 1. Login & set subscription ─────────────────────────────────────────────
Write-Step "Setting Azure context"
az account set --subscription $SubscriptionId | Out-Null
$currentUser = az ad signed-in-user show --query id -o tsv
$tenantId    = az account show --query tenantId -o tsv
Write-OK "Subscription: $SubscriptionId | Tenant: $tenantId | Deployer OID: $currentUser"

# ─── 2. Create / ensure Resource Group ───────────────────────────────────────
Write-Step "Ensuring resource group: $ResourceGroupName"
$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq "false") {
    az group create --name $ResourceGroupName --location $Location | Out-Null
    Write-OK "Resource group created."
} else {
    Write-OK "Resource group already exists."
}

# ─── 3. Get workspace resource ID ─────────────────────────────────────────────
Write-Step "Looking up workspace"
$workspaceId = az monitor log-analytics workspace show `
    --resource-group $ResourceGroupName `
    --workspace-name $WorkspaceName `
    --query id -o tsv 2>$null

if (-not $workspaceId) {
    throw "Workspace '$WorkspaceName' not found in resource group '$ResourceGroupName'. Ensure it exists before running this script."
}
Write-OK "Workspace ID: $workspaceId"

# ─── 4. Create App Registration ───────────────────────────────────────────────
Write-Step "Creating App Registration: $AppRegistrationName"
$existingApp = az ad app list --display-name $AppRegistrationName --query "[0].appId" -o tsv 2>$null
if ($existingApp) {
    Write-Warn "App Registration already exists (appId: $existingApp). Skipping creation."
    $clientId = $existingApp
} else {
    $clientId = az ad app create `
        --display-name $AppRegistrationName `
        --sign-in-audience AzureADMyOrg `
        --query appId -o tsv
    Write-OK "App Registration created. Client ID: $clientId"
}

# Create service principal if not exists
$spExists = az ad sp show --id $clientId --query id -o tsv 2>$null
if (-not $spExists) {
    az ad sp create --id $clientId | Out-Null
    Write-OK "Service Principal created."
    Start-Sleep -Seconds 15  # propagation delay
}

# Create client secret
Write-Step "Creating client secret"
$secretResult = az ad app credential reset `
    --id $clientId `
    --append `
    --display-name "SentinelFreshserviceSecret" `
    --years 2 `
    --query "{secret:password}" `
    -o json | ConvertFrom-Json
$clientSecret = $secretResult.secret
Write-OK "Client secret created (expires in 2 years). Store this safely — it will not be shown again."

# ─── 5. Assign Sentinel Responder role ────────────────────────────────────────
Write-Step "Assigning Microsoft Sentinel Responder role"
$spObjectId = az ad sp show --id $clientId --query id -o tsv
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

$existingRole = az role assignment list `
    --assignee $spObjectId `
    --role "Microsoft Sentinel Responder" `
    --scope $rgScope `
    --query "[0].id" -o tsv 2>$null

if ($existingRole) {
    Write-Warn "Role already assigned. Skipping."
} else {
    az role assignment create `
        --assignee $spObjectId `
        --role "Microsoft Sentinel Responder" `
        --scope $rgScope | Out-Null
    Write-OK "Sentinel Responder role assigned on resource group scope."
}

# ─── 6. Deploy ARM orchestrator ───────────────────────────────────────────────
Write-Step "Deploying ARM solution (this takes 3-5 minutes)..."
$severityArray = $SyncOnSeverity.Split(",") | ForEach-Object { $_.Trim() }

# Use a parameters file rather than inline --parameters key=value pairs.
# On Windows, az.cmd is a batch-file wrapper that re-parses arguments through
# cmd.exe, which strips the inner double-quotes from inline JSON (e.g. an
# array parameter like ["High","Medium"] arrives at ARM as [High,Medium],
# which fails to parse as JSON). A parameters file avoids that entirely.
$armParameters = [ordered]@{
    location                = @{ value = $Location }
    workspaceName            = @{ value = $WorkspaceName }
    workspaceId              = @{ value = $workspaceId }
    clientId                 = @{ value = $clientId }
    clientSecret             = @{ value = $clientSecret }
    freshserviceDomain       = @{ value = $FreshserviceDomain }
    freshserviceApiKey       = @{ value = $FreshserviceApiKey }
    defaultRequesterEmail    = @{ value = $DefaultRequesterEmail }
    keyVaultName             = @{ value = $KeyVaultName }
    deployerObjectId         = @{ value = $currentUser }
    syncOnSeverity           = @{ value = $severityArray }
    incidentTagFilter        = @{ value = $IncidentTagFilter }
    pollingIntervalMinutes   = @{ value = $PollingIntervalMinutes }
}
$armParametersFile = [ordered]@{
    '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters     = $armParameters
}

$paramsFilePath = Join-Path ([System.IO.Path]::GetTempPath()) "sentinel-fs-deploy-params-$(Get-Random).json"
$armParametersFile | ConvertTo-Json -Depth 10 | Set-Content -Path $paramsFilePath -Encoding utf8

try {
    $deployOutput = az deployment group create `
        --resource-group $ResourceGroupName `
        --template-uri "$TemplateBaseUri/azuredeploy/orchestrator.json" `
        --parameters "@$paramsFilePath" `
        --query "properties.outputs" `
        -o json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host $deployOutput -ForegroundColor Red
        throw "ARM deployment failed. See above for details."
    }
} finally {
    Remove-Item -Path $paramsFilePath -ErrorAction SilentlyContinue
}

$outputs = $deployOutput | ConvertFrom-Json
$webhookUrl = $outputs.webhookReceiverUrl.value
$kvUri      = $outputs.keyVaultUri.value

Write-OK "ARM deployment succeeded."

# ─── 7. Enable Sentinel Automation Rules ─────────────────────────────────────
Write-Step "Enabling Sentinel Automation Rules"
Write-Warn "Automation rules require manual consent for the azuresentinel API connection."
Write-Warn "In Azure Portal: Logic Apps > Sentinel-Freshservice-CreateTicket > API Connections > Authorize"

# ─── 8. Output post-deployment instructions ───────────────────────────────────
$summary = @"

╔══════════════════════════════════════════════════════════════════╗
║    DEPLOYMENT COMPLETE — POST-DEPLOYMENT STEPS REQUIRED          ║
╚══════════════════════════════════════════════════════════════════╝

✅ Resources deployed to: $ResourceGroupName
✅ Key Vault URI:          $kvUri
✅ App Registration:       $AppRegistrationName ($clientId)

📋 NEXT STEPS (required to complete setup):

1. FRESHSERVICE CUSTOM FIELDS (if not done):
   Admin > Ticket Fields > Add these 4 fields to Incident type:
     - sentinel_incident_id    (Single line text)
     - sentinel_incident_number (Number)
     - sentinel_severity        (Single line text)
     - sentinel_workspace       (Single line text)

2. FRESHSERVICE WEBHOOK AUTOMATOR:
   Admin > Workflow Automator > New Rule:
     Event: Ticket Updated
     Condition: sentinel_incident_id is not empty
     Action: Trigger Webhook
     URL: $webhookUrl
     Method: POST, Content-Type: application/json
     Body: (see README for full payload template)

3. AUTHORIZE API CONNECTION IN AZURE PORTAL:
   Portal > Logic Apps > Sentinel-Freshservice-CreateTicket
   > API connections > azuresentinel-* > Edit > Authorize
   (repeat for SyncComments Logic App)

4. VERIFY SENTINEL AUTOMATION RULE:
   Sentinel > Automation > confirm rule 'Create Freshservice Ticket' is Enabled

5. TEST THE INTEGRATION:
   Sentinel > Incidents > Create test incident manually
   Verify Freshservice ticket is created within 60 seconds
   Resolve the FS ticket and verify Sentinel incident closes

🔐 SECURITY REMINDER:
   The client secret created during this script is stored in Key Vault.
   Set a calendar reminder to rotate it before expiry (2 years from now).

"@

Write-Host $summary -ForegroundColor White

# Save outputs to file
$outputs | ConvertTo-Json -Depth 5 | Out-File "deployment-outputs.json"
Write-OK "Full deployment outputs saved to: deployment-outputs.json"
