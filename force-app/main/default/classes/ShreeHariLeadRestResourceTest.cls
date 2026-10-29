/**
 * Tests for the website lead capture endpoint.
 *
 * Each test drives the resource the way the website does — a JSON body in, a
 * status code and JSON body out — so the assertions are on the published
 * contract rather than on internal method calls. Leads follow the same rules
 * as the New Lead screen.
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

    /**
     * A valid enquiry (lastName, phone, description, leadSource) with the
     * given keys added or replaced; a null value removes the key.
     */
    private static String body(Map<String, Object> changes) {
        Map<String, Object> payload = new Map<String, Object>{
            'lastName' => 'Sharma',
            'phone' => '+91-9800011111',
            'description' => 'Gold ring, budget 40,000 INR.',
            'leadSource' => 'Shopify'
        };
        for (String key : changes.keySet()) {
            if (changes.get(key) == null) {
                payload.remove(key);
            } else {
                payload.put(key, changes.get(key));
            }
        }
        return JSON.serialize(payload);
    }

    private static Integer statusOf(Map<String, Object> response) {
        return (Integer) response.get('__status');
    }

    private static void assertBadRequest(Map<String, Object> response, String errorCode, String field) {
        Assert.areEqual(400, statusOf(response), 'Should be a bad request: ' + response);
        Assert.areEqual(errorCode, response.get('errorCode'), 'Error code should name the cause');
        if (field != null) {
            Assert.areEqual(field, response.get('field'), 'The offending field should be reported');
        }
        Assert.areEqual(false, response.get('success'), 'success should be false');
    }

    // =====================================================================
    // New customer: a Lead
    // =====================================================================

    @IsTest
    static void createsAB2cLeadFromWebsiteEnquiry() {
        Map<String, Object> response = post(body(new Map<String, Object>{
            'salutation' => 'Ms.',
            'firstName' => 'Ananya',
            'phone' => '+91-9830012345',
            'email' => 'ananya.sharma@example.com',
            'street' => '12/1 Lake View Road',
            'city' => 'Kolkata',
            'state' => 'West Bengal',
            'postalCode' => '700029',
            'country' => 'India',
            'storeCode' => STORE_CODE,
            'rating' => 'Warm'
        }));

        Assert.areEqual(201, statusOf(response), 'A valid enquiry should be created: ' + response);
        Assert.areEqual(true, response.get('success'), 'success should be true');
        Assert.areEqual('CREATED', response.get('action'), 'action should be CREATED');
        Assert.isNotNull(response.get('leadId'), 'leadId should be returned');
        Assert.areEqual('New', response.get('status'), 'Status should default to New');
        Assert.isNotNull(response.get('storeAssociationId'), 'Store should be resolved');
        Assert.isNull(response.get('caseId'), 'No enquiry fields on a new Lead');

        Lead saved = [
            SELECT Company, Business_Type__c, Phone, Description, LeadSource, City, Walk_In_Flag__c
            FROM Lead
            LIMIT 1
        ];
        Assert.isTrue(saved.Company.startsWith('Ananya Sharma Family ('), 'A blank company makes a B2C Lead: ' + saved.Company);
        Assert.areEqual('B2C', saved.Business_Type__c, 'B2C, as on the New Lead screen');
        Assert.areEqual(saved.Company, response.get('company'), 'The response reports the company saved');
        Assert.areEqual('+91-9830012345', saved.Phone, 'Phone is saved exactly as sent');
        Assert.areEqual('Gold ring, budget 40,000 INR.', saved.Description, 'Product description saved');
        Assert.areEqual('Shopify', saved.LeadSource, 'Lead Source should be mapped');
        Assert.areEqual('Kolkata', saved.City, 'City should be mapped');
        Assert.areEqual(false, saved.Walk_In_Flag__c, 'Walk-In Flag should default to false');
    }

    @IsTest
    static void aCompanyMakesAB2bLead() {
        Map<String, Object> response = post(body(new Map<String, Object>{
            'firstName' => 'Rakesh',
            'lastName' => 'Agarwal',
            'company' => 'Agarwal Jewellers Pvt Ltd',
            'leadSource' => 'India Mart',
            'industry' => 'Retail',
            'annualRevenue' => 45000000,
            'numberOfEmployees' => 24
        }));

        Assert.areEqual(201, statusOf(response), 'A valid enquiry with company details should be created');

        Lead saved = [SELECT Company, Business_Type__c, Industry, AnnualRevenue, NumberOfEmployees FROM Lead LIMIT 1];
        Assert.areEqual('Agarwal Jewellers Pvt Ltd', saved.Company, 'Company should be kept as sent');
        Assert.areEqual('B2B', saved.Business_Type__c, 'A company makes the Lead B2B');
        Assert.areEqual('Retail', saved.Industry, 'Industry should be mapped');
        Assert.areEqual(45000000, saved.AnnualRevenue.intValue(), 'Annual Revenue should be mapped');
        Assert.areEqual(24, saved.NumberOfEmployees, 'Employee count should be mapped');
    }

    @IsTest
    static void businessTypeInThePayloadIsIgnored() {
        Campaign campaign = new Campaign(Name = 'Diwali 2026', IsActive = true);
        insert campaign;

        Map<String, Object> response = post(body(new Map<String, Object>{
            'company' => 'Sharma Traders',
            'businessType' => 'Retail',
            'leadSource' => 'Walk-in',
            'walkInFlag' => true,
            'campaignName' => 'diwali 2026'
        }));

        Assert.areEqual(201, statusOf(response), 'businessType is not checked, as it is not used');

        Lead saved = [SELECT Business_Type__c, Walk_In_Flag__c, Campaign_Attribution__c FROM Lead LIMIT 1];
        Assert.areEqual('B2B', saved.Business_Type__c, 'Set from the company, not the payload');
        Assert.areEqual(true, saved.Walk_In_Flag__c, 'Walk-In Flag should be mapped');
        Assert.areEqual(campaign.Id, saved.Campaign_Attribution__c, 'Campaign should be found by name, ignoring case');
    }

    @IsTest
    static void mapsPersonalDetails() {
        Map<String, Object> response = post(body(new Map<String, Object>{
            'dateOfBirth' => '1992-08-25',
            'maritalStatus' => 'Married',
            'anniversaryDate' => '2018-02-14'
        }));

        Assert.areEqual(201, statusOf(response), 'Valid personal details should be accepted');

        Lead saved = [SELECT Date_of_Birth__c, Marital_Status__c, Anniversary_Date__c FROM Lead LIMIT 1];
        Assert.areEqual(Date.newInstance(1992, 8, 25), saved.Date_of_Birth__c, 'Date of Birth should be mapped');
        Assert.areEqual('Married', saved.Marital_Status__c, 'Marital Status should be mapped');
        Assert.areEqual(Date.newInstance(2018, 2, 14), saved.Anniversary_Date__c, 'Anniversary Date should be mapped');
    }

    @IsTest
    static void statusAndQualificationNotesAreKeptWhenSent() {
        Map<String, Object> response = post(body(new Map<String, Object>{
            'status' => 'Contacted',
            'qualificationNotes' => 'Called back, visiting the store on Saturday.'
        }));

        Assert.areEqual(201, statusOf(response), 'Accepted');

        Lead saved = [SELECT Status, Qualification_Notes__c FROM Lead LIMIT 1];
        Assert.areEqual('Contacted', saved.Status, 'Status as sent');
        Assert.areEqual('Called back, visiting the store on Saturday.', saved.Qualification_Notes__c, 'Notes as sent');
    }

    @IsTest
    static void appliesDocumentedDefaultsAndIgnoresUnknownFields() {
        Map<String, Object> response = post(body(new Map<String, Object>{
            'utmSource' => 'newsletter',
            'someFieldWeDoNotKnow' => true
        }));

        Assert.areEqual(201, statusOf(response), 'Unknown keys should be ignored, not rejected');

        Lead saved = [SELECT Status, Qualification_Notes__c FROM Lead LIMIT 1];
        Assert.areEqual('New', saved.Status, 'Status should default to New');
        Assert.isNull(saved.Qualification_Notes__c, 'No notes unless sent');
    }

    // =====================================================================
    // Existing customer: an enquiry Case
    // =====================================================================

    @IsTest
    static void raisesAnEnquiryForAnExistingCustomer() {
        Account household = new Account(Name = 'Sharma Household', Phone = '9830012399');
        insert household;

        Map<String, Object> response = post(body(new Map<String, Object>{
            'firstName' => 'Ananya',
            'phone' => '+91 98300 12399',
            'storeCode' => STORE_CODE
        }));

        Assert.areEqual(201, statusOf(response), 'Accepted: ' + response);
        Assert.areEqual('ENQUIRY_CREATED', response.get('action'), 'An enquiry, not a Lead');
        Assert.isNotNull(response.get('caseId'), 'caseId returned');
        Assert.isNotNull(response.get('caseNumber'), 'caseNumber returned');
        Assert.areEqual(household.Id, response.get('accountId'), 'The customer it was raised for');
        Assert.isNull(response.get('leadId'), 'No Lead');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'No Lead is created');

        Id caseId = (Id) response.get('caseId');
        Case enquiry = [
            SELECT AccountId, Origin, Priority, Type, Status, Subject, Description, SuppliedPhone, Lead_Source__c, Store__c
            FROM Case
            WHERE Id = :caseId
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(household.Id, enquiry.AccountId, 'On the customer');
        Assert.areEqual('Phone', enquiry.Origin, 'Same as the New Lead screen');
        Assert.areEqual('Medium', enquiry.Priority, 'Same as the New Lead screen');
        Assert.areEqual('Service Enquiry', enquiry.Type, 'A service enquiry');
        Assert.areEqual('Enquiry from Ananya Sharma', enquiry.Subject, 'Named after the customer');
        Assert.areEqual('Gold ring, budget 40,000 INR.', enquiry.Description, 'The product description');
        Assert.areEqual('+91 98300 12399', enquiry.SuppliedPhone, 'Phone as sent');
        Assert.areEqual('Shopify', enquiry.Lead_Source__c, 'Lead source kept');
        Assert.isNotNull(enquiry.Store__c, 'Store kept');
    }

    @IsTest
    static void refusesAnOpenLeadWithTheSamePhone() {
        Lead existing = new Lead(LastName = 'Sharma', Company = 'Sharma Traders', Phone = '9830012377');
        insert existing;

        Map<String, Object> response = post(body(new Map<String, Object>{ 'phone' => '+91-98300-12377' }));

        Assert.areEqual(409, statusOf(response), 'A duplicate of an open Lead');
        Assert.areEqual('DUPLICATE_DETECTED', response.get('errorCode'), 'Error code should name the cause');
        Assert.isTrue(((String) response.get('message')).contains(existing.Id), 'Names the existing Lead: ' + response.get('message'));
        Assert.areEqual(1, [SELECT COUNT() FROM Lead], 'No second Lead');
    }

    // =====================================================================
    // Validation failures
    // =====================================================================

    @IsTest
    static void rejectsMissingLastName() {
        assertBadRequest(post(body(new Map<String, Object>{ 'lastName' => null })), 'MISSING_REQUIRED_FIELD', 'lastName');
    }

    @IsTest
    static void rejectsMissingPhone() {
        assertBadRequest(
            post(body(new Map<String, Object>{ 'phone' => null, 'email' => 'ananya@example.com' })),
            'MISSING_REQUIRED_FIELD',
            'phone'
        );
    }

    @IsTest
    static void rejectsMissingDescription() {
        assertBadRequest(post(body(new Map<String, Object>{ 'description' => '  ' })), 'MISSING_REQUIRED_FIELD', 'description');
    }

    @IsTest
    static void rejectsMissingLeadSource() {
        assertBadRequest(post(body(new Map<String, Object>{ 'leadSource' => null })), 'MISSING_REQUIRED_FIELD', 'leadSource');
    }

    @IsTest
    static void rejectsAPhoneThatIsNotTenDigits() {
        assertBadRequest(post(body(new Map<String, Object>{ 'phone' => '12345' })), 'INVALID_PHONE', 'phone');
    }

    @IsTest
    static void rejectsUnknownPicklistValue() {
        Map<String, Object> response = post(body(new Map<String, Object>{ 'leadSource' => 'Website' }));

        assertBadRequest(response, 'INVALID_PICKLIST_VALUE', 'leadSource');
        Assert.isTrue(
            ((String) response.get('message')).contains('Allowed values'),
            'The message should list the values the org accepts'
        );
    }

    @IsTest
    static void rejectsMalformedEmail() {
        assertBadRequest(post(body(new Map<String, Object>{ 'email' => 'ananya.sharma.example.com' })), 'INVALID_EMAIL_FORMAT', 'email');
    }

    @IsTest
    static void rejectsOversizedValue() {
        assertBadRequest(post(body(new Map<String, Object>{ 'lastName' => 'A'.repeat(120) })), 'VALUE_TOO_LONG', 'lastName');
    }

    @IsTest
    static void rejectsUnknownStoreCode() {
        assertBadRequest(post(body(new Map<String, Object>{ 'storeCode' => 'NO-SUCH-STORE' })), 'STORE_NOT_FOUND', 'storeCode');
    }

    @IsTest
    static void rejectsUnknownCampaignName() {
        assertBadRequest(post(body(new Map<String, Object>{ 'campaignName' => 'No Such Campaign' })), 'CAMPAIGN_NOT_FOUND', 'campaignName');
    }

    @IsTest
    static void prefersActiveCampaignWhenNamesClash() {
        Campaign inactive = new Campaign(Name = 'Akshaya Tritiya', IsActive = false);
        Campaign active = new Campaign(Name = 'Akshaya Tritiya', IsActive = true);
        insert new List<Campaign>{ inactive, active };

        Map<String, Object> response = post(body(new Map<String, Object>{ 'campaignName' => 'Akshaya Tritiya' }));

        Assert.areEqual(201, statusOf(response), 'A known campaign name should be accepted');
        Assert.areEqual(
            active.Id,
            [SELECT Campaign_Attribution__c FROM Lead LIMIT 1].Campaign_Attribution__c,
            'The active campaign should win'
        );
    }

    @IsTest
    static void rejectsStateWithoutCountry() {
        assertBadRequest(post(body(new Map<String, Object>{ 'state' => 'West Bengal' })), 'INVALID_ADDRESS', 'country');
    }

    @IsTest
    static void rejectsUnknownMaritalStatus() {
        assertBadRequest(post(body(new Map<String, Object>{ 'maritalStatus' => 'Single' })), 'INVALID_PICKLIST_VALUE', 'maritalStatus');
    }

    @IsTest
    static void rejectsWronglyFormattedDate() {
        assertBadRequest(post(body(new Map<String, Object>{ 'dateOfBirth' => '25/08/1992' })), 'INVALID_DATE', 'dateOfBirth');
    }

    @IsTest
    static void rejectsImpossibleDate() {
        assertBadRequest(
            post(body(new Map<String, Object>{ 'maritalStatus' => 'Married', 'anniversaryDate' => '2019-02-30' })),
            'INVALID_DATE',
            'anniversaryDate'
        );
    }

    @IsTest
    static void rejectsFutureDate() {
        assertBadRequest(
            post(body(new Map<String, Object>{ 'dateOfBirth' => String.valueOf(Date.today().addDays(1)) })),
            'INVALID_DATE',
            'dateOfBirth'
        );
    }

    @IsTest
    static void rejectsAnniversaryForUnmarriedCustomer() {
        assertBadRequest(
            post(body(new Map<String, Object>{ 'maritalStatus' => 'Unmarried', 'anniversaryDate' => '2018-02-14' })),
            'ANNIVERSARY_NOT_ALLOWED',
            'anniversaryDate'
        );
    }

    @IsTest
    static void rejectsAnniversaryWithoutMaritalStatus() {
        assertBadRequest(
            post(body(new Map<String, Object>{ 'anniversaryDate' => '2018-02-14' })),
            'ANNIVERSARY_NOT_ALLOWED',
            'anniversaryDate'
        );
    }

    @IsTest
    static void rejectsAnniversaryBeforeDateOfBirth() {
        assertBadRequest(
            post(body(new Map<String, Object>{
                'maritalStatus' => 'Married', 'dateOfBirth' => '1992-08-25', 'anniversaryDate' => '1990-02-14'
            })),
            'INVALID_DATE',
            'anniversaryDate'
        );
    }

    @IsTest
    static void rejectsUnparseableBody() {
        assertBadRequest(post('{"lastName":'), 'INVALID_JSON', null);
    }

    @IsTest
    static void rejectsEmptyBody() {
        assertBadRequest(post(null), 'INVALID_JSON', null);
    }
}
