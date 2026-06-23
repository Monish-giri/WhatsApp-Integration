public with sharing class WhatsAppOutboundQueueable implements Queueable, Database.AllowsCallouts {
    private WhatsAppOutboundService.OutboundRequest requestPayload;

    public WhatsAppOutboundQueueable(WhatsAppOutboundService.OutboundRequest requestPayload) {
        this.requestPayload = requestPayload;
    }

    public void execute(QueueableContext context) {
        try {
            System.debug(LoggingLevel.INFO, 'WA_QUEUE start request=' + JSON.serialize(requestPayload));
            String metaMessageId = WhatsAppOutboundService.sendMessage(requestPayload);
            System.debug(LoggingLevel.INFO, 'WA_QUEUE success metaMessageId=' + metaMessageId);
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'WA_QUEUE failed error=' + ex.getMessage() +
                ' stack=' + ex.getStackTraceString());
            if (requestPayload != null && requestPayload.whatsappMessageId != null) {
                WhatsAppMessageService.failOutboundMessage(
                    requestPayload.whatsappMessageId,
                    ex.getMessage()
                );
            }
        }
    }
}
