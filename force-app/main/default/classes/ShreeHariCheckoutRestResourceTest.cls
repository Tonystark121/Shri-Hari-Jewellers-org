/**
 * Tests for the abandoned checkout endpoint. Each test posts a
 * checkout.abandoned event the way the caller does and checks the response
 * and the records it leaves behind.
 */
@IsTest
private class ShreeHariCheckoutRestResourceTest {

    private static final String RESOURCE_URI = '/services/apexrest/shreehari/v1/abandoned-checkouts';

    // =====================================================================
    // Helpers
    // =====================================================================

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

        Test.startTest();
        ShreeHariCheckoutRestResource.receiveCheckout();
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        parsed.put('__status', RestContext.response.statusCode);
        return parsed;
    }

    /** The event as documented, cut down to the parts that are read plus a few that are ignored. */
    private static Map<String, Object> event() {
        return new Map<String, Object>{
            'event' => new Map<String, Object>{
                'id' => 'cbv3x2k1abc',
                'type' => 'checkout.abandoned',
                'timestamp' => 1756464700000L,
                'platform' => 'shopify'
            },
            'data' => new Map<String, Object>{
                'consent' => new Map<String, Object>{ 'whatsapp' => true, 'email' => true, 'sms' => false },
                'user' => new Map<String, Object>{
                    'user_id' => 'cust_abc123',
                    'contact' => '+919876543210',
                    'email' => 'priya@example.com',
                    'first_name' => 'Priya',
                    'last_name' => 'Sharma',
                    'login_method' => 'otp',
                    'address' => new Map<String, Object>{
                        'line1' => '221B Baker Street',
                        'line2' => 'Near City Mall',
                        'city' => 'Mumbai',
                        'state' => 'Maharashtra',
                        'country' => 'India',
                        'pincode' => '400067'
                    }
                },
                'session' => new Map<String, Object>{
                    'utm_source' => 'facebook',
                    'products_viewed' => new List<Object>{
                        new Map<String, Object>{
                            'product_id' => '10252876775744',
                            'title' => 'Paithani Silk Saree',
                            'price' => 799900
                        }
                    }
                },
                'checkout' => new Map<String, Object>{
                    'checkout_id' => 'chk_2xY8KpL3nW',
                    'line_items' => new List<Object>{
                        new Map<String, Object>{ 'name' => 'Saanjh Paithani Silk Peacock Handloom Saree Deep Teal' }
                    }
                }
            }
        };
    }

    private static Map<String, Object> part(Map<String, Object> payload, String name) {
        return (Map<String, Object>) ((Map<String, Object>) payload.get('data')).get(name);
    }

    private static Integer statusOf(Map<String, Object> response) {
        return (Integer) response.get('__status');
    }

    private static void assertError(Map<String, Object> response, Integer status, String errorCode, String field) {
        Assert.areEqual(status, statusOf(response), 'Status: ' + response);
        Assert.areEqual(false, response.get('success'), 'success should be false');
        Assert.areEqual(errorCode, response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual(field, response.get('field'), 'The offending field should be reported');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WITH SYSTEM_MODE], 'No Lead');
        Assert.areEqual(0, [SELECT COUNT() FROM Case WITH SYSTEM_MODE], 'No Case');
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Integration_Log__c WHERE API_Name__c = 'Abandoned Checkout' AND Error_Code__c = :errorCode WITH SYSTEM_MODE],
            'The failed call is logged'
        );
    }

    // =====================================================================
    // Nobody matches: a Lead
    // =====================================================================

    @IsTest
    static void createsALeadFromTheUser() {
        Map<String, Object> response = post(JSON.serialize(event()));

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Assert.areEqual(true, response.get('success'), 'success should be true');
        Assert.areEqual('CREATED', response.get('action'), 'A Lead');
        Assert.areEqual('New', response.get('status'), 'Status New');
        Assert.isNull(response.get('caseId'), 'No enquiry');

        Lead saved = [
            SELECT Id, FirstName, LastName, Phone, MobilePhone, Email, Street, City, State, Country, PostalCode,
                   LeadSource, Status, Description, User_Id__c, Business_Type__c, Company,
                   WA_Opt_In__c, Email_Opt_In__c, SMS_Opt_In__c
            FROM Lead
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(saved.Id, response.get('leadId'), 'leadId returned');
        Assert.areEqual(saved.Company, response.get('company'), 'Company returned');
        Assert.areEqual('Priya', saved.FirstName);
        Assert.areEqual('Sharma', saved.LastName);
        Assert.areEqual('+919876543210', saved.Phone, 'Phone as sent');
        Assert.isNull(saved.MobilePhone, 'The one number is saved once, in Phone');
        Assert.areEqual('priya@example.com', saved.Email);
        Assert.isTrue(saved.Street.startsWith('221B Baker Street'), 'line1 first: ' + saved.Street);
        Assert.isTrue(saved.Street.endsWith('Near City Mall'), 'line2 after it: ' + saved.Street);
        Assert.areEqual('Mumbai', saved.City);
        Assert.areEqual('Maharashtra', saved.State);
        Assert.areEqual('India', saved.Country);
        Assert.areEqual('400067', saved.PostalCode);
        Assert.areEqual('Shopify', saved.LeadSource);
        Assert.areEqual('New', saved.Status);
        Assert.areEqual('Paithani Silk Saree', saved.Description, 'The viewed product title, not the line item');
        Assert.areEqual('cust_abc123', saved.User_Id__c);
        Assert.areEqual('B2C', saved.Business_Type__c, 'No company: B2C');
        Assert.isTrue(saved.Company.startsWith('Priya Sharma B2C'), 'System company: ' + saved.Company);
        Assert.isTrue(saved.WA_Opt_In__c, 'WhatsApp consent');
        Assert.isTrue(saved.Email_Opt_In__c, 'Email consent');
        Assert.isFalse(saved.SMS_Opt_In__c, 'No SMS consent');
        Assert.areEqual(0, [SELECT COUNT() FROM Integration_Log__c WITH SYSTEM_MODE], 'Nothing logged for a success');
    }

    @IsTest
    static void joinsEveryViewedTitleOnce() {
        Map<String, Object> payload = event();
        part(payload, 'session').put('products_viewed', new List<Object>{
            new Map<String, Object>{ 'title' => 'Paithani Silk Saree' },
            new Map<String, Object>{ 'title' => ' Gold Bangle ' },
            new Map<String, Object>{ 'product_id' => '1' },
            new Map<String, Object>{ 'title' => 'Paithani Silk Saree' },
            'not a product'
        });

        Map<String, Object> response = post(JSON.serialize(payload));

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Assert.areEqual('Paithani Silk Saree, Gold Bangle', [SELECT Description FROM Lead WITH SYSTEM_MODE].Description);
    }

    @IsTest
    static void usesTheDefaultDescriptionWithoutViewedProducts() {
        Map<String, Object> payload = event();
        part(payload, 'session').put('products_viewed', new List<Object>());

        Map<String, Object> response = post(JSON.serialize(payload));

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Assert.areEqual('Abandon Checkout Lead', [SELECT Description FROM Lead WITH SYSTEM_MODE].Description);
    }

    @IsTest
    static void usesTheDefaultDescriptionWithoutASession() {
        Map<String, Object> payload = event();
        ((Map<String, Object>) payload.get('data')).remove('session');
        ((Map<String, Object>) payload.get('data')).remove('consent');
        part(payload, 'user').remove('address');

        Map<String, Object> response = post(JSON.serialize(payload));

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Lead saved = [SELECT Description, MobilePhone, WA_Opt_In__c, Email_Opt_In__c, SMS_Opt_In__c, City FROM Lead WITH SYSTEM_MODE];
        Assert.areEqual('Abandon Checkout Lead', saved.Description);
        Assert.isNull(saved.MobilePhone, 'No WhatsApp Number');
        Assert.isFalse(saved.WA_Opt_In__c || saved.Email_Opt_In__c || saved.SMS_Opt_In__c, 'No consent sent');
        Assert.isNull(saved.City, 'No address sent');
    }

    @IsTest
    static void leavesWhatsAppNumberBlankWithoutWhatsAppConsent() {
        Map<String, Object> payload = event();
        part(payload, 'consent').put('whatsapp', false);

        Map<String, Object> response = post(JSON.serialize(payload));

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Lead saved = [SELECT Phone, MobilePhone, WA_Opt_In__c FROM Lead WITH SYSTEM_MODE];
        Assert.areEqual('+919876543210', saved.Phone);
        Assert.isNull(saved.MobilePhone, 'No WhatsApp Number');
        Assert.isFalse(saved.WA_Opt_In__c, 'No WhatsApp consent');
    }

    @IsTest
    static void usesTheFirstNameAsLastNameWhenItIsTheOnlyName() {
        Map<String, Object> payload = event();
        part(payload, 'user').put('last_name', '  ');

        Map<String, Object> response = post(JSON.serialize(payload));

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Lead saved = [SELECT FirstName, LastName FROM Lead WITH SYSTEM_MODE];
        Assert.areEqual('Priya', saved.LastName);
        Assert.isNull(saved.FirstName);
    }

    @IsTest
    static void usesThePhoneAsLastNameWhenNoNameIsSent() {
        Map<String, Object> payload = event();
        part(payload, 'user').remove('first_name');
        part(payload, 'user').put('last_name', null);

        Map<String, Object> response = post(JSON.serialize(payload));

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Lead saved = [SELECT FirstName, LastName, Phone FROM Lead WITH SYSTEM_MODE];
        Assert.areEqual('+919876543210', saved.LastName, 'The phone as sent');
        Assert.isNull(saved.FirstName);
        Assert.areEqual('+919876543210', saved.Phone);
    }

    @IsTest
    static void acceptsTheSmallestDocumentedEvent() {
        // Only what the guide marks "always present"; email empty as on a phone-only checkout.
        String body = '{"event":{"id":"e1","type":"checkout.abandoned","timestamp":1756464700000,'
            + '"shop_id":"store-8821.myshopify.com","version":"2.0","platform":"shopify"},'
            + '"data":{"consent":{"whatsapp":false,"email":false,"sms":true},'
            + '"user":{"contact":"+919876543210","email":""},'
            + '"session":{"rzp_unified_session_id":"cbe817b5","device_type":"mobile"},'
            + '"enrichment":{"customer_signals":{}},'
            + '"checkout":{"order_id":"order_1","line_items":[],"promotions":[]}}}';

        Map<String, Object> response = post(body);

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Lead saved = [
            SELECT FirstName, LastName, Phone, MobilePhone, Email, Street, City, State, Country, PostalCode,
                   Description, User_Id__c, LeadSource, WA_Opt_In__c, Email_Opt_In__c, SMS_Opt_In__c
            FROM Lead
            WITH SYSTEM_MODE
        ];
        Assert.areEqual('+919876543210', saved.LastName, 'No name: the phone');
        Assert.isNull(saved.FirstName);
        Assert.areEqual('+919876543210', saved.Phone);
        Assert.isNull(saved.MobilePhone, 'No WhatsApp consent');
        Assert.isNull(saved.Email, 'Empty email is blank');
        Assert.isNull(saved.User_Id__c);
        Assert.isNull(saved.Street);
        Assert.isNull(saved.City);
        Assert.isNull(saved.State);
        Assert.isNull(saved.Country);
        Assert.isNull(saved.PostalCode);
        Assert.areEqual('Abandon Checkout Lead', saved.Description);
        Assert.areEqual('Shopify', saved.LeadSource);
        Assert.isFalse(saved.WA_Opt_In__c);
        Assert.isFalse(saved.Email_Opt_In__c);
        Assert.isTrue(saved.SMS_Opt_In__c);
    }

    @IsTest
    static void refusesTheLegacyFormat() {
        String body = '{"event":"abandoned_checkout","phone":"+919876543210","email":"priya@example.com"}';
        assertError(post(body), 400, 'UNSUPPORTED_EVENT', 'event.type');
    }

    @IsTest
    static void acceptsANumericContact() {
        Map<String, Object> payload = event();
        part(payload, 'user').put('contact', 9876543210L);

        Map<String, Object> response = post(JSON.serialize(payload));

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Assert.areEqual('9876543210', [SELECT Phone FROM Lead WITH SYSTEM_MODE].Phone);
    }

    // =====================================================================
    // cart.abandoned: handled exactly like checkout.abandoned
    // =====================================================================

    /** The cart.abandoned event as documented. */
    private static String cartEvent() {
        return '{"event":{"id":"cbv3x2k1abc","type":"cart.abandoned","timestamp":1756464700000,'
            + '"shop_id":"store-8821.myshopify.com","version":"2.0","platform":"shopify"},'
            + '"data":{"consent":{"whatsapp":true,"email":true,"sms":false},"notes":{"client_id":"..."},'
            + '"user":{"contact":"+918888888888","email":"user@example.com"},'
            + '"session":{"rzp_unified_session_id":"abc123-...","device_type":"mobile",'
            + '"pages_visited":[{"url":"https://store.com/collections/sarees","duration_seconds":45}],'
            + '"products_viewed":[{"product_id":"7652090314919","title":"Banarasi Saree","price":700000}]},'
            + '"geo":{"city":"Delhi","state":"Delhi","country_code":"IN"},'
            + '"enrichment":{"customer_signals":{}},'
            + '"cart":{"cart_token":"c1-68be3b...","cart_url":"https://store.myshopify.com/cart",'
            + '"magic_recovery_url":"https://checkout.razorpay.com/magic/recover/cart/c1-...","currency":"INR",'
            + '"line_items_total":700000,"line_items":[{"product_id":"7652090314919","variant_id":"43306810998951",'
            + '"name":"Sujatra Banarasi Saree","variant_title":"S / Blue","sku":"SJT-BNRS-001-S-BLU","quantity":1,'
            + '"price":700000,"taxable":true,"tax_amount":0,"image_url":"https://cdn.shopify.com/.../saree.jpg"}],'
            + '"last_cart_activity":"item_added","last_cart_activity_timestamp":1756463500,'
            + '"available_coupons":[{"coupon_code":"CARTBACK10","description":"10% off"}],'
            + '"customer_history":{"visit_frequency":"medium","sessions_last_30_days":2,'
            + '"prior_orders_count":0,"has_prior_orders":false}}}}';
    }

    @IsTest
    static void createsALeadFromAnAbandonedCart() {
        Map<String, Object> response = post(cartEvent());

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Assert.areEqual('CREATED', response.get('action'), 'A Lead');

        Lead saved = [
            SELECT Id, FirstName, LastName, Phone, MobilePhone, Email, Street, City, State, Country, PostalCode,
                   LeadSource, Status, Description, User_Id__c, Business_Type__c,
                   WA_Opt_In__c, Email_Opt_In__c, SMS_Opt_In__c
            FROM Lead
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(saved.Id, response.get('leadId'));
        Assert.areEqual('+918888888888', saved.LastName, 'No name on a cart event: the phone');
        Assert.isNull(saved.FirstName);
        Assert.areEqual('+918888888888', saved.Phone, 'Phone as sent');
        Assert.isNull(saved.MobilePhone, 'The one number is saved once, in Phone');
        Assert.areEqual('user@example.com', saved.Email);
        Assert.areEqual('Banarasi Saree', saved.Description, 'The viewed product title');
        Assert.areEqual('Shopify', saved.LeadSource);
        Assert.areEqual('New', saved.Status);
        Assert.areEqual('B2C', saved.Business_Type__c);
        Assert.isNull(saved.User_Id__c, 'No user_id on a cart event');
        Assert.isNull(saved.Street, 'No address on a cart event');
        Assert.isNull(saved.City, 'data.geo is not read, as on checkout.abandoned');
        Assert.isNull(saved.State);
        Assert.isNull(saved.Country);
        Assert.isNull(saved.PostalCode);
        Assert.isTrue(saved.WA_Opt_In__c);
        Assert.isTrue(saved.Email_Opt_In__c);
        Assert.isFalse(saved.SMS_Opt_In__c);
    }

    @IsTest
    static void abandonedCartRaisesAnEnquiryForAnAccountWithItsContact() {
        Account household = new Account(Name = 'Sharma Family', Phone = '8888888888');
        insert household;
        Contact person = new Contact(AccountId = household.Id, LastName = 'Sharma', Email = 'user@example.com');
        insert person;

        Map<String, Object> response = post(cartEvent());

        Assert.areEqual(201, statusOf(response), 'Accepted: ' + response);
        Assert.areEqual('ENQUIRY_CREATED', response.get('action'));
        Assert.areEqual(household.Id, response.get('accountId'));
        Assert.areEqual(person.Id, response.get('contactId'));
        Assert.areEqual(false, response.get('contactCreated'));
        Assert.areEqual(false, response.get('accountCreated'));
        Assert.areEqual(1, [SELECT COUNT() FROM Contact WITH SYSTEM_MODE], 'Phone on the Account, email on its Contact: no second Contact');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WITH SYSTEM_MODE], 'No Lead');
        Assert.areEqual('Banarasi Saree', [SELECT Description FROM Case WITH SYSTEM_MODE].Description);
    }

    @IsTest
    static void abandonedCartCreatesTheContactWhenOnlyAnAccountMatches() {
        Account household = new Account(Name = 'Sharma Family', Phone = '8888888888');
        insert household;

        Map<String, Object> response = post(cartEvent());

        Assert.areEqual(201, statusOf(response), 'Accepted: ' + response);
        Assert.areEqual('ENQUIRY_CREATED', response.get('action'));
        Assert.areEqual(true, response.get('contactCreated'));
        Assert.areEqual(false, response.get('accountCreated'));
        Contact created = [SELECT Id, AccountId, LastName, Phone, Email FROM Contact WITH SYSTEM_MODE];
        Assert.areEqual(household.Id, created.AccountId);
        Assert.areEqual('+918888888888', created.LastName, 'No name: the phone');
        Assert.areEqual('user@example.com', created.Email);
        Assert.areEqual(created.Id, [SELECT ContactId FROM Case WITH SYSTEM_MODE].ContactId);
    }

    @IsTest
    static void abandonedCartCreatesTheAccountWhenOnlyAContactMatches() {
        Contact person = new Contact(FirstName = 'Priya', LastName = 'Sharma', Phone = '8888888888');
        insert person;

        Map<String, Object> response = post(cartEvent());

        Assert.areEqual(201, statusOf(response), 'Accepted: ' + response);
        Assert.areEqual('ENQUIRY_CREATED', response.get('action'));
        Assert.areEqual(true, response.get('accountCreated'));
        Assert.areEqual(false, response.get('contactCreated'));
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WITH SYSTEM_MODE], 'No Lead');
        Account created = [SELECT Id FROM Account WITH SYSTEM_MODE];
        Assert.areEqual(created.Id, [SELECT AccountId FROM Contact WITH SYSTEM_MODE].AccountId, 'The Contact moved under it');
        Case enquiry = [SELECT Id, AccountId, ContactId FROM Case WITH SYSTEM_MODE];
        Assert.areEqual(enquiry.Id, response.get('caseId'), 'The Case Id is returned');
        Assert.areEqual(created.Id, enquiry.AccountId);
        Assert.areEqual(person.Id, enquiry.ContactId);
    }

    @IsTest
    static void abandonedCartAnswersDuplicateWhenAnOpenLeadExists() {
        Lead openLead = new Lead(LastName = 'Sharma', Phone = '8888888888', Description = 'Gold ring');
        insert openLead;

        Map<String, Object> response = post(cartEvent());

        Assert.areEqual(200, statusOf(response), 'Answered: ' + response);
        Assert.areEqual('DUPLICATE_LEAD', response.get('action'));
        Assert.areEqual(openLead.Id, response.get('leadId'));
        Assert.areEqual('Gold ring', [SELECT Description FROM Lead WITH SYSTEM_MODE].Description, 'Not updated');
    }

    @IsTest
    static void refusesTheSessionAbandonedEvent() {
        assertError(post(cartEvent().replace('cart.abandoned', 'cart.session_abandoned')), 400, 'UNSUPPORTED_EVENT', 'event.type');
    }

    // =====================================================================
    // Existing customer: an enquiry Case
    // =====================================================================

    @IsTest
    static void raisesAnEnquiryForAnAccountWithItsContact() {
        Account household = new Account(Name = 'Sharma Family', Phone = '9876543210');
        insert household;
        Contact person = new Contact(AccountId = household.Id, FirstName = 'Priya', LastName = 'Sharma', Phone = '98765 43210');
        insert person;

        Map<String, Object> response = post(JSON.serialize(event()));

        Assert.areEqual(201, statusOf(response), 'Accepted: ' + response);
        Assert.areEqual('ENQUIRY_CREATED', response.get('action'), 'An enquiry, not a Lead');
        Assert.areEqual(household.Id, response.get('accountId'));
        Assert.areEqual(person.Id, response.get('contactId'));
        Assert.areEqual(false, response.get('contactCreated'));
        Assert.areEqual(false, response.get('accountCreated'));
        Assert.isNotNull(response.get('caseNumber'), 'caseNumber returned');
        Assert.isNull(response.get('leadId'), 'No Lead');

        Assert.areEqual(0, [SELECT COUNT() FROM Lead WITH SYSTEM_MODE], 'No Lead');
        Assert.areEqual(1, [SELECT COUNT() FROM Account WITH SYSTEM_MODE], 'No new Account');
        Assert.areEqual(1, [SELECT COUNT() FROM Contact WITH SYSTEM_MODE], 'No new Contact');

        Case enquiry = [
            SELECT Id, AccountId, ContactId, Subject, Description, Origin, Priority, Type, SuppliedPhone, SuppliedEmail,
                   Lead_Source__c
            FROM Case
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(enquiry.Id, response.get('caseId'));
        Assert.areEqual(household.Id, enquiry.AccountId);
        Assert.areEqual(person.Id, enquiry.ContactId);
        Assert.areEqual('Enquiry from Priya Sharma', enquiry.Subject);
        Assert.areEqual('Paithani Silk Saree', enquiry.Description, 'The product description');
        Assert.areEqual('Phone', enquiry.Origin, 'Same as Upload Leads');
        Assert.areEqual('Medium', enquiry.Priority, 'Same as Upload Leads');
        Assert.areEqual('Service Enquiry', enquiry.Type, 'Same as Upload Leads');
        Assert.areEqual('+919876543210', enquiry.SuppliedPhone);
        Assert.areEqual('priya@example.com', enquiry.SuppliedEmail);
        Assert.areEqual('Shopify', enquiry.Lead_Source__c);
    }

    @IsTest
    static void createsTheContactWhenOnlyAnAccountMatches() {
        Account household = new Account(Name = 'Sharma Family', Email__c = 'priya@example.com');
        insert household;
        Contact other = new Contact(AccountId = household.Id, LastName = 'Someone Else', Phone = '9000000001');
        insert other;

        Map<String, Object> response = post(JSON.serialize(event()));

        Assert.areEqual(201, statusOf(response), 'Accepted: ' + response);
        Assert.areEqual('ENQUIRY_CREATED', response.get('action'), 'An enquiry, not a Lead');
        Assert.areEqual(household.Id, response.get('accountId'));
        Assert.areEqual(true, response.get('contactCreated'));
        Assert.areEqual(false, response.get('accountCreated'));
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WITH SYSTEM_MODE], 'No Lead');
        Assert.areEqual(1, [SELECT COUNT() FROM Account WITH SYSTEM_MODE], 'No new Account');

        Contact created = [
            SELECT Id, AccountId, FirstName, LastName, Phone, MobilePhone, Email, MailingCity, MailingPostalCode,
                   LeadSource, OwnerId
            FROM Contact
            WHERE Id != :other.Id
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(created.Id, response.get('contactId'));
        Assert.areEqual(household.Id, created.AccountId, 'Under the matched Account');
        Assert.areEqual('Priya', created.FirstName);
        Assert.areEqual('Sharma', created.LastName);
        Assert.areEqual('+919876543210', created.Phone);
        Assert.isNull(created.MobilePhone, 'The one number is saved once, in Phone');
        Assert.areEqual('priya@example.com', created.Email);
        Assert.areEqual('Mumbai', created.MailingCity);
        Assert.areEqual('400067', created.MailingPostalCode);
        Assert.areEqual('Shopify', created.LeadSource);
        Assert.areEqual([SELECT OwnerId FROM Account WITH SYSTEM_MODE].OwnerId, created.OwnerId, 'Owned by the account owner');

        Case enquiry = [SELECT AccountId, ContactId FROM Case WITH SYSTEM_MODE];
        Assert.areEqual(household.Id, enquiry.AccountId);
        Assert.areEqual(created.Id, enquiry.ContactId, 'The enquiry is for the new Contact');
    }

    @IsTest
    static void createsTheAccountWhenOnlyAContactMatches() {
        Contact person = new Contact(FirstName = 'Priya', LastName = 'Sharma', MobilePhone = '9876543210');
        insert person;

        Map<String, Object> response = post(JSON.serialize(event()));

        Assert.areEqual(201, statusOf(response), 'Accepted: ' + response);
        Assert.areEqual('ENQUIRY_CREATED', response.get('action'), 'An enquiry, not a Lead');
        Assert.areEqual(true, response.get('accountCreated'));
        Assert.areEqual(false, response.get('contactCreated'));
        Assert.areEqual(person.Id, response.get('contactId'));
        Assert.isNotNull(response.get('caseNumber'), 'caseNumber returned');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WITH SYSTEM_MODE], 'No Lead');
        Assert.areEqual(1, [SELECT COUNT() FROM Contact WITH SYSTEM_MODE], 'No new Contact');

        Account created = [SELECT Id, Name, Phone, Email__c, Business_Type__c, BillingCity FROM Account WITH SYSTEM_MODE];
        Assert.areEqual(created.Id, response.get('accountId'), 'The new Account is returned');
        Assert.areEqual('Sharma Family (Priya)', created.Name, 'Named as on the New Lead screen');
        Assert.areEqual('B2C', created.Business_Type__c);
        Assert.areEqual('+919876543210', created.Phone);
        Assert.areEqual('priya@example.com', created.Email__c);
        Assert.areEqual('Mumbai', created.BillingCity);
        Assert.areEqual(created.Id, [SELECT AccountId FROM Contact WITH SYSTEM_MODE].AccountId, 'The Contact moved under it');

        Case enquiry = [SELECT Id, AccountId, ContactId, Description FROM Case WITH SYSTEM_MODE];
        Assert.areEqual(enquiry.Id, response.get('caseId'), 'The Case Id is returned');
        Assert.areEqual(created.Id, enquiry.AccountId, 'On the new Account');
        Assert.areEqual(person.Id, enquiry.ContactId, 'And on the Contact');
        Assert.areEqual('Paithani Silk Saree', enquiry.Description);
    }

    @IsTest
    static void usesTheAccountWhenItMatchesBesideAContactWithoutAccount() {
        insert new Contact(LastName = 'Loose Contact', Phone = '9876543210');
        Account household = new Account(Name = 'Sharma Family', Email__c = 'priya@example.com');
        insert household;

        Map<String, Object> response = post(JSON.serialize(event()));

        Assert.areEqual(201, statusOf(response), 'Accepted: ' + response);
        Assert.areEqual('ENQUIRY_CREATED', response.get('action'), 'The Account is a customer');
        Assert.areEqual(household.Id, response.get('accountId'));
        Assert.areEqual(false, response.get('accountCreated'), 'No second Account');
        Assert.areEqual(true, response.get('contactCreated'));
        Assert.areEqual(1, [SELECT COUNT() FROM Account WITH SYSTEM_MODE]);
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WITH SYSTEM_MODE], 'No Lead');
    }

    // =====================================================================
    // Open Lead: answered as a duplicate, nothing changed
    // =====================================================================

    @IsTest
    static void answersDuplicateWhenAnOpenLeadExists() {
        Lead openLead = new Lead(
            LastName = 'Sharma', Phone = '9876543210', Description = 'Gold ring', LeadSource = 'Shopify',
            User_Id__c = 'old_user'
        );
        insert openLead;

        Map<String, Object> response = post(JSON.serialize(event()));

        Assert.areEqual(200, statusOf(response), 'Answered, not retried: ' + response);
        Assert.areEqual(true, response.get('success'));
        Assert.areEqual('DUPLICATE_LEAD', response.get('action'));
        Assert.areEqual(openLead.Id, response.get('leadId'));
        String message = (String) response.get('message');
        Assert.isTrue(message.startsWith('A duplicate Lead already exists'), message);
        Assert.isTrue(message.contains(openLead.Id), 'Names the Lead: ' + message);

        Lead unchanged = [SELECT Description, User_Id__c FROM Lead WITH SYSTEM_MODE];
        Assert.areEqual('Gold ring', unchanged.Description, 'The open Lead is not updated');
        Assert.areEqual('old_user', unchanged.User_Id__c, 'The open Lead is not updated');
        Assert.areEqual(0, [SELECT COUNT() FROM Case WITH SYSTEM_MODE], 'No Case');
        Assert.areEqual(1, [SELECT COUNT() FROM Lead WITH SYSTEM_MODE], 'No second Lead');
        Assert.areEqual(0, [SELECT COUNT() FROM Integration_Log__c WITH SYSTEM_MODE], 'Not an error: nothing logged');
    }

    @IsTest
    static void createsALeadWhenTheOnlyMatchIsAnUnqualifiedLead() {
        insert new Lead(LastName = 'Sharma', Phone = '9876543210', Description = 'Gold ring', Status = 'Unqualified');

        Map<String, Object> response = post(JSON.serialize(event()));

        Assert.areEqual(201, statusOf(response), 'Created: ' + response);
        Assert.areEqual('CREATED', response.get('action'));
        Assert.areEqual(2, [SELECT COUNT() FROM Lead WITH SYSTEM_MODE]);
    }

    // =====================================================================
    // Refused payloads
    // =====================================================================

    @IsTest
    static void refusesAnEmptyBody() {
        assertError(post(null), 400, 'INVALID_JSON', null);
    }

    @IsTest
    static void refusesABodyThatIsNotJson() {
        assertError(post('{"event": '), 400, 'INVALID_JSON', null);
    }

    @IsTest
    static void refusesABodyThatIsNotAnObject() {
        assertError(post('[1, 2]'), 400, 'INVALID_JSON', null);
    }

    @IsTest
    static void refusesAnotherEventType() {
        Map<String, Object> payload = event();
        ((Map<String, Object>) payload.get('event')).put('type', 'order.paid');
        assertError(post(JSON.serialize(payload)), 400, 'UNSUPPORTED_EVENT', 'event.type');
    }

    @IsTest
    static void refusesAMissingEvent() {
        Map<String, Object> payload = event();
        payload.remove('event');
        assertError(post(JSON.serialize(payload)), 400, 'UNSUPPORTED_EVENT', 'event.type');
    }

    @IsTest
    static void refusesAMissingUser() {
        Map<String, Object> payload = event();
        ((Map<String, Object>) payload.get('data')).remove('user');
        assertError(post(JSON.serialize(payload)), 400, 'MISSING_REQUIRED_FIELD', 'data.user');
    }

    @IsTest
    static void refusesAMissingContact() {
        Map<String, Object> payload = event();
        part(payload, 'user').put('contact', '');
        assertError(post(JSON.serialize(payload)), 400, 'MISSING_REQUIRED_FIELD', 'data.user.contact');
    }

    @IsTest
    static void refusesAnInvalidPhone() {
        Map<String, Object> payload = event();
        part(payload, 'user').put('contact', '+4412345');
        assertError(post(JSON.serialize(payload)), 400, 'INVALID_PHONE', 'data.user.contact');
    }

    @IsTest
    static void refusesAnInvalidEmail() {
        Map<String, Object> payload = event();
        part(payload, 'user').put('email', 'priya@example');
        assertError(post(JSON.serialize(payload)), 400, 'INVALID_EMAIL_FORMAT', 'data.user.email');
    }

    @IsTest
    static void refusesAValueThatIsTooLong() {
        Map<String, Object> payload = event();
        part(payload, 'user').put('user_id', 'x'.repeat(256));
        assertError(post(JSON.serialize(payload)), 400, 'VALUE_TOO_LONG', 'data.user.user_id');
    }
}
