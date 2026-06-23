trigger WhatAppContactTrigger on WhatsApp_Contact__c (before insert, before update) 
{
	WhatsAppContactTriggerHandler obj = new WhatsAppContactTriggerHandler();
    obj.doAction();
}