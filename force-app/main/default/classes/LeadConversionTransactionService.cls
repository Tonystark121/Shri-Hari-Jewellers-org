/**
 * @description
 * Customer and bill handling: a Lead becomes a customer only when it buys.
 *
 * Convert a Lead with its first bill (Convert button on Lead):
 *   1. find the customer - the Account staff picked on the screen, or a new
 *      one when they chose to create it. Without either (the POS API,
 *      later), an Account that already has the Lead's phone or email (or a
 *      Contact under it that has) is used. A new Account carries the Lead's
 *      phone, email and personal details (name: the Company when a user
 *      typed it, else the person - never the Lead's "<Name> - B2C-<number>"),
 *   2. save the bill (Transaction_Record__c) on that Account,
 *   3. convert the Lead into that Account with Salesforce's own conversion,
 *      which creates the Contact (or merges into the one on that Account
 *      with the same phone or email), keeps the Lead history and creates no
 *      Opportunity.
 * Staff have already compared the matches, so the platform's duplicate
 * alerts do not stop the new Account or Contact.
 * The three steps succeed or fail together for each Lead.
 *
 * Leads cannot be converted any other way: LeadTriggerHandler rejects a
 * conversion unless isConverting() is true, which only this class sets.
 *
 * The methods take lists so bulk callers (the POS bill API, later) can use
 * them. When one Lead fails, the whole attempt is rolled back and the rest
 * are saved again without it.
 *
 * Runs without sharing and writes in system mode: an existing customer must
 * be found even when the user cannot see it, and the screen is the gate.
 */
