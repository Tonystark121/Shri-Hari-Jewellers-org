/**
 * Tests for LeadConversionTransactionService: a Lead converts only together with
 * its first bill, into a new Account or into the existing customer's Account,
 * all or nothing.
 */
@IsTest
private class LeadConversionTransactionServiceTest {

    private static Integer counter = 0;

    // =====================================================================
    // Helpers
    // =====================================================================

    /** A B2C enquiry with its own phone and email. */
    private static Lead enquiry(String firstName, String lastName) {
        counter++;
        String suffix = String.valueOf(counter).leftPad(4, '0');
        return new Lead(
            FirstName = firstName,
            LastName = lastName,
            Phone = '987650' + suffix,
            Email = 'convert' + suffix + '@customer.example.com'
        );
    }

    private static Transaction_Record__c bill(String billNumber, Decimal amount) {
        return new Transaction_Record__c(
            Bill_Number__c = billNumber,
            Amount__c = amount,
            Transaction_Date__c = Datetime.now()
        );
    }

    private static LeadConversionTransactionService.ConvertRequest request(Id leadId, String accountName, Transaction_Record__c bill) {
        LeadConversionTransactionService.ConvertRequest conversionRequest = new LeadConversionTransactionService.ConvertRequest();
        conversionRequest.leadId = leadId;
        conversionRequest.accountName = accountName;
        conversionRequest.bill = bill;
        return conversionRequest;
    }

