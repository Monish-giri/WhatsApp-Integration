
@RestResource(urlMapping='/whatsapp/webhook/*')
global without sharing class WhatsAppWebhookService {

    // Webhook verify token — must match exactly what you entered in Meta portal
    private static final String HARDCODED_WEBHOOK_VERIFY_TOKEN = 'LankaTiles_WA_Webhook_2024';

    // ─────────────────────────────────────────────
    // WEBHOOK VERIFICATION (GET)
    // Meta calls this once when you configure the webhook
    // ─────────────────────────────────────────────
    @HttpGet
    global static void verifyWebhook() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        String mode      = req.params.get('hub.mode');
        String token     = req.params.get('hub.verify_token');
        String challenge = req.params.get('hub.challenge');
        String expected  = getVerifyToken();

        System.debug(LoggingLevel.INFO,
            'WA_WEBHOOK verifyWebhook mode=' + mode +
            ' tokenProvided=' + String.isNotBlank(token));

        if (mode == 'subscribe' && !String.isBlank(token) && token == expected) {
            res.statusCode    = 200;
            res.responseBody  = Blob.valueOf(challenge == null ? '' : challenge);
            System.debug(LoggingLevel.INFO, 'WA_WEBHOOK verification success');
            return;
        }

        res.statusCode   = 403;
        res.responseBody = Blob.valueOf('Forbidden');
        System.debug(LoggingLevel.WARN, 'WA_WEBHOOK verification failed');
    }

    // ─────────────────────────────────────────────
    // INBOUND MESSAGE HANDLER (POST)
    // Meta calls this for every new message / status update
    // ─────────────────────────────────────────────
    @HttpPost
    global static void handleInbound() {
        RestResponse res = RestContext.response;
        res.statusCode = 200; // Always 200 immediately — stops Meta retrying

        try {
            RestRequest req     = RestContext.request;
            String      rawBody = req.requestBody == null ? null : req.requestBody.toString();

            System.debug(LoggingLevel.INFO,
                'WA_WEBHOOK inbound raw=' + (rawBody == null ? null : rawBody.left(Math.min(3000, rawBody.length()))));

            if (String.isBlank(rawBody)) {
                System.debug(LoggingLevel.WARN, 'WA_WEBHOOK inbound empty body');
                return;
            }

            Map<String, Object> payload =
                (Map<String, Object>) JSON.deserializeUntyped(rawBody);

            if (payload == null || !payload.containsKey('entry')) {
                System.debug(LoggingLevel.WARN, 'WA_WEBHOOK payload missing entry');
                return;
            }

            List<Object> entries = (List<Object>) payload.get('entry');

            for (Object entryObj : entries) {
                Map<String, Object> entry   = (Map<String, Object>) entryObj;
                List<Object>           changes = entry == null ? null : (List<Object>) entry.get('changes');
                if (changes == null) continue;

                for (Object changeObj : changes) {
                    Map<String, Object> change = (Map<String, Object>) changeObj;
                    Map<String, Object> value  = change == null ? null : (Map<String, Object>) change.get('value');
                    if (value == null) continue;

                    processStatuses(value);

                    List<Object> messages = (List<Object>) value.get('messages');
                    if (messages == null) continue;

                    for (Object msgObj : messages) {
                        processSingleMessage(value, (Map<String, Object>) msgObj);
                    }
                }
            }

        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR,
                'WA_WEBHOOK handleInbound exception=' + ex.getMessage() +
                ' stack=' + ex.getStackTraceString());
        }
    }

    // ─────────────────────────────────────────────
    // PROCESS SINGLE MESSAGE
    // ─────────────────────────────────────────────
    private static void processSingleMessage(
        Map<String, Object> valueObj,
        Map<String, Object> msg
    ) {
        if (msg == null) return;

        String fromNumber = extractInboundPhone(valueObj, msg);
        if (String.isBlank(fromNumber)) {
            System.debug(LoggingLevel.WARN, 'WA_WEBHOOK processSingleMessage no sender');
            return;
        }

        // Upsert WhatsApp_Contact__c — creates if not exists, returns existing if it does
        WhatsApp_Contact__c contactRec =
            WhatsAppMessageService.upsertWhatsAppContact(fromNumber);

        String msgType = (String) msg.get('type');
        if (String.isBlank(msgType)) msgType = 'text';

        String messageBody = extractBody(msg);
        String mediaValue  = extractMediaUrl(msg);
        String mimeType    = extractMimeType(msg);
        String fileName    = extractFileName(msg);
        String metaMediaId  = mediaValue;

        if (String.isBlank(messageBody) && (msgType == 'image' || msgType == 'document')) {
            messageBody = msgType == 'image'
                ? 'Photo'
                : (String.isNotBlank(fileName) ? fileName : 'Document');
        }

        Id contentDocumentId = null;
        if ((msgType == 'image' || msgType == 'document') && String.isNotBlank(mediaValue)) {
            contentDocumentId = WhatsAppMediaService.fetchMediaIntoSalesforce(
                mediaValue,
                msgType,
                fileName,
                mimeType,
                contactRec.Id
            );
            if (contentDocumentId != null) {
                mediaValue = String.valueOf(contentDocumentId);
                if (String.isBlank(fileName)) {
                    fileName = msgType == 'image' ? 'WhatsApp Image' : 'WhatsApp Document';
                }
            }
        }

        WhatsApp_Message__c inboundRow = WhatsAppMessageService.createInboundMessage(
            contactRec.Id,
            messageBody,
            (String) msg.get('id'),
            msgType,
            mediaValue,
            mimeType,
            fileName
        );

        if (contentDocumentId == null
            && inboundRow != null
            && (msgType == 'image' || msgType == 'document')
            && String.isNotBlank(metaMediaId)
            && !metaMediaId.startsWith('069')) {
            System.enqueueJob(new WhatsAppInboundMediaQueueable(
                inboundRow.Id,
                metaMediaId,
                msgType,
                fileName,
                mimeType,
                contactRec.Id
            ));
        }

        System.debug(LoggingLevel.INFO,
            'WA_WEBHOOK inbound saved msgId=' + (String) msg.get('id') +
            ' type=' + msgType + ' contactId=' + contactRec.Id);
    }

    // ─────────────────────────────────────────────
    // PROCESS STATUS UPDATES
    // Updates Message Status__c — Delivered, Read, Failed
    // ─────────────────────────────────────────────
    private static void processStatuses(Map<String, Object> valueObj) {
        List<Object> statuses = (List<Object>) valueObj.get('statuses');
        if (statuses == null || statuses.isEmpty()) return;

        for (Object statusObj : statuses) {
            Map<String, Object> status = (Map<String, Object>) statusObj;
            if (status == null) continue;

            System.debug(LoggingLevel.INFO,
                'WA_WEBHOOK status update id=' + (String) status.get('id') +
                ' status=' + (String) status.get('status'));

            WhatsAppMessageService.updateMessageStatus(
                (String) status.get('id'),
                (String) status.get('status')
            );
        }
    }

    // ─────────────────────────────────────────────
    // PHONE EXTRACTION HELPERS
    // ─────────────────────────────────────────────
    private static String extractInboundPhone(
        Map<String, Object> valueObj,
        Map<String, Object> message
    ) {
        String fromMessage = message == null ? null : (String) message.get('from');
        if (String.isNotBlank(fromMessage)) return fromMessage;

        List<Object> contacts = (List<Object>) valueObj.get('contacts');
        return getPhoneFromContacts(contacts);
    }

    private static String getPhoneFromContacts(List<Object> contacts) {
        if (contacts == null || contacts.isEmpty() || contacts[0] == null) return null;
        Map<String, Object> first = (Map<String, Object>) contacts[0];
        return first == null ? null : (String) first.get('wa_id');
    }

    // ─────────────────────────────────────────────
    // MESSAGE CONTENT EXTRACTION HELPERS
    // ─────────────────────────────────────────────
    private static String extractBody(Map<String, Object> message) {
        if (message == null) return null;

        if (message.containsKey('text')) {
            Map<String, Object> textObj = (Map<String, Object>) message.get('text');
            return textObj == null ? null : (String) textObj.get('body');
        }
        if (message.containsKey('button')) {
            return getNestedString(message, 'button', 'text');
        }
        if (message.containsKey('interactive')) {
            Map<String, Object> interactive = (Map<String, Object>) message.get('interactive');
            String type = interactive == null ? null : (String) interactive.get('type');
            if (type == 'button_reply') return getNestedString(interactive, 'button_reply', 'title');
            if (type == 'list_reply')   return getNestedString(interactive, 'list_reply',   'title');
        }
        if (message.containsKey('image')) {
            return getNestedString(message, 'image', 'caption');
        }
        if (message.containsKey('document')) {
            return getNestedString(message, 'document', 'caption');
        }
        if (message.containsKey('video')) {
            return getNestedString(message, 'video', 'caption');
        }
        return null;
    }

    private static String extractMediaUrl(Map<String, Object> message) {
        if (message == null) return null;
        if (message.containsKey('image'))    return firstNonBlank(getNestedString(message, 'image',    'id'), getNestedString(message, 'image',    'link'));
        if (message.containsKey('audio'))    return firstNonBlank(getNestedString(message, 'audio',    'id'), getNestedString(message, 'audio',    'link'));
        if (message.containsKey('video'))    return firstNonBlank(getNestedString(message, 'video',    'id'), getNestedString(message, 'video',    'link'));
        if (message.containsKey('document')) return firstNonBlank(getNestedString(message, 'document', 'id'), getNestedString(message, 'document', 'link'));
        return null;
    }

    private static String extractMimeType(Map<String, Object> message) {
        if (message == null) return null;
        if (message.containsKey('image'))    return getNestedString(message, 'image',    'mime_type');
        if (message.containsKey('audio'))    return getNestedString(message, 'audio',    'mime_type');
        if (message.containsKey('video'))    return getNestedString(message, 'video',    'mime_type');
        if (message.containsKey('document')) return getNestedString(message, 'document', 'mime_type');
        return null;
    }

    private static String extractFileName(Map<String, Object> message) {
        if (message == null) return null;
        if (message.containsKey('document')) return getNestedString(message, 'document', 'filename');
        return null;
    }

    // ─────────────────────────────────────────────
    // UTILITY HELPERS
    // ─────────────────────────────────────────────
    private static String getNestedString(
        Map<String, Object> container,
        String key,
        String nestedKey
    ) {
        Map<String, Object> nested = (Map<String, Object>) container.get(key);
        return nested == null ? null : (String) nested.get(nestedKey);
    }

    private static String firstNonBlank(String v1, String v2) {
        return String.isNotBlank(v1) ? v1 : v2;
    }

    // ─────────────────────────────────────────────
    // CONFIG READERS
    // ─────────────────────────────────────────────

    // Returns the hardcoded webhook verify token
    private static String getVerifyToken() {
        return HARDCODED_WEBHOOK_VERIFY_TOKEN;
    }
}
