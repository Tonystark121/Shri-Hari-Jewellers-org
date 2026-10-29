/**
 * @description
 * Lead upload from a CSV file - the Upload Leads button on the Lead list.
 *
 * Every row goes through the same rules as the New Lead screen:
 *   - Last Name, Phone and Product Description are required;
 *   - Phone must be 10 digits (a leading +91 or 91, spaces and dashes are
 *     fine) and is saved exactly as written;
 *   - dates are YYYY-MM-DD; Date of Birth and Anniversary Date cannot be in
 *     the future; Anniversary Date only for a Married customer and after
 *     the Date of Birth;
 *   - picklist values must be active values; Store by Store Code, Campaign
 *     by Campaign Name;
 *   - a blank Company makes the Lead B2C (LeadTriggerHandler assigns
 *     "<Name> Family (<Lead Number>)"); a Company makes it B2B;
 *   - an existing customer (same phone or email on an Account or Contact)
 *     gets an enquiry Case instead of a Lead - Origin Phone, Priority
 *     Medium, owned by the account owner;
 *   - an open Lead with the same phone or email, or a repeat of an earlier
 *     row in the same file, fails.
 *
 * Rows that pass are saved; rows that fail are not. Every row is written to
 * a results CSV (the uploaded columns plus Result, Record Number, Record Id
 * and Reason) that the user downloads from the results screen.
 *
 * Columns are matched by header name, ignoring case, spaces, "*" and
 * anything in brackets, so the template header "Date of Birth (YYYY-MM-DD)"
 * and a plain "Date of Birth" both work. Unknown columns (such as the
 * Result columns of a results file) are ignored.
 *
 * One upload runs in one transaction, so a file is limited to MAX_ROWS
 * rows; a larger file is refused with a message to split it.
 *
 * Records are written in system mode: the upload screen is the gate, the
 * same as the New Lead screen.
 */
