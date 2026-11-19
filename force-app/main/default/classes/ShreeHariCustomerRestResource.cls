/**
 * Inbound REST endpoint that records Shopify customers in Staging_Customer__c.
 *
 *   POST /services/apexrest/shreehari/v1/customers
 *
 * One customer per call, in the plain Shopify customer shape
 * (https://shopify.dev/docs/api/liquid/objects/customer). A body of the form
 * {"customer": {...}} is also accepted and unwrapped.
 *
 * Every call creates a new Staging Customer record (SC-1, SC-2, ...), so the
 * object is a complete history of what was sent. Each documented property has
 * a field named after it (first_name -> First_Name__c, id -> Id__c,
 * has_avatar? -> Has_Avatar__c). The documentation gives no property a fixed
 * set of values, so there are no picklists. Nothing is converted:
 *
 *   - text, number and true/false properties go to typed fields; numbers and
 *     true/false may also arrive as strings ("5600", "true");
 *   - arrays and nested objects (addresses, default_address, orders,
 *     last_order, tags, metafields, ...) are stored as JSON text; a plain
 *     string (e.g. tags sent as "vip, newsletter") is kept exactly as sent;
 *   - any key that is not a documented customer property is kept in
 *     Additional_Properties__c, so no information is dropped.
 *
 * id is the only required property. null, and an empty string sent for a
 * number or true/false property, mean "no value" and leave the field blank.
 * When a value cannot be stored (wrong type, longer than its field) the whole
 * call is rejected with 400 and a body naming the property and the reason;
 * nothing is saved.
 *
 * Responses use the same envelope as the Product and Order APIs:
 *   201 {success, stagingCustomerId, stagingCustomerNumber, shopifyCustomerId, message}
 *   4xx/5xx {success:false, errorCode, message, field, httpStatus}
 *
 * Authentication is handled by the platform (Shree Hari Website API External
 * Client App); the integration user needs access to this class and create
 * and read access on Staging_Customer__c and its fields.
 */
