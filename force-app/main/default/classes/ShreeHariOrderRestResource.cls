/**
 * Inbound REST endpoint that records Shopify orders in Staging_Order__c.
 *
 *   POST /services/apexrest/shreehari/v1/orders
 *
 * One order per call, in the plain Shopify order shape
 * (https://shopify.dev/docs/api/liquid/objects/order). A body of the form
 * {"order": {...}} is also accepted and unwrapped.
 *
 * Every call creates a new Staging Order record (SO-1, SO-2, ...), so the
 * object is a complete history of what was sent. Each documented property has
 * a field named after it (financial_status -> Financial_Status__c, id -> Id__c,
 * pickup_in_store? -> Pickup_In_Store__c). Nothing is converted:
 *
 *   - text, number, true/false and timestamp properties go to typed fields;
 *     numbers and true/false may also arrive as strings ("49293", "true");
 *   - properties documented as a string from a set of values are picklists.
 *     cancel_reason and financial_status accept only the documented values,
 *     spelled exactly as documented. fulfillment_status_label carries the
 *     documented values but, being a localized label, any other text is
 *     stored as sent (text that differs from a documented value only in
 *     letter case, such as "Partial", is stored by Salesforce as the
 *     documented value, partial);
 *   - arrays and nested objects (line_items, customer, billing_address,
 *     shipping_address, transactions, tax_lines, metafields, ...) are stored
 *     as JSON text; a plain string (e.g. tags sent as "gift, rush") is kept
 *     exactly as sent;
 *   - any key that is not a documented order property is kept in
 *     Additional_Properties__c, so no information is dropped.
 *
 * id is the only required property. null, and an empty string sent for a
 * number, true/false, timestamp or picklist property, mean "no value" and
 * leave the field blank. When a value cannot be stored (wrong type, value
 * outside the documented set, unreadable timestamp, longer than its field)
 * the whole call is rejected with 400 and a body naming the property and the
 * reason; nothing is saved.
 *
 * Responses use the same envelope as the Product and Customer APIs:
 *   201 {success, stagingOrderId, stagingOrderNumber, shopifyOrderId, message}
 *   4xx/5xx {success:false, errorCode, message, field, httpStatus}
 *
 * Authentication is handled by the platform (Shree Hari Website API External
 * Client App); the integration user needs the Shree Hari Order API Access
 * permission set.
 */
