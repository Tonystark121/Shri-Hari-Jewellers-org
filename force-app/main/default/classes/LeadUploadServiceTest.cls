/**
 * Tests for LeadUploadService: CSV upload of Leads with the same rules as
 * the New Lead screen, and the results file.
 */
@IsTest
private class LeadUploadServiceTest {

    /** The template header row (Lead_Upload_Template static resource). */
    private static final String HEADER =
        'Salutation,First Name,Last Name *,Phone *,Email,Date of Birth (YYYY-MM-DD),Street,City,State,Postal Code,Country,'
        + 'Product Description *,Marital Status,Anniversary Date (YYYY-MM-DD),Status,Lead Source,Walk-In (Yes/No),'
        + 'Store Code,Campaign Name,Company,Industry,Title,Website';

    // =====================================================================
    // Helpers
    // =====================================================================

    /** One template row; blank cells for everything not given. */
    private static String row(Map<String, String> cells) {
        List<String> columns = new List<String>{
            'Salutation', 'First Name', 'Last Name', 'Phone', 'Email', 'Date of Birth', 'Street', 'City', 'State',
            'Postal Code', 'Country', 'Product Description', 'Marital Status', 'Anniversary Date', 'Status',
            'Lead Source', 'Walk-In', 'Store Code', 'Campaign Name', 'Company', 'Industry', 'Title', 'Website'
        };
        List<String> values = new List<String>();
        for (String column : columns) {
            String value = cells.get(column);
            values.add(value == null ? '' : value);
        }
        return String.join(values, ',');
    }

    private static Map<String, String> customer(String lastName, String phone) {
        return new Map<String, String>{
            'First Name' => 'Test',
            'Last Name' => lastName,
            'Phone' => phone,
            'Product Description' => 'Gold necklace'
        };
    }

    private static LeadUploadService.UploadResult upload(String csv) {
        ContentVersion file = new ContentVersion(
            Title = 'leads',
            PathOnClient = 'leads.csv',
            VersionData = Blob.valueOf(csv)
        );
        insert file;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :file.Id].ContentDocumentId;

