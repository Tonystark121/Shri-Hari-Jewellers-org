/**
 * Tests for the Shopify order staging endpoint.
 *
 * Each test drives the resource the way the sender does: a JSON body in, a
 * status code and JSON body out, then checks what was stored on
 * Staging_Order__c. Calls are made as a user whose only access is the
 * Shree Hari Order API Access permission set.
 */
@IsTest
private class ShreeHariOrderRestResourceTest {

    private static final String RESOURCE_URI = '/services/apexrest/shreehari/v1/orders';

    // The sets of values on https://shopify.dev/docs/api/liquid/objects/order, in documentation order
    private static final List<String> CANCEL_REASONS = new List<String>{
        'customer', 'declined', 'fraud', 'inventory', 'staff', 'other'
    };
    private static final List<String> FINANCIAL_STATUSES = new List<String>{
        'authorized', 'expired', 'paid', 'partially_paid', 'partially_refunded', 'pending', 'refunded', 'unpaid', 'voided'
    };
    private static final List<String> FULFILLMENT_STATUS_LABELS = new List<String>{
        'complete', 'fulfilled', 'partial', 'restocked', 'unfulfilled'
    };

    // =====================================================================
    // Helpers
    // =====================================================================

    private static User apiUser;

    /** A user whose only access to Staging Order is the Shree Hari Order API Access permission set. */
    private static User apiUser() {
        if (apiUser == null) {
            String unique = 'orderapi' + Crypto.getRandomInteger() + '@shreehari.test';
            apiUser = new User(
                ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id,
                LastName = 'Order API', Alias = 'ordapi', Email = unique, Username = unique,
                TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN', EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            );
            System.runAs(new User(Id = UserInfo.getUserId())) {
                insert apiUser;
                insert new PermissionSetAssignment(
                    AssigneeId = apiUser.Id,
                    PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Shree_Hari_Order_API_Access' LIMIT 1].Id
                );
            }
        }
        return apiUser;
    }

    /** Posts the body as the API user and returns the parsed response with its status code. */
    private static Map<String, Object> post(String body) {
        RestRequest request = new RestRequest();
        request.requestURI = RESOURCE_URI;
        request.httpMethod = 'POST';
        request.addHeader('Content-Type', 'application/json');
        if (body != null) {
            request.requestBody = Blob.valueOf(body);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();

        System.runAs(apiUser()) {
            ShreeHariOrderRestResource.receiveOrder();
        }

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        parsed.put('__status', RestContext.response.statusCode);
        return parsed;
    }

    /** Every documented property of the Shopify order object, including the deprecated discounts. */
    private static Map<String, Object> fullOrder() {
        Map<String, Object> address = new Map<String, Object>{
            'id' => 56174706753L, 'first_name' => 'Asha', 'last_name' => 'Mehta', 'name' => 'Asha Mehta',
            'company' => null, 'address1' => '12 MG Road', 'address2' => '2nd floor',
            'street' => '12 MG Road, 2nd floor', 'city' => 'Ahmedabad', 'province' => 'Gujarat',
            'province_code' => 'GJ', 'country' => new Map<String, Object>{ 'name' => 'India', 'iso_code' => 'IN' },
            'country_code' => 'IN', 'zip' => '380001', 'phone' => '+919876543210'
        };
        Map<String, Object> discountApplication = new Map<String, Object>{
            'title' => 'DIWALI10', 'type' => 'discount_code', 'value' => 10.0, 'value_type' => 'percentage',
            'target_selection' => 'all', 'target_type' => 'line_item', 'total_allocated_amount' => 500000
        };
        Map<String, Object> lineItem = new Map<String, Object>{
            'id' => 11406125531201L, 'product_id' => 6786188247105L, 'variant_id' => 39897499729985L,
            'title' => 'Classic Gold Ring', 'sku' => 'RING-16-22K', 'quantity' => 1,
            'original_price' => 5000000, 'final_price' => 4500000, 'final_line_price' => 4500000,
            'taxable' => true, 'gift_card' => false,
            'properties' => new Map<String, Object>{ 'Engraving' => 'A & R' }
        };
        Map<String, Object> taxLine = new Map<String, Object>{
            'title' => 'GST', 'rate' => 0.03, 'rate_percentage' => 3.0, 'price' => 135000
        };
        return new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'gift_wrap' => 'yes', 'occasion' => 'Anniversary' },
            'billing_address' => address,
            'cancel_reason' => 'customer',
            'cancel_reason_label' => 'Customer changed/cancelled order',
            'cancelled' => true,
            'cancelled_at' => '2026-11-03T09:15:00+05:30',
            'cart_level_discount_applications' => new List<Object>{ discountApplication },
            'confirmation_number' => '0YMJHPM8U',
            'created_at' => '2026-11-01 10:30:00 +0530',
            'customer' => new Map<String, Object>{
                'id' => 5625411010625L, 'name' => 'Asha Mehta', 'email' => 'asha.mehta@example.com',
                'phone' => '+919876543210', 'orders_count' => 1, 'tags' => new List<Object>{ 'vip' }
            },
            'customer_order_url' => 'https://shopify.com/56174706753/account/orders/4295688749121?locale=en&region_country=IN',
            'customer_url' => 'https://shreehari.example.com/account/orders/8be02e56c658bcd1f034d28c496fddd9',
            'discount_applications' => new List<Object>{ discountApplication },
            'discounts' => new List<Object>{
                new Map<String, Object>{ 'code' => 'DIWALI10', 'amount' => 500000, 'type' => 'PercentageDiscount' }
            },
            'email' => 'asha.mehta@example.com',
            'financial_status' => 'partially_refunded',
            'financial_status_label' => 'Partially refunded',
            'fulfillment_status' => 'partial',
            'fulfillment_status_label' => 'partial',
            'id' => 4295688749121L,
            'item_count' => 1,
            'line_items' => new List<Object>{ lineItem },
            'line_items_subtotal_price' => 4500000,
            'metafields' => new Map<String, Object>{
                'custom' => new Map<String, Object>{ 'showroom' => 'Ahmedabad', 'hallmark_charge' => 4500 }
            },
            'name' => '#1001',
            'note' => 'Please deliver before the 14th.',
            'order_number' => 1001,
            'order_status_url' => 'https://shreehari.example.com/56174706753/orders/8be02e56c658bcd1f034d28c496fddd9/authenticate?key=4f9baf2b8ebd0f75ec73eb9bac6e4519',
            'phone' => '+919876543210',
            'pickup_in_store?' => true,
            'shipping_address' => address,
            'shipping_methods' => new List<Object>{
                new Map<String, Object>{ 'handle' => 'insured-courier', 'title' => 'Insured Courier', 'price' => 25000 }
            },
            'shipping_price' => 25000,
            'subtotal_line_items' => new List<Object>{ lineItem },
            'subtotal_price' => 4000000,
            'tags' => new List<Object>{ 'anniversary', 'gift' },
            'tax_lines' => new List<Object>{ taxLine },
            'tax_price' => 135000,
            'total_discounts' => 500000,
            'total_duties' => 1250.5,
            'total_net_amount' => 4060000,
            'total_price' => 4160000,
            'total_refunded_amount' => 100000,
            'transactions' => new List<Object>{
                new Map<String, Object>{
                    'id' => 5432242176065L, 'kind' => 'sale', 'status' => 'success', 'gateway' => 'razorpay',
                    'amount' => 4160000, 'created_at' => '2026-11-01 10:31:02 +0530', 'receipt' => 'pay_NbA1'
                }
            }
        };
    }

