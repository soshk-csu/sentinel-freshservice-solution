#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Verify and test the Sentinel-Freshservice connector deployment.
    Run after setup.ps1 completes and all post-deployment steps are done.
#>
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [Parameter(Mandatory)][string]$FreshserviceDomain,
    [Parameter(Mandatory)][string]$FreshserviceApiKey,
    [Parameter(Mandatory)][string]$WebhookReceiverUrl,
    [switch]$CreateTestIncident
)

$ErrorActionPreference = "Stop"
function step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function ok   { param([string]$m) Write-Host "    ✅ $m" -ForegroundColor Green }
function fail { param([string]$m) Write-Host "    ❌ $m" -ForegroundColor Red }
function warn { param([string]$m) Write-Host "    ⚠️  $m" -ForegroundColor Yellow }

$Results = @{ Passed = 0; Failed = 0; Warnings = 0 }
function Check {
    param([bool]$condition, [string]$pass, [string]$failMsg)
    if ($condition) { ok $pass; $Results.Passed++ }
    else { fail $failMsg; $Results.Failed++ }
}

az account set --subscription $SubscriptionId

# ─── 1. Logic Apps deployed ───────────────────────────────────────────────────
step "Checking Logic App deployments"
$playbookNames = @(
    "Sentinel-Freshservice-CreateTicket",
    "Freshservice-Sentinel-WebhookReceiver",
    "Sentinel-Freshservice-IncidentPoller",
    "Sentinel-Freshservice-SyncComments"
)
foreach ($name in $playbookNames) {
    $state = az logic workflow show `
        --resource-group $ResourceGroupName `
        --name $name `
        --query "state" -o tsv 2>$null
    Check ($state -eq "Enabled") "$name is Enabled" "$name state: $state (expected Enabled)"
}

# ─── 2. Managed Identities assigned ──────────────────────────────────────────
step "Checking Managed Identities"
foreach ($name in $playbookNames) {
    $identityType = az logic workflow show `
        --resource-group $ResourceGroupName `
        --name $name `
        --query "identity.type" -o tsv 2>$null
    Check ($identityType -eq "SystemAssigned") "$name has SystemAssigned identity" "$name has no managed identity"
}

# ─── 3. Key Vault accessible ──────────────────────────────────────────────────
step "Checking Key Vault"
$kvList = az keyvault list `
    --resource-group $ResourceGroupName `
    --query "[].name" -o tsv 2>$null
Check (-not [string]::IsNullOrEmpty($kvList)) "Key Vault found: $kvList" "No Key Vault found in resource group"

# Check secrets exist
foreach ($secret in @("FreshserviceApiKey", "SentinelClientSecret", "FreshserviceWebhookSecret")) {
    $secretValue = az keyvault secret show `
        --vault-name $kvList `
        --name $secret `
        --query "value" -o tsv 2>$null
    Check (-not [string]::IsNullOrEmpty($secretValue)) "Secret '$secret' exists in Key Vault" "Secret '$secret' missing from Key Vault"
}

# ─── 4. Automation Rules active ───────────────────────────────────────────────
step "Checking Sentinel Automation Rules"
$rules = az rest `
    --method GET `
    --url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/providers/Microsoft.SecurityInsights/automationRules?api-version=2023-11-01" `
    --query "value[?contains(properties.displayName, 'Freshservice')]" `
    -o json 2>$null | ConvertFrom-Json

Check ($rules.Count -gt 0) "$($rules.Count) Freshservice automation rule(s) found" "No Freshservice automation rules found in Sentinel"
foreach ($rule in $rules) {
    $enabled = $rule.properties.triggeringLogic.isEnabled
    Check $enabled "Rule '$($rule.properties.displayName)' is enabled" "Rule '$($rule.properties.displayName)' is DISABLED"
}

# ─── 5. Freshservice API connectivity ─────────────────────────────────────────
step "Testing Freshservice API connectivity"
try {
    $credentials = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${FreshserviceApiKey}:X"))
    $response = Invoke-RestMethod `
        -Uri "https://$FreshserviceDomain/api/v2/tickets?per_page=1" `
        -Headers @{ Authorization = "Basic $credentials" } `
        -Method GET
    Check $true "Freshservice API accessible (found $($response.tickets.Count) ticket in test query)" ""
} catch {
    fail "Cannot reach Freshservice API: $($_.Exception.Message)"
    $Results.Failed++
}

