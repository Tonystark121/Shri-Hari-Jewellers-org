/**
 * Tests for LeadTriggerHandler: the B2C / B2B Company, the phone check, the
 * existing-customer block, changing a Lead's phone or email, and the
 * matching used by the New Lead flow (phone cleaning, existing customers,
 * open Leads).
 *
 * Duplicate open Leads are blocked by the Lead Duplicate Check duplicate
 * rule and are not tested here.
 *
 * The update-side rules (beforeUpdate) are tested by calling the handler
 * directly with in-memory Leads, so they are covered whether or not the
 * update section of LeadTrigger is switched on. The older tests that go
 * through real updates keep their "TODO: re-enable" assertions; search for
 * that text to find them.
 */
@IsTest
private class LeadTriggerHandlerTest {

    private static Integer idCounter = 1;

    // =====================================================================
    // Helpers
    // =====================================================================

    private static Lead reload(Id leadId) {
        return [
            SELECT FirstName, LastName, Company, Business_Type__c, Lead_Number__c, Phone, B2B_Lead__c
            FROM Lead
            WHERE Id = :leadId
            WITH SYSTEM_MODE
        ];
    }

    /** A well-formed Lead Id that does not exist in the database. */
    private static Id fakeLeadId() {
        String prefix = Lead.SObjectType.getDescribe().getKeyPrefix();
        return (Id) (prefix + String.valueOf(idCounter++).leftPad(12, '0'));
    }

    /** An in-memory Lead that may carry read-only fields (IsConverted, Lead_Number__c). */
    private static Lead leadWith(Map<String, Object> fields) {
        Map<String, Object> data = new Map<String, Object>(fields);
        data.put('attributes', new Map<String, Object>{ 'type' => 'Lead' });
        return (Lead) JSON.deserialize(JSON.serialize(data), Lead.class);
    }

    /** An in-memory Lead as it would be stored, with Lead Number 000123. */
    private static Lead personLead(Id leadId, String businessType, String first, String last, String company, Boolean b2bBox) {
        return leadWith(new Map<String, Object>{
            'Id' => leadId,
            'FirstName' => first,
            'LastName' => last,
            'Company' => company,
            'Business_Type__c' => businessType,
            'B2B_Lead__c' => b2bBox,
            'Lead_Number__c' => '000123',
            'IsConverted' => false
        });
    }

    /** An in-memory B2B Lead with a typed Company (its Company is never locked). */
    private static Lead typedLead(Id leadId, String phone, String whatsApp, String email) {
        return leadWith(new Map<String, Object>{
            'Id' => leadId,
            'LastName' => 'Typed',
            'Company' => 'Typed Traders',
            'Business_Type__c' => 'B2B',
            'IsConverted' => false,
            'Phone' => phone,
            'MobilePhone' => whatsApp,
            'Email' => email
        });
    }

    private static void runUpdate(Lead oldLead, Lead newLead) {
        LeadTriggerHandler.beforeUpdate(
            new List<Lead>{ newLead },
            new Map<Id, Lead>{ oldLead.Id => oldLead }
        );
    }

    private static List<String> messagesOf(Lead leadRecord) {
        List<String> messages = new List<String>();
        for (Database.Error error : leadRecord.getErrors()) {
            messages.add(error.getMessage());
        }
        return messages;
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
        // TODO: re-enable when the update section of LeadTrigger is switched on.
        // Assert.areEqual('Neha Jain Kapoor B2C (' + saved.Lead_Number__c + ')', saved.Company, 'Company follows the new name');
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

        // TODO: re-enable when the update section of LeadTrigger is switched on.
        // Assert.areEqual('Kiran Rao Menon - B2C-' + saved.Lead_Number__c, reload(walkIn.Id).Company, 'Kept in the earlier format');
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

        // TODO: re-enable when the update section of LeadTrigger is switched on.
        // Assert.areEqual('Meera Iyer Nair Family (' + saved.Lead_Number__c + ')', reload(walkIn.Id).Company, 'Kept in the Family format');
    }

    /** No one can change a B2C Company by hand. */
    @IsTest
    static void aB2cCompanyCannotBeChangedByHand() {
        Lead walkIn = new Lead(FirstName = 'Pooja', LastName = 'Nair');
        insert walkIn;

        Test.startTest();
        Database.SaveResult result = Database.update(new Lead(Id = walkIn.Id, Company = 'Something Else'), false);
        Test.stopTest();

        // TODO: re-enable when the update section of LeadTrigger is switched on.
        // Assert.isFalse(result.isSuccess(), 'The change is refused');
        // Assert.areEqual(LeadTriggerHandler.COMPANY_LOCKED, result.getErrors()[0].getMessage(), 'With a plain reason');
    }

    // =====================================================================
    // B2B Lead checkbox: insert
    // =====================================================================

    /** B2B Lead ticked and no Company: B2B, "<Name> B2B (<Lead Number>)". */
    @IsTest
    static void aB2bLeadWithoutACompanyGetsAB2bCompany() {
        Lead lead1 = new Lead(FirstName = 'Rohan', LastName = 'Gupta', B2B_Lead__c = true);

        Test.startTest();
        insert lead1;
        Test.stopTest();

        Lead saved = reload(lead1.Id);
        Assert.areEqual('B2B', saved.Business_Type__c, 'The box makes it B2B');
        Assert.areEqual('Rohan Gupta B2B (' + saved.Lead_Number__c + ')', saved.Company, 'Name, B2B and the Lead Number');
    }

    /** B2B Lead ticked with the New Lead screen's "- B2C" default: still B2B. */
    @IsTest
    static void aB2bLeadWithTheB2cScreenDefaultBecomesB2b() {
        Lead lead1 = new Lead(FirstName = 'Sunil', LastName = 'Das', Company = 'Sunil Das - B2C', B2B_Lead__c = true);

        Test.startTest();
        insert lead1;
        Test.stopTest();

        Lead saved = reload(lead1.Id);
        Assert.areEqual('B2B', saved.Business_Type__c, 'The box wins over the default');
        Assert.areEqual('Sunil Das B2B (' + saved.Lead_Number__c + ')', saved.Company, 'B2B format');
    }

    /** B2B Lead ticked with a "<Name> - B2B" default: completed with the Lead Number. */
    @IsTest
    static void aB2bLeadWithTheB2bDefaultIsCompletedWithTheLeadNumber() {
        Lead lead1 = new Lead(FirstName = 'Tara', LastName = 'Sen', Company = 'Tara Sen - B2B', B2B_Lead__c = true);

        Test.startTest();
        insert lead1;
        Test.stopTest();

        Lead saved = reload(lead1.Id);
        Assert.areEqual('B2B', saved.Business_Type__c, 'B2B');
        Assert.areEqual('Tara Sen B2B (' + saved.Lead_Number__c + ')', saved.Company, 'Lead Number added');
    }

    /** B2B Lead ticked with a typed Company: the Company is kept, the type is B2B. */
    @IsTest
    static void aB2bLeadWithATypedCompanyKeepsIt() {
        Lead lead1 = new Lead(LastName = 'Jain', Company = 'Jain Gems Pvt Ltd', B2B_Lead__c = true);

        Test.startTest();
        insert lead1;
        Test.stopTest();

        Lead saved = reload(lead1.Id);
        Assert.areEqual('B2B', saved.Business_Type__c, 'B2B');
        Assert.areEqual('Jain Gems Pvt Ltd', saved.Company, 'Untouched');
    }

    /** "- B2B" on a Lead without the box ticked is just a typed Company. */
    @IsTest
    static void aB2bSuffixWithoutTheBoxIsATypedCompany() {
        Lead lead1 = new Lead(FirstName = 'Ravi', LastName = 'Shah', Company = 'Ravi Shah - B2B');

        Test.startTest();
        insert lead1;
        Test.stopTest();

        Assert.areEqual('Ravi Shah - B2B', reload(lead1.Id).Company, 'Kept as typed');
    }

