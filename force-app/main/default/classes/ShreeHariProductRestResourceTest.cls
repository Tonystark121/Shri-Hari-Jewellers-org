/**
 * Tests for the Shopify product staging endpoint.
 *
 * Each test drives the resource the way the sender does: a JSON body in, a
 * status code and JSON body out, then checks what was stored on
 * Staging_Product__c and Staging_Product_Variant__c.
 */
@IsTest
private class ShreeHariProductRestResourceTest {

    private static final String RESOURCE_URI = '/services/apexrest/shreehari/v1/products';

    // =====================================================================
    // Helpers
    // =====================================================================

    private static User apiUser;

    /**
     * A Standard User given create and read on Staging Product, Staging
     * Product Variant and their fields through a permission set built here, so
     * the tests do not depend on how access is granted in the org.
     */
    private static User apiUser() {
        if (apiUser == null) {
            String unique = 'productapi' + Crypto.getRandomInteger() + '@shreehari.test';
            apiUser = new User(
                ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id,
                LastName = 'Product API', Alias = 'prodapi', Email = unique, Username = unique,
                TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN', EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            );
            System.runAs(new User(Id = UserInfo.getUserId())) {
                insert apiUser;

                PermissionSet access = new PermissionSet(
                    Name = 'Test_Staging_Product_Access', Label = 'Test Staging Product Access'
                );
                insert access;
                List<ObjectPermissions> objectAccess = new List<ObjectPermissions>();
                List<FieldPermissions> fieldAccess = new List<FieldPermissions>();
                for (Schema.SObjectType objectType : new List<Schema.SObjectType>{
                    Staging_Product__c.SObjectType, Staging_Product_Variant__c.SObjectType
                }) {
                    String objectName = objectType.getDescribe().getName();
                    objectAccess.add(new ObjectPermissions(
                        ParentId = access.Id, SobjectType = objectName,
                        PermissionsCreate = true, PermissionsRead = true
                    ));
                    for (Schema.SObjectField field : objectType.getDescribe().fields.getMap().values()) {
                        Schema.DescribeFieldResult d = field.getDescribe();
                        if (d.isCustom() && d.isPermissionable()) {
                            fieldAccess.add(new FieldPermissions(
                                ParentId = access.Id, SobjectType = objectName,
                                Field = objectName + '.' + d.getName(),
                                PermissionsRead = true, PermissionsEdit = true
                            ));
                        }
                    }
                }
                insert objectAccess;
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
            ShreeHariProductRestResource.receiveProduct();
        }

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        parsed.put('__status', RestContext.response.statusCode);
        return parsed;
    }

    /** Every documented property of the Shopify product object. */
    private static Map<String, Object> fullProduct() {
        Map<String, Object> image = new Map<String, Object>{
            'id' => 1001L, 'src' => 'products/ring.jpg', 'alt' => 'Gold ring',
            'position' => 1, 'width' => 800, 'height' => 800, 'aspect_ratio' => 1.0
        };
        Map<String, Object> media = new Map<String, Object>{
            'id' => 2001L, 'media_type' => 'image', 'position' => 1, 'alt' => 'Gold ring',
            'preview_image' => image
        };
        Map<String, Object> variant = fullVariant(39897499729985L, 'RING-16-22K');
        Map<String, Object> option = new Map<String, Object>{
            'name' => 'Size', 'position' => 1, 'selected_value' => '16',
            'values' => new List<Object>{ '14', '16', '18' }
        };
        return new Map<String, Object>{
            'id' => 6786188247105L,
            'title' => 'Classic Gold Ring',
            'handle' => 'classic-gold-ring',
            'vendor' => 'Shree Hari',
            'type' => 'Ring',
            'template_suffix' => '',
            'url' => '/products/classic-gold-ring',
            'description' => '<p>22K gold ring.</p>',
            'content' => '<p>22K gold ring.</p>',
            'price' => 4500000,
            'price_min' => 4500000,
            'price_max' => 5200000,
            'compare_at_price' => 4800000,
            'compare_at_price_min' => 4800000,
            'compare_at_price_max' => 5500000,
            'variants_count' => 2,
            'available' => true,
            'gift_card?' => false,
            'has_only_default_variant' => false,
            'price_varies' => true,
            'compare_at_price_varies' => true,
            'requires_selling_plan' => false,
            'quantity_price_breaks_configured?' => false,
            'created_at' => '2026-11-01T10:30:00+05:30',
            'published_at' => '2026-11-02T08:00:00Z',
            'variants' => new List<Object>{ variant, fullVariant(39897499762753L, 'RING-18-22K') },
            'collections' => new List<Object>{
                new Map<String, Object>{ 'id' => 3001L, 'handle' => 'rings', 'title' => 'Rings' }
            },
            'images' => new List<Object>{ image },
            'media' => new List<Object>{ media },
            'tags' => new List<Object>{ '22K', 'gold', 'ring' },
            'options' => new List<Object>{ 'Size', 'Purity' },
            'options_with_values' => new List<Object>{ option },
            'options_by_name' => new Map<String, Object>{ 'size' => option },
            'selling_plan_groups' => new List<Object>(),
            'metafields' => new Map<String, Object>{
                'custom' => new Map<String, Object>{ 'purity' => '22K', 'gross_weight' => 5.25 }
            },
            'category' => new Map<String, Object>{ 'id' => 'aa-6-8', 'name' => 'Rings' },
            'featured_image' => image,
            'featured_media' => media,
            'first_available_variant' => variant,
            'selected_variant' => variant,
            'selected_or_first_available_variant' => variant,
            'selected_selling_plan' => new Map<String, Object>{ 'id' => 1L, 'name' => 'Monthly' },
            'selected_selling_plan_allocation' => new Map<String, Object>{ 'price' => 4500000 },
            'selected_or_first_available_selling_plan_allocation' => new Map<String, Object>{ 'price' => 4400000 }
        };
    }

    /** Every documented property of the Shopify variant object, deprecated ones included. */
    private static Map<String, Object> fullVariant(Long id, String sku) {
        Map<String, Object> image = new Map<String, Object>{ 'id' => 1001L, 'src' => 'products/ring.jpg' };
        return new Map<String, Object>{
            'available' => true,
            'barcode' => '8901234567890',
            'compare_at_price' => 4800000,
            'featured_image' => image,
            'featured_media' => new Map<String, Object>{ 'id' => 2001L, 'media_type' => 'image' },
            'id' => id,
            'image' => image,
            'incoming' => true,
            'inventory_management' => 'shopify',
            'inventory_policy' => 'deny',
            'inventory_quantity' => -2,
            'matched' => true,
            'metafields' => new Map<String, Object>{
                'custom.net_weight' => new Map<String, Object>{ 'type' => 'number_decimal', 'value' => 4.9 }
            },
            'next_incoming_date' => '2026-12-01 09:00:00 +0530',
            'options' => new List<Object>{ '16', '22K' },
            'options_with_values' => new List<Object>{
                new Map<String, Object>{ 'name' => 'Size', 'value' => '16' },
                new Map<String, Object>{ 'name' => 'Purity', 'value' => '22K' }
            },
            'price' => 4500000,
            'product' => new Map<String, Object>{ 'id' => 6786188247105L },
            'quantity_price_breaks' => new List<Object>{
                new Map<String, Object>{ 'minimum_quantity' => 5, 'price' => 4400000 }
            },
            'quantity_price_breaks_configured?' => true,
            'quantity_rule' => new Map<String, Object>{ 'min' => 1, 'max' => null, 'increment' => 1 },
            'requires_selling_plan' => false,
            'requires_shipping' => true,
            'selected' => false,
            'selected_selling_plan_allocation' => new Map<String, Object>{ 'price' => 4400000 },
            'selling_plan_allocations' => new List<Object>{ new Map<String, Object>{ 'price' => 4400000 } },
            'sku' => sku,
            'store_availabilities' => new List<Object>{
                new Map<String, Object>{ 'available' => true, 'pick_up_enabled' => true }
            },
            'taxable' => true,
            'title' => '16 / 22K',
            'unit_price' => 900000,
            'unit_price_measurement' => new Map<String, Object>{ 'measured_type' => 'weight', 'quantity_unit' => 'g' },
            'url' => '/products/classic-gold-ring?variant=' + id,
            'weight' => 5.25,
            'weight_in_unit' => 5.25,
            'weight_unit' => 'g',
            'option1' => '16',
            'option2' => '22K',
            'option3' => null
        };
    }

    private static List<Staging_Product_Variant__c> variantsOf(Id productId) {
        return [
            SELECT Id, Name, Staging_Product__c, Available__c, Barcode__c, Compare_At_Price__c, Featured_Image__c,
                Featured_Media__c, Id__c, Image__c, Incoming__c, Inventory_Management__c, Inventory_Policy__c,
                Inventory_Quantity__c, Matched__c, Metafields__c, Next_Incoming_Date__c, Options__c,
                Options_With_Values__c, Price__c, Product__c, Quantity_Price_Breaks__c,
                Quantity_Price_Breaks_Configured__c, Quantity_Rule__c, Requires_Selling_Plan__c,
                Requires_Shipping__c, Selected__c, Selected_Selling_Plan_Allocation__c,
                Selling_Plan_Allocations__c, SKU__c, Store_Availabilities__c, Taxable__c, Title__c, Unit_Price__c,
                Unit_Price_Measurement__c, Url__c, Weight__c, Weight_In_Unit__c, Weight_Unit__c, Option1__c,
                Option2__c, Option3__c, Additional_Properties__c
            FROM Staging_Product_Variant__c
            WHERE Staging_Product__c = :productId
            WITH SYSTEM_MODE
            ORDER BY Name
        ];
    }

    private static Map<String, Object> productWithVariants(List<Object> variants) {
        Map<String, Object> product = fullProduct();
        product.put('variants', variants);
        return product;
    }

    private static Staging_Product__c onlyRecord() {
        List<Staging_Product__c> records = [
            SELECT Id, Name, Shopify_Id__c, Title__c, Handle__c, Vendor__c, Product_Type__c,
                Template_Suffix__c, Url__c, Description__c, Content__c,
                Price__c, Price_Min__c, Price_Max__c, Compare_At_Price__c,
                Compare_At_Price_Min__c, Compare_At_Price_Max__c, Variants_Count__c,
                Available__c, Gift_Card__c, Has_Only_Default_Variant__c, Price_Varies__c,
                Compare_At_Price_Varies__c, Requires_Selling_Plan__c,
                Quantity_Price_Breaks_Configured__c, Shopify_Created_At__c, Shopify_Published_At__c,
                Collections__c, Images__c, Media__c, Tags__c, Options__c,
                Options_With_Values__c, Options_By_Name__c, Selling_Plan_Groups__c, Metafields__c,
                Category__c, Featured_Image__c, Featured_Media__c, First_Available_Variant__c,
                Selected_Variant__c, Selected_Or_First_Available_Variant__c, Selected_Selling_Plan__c,
                Selected_Selling_Plan_Allocation__c, Selected_Or_First_Avail_Plan_Allocation__c,
                Additional_Properties__c, Processing_Status__c
            FROM Staging_Product__c
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(1, records.size(), 'Exactly one Staging Product should exist');
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
        Assert.areEqual(0, [SELECT COUNT() FROM Staging_Product__c WITH SYSTEM_MODE], 'No product should be saved');
        Assert.areEqual(0, [SELECT COUNT() FROM Staging_Product_Variant__c WITH SYSTEM_MODE], 'No variant should be saved');
    }

    private static Map<String, Object> withChange(String key, Object value) {
        Map<String, Object> product = fullProduct();
        product.put(key, value);
        return product;
    }

    // =====================================================================
    // Stored as sent
    // =====================================================================

    @IsTest
    static void storesEveryDocumentedProperty() {
        Map<String, Object> product = fullProduct();

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(product));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Assert.areEqual(true, response.get('success'), 'success should be true');

        Staging_Product__c r = onlyRecord();
        Assert.areEqual(String.valueOf(r.Id), response.get('stagingProductId'), 'Response should carry the record Id');
        Assert.areEqual(r.Name, response.get('stagingProductNumber'), 'Response should carry SP number');
        Assert.isTrue(r.Name.startsWith('SP-'), 'Name should be the SP- auto number');
        Assert.areEqual('6786188247105', response.get('shopifyProductId'), 'Response should echo the id');
        Assert.areEqual(ShreeHariProductRestResource.STATUS_NEW, r.Processing_Status__c, 'New on arrival');

        // Text
        Assert.areEqual('6786188247105', r.Shopify_Id__c, 'id');
        Assert.areEqual('Classic Gold Ring', r.Title__c, 'title');
        Assert.areEqual('classic-gold-ring', r.Handle__c, 'handle');
        Assert.areEqual('Shree Hari', r.Vendor__c, 'vendor');
        Assert.areEqual('Ring', r.Product_Type__c, 'type');
        Assert.isNull(r.Template_Suffix__c, 'template_suffix sent empty is stored blank');
        Assert.areEqual('/products/classic-gold-ring', r.Url__c, 'url');
        Assert.areEqual('<p>22K gold ring.</p>', r.Description__c, 'description');
        Assert.areEqual('<p>22K gold ring.</p>', r.Content__c, 'content');
        // Numbers, unconverted
        assertNumber(4500000, r.Price__c, 'price');
        assertNumber(4500000, r.Price_Min__c, 'price_min');
        assertNumber(5200000, r.Price_Max__c, 'price_max');
        assertNumber(4800000, r.Compare_At_Price__c, 'compare_at_price');
        assertNumber(4800000, r.Compare_At_Price_Min__c, 'compare_at_price_min');
        assertNumber(5500000, r.Compare_At_Price_Max__c, 'compare_at_price_max');
        assertNumber(2, r.Variants_Count__c, 'variants_count');
        // True / false
        Assert.isTrue(r.Available__c, 'available');
        Assert.isFalse(r.Gift_Card__c, 'gift_card?');
        Assert.isFalse(r.Has_Only_Default_Variant__c, 'has_only_default_variant');
        Assert.isTrue(r.Price_Varies__c, 'price_varies');
        Assert.isTrue(r.Compare_At_Price_Varies__c, 'compare_at_price_varies');
        Assert.isFalse(r.Requires_Selling_Plan__c, 'requires_selling_plan');
        Assert.isFalse(r.Quantity_Price_Breaks_Configured__c, 'quantity_price_breaks_configured?');
        // Timestamps
        Assert.areEqual(Datetime.newInstanceGmt(2026, 11, 1, 5, 0, 0), r.Shopify_Created_At__c, 'created_at');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 11, 2, 8, 0, 0), r.Shopify_Published_At__c, 'published_at');
        // Arrays and nested objects, as JSON
        assertJson(product.get('collections'), r.Collections__c, 'collections');
        assertJson(product.get('images'), r.Images__c, 'images');
        assertJson(product.get('media'), r.Media__c, 'media');
        assertJson(product.get('tags'), r.Tags__c, 'tags');
        assertJson(product.get('options'), r.Options__c, 'options');
        assertJson(product.get('options_with_values'), r.Options_With_Values__c, 'options_with_values');
        assertJson(product.get('options_by_name'), r.Options_By_Name__c, 'options_by_name');
        assertJson(product.get('selling_plan_groups'), r.Selling_Plan_Groups__c, 'selling_plan_groups');
        assertJson(product.get('metafields'), r.Metafields__c, 'metafields');
        assertJson(product.get('category'), r.Category__c, 'category');
        assertJson(product.get('featured_image'), r.Featured_Image__c, 'featured_image');
        assertJson(product.get('featured_media'), r.Featured_Media__c, 'featured_media');
        assertJson(product.get('first_available_variant'), r.First_Available_Variant__c, 'first_available_variant');
        assertJson(product.get('selected_variant'), r.Selected_Variant__c, 'selected_variant');
        assertJson(product.get('selected_or_first_available_variant'), r.Selected_Or_First_Available_Variant__c,
            'selected_or_first_available_variant');
        assertJson(product.get('selected_selling_plan'), r.Selected_Selling_Plan__c, 'selected_selling_plan');
        assertJson(product.get('selected_selling_plan_allocation'), r.Selected_Selling_Plan_Allocation__c,
            'selected_selling_plan_allocation');
        assertJson(product.get('selected_or_first_available_selling_plan_allocation'),
            r.Selected_Or_First_Avail_Plan_Allocation__c, 'selected_or_first_available_selling_plan_allocation');
        Assert.isNull(r.Additional_Properties__c, 'Nothing undocumented was sent');
        Assert.areEqual(2, response.get('variantCount'), 'Response should give the number of variants stored');
        Assert.areEqual('Product received and stored as ' + r.Name + ' with 2 variants.', response.get('message'), 'message');
        Assert.areEqual(2, variantsOf(r.Id).size(), 'One Staging Product Variant per variant sent');
    }

