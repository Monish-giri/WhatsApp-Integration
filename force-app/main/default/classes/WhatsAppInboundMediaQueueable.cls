public class WhatsAppInboundMediaQueueable implements Queueable, Database.AllowsCallouts {
    private Id messageId;
    private String mediaIdOrLink;
    private String msgType;
    private String fileName;
    private String mimeType;
    private Id contactId;

    public WhatsAppInboundMediaQueueable(
        Id messageId,
        String mediaIdOrLink,
        String msgType,
        String fileName,
        String mimeType,
        Id contactId
    ) {
        this.messageId = messageId;
        this.mediaIdOrLink = mediaIdOrLink;
        this.msgType = msgType;
        this.fileName = fileName;
        this.mimeType = mimeType;
        this.contactId = contactId;
    }

    public void execute(QueueableContext context) {
        WhatsAppMediaService.attachMediaToInboundMessage(
            messageId,
            mediaIdOrLink,
            msgType,
            fileName,
            mimeType,
            contactId
        );
    }
}
