/**
 * Tests for LeadTriggerHandler: the B2C Company, the phone check, the
 * existing-customer block, and the matching used by the New Lead flow
 * (phone cleaning, existing customers, open Leads).
 *
 * Duplicate open Leads are blocked by the Lead Duplicate Check duplicate
 * rule and are not tested here.
 */
@IsTest
private class LeadTriggerHandlerTest {

    private static Lead reload(Id leadId) {
        return [
            SELECT FirstName, LastName, Company, Business_Type__c, Lead_Number__c, Phone
            FROM Lead
            WHERE Id = :leadId
            WITH SYSTEM_MODE
        ];
    }

    // =====================================================================
    // B2C Company
    // =====================================================================

    /** A Lead saved without a Company is B2C and gets "<Name> - B2C-<Lead Number>". */
    @IsTest
    static void aLeadWithoutACompanyIsB2cWithAUniqueCompany() {
        Lead walkIn = new Lead(FirstName = 'Asha', LastName = 'Mehta');

        Test.startTest();
        insert walkIn;
        Test.stopTest();

        Lead saved = reload(walkIn.Id);
        Assert.areEqual('B2C', saved.Business_Type__c, 'No company means B2C');
        Assert.areEqual('Asha Mehta - B2C-' + saved.Lead_Number__c, saved.Company, 'Name, B2C and the Lead Number');
    }

    /** The New Lead screen's default "<Name> - B2C" is treated the same as a blank Company. */
    @IsTest
    static void theScreenDefaultCompanyIsCompletedWithTheLeadNumber() {
        Lead walkIn = new Lead(FirstName = 'Ravi', LastName = 'Shah', Company = 'Ravi Shah - B2C');

        Test.startTest();
        insert walkIn;
        Test.stopTest();

        Lead saved = reload(walkIn.Id);
        Assert.areEqual('B2C', saved.Business_Type__c, 'The default company means B2C');
        Assert.areEqual('Ravi Shah - B2C-' + saved.Lead_Number__c, saved.Company, 'The Lead Number is added');
    }

    /** A Company that was typed in is kept as it is. */
    @IsTest
    static void aTypedCompanyIsKept() {
        Lead business = new Lead(LastName = 'Agarwal', Company = 'Agarwal Jewellers Pvt Ltd');

        Test.startTest();
        insert business;
        Test.stopTest();

        Lead saved = reload(business.Id);
        Assert.areEqual('Agarwal Jewellers Pvt Ltd', saved.Company, 'Company is untouched');
        Assert.areNotEqual('B2C', saved.Business_Type__c, 'And the Lead is not made B2C');
    }

    /** Every B2C Lead in one save gets its own Company. */
    @IsTest
    static void companiesAreUniqueInABulkSave() {
        List<Lead> walkIns = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            walkIns.add(new Lead(FirstName = 'Same', LastName = 'Name'));
        }

        Test.startTest();
        insert walkIns;
        Test.stopTest();