@RestResource(urlMapping='/shreehari/v1/customers/*')
global with sharing class ShreeHariCustomerRestResource {

    private static final String CONTENT_TYPE = 'application/json; charset=UTF-8';
    @TestVisible
    private static final String STATUS_NEW = 'New';

    private enum Kind { TEXT, NUM, BOOL, JSON_TEXT }

    /**
     * Shopify property -> Staging_Customer__c field, in documentation order.
     * Keys ending in "?" are the Liquid names; the same name without "?" is
     * accepted as well.
     */
    @TestVisible
    private static final List<Mapping> MAPPINGS = new List<Mapping>{
        new Mapping('accepts_marketing', Staging_Customer__c.Accepts_Marketing__c, Kind.BOOL),
        new Mapping('addresses', Staging_Customer__c.Addresses__c, Kind.JSON_TEXT),
        new Mapping('addresses_count', Staging_Customer__c.Addresses_Count__c, Kind.NUM),
        new Mapping('b2b?', Staging_Customer__c.B2B__c, Kind.BOOL),
        new Mapping('company_available_locations', Staging_Customer__c.Company_Available_Locations__c, Kind.JSON_TEXT),
        new Mapping('company_available_locations_count', Staging_Customer__c.Company_Available_Locations_Count__c, Kind.NUM),
        new Mapping('current_company', Staging_Customer__c.Current_Company__c, Kind.JSON_TEXT),
        new Mapping('current_location', Staging_Customer__c.Current_Location__c, Kind.JSON_TEXT),
        new Mapping('default_address', Staging_Customer__c.Default_Address__c, Kind.JSON_TEXT),
        new Mapping('email', Staging_Customer__c.Email__c, Kind.TEXT),
        new Mapping('first_name', Staging_Customer__c.First_Name__c, Kind.TEXT),
        new Mapping('has_account', Staging_Customer__c.Has_Account__c, Kind.BOOL),
        new Mapping('has_avatar?', Staging_Customer__c.Has_Avatar__c, Kind.BOOL),
        new Mapping('id', Staging_Customer__c.Id__c, Kind.TEXT),
        new Mapping('last_name', Staging_Customer__c.Last_Name__c, Kind.TEXT),
        new Mapping('last_order', Staging_Customer__c.Last_Order__c, Kind.JSON_TEXT),
        new Mapping('metafields', Staging_Customer__c.Metafields__c, Kind.JSON_TEXT),
        new Mapping('name', Staging_Customer__c.Name__c, Kind.TEXT),
        new Mapping('orders', Staging_Customer__c.Orders__c, Kind.JSON_TEXT),
        new Mapping('orders_count', Staging_Customer__c.Orders_Count__c, Kind.NUM),
        new Mapping('payment_methods', Staging_Customer__c.Payment_Methods__c, Kind.JSON_TEXT),
        new Mapping('phone', Staging_Customer__c.Phone__c, Kind.TEXT),
        new Mapping('store_credit_account', Staging_Customer__c.Store_Credit_Account__c, Kind.JSON_TEXT),
        new Mapping('tags', Staging_Customer__c.Tags__c, Kind.JSON_TEXT),
        new Mapping('tax_exempt', Staging_Customer__c.Tax_Exempt__c, Kind.BOOL),
        new Mapping('total_spent', Staging_Customer__c.Total_Spent__c, Kind.NUM)
    };

    @TestVisible
    private static final String ADDITIONAL_PROPERTIES = 'additional properties';

    // =====================================================================
    // HTTP entry point
    // =====================================================================

    @HttpPost
    global static void receiveCustomer() {
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

            Staging_Customer__c record = buildRecord(parse(body));
            try {
                insert record;
            } catch (DmlException e) {
                throw error('DML_EXCEPTION', 500, null, e.getDmlMessage(0));
            }

            Staging_Customer__c saved = [
                SELECT Id, Name, Id__c FROM Staging_Customer__c WHERE Id = :record.Id WITH SYSTEM_MODE
            ];
            CustomerResponse result = new CustomerResponse();
            result.success = true;
            result.stagingCustomerId = saved.Id;
            result.stagingCustomerNumber = saved.Name;
            result.shopifyCustomerId = saved.Id__c;
            result.message = 'Customer received and stored as ' + saved.Name + '.';

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
            throw badRequest('INVALID_JSON', null, 'Request body is empty. Send one Shopify customer as a JSON object.');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(body);
        } catch (Exception e) {
            throw badRequest('INVALID_JSON', null, 'Request body could not be parsed as JSON: ' + e.getMessage());
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw badRequest('INVALID_JSON', null, 'Request body must be one customer as a JSON object (one customer per call).');
        }
        Map<String, Object> customer = (Map<String, Object>) parsed;

        // {"customer": {...}}, the Shopify Admin API / webhook wrapper
        if (customer.size() == 1 && customer.get('customer') instanceof Map<String, Object>) {
            customer = (Map<String, Object>) customer.get('customer');
        }
        return customer;
    }

    // =====================================================================
    // Mapping
    // =====================================================================

    private static Staging_Customer__c buildRecord(Map<String, Object> customer) {
        Staging_Customer__c record = new Staging_Customer__c(Processing_Status__c = STATUS_NEW);
        Set<String> used = new Set<String>();

        for (Mapping m : MAPPINGS) {
            String key = m.keyIn(customer);
            if (key == null) {
                continue;
            }
            used.add(key);
            Object value = customer.get(key);
            if (value == null || isBlankForTypedField(m, value)) {
                continue;
            }
            record.put(m.field, convert(m, key, value));
        }

        if (String.isBlank(record.Id__c)) {
            throw badRequest('MISSING_REQUIRED_FIELD', 'id', 'id is required: the Shopify customer ID.');
        }

        Map<String, Object> additional = new Map<String, Object>();
        for (String key : customer.keySet()) {
            if (!used.contains(key)) {
                additional.put(key, customer.get(key));
            }
        }
        if (!additional.isEmpty()) {
            String text = JSON.serialize(additional);
            checkLength(Staging_Customer__c.Additional_Properties__c, ADDITIONAL_PROPERTIES, text);
            record.Additional_Properties__c = text;
        }
        return record;
    }

    /** An empty string has no meaning for a number or true/false: it is "no value". */
    private static Boolean isBlankForTypedField(Mapping m, Object value) {
        return (m.kind == Kind.NUM || m.kind == Kind.BOOL)
            && value instanceof String && String.isBlank((String) value);
    }

    private static Object convert(Mapping m, String key, Object value) {
        switch on m.kind {
            when TEXT {
                if (value instanceof Map<String, Object> || value instanceof List<Object>) {
                    throw badRequest('INVALID_TYPE', key, key + ' must be text, but an object or array was sent.');
                }
                String text = String.valueOf(value);
                checkLength(m.field, key, text);
                return text;
            }
            when NUM {
                return toNumber(m.field, key, value);
            }
            when BOOL {
                return toBoolean(key, value);
            }
            when else {
                String text = (value instanceof String) ? (String) value : JSON.serialize(value);
                checkLength(m.field, key, text);
                return text;
            }
        }
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
        public String keyIn(Map<String, Object> customer) {
            if (customer.containsKey(key)) {
                return key;
            }
            String plain = key.removeEnd('?');
            return (plain != key && customer.containsKey(plain)) ? plain : null;
        }
    }

    global class CustomerResponse {
        public Boolean success;
        public Id stagingCustomerId;
        public String stagingCustomerNumber;
        public String shopifyCustomerId;
        public String message;
    }

    public class ApiException extends Exception {
        public String errorCode;
        public Integer httpStatus;
        public String jsonField;
    }
}
