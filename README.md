# Microsoft Sentinel Solution for Freshservice — Bidirectional Sync

> A Microsoft Sentinel Content Hub solution providing full bidirectional incident ↔ ticket synchronization between Microsoft Sentinel and Freshservice ITSM, modelled after the [Microsoft Sentinel Solution for ServiceNow](https://techcommunity.microsoft.com/blog/microsoftsentinelblog/whats-new-introducing-microsoft-sentinel-solution-for-servicenow-bi-directional-/3692840).

---

## Overview

This solution enables SOC teams using Freshservice as their ITSM to:

- Automatically create Freshservice tickets when Sentinel incidents are created
- Enrich tickets with full entity context (Host, IP, User, URL, Process)
- Map Sentinel severity to Freshservice priority
- Automatically close Sentinel incidents when Freshservice tickets are resolved
- Sync comments bidirectionally between both platforms
- Monitor sync health via a dedicated Workbook

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Microsoft Sentinel                          │
│  Incident Created/Updated ──► Automation Rule ──► Playbook 1   │
│                                                        │        │
│  Incident Updated ◄── PATCH API ◄── Logic App 4       │        │
│  (status, comment)                                     ▼        │
└────────────────────────────────────────────────────────────────-┘
         ▲                                        │
         │                               POST /api/v2/tickets
   Webhook callback                              │
  (status change)                               ▼
         │                         ┌────────────────────────┐
         └──────── Logic App 3 ◄── │    Freshservice ITSM   │
                                   │  Ticket created/updated│
                                   │  Webhook triggered on  │
                                   │  status change         │
                                   └────────────────────────┘
                 Logic App 2 (Poller, every 5 min) fills gaps
```

### Components

| Component | Name | Purpose |
|-----------|------|---------|
| Playbook 1 | `Sentinel-Freshservice-CreateTicket` | Event-driven: creates FS ticket on incident creation |
| Playbook 2 | `Sentinel-Freshservice-IncidentPoller` | Schedule-driven: polls Sentinel every 5 min for missed incidents |
| Playbook 3 | `Freshservice-Sentinel-WebhookReceiver` | Receives FS webhooks (status change and note-added), authenticated via Basic Auth against `FreshserviceWebhookSecret`. Updates/closes the Sentinel incident, or mirrors a new FS note as a Sentinel comment |
| Playbook 4 | `Sentinel-Freshservice-SyncComments` | Schedule-driven (`commentSyncIntervalMinutes`, default 10 min): polls Sentinel comments on FS-linked incidents and mirrors new ones as FS ticket notes |
| Workbook | `FreshserviceSyncStatus` | Monitors sync coverage, rates, and closure source |

---

## Prerequisites

### Azure Prerequisites
- Microsoft Sentinel workspace (Log Analytics)
- Azure Key Vault (for secret storage)
- Azure AD App Registration with `Microsoft Sentinel Responder` role

### Freshservice Prerequisites
- Freshservice account with API access
- Admin access to configure webhooks
- Custom fields added to the Incident ticket type (see below)

---

## Step 1: Create the Azure AD App Registration

This grants the Logic Apps permission to call the Sentinel Management API.

1. Navigate to **Azure Portal → Azure Active Directory → App registrations**
2. Click **New registration**
   - Name: `SentinelFreshserviceConnector`
   - Supported account types: *Single tenant*
   - Click **Register**
3. Note the **Application (client) ID** and **Directory (tenant) ID**
4. Go to **Certificates & secrets → New client secret**
   - Description: `SentinelFreshserviceSecret`
   - Expiry: 24 months (recommended)
   - **Copy the secret value immediately** — it won't be shown again

### Assign the Sentinel Responder Role

1. In the Azure portal, navigate to the **Resource Group** containing your Sentinel workspace
2. Click **Access control (IAM) → Add role assignment**
3. Role: **Microsoft Sentinel Responder**
4. Assign access to: *User, group, or service principal*
5. Select the `SentinelFreshserviceConnector` app registration
6. Click **Save**

> ⚠️ Assign the role on the **Resource Group** (or the workspace itself), not the subscription. Least-privilege: Responder can read and update incidents without broader Azure access.

---

## Step 2: Configure Freshservice Custom Fields

Add the following custom fields to the **Incident** ticket type in Freshservice:

1. Go to **Admin → Global Settings → Service Management → Field Manager → Ticket Fields**
   (if you don't see this, your Admin role needs the **"Manage Fields and Tags"** permission enabled; if your
   account uses Workspaces, ticket fields are configured per-workspace and the workspace must be fully set up and
   published first)
2. Add the following fields:

| Field Label | Field Name (API) | Type | Description |
|-------------|-----------------|------|-------------|
| Sentinel Incident ID | `sentinel_incident_id` | Single line text | Azure resource ID of the Sentinel incident |
| Sentinel Incident # | `sentinel_incident` | Number | Human-readable incident number |
| Sentinel Severity | `sentinel_severity` | Single line text | High / Medium / Low / Informational |
| Sentinel Workspace | `sentinel_workspace` | Single line text | Name of the Sentinel workspace |

> **Don't assume the API field name matches the label you typed.** Freshservice auto-generates the internal
> `name` from the label and silently strips characters that aren't valid in an identifier — e.g. the label
> "Sentinel Incident #" generates the internal name `sentinel_incident` (the `#` is dropped), **not**
> `sentinel_incident_number`. This isn't hypothetical — it's exactly what happened during testing. After creating
> all 4 fields, confirm the real generated names before deploying anything:
> ```powershell
> $domain = "yourcompany.freshservice.com"
> $apiKey = "your-api-key"
> $cred = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${apiKey}:X"))
> $response = Invoke-RestMethod -Uri "https://$domain/api/v2/ticket_form_fields" -Headers @{ Authorization = "Basic $cred" }
> $response.ticket_fields | Where-Object { $_.label -like "*Sentinel*" } | Select-Object name, label, type
> ```
> If any generated name doesn't match the table above, either fix the field's label and re-check (deleting and
> recreating the field changes its internal name — editing the label alone does not), or update the `cf_...`
> references throughout the playbooks and `metadata/FreshserviceConfig.json` to match what's actually there.

---

## Step 3: Configure the Freshservice Webhooks

Set up **two** Workflow Automator rules in Freshservice so both status changes and new notes call back to
`Freshservice-Sentinel-WebhookReceiver`. The complete, ready-to-copy rule bodies live in
[`metadata/FreshserviceConfig.json`](metadata/FreshserviceConfig.json) under `automator_rules` — use those verbatim
rather than retyping them, since the playbook's trigger schema is written to match those payloads exactly (including
`ticket_responder_name`, `ticket_priority`, `ticket_subject`, and `ticket_url`, which a shorter hand-written payload
would omit).