public without sharing class LeadConversionTransactionService {

    // Database.convertLead accepts at most 100 Leads per call.
    private static final Integer CONVERT_CHUNK_SIZE = 100;
    private static final Integer ACCOUNT_NAME_MAX_LENGTH = 255;

    /** True only while this class converts Leads; see LeadTriggerHandler. */
    private static Boolean converting = false;

    public static Boolean isConverting() {
        return converting;
    }

    // =====================================================================
    // Invocable action (Convert flow)
    // =====================================================================

    public class ConvertRequest {
        @InvocableVariable(label='Lead Id' description='The Lead that bought.' required=true)
        public Id leadId;

        @InvocableVariable(label='Account Name' description='Name for a new Account. Leave blank for the person (B2C) or the company (B2B). Not used when the Lead is an existing customer.')
        public String accountName;

        // Text, not Id: a screen with nothing picked sends an empty value, which an Id input rejects.
        @InvocableVariable(label='Existing Account Id' description='The existing customer Account picked on the screen. The bill is added to it and the Lead converted into it. Blank when none was picked.')
        public String accountId;

        @InvocableVariable(label='Create New Account' description='True to create a new Account even when the phone or email matches an existing customer. Existing Account Id is then ignored.')
        public Boolean createNewAccount;

        @InvocableVariable(label='Bill' description='Unsaved Transaction Record with the bill details. Account is filled in by the service.' required=true)
        public Transaction_Record__c bill;
    }

    public class ConvertResult {
        @InvocableVariable(label='Is Success' description='True when the Account, the bill and the conversion were all saved.')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message' description='Why nothing was saved. Blank on success.')
        public String errorMessage;

        @InvocableVariable(label='Is Existing Customer' description='True when the bill was added to an Account that already existed.')
        public Boolean isExistingCustomer;

        @InvocableVariable(label='Account Id')
        public Id accountId;

        @InvocableVariable(label='Account Name')
        public String accountName;

        @InvocableVariable(label='Contact Id')
        public Id contactId;

        @InvocableVariable(label='Transaction Id')
        public Id transactionId;
    }

    @InvocableMethod(
        label='Convert Lead with Bill'
        description='Finds or creates the customer Account, saves the bill on it and converts the Lead into it. All or nothing per Lead.'
        category='Lead'
    )
    public static List<ConvertResult> convertWithBill(List<ConvertRequest> requests) {
        List<ConvertResult> results = new List<ConvertResult>();
        for (ConvertRequest request : requests) {
            ConvertResult result = new ConvertResult();
            result.isSuccess = false;
            result.isExistingCustomer = false;
            results.add(result);
        }

        // 1. Requests that can be attempted ----------------------------------
        Map<Id, Lead> leadsById = lockLeads(requests);
        Map<Id, Account> pickedAccounts = pickedAccounts(requests);
        List<Integer> pending = new List<Integer>();
        Set<Id> leadsSeen = new Set<Id>();

        for (Integer i = 0; i < requests.size(); i++) {
            ConvertRequest request = requests[i];
            Lead leadRecord = request.leadId == null ? null : leadsById.get(request.leadId);

            if (leadRecord == null) {
                results[i].errorMessage = 'The Lead could not be found. It may have been deleted.';
            } else if (leadRecord.IsConverted) {
                results[i].errorMessage = 'This Lead is already converted.';
            } else if (leadsSeen.contains(leadRecord.Id)) {
                results[i].errorMessage = 'This Lead was sent more than once.';
            } else if (request.bill == null) {
                results[i].errorMessage = 'Bill details are required to convert a Lead.';
            } else if (isPicked(request) && !pickedAccounts.containsKey(pickedAccountId(request))) {
                results[i].errorMessage = 'The selected customer Account could not be found. It may have been deleted.';
            } else if (accountNameFor(request, leadRecord).length() > ACCOUNT_NAME_MAX_LENGTH) {
                results[i].errorMessage = 'Account Name can be at most ' + ACCOUNT_NAME_MAX_LENGTH + ' characters.';
            } else {
                leadsSeen.add(leadRecord.Id);
                pending.add(i);
            }
        }

        // 2. Existing customers ----------------------------------------------
        Map<Integer, LeadTriggerHandler.Customer> customerByRequest =
            existingCustomers(pending, requests, leadsById, pickedAccounts);

        // 3. Save; on any failure roll back and retry without the failed Leads
        while (!pending.isEmpty()) {
            Savepoint beforeAttempt = Database.setSavepoint();
            Map<Integer, String> failures = attempt(pending, requests, leadsById, customerByRequest, results);

            if (failures.isEmpty()) {
                break;
            }

            Database.rollback(beforeAttempt);

            List<Integer> stillPending = new List<Integer>();
            for (Integer i : pending) {
                ConvertResult result = results[i];
                result.isSuccess = false;
                result.accountId = null;
                result.accountName = null;
                result.contactId = null;
                result.transactionId = null;
                if (failures.containsKey(i)) {
                    result.errorMessage = failures.get(i);
                } else {
                    stillPending.add(i);
                }
            }
            pending = stillPending;
        }

        return results;
    }

    // =====================================================================
    // Save
    // =====================================================================

    /**
     * Account (new customers only), then bill, then conversion. Returns the
     * requests that failed with their reason; stops at the first step with a
     * failure because the caller rolls the attempt back anyway.
     */
    private static Map<Integer, String> attempt(
        List<Integer> pending,
        List<ConvertRequest> requests,
        Map<Id, Lead> leadsById,
        Map<Integer, LeadTriggerHandler.Customer> customerByRequest,
        List<ConvertResult> results
    ) {
        Map<Integer, String> failures = new Map<Integer, String>();
        Map<Integer, Id> accountIdByRequest = new Map<Integer, Id>();
        Map<Integer, String> accountNameByRequest = new Map<Integer, String>();

        // Account ------------------------------------------------------------
        List<Integer> newCustomers = new List<Integer>();
        List<Account> accounts = new List<Account>();
        for (Integer i : pending) {
            LeadTriggerHandler.Customer customer = customerByRequest.get(i);
            if (customer != null) {
                accountIdByRequest.put(i, customer.accountId);
                accountNameByRequest.put(i, customer.accountName);
            } else {
                newCustomers.add(i);
                accounts.add(newAccountFor(requests[i], leadsById.get(requests[i].leadId)));
            }
        }

        if (!accounts.isEmpty()) {
            List<Database.SaveResult> saves = Database.insert(accounts, saveDespiteDuplicates(), AccessLevel.SYSTEM_MODE);
            for (Integer position = 0; position < saves.size(); position++) {
                Integer i = newCustomers[position];
                if (saves[position].isSuccess()) {
                    accountIdByRequest.put(i, saves[position].getId());
                    accountNameByRequest.put(i, accounts[position].Name);
                } else {
                    failures.put(i, 'The Account could not be created: ' + messageFrom(saves[position].getErrors()));
                }
            }
            if (!failures.isEmpty()) {
                return failures;
            }
        }

        // Bill -----------------------------------------------------------------
        List<Transaction_Record__c> bills = new List<Transaction_Record__c>();
        for (Integer i : pending) {
            // A copy, so a rolled-back attempt leaves no Id on the caller's record.
            Transaction_Record__c bill = requests[i].bill.clone(false, true);
            bill.Account__c = accountIdByRequest.get(i);
            bills.add(bill);
        }

        List<Database.SaveResult> billSaves = Database.insert(bills, false, AccessLevel.SYSTEM_MODE);
        for (Integer position = 0; position < billSaves.size(); position++) {
            if (!billSaves[position].isSuccess()) {
                failures.put(pending[position], billMessageFrom(bills[position], billSaves[position].getErrors()));
            }
        }
        if (!failures.isEmpty()) {
            return failures;
        }

        // Conversion -----------------------------------------------------------
        String convertedStatus = convertedStatus();
        List<Database.LeadConvertResult> conversions = new List<Database.LeadConvertResult>();
        List<Database.LeadConvert> chunk = new List<Database.LeadConvert>();

        converting = true;
        try {
            for (Integer position = 0; position < pending.size(); position++) {
                Integer i = pending[position];
                Lead leadRecord = leadsById.get(requests[i].leadId);
                LeadTriggerHandler.Customer customer = customerByRequest.get(i);

                Database.LeadConvert conversion = new Database.LeadConvert();
                conversion.setLeadId(leadRecord.Id);
                conversion.setAccountId(accountIdByRequest.get(i));
                if (customer != null && customer.contactId != null) {
                    conversion.setContactId(customer.contactId);
                }
                conversion.setDoNotCreateOpportunity(true);
                conversion.setConvertedStatus(convertedStatus);
                if (!isOwnedByUser(leadRecord)) {
                    // A queue cannot own the Contact.
                    conversion.setOwnerId(UserInfo.getUserId());
                }
                chunk.add(conversion);

                if (chunk.size() == CONVERT_CHUNK_SIZE || position == pending.size() - 1) {
                    conversions.addAll(Database.convertLead(chunk, saveDespiteDuplicates()));
                    chunk = new List<Database.LeadConvert>();
                }
            }
        } finally {
            converting = false;
        }

        for (Integer position = 0; position < pending.size(); position++) {
            Integer i = pending[position];
            Database.LeadConvertResult conversion = conversions[position];
            if (!conversion.isSuccess()) {
                failures.put(i, 'The Lead could not be converted: ' + messageFrom(conversion.getErrors()));
                continue;
            }

            ConvertResult result = results[i];
            result.isSuccess = true;
            result.errorMessage = null;
            result.isExistingCustomer = customerByRequest.containsKey(i);
            result.accountId = accountIdByRequest.get(i);
            result.accountName = accountNameByRequest.get(i);
            result.contactId = conversion.getContactId();
            result.transactionId = bills[position].Id;
        }

        return failures;
    }

    /** A new customer Account carrying the Lead's contact and personal details. */
    private static Account newAccountFor(ConvertRequest request, Lead leadRecord) {
        Account accountRecord = new Account(
            Name = accountNameFor(request, leadRecord),
            Phone = leadRecord.Phone,
            Email__c = leadRecord.Email,
            Business_Type__c = leadRecord.Business_Type__c,
            Date_of_Birth__c = leadRecord.Date_of_Birth__c,
            Anniversary_Date__c = leadRecord.Anniversary_Date__c,
            Marital_Status__c = leadRecord.Marital_Status__c,
            Primary_Store__c = leadRecord.Store_Association__c,
            Campaign_Attribution__c = leadRecord.Campaign_Attribution__c
        );
        if (isOwnedByUser(leadRecord)) {
            accountRecord.OwnerId = leadRecord.OwnerId;
        }
        return accountRecord;
    }

    // =====================================================================
    // Existing customers
    // =====================================================================

    /**
     * The existing customer Account for each request: the one picked on the
     * screen, else (unless a new Account was asked for) the one the Lead's
     * phone or email already belongs to.
     */
    private static Map<Integer, LeadTriggerHandler.Customer> existingCustomers(
        List<Integer> pending,
        List<ConvertRequest> requests,
        Map<Id, Lead> leadsById,
        Map<Id, Account> pickedAccounts
    ) {
        Map<Integer, LeadTriggerHandler.Customer> byRequest = new Map<Integer, LeadTriggerHandler.Customer>();
        List<Integer> toMatch = new List<Integer>();
        for (Integer i : pending) {
            if (isPicked(requests[i])) {
                byRequest.put(i, pickedCustomer(pickedAccounts.get(pickedAccountId(requests[i])), leadsById.get(requests[i].leadId)));
            } else if (requests[i].createNewAccount != true) {
                toMatch.add(i);
            }
        }
        if (toMatch.isEmpty()) {
            return byRequest;
        }

        Set<String> phones = new Set<String>();
        Set<String> emails = new Set<String>();
        for (Integer i : toMatch) {
            Lead leadRecord = leadsById.get(requests[i].leadId);
            String phone = LeadTriggerHandler.normalizePhone(leadRecord.Phone);
            if (LeadTriggerHandler.isValidPhone(phone)) {
                phones.add(phone);
            }
            if (String.isNotBlank(leadRecord.Email)) {
                emails.add(leadRecord.Email);
            }
        }

        Map<String, LeadTriggerHandler.Customer> customers = LeadTriggerHandler.findCustomers(phones, emails);
        if (customers.isEmpty()) {
            return byRequest;
        }

        for (Integer i : toMatch) {
            Lead leadRecord = leadsById.get(requests[i].leadId);
            String phone = LeadTriggerHandler.normalizePhone(leadRecord.Phone);
            LeadTriggerHandler.Customer customer;
            if (LeadTriggerHandler.isValidPhone(phone)) {
                customer = customers.get(LeadTriggerHandler.phoneKey(phone));
            }
            if (customer == null && String.isNotBlank(leadRecord.Email)) {
                customer = customers.get(LeadTriggerHandler.emailKey(leadRecord.Email));
            }
            // A Contact without an Account cannot take the bill; such a
            // person is treated as a new customer.
            if (customer != null && customer.accountId != null) {
                byRequest.put(i, customer);
            }
        }
        return byRequest;
    }

    /** True when the screen picked an existing Account (and did not ask for a new one). */
    private static Boolean isPicked(ConvertRequest request) {
        return String.isNotBlank(request.accountId) && request.createNewAccount != true;
    }

    /** The picked Account's Id, or null when the text is not an Account Id (reported as not found). */
    private static Id pickedAccountId(ConvertRequest request) {
        try {
            Id accountId = Id.valueOf(request.accountId.trim());
            return accountId.getSobjectType() == Account.SObjectType ? accountId : null;
        } catch (StringException invalid) {
            return null;
        }
    }

    /** The picked Accounts with their Contacts, to find the person among them. */
    private static Map<Id, Account> pickedAccounts(List<ConvertRequest> requests) {
        Set<Id> accountIds = new Set<Id>();
        for (ConvertRequest request : requests) {
            if (isPicked(request) && pickedAccountId(request) != null) {
                accountIds.add(pickedAccountId(request));
            }
        }
        if (accountIds.isEmpty()) {
            return new Map<Id, Account>();
        }
        return new Map<Id, Account>([
            SELECT Id, Name,
                   (SELECT Id, Phone, MobilePhone, Email FROM Contacts ORDER BY LastModifiedDate DESC)
            FROM Account
            WHERE Id IN :accountIds
            WITH SYSTEM_MODE
        ]);
    }

    /**
     * The picked Account, with the Contact on it that has the Lead's phone or
     * email - the Lead merges into that Contact instead of creating a second
     * one. Without such a Contact a new one is created on the Account.
     */
    private static LeadTriggerHandler.Customer pickedCustomer(Account accountRecord, Lead leadRecord) {
        LeadTriggerHandler.Customer customer = new LeadTriggerHandler.Customer();
        customer.accountId = accountRecord.Id;
        customer.accountName = accountRecord.Name;

        String phone = LeadTriggerHandler.normalizePhone(leadRecord.Phone);
        Boolean hasPhone = LeadTriggerHandler.isValidPhone(phone);
        for (Contact contactRecord : accountRecord.Contacts) {
            Boolean samePhone = hasPhone && (
                LeadTriggerHandler.normalizePhone(contactRecord.Phone) == phone
                || LeadTriggerHandler.normalizePhone(contactRecord.MobilePhone) == phone
            );
            Boolean sameEmail = String.isNotBlank(leadRecord.Email) && String.isNotBlank(contactRecord.Email)
                && leadRecord.Email.trim().equalsIgnoreCase(contactRecord.Email.trim());
            if (samePhone || sameEmail) {
                customer.contactId = contactRecord.Id;
                break;
            }
        }
        return customer;
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    /**
     * Partial saves that go through the platform's duplicate alerts: staff
     * have already seen the matching customers on the screen.
     */
    private static Database.DMLOptions saveDespiteDuplicates() {
        Database.DMLOptions options = new Database.DMLOptions();
        options.optAllOrNone = false;
        options.DuplicateRuleHeader.allowSave = true;
        return options;
    }

    /** Reads and locks the Leads, so the same Lead cannot be converted twice at once. */
    private static Map<Id, Lead> lockLeads(List<ConvertRequest> requests) {
        Set<Id> leadIds = new Set<Id>();
        for (ConvertRequest request : requests) {
            if (request.leadId != null) {
                leadIds.add(request.leadId);
            }
        }
        if (leadIds.isEmpty()) {
            return new Map<Id, Lead>();
        }
        return new Map<Id, Lead>([
            SELECT Id, FirstName, LastName, Company, Business_Type__c, Phone, Email, IsConverted, OwnerId,
                   Date_of_Birth__c, Anniversary_Date__c, Marital_Status__c,
                   Store_Association__c, Campaign_Attribution__c
            FROM Lead
            WHERE Id IN :leadIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ]);
    }

    /**
     * The name entered on the screen, else the Company when a user typed it,
     * else the person's name (never the system's "<Name> - B2C-<number>").
     */
    @TestVisible
    private static String accountNameFor(ConvertRequest request, Lead leadRecord) {
        if (String.isNotBlank(request.accountName)) {
            return request.accountName.trim();
        }
        if (!LeadTriggerHandler.isSystemCompany(leadRecord.Company)) {
            return leadRecord.Company.trim();
        }
        return String.isBlank(leadRecord.FirstName)
            ? leadRecord.LastName.trim()
            : (leadRecord.FirstName.trim() + ' ' + leadRecord.LastName.trim());
    }

    private static Boolean isOwnedByUser(Lead leadRecord) {
        return leadRecord.OwnerId.getSobjectType() == User.SObjectType;
    }

    private static String convertedStatus() {
        return [
            SELECT ApiName
            FROM LeadStatus
            WHERE IsConverted = true
            WITH SYSTEM_MODE
            ORDER BY SortOrder
            LIMIT 1
        ].ApiName;
    }

    private static String messageFrom(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error error : errors) {
            messages.add(error.getMessage());
        }
        return String.join(messages, ' ');
    }

    /**
     * Bill Number is the only unique field on Transaction Record, so a
     * duplicate-value error is always the bill number; say so plainly (the
     * platform's message does not always name the field).
     */
    private static String billMessageFrom(Transaction_Record__c bill, List<Database.Error> errors) {
        for (Database.Error error : errors) {
            if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                return 'A bill with Bill Number ' + bill.Bill_Number__c + ' already exists.';
            }
        }
        String message = messageFrom(errors);
        // The bill trigger already explains its rejections in full.
        return message.startsWith('The bill was not saved: ') ? message : 'The bill could not be saved: ' + message;
    }
}
