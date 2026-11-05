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

    /** A new customer gets an Account (named "<Surname> Family (<First Name>)"), a Contact and the bill, and the Lead converts. */
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
        Assert.areEqual('Mehta Family (Asha)', customer.Name, 'Named after the family');
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

    /** A B2C Lead ("<Name> B2C (<Lead Number>)") gets a "<Surname> Family (<First Name>)" Account, without the Lead Number. */
    @IsTest
    static void aB2cAccountIsNamedAfterTheFamily() {
        Lead person = enquiry('Asha', 'Mehta');
        insert person;
        Lead saved = [SELECT Company, Lead_Number__c FROM Lead WHERE Id = :person.Id WITH SYSTEM_MODE];
        Assert.areEqual('Asha Mehta B2C (' + saved.Lead_Number__c + ')', saved.Company, 'The trigger gave the Lead a system Company');

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(person.Id, null, bill('CTS-0015', 1000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('Mehta Family (Asha)', result.accountName, 'Surname, Family, first name');
    }

    /** Leads that still hold an earlier system Company also get a "<Surname> Family (<First Name>)" Account. */
    @IsTest
    static void earlierFormatLeadsGetAFamilyAccount() {
        Lead dashFormat = enquiry('Kiran', 'Rao');
        dashFormat.Company = 'Placeholder';
        Lead familyFormat = enquiry('Meera', 'Iyer');
        familyFormat.Company = 'Placeholder';
        insert new List<Lead>{ dashFormat, familyFormat };
        Map<Id, Lead> saved = new Map<Id, Lead>([
            SELECT Lead_Number__c FROM Lead WHERE Id IN (:dashFormat.Id, :familyFormat.Id) WITH SYSTEM_MODE
        ]);
        // Recreate Leads from before the change: B2C with the earlier Companies.
        update new List<Lead>{
            new Lead(Id = dashFormat.Id, Business_Type__c = 'B2C',
                Company = 'Kiran Rao - B2C-' + saved.get(dashFormat.Id).Lead_Number__c),
            new Lead(Id = familyFormat.Id, Business_Type__c = 'B2C',
                Company = 'Meera Iyer Family (' + saved.get(familyFormat.Id).Lead_Number__c + ')')
        };

        Test.startTest();
        List<LeadConversionTransactionService.ConvertResult> results = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{
                request(dashFormat.Id, null, bill('CTS-0016', 1000)),
                request(familyFormat.Id, null, bill('CTS-0040', 1000))
            }
        );
        Test.stopTest();

        Assert.isTrue(results[0].isSuccess, 'Conversion should succeed: ' + results[0].errorMessage);
        Assert.isTrue(results[1].isSuccess, 'Conversion should succeed: ' + results[1].errorMessage);
        Assert.areEqual('Rao Family (Kiran)', results[0].accountName, 'From "<Name> - B2C-<number>"');
        Assert.areEqual('Iyer Family (Meera)', results[1].accountName, 'From "<Name> Family (<number>)"');
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
     * The new Contact gets the Lead's Date of Birth (as Birthdate),
     * Anniversary Date and Marital Status - on a new Account and on a picked
     * existing one, where the Account keeps its own values.
     */
    @IsTest
    static void aNewContactGetsThePersonalDetails() {
        Lead newCustomer = enquiry('Asha', 'Mehta');
        Lead familyMember = enquiry('Rohan', 'Mehta');
        for (Lead person : new List<Lead>{ newCustomer, familyMember }) {
            person.Date_of_Birth__c = Date.newInstance(1990, 8, 25);
            person.Marital_Status__c = 'Married';
            person.Anniversary_Date__c = Date.newInstance(2015, 2, 14);
        }
        familyMember.Date_of_Birth__c = Date.newInstance(1988, 1, 5);
        insert new List<Lead>{ newCustomer, familyMember };
        Account household = new Account(Name = 'Mehta Family', Date_of_Birth__c = Date.newInstance(1960, 3, 1));
        insert household;

        LeadConversionTransactionService.ConvertRequest toHousehold = request(familyMember.Id, null, bill('CTS-0030', 2000));
        toHousehold.accountId = household.Id;

        Test.startTest();
        List<LeadConversionTransactionService.ConvertResult> results = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{
                request(newCustomer.Id, null, bill('CTS-0029', 1000)),
                toHousehold
            }
        );
        Test.stopTest();

        for (Integer i = 0; i < results.size(); i++) {
            Assert.isTrue(results[i].isSuccess, 'Conversion should succeed: ' + results[i].errorMessage);
            Lead person = i == 0 ? newCustomer : familyMember;
            Contact created = [
                SELECT Birthdate, Anniversary_Date__c, Marital_Status__c FROM Contact WHERE Id = :results[i].contactId WITH SYSTEM_MODE
            ];
            Assert.areEqual(person.Date_of_Birth__c, created.Birthdate, 'Date of Birth carried over');
            Assert.areEqual(person.Anniversary_Date__c, created.Anniversary_Date__c, 'Anniversary Date carried over');
            Assert.areEqual('Married', created.Marital_Status__c, 'Marital Status carried over');
        }
        Assert.areEqual(
            Date.newInstance(1960, 3, 1),
            [SELECT Date_of_Birth__c FROM Account WHERE Id = :household.Id WITH SYSTEM_MODE].Date_of_Birth__c,
            'The existing Account keeps its value'
        );
    }

    /** A Contact the Lead merges into (same name, phone and email) is left as it is. */
    @IsTest
    static void aMergedContactKeepsItsDetails() {
        Lead returning = enquiry('Sanjay', 'Gupta');
        returning.Date_of_Birth__c = Date.newInstance(1985, 6, 10);
        returning.Marital_Status__c = 'Married';
        insert returning;
        Account household = new Account(Name = 'Gupta Household');
        insert household;
        Contact person = new Contact(
            FirstName = 'Sanjay',
            LastName = 'Gupta',
            AccountId = household.Id,
            Phone = returning.Phone,
            Email = returning.Email,
            Birthdate = Date.newInstance(1985, 6, 11)
        );
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Database.insert(person, options);

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(returning.Id, null, bill('CTS-0031', 3000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual(person.Id, result.contactId, 'Merged into the existing Contact');
        Contact merged = [SELECT Birthdate, Marital_Status__c FROM Contact WHERE Id = :person.Id WITH SYSTEM_MODE];
        Assert.areEqual(Date.newInstance(1985, 6, 11), merged.Birthdate, 'Its Birthdate is kept');
        Assert.isNull(merged.Marital_Status__c, 'Nothing is filled in');
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

    /** Values already on a picked Account are never overwritten; the Lead's Description is added on a new line. */
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
        Assert.areEqual('Wholesale buyer\nSilver anklet', saved.Description, 'Lead Description added on a new line');
    }

    /** Two Leads converting into the same Account in one call both add their Description. */
    @IsTest
    static void everyLeadsDescriptionIsAdded() {
        Lead first = enquiry('Uma', 'Rao');
        first.Description = 'Gold chain';
        Lead second = enquiry('Uday', 'Rao');
        second.Description = 'Diamond ring';
        insert new List<Lead>{ first, second };
        Account household = new Account(Name = 'Rao Family', Description = 'Regular customer', Business_Type__c = 'B2C');
        insert household;

        LeadConversionTransactionService.ConvertRequest firstRequest = request(first.Id, null, bill('CTS-0031', 1000));
        firstRequest.accountId = household.Id;
        LeadConversionTransactionService.ConvertRequest secondRequest = request(second.Id, null, bill('CTS-0032', 2000));
        secondRequest.accountId = household.Id;

        Test.startTest();
        List<LeadConversionTransactionService.ConvertResult> results = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ firstRequest, secondRequest }
        );
        Test.stopTest();

        Assert.isTrue(results[0].isSuccess, 'First conversion should succeed: ' + results[0].errorMessage);
        Assert.isTrue(results[1].isSuccess, 'Second conversion should succeed: ' + results[1].errorMessage);
        Account saved = [SELECT Name, Description FROM Account WHERE Id = :household.Id WITH SYSTEM_MODE];
        Assert.areEqual('Regular customer\nGold chain\nDiamond ring', saved.Description, 'Each on its own line, in order');
        Assert.areEqual('Rao Family (Uma, Uday)', saved.Name, 'Both first names added to the family, in order');
        Assert.areEqual(saved.Name, results[1].accountName, 'The result shows the new name');
    }

    // =====================================================================
    // Family Account name
    // =====================================================================

    /** A B2C Lead merged into the family Account it was picked for adds its name. */
    @IsTest
    static void aMergedLeadsNameIsAddedToThePickedFamily() {
        Lead familyMember = enquiry('Rohit', 'Mehta');
        insert familyMember;
        Account household = new Account(Name = 'Asha Mehta Family', Business_Type__c = 'B2C');
        insert household;
        LeadConversionTransactionService.ConvertRequest conversionRequest = request(familyMember.Id, null, bill('CTS-0041', 1500));
        conversionRequest.accountId = household.Id;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('Mehta Family (Asha, Rohit)',
            [SELECT Name FROM Account WHERE Id = :household.Id WITH SYSTEM_MODE].Name, 'First name added, surname once');
        Assert.areEqual('Mehta Family (Asha, Rohit)', result.accountName, 'The result shows the new name');
    }

    /** The same happens when the family Account is found by the Lead's phone. */
    @IsTest
    static void aMatchedLeadsNameIsAddedToTheFamily() {
        Lead returning = enquiry('Vikram', 'Rao');
        insert returning;
        Account household = new Account(Name = 'Sunita Rao Family', Phone = returning.Phone, Business_Type__c = 'B2C');
        insert household;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(returning.Id, null, bill('CTS-0042', 1500));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual(household.Id, result.accountId, 'The matched Account is used');
        Assert.areEqual('Rao Family (Sunita, Vikram)', result.accountName, 'First name added');
    }

    /** A person already named in the family is not added again. */
    @IsTest
    static void aNameAlreadyInTheFamilyIsNotAddedAgain() {
        Lead familyMember = enquiry('Rohit', 'Mehta');
        insert familyMember;
        Account household = new Account(Name = 'Mehta Family (Asha, Rohit)', Business_Type__c = 'B2C');
        insert household;
        LeadConversionTransactionService.ConvertRequest conversionRequest = request(familyMember.Id, null, bill('CTS-0043', 1500));
        conversionRequest.accountId = household.Id;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('Mehta Family (Asha, Rohit)', result.accountName, 'Name unchanged');
    }

    /** A B2B Lead into a B2C family Account leaves the name as it is. */
    @IsTest
    static void aBusinessLeadLeavesTheNameAsItIs() {
        Lead business = enquiry('Rakesh', 'Mehta');
        business.Company = 'Mehta Jewellers';
        business.Business_Type__c = 'B2B';
        insert business;
        Account household = new Account(Name = 'Asha Mehta Family', Business_Type__c = 'B2C');
        insert household;
        LeadConversionTransactionService.ConvertRequest conversionRequest = request(business.Id, null, bill('CTS-0044', 1500));
        conversionRequest.accountId = household.Id;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('Asha Mehta Family', result.accountName, 'Name unchanged for a business Lead');
    }

    /** The naming rule itself. */
    @IsTest
    static void familyNameRules() {
        // A new family: the surname once, then the first name.
        Assert.areEqual('Mehta Family (Asha)', LeadConversionTransactionService.familyAccountName(' Asha ', ' Mehta '), 'Surname, then first name');
        Assert.areEqual('Mehta Family (Asha)', LeadConversionTransactionService.familyAccountName(null, 'Asha  Mehta'), 'Full name in Last Name is split');
        Assert.areEqual('Sharma Family (R K)', LeadConversionTransactionService.familyAccountName('', 'R K Sharma'), 'Its last word is the surname');
        Assert.areEqual('De Souza Family (Anup)', LeadConversionTransactionService.familyAccountName('Anup', 'De Souza'), 'Last Name as typed when there is a First Name');
        Assert.areEqual('Ali Family', LeadConversionTransactionService.familyAccountName(null, 'Ali'), 'No first name');

        // One more member.
        Assert.areEqual('Sharma Family (Anup, Suman)',
            LeadConversionTransactionService.familyAccountNameWith('Sharma Family (Anup)', 'Suman', 'Sharma'), 'Same surname: first name only');
        Assert.areEqual('Sharma Family (Anup, Suman, Neha Kapoor)',
            LeadConversionTransactionService.familyAccountNameWith('Sharma Family (Anup, Suman)', 'Neha', 'Kapoor'), 'Another surname: full name');
        Assert.areEqual('sharma Family (Anup, suman)',
            LeadConversionTransactionService.familyAccountNameWith('sharma family  (Anup)', null, 'suman sharma'), 'Any case, extra spaces, split name');
        Assert.areEqual('Ali Family (Riya)',
            LeadConversionTransactionService.familyAccountNameWith('Ali Family', 'Riya', 'Ali'), 'A first name for a family without one');
        Assert.isNull(LeadConversionTransactionService.familyAccountNameWith('Sharma Family (Anup, Suman)', 'suman', 'SHARMA'), 'Already listed, any case');
        Assert.isNull(LeadConversionTransactionService.familyAccountNameWith('Sharma Family (Anup)', null, 'Sharma'), 'No first name to add');
        Assert.isNull(LeadConversionTransactionService.familyAccountNameWith('Sharma Family (Anup)', ' ', ' '), 'No person');

        // Earlier names are rewritten in the new form.
        Assert.areEqual('Mehta Family (Asha, Rohit)',
            LeadConversionTransactionService.familyAccountNameWith('Asha Mehta Family', 'Rohit', 'Mehta'), 'Earlier one-person name');
        Assert.areEqual('sinha Family (raj, aman, Neha)',
            LeadConversionTransactionService.familyAccountNameWith('raj sinha & aman sinha Family', 'Neha', 'Sinha'), 'Earlier "&" name');
        Assert.areEqual('Mehta Family (Asha, Rohit)',
            LeadConversionTransactionService.familyAccountNameWith('Asha Mehta Family (000123)', 'Rohit', 'Mehta'), 'Earlier name with a Lead Number');

        // Kept as it is.
        Assert.isNull(LeadConversionTransactionService.familyAccountNameWith('Nair Household', 'Pooja', 'Nair'), 'Not a family name');
        Assert.isNull(LeadConversionTransactionService.familyAccountNameWith('Family', 'Rohit', 'Mehta'), 'No surname');
        Assert.isNull(LeadConversionTransactionService.familyAccountNameWith('', 'Rohit', 'Mehta'), 'Blank name');
        String longFamily = 'Mehta Family (' + 'A'.repeat(240) + ')';
        Assert.isNull(LeadConversionTransactionService.familyAccountNameWith(longFamily, 'Rohit', 'Mehta'), 'Over 255 characters');
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

    /**
     * Standard conversion (Convert dialog, Path, API) is refused.
     *
     * Set aside (no @IsTest) while the update section of LeadTrigger is
     * commented out in UAT, as the block it checks is in that section. Put
     * @IsTest back when the trigger's update section is switched on again.
     */
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
        Assert.areEqual(4, [SELECT COUNT() FROM Account WHERE Name LIKE 'Buyer % Family (Bulk)'], 'Four Accounts; the failed one is rolled back');
    }

    // =====================================================================
    // WhatsApp Number (Lead and Contact: the standard Mobile field; Account: WhatsApp_Number__c)
    // =====================================================================

    /** A new customer's Account and Contact carry the Lead's WhatsApp Number. */
    @IsTest
    static void aNewCustomerGetsTheWhatsAppNumber() {
        Lead buyer = enquiry('Meena', 'Rao');
        buyer.MobilePhone = '+91 98765 51234';
        insert buyer;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(buyer.Id, null, bill('CTS-W001', 2000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('+91 98765 51234',
            [SELECT WhatsApp_Number__c FROM Account WHERE Id = :result.accountId WITH SYSTEM_MODE].WhatsApp_Number__c,
            'On the Account, as typed');
        Assert.areEqual('+91 98765 51234',
            [SELECT MobilePhone FROM Contact WHERE Id = :result.contactId WITH SYSTEM_MODE].MobilePhone,
            'On the Contact, as typed');
    }

    /** A picked Account's blank WhatsApp Number is filled; one it already has is kept. */
    @IsTest
    static void anExistingAccountsWhatsAppNumberIsFilledOnlyWhenBlank() {
        Lead first = enquiry('Kavya', 'Iyer');
        first.MobilePhone = '9876551235';
        Lead second = enquiry('Arjun', 'Pillai');
        second.MobilePhone = '9876551236';
        insert new List<Lead>{ first, second };
        Account blank = new Account(Name = 'Iyer Household', Phone = first.Phone);
        Account kept = new Account(Name = 'Pillai Household', Phone = second.Phone, WhatsApp_Number__c = '9000000001');
        insert new List<Account>{ blank, kept };

        LeadConversionTransactionService.ConvertRequest toBlank = request(first.Id, null, bill('CTS-W002', 1000));
        toBlank.accountId = blank.Id;
        LeadConversionTransactionService.ConvertRequest toKept = request(second.Id, null, bill('CTS-W003', 1000));
        toKept.accountId = kept.Id;

        Test.startTest();
        List<LeadConversionTransactionService.ConvertResult> results = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ toBlank, toKept }
        );
        Test.stopTest();

        Assert.isTrue(results[0].isSuccess && results[1].isSuccess, 'Both convert: ' + results);
        Assert.areEqual('9876551235', [SELECT WhatsApp_Number__c FROM Account WHERE Id = :blank.Id WITH SYSTEM_MODE].WhatsApp_Number__c, 'Blank filled');
        Assert.areEqual('9000000001', [SELECT WhatsApp_Number__c FROM Account WHERE Id = :kept.Id WITH SYSTEM_MODE].WhatsApp_Number__c, 'Existing kept');
    }

    /** With nothing picked, a customer whose Phone is the Lead's WhatsApp Number is matched. */
    @IsTest
    static void theCustomerIsMatchedByTheLeadsWhatsAppNumber() {
        Lead returning = enquiry('Nisha', 'Ghosh');
        returning.MobilePhone = '98765 51237';
        insert returning;
        // Became a customer after the enquiry, with the WhatsApp number saved as the phone.
        Account household = new Account(Name = 'Ghosh Household', Phone = '9876551237');
        insert household;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(returning.Id, null, bill('CTS-W004', 1000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual(household.Id, result.accountId, 'Matched by WhatsApp Number');
        Assert.areEqual(1, [SELECT COUNT() FROM Account], 'No second Account');
    }

    // =====================================================================
    // Account names: same Business Type merges, across types does not
    // =====================================================================

    private static LeadConversionTransactionService.ConvertResult convertInto(Id leadId, Id accountId, String billNumber) {
        LeadConversionTransactionService.ConvertRequest conversionRequest = request(leadId, null, bill(billNumber, 1500));
        conversionRequest.accountId = accountId;
        return LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
    }

    /** A B2B Lead into a B2B Account adds the person: "test user" + Rakesh Jain = "test user & Rakesh Jain". */
    @IsTest
    static void aBusinessLeadsNameIsAddedToABusinessAccount() {
        Lead business = enquiry('Rakesh', 'Jain');
        business.Company = 'Jain Exports Pvt Ltd';
        business.Business_Type__c = 'B2B';
        insert business;
        Account company = new Account(Name = 'test user', Business_Type__c = 'B2B');
        insert company;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertInto(business.Id, company.Id, 'CTS-B001');
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('test user & Rakesh Jain', [SELECT Name FROM Account WHERE Id = :company.Id WITH SYSTEM_MODE].Name, 'Person added');
        Assert.areEqual('test user & Rakesh Jain', result.accountName, 'The result shows the new name');
    }

    /** A person already in a B2B Account's name is not added again, whatever the case. */
    @IsTest
    static void aNameAlreadyInTheBusinessAccountIsNotAddedAgain() {
        Lead business = enquiry('Rakesh', 'Jain');
        business.Company = 'Jain Exports Pvt Ltd';
        business.Business_Type__c = 'B2B';
        insert business;
        Account company = new Account(Name = 'test user & rakesh jain', Business_Type__c = 'B2B');
        insert company;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertInto(business.Id, company.Id, 'CTS-B002');
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('test user & rakesh jain', result.accountName, 'Name unchanged');
    }

    /** A B2C Lead into a B2B Account leaves the name as it is, even one ending in Family. */
    @IsTest
    static void aB2cLeadLeavesABusinessAccountsNameAsItIs() {
        Lead person = enquiry('Priya', 'Shah');
        insert person;
        Account company = new Account(Name = 'Shah Family', Business_Type__c = 'B2B');
        insert company;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertInto(person.Id, company.Id, 'CTS-B003');
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('Shah Family', result.accountName, 'Name unchanged across types');
    }

    /** An Account whose Business Type is Unknown keeps its name, for B2B and B2C Leads alike. */
    @IsTest
    static void anAccountOfUnknownTypeKeepsItsName() {
        Lead business = enquiry('Rakesh', 'Jain');
        business.Company = 'Jain Exports Pvt Ltd';
        business.Business_Type__c = 'B2B';
        Lead person = enquiry('Asha', 'Mehta');
        insert new List<Lead>{ business, person };
        Account unknownCompany = new Account(Name = 'test user', Business_Type__c = 'Unknown');
        Account unknownFamily = new Account(Name = 'Rohit Mehta Family', Business_Type__c = 'Unknown');
        insert new List<Account>{ unknownCompany, unknownFamily };

        Test.startTest();
        LeadConversionTransactionService.ConvertResult toCompany = convertInto(business.Id, unknownCompany.Id, 'CTS-B004');
        LeadConversionTransactionService.ConvertResult toFamily = convertInto(person.Id, unknownFamily.Id, 'CTS-B005');
        Test.stopTest();

        Assert.areEqual('test user', toCompany.accountName, 'B2B Lead, Unknown Account: unchanged');
        Assert.areEqual('Rohit Mehta Family', toFamily.accountName, 'B2C Lead, Unknown Account: unchanged');
    }

    /** An older Lead with Business Type Unknown follows its Company: a typed Company is B2B. */
    @IsTest
    static void anUnknownTypeLeadFollowsItsCompany() {
        Lead olderLead = enquiry('Rohit', 'Sharma');
        olderLead.Company = 'Halsa Global';
        olderLead.Business_Type__c = 'Unknown';
        insert olderLead;
        Account company = new Account(Name = 'test user', Business_Type__c = 'B2B');
        insert company;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertInto(olderLead.Id, company.Id, 'CTS-B006');
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Assert.areEqual('test user & Rohit Sharma', result.accountName, 'Treated as B2B');
    }

    /** The B2B naming rule itself. */
    @IsTest
    static void businessNameRules() {
        Assert.areEqual('test user & Rakesh Jain',
            LeadConversionTransactionService.businessAccountNameWith(' test user ', ' Rakesh Jain '), 'Person added, trimmed');
        Assert.isNull(LeadConversionTransactionService.businessAccountNameWith('test user & Rakesh Jain', 'RAKESH JAIN'), 'Already named, any case');
        Assert.isNull(LeadConversionTransactionService.businessAccountNameWith(null, 'Rakesh Jain'), 'No name');
        Assert.isNull(LeadConversionTransactionService.businessAccountNameWith('test user', ' '), 'No person');
        Assert.isNull(LeadConversionTransactionService.businessAccountNameWith('x'.repeat(250), 'Rakesh Jain'), 'Over 255 characters');
    }

    // =====================================================================
    // WA / SMS / Email opt-ins
    // =====================================================================

    /** A new customer Account takes the Lead's three opt-ins. */
    @IsTest
    static void aNewAccountGetsTheLeadsOptIns() {
        Lead optedIn = enquiry('Anil', 'Singha');
        optedIn.WA_Opt_In__c = true;
        optedIn.SMS_Opt_In__c = true;
        optedIn.Email_Opt_In__c = false;
        insert optedIn;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = convertOne(optedIn.Id, null, bill('CTS-OPT1', 1000));
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Account saved = [SELECT WA_Opt_In__c, SMS_Opt_In__c, Email_Opt_In__c FROM Account WHERE Id = :result.accountId WITH SYSTEM_MODE];
        Assert.isTrue(saved.WA_Opt_In__c, 'WA Opt In copied');
        Assert.isTrue(saved.SMS_Opt_In__c, 'SMS Opt In copied');
        Assert.isFalse(saved.Email_Opt_In__c, 'Email Opt In copied (not opted in)');
    }

    /** Into an existing Account an opt-in is ticked when the Lead has it, and never unticked. */
    @IsTest
    static void anExistingAccountsOptInsAreTickedNeverUnticked() {
        Lead buyer = enquiry('Ravi', 'Kapoor');
        buyer.WA_Opt_In__c = true;
        buyer.SMS_Opt_In__c = false;
        buyer.Email_Opt_In__c = false;
        insert buyer;
        Account household = new Account(
            Name = 'Kapoor Household', Phone = buyer.Phone, Business_Type__c = 'B2C',
            WA_Opt_In__c = false, SMS_Opt_In__c = true, Email_Opt_In__c = false
        );
        insert household;
        LeadConversionTransactionService.ConvertRequest conversionRequest = request(buyer.Id, null, bill('CTS-OPT2', 1000));
        conversionRequest.accountId = household.Id;

        Test.startTest();
        LeadConversionTransactionService.ConvertResult result = LeadConversionTransactionService.convertWithBill(
            new List<LeadConversionTransactionService.ConvertRequest>{ conversionRequest }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isSuccess, 'Conversion should succeed: ' + result.errorMessage);
        Account saved = [SELECT WA_Opt_In__c, SMS_Opt_In__c, Email_Opt_In__c FROM Account WHERE Id = :household.Id WITH SYSTEM_MODE];
        Assert.isTrue(saved.WA_Opt_In__c, 'Ticked: the Lead opted in');
        Assert.isTrue(saved.SMS_Opt_In__c, 'Kept: the Lead did not opt in, the Account had');
        Assert.isFalse(saved.Email_Opt_In__c, 'Still off: neither opted in');
    }
}