1. Go to **Admin → Workflow Automator**
2. Create rule 1 — **"Sentinel Connector — Ticket Status to Sentinel"**:
   - **Event:** Ticket Updated
   - **Condition:** Custom field `sentinel_incident_id` is not empty
   - **Action:** Trigger Webhook → POST → *(webhook URL from Step 5/8 output)* → JSON body from
     `metadata/FreshserviceConfig.json` → `automator_rules[0].actions[0].config.body`
   - **Requires Authentication:** enabled, Basic Auth, username = `freshservice-webhook` (or whatever you set
     `WebhookAuthUsername` to), password = the `FreshserviceWebhookSecret` value from Key Vault
3. Create rule 2 — **"Sentinel Connector — New Note to Sentinel Comment"**:
   - **Event:** Note Added, **Condition:** `sentinel_incident_id` is not empty AND note is public
   - **Action:** same webhook URL and auth as rule 1, JSON body from `automator_rules[1].actions[0].config.body`
4. Save both rules and set them to **Active**

> **Verify before relying on auto-close:** it isn't confirmed whether `{{ticket.status}}` renders as text
> ("Resolved") or the numeric status code ("4") in your tenant. `Freshservice-Sentinel-WebhookReceiver` matches both
> forms (see `Normalize_FS_Status`), but you should still trigger a real status change during Step 8 testing and
> confirm in the Logic App run history that `canonicalStatus` resolves to the expected value rather than `other`.

---

## Step 4: Store Secrets in Key Vault

Store all sensitive values in Azure Key Vault before deploying.

```bash
# Set the Key Vault name
KV_NAME="your-key-vault-name"

# Store Freshservice API key
az keyvault secret set \
  --vault-name $KV_NAME \
  --name "FreshserviceApiKey" \
  --value "YOUR_FRESHSERVICE_API_KEY"

# Store Azure AD client secret
az keyvault secret set \
  --vault-name $KV_NAME \
  --name "SentinelClientSecret" \
  --value "YOUR_CLIENT_SECRET"
```

Grant the Logic Apps managed identities access after deployment (Step 6).

---

## Step 5: Deploy the Solution

### Option A — Azure Portal (One-click deploy)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsoshk-csu%2Fsentinel-freshservice-solution%2Fmain%2Fazuredeploy%2Forchestrator.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fsoshk-csu%2Fsentinel-freshservice-solution%2Fmain%2Fazuredeploy%2FcreateUiDefinition.json)

> The portal wizard (`createUiDefinition.json`) cannot look up your signed-in user's Object ID, so the Key Vault
> Administrator role isn't auto-assigned to you when deploying this way. Grant yourself **Key Vault Secrets Officer**
> (or Administrator) on the created vault afterward if you need to inspect secrets from the portal.

### Option B — Azure CLI