    /** B2C, B2B and typed Leads in one save each get the right Company. */
    @IsTest
    static void aMixedBulkSaveNamesEachLeadByItsOwnRule() {
        Lead b2c = new Lead(FirstName = 'Cara', LastName = 'One');
        Lead b2b = new Lead(FirstName = 'Beta', LastName = 'Two', B2B_Lead__c = true);
        Lead typed = new Lead(LastName = 'Three', Company = 'Three Traders');

        Test.startTest();
        insert new List<Lead>{ b2c, b2b, typed };
        Test.stopTest();

        Lead savedB2c = reload(b2c.Id);
        Lead savedB2b = reload(b2b.Id);
        Assert.areEqual('Cara One B2C (' + savedB2c.Lead_Number__c + ')', savedB2c.Company, 'B2C format');
        Assert.areEqual('Beta Two B2B (' + savedB2b.Lead_Number__c + ')', savedB2b.Company, 'B2B format');
        Assert.areEqual('Three Traders', reload(typed.Id).Company, 'Typed is kept');
    }

    // =====================================================================
    // Company helpers
    // =====================================================================
    @IsTest
    static void buildsEveryCompanyFormat() {
        Lead person = personLead(fakeLeadId(), 'B2C', 'Asha', 'Mehta', null, false);

        Assert.areEqual('Asha Mehta - B2C', LeadTriggerHandler.companyStem(person), 'B2C placeholder');
        Assert.areEqual('Asha Mehta - B2B', LeadTriggerHandler.b2bStem(person), 'B2B placeholder');
        Assert.areEqual('Asha Mehta B2C (000123)', LeadTriggerHandler.b2cCompany(person), 'B2C');
        Assert.areEqual('Asha Mehta B2B (000123)', LeadTriggerHandler.b2bCompany(person), 'B2B');
        Assert.areEqual('Asha Mehta Family (000123)', LeadTriggerHandler.familyB2cCompany(person), 'Family');
        Assert.areEqual('Asha Mehta - B2C-000123', LeadTriggerHandler.legacyB2cCompany(person), 'Earlier');
    }

    @IsTest
    static void buildsThePersonNameFromWhateverIsFilledIn() {
        Assert.areEqual('Asha Mehta', LeadTriggerHandler.personName(new Lead(FirstName = ' Asha ', LastName = ' Mehta ')), 'Both');
        Assert.areEqual('Mehta', LeadTriggerHandler.personName(new Lead(LastName = 'Mehta')), 'Last name only');
        Assert.areEqual('Asha', LeadTriggerHandler.personName(new Lead(FirstName = 'Asha')), 'First name only');
        Assert.areEqual('', LeadTriggerHandler.personName(new Lead()), 'Neither');
    }

