public with sharing class WhatsAppOutboundService
{
    public class OutboundRequest {
        public String toPhoneNumber;
        public String type;
        public String textBody;
        public String mediaId;
        public String mediaLink;
        public String contentDocumentId;
        public String mimeType;
        public String caption;
        public String fileName;
        // Salesforce row created before Queueable so CDC can refresh the chat immediately.
        public Id whatsappMessageId;
    }

    public static String sendTextMessage(
        String toPhoneNumber,
        String messageBody
    )
    {
        OutboundRequest request = new OutboundRequest();
        request.toPhoneNumber = toPhoneNumber;
        request.type = 'text';
        request.textBody = messageBody;
        return sendMessage(request);
    }

    public static String sendMessage(OutboundRequest request) {
        System.debug(LoggingLevel.INFO, 'WA_OUTBOUND sendMessage start request=' + JSON.serialize(request));
        if (request == null) {
            throw new AuraHandledException('Outbound request is required.');
        }
        if (String.isBlank(request.toPhoneNumber) || String.isBlank(request.type)) {
            throw new AuraHandledException('Phone number and message type are required.');
        }

        String typeValue = request.type.trim().toLowerCase();
        if (typeValue == 'text' && String.isBlank(request.textBody)) {
            throw new AuraHandledException('Text body is required for text messages.');
        }
        if (typeValue != 'text' && String.isBlank(request.mediaId) && String.isBlank(request.mediaLink)) {
            throw new AuraHandledException('Media id or media link is required for media messages.');
        }

        WhatsApp_Config__mdt config =
            WhatsApp_Config__mdt.getInstance(
                'Default'
            );
        if (config == null || String.isBlank(config.Phone_Number_Id__c)) {
            throw new AuraHandledException('WhatsApp config is missing Phone Number Id.');
        }
        if (String.isBlank(config.Verify_Token__c)) {
            throw new AuraHandledException('WhatsApp config is missing access token in Verify_Token__c.');
        }

        String endpoint =
            'callout:WhatsApp_Meta/v22.0/' +
            config.Phone_Number_Id__c +
            '/messages';
        System.debug(LoggingLevel.INFO, 'WA_OUTBOUND endpoint=' + endpoint);

        Map<String, Object> textObj =
            buildTypePayload(typeValue, request);

        Map<String, Object> payload =
            new Map<String, Object>();
        payload.put('messaging_product', 'whatsapp');
        payload.put('recipient_type', 'individual');
        payload.put('to', request.toPhoneNumber);
        payload.put('type', typeValue);
        payload.put(typeValue, textObj);
        System.debug(LoggingLevel.INFO, 'WA_OUTBOUND payload=' + JSON.serialize(payload));

        HttpRequest req =
            new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + config.Verify_Token__c);
        req.setBody(JSON.serialize(payload));

        Http http = new Http();
        HttpResponse res = http.send(req);
        System.debug(LoggingLevel.INFO, 'WA_OUTBOUND response status=' + res.getStatusCode() +
            ' body=' + res.getBody());

        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            throw new AuraHandledException(buildMetaErrorMessage(res));
        }

        Map<String, Object> responseMap =
            (Map<String, Object>)
            JSON.deserializeUntyped(
                res.getBody()
            );
        String metaMessageId = null;
        if (responseMap != null && responseMap.containsKey('messages')) {
            List<Object> messages = (List<Object>) responseMap.get('messages');
            if (messages != null && !messages.isEmpty()) {
                Map<String, Object> firstMessage = (Map<String, Object>) messages[0];
                metaMessageId = (String) firstMessage.get('id');
            }
        }

        if (request.whatsappMessageId != null) {
            WhatsAppMessageService.completeOutboundMessage(
                request.whatsappMessageId,
                metaMessageId
            );
            System.debug(LoggingLevel.INFO,
                'WA_OUTBOUND pending message completed sfId=' + request.whatsappMessageId +
                ' metaMessageId=' + metaMessageId);
        } else {
            WhatsApp_Contact__c contactRec =
                WhatsAppMessageService.upsertWhatsAppContact(request.toPhoneNumber);

            WhatsAppMessageService.createOutboundMessageDetailed(
                contactRec.Id,
                typeValue == 'text' ? request.textBody : request.caption,
                metaMessageId,
                typeValue,
                typeValue == 'text'
                    ? null
                    : (String.isNotBlank(request.contentDocumentId)
                        ? request.contentDocumentId
                        : (String.isNotBlank(request.mediaLink) ? request.mediaLink : request.mediaId)),
                request.mimeType,
                request.fileName
            );
            System.debug(LoggingLevel.INFO, 'WA_OUTBOUND message persisted contactId=' + contactRec.Id +
                ' metaMessageId=' + metaMessageId);
        }
        return metaMessageId;
    }

    private static String buildMetaErrorMessage(HttpResponse res) {
        String rawBody = res == null ? null : res.getBody();
        Integer statusCode = res == null ? null : res.getStatusCode();
        String message = null;
        String details = null;
        String code = null;

        try {
            Map<String, Object> bodyMap = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            Map<String, Object> errorMap = bodyMap == null ? null : (Map<String, Object>) bodyMap.get('error');
            if (errorMap != null) {
                message = (String) errorMap.get('message');
                Object codeObj = errorMap.get('code');
                if (codeObj != null) {
                    code = String.valueOf(codeObj);
                }
                Map<String, Object> errorData = (Map<String, Object>) errorMap.get('error_data');
                if (errorData != null) {
                    details = (String) errorData.get('details');
                }
            }
        } catch (Exception ex) {
            // Ignore parse failure; fallback below.
        }

        String summary = 'WhatsApp API error: ' + String.valueOf(statusCode);
        if (String.isNotBlank(code)) {
            summary += ' (code ' + code + ')';
        }
        if (String.isNotBlank(message)) {
            summary += ' - ' + message;
        }
        if (String.isNotBlank(details)) {
            summary += ' | ' + details;
        }
        if (String.isBlank(message) && String.isBlank(details) && String.isNotBlank(rawBody)) {
            summary += ' - ' + rawBody;
        }
        return summary;
    }

    private static Map<String, Object> buildTypePayload(String typeValue, OutboundRequest request) {
        Map<String, Object> content = new Map<String, Object>();
        if (typeValue == 'text') {
            content.put('preview_url', false);
            content.put('body', request.textBody);
            return content;
        }

        Set<String> allowedMediaTypes = new Set<String>{ 'image', 'document', 'audio', 'video', 'sticker' };
        if (!allowedMediaTypes.contains(typeValue)) {
            throw new AuraHandledException('Unsupported WhatsApp message type: ' + typeValue);
        }

        if (String.isNotBlank(request.mediaId)) {
            content.put('id', request.mediaId);
        } else {
            content.put('link', request.mediaLink);
        }

        if ((typeValue == 'image' || typeValue == 'video' || typeValue == 'document') && String.isNotBlank(request.caption)) {
            content.put('caption', request.caption);
        }
        if (typeValue == 'document' && String.isNotBlank(request.fileName)) {
            content.put('filename', request.fileName);
        }
        return content;
    }
}