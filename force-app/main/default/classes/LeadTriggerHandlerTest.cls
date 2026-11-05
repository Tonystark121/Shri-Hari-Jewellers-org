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

    /** A Lead saved without a Company is B2C and gets "<Name> B2C (<Lead Number>)". */
    @IsTest
    static void aLeadWithoutACompanyIsB2cWithAUniqueCompany() {
        Lead walkIn = new Lead(FirstName = 'Asha', LastName = 'Mehta');

        Test.startTest();
        insert walkIn;
        Test.stopTest();

        Lead saved = reload(walkIn.Id);
        Assert.areEqual('B2C', saved.Business_Type__c, 'No company means B2C');
        Assert.areEqual('Asha Mehta B2C (' + saved.Lead_Number__c + ')', saved.Company, 'Name, B2C and the Lead Number');
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
        Assert.areEqual('Ravi Shah B2C (' + saved.Lead_Number__c + ')', saved.Company, 'The Lead Number is added');
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
        Assert.areEqual('Neha Jain Kapoor B2C (' + saved.Lead_Number__c + ')', saved.Company, 'Company follows the new name');
    }

    /** A Lead saved before the Family format keeps "<Name> - B2C-<Lead Number>", which still follows the name. */
    @IsTest
    static void anEarlierFormatCompanyFollowsANameChange() {
        Lead walkIn = new Lead(FirstName = 'Kiran', LastName = 'Rao', Company = 'Placeholder');
        insert walkIn;
        Lead saved = reload(walkIn.Id);
        // Recreate a Lead from before the change: B2C with the earlier Company.
        update new Lead(Id = walkIn.Id, Business_Type__c = 'B2C', Company = 'Kiran Rao - B2C-' + saved.Lead_Number__c);

        Test.startTest();
        update new Lead(Id = walkIn.Id, LastName = 'Rao Menon');
        Test.stopTest();

        Assert.areEqual('Kiran Rao Menon - B2C-' + saved.Lead_Number__c, reload(walkIn.Id).Company, 'Kept in the earlier format');
    }

    /** A Lead saved before the B2C format keeps "<Name> Family (<Lead Number>)", which still follows the name. */
    @IsTest
    static void aFamilyFormatCompanyFollowsANameChange() {
        Lead walkIn = new Lead(FirstName = 'Meera', LastName = 'Iyer', Company = 'Placeholder');
        insert walkIn;
        Lead saved = reload(walkIn.Id);
        // Recreate a Lead from before the change: B2C with the Family Company.
        update new Lead(Id = walkIn.Id, Business_Type__c = 'B2C', Company = 'Meera Iyer Family (' + saved.Lead_Number__c + ')');

        Test.startTest();
        update new Lead(Id = walkIn.Id, LastName = 'Iyer Nair');
        Test.stopTest();

        Assert.areEqual('Meera Iyer Nair Family (' + saved.Lead_Number__c + ')', reload(walkIn.Id).Company, 'Kept in the Family format');
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

    /** API inserts are checked too (the API raises the enquiry first; this is the safety net). */
    @IsTest
    static void apiLeadsForAnExistingCustomerAreRefusedToo() {
        insert new Account(Name = 'Bose Household', Phone = '9830012344');
        RestContext.request = new RestRequest();

        Test.startTest();
        Database.SaveResult result = Database.insert(
            new Lead(LastName = 'Bose', Company = 'Bose Traders', Phone = '9830012344'),
            false
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Refused like any other insert');
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

    @IsTest
    static void tellsASystemCompanyFromATypedOne() {
        Assert.isTrue(LeadTriggerHandler.isSystemCompany(null), 'Blank');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('Asha Mehta - B2C'), 'The New Lead screen default');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('Asha Mehta - B2C-000123 '), 'Stamped with the Lead Number');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('asha mehta - b2c-7'), 'Any case');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('Asha Mehta B2C (000123)'), 'The B2C format');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('Asha Mehta Family (000123)'), 'The earlier Family format');
        Assert.isFalse(LeadTriggerHandler.isSystemCompany('Mehta B2C Jewellers'), 'Mentions B2C in a typed name');
        Assert.isFalse(LeadTriggerHandler.isSystemCompany('Mehta Family Jewellers'), 'Mentions Family but typed');
        Assert.isFalse(LeadTriggerHandler.isSystemCompany('Mehta Jewellers Pvt Ltd'), 'Typed by a user');
        Assert.isFalse(LeadTriggerHandler.isSystemCompany('B2C Retail - B2C Store'), 'Mentions B2C but typed');
    }

    @IsTest
    static void listsEveryAccountWithThePhoneOrEmail() {
        Account byPhone = new Account(Name = 'Iyer Household', Phone = '+91 98300 12388');
        Account byContact = new Account(Name = 'Iyer Traders');
        Account unrelated = new Account(Name = 'Other Household', Phone = '9830099999');
        insert new List<Account>{ byPhone, byContact, unrelated };
        insert new Contact(LastName = 'Iyer', AccountId = byContact.Id, Email = 'iyer@matcher.example.com');

        Test.startTest();
        LeadTriggerHandler.CheckResult result = checkOne('9830012388', 'iyer@matcher.example.com');
        Test.stopTest();

        Assert.areEqual(2, result.matchingAccountCount, 'The phone match and the Contact email match');
        Set<Id> found = new Map<Id, Account>(result.matchingAccounts).keySet();
        Assert.isTrue(found.contains(byPhone.Id), 'The Account with the phone in another format');
        Assert.isTrue(found.contains(byContact.Id), 'The Account of the Contact with the email');
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

    // =====================================================================
    // Existing customer known only as a Contact: an Account is created
    // =====================================================================

    private static Contact contactWithoutAccount(String phone) {
        Contact person = new Contact(
            FirstName = 'Asha',
            LastName = 'Mehta',
            MobilePhone = phone,
            Email = 'asha@contact.example.com',
            Birthdate = Date.newInstance(1990, 4, 12),
            Marital_Status__c = 'Married',
            Anniversary_Date__c = Date.newInstance(2015, 2, 1),
            MailingCity = 'Kolkata',
            Description = 'Prefers gold.'
        );
        insert person;
        return person;
    }

    private static LeadTriggerHandler.CheckResult checkAndCreateAccount(Lead details) {
        LeadTriggerHandler.CheckRequest request = new LeadTriggerHandler.CheckRequest();
        request.phone = details.Phone;
        request.email = details.Email;
        request.createCustomerAccount = true;
        request.leadRecord = details;
        return LeadTriggerHandler.check(new List<LeadTriggerHandler.CheckRequest>{ request })[0];
    }

    @IsTest
    static void aContactWithoutAnAccountIsReportedWithoutCreatingOne() {
        Contact person = contactWithoutAccount('9830012366');

        Test.startTest();
        LeadTriggerHandler.CheckResult result = checkOne('+91 98300 12366', null);
        Test.stopTest();

        Assert.isTrue(result.isExistingCustomer, 'The Contact is a customer');
        Assert.areEqual(person.Id, result.contactId, 'The Contact is identified');
        Assert.isNull(result.accountId, 'No Account yet');
        Assert.areEqual('Asha Mehta', result.accountName, 'Named after the person');
        Assert.areEqual(UserInfo.getUserId(), result.caseOwnerId, 'The enquiry would go to the current user');
        Assert.areEqual(0, [SELECT COUNT() FROM Account], 'Only checking creates nothing');
    }

    @IsTest
    static void aContactWithoutAnAccountGetsAFamilyAccountWhenTheEnquiryIsRaised() {
        Contact person = contactWithoutAccount('9830012366');
        Lead details = new Lead(
            FirstName = 'Asha',
            LastName = 'Mehta',
            Phone = '+91 98300 12366',
            Company = 'Asha Mehta - B2C',
            Description = 'Diamond earrings'
        );

        Test.startTest();
        LeadTriggerHandler.CheckResult result = checkAndCreateAccount(details);
        Test.stopTest();

        Account created = [
            SELECT Id, Name, Business_Type__c, OwnerId, Phone, Email__c, Date_of_Birth__c, Marital_Status__c,
                   Anniversary_Date__c, BillingCity, Description
            FROM Account
        ];
        Assert.areEqual('Asha Mehta Family', created.Name, 'Named as on conversion for B2C');
        Assert.areEqual('B2C', created.Business_Type__c, 'B2C');
        Assert.areEqual(UserInfo.getUserId(), created.OwnerId, 'Owned by the user raising the enquiry');
        Assert.areEqual('+91 98300 12366', created.Phone, 'Phone from the Lead, as entered');
        Assert.areEqual('asha@contact.example.com', created.Email__c, 'Email from the Contact: none on the Lead');
        Assert.areEqual(Date.newInstance(1990, 4, 12), created.Date_of_Birth__c, 'Date of Birth from the Contact');
        Assert.areEqual('Married', created.Marital_Status__c, 'Marital Status from the Contact');
        Assert.areEqual(Date.newInstance(2015, 2, 1), created.Anniversary_Date__c, 'With its Anniversary Date');
        Assert.areEqual('Kolkata', created.BillingCity, 'Address from the Contact: none on the Lead');
        Assert.areEqual('Diamond earrings', created.Description, 'Description from the Lead');

        Assert.areEqual(created.Id, [SELECT AccountId FROM Contact WHERE Id = :person.Id].AccountId,
            'The Contact is moved under its new Account');
        Assert.areEqual(created.Id, result.accountId, 'Reported with the new Account');
        Assert.areEqual('Asha Mehta Family', result.accountName, 'And its name');
        Assert.areEqual(person.Id, result.contactId, 'The same Contact');
        Assert.areEqual(UserInfo.getUserId(), result.caseOwnerId, 'The enquiry goes to the Account owner');
        Assert.areEqual(1, [SELECT COUNT() FROM Loyalty_Record__c WHERE Account__c = :created.Id],
            'A new Account gets its Loyalty Record as usual');
    }

    @IsTest
    static void theLeadsDetailsWinOverTheContacts() {
        Contact person = contactWithoutAccount('9830012366');
        Lead details = new Lead(
            FirstName = 'Rohit',
            LastName = 'Mehta',
            Phone = '9830012366',
            Email = 'rohit@lead.example.com',
            Company = 'Mehta Jewellers',
            Date_of_Birth__c = Date.newInstance(1988, 9, 30),
            Marital_Status__c = 'Unmarried',
            City = 'Howrah',
            Website = 'https://mehta.example.com'
        );

        Test.startTest();
        checkAndCreateAccount(details);
        Test.stopTest();

        Account created = [
            SELECT Name, Business_Type__c, Email__c, Date_of_Birth__c, Marital_Status__c, Anniversary_Date__c,
                   BillingCity, Website, Description
            FROM Account
        ];
        Assert.areEqual('Mehta Jewellers', created.Name, 'A typed Company names the Account, as on conversion');
        Assert.areEqual('B2B', created.Business_Type__c, 'B2B');
        Assert.areEqual('rohit@lead.example.com', created.Email__c, 'Email from the Lead');
        Assert.areEqual(Date.newInstance(1988, 9, 30), created.Date_of_Birth__c, 'Date of Birth from the Lead');
        Assert.areEqual('Unmarried', created.Marital_Status__c, 'Marital Status from the Lead');
        Assert.isNull(created.Anniversary_Date__c, 'Not the Contact\'s Anniversary Date with the Lead\'s status');
        Assert.areEqual('Howrah', created.BillingCity, 'Address from the Lead');
        Assert.areEqual('https://mehta.example.com', created.Website, 'Website from the Lead');
        Assert.areEqual('Prefers gold.', created.Description, 'Description from the Contact: none on the Lead');
    }

    @IsTest
    static void oneAccountPerContactAndExistingAccountsAreLeftAlone() {
        Contact person = contactWithoutAccount('9830012366');
        Account household = new Account(Name = 'Bose Household');
        insert household;

        LeadTriggerHandler.Customer first = new LeadTriggerHandler.Customer();
        first.contactId = person.Id;
        first.accountName = 'Asha Mehta';
        LeadTriggerHandler.Customer second = new LeadTriggerHandler.Customer();
        second.contactId = person.Id;
        second.accountName = 'Asha Mehta';
        LeadTriggerHandler.Customer withAccount = new LeadTriggerHandler.Customer();
        withAccount.accountId = household.Id;
        withAccount.accountName = 'Bose Household';

        Test.startTest();
        Map<Integer, String> failures = LeadTriggerHandler.createCustomerAccounts(
            new List<Lead>{
                new Lead(FirstName = 'Asha', LastName = 'Mehta', Phone = '9830012366'),
                new Lead(FirstName = 'Rohit', LastName = 'Mehta', Phone = '9830012366'),
                new Lead(LastName = 'Bose', Phone = '9830012355'),
                new Lead(LastName = 'Nobody', Phone = '9830012311')
            },
            new List<LeadTriggerHandler.Customer>{ first, second, withAccount, null }
        );
        Test.stopTest();

        Assert.isTrue(failures.isEmpty(), 'No failures: ' + failures);
        Assert.areEqual(2, [SELECT COUNT() FROM Account], 'One new Account for the one Contact');
        Assert.isNotNull(first.accountId, 'Given an Account');
        Assert.areEqual(first.accountId, second.accountId, 'The same Account for the same Contact');
        Assert.areEqual('Asha Mehta Family', first.accountName, 'Built from the first Lead');
        Assert.areEqual(household.Id, withAccount.accountId, 'A customer with an Account keeps it');
    }

    @IsTest
    static void aContactPlacedUnderAnAccountMeanwhileKeepsIt() {
        Contact person = contactWithoutAccount('9830012366');
        LeadTriggerHandler.Customer customer = new LeadTriggerHandler.Customer();
        customer.contactId = person.Id;
        Account household = new Account(Name = 'Mehta Household');
        insert household;
        update new Contact(Id = person.Id, AccountId = household.Id);

        Test.startTest();
        Map<Integer, String> failures = LeadTriggerHandler.createCustomerAccounts(
            new List<Lead>{ new Lead(LastName = 'Mehta', Phone = '9830012366') },
            new List<LeadTriggerHandler.Customer>{ customer }
        );
        Test.stopTest();

        Assert.isTrue(failures.isEmpty(), 'No failures: ' + failures);
        Assert.areEqual(household.Id, customer.accountId, 'The Account it now has');
        Assert.areEqual('Mehta Household', customer.accountName, 'And its name');
        Assert.areEqual(1, [SELECT COUNT() FROM Account], 'No new Account');
    }

    @IsTest
    static void aDeletedContactIsReported() {
        Contact person = contactWithoutAccount('9830012366');
        LeadTriggerHandler.Customer customer = new LeadTriggerHandler.Customer();
        customer.contactId = person.Id;
        delete person;

        Test.startTest();
        Map<Integer, String> failures = LeadTriggerHandler.createCustomerAccounts(
            new List<Lead>{ new Lead(LastName = 'Mehta', Phone = '9830012366') },
            new List<LeadTriggerHandler.Customer>{ customer }
        );
        Test.stopTest();

        Assert.areEqual('The customer\'s Contact no longer exists.', failures.get(0), 'Explained');
        Assert.isNull(customer.accountId, 'No Account');
        Assert.areEqual(0, [SELECT COUNT() FROM Account], 'Nothing created');
    }

    // =====================================================================
    // Changing a Lead's phone or email
    // =====================================================================

    /** The trigger's reason for refusing the change (it comes before any duplicate rule's). */
    private static Database.Error onlyError(Database.SaveResult result) {
        Assert.isFalse(result.isSuccess(), 'The change is refused');
        return result.getErrors()[0];
    }

    @IsTest
    static void changingThePhoneToACustomersIsRefused() {
        insert new Account(Name = 'Sen Household', Phone = '9830012341');
        Lead leadRecord = new Lead(LastName = 'Sen', Phone = '9830012342');
        insert leadRecord;

        Test.startTest();
        Database.SaveResult result = Database.update(new Lead(Id = leadRecord.Id, Phone = '+91 98300 12341'), false);
        Test.stopTest();

        Database.Error error = onlyError(result);
        Assert.areEqual(new List<String>{ 'Phone' }, error.getFields(), 'Shown on Phone');
        Assert.areEqual(
            'This phone belongs to an existing customer: Sen Household. Raise an enquiry (Case) for that customer instead.',
            error.getMessage(), 'Names the customer'
        );
        Assert.areEqual('9830012342', reload(leadRecord.Id).Phone, 'The old phone is kept');
    }

    @IsTest
    static void changingTheEmailToACustomerKnownOnlyAsAContactIsRefused() {
        insert new Contact(FirstName = 'Asha', LastName = 'Mehta', Email = 'asha@contact.example.com');
        Lead leadRecord = new Lead(LastName = 'Mehta', Phone = '9830012342', Email = 'old@lead.example.com');
        insert leadRecord;

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Lead(Id = leadRecord.Id, Email = 'ASHA@contact.example.com'), false
        );
        Test.stopTest();

        Database.Error error = onlyError(result);
        Assert.areEqual(new List<String>{ 'Email' }, error.getFields(), 'Shown on Email');
        Assert.isTrue(error.getMessage().contains('existing customer: Asha Mehta'), error.getMessage());
    }

    @IsTest
    static void changingThePhoneToAnotherOpenLeadsIsRefusedInAnyFormat() {
        Lead other = new Lead(LastName = 'Roy', Phone = '+91 98300 12343');
        Lead leadRecord = new Lead(LastName = 'Das', Phone = '9830012344');
        insert new List<Lead>{ other, leadRecord };

        Test.startTest();
        Database.SaveResult result = Database.update(new Lead(Id = leadRecord.Id, Phone = '9830012343'), false);
        Test.stopTest();

        Database.Error error = onlyError(result);
        Assert.areEqual(new List<String>{ 'Phone' }, error.getFields(), 'Shown on Phone');
        Assert.isTrue(error.getMessage().startsWith('A Lead with this phone already exists: Roy'), error.getMessage());
    }

    @IsTest
    static void retypingTheSamePhoneOrEditingOtherFieldsIsNotStopped() {
        Lead leadRecord = new Lead(LastName = 'Ghosh', Phone = '9830012345', Email = 'ghosh@lead.example.com');
        insert leadRecord;
        // The person became a customer after the Lead was made.
        insert new Account(Name = 'Ghosh Household', Phone = '9830012345', Email__c = 'ghosh@lead.example.com');

        Test.startTest();
        Database.SaveResult result = Database.update(new Lead(
            Id = leadRecord.Id,
            Phone = '+91 98300 12345',
            Email = 'GHOSH@lead.example.com',
            Description = 'Silver anklets'
        ), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'The same phone and email, only written differently: ' + result.getErrors());
        Assert.areEqual('+91 98300 12345', reload(leadRecord.Id).Phone, 'Saved as entered');
    }

    @IsTest
    static void twoLeadsCannotTakeTheSameNewPhoneInOneSave() {
        Lead first = new Lead(LastName = 'Pal', Phone = '9830012346');
        Lead second = new Lead(LastName = 'Bose', Phone = '9830012347');
        insert new List<Lead>{ first, second };

        Test.startTest();
        List<Database.SaveResult> results = Database.update(new List<Lead>{
            new Lead(Id = first.Id, Phone = '9830012348'),
            new Lead(Id = second.Id, Phone = '+91 98300 12348')
        }, false);
        Test.stopTest();

        Assert.isTrue(results[0].isSuccess(), 'The first takes it: ' + results[0].getErrors());
        Assert.areEqual('Another Lead in this save has the same phone.', onlyError(results[1]).getMessage(),
            'The second is refused');
    }

    // =====================================================================
    // WhatsApp Number (Lead and Contact: MobilePhone; Account: WhatsApp_Number__c)
    // =====================================================================

    @IsTest
    static void aLeadWhoseWhatsAppIsACustomersNumberIsRefused() {
        insert new List<Account>{
            new Account(Name = 'Das Household', WhatsApp_Number__c = '+91 98300 22001'),
            new Account(Name = 'Basu Household', Phone = '9830022002')
        };

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(new List<Lead>{
            new Lead(LastName = 'Das', Phone = '9830022011', MobilePhone = '9830022001'),
            new Lead(LastName = 'Basu', Phone = '9830022012', MobilePhone = '98300-22002'),
            new Lead(LastName = 'Free', Phone = '9830022013', MobilePhone = '9830022014')
        }, false);
        Test.stopTest();

        Assert.isFalse(results[0].isSuccess(), 'WhatsApp = an Account\'s WhatsApp Number');
        Assert.isTrue(results[0].getErrors()[0].getMessage().contains('Das Household'), results[0].getErrors()[0].getMessage());
        Assert.isFalse(results[1].isSuccess(), 'WhatsApp = an Account\'s Phone');
        Assert.isTrue(results[2].isSuccess(), 'A new number: ' + results[2].getErrors());
    }

    @IsTest
    static void aLeadWhosePhoneIsACustomersWhatsAppIsRefused() {
        insert new Account(Name = 'Sen Household', WhatsApp_Number__c = '9830022003');

        Test.startTest();
        Database.SaveResult result = Database.insert(new Lead(LastName = 'Sen', Phone = '+91 98300 22003'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Phone = an Account\'s WhatsApp Number');
    }

    @IsTest
    static void anInvalidWhatsAppNumberIsRefusedAndABlankOneIsFine() {
        Test.startTest();
        Database.SaveResult invalid = Database.insert(new Lead(LastName = 'Bad', Phone = '9830022004', MobilePhone = '12345'), false);
        Database.SaveResult blank = Database.insert(new Lead(LastName = 'Blank', Phone = '9830022005'), false);
        Test.stopTest();

        Assert.isFalse(invalid.isSuccess(), 'Not 10 digits');
        Assert.areEqual('WhatsApp Number must be a 10-digit number, optionally starting with +91 or 91.',
            invalid.getErrors()[0].getMessage(), 'Explained');
        Assert.isTrue(blank.isSuccess(), 'WhatsApp Number is optional: ' + blank.getErrors());
    }

    @IsTest
    static void theCheckMatchesTheWhatsAppNumberAgainstEveryStoredNumber() {
        Account household = new Account(Name = 'Paul Household', WhatsApp_Number__c = '9830022006');
        insert household;
        Lead openLead = new Lead(LastName = 'Roy', Phone = '9830022007', MobilePhone = '+91 98300 22008');
        insert openLead;

        Test.startTest();
        LeadTriggerHandler.CheckRequest byAccountWhatsApp = new LeadTriggerHandler.CheckRequest();
        byAccountWhatsApp.phone = '9830022099';
        byAccountWhatsApp.whatsApp = '98300 22006';
        LeadTriggerHandler.CheckRequest byLeadWhatsApp = new LeadTriggerHandler.CheckRequest();
        byLeadWhatsApp.phone = '9830022008';
        List<LeadTriggerHandler.CheckResult> results = LeadTriggerHandler.check(
            new List<LeadTriggerHandler.CheckRequest>{ byAccountWhatsApp, byLeadWhatsApp }
        );
        Test.stopTest();

        Assert.isTrue(results[0].isExistingCustomer, 'WhatsApp = the Account\'s WhatsApp Number');
        Assert.areEqual(household.Id, results[0].accountId, 'That Account');
        Assert.areEqual(1, results[0].matchingAccountCount, 'Listed for conversion');
        Assert.isTrue(results[1].isOpenLead, 'Phone = an open Lead\'s WhatsApp Number');
        Assert.areEqual(openLead.Id, results[1].openLeadId, 'That Lead');
    }

    @IsTest
    static void changingTheWhatsAppNumberToATakenOneIsRefused() {
        insert new Account(Name = 'Kar Household', Phone = '9830022009');
        Lead other = new Lead(LastName = 'Other', Phone = '9830022010');
        Lead leadRecord = new Lead(LastName = 'Kar', Phone = '9830022015');
        insert new List<Lead>{ other, leadRecord };

        Test.startTest();
        Database.SaveResult toCustomer = Database.update(new Lead(Id = leadRecord.Id, MobilePhone = '+91 98300 22009'), false);
        Database.SaveResult toOtherLead = Database.update(new Lead(Id = leadRecord.Id, MobilePhone = '9830022010'), false);
        Database.SaveResult toOwnPhone = Database.update(new Lead(Id = leadRecord.Id, MobilePhone = '98300 22015'), false);
        Test.stopTest();

        Assert.isFalse(toCustomer.isSuccess(), 'A customer\'s phone');
        Assert.areEqual(new List<String>{ 'MobilePhone' }, toCustomer.getErrors()[0].getFields(), 'Shown on WhatsApp Number');
        Assert.isTrue(toCustomer.getErrors()[0].getMessage().startsWith('This WhatsApp number belongs to an existing customer: Kar Household'),
            toCustomer.getErrors()[0].getMessage());
        Assert.isFalse(toOtherLead.isSuccess(), 'Another open Lead\'s phone');
        Assert.isTrue(toOwnPhone.isSuccess(), 'Its own phone as WhatsApp is fine: ' + toOwnPhone.getErrors());
    }

    @IsTest
    static void aContactOnlyCustomersNewAccountGetsTheWhatsAppNumber() {
        Contact withWhatsApp = new Contact(LastName = 'Ali', Phone = '9830022016', MobilePhone = '9830022017');
        Contact plain = new Contact(LastName = 'Bose', Phone = '9830022018');
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Database.insert(new List<Contact>{ withWhatsApp, plain }, options);

        LeadTriggerHandler.Customer fromContact = new LeadTriggerHandler.Customer();
        fromContact.contactId = withWhatsApp.Id;
        LeadTriggerHandler.Customer fromLead = new LeadTriggerHandler.Customer();
        fromLead.contactId = plain.Id;

        Test.startTest();
        Map<Integer, String> failures = LeadTriggerHandler.createCustomerAccounts(
            new List<Lead>{
                new Lead(LastName = 'Ali', Phone = '9830022016'),
                new Lead(LastName = 'Bose', Phone = '9830022018', MobilePhone = '9830022019')
            },
            new List<LeadTriggerHandler.Customer>{ fromContact, fromLead }
        );
        Test.stopTest();

        Assert.isTrue(failures.isEmpty(), 'No failures: ' + failures);
        Assert.areEqual('9830022017', [SELECT WhatsApp_Number__c FROM Account WHERE Id = :fromContact.accountId].WhatsApp_Number__c,
            'The Contact\'s, as the Lead has none');
        Assert.areEqual('9830022019', [SELECT WhatsApp_Number__c FROM Account WHERE Id = :fromLead.accountId].WhatsApp_Number__c,
            'The Lead\'s first');
    }
}
