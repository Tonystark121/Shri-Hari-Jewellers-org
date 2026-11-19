/**
 * Tests for the Shopify customer staging endpoint.
 *
 * Each test drives the resource the way the sender does: a JSON body in, a
 * status code and JSON body out, then checks what was stored on
 * Staging_Customer__c.
 */
@IsTest
private class ShreeHariCustomerRestResourceTest {

    private static final String RESOURCE_URI = '/services/apexrest/shreehari/v1/customers';

    // =====================================================================
    // Helpers
    // =====================================================================

    private static User apiUser;

    /**
     * A Standard User given create and read on Staging Customer and its fields
     * through a permission set built here, so the tests do not depend on how
     * access is granted in the org.
     */
    private static User apiUser() {
        if (apiUser == null) {
            String unique = 'customerapi' + Crypto.getRandomInteger() + '@shreehari.test';
            apiUser = new User(
                ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id,
                LastName = 'Customer API', Alias = 'custapi', Email = unique, Username = unique,
                TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN', EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            );
            System.runAs(new User(Id = UserInfo.getUserId())) {
                insert apiUser;

                PermissionSet access = new PermissionSet(
                    Name = 'Test_Staging_Customer_Access', Label = 'Test Staging Customer Access'
                );
                insert access;
                insert new ObjectPermissions(
                    ParentId = access.Id, SobjectType = 'Staging_Customer__c',
                    PermissionsCreate = true, PermissionsRead = true
                );
                List<FieldPermissions> fieldAccess = new List<FieldPermissions>();
                for (Schema.SObjectField field : Schema.SObjectType.Staging_Customer__c.fields.getMap().values()) {
                    Schema.DescribeFieldResult d = field.getDescribe();
                    if (d.isCustom() && d.isPermissionable()) {
                        fieldAccess.add(new FieldPermissions(
                            ParentId = access.Id, SobjectType = 'Staging_Customer__c',
                            Field = 'Staging_Customer__c.' + d.getName(),
                            PermissionsRead = true, PermissionsEdit = true
                        ));
                    }
                }
                insert fieldAccess;
                insert new PermissionSetAssignment(AssigneeId = apiUser.Id, PermissionSetId = access.Id);
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
            ShreeHariCustomerRestResource.receiveCustomer();
        }

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        parsed.put('__status', RestContext.response.statusCode);
        return parsed;
    }

    /** Every documented property of the Shopify customer object. */
    private static Map<String, Object> fullCustomer() {
        Map<String, Object> address = new Map<String, Object>{
            'id' => 56174706753L, 'first_name' => 'Asha', 'last_name' => 'Mehta', 'name' => 'Asha Mehta',
            'company' => null, 'address1' => '12 MG Road', 'address2' => '2nd floor',
            'street' => '12 MG Road, 2nd floor', 'city' => 'Ahmedabad', 'province' => 'Gujarat',
            'province_code' => 'GJ', 'country' => new Map<String, Object>{ 'name' => 'India', 'iso_code' => 'IN' },
            'country_code' => 'IN', 'zip' => '380001', 'phone' => '+919876543210',
            'summary' => 'Asha Mehta, 12 MG Road, 2nd floor, Ahmedabad, Gujarat, India',
            'url' => '/account/addresses/56174706753'
        };
        Map<String, Object> order = new Map<String, Object>{
            'id' => 3945659400257L, 'name' => '#1001', 'order_number' => 1001,
            'created_at' => '2026-11-01T10:30:00+05:30', 'financial_status' => 'paid',
            'fulfillment_status' => 'fulfilled', 'total_price' => 4500000,
            'line_items' => new List<Object>{
                new Map<String, Object>{ 'title' => 'Classic Gold Ring', 'quantity' => 1, 'sku' => 'RING-16-22K' }
            }
        };
        Map<String, Object> location = new Map<String, Object>{
            'id' => 9001L, 'name' => 'Ahmedabad Showroom', 'current?' => true
        };
        return new Map<String, Object>{
            'id' => 5625411010625L,
            'name' => 'Asha Mehta',
            'first_name' => 'Asha',
            'last_name' => 'Mehta',
            'email' => 'asha.mehta@example.com',
            'phone' => '+919876543210',
            'addresses_count' => 1,
            'company_available_locations_count' => 1,
            'orders_count' => 1,
            'total_spent' => 4500000,
            'accepts_marketing' => true,
            'b2b?' => false,
            'has_account' => true,
            'has_avatar?' => false,
            'tax_exempt' => false,
            'addresses' => new List<Object>{ address },
            'default_address' => address,
            'company_available_locations' => new List<Object>{ location },
            'current_company' => new Map<String, Object>{ 'id' => 8001L, 'name' => 'Mehta Jewels' },
            'current_location' => location,
            'orders' => new List<Object>{ order },
            'last_order' => order,
            'payment_methods' => new List<Object>{
                new Map<String, Object>{ 'id' => 7001L, 'payment_instrument_type' => 'credit_card' }
            },
            'store_credit_account' => new Map<String, Object>{
                'balance' => new Map<String, Object>{ 'value' => 50000, 'currency' => 'INR' }
            },
            'tags' => new List<Object>{ 'newsletter', 'vip' },
            'metafields' => new Map<String, Object>{
                'custom' => new Map<String, Object>{ 'anniversary' => '2020-02-14', 'ring_size' => 16 }
            }
        };
    }

    private static Staging_Customer__c onlyRecord() {
        List<Staging_Customer__c> records = [
            SELECT Id, Name, Id__c, Name__c, First_Name__c, Last_Name__c, Email__c, Phone__c,
                Addresses_Count__c, Company_Available_Locations_Count__c, Orders_Count__c, Total_Spent__c,
                Accepts_Marketing__c, B2B__c, Has_Account__c, Has_Avatar__c, Tax_Exempt__c,
                Addresses__c, Default_Address__c, Company_Available_Locations__c, Current_Company__c,
                Current_Location__c, Orders__c, Last_Order__c, Payment_Methods__c, Store_Credit_Account__c,
                Tags__c, Metafields__c, Additional_Properties__c, Processing_Status__c
            FROM Staging_Customer__c
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(1, records.size(), 'Exactly one Staging Customer should exist');
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

    private static void assertRejected(Map<String, Object> response, String errorCode, String field) {
        Assert.areEqual(400, response.get('__status'), 'Should be a bad request: ' + response);
        Assert.areEqual(false, response.get('success'), 'success should be false');
        Assert.areEqual(errorCode, response.get('errorCode'), 'Error code should name the cause: ' + response);
        Assert.areEqual(field, response.get('field'), 'The offending property should be reported');
        Assert.isTrue(String.isNotBlank((String) response.get('message')), 'A reason should be given');
        Assert.areEqual(0, [SELECT COUNT() FROM Staging_Customer__c WITH SYSTEM_MODE], 'Nothing should be saved');
    }

    private static Map<String, Object> withChange(String key, Object value) {
        Map<String, Object> customer = fullCustomer();
        customer.put(key, value);
        return customer;
    }

    // =====================================================================
    // Stored as sent
    // =====================================================================

    @IsTest
    static void storesEveryDocumentedProperty() {
        Map<String, Object> customer = fullCustomer();

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(customer));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Assert.areEqual(true, response.get('success'), 'success should be true');

        Staging_Customer__c r = onlyRecord();
        Assert.areEqual(String.valueOf(r.Id), response.get('stagingCustomerId'), 'Response should carry the record Id');
        Assert.areEqual(r.Name, response.get('stagingCustomerNumber'), 'Response should carry SC number');
        Assert.isTrue(r.Name.startsWith('SC-'), 'Name should be the SC- auto number');
        Assert.areEqual('5625411010625', response.get('shopifyCustomerId'), 'Response should echo the id');
        Assert.areEqual(ShreeHariCustomerRestResource.STATUS_NEW, r.Processing_Status__c, 'New on arrival');

        // Text
        Assert.areEqual('5625411010625', r.Id__c, 'id');
        Assert.areEqual('Asha Mehta', r.Name__c, 'name');
        Assert.areEqual('Asha', r.First_Name__c, 'first_name');
        Assert.areEqual('Mehta', r.Last_Name__c, 'last_name');
        Assert.areEqual('asha.mehta@example.com', r.Email__c, 'email');
        Assert.areEqual('+919876543210', r.Phone__c, 'phone');
        // Numbers, unconverted
        assertNumber(1, r.Addresses_Count__c, 'addresses_count');
        assertNumber(1, r.Company_Available_Locations_Count__c, 'company_available_locations_count');
        assertNumber(1, r.Orders_Count__c, 'orders_count');
        assertNumber(4500000, r.Total_Spent__c, 'total_spent');
        // True / false
        Assert.isTrue(r.Accepts_Marketing__c, 'accepts_marketing');
        Assert.isFalse(r.B2B__c, 'b2b?');
        Assert.isTrue(r.Has_Account__c, 'has_account');
        Assert.isFalse(r.Has_Avatar__c, 'has_avatar?');
        Assert.isFalse(r.Tax_Exempt__c, 'tax_exempt');
        // Arrays and nested objects, as JSON
        assertJson(customer.get('addresses'), r.Addresses__c, 'addresses');
        assertJson(customer.get('default_address'), r.Default_Address__c, 'default_address');
        assertJson(customer.get('company_available_locations'), r.Company_Available_Locations__c,
            'company_available_locations');
        assertJson(customer.get('current_company'), r.Current_Company__c, 'current_company');
        assertJson(customer.get('current_location'), r.Current_Location__c, 'current_location');
        assertJson(customer.get('orders'), r.Orders__c, 'orders');
        assertJson(customer.get('last_order'), r.Last_Order__c, 'last_order');
        assertJson(customer.get('payment_methods'), r.Payment_Methods__c, 'payment_methods');
        assertJson(customer.get('store_credit_account'), r.Store_Credit_Account__c, 'store_credit_account');
        assertJson(customer.get('tags'), r.Tags__c, 'tags');
        assertJson(customer.get('metafields'), r.Metafields__c, 'metafields');
        Assert.isNull(r.Additional_Properties__c, 'Nothing undocumented was sent');
    }

    @IsTest
    static void everyDocumentedPropertyHasAFieldNamedAfterIt() {
        Set<String> keys = new Set<String>();
        Set<Schema.SObjectField> fields = new Set<Schema.SObjectField>();
        for (ShreeHariCustomerRestResource.Mapping m : ShreeHariCustomerRestResource.MAPPINGS) {
            keys.add(m.key);
            fields.add(m.field);

            // first_name -> First_Name__c, has_avatar? -> Has_Avatar__c, b2b? -> B2B__c
            List<String> words = new List<String>();
            for (String word : m.key.removeEnd('?').split('_')) {
                words.add(word == 'b2b' ? 'B2B' : word.capitalize());
            }
            Schema.DescribeFieldResult d = m.field.getDescribe();
            Assert.isTrue((String.join(words, '_') + '__c').equals(d.getName()), 'Field name for ' + m.key + ': ' + d.getName());
            Assert.isTrue(String.join(words, ' ').equals(d.getLabel()), 'Field label for ' + m.key + ': ' + d.getLabel());
            Assert.areNotEqual(Schema.DisplayType.PICKLIST, d.getType(),
                'The documentation gives no customer property a set of values: ' + m.key);
        }
        Assert.areEqual(26, keys.size(), 'All 26 documented customer properties should be mapped');
        Assert.areEqual(26, fields.size(), 'Each property should have its own field');
        Assert.areEqual(keys, fullCustomer().keySet(), 'The test payload should carry every mapped property');
    }

    @IsTest
    static void storesTheShopifyDocumentationExample() {
        // The example on https://shopify.dev/docs/api/liquid/objects/customer, as published
        String body = '{"accepts_marketing": true, "addresses": [], "addresses_count": 5, "b2b?": false,'
            + ' "company_available_locations": [], "company_available_locations_count": 1,'
            + ' "current_company": {}, "current_location": null, "default_address": {},'
            + ' "email": "cornelius.potionmaker@gmail.com", "first_name": "Cornelius", "has_account": true,'
            + ' "has_avatar?": false, "id": 5625411010625, "last_name": "Potionmaker", "last_order": {},'
            + ' "metafields": {}, "name": "Cornelius Potionmaker", "orders": [], "orders_count": 1,'
            + ' "payment_methods": [], "phone": "+441314960905", "store_credit_account": {},'
            + ' "tags": ["newsletter"], "tax_exempt": false, "total_spent": 5600}';

        Test.startTest();
        Map<String, Object> response = post(body);
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'The documented example should be accepted: ' + response);
        Staging_Customer__c r = onlyRecord();
        Assert.areEqual('5625411010625', r.Id__c, 'id');
        Assert.areEqual('Cornelius Potionmaker', r.Name__c, 'name');
        Assert.areEqual('+441314960905', r.Phone__c, 'phone');
        assertNumber(5, r.Addresses_Count__c, 'addresses_count');
        assertNumber(5600, r.Total_Spent__c, 'total_spent');
        Assert.areEqual('[]', r.Addresses__c, 'An empty array is stored as sent');
        Assert.areEqual('{}', r.Default_Address__c, 'An empty object is stored as sent');
        Assert.isNull(r.Current_Location__c, 'null current_location stays blank');
        assertJson(new List<Object>{ 'newsletter' }, r.Tags__c, 'tags');
        Assert.isNull(r.Additional_Properties__c, 'Nothing undocumented in the example');
    }

    @IsTest
    static void keepsUndocumentedKeysInAdditionalProperties() {
        Map<String, Object> customer = withChange('created_at', '2026-11-01T10:30:00+05:30');
        customer.put('state', 'enabled');

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(customer));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Map<String, Object> extra = (Map<String, Object>) JSON.deserializeUntyped(onlyRecord().Additional_Properties__c);
        Assert.areEqual(2, extra.size(), 'Only the undocumented keys should be kept there');
        Assert.areEqual('2026-11-01T10:30:00+05:30', extra.get('created_at'), 'created_at kept');
        Assert.areEqual('enabled', extra.get('state'), 'state kept');
    }

    @IsTest
    static void storesOnlyWhatIsSentAndIgnoresNulls() {
        Test.startTest();
        Map<String, Object> response = post('{"id": "123", "email": null, "orders": null, "total_spent": null}');
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Only id is required: ' + response);
        Staging_Customer__c r = onlyRecord();
        Assert.areEqual('123', r.Id__c, 'id');
        Assert.isNull(r.Email__c, 'null email stays blank');
        Assert.isNull(r.Orders__c, 'null orders stays blank');
        Assert.isNull(r.Total_Spent__c, 'null total_spent stays blank');
        Assert.isFalse(r.Accepts_Marketing__c, 'A flag that was not sent is unchecked');
        Assert.isNull(r.Additional_Properties__c, 'null documented keys are not undocumented');
    }

    @IsTest
    static void treatsEmptyTextAsNoValueForNumbersAndFlags() {
        Map<String, Object> customer = fullCustomer();
        customer.put('total_spent', '');
        customer.put('orders_count', '  ');
        customer.put('accepts_marketing', '');
        customer.put('phone', '');

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(customer));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Empty text is not an error: ' + response);
        Staging_Customer__c r = onlyRecord();
        Assert.isNull(r.Total_Spent__c, 'total_spent');
        Assert.isNull(r.Orders_Count__c, 'orders_count');
        Assert.isFalse(r.Accepts_Marketing__c, 'accepts_marketing');
        Assert.isNull(r.Phone__c, 'phone');
        Assert.isNull(r.Additional_Properties__c, 'Empty documented keys are not undocumented');
    }

