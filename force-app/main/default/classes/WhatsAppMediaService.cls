public without sharing class WhatsAppMediaService {
    private static final String GRAPH_VERSION = 'v22.0';

    public static Id fetchMediaIntoSalesforce(
        String mediaIdOrLink,
        String msgType,
        String sourceFileName,
        String mimeType,
        Id publishToRecordId
    ) {
        try {
            String accessToken = getAccessToken();
            if (String.isBlank(accessToken)) {
                System.debug(LoggingLevel.ERROR, 'WA_MEDIA missing Meta access token');
                return null;
            }

            String downloadUrl = mediaIdOrLink;
            String detectedMime = mimeType;

            if (!String.valueOf(mediaIdOrLink).startsWith('http')) {
                Map<String, Object> mediaInfo = getMediaInfo(mediaIdOrLink, accessToken);
                downloadUrl = (String) mediaInfo.get('url');
                if (String.isBlank(detectedMime)) {
                    detectedMime = (String) mediaInfo.get('mime_type');
                }
            }

            if (String.isBlank(downloadUrl)) {
                return null;
            }

            Blob body = downloadMediaBlob(downloadUrl, accessToken);
            if (body == null || body.size() == 0) {
                return null;
            }

            String extension = msgType == 'image'
                ? fileExtensionFromMime(detectedMime)
                : documentExtensionFromMime(detectedMime);

            String generatedName = sourceFileName;
            if (String.isBlank(generatedName)) {
                generatedName = 'WhatsApp_' + msgType + '_' +
                    Datetime.now().formatGMT('yyyyMMdd_HHmmss') + '.' + extension;
            }

            Integer dotPos = generatedName.lastIndexOf('.');
            String title = dotPos > 0 ? generatedName.substring(0, dotPos) : generatedName;

            ContentVersion cv = new ContentVersion(
                Title = title,
                PathOnClient = generatedName,
                VersionData = body
            );
            insert cv;

            ContentVersion inserted = [
                SELECT ContentDocumentId
                FROM ContentVersion
                WHERE Id = :cv.Id
                LIMIT 1
            ];

            if (publishToRecordId != null && inserted.ContentDocumentId != null) {
                insert new ContentDocumentLink(
                    ContentDocumentId = inserted.ContentDocumentId,
                    LinkedEntityId = publishToRecordId,
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                );
            }

            return inserted.ContentDocumentId;
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR,
                'WA_MEDIA fetch/store failed: ' + ex.getMessage() +
                ' stack=' + ex.getStackTraceString());
            return null;
        }
    }

    public static void attachMediaToInboundMessage(
        Id messageId,
        String mediaIdOrLink,
        String msgType,
        String sourceFileName,
        String mimeType,
        Id contactId
    ) {
        Id contentDocumentId = fetchMediaIntoSalesforce(
            mediaIdOrLink,
            msgType,
            sourceFileName,
            mimeType,
            contactId
        );

        WhatsApp_Message__c updateRow = new WhatsApp_Message__c(Id = messageId);
        if (contentDocumentId != null) {
            updateRow.Media_URL__c = String.valueOf(contentDocumentId);
            updateRow.Error_Message__c = null;
        } else {
            updateRow.Error_Message__c = 'Media download failed';
        }
        update updateRow;
    }

    private static Map<String, Object> getMediaInfo(String mediaId, String accessToken) {
        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint(
            'https://graph.facebook.com/' + GRAPH_VERSION + '/' + EncodingUtil.urlEncode(mediaId, 'UTF-8')
        );
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        HttpResponse response = new Http().send(req);
        if (response.getStatusCode() >= 300) {
            throw new CalloutException(
                'Media metadata call failed (' + response.getStatusCode() + '): ' + response.getBody()
            );
        }
        return (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
    }

    private static Blob downloadMediaBlob(String mediaUrl, String accessToken) {
        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint(mediaUrl);
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        HttpResponse response = new Http().send(req);
        if (response.getStatusCode() >= 300) {
            throw new CalloutException(
                'Media download failed (' + response.getStatusCode() + '): ' + response.getBody()
            );
        }
        return response.getBodyAsBlob();
    }

    private static String getAccessToken() {
        WhatsApp_Config__mdt config = WhatsApp_Config__mdt.getInstance('Default');
        return config == null ? null : config.Verify_Token__c;
    }

    private static String fileExtensionFromMime(String mimeType) {
        if (String.isBlank(mimeType)) {
            return 'jpg';
        }
        String mt = mimeType.toLowerCase();
        if (mt.contains('png')) {
            return 'png';
        }
        if (mt.contains('gif')) {
            return 'gif';
        }
        if (mt.contains('webp')) {
            return 'webp';
        }
        if (mt.contains('heic')) {
            return 'heic';
        }
        if (mt.contains('jpeg') || mt.contains('jpg')) {
            return 'jpg';
        }
        return 'jpg';
    }

    private static String documentExtensionFromMime(String mimeType) {
        if (String.isBlank(mimeType)) {
            return 'bin';
        }
        String mt = mimeType.toLowerCase();
        if (mt.contains('pdf')) {
            return 'pdf';
        }
        if (mt.contains('word') || mt.contains('msword')) {
            return 'doc';
        }
        if (mt.contains('wordprocessingml')) {
            return 'docx';
        }
        if (mt.contains('excel') || mt.contains('spreadsheetml')) {
            return 'xlsx';
        }
        if (mt.contains('powerpoint') || mt.contains('presentationml')) {
            return 'pptx';
        }
        if (mt.contains('zip')) {
            return 'zip';
        }
        if (mt.contains('text/plain')) {
            return 'txt';
        }
        if (mt.contains('json')) {
            return 'json';
        }
        return 'bin';
    }
}