    @IsTest
    static void storesEveryVariantPropertyOnItsOwnRecord() {
        Map<String, Object> product = fullProduct();
        Map<String, Object> sent = (Map<String, Object>) ((List<Object>) product.get('variants'))[0];

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(product));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Staging_Product__c r = onlyRecord();
        List<Staging_Product_Variant__c> variants = variantsOf(r.Id);
        Assert.areEqual(2, variants.size(), 'Both variants stored');
        Staging_Product_Variant__c v = variants[0];
        Assert.isTrue(v.Name.startsWith('SPV-'), 'Name should be the SPV- auto number');
        Assert.areEqual(r.Id, v.Staging_Product__c, 'Linked to its Staging Product');
        Assert.areEqual('RING-18-22K', variants[1].SKU__c, 'Variants are stored in the order sent');

        // Text
        Assert.areEqual('39897499729985', v.Id__c, 'id');
        Assert.areEqual('16 / 22K', v.Title__c, 'title');
        Assert.areEqual('RING-16-22K', v.SKU__c, 'sku');
        Assert.areEqual('8901234567890', v.Barcode__c, 'barcode');
        Assert.areEqual('shopify', v.Inventory_Management__c, 'inventory_management');
        Assert.areEqual('/products/classic-gold-ring?variant=39897499729985', v.Url__c, 'url');
        Assert.areEqual('g', v.Weight_Unit__c, 'weight_unit');
        Assert.areEqual('16', v.Option1__c, 'option1');
        Assert.areEqual('22K', v.Option2__c, 'option2');
        Assert.isNull(v.Option3__c, 'option3 sent as null stays blank');
        // Picklist
        Assert.areEqual('deny', v.Inventory_Policy__c, 'inventory_policy');
        // Numbers, unconverted
        assertNumber(4500000, v.Price__c, 'price');
        assertNumber(4800000, v.Compare_At_Price__c, 'compare_at_price');
        assertNumber(900000, v.Unit_Price__c, 'unit_price');
        assertNumber(-2, v.Inventory_Quantity__c, 'inventory_quantity can be negative');
        assertNumber(5.25, v.Weight__c, 'weight');
        assertNumber(5.25, v.Weight_In_Unit__c, 'weight_in_unit');
        // True / false
        Assert.isTrue(v.Available__c, 'available');
        Assert.isTrue(v.Incoming__c, 'incoming');
        Assert.isTrue(v.Matched__c, 'matched');
        Assert.isTrue(v.Quantity_Price_Breaks_Configured__c, 'quantity_price_breaks_configured?');
        Assert.isFalse(v.Requires_Selling_Plan__c, 'requires_selling_plan');
        Assert.isTrue(v.Requires_Shipping__c, 'requires_shipping');
        Assert.isFalse(v.Selected__c, 'selected');
        Assert.isTrue(v.Taxable__c, 'taxable');
        // Timestamp
        Assert.areEqual(Datetime.newInstanceGmt(2026, 12, 1, 3, 30, 0), v.Next_Incoming_Date__c, 'next_incoming_date');
        // Nested objects and arrays, as JSON
        assertJson(sent.get('featured_image'), v.Featured_Image__c, 'featured_image');
        assertJson(sent.get('featured_media'), v.Featured_Media__c, 'featured_media');
        assertJson(sent.get('image'), v.Image__c, 'image');
        assertJson(sent.get('metafields'), v.Metafields__c, 'metafields');
        assertJson(sent.get('options'), v.Options__c, 'options');
        assertJson(sent.get('options_with_values'), v.Options_With_Values__c, 'options_with_values');
        assertJson(sent.get('product'), v.Product__c, 'product');
        assertJson(sent.get('quantity_price_breaks'), v.Quantity_Price_Breaks__c, 'quantity_price_breaks');
        assertJson(sent.get('quantity_rule'), v.Quantity_Rule__c, 'quantity_rule');
        assertJson(sent.get('selected_selling_plan_allocation'), v.Selected_Selling_Plan_Allocation__c,
            'selected_selling_plan_allocation');
        assertJson(sent.get('selling_plan_allocations'), v.Selling_Plan_Allocations__c, 'selling_plan_allocations');
        assertJson(sent.get('store_availabilities'), v.Store_Availabilities__c, 'store_availabilities');
        assertJson(sent.get('unit_price_measurement'), v.Unit_Price_Measurement__c, 'unit_price_measurement');
        Assert.isNull(v.Additional_Properties__c, 'Nothing undocumented was sent');
    }

    @IsTest
    static void everyDocumentedPropertyHasAField() {
        Set<String> keys = new Set<String>();
        Set<Schema.SObjectField> fields = new Set<Schema.SObjectField>();
        for (ShreeHariProductRestResource.Mapping m : ShreeHariProductRestResource.MAPPINGS) {
            keys.add(m.key);
            fields.add(m.field);
        }
        Assert.areEqual(43, keys.size(), 'The 43 documented product properties other than variants should be mapped');
        Assert.areEqual(43, fields.size(), 'Each property should have its own field');
        Assert.isFalse(keys.contains(ShreeHariProductRestResource.VARIANTS), 'variants are stored as their own records');
        keys.add(ShreeHariProductRestResource.VARIANTS);
        Assert.areEqual(keys, fullProduct().keySet(), 'The test payload should carry all 44 product properties');
    }

    @IsTest
    static void everyDocumentedVariantPropertyHasAFieldNamedAfterIt() {
        Set<String> keys = new Set<String>();
        Set<Schema.SObjectField> fields = new Set<Schema.SObjectField>();
        for (ShreeHariProductRestResource.Mapping m : ShreeHariProductRestResource.VARIANT_MAPPINGS) {
            keys.add(m.key);
            fields.add(m.field);
            String expected = '';
            for (String part : m.key.removeEnd('?').split('_')) {
                expected += (expected == '' ? '' : '_') + (part == 'sku' ? 'SKU' : part.capitalize());
            }
            Assert.areEqual(expected + '__c', m.field.getDescribe().getName(), 'Field named after variant.' + m.key);
        }
        Assert.areEqual(39, keys.size(), 'All 39 documented variant properties (3 deprecated) should be mapped');
        Assert.areEqual(39, fields.size(), 'Each variant property should have its own field');
        Assert.areEqual(keys, fullVariant(1L, 'X').keySet(), 'The test variant should carry every mapped property');
    }

    @IsTest
    static void storesTheMostVariantsShopifySends() {
        List<Object> variants = new List<Object>();
        for (Integer i = 0; i < 250; i++) {
            variants.add(fullVariant(40000000000000L + i, 'SKU-' + i));
        }

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(productWithVariants(variants)));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Assert.areEqual(250, response.get('variantCount'), 'All 250 variants reported');
        Assert.areEqual(250, variantsOf(onlyRecord().Id).size(), 'All 250 variants stored');
    }

    @IsTest
    static void storesAProductWithNoVariants() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(productWithVariants(new List<Object>())));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Assert.areEqual(0, response.get('variantCount'), 'No variants reported');
        Assert.areEqual('Product received and stored as ' + onlyRecord().Name + ' with 0 variants.', response.get('message'), 'message');
        Assert.areEqual(0, [SELECT COUNT() FROM Staging_Product_Variant__c WITH SYSTEM_MODE], 'No variants stored');
    }

    @IsTest
    static void keepsUndocumentedVariantKeysOnTheVariant() {
        Map<String, Object> variant = fullVariant(39897499729985L, 'RING-16-22K');
        variant.put('inventory_item_id', 4411L);
        variant.put('position', 1);
        variant.put('available?', true);

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(productWithVariants(new List<Object>{ variant })));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Staging_Product__c r = onlyRecord();
        Assert.isNull(r.Additional_Properties__c, 'variants is documented on the product');
        Map<String, Object> extra = (Map<String, Object>) JSON.deserializeUntyped(variantsOf(r.Id)[0].Additional_Properties__c);
        Assert.areEqual(3, extra.size(), 'Only the undocumented variant keys should be kept there: ' + extra);
        Assert.areEqual(4411, extra.get('inventory_item_id'), 'inventory_item_id kept');
        Assert.areEqual(1, extra.get('position'), 'position kept');
        Assert.areEqual(true, extra.get('available?'), 'A ? added to a name without one is not documented');
    }

    @IsTest
    static void acceptsVariantNamesWithoutQuestionMark() {
        Map<String, Object> variant = fullVariant(39897499729985L, 'RING-16-22K');
        variant.remove('quantity_price_breaks_configured?');
        variant.put('quantity_price_breaks_configured', false);

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(productWithVariants(new List<Object>{ variant })));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Staging_Product_Variant__c v = variantsOf(onlyRecord().Id)[0];
        Assert.isFalse(v.Quantity_Price_Breaks_Configured__c, 'quantity_price_breaks_configured without ? is read');
        Assert.isNull(v.Additional_Properties__c, 'Alternate name is not undocumented');
    }

    @IsTest
    static void keepsUndocumentedKeysInAdditionalProperties() {
        Map<String, Object> product = withChange('body_html', '<p>Admin API description</p>');
        product.put('status', 'active');

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(product));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Map<String, Object> extra = (Map<String, Object>) JSON.deserializeUntyped(onlyRecord().Additional_Properties__c);
        Assert.areEqual(2, extra.size(), 'Only the undocumented keys should be kept there');
        Assert.areEqual('<p>Admin API description</p>', extra.get('body_html'), 'body_html kept');
        Assert.areEqual('active', extra.get('status'), 'status kept');
    }

    @IsTest
    static void storesOnlyWhatIsSentAndIgnoresNulls() {
        Test.startTest();
        Map<String, Object> response = post('{"id": "123", "title": null, "variants": null, "price": null}');
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Only id is required: ' + response);
        Staging_Product__c r = onlyRecord();
        Assert.areEqual('123', r.Shopify_Id__c, 'id');
        Assert.isNull(r.Title__c, 'null title stays blank');
        Assert.areEqual(0, [SELECT COUNT() FROM Staging_Product_Variant__c WITH SYSTEM_MODE], 'null variants stores no variant');
        Assert.isNull(r.Price__c, 'null price stays blank');
        Assert.isNull(r.Additional_Properties__c, 'null documented keys are not undocumented');
    }

    @IsTest
    static void eachCallCreatesANewRecord() {
        String body = JSON.serialize(fullProduct());

        Test.startTest();
        Map<String, Object> first = post(body);
        Map<String, Object> second = post(body);
        Test.stopTest();

        Assert.areEqual(201, first.get('__status'), 'First call created');
        Assert.areEqual(201, second.get('__status'), 'Second call created');
        Assert.areNotEqual(first.get('stagingProductId'), second.get('stagingProductId'), 'Two records');
        Assert.areNotEqual(first.get('stagingProductNumber'), second.get('stagingProductNumber'), 'Two SP numbers');
        Assert.areEqual(2, [SELECT COUNT() FROM Staging_Product__c WHERE Shopify_Id__c = '6786188247105' WITH SYSTEM_MODE],
            'Both calls should be kept as history');
    }

    @IsTest
    static void acceptsTheProductWrapperAndNamesWithoutQuestionMark() {
        Map<String, Object> product = fullProduct();
        product.remove('gift_card?');
        product.remove('quantity_price_breaks_configured?');
        product.put('gift_card', true);
        product.put('quantity_price_breaks_configured', true);

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(new Map<String, Object>{ 'product' => product }));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Wrapped product accepted: ' + response);
        Staging_Product__c r = onlyRecord();
        Assert.areEqual('6786188247105', r.Shopify_Id__c, 'Unwrapped id');
        Assert.isTrue(r.Gift_Card__c, 'gift_card without ? is read');
        Assert.isTrue(r.Quantity_Price_Breaks_Configured__c, 'quantity_price_breaks_configured without ? is read');
        Assert.isNull(r.Additional_Properties__c, 'Alternate names are not undocumented');
    }

    @IsTest
    static void acceptsNumbersAndBooleansSentAsTextAndKeepsPlainStringsAsSent() {
        Map<String, Object> product = withChange('price', '45000.50');
        product.put('available', 'FALSE');
        product.put('tags', '22K, gold, ring');
        product.put('id', 'gid://shopify/Product/6786188247105');

        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(product));
        Test.stopTest();

        Assert.areEqual(201, response.get('__status'), 'Should be created: ' + response);
        Staging_Product__c r = onlyRecord();
        assertNumber(45000.50, r.Price__c, 'Numeric text is stored as a number');
        Assert.isFalse(r.Available__c, 'Boolean text is stored as a checkbox');
        Assert.areEqual('22K, gold, ring', r.Tags__c, 'A plain string is kept exactly as sent');
        Assert.areEqual('gid://shopify/Product/6786188247105', r.Shopify_Id__c, 'Text ids are kept as sent');
    }

    @IsTest
    static void convertsEveryTimestampFormToGmt() {
        Assert.areEqual(Datetime.newInstanceGmt(2021, 4, 30, 15, 22, 36),
            ShreeHariProductRestResource.toDatetime('k', '2021-04-30T11:22:36-04:00'), 'ISO with negative offset');
        Assert.areEqual(Datetime.newInstanceGmt(2021, 4, 30, 5, 52, 36),
            ShreeHariProductRestResource.toDatetime('k', '2021-04-30 11:22:36 +0530'), 'Liquid form with +0530');
        Assert.areEqual(Datetime.newInstanceGmt(2021, 4, 30, 11, 22, 36),
            ShreeHariProductRestResource.toDatetime('k', '2021-04-30T11:22:36.123Z'), 'UTC with milliseconds');
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
    static void rejectsMoreThanOneProductPerCall() {
        Test.startTest();
        Map<String, Object> response = post('[{"id": "1"}, {"id": "2"}]');
        Test.stopTest();
        assertRejected(response, 'INVALID_JSON', null);
    }

    @IsTest
    static void rejectsAMissingId() {
        Map<String, Object> product = fullProduct();
        product.remove('id');
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(product));
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
        Map<String, Object> response = post(JSON.serialize(withChange('title', new Map<String, Object>{ 'en' => 'Ring' })));
        Test.stopTest();
        assertRejected(response, 'INVALID_TYPE', 'title');
    }

    @IsTest
    static void rejectsANonNumericPrice() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('price_max', 'ten')));
        Test.stopTest();
        assertRejected(response, 'INVALID_NUMBER', 'price_max');
    }

    @IsTest
    static void rejectsANumberTooLargeForItsField() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('price', 123456789012345L)));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', 'price');
    }

    @IsTest
    static void rejectsANonBooleanFlag() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('available', 'yes')));
        Test.stopTest();
        assertRejected(response, 'INVALID_BOOLEAN', 'available');
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
        Map<String, Object> response = post(JSON.serialize(withChange('published_at', '2026-02-30T10:00:00Z')));
        Test.stopTest();
        assertRejected(response, 'INVALID_DATE', 'published_at');
    }

    @IsTest
    static void rejectsAnArrayLongerThanItsField() {
        List<Object> images = new List<Object>();
        String filler = 'x'.repeat(1000);
        for (Integer i = 0; i < 140; i++) {
            images.add(new Map<String, Object>{ 'id' => i, 'alt' => filler });
        }
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('images', images)));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', 'images');
    }

    // ---- Variants: the property is named with its position in the array

    @IsTest
    static void rejectsVariantsThatAreNotAnArray() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('variants', new Map<String, Object>{ 'id' => 1 })));
        Test.stopTest();
        assertRejected(response, 'INVALID_TYPE', 'variants');
    }

    @IsTest
    static void rejectsAVariantThatIsNotAnObject() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(productWithVariants(
            new List<Object>{ fullVariant(1L, 'A'), 'RING-18-22K' }
        )));
        Test.stopTest();
        assertRejected(response, 'INVALID_TYPE', 'variants[1]');
    }

    @IsTest
    static void rejectsAVariantWithoutId() {
        Map<String, Object> second = fullVariant(2L, 'B');
        second.remove('id');
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(productWithVariants(
            new List<Object>{ fullVariant(1L, 'A'), second }
        )));
        Test.stopTest();
        assertRejected(response, 'MISSING_REQUIRED_FIELD', 'variants[1].id');
    }

    @IsTest
    static void rejectsAnInventoryPolicyOutsideItsValues() {
        Map<String, Object> variant = fullVariant(1L, 'A');
        variant.put('inventory_policy', 'Deny');
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(productWithVariants(new List<Object>{ variant })));
        Test.stopTest();
        assertRejected(response, 'INVALID_VALUE', 'variants[0].inventory_policy');
        Assert.areEqual('variants[0].inventory_policy must be one of: continue, deny; but "Deny" was sent.',
            response.get('message'), 'The allowed values are listed');
    }

    @IsTest
    static void rejectsAVariantValueOfTheWrongType() {
        Map<String, Object> variant = fullVariant(1L, 'A');
        variant.put('price', 'forty five thousand');
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(productWithVariants(new List<Object>{ fullVariant(2L, 'B'), variant })));
        Test.stopTest();
        assertRejected(response, 'INVALID_NUMBER', 'variants[1].price');
    }

    @IsTest
    static void rejectsAVariantTimestampWithoutTimeZone() {
        Map<String, Object> variant = fullVariant(1L, 'A');
        variant.put('next_incoming_date', '2026-12-01');
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(productWithVariants(new List<Object>{ variant })));
        Test.stopTest();
        assertRejected(response, 'INVALID_DATE', 'variants[0].next_incoming_date');
    }

    @IsTest
    static void rejectsAVariantTextLongerThanItsField() {
        Map<String, Object> variant = fullVariant(1L, 'A');
        variant.put('sku', 'S'.repeat(256));
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(productWithVariants(new List<Object>{ variant })));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', 'variants[0].sku');
    }

    @IsTest
    static void rejectsTextLongerThanItsField() {
        Test.startTest();
        Map<String, Object> response = post(JSON.serialize(withChange('title', 'a'.repeat(256))));
        Test.stopTest();
        assertRejected(response, 'VALUE_TOO_LONG', 'title');
    }
}
