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
| Playbook 3 | `Freshservice-Sentinel-WebhookReceiver` | Receives FS webhook and updates/closes Sentinel incident |
| Playbook 4 | `Sentinel-Freshservice-SyncComments` | Syncs comments/notes in both directions every 10 min |
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

1. Go to **Admin → Ticket Fields** (under Service Management)
2. Add the following fields:

| Field Label | Field Name (API) | Type | Description |
|-------------|-----------------|------|-------------|
| Sentinel Incident ID | `sentinel_incident_id` | Single line text | Azure resource ID of the Sentinel incident |
| Sentinel Incident # | `sentinel_incident_number` | Number | Human-readable incident number |
| Sentinel Severity | `sentinel_severity` | Single line text | High / Medium / Low / Informational |
| Sentinel Workspace | `sentinel_workspace` | Single line text | Name of the Sentinel workspace |

> Note the exact API field names — they must match the `custom_fields` keys in the Logic App payloads.

---

## Step 3: Configure the Freshservice Webhook

Set up an automation rule in Freshservice to call back to the Logic App whenever a ticket status changes.

1. Go to **Admin → Workflow Automator** (or **Supervisor Rules**)
2. Create a new rule:
   - **Event:** Ticket Updated
   - **Condition:** Custom field `sentinel_incident_id` is not empty
   - **Action:** Trigger Webhook
     - **Request type:** POST
     - **URL:** *(paste the webhook URL from Step 5 output)*
     - **Content type:** application/json
     - **Encoding:** JSON
     - **Content:**
       ```json
       {
         "freshdesk_webhook": {
           "ticket_id": "{{ticket.id}}",
           "ticket_status": "{{ticket.status}}",
           "ticket_resolution_notes": "{{ticket.resolution_notes}}",
           "ticket_cf_sentinel_incident_id": "{{ticket.cf.sentinel_incident_id}}",
           "ticket_cf_sentinel_incident_number": "{{ticket.cf.sentinel_incident_number}}",
           "ticket_responder_email": "{{ticket.agent.email}}"
         }
       }
       ```
3. Save the rule and set it to **Active**

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

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fyour-org%2Fsentinel-freshservice%2Fmain%2Fazuredeploy%2FmainTemplate.json)

### Option B — Azure CLI

```bash
# Clone the solution
git clone https://github.com/your-org/sentinel-freshservice-solution.git
cd sentinel-freshservice-solution

# Edit parameters
cp azuredeploy/mainTemplate.parameters.json azuredeploy/myparams.json
# Edit myparams.json with your values

# Deploy
az deployment group create \
  --resource-group YOUR-RESOURCE-GROUP \
  --template-file azuredeploy/mainTemplate.json \
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
  --trigger-name HTTP_Webhook_from_Freshservice
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

| Freshservice Status | Sentinel Incident Status |
|---------------------|--------------------------|
| Resolved (4) | Closed (TruePositive) |
| Closed (5) | Closed (TruePositive) |
| In Progress (3) | Comment added |
| Pending (6) | Comment added |

---

## Limitations

- Solution works per Sentinel workspace; multi-workspace requires separate deployments
- Freshservice domain separation is not supported (single instance only)
- Logic Apps Consumption plan has a 90-day run history limit
- Comment sync is polling-based (10 min latency); not real-time
- Attachment sync is not supported in this version

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Ticket not created | Automation rule not triggered | Check Sentinel Automation rules are enabled |
| 401 on Freshservice API | API key wrong or expired | Verify Key Vault secret value |
| 401 on Sentinel API | Client secret expired | Rotate App Registration secret, update Key Vault |
| Sentinel not closing | Webhook URL wrong in FS | Re-run Step 8 and update Freshservice automator |
| Duplicate tickets | Poller + trigger both firing | Add tag condition to Automation Rule or disable poller |
| `sentinel_incident_id` missing | Custom fields not created | Complete Step 2 |

---

## Contributing

Issues and pull requests welcome at [github.com/your-org/sentinel-freshservice-solution](https://github.com/your-org/sentinel-freshservice-solution).

## License

MIT License — see LICENSE file.
