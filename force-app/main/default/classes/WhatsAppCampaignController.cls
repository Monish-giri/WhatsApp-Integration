public with sharing class WhatsAppCampaignController {
    
    
    
    
    public class TemplateOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        
        public TemplateOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<TemplateOption> getTemplates() {
        
        List<TemplateOption> options = new List<TemplateOption>();
        
        for(WhatsApp_Template__mdt temp :
            [SELECT MasterLabel,
             Template_Name__c
             FROM WhatsApp_Template__mdt
             WHERE Active__c = true]) {
                 
                 options.add(
                     new TemplateOption(
                         temp.MasterLabel,
                         temp.Template_Name__c
                     )
                 );
             }
        
        return options;
    }
    
    @AuraEnabled
    public static String sendCampaignMessage(
        Id campaignId,
        String templateName,
        String variableText
    )
    {
        List<CampaignMember> members = [
            SELECT Id,
            Phone
            FROM CampaignMember
            WHERE CampaignId = :campaignId
            AND Phone != null
        ];
        
        WhatsApp_Config__mdt config = [
            SELECT Verify_Token__c,
            Phone_Number_Id__c
            FROM WhatsApp_Config__mdt
            LIMIT 1
        ];
        
        Integer sentCount = 0;
        List<String> responses = new List<String>();
        
        for(CampaignMember cm : members)
        {
            try
            {
                HttpRequest req = new HttpRequest();
                
                req.setEndpoint(
                    'https://graph.facebook.com/v23.0/' +
                    config.Phone_Number_Id__c +
                    '/messages'
                );
                
                req.setMethod('POST');
                
                req.setHeader(
                    'Authorization',
                    'Bearer ' + config.Verify_Token__c
                );
                
                req.setHeader(
                    'Content-Type',
                    'application/json'
                );
                
                Map<String,Object> payload = new Map<String,Object>();
                
                payload.put(
                    'messaging_product',
                    'whatsapp'
                );
                
                payload.put(
                    'to',
                    cm.Phone
                );
                
                payload.put(
                    'type',
                    'template'
                );
                
                Map<String,Object> template = new Map<String,Object>();
                
                template.put(
                    'name',
                    templateName
                );
                
                template.put(
                    'language',
                    new Map<String,Object>{
                        'code' => 'en'
                            }
                );
                
                template.put(
                    'components',
                    new List<Object>{
                        new Map<String,Object>{
                            'type' => 'body',
                                'parameters' => new List<Object>{
                                    new Map<String,Object>{
                                        'type' => 'text',
                                            'text' => variableText
                                            }
                                }
                        }
                    }
                );
                
                payload.put(
                    'template',
                    template
                );
                
                req.setBody(
                    JSON.serialize(payload)
                );
                
                HttpResponse res =
                    new Http().send(req);
                
                responses.add(
                    'Phone=' + cm.Phone +
                    ' Status=' + res.getStatusCode() +
                    ' Response=' + res.getBody()
                );
                
                if(res.getStatusCode() >= 200 &&
                   res.getStatusCode() < 300)
                {
                    sentCount++;
                    
                    String normalizedPhone =
                        cm.Phone.replace('+','')
                        .replace(' ','')
                        .replace('-','');
                    
                    String last10 =
                        normalizedPhone.length() > 10
                        ? normalizedPhone.right(10)
                        : normalizedPhone;
                    
                    List<WhatsApp_Contact__c> contacts = [
                        SELECT Id,
                        Phone__c
                        FROM WhatsApp_Contact__c
                        WHERE Phone__c LIKE :('%' + last10)
                        LIMIT 1
                    ];
                    
                    if(!contacts.isEmpty())
                    {
                        WhatsApp_Message__c msg =
                            new WhatsApp_Message__c();
                        
                        msg.WhatsApp_Contact__c = contacts[0].Id;
                        
                        msg.Direction__c = 'Outbound';
                        msg.Status__c = 'Sent';
                        msg.Message_Type__c = 'Text';
                        
                        msg.Message_Body__c = variableText;
                        
                        msg.Sent_At__c = System.now();
                        
                        try
                        {
                            Map<String,Object> responseMap =
                                (Map<String,Object>)JSON.deserializeUntyped(
                                    res.getBody()
                                );
                            
                            List<Object> messageList =
                                (List<Object>)responseMap.get('messages');
                            
                            if(messageList != null &&
                               !messageList.isEmpty())
                            {
                                Map<String,Object> firstMessage =
                                    (Map<String,Object>)messageList[0];
                                
                                msg.WhatsApp_Message_Id__c =
                                    (String)firstMessage.get('id');
                            }
                        }
                        catch(Exception ex)
                        {
                            System.debug(
                                'Unable to parse WhatsApp Message Id: ' +
                                ex.getMessage()
                            );
                        }
                        
                        insert msg;
                    }
                }
            }
            catch(Exception e)
            {
                responses.add(
                    'Phone=' + cm.Phone +
                    ' Error=' + e.getMessage()
                );
            }
        }
        
        return
            'Sent=' + sentCount +
            ' Total=' + members.size() +
            ' Details=' + String.join(responses, ' | ');
    }
}