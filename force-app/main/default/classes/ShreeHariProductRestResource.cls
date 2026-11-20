/**
 * Inbound REST endpoint that records Shopify products in Staging_Product__c
 * and their variants in Staging_Product_Variant__c.
 *
 *   POST /services/apexrest/shreehari/v1/products
 *
 * One product per call, in the plain Shopify product shape
 * (https://shopify.dev/docs/api/liquid/objects/product). A body of the form
 * {"product": {...}} is also accepted and unwrapped.
 *
 * Every call creates a new Staging Product record (SP-1, SP-2, ...) and one
 * Staging Product Variant record (SPV-1, SPV-2, ...) under it for each entry
 * of "variants", so the objects are a complete history of what was sent.
 * Shopify sends up to 250 variants per product, too many for one text field,
 * which is why each variant is its own record. Nothing is converted:
 *
 *   - text, number, true/false and timestamp properties go to typed fields;
 *     numbers and true/false may also arrive as strings ("10.00", "true");
 *   - a property with a documented set of values (variant inventory_policy)
 *     goes to a restricted picklist and must be one of those values;
 *   - arrays and nested objects (collections, images, media, tags, options,
 *     metafields, ...) are stored as JSON text; a plain string (e.g. tags
 *     sent as "gold, ring") is kept exactly as sent;
 *   - any key that is not a documented product or variant property is kept
 *     in Additional_Properties__c of that record, so no information is
 *     dropped.
 *
 * id is the only required property, of the product and of each variant.
 * When a value cannot be stored (wrong type, value outside its set,
 * unreadable timestamp, longer than its field) the whole call is rejected
 * with 400 and a body naming the property and the reason, e.g.
 * "variants[2].price"; nothing is saved, neither the product nor any variant.
 *
 * Responses use the same envelope as the Lead API (ShreeHariLeadRestResource):
 *   201 {success, stagingProductId, stagingProductNumber, shopifyProductId,
 *        variantCount, message}
 *   4xx/5xx {success:false, errorCode, message, field, httpStatus}
 *
 * Authentication is handled by the platform (Shree Hari Website API External
 * Client App); the integration user gets its access from the Shree Hari Lead
 * API Access permission set.
 */
