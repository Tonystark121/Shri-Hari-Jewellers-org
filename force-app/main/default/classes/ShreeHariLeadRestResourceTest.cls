/**
 * Tests for the website lead capture endpoint.
 *
 * Each test drives the resource the way the website does — a JSON body in, a
 * status code and JSON body out — so the assertions are on the published
 * contract rather than on internal method calls.
 */
@IsTest
private class ShreeHariLeadRestResourceTest {

    private static final String RESOURCE_URI = '/services/apexrest/shreehari/v1/leads';
    private static final String STORE_CODE = 'TST-001';

    @TestSetup
    static void makeData() {
        insert new Store_Location__c(Name = 'Test Store', Store_Code__c = STORE_CODE);
    }

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
        ShreeHariLeadRestResource.createLead();
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        parsed.put('__status', RestContext.response.statusCode);
        return parsed;
    }

    private static Integer statusOf(Map<String, Object> response) {
        return (Integer) response.get('__status');
    }

    // =====================================================================
    // Happy paths
    // =====================================================================

    @IsTest
    static void createsB2CLeadFromWebsiteEnquiry() {
        String body =
            '{' +
            '"salutation":"Ms.",' +
            '"firstName":"Ananya",' +
            '"lastName":"Sharma",' +
            '"phone":"+91-9830012345",' +
            '"email":"ananya.sharma@example.com",' +
            '"leadSource":"Shopify",' +
            '"businessType":"B2C",' +
            '"street":"12/1 Lake View Road",' +
            '"city":"Kolkata",' +
            '"state":"West Bengal",' +
            '"postalCode":"700029",' +
            '"country":"India",' +
            '"storeCode":"' + STORE_CODE + '",' +
            '"rating":"Warm",' +
            '"description":"22K gold necklace set, budget 3,50,000 INR."' +
            '}';

        Map<String, Object> response = post(body);

        Assert.areEqual(201, statusOf(response), 'A valid enquiry should be created');
        Assert.areEqual(true, response.get('success'), 'success should be true');
        Assert.areEqual('CREATED', response.get('action'), 'action should be CREATED');
        Assert.isNotNull(response.get('leadId'), 'leadId should be returned');
        Assert.areEqual('New', response.get('status'), 'Status should default to New');
        Assert.isNotNull(response.get('storeAssociationId'), 'Store should be resolved');

        Lead saved = [
            SELECT FirstName, LastName, Company, Email, Phone, LeadSource, Status,
                   Business_Type__c, Rating, Walk_In_Flag__c, HasOptedOutOfEmail,
                   City, Store_Association__c
            FROM Lead
            LIMIT 1
        ];
        Assert.areEqual('Ananya Sharma', saved.Company, 'Company should default to the customer name for B2C');
        Assert.areEqual('Shopify', saved.LeadSource, 'Lead Source should be mapped');
        Assert.areEqual('B2C', saved.Business_Type__c, 'Business Type should be mapped');
        Assert.areEqual('Kolkata', saved.City, 'City should be mapped');
        Assert.areEqual(false, saved.Walk_In_Flag__c, 'Walk-In Flag should default to false');
        Assert.areEqual(false, saved.HasOptedOutOfEmail, 'Opt out should default to false');
        Assert.isNotNull(saved.Store_Association__c, 'Store Association should be set');
    }

    @IsTest
    static void createsB2BLeadWithCompanyDetails() {
        String body =
            '{' +
            '"firstName":"Rakesh",' +
            '"lastName":"Agarwal",' +
            '"company":"Agarwal Jewellers Pvt Ltd",' +
            '"title":"Purchase Head",' +
            '"phone":"+91-9007712345",' +
            '"email":"rakesh@agarwaljewellers.example",' +
            '"leadSource":"India Mart",' +
            '"businessType":"B2B",' +
            '"industry":"Retail",' +
            '"annualRevenue":45000000,' +
            '"numberOfEmployees":24' +
            '}';

        Map<String, Object> response = post(body);

        Assert.areEqual(201, statusOf(response), 'A valid B2B enquiry should be created');

        Lead saved = [
            SELECT Company, Title, Industry, AnnualRevenue, NumberOfEmployees, Business_Type__c
            FROM Lead
            LIMIT 1
        ];
        Assert.areEqual('Agarwal Jewellers Pvt Ltd', saved.Company, 'Company should be kept as sent');
        Assert.areEqual('Retail', saved.Industry, 'Industry should be mapped');
        Assert.areEqual(45000000, saved.AnnualRevenue.intValue(), 'Annual Revenue should be mapped');
        Assert.areEqual(24, saved.NumberOfEmployees, 'Employee count should be mapped');
    }

    @IsTest
    static void appliesDocumentedDefaultsAndIgnoresUnknownFields() {
        String body =
            '{' +
            '"lastName":"Bose",' +
            '"phone":"+91-9800011111",' +
            '"leadSource":"WhatsApp",' +
            '"utmSource":"newsletter",' +
            '"someFieldWeDoNotKnow":true' +
            '}';

        Map<String, Object> response = post(body);

        Assert.areEqual(201, statusOf(response), 'Unknown keys should be ignored, not rejected');
        Assert.areEqual('Unknown', response.get('businessType'), 'Business Type should default to Unknown');

        Lead saved = [SELECT Company, Status, Business_Type__c FROM Lead LIMIT 1];
        Assert.areEqual('Bose', saved.Company, 'Company should fall back to the single name supplied');
        Assert.areEqual('New', saved.Status, 'Status should default to New');
        Assert.areEqual('Unknown', saved.Business_Type__c, 'Business Type should default to Unknown');
    }

    // =====================================================================
    // Validation failures
    // =====================================================================

    @IsTest
    static void rejectsMissingLastName() {
        Map<String, Object> response = post('{"leadSource":"Shopify","phone":"+91-9800011111"}');

        Assert.areEqual(400, statusOf(response), 'A missing name should be a bad request');
        Assert.areEqual('MISSING_REQUIRED_FIELD', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('lastName', response.get('field'), 'The offending field should be reported');
        Assert.areEqual(false, response.get('success'), 'success should be false');
    }

    @IsTest
    static void rejectsMissingLeadSource() {
        Map<String, Object> response = post('{"lastName":"Sharma","phone":"+91-9800011111"}');

        Assert.areEqual(400, statusOf(response), 'A missing source should be a bad request');
        Assert.areEqual('MISSING_REQUIRED_FIELD', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('leadSource', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void rejectsEnquiryWithNoPhoneOrEmail() {
        Map<String, Object> response = post('{"lastName":"Sharma","leadSource":"Shopify"}');

        Assert.areEqual(400, statusOf(response), 'An unreachable customer should be rejected');
        Assert.areEqual('CONTACT_INFO_REQUIRED', response.get('errorCode'), 'Error code should name the cause');
    }

    @IsTest
    static void rejectsB2BWithoutCompany() {
        Map<String, Object> response = post(
            '{"lastName":"Agarwal","leadSource":"India Mart","phone":"+91-9800011111","businessType":"B2B"}'
        );

        Assert.areEqual(400, statusOf(response), 'B2B without a firm name should be rejected');
        Assert.areEqual('COMPANY_REQUIRED', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('company', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void rejectsUnknownPicklistValue() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Website","phone":"+91-9800011111"}'
        );

        Assert.areEqual(400, statusOf(response), 'An unlisted source should be rejected');
        Assert.areEqual('INVALID_PICKLIST_VALUE', response.get('errorCode'), 'Error code should name the cause');
        Assert.isTrue(
            ((String) response.get('message')).contains('Allowed values'),
            'The message should list the values the org accepts'
        );
    }

    @IsTest
    static void rejectsMalformedEmail() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","email":"ananya.sharma.example.com"}'
        );

        Assert.areEqual(400, statusOf(response), 'A malformed email should be rejected');
        Assert.areEqual('INVALID_EMAIL_FORMAT', response.get('errorCode'), 'Error code should name the cause');
    }

    @IsTest
    static void rejectsOversizedValue() {
        String longName = 'A'.repeat(120);
        Map<String, Object> response = post(
            '{"lastName":"' + longName + '","leadSource":"Shopify","phone":"+91-9800011111"}'
        );

        Assert.areEqual(400, statusOf(response), 'A value past the field length should be rejected');
        Assert.areEqual('VALUE_TOO_LONG', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('lastName', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void rejectsUnknownStoreCode() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","storeCode":"NO-SUCH-STORE"}'
        );

        Assert.areEqual(400, statusOf(response), 'An unknown store should be rejected');
        Assert.areEqual('STORE_NOT_FOUND', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('storeCode', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void rejectsUnknownCampaign() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","campaignId":"701000000000000"}'
        );

        Assert.areEqual(400, statusOf(response), 'An unknown campaign should be rejected');
        Assert.areEqual('CAMPAIGN_NOT_FOUND', response.get('errorCode'), 'Error code should name the cause');
    }

    @IsTest
    static void rejectsMalformedCampaignId() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","campaignId":"NOT-AN-ID"}'
        );

        Assert.areEqual(400, statusOf(response), 'A malformed Id should be rejected');
        Assert.areEqual('CAMPAIGN_NOT_FOUND', response.get('errorCode'), 'Error code should name the cause');
    }

    @IsTest
    static void rejectsStateWithoutCountry() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","state":"West Bengal"}'
        );

        Assert.areEqual(400, statusOf(response), 'A state without a country should be rejected');
        Assert.areEqual('INVALID_ADDRESS', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('country', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void rejectsUnparseableBody() {
        Map<String, Object> response = post('{"lastName":');

        Assert.areEqual(400, statusOf(response), 'Broken JSON should be rejected');
        Assert.areEqual('INVALID_JSON', response.get('errorCode'), 'Error code should name the cause');
    }

    @IsTest
    static void rejectsEmptyBody() {
        Map<String, Object> response = post(null);

        Assert.areEqual(400, statusOf(response), 'An empty body should be rejected');
        Assert.areEqual('INVALID_JSON', response.get('errorCode'), 'Error code should name the cause');
    }
}