    @IsTest
    static void eachCallCreatesANewRecord() {
        String body = JSON.serialize(fullCustomer());

        Test.startTest();
        Map<String, Object> first = post(body);
        Map<String, Object> second = post(body);
        Test.stopTest();

        Assert.areEqual(201, first.get('__status'), 'First call created');
        Assert.areEqual(201, second.get('__status'), 'Second call created');
        Assert.areNotEqual(first.get('stagingCustomerId'), second.get('stagingCustomerId'), 'Two records');
        Assert.areNotEqual(first.get('stagingCustomerNumber'), second.get('stagingCustomerNumber'), 'Two SC numbers');
        Assert.areEqual(2, [SELECT COUNT() FROM Staging_Customer__c WHERE Id__c = '5625411010625' WITH SYSTEM_MODE],
            'Both calls should be kept as history');
    }

    @IsTest
    static void acceptsTheCustomerWrapperAndNamesWithoutQuestionMark() {
        Map<String, Object> customer = fullCustomer();
        customer.remove('b2b?');
        customer.remove('has_avatar?');
        customer.put('b2b', true);
        customer.put('has_avatar', true);

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(new Map<String, Object>{ 'customer' => customer }));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Wrapped customer accepted: ' + response);
        Staging_Customer__c r = onlyRecord();
        Assert.areEqual('5625411010625', r.Id__c, 'Unwrapped id');
        Assert.isTrue(r.B2B__c, 'b2b without ? is read');
        Assert.isTrue(r.Has_Avatar__c, 'has_avatar without ? is read');
        Assert.isNull(r.Additional_Properties__c, 'Alternate names are not undocumented');
    }

    @IsTest
    static void acceptsNumbersAndBooleansSentAsTextAndKeepsPlainStringsAsSent() {
        Map<String, Object> customer = withChange('total_spent', '45000.50');
        customer.put('orders_count', ' 7 ');
        customer.put('accepts_marketing', 'FALSE');
        customer.put('tags', 'vip, newsletter');
        customer.put('id', 'gid://shopify/Customer/5625411010625');
        customer.put('phone', '098765 43210');
        customer.put('email', 'not an email');

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(customer));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Staging_Customer__c r = onlyRecord();
        assertNumber(45000.50, r.Total_Spent__c, 'Numeric text is stored as a number');
        assertNumber(7, r.Orders_Count__c, 'Numeric text with spaces is stored as a number');
        Assert.isFalse(r.Accepts_Marketing__c, 'Boolean text is stored as a checkbox');
        Assert.areEqual('vip, newsletter', r.Tags__c, 'A plain string is kept exactly as sent');
        Assert.areEqual('gid://shopify/Customer/5625411010625', r.Id__c, 'Text ids are kept as sent');
        Assert.areEqual('098765 43210', r.Phone__c, 'phone is kept as typed');
        Assert.areEqual('not an email', r.Email__c, 'email is kept as sent, not validated');
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
    static void rejectsMoreThanOneCustomerPerCall() {
        Test.startTest();
        Map<String, Object> response = post('[{"id": "1"}, {"id": "2"}]');
        Test.stopTest();
        assertRejected(response, 'INVALID_JSON', null);
    }

    @IsTest
    static void rejectsAMissingId() {
        Map<String, Object> customer = fullCustomer();
        customer.remove('id');
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(customer));
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
    static void rejectsAnObjectInATextProperty() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('email', new Map<String, Object>{ 'value' => 'a@b.c' })));
        Test.stopTest();
        assertRejected(response, 'INVALID_TYPE', 'email');
    }

    @IsTest
    static void rejectsAnArrayInATextProperty() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('phone', new List<Object>{ '+919876543210' })));
        Test.stopTest();
        assertRejected(response, 'INVALID_TYPE', 'phone');
    }

    @IsTest
    static void rejectsANonNumericCount() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('orders_count', 'ten')));
        Test.stopTest();
        assertRejected(response, 'INVALID_NUMBER', 'orders_count');
    }

    @IsTest
    static void rejectsABooleanInANumberProperty() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('addresses_count', true)));
        Test.stopTest();
        assertRejected(response, 'INVALID_NUMBER', 'addresses_count');
    }

    @IsTest
    static void rejectsANumberTooLargeForItsField() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('total_spent', 123456789012345L)));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', 'total_spent');
    }

    @IsTest
    static void rejectsANonBooleanFlag() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('accepts_marketing', 'yes')));
        Test.stopTest();
        assertRejected(response, 'INVALID_BOOLEAN', 'accepts_marketing');
    }

    @IsTest
    static void rejectsANumberInAFlagWithoutQuestionMark() {
        Map<String, Object> customer = fullCustomer();
        customer.remove('b2b?');
        customer.put('b2b', 1);
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(customer));
        Test.stopTest();
        assertRejected(response, 'INVALID_BOOLEAN', 'b2b');
    }

    @IsTest
    static void rejectsAnArrayLongerThanItsField() {
        List<Object> orders = new List<Object>();
        String filler = 'x'.repeat(1000);
        for (Integer i = 0; i < 140; i++) {
            orders.add(new Map<String, Object>{ 'id' => i, 'name' => filler });
        }
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('orders', orders)));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', 'orders');
    }

    @IsTest
    static void rejectsTextLongerThanItsField() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('first_name', 'a'.repeat(256))));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', 'first_name');
    }

    @IsTest
    static void rejectsUndocumentedKeysLongerThanAdditionalProperties() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('note', 'x'.repeat(131100))));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', ShreeHariCustomerRestResource.ADDITIONAL_PROPERTIES);
    }
}