    @IsTest
    static void tellsASystemCompanyFromATypedOne() {
        Assert.isTrue(LeadTriggerHandler.isSystemCompany(null), 'Blank');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('Asha Mehta - B2C'), 'The New Lead screen default');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('Asha Mehta - B2B'), 'The B2B default');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('Asha Mehta - B2C-000123 '), 'Stamped with the Lead Number');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('asha mehta - b2c-7'), 'Any case');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('Asha Mehta B2C (000123)'), 'The B2C format');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('Asha Mehta B2B (000123)'), 'The B2B format');
        Assert.isTrue(LeadTriggerHandler.isSystemCompany('Asha Mehta Family (000123)'), 'The earlier Family format');
        Assert.isFalse(LeadTriggerHandler.isSystemCompany('Mehta B2C Jewellers'), 'Mentions B2C in a typed name');
        Assert.isFalse(LeadTriggerHandler.isSystemCompany('Mehta B2B Jewellers'), 'Mentions B2B in a typed name');
        Assert.isFalse(LeadTriggerHandler.isSystemCompany('Mehta Family Jewellers'), 'Mentions Family but typed');
        Assert.isFalse(LeadTriggerHandler.isSystemCompany('Mehta Jewellers Pvt Ltd'), 'Typed by a user');
        Assert.isFalse(LeadTriggerHandler.isSystemCompany('B2C Retail - B2C Store'), 'Mentions B2C but typed');
    }

    // =====================================================================
    // B2B Lead checkbox and Company rules on update (handler called directly)
    // =====================================================================

    @IsTest
    static void tickingB2bOnASystemNamedLeadSwitchesItToTheB2bFormat() {
        Id leadId = fakeLeadId();
        Lead oldLead = personLead(leadId, 'B2C', 'Asha', 'Mehta', 'Asha Mehta B2C (000123)', false);
        Lead newLead = personLead(leadId, 'B2C', 'Asha', 'Mehta', 'Asha Mehta B2C (000123)', true);

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual('B2B', newLead.Business_Type__c, 'Now B2B');
        Assert.areEqual('Asha Mehta B2B (000123)', newLead.Company, 'In the B2B format');
        Assert.isTrue(messagesOf(newLead).isEmpty(), 'No error');
    }

    @IsTest
    static void tickingB2bOnATypedCompanyOnlyChangesTheType() {
        Id leadId = fakeLeadId();
        Lead oldLead = personLead(leadId, 'B2B', 'Asha', 'Mehta', 'Mehta Jewellers', false);
        Lead newLead = personLead(leadId, 'B2B', 'Asha', 'Mehta', 'Mehta Jewellers', true);
        newLead.Business_Type__c = null;

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual('B2B', newLead.Business_Type__c, 'B2B');
        Assert.areEqual('Mehta Jewellers', newLead.Company, 'The typed Company is kept');
    }

    @IsTest
    static void untickingB2bOnASystemNamedLeadSwitchesItBackToB2c() {
        Id leadId = fakeLeadId();
        Lead oldLead = personLead(leadId, 'B2B', 'Asha', 'Mehta', 'Asha Mehta B2B (000123)', true);
        Lead newLead = personLead(leadId, 'B2B', 'Asha', 'Mehta', 'Asha Mehta B2B (000123)', false);

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual('B2C', newLead.Business_Type__c, 'Back to B2C');
        Assert.areEqual('Asha Mehta B2C (000123)', newLead.Company, 'In the B2C format');
    }

    @IsTest
    static void untickingB2bOnATypedCompanyChangesNothing() {
        Id leadId = fakeLeadId();
        Lead oldLead = personLead(leadId, 'B2B', 'Asha', 'Mehta', 'Mehta Jewellers', true);
        Lead newLead = personLead(leadId, 'B2B', 'Asha', 'Mehta', 'Mehta Jewellers', false);

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual('B2B', newLead.Business_Type__c, 'Still B2B');
        Assert.areEqual('Mehta Jewellers', newLead.Company, 'Typed Company untouched');
    }

    @IsTest
    static void aSystemNamedCompanyCannotBeChangedByHand() {
        Id leadId = fakeLeadId();
        Lead oldLead = personLead(leadId, 'B2C', 'Asha', 'Mehta', 'Asha Mehta B2C (000123)', false);
        Lead newLead = personLead(leadId, 'B2C', 'Asha', 'Mehta', 'Something Else', false);

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual(new List<String>{ LeadTriggerHandler.COMPANY_LOCKED }, messagesOf(newLead), 'Refused with a plain reason');
    }

    @IsTest
    static void aSystemNamedB2bCompanyCannotBeChangedByHandEither() {
        Id leadId = fakeLeadId();
        Lead oldLead = personLead(leadId, 'B2B', 'Asha', 'Mehta', 'Asha Mehta B2B (000123)', true);
        Lead newLead = personLead(leadId, 'B2B', 'Asha', 'Mehta', 'Something Else', true);

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual(new List<String>{ LeadTriggerHandler.COMPANY_LOCKED }, messagesOf(newLead), 'Refused');
    }

    @IsTest
    static void aTypedB2bCompanyCanBeChangedByHand() {
        Id leadId = fakeLeadId();
        Lead oldLead = personLead(leadId, 'B2B', 'Asha', 'Mehta', 'Mehta Jewellers', true);
        Lead newLead = personLead(leadId, 'B2B', 'Asha', 'Mehta', 'Mehta Gems', true);

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual('Mehta Gems', newLead.Company, 'Allowed');
        Assert.isTrue(messagesOf(newLead).isEmpty(), 'No error');
    }

    private static Lead renamed(String businessType, String company, Boolean b2bBox) {
        Id leadId = fakeLeadId();
        Lead oldLead = personLead(leadId, businessType, 'Neha', 'Jain', company, b2bBox);
        Lead newLead = personLead(leadId, businessType, 'Neha', 'Jain Kapoor', company, b2bBox);
        runUpdate(oldLead, newLead);
        return newLead;
    }

    @IsTest
    static void theCompanyFollowsANameChangeInEveryFormat() {
        Test.startTest();
        Lead b2c = renamed('B2C', 'Neha Jain B2C (000123)', false);
        Lead b2b = renamed('B2B', 'Neha Jain B2B (000123)', true);
        Lead family = renamed('B2C', 'Neha Jain Family (000123)', false);
        Lead earlier = renamed('B2C', 'Neha Jain - B2C-000123', false);
        Test.stopTest();

        Assert.areEqual('Neha Jain Kapoor B2C (000123)', b2c.Company, 'B2C format');
        Assert.areEqual('Neha Jain Kapoor B2B (000123)', b2b.Company, 'B2B format');
        Assert.areEqual('Neha Jain Kapoor Family (000123)', family.Company, 'Family format');
        Assert.areEqual('Neha Jain Kapoor - B2C-000123', earlier.Company, 'Earlier format');
    }

    @IsTest
    static void aTypedCompanyOrAnUnknownFormatDoesNotFollowANameChange() {
        Test.startTest();
        Lead typed = renamed('B2B', 'Jain Jewellers', true);
        Lead unknownFormat = renamed('B2C', 'Placeholder', false);
        Test.stopTest();

        Assert.areEqual('Jain Jewellers', typed.Company, 'Typed Company kept');
        Assert.areEqual('Placeholder', unknownFormat.Company, 'A Company in no known format is kept');
        Assert.isTrue(messagesOf(unknownFormat).isEmpty(), 'And not an error');
    }

    @IsTest
    static void editingOtherFieldsLeavesTheCompanyAlone() {
        Id leadId = fakeLeadId();
        Lead oldLead = personLead(leadId, 'B2C', 'Asha', 'Mehta', 'Asha Mehta B2C (000123)', false);
        Lead newLead = personLead(leadId, 'B2C', 'Asha', 'Mehta', 'Asha Mehta B2C (000123)', false);
        newLead.Description = 'Likes silver';

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual('Asha Mehta B2C (000123)', newLead.Company, 'Unchanged');
        Assert.isTrue(messagesOf(newLead).isEmpty(), 'No error');
    }

    // =====================================================================
    // Conversion
    // =====================================================================

    @IsTest
    static void aConversionOutsideTheConvertButtonIsRefused() {
        Id leadId = fakeLeadId();
        Lead oldLead = leadWith(new Map<String, Object>{
            'Id' => leadId, 'LastName' => 'Mehta', 'Company' => 'Mehta Traders', 'IsConverted' => false
        });
        Lead newLead = leadWith(new Map<String, Object>{
            'Id' => leadId, 'LastName' => 'Mehta', 'Company' => 'Mehta Traders', 'IsConverted' => true
        });

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual(new List<String>{ LeadTriggerHandler.CONVERSION_NOT_ALLOWED }, messagesOf(newLead), 'Refused');
    }

    @IsTest
    static void anAlreadyConvertedLeadIsLeftAlone() {
        insert new Account(Name = 'Sen Household', Phone = '9830012341');
        Id leadId = fakeLeadId();
        Lead oldLead = leadWith(new Map<String, Object>{
            'Id' => leadId, 'LastName' => 'Sen', 'Company' => 'Sen Traders', 'IsConverted' => true, 'Phone' => '9830012342'
        });
        Lead newLead = leadWith(new Map<String, Object>{
            'Id' => leadId, 'LastName' => 'Sen', 'Company' => 'Sen Traders', 'IsConverted' => true, 'Phone' => '9830012341'
        });

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.isTrue(messagesOf(newLead).isEmpty(), 'Not checked: ' + messagesOf(newLead));
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

    /** A B2B Lead for an existing customer is refused too. */
    @IsTest
    static void aB2bLeadForAnExistingCustomerIsRefused() {
        insert new Account(Name = 'Rao Household', Phone = '9830012356');

        Test.startTest();
        Database.SaveResult result = Database.insert(
            new Lead(LastName = 'Rao', Phone = '9830012356', B2B_Lead__c = true),
            false
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Refused whatever the type');
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
        Assert.isFalse(LeadTriggerHandler.isValidPhone(null), 'Null');
        Assert.isNull(LeadTriggerHandler.normalizePhone(null), 'Blank stays blank');
    }

    @IsTest
    static void listsTheCommonStoredFormsOfAValidNumberOnly() {
        Set<String> forms = LeadTriggerHandler.storedFormsOf(new Set<String>{ '9830012345', '12345' });

        Assert.areEqual(8, forms.size(), 'Eight forms of the valid number, none of the invalid one');
        Assert.isTrue(forms.contains('+91-9830012345'), '+91 and a dash');
        Assert.isTrue(forms.contains('+91 98300 12345'), '+91 and a space in the middle');
        Assert.isTrue(forms.contains('98300 12345'), 'Spaced');
        Assert.isTrue(forms.contains('09830012345'), 'Leading 0');
        Assert.isFalse(forms.contains('12345'), 'The invalid number is skipped');
    }

    @IsTest
    static void listsTheValidNumbersAndKeysOfALead() {
        Lead person = new Lead(
            Phone = '+91 98300 12345', MobilePhone = '9830012345', Email = ' Asha@Match.example.com '
        );

        List<String> phones = LeadTriggerHandler.phonesOf(person);
        List<String> keys = LeadTriggerHandler.matchKeysOf(person);

        Assert.areEqual(new List<String>{ '9830012345' }, phones, 'The same number twice is listed once');
        Assert.areEqual(new List<String>{ 'phone:9830012345', 'email:asha@match.example.com' }, keys, 'Phone key then email key');
        Assert.areEqual(
            new List<String>{ '9830012345' },
            LeadTriggerHandler.phonesOf(new Lead(Phone = '9830012345', MobilePhone = '12345')),
            'An invalid WhatsApp number is skipped'
        );
        Assert.isTrue(LeadTriggerHandler.matchKeysOf(new Lead()).isEmpty(), 'Nothing to match');
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
    static void searchingForNothingFindsNothing() {
        Test.startTest();
        Map<String, LeadTriggerHandler.Customer> customers = LeadTriggerHandler.findCustomers(null, null);
        Map<String, List<Account>> accounts = LeadTriggerHandler.findAccounts(null, null);
        Map<String, Lead> leads = LeadTriggerHandler.findOpenLeads(null, null);
        Map<String, List<Account>> unmatched = LeadTriggerHandler.findAccounts(
            new Set<String>{ '9830099990' }, new Set<String>{ 'nobody@matcher.example.com' }
        );
        Test.stopTest();

        Assert.isTrue(customers.isEmpty(), 'No customers');
        Assert.isTrue(accounts.isEmpty(), 'No Accounts');
        Assert.isTrue(leads.isEmpty(), 'No Leads');
        Assert.isTrue(unmatched.isEmpty(), 'Nothing stored matches');
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

    @IsTest
    static void findsAnOpenLeadByItsEmailAndWhatsAppNumber() {
        Lead openLead = new Lead(
            LastName = 'Kapoor', Company = 'Kapoor Traders', Phone = '9830012301',
            MobilePhone = '+91 98300 12302', Email = 'kapoor@matcher.example.com'
        );
        insert openLead;

        Test.startTest();
        Map<String, Lead> found = LeadTriggerHandler.findOpenLeads(
            new Set<String>{ '9830012302' }, new Set<String>{ 'KAPOOR@matcher.example.com' }
        );
        Test.stopTest();

        Assert.areEqual(openLead.Id, found.get(LeadTriggerHandler.phoneKey('9830012302')).Id, 'By WhatsApp Number');
        Assert.areEqual(openLead.Id, found.get(LeadTriggerHandler.emailKey('kapoor@matcher.example.com')).Id, 'By email');
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
        Assert.areEqual('Mehta Family (Asha)', created.Name, 'Named as on conversion for B2C');
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
        Assert.areEqual('Mehta Family (Asha)', result.accountName, 'And its name');
        Assert.areEqual(person.Id, result.contactId, 'The same Contact');
        Assert.areEqual(UserInfo.getUserId(), result.caseOwnerId, 'The enquiry goes to the Account owner');
        // TODO: re-enable once the "Account: Create Loyalty Record" flow is active in prod.
        // Assert.areEqual(1, [SELECT COUNT() FROM Loyalty_Record__c WHERE Account__c = :created.Id],
        //     'A new Account gets its Loyalty Record as usual');
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
    static void aB2bLeadWithoutACompanyNameGetsAB2bAccountNamedAfterThePerson() {
        contactWithoutAccount('9830012366');
        Lead details = new Lead(
            FirstName = 'Rohit',
            LastName = 'Mehta',
            Phone = '9830012366',
            Company = 'Rohit Mehta - B2B',
            B2B_Lead__c = true
        );

        Test.startTest();
        LeadTriggerHandler.CheckResult result = checkAndCreateAccount(details);
        Test.stopTest();

        Account created = [SELECT Name, Business_Type__c FROM Account];
        Assert.areEqual('Rohit Mehta B2B', created.Name, 'The person\'s name and B2B');
        Assert.areEqual('B2B', created.Business_Type__c, 'B2B');
        Assert.areEqual('Rohit Mehta B2B', result.accountName, 'Reported with that name');
    }

    @IsTest
    static void aB2bLeadWithATypedCompanyNamesTheAccountAfterIt() {
        contactWithoutAccount('9830012366');
        Lead details = new Lead(
            FirstName = 'Rohit',
            LastName = 'Mehta',
            Phone = '9830012366',
            Company = 'Mehta Gems Pvt Ltd',
            B2B_Lead__c = true
        );

        Test.startTest();
        checkAndCreateAccount(details);
        Test.stopTest();

        Account created = [SELECT Name, Business_Type__c FROM Account];
        Assert.areEqual('Mehta Gems Pvt Ltd', created.Name, 'The typed Company');
        Assert.areEqual('B2B', created.Business_Type__c, 'B2B');
    }

    @IsTest
    static void aMissingLeadFallsBackToTheContact() {
        Contact person = contactWithoutAccount('9830012366');
        LeadTriggerHandler.Customer customer = new LeadTriggerHandler.Customer();
        customer.contactId = person.Id;

        Test.startTest();
        Map<Integer, String> failures = LeadTriggerHandler.createCustomerAccounts(
            new List<Lead>{ null },
            new List<LeadTriggerHandler.Customer>{ customer }
        );
        Test.stopTest();

        Assert.isTrue(failures.isEmpty(), 'No failures: ' + failures);
        Account created = [SELECT Name, Business_Type__c, Phone, Email__c FROM Account];
        Assert.areEqual('Mehta Family (Asha)', created.Name, 'Named after the Contact');
        Assert.areEqual('B2C', created.Business_Type__c, 'B2C');
        Assert.areEqual('9830012366', created.Phone, 'Phone from the Contact\'s WhatsApp number');
        Assert.areEqual('asha@contact.example.com', created.Email__c, 'Email from the Contact');
    }

    @IsTest
    static void anAccountThatCannotBeCreatedIsReported() {
        Contact person = contactWithoutAccount('9830012366');
        LeadTriggerHandler.Customer customer = new LeadTriggerHandler.Customer();
        customer.contactId = person.Id;

        Test.startTest();
        Map<Integer, String> failures = LeadTriggerHandler.createCustomerAccounts(
            new List<Lead>{ new Lead(LastName = 'Mehta', Company = 'M'.repeat(300), Phone = '9830012366') },
            new List<LeadTriggerHandler.Customer>{ customer }
        );
        Test.stopTest();

        Assert.isTrue(
            failures.get(0).startsWith('The customer Account could not be created: '),
            'Explained: ' + failures
        );
        Assert.isNull(customer.accountId, 'No Account');
        Assert.areEqual(0, [SELECT COUNT() FROM Account], 'Nothing created');
    }

    @IsTest
    static void checkingWithAnAccountThatCannotBeCreatedRaisesAnError() {
        contactWithoutAccount('9830012366');
        Lead details = new Lead(LastName = 'Mehta', Company = 'M'.repeat(300), Phone = '9830012366');

        Test.startTest();
        Boolean raised = false;
        try {
            checkAndCreateAccount(details);
        } catch (LeadTriggerHandler.CustomerAccountException failure) {
            raised = true;
        }
        Test.stopTest();

        Assert.isTrue(raised, 'The flow is told why');
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
        Assert.areEqual('Mehta Family (Asha)', first.accountName, 'Built from the first Lead');
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
    // Changing a Lead's phone or email (real updates; see TODO notes)
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

        // TODO: re-enable when the update section of LeadTrigger is switched on.
        // Database.Error error = onlyError(result);
        // Assert.areEqual(new List<String>{ 'Phone' }, error.getFields(), 'Shown on Phone');
        // Assert.areEqual(
        //     'This phone belongs to an existing customer: Sen Household. Raise an enquiry (Case) for that customer instead.',
        //     error.getMessage(), 'Names the customer'
        // );
        // Assert.areEqual('9830012342', reload(leadRecord.Id).Phone, 'The old phone is kept');
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

        // TODO: re-enable when the update section of LeadTrigger is switched on.
        // Database.Error error = onlyError(result);
        // Assert.areEqual(new List<String>{ 'Email' }, error.getFields(), 'Shown on Email');
        // Assert.isTrue(error.getMessage().contains('existing customer: Asha Mehta'), error.getMessage());
    }

    @IsTest
    static void changingThePhoneToAnotherOpenLeadsIsRefusedInAnyFormat() {
        Lead other = new Lead(LastName = 'Roy', Phone = '+91 98300 12343');
        Lead leadRecord = new Lead(LastName = 'Das', Phone = '9830012344');
        insert new List<Lead>{ other, leadRecord };

        Test.startTest();
        Database.SaveResult result = Database.update(new Lead(Id = leadRecord.Id, Phone = '9830012343'), false);
        Test.stopTest();

        // TODO: re-enable when the update section of LeadTrigger is switched on.
        // Database.Error error = onlyError(result);
        // Assert.areEqual(new List<String>{ 'Phone' }, error.getFields(), 'Shown on Phone');
        // Assert.isTrue(error.getMessage().startsWith('A Lead with this phone already exists: Roy'), error.getMessage());
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
        // TODO: re-enable when the update section of LeadTrigger is switched on.
        // Assert.areEqual('Another Lead in this save has the same phone.', onlyError(results[1]).getMessage(),
        //     'The second is refused');
    }

    // =====================================================================
    // Changing a Lead's phone or email (handler called directly)
    // =====================================================================

    @IsTest
    static void aPhoneChangedToACustomersIsRefused() {
        insert new Account(Name = 'Sen Household', Phone = '9830012341');
        Id leadId = fakeLeadId();
        Lead oldLead = typedLead(leadId, '9830012342', null, null);
        Lead newLead = typedLead(leadId, '+91 98300 12341', null, null);

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{ 'This phone belongs to an existing customer: Sen Household. Raise an enquiry (Case) for that customer instead.' },
            messagesOf(newLead), 'Names the customer'
        );
    }

    @IsTest
    static void aWhatsAppNumberChangedToACustomersIsRefused() {
        insert new Account(Name = 'Kar Household', Phone = '9830022009');
        Id leadId = fakeLeadId();
        Lead oldLead = typedLead(leadId, '9830022015', '9830022016', null);
        Lead newLead = typedLead(leadId, '9830022015', '+91 98300 22009', null);

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{ 'This WhatsApp number belongs to an existing customer: Kar Household. Raise an enquiry (Case) for that customer instead.' },
            messagesOf(newLead), 'Refused on the WhatsApp Number'
        );
    }

    @IsTest
    static void anEmailChangedToACustomerKnownOnlyAsAContactIsRefused() {
        insert new Contact(FirstName = 'Asha', LastName = 'Mehta', Email = 'asha@contact.example.com');
        Id leadId = fakeLeadId();
        Lead oldLead = typedLead(leadId, null, null, 'old@lead.example.com');
        Lead newLead = typedLead(leadId, null, null, 'ASHA@contact.example.com');

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{ 'This email belongs to an existing customer: Asha Mehta. Raise an enquiry (Case) for that customer instead.' },
            messagesOf(newLead), 'Refused on the Email'
        );
    }

    @IsTest
    static void aPhoneChangedToAnotherOpenLeadsIsRefusedInAnyFormat() {
        insert new Lead(LastName = 'Roy', Company = 'Roy Traders', Phone = '+91 98300 12343');
        Id leadId = fakeLeadId();
        Lead oldLead = typedLead(leadId, '9830012344', null, null);
        Lead newLead = typedLead(leadId, '9830012343', null, null);

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        List<String> messages = messagesOf(newLead);
        Assert.areEqual(1, messages.size(), 'One error: ' + messages);
        Assert.isTrue(messages[0].startsWith('A Lead with this phone already exists: Roy'), messages[0]);
    }

    @IsTest
    static void aPhoneChangedToItsOwnStoredNumberIsNotStopped() {
        Lead stored = new Lead(LastName = 'Self', Company = 'Self Traders', Phone = '9830012350');
        insert stored;
        Lead oldLead = typedLead(stored.Id, '9830012349', null, null);
        Lead newLead = typedLead(stored.Id, '9830012350', null, null);

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.isTrue(messagesOf(newLead).isEmpty(), 'A Lead is not a duplicate of itself: ' + messagesOf(newLead));
    }

    @IsTest
    static void twoLeadsTakingTheSameNewPhoneInOneSaveAreStopped() {
        Id firstId = fakeLeadId();
        Id secondId = fakeLeadId();
        Lead firstOld = typedLead(firstId, '9830012346', null, null);
        Lead secondOld = typedLead(secondId, '9830012347', null, null);
        Lead firstNew = typedLead(firstId, '9830012348', null, null);
        Lead secondNew = typedLead(secondId, '+91 98300 12348', null, null);

        Test.startTest();
        LeadTriggerHandler.beforeUpdate(
            new List<Lead>{ firstNew, secondNew },
            new Map<Id, Lead>{ firstId => firstOld, secondId => secondOld }
        );
        Test.stopTest();

        Assert.isTrue(messagesOf(firstNew).isEmpty(), 'The first takes it');
        Assert.areEqual(new List<String>{ 'Another Lead in this save has the same phone.' }, messagesOf(secondNew), 'The second is refused');
    }

    @IsTest
    static void retypingTheSameDetailsOrEnteringInvalidOnesIsNotChecked() {
        insert new Account(Name = 'Ghosh Household', Phone = '9830012345', Email__c = 'ghosh@lead.example.com');
        Id sameId = fakeLeadId();
        Id invalidId = fakeLeadId();
        Id blankEmailId = fakeLeadId();
        Lead sameOld = typedLead(sameId, '9830012345', null, 'ghosh@lead.example.com');
        Lead sameNew = typedLead(sameId, '+91 98300 12345', null, 'GHOSH@lead.example.com');
        Lead invalidOld = typedLead(invalidId, '9830012346', null, null);
        Lead invalidNew = typedLead(invalidId, '12345', '98300abc45', null);
        Lead blankEmailOld = typedLead(blankEmailId, '9830012347', null, 'someone@lead.example.com');
        Lead blankEmailNew = typedLead(blankEmailId, '9830012347', null, null);

        Test.startTest();
        LeadTriggerHandler.beforeUpdate(
            new List<Lead>{ sameNew, invalidNew, blankEmailNew },
            new Map<Id, Lead>{ sameId => sameOld, invalidId => invalidOld, blankEmailId => blankEmailOld }
        );
        Test.stopTest();

        Assert.isTrue(messagesOf(sameNew).isEmpty(), 'Same phone and email written differently: ' + messagesOf(sameNew));
        Assert.isTrue(messagesOf(invalidNew).isEmpty(), 'Invalid numbers are the validation rule\'s job');
        Assert.isTrue(messagesOf(blankEmailNew).isEmpty(), 'A cleared email is not checked');
    }

    @IsTest
    static void anEmailAddedToALeadThatHadNoneIsChecked() {
        insert new Account(Name = 'Mitra Household', Email__c = 'mitra@matcher.example.com');
        Id leadId = fakeLeadId();
        Lead oldLead = typedLead(leadId, null, null, null);
        Lead newLead = typedLead(leadId, null, null, 'mitra@matcher.example.com');

        Test.startTest();
        runUpdate(oldLead, newLead);
        Test.stopTest();

        Assert.areEqual(1, messagesOf(newLead).size(), 'Refused: ' + messagesOf(newLead));
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
        }, false, AccessLevel.SYSTEM_MODE);
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
        Database.SaveResult invalid = Database.insert(
            new Lead(LastName = 'Bad', Phone = '9830022004', MobilePhone = '12345'), false, AccessLevel.SYSTEM_MODE
        );
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
        insert as system openLead;

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
        Database.SaveResult toCustomer = Database.update(new Lead(Id = leadRecord.Id, MobilePhone = '+91 98300 22009'), false, AccessLevel.SYSTEM_MODE);
        Database.SaveResult toOtherLead = Database.update(new Lead(Id = leadRecord.Id, MobilePhone = '9830022010'), false, AccessLevel.SYSTEM_MODE);
        Database.SaveResult toOwnPhone = Database.update(new Lead(Id = leadRecord.Id, MobilePhone = '98300 22015'), false, AccessLevel.SYSTEM_MODE);
        Test.stopTest();

        // TODO: re-enable when the update section of LeadTrigger is switched on.
        // Assert.isFalse(toCustomer.isSuccess(), 'A customer\'s phone');
        // Assert.areEqual(new List<String>{ 'MobilePhone' }, toCustomer.getErrors()[0].getFields(), 'Shown on WhatsApp Number');
        // Assert.isTrue(toCustomer.getErrors()[0].getMessage().startsWith('This WhatsApp number belongs to an existing customer: Kar Household'),
        //     toCustomer.getErrors()[0].getMessage());
        // Assert.isFalse(toOtherLead.isSuccess(), 'Another open Lead\'s phone');
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

    // =====================================================================
    // Insert rules (direct inserts: Workbench, Data Loader, CLI)
    // =====================================================================

    /** A Lead that passes every insert rule. */
    private static Lead directLead(String lastName, String phone) {
        return new Lead(LastName = lastName, Phone = phone, Description = 'Gold ring');
    }

    /** Inserts as a direct insert would, with the insert rules on; returns the error text, or null when saved. */
    private static String directInsert(Lead leadRecord) {
        LeadTriggerHandler.applyInsertRulesInTests = true;
        Database.SaveResult save = Database.insert(leadRecord, false);
        return save.isSuccess() ? null : save.getErrors()[0].getMessage();
    }

    @IsTest
    static void insertRulesAreOffInOtherTests() {
        // The older tests rely on this: a Lead without Phone or Product Description still saves.
        Database.SaveResult save = Database.insert(new Lead(LastName = 'Bare'), false);
        Assert.isTrue(save.isSuccess(), String.valueOf(save.getErrors()));
    }

    @IsTest
    static void directInsertNeedsPhoneAndProductDescription() {
        Assert.areEqual(LeadTriggerHandler.PHONE_REQUIRED,
            directInsert(new Lead(LastName = 'Nophone', Description = 'Gold ring')));
        Assert.areEqual(LeadTriggerHandler.PRODUCT_REQUIRED,
            directInsert(new Lead(LastName = 'Noproduct', Phone = '9830033001')));
        Assert.isNull(directInsert(directLead('Complete', '9830033002')));
    }

    @IsTest
    static void directInsertRefusesFutureDateOfBirth() {
        Lead future = directLead('Future', '9830033003');
        future.Date_of_Birth__c = Date.today().addDays(1);
        Assert.areEqual(LeadTriggerHandler.BIRTH_DATE_IN_FUTURE, directInsert(future));

        Lead today = directLead('Today', '9830033004');
        today.Date_of_Birth__c = Date.today();
        Assert.isNull(directInsert(today));
    }

    @IsTest
    static void directInsertRefusesConvertedAndUnknownStatus() {
        Lead converted = directLead('Converted', '9830033005');
        converted.Status = 'Converted';
        Assert.areEqual(LeadTriggerHandler.CONVERTED_STATUS_REFUSED, directInsert(converted));

        Lead unknown = directLead('Unknown', '9830033006');
        unknown.Status = 'Garbage';
        String reason = directInsert(unknown);
        Assert.isTrue(reason.startsWith('"Garbage" is not a valid Status. Allowed values: '), reason);
        Assert.isTrue(reason.contains('New'), reason);
        Assert.isFalse(reason.contains('Converted'), 'Converted is not offered: ' + reason);
    }

    @IsTest
    static void directInsertCorrectsTheCaseOfPicklistValues() {
        Lead lowered = directLead('Lowered', '9830033007');
        lowered.Status = 'contacted';
        lowered.Marital_Status__c = 'married';
        Assert.isNull(directInsert(lowered));

        Lead saved = [SELECT Status, Marital_Status__c FROM Lead WHERE Id = :lowered.Id];
        Assert.isTrue(saved.Status.equals('Contacted'), saved.Status);
        Assert.isTrue(saved.Marital_Status__c.equals('Married'), saved.Marital_Status__c);

        Lead blankStatus = directLead('Blankstatus', '9830033008');
        Assert.isNull(directInsert(blankStatus));
        Assert.areEqual('New', [SELECT Status FROM Lead WHERE Id = :blankStatus.Id].Status);
    }

    @IsTest
    static void directInsertRefusesUnknownPicklistValues() {
        Lead source = directLead('Source', '9830033009');
        source.LeadSource = 'Not A Source';
        String reason = directInsert(source);
        Assert.isTrue(reason.startsWith('"Not A Source" is not a valid Lead Source. Allowed values: '), reason);

        Lead salutation = directLead('Salutation', '9830033010');
        salutation.Salutation = 'Zzz.';
        reason = directInsert(salutation);
        Assert.isTrue(reason.startsWith('"Zzz." is not a valid Salutation. Allowed values: '), reason);

        Lead industry = directLead('Industry', '9830033011');
        industry.Industry = 'Not An Industry';
        reason = directInsert(industry);
        Assert.isTrue(reason.startsWith('"Not An Industry" is not a valid Industry. Allowed values: '), reason);

        Lead marital = directLead('Marital', '9830033012');
        marital.Marital_Status__c = 'Complicated';
        // A restricted picklist: the platform refuses it before the trigger runs.
        reason = directInsert(marital);
        Assert.isTrue(reason != null && reason.contains('Marital Status'), reason);
    }

    @IsTest
    static void directInsertWithTypedCompanyIsB2b() {
        Lead typed = directLead('Typed', '9830033013');
        typed.Company = 'Typed Traders';
        Assert.isNull(directInsert(typed));
        Lead saved = reload(typed.Id);
        Assert.areEqual('B2B', saved.Business_Type__c);
        Assert.areEqual('Typed Traders', saved.Company);

        Lead blank = directLead('Blank', '9830033014');
        Assert.isNull(directInsert(blank));
        saved = reload(blank.Id);
        Assert.areEqual('B2C', saved.Business_Type__c);
        Assert.areEqual('Blank B2C (' + saved.Lead_Number__c + ')', saved.Company);

        // A Business Type that was sent is kept.
        Lead stated = directLead('Stated', '9830033015');
        stated.Company = 'Stated Traders';
        stated.Business_Type__c = 'B2C';
        Assert.isNull(directInsert(stated));
        Assert.areEqual('B2C', reload(stated.Id).Business_Type__c);
    }

    @IsTest
    static void directInsertRefusesOpenLeadInAnotherPhoneFormat() {
        Lead existing = directLead('Existing', '9830033016');
        existing.FirstName = 'Open';
        existing.MobilePhone = '9830033017';
        existing.Email = 'open.lead@example.com';
        Assert.isNull(directInsert(existing));

        String otherFormat = directInsert(directLead('Otherformat', '+91-9830033016'));
        Assert.isTrue(otherFormat.startsWith('A Lead with this phone, WhatsApp number or email already exists: Open Existing'),
            otherFormat);
        Assert.isTrue(otherFormat.endsWith(', Lead Id ' + existing.Id + ').'), 'The open Lead\'s Id is given: ' + otherFormat);

        // The new Lead's WhatsApp Number is the open Lead's Phone, and the other way round.
        Lead whatsAppIsPhone = directLead('Whatsappisphone', '9830033018');
        whatsAppIsPhone.MobilePhone = '91 9830033016';
        Assert.isTrue(directInsert(whatsAppIsPhone).contains('already exists: Open Existing'));
        Assert.isTrue(directInsert(directLead('Phoneiswhatsapp', '98300 33017')).contains('already exists: Open Existing'));

        Lead sameEmail = directLead('Sameemail', '9830033019');
        sameEmail.Email = 'OPEN.LEAD@example.com';
        Assert.isTrue(directInsert(sameEmail).contains('already exists: Open Existing'));
    }

    // ---------------------------------------------------------------------
    // A Lead may share details with an Unqualified Lead (Lead Duplicate Check
    // is inactive; every path skips Unqualified Leads in findOpenLeads).
    // ---------------------------------------------------------------------

    /** An Unqualified Lead with Phone 9830033020, WhatsApp Number 9830033120 and an email. */
    private static Lead unqualifiedLead() {
        Lead unqualified = directLead('Unqualified', '+91-9830033020');
        unqualified.FirstName = 'Old';
        unqualified.MobilePhone = '9830033120';
        unqualified.Email = 'old.unqualified@example.com';
        unqualified.Status = 'Unqualified';
        Assert.isNull(directInsert(unqualified));
        return unqualified;
    }

    /** Saved, then undone, so that it is matched against the Unqualified Lead only. */
    private static String directInsertAlone(Lead leadRecord) {
        Savepoint beforeInsert = Database.setSavepoint();
        String reason = directInsert(leadRecord);
        Database.rollback(beforeInsert);
        return reason;
    }

    @IsTest
    static void directInsertAllowsTheDetailsOfAnUnqualifiedLead() {
        Lead unqualified = unqualifiedLead();

        // Same phone, exactly as stored and in another format.
        Assert.isNull(directInsertAlone(directLead('Exactphone', '+91-9830033020')));
        Assert.isNull(directInsertAlone(directLead('Otherformat', '9830033020')));

        // Phone = its WhatsApp Number; WhatsApp Number = its Phone.
        Assert.isNull(directInsertAlone(directLead('Phoneiswhatsapp', '9830033120')));
        Lead whatsApp = directLead('Whatsappisphone', '9830033021');
        whatsApp.MobilePhone = '+91 9830033020';
        Assert.isNull(directInsertAlone(whatsApp));

        // Same email, in another case.
        Lead email = directLead('Sameemail', '9830033022');
        email.Email = 'OLD.UNQUALIFIED@example.com';
        Assert.isNull(directInsertAlone(email));

        // Same name, phone and WhatsApp Number. (Same name AND same email is stopped by Salesforce's
        // Standard Lead Duplicate Rule, an alert-only rule that refuses inserts made by code or the API.)
        Lead same = directLead('Unqualified', '+91-9830033020');
        same.FirstName = 'Old';
        same.MobilePhone = '9830033120';
        String sameReason = directInsert(same);
        Assert.isNull(sameReason, 'Refused: ' + sameReason);

        Assert.areEqual(2, [SELECT COUNT() FROM Lead]);
        Assert.areEqual('Unqualified', [SELECT Status FROM Lead WHERE Id = :unqualified.Id].Status, 'Left as it was');
        Assert.areEqual('New', [SELECT Status FROM Lead WHERE Id = :same.Id].Status);

        // The new Lead is open: a third with the same details is its duplicate.
        Assert.isTrue(directInsert(directLead('Third', '9830033020')).contains('Lead Id ' + same.Id));
    }

    @IsTest
    static void unqualifiedLeadsAreNotDuplicatesButOpenOnesAre() {
        unqualifiedLead();
        Lead open = directLead('Open', '9830033023');
        open.Email = 'open.one@example.com';
        Assert.isNull(directInsert(open));

        // One save: the Unqualified Lead's details pass, the open Lead's are refused.
        Lead likeUnqualified = directLead('Likeunqualified', '+91-9830033020');
        Lead likeOpen = directLead('Likeopen', '9830033024');
        likeOpen.Email = 'OPEN.ONE@example.com';
        LeadTriggerHandler.applyInsertRulesInTests = true;
        List<Database.SaveResult> saves = Database.insert(new List<Lead>{ likeUnqualified, likeOpen }, false);

        Assert.isTrue(saves[0].isSuccess(), String.valueOf(saves[0].getErrors()));
        Assert.isTrue(saves[1].getErrors()[0].getMessage().contains('Lead Id ' + open.Id), String.valueOf(saves[1].getErrors()));
    }

    @IsTest
    static void newLeadScreenDoesNotReportAnUnqualifiedLead() {
        unqualifiedLead();

        LeadTriggerHandler.CheckResult byPhone = checkOne('+91-9830033020', null);
        Assert.isFalse(byPhone.isOpenLead, 'Phone of an Unqualified Lead');
        Assert.isNull(byPhone.openLeadId);
        Assert.isFalse(checkOne('9830033120', null).isOpenLead, 'Its WhatsApp Number');
        Assert.isFalse(checkOne('9830033025', 'old.unqualified@example.com').isOpenLead, 'Its email');
        Assert.isFalse(byPhone.isExistingCustomer);

        // The New Lead screen then saves the Lead.
        LeadTriggerHandler.applyInsertRulesInTests = true;
        insert new Lead(LastName = 'Fromscreen', Phone = '+91-9830033020', Description = 'Gold ring', Status = 'New');
        Assert.areEqual(2, [SELECT COUNT() FROM Lead]);
    }

    @IsTest
    static void uploadLeadsAllowsTheDetailsOfAnUnqualifiedLead() {
        unqualifiedLead();
        String csv = 'First Name,Last Name,Phone,WhatsApp Number,Email,Product Description\n'
            + ',Exactphone,+91-9830033020,,,Gold ring\n'
            + ',Whatsapp,9830033026,+91 9830033120,,Gold ring\n'
            + ',Email,9830033027,,Old.Unqualified@example.com,Gold ring\n';
        ContentVersion file = new ContentVersion(Title = 'leads', PathOnClient = 'leads.csv', VersionData = Blob.valueOf(csv));
        insert file;
        LeadUploadService.UploadRequest request = new LeadUploadService.UploadRequest();
        request.contentDocumentIds = new List<String>{
            [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :file.Id].ContentDocumentId
        };

        Test.startTest();
        LeadUploadService.UploadResult result = LeadUploadService.upload(new List<LeadUploadService.UploadRequest>{ request })[0];
        Test.stopTest();

        Assert.isTrue(result.isFileValid, 'File refused: ' + result.errorMessage);
        Assert.areEqual(3, result.leadsCreated,
            [SELECT VersionData FROM ContentVersion WHERE Id = :result.resultFileVersionId].VersionData.toString());
        Assert.areEqual(0, result.failedRows);
        Assert.areEqual(4, [SELECT COUNT() FROM Lead]);
    }

    @IsTest
    static void websiteApiAllowsTheDetailsOfAnUnqualifiedLead() {
        unqualifiedLead();

        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/shreehari/v1/leads';
        request.httpMethod = 'POST';
        request.addHeader('Content-Type', 'application/json');
        request.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'lastName' => 'Website',
            'phone' => '+91-9830033020',
            'email' => 'old.unqualified@example.com',
            'description' => 'Gold ring',
            'leadSource' => 'Shopify'
        }));
        RestContext.request = request;
        RestContext.response = new RestResponse();

        Test.startTest();
        ShreeHariLeadRestResource.createLead();
        Test.stopTest();
        RestContext.request = null;

        Assert.areEqual(201, RestContext.response.statusCode, RestContext.response.responseBody.toString());
        Assert.areEqual(2, [SELECT COUNT() FROM Lead]);
    }

    @IsTest
    static void directInsertRefusesTheSamePersonTwiceInOneSave() {
        Lead first = directLead('First', '9830033021');
        Lead samePhone = directLead('Samephone', '+91 9830033021');
        Lead whatsAppIsFirstPhone = directLead('Third', '9830033022');
        whatsAppIsFirstPhone.MobilePhone = '9830033021';
        Lead other = directLead('Other', '9830033023');
        // Refused for its own reason, so its phone is still free for the next one.
        Lead noProduct = new Lead(LastName = 'Noproduct', Phone = '9830033024');
        Lead afterRefused = directLead('Afterrefused', '9830033024');

        LeadTriggerHandler.applyInsertRulesInTests = true;
        List<Database.SaveResult> saves = Database.insert(
            new List<Lead>{ first, samePhone, whatsAppIsFirstPhone, other, noProduct, afterRefused }, false
        );

        Assert.isTrue(saves[0].isSuccess(), String.valueOf(saves[0].getErrors()));
        Assert.areEqual(LeadTriggerHandler.SAME_AS_ANOTHER_IN_SAVE, saves[1].getErrors()[0].getMessage());
        Assert.areEqual(LeadTriggerHandler.SAME_AS_ANOTHER_IN_SAVE, saves[2].getErrors()[0].getMessage());
        Assert.isTrue(saves[3].isSuccess(), String.valueOf(saves[3].getErrors()));
        Assert.areEqual(LeadTriggerHandler.PRODUCT_REQUIRED, saves[4].getErrors()[0].getMessage());
        Assert.isTrue(saves[5].isSuccess(), String.valueOf(saves[5].getErrors()));
        Assert.areEqual(3, [SELECT COUNT() FROM Lead]);
    }

    @IsTest
    static void directInsertChecksPhoneWhatsAppAndAnniversary() {
        Assert.areEqual(LeadTriggerHandler.PHONE_INVALID, directInsert(directLead('Shortphone', '12345')));

        Lead whatsApp = directLead('Badwhatsapp', '9830033031');
        whatsApp.MobilePhone = '12345';
        Assert.areEqual(LeadTriggerHandler.WHATSAPP_INVALID, directInsert(whatsApp));

        Lead unmarried = directLead('Unmarried', '9830033032');
        unmarried.Anniversary_Date__c = Date.today().addYears(-1);
        Assert.areEqual(LeadTriggerHandler.ANNIVERSARY_NOT_MARRIED, directInsert(unmarried));

        Lead future = directLead('Futureanniversary', '9830033033');
        future.Marital_Status__c = 'Married';
        future.Anniversary_Date__c = Date.today().addDays(1);
        Assert.areEqual(LeadTriggerHandler.ANNIVERSARY_IN_FUTURE, directInsert(future));

        Lead beforeBirth = directLead('Beforebirth', '9830033034');
        beforeBirth.Marital_Status__c = 'Married';
        beforeBirth.Date_of_Birth__c = Date.newInstance(1990, 1, 1);
        beforeBirth.Anniversary_Date__c = Date.newInstance(1990, 1, 1);
        Assert.areEqual(LeadTriggerHandler.ANNIVERSARY_BEFORE_BIRTH, directInsert(beforeBirth));

        Lead complete = directLead('Married', '+91 98300-33035');
        complete.MobilePhone = '(98300) 33036';
        complete.Marital_Status__c = 'Married';
        complete.Date_of_Birth__c = Date.newInstance(1990, 1, 1);
        complete.Anniversary_Date__c = Date.newInstance(2015, 2, 3);
        Assert.isNull(directInsert(complete));
        Assert.areEqual('+91 98300-33035', reload(complete.Id).Phone, 'Saved as written');
    }

    @IsTest
    static void directInsertNeedsOnlyLastNamePhoneAndProductDescription() {
        // Nothing else is required: no First Name, Email, Lead Source, Status, Company or Store.
        Lead minimal = new Lead(LastName = 'Minimal', Phone = '9830033037', Description = 'Gold ring');
        Assert.isNull(directInsert(minimal));

        Lead saved = [
            SELECT Status, Company, Business_Type__c, Lead_Number__c FROM Lead WHERE Id = :minimal.Id WITH SYSTEM_MODE
        ];
        Assert.areEqual('New', saved.Status);
        Assert.areEqual('B2C', saved.Business_Type__c);
        Assert.areEqual('Minimal B2C (' + saved.Lead_Number__c + ')', saved.Company);

        String noLastName = directInsert(new Lead(Phone = '9830033038', Description = 'Gold ring'));
        Assert.isNotNull(noLastName, 'Last Name is required by the platform');
    }

    @IsTest
    static void directInsertWithB2bCheckboxIsB2b() {
        // Checkbox with no Company: "<Name> B2B (<Lead Number>)".
        Lead ticked = directLead('Mehta', '9830033039');
        ticked.FirstName = 'Asha';
        ticked.B2B_Lead__c = true;
        Assert.isNull(directInsert(ticked));
        Lead saved = reload(ticked.Id);
        Assert.areEqual('B2B', saved.Business_Type__c);
        Assert.areEqual('Asha Mehta B2B (' + saved.Lead_Number__c + ')', saved.Company);

        // Checkbox with a typed Company: the Company is kept.
        Lead typed = directLead('Shah', '9830033040');
        typed.B2B_Lead__c = true;
        typed.Company = 'Shah Jewels';
        Assert.isNull(directInsert(typed));
        saved = reload(typed.Id);
        Assert.areEqual('B2B', saved.Business_Type__c);
        Assert.areEqual('Shah Jewels', saved.Company);
    }

    @IsTest
    static void directInsertForAnExistingCustomerIsRefused() {
        insert new Account(Name = 'Known Family', Phone = '9830033025');

        String reason = directInsert(directLead('Known', '+91 9830033025'));

        Assert.areEqual('An existing customer has this phone, WhatsApp number or email: Known Family. '
            + LeadTriggerHandler.USE_UPLOAD_BUTTON, reason);
        Assert.areEqual(0, [SELECT COUNT() FROM Lead]);
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'No enquiry from a direct insert');
    }

    @IsTest
    static void directInsertMatchesTheCustomerByWhatsAppEmailAndContact() {
        insert new List<Account>{
            new Account(Name = 'Whatsapp Family', WhatsApp_Number__c = '9830033041'),
            new Account(Name = 'Email Family', Email__c = 'email.family@example.com')
        };
        Contact person = new Contact(FirstName = 'Rohit', LastName = 'Bose', MobilePhone = '9830033047');
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Database.insert(person, options);

        // The Lead's Phone is the customer's WhatsApp Number.
        String reason = directInsert(directLead('One', '9830033041'));
        Assert.isTrue(reason.endsWith('Whatsapp Family. ' + LeadTriggerHandler.USE_UPLOAD_BUTTON), reason);

        Lead email = directLead('Two', '9830033042');
        email.Email = 'EMAIL.FAMILY@example.com';
        reason = directInsert(email);
        Assert.isTrue(reason.endsWith('Email Family. ' + LeadTriggerHandler.USE_UPLOAD_BUTTON), reason);

        // A customer known only as a Contact: the Lead's WhatsApp Number is the Contact's.
        Lead contactOnly = directLead('Three', '9830033043');
        contactOnly.MobilePhone = '+91 9830033047';
        reason = directInsert(contactOnly);
        Assert.isTrue(reason.endsWith('Rohit Bose. ' + LeadTriggerHandler.USE_UPLOAD_BUTTON), reason);
        Assert.isNull([SELECT AccountId FROM Contact WHERE Id = :person.Id].AccountId, 'No Account is created');

        Assert.areEqual(0, [SELECT COUNT() FROM Lead]);
        Assert.areEqual(0, [SELECT COUNT() FROM Case]);
    }

    @IsTest
    static void directInsertForACustomerWithBadDetailsGivesTheDetailsReason() {
        insert new Account(Name = 'Known Family', Phone = '9830033043');

        // The Lead's own values are checked first, as in Upload Leads.
        Assert.areEqual(LeadTriggerHandler.PRODUCT_REQUIRED, directInsert(new Lead(LastName = 'Known', Phone = '9830033043')));
        Lead future = directLead('Known', '9830033043');
        future.Date_of_Birth__c = Date.today().addDays(1);
        Assert.areEqual(LeadTriggerHandler.BIRTH_DATE_IN_FUTURE, directInsert(future));
        Assert.areEqual(0, [SELECT COUNT() FROM Lead]);
    }

    @IsTest
    static void directInsertInOneSaveMixesLeadsAndRefusals() {
        Account customer = new Account(Name = 'Known Family', Phone = '9830033044');
        insert customer;
        Lead open = directLead('Existing', '9830033045');
        open.FirstName = 'Open';
        Assert.isNull(directInsert(open));

        Lead fresh = directLead('Fresh', '9830033046');
        Lead forCustomer = directLead('Customer', '9830033044');
        Lead customerAgain = directLead('Customeragain', '+91 9830033044');
        Lead forOpenLead = directLead('Openlead', '+91-9830033045');
        Lead noPhone = new Lead(LastName = 'Nophone', Description = 'Gold ring');

        LeadTriggerHandler.applyInsertRulesInTests = true;
        List<Database.SaveResult> saves = Database.insert(
            new List<Lead>{ fresh, forCustomer, customerAgain, forOpenLead, noPhone }, false
        );

        Assert.isTrue(saves[0].isSuccess(), String.valueOf(saves[0].getErrors()));
        Assert.isTrue(saves[1].getErrors()[0].getMessage().endsWith('Known Family. ' + LeadTriggerHandler.USE_UPLOAD_BUTTON));
        Assert.areEqual(LeadTriggerHandler.SAME_AS_ANOTHER_IN_SAVE, saves[2].getErrors()[0].getMessage());
        Assert.isTrue(saves[3].getErrors()[0].getMessage().contains('Lead Id ' + open.Id));
        Assert.areEqual(LeadTriggerHandler.PHONE_REQUIRED, saves[4].getErrors()[0].getMessage());

        Assert.areEqual(2, [SELECT COUNT() FROM Lead], 'The open Lead and the fresh one');
        Assert.areEqual(0, [SELECT COUNT() FROM Case]);
    }

    @IsTest
    static void websiteApiKeepsTheStatusItIsSent() {
        // Apex REST (ShreeHariLeadRestResource) saves the status it was sent, as before.
        RestContext.request = new RestRequest();
        Lead converted = directLead('Website', '9830033026');
        converted.Status = 'Converted';
        String reason = directInsert(converted);
        RestContext.request = null;

        Assert.isNull(reason);
        Assert.areEqual('Converted', [SELECT Status FROM Lead WHERE Id = :converted.Id].Status);
    }

    @IsTest
    static void uploadLeadsGivesTheSameResultsWithTheInsertRulesOn() {
        Lead existing = directLead('Existing', '9830033027');
        existing.FirstName = 'Open';
        Assert.isNull(directInsert(existing));

        String csv = 'Last Name,Phone,Product Description,Company,Status\n'
            + 'Saved,9830033028,Gold ring,,\n'
            + 'Business,9830033029,Gold coin,Upload Traders,contacted\n'
            + 'Repeat,+91 9830033028,Gold ring,,\n'
            + 'Taken,+91-9830033027,Gold ring,,\n'
            + 'Noproduct,9830033030,,,\n';
        ContentVersion file = new ContentVersion(
            Title = 'leads', PathOnClient = 'leads.csv', VersionData = Blob.valueOf(csv)
        );
        insert file;
        LeadUploadService.UploadRequest request = new LeadUploadService.UploadRequest();
        request.contentDocumentIds = new List<String>{
            [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :file.Id].ContentDocumentId
        };

        Test.startTest();
        LeadUploadService.UploadResult result = LeadUploadService.upload(
            new List<LeadUploadService.UploadRequest>{ request }
        )[0];
        Test.stopTest();

        Assert.isTrue(result.isFileValid, 'File refused: ' + result.errorMessage);
        Assert.areEqual(5, result.totalRows);
        Assert.areEqual(2, result.leadsCreated);
        Assert.areEqual(3, result.failedRows);

        String results = [SELECT VersionData FROM ContentVersion WHERE Id = :result.resultFileVersionId].VersionData.toString();
        // The upload's own reasons, not the trigger's.
        Assert.isTrue(results.contains('Same phone, WhatsApp number or email as row 2 of this file.'), results);
        Assert.isTrue(results.contains('A Lead with this phone, WhatsApp number or email already exists: Open Existing'), results);
        Assert.isTrue(results.contains('Product Description is required.'), results);

        Lead business = [SELECT Status, Business_Type__c FROM Lead WHERE Phone = '9830033029'];
        Assert.areEqual('B2B', business.Business_Type__c);
        Assert.areEqual('Contacted', business.Status);
    }
}
