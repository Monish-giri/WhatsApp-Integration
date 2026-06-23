public class WhatsAppWebhookWrapper 
{
    public List<Entry> entry;

    public class Entry 
    {
        public List<Change> changes;
    }

    public class Change 
    {
        public Value value;
    }

    public class Value 
    {
        public List<Message> messages;
        public List<ContactRef> contacts;
        public List<StatusUpdate> statuses;
    }

    public class Message 
    {
        public String id;
        public String timestamp;
        public String type;
        public Text text;
        public Media image;
        public Media audio;
        public Media video;
        public Media document;
    }

    public class Text 
    {
        public String body;
    }

    public class Media {
        public String id;
        public String mime_type;
        public String sha256;
        public String filename;
    }

    public class ContactRef {
        public String wa_id;
    }

    public class StatusUpdate {
        public String id;
        public String status;
        public String timestamp;
    }
}