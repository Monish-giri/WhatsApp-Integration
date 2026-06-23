import { LightningElement, wire, api } from 'lwc';
import getTemplates from '@salesforce/apex/WhatsAppCampaignController.getTemplates';
import sendCampaignMessage from '@salesforce/apex/WhatsAppCampaignController.sendCampaignMessage';

export default class WhatsAppCampaignSender extends LightningElement {

    @api recordId;

    templateOptions = [];
    selectedTemplate;
    messageVariable;

    @wire(getTemplates)
    wiredTemplates({ data, error }) {
        if (data) {
            this.templateOptions = data;
        } else if (error) {
            console.error('Template Error', error);
        }
    }

    handleTemplateChange(event) {
        this.selectedTemplate = event.detail.value;
    }

    handleMessageChange(event) {
        this.messageVariable = event.target.value;
    }

    handleSend() {

        console.log('Campaign Id', this.recordId);
        console.log('Template', this.selectedTemplate);
        console.log('Variable', this.messageVariable);

        sendCampaignMessage({
            campaignId: this.recordId,
            templateName: this.selectedTemplate,
            variableText: this.messageVariable
        })
        .then(result => {
            console.log('Apex Success =>', result);
        })
        .catch(error => {
            console.error('Apex Error =>', JSON.stringify(error));
        });
    }

    renderedCallback() {
        console.log('recordId', this.recordId);
    }
}