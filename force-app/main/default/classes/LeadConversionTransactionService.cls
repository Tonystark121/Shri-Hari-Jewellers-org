/**
 * @description
 * Customer and bill handling: a Lead becomes a customer only when it buys.
 *
 * Convert a Lead with its first bill (Convert button on Lead):
 *   1. find the customer - the Account staff picked on the screen, or a new
 *      one when they chose to create it. Without either (the POS API,
 *      later), an Account that already has the Lead's phone, WhatsApp number
 *      or email (or a Contact under it that has) is used. A new Account
 *      carries the Lead's phone, WhatsApp number, email, WA / SMS / Email
 *      opt-ins and personal details
 *      (name: the Company when a user typed it (B2B), else "<Name> Family"
 *      (B2C), e.g. Asha Mehta Family). An existing Account keeps every value
 *      it has; its blank Email, WhatsApp Number and Business Type ("Unknown"
 *      counts as blank) are filled from the Lead, and an opt-in the Lead has
 *      is ticked on it (an opt-in is never unticked), and the Lead's Description
 *      (the product description) is added to
 *      the Account's on a new line. The Lead's name is added to the
 *      Account's name when both have the same Business Type: a B2C Lead to a
 *      B2C family Account - "Asha Mehta Family" + Rohit Mehta becomes "Asha
 *      Mehta & Rohit Mehta Family" (familyAccountNameWith) - and a B2B Lead
 *      to a B2B Account - "test user" + Rakesh Jain becomes "test user &
 *      Rakesh Jain" (businessAccountNameWith). Across types, or when the
 *      Account's Business Type is blank or Unknown, the name is kept,
 *   2. save the bill (Transaction_Record__c) on that Account,
 *   3. convert the Lead into that Account with Salesforce's own conversion,
 *      which creates a new Contact on the Account from the Lead's details -
 *      or, when a Contact there already has the Lead's name, phone and
 *      email, merges into it - keeps the Lead history and creates no
 *      Opportunity. A new Contact also gets the Lead's Date of Birth
 *      (Birthdate), Anniversary Date and Marital Status; a merged one is
 *      left as it is.
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
    /** The Account default: a placeholder, so it is replaced like a blank. */
    private static final String BUSINESS_TYPE_UNKNOWN = 'Unknown';
    private static final String BUSINESS_TYPE_B2B = 'B2B';
    private static final String BUSINESS_TYPE_B2C = 'B2C';
    private static final String FAMILY_SUFFIX = ' Family';
    private static final String MEMBER_SEPARATOR = ' & ';

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

        @InvocableVariable(label='Account Name' description='Name for a new Account. Leave blank for "<Name> Family" (B2C) or the company (B2B). Not used when the Lead is an existing customer.')
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

        // Existing customers: their blank details and family name -----------
        Map<Id, String> customerNames = new Map<Id, String>();
        failures = fillBlankDetails(pending, requests, leadsById, customerByRequest, customerNames);
        if (!failures.isEmpty()) {
            return failures;
        }
        for (Integer i : pending) {
            LeadTriggerHandler.Customer customer = customerByRequest.get(i);
            if (customer != null && customerNames.containsKey(customer.accountId)) {
                accountNameByRequest.put(i, customerNames.get(customer.accountId));
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
        if (!failures.isEmpty()) {
            return failures;
        }

        // New Contacts: the Lead's personal details --------------------------
        return fillPersonalDetails(pending, requests, leadsById, customerByRequest, results);
    }

    /**
     * Copies the Lead's Date of Birth, Anniversary Date and Marital Status to
     * the Contact the conversion created. Setup's Lead field mapping sends
     * them to the Account, and a Lead field maps to one object only, so they
     * are set here. A Contact the Lead merged into is left as it is.
     */
    private static Map<Integer, String> fillPersonalDetails(
        List<Integer> pending,
        List<ConvertRequest> requests,
        Map<Id, Lead> leadsById,
        Map<Integer, LeadTriggerHandler.Customer> customerByRequest,
        List<ConvertResult> results
    ) {
        Map<Integer, String> failures = new Map<Integer, String>();
        List<Contact> updates = new List<Contact>();
        List<Integer> updatedRequests = new List<Integer>();
        for (Integer i : pending) {
            LeadTriggerHandler.Customer customer = customerByRequest.get(i);
            Lead leadRecord = leadsById.get(requests[i].leadId);
            Boolean merged = customer != null && customer.contactId != null;
            if (merged || (leadRecord.Date_of_Birth__c == null
                && leadRecord.Anniversary_Date__c == null
                && String.isBlank(leadRecord.Marital_Status__c))) {
                continue;
            }
            updates.add(new Contact(
                Id = results[i].contactId,
                Birthdate = leadRecord.Date_of_Birth__c,
                Anniversary_Date__c = leadRecord.Anniversary_Date__c,
                Marital_Status__c = leadRecord.Marital_Status__c
            ));
            updatedRequests.add(i);
        }

        if (!updates.isEmpty()) {
            List<Database.SaveResult> saves = Database.update(updates, saveDespiteDuplicates(), AccessLevel.SYSTEM_MODE);
            for (Integer position = 0; position < saves.size(); position++) {
                if (!saves[position].isSuccess()) {
                    failures.put(
                        updatedRequests[position],
                        'The Contact could not be updated: ' + messageFrom(saves[position].getErrors())
                    );
                }
            }
        }
        return failures;
    }

    /**
     * Fills an existing customer's blank Email and Business Type from the
     * Lead, and adds the Lead's Description (the product description) to the
     * Account's on a new line, so nothing is lost. Other values already on
     * the Account are kept; Business Type "Unknown" (the Account default)
     * counts as blank. Salesforce's own conversion fills the other blank
     * mapped fields.
     *
     * Each Lead's name is also added to the Account's name when both are of
     * the same Business Type (see businessTypeOf): a B2C Lead into a B2C
     * family Account (familyAccountNameWith), a B2B Lead into a B2B Account
     * (businessAccountNameWith). A B2C Lead into a B2B Account, a B2B Lead
     * into a B2C Account, or an Account whose Business Type is blank or
     * Unknown, leaves the name as it is. The resulting name of every
     * existing customer Account is put in accountNames.
     */
    private static Map<Integer, String> fillBlankDetails(
        List<Integer> pending,
        List<ConvertRequest> requests,
        Map<Id, Lead> leadsById,
        Map<Integer, LeadTriggerHandler.Customer> customerByRequest,
        Map<Id, String> accountNames
    ) {
        Map<Integer, String> failures = new Map<Integer, String>();
        // The first Lead for an Account fills its blanks; later ones find
        // nothing blank. Every Lead's Description is added, in order.
        Map<Id, Integer> requestByAccount = new Map<Id, Integer>();
        Map<Id, List<String>> descriptionsByAccount = new Map<Id, List<String>>();
        Map<Id, List<Lead>> membersByAccount = new Map<Id, List<Lead>>();
        for (Integer i : pending) {
            LeadTriggerHandler.Customer customer = customerByRequest.get(i);
            if (customer == null) {
                continue;
            }
            if (!requestByAccount.containsKey(customer.accountId)) {
                requestByAccount.put(customer.accountId, i);
                descriptionsByAccount.put(customer.accountId, new List<String>());
                membersByAccount.put(customer.accountId, new List<Lead>());
            }
            Lead leadRecord = leadsById.get(requests[i].leadId);
            String description = leadRecord.Description;
            if (String.isNotBlank(description)) {
                descriptionsByAccount.get(customer.accountId).add(description.trim());
            }
            membersByAccount.get(customer.accountId).add(leadRecord);
        }
        if (requestByAccount.isEmpty()) {
            return failures;
        }

        Set<Id> accountIds = requestByAccount.keySet();
        List<Account> updates = new List<Account>();
        List<Integer> updatedRequests = new List<Integer>();
        for (Account accountRecord : [
            SELECT Id, Name, Email__c, WhatsApp_Number__c, Business_Type__c, Description,
                   WA_Opt_In__c, SMS_Opt_In__c, Email_Opt_In__c
            FROM Account
            WHERE Id IN :accountIds
            WITH SYSTEM_MODE
        ]) {
            Integer i = requestByAccount.get(accountRecord.Id);
            Lead leadRecord = leadsById.get(requests[i].leadId);
            Account changes = new Account(Id = accountRecord.Id);
            Boolean changed = false;

            // The Account's Business Type as it was before this conversion.
            String accountType = accountRecord.Business_Type__c;
            String name = accountRecord.Name;
            for (Lead member : membersByAccount.get(accountRecord.Id)) {
                String leadType = businessTypeOf(member);
                String withMember;
                if (leadType == BUSINESS_TYPE_B2C && accountType == BUSINESS_TYPE_B2C) {
                    withMember = familyAccountNameWith(name, LeadTriggerHandler.personName(member));
                } else if (leadType == BUSINESS_TYPE_B2B && accountType == BUSINESS_TYPE_B2B) {
                    withMember = businessAccountNameWith(name, LeadTriggerHandler.personName(member));
                }
                if (withMember != null) {
                    name = withMember;
                }
            }
            if (!name.equals(accountRecord.Name)) {
                changes.Name = name;
                changed = true;
            }
            accountNames.put(accountRecord.Id, name);

            if (String.isBlank(accountRecord.Email__c) && String.isNotBlank(leadRecord.Email)) {
                changes.Email__c = leadRecord.Email;
                changed = true;
            }
            if (String.isBlank(accountRecord.WhatsApp_Number__c) && String.isNotBlank(leadRecord.MobilePhone)) {
                changes.WhatsApp_Number__c = leadRecord.MobilePhone;
                changed = true;
            }
            // Opt-ins: a Lead's consent is added; consent on the Account is never removed.
            if (leadRecord.WA_Opt_In__c && !accountRecord.WA_Opt_In__c) {
                changes.WA_Opt_In__c = true;
                changed = true;
            }
            if (leadRecord.SMS_Opt_In__c && !accountRecord.SMS_Opt_In__c) {
                changes.SMS_Opt_In__c = true;
                changed = true;
            }
            if (leadRecord.Email_Opt_In__c && !accountRecord.Email_Opt_In__c) {
                changes.Email_Opt_In__c = true;
                changed = true;
            }
            if ((String.isBlank(accountRecord.Business_Type__c) || accountRecord.Business_Type__c == BUSINESS_TYPE_UNKNOWN)
                && String.isNotBlank(leadRecord.Business_Type__c) && leadRecord.Business_Type__c != BUSINESS_TYPE_UNKNOWN) {
                changes.Business_Type__c = leadRecord.Business_Type__c;
                changed = true;
            }
            List<String> descriptions = descriptionsByAccount.get(accountRecord.Id);
            if (!descriptions.isEmpty()) {
                if (String.isNotBlank(accountRecord.Description)) {
                    descriptions.add(0, accountRecord.Description);
                }
                changes.Description = String.join(descriptions, '\n');
                changed = true;
            }
            if (changed) {
                updates.add(changes);
                updatedRequests.add(i);
            }
        }

        if (!updates.isEmpty()) {
            List<Database.SaveResult> saves = Database.update(updates, saveDespiteDuplicates(), AccessLevel.SYSTEM_MODE);
            for (Integer position = 0; position < saves.size(); position++) {
                if (!saves[position].isSuccess()) {
                    failures.put(
                        updatedRequests[position],
                        'The customer Account could not be updated: ' + messageFrom(saves[position].getErrors())
                    );
                }
            }
        }
        return failures;
    }

    /** A new customer Account carrying the Lead's contact and personal details. */
    private static Account newAccountFor(ConvertRequest request, Lead leadRecord) {
        Account accountRecord = new Account(
            Name = accountNameFor(request, leadRecord),
            Phone = leadRecord.Phone,
            WhatsApp_Number__c = leadRecord.MobilePhone,
            Email__c = leadRecord.Email,
            Business_Type__c = leadRecord.Business_Type__c,
            Date_of_Birth__c = leadRecord.Date_of_Birth__c,
            Anniversary_Date__c = leadRecord.Anniversary_Date__c,
            Marital_Status__c = leadRecord.Marital_Status__c,
            Primary_Store__c = leadRecord.Store_Association__c,
            Campaign_Attribution__c = leadRecord.Campaign_Attribution__c,
            WA_Opt_In__c = leadRecord.WA_Opt_In__c,
            SMS_Opt_In__c = leadRecord.SMS_Opt_In__c,
            Email_Opt_In__c = leadRecord.Email_Opt_In__c,
            Description = leadRecord.Description
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
     * phone, WhatsApp number or email already belongs to. Each comes with the Contact the Lead
     * merges into, when that Account already has the same person.
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
                Account accountRecord = pickedAccounts.get(pickedAccountId(requests[i]));
                byRequest.put(i, customerFor(accountRecord.Id, accountRecord.Name));
            } else if (requests[i].createNewAccount != true) {
                toMatch.add(i);
            }
        }

        byRequest.putAll(matchedCustomers(toMatch, requests, leadsById));
        findSamePerson(byRequest, requests, leadsById);
        return byRequest;
    }

    /** The Account the Lead's phone, WhatsApp number or email already belongs to, for each request that has one. */
    private static Map<Integer, LeadTriggerHandler.Customer> matchedCustomers(
        List<Integer> toMatch,
        List<ConvertRequest> requests,
        Map<Id, Lead> leadsById
    ) {
        Map<Integer, LeadTriggerHandler.Customer> byRequest = new Map<Integer, LeadTriggerHandler.Customer>();
        if (toMatch.isEmpty()) {
            return byRequest;
        }

        Set<String> phones = new Set<String>();
        Set<String> emails = new Set<String>();
        for (Integer i : toMatch) {
            Lead leadRecord = leadsById.get(requests[i].leadId);
            phones.addAll(LeadTriggerHandler.phonesOf(leadRecord));
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
            LeadTriggerHandler.Customer customer;
            for (String key : LeadTriggerHandler.matchKeysOf(leadRecord)) {
                if (customer == null && customers.containsKey(key)) {
                    customer = customers.get(key);
                }
            }
            // A Contact without an Account cannot take the bill; such a
            // person is treated as a new customer.
            if (customer != null && customer.accountId != null) {
                // A copy: findSamePerson sets the Contact per Lead.
                byRequest.put(i, customerFor(customer.accountId, customer.accountName));
            }
        }
        return byRequest;
    }

    private static LeadTriggerHandler.Customer customerFor(Id accountId, String accountName) {
        LeadTriggerHandler.Customer customer = new LeadTriggerHandler.Customer();
        customer.accountId = accountId;
        customer.accountName = accountName;
        return customer;
    }

    /**
     * Sets the Contact the Lead merges into: one on the customer's Account
     * with the Lead's name, phone and email. When any of them differs, the
     * contactId stays blank and the conversion creates a new Contact on the
     * Account from the Lead's details.
     */
    private static void findSamePerson(
        Map<Integer, LeadTriggerHandler.Customer> byRequest,
        List<ConvertRequest> requests,
        Map<Id, Lead> leadsById
    ) {
        Set<Id> accountIds = new Set<Id>();
        for (LeadTriggerHandler.Customer customer : byRequest.values()) {
            accountIds.add(customer.accountId);
        }
        if (accountIds.isEmpty()) {
            return;
        }

        Map<Id, List<Contact>> contactsByAccount = new Map<Id, List<Contact>>();
        for (Contact contactRecord : [
            SELECT Id, AccountId, FirstName, LastName, Phone, MobilePhone, Email
            FROM Contact
            WHERE AccountId IN :accountIds
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
        ]) {
            if (!contactsByAccount.containsKey(contactRecord.AccountId)) {
                contactsByAccount.put(contactRecord.AccountId, new List<Contact>());
            }
            contactsByAccount.get(contactRecord.AccountId).add(contactRecord);
        }

        for (Integer i : byRequest.keySet()) {
            LeadTriggerHandler.Customer customer = byRequest.get(i);
            Lead leadRecord = leadsById.get(requests[i].leadId);
            List<Contact> contacts = contactsByAccount.get(customer.accountId);
            if (contacts == null) {
                continue;
            }
            for (Contact contactRecord : contacts) {
                if (isSamePerson(contactRecord, leadRecord)) {
                    customer.contactId = contactRecord.Id;
                    break;
                }
            }
        }
    }

    /**
     * Same first name, last name, phone and email (names and email ignoring
     * case and spaces around them, phone as 10 digits on the Contact's Phone
     * or Mobile). A value blank on both counts as the same.
     */
    @TestVisible
    private static Boolean isSamePerson(Contact contactRecord, Lead leadRecord) {
        if (!sameText(contactRecord.FirstName, leadRecord.FirstName)
            || !sameText(contactRecord.LastName, leadRecord.LastName)
            || !sameText(contactRecord.Email, leadRecord.Email)) {
            return false;
        }

        String phone = LeadTriggerHandler.normalizePhone(leadRecord.Phone);
        if (String.isBlank(phone)) {
            return String.isBlank(contactRecord.Phone) && String.isBlank(contactRecord.MobilePhone);
        }
        return phone == LeadTriggerHandler.normalizePhone(contactRecord.Phone)
            || phone == LeadTriggerHandler.normalizePhone(contactRecord.MobilePhone);
    }

    private static Boolean sameText(String first, String second) {
        String a = String.isBlank(first) ? '' : first.trim();
        String b = String.isBlank(second) ? '' : second.trim();
        return a.equalsIgnoreCase(b);
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

    /** The picked Accounts. */
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
            SELECT Id, Name
            FROM Account
            WHERE Id IN :accountIds
            WITH SYSTEM_MODE
        ]);
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
            SELECT Id, FirstName, LastName, Company, Lead_Number__c, Business_Type__c, Phone, MobilePhone, Email, IsConverted, OwnerId,
                   Date_of_Birth__c, Anniversary_Date__c, Marital_Status__c, Description,
                   Store_Association__c, Campaign_Attribution__c,
                   WA_Opt_In__c, SMS_Opt_In__c, Email_Opt_In__c
            FROM Lead
            WHERE Id IN :leadIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ]);
    }

    /**
     * The name entered on the screen, else the Company when a user typed it
     * (B2B), else "<Name> Family" (B2C) - whichever format the Lead's system
     * Company is in.
     */
    @TestVisible
    private static String accountNameFor(ConvertRequest request, Lead leadRecord) {
        if (String.isNotBlank(request.accountName)) {
            return request.accountName.trim();
        }
        if (!LeadTriggerHandler.isSystemCompany(leadRecord.Company)) {
            return leadRecord.Company.trim();
        }
        return familyAccountName(LeadTriggerHandler.personName(leadRecord));
    }

    // =====================================================================
    // Family Account names
    // =====================================================================

    /** "<Name> Family", e.g. Asha Mehta Family: a new B2C customer's Account. */
    public static String familyAccountName(String personName) {
        return personName.trim() + FAMILY_SUFFIX;
    }

    /**
     * The family Account's name with one more member, e.g. "Asha Mehta
     * Family" + Rohit Mehta = "Asha Mehta & Rohit Mehta Family". Null - keep
     * the name as it is - when it does not end in "Family" (a business, or a
     * name given by hand), already holds that person's name, or would go over
     * the 255-character limit.
     */
    public static String familyAccountNameWith(String accountName, String personName) {
        if (String.isBlank(accountName) || String.isBlank(personName)) {
            return null;
        }
        String trimmed = accountName.trim();
        if (!trimmed.endsWithIgnoreCase(FAMILY_SUFFIX)) {
            return null;
        }
        String members = trimmed.left(trimmed.length() - FAMILY_SUFFIX.length()).trim();
        if (String.isBlank(members)) {
            return null;
        }
        String person = personName.trim();
        for (String member : members.split(MEMBER_SEPARATOR)) {
            if (member.trim().equalsIgnoreCase(person)) {
                return null;
            }
        }
        String withMember = members + MEMBER_SEPARATOR + person + FAMILY_SUFFIX;
        return withMember.length() > ACCOUNT_NAME_MAX_LENGTH ? null : withMember;
    }

    /**
     * A B2B Account's name with one more person, e.g. "test user" + Rakesh
     * Jain = "test user & Rakesh Jain". Null - keep the name as it is - when
     * the name already holds that person's name or would go over the
     * 255-character limit.
     */
    public static String businessAccountNameWith(String accountName, String personName) {
        if (String.isBlank(accountName) || String.isBlank(personName)) {
            return null;
        }
        String trimmed = accountName.trim();
        String person = personName.trim();
        for (String member : trimmed.split(MEMBER_SEPARATOR)) {
            if (member.trim().equalsIgnoreCase(person)) {
                return null;
            }
        }
        String withMember = trimmed + MEMBER_SEPARATOR + person;
        return withMember.length() > ACCOUNT_NAME_MAX_LENGTH ? null : withMember;
    }

    /**
     * The Lead's Business Type, B2B or B2C. A blank or Unknown Business Type
     * (older Leads) follows the Company: a typed Company is B2B, the
     * system's Company is B2C.
     */
    @TestVisible
    private static String businessTypeOf(Lead leadRecord) {
        if (leadRecord.Business_Type__c == BUSINESS_TYPE_B2B || leadRecord.Business_Type__c == BUSINESS_TYPE_B2C) {
            return leadRecord.Business_Type__c;
        }
        return LeadTriggerHandler.isSystemCompany(leadRecord.Company) ? BUSINESS_TYPE_B2C : BUSINESS_TYPE_B2B;
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