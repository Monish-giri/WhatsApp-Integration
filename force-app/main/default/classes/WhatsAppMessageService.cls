// without sharing: inbound webhook runs as Site Guest and must find contacts
// created by internal users (OWD/sharing would hide them from a with sharing lookup).
public without sharing class WhatsAppMessageService 
{
    private static final String INBOUND_STATUS = 'Pending';
    private static final Set<String> ALLOWED_STATUS = new Set<String>{
        'Sent', 'Delivered', 'Read', 'Failed', 'Pending'
    };

    // ---------------------------------------------------------
    // CREATE / FIND WHATSAPP CONTACT
    // ---------------------------------------------------------
    
    public static WhatsApp_Contact__c upsertWhatsAppContact(String phoneNumber)
    {
        String normalizedPhone = normalizePhone(phoneNumber);
        if (String.isBlank(normalizedPhone)) {
            throw new AuraHandledException('Phone number is required.');
        }

        WhatsApp_Contact__c existingContact = findContactByNormalizedPhone(normalizedPhone);
        if (existingContact != null) {
            return existingContact;
        }

        WhatsApp_Contact__c newContact = new WhatsApp_Contact__c();
        newContact.Phone__c = normalizedPhone;
        newContact.Is_Active__c = true;

        insert newContact;

        return newContact;
    }

    private static WhatsApp_Contact__c findContactByNormalizedPhone(String normalizedPhone) {
        List<WhatsApp_Contact__c> exactMatches = [
            SELECT Id, Phone__c
            FROM WhatsApp_Contact__c
            WHERE Phone__c = :normalizedPhone
            LIMIT 1
        ];
        if (!exactMatches.isEmpty()) {
            return exactMatches[0];
        }

        // Phone field type may store formatting differently than our normalized key.
        String suffixPattern = '%' + normalizedPhone;
        for (WhatsApp_Contact__c candidate : [
            SELECT Id, Phone__c
            FROM WhatsApp_Contact__c
            WHERE Phone__c LIKE :suffixPattern
            ORDER BY Last_Message_Date__c DESC NULLS LAST, CreatedDate DESC
            LIMIT 50
        ]) {
            if (normalizePhone(candidate.Phone__c) == normalizedPhone) {
                return candidate;
            }
        }

        return null;
    }
    
    // ---------------------------------------------------------
    // CREATE INBOUND MESSAGE
    // ---------------------------------------------------------
    
    

public static WhatsApp_Message__c createInboundMessage(
    Id whatsappContactId,
    String messageBody,
    String messageId,
    String messageType,
    String mediaUrl,
    String mimeType,
    String fileName
)
{
    if (String.isNotBlank(messageId)) {
        WhatsApp_Message__c existing = findByMessageId(messageId);
        if (existing != null) {
            return existing;
        }
    }

    WhatsApp_Message__c msg =
        new WhatsApp_Message__c();

    // -------------------------------------------------
    // RELATIONSHIP
    // -------------------------------------------------

    msg.WhatsApp_Contact__c = whatsappContactId;

    // -------------------------------------------------
    // MESSAGE CONTENT
    // -------------------------------------------------

    msg.Message_Body__c = messageBody;

    // -------------------------------------------------
    // MEDIA
    // -------------------------------------------------

    msg.Media_URL__c = mediaUrl;

    msg.Mime_Type__c = mimeType;

    msg.File_Name__c = fileName;

    // -------------------------------------------------
    // REQUIRED PICKLISTS
    // -------------------------------------------------

    msg.Direction__c = 'Inbound';

    msg.Message_Type__c = normalizeMessageType(messageType);

    msg.Status__c = INBOUND_STATUS;

    // -------------------------------------------------
    // META DATA
    // -------------------------------------------------

    msg.WhatsApp_Message_Id__c = messageId;

    msg.Sent_At__c = System.now();

    insert msg;
    touchContactForInbound(whatsappContactId);

    return msg;
}

   
public static WhatsApp_Message__c createOutboundMessage(Id whatsappContactId,String messageBody,String messageId)
{
    return createOutboundMessageDetailed(
        whatsappContactId,
        messageBody,
        messageId,
        'Text',
        null,
        null,
        null
    );
}

public static WhatsApp_Message__c createOutboundMessageDetailed(
    Id whatsappContactId,
    String messageBody,
    String messageId,
    String messageType,
    String mediaUrl,
    String mimeType,
    String fileName
)
{
    WhatsApp_Message__c msg =
        new WhatsApp_Message__c();

    msg.WhatsApp_Contact__c = whatsappContactId;

    msg.Message_Body__c = messageBody;

    msg.Media_URL__c = mediaUrl;

    msg.Mime_Type__c = mimeType;

    msg.File_Name__c = fileName;

    msg.Direction__c = 'Outbound';

    msg.Message_Type__c = normalizeMessageType(messageType);

    msg.Status__c = 'Sent';

    msg.WhatsApp_Message_Id__c = messageId;

    msg.Sent_At__c = System.now();

    insert msg;

    return msg;
}

    public static WhatsApp_Message__c createPendingOutboundMessage(
        Id whatsappContactId,
        String messageBody,
        String messageType,
        String mediaUrl,
        String mimeType,
        String fileName
    ) {
        WhatsApp_Message__c msg = new WhatsApp_Message__c();
        msg.WhatsApp_Contact__c = whatsappContactId;
        msg.Message_Body__c = messageBody;
        msg.Media_URL__c = mediaUrl;
        msg.Mime_Type__c = mimeType;
        msg.File_Name__c = fileName;
        msg.Direction__c = 'Outbound';
        msg.Message_Type__c = normalizeMessageType(messageType);
        msg.Status__c = 'Pending';
        msg.Sent_At__c = System.now();
        insert msg;
        return msg;
    }

    public static void completeOutboundMessage(Id salesforceMessageId, String metaMessageId) {
        if (salesforceMessageId == null) {
            return;
        }
        WhatsApp_Message__c msg = new WhatsApp_Message__c(
            Id = salesforceMessageId,
            Status__c = 'Sent',
            WhatsApp_Message_Id__c = metaMessageId,
            Error_Message__c = null
        );
        update msg;
    }

    public static void failOutboundMessage(Id salesforceMessageId, String errorMessage) {
        if (salesforceMessageId == null) {
            return;
        }
        WhatsApp_Message__c msg = new WhatsApp_Message__c(
            Id = salesforceMessageId,
            Status__c = 'Failed',
            Error_Message__c = errorMessage == null ? null : errorMessage.left(255)
        );
        update msg;
    }

    public static void updateMessageStatus(String messageId, String statusValue) {
        if (String.isBlank(messageId)) {
            return;
        }
        WhatsApp_Message__c existing = findByMessageId(messageId);
        if (existing == null) {
            return;
        }

        String normalizedStatus = normalizeStatus(statusValue);
        if (normalizedStatus == null) {
            return;
        }

        if (existing.Status__c != normalizedStatus) {
            existing.Status__c = normalizedStatus;
            update existing;
        }
    }

    public static String normalizePhone(String phoneNumber) {
        if (String.isBlank(phoneNumber)) {
            return null;
        }
        String digits = phoneNumber.replaceAll('[^0-9]', '');
        if (String.isBlank(digits)) {
            return null;
        }
        return digits.length() >= 10
            ? digits.substring(digits.length() - 10)
            : digits;
    }

    private static String normalizeMessageType(String messageType) {
        if (String.isBlank(messageType)) {
            return 'Text';
        }
        String cleaned = messageType.trim().toLowerCase();
        if (cleaned == 'text') return 'Text';
        if (cleaned == 'image') return 'Image';
        if (cleaned == 'file' || cleaned == 'document') return 'File';
        if (cleaned == 'audio') return 'Audio';
        if (cleaned == 'video') return 'Video';
        if (cleaned == 'location') return 'Location';
        if (cleaned == 'sticker') return 'Sticker';
        return 'Text';
    }

    private static String normalizeStatus(String statusValue) {
        if (String.isBlank(statusValue)) {
            return null;
        }
        String cleaned = statusValue.trim().toLowerCase();
        String mapped;
        if (cleaned == 'sent') mapped = 'Sent';
        else if (cleaned == 'delivered') mapped = 'Delivered';
        else if (cleaned == 'read') mapped = 'Read';
        else if (cleaned == 'failed') mapped = 'Failed';
        else if (cleaned == 'pending') mapped = 'Pending';
        else mapped = null;

        return mapped != null && ALLOWED_STATUS.contains(mapped) ? mapped : null;
    }

    private static WhatsApp_Message__c findByMessageId(String messageId) {
        List<WhatsApp_Message__c> existing = [
            SELECT Id, Status__c
            FROM WhatsApp_Message__c
            WHERE WhatsApp_Message_Id__c = :messageId
            LIMIT 1
        ];
        return existing.isEmpty() ? null : existing[0];
    }

    private static void touchContactForInbound(Id whatsappContactId) {
        if (whatsappContactId == null) {
            return;
        }
        WhatsApp_Contact__c contactToUpdate = [
            SELECT Id, Unread_Count__c
            FROM WhatsApp_Contact__c
            WHERE Id = :whatsappContactId
            LIMIT 1
        ];
        Decimal unreadCount = contactToUpdate.Unread_Count__c == null
            ? 0
            : contactToUpdate.Unread_Count__c;
        contactToUpdate.Unread_Count__c = unreadCount + 1;
        contactToUpdate.Last_Message_Date__c = System.now();
        update contactToUpdate;
    }

    
}