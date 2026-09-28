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
    static void createsLeadFromWebsiteEnquiry() {
        String body =
            '{' +
            '"salutation":"Ms.",' +
            '"firstName":"Ananya",' +
            '"lastName":"Sharma",' +
            '"phone":"+91-9830012345",' +
            '"email":"ananya.sharma@example.com",' +
            '"leadSource":"Shopify",' +
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
        Assert.areEqual('Halsa Global', response.get('company'), 'Company should default to Halsa Global');

        Lead saved = [
            SELECT FirstName, LastName, Company, Email, Phone, LeadSource, Status,
                   Rating, Walk_In_Flag__c, Business_Type__c,
                   City, Store_Association__c
            FROM Lead
            LIMIT 1
        ];
        Assert.areEqual('Halsa Global', saved.Company, 'Company should default to Halsa Global');
        Assert.areEqual('Shopify', saved.LeadSource, 'Lead Source should be mapped');
        Assert.areEqual('Kolkata', saved.City, 'City should be mapped');
        Assert.areEqual(false, saved.Walk_In_Flag__c, 'Walk-In Flag should default to false');
        Assert.areEqual('Unknown', saved.Business_Type__c, 'Business Type should default to Unknown');
        Assert.isNotNull(saved.Store_Association__c, 'Store Association should be set');
    }

    @IsTest
    static void keepsCompanyAndFirmDetailsWhenSent() {
        String body =
            '{' +
            '"firstName":"Rakesh",' +
            '"lastName":"Agarwal",' +
            '"company":"Agarwal Jewellers Pvt Ltd",' +
            '"phone":"+91-9007712345",' +
            '"email":"rakesh@agarwaljewellers.example",' +
            '"leadSource":"India Mart",' +
            '"industry":"Retail",' +
            '"annualRevenue":45000000,' +
            '"numberOfEmployees":24' +
            '}';

        Map<String, Object> response = post(body);

        Assert.areEqual(201, statusOf(response), 'A valid enquiry with company details should be created');

        Lead saved = [
            SELECT Company, Industry, AnnualRevenue, NumberOfEmployees
            FROM Lead
            LIMIT 1
        ];
        Assert.areEqual('Agarwal Jewellers Pvt Ltd', saved.Company, 'Company should be kept as sent');
        Assert.areEqual('Retail', saved.Industry, 'Industry should be mapped');
        Assert.areEqual(45000000, saved.AnnualRevenue.intValue(), 'Annual Revenue should be mapped');
        Assert.areEqual(24, saved.NumberOfEmployees, 'Employee count should be mapped');
    }

    @IsTest
    static void mapsBusinessTypeWalkInAndCampaign() {
        Campaign campaign = new Campaign(Name = 'Diwali 2026', IsActive = true);
        insert campaign;

        String body =
            '{' +
            '"lastName":"Sharma",' +
            '"phone":"+91-9830012345",' +
            '"leadSource":"Walk-in",' +
            '"businessType":"B2C",' +
            '"industry":"Retail",' +
            '"walkInFlag":true,' +
            '"campaignName":"diwali 2026"' +
            '}';

        Map<String, Object> response = post(body);

        Assert.areEqual(201, statusOf(response), 'A valid enquiry should be created');

        Lead saved = [
            SELECT Business_Type__c, Industry, Walk_In_Flag__c, Campaign_Attribution__c
            FROM Lead
            LIMIT 1
        ];
        Assert.areEqual('B2C', saved.Business_Type__c, 'Business Type should be mapped');
        Assert.areEqual('Retail', saved.Industry, 'Industry should be mapped');
        Assert.areEqual(true, saved.Walk_In_Flag__c, 'Walk-In Flag should be mapped');
        Assert.areEqual(campaign.Id, saved.Campaign_Attribution__c, 'Campaign should be found by name, ignoring case');
    }

    @IsTest
    static void rejectsUnknownBusinessType() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","businessType":"Retail"}'
        );

        Assert.areEqual(400, statusOf(response), 'An unlisted business type should be rejected');
        Assert.areEqual('INVALID_PICKLIST_VALUE', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('businessType', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void mapsPersonalDetails() {
        String body =
            '{' +
            '"lastName":"Sharma",' +
            '"phone":"+91-9830012345",' +
            '"leadSource":"Shopify",' +
            '"dateOfBirth":"1992-08-25",' +
            '"maritalStatus":"Married",' +
            '"anniversaryDate":"2018-02-14"' +
            '}';

        Map<String, Object> response = post(body);

        Assert.areEqual(201, statusOf(response), 'Valid personal details should be accepted');

        Lead saved = [SELECT Date_of_Birth__c, Marital_Status__c, Anniversary_Date__c FROM Lead LIMIT 1];
        Assert.areEqual(Date.newInstance(1992, 8, 25), saved.Date_of_Birth__c, 'Date of Birth should be mapped');
        Assert.areEqual('Married', saved.Marital_Status__c, 'Marital Status should be mapped');
        Assert.areEqual(Date.newInstance(2018, 2, 14), saved.Anniversary_Date__c, 'Anniversary Date should be mapped');
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

        Lead saved = [SELECT Company, Status FROM Lead LIMIT 1];
        Assert.areEqual('Halsa Global', saved.Company, 'Company should default to Halsa Global');
        Assert.areEqual('New', saved.Status, 'Status should default to New');
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
    static void rejectsUnknownCampaignName() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","campaignName":"No Such Campaign"}'
        );

        Assert.areEqual(400, statusOf(response), 'An unknown campaign should be rejected');
        Assert.areEqual('CAMPAIGN_NOT_FOUND', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('campaignName', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void prefersActiveCampaignWhenNamesClash() {
        Campaign inactive = new Campaign(Name = 'Akshaya Tritiya', IsActive = false);
        Campaign active = new Campaign(Name = 'Akshaya Tritiya', IsActive = true);
        insert new List<Campaign>{ inactive, active };

        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","campaignName":"Akshaya Tritiya"}'
        );

        Assert.areEqual(201, statusOf(response), 'A known campaign name should be accepted');
        Assert.areEqual(
            active.Id,
            [SELECT Campaign_Attribution__c FROM Lead LIMIT 1].Campaign_Attribution__c,
            'The active campaign should win'
        );
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
    static void rejectsUnknownMaritalStatus() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","maritalStatus":"Single"}'
        );

        Assert.areEqual(400, statusOf(response), 'An unlisted marital status should be rejected');
        Assert.areEqual('INVALID_PICKLIST_VALUE', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('maritalStatus', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void rejectsWronglyFormattedDate() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","dateOfBirth":"25/08/1992"}'
        );

        Assert.areEqual(400, statusOf(response), 'A DD/MM/YYYY date should be rejected');
        Assert.areEqual('INVALID_DATE', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('dateOfBirth', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void rejectsImpossibleDate() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","anniversaryDate":"2019-02-30"}'
        );

        Assert.areEqual(400, statusOf(response), '30 February should be rejected, not rolled into March');
        Assert.areEqual('INVALID_DATE', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('anniversaryDate', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void rejectsFutureDate() {
        String tomorrow = String.valueOf(Date.today().addDays(1));
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111","dateOfBirth":"' + tomorrow + '"}'
        );

        Assert.areEqual(400, statusOf(response), 'A birth date in the future should be rejected');
        Assert.areEqual('INVALID_DATE', response.get('errorCode'), 'Error code should name the cause');
    }

    @IsTest
    static void rejectsAnniversaryForUnmarriedCustomer() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111",' +
            '"maritalStatus":"Unmarried","anniversaryDate":"2018-02-14"}'
        );

        Assert.areEqual(400, statusOf(response), 'An unmarried customer cannot have an anniversary date');
        Assert.areEqual('ANNIVERSARY_NOT_ALLOWED', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('anniversaryDate', response.get('field'), 'The offending field should be reported');
    }

    @IsTest
    static void rejectsAnniversaryBeforeDateOfBirth() {
        Map<String, Object> response = post(
            '{"lastName":"Sharma","leadSource":"Shopify","phone":"+91-9800011111",' +
            '"dateOfBirth":"1992-08-25","anniversaryDate":"1990-02-14"}'
        );

        Assert.areEqual(400, statusOf(response), 'An anniversary before birth should be rejected');
        Assert.areEqual('INVALID_DATE', response.get('errorCode'), 'Error code should name the cause');
        Assert.areEqual('anniversaryDate', response.get('field'), 'The offending field should be reported');
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