@RestResource(urlMapping='/shreehari/v1/orders/*')
global with sharing class ShreeHariOrderRestResource {

    private static final String CONTENT_TYPE = 'application/json; charset=UTF-8';
    @TestVisible
    private static final String STATUS_NEW = 'New';

    private enum Kind { TEXT, NUM, BOOL, DATE_TIME, PICKLIST, JSON_TEXT }

    /**
     * Shopify property -> Staging_Order__c field, in documentation order.
     * Keys ending in "?" are the Liquid names; the same name without "?" is
     * accepted as well.
     */
    @TestVisible
    private static final List<Mapping> MAPPINGS = new List<Mapping>{
        new Mapping('attributes', Staging_Order__c.Attributes__c, Kind.JSON_TEXT),
        new Mapping('billing_address', Staging_Order__c.Billing_Address__c, Kind.JSON_TEXT),
        new Mapping('cancel_reason', Staging_Order__c.Cancel_Reason__c, Kind.PICKLIST),
        new Mapping('cancel_reason_label', Staging_Order__c.Cancel_Reason_Label__c, Kind.TEXT),
        new Mapping('cancelled', Staging_Order__c.Cancelled__c, Kind.BOOL),
        new Mapping('cancelled_at', Staging_Order__c.Cancelled_At__c, Kind.DATE_TIME),
        new Mapping('cart_level_discount_applications', Staging_Order__c.Cart_Level_Discount_Applications__c, Kind.JSON_TEXT),
        new Mapping('confirmation_number', Staging_Order__c.Confirmation_Number__c, Kind.TEXT),
        new Mapping('created_at', Staging_Order__c.Created_At__c, Kind.DATE_TIME),
        new Mapping('customer', Staging_Order__c.Customer__c, Kind.JSON_TEXT),
        new Mapping('customer_order_url', Staging_Order__c.Customer_Order_Url__c, Kind.TEXT),
        new Mapping('customer_url', Staging_Order__c.Customer_Url__c, Kind.TEXT),
        new Mapping('discount_applications', Staging_Order__c.Discount_Applications__c, Kind.JSON_TEXT),
        new Mapping('discounts', Staging_Order__c.Discounts__c, Kind.JSON_TEXT),
        new Mapping('email', Staging_Order__c.Email__c, Kind.TEXT),
        new Mapping('financial_status', Staging_Order__c.Financial_Status__c, Kind.PICKLIST),
        new Mapping('financial_status_label', Staging_Order__c.Financial_Status_Label__c, Kind.TEXT),
        new Mapping('fulfillment_status', Staging_Order__c.Fulfillment_Status__c, Kind.TEXT),
        new Mapping('fulfillment_status_label', Staging_Order__c.Fulfillment_Status_Label__c, Kind.PICKLIST),
        new Mapping('id', Staging_Order__c.Id__c, Kind.TEXT),
        new Mapping('item_count', Staging_Order__c.Item_Count__c, Kind.NUM),
        new Mapping('line_items', Staging_Order__c.Line_Items__c, Kind.JSON_TEXT),
        new Mapping('line_items_subtotal_price', Staging_Order__c.Line_Items_Subtotal_Price__c, Kind.NUM),
        new Mapping('metafields', Staging_Order__c.Metafields__c, Kind.JSON_TEXT),
        new Mapping('name', Staging_Order__c.Name__c, Kind.TEXT),
        new Mapping('note', Staging_Order__c.Note__c, Kind.TEXT),
        new Mapping('order_number', Staging_Order__c.Order_Number__c, Kind.NUM),
        new Mapping('order_status_url', Staging_Order__c.Order_Status_Url__c, Kind.TEXT),
        new Mapping('phone', Staging_Order__c.Phone__c, Kind.TEXT),
        new Mapping('pickup_in_store?', Staging_Order__c.Pickup_In_Store__c, Kind.BOOL),
        new Mapping('shipping_address', Staging_Order__c.Shipping_Address__c, Kind.JSON_TEXT),
        new Mapping('shipping_methods', Staging_Order__c.Shipping_Methods__c, Kind.JSON_TEXT),
        new Mapping('shipping_price', Staging_Order__c.Shipping_Price__c, Kind.NUM),
        new Mapping('subtotal_line_items', Staging_Order__c.Subtotal_Line_Items__c, Kind.JSON_TEXT),
        new Mapping('subtotal_price', Staging_Order__c.Subtotal_Price__c, Kind.NUM),
        new Mapping('tags', Staging_Order__c.Tags__c, Kind.JSON_TEXT),
        new Mapping('tax_lines', Staging_Order__c.Tax_Lines__c, Kind.JSON_TEXT),
        new Mapping('tax_price', Staging_Order__c.Tax_Price__c, Kind.NUM),
        new Mapping('total_discounts', Staging_Order__c.Total_Discounts__c, Kind.NUM),
        new Mapping('total_duties', Staging_Order__c.Total_Duties__c, Kind.NUM),
        new Mapping('total_net_amount', Staging_Order__c.Total_Net_Amount__c, Kind.NUM),
        new Mapping('total_price', Staging_Order__c.Total_Price__c, Kind.NUM),
        new Mapping('total_refunded_amount', Staging_Order__c.Total_Refunded_Amount__c, Kind.NUM),
        new Mapping('transactions', Staging_Order__c.Transactions__c, Kind.JSON_TEXT)
    };

    @TestVisible
    private static final String ADDITIONAL_PROPERTIES = 'additional properties';

    // yyyy-MM-dd[T ]HH:mm:ss[.fff] then Z or an offset (+05:30, +0530, -04:00)
    private static final Pattern DATE_TIME_PATTERN = Pattern.compile(
        '^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?\\s*(Z|[+-]\\d{2}:?\\d{2})$'
    );

    // =====================================================================
    // HTTP entry point
    // =====================================================================

    @HttpPost
    global static void receiveOrder() {
        RestResponse response = RestContext.response;
        if (response == null) {
            response = new RestResponse();
            RestContext.response = response;
        }
        response.addHeader('Content-Type', CONTENT_TYPE);

        try {
            RestRequest request = RestContext.request;
            String body = (request != null && request.requestBody != null)
                ? request.requestBody.toString()
                : null;

            Staging_Order__c record = buildRecord(parse(body));
            try {
                insert record;
            } catch (DmlException e) {
                throw error('DML_EXCEPTION', 500, null, e.getDmlMessage(0));
            }

            Staging_Order__c saved = [
                SELECT Id, Name, Id__c FROM Staging_Order__c WHERE Id = :record.Id WITH SYSTEM_MODE
            ];
            OrderResponse result = new OrderResponse();
            result.success = true;
            result.stagingOrderId = saved.Id;
            result.stagingOrderNumber = saved.Name;
            result.shopifyOrderId = saved.Id__c;
            result.message = 'Order received and stored as ' + saved.Name + '.';

            response.statusCode = 201;
            response.responseBody = Blob.valueOf(JSON.serialize(result, true));

        } catch (ApiException e) {
            writeError(response, e.errorCode, e.httpStatus, e.jsonField, e.getMessage());
        } catch (Exception e) {
            writeError(response, 'DML_EXCEPTION', 500, null, e.getMessage());
        }
    }

    // =====================================================================
    // Parsing
    // =====================================================================

    private static Map<String, Object> parse(String body) {
        if (String.isBlank(body)) {
            throw badRequest('INVALID_JSON', null, 'Request body is empty. Send one Shopify order as a JSON object.');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(body);
        } catch (Exception e) {
            throw badRequest('INVALID_JSON', null, 'Request body could not be parsed as JSON: ' + e.getMessage());
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw badRequest('INVALID_JSON', null, 'Request body must be one order as a JSON object (one order per call).');
        }
        Map<String, Object> order = (Map<String, Object>) parsed;

        // {"order": {...}}, the Shopify Admin API / webhook wrapper
        if (order.size() == 1 && order.get('order') instanceof Map<String, Object>) {
            order = (Map<String, Object>) order.get('order');
        }
        return order;
    }

    // =====================================================================
    // Mapping
    // =====================================================================

    private static Staging_Order__c buildRecord(Map<String, Object> order) {
        Staging_Order__c record = new Staging_Order__c(Processing_Status__c = STATUS_NEW);
        Set<String> used = new Set<String>();

        for (Mapping m : MAPPINGS) {
            String key = m.keyIn(order);
            if (key == null) {
                continue;
            }
            used.add(key);
            Object value = order.get(key);
            if (value == null || isBlankForTypedField(m, value)) {
                continue;
            }
            record.put(m.field, convert(m, key, value));
        }

        if (String.isBlank(record.Id__c)) {
            throw badRequest('MISSING_REQUIRED_FIELD', 'id', 'id is required: the Shopify order ID.');
        }

        Map<String, Object> additional = new Map<String, Object>();
        for (String key : order.keySet()) {
            if (!used.contains(key)) {
                additional.put(key, order.get(key));
            }
        }
        if (!additional.isEmpty()) {
            String text = JSON.serialize(additional);
            checkLength(Staging_Order__c.Additional_Properties__c, ADDITIONAL_PROPERTIES, text);
            record.Additional_Properties__c = text;
        }
        return record;
    }

    /** An empty string has no meaning for a number, true/false, timestamp or picklist: it is "no value". */
    private static Boolean isBlankForTypedField(Mapping m, Object value) {
        return m.kind != Kind.TEXT && m.kind != Kind.JSON_TEXT
            && value instanceof String && String.isBlank((String) value);
    }

    private static Object convert(Mapping m, String key, Object value) {
        switch on m.kind {
            when TEXT {
                return toText(m.field, key, value);
            }
            when NUM {
                return toNumber(m.field, key, value);
            }
            when BOOL {
                return toBoolean(key, value);
            }
            when DATE_TIME {
                return toDatetime(key, value);
            }
            when PICKLIST {
                return toPicklistValue(m.field, key, value);
            }
            when else {
                String text = (value instanceof String) ? (String) value : JSON.serialize(value);
                checkLength(m.field, key, text);
                return text;
            }
        }
    }

    private static String toText(Schema.SObjectField field, String key, Object value) {
        if (value instanceof Map<String, Object> || value instanceof List<Object>) {
            throw badRequest('INVALID_TYPE', key, key + ' must be text, but an object or array was sent.');
        }
        String text = String.valueOf(value);
        checkLength(field, key, text);
        return text;
    }

    /**
     * A restricted picklist accepts only its own values, spelled exactly as
     * documented. An unrestricted one keeps whatever text was sent.
     */
    private static String toPicklistValue(Schema.SObjectField field, String key, Object value) {
        String text = toText(field, key, value);
        Schema.DescribeFieldResult d = field.getDescribe();
        if (!d.isRestrictedPicklist()) {
            return text;
        }
        List<String> allowed = new List<String>();
        for (Schema.PicklistEntry entry : d.getPicklistValues()) {
            if (entry.isActive()) {
                if (entry.getValue().equals(text)) {
                    return text;
                }
                allowed.add(entry.getValue());
            }
        }
        throw badRequest(
            'INVALID_VALUE',
            key,
            key + ' must be one of: ' + String.join(allowed, ', ') + '; but "' + text + '" was sent.'
        );
    }

    private static Decimal toNumber(Schema.SObjectField field, String key, Object value) {
        Decimal result;
        if (value instanceof Decimal || value instanceof Integer || value instanceof Long || value instanceof Double) {
            result = Decimal.valueOf(String.valueOf(value));
        } else if (value instanceof String) {
            try {
                result = Decimal.valueOf(((String) value).trim());
            } catch (Exception e) {
                result = null;
            }
        }
        if (result == null) {
            throw badRequest('INVALID_NUMBER', key, key + ' must be a number, but "' + String.valueOf(value) + '" was sent.');
        }
        Schema.DescribeFieldResult d = field.getDescribe();
        Integer maxDigits = d.getPrecision() - d.getScale();
        Integer digits = result.abs().setScale(0, RoundingMode.DOWN).toPlainString().length();
        if (digits > maxDigits) {
            throw badRequest('VALUE_TOO_LONG', key, key + ' is too large: at most ' + maxDigits + ' digits before the decimal point are allowed.');
        }
        return result;
    }

    private static Boolean toBoolean(String key, Object value) {
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        if (value instanceof String) {
            String text = ((String) value).trim().toLowerCase();
            if (text == 'true') {
                return true;
            }
            if (text == 'false') {
                return false;
            }
        }
        throw badRequest('INVALID_BOOLEAN', key, key + ' must be true or false, but "' + String.valueOf(value) + '" was sent.');
    }

    @TestVisible
    private static Datetime toDatetime(String key, Object value) {
        String text = (value instanceof String) ? ((String) value).trim() : null;
        Matcher match = (text == null) ? null : DATE_TIME_PATTERN.matcher(text);
        if (match == null || !match.matches()) {
            throw invalidDatetime(key, value);
        }
        Integer year = Integer.valueOf(match.group(1));
        Integer month = Integer.valueOf(match.group(2));
        Integer day = Integer.valueOf(match.group(3));
        Integer hour = Integer.valueOf(match.group(4));
        Integer minute = Integer.valueOf(match.group(5));
        Integer second = Integer.valueOf(match.group(6));
        if (month < 1 || month > 12 || day < 1 || day > Date.daysInMonth(year, month)
            || hour > 23 || minute > 59 || second > 59) {
            throw invalidDatetime(key, value);
        }
        Datetime result = Datetime.newInstanceGmt(year, month, day, hour, minute, second);

        String zone = match.group(7);
        if (zone != 'Z') {
            String digits = zone.substring(1).remove(':');
            Integer offsetMinutes = Integer.valueOf(digits.left(2)) * 60 + Integer.valueOf(digits.right(2));
            if (Integer.valueOf(digits.left(2)) > 14 || Integer.valueOf(digits.right(2)) > 59) {
                throw invalidDatetime(key, value);
            }
            // Local time minus its offset is GMT: 11:00-04:00 is 15:00Z
            result = result.addMinutes(zone.startsWith('+') ? -offsetMinutes : offsetMinutes);
        }
        return result;
    }

    private static ApiException invalidDatetime(String key, Object value) {
        return badRequest(
            'INVALID_DATE',
            key,
            key + ' must be a timestamp with a time zone, such as 2026-11-17T10:30:00+05:30, but "'
                + String.valueOf(value) + '" was sent.'
        );
    }

    private static void checkLength(Schema.SObjectField field, String key, String text) {
        Integer maxLength = field.getDescribe().getLength();
        if (text.length() > maxLength) {
            throw badRequest(
                'VALUE_TOO_LONG',
                key,
                key + ' is ' + text.length() + ' characters long; at most ' + maxLength + ' can be stored.'
            );
        }
    }

    // =====================================================================
    // Responses and errors
    // =====================================================================

    private static void writeError(
        RestResponse response,
        String errorCode,
        Integer httpStatus,
        String jsonField,
        String message
    ) {
        Integer status = (httpStatus == null) ? 500 : httpStatus;

        JSONGenerator json = JSON.createGenerator(true);
        json.writeStartObject();
        json.writeBooleanField('success', false);
        json.writeStringField('errorCode', errorCode);
        json.writeStringField('message', message == null ? '' : message);
        if (String.isNotBlank(jsonField)) {
            json.writeStringField('field', jsonField);
        }
        json.writeNumberField('httpStatus', status);
        json.writeEndObject();

        response.statusCode = status;
        response.responseBody = Blob.valueOf(json.getAsString());
    }

    private static ApiException error(String errorCode, Integer httpStatus, String jsonField, String message) {
        ApiException e = new ApiException(message);
        e.errorCode = errorCode;
        e.httpStatus = httpStatus;
        e.jsonField = jsonField;
        return e;
    }

    private static ApiException badRequest(String errorCode, String jsonField, String message) {
        return error(errorCode, 400, jsonField, message);
    }

    // =====================================================================
    // Inner types
    // =====================================================================

    @TestVisible
    private class Mapping {
        public final String key;
        public final Schema.SObjectField field;
        public final Kind kind;

        public Mapping(String key, Schema.SObjectField field, Kind kind) {
            this.key = key;
            this.field = field;
            this.kind = kind;
        }

        /** The key present in the payload: the documented name, or it without a trailing "?". */
        public String keyIn(Map<String, Object> order) {
            if (order.containsKey(key)) {
                return key;
            }
            String plain = key.removeEnd('?');
            return (plain != key && order.containsKey(plain)) ? plain : null;
        }
    }

    global class OrderResponse {
        public Boolean success;
        public Id stagingOrderId;
        public String stagingOrderNumber;
        public String shopifyOrderId;
        public String message;
    }

    public class ApiException extends Exception {
        public String errorCode;
        public Integer httpStatus;
        public String jsonField;
    }
}