public with sharing class LeadUploadService {

    @TestVisible
    private static final Integer MAX_ROWS = 1000;

    @TestVisible
    private static final String RESULT_LEAD = 'Lead Created';
    @TestVisible
    private static final String RESULT_ENQUIRY = 'Enquiry Raised';
    @TestVisible
    private static final String RESULT_FAILED = 'Failed';

    private static final String MARRIED = 'Married';
    private static final String DEFAULT_STATUS = 'New';

    private static final Pattern DATE_PATTERN = Pattern.compile('^\\d{4}-\\d{2}-\\d{2}$');
    private static final Pattern EMAIL_PATTERN = Pattern.compile(
        '^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$'
    );

    // Column keys: the header name lower-cased, without spaces, "*",
    // punctuation or anything in brackets.
    private static final String COL_SALUTATION = 'salutation';
    private static final String COL_FIRST_NAME = 'firstname';
    private static final String COL_LAST_NAME = 'lastname';
    private static final String COL_PHONE = 'phone';
    private static final String COL_EMAIL = 'email';
    private static final String COL_DATE_OF_BIRTH = 'dateofbirth';
    private static final String COL_STREET = 'street';
    private static final String COL_CITY = 'city';
    private static final String COL_STATE = 'state';
    private static final String COL_POSTAL_CODE = 'postalcode';
    private static final String COL_COUNTRY = 'country';
    private static final String COL_PRODUCT = 'productdescription';
    private static final String COL_MARITAL = 'maritalstatus';
    private static final String COL_ANNIVERSARY = 'anniversarydate';
    private static final String COL_STATUS = 'status';
    private static final String COL_LEAD_SOURCE = 'leadsource';
    private static final String COL_WALK_IN = 'walkin';
    private static final String COL_STORE_CODE = 'storecode';
    private static final String COL_CAMPAIGN = 'campaignname';
    private static final String COL_COMPANY = 'company';
    private static final String COL_INDUSTRY = 'industry';
    private static final String COL_TITLE = 'title';
    private static final String COL_WEBSITE = 'website';

    /** Required columns, with the label shown when one is missing. */
    private static final Map<String, String> REQUIRED_COLUMNS = new Map<String, String>{
        COL_LAST_NAME => 'Last Name',
        COL_PHONE => 'Phone',
        COL_PRODUCT => 'Product Description'
    };

    // =====================================================================
    // Invocable action (Upload Leads flow)
    // =====================================================================

    public class UploadRequest {
        @InvocableVariable(label='Uploaded File Ids' description='Content Document Ids from the File Upload component. The last (most recently uploaded) file is processed.' required=true)
        public List<String> contentDocumentIds;
    }

    public class UploadResult {
        @InvocableVariable(label='Is File Valid' description='False when the file itself could not be processed (wrong type, empty, missing columns, too many rows).')
        public Boolean isFileValid;

        @InvocableVariable(label='Error Message' description='Why the file could not be processed. Blank when Is File Valid is true.')
        public String errorMessage;

        @InvocableVariable(label='Total Rows')
        public Integer totalRows;

        @InvocableVariable(label='Leads Created')
        public Integer leadsCreated;

        @InvocableVariable(label='Enquiries Raised')
        public Integer enquiriesRaised;

        @InvocableVariable(label='Failed Rows')
        public Integer failedRows;

        @InvocableVariable(label='Results File Version Id' description='ContentVersion Id of the results CSV, for the download link.')
        public Id resultFileVersionId;

        @InvocableVariable(label='Results File Name')
        public String resultFileName;
    }

    /**
     * Processes one uploaded CSV per request. The Upload Leads flow always
     * sends a single request.
     */
    @InvocableMethod(
        label='Upload Leads from CSV'
        description='Creates Leads (or enquiry Cases for existing customers) from an uploaded CSV with the same rules as the New Lead screen, and returns a results CSV.'
        category='Lead'
    )
    public static List<UploadResult> upload(List<UploadRequest> requests) {
        List<UploadResult> results = new List<UploadResult>();
        for (UploadRequest request : requests) {
            results.add(processFile(request.contentDocumentIds));
        }
        return results;
    }

    // =====================================================================
    // File
    // =====================================================================

    private static UploadResult processFile(List<String> contentDocumentIds) {
        UploadResult result = new UploadResult();
        result.isFileValid = false;
        result.totalRows = 0;
        result.leadsCreated = 0;
        result.enquiriesRaised = 0;
        result.failedRows = 0;

        // The File Upload component keeps earlier uploads in its list, so
        // after a refused file the newest upload is the last one.
        String contentDocumentId = (contentDocumentIds == null || contentDocumentIds.isEmpty())
            ? null
            : contentDocumentIds[contentDocumentIds.size() - 1];
        if (String.isBlank(contentDocumentId)) {
            result.errorMessage = 'Choose a CSV file to upload.';
            return result;
        }

        List<ContentVersion> versions = [
            SELECT Title, FileExtension, VersionData
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId
              AND IsLatest = true
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (versions.isEmpty()) {
            result.errorMessage = 'The uploaded file could not be found. Upload it again.';
            return result;
        }

        ContentVersion file = versions[0];
        if (file.FileExtension == null || file.FileExtension.toLowerCase() != 'csv') {
            result.errorMessage = 'Upload a .csv file. In Excel, use Save As and choose "CSV UTF-8 (Comma delimited)".';
            return result;
        }

        List<List<String>> table = parseCsv(file.VersionData.toString());
        if (table.isEmpty()) {
            result.errorMessage = 'The file is empty.';
            return result;
        }

        List<String> header = table.remove(0);
        Map<String, Integer> columnIndex = new Map<String, Integer>();
        for (Integer i = 0; i < header.size(); i++) {
            String key = columnKey(header[i]);
            if (String.isNotBlank(key) && !columnIndex.containsKey(key)) {
                columnIndex.put(key, i);
            }
        }

        List<String> missing = new List<String>();
        for (String key : REQUIRED_COLUMNS.keySet()) {
            if (!columnIndex.containsKey(key)) {
                missing.add(REQUIRED_COLUMNS.get(key));
            }
        }
        if (!missing.isEmpty()) {
            result.errorMessage = 'The file is missing the required column(s): ' + String.join(missing, ', ')
                + '. Download the template and keep its header row.';
            return result;
        }

        List<Row> rows = new List<Row>();
        for (Integer i = 0; i < table.size(); i++) {
            if (!isBlankRow(table[i])) {
                rows.add(new Row(i + 2, table[i]));
            }
        }
        if (rows.isEmpty()) {
            result.errorMessage = 'The file has a header row but no customers to upload.';
            return result;
        }
        if (rows.size() > MAX_ROWS) {
            result.errorMessage = 'The file has ' + rows.size() + ' rows. Up to ' + MAX_ROWS
                + ' rows can be uploaded at a time - split it into smaller files.';
            return result;
        }

        processRows(rows, columnIndex);

        for (Row row : rows) {
            if (row.result == RESULT_LEAD) {
                result.leadsCreated++;
            } else if (row.result == RESULT_ENQUIRY) {
                result.enquiriesRaised++;
            } else {
                result.failedRows++;
            }
        }

        ContentVersion resultsFile = resultsFile(header, rows);
        result.isFileValid = true;
        result.totalRows = rows.size();
        result.resultFileVersionId = resultsFile.Id;
        result.resultFileName = resultsFile.PathOnClient;
        return result;
    }

    // =====================================================================
    // Rows
    // =====================================================================

    private class Row {
        Integer lineNumber;
        List<String> values;
        Lead leadRecord;
        Case enquiry;
        String customerName;
        String normalizedPhone;
        String email;
        String result;
        String recordNumber;
        Id recordId;
        String reason;

        Row(Integer lineNumber, List<String> values) {
            this.lineNumber = lineNumber;
            this.values = values;
        }

        Boolean isOpen() {
            return result == null;
        }

        void fail(String reason) {
            this.result = RESULT_FAILED;
            this.reason = reason;
        }
    }

    private class RowException extends Exception {}

    private static void processRows(List<Row> rows, Map<String, Integer> columnIndex) {

        // 1. Check each row and build its Lead ---------------------------
        Lookups lookups = new Lookups(rows, columnIndex);
        for (Row row : rows) {
            try {
                buildLead(row, columnIndex, lookups);
            } catch (RowException e) {
                row.fail(e.getMessage());
            }
        }

        // 2. The same person twice in one file ---------------------------
        Map<String, Integer> firstLineByKey = new Map<String, Integer>();
        for (Row row : rows) {
            if (!row.isOpen()) {
                continue;
            }
            for (String key : matchKeys(row)) {
                if (firstLineByKey.containsKey(key)) {
                    row.fail('Same phone or email as row ' + firstLineByKey.get(key) + ' of this file.');
                    break;
                }
            }
            if (row.isOpen()) {
                for (String key : matchKeys(row)) {
                    firstLineByKey.put(key, row.lineNumber);
                }
            }
        }

        // 3. Existing customers and open Leads -----------------------------
        Set<String> phones = new Set<String>();
        Set<String> emails = new Set<String>();
        for (Row row : rows) {
            if (row.isOpen()) {
                phones.add(row.normalizedPhone);
                if (String.isNotBlank(row.email)) {
                    emails.add(row.email);
                }
            }
        }
        Map<String, LeadTriggerHandler.Customer> customers = LeadTriggerHandler.findCustomers(phones, emails);
        Map<String, Lead> openLeads = LeadTriggerHandler.findOpenLeads(phones, emails);

        for (Row row : rows) {
            if (!row.isOpen()) {
                continue;
            }
            LeadTriggerHandler.Customer customer;
            Lead openLead;
            for (String key : matchKeys(row)) {
                if (customer == null && customers.containsKey(key)) {
                    customer = customers.get(key);
                }
                if (openLead == null && openLeads.containsKey(key)) {
                    openLead = openLeads.get(key);
                }
            }
            if (customer != null) {
                row.enquiry = enquiryFor(row.leadRecord, customer);
                row.customerName = customer.accountName;
            } else if (openLead != null) {
                row.fail('A Lead with this phone or email already exists: ' + openLead.Name
                    + ' (owner ' + openLead.Owner.Name + ').');
            }
        }

        // 4. Save Leads ----------------------------------------------------
        List<Row> leadRows = new List<Row>();
        List<Lead> leads = new List<Lead>();
        for (Row row : rows) {
            if (row.isOpen() && row.enquiry == null) {
                leadRows.add(row);
                leads.add(row.leadRecord);
            }
        }
        if (!leads.isEmpty()) {
            List<Database.SaveResult> saves = Database.insert(leads, false, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < saves.size(); i++) {
                if (saves[i].isSuccess()) {
                    leadRows[i].result = RESULT_LEAD;
                    leadRows[i].recordId = saves[i].getId();
                } else {
                    leadRows[i].fail(messageFrom(saves[i].getErrors()));
                }
            }
        }

        // 5. Save enquiries ------------------------------------------------
        List<Row> enquiryRows = new List<Row>();
        List<Case> enquiries = new List<Case>();
        for (Row row : rows) {
            if (row.isOpen() && row.enquiry != null) {
                enquiryRows.add(row);
                enquiries.add(row.enquiry);
            }
        }
        if (!enquiries.isEmpty()) {
            List<Database.SaveResult> saves = Database.insert(enquiries, false, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < saves.size(); i++) {
                if (saves[i].isSuccess()) {
                    enquiryRows[i].result = RESULT_ENQUIRY;
                    enquiryRows[i].recordId = saves[i].getId();
                    enquiryRows[i].reason = 'Existing customer: ' + enquiryRows[i].customerName + '.';
                } else {
                    enquiryRows[i].fail(messageFrom(saves[i].getErrors()));
                }
            }
        }

        // 6. Lead and Case numbers for the results file ---------------------
        Map<Id, String> numbers = new Map<Id, String>();
        Set<Id> savedIds = new Set<Id>();
        for (Row row : rows) {
            if (row.recordId != null) {
                savedIds.add(row.recordId);
            }
        }
        if (!savedIds.isEmpty()) {
            for (Lead saved : [SELECT Id, Lead_Number__c FROM Lead WHERE Id IN :savedIds WITH SYSTEM_MODE]) {
                numbers.put(saved.Id, saved.Lead_Number__c);
            }
            for (Case saved : [SELECT Id, CaseNumber FROM Case WHERE Id IN :savedIds WITH SYSTEM_MODE]) {
                numbers.put(saved.Id, saved.CaseNumber);
            }
        }
        for (Row row : rows) {
            if (row.recordId != null) {
                row.recordNumber = numbers.get(row.recordId);
            }
        }
    }

    /** Checks one row and builds its unsaved Lead; throws RowException with the reason when it cannot be uploaded. */
    private static void buildLead(Row row, Map<String, Integer> columnIndex, Lookups lookups) {
        String lastName = value(row, columnIndex, COL_LAST_NAME);
        if (String.isBlank(lastName)) {
            throw new RowException('Last Name is required.');
        }

        String phone = value(row, columnIndex, COL_PHONE);
        if (String.isBlank(phone)) {
            throw new RowException('Phone is required.');
        }
        String normalizedPhone = LeadTriggerHandler.normalizePhone(phone);
        if (!LeadTriggerHandler.isValidPhone(normalizedPhone)) {
            if (phone.containsIgnoreCase('E+')) {
                throw new RowException('Phone "' + phone + '" was changed by Excel into scientific notation. '
                    + 'Format the Phone column as Text and enter the number again.');
            }
            throw new RowException('Phone must be a 10-digit number, optionally starting with +91 or 91.');
        }

        String productDescription = value(row, columnIndex, COL_PRODUCT);
        if (String.isBlank(productDescription)) {
            throw new RowException('Product Description is required.');
        }

        String email = value(row, columnIndex, COL_EMAIL);
        if (String.isNotBlank(email) && !EMAIL_PATTERN.matcher(email).matches()) {
            throw new RowException('"' + email + '" is not a valid email address.');
        }

        Date dateOfBirth = parseDate(value(row, columnIndex, COL_DATE_OF_BIRTH), 'Date of Birth');
        if (dateOfBirth != null && dateOfBirth > Date.today()) {
            throw new RowException('Date of Birth cannot be in the future.');
        }

        String maritalStatus = picklistValue(value(row, columnIndex, COL_MARITAL), Lead.Marital_Status__c, 'Marital Status');
        Date anniversary = parseDate(value(row, columnIndex, COL_ANNIVERSARY), 'Anniversary Date');
        if (anniversary != null) {
            if (maritalStatus != MARRIED) {
                throw new RowException('Anniversary Date can only be given when Marital Status is Married.');
            }
            if (anniversary > Date.today()) {
                throw new RowException('Anniversary Date cannot be in the future.');
            }
            if (dateOfBirth != null && anniversary <= dateOfBirth) {
                throw new RowException('Anniversary Date must be after the Date of Birth.');
            }
        }

        String status = picklistValue(value(row, columnIndex, COL_STATUS), Lead.Status, 'Status');
        String company = value(row, columnIndex, COL_COMPANY);

        Lead leadRecord = new Lead(
            Salutation = picklistValue(value(row, columnIndex, COL_SALUTATION), Lead.Salutation, 'Salutation'),
            FirstName = value(row, columnIndex, COL_FIRST_NAME),
            LastName = lastName,
            Phone = phone,
            Email = email,
            Date_of_Birth__c = dateOfBirth,
            Street = value(row, columnIndex, COL_STREET),
            City = value(row, columnIndex, COL_CITY),
            State = value(row, columnIndex, COL_STATE),
            PostalCode = value(row, columnIndex, COL_POSTAL_CODE),
            Country = value(row, columnIndex, COL_COUNTRY),
            Description = productDescription,
            Marital_Status__c = maritalStatus,
            Anniversary_Date__c = anniversary,
            Status = String.isBlank(status) ? DEFAULT_STATUS : status,
            LeadSource = picklistValue(value(row, columnIndex, COL_LEAD_SOURCE), Lead.LeadSource, 'Lead Source'),
            Walk_In_Flag__c = walkIn(value(row, columnIndex, COL_WALK_IN)),
            Store_Association__c = lookups.storeId(value(row, columnIndex, COL_STORE_CODE)),
            Campaign_Attribution__c = lookups.campaignId(value(row, columnIndex, COL_CAMPAIGN)),
            Company = company,
            Industry = picklistValue(value(row, columnIndex, COL_INDUSTRY), Lead.Industry, 'Industry'),
            Title = value(row, columnIndex, COL_TITLE),
            Website = value(row, columnIndex, COL_WEBSITE)
        );
        // A blank Company is made B2C by LeadTriggerHandler.
        if (String.isNotBlank(company)) {
            leadRecord.Business_Type__c = 'B2B';
        }

        row.leadRecord = leadRecord;
        row.normalizedPhone = normalizedPhone;
        row.email = email;
    }

    /**
     * Enquiry Case for an existing customer, filled in the same way as on the
     * New Lead screen. Also used by the website API (ShreeHariLeadRestResource).
     */
    public static Case enquiryFor(Lead leadRecord, LeadTriggerHandler.Customer customer) {
        String fullName = String.isBlank(leadRecord.FirstName)
            ? leadRecord.LastName
            : leadRecord.FirstName + ' ' + leadRecord.LastName;
        return new Case(
            AccountId = customer.accountId,
            ContactId = customer.contactId,
            OwnerId = customer.ownerId == null ? UserInfo.getUserId() : customer.ownerId,
            Subject = 'Enquiry from ' + fullName,
            Origin = 'Phone',
            Priority = 'Medium',
            Type = 'Service Enquiry',
            Status = 'New',
            SuppliedName = fullName,
            SuppliedPhone = leadRecord.Phone,
            SuppliedEmail = leadRecord.Email,
            Description = leadRecord.Description,
            Store__c = leadRecord.Store_Association__c,
            Campaign__c = leadRecord.Campaign_Attribution__c,
            Lead_Source__c = leadRecord.LeadSource
        );
    }

    private static List<String> matchKeys(Row row) {
        List<String> keys = new List<String>{ LeadTriggerHandler.phoneKey(row.normalizedPhone) };
        if (String.isNotBlank(row.email)) {
            keys.add(LeadTriggerHandler.emailKey(row.email));
        }
        return keys;
    }

    // =====================================================================
    // Store and Campaign lookups
    // =====================================================================

    /** Store Codes and Campaign Names used in the file, resolved with one query each. */
    private class Lookups {
        Map<String, Id> storeByCode = new Map<String, Id>();
        Map<String, Id> campaignByName = new Map<String, Id>();

        Lookups(List<Row> rows, Map<String, Integer> columnIndex) {
            Set<String> codes = new Set<String>();
            Set<String> names = new Set<String>();
            for (Row row : rows) {
                String code = value(row, columnIndex, COL_STORE_CODE);
                String name = value(row, columnIndex, COL_CAMPAIGN);
                if (String.isNotBlank(code)) {
                    codes.add(code);
                }
                if (String.isNotBlank(name)) {
                    names.add(name);
                }
            }
            if (!codes.isEmpty()) {
                for (Store_Location__c store : [
                    SELECT Id, Store_Code__c FROM Store_Location__c WHERE Store_Code__c IN :codes WITH SYSTEM_MODE
                ]) {
                    storeByCode.put(store.Store_Code__c.toLowerCase(), store.Id);
                }
            }
            if (!names.isEmpty()) {
                // Two campaigns with one name: the active one, then the newest.
                for (Campaign campaignRecord : [
                    SELECT Id, Name FROM Campaign WHERE Name IN :names WITH SYSTEM_MODE
                    ORDER BY IsActive DESC, CreatedDate DESC
                ]) {
                    String key = campaignRecord.Name.toLowerCase();
                    if (!campaignByName.containsKey(key)) {
                        campaignByName.put(key, campaignRecord.Id);
                    }
                }
            }
        }

        Id storeId(String code) {
            if (String.isBlank(code)) {
                return null;
            }
            Id storeId = storeByCode.get(code.toLowerCase());
            if (storeId == null) {
                throw new RowException('No Store has the Store Code "' + code + '".');
            }
            return storeId;
        }

        Id campaignId(String name) {
            if (String.isBlank(name)) {
                return null;
            }
            Id campaignId = campaignByName.get(name.toLowerCase());
            if (campaignId == null) {
                throw new RowException('No Campaign is named "' + name + '".');
            }
            return campaignId;
        }
    }

    // =====================================================================
    // Values
    // =====================================================================

    private static String value(Row row, Map<String, Integer> columnIndex, String key) {
        Integer index = columnIndex.get(key);
        if (index == null || index >= row.values.size()) {
            return null;
        }
        String cell = row.values[index];
        return String.isBlank(cell) ? null : cell.trim();
    }

    /** A YYYY-MM-DD date that really exists (2026-02-30 is refused, not rolled into March). */
    @TestVisible
    private static Date parseDate(String text, String label) {
        if (String.isBlank(text)) {
            return null;
        }
        Date parsed;
        if (DATE_PATTERN.matcher(text).matches()) {
            try {
                parsed = Date.valueOf(text);
            } catch (Exception e) {
                parsed = null;
            }
        }
        if (parsed == null || String.valueOf(parsed) != text) {
            throw new RowException(label + ' "' + text + '" must be a real date written as YYYY-MM-DD, e.g. 1990-08-25. '
                + '(Excel may have changed the format - format the column as Text.)');
        }
        return parsed;
    }

    /** The active picklist value matching the text (ignoring case), or a RowException listing the allowed values. */
    private static String picklistValue(String text, Schema.SObjectField field, String label) {
        if (String.isBlank(text)) {
            return null;
        }
        List<String> allowed = new List<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                if (entry.getValue().equalsIgnoreCase(text)) {
                    return entry.getValue();
                }
                allowed.add(entry.getValue());
            }
        }
        throw new RowException('"' + text + '" is not a valid ' + label + '. Allowed values: ' + String.join(allowed, ', ') + '.');
    }

    private static Boolean walkIn(String text) {
        if (String.isBlank(text)) {
            return false;
        }
        String lowered = text.toLowerCase();
        if (lowered == 'yes' || lowered == 'y' || lowered == 'true' || lowered == '1') {
            return true;
        }
        if (lowered == 'no' || lowered == 'n' || lowered == 'false' || lowered == '0') {
            return false;
        }
        throw new RowException('Walk-In must be Yes or No.');
    }

    private static String messageFrom(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'The record could not be saved.';
        }
        List<String> messages = new List<String>();
        for (Database.Error error : errors) {
            messages.add(error.getMessage());
        }
        return String.join(messages, ' ');
    }

    // =====================================================================
    // CSV
    // =====================================================================

    /** Header text to column key: lower case, without anything in brackets, "*", spaces or punctuation. */
    @TestVisible
    private static String columnKey(String header) {
        if (header == null) {
            return null;
        }
        return header.replace(byteOrderMark(), '')
            .replaceAll('\\([^)]*\\)', '')
            .toLowerCase()
            .replaceAll('[^a-z0-9]', '');
    }

    private static Boolean isBlankRow(List<String> values) {
        for (String cell : values) {
            if (String.isNotBlank(cell)) {
                return false;
            }
        }
        return true;
    }

    /**
     * Splits CSV text into rows of cells. Handles quoted cells containing
     * commas, doubled quotes ("") and line breaks, Windows and Mac line
     * endings, and the byte-order mark Excel writes at the start of a
     * UTF-8 file. Lines without quotes take a fast path.
     */
    @TestVisible
    private static List<List<String>> parseCsv(String text) {
        List<List<String>> table = new List<List<String>>();
        if (String.isBlank(text)) {
            return table;
        }

        text = text.replace(byteOrderMark(), '').replace('\r\n', '\n').replace('\r', '\n');
        List<String> lines = text.split('\n', -1);

        Integer lineIndex = 0;
        while (lineIndex < lines.size()) {
            String line = lines[lineIndex];

            if (!line.contains('"')) {
                table.add(line.split(',', -1));
                lineIndex++;
                continue;
            }

            List<String> cells = new List<String>();
            String current = '';
            Boolean inQuotes = false;
            while (true) {
                Integer position = 0;
                Integer length = line.length();
                while (position < length) {
                    String character = line.substring(position, position + 1);
                    if (inQuotes) {
                        if (character == '"') {
                            if (position + 1 < length && line.substring(position + 1, position + 2) == '"') {
                                current += '"';
                                position += 2;
                                continue;
                            }
                            inQuotes = false;
                        } else {
                            current += character;
                        }
                    } else if (character == '"') {
                        inQuotes = true;
                    } else if (character == ',') {
                        cells.add(current);
                        current = '';
                    } else {
                        current += character;
                    }
                    position++;
                }
                lineIndex++;
                // A quoted cell that runs onto the next line.
                if (inQuotes && lineIndex < lines.size()) {
                    current += '\n';
                    line = lines[lineIndex];
                    continue;
                }
                break;
            }
            cells.add(current);
            table.add(cells);
        }
        return table;
    }

    /** The uploaded columns plus Result, Record Number, Record Id and Reason, saved as a CSV file. */
    private static ContentVersion resultsFile(List<String> header, List<Row> rows) {
        List<String> lines = new List<String>();

        List<String> headerCells = new List<String>(header);
        headerCells.addAll(new List<String>{ 'Result', 'Record Number', 'Record Id', 'Reason' });
        lines.add(csvLine(headerCells));

        for (Row row : rows) {
            List<String> cells = new List<String>();
            for (Integer i = 0; i < header.size(); i++) {
                cells.add(i < row.values.size() ? row.values[i] : '');
            }
            cells.add(row.result);
            cells.add(row.recordNumber);
            cells.add(row.recordId);
            cells.add(row.reason);
            lines.add(csvLine(cells));
        }

        String fileName = 'Lead_Upload_Results_' + Datetime.now().format('yyyy-MM-dd_HHmm') + '.csv';
        ContentVersion file = new ContentVersion(
            Title = fileName.removeEnd('.csv'),
            PathOnClient = fileName,
            // The byte-order mark makes Excel read the file as UTF-8.
            VersionData = Blob.valueOf(byteOrderMark() + String.join(lines, '\r\n'))
        );
        insert as system file;
        return file;
    }

    private static String csvLine(List<String> cells) {
        List<String> escaped = new List<String>();
        for (String cell : cells) {
            String text = cell == null ? '' : cell;
            if (text.contains(',') || text.contains('"') || text.contains('\n') || text.contains('\r')) {
                text = '"' + text.replace('"', '""') + '"';
            }
            escaped.add(text);
        }
        return String.join(escaped, ',');
    }

    private static String byteOrderMark() {
        return String.fromCharArray(new List<Integer>{ 65279 });
    }
}
