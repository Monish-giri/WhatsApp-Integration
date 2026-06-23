public with sharing class WhatsAppChatController {
    public class ChatMessageRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String direction;
        @AuraEnabled public String message;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String messageType;
        @AuraEnabled public String fileName;
        @AuraEnabled public String mimeType;
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String previewUrl;
        @AuraEnabled public String downloadUrl;
        @AuraEnabled public Boolean isAttachment;
        @AuraEnabled public Boolean isImageAttachment;
    }

    public class ChatThreadResponse {
        @AuraEnabled public Id whatsAppContactId;
        @AuraEnabled public List<ChatMessageRow> messages;
    }

    // Cacheable for fast wire load; use refreshApex in LWC after CDC to bypass stale cache.
    @AuraEnabled(cacheable=true)
    public static ChatThreadResponse getChatThread(Id recordId) {
        return buildChatThread(recordId);
    }

    private static ChatThreadResponse buildChatThread(Id recordId) {
        ChatThreadResponse response = new ChatThreadResponse();
        response.messages = new List<ChatMessageRow>();

        WhatsApp_Contact__c waContact = findWhatsAppContactByRecord(recordId);
        if (waContact == null) {
            return response;
        }

        response.whatsAppContactId = waContact.Id;

        List<WhatsApp_Message__c> rows = [
            SELECT Id, Direction__c, Message_Body__c, Message_Type__c, Sent_At__c,
                   File_Name__c, Mime_Type__c, Media_URL__c
            FROM WhatsApp_Message__c
            WHERE WhatsApp_Contact__c = :waContact.Id
            ORDER BY Sent_At__c ASC, CreatedDate ASC
            LIMIT 500
        ];

        for (WhatsApp_Message__c row : rows) {
            ChatMessageRow dto = new ChatMessageRow();
            dto.id = row.Id;
            dto.direction = row.Direction__c;
            dto.message = row.Message_Body__c;
            dto.createdDate = row.Sent_At__c;
            dto.messageType = row.Message_Type__c;
            dto.fileName = row.File_Name__c;
            dto.mimeType = row.Mime_Type__c;

            String docId = normalizeDocumentId(row.Media_URL__c);
            dto.contentDocumentId = docId;
            dto.previewUrl = buildPreviewUrl(docId);
            dto.downloadUrl = buildDownloadUrl(docId);

            dto.isAttachment = !String.isBlank(row.Media_URL__c) ||
                row.Message_Type__c == 'Image' || row.Message_Type__c == 'File';
            dto.isImageAttachment = row.Message_Type__c == 'Image';
            response.messages.add(dto);
        }
        return response;
    }

    @AuraEnabled
    public static String sendChatPayload(Id recordId, String messageText, String contentVersionId) {
        try {
            System.debug(LoggingLevel.INFO, 'WA_CHAT sendChatPayload start recordId=' + recordId +
                ' hasText=' + String.isNotBlank(messageText) +
                ' hasAttachment=' + String.isNotBlank(contentVersionId));
            Boolean hasText = String.isNotBlank(messageText);
            Boolean hasAttachment = String.isNotBlank(contentVersionId);
            if (!hasText && !hasAttachment) {
                System.debug(LoggingLevel.WARN, 'WA_CHAT sendChatPayload nothing to send');
                return 'Nothing to send.';
            }

            WhatsApp_Contact__c waContact = getOrCreateWhatsAppContact(recordId);
            if (waContact == null || String.isBlank(waContact.Phone__c)) {
                System.debug(LoggingLevel.ERROR, 'WA_CHAT no WhatsApp contact/phone for recordId=' + recordId);
                return 'Unable to resolve WhatsApp contact phone.';
            }
            System.debug(LoggingLevel.INFO, 'WA_CHAT resolved WA contact Id=' + waContact.Id + ' phone=' + waContact.Phone__c);

            String outboundPhone = resolveOutboundPhone(recordId, waContact.Phone__c);
            if (String.isBlank(outboundPhone)) {
                System.debug(LoggingLevel.ERROR, 'WA_CHAT outbound phone normalization failed for recordId=' + recordId);
                return 'Unable to resolve outbound phone in international format.';
            }
            System.debug(LoggingLevel.INFO, 'WA_CHAT outbound phone=' + outboundPhone);

            if (hasText && !hasAttachment) {
                WhatsApp_Message__c pendingText = WhatsAppMessageService.createPendingOutboundMessage(
                    waContact.Id,
                    messageText.trim(),
                    'text',
                    null,
                    null,
                    null
                );

                WhatsAppOutboundService.OutboundRequest textRequest = new WhatsAppOutboundService.OutboundRequest();
                textRequest.toPhoneNumber = outboundPhone;
                textRequest.type = 'text';
                textRequest.textBody = messageText.trim();
                textRequest.whatsappMessageId = pendingText.Id;
                Id textJobId = System.enqueueJob(new WhatsAppOutboundQueueable(textRequest));
                System.debug(LoggingLevel.INFO, 'WA_CHAT text queued jobId=' + textJobId +
                    ' pendingMessageId=' + pendingText.Id);
            }

            if (hasAttachment) {
                ContentVersion cv = [
                    SELECT Id, ContentDocumentId, Title, FileExtension, FileType
                    FROM ContentVersion
                    WHERE Id = :contentVersionId
                    LIMIT 1
                ];

                String publicLink = getOrCreatePublicFileLink(cv.Id);
                if (String.isBlank(publicLink)) {
                    return 'ERROR: Unable to generate public link for attachment.';
                }

                String mediaType = isImageFileType(cv.FileType) ? 'image' : 'document';
                String mediaFileName = String.isBlank(cv.FileExtension)
                    ? cv.Title
                    : cv.Title + '.' + cv.FileExtension.toLowerCase();
                String caption = hasText ? messageText.trim() : null;

                WhatsApp_Message__c pendingMedia = WhatsAppMessageService.createPendingOutboundMessage(
                    waContact.Id,
                    caption,
                    mediaType,
                    String.valueOf(cv.ContentDocumentId),
                    cv.FileType,
                    mediaFileName
                );

                WhatsAppOutboundService.OutboundRequest mediaRequest = new WhatsAppOutboundService.OutboundRequest();
                mediaRequest.toPhoneNumber = outboundPhone;
                mediaRequest.type = mediaType;
                mediaRequest.mediaLink = publicLink;
                mediaRequest.contentDocumentId = cv.ContentDocumentId;
                mediaRequest.mimeType = cv.FileType;
                mediaRequest.caption = caption;
                mediaRequest.fileName = mediaFileName;
                mediaRequest.whatsappMessageId = pendingMedia.Id;
                Id mediaJobId = System.enqueueJob(new WhatsAppOutboundQueueable(mediaRequest));
                System.debug(LoggingLevel.INFO, 'WA_CHAT media queued jobId=' + mediaJobId +
                    ' pendingMessageId=' + pendingMedia.Id +
                    ' link=' + publicLink);
            }

            return 'SUCCESS';
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'WA_CHAT sendChatPayload exception=' + ex.getMessage() +
                ' stack=' + ex.getStackTraceString());
            return 'ERROR: ' + ex.getMessage();
        }
    }

    @AuraEnabled
    public static String uploadEmployeeFile(Id recordId, String fileName, String base64Data) {
        if (recordId == null || String.isBlank(fileName) || String.isBlank(base64Data)) {
            throw new AuraHandledException('Missing upload parameters.');
        }

        ContentVersion cv = new ContentVersion();
        cv.Title = fileName;
        cv.PathOnClient = '/' + fileName;
        cv.VersionData = EncodingUtil.base64Decode(base64Data);
        cv.FirstPublishLocationId = recordId;
        insert cv;

        return cv.Id;
    }

    @AuraEnabled
    public static void markThreadRead(Id recordId) {
        WhatsApp_Contact__c waContact = findWhatsAppContactByRecord(recordId);
        if (waContact == null) {
            return;
        }
        waContact.Unread_Count__c = 0;
        update waContact;
    }

    private static WhatsApp_Contact__c findWhatsAppContactByRecord(Id recordId) {
        if (recordId == null) {
            return null;
        }
        Schema.SObjectType sobType = recordId.getSObjectType();
        if (sobType == Account.SObjectType) {
            List<WhatsApp_Contact__c> rows = [
                SELECT Id, Phone__c, Account__c, Contact__c, Lead__c
                FROM WhatsApp_Contact__c
                WHERE Account__c = :recordId
                ORDER BY Last_Message_Date__c DESC, CreatedDate DESC
                LIMIT 1
            ];
            return rows.isEmpty() ? null : rows[0];
        }
        if (sobType == Contact.SObjectType) {
            List<WhatsApp_Contact__c> rows = [
                SELECT Id, Phone__c, Account__c, Contact__c, Lead__c
                FROM WhatsApp_Contact__c
                WHERE Contact__c = :recordId
                ORDER BY Last_Message_Date__c DESC, CreatedDate DESC
                LIMIT 1
            ];
            return rows.isEmpty() ? null : rows[0];
        }
        if (sobType == Lead.SObjectType) {
            List<WhatsApp_Contact__c> rows = [
                SELECT Id, Phone__c, Account__c, Contact__c, Lead__c
                FROM WhatsApp_Contact__c
                WHERE Lead__c = :recordId
                ORDER BY Last_Message_Date__c DESC, CreatedDate DESC
                LIMIT 1
            ];
            return rows.isEmpty() ? null : rows[0];
        }
        if (sobType == WhatsApp_Contact__c.SObjectType) {
            List<WhatsApp_Contact__c> rows = [
                SELECT Id, Phone__c, Account__c, Contact__c, Lead__c
                FROM WhatsApp_Contact__c
                WHERE Id = :recordId
                LIMIT 1
            ];
            return rows.isEmpty() ? null : rows[0];
        }
        return null;
    }

    private static WhatsApp_Contact__c getOrCreateWhatsAppContact(Id recordId) {
        WhatsApp_Contact__c existing = findWhatsAppContactByRecord(recordId);
        if (existing != null) {
            return existing;
        }
        if (recordId == null) {
            return null;
        }

        Schema.SObjectType sobType = recordId.getSObjectType();
        String phone;
        if (sobType == Account.SObjectType) {
            Account row = [SELECT Id, Phone FROM Account WHERE Id = :recordId LIMIT 1];
            phone = row.Phone;
        } else if (sobType == Contact.SObjectType) {
            Contact row = [SELECT Id, MobilePhone, Phone FROM Contact WHERE Id = :recordId LIMIT 1];
            phone = String.isNotBlank(row.MobilePhone) ? row.MobilePhone : row.Phone;
        } else if (sobType == Lead.SObjectType) {
            Lead row = [SELECT Id, MobilePhone, Phone FROM Lead WHERE Id = :recordId LIMIT 1];
            phone = String.isNotBlank(row.MobilePhone) ? row.MobilePhone : row.Phone;
        } else if (sobType == WhatsApp_Contact__c.SObjectType) {
            List<WhatsApp_Contact__c> rows = [
                SELECT Id, Phone__c, Account__c, Contact__c, Lead__c
                FROM WhatsApp_Contact__c
                WHERE Id = :recordId
                LIMIT 1
            ];
            return rows.isEmpty() ? null : rows[0];
        } else {
            return null;
        }

        WhatsApp_Contact__c waContact = WhatsAppMessageService.upsertWhatsAppContact(phone);
        if (sobType == Account.SObjectType) {
            waContact.Account__c = recordId;
            waContact.Matched_Record_Type__c = 'Account';
        } else if (sobType == Contact.SObjectType) {
            waContact.Contact__c = recordId;
            waContact.Matched_Record_Type__c = 'Contact';
        } else if (sobType == Lead.SObjectType) {
            waContact.Lead__c = recordId;
            waContact.Matched_Record_Type__c = 'Lead';
        }
        update waContact;
        return waContact;
    }

    private static Boolean isImageFileType(String fileType) {
        if (String.isBlank(fileType)) {
            return false;
        }
        String normalized = fileType.toLowerCase();
        return normalized == 'png' || normalized == 'jpg' || normalized == 'jpeg' ||
            normalized == 'gif' || normalized == 'bmp' || normalized == 'webp';
    }

    private static String normalizeDocumentId(String rawValue) {
        if (String.isBlank(rawValue)) {
            return null;
        }
        String value = rawValue.trim();
        if (!value.startsWith('069')) {
            return null;
        }
        if (value.length() == 15 || value.length() == 18) {
            return value;
        }
        if (value.length() > 15) {
            return value.substring(0, 15);
        }
        return null;
    }

    private static String buildPreviewUrl(String contentDocumentId) {
        if (String.isBlank(contentDocumentId)) {
            return null;
        }
        return '/lightning/r/ContentDocument/' + contentDocumentId + '/view';
    }

    private static String buildDownloadUrl(String contentDocumentId) {
        if (String.isBlank(contentDocumentId)) {
            return null;
        }
        return '/sfc/servlet.shepherd/document/download/' + contentDocumentId;
    }

    private static String resolveOutboundPhone(Id recordId, String fallbackPhone) {
        String candidate = fallbackPhone;
        if (recordId != null) {
            Schema.SObjectType sobType = recordId.getSObjectType();
            if (sobType == Account.SObjectType) {
                Account row = [SELECT Phone FROM Account WHERE Id = :recordId LIMIT 1];
                if (String.isNotBlank(row.Phone)) {
                    candidate = row.Phone;
                }
            } else if (sobType == Contact.SObjectType) {
                Contact row = [SELECT MobilePhone, Phone FROM Contact WHERE Id = :recordId LIMIT 1];
                if (String.isNotBlank(row.MobilePhone)) {
                    candidate = row.MobilePhone;
                } else if (String.isNotBlank(row.Phone)) {
                    candidate = row.Phone;
                }
            } else if (sobType == Lead.SObjectType) {
                Lead row = [SELECT MobilePhone, Phone FROM Lead WHERE Id = :recordId LIMIT 1];
                if (String.isNotBlank(row.MobilePhone)) {
                    candidate = row.MobilePhone;
                } else if (String.isNotBlank(row.Phone)) {
                    candidate = row.Phone;
                }
            }
        }
        return normalizeForWhatsApp(candidate);
    }

    private static String normalizeForWhatsApp(String rawPhone) {
        if (String.isBlank(rawPhone)) {
            return null;
        }
        String digits = rawPhone.replaceAll('[^0-9]', '');
        if (String.isBlank(digits)) {
            return null;
        }
        // Accept phone values from CRM/WhatsApp contact as-is after digit cleanup.
        // Meta will return an explicit 400 if number format is still invalid.
        if (digits.length() >= 10) {
            return digits;
        }
        return null;
    }

    private static String getOrCreatePublicFileLink(Id contentVersionId) {
        List<ContentDistribution> existing = [
            SELECT Id, DistributionPublicUrl, ContentDownloadUrl
            FROM ContentDistribution
            WHERE ContentVersionId = :contentVersionId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        ContentDistribution dist;
        if (!existing.isEmpty()) {
            dist = existing[0];
        } else {
            ContentDistribution createDist = new ContentDistribution();
            createDist.Name = 'WhatsApp Share ' + String.valueOf(Datetime.now().getTime());
            createDist.ContentVersionId = contentVersionId;
            createDist.PreferencesAllowViewInBrowser = true;
            createDist.PreferencesAllowOriginalDownload = true;
            createDist.PreferencesLinkLatestVersion = true;
            insert createDist;

            dist = [
                SELECT Id, DistributionPublicUrl, ContentDownloadUrl
                FROM ContentDistribution
                WHERE Id = :createDist.Id
                LIMIT 1
            ];
        }
        if (String.isNotBlank(dist.ContentDownloadUrl)) {
            return dist.ContentDownloadUrl;
        }
        return dist.DistributionPublicUrl;
    }
}