```bash
# Clone the solution
git clone https://github.com/soshk-csu/sentinel-freshservice-solution.git
cd sentinel-freshservice-solution

# Edit parameters
cp azuredeploy/orchestrator.parameters.json azuredeploy/myparams.json
# Edit myparams.json with your values, including deployerObjectId (az ad signed-in-user show --query id -o tsv)

# Deploy
az deployment group create \
  --resource-group YOUR-RESOURCE-GROUP \
  --template-file azuredeploy/orchestrator.json \
  --parameters @azuredeploy/myparams.json
```

### Option C — Sentinel Content Hub

1. In Microsoft Sentinel, go to **Content Hub**
2. Search for **"Freshservice"**
3. Select the solution and click **Install**
4. Follow the configuration wizard

---

## Step 6: Grant Key Vault Access to Logic App Managed Identities

After deployment, each Logic App has a System Assigned Managed Identity. Grant them Key Vault secret read access.

```bash
# Get the Logic App principal IDs (repeat for each playbook)
PRINCIPAL_ID=$(az logic workflow show \
  --resource-group YOUR-RG \
  --name Sentinel-Freshservice-CreateTicket \
  --query identity.principalId -o tsv)

# Grant Key Vault Secrets User role
az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee $PRINCIPAL_ID \
  --scope /subscriptions/YOUR-SUB/resourceGroups/YOUR-RG/providers/Microsoft.KeyVault/vaults/YOUR-KV
```

Repeat for all four Logic App playbooks.

---

## Step 7: Configure Sentinel Automation Rules

Link the trigger playbook to Sentinel's automation engine.

1. In Microsoft Sentinel, go to **Configuration → Automation**
2. Click **Create → Automation rule**
3. Configure:
   - **Name:** `Create Freshservice Ticket`
   - **Trigger:** When incident is created
   - **Conditions:** *(optional)* Severity equals High, Medium
   - **Actions:** Run playbook → `Sentinel-Freshservice-CreateTicket`
4. Click **Apply**

> Optionally add a tag filter condition: `Incident tags contains 'freshservice'` to only sync tagged incidents (matching the `sentinelIncidentTag` parameter).

---

## Step 8: Get the Webhook URL and Update Freshservice

After deployment, retrieve the webhook receiver URL:

```bash
# Get the webhook callback URL
az logic workflow trigger list-callback-url \
  --resource-group YOUR-RG \
  --workflow-name Freshservice-Sentinel-WebhookReceiver \
  --trigger-name HTTP_Webhook_Freshservice
```

Copy the `value` URL and paste it into the Freshservice Workflow Automator webhook action from Step 3.

---

## Severity / Priority Mapping

| Sentinel Severity | Freshservice Priority |
|-------------------|----------------------|
| High | 2 — Urgent |
| Medium | 3 — High |
| Low | 4 — Medium |
| Informational | 4 — Medium |

## Status Mapping (Freshservice → Sentinel)

Matches `metadata/FreshserviceConfig.json`'s `fs_status_to_sentinel_status` table. The webhook receiver's
`Normalize_FS_Status` step matches either the numeric code or the text label for each row.

| Freshservice Status | Sentinel Incident Status |
|---------------------|--------------------------|
| Resolved (4) | Closed (TruePositive) |
| Closed (5) | Closed (TruePositive) |
| Pending (3) | Comment added |
| In Progress (6) | Comment added + owner synced |

---

## Limitations

- Solution works per Sentinel workspace; multi-workspace requires separate deployments
- Freshservice domain separation is not supported (single instance only)
- Logic Apps Consumption plan has a 90-day run history limit
- Freshservice → Sentinel comment sync is event-driven (near real-time, via the `note_added` webhook rule).
  Sentinel → Freshservice comment sync is polling-based (`commentSyncIntervalMinutes`, default 10 min)
- Attachment sync is not supported in this version

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Ticket not created | Automation rule not triggered | Check Sentinel Automation rules are enabled |
| 401 on Freshservice API | API key wrong or expired | Verify Key Vault secret value |
| 401 on Sentinel API | Client secret expired | Rotate App Registration secret, update Key Vault |
| 401 from the webhook receiver itself | Freshservice webhook auth doesn't match `FreshserviceWebhookSecret` | Re-check the "Requires Authentication" username/password on both automator rules against the Key Vault secret |
| Sentinel not closing | Webhook URL wrong in FS, or `canonicalStatus` resolves to `other` | Re-run Step 8, update the automator webhook URL, and check the Logic App run history for the resolved `canonicalStatus` value |
| Duplicate tickets | Poller and event-driven trigger both firing before the first ticket's tag propagates | Both playbooks now dedup by the `sentinel-inc-<number>` tag before creating; if it still happens, increase `pollingIntervalMinutes` or disable the poller |
| `sentinel_incident_id` missing | Custom fields not created | Complete Step 2 |

---

## Contributing

Issues and pull requests welcome at [github.com/soshk-csu/sentinel-freshservice-solution](https://github.com/soshk-csu/sentinel-freshservice-solution).

## License

MIT License — see LICENSE file.