        LeadUploadService.UploadRequest request = new LeadUploadService.UploadRequest();
        request.contentDocumentIds = new List<String>{ documentId };
        return LeadUploadService.upload(new List<LeadUploadService.UploadRequest>{ request })[0];
    }

    /** The results file as rows of cells, header first. */
    private static List<List<String>> resultsOf(LeadUploadService.UploadResult result) {
        ContentVersion file = [SELECT VersionData FROM ContentVersion WHERE Id = :result.resultFileVersionId];
        return LeadUploadService.parseCsv(file.VersionData.toString());
    }

    /** Result and Reason of data row `index` (1 = first data row) in the results file. */
    private static List<String> outcome(List<List<String>> results, Integer index) {
        List<String> cells = results[index];
        Integer size = cells.size();
        return new List<String>{ cells[size - 4], cells[size - 1] };
    }

    // =====================================================================
    // Successful rows
    // =====================================================================

    @IsTest
    static void createsB2cAndB2bLeadsLikeTheNewLeadScreen() {
        Map<String, String> individual = customer('Mehta', '+91 98300 12301');
        individual.put('Marital Status', 'married');
        individual.put('Date of Birth', '1990-08-25');
        individual.put('Anniversary Date', '2015-02-14');
        individual.put('Walk-In', 'Yes');
        Map<String, String> business = customer('Agarwal', '9830012302');
        business.put('Company', 'Agarwal Jewellers');

        Test.startTest();
        LeadUploadService.UploadResult result = upload(HEADER + '\n' + row(individual) + '\n' + row(business) + '\n');
        Test.stopTest();

        Assert.isTrue(result.isFileValid, 'The file is valid: ' + result.errorMessage);
        Assert.areEqual(2, result.totalRows, 'Two customers');
        Assert.areEqual(2, result.leadsCreated, 'Both become Leads');
        Assert.areEqual(0, result.failedRows, 'Nothing failed');

        Lead b2c = [SELECT Company, Business_Type__c, Lead_Number__c, Phone, Description, Marital_Status__c,
                    Anniversary_Date__c, Walk_In_Flag__c, Status
                    FROM Lead WHERE LastName = 'Mehta' WITH SYSTEM_MODE];
        Assert.areEqual('B2C', b2c.Business_Type__c, 'No company means B2C');
        Assert.areEqual('Test Mehta - B2C-' + b2c.Lead_Number__c, b2c.Company, 'With the unique B2C company');
        Assert.areEqual('+91 98300 12301', b2c.Phone, 'Phone saved exactly as written');
        Assert.areEqual('Gold necklace', b2c.Description, 'Product Description saved');
        Assert.areEqual('Married', b2c.Marital_Status__c, 'Picklist matched regardless of case');
        Assert.areEqual(Date.newInstance(2015, 2, 14), b2c.Anniversary_Date__c, 'Anniversary saved');
        Assert.isTrue(b2c.Walk_In_Flag__c, 'Yes means walk-in');
        Assert.areEqual('New', b2c.Status, 'Status defaults to New');

        Lead b2b = [SELECT Company, Business_Type__c FROM Lead WHERE LastName = 'Agarwal' WITH SYSTEM_MODE];
        Assert.areEqual('Agarwal Jewellers', b2b.Company, 'Company kept');
        Assert.areEqual('B2B', b2b.Business_Type__c, 'A company means B2B');

        List<List<String>> results = resultsOf(result);
        Assert.areEqual('Result', results[0][results[0].size() - 4], 'Result columns are added to the header');
        Assert.areEqual('Lead Created', outcome(results, 1)[0], 'Row result written');
    }

    @IsTest
    static void resolvesStoreCodeAndCampaignName() {
        Store_Location__c store = new Store_Location__c(Name = 'Park Street', Store_Code__c = 'KOL-01');
        insert store;
        Campaign diwali = new Campaign(Name = 'Diwali 2026', IsActive = true);
        insert diwali;
        Map<String, String> cells = customer('Bose', '9830012303');
        cells.put('Store Code', 'kol-01');
        cells.put('Campaign Name', 'Diwali 2026');

        Test.startTest();
        LeadUploadService.UploadResult result = upload(HEADER + '\n' + row(cells));
        Test.stopTest();

        Assert.areEqual(1, result.leadsCreated, 'Created: ' + outcome(resultsOf(result), 1));
        Lead saved = [SELECT Store_Association__c, Campaign_Attribution__c FROM Lead WHERE LastName = 'Bose' WITH SYSTEM_MODE];
        Assert.areEqual(store.Id, saved.Store_Association__c, 'Store found by its code, ignoring case');
        Assert.areEqual(diwali.Id, saved.Campaign_Attribution__c, 'Campaign found by name');
    }

    @IsTest
    static void anExistingCustomerGetsAnEnquiryInsteadOfALead() {
        Account household = new Account(Name = 'Sharma Household', Phone = '9830012355');
        insert household;
        Map<String, String> cells = customer('Sharma', '+91-98300-12355');
        cells.put('Lead Source', 'Walk-in');

        Test.startTest();
        LeadUploadService.UploadResult result = upload(HEADER + '\n' + row(cells));
        Test.stopTest();

        Assert.areEqual(0, result.leadsCreated, 'No Lead for an existing customer');
        Assert.areEqual(1, result.enquiriesRaised, 'An enquiry instead');
        Case enquiry = [SELECT AccountId, Origin, Priority, Type, Description, Lead_Source__c, Subject
                        FROM Case WITH SYSTEM_MODE LIMIT 1];
        Assert.areEqual(household.Id, enquiry.AccountId, 'On the customer');
        Assert.areEqual('Phone', enquiry.Origin, 'Origin Phone, as on the screen');
        Assert.areEqual('Medium', enquiry.Priority, 'Priority Medium');
        Assert.areEqual('Enquiry', enquiry.Type, 'Type Enquiry');
        Assert.areEqual('Gold necklace', enquiry.Description, 'Product Description carried over');
        Assert.areEqual('Walk-in', enquiry.Lead_Source__c, 'Lead Source carried over');
        Assert.areEqual('Enquiry from Test Sharma', enquiry.Subject, 'Subject filled in');

        List<String> rowOutcome = outcome(resultsOf(result), 1);
        Assert.areEqual('Enquiry Raised', rowOutcome[0], 'Reported as an enquiry');
        Assert.isTrue(rowOutcome[1].contains('Sharma Household'), 'Naming the customer: ' + rowOutcome[1]);
    }

    // =====================================================================
    // Failed rows
    // =====================================================================

    @IsTest
    static void invalidRowsAreNotSavedAndExplainWhy() {
        Map<String, String> noLastName = customer('', '9830012311');
        Map<String, String> shortPhone = customer('Short', '98300 123');
        Map<String, String> excelPhone = customer('Excel', '9.19830E+11');
        Map<String, String> noProduct = customer('NoProduct', '9830012312');
        noProduct.put('Product Description', '');
        Map<String, String> futureBirth = customer('Future', '9830012313');
        futureBirth.put('Date of Birth', String.valueOf(Date.today().addDays(1)));
        Map<String, String> unmarried = customer('Single', '9830012314');
        unmarried.put('Marital Status', 'Unmarried');
        unmarried.put('Anniversary Date', '2015-02-14');
        Map<String, String> earlyAnniversary = customer('Early', '9830012315');
        earlyAnniversary.put('Marital Status', 'Married');
        earlyAnniversary.put('Date of Birth', '1990-08-25');
        earlyAnniversary.put('Anniversary Date', '1990-08-25');
        Map<String, String> badDate = customer('BadDate', '9830012316');
        badDate.put('Date of Birth', '25/08/1990');
        Map<String, String> badSource = customer('BadSource', '9830012317');
        badSource.put('Lead Source', 'Newspaper');
        Map<String, String> badStore = customer('BadStore', '9830012318');
        badStore.put('Store Code', 'NOPE');

        List<String> lines = new List<String>{ HEADER };
        for (Map<String, String> cells : new List<Map<String, String>>{
            noLastName, shortPhone, excelPhone, noProduct, futureBirth, unmarried, earlyAnniversary, badDate, badSource, badStore
        }) {
            lines.add(row(cells));
        }

        Test.startTest();
        LeadUploadService.UploadResult result = upload(String.join(lines, '\r\n'));
        Test.stopTest();

        Assert.areEqual(10, result.failedRows, 'Every row fails');
        Assert.areEqual(0, result.leadsCreated, 'And nothing is saved');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'No Leads in the org');

        List<List<String>> results = resultsOf(result);
        List<String> expectedReasons = new List<String>{
            'Last Name is required', '10-digit', 'scientific notation', 'Product Description is required',
            'Date of Birth cannot be in the future', 'only be given when Marital Status is Married',
            'must be after the Date of Birth', 'YYYY-MM-DD', 'not a valid Lead Source', 'Store Code'
        };
        for (Integer i = 0; i < expectedReasons.size(); i++) {
            List<String> rowOutcome = outcome(results, i + 1);
            Assert.areEqual('Failed', rowOutcome[0], 'Row ' + (i + 1) + ' failed');
            Assert.isTrue(rowOutcome[1].contains(expectedReasons[i]), 'Row ' + (i + 1) + ' reason: ' + rowOutcome[1]);
        }
    }

    @IsTest
    static void duplicatesAreRefused() {
        insert new Lead(LastName = 'Kapoor', Company = 'Kapoor Traders', Phone = '9830012377');
        Map<String, String> openLead = customer('Kapoor', '+91 98300 12377');
        Map<String, String> first = customer('First', '9830012321');
        first.put('Email', 'same@upload.example.com');
        Map<String, String> repeat = customer('Repeat', '9830012322');
        repeat.put('Email', 'SAME@upload.example.com');

        Test.startTest();
        LeadUploadService.UploadResult result = upload(HEADER + '\n' + row(openLead) + '\n' + row(first) + '\n' + row(repeat));
        Test.stopTest();

        Assert.areEqual(1, result.leadsCreated, 'Only the first new person is saved');
        Assert.areEqual(2, result.failedRows, 'The open Lead and the repeat fail');
        List<List<String>> results = resultsOf(result);
        Assert.isTrue(outcome(results, 1)[1].contains('already exists'), 'Open Lead reported: ' + outcome(results, 1)[1]);
        Assert.isTrue(outcome(results, 3)[1].contains('row 3'), 'Repeat points to its first row: ' + outcome(results, 3)[1]);
    }

    // =====================================================================
    // The file itself
    // =====================================================================

    @IsTest
    static void aFileWithoutTheRequiredColumnsIsRefused() {
        Test.startTest();
        LeadUploadService.UploadResult result = upload('First Name,Email\nAsha,asha@upload.example.com');
        Test.stopTest();

        Assert.isFalse(result.isFileValid, 'Refused');
        Assert.isTrue(result.errorMessage.contains('Last Name, Phone, Product Description'), result.errorMessage);
    }

    @IsTest
    static void anEmptyOrHeaderOnlyFileIsRefused() {
        Test.startTest();
        LeadUploadService.UploadResult headerOnly = upload(HEADER + '\n\n');
        Test.stopTest();

        Assert.isFalse(headerOnly.isFileValid, 'Nothing to upload');
        Assert.isTrue(headerOnly.errorMessage.contains('no customers'), headerOnly.errorMessage);
    }

    @IsTest
    static void aFileOverTheRowLimitIsRefused() {
        List<String> lines = new List<String>{ HEADER };
        for (Integer i = 0; i <= LeadUploadService.MAX_ROWS; i++) {
            lines.add('Mr.,A,B,9830012345,,,,,,,,Ring');
        }

        Test.startTest();
        LeadUploadService.UploadResult result = upload(String.join(lines, '\n'));
        Test.stopTest();

        Assert.isFalse(result.isFileValid, 'Too many rows');
        Assert.isTrue(result.errorMessage.contains('split it'), result.errorMessage);
    }

    @IsTest
    static void aFileThatIsNotCsvIsRefused() {
        ContentVersion file = new ContentVersion(Title = 'leads', PathOnClient = 'leads.xlsx', VersionData = Blob.valueOf('x'));
        insert file;
        LeadUploadService.UploadRequest request = new LeadUploadService.UploadRequest();
        request.contentDocumentIds = new List<String>{
            [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :file.Id].ContentDocumentId
        };

        Test.startTest();
        LeadUploadService.UploadResult result = LeadUploadService.upload(new List<LeadUploadService.UploadRequest>{ request })[0];
        Test.stopTest();

        Assert.isFalse(result.isFileValid, 'Only CSV');
        Assert.isTrue(result.errorMessage.contains('.csv'), result.errorMessage);
    }

    // =====================================================================
    // CSV reading
    // =====================================================================

    @IsTest
    static void readsQuotedCellsWithCommasQuotesAndLineBreaks() {
        String bom = String.fromCharArray(new List<Integer>{ 65279 });
        List<List<String>> table = LeadUploadService.parseCsv(
            bom + 'A,B,C\r\n"Ring, gold","She said ""hi""","line one\nline two"\r\nplain,,end'
        );

        Assert.areEqual(3, table.size(), 'Header and two rows');
        Assert.areEqual('A', table[0][0], 'Byte-order mark removed');
        Assert.areEqual('Ring, gold', table[1][0], 'Comma inside quotes');
        Assert.areEqual('She said "hi"', table[1][1], 'Doubled quotes');
        Assert.areEqual('line one\nline two', table[1][2], 'Line break inside quotes');
        Assert.areEqual('', table[2][1], 'Empty cell kept');
    }

    @IsTest
    static void matchesHeadersLooselyAndRefusesImpossibleDates() {
        Assert.areEqual('dateofbirth', LeadUploadService.columnKey('Date of Birth (YYYY-MM-DD)'), 'Brackets ignored');
        Assert.areEqual('lastname', LeadUploadService.columnKey(' Last Name * '), 'Asterisk and spaces ignored');
        Assert.areEqual('walkin', LeadUploadService.columnKey('Walk-In (Yes/No)'), 'Punctuation ignored');
        Assert.areEqual(Date.newInstance(1990, 8, 25), LeadUploadService.parseDate('1990-08-25', 'Date'), 'Valid date');
        try {
            LeadUploadService.parseDate('2026-02-30', 'Date');
            Assert.fail('30 February is not a date');
        } catch (Exception e) {
            Assert.isTrue(e.getMessage().contains('YYYY-MM-DD'), e.getMessage());
        }
    }
}