@RestResource(urlMapping='/shreehari/v1/products/*')
global with sharing class ShreeHariProductRestResource {

    private static final String CONTENT_TYPE = 'application/json; charset=UTF-8';
    @TestVisible
    private static final String STATUS_NEW = 'New';
    @TestVisible
    private static final String VARIANTS = 'variants';

    private enum Kind { TEXT, NUM, BOOL, DATE_TIME, PICKLIST, JSON_TEXT }

    /**
     * Shopify product property -> Staging_Product__c field. "variants" is not
     * listed: each variant becomes a Staging_Product_Variant__c record
     * (VARIANT_MAPPINGS). Keys ending in "?" are the Liquid names; the same
     * name without "?" is accepted as well.
     */
    @TestVisible
    private static final List<Mapping> MAPPINGS = new List<Mapping>{
        // Text
        new Mapping('id', Staging_Product__c.Shopify_Id__c, Kind.TEXT),
        new Mapping('title', Staging_Product__c.Title__c, Kind.TEXT),
        new Mapping('handle', Staging_Product__c.Handle__c, Kind.TEXT),
        new Mapping('vendor', Staging_Product__c.Vendor__c, Kind.TEXT),
        new Mapping('type', Staging_Product__c.Product_Type__c, Kind.TEXT),
        new Mapping('template_suffix', Staging_Product__c.Template_Suffix__c, Kind.TEXT),
        new Mapping('url', Staging_Product__c.Url__c, Kind.TEXT),
        new Mapping('description', Staging_Product__c.Description__c, Kind.TEXT),
        new Mapping('content', Staging_Product__c.Content__c, Kind.TEXT),
        // Numbers
        new Mapping('price', Staging_Product__c.Price__c, Kind.NUM),
        new Mapping('price_min', Staging_Product__c.Price_Min__c, Kind.NUM),
        new Mapping('price_max', Staging_Product__c.Price_Max__c, Kind.NUM),
        new Mapping('compare_at_price', Staging_Product__c.Compare_At_Price__c, Kind.NUM),
        new Mapping('compare_at_price_min', Staging_Product__c.Compare_At_Price_Min__c, Kind.NUM),
        new Mapping('compare_at_price_max', Staging_Product__c.Compare_At_Price_Max__c, Kind.NUM),
        new Mapping('variants_count', Staging_Product__c.Variants_Count__c, Kind.NUM),
        // True / false
        new Mapping('available', Staging_Product__c.Available__c, Kind.BOOL),
        new Mapping('gift_card?', Staging_Product__c.Gift_Card__c, Kind.BOOL),
        new Mapping('has_only_default_variant', Staging_Product__c.Has_Only_Default_Variant__c, Kind.BOOL),
        new Mapping('price_varies', Staging_Product__c.Price_Varies__c, Kind.BOOL),
        new Mapping('compare_at_price_varies', Staging_Product__c.Compare_At_Price_Varies__c, Kind.BOOL),
        new Mapping('requires_selling_plan', Staging_Product__c.Requires_Selling_Plan__c, Kind.BOOL),
        new Mapping('quantity_price_breaks_configured?', Staging_Product__c.Quantity_Price_Breaks_Configured__c, Kind.BOOL),
        // Timestamps
        new Mapping('created_at', Staging_Product__c.Shopify_Created_At__c, Kind.DATE_TIME),
        new Mapping('published_at', Staging_Product__c.Shopify_Published_At__c, Kind.DATE_TIME),
        // Arrays and nested objects, stored as JSON text
        new Mapping('collections', Staging_Product__c.Collections__c, Kind.JSON_TEXT),
        new Mapping('images', Staging_Product__c.Images__c, Kind.JSON_TEXT),
        new Mapping('media', Staging_Product__c.Media__c, Kind.JSON_TEXT),
        new Mapping('tags', Staging_Product__c.Tags__c, Kind.JSON_TEXT),
        new Mapping('options', Staging_Product__c.Options__c, Kind.JSON_TEXT),
        new Mapping('options_with_values', Staging_Product__c.Options_With_Values__c, Kind.JSON_TEXT),
        new Mapping('options_by_name', Staging_Product__c.Options_By_Name__c, Kind.JSON_TEXT),
        new Mapping('selling_plan_groups', Staging_Product__c.Selling_Plan_Groups__c, Kind.JSON_TEXT),
        new Mapping('metafields', Staging_Product__c.Metafields__c, Kind.JSON_TEXT),
        new Mapping('category', Staging_Product__c.Category__c, Kind.JSON_TEXT),
        new Mapping('featured_image', Staging_Product__c.Featured_Image__c, Kind.JSON_TEXT),
        new Mapping('featured_media', Staging_Product__c.Featured_Media__c, Kind.JSON_TEXT),
        new Mapping('first_available_variant', Staging_Product__c.First_Available_Variant__c, Kind.JSON_TEXT),
        new Mapping('selected_variant', Staging_Product__c.Selected_Variant__c, Kind.JSON_TEXT),
        new Mapping('selected_or_first_available_variant', Staging_Product__c.Selected_Or_First_Available_Variant__c, Kind.JSON_TEXT),
        new Mapping('selected_selling_plan', Staging_Product__c.Selected_Selling_Plan__c, Kind.JSON_TEXT),
        new Mapping('selected_selling_plan_allocation', Staging_Product__c.Selected_Selling_Plan_Allocation__c, Kind.JSON_TEXT),
        new Mapping('selected_or_first_available_selling_plan_allocation', Staging_Product__c.Selected_Or_First_Avail_Plan_Allocation__c, Kind.JSON_TEXT)
    };

    /**
     * Shopify variant property (https://shopify.dev/docs/api/liquid/objects/variant)
     * -> Staging_Product_Variant__c field, in the order of the documentation,
     * then the three deprecated properties.
     */
    @TestVisible
    private static final List<Mapping> VARIANT_MAPPINGS = new List<Mapping>{
        new Mapping('available', Staging_Product_Variant__c.Available__c, Kind.BOOL),
        new Mapping('barcode', Staging_Product_Variant__c.Barcode__c, Kind.TEXT),
        new Mapping('compare_at_price', Staging_Product_Variant__c.Compare_At_Price__c, Kind.NUM),
        new Mapping('featured_image', Staging_Product_Variant__c.Featured_Image__c, Kind.JSON_TEXT),
        new Mapping('featured_media', Staging_Product_Variant__c.Featured_Media__c, Kind.JSON_TEXT),
        new Mapping('id', Staging_Product_Variant__c.Id__c, Kind.TEXT),
        new Mapping('image', Staging_Product_Variant__c.Image__c, Kind.JSON_TEXT),
        new Mapping('incoming', Staging_Product_Variant__c.Incoming__c, Kind.BOOL),
        new Mapping('inventory_management', Staging_Product_Variant__c.Inventory_Management__c, Kind.TEXT),
        new Mapping('inventory_policy', Staging_Product_Variant__c.Inventory_Policy__c, Kind.PICKLIST),
        new Mapping('inventory_quantity', Staging_Product_Variant__c.Inventory_Quantity__c, Kind.NUM),
        new Mapping('matched', Staging_Product_Variant__c.Matched__c, Kind.BOOL),
        new Mapping('metafields', Staging_Product_Variant__c.Metafields__c, Kind.JSON_TEXT),
        new Mapping('next_incoming_date', Staging_Product_Variant__c.Next_Incoming_Date__c, Kind.DATE_TIME),
        new Mapping('options', Staging_Product_Variant__c.Options__c, Kind.JSON_TEXT),
        new Mapping('options_with_values', Staging_Product_Variant__c.Options_With_Values__c, Kind.JSON_TEXT),
        new Mapping('price', Staging_Product_Variant__c.Price__c, Kind.NUM),
        new Mapping('product', Staging_Product_Variant__c.Product__c, Kind.JSON_TEXT),
        new Mapping('quantity_price_breaks', Staging_Product_Variant__c.Quantity_Price_Breaks__c, Kind.JSON_TEXT),
        new Mapping('quantity_price_breaks_configured?', Staging_Product_Variant__c.Quantity_Price_Breaks_Configured__c, Kind.BOOL),
        new Mapping('quantity_rule', Staging_Product_Variant__c.Quantity_Rule__c, Kind.JSON_TEXT),
        new Mapping('requires_selling_plan', Staging_Product_Variant__c.Requires_Selling_Plan__c, Kind.BOOL),
        new Mapping('requires_shipping', Staging_Product_Variant__c.Requires_Shipping__c, Kind.BOOL),
        new Mapping('selected', Staging_Product_Variant__c.Selected__c, Kind.BOOL),
        new Mapping('selected_selling_plan_allocation', Staging_Product_Variant__c.Selected_Selling_Plan_Allocation__c, Kind.JSON_TEXT),
        new Mapping('selling_plan_allocations', Staging_Product_Variant__c.Selling_Plan_Allocations__c, Kind.JSON_TEXT),
        new Mapping('sku', Staging_Product_Variant__c.SKU__c, Kind.TEXT),
        new Mapping('store_availabilities', Staging_Product_Variant__c.Store_Availabilities__c, Kind.JSON_TEXT),
        new Mapping('taxable', Staging_Product_Variant__c.Taxable__c, Kind.BOOL),
        new Mapping('title', Staging_Product_Variant__c.Title__c, Kind.TEXT),
        new Mapping('unit_price', Staging_Product_Variant__c.Unit_Price__c, Kind.NUM),
        new Mapping('unit_price_measurement', Staging_Product_Variant__c.Unit_Price_Measurement__c, Kind.JSON_TEXT),
        new Mapping('url', Staging_Product_Variant__c.Url__c, Kind.TEXT),
        new Mapping('weight', Staging_Product_Variant__c.Weight__c, Kind.NUM),
        new Mapping('weight_in_unit', Staging_Product_Variant__c.Weight_In_Unit__c, Kind.NUM),
        new Mapping('weight_unit', Staging_Product_Variant__c.Weight_Unit__c, Kind.TEXT),
        // Deprecated by Shopify, kept so nothing sent is lost
        new Mapping('option1', Staging_Product_Variant__c.Option1__c, Kind.TEXT),
        new Mapping('option2', Staging_Product_Variant__c.Option2__c, Kind.TEXT),
        new Mapping('option3', Staging_Product_Variant__c.Option3__c, Kind.TEXT)
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
    global static void receiveProduct() {
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

            Map<String, Object> product = parse(body);
            // Every value is checked before anything is saved
            Staging_Product__c record = buildRecord(product);
            List<Staging_Product_Variant__c> variantRecords = buildVariants(product);

            Savepoint beforeSave = Database.setSavepoint();
            try {
                insert record;
                for (Staging_Product_Variant__c variant : variantRecords) {
                    variant.Staging_Product__c = record.Id;
                }
                insert variantRecords;
            } catch (DmlException e) {
                Database.rollback(beforeSave);
                throw error('DML_EXCEPTION', 500, null, e.getDmlMessage(0));
            }

            Staging_Product__c saved = [
                SELECT Id, Name, Shopify_Id__c FROM Staging_Product__c WHERE Id = :record.Id WITH SYSTEM_MODE
            ];
            ProductResponse result = new ProductResponse();
            result.success = true;
            result.stagingProductId = saved.Id;
            result.stagingProductNumber = saved.Name;
            result.shopifyProductId = saved.Shopify_Id__c;
            result.variantCount = variantRecords.size();
            result.message = 'Product received and stored as ' + saved.Name + ' with '
                + variantRecords.size() + (variantRecords.size() == 1 ? ' variant.' : ' variants.');

            response.statusCode = 201;
            response.responseBody = Blob.valueOf(JSON.serialize(result, true));

        } catch (ApiException e) {
            writeError(response, e.errorCode, e.httpStatus, e.jsonField, e.getMessage());
            IntegrationLogService.logError(IntegrationLogService.API_PRODUCT, 'ShreeHariProductRestResource', 'receiveProduct', e);
        } catch (Exception e) {
            writeError(response, 'DML_EXCEPTION', 500, null, e.getMessage());
            IntegrationLogService.logError(IntegrationLogService.API_PRODUCT, 'ShreeHariProductRestResource', 'receiveProduct', e);
        }
    }

    // =====================================================================
    // Parsing
    // =====================================================================

    private static Map<String, Object> parse(String body) {
        if (String.isBlank(body)) {
            throw badRequest('INVALID_JSON', null, 'Request body is empty. Send one Shopify product as a JSON object.');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(body);
        } catch (Exception e) {
            throw badRequest('INVALID_JSON', null, 'Request body could not be parsed as JSON: ' + e.getMessage());
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw badRequest('INVALID_JSON', null, 'Request body must be one product as a JSON object (one product per call).');
        }
        Map<String, Object> product = (Map<String, Object>) parsed;

        // {"product": {...}}, the Shopify Admin API / webhook wrapper
        if (product.size() == 1 && product.get('product') instanceof Map<String, Object>) {
            product = (Map<String, Object>) product.get('product');
        }
        return product;
    }

    // =====================================================================
    // Mapping
    // =====================================================================

    private static Staging_Product__c buildRecord(Map<String, Object> product) {
        Staging_Product__c record = new Staging_Product__c(Processing_Status__c = STATUS_NEW);
        Set<String> used = fill(record, product, MAPPINGS, '');
        used.add(VARIANTS);

        if (String.isBlank(record.Shopify_Id__c)) {
            throw badRequest('MISSING_REQUIRED_FIELD', 'id', 'id is required: the Shopify product ID.');
        }
        record.Additional_Properties__c = additionalProperties(
            product, used, Staging_Product__c.Additional_Properties__c, ADDITIONAL_PROPERTIES
        );
        return record;
    }

    /** One Staging Product Variant per entry of "variants", in the order sent. */
    private static List<Staging_Product_Variant__c> buildVariants(Map<String, Object> product) {
        List<Staging_Product_Variant__c> records = new List<Staging_Product_Variant__c>();
        String key = product.containsKey(VARIANTS) ? VARIANTS : null;
        Object value = (key == null) ? null : product.get(key);
        if (value == null) {
            return records;
        }
        if (!(value instanceof List<Object>)) {
            throw badRequest('INVALID_TYPE', VARIANTS, 'variants must be an array of variant objects.');
        }
        List<Object> entries = (List<Object>) value;
        for (Integer i = 0; i < entries.size(); i++) {
            String path = VARIANTS + '[' + i + ']';
            if (!(entries[i] instanceof Map<String, Object>)) {
                throw badRequest('INVALID_TYPE', path, path + ' must be a variant object.');
            }
            Map<String, Object> variant = (Map<String, Object>) entries[i];
            Staging_Product_Variant__c record = new Staging_Product_Variant__c();
            Set<String> used = fill(record, variant, VARIANT_MAPPINGS, path + '.');

            if (String.isBlank(record.Id__c)) {
                throw badRequest('MISSING_REQUIRED_FIELD', path + '.id', path + '.id is required: the Shopify variant ID.');
            }
            record.Additional_Properties__c = additionalProperties(
                variant, used, Staging_Product_Variant__c.Additional_Properties__c, path + ' ' + ADDITIONAL_PROPERTIES
            );
            records.add(record);
        }
        return records;
    }

    /**
     * Puts every mapped key of source on the record. Returns the keys used.
     * prefix is put in front of a key in error messages ("variants[2].").
     */
    private static Set<String> fill(SObject record, Map<String, Object> source, List<Mapping> mappings, String prefix) {
        Set<String> used = new Set<String>();
        for (Mapping m : mappings) {
            String key = m.keyIn(source);
            if (key == null) {
                continue;
            }
            used.add(key);
            Object value = source.get(key);
            if (value == null) {
                continue;
            }
            record.put(m.field, convert(m, prefix + key, value));
        }
        return used;
    }

    /** The keys of source that are not documented, as one JSON object; null when there are none. */
    private static String additionalProperties(
        Map<String, Object> source,
        Set<String> used,
        Schema.SObjectField field,
        String label
    ) {
        Map<String, Object> additional = new Map<String, Object>();
        for (String key : source.keySet()) {
            if (!used.contains(key)) {
                additional.put(key, source.get(key));
            }
        }
        if (additional.isEmpty()) {
            return null;
        }
        String text = JSON.serialize(additional);
        checkLength(field, label, text);
        return text;
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
     * documented.
     */
    private static String toPicklistValue(Schema.SObjectField field, String key, Object value) {
        String text = toText(field, key, value);
        List<String> allowed = new List<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
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
        public String keyIn(Map<String, Object> source) {
            if (source.containsKey(key)) {
                return key;
            }
            String plain = key.removeEnd('?');
            return (plain != key && source.containsKey(plain)) ? plain : null;
        }
    }

    global class ProductResponse {
        public Boolean success;
        public Id stagingProductId;
        public String stagingProductNumber;
        public String shopifyProductId;
        public Integer variantCount;
        public String message;
    }

    public class ApiException extends Exception {
        public String errorCode;
        public Integer httpStatus;
        public String jsonField;
    }
}