        Set<String> companies = new Set<String>();
        for (Lead saved : [SELECT Company FROM Lead WHERE Id IN :walkIns]) {
            companies.add(saved.Company);
        }
        Assert.areEqual(200, companies.size(), 'Two people with the same name still get different Companies');
    }

    /** On a B2C Lead the Company follows the person's name. */
    @IsTest
    static void theB2cCompanyFollowsANameChange() {
        Lead walkIn = new Lead(FirstName = 'Neha', LastName = 'Jain');
        insert walkIn;

        Test.startTest();
        update new Lead(Id = walkIn.Id, LastName = 'Jain Kapoor');
        Test.stopTest();

        Lead saved = reload(walkIn.Id);
        Assert.areEqual('Neha Jain Kapoor - B2C-' + saved.Lead_Number__c, saved.Company, 'Company follows the new name');
    }

    /** No one can change a B2C Company by hand. */
    @IsTest
    static void aB2cCompanyCannotBeChangedByHand() {
        Lead walkIn = new Lead(FirstName = 'Pooja', LastName = 'Nair');
        insert walkIn;

        Test.startTest();
        Database.SaveResult result = Database.update(new Lead(Id = walkIn.Id, Company = 'Something Else'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'The change is refused');
        Assert.areEqual(LeadTriggerHandler.COMPANY_LOCKED, result.getErrors()[0].getMessage(), 'With a plain reason');
    }

    // =====================================================================
    // Phone
    // =====================================================================

    /** The phone is saved exactly as entered; only the check ignores +91 and separators. */
    @IsTest
    static void thePhoneIsSavedAsEntered() {
        Lead walkIn = new Lead(LastName = 'Verma', Phone = '+91 98300 12366');

        Test.startTest();
        insert walkIn;
        Test.stopTest();

        Assert.areEqual('+91 98300 12366', reload(walkIn.Id).Phone, 'Not reformatted');
    }

    /** A phone that is not 10 digits (after +91 or 91) cannot be saved. */
    @IsTest
    static void aPhoneThatIsNotTenDigitsIsRejected() {
        Test.startTest();
        Database.SaveResult result = Database.insert(new Lead(LastName = 'Short', Phone = '98300 123'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Nine digits are refused');
        Assert.isTrue(
            result.getErrors()[0].getMessage().contains('10-digit'),
            'By the phone validation rule: ' + result.getErrors()[0].getMessage()
        );
    }

    // =====================================================================
    // Existing customers
    // =====================================================================

    /** A Lead for an existing customer is refused; an enquiry is raised instead. */
    @IsTest
    static void aLeadForAnExistingCustomerIsRefused() {
        insert new Account(Name = 'Sharma Household', Phone = '9830012355');

        Test.startTest();
        Database.SaveResult result = Database.insert(
            new Lead(LastName = 'Sharma', Phone = '+91-98300-12355'),
            false
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'The same phone in another format is still the same customer');
        Assert.isTrue(
            result.getErrors()[0].getMessage().contains('Sharma Household'),
            'The message names the customer: ' + result.getErrors()[0].getMessage()
        );
    }

    /** Leads from the website API are not checked here; the API will raise the enquiry itself. */
    @IsTest
    static void websiteApiLeadsAreNotCheckedYet() {
        insert new Account(Name = 'Bose Household', Phone = '9830012344');
        RestContext.request = new RestRequest();

        Test.startTest();
        Database.SaveResult result = Database.insert(
            new Lead(LastName = 'Bose', Company = 'Halsa Global', Phone = '9830012344'),
            false
        );
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'Saved as before until the API phase');
    }


    private static LeadTriggerHandler.CheckResult checkOne(String phone, String email) {
        LeadTriggerHandler.CheckRequest request = new LeadTriggerHandler.CheckRequest();
        request.phone = phone;
        request.email = email;
        return LeadTriggerHandler.check(new List<LeadTriggerHandler.CheckRequest>{ request })[0];
    }

    // =====================================================================
    // Matching: phone cleaning
    // =====================================================================

    @IsTest
    static void cleansCommonIndianFormatsToTenDigits() {
        Assert.areEqual('9830012345', LeadTriggerHandler.normalizePhone('9830012345'), 'Already 10 digits');
        Assert.areEqual('9830012345', LeadTriggerHandler.normalizePhone('+91 98300 12345'), '+91 and spaces');
        Assert.areEqual('9830012345', LeadTriggerHandler.normalizePhone('+91-9830012345'), '+91 and a dash');
        Assert.areEqual('9830012345', LeadTriggerHandler.normalizePhone('919830012345'), '91 without the plus');
        Assert.areEqual('9830012345', LeadTriggerHandler.normalizePhone('(98300) 123.45'), 'Brackets and dots');
        Assert.areEqual('9123456789', LeadTriggerHandler.normalizePhone('9123456789'), 'A number starting 91 is not cut short');
    }

    @IsTest
    static void leavesNumbersThatAreNotIndianMobilesInvalid() {
        Assert.isFalse(LeadTriggerHandler.isValidPhone(LeadTriggerHandler.normalizePhone('09830012345')), 'A leading 0 is not removed');
        Assert.isFalse(LeadTriggerHandler.isValidPhone(LeadTriggerHandler.normalizePhone('12345')), 'Too short');
        Assert.isFalse(LeadTriggerHandler.isValidPhone(LeadTriggerHandler.normalizePhone('+1 415 555 0100')), 'Another country code');
        Assert.isFalse(LeadTriggerHandler.isValidPhone(LeadTriggerHandler.normalizePhone('98300abc45')), 'Letters');
        Assert.isNull(LeadTriggerHandler.normalizePhone(null), 'Blank stays blank');
    }

    // =====================================================================
    // Matching: existing customers
    // =====================================================================

    @IsTest
    static void findsAnAccountWhosePhoneIsStoredInAnotherFormat() {
        insert new Account(Name = 'Sharma Household', Phone = '+91-9830012395');

        Test.startTest();
        Map<String, LeadTriggerHandler.Customer> customers = LeadTriggerHandler.findCustomers(
            new Set<String>{ '9830012395' }, new Set<String>()
        );
        Test.stopTest();

        LeadTriggerHandler.Customer customer = customers.get(LeadTriggerHandler.phoneKey('9830012395'));
        Assert.isNotNull(customer, 'The +91- form is matched');
        Assert.areEqual('Sharma Household', customer.accountName, 'With the Account name');
        Assert.areEqual(UserInfo.getUserId(), customer.ownerId, 'And its active owner');
    }

    @IsTest
    static void findsAnAccountByItsEmail() {
        insert new Account(Name = 'Gupta Household', Email__c = 'gupta@matcher.example.com');

        Test.startTest();
        Map<String, LeadTriggerHandler.Customer> customers = LeadTriggerHandler.findCustomers(
            new Set<String>(), new Set<String>{ 'GUPTA@matcher.example.com' }
        );
        Test.stopTest();

        LeadTriggerHandler.Customer customer = customers.get(LeadTriggerHandler.emailKey('gupta@matcher.example.com'));
        Assert.isNotNull(customer, 'Email is matched without regard to case');
        Assert.areEqual('Gupta Household', customer.accountName, 'On the Account');
    }

    @IsTest
    static void aContactMatchNamesThePersonAndTheirHousehold() {
        Account household = new Account(Name = 'Nair Household', Phone = '9830012399');
        insert household;
        Contact person = new Contact(LastName = 'Nair', AccountId = household.Id, MobilePhone = '9830012399');
        insert person;

        Test.startTest();
        LeadTriggerHandler.Customer customer = LeadTriggerHandler.findCustomers(
            new Set<String>{ '9830012399' }, new Set<String>()
        ).get(LeadTriggerHandler.phoneKey('9830012399'));
        Test.stopTest();

        Assert.areEqual(person.Id, customer.contactId, 'The Contact is identified');
        Assert.areEqual(household.Id, customer.accountId, 'Within the household');
    }

    // =====================================================================
    // Matching: invocable check (New Lead flow)
    // =====================================================================

    @IsTest
    static void reportsAnInvalidPhone() {
        Test.startTest();
        LeadTriggerHandler.CheckResult result = checkOne('12345', null);
        Test.stopTest();

        Assert.isFalse(result.isPhoneValid, 'Not 10 digits');
        Assert.isFalse(result.isExistingCustomer, 'Nothing is matched on an invalid phone');
    }

    @IsTest
    static void aBlankPhoneIsNotAnError() {
        Test.startTest();
        LeadTriggerHandler.CheckResult result = checkOne(null, 'nobody@matcher.example.com');
        Test.stopTest();

        Assert.isTrue(result.isPhoneValid, 'Phone is optional');
        Assert.isFalse(result.isExistingCustomer, 'No customer');
        Assert.isFalse(result.isOpenLead, 'No Lead');
    }

    @IsTest
    static void reportsAnExistingCustomerWithTheCaseOwner() {
        Account household = new Account(Name = 'Mehta Household', Phone = '9830012388');
        insert household;

        Test.startTest();
        LeadTriggerHandler.CheckResult result = checkOne('+91 98300 12388', null);
        Test.stopTest();

        Assert.isTrue(result.isPhoneValid, '+91 with spaces is valid');
        Assert.areEqual('9830012388', result.normalizedPhone, 'Cleaned for matching');
        Assert.isTrue(result.isExistingCustomer, 'The household is found');
        Assert.areEqual(household.Id, result.accountId, 'On its Account');
        Assert.areEqual(UserInfo.getUserId(), result.caseOwnerId, 'The enquiry goes to the account owner');
    }

    @IsTest
    static void reportsAnOpenLead() {
        Lead existing = new Lead(LastName = 'Kapoor', Company = 'Kapoor Traders', Phone = '+91 98300 12377');
        insert existing;

        Test.startTest();
        LeadTriggerHandler.CheckResult result = checkOne('9830012377', null);
        Test.stopTest();

        Assert.isFalse(result.isExistingCustomer, 'Not a customer yet');
        Assert.isTrue(result.isOpenLead, 'The open Lead is found whatever format its phone was saved in');
        Assert.areEqual(existing.Id, result.openLeadId, 'The right Lead');
    }

    @IsTest
    static void anExistingCustomerIsReportedBeforeAnOpenLead() {
        Lead existing = new Lead(LastName = 'Bose', Company = 'Bose Traders', Email = 'bose@matcher.example.com');
        insert existing;
        Account household = new Account(Name = 'Bose Household', Email__c = 'bose@matcher.example.com');
        insert household;

        Test.startTest();
        LeadTriggerHandler.CheckResult result = checkOne(null, 'bose@matcher.example.com');
        Test.stopTest();

        Assert.isTrue(result.isExistingCustomer, 'The customer is found');
        Assert.areEqual(household.Id, result.accountId, 'On the household Account');
        Assert.isTrue(result.isOpenLead, 'The Lead is reported too; the flow handles the customer first');
    }
}
