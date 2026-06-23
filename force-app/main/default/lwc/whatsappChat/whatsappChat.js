import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { refreshApex } from '@salesforce/apex';

import getChatThread from '@salesforce/apex/WhatsAppChatController.getChatThread';
import sendChatPayload from '@salesforce/apex/WhatsAppChatController.sendChatPayload';
import uploadEmployeeFile from '@salesforce/apex/WhatsAppChatController.uploadEmployeeFile';
import markThreadRead from '@salesforce/apex/WhatsAppChatController.markThreadRead';

const CDC_REFRESH_DEBOUNCE_MS = 300;

export default class WhatsappChat extends LightningElement {
    _recordId;
    @track messages = [];
    newMessage = '';
    isSending = false;
    isUploading = false;
    pendingAttachmentId = null;
    pendingAttachmentName = '';
    scrollUiTimer;
    focusInputTimer;
    cdcRefreshTimer;
    lastSeenMessageId = null;
    showScrollToLatest = false;
    channelName = '/data/WhatsApp_Message__ChangeEvent';
    subscription = null;
    whatsAppContactId = null;
    wiredThreadResult;

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        const prev = this._recordId;
        this._recordId = value;
        if (value && value !== prev) {
            this.markAsRead();
        }
        if (!value) {
            this.messages = [];
            this.whatsAppContactId = null;
        }
    }

    @wire(getChatThread, { recordId: '$recordId' })
    wiredChatThread(result) {
        this.wiredThreadResult = result;
        if (result.data) {
            this.applyThreadData(result.data, true);
        } else if (result.error) {
            // eslint-disable-next-line no-console
            console.error('WhatsApp chat wire load failed:', result.error);
        }
    }

    connectedCallback() {
        this.subscribeToCDC();
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(this.subscription, () => {});
            this.subscription = null;
        }
        window.clearTimeout(this.scrollUiTimer);
        window.clearTimeout(this.focusInputTimer);
        window.clearTimeout(this.cdcRefreshTimer);
    }

    handleChange(event) {
        this.newMessage = event.target.value;
    }

    handleKeyDown(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            this.handleSend();
        }
    }

    subscribeToCDC() {
        const messageCallback = (message) => {
            if (this.isRelevantChangeEvent(message)) {
                this.scheduleThreadRefresh();
            }
        };

        subscribe(this.channelName, -1, messageCallback)
            .then((response) => {
                this.subscription = response;
            })
            .catch((error) => {
                // eslint-disable-next-line no-console
                console.error('WhatsApp chat CDC subscribe failed:', error);
            });

        onError((error) => {
            // eslint-disable-next-line no-console
            console.error('WhatsApp chat CDC stream error:', error);
        });
    }

    scheduleThreadRefresh() {
        window.clearTimeout(this.cdcRefreshTimer);
        this.cdcRefreshTimer = window.setTimeout(() => {
            this.refreshThreadFromServer();
        }, CDC_REFRESH_DEBOUNCE_MS);
    }

    async refreshThreadFromServer() {
        if (!this.wiredThreadResult) {
            return;
        }
        try {
            await refreshApex(this.wiredThreadResult);
        } catch (error) {
            // eslint-disable-next-line no-console
            console.error('WhatsApp chat refresh failed:', error);
        }
    }

    isRelevantChangeEvent(message) {
        if (!this.recordId) {
            return false;
        }
        if (!this.whatsAppContactId) {
            return true;
        }

        const payload = message?.data?.payload;
        if (!payload) {
            return true;
        }

        const parentId = payload.WhatsApp_Contact__c;
        if (parentId) {
            return parentId === this.whatsAppContactId;
        }

        return true;
    }

    async handleSend() {
        if (this.isSending) {
            return;
        }

        const hasText = this.newMessage && this.newMessage.trim() !== '';
        const hasAttachment = !!this.pendingAttachmentId;
        if (!hasText && !hasAttachment) {
            return;
        }

        this.isSending = true;
        try {
            const result = await sendChatPayload({
                recordId: this.recordId,
                messageText: hasText ? this.newMessage.trim() : '',
                contentVersionId: this.pendingAttachmentId
            });
            if (result !== 'SUCCESS') {
                throw new Error(result);
            }

            this.newMessage = '';
            this.pendingAttachmentId = null;
            this.pendingAttachmentName = '';
            // UI updates via CDC when the Pending row is inserted (and again when Queueable sets Sent).
        } catch (error) {
            const message = this.extractErrorMessage(error, 'Unable to send message.');
            // eslint-disable-next-line no-console
            console.error('Send error details:', error);
            this.showToast('Send failed', message, 'error');
        } finally {
            this.isSending = false;
        }
    }

    handleAttachClick() {
        if (!this.recordId || this.isUploading) {
            return;
        }
        const fileInput = this.template.querySelector('.attach-file-input');
        if (fileInput) {
            fileInput.click();
        }
    }

    async handleFileSelected(event) {
        const file = event.target.files && event.target.files[0];
        event.target.value = null;
        if (!file || !this.recordId) {
            return;
        }

        const maxFileBytes = 4 * 1024 * 1024;
        if (file.size > maxFileBytes) {
            this.showToast('File too large', 'Please upload a file up to 4 MB.', 'warning');
            return;
        }

        this.isUploading = true;
        try {
            const base64Data = await this.readFileAsBase64(file);
            const versionId = await uploadEmployeeFile({
                recordId: this.recordId,
                fileName: file.name,
                base64Data
            });

            this.pendingAttachmentId = versionId;
            this.pendingAttachmentName = file.name;
            this.showToast('Attachment ready', `${file.name} will be sent on Send.`, 'success');
            this.focusMessageInput();
        } catch (error) {
            const message = error?.body?.message || error?.message || 'Unable to attach file.';
            this.showToast('Upload failed', message, 'error');
        } finally {
            this.isUploading = false;
        }
    }

    applyThreadData(thread, scrollAfterRender) {
        this.whatsAppContactId = thread?.whatsAppContactId || null;
        const data = thread?.messages || [];

        const chatContainer = this.template.querySelector('.chat-container');
        const shouldStickToBottom =
            scrollAfterRender && (!chatContainer || this.isNearBottom(chatContainer));

        this.messages = data.map((row) => {
            const directionRaw = String(row.direction || '').trim().toLowerCase();
            const isOutgoing = new Set(['sent', 'outbound', 'outgoing', 'out']).has(directionRaw);

            const attachmentLabel =
                row.fileName ||
                row.message ||
                (row.isImageAttachment ? 'Photo' : 'Attachment');

            return {
                id: row.id,
                message: row.message,
                direction: row.direction,
                createdDate: row.createdDate,
                fileName: row.fileName,
                attachmentLabel,
                previewUrl: row.previewUrl,
                downloadUrl: row.downloadUrl,
                isAttachment: row.isAttachment,
                isImageAttachment: row.isImageAttachment,
                cssClass: isOutgoing ? 'message-row outgoing' : 'message-row incoming',
                displayTime: this.formatTime(row.createdDate)
            };
        });

        this.lastSeenMessageId =
            this.messages.length > 0 ? this.messages[this.messages.length - 1].id : null;

        if (!scrollAfterRender) {
            return;
        }

        window.clearTimeout(this.scrollUiTimer);
        this.scrollUiTimer = window.setTimeout(() => {
            if (shouldStickToBottom) {
                this.scrollToBottom(false);
            }
            this.updateScrollButtonVisibility();
        }, 0);
    }

    async markAsRead() {
        if (!this.recordId) {
            return;
        }
        try {
            await markThreadRead({ recordId: this.recordId });
        } catch (error) {
            // no-op
        }
    }

    formatTime(dateValue) {
        if (!dateValue) {
            return '';
        }
        const dt = new Date(dateValue);
        return dt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }

    readFileAsBase64(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => {
                const result = String(reader.result || '');
                const commaIndex = result.indexOf(',');
                resolve(commaIndex >= 0 ? result.substring(commaIndex + 1) : result);
            };
            reader.onerror = () => reject(new Error('Failed to read file.'));
            reader.readAsDataURL(file);
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractErrorMessage(error, fallbackMessage) {
        if (!error) {
            return fallbackMessage;
        }

        const body = error.body || {};
        const output = body.output || {};
        const pageErrors = output.errors || [];
        const fieldErrors = output.fieldErrors || {};

        if (body.message) {
            return body.message;
        }
        if (pageErrors.length && pageErrors[0]?.message) {
            return pageErrors[0].message;
        }
        for (const fieldName of Object.keys(fieldErrors)) {
            const first = fieldErrors[fieldName] && fieldErrors[fieldName][0];
            if (first && first.message) {
                return first.message;
            }
        }
        if (error.message) {
            return error.message;
        }
        return fallbackMessage;
    }

    handleChatScroll() {
        this.updateScrollButtonVisibility();
    }

    handleScrollToLatest() {
        this.scrollToBottom(true);
        this.showScrollToLatest = false;
    }

    updateScrollButtonVisibility() {
        const chatContainer = this.template.querySelector('.chat-container');
        if (!chatContainer) {
            this.showScrollToLatest = false;
            return;
        }
        const canScroll = chatContainer.scrollHeight - chatContainer.clientHeight > 20;
        this.showScrollToLatest = canScroll && !this.isNearBottom(chatContainer);
    }

    isNearBottom(container) {
        const distance = container.scrollHeight - container.scrollTop - container.clientHeight;
        return distance <= 40;
    }

    scrollToBottom(smooth) {
        const chatContainer = this.template.querySelector('.chat-container');
        if (!chatContainer) {
            return;
        }
        chatContainer.scrollTo({
            top: chatContainer.scrollHeight,
            behavior: smooth ? 'smooth' : 'auto'
        });
    }

    focusMessageInput() {
        window.clearTimeout(this.focusInputTimer);
        this.focusInputTimer = window.setTimeout(() => {
            const inputCmp = this.template.querySelector('lightning-input.chat-input');
            if (inputCmp && typeof inputCmp.focus === 'function') {
                inputCmp.focus();
            }
        }, 0);
    }
}
