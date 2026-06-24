# WhatsApp Integration for Salesforce

Salesforce-native integration with the **Meta WhatsApp Cloud API**. Supports inbound webhooks, outbound messaging from Lightning, real-time chat UI (CDC), media handling, and CRM phone matching on Account, Contact, and Lead.

This repository is a **standalone extract** of the WhatsApp integration from the Lanka Tiles project. Deploy it into any Salesforce org that has standard Account, Contact, and Lead objects.

---

## Table of contents

1. [Architecture overview](#architecture-overview)
2. [Data model](#data-model)
3. [Inbound flow (Meta → Salesforce)](#inbound-flow-meta--salesforce)
4. [Outbound flow (Salesforce → Meta)](#outbound-flow-salesforce--meta)
5. [Real-time chat UI](#real-time-chat-ui)
6. [Repository contents](#repository-contents)
7. [Prerequisites](#prerequisites)
8. [Post-deploy configuration](#post-deploy-configuration)
9. [Deploy](#deploy)
10. [Testing](#testing)
11. [Troubleshooting](#troubleshooting)

---

## Architecture overview

```text
                         ┌─────────────────────────────────────┐
                         │           Meta WhatsApp Cloud        │
                         │   (Graph API + Webhook callbacks)    │
                         └──────────────┬──────────────────────┘
                                        │
          Inbound POST/GET              │              Outbound POST
          (webhook verify + messages)   │              (send messages)
                                        │
                         ┌──────────────▼──────────────────────┐
                         │   Salesforce Experience Cloud Site   │
                         │   /services/apexrest/whatsapp/...    │
                         │   (Site Guest User)                  │
                         └──────────────┬──────────────────────┘
                                        │
                         ┌──────────────▼──────────────────────┐
                         │      WhatsAppWebhookService          │
                         │  WhatsAppMessageService              │
                         │  WhatsAppMediaService                │
                         └──────────────┬──────────────────────┘
                                        │
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
   WhatsApp_Contact__c          WhatsApp_Message__c         ContentVersion
   (phone + CRM match)         (inbound/outbound thread)    (media files)
              │                         │
              └─────────────┬───────────┘
                            │
              ┌─────────────▼───────────┐
              │   whatsappChat LWC        │
              │   (CDC live refresh)      │
              │   on Account/Contact/Lead │
              └───────────────────────────┘
```

| Layer | Responsibility |
|-------|----------------|
| **Site + REST** | Public HTTPS endpoint for Meta webhook verification and inbound payloads |
| **Apex services** | Parse Meta JSON, upsert contacts, create messages, download media, call Graph API |
| **Custom objects** | Persist threads and messages |
| **LWC** | Agent chat UI on CRM record pages |
| **CDC** | Push message changes to the UI without polling |

---

## Data model

### `WhatsApp_Contact__c`

One row per WhatsApp phone number (normalized to last 10 digits).

| Field | Purpose |
|-------|---------|
| `Phone__c` | Normalized WhatsApp number (unique key for matching) |
| `Account__c` / `Contact__c` / `Lead__c` | CRM record matched by phone (trigger) |
| `Matched_Record_Type__c` | Account, Contact, Lead, or Unmatched |
| `Unread_Count__c` | Inbound messages not yet read in UI |
| `Last_Message_Date__c` | Latest activity timestamp |
| `Is_Active__c` | Active thread flag |

### `WhatsApp_Message__c` (Master-Detail → Contact)

| Field | Purpose |
|-------|---------|
| `Direction__c` | Inbound / Outbound |
| `Message_Type__c` | Text, Image, File, Audio, Video, etc. |
| `Message_Body__c` | Text or caption |
| `Media_URL__c` | **ContentDocument Id** (`069…`) for files shown in chat |
| `WhatsApp_Message_Id__c` | Meta message id (idempotency + status updates) |
| `Status__c` | Pending, Sent, Delivered, Read, Failed |
| `Sent_At__c` | Message timestamp |

### `WhatsApp_Config__mdt` (record: **Default**)

| Field | Purpose |
|-------|---------|
| `Phone_Number_Id__c` | Meta WhatsApp phone number id |
| `Verify_Token__c` | Meta **API access token** (Bearer) for outbound + media download |
| `Webhook_Verify_Token__c` | Optional; webhook verify token is hardcoded in Apex today |

---

## Inbound flow (Meta → Salesforce)

1. Customer sends WhatsApp message to your business number.
2. Meta **POST**s JSON to your Site URL:
   `https://<org>--<sandbox>.sandbox.my.salesforce-sites.com/services/apexrest/whatsapp/webhook`
3. `WhatsAppWebhookService.handleInbound()` parses the payload.
4. Phone is extracted from `messages[].from` or `contacts[].wa_id`.
5. `WhatsAppMessageService.upsertWhatsAppContact()` finds or creates `WhatsApp_Contact__c` (uses `without sharing` so Site Guest can see contacts created by internal users).
6. For **images/documents**:
   - `WhatsAppMediaService` downloads from Meta Graph API
   - Stores `ContentVersion` + `ContentDocumentLink` on the contact
   - Saves ContentDocument Id in `Media_URL__c`
   - If sync download fails, `WhatsAppInboundMediaQueueable` retries asynchronously
7. `WhatsAppMessageService.createInboundMessage()` inserts `WhatsApp_Message__c`.
8. **CDC** notifies the `whatsappChat` LWC to refresh.

### Webhook verification (one-time, Meta setup)

Meta sends **GET** with `hub.mode=subscribe`, `hub.verify_token`, `hub.challenge`.

Apex returns the challenge string when the verify token matches `LankaTiles_WA_Webhook_2024` (constant in `WhatsAppWebhookService`).

---

## Outbound flow (Salesforce → Meta)

1. Agent uses **whatsappChat** LWC on Account, Contact, or Lead.
2. `WhatsAppChatController.sendChatPayload()` resolves phone and enqueues work.
3. A **Pending** `WhatsApp_Message__c` row is inserted immediately (CDC shows the bubble).
4. `WhatsAppOutboundQueueable` runs asynchronously (allows DML + callout):
   - Calls Meta Graph API via Named Credential `callout:WhatsApp_Meta`
   - Updates message to **Sent** (or **Failed**)
5. Meta status webhooks update Delivered / Read via `processStatuses()`.

### Media outbound

- File is uploaded as `ContentVersion`
- Public link via `ContentDistribution`
- Sent to Meta as `image` or `document` with link
- `Media_URL__c` stores ContentDocument Id for in-app preview

---

## Real-time chat UI

**Component:** `whatsappChat` (LWC)

| Mechanism | When |
|-----------|------|
| `@wire(getChatThread)` | Initial load on record page (cacheable) |
| **Change Data Capture** | `/data/WhatsApp_Message__ChangeEvent` |
| `refreshApex()` | After CDC event (debounced 300 ms) |

No background polling. UI updates when message records are inserted or updated.

**Place the component** on Lightning record pages for Account, Contact, Lead, or `WhatsApp_Contact__c`.

---

## Repository contents

```text
force-app/main/default/
├── classes/
│   ├── WhatsAppWebhookService.cls          # Inbound REST webhook
│   ├── WhatsAppMessageService.cls          # Contact/message CRUD
│   ├── WhatsAppOutboundService.cls         # Meta send API
│   ├── WhatsAppOutboundQueueable.cls       # Async outbound callouts
│   ├── WhatsAppMediaService.cls            # Inbound media download
│   ├── WhatsAppInboundMediaQueueable.cls   # Async media retry
│   ├── WhatsAppChatController.cls          # LWC Apex API
│   ├── WhatsAppCampaignController.cls      # Campaign template bulk send
│   ├── WhatsAppContactTriggerHandler.cls   # Phone → CRM matching
│   └── WhatsAppWebhookWrapper.cls          # DTO (legacy/helper)
├── triggers/
│   └── WhatAppContactTrigger.trigger
├── lwc/
│   ├── whatsappChat/                       # Main chat UI
│   └── whatsAppCampaignSender/             # Template sender (needs controller)
├── objects/
│   ├── WhatsApp_Contact__c/
│   ├── WhatsApp_Message__c/
│   ├── WhatsApp_Config__mdt/
│   └── WhatsApp_Webhook_Config__mdt/
├── permissionsets/
│   └── WhatsApp_Webhook_Guest.permissionset-meta.xml
├── remoteSiteSettings/
│   ├── Meta_Graph_API.remoteSite-meta.xml
│   └── Meta_WhatsApp_Media_CDN.remoteSite-meta.xml
└── customMetadata/
    └── WhatsApp_Webhook_Config.Default.md-meta.xml
```

> **Note:** `WhatsAppCampaignController` requires custom metadata type `WhatsApp_Template__mdt` (template definitions). Retrieve or create that metadata in your org separately.

---

## Prerequisites

- Salesforce org (sandbox or production)
- Meta Developer app with **WhatsApp Business** product
- WhatsApp test/production phone number
- Salesforce CLI (`sf`) authenticated to target org

---

## Post-deploy configuration

These items are **manual in Setup** (not fully in source metadata).

### 1. Custom Metadata — `WhatsApp_Config__mdt` → **Default**

| Field | Value |
|-------|--------|
| `Phone_Number_Id__c` | From Meta → WhatsApp → API Setup |
| `Verify_Token__c` | Meta long-lived **access token** (`EAA…`) |

### 2. Named Credential — `WhatsApp_Meta`

- **URL:** `https://graph.facebook.com`
- **Authentication:** Named Principal or per-org token aligned with `Verify_Token__c`
- Used by `WhatsAppOutboundService` as `callout:WhatsApp_Meta`

### 3. Remote Site Settings

Deployed from this repo (`Meta_Graph_API`, `Meta_WhatsApp_Media_CDN`). Confirm they are **Active**.

### 4. Experience Cloud / Site

Create an active Site (e.g. `WhatsApp_Webhook`):

| Setting | Value |
|---------|--------|
| Active | Yes |
| HTTPS | Required |
| Guest profile | Custom profile for Site Guest User |

**Webhook URL:**

```text
https://<my-domain>--<sandbox>.sandbox.my.salesforce-sites.com/services/apexrest/whatsapp/webhook
```

### 5. Site Guest User permissions

**Public Access Settings → Guest Profile:**

- **Enabled Apex Class Access:**  
  `WhatsAppWebhookService`, `WhatsAppMessageService`, `WhatsAppMediaService`, `WhatsAppInboundMediaQueueable`
- Assign permission set **WhatsApp Webhook Guest**
- **Object permissions (profile):**  
  `WhatsApp_Contact__c`, `WhatsApp_Message__c`: Read, Create, **Edit**  
  `ContentVersion`, `ContentDocumentLink`: Read, Create

### 6. Change Data Capture

**Setup → Integrations → Change Data Capture** → enable **WhatsApp Message**.

> CDC for custom objects is configured in Setup, not in `object-meta.xml` (API 66).

### 7. Meta webhook

**Meta Developer → WhatsApp → Configuration:**

| Field | Value |
|-------|--------|
| Callback URL | Site URL above |
| Verify token | `LankaTiles_WA_Webhook_2024` |
| Subscribe | `messages` |

### 8. Internal user access

Grant CRM users Read/Create on `WhatsApp_Contact__c` and `WhatsApp_Message__c`, and add `whatsappChat` to Account/Contact/Lead record pages.

---

## Deploy

```bash
sf project deploy start --source-dir force-app/main/default --target-org <your-org-alias>
```

Or deploy the entire project:

```bash
sf project deploy start --target-org <your-org-alias>
```

---

## Testing

### Webhook verify (Postman)

```http
GET https://<site-domain>/services/apexrest/whatsapp/webhook?hub.mode=subscribe&hub.verify_token=LankaTiles_WA_Webhook_2024&hub.challenge=test123
Host: <site-domain-without-https>
```

Expected: **200** + body `test123`

### Inbound text

Send WhatsApp text to business number → new `WhatsApp_Message__c` (Inbound) → chat updates via CDC.

### Inbound image

Send image → `Media_URL__c` should start with `069` → image renders in chat.

### Outbound from Salesforce

Open Contact with chat LWC → send text/image → Pending then Sent → message on customer's WhatsApp (test numbers must be on Meta allow list in sandbox).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| HTML 400 from Site | Missing `Host` header or wrong URL | Use `-sites.com` URL; add Host in Postman |
| 403 on webhook verify | Missing query params or wrong token | Full GET URL with `hub.mode`, `hub.verify_token`, `hub.challenge` |
| Duplicate contacts | Guest couldn't see existing contacts | Deploy `without sharing` on `WhatsAppMessageService` |
| Empty inbound image bubble | Media download failed | Check `WA_MEDIA` debug logs; Remote Sites; Guest token access |
| Outbound 401 | Invalid access token | Update `Verify_Token__c` in Custom Metadata |
| Outbound 400 code 131030 | Sandbox test mode | Add recipient to Meta test allow list |
| Chat not live-updating | CDC off or cached wire | Enable CDC on `WhatsApp_Message__c`; confirm empApi subscription in browser console |

### Debug logs

Enable **FINEST** on Site Guest User for inbound; on your user for outbound/chat. Search prefixes: `WA_WEBHOOK`, `WA_OUTBOUND`, `WA_QUEUE`, `WA_MEDIA`, `WA_CHAT`.

---

## Phone matching logic

`WhatAppContactTrigger` (before insert/update on `WhatsApp_Contact__c`):

- Normalizes phone to **last 10 digits**
- Matches against Account.Phone, Contact.Phone/MobilePhone, Lead.Phone/MobilePhone
- Sets `Matched_Record_Type__c` and lookup fields

---

## Security notes

- Webhook verify token is **hardcoded** in `WhatsAppWebhookService` — change `HARDCODED_WEBHOOK_VERIFY_TOKEN` before production if needed.
- `Verify_Token__c` holds the Meta API secret — protect Custom Metadata access.
- Site Guest has minimal permissions; only required Apex classes are exposed.
- Consider HMAC signature verification for production webhooks (not implemented in this version).

---

## License

Internal use — Lanka Tiles / derivative deployments. Adapt Meta app credentials and Site URLs per environment.
