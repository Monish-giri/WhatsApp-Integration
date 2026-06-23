public class WhatsAppContactTriggerHandler 
{
    List<WhatsApp_Contact__c> triggerNew;
    List<WhatsApp_Contact__c> triggerOld;
    Map<Id,WhatsApp_Contact__c> triggerNewMap;
    Map<Id,WhatsApp_Contact__c> triggerOldMap;
    
    // Constructor handles assignment of context variables
    public WhatsAppContactTriggerHandler()
    {
        triggerNew = (List<WhatsApp_Contact__c>)trigger.new;
        triggerOld = (List<WhatsApp_Contact__c>)trigger.old;
        triggerNewMap = (Map<Id,WhatsApp_Contact__c>)trigger.newMap;
        triggerOldMap = (Map<Id,WhatsApp_Contact__c>)trigger.oldMap;
    }
    
    // ─────────────────────────────────────────────
    // SINGLE ENTRY POINT (SWITCH METHOD)
    // ─────────────────────────────────────────────
    public  void doAction()
    {
        // Create an instance of the class to access instance variables and methods
        // create instance only if the method is static if else not required 
        //WhatsAppContactTriggerHandler handler = new WhatsAppContactTriggerHandler();
        
        switch on Trigger.operationType
        {
            when BEFORE_INSERT
            {
                matchPhoneNumbers(triggerNew, null);
            }
            when AFTER_INSERT
            {
                
            }
            when BEFORE_UPDATE
            {
                matchPhoneNumbers(triggerNew, triggerOldMap);
            }
            when AFTER_UPDATE
            {
               
            }
            when BEFORE_DELETE
            {
                
            }
            when AFTER_DELETE
            {
                
            }
            when AFTER_UNDELETE
            {
                
            }
        }
    }
    
    // ─────────────────────────────────────────────
    // CORE MATCHING LOGIC
    // ─────────────────────────────────────────────
    private void matchPhoneNumbers( List<WhatsApp_Contact__c> newList, Map<Id, WhatsApp_Contact__c> oldMap) 
    {
        Map<String, List<WhatsApp_Contact__c>> last10ToRecords = new Map<String, List<WhatsApp_Contact__c>>();
        
        for (WhatsApp_Contact__c rec : newList) 
        {
            Boolean isInsert    = (oldMap == null);
            Boolean phoneChanged = !isInsert
                && rec.Phone__c != oldMap.get(rec.Id).Phone__c;
            
            if (!isInsert && !phoneChanged) continue;
            
            rec.Contact__c             = null;
            rec.Account__c             = null;
            rec.Lead__c                = null;
            rec.Matched_Record_Type__c = 'Unmatched';
            
            if (String.isBlank(rec.Phone__c)) continue;

            String last10 = normalise(rec.Phone__c);
            if (String.isNotBlank(last10)) {
                rec.Phone__c = last10;
            }
            if (String.isNotBlank(last10)) {
                if (!last10ToRecords.containsKey(last10)) {
                    last10ToRecords.put(last10, new List<WhatsApp_Contact__c>());
                }
                last10ToRecords.get(last10).add(rec);
            }
        }
        
        if (last10ToRecords.isEmpty()) return;
        
        Set<String> targetPhones = last10ToRecords.keySet();
        
        Map<String, Id> contactMap = buildContactMap(targetPhones);
        Map<String, Id> accountMap = buildAccountMap(targetPhones);
        Map<String, Id> leadMap    = buildLeadMap(targetPhones);
        
        for (String last10 : last10ToRecords.keySet()) {
            Boolean hasContact = contactMap.containsKey(last10);
            Boolean hasAccount = accountMap.containsKey(last10);
            Boolean hasLead    = leadMap.containsKey(last10);
            
            for (WhatsApp_Contact__c rec : last10ToRecords.get(last10)) {
                if (hasContact) rec.Contact__c = contactMap.get(last10);
                if (hasAccount) rec.Account__c = accountMap.get(last10);
                if (hasLead)    rec.Lead__c    = leadMap.get(last10);
                
                if      (hasContact) rec.Matched_Record_Type__c = 'Contact';
                else if (hasAccount) rec.Matched_Record_Type__c = 'Account';
                else if (hasLead)    rec.Matched_Record_Type__c = 'Lead';
            }
        }
    }
    
    // ─────────────────────────────────────────────
    // QUERY HELPERS
    // ─────────────────────────────────────────────
    
    private Map<String, Id> buildContactMap(Set<String> targetPhones) {
        Map<String, Id> result = new Map<String, Id>();
        for (Contact c : [
            SELECT Id, MobilePhone, Phone 
            FROM Contact 
            WHERE MobilePhone != null OR Phone != null
        ]) {
            if (c.MobilePhone != null) {
                String norm = normalise(c.MobilePhone);
                if (targetPhones.contains(norm)) result.put(norm, c.Id);
            }
            if (c.Phone != null) {
                String norm = normalise(c.Phone);
                if (targetPhones.contains(norm) && !result.containsKey(norm)) {
                    result.put(norm, c.Id);
                }
            }
        }
        return result;
    }
    
    private Map<String, Id> buildAccountMap(Set<String> targetPhones) {
        Map<String, Id> result = new Map<String, Id>();
        for (Account a : [
            SELECT Id, Phone 
            FROM Account 
            WHERE Phone != null
        ]) {
            String norm = normalise(a.Phone);
            if (targetPhones.contains(norm)) {
                result.put(norm, a.Id);
            }
        }
        return result;
    }
    
    private Map<String, Id> buildLeadMap(Set<String> targetPhones) {
        Map<String, Id> result = new Map<String, Id>();
        for (Lead l : [
            SELECT Id, MobilePhone, Phone 
            FROM Lead 
            WHERE IsConverted = false AND (MobilePhone != null OR Phone != null)
        ]) {
            if (l.MobilePhone != null) {
                String norm = normalise(l.MobilePhone);
                if (targetPhones.contains(norm)) result.put(norm, l.Id);
            }
            if (l.Phone != null) {
                String norm = normalise(l.Phone);
                if (targetPhones.contains(norm) && !result.containsKey(norm)) {
                    result.put(norm, l.Id);
                }
            }
        }
        return result;
    }            
    
    // ─────────────────────────────────────────────
    // UTILITY
    // ─────────────────────────────────────────────
    
    private String normalise(String phone) {
        if (String.isBlank(phone)) return '';
        String digits = phone.replaceAll('[^0-9]', '');
        return digits.length() >= 10
            ? digits.substring(digits.length() - 10)
            : digits;
    }
}