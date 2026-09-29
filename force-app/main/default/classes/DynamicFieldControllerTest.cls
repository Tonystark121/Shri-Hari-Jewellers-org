/**
 * Tests for DynamicFieldController.
 *
 * Uses only Account fields the test user can already read (Name, Industry,
 * Last_12M_Spend__c, CreatedDate, WA_Opt_In__c), because searches run in user
 * mode and new fields have no field-level access until it is granted.
 */
@IsTest
private class DynamicFieldControllerTest {

    private static final String COLUMNS = 'Name,Industry,Last_12M_Spend__c';

    @TestSetup
    static void makeData() {
        insert new List<Account>{
            new Account(Name = 'Alpha Jewellers', Industry = 'Retail', Last_12M_Spend__c = 10000),
            new Account(Name = 'Beta Traders', Industry = 'Finance', Last_12M_Spend__c = 30000),
            new Account(Name = 'Gamma Stores', Last_12M_Spend__c = 100)
        };
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    private static Map<String, Object> rule(String field, String operator, String value) {
        return new Map<String, Object>{ 'field' => field, 'operator' => operator, 'value' => value };
    }

    private static Map<String, Object> rangeRule(String field, String valueFrom, String valueTo) {
        return new Map<String, Object>{ 'field' => field, 'operator' => 'between', 'value' => valueFrom, 'valueTo' => valueTo };
    }

    private static Map<String, Object> listRule(String field, String operator, List<String> values) {
        return new Map<String, Object>{ 'field' => field, 'operator' => operator, 'values' => values };
    }

    private static Set<String> namesFound(List<Map<String, Object>> rules, String logic) {
        DynamicFieldController.SearchResult result =
            DynamicFieldController.searchRecords('Account', COLUMNS, JSON.serialize(rules), logic);
        Set<String> names = new Set<String>();
        for (Map<String, Object> row : result.records) {
            names.add((String) row.get('Name'));
        }
        return names;
    }

    private static String errorFor(List<Map<String, Object>> rules, String logic) {
        try {
            DynamicFieldController.searchRecords('Account', COLUMNS, JSON.serialize(rules), logic);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    // =====================================================================
    // Fields and picklist values
    // =====================================================================

    @IsTest
    static void listsFilterableFieldsWithTheirCategory() {
        Map<String, String> typeByField = new Map<String, String>();
        for (DynamicFieldController.FieldOption option : DynamicFieldController.getFilterFields('Account')) {
            typeByField.put(option.value, option.dataType);
        }

        Assert.areEqual('string', typeByField.get('Name'), 'Text fields are offered');
        Assert.areEqual('picklist', typeByField.get('Industry'), 'Picklists are offered');
        Assert.areEqual('currency', typeByField.get('Last_12M_Spend__c'), 'Currency fields are offered');
        Assert.areEqual('boolean', typeByField.get('WA_Opt_In__c'), 'Checkboxes are offered');
        Assert.areEqual('datetime', typeByField.get('CreatedDate'), 'Date/Time fields are offered');
        Assert.isFalse(typeByField.containsKey('ParentId'), 'Lookups are left out');
        Assert.isFalse(typeByField.containsKey('Description'), 'Long text cannot be filtered and is left out');
    }

    @IsTest
    static void returnsActivePicklistValues() {
        List<DynamicFieldController.PicklistOptionWrapper> values =
            DynamicFieldController.getPicklistValues('Account', 'Industry');

        Set<String> found = new Set<String>();
        for (DynamicFieldController.PicklistOptionWrapper value : values) {
            found.add(value.value);
        }
        Assert.isTrue(found.contains('Retail'), 'Industry values are returned');
        Assert.isTrue(DynamicFieldController.getPicklistValues('Account', 'Name').isEmpty(), 'A text field has no picklist values');
    }

    // =====================================================================
    // Search
    // =====================================================================

    @IsTest
    static void noRulesReturnsEveryRecordWithTheRequestedColumns() {
        DynamicFieldController.SearchResult result =
            DynamicFieldController.searchRecords('Account', COLUMNS, '[]', null);

        Assert.areEqual(3, result.records.size(), 'All records');
        Assert.isFalse(result.truncated, 'Well under the limit');
        Assert.areEqual(3, result.columns.size(), 'One column per requested field');
        Assert.areEqual('currency', result.columns[2].type, 'Currency columns format as currency');
        Assert.areEqual('Alpha Jewellers', result.records[0].get('Name'), 'Ordered by Name');
        Assert.isNotNull(result.records[0].get('Id'), 'Each row carries its Id for selection');
    }

    @IsTest
    static void filtersNumbersIncludingBetween() {
        Assert.areEqual(
            new Set<String>{ 'Alpha Jewellers', 'Beta Traders' },
            namesFound(new List<Map<String, Object>>{ rule('Last_12M_Spend__c', 'greaterThan', '5000') }, null),
            'Greater Than'
        );
        Assert.areEqual(
            new Set<String>{ 'Alpha Jewellers' },
            namesFound(new List<Map<String, Object>>{ rangeRule('Last_12M_Spend__c', '5000', '20000') }, null),
            'Between is inclusive of both ends'
        );
    }

    @IsTest
    static void filtersDatesOnTheCalendarDayOfADateTime() {
        String today = String.valueOf(Date.today());
        Assert.areEqual(
            3,
            namesFound(new List<Map<String, Object>>{ rangeRule('CreatedDate', today, today) }, null).size(),
            'Every record was created today'
        );
        Assert.areEqual(
            0,
            namesFound(new List<Map<String, Object>>{ rule('CreatedDate', 'lessThan', today) }, null).size(),
            'None before today'
        );
    }

    @IsTest
    static void filtersTextAndPicklists() {
        Assert.areEqual(
            new Set<String>{ 'Beta Traders' },
            namesFound(new List<Map<String, Object>>{ rule('Name', 'startWith', 'Beta') }, null),
            'Starts With'
        );
        Assert.areEqual(
            new Set<String>{ 'Gamma Stores' },
            namesFound(new List<Map<String, Object>>{ rule('Name', 'endWith', 'Stores') }, null),
            'Ends With'
        );
        Assert.areEqual(
            new Set<String>{ 'Alpha Jewellers' },
            namesFound(new List<Map<String, Object>>{ rule('Name', 'contains', 'Jewel') }, null),
            'Contains'
        );
        Assert.areEqual(
            new Set<String>{ 'Alpha Jewellers', 'Gamma Stores' },
            namesFound(new List<Map<String, Object>>{ rule('Name', 'in', 'Alpha Jewellers, Gamma Stores') }, null),
            'In takes comma-separated values'
        );
        Assert.areEqual(
            new Set<String>{ 'Alpha Jewellers', 'Beta Traders' },
            namesFound(new List<Map<String, Object>>{ listRule('Industry', 'in', new List<String>{ 'Retail', 'Finance' }) }, null),
            'Picklist In'
        );
        Assert.areEqual(
            new Set<String>{ 'Beta Traders', 'Gamma Stores' },
            namesFound(new List<Map<String, Object>>{ rule('Industry', 'doesNotEquals', 'Retail') }, null),
            'Does Not Equal includes blanks'
        );
        Assert.areEqual(
            new Set<String>{ 'Gamma Stores' },
            namesFound(new List<Map<String, Object>>{ rule('Industry', 'isNull', 'True') }, null),
            'Is Null True'
        );
        Assert.areEqual(
            3,
            namesFound(new List<Map<String, Object>>{ rule('WA_Opt_In__c', 'equals', 'False') }, null).size(),
            'Checkbox equals False'
        );
    }

    @IsTest
    static void combinesRulesWithRuleLogic() {
        List<Map<String, Object>> rules = new List<Map<String, Object>>{
            rule('Last_12M_Spend__c', 'greaterThan', '5000'),
            rule('Industry', 'equals', 'Finance'),
            rule('Name', 'startWith', 'Gamma')
        };

        Assert.areEqual(0, namesFound(rules, '').size(), 'Blank logic ANDs every rule: nobody matches all three');
        Assert.areEqual(
            new Set<String>{ 'Beta Traders', 'Gamma Stores' },
            namesFound(rules, '(1 AND 2) OR 3'),
            'Custom logic'
        );
        Assert.areEqual(
            new Set<String>{ 'Alpha Jewellers', 'Beta Traders', 'Gamma Stores' },
            namesFound(rules, '1 or 2 or 3'),
            'Logic is case-insensitive'
        );
    }

    // =====================================================================
    // Errors
    // =====================================================================

    @IsTest
    static void rejectsInvalidRuleLogic() {
        List<Map<String, Object>> rules = new List<Map<String, Object>>{
            rule('Name', 'contains', 'a'),
            rule('Name', 'contains', 'e')
        };

        Assert.isTrue(errorFor(rules, '1 AND 2 OR 1').contains('parentheses'), 'Mixing AND and OR needs parentheses');
        Assert.isTrue(errorFor(rules, '1').contains('Rule 2 is not used'), 'Every rule must be used');
        Assert.isTrue(errorFor(rules, '1 AND 3').contains('only 2 rule'), 'Rule numbers must exist');
        Assert.isTrue(errorFor(rules, '1 AND DROP 2').contains('can only contain'), 'Only numbers, AND, OR and parentheses');
        Assert.isTrue(errorFor(rules, '(1 AND 2').contains('without a closing'), 'Parentheses must balance');
        Assert.isTrue(errorFor(rules, '1 AND 2)').contains('without an opening'), 'Parentheses must balance');
        Assert.isTrue(errorFor(rules, '1 AND').contains('cannot end'), 'Logic cannot end with an operator');
        Assert.isTrue(errorFor(rules, '1 2').contains('missing AND or OR'), 'Numbers must be joined');
    }

    @IsTest
    static void rejectsInvalidRules() {
        Assert.isTrue(
            errorFor(new List<Map<String, Object>>{ rule('Last_12M_Spend__c', 'startWith', '5') }, null).contains('valid operator'),
            'Operator must suit the field type'
        );
        Assert.isTrue(
            errorFor(new List<Map<String, Object>>{ rangeRule('Last_12M_Spend__c', '900', '100') }, null).contains('From value'),
            'From must not be after To'
        );
        Assert.isTrue(
            errorFor(new List<Map<String, Object>>{ rule('Last_12M_Spend__c', 'greaterThan', 'lots') }, null).contains('not a valid value'),
            'Numbers must be numbers'
        );
        Assert.isTrue(
            errorFor(new List<Map<String, Object>>{ rule('Name', 'equals', '') }, null).contains('enter a value'),
            'A value is required'
        );
        Assert.isTrue(
            errorFor(new List<Map<String, Object>>{ rule('No_Such_Field__c', 'equals', 'x') }, null).contains('not available'),
            'Unknown fields are refused'
        );
        Assert.isTrue(
            errorFor(new List<Map<String, Object>>{ rule('Industry', 'isNull', 'Maybe') }, null).contains('True or False'),
            'Is Null takes True or False'
        );
    }

    // =====================================================================
    // Voucher code
    // =====================================================================

    @IsTest
    static void defaultPrefixHasTheDocumentedFormat() {
        Pattern format = Pattern.compile('^GV-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$');

        DynamicFieldController.VoucherCodeResult result = DynamicFieldController.generateVoucherCodes(
            new List<DynamicFieldController.VoucherCodeRequest>{ new DynamicFieldController.VoucherCodeRequest() }
        )[0];

        Assert.isTrue(format.matcher(result.defaultPrefix).matches(), 'Unexpected prefix: ' + result.defaultPrefix);
        Assert.isTrue(result.vouchers.isEmpty(), 'No vouchers without Accounts');
        Assert.isTrue(format.matcher(DynamicFieldController.newVoucherCodePrefix()).matches(), 'The LWC button gets the same format');
    }

    @IsTest
    static void buildsOneVoucherPerAccountWithUniqueCodes() {
        List<String> accountIds = new List<String>();
        for (Account a : [SELECT Id FROM Account ORDER BY Name]) {
            accountIds.add(a.Id);
        }

        DynamicFieldController.VoucherCodeRequest request = new DynamicFieldController.VoucherCodeRequest();
        request.codePrefix = '  ANNMAY26 ';
        request.accountIds = accountIds;
        List<Gift_Voucher__c> vouchers = DynamicFieldController.generateVoucherCodes(
            new List<DynamicFieldController.VoucherCodeRequest>{ request }
        )[0].vouchers;

        Assert.areEqual(3, vouchers.size(), 'One voucher per Account');
        Pattern format = Pattern.compile('^ANNMAY26-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$');
        Set<String> codes = new Set<String>();
        for (Integer i = 0; i < vouchers.size(); i++) {
            Assert.areEqual(accountIds[i], vouchers[i].Account__c, 'Vouchers follow the Account order');
            Assert.isTrue(format.matcher(vouchers[i].Voucher_Code__c).matches(), 'Unexpected code: ' + vouchers[i].Voucher_Code__c);
            Assert.isNull(vouchers[i].Id, 'The flow saves them, not this method');
            codes.add(vouchers[i].Voucher_Code__c);
        }
        Assert.areEqual(3, codes.size(), 'Every code is different');
    }

    @IsTest
    static void rejectsBlankOrTooLongVoucherCode() {
        List<String> accountIds = new List<String>{ [SELECT Id FROM Account LIMIT 1].Id };
        for (String badPrefix : new List<String>{ '  ', 'X'.repeat(46) }) {
            try {
                DynamicFieldController.vouchersWithUniqueCodes(badPrefix, accountIds);
                Assert.fail('Should reject prefix "' + badPrefix + '"');
            } catch (DynamicFieldController.VoucherCodeException e) {
                Assert.isTrue(e.getMessage().contains('Voucher Code'), 'Readable message');
            }
        }
    }

    // =====================================================================
    // Day-and-month date operators
    // =====================================================================

    @IsTest
    static void filtersDatesIgnoringTheYear() {
        String thisMonth = String.valueOf(Date.today().month());
        String otherMonth = String.valueOf(Date.today().addMonths(6).month());

        Assert.areEqual(3, namesFound(new List<Map<String, Object>>{ rule('CreatedDate', 'inMonth', thisMonth) }, null).size(), 'In Month: created this month');
        Assert.areEqual(0, namesFound(new List<Map<String, Object>>{ rule('CreatedDate', 'inMonth', otherMonth) }, null).size(), 'In Month: nobody in another month');
        Assert.areEqual(3, namesFound(new List<Map<String, Object>>{ rule('CreatedDate', 'thisMonthAnyYear', null) }, null).size(), 'This Month');
        Assert.areEqual(0, namesFound(new List<Map<String, Object>>{ rule('CreatedDate', 'nextMonthAnyYear', null) }, null).size(), 'Next Month');
        Assert.areEqual(3, namesFound(new List<Map<String, Object>>{ rule('CreatedDate', 'nextNDaysAnyYear', '1') }, null).size(), 'Next N Days includes today');
        Assert.areEqual(3, namesFound(new List<Map<String, Object>>{ rule('CreatedDate', 'nextNDaysAnyYear', '90') }, null).size(), 'Ranges across months are OR-ed');
    }

    @IsTest
    static void rejectsInvalidDayAndMonthValues() {
        Assert.isTrue(
            errorFor(new List<Map<String, Object>>{ rule('CreatedDate', 'inMonth', '13') }, null).contains('choose a month'),
            'Month must be 1-12'
        );
        Assert.isTrue(
            errorFor(new List<Map<String, Object>>{ rule('CreatedDate', 'nextNDaysAnyYear', '91') }, null).contains('from 1 to 90'),
            'Days must be 1-90'
        );
        Assert.isTrue(
            errorFor(new List<Map<String, Object>>{ rule('Last_12M_Spend__c', 'inMonth', '5') }, null).contains('valid operator'),
            'Only date fields take month operators'
        );
    }

    @IsTest
    static void rejectsUnknownObject() {
        try {
            DynamicFieldController.getFilterFields('No_Such_Object__c');
            Assert.fail('An unknown object should be refused');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not available'), 'Readable message');
        }
    }
}