# ─── 6. Custom fields exist ───────────────────────────────────────────────────
step "Checking Freshservice custom fields"
try {
    $credentials = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${FreshserviceApiKey}:X"))
    $fields = Invoke-RestMethod `
        -Uri "https://$FreshserviceDomain/api/v2/ticket_form_fields" `
        -Headers @{ Authorization = "Basic $credentials" } `
        -Method GET
    $fieldNames = $fields.ticket_fields | Select-Object -ExpandProperty name
    foreach ($cf in @("sentinel_incident_id", "sentinel_incident", "sentinel_severity", "sentinel_workspace")) {
        Check ($cf -in $fieldNames) "Custom field '$cf' exists" "Custom field '$cf' MISSING or misnamed — check Admin > Global Settings > Service Management > Field Manager > Ticket Fields (Freshservice generates the internal name from the label and strips invalid characters, so it may not match what you typed)"
    }
} catch {
    warn "Could not verify custom fields: $($_.Exception.Message)"
    $Results.Warnings++
}

# ─── 7. Webhook endpoint live ─────────────────────────────────────────────────
step "Testing webhook receiver endpoint"
try {
    $testPayload = @{
        freshdesk_webhook = @{
            ticket_id = 99999
            ticket_status = "Open"
            ticket_cf_sentinel_incident_id = ""
        }
    } | ConvertTo-Json -Depth 3

    $webhookResponse = Invoke-RestMethod `
        -Uri $WebhookReceiverUrl `
        -Method POST `
        -ContentType "application/json" `
        -Body $testPayload `
        -StatusCodeVariable statusCode 2>$null
    # We expect a 400 since sentinel_incident_id is empty — that means the Logic App ran
    Check ($statusCode -in @(200, 400)) "Webhook receiver is live (status: $statusCode)" "Webhook receiver did not respond"
} catch {
    # A 400 from the Logic App is still a success (it means it's running)
    if ($_.Exception.Response.StatusCode.value__ -eq 400) {
        ok "Webhook receiver is live (returned 400 — expected for empty incident ID test)"
        $Results.Passed++
    } else {
        fail "Webhook receiver error: $($_.Exception.Message)"
        $Results.Failed++
    }
}

# ─── 8. End-to-end test ───────────────────────────────────────────────────────
if ($CreateTestIncident) {
    step "Creating test Sentinel incident for end-to-end validation"
    warn "This will create a real incident in Sentinel and a real ticket in Freshservice."
    warn "It will be tagged as a test and should be deleted after verification."

    $testIncidentBody = @{
        properties = @{
            title = "[TEST] Sentinel-Freshservice Connector Validation"
            description = "This is an automated test incident created by the connector verification script. Please delete after validation."
            severity = "Low"
            status = "New"
            labels = @(@{ labelName = "connector-test" })
        }
    } | ConvertTo-Json -Depth 5

    $token = (az account get-access-token --resource "https://management.azure.com" | ConvertFrom-Json).accessToken
    $incidentId = [System.Guid]::NewGuid().ToString()
    $incidentUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/providers/Microsoft.SecurityInsights/incidents/${incidentId}?api-version=2023-11-01"

    $incident = Invoke-RestMethod -Method PUT -Uri $incidentUrl `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body $testIncidentBody

    ok "Test incident created: $($incident.properties.incidentNumber)"
    Write-Host "    Waiting 90 seconds for automation to create Freshservice ticket..." -ForegroundColor Gray
    Start-Sleep -Seconds 90

    # Check for FS ticket
    $credentials = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${FreshserviceApiKey}:X"))
    $tickets = Invoke-RestMethod `
        -Uri "https://$FreshserviceDomain/api/v2/tickets?type=Incident&tag=sentinel-inc-$($incident.properties.incidentNumber)" `
        -Headers @{ Authorization = "Basic $credentials" } `
        -Method GET

    Check ($tickets.tickets.Count -gt 0) `
        "End-to-end test PASSED: FS ticket created (ID: $($tickets.tickets[0].id))" `
        "End-to-end test FAILED: No Freshservice ticket found for test incident after 90s"

    # Clean up test incident
    Invoke-RestMethod -Method PATCH -Uri $incidentUrl `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body '{"properties":{"status":"Closed","classification":"Undetermined","classificationComment":"Test incident — automated cleanup by verify script"}}' | Out-Null
    ok "Test Sentinel incident closed"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host "`n════════════════════════════════════════" -ForegroundColor White
Write-Host "  Verification Results" -ForegroundColor White
Write-Host "════════════════════════════════════════" -ForegroundColor White
Write-Host "  ✅ Passed:   $($Results.Passed)" -ForegroundColor Green
Write-Host "  ❌ Failed:   $($Results.Failed)" -ForegroundColor Red
Write-Host "  ⚠️  Warnings: $($Results.Warnings)" -ForegroundColor Yellow
Write-Host "════════════════════════════════════════`n" -ForegroundColor White

if ($Results.Failed -gt 0) {
    Write-Host "One or more checks failed. Review errors above and consult the Troubleshooting section in README.md." -ForegroundColor Red
    exit 1
} else {
    Write-Host "All checks passed. Connector is ready." -ForegroundColor Green
}
