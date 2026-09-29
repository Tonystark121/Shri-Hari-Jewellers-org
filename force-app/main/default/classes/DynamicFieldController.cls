/**
 * @description
 * Server side of the dynamicFieldSelection LWC: which fields of an object can
 * be filtered, their picklist values, and the search that turns the rules a
 * user built on screen into a query. Also generates the voucher codes for the
 * Create Gift Voucher flow (invocable action + a method for the LWC).
 *
 * Every field name is checked against the object's describe and every value
 * reaches SOQL as a bind variable (multi-select picklist values, which SOQL
 * cannot bind, are checked against the field's own values first), so nothing
 * typed in the browser becomes query text. Searches run in user mode: a user
 * only finds records and fields their access allows.
 *
 * Rule operators (the values the LWC sends):
 *   equals, doesNotEquals, greaterThan, lessThan, greaterThanOrEqual,
 *   lessThanOrEqual, between, startWith, endWith, contains, in,
 *   includes, excludes, isNull
 * Date and Date/Time fields also accept, comparing day and month only
 * (e.g. birthdays and anniversaries):
 *   inMonth (value 1-12), thisMonthAnyYear, nextMonthAnyYear,
 *   nextNDaysAnyYear (value 1-90: today through today + N days)
 */
public with sharing class DynamicFieldController {

    @TestVisible
    private static final Integer MAX_RECORDS = 2000;

    // Normalised data types the LWC understands, keyed by the platform type.
    private static final Map<Schema.DisplayType, String> TYPE_CATEGORIES = new Map<Schema.DisplayType, String>{
        Schema.DisplayType.STRING        => 'string',
        Schema.DisplayType.EMAIL         => 'string',
        Schema.DisplayType.PHONE         => 'string',
        Schema.DisplayType.URL           => 'string',
        Schema.DisplayType.TEXTAREA      => 'string',
        Schema.DisplayType.COMBOBOX      => 'string',
        Schema.DisplayType.PICKLIST      => 'picklist',
        Schema.DisplayType.MULTIPICKLIST => 'multipicklist',
        Schema.DisplayType.BOOLEAN       => 'boolean',
        Schema.DisplayType.CURRENCY      => 'currency',
        Schema.DisplayType.DOUBLE        => 'number',
        Schema.DisplayType.INTEGER       => 'number',
        Schema.DisplayType.LONG          => 'number',
        Schema.DisplayType.PERCENT       => 'percent',
        Schema.DisplayType.DATE          => 'date',
        Schema.DisplayType.DATETIME      => 'datetime'
    };

    private static final Set<String> NUMERIC_OPERATORS = new Set<String>{
        'equals', 'doesNotEquals', 'greaterThan', 'lessThan',
        'greaterThanOrEqual', 'lessThanOrEqual', 'between', 'isNull'
    };

    // Date operators that ignore the year (birthdays, anniversaries).
    private static final Set<String> ANY_YEAR_OPERATORS = new Set<String>{
        'inMonth', 'thisMonthAnyYear', 'nextMonthAnyYear', 'nextNDaysAnyYear'
    };

    private static final Set<String> DATE_OPERATORS = new Set<String>{
        'equals', 'doesNotEquals', 'greaterThan', 'lessThan',
        'greaterThanOrEqual', 'lessThanOrEqual', 'between', 'isNull',
        'inMonth', 'thisMonthAnyYear', 'nextMonthAnyYear', 'nextNDaysAnyYear'
    };

    @TestVisible
    private static final Integer MAX_NEXT_DAYS = 90;

    // Operators each category accepts. Mirrors fieldToOperatorsMap in the LWC.
    private static final Map<String, Set<String>> OPERATORS_BY_CATEGORY = new Map<String, Set<String>>{
        'string'        => new Set<String>{ 'equals', 'doesNotEquals', 'startWith', 'endWith', 'contains', 'in', 'isNull' },
        'picklist'      => new Set<String>{ 'equals', 'doesNotEquals', 'in', 'isNull' },
        'multipicklist' => new Set<String>{ 'includes', 'excludes', 'isNull' },
        'boolean'       => new Set<String>{ 'equals' },
        'currency'      => NUMERIC_OPERATORS,
        'number'        => NUMERIC_OPERATORS,
        'percent'       => NUMERIC_OPERATORS,
        'date'          => DATE_OPERATORS,
        'datetime'      => DATE_OPERATORS
    };

    private static final Map<String, String> COMPARISONS = new Map<String, String>{
        'equals'             => '=',
        'doesNotEquals'      => '!=',
        'greaterThan'        => '>',
        'lessThan'           => '<',
        'greaterThanOrEqual' => '>=',
        'lessThanOrEqual'    => '<='
    };

    // =====================================================================
    // Fields
    // =====================================================================

    public class FieldOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String dataType;
    }

    /**
     * @description
     * The fields of an object a user can filter on: accessible, filterable,
     * of a supported type, and not a lookup. Sorted by label.
     */
    @AuraEnabled(cacheable=true)
    public static List<FieldOption> getFilterFields(String objectApiName) {
        Map<String, Schema.SObjectField> fieldMap = describeObject(objectApiName).fields.getMap();

        List<FieldOption> options = new List<FieldOption>();
        for (Schema.SObjectField field : fieldMap.values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            String category = TYPE_CATEGORIES.get(describe.getType());
            if (category == null || !describe.isFilterable() || !describe.isAccessible()) {
                continue;
            }
            FieldOption option = new FieldOption();
            option.label = describe.getLabel();
            option.value = describe.getName();
            option.dataType = category;
            options.add(option);
        }
        options.sort(new FieldOptionByLabel());
        return options;
    }

    private class FieldOptionByLabel implements Comparator<FieldOption> {
        public Integer compare(FieldOption a, FieldOption b) {
            return a.label.compareTo(b.label);
        }
    }

    /**
     * @description
     * Active picklist values (label + value) of a picklist or multi-select
     * picklist field, for populating the value selector.
     */
    @AuraEnabled(cacheable=true)
    public static List<PicklistOptionWrapper> getPicklistValues(String objectApiName, String fieldApiName) {
        List<PicklistOptionWrapper> options = new List<PicklistOptionWrapper>();
        Schema.DescribeFieldResult describe = describeField(describeObject(objectApiName), fieldApiName);

        Schema.DisplayType fieldType = describe.getType();
        if (fieldType == Schema.DisplayType.PICKLIST || fieldType == Schema.DisplayType.MULTIPICKLIST) {
            for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
                if (entry.isActive()) {
                    options.add(new PicklistOptionWrapper(entry.getLabel(), entry.getValue()));
                }
            }
        }
        return options;
    }

    /**
     * @description
     * Wrapper class to hold a picklist option's label and value.
     */
    public class PicklistOptionWrapper {
        @AuraEnabled public String label;
        @AuraEnabled public String value;

        public PicklistOptionWrapper(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    // =====================================================================
    // Search
    // =====================================================================

    /** One rule as the LWC sends it. */
    public class FilterRule {
        public String field;
        public String operator;
        public String value;
        public String valueTo;
        public List<String> values;
    }

    public class ColumnInfo {
        @AuraEnabled public String label;
        @AuraEnabled public String fieldName;
        @AuraEnabled public String type;
    }

    public class SearchResult {
        @AuraEnabled public List<ColumnInfo> columns;
        @AuraEnabled public List<Map<String, Object>> records;
        @AuraEnabled public Boolean truncated;
    }

    /**
     * @description
     * Records of objectApiName matching the rules, at most MAX_RECORDS,
     * ordered by Name. truncated is true when more records matched.
     *
     * @param objectApiName  object to search, e.g. Account
     * @param columnFields   comma-separated fields to return for the table
     * @param rulesJson      JSON list of FilterRule, numbered 1..n in order
     * @param ruleLogic      e.g. "1 AND (2 OR 3)"; blank means all rules AND-ed
     */
    @AuraEnabled
    public static SearchResult searchRecords(String objectApiName, String columnFields, String rulesJson, String ruleLogic) {
        try {
            return runSearch(objectApiName, columnFields, rulesJson, ruleLogic);
        } catch (FilterException e) {
            throw auraError(e.getMessage());
        } catch (JSONException e) {
            throw auraError('The filter rules could not be read. Please rebuild them and try again.');
        } catch (QueryException e) {
            throw auraError('The records could not be searched: ' + e.getMessage());
        }
    }

    @TestVisible
    private class FilterException extends Exception {}

    private static SearchResult runSearch(String objectApiName, String columnFields, String rulesJson, String ruleLogic) {
        Schema.DescribeSObjectResult objectDescribe = describeObject(objectApiName);
        Map<String, Schema.SObjectField> fieldMap = objectDescribe.fields.getMap();

        // Columns ------------------------------------------------------------
        List<ColumnInfo> columns = new List<ColumnInfo>();
        List<String> selectFields = new List<String>{ 'Id' };
        for (String rawName : String.isBlank(columnFields) ? new List<String>() : columnFields.split(',')) {
            String fieldName = rawName.trim();
            if (String.isBlank(fieldName)) {
                continue;
            }
            Schema.DescribeFieldResult describe = describeField(objectDescribe, fieldName);
            ColumnInfo column = new ColumnInfo();
            column.label = describe.getLabel();
            column.fieldName = describe.getName();
            column.type = columnType(describe.getType());
            columns.add(column);
            selectFields.add(describe.getName());
        }

        // Rules --------------------------------------------------------------
        List<FilterRule> rules = String.isBlank(rulesJson)
            ? new List<FilterRule>()
            : (List<FilterRule>) JSON.deserialize(rulesJson, List<FilterRule>.class);

        Map<String, Object> binds = new Map<String, Object>();
        List<String> conditions = new List<String>();
        for (Integer i = 0; i < rules.size(); i++) {
            conditions.add(buildCondition(objectDescribe, rules[i], i + 1, binds));
        }

        String whereClause = conditions.isEmpty() ? '' : ' WHERE ' + applyLogic(conditions, ruleLogic);
        String orderBy = fieldMap.containsKey('name') ? ' ORDER BY Name' : ' ORDER BY CreatedDate DESC';

        String soql = 'SELECT ' + String.join(selectFields, ', ')
            + ' FROM ' + objectDescribe.getName()
            + whereClause + orderBy
            + ' LIMIT ' + (MAX_RECORDS + 1);

        List<SObject> found = Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);

        SearchResult result = new SearchResult();
        result.columns = columns;
        result.truncated = found.size() > MAX_RECORDS;
        result.records = new List<Map<String, Object>>();
        for (Integer i = 0; i < Math.min(found.size(), MAX_RECORDS); i++) {
            Map<String, Object> row = new Map<String, Object>{ 'Id' => found[i].Id };
            for (ColumnInfo column : columns) {
                row.put(column.fieldName, found[i].get(column.fieldName));
            }
            result.records.add(row);
        }
        return result;
    }

    /** SOQL for one rule. Values are added to binds under r<n>a / r<n>b. */
    @TestVisible
    private static String buildCondition(
        Schema.DescribeSObjectResult objectDescribe,
        FilterRule rule,
        Integer ruleNumber,
        Map<String, Object> binds
    ) {
        String prefix = 'Rule ' + ruleNumber + ': ';
        if (rule == null || String.isBlank(rule.field)) {
            throw new FilterException(prefix + 'choose a field.');
        }
        Schema.DescribeFieldResult describe = describeField(objectDescribe, rule.field);
        String category = TYPE_CATEGORIES.get(describe.getType());
        if (category == null || !describe.isFilterable()) {
            throw new FilterException(prefix + describe.getLabel() + ' cannot be used in a filter.');
        }
        if (String.isBlank(rule.operator) || !OPERATORS_BY_CATEGORY.get(category).contains(rule.operator)) {
            throw new FilterException(prefix + 'choose a valid operator for ' + describe.getLabel() + '.');
        }

        String fieldName = describe.getName();
        // Date inputs are compared with the calendar day of a Date/Time field.
        String leftSide = category == 'datetime' ? 'DAY_ONLY(' + fieldName + ')' : fieldName;
        String bindA = 'r' + ruleNumber + 'a';
        String bindB = 'r' + ruleNumber + 'b';
        String op = rule.operator;

        if (op == 'isNull') {
            Boolean isNull = parseBoolean(rule.value, prefix + 'choose True or False.');
            return '(' + fieldName + (isNull ? ' = null' : ' != null') + ')';
        }

        if (op == 'includes' || op == 'excludes') {
            List<String> chosen = requireValues(rule.values, prefix + 'choose at least one value.');
            Set<String> allowed = new Set<String>();
            for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
                allowed.add(entry.getValue());
            }
            List<String> quoted = new List<String>();
            for (String value : chosen) {
                if (!allowed.contains(value)) {
                    throw new FilterException(prefix + '\'' + value + '\' is not a value of ' + describe.getLabel() + '.');
                }
                quoted.add('\'' + String.escapeSingleQuotes(value) + '\'');
            }
            return '(' + fieldName + (op == 'includes' ? ' INCLUDES (' : ' EXCLUDES (') + String.join(quoted, ', ') + '))';
        }

        if (op == 'in') {
            List<String> chosen = category == 'picklist'
                ? requireValues(rule.values, prefix + 'choose at least one value.')
                : splitCommaList(rule.value, prefix + 'enter one or more values separated by commas.');
            binds.put(bindA, chosen);
            return '(' + fieldName + ' IN :' + bindA + ')';
        }

        if (op == 'startWith' || op == 'endWith' || op == 'contains') {
            String text = requireText(rule.value, prefix + 'enter a value.');
            String escaped = text.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_');
            String pattern = op == 'startWith' ? escaped + '%' : op == 'endWith' ? '%' + escaped : '%' + escaped + '%';
            binds.put(bindA, pattern);
            return '(' + fieldName + ' LIKE :' + bindA + ')';
        }

        if (ANY_YEAR_OPERATORS.contains(op)) {
            return anyYearCondition(category, fieldName, op, rule.value, ruleNumber, prefix, binds);
        }

        if (op == 'between') {
            Object low = typedValue(category, rule.value, prefix + 'enter the From value.');
            Object high = typedValue(category, rule.valueTo, prefix + 'enter the To value.');
            if (isGreater(low, high)) {
                throw new FilterException(prefix + 'the From value must not be after the To value.');
            }
            binds.put(bindA, low);
            binds.put(bindB, high);
            return '(' + leftSide + ' >= :' + bindA + ' AND ' + leftSide + ' <= :' + bindB + ')';
        }

        // equals, doesNotEquals and the four comparisons
        binds.put(bindA, typedValue(category, rule.value, prefix + 'enter a value.'));
        return '(' + leftSide + ' ' + COMPARISONS.get(op) + ' :' + bindA + ')';
    }

    /**
     * Day-and-month conditions that ignore the year, so a date of birth in
     * 1990 still matches "birthday next month". Date/Time fields are first
     * converted to the user's time zone.
     */
    private static String anyYearCondition(
        String category,
        String fieldName,
        String op,
        String rawValue,
        Integer ruleNumber,
        String prefix,
        Map<String, Object> binds
    ) {
        String dateExpression = category == 'datetime' ? 'convertTimezone(' + fieldName + ')' : fieldName;
        String monthExpression = 'CALENDAR_MONTH(' + dateExpression + ')';
        String dayExpression = 'DAY_IN_MONTH(' + dateExpression + ')';
        Date today = Date.today();

        if (op == 'inMonth' || op == 'thisMonthAnyYear' || op == 'nextMonthAnyYear') {
            Integer month;
            if (op == 'thisMonthAnyYear') {
                month = today.month();
            } else if (op == 'nextMonthAnyYear') {
                month = today.addMonths(1).month();
            } else {
                month = wholeNumber(rawValue, 1, 12, prefix + 'choose a month.');
            }
            String bindName = 'r' + ruleNumber + 'm';
            binds.put(bindName, month);
            return '(' + monthExpression + ' = :' + bindName + ')';
        }

        // nextNDaysAnyYear: today through today + N days, one day-range per
        // calendar month (at most four months for 90 days), OR-ed together.
        Integer days = wholeNumber(rawValue, 1, MAX_NEXT_DAYS, prefix + 'enter a number of days from 1 to ' + MAX_NEXT_DAYS + '.');
        List<String> monthRanges = new List<String>();
        Date rangeStart = today;
        Date lastDay = today.addDays(days);

        while (rangeStart <= lastDay) {
            Date monthEnd = rangeStart.toStartOfMonth().addMonths(1).addDays(-1);
            Date rangeEnd = monthEnd < lastDay ? monthEnd : lastDay;
            Integer rangeEndDay = rangeEnd.day();
            // A 29 February birthday is celebrated on 28 February in a non-leap year.
            if (rangeEnd.month() == 2 && rangeEndDay == 28 && !Date.isLeapYear(rangeEnd.year())) {
                rangeEndDay = 29;
            }

            String suffix = 'r' + ruleNumber + 'n' + monthRanges.size();
            binds.put(suffix + 'm', rangeStart.month());
            binds.put(suffix + 'f', rangeStart.day());
            binds.put(suffix + 't', rangeEndDay);
            monthRanges.add(
                '(' + monthExpression + ' = :' + suffix + 'm'
                + ' AND ' + dayExpression + ' >= :' + suffix + 'f'
                + ' AND ' + dayExpression + ' <= :' + suffix + 't)'
            );
            rangeStart = rangeEnd.addDays(1);
        }
        return '(' + String.join(monthRanges, ' OR ') + ')';
    }

    private static Integer wholeNumber(String raw, Integer minimum, Integer maximum, String message) {
        Integer value;
        try {
            value = Integer.valueOf(requireText(raw, message));
        } catch (FilterException e) {
            throw e;
        } catch (Exception e) {
            throw new FilterException(message);
        }
        if (value < minimum || value > maximum) {
            throw new FilterException(message);
        }
        return value;
    }

    /** Converts the text a user entered into the type the field compares with. */
    private static Object typedValue(String category, String raw, String missingMessage) {
        String value = requireText(raw, missingMessage);
        try {
            switch on category {
                when 'currency', 'number', 'percent' {
                    return Decimal.valueOf(value);
                }
                when 'date', 'datetime' {
                    return Date.valueOf(value);
                }
                when 'boolean' {
                    return parseBoolean(value, missingMessage);
                }
                when else {
                    return value;
                }
            }
        } catch (FilterException e) {
            throw e;
        } catch (Exception e) {
            throw new FilterException(missingMessage.substringBefore(':') + ': \'' + value + '\' is not a valid value.');
        }
    }

    private static Boolean isGreater(Object a, Object b) {
        if (a instanceof Date) {
            return (Date) a > (Date) b;
        }
        if (a instanceof Decimal) {
            return (Decimal) a > (Decimal) b;
        }
        return false;
    }

    private static Boolean parseBoolean(String raw, String message) {
        if (raw == 'True' || raw == 'true') {
            return true;
        }
        if (raw == 'False' || raw == 'false') {
            return false;
        }
        throw new FilterException(message);
    }

    private static String requireText(String raw, String message) {
        if (String.isBlank(raw)) {
            throw new FilterException(message);
        }
        return raw.trim();
    }

    private static List<String> requireValues(List<String> values, String message) {
        List<String> cleaned = new List<String>();
        if (values != null) {
            for (String value : values) {
                if (String.isNotBlank(value)) {
                    cleaned.add(value);
                }
            }
        }
        if (cleaned.isEmpty()) {
            throw new FilterException(message);
        }
        return cleaned;
    }

    private static List<String> splitCommaList(String raw, String message) {
        List<String> values = new List<String>();
        for (String part : requireText(raw, message).split(',')) {
            if (String.isNotBlank(part)) {
                values.add(part.trim());
            }
        }
        if (values.isEmpty()) {
            throw new FilterException(message);
        }
        return values;
    }

    // =====================================================================
    // Rule logic
    // =====================================================================

    /**
     * @description
     * Combines the rule conditions using ruleLogic, e.g. "1 AND (2 OR 3)".
     * Blank logic joins every rule with AND. The logic may only contain rule
     * numbers, AND, OR and parentheses; every rule must be used; AND and OR
     * cannot be mixed at the same level without parentheses (SOQL rejects it).
     */
    @TestVisible
    private static String applyLogic(List<String> conditions, String ruleLogic) {
        if (String.isBlank(ruleLogic)) {
            return String.join(conditions, ' AND ');
        }

        Matcher tokenMatcher = Pattern.compile('(?i)\\s*(\\(|\\)|\\d+|AND|OR)\\s*').matcher(ruleLogic);
        List<String> tokens = new List<String>();
        Integer position = 0;
        while (tokenMatcher.find()) {
            if (tokenMatcher.start() != position) {
                break;
            }
            tokens.add(tokenMatcher.group(1).toUpperCase());
            position = tokenMatcher.end();
        }
        if (position != ruleLogic.length() || tokens.isEmpty()) {
            throw new FilterException('Rule Logic can only contain rule numbers, AND, OR and parentheses, e.g. 1 AND (2 OR 3).');
        }

        List<String> output = new List<String>();
        Set<Integer> used = new Set<Integer>();
        List<String> levelOperators = new List<String>{ null };  // operator in use at each paren depth
        Boolean expectOperand = true;

        for (String token : tokens) {
            if (expectOperand) {
                if (token == '(') {
                    levelOperators.add(null);
                    output.add('(');
                } else if (token.isNumeric()) {
                    Integer ruleNumber = Integer.valueOf(token);
                    if (ruleNumber < 1 || ruleNumber > conditions.size()) {
                        throw new FilterException('Rule Logic refers to rule ' + token + ', but there are only ' + conditions.size() + ' rule(s).');
                    }
                    used.add(ruleNumber);
                    output.add(conditions[ruleNumber - 1]);
                    expectOperand = false;
                } else {
                    throw new FilterException('Rule Logic is incomplete near "' + token + '".');
                }
            } else {
                if (token == ')') {
                    if (levelOperators.size() == 1) {
                        throw new FilterException('Rule Logic has a closing parenthesis without an opening one.');
                    }
                    levelOperators.remove(levelOperators.size() - 1);
                    output.add(')');
                } else if (token == 'AND' || token == 'OR') {
                    Integer depth = levelOperators.size() - 1;
                    String current = levelOperators[depth];
                    if (current != null && current != token) {
                        throw new FilterException('Use parentheses when mixing AND and OR in Rule Logic, e.g. 1 AND (2 OR 3).');
                    }
                    levelOperators[depth] = token;
                    output.add(token);
                    expectOperand = true;
                } else {
                    throw new FilterException('Rule Logic is missing AND or OR near "' + token + '".');
                }
            }
        }

        if (expectOperand) {
            throw new FilterException('Rule Logic cannot end with AND, OR or an opening parenthesis.');
        }
        if (levelOperators.size() != 1) {
            throw new FilterException('Rule Logic has an opening parenthesis without a closing one.');
        }
        for (Integer i = 1; i <= conditions.size(); i++) {
            if (!used.contains(i)) {
                throw new FilterException('Rule ' + i + ' is not used in Rule Logic. Add it or delete the rule.');
            }
        }
        return String.join(output, ' ');
    }

    // =====================================================================
    // Voucher code
    // =====================================================================

    // Voucher_Code__c is Unique, so every voucher gets its own code:
    //   <prefix>-<4 random characters>, e.g. ANNMAY26-7KM3.
    // The prefix is what the user sees and may edit on the Voucher Details
    // screen; by default it is a random GV-XXXXXX.

    @TestVisible
    private static final String DEFAULT_PREFIX_START = 'GV-';
    @TestVisible
    private static final Integer DEFAULT_PREFIX_RANDOM_LENGTH = 6;
    @TestVisible
    private static final Integer SUFFIX_LENGTH = 4;
    @TestVisible
    private static final Integer MAX_PREFIX_LENGTH = 45;  // 50 (field length) - '-' - 4-character suffix
    private static final Integer MAX_CODE_ATTEMPTS = 5;
    // A-Z and 2-9 without the look-alikes 0/O and 1/I/L, so a code can be
    // read out at the counter without confusion.
    @TestVisible
    private static final String VOUCHER_CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

    public class VoucherCodeRequest {
        @InvocableVariable(label='Voucher Code Prefix' description='Code entered on the Voucher Details screen. Leave blank to get a default prefix.')
        public String codePrefix;

        @InvocableVariable(label='Account Ids' description='Selected Accounts. Leave blank to get a default prefix.')
        public List<String> accountIds;
    }

    public class VoucherCodeResult {
        @InvocableVariable(label='Default Voucher Code Prefix' description='Random prefix such as GV-7KM3QX, returned when no Account Ids are passed.')
        public String defaultPrefix;

        @InvocableVariable(label='Vouchers' description='One unsaved Gift Voucher per Account, with Account and a unique Voucher Code filled in.')
        public List<Gift_Voucher__c> vouchers;
    }

    public class VoucherCodeException extends Exception {}

    /**
     * @description
     * Two uses in the Create Gift Voucher flow:
     *   - no Account Ids: returns a random default prefix for the Voucher
     *     Details screen;
     *   - prefix and Account Ids: returns one unsaved Gift Voucher per Account
     *     with a Voucher Code of prefix-XXXX that no existing voucher (and no
     *     other voucher in the list) already uses. The flow fills in the
     *     remaining fields and creates them.
     */
    @InvocableMethod(
        label='Generate Gift Voucher Codes'
        description='Returns a default voucher code prefix, or one Gift Voucher per Account with a unique Voucher Code (prefix-XXXX).'
        category='Gift Voucher'
    )
    public static List<VoucherCodeResult> generateVoucherCodes(List<VoucherCodeRequest> requests) {
        List<VoucherCodeResult> results = new List<VoucherCodeResult>();
        for (VoucherCodeRequest request : requests) {
            VoucherCodeResult result = new VoucherCodeResult();
            if (request.accountIds == null || request.accountIds.isEmpty()) {
                result.defaultPrefix = newDefaultPrefix();
                result.vouchers = new List<Gift_Voucher__c>();
            } else {
                result.vouchers = vouchersWithUniqueCodes(request.codePrefix, request.accountIds);
            }
            results.add(result);
        }
        return results;
    }

    /** A fresh random prefix, for the "Generate new code" button on the Voucher Details screen. */
    @AuraEnabled
    public static String newVoucherCodePrefix() {
        return newDefaultPrefix();
    }

    @TestVisible
    private static String newDefaultPrefix() {
        return DEFAULT_PREFIX_START + randomCharacters(DEFAULT_PREFIX_RANDOM_LENGTH);
    }

    @TestVisible
    private static List<Gift_Voucher__c> vouchersWithUniqueCodes(String codePrefix, List<String> accountIds) {
        String prefix = codePrefix == null ? '' : codePrefix.trim();
        if (String.isBlank(prefix)) {
            throw new VoucherCodeException('Voucher Code is required.');
        }
        if (prefix.length() > MAX_PREFIX_LENGTH) {
            throw new VoucherCodeException('Voucher Code can be at most ' + MAX_PREFIX_LENGTH + ' characters.');
        }

        List<String> codes = new List<String>();
        for (Integer i = 0; i < accountIds.size(); i++) {
            codes.add(null);
        }

        // Fill every empty slot with a random code, then empty the slots whose
        // code repeats one in the list or one already saved, and try again.
        for (Integer attempt = 0; attempt < MAX_CODE_ATTEMPTS; attempt++) {
            for (Integer i = 0; i < codes.size(); i++) {
                if (codes[i] == null) {
                    codes[i] = prefix + '-' + randomCharacters(SUFFIX_LENGTH);
                }
            }

            Set<String> taken = new Set<String>();
            for (Gift_Voucher__c existing : [
                SELECT Voucher_Code__c
                FROM Gift_Voucher__c
                WHERE Voucher_Code__c IN :codes
                WITH SYSTEM_MODE
            ]) {
                taken.add(existing.Voucher_Code__c.toUpperCase());
            }

            Boolean allUnique = true;
            Set<String> seen = new Set<String>();
            for (Integer i = 0; i < codes.size(); i++) {
                String key = codes[i].toUpperCase();
                if (taken.contains(key) || seen.contains(key)) {
                    codes[i] = null;
                    allUnique = false;
                } else {
                    seen.add(key);
                }
            }
            if (allUnique) {
                List<Gift_Voucher__c> vouchers = new List<Gift_Voucher__c>();
                for (Integer i = 0; i < accountIds.size(); i++) {
                    vouchers.add(new Gift_Voucher__c(Account__c = Id.valueOf(accountIds[i]), Voucher_Code__c = codes[i]));
                }
                return vouchers;
            }
        }
        throw new VoucherCodeException(
            'Could not find enough unused codes starting with ' + prefix + '. Please use a different Voucher Code.'
        );
    }

    private static String randomCharacters(Integer length) {
        String text = '';
        for (Integer i = 0; i < length; i++) {
            Integer index = Math.mod(Crypto.getRandomInteger(), VOUCHER_CODE_ALPHABET.length());
            if (index < 0) {
                index += VOUCHER_CODE_ALPHABET.length();
            }
            text += VOUCHER_CODE_ALPHABET.substring(index, index + 1);
        }
        return text;
    }

    // =====================================================================
    // Describe helpers
    // =====================================================================

    private static Schema.DescribeSObjectResult describeObject(String objectApiName) {
        Schema.SObjectType objectType = String.isBlank(objectApiName)
            ? null
            : Schema.getGlobalDescribe().get(objectApiName.trim());
        if (objectType == null || !objectType.getDescribe().isAccessible()) {
            throw auraError('Object ' + objectApiName + ' is not available.');
        }
        return objectType.getDescribe();
    }

    private static Schema.DescribeFieldResult describeField(Schema.DescribeSObjectResult objectDescribe, String fieldApiName) {
        Schema.SObjectField field = String.isBlank(fieldApiName)
            ? null
            : objectDescribe.fields.getMap().get(fieldApiName.trim().toLowerCase());
        if (field == null || !field.getDescribe().isAccessible()) {
            throw auraError('Field ' + fieldApiName + ' is not available on ' + objectDescribe.getLabel() + '.');
        }
        return field.getDescribe();
    }

    /** lightning-datatable column type for a field type. */
    private static String columnType(Schema.DisplayType fieldType) {
        switch on fieldType {
            when CURRENCY {
                return 'currency';
            }
            when DOUBLE, INTEGER, LONG, PERCENT {
                return 'number';
            }
            when DATE {
                return 'date-local';
            }
            when DATETIME {
                return 'date';
            }
            when BOOLEAN {
                return 'boolean';
            }
            when else {
                return 'text';
            }
        }
    }

    /** AuraHandledException whose message is readable in Apex tests too. */
    private static AuraHandledException auraError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