    private static Staging_Order__c onlyRecord() {
        List<Staging_Order__c> records = [
            SELECT Id, Name, Attributes__c, Billing_Address__c, Cancel_Reason__c, Cancel_Reason_Label__c,
                Cancelled__c, Cancelled_At__c, Cart_Level_Discount_Applications__c, Confirmation_Number__c,
                Created_At__c, Customer__c, Customer_Order_Url__c, Customer_Url__c, Discount_Applications__c,
                Discounts__c, Email__c, Financial_Status__c, Financial_Status_Label__c, Fulfillment_Status__c,
                Fulfillment_Status_Label__c, Id__c, Item_Count__c, Line_Items__c, Line_Items_Subtotal_Price__c,
                Metafields__c, Name__c, Note__c, Order_Number__c, Order_Status_Url__c, Phone__c,
                Pickup_In_Store__c, Shipping_Address__c, Shipping_Methods__c, Shipping_Price__c,
                Subtotal_Line_Items__c, Subtotal_Price__c, Tags__c, Tax_Lines__c, Tax_Price__c,
                Total_Discounts__c, Total_Duties__c, Total_Net_Amount__c, Total_Price__c,
                Total_Refunded_Amount__c, Transactions__c, Additional_Properties__c, Processing_Status__c
            FROM Staging_Order__c
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(1, records.size(), 'Exactly one Staging Order should exist');
        return records[0];
    }

    /** The stored JSON text, read back, equals what was sent. */
    private static void assertJson(Object sent, String stored, String label) {
        Assert.isNotNull(stored, label + ' should be stored');
        Assert.areEqual(JSON.deserializeUntyped(JSON.serialize(sent)), JSON.deserializeUntyped(stored),
            label + ' should be stored exactly as sent');
    }

    private static void assertNumber(Decimal expected, Decimal actual, String label) {
        Assert.isTrue(actual != null && actual == expected, label + ': expected ' + expected + ', got ' + actual);
    }

    /** Case-sensitive comparison; Assert.areEqual on strings ignores case. */
    private static void assertExactText(String expected, String actual, String label) {
        Assert.isTrue(expected.equals(actual), label + ': expected "' + expected + '", got "' + actual + '"');
    }

    private static void assertRejected(Map<String, Object> response, String errorCode, String field) {
        Assert.areEqual(400, response.get('__status'), 'Should be a bad request: ' + response);
        Assert.areEqual(false, response.get('success'), 'success should be false');
        Assert.areEqual(errorCode, response.get('errorCode'), 'Error code should name the cause: ' + response);
        Assert.areEqual(field, response.get('field'), 'The offending property should be reported');
        Assert.isTrue(String.isNotBlank((String) response.get('message')), 'A reason should be given');
        Assert.areEqual(0, [SELECT COUNT() FROM Staging_Order__c WITH SYSTEM_MODE], 'Nothing should be saved');
    }

    private static Map<String, Object> withChange(String key, Object value) {
        Map<String, Object> order = fullOrder();
        order.put(key, value);
        return order;
    }

    private static List<String> activeValues(Schema.SObjectField field) {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    // =====================================================================
    // Structure: names and sets of values follow the documentation
    // =====================================================================

    @IsTest
    static void everyDocumentedPropertyHasAFieldNamedAfterIt() {
        Set<String> keys = new Set<String>();
        Set<Schema.SObjectField> fields = new Set<Schema.SObjectField>();
        for (ShreeHariOrderRestResource.Mapping m : ShreeHariOrderRestResource.MAPPINGS) {
            keys.add(m.key);
            fields.add(m.field);

            // financial_status -> Financial_Status__c, pickup_in_store? -> Pickup_In_Store__c
            List<String> words = new List<String>();
            for (String word : m.key.removeEnd('?').split('_')) {
                words.add(word.capitalize());
            }
            String expectedName = String.join(words, '_') + '__c';
            Schema.DescribeFieldResult d = m.field.getDescribe();
            assertExactText(expectedName, d.getName(), 'Field name for ' + m.key);
            assertExactText(String.join(words, ' '), d.getLabel(), 'Field label for ' + m.key);
        }
        Assert.areEqual(44, keys.size(), 'All 44 documented order properties should be mapped');
        Assert.areEqual(44, fields.size(), 'Each property should have its own field');
        Assert.areEqual(keys, fullOrder().keySet(), 'The test payload should carry every mapped property');
    }

    @IsTest
    static void picklistsCarryExactlyTheDocumentedValues() {
        Assert.areEqual(CANCEL_REASONS, activeValues(Staging_Order__c.Cancel_Reason__c), 'cancel_reason values');
        Assert.areEqual(FINANCIAL_STATUSES, activeValues(Staging_Order__c.Financial_Status__c), 'financial_status values');
        Assert.areEqual(FULFILLMENT_STATUS_LABELS, activeValues(Staging_Order__c.Fulfillment_Status_Label__c),
            'fulfillment_status_label values');
        for (String value : activeValues(Staging_Order__c.Financial_Status__c)) {
            Assert.isTrue(value.equals(value.toLowerCase()), 'Values are spelled as documented, in lower case: ' + value);
        }

        Assert.isTrue(Staging_Order__c.Cancel_Reason__c.getDescribe().isRestrictedPicklist(), 'cancel_reason is restricted');
        Assert.isTrue(Staging_Order__c.Financial_Status__c.getDescribe().isRestrictedPicklist(), 'financial_status is restricted');
        Assert.isFalse(Staging_Order__c.Fulfillment_Status_Label__c.getDescribe().isRestrictedPicklist(),
            'fulfillment_status_label is localized, so it is not restricted');

        // The documentation gives no set of values for these, so they stay text
        Assert.areEqual(Schema.DisplayType.STRING, Staging_Order__c.Fulfillment_Status__c.getDescribe().getType(),
            'fulfillment_status');
        Assert.areEqual(Schema.DisplayType.STRING, Staging_Order__c.Financial_Status_Label__c.getDescribe().getType(),
            'financial_status_label');
        Assert.areEqual(Schema.DisplayType.STRING, Staging_Order__c.Cancel_Reason_Label__c.getDescribe().getType(),
            'cancel_reason_label');
    }

    // =====================================================================
    // Stored as sent
    // =====================================================================

    @IsTest
    static void storesEveryDocumentedProperty() {
        Map<String, Object> order = fullOrder();

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(order));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Assert.areEqual(true, response.get('success'), 'success should be true');

        Staging_Order__c r = onlyRecord();
        Assert.areEqual(String.valueOf(r.Id), response.get('stagingOrderId'), 'Response should carry the record Id');
        Assert.areEqual(r.Name, response.get('stagingOrderNumber'), 'Response should carry SO number');
        Assert.isTrue(r.Name.startsWith('SO-'), 'Name should be the SO- auto number');
        Assert.areEqual('4295688749121', response.get('shopifyOrderId'), 'Response should echo the id');
        Assert.areEqual(ShreeHariOrderRestResource.STATUS_NEW, r.Processing_Status__c, 'New on arrival');

        // Text
        assertExactText('4295688749121', r.Id__c, 'id');
        assertExactText('#1001', r.Name__c, 'name');
        assertExactText('0YMJHPM8U', r.Confirmation_Number__c, 'confirmation_number');
        assertExactText('asha.mehta@example.com', r.Email__c, 'email');
        assertExactText('+919876543210', r.Phone__c, 'phone');
        assertExactText('Please deliver before the 14th.', r.Note__c, 'note');
        assertExactText('Customer changed/cancelled order', r.Cancel_Reason_Label__c, 'cancel_reason_label');
        assertExactText('Partially refunded', r.Financial_Status_Label__c, 'financial_status_label');
        assertExactText('partial', r.Fulfillment_Status__c, 'fulfillment_status');
        assertExactText((String) order.get('customer_order_url'), r.Customer_Order_Url__c, 'customer_order_url');
        assertExactText((String) order.get('customer_url'), r.Customer_Url__c, 'customer_url');
        assertExactText((String) order.get('order_status_url'), r.Order_Status_Url__c, 'order_status_url');
        // Sets of values
        assertExactText('customer', r.Cancel_Reason__c, 'cancel_reason');
        assertExactText('partially_refunded', r.Financial_Status__c, 'financial_status');
        assertExactText('partial', r.Fulfillment_Status_Label__c, 'fulfillment_status_label');
        // Numbers, unconverted
        assertNumber(1, r.Item_Count__c, 'item_count');
        assertNumber(1001, r.Order_Number__c, 'order_number');
        assertNumber(4500000, r.Line_Items_Subtotal_Price__c, 'line_items_subtotal_price');
        assertNumber(25000, r.Shipping_Price__c, 'shipping_price');
        assertNumber(4000000, r.Subtotal_Price__c, 'subtotal_price');
        assertNumber(135000, r.Tax_Price__c, 'tax_price');
        assertNumber(500000, r.Total_Discounts__c, 'total_discounts');
        assertNumber(1250.5, r.Total_Duties__c, 'total_duties');
        assertNumber(4060000, r.Total_Net_Amount__c, 'total_net_amount');
        assertNumber(4160000, r.Total_Price__c, 'total_price');
        assertNumber(100000, r.Total_Refunded_Amount__c, 'total_refunded_amount');
        // True / false
        Assert.isTrue(r.Cancelled__c, 'cancelled');
        Assert.isTrue(r.Pickup_In_Store__c, 'pickup_in_store?');
        // Timestamps
        Assert.areEqual(Datetime.newInstanceGmt(2026, 11, 3, 3, 45, 0), r.Cancelled_At__c, 'cancelled_at');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 11, 1, 5, 0, 0), r.Created_At__c, 'created_at');
        // Arrays and nested objects, as JSON
        assertJson(order.get('attributes'), r.Attributes__c, 'attributes');
        assertJson(order.get('billing_address'), r.Billing_Address__c, 'billing_address');
        assertJson(order.get('cart_level_discount_applications'), r.Cart_Level_Discount_Applications__c,
            'cart_level_discount_applications');
        assertJson(order.get('customer'), r.Customer__c, 'customer');
        assertJson(order.get('discount_applications'), r.Discount_Applications__c, 'discount_applications');
        assertJson(order.get('discounts'), r.Discounts__c, 'discounts');
        assertJson(order.get('line_items'), r.Line_Items__c, 'line_items');
        assertJson(order.get('metafields'), r.Metafields__c, 'metafields');
        assertJson(order.get('shipping_address'), r.Shipping_Address__c, 'shipping_address');
        assertJson(order.get('shipping_methods'), r.Shipping_Methods__c, 'shipping_methods');
        assertJson(order.get('subtotal_line_items'), r.Subtotal_Line_Items__c, 'subtotal_line_items');
        assertJson(order.get('tags'), r.Tags__c, 'tags');
        assertJson(order.get('tax_lines'), r.Tax_Lines__c, 'tax_lines');
        assertJson(order.get('transactions'), r.Transactions__c, 'transactions');
        Assert.isNull(r.Additional_Properties__c, 'Nothing undocumented was sent');
    }

    @IsTest
    static void storesTheShopifyDocumentationExample() {
        // The example on https://shopify.dev/docs/api/liquid/objects/order, as published
        String customerOrderUrl = 'https://shopify.com/56174706753/account/orders/4295688749121?locale=en&region_country=CA'
            + '&buyer_flags=eyJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJwb2xpbmFzLXBvdGVudC1wb3Rpb25zLm15c2hvcGlmeS5jb20iLCJmbGFncyI6W10sImV4cCI6MTc5NTE0NTU5NywibmJmIjoxNzk0NTQwNzk3fQ.eTiN4VpfWA_eXKkLhc2DYRgN4GaVN9H3TSo0Z5u7hXg';
        String customerUrl = 'https://polinas-potent-potions.myshopify.com/account/orders/8be02e56c658bcd1f034d28c496fddd9';
        String orderStatusUrl = 'https://polinas-potent-potions.myshopify.com/56174706753/orders/8be02e56c658bcd1f034d28c496fddd9/authenticate?key=4f9baf2b8ebd0f75ec73eb9bac6e4519';
        String body = '{"attributes": {}, "billing_address": {}, "cancel_reason": null, "cancel_reason_label": null,'
            + ' "cancelled": false, "cancelled_at": null, "cart_level_discount_applications": [],'
            + ' "confirmation_number": "0YMJHPM8U", "created_at": "2022-04-29 11:15:46 -0400", "customer": {},'
            + ' "customer_order_url": "' + customerOrderUrl + '", "customer_url": "' + customerUrl + '",'
            + ' "discount_applications": [], "discounts": null, "email": "cornelius.potionmaker@gmail.com",'
            + ' "financial_status": "paid", "financial_status_label": "Paid", "fulfillment_status": "partial",'
            + ' "fulfillment_status_label": "Partial", "id": 4295688749121, "item_count": 6, "line_items": [],'
            + ' "line_items_subtotal_price": 49293, "metafields": {}, "name": "#1001", "note": null,'
            + ' "order_number": 1001, "order_status_url": "' + orderStatusUrl + '", "phone": null,'
            + ' "pickup_in_store?": false, "shipping_address": {}, "shipping_methods": [], "shipping_price": 0,'
            + ' "subtotal_line_items": [], "subtotal_price": 49293, "tags": [], "tax_lines": [], "tax_price": 0,'
            + ' "total_discounts": 0, "total_duties": null, "total_net_amount": 49293, "total_price": 49293,'
            + ' "total_refunded_amount": 0, "transactions": []}';

        Test.startTest();
        Map<String, Object> response = post(body);
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'The documented example should be accepted: ' + response);
        Staging_Order__c r = onlyRecord();
        assertExactText('4295688749121', r.Id__c, 'id');
        assertExactText('#1001', r.Name__c, 'name');
        assertExactText('0YMJHPM8U', r.Confirmation_Number__c, 'confirmation_number');
        assertExactText('cornelius.potionmaker@gmail.com', r.Email__c, 'email');
        assertExactText('paid', r.Financial_Status__c, 'financial_status');
        assertExactText('Paid', r.Financial_Status_Label__c, 'financial_status_label');
        assertExactText('partial', r.Fulfillment_Status__c, 'fulfillment_status');
        // Salesforce stores a picklist value that differs only in letter case as the defined value
        assertExactText('partial', r.Fulfillment_Status_Label__c, 'fulfillment_status_label "Partial" is the documented value partial');
        assertExactText(customerOrderUrl, r.Customer_Order_Url__c, 'customer_order_url');
        assertExactText(customerUrl, r.Customer_Url__c, 'customer_url');
        assertExactText(orderStatusUrl, r.Order_Status_Url__c, 'order_status_url');
        Assert.areEqual(Datetime.newInstanceGmt(2022, 4, 29, 15, 15, 46), r.Created_At__c, 'created_at, as GMT');
        assertNumber(6, r.Item_Count__c, 'item_count');
        assertNumber(1001, r.Order_Number__c, 'order_number');
        assertNumber(49293, r.Line_Items_Subtotal_Price__c, 'line_items_subtotal_price');
        assertNumber(49293, r.Subtotal_Price__c, 'subtotal_price');
        assertNumber(49293, r.Total_Net_Amount__c, 'total_net_amount');
        assertNumber(49293, r.Total_Price__c, 'total_price');
        assertNumber(0, r.Shipping_Price__c, 'shipping_price sent as 0 is stored as 0');
        assertNumber(0, r.Tax_Price__c, 'tax_price');
        assertNumber(0, r.Total_Discounts__c, 'total_discounts');
        assertNumber(0, r.Total_Refunded_Amount__c, 'total_refunded_amount');
        Assert.isFalse(r.Cancelled__c, 'cancelled');
        Assert.isFalse(r.Pickup_In_Store__c, 'pickup_in_store?');
        Assert.areEqual('{}', r.Attributes__c, 'An empty object is stored as sent');
        Assert.areEqual('[]', r.Line_Items__c, 'An empty array is stored as sent');
        Assert.areEqual('[]', r.Tags__c, 'tags');
        Assert.isNull(r.Cancel_Reason__c, 'null cancel_reason stays blank');
        Assert.isNull(r.Cancel_Reason_Label__c, 'null cancel_reason_label stays blank');
        Assert.isNull(r.Cancelled_At__c, 'null cancelled_at stays blank');
        Assert.isNull(r.Discounts__c, 'null discounts stays blank');
        Assert.isNull(r.Note__c, 'null note stays blank');
        Assert.isNull(r.Phone__c, 'null phone stays blank');
        Assert.isNull(r.Total_Duties__c, 'null total_duties stays blank');
        Assert.isNull(r.Additional_Properties__c, 'Nothing undocumented in the example');
    }

    @IsTest
    static void acceptsEveryDocumentedValueOfEachSet() {
        Test.startTest();
        for (String value : CANCEL_REASONS) {
            Map<String, Object> response = post(JSON.serialize(
                new Map<String, Object>{ 'id' => 'cancel_reason:' + value, 'cancel_reason' => value }));
            Assert.areEqual(201, response.get('__status'), 'cancel_reason ' + value + ': ' + response);
        }
        for (String value : FINANCIAL_STATUSES) {
            Map<String, Object> response = post(JSON.serialize(
                new Map<String, Object>{ 'id' => 'financial_status:' + value, 'financial_status' => value }));
            Assert.areEqual(201, response.get('__status'), 'financial_status ' + value + ': ' + response);
        }
        for (String value : FULFILLMENT_STATUS_LABELS) {
            Map<String, Object> response = post(JSON.serialize(
                new Map<String, Object>{ 'id' => 'fulfillment_status_label:' + value, 'fulfillment_status_label' => value }));
            Assert.areEqual(201, response.get('__status'), 'fulfillment_status_label ' + value + ': ' + response);
        }
        Test.stopTest();

        for (Staging_Order__c r : [
            SELECT Id__c, Cancel_Reason__c, Financial_Status__c, Fulfillment_Status_Label__c
            FROM Staging_Order__c WITH SYSTEM_MODE
        ]) {
            String property = r.Id__c.substringBefore(':');
            String sent = r.Id__c.substringAfter(':');
            String stored = property == 'cancel_reason' ? r.Cancel_Reason__c
                : property == 'financial_status' ? r.Financial_Status__c
                : r.Fulfillment_Status_Label__c;
            assertExactText(sent, stored, property);
        }
        Assert.areEqual(CANCEL_REASONS.size() + FINANCIAL_STATUSES.size() + FULFILLMENT_STATUS_LABELS.size(),
            [SELECT COUNT() FROM Staging_Order__c WITH SYSTEM_MODE], 'One record per value');
    }

    @IsTest
    static void keepsALocalizedFulfillmentStatusLabelAsSent() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('fulfillment_status_label', 'Teilweise erfüllt')));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'A localized label is accepted: ' + response);
        assertExactText('Teilweise erfüllt', onlyRecord().Fulfillment_Status_Label__c, 'fulfillment_status_label');
    }

    @IsTest
    static void keepsUndocumentedKeysInAdditionalProperties() {
        Map<String, Object> order = withChange('currency', 'INR');
        order.put('updated_at', '2026-11-03T09:15:00+05:30');
        order.put('payment_gateway_names', new List<Object>{ 'razorpay' });

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(order));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Map<String, Object> extra = (Map<String, Object>) JSON.deserializeUntyped(onlyRecord().Additional_Properties__c);
        Assert.areEqual(3, extra.size(), 'Only the undocumented keys should be kept there');
        Assert.areEqual('INR', extra.get('currency'), 'currency kept');
        Assert.areEqual('2026-11-03T09:15:00+05:30', extra.get('updated_at'), 'updated_at kept');
        Assert.areEqual(new List<Object>{ 'razorpay' }, extra.get('payment_gateway_names'), 'payment_gateway_names kept');
    }

    @IsTest
    static void storesOnlyWhatIsSentAndIgnoresNulls() {
        Test.startTest();
        Map<String, Object> response = post(
            '{"id": "123", "name": null, "line_items": null, "total_price": null, "financial_status": null, "created_at": null}'
        );
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Only id is required: ' + response);
        Staging_Order__c r = onlyRecord();
        assertExactText('123', r.Id__c, 'id');
        Assert.isNull(r.Name__c, 'null name stays blank');
        Assert.isNull(r.Line_Items__c, 'null line_items stays blank');
        Assert.isNull(r.Total_Price__c, 'null total_price stays blank');
        Assert.isNull(r.Financial_Status__c, 'null financial_status stays blank');
        Assert.isNull(r.Created_At__c, 'null created_at stays blank');
        Assert.isNull(r.Cancel_Reason__c, 'A set-of-values property that was not sent has no default');
        Assert.isNull(r.Fulfillment_Status_Label__c, 'A set-of-values property that was not sent has no default');
        Assert.isFalse(r.Cancelled__c, 'A flag that was not sent is unchecked');
        Assert.isNull(r.Additional_Properties__c, 'null documented keys are not undocumented');
    }

    @IsTest
    static void treatsEmptyTextAsNoValueForTypedProperties() {
        Map<String, Object> order = fullOrder();
        order.put('cancel_reason', '');
        order.put('financial_status', '  ');
        order.put('fulfillment_status_label', '');
        order.put('cancelled_at', '');
        order.put('total_duties', '');
        order.put('cancelled', '');
        order.put('note', '');

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(order));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Empty text is not an error: ' + response);
        Staging_Order__c r = onlyRecord();
        Assert.isNull(r.Cancel_Reason__c, 'cancel_reason');
        Assert.isNull(r.Financial_Status__c, 'financial_status');
        Assert.isNull(r.Fulfillment_Status_Label__c, 'fulfillment_status_label');
        Assert.isNull(r.Cancelled_At__c, 'cancelled_at');
        Assert.isNull(r.Total_Duties__c, 'total_duties');
        Assert.isFalse(r.Cancelled__c, 'cancelled');
        Assert.isNull(r.Note__c, 'note');
        Assert.isNull(r.Additional_Properties__c, 'Empty documented keys are not undocumented');
    }

    @IsTest
    static void eachCallCreatesANewRecord() {
        String body = JSON.serialize(fullOrder());

        Test.startTest();
        Map<String, Object> first = post(body);
        Map<String, Object> second = post(body);
        Test.stopTest();

        Assert.areEqual(201, first.get('__status'), 'First call created');
        Assert.areEqual(201, second.get('__status'), 'Second call created');
        Assert.areNotEqual(first.get('stagingOrderId'), second.get('stagingOrderId'), 'Two records');
        Assert.areNotEqual(first.get('stagingOrderNumber'), second.get('stagingOrderNumber'), 'Two SO numbers');
        Assert.areEqual(2, [SELECT COUNT() FROM Staging_Order__c WHERE Id__c = '4295688749121' WITH SYSTEM_MODE],
            'Both calls should be kept as history');
    }

    @IsTest
    static void acceptsTheOrderWrapperAndNamesWithoutQuestionMark() {
        Map<String, Object> order = fullOrder();
        order.remove('pickup_in_store?');
        order.put('pickup_in_store', true);

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(new Map<String, Object>{ 'order' => order }));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Wrapped order accepted: ' + response);
        Staging_Order__c r = onlyRecord();
        assertExactText('4295688749121', r.Id__c, 'Unwrapped id');
        Assert.isTrue(r.Pickup_In_Store__c, 'pickup_in_store without ? is read');
        Assert.isNull(r.Additional_Properties__c, 'Alternate names are not undocumented');
    }

    @IsTest
    static void acceptsNumbersAndBooleansSentAsTextAndKeepsPlainStringsAsSent() {
        Map<String, Object> order = withChange('total_price', '41600.50');
        order.put('order_number', ' 1001 ');
        order.put('cancelled', 'FALSE');
        order.put('tags', 'anniversary, gift');
        order.put('id', 'gid://shopify/Order/4295688749121');
        order.put('phone', '098765 43210');
        order.put('email', 'not an email');
        order.put('name', 1001);

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(order));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Staging_Order__c r = onlyRecord();
        assertNumber(41600.50, r.Total_Price__c, 'Numeric text is stored as a number');
        assertNumber(1001, r.Order_Number__c, 'Numeric text with spaces is stored as a number');
        Assert.isFalse(r.Cancelled__c, 'Boolean text is stored as a checkbox');
        assertExactText('anniversary, gift', r.Tags__c, 'A plain string is kept exactly as sent');
        assertExactText('gid://shopify/Order/4295688749121', r.Id__c, 'Text ids are kept as sent');
        assertExactText('098765 43210', r.Phone__c, 'phone is kept as typed');
        assertExactText('not an email', r.Email__c, 'email is kept as sent, not validated');
        assertExactText('1001', r.Name__c, 'A number sent for a text property is stored as its text');
    }

    @IsTest
    static void convertsEveryTimestampFormToGmt() {
        Assert.areEqual(Datetime.newInstanceGmt(2022, 4, 29, 15, 15, 46),
            ShreeHariOrderRestResource.toDatetime('k', '2022-04-29 11:15:46 -0400'), 'Liquid form, as documented');
        Assert.areEqual(Datetime.newInstanceGmt(2021, 4, 30, 15, 22, 36),
            ShreeHariOrderRestResource.toDatetime('k', '2021-04-30T11:22:36-04:00'), 'ISO with negative offset');
        Assert.areEqual(Datetime.newInstanceGmt(2021, 4, 30, 5, 52, 36),
            ShreeHariOrderRestResource.toDatetime('k', '2021-04-30 11:22:36 +0530'), 'Liquid form with +0530');
        Assert.areEqual(Datetime.newInstanceGmt(2021, 4, 30, 11, 22, 36),
            ShreeHariOrderRestResource.toDatetime('k', '2021-04-30T11:22:36.123Z'), 'UTC with milliseconds');
    }

    // =====================================================================
    // Rejected with a reason; nothing saved
    // =====================================================================

    @IsTest
    static void rejectsAnEmptyBody() {
        Test.startTest();
        Map<String, Object> response = post(null);
        Test.stopTest();
        assertRejected(response, 'INVALID_JSON', null);
    }

    @IsTest
    static void rejectsMalformedJson() {
        Test.startTest();
        Map<String, Object> response = post('{"id": "1",');
        Test.stopTest();
        assertRejected(response, 'INVALID_JSON', null);
    }

    @IsTest
    static void rejectsMoreThanOneOrderPerCall() {
        Test.startTest();
        Map<String, Object> response = post('[{"id": "1"}, {"id": "2"}]');
        Test.stopTest();
        assertRejected(response, 'INVALID_JSON', null);
    }

    @IsTest
    static void rejectsAMissingId() {
        Map<String, Object> order = fullOrder();
        order.remove('id');
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(order));
        Test.stopTest();
        assertRejected(response, 'MISSING_REQUIRED_FIELD', 'id');
    }

    @IsTest
    static void rejectsABlankId() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('id', '   ')));
        Test.stopTest();
        assertRejected(response, 'MISSING_REQUIRED_FIELD', 'id');
    }

    @IsTest
    static void rejectsAFinancialStatusOutsideTheDocumentedSet() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('financial_status', 'on_hold')));
        Test.stopTest();
        assertRejected(response, 'INVALID_VALUE', 'financial_status');
        String message = (String) response.get('message');
        Assert.isTrue(message.contains(String.join(FINANCIAL_STATUSES, ', ')), 'The allowed values should be listed: ' + message);
        Assert.isTrue(message.contains('"on_hold"'), 'The value sent should be quoted back: ' + message);
    }

    @IsTest
    static void rejectsAFinancialStatusNotSpelledAsDocumented() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('financial_status', 'Paid')));
        Test.stopTest();
        assertRejected(response, 'INVALID_VALUE', 'financial_status');
    }

    @IsTest
    static void rejectsACancelReasonOutsideTheDocumentedSet() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('cancel_reason', 'changed_mind')));
        Test.stopTest();
        assertRejected(response, 'INVALID_VALUE', 'cancel_reason');
        Assert.isTrue(((String) response.get('message')).contains(String.join(CANCEL_REASONS, ', ')),
            'The allowed values should be listed: ' + response.get('message'));
    }

    @IsTest
    static void rejectsAnObjectInASetOfValuesProperty() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(
            withChange('fulfillment_status_label', new Map<String, Object>{ 'en' => 'partial' })));
        Test.stopTest();
        assertRejected(response, 'INVALID_TYPE', 'fulfillment_status_label');
    }

    @IsTest
    static void rejectsAnObjectInATextProperty() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('name', new Map<String, Object>{ 'value' => '#1001' })));
        Test.stopTest();
        assertRejected(response, 'INVALID_TYPE', 'name');
    }

    @IsTest
    static void rejectsAnArrayInATextProperty() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('note', new List<Object>{ 'line 1', 'line 2' })));
        Test.stopTest();
        assertRejected(response, 'INVALID_TYPE', 'note');
    }

    @IsTest
    static void rejectsANonNumericPrice() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('total_price', 'Rs. 41,600')));
        Test.stopTest();
        assertRejected(response, 'INVALID_NUMBER', 'total_price');
    }

    @IsTest
    static void rejectsABooleanInANumberProperty() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('item_count', true)));
        Test.stopTest();
        assertRejected(response, 'INVALID_NUMBER', 'item_count');
    }

    @IsTest
    static void rejectsANumberTooLargeForItsField() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('total_price', 123456789012345L)));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', 'total_price');
    }

    @IsTest
    static void rejectsANonBooleanFlag() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('cancelled', 'yes')));
        Test.stopTest();
        assertRejected(response, 'INVALID_BOOLEAN', 'cancelled');
    }

    @IsTest
    static void rejectsANumberInAFlagWithoutQuestionMark() {
        Map<String, Object> order = fullOrder();
        order.remove('pickup_in_store?');
        order.put('pickup_in_store', 1);
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(order));
        Test.stopTest();
        assertRejected(response, 'INVALID_BOOLEAN', 'pickup_in_store');
    }

    @IsTest
    static void rejectsATimestampWithoutTimeZone() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('created_at', '2026-11-01T10:30:00')));
        Test.stopTest();
        assertRejected(response, 'INVALID_DATE', 'created_at');
    }

    @IsTest
    static void rejectsAnImpossibleDate() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('cancelled_at', '2026-02-30T10:00:00Z')));
        Test.stopTest();
        assertRejected(response, 'INVALID_DATE', 'cancelled_at');
    }

    @IsTest
    static void rejectsAnImpossibleTimeZoneOffset() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('created_at', '2026-11-01T10:30:00+15:00')));
        Test.stopTest();
        assertRejected(response, 'INVALID_DATE', 'created_at');
    }

    @IsTest
    static void rejectsANumberSentAsATimestamp() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('created_at', 1793528400)));
        Test.stopTest();
        assertRejected(response, 'INVALID_DATE', 'created_at');
    }

    @IsTest
    static void rejectsAnArrayLongerThanItsField() {
        List<Object> lineItems = new List<Object>();
        String filler = 'x'.repeat(1000);
        for (Integer i = 0; i < 140; i++) {
            lineItems.add(new Map<String, Object>{ 'id' => i, 'title' => filler });
        }
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('line_items', lineItems)));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', 'line_items');
    }

    @IsTest
    static void rejectsTextLongerThanItsField() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('confirmation_number', 'A'.repeat(256))));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', 'confirmation_number');
    }

    @IsTest
    static void rejectsUndocumentedKeysLongerThanAdditionalProperties() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('landing_site', 'x'.repeat(131100))));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', ShreeHariOrderRestResource.ADDITIONAL_PROPERTIES);
    }
}