    private static LeadConversionTransactionService.ConvertResult convertOne(Id leadId, String accountName, Transaction_Record__c bill) {
        return LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ request(leadId, accountName, bill) }
        )[0];
    }

    private static Lead reload(Id leadId) {
        return [
            SELECT IsConverted, Status, ConvertedAccountId, ConvertedContactId, ConvertedOpportunityId
            FROM Lead
            WHERE Id = :leadId
            WITH SYSTEM_MODE
        ];
    }

    // =====================================================================
    // New customer
    // =====================================================================

    /** A new customer gets an Account (named "<Name> Family (<Lead Number>)"), a Contact and the bill, and the Lead converts. */
    @IsTest
    static void aNewCustomerGetsAnAccountContactAndBill() {
        Lead walkIn = enquiry('Asha', 'Mehta');
        walkIn.Date_of_Birth__c = Date.newInstance(1990, 8, 25);
        insert walkIn;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(walkIn.Id, null, bill('CTS-0001', 5000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.isFalse(result.isExistingCustomer, 'A new customer');

        Lead converted = reload(walkIn.Id);
        Assert.isTrue(converted.IsConverted, 'The Lead is converted');
        Assert.areEqual('Converted', converted.Status, 'With the converted status');
        Assert.areEqual(result.accountId, converted.ConvertedAccountId, 'Into the new Account');
        Assert.areEqual(result.contactId, converted.ConvertedContactId, 'With a Contact');
        Assert.isNull(converted.ConvertedOpportunityId, 'No Opportunity');

        Account customer = [
            SELECT Name, Phone, Email__c, Business_Type__c, Date_of_Birth__c
            FROM Account WHERE Id = :result.accountId WITH SYSTEM_MODE
        ];
        String leadNumber = [SELECT Lead_Number__c FROM Lead WHERE Id = :walkIn.Id WITH SYSTEM_MODE].Lead_Number__c;
        Assert.areEqual('Asha Mehta Family (' + leadNumber + ')', customer.Name, 'Named after the family');
        Assert.areEqual(walkIn.Phone, customer.Phone, 'Phone carried over');
        Assert.areEqual(walkIn.Email, customer.Email__c, 'Email carried over');
        Assert.areEqual('B2C', customer.Business_Type__c, 'Business Type carried over');
        Assert.areEqual(walkIn.Date_of_Birth__c, customer.Date_of_Birth__c, 'Personal details carried over');

        Transaction_Record__c saved = [
            SELECT Account__c, Bill_Number__c FROM Transaction_Record__c WHERE Id = :result.transactionId WITH SYSTEM_MODE
        ];
        Assert.areEqual(result.accountId, saved.Account__c, 'The bill is on the new Account');
    }

    /** A B2B Lead's Account is named after the company. */
    @IsTest
    static void aBusinessAccountIsNamedAfterTheCompany() {
        Lead business = enquiry('Rakesh', 'Agarwal');
        business.Company = 'Agarwal Jewellers Pvt Ltd';
        business.Business_Type__c = 'B2B';
        insert business;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(business.Id, '  ', bill('CTS-0002', 12000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('Agarwal Jewellers Pvt Ltd', result.accountName, 'Company name for a business');
    }

    /** A B2C Lead's Account takes the Lead's Company, "<Name> Family (<Lead Number>)". */
    @IsTest
    static void aB2cAccountIsNamedAfterTheFamily() {
        Lead person = enquiry('Asha', 'Mehta');
        insert person;
        Lead saved = [SELECT Company, Lead_Number__c FROM Lead WHERE Id = :person.Id WITH SYSTEM_MODE];
        Assert.areEqual('Asha Mehta Family (' + saved.Lead_Number__c + ')', saved.Company, 'The trigger gave the Lead a system Company');

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(person.Id, null, bill('CTS-0015', 1000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual(saved.Company, result.accountName, 'Same as the Lead Company');
    }

    /** A Lead that still holds the earlier "<Name> - B2C-<number>" Company also gets a "<Name> Family (<number>)" Account. */
    @IsTest
    static void anEarlierFormatLeadGetsAFamilyAccount() {
        Lead person = enquiry('Kiran', 'Rao');
        person.Company = 'Placeholder';
        insert person;
        String leadNumber = [SELECT Lead_Number__c FROM Lead WHERE Id = :person.Id WITH SYSTEM_MODE].Lead_Number__c;
        // Recreate a Lead from before the change: B2C with the earlier Company.
        update new Lead(Id = person.Id, Business_Type__c = 'B2C', Company = 'Kiran Rao - B2C-' + leadNumber);

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(person.Id, null, bill('CTS-0016', 1000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('Kiran Rao Family (' + leadNumber + ')', result.accountName, 'The new format');
    }

    /** A name typed on the screen wins. */
    @IsTest
    static void theAccountNameEnteredIsUsed() {
        Lead walkIn = enquiry('Ravi', 'Shah');
        insert walkIn;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(walkIn.Id, 'Shah Family', bill('CTS-0003', 900));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('Shah Family', [SELECT Name FROM Account WHERE Id = :result.accountId WITH SYSTEM_MODE].Name, 'Typed name used');
    }

    /** The first bill of a new customer earns loyalty points in the same save. */
    @IsTest
    static void theFirstBillEarnsLoyaltyPoints() {
        Lead walkIn = enquiry('Neha', 'Jain');
        insert walkIn;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(walkIn.Id, null, bill('CTS-0004', 5000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual(
            100,
            [SELECT Points_Balance__c FROM Loyalty_Record__c WHERE Account__c = :result.accountId WITH SYSTEM_MODE].Points_Balance__c,
            '5,000 at Silver 2% is 100 points'
        );
    }

    // =====================================================================
    // Existing customer
    // =====================================================================

    /** The Lead's phone belongs to an existing customer: the bill goes on that Account and the Lead converts into it. */
    @IsTest
    static void anExistingCustomersBillGoesOnTheirAccount() {
        Lead returning = enquiry('Pooja', 'Nair');
        insert returning;
        Account household = new Account(Name = 'Nair Household', Phone = '+91-' + returning.Phone);
        insert household;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(returning.Id, 'Ignored', bill('CTS-0005', 3000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.isTrue(result.isExistingCustomer, 'Recognised as an existing customer');
        Assert.areEqual(household.Id, result.accountId, 'The existing Account is used');
        Assert.areEqual('Nair Household', result.accountName, 'Its name is kept');
        Assert.areEqual(1, [SELECT COUNT() FROM Account], 'No second Account is created');
        Assert.areEqual(household.Id, reload(returning.Id).ConvertedAccountId, 'The Lead converts into it');
        Assert.areEqual(
            household.Id,
            [SELECT Account__c FROM Transaction_Record__c WHERE Id = :result.transactionId WITH SYSTEM_MODE].Account__c,
            'And the bill is on it'
        );
    }

    /** A Contact with the Lead's name, phone and email is reused instead of a second Contact being created. */
    @IsTest
    static void aMatchingContactIsReused() {
        Lead returning = enquiry('Sanjay', 'Gupta');
        insert returning;
        Account household = new Account(Name = 'Gupta Household');
        insert household;
        Contact person = new Contact(
            FirstName = 'sanjay',
            LastName = 'Gupta',
            AccountId = household.Id,
            Phone = '+91 ' + returning.Phone,
            Email = returning.Email.toUpperCase()
        );
        // The org's Contact duplicate rule alerts on the matching Lead; save anyway.
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Database.insert(person, options);

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(returning.Id, null, bill('CTS-0006', 3000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual(person.Id, result.contactId, 'The existing Contact is used');
        Assert.areEqual(1, [SELECT COUNT() FROM Contact], 'No second Contact');
    }

    /**
     * Of several matching customers, the one picked on the screen gets the
     * bill. Its Contact with the same phone is another person, so the Lead
     * gets a new Contact on that Account.
     */
    @IsTest
    static void thePickedAccountIsUsed() {
        Lead returning = enquiry('Meera', 'Iyer');
        insert returning;
        Account picked = new Account(Name = 'Iyer Household', Phone = returning.Phone);
        Account other = new Account(Name = 'Iyer Traders', Phone = '+91-' + returning.Phone);
        insert new List<Account>{ picked, other };
        Contact person = new Contact(LastName = 'Iyer', AccountId = picked.Id, MobilePhone = '+91 ' + returning.Phone);
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Database.insert(person, options);

        LeadConversionTransactionService.ConvertRequest conversionRequest = request(returning.Id, null, bill('CTS-0012', 4000));
        conversionRequest.accountId = picked.Id;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.isTrue(result.isExistingCustomer, 'An existing customer');
        Assert.areEqual(picked.Id, result.accountId, 'The picked Account is used');
        Assert.areNotEqual(person.Id, result.contactId, 'The other person is not reused');
        Assert.areEqual(2, [SELECT COUNT() FROM Account], 'No new Account');

        Contact created = [
            SELECT AccountId, FirstName, LastName, Phone, Email FROM Contact WHERE Id = :result.contactId WITH SYSTEM_MODE
        ];
        Assert.areEqual(picked.Id, created.AccountId, 'The new Contact is on the picked Account');
        Assert.areEqual('Meera', created.FirstName, 'With the Lead name');
        Assert.areEqual('Iyer', created.LastName, 'With the Lead name');
        Assert.areEqual(returning.Phone, created.Phone, 'With the Lead phone');
        Assert.areEqual(returning.Email, created.Email, 'With the Lead email');
    }

    /** Same name and phone but a different email is another person: a new Contact. */
    @IsTest
    static void aDifferentEmailGetsANewContact() {
        Lead returning = enquiry('Aparna', 'Gupta');
        insert returning;
        Account household = new Account(Name = 'Gupta Family');
        insert household;
        Contact other = new Contact(
            FirstName = 'Aparna',
            LastName = 'Gupta',
            AccountId = household.Id,
            Phone = returning.Phone,
            Email = 'someone.else@customer.example.com'
        );
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Database.insert(other, options);

        LeadConversionTransactionService.ConvertRequest conversionRequest = request(returning.Id, null, bill('CTS-0017', 2500));
        conversionRequest.accountId = household.Id;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areNotEqual(other.Id, result.contactId, 'A new Contact');
        Assert.areEqual(2, [SELECT COUNT() FROM Contact WHERE AccountId = :household.Id], 'Both on the household');
    }

    /** A value blank on both sides counts as the same; blank on one side does not. */
    @IsTest
    static void tellsTheSamePerson() {
        Lead leadRecord = new Lead(FirstName = 'Ravi', LastName = 'Shah', Phone = '98300 12345');
        Contact samePerson = new Contact(FirstName = ' ravi ', LastName = 'SHAH', MobilePhone = '+91-9830012345');
        Contact withEmail = new Contact(FirstName = 'Ravi', LastName = 'Shah', Phone = '9830012345', Email = 'ravi@customer.example.com');
        Contact otherPhone = new Contact(FirstName = 'Ravi', LastName = 'Shah', Phone = '9830099999');

        Assert.isTrue(LeadConversionTransactionService.isSamePerson(samePerson, leadRecord), 'Case, spaces and phone format ignored');
        Assert.isFalse(LeadConversionTransactionService.isSamePerson(withEmail, leadRecord), 'Email only on the Contact');
        Assert.isFalse(LeadConversionTransactionService.isSamePerson(otherPhone, leadRecord), 'Different phone');
    }

    /**
     * Points POS reports on the conversion bill come off the picked customer's
     * balance; more than they hold rejects the conversion with the reason.
     */
    @IsTest
    static void pointsRedeemedOnTheConversionBillAreRecorded() {
        Lead returning = enquiry('Kavya', 'Rao');
        insert returning;
        Account household = new Account(Name = 'Rao Household', Phone = returning.Phone);
        insert household;
        Loyalty_Record__c loyalty = [SELECT Id FROM Loyalty_Record__c WHERE Account__c = :household.Id WITH SYSTEM_MODE];
        loyalty.Points_Balance__c = 300;
        update as system loyalty;
        insert as system new Loyalty_Transaction__c(
            Loyalty_Record__c = loyalty.Id,
            Transaction_Type__c = 'Earn',
            Status__c = 'Active',
            Points_Earned__c = 300,
            Remaining_Points__c = 300,
            Credit_Date__c = Date.today().addDays(-10),
            Expiry_Date__c = Date.today().addDays(355)
        );

        Transaction_Record__c tooMany = bill('CTS-0016', 5000);
        tooMany.Points_Redeemed__c = 500;
        LeadConversionTransactionService.ConvertRequest rejected = request(returning.Id, null, tooMany);
        rejected.accountId = household.Id;
        LeadConversionTransactionService.ConvertResult refused = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ rejected }
        )[0];
        Assert.isFalse(refused.isSuccess, 'More points than the customer holds');
        Assert.isTrue(refused.errorMessage.startsWith('The bill was not saved: Points Redeemed (500)'), refused.errorMessage);
        Assert.isFalse(reload(returning.Id).IsConverted, 'Nothing is converted');

        Transaction_Record__c withPoints = bill('CTS-0017', 5000);
        withPoints.Points_Redeemed__c = 200;
        LeadConversionTransactionService.ConvertRequest accepted = request(returning.Id, null, withPoints);
        accepted.accountId = household.Id;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ accepted }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual(
            4800,
            [SELECT Net_Amount__c FROM Transaction_Record__c WHERE Id = :result.transactionId WITH SYSTEM_MODE].Net_Amount__c,
            '5,000 - 200 points'
        );
        Assert.areEqual(
            200,
            [SELECT Total_Points_Redeemed__c FROM Loyalty_Record__c WHERE Id = :loyalty.Id WITH SYSTEM_MODE].Total_Points_Redeemed__c,
            'The 200 came off the balance'
        );
    }

    /** A new customer's Account gets the product description too. */
    @IsTest
    static void aNewAccountGetsTheProductDescription() {
        Lead buyer = enquiry('Nisha', 'Kapoor');
        buyer.Description = 'Diamond ring, budget 80,000';
        insert buyer;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(buyer.Id, null, bill('CTS-0020', 80000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Account saved = [SELECT Description, Email__c, Business_Type__c FROM Account WHERE Id = :result.accountId WITH SYSTEM_MODE];
        Assert.areEqual('Diamond ring, budget 80,000', saved.Description, 'Product description on the Account');
        Assert.areEqual(buyer.Email, saved.Email__c, 'Email on the Account');
        Assert.areEqual('B2C', saved.Business_Type__c, 'Business Type on the Account');
    }

    /** A picked Account's blank Email, Business Type ("Unknown") and Description are filled from the Lead. */
    @IsTest
    static void anExistingAccountsBlankDetailsAreFilled() {
        Lead buyer = enquiry('Tara', 'Bhat');
        buyer.Description = 'Gold bangles';
        insert buyer;
        Account household = new Account(Name = 'Bhat Household', Phone = buyer.Phone, Business_Type__c = 'Unknown');
        insert household;

        LeadConversionTransactionService.ConvertRequest conversionRequest = request(buyer.Id, null, bill('CTS-0021', 2000));
        conversionRequest.accountId = household.Id;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Account saved = [SELECT Name, Phone, Email__c, Business_Type__c, Description FROM Account WHERE Id = :household.Id WITH SYSTEM_MODE];
        Assert.areEqual(buyer.Email, saved.Email__c, 'Blank Email filled');
        Assert.areEqual('B2C', saved.Business_Type__c, 'Unknown replaced');
        Assert.areEqual('Gold bangles', saved.Description, 'Blank Description filled');
        Assert.areEqual('Bhat Household', saved.Name, 'Name kept');
    }

    /** Values already on a picked Account are never overwritten. */
    @IsTest
    static void anExistingAccountsValuesAreKept() {
        Lead buyer = enquiry('Vikram', 'Sen');
        buyer.Description = 'Silver anklet';
        insert buyer;
        Account household = new Account(
            Name = 'Sen Traders', Phone = buyer.Phone, Email__c = 'accounts@sentraders.example',
            Business_Type__c = 'B2B', Description = 'Wholesale buyer'
        );
        insert household;

        LeadConversionTransactionService.ConvertRequest conversionRequest = request(buyer.Id, null, bill('CTS-0022', 2000));
        conversionRequest.accountId = household.Id;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Account saved = [SELECT Email__c, Business_Type__c, Description FROM Account WHERE Id = :household.Id WITH SYSTEM_MODE];
        Assert.areEqual('accounts@sentraders.example', saved.Email__c, 'Email kept');
        Assert.areEqual('B2B', saved.Business_Type__c, 'Business Type kept');
        Assert.areEqual('Wholesale buyer', saved.Description, 'Description kept');
    }

    /** Staff can create a new customer even when the phone and email match one. */
    @IsTest
    static void aNewAccountCanBeCreatedDespiteAMatch() {
        Lead newPerson = enquiry('Arjun', 'Iyer');
        insert newPerson;
        Account household = new Account(Name = 'Arjun Iyer', Phone = newPerson.Phone, Email__c = newPerson.Email);
        insert household;
        Contact relative = new Contact(LastName = 'Iyer', AccountId = household.Id, Email = newPerson.Email);
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Database.insert(relative, options);

        LeadConversionTransactionService.ConvertRequest conversionRequest = request(newPerson.Id, null, bill('CTS-0013', 2000));
        conversionRequest.accountId = household.Id;
        conversionRequest.createNewAccount = true;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.isFalse(result.isExistingCustomer, 'A new customer');
        Assert.areNotEqual(household.Id, result.accountId, 'Create New wins over the Account Id');
        Assert.areEqual(2, [SELECT COUNT() FROM Account], 'A second Account, despite the same name, phone and email');
        Assert.areNotEqual(relative.Id, result.contactId, 'With its own Contact');
    }

    /** The screen sends an empty Account Id when nothing matched: it means a new customer, not an error. */
    @IsTest
    static void anEmptyAccountIdCreatesANewCustomer() {
        Lead walkIn = enquiry('Ananya', 'Sharma');
        insert walkIn;
        LeadConversionTransactionService.ConvertRequest conversionRequest = request(walkIn.Id, null, bill('CTS-0018', 5000));
        conversionRequest.accountId = '';
        conversionRequest.createNewAccount = true;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.isFalse(result.isExistingCustomer, 'A new customer');
    }

    /** Text that is not an Account Id is reported like a missing Account. */
    @IsTest
    static void anInvalidAccountIdIsRefused() {
        Lead walkIn = enquiry('Rohan', 'Das');
        insert walkIn;
        LeadConversionTransactionService.ConvertRequest conversionRequest = request(walkIn.Id, null, bill('CTS-0019', 5000));
        conversionRequest.accountId = 'not-an-id';

        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];

        Assert.isFalse(result.isSuccess, 'Refused');
        Assert.areEqual('The selected customer Account could not be found. It may have been deleted.', result.errorMessage, 'Says why');
    }

    /** A picked Account deleted in the meantime is reported and nothing is saved. */
    @IsTest
    static void aDeletedPickedAccountIsRefused() {
        Lead returning = enquiry('Ravi', 'Menon');
        insert returning;
        Account gone = new Account(Name = 'Menon Household', Phone = returning.Phone);
        insert gone;
        LeadConversionTransactionService.ConvertRequest conversionRequest = request(returning.Id, null, bill('CTS-0014', 1500));
        conversionRequest.accountId = gone.Id;
        delete gone;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isFalse(result.isSuccess, 'Refused');
        Assert.areEqual('The selected customer Account could not be found. It may have been deleted.', result.errorMessage, 'Says why');
        Assert.isFalse(reload(returning.Id).IsConverted, 'The Lead is not converted');
        Assert.areEqual(0, [SELECT COUNT() FROM Transaction_Record__c], 'No bill');
    }

    // =====================================================================
    // Nothing is saved when a step fails
    // =====================================================================

    /** A bill that cannot be saved leaves no Account behind and the Lead unconverted. */
    @IsTest
    static void aRejectedBillRollsEverythingBack() {
        Account earlierCustomer = new Account(Name = 'Earlier Customer');
        insert earlierCustomer;
        Transaction_Record__c earlier = bill('CTS-TAKEN', 800);
        earlier.Account__c = earlierCustomer.Id;
        insert earlier;
        Lead walkIn = enquiry('Kiran', 'Rao');
        insert walkIn;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(walkIn.Id, 'Rao Household', bill('CTS-TAKEN', 2500));
        Test.stopTest();

        Assert.isFalse(result.isSuccess, 'A duplicate Bill Number cannot be saved');
        Assert.isTrue(result.errorMessage.contains('CTS-TAKEN'), 'The message names the bill: ' + result.errorMessage);
        Assert.isFalse(reload(walkIn.Id).IsConverted, 'The Lead stays unconverted');
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name = 'Rao Household'], 'The new Account is rolled back');
    }

    /** A Lead converts once. */
    @IsTest
    static void anAlreadyConvertedLeadIsRefused() {
        Lead walkIn = enquiry('Manoj', 'Verma');
        insert walkIn;
        Assert.isTrue(convertOne(walkIn.Id, null, bill('CTS-0007', 900)).isSuccess, 'First conversion succeeds');

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(walkIn.Id, null, bill('CTS-0008', 900));
        Test.stopTest();

        Assert.isFalse(result.isSuccess, 'Second conversion refused');
        Assert.areEqual('This Lead is already converted.', result.errorMessage, 'With a plain reason');
        Assert.areEqual(0, [SELECT COUNT() FROM Transaction_Record__c WHERE Bill_Number__c = 'CTS-0008'], 'Second bill not saved');
    }

    /** Standard conversion (Convert dialog, Path, API) is refused. */
    @IsTest
    static void standardConversionIsRefused() {
        Lead walkIn = enquiry('Farah', 'Khan');
        insert walkIn;
        Database.LeadConvert conversion = new Database.LeadConvert();
        conversion.setLeadId(walkIn.Id);
        conversion.setDoNotCreateOpportunity(true);
        conversion.setConvertedStatus('Converted');

        Test.startTest();
        Database.LeadConvertResult result = Database.convertLead(conversion, false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Refused');
        Assert.isTrue(
            result.getErrors()[0].getMessage().contains('converted only when the customer buys'),
            result.getErrors()[0].getMessage()
        );
        Assert.isFalse(reload(walkIn.Id).IsConverted, 'The Lead stays unconverted');
    }

    // =====================================================================
    // Many Leads at once
    // =====================================================================

    /** One Lead's failure does not stop the others. */
    @IsTest
    static void aFailedLeadDoesNotBlockTheOthers() {
        Account earlierCustomer = new Account(Name = 'Earlier Customer');
        insert earlierCustomer;
        Transaction_Record__c earlier = bill('CTS-USED', 800);
        earlier.Account__c = earlierCustomer.Id;
        insert earlier;

        List<Lead> enquiries = new List<Lead>();
        for (Integer i = 0; i < 5; i++) {
            enquiries.add(enquiry('Bulk', 'Buyer ' + i));
        }
        insert enquiries;

        List<LeadConversionTransactionService.ConvertRequest> requests = new List<LeadConversionTransactionService.ConvertRequest>();
        for (Integer i = 0; i < enquiries.size(); i++) {
            requests.add(request(enquiries[i].Id, null, bill(i == 2 ? 'CTS-USED' : 'CTS-BULK-' + i, 1000)));
        }

        Test.startTest();
        List<LeadConversionTransactionService.ConvertResult> results = LeadConversionTransactionService.convertWithBill(requests);
        Test.stopTest();

        for (Integer i = 0; i < results.size(); i++) {
            if (i == 2) {
                Assert.isFalse(results[i].isSuccess, 'The Lead with the used bill number fails');
            } else {
                Assert.isTrue(results[i].isSuccess, 'Lead ' + i + ' converts: ' + results[i].errorMessage);
            }
        }
        Assert.areEqual(4, [SELECT COUNT() FROM Lead WHERE Id IN :enquiries AND IsConverted = true], 'Four converted');
        Assert.areEqual(4, [SELECT COUNT() FROM Account WHERE Name LIKE 'Bulk Buyer%'], 'Four Accounts; the failed one is rolled back');
    }
}
