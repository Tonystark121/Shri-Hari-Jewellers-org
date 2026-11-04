/**
 * @description
 * Trigger logic for Lead.
 *
 * Phone
 *   Phone is saved exactly as entered. The validation rule
 *   Phone_Must_Be_10_Digits checks it, and matching compares the cleaned
 *   10-digit form (normalizePhone) without changing it.
 *
 * B2C Company
 *   Company is required on Lead, but a B2C customer has none. When Company
 *   is blank (uploads, API) or still holds the New Lead screen's default
 *   "<Name> - B2C", the Lead is B2C: Business Type is set to B2C and Company
 *   becomes "<Name> B2C (<Lead Number>)", e.g. Asha Mehta B2C (000123).
 *   The Lead Number only exists once the Lead is saved, so it is added in
 *   after insert. A Company that was typed in is kept as it is.
 *
 *   On a B2C Lead the Company is then maintained by the system only: it
 *   follows name changes and cannot be changed by hand. (Company is
 *   system-required, so it cannot be made read-only on the page layout.)
 *   Leads saved before this format keep theirs - "<Name> Family (<Lead
 *   Number>)" or "<Name> - B2C-<Lead Number>" - and it still follows name
 *   changes in that form.
 *
 * Existing customers
 *   A Lead whose phone or email belongs to an existing customer (Account or
 *   Contact) is not saved: an enquiry Case is raised for the customer
 *   instead. The New Lead flow, Upload Leads and the website API
 *   (ShreeHariLeadRestResource) raise the enquiry before saving; this check
 *   stops any other insert. A customer known only as a Contact (no Account)
 *   is given an Account when its enquiry is raised (createCustomerAccounts).
 *
 * Conversion
 *   A Lead converts only together with its first bill, through
 *   LeadConversionTransactionService. Any other conversion is refused.
 *
 * Changing a Lead's phone or email
 *   An edit that gives a Lead the phone or email of an existing customer or
 *   of another open Lead is refused, with the same matching as on create
 *   (blockTakenContactDetails). The Lead keeps its old value. Only a value
 *   that really changed is checked.
 *
 * Duplicate open Leads on create are blocked by the Lead Duplicate Check
 * duplicate rule (exact matches, create and edit), not here.
 *
 * Matching ("is this person already known?")
 *   Also used by the New Lead flow (invocable check()) and, later, by the
 *   website API and Lead conversion:
 *     - existing customer: an Account whose Phone or Email matches, or a
 *       Contact whose Phone, Mobile or Email matches;
 *     - open Lead: an unconverted Lead whose Phone or Email matches.
 *   Phones are compared as 10 digits: normalizePhone() removes spaces,
 *   dashes, brackets, dots and a leading +91 or 91 for comparing only. Stored
 *   phones can be in any format (e.g. +91-9830012345), so they are found by
 *   trying the common stored forms of each number and normalising what
 *   comes back.
 *
 * Runs without sharing: the Company update after insert must succeed even
 * when an assignment rule has given the Lead to another user, and a customer
 * or Lead the current user cannot see is still the same person and must
 * still be found. For the same reason its queries and the Company update
 * run in system mode: Apex at this API version otherwise enforces the
 * running user's field-level security.
 */
public without sharing class LeadTriggerHandler {

    @TestVisible
    private static final String BUSINESS_TYPE_B2C = 'B2C';

    private static final String BUSINESS_TYPE_B2B = 'B2B';

    private static final String B2C_SUFFIX = ' - B2C';

    @TestVisible
    private static final String COMPANY_LOCKED =
        'Company is set automatically for B2C Leads and cannot be changed.';

    @TestVisible
    private static final String CONVERSION_NOT_ALLOWED =
        'A Lead is converted only when the customer buys. Use the Convert button and enter the bill.';

    /** True while this class writes the Lead Number into Company. */
    private static Boolean stampingCompany = false;

    // =====================================================================
    // Trigger entry points
    // =====================================================================

    public static void beforeInsert(List<Lead> leads) {
        for (Lead leadRecord : leads) {
            if (isAutoCompany(leadRecord.Company)) {
                leadRecord.Business_Type__c = BUSINESS_TYPE_B2C;
                // Placeholder until the Lead Number exists (after insert).
                leadRecord.Company = companyStem(leadRecord);
            }
        }

        blockExistingCustomers(leads);
    }

    /** Adds the Lead Number to the Company of every new B2C Lead. */
    public static void afterInsert(List<Lead> leads) {
        List<Lead> toStamp = new List<Lead>();
        for (Lead leadRecord : leads) {
            if (leadRecord.Business_Type__c == BUSINESS_TYPE_B2C && leadRecord.Company == companyStem(leadRecord)) {
                toStamp.add(new Lead(Id = leadRecord.Id, Company = b2cCompany(leadRecord)));
            }
        }

        if (toStamp.isEmpty()) {
            return;
        }

        stampingCompany = true;
        try {
            update as system toStamp;
        } finally {
            stampingCompany = false;
        }
    }

    public static void beforeUpdate(List<Lead> leads, Map<Id, Lead> oldLeads) {
        List<Lead> contactDetailsChanged = new List<Lead>();
        for (Lead leadRecord : leads) {
            Lead oldLead = oldLeads.get(leadRecord.Id);

            // A Lead converts only when it buys, through the Convert button
            // (LeadConversionTransactionService). Standard conversion - the Convert
            // dialog, the Path's Converted step, the API - is refused.
            if (leadRecord.IsConverted && !oldLead.IsConverted && !LeadConversionTransactionService.isConverting()) {
                leadRecord.addError(CONVERSION_NOT_ALLOWED);
                continue;
            }

            // Conversion updates the Lead too; leave it alone.
            if (leadRecord.IsConverted) {
                continue;
            }

            if (phoneChanged(leadRecord, oldLead) || emailChanged(leadRecord, oldLead)) {
                contactDetailsChanged.add(leadRecord);
            }

            if (stampingCompany || oldLead.Business_Type__c != BUSINESS_TYPE_B2C) {
                continue;
            }

            if (leadRecord.Company != oldLead.Company) {
                leadRecord.Company.addError(COMPANY_LOCKED);
                continue;
            }

            // Keep the Company in step with the person's name, as long as it
            // is still the system's value.
            Boolean nameChanged = leadRecord.FirstName != oldLead.FirstName || leadRecord.LastName != oldLead.LastName;
            if (nameChanged && oldLead.Company == b2cCompany(oldLead)) {
                leadRecord.Company = b2cCompany(leadRecord);
            } else if (nameChanged && oldLead.Company == familyB2cCompany(oldLead)) {
                leadRecord.Company = familyB2cCompany(leadRecord);
            } else if (nameChanged && oldLead.Company == legacyB2cCompany(oldLead)) {
                leadRecord.Company = legacyB2cCompany(leadRecord);
            }
        }

        blockTakenContactDetails(contactDetailsChanged, oldLeads);
    }

    // =====================================================================
    // Existing customers
    // =====================================================================

    private static void blockExistingCustomers(List<Lead> leads) {
        Set<String> phones = new Set<String>();
        Set<String> emails = new Set<String>();

        for (Lead leadRecord : leads) {
            String phone = normalizePhone(leadRecord.Phone);
            if (isValidPhone(phone)) {
                phones.add(phone);
            }
            if (String.isNotBlank(leadRecord.Email)) {
                emails.add(leadRecord.Email);
            }
        }

        Map<String, Customer> customers = findCustomers(phones, emails);
        if (customers.isEmpty()) {
            return;
        }

        for (Lead leadRecord : leads) {
            Customer customer;
            String phone = normalizePhone(leadRecord.Phone);
            if (isValidPhone(phone)) {
                customer = customers.get(phoneKey(phone));
            }
            if (customer == null && String.isNotBlank(leadRecord.Email)) {
                customer = customers.get(emailKey(leadRecord.Email));
            }
            if (customer != null) {
                leadRecord.addError(
                    'An existing customer has this phone or email: ' + customer.accountName
                    + '. Raise an enquiry (Case) for that customer instead of creating a Lead.'
                );
            }
        }
    }

    /**
     * A Lead's phone or email changed to one that an existing customer or
     * another open Lead already has: the change is refused, as those details
     * are refused on a new Lead. The Lead keeps its old value. Only a value
     * that really changed is checked - phones as 10 digits, emails ignoring
     * case - so retyping the same phone in another format, or editing any
     * other field, is not stopped. Two Leads in one save cannot take the same
     * new phone or email either.
     */
    private static void blockTakenContactDetails(List<Lead> leads, Map<Id, Lead> oldLeads) {
        if (leads.isEmpty()) {
            return;
        }

        Set<String> phones = new Set<String>();
        Set<String> emails = new Set<String>();
        for (Lead leadRecord : leads) {
            Lead oldLead = oldLeads.get(leadRecord.Id);
            if (phoneChanged(leadRecord, oldLead)) {
                phones.add(normalizePhone(leadRecord.Phone));
            }
            if (emailChanged(leadRecord, oldLead)) {
                emails.add(leadRecord.Email);
            }
        }

        Map<String, Customer> customers = findCustomers(phones, emails);
        Map<String, Lead> openLeads = findOpenLeads(phones, emails);
        Map<String, Id> takenInThisSave = new Map<String, Id>();

        for (Lead leadRecord : leads) {
            Lead oldLead = oldLeads.get(leadRecord.Id);
            if (phoneChanged(leadRecord, oldLead)) {
                String reason = takenReason(
                    leadRecord, phoneKey(normalizePhone(leadRecord.Phone)), 'phone', customers, openLeads, takenInThisSave
                );
                if (reason != null) {
                    leadRecord.Phone.addError(reason);
                }
            }
            if (emailChanged(leadRecord, oldLead)) {
                String reason = takenReason(
                    leadRecord, emailKey(leadRecord.Email), 'email', customers, openLeads, takenInThisSave
                );
                if (reason != null) {
                    leadRecord.Email.addError(reason);
                }
            }
        }
    }

    /** Why the Lead cannot take this phone or email, or null when it is free. */
    private static String takenReason(
        Lead leadRecord,
        String key,
        String label,
        Map<String, Customer> customers,
        Map<String, Lead> openLeads,
        Map<String, Id> takenInThisSave
    ) {
        Customer customer = customers.get(key);
        if (customer != null) {
            return 'This ' + label + ' belongs to an existing customer: ' + customer.accountName
                + '. Raise an enquiry (Case) for that customer instead.';
        }
        Lead openLead = openLeads.get(key);
        if (openLead != null && openLead.Id != leadRecord.Id) {
            return 'A Lead with this ' + label + ' already exists: ' + openLead.Name
                + ' (owner ' + openLead.Owner.Name + ').';
        }
        if (takenInThisSave.containsKey(key) && takenInThisSave.get(key) != leadRecord.Id) {
            return 'Another Lead in this save has the same ' + label + '.';
        }
        takenInThisSave.put(key, leadRecord.Id);
        return null;
    }

    /** The phone now is a valid number that differs, as 10 digits, from before. */
    private static Boolean phoneChanged(Lead leadRecord, Lead oldLead) {
        String phone = normalizePhone(leadRecord.Phone);
        return isValidPhone(phone) && phone != normalizePhone(oldLead.Phone);
    }

    /** The email now is set and differs, ignoring case, from before. */
    private static Boolean emailChanged(Lead leadRecord, Lead oldLead) {
        if (String.isBlank(leadRecord.Email)) {
            return false;
        }
        return String.isBlank(oldLead.Email)
            || leadRecord.Email.trim().toLowerCase() != oldLead.Email.trim().toLowerCase();
    }

    // =====================================================================
    // Company
    // =====================================================================

    /** Blank, or the New Lead screen's default "<Name> - B2C". */
    @TestVisible
    private static Boolean isAutoCompany(String company) {
        return String.isBlank(company) || company.trim().endsWithIgnoreCase(B2C_SUFFIX);
    }

    /**
     * True when Company was filled in by the system rather than typed by a
     * user: blank, "<Name> - B2C", "<Name> B2C (<Lead Number>)" or the
     * earlier "<Name> Family (<Lead Number>)" and "<Name> - B2C-<Lead Number>".
     */
    public static Boolean isSystemCompany(String company) {
        return String.isBlank(company)
            || Pattern.matches('(?i).* - B2C(-[0-9]+)?|.* (B2C|Family) [(][0-9]+[)]', company.trim());
    }

    /** "<First Name> <Last Name>" */
    public static String personName(Lead leadRecord) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(leadRecord.FirstName)) {
            parts.add(leadRecord.FirstName.trim());
        }
        if (String.isNotBlank(leadRecord.LastName)) {
            parts.add(leadRecord.LastName.trim());
        }
        return String.join(parts, ' ');
    }

    /** "<First Name> <Last Name> - B2C": the placeholder until the Lead Number exists. */
    @TestVisible
    private static String companyStem(Lead leadRecord) {
        return personName(leadRecord) + B2C_SUFFIX;
    }

    /** "<First Name> <Last Name> B2C (<Lead Number>)", e.g. Asha Mehta B2C (000123). */
    public static String b2cCompany(Lead leadRecord) {
        return personName(leadRecord) + ' B2C (' + leadRecord.Lead_Number__c + ')';
    }

    /** The earlier format, "<First Name> <Last Name> Family (<Lead Number>)", kept by Leads saved before. */
    @TestVisible
    private static String familyB2cCompany(Lead leadRecord) {
        return personName(leadRecord) + ' Family (' + leadRecord.Lead_Number__c + ')';
    }

    /** The earlier format, "<First Name> <Last Name> - B2C-<Lead Number>", kept by Leads saved before. */
    @TestVisible
    private static String legacyB2cCompany(Lead leadRecord) {
        return companyStem(leadRecord) + '-' + leadRecord.Lead_Number__c;
    }

    // =====================================================================
    // Matching: phone numbers
    // =====================================================================

    /**
     * The 10-digit form of a phone number: spaces, dashes, brackets and dots
     * removed, then a leading +91 or 91 dropped when 12 digits remain.
     * Anything else (letters, other country codes, wrong length) comes back
     * cleaned but not 10 digits, so isValidPhone() rejects it.
     */
    public static String normalizePhone(String phone) {
        if (String.isBlank(phone)) {
            return phone;
        }

        String cleaned = phone.replaceAll('[\\s\\-().]', '');
        Boolean hasPlus = cleaned.startsWith('+');
        String digits = hasPlus ? cleaned.substring(1) : cleaned;

        if (!digits.isNumeric()) {
            return phone.trim();
        }
        if (digits.length() == 12 && digits.startsWith('91')) {
            return digits.substring(2);
        }
        return hasPlus ? '+' + digits : digits;
    }

    /** True for a 10-digit number. */
    public static Boolean isValidPhone(String normalizedPhone) {
        return normalizedPhone != null && Pattern.matches('[0-9]{10}', normalizedPhone);
    }

    /** Forms a 10-digit number is commonly stored in on Accounts and Contacts. */
    @TestVisible
    private static Set<String> storedFormsOf(Set<String> normalizedPhones) {
        Set<String> forms = new Set<String>();
        for (String phone : normalizedPhones) {
            if (!isValidPhone(phone)) {
                continue;
            }
            String spaced = phone.left(5) + ' ' + phone.right(5);
            forms.addAll(new List<String>{
                phone,
                '+91' + phone,
                '91' + phone,
                '0' + phone,
                '+91-' + phone,
                '+91 ' + phone,
                '+91 ' + spaced,
                spaced
            });
        }
        return forms;
    }

    // =====================================================================
    // Matching: existing customers
    // =====================================================================

    public class Customer {
        public Id accountId;
        public String accountName;
        /** Account owner, or null when the owner is inactive. */
        public Id ownerId;
        public Id contactId;
    }

    public static String phoneKey(String normalizedPhone) {
        return 'phone:' + normalizedPhone;
    }

    public static String emailKey(String email) {
        return 'email:' + email.trim().toLowerCase();
    }

    /**
     * Existing customers for the given phones (10-digit form) and emails,
     * keyed by phoneKey() / emailKey(). A Contact match wins over an Account
     * match, because it identifies the person as well as the household; among
     * several matches the most recently modified wins.
     */
    public static Map<String, Customer> findCustomers(Set<String> normalizedPhones, Set<String> emails) {
        Map<String, Customer> customers = new Map<String, Customer>();
        Set<String> phoneForms = storedFormsOf(normalizedPhones == null ? new Set<String>() : normalizedPhones);
        Set<String> lowerEmails = lowerCased(emails);

        if (phoneForms.isEmpty() && lowerEmails.isEmpty()) {
            return customers;
        }

        for (Contact contactRecord : [
            SELECT Id, Name, Phone, MobilePhone, Email,
                   AccountId, Account.Name, Account.OwnerId, Account.Owner.IsActive
            FROM Contact
            WHERE Phone IN :phoneForms
               OR MobilePhone IN :phoneForms
               OR Email IN :lowerEmails
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
        ]) {
            Customer customer = new Customer();
            customer.contactId = contactRecord.Id;
            customer.accountId = contactRecord.AccountId;
            customer.accountName = contactRecord.AccountId == null ? contactRecord.Name : contactRecord.Account.Name;
            customer.ownerId = contactRecord.AccountId != null && contactRecord.Account.Owner.IsActive
                ? contactRecord.Account.OwnerId
                : null;

            putIfAbsent(customers, phoneMatchKey(contactRecord.Phone, normalizedPhones), customer);
            putIfAbsent(customers, phoneMatchKey(contactRecord.MobilePhone, normalizedPhones), customer);
            if (String.isNotBlank(contactRecord.Email) && lowerEmails.contains(contactRecord.Email.toLowerCase())) {
                putIfAbsent(customers, emailKey(contactRecord.Email), customer);
            }
        }

        for (Account accountRecord : [
            SELECT Id, Name, Phone, Email__c, OwnerId, Owner.IsActive
            FROM Account
            WHERE Phone IN :phoneForms
               OR Email__c IN :lowerEmails
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
        ]) {
            Customer customer = new Customer();
            customer.accountId = accountRecord.Id;
            customer.accountName = accountRecord.Name;
            customer.ownerId = accountRecord.Owner.IsActive ? accountRecord.OwnerId : null;

            putIfAbsent(customers, phoneMatchKey(accountRecord.Phone, normalizedPhones), customer);
            if (String.isNotBlank(accountRecord.Email__c) && lowerEmails.contains(accountRecord.Email__c.toLowerCase())) {
                putIfAbsent(customers, emailKey(accountRecord.Email__c), customer);
            }
        }

        return customers;
    }

    /**
     * Every customer Account for the given phones (10-digit form) and emails,
     * keyed by phoneKey() / emailKey(): Accounts with that phone or email and
     * the Accounts of Contacts with it, most recently modified first, each
     * Account once per key. Lets staff pick the customer when there are
     * several.
     */
    public static Map<String, List<Account>> findAccounts(Set<String> normalizedPhones, Set<String> emails) {
        Map<String, List<Account>> accountsByKey = new Map<String, List<Account>>();
        Set<String> phoneForms = storedFormsOf(normalizedPhones == null ? new Set<String>() : normalizedPhones);
        Set<String> lowerEmails = lowerCased(emails);

        if (phoneForms.isEmpty() && lowerEmails.isEmpty()) {
            return accountsByKey;
        }

        Map<Id, Set<String>> keysByAccountId = new Map<Id, Set<String>>();
        for (Contact contactRecord : [
            SELECT AccountId, Phone, MobilePhone, Email
            FROM Contact
            WHERE AccountId != null
              AND (Phone IN :phoneForms OR MobilePhone IN :phoneForms OR Email IN :lowerEmails)
            WITH SYSTEM_MODE
        ]) {
            addKey(keysByAccountId, contactRecord.AccountId, phoneMatchKey(contactRecord.Phone, normalizedPhones));
            addKey(keysByAccountId, contactRecord.AccountId, phoneMatchKey(contactRecord.MobilePhone, normalizedPhones));
            addKey(keysByAccountId, contactRecord.AccountId, emailMatchKey(contactRecord.Email, lowerEmails));
        }
        for (Account accountRecord : [
            SELECT Id, Phone, Email__c
            FROM Account
            WHERE Phone IN :phoneForms OR Email__c IN :lowerEmails
            WITH SYSTEM_MODE
        ]) {
            addKey(keysByAccountId, accountRecord.Id, phoneMatchKey(accountRecord.Phone, normalizedPhones));
            addKey(keysByAccountId, accountRecord.Id, emailMatchKey(accountRecord.Email__c, lowerEmails));
        }

        if (keysByAccountId.isEmpty()) {
            return accountsByKey;
        }

        Set<Id> accountIds = keysByAccountId.keySet();
        for (Account accountRecord : [
            SELECT Id, Name, Phone, Email__c, Customer_Tier__c, Last_12M_Spend__c, CASA_ID__c
            FROM Account
            WHERE Id IN :accountIds
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
        ]) {
            for (String key : keysByAccountId.get(accountRecord.Id)) {
                if (!accountsByKey.containsKey(key)) {
                    accountsByKey.put(key, new List<Account>());
                }
                accountsByKey.get(key).add(accountRecord);
            }
        }
        return accountsByKey;
    }

    // =====================================================================
    // Existing customers: a Contact without an Account
    // =====================================================================

    /**
     * Gives every customer that is only a Contact (no Account) an Account
     * before its enquiry Case is raised, and moves the Contact under it, so
     * the enquiry sits on an Account like any other.
     *
     * The Account is named as on conversion: the Lead's Company when one was
     * typed (B2B), else "<Name> Family" (B2C). Every other value comes from
     * the Lead - the details just entered - and, where the Lead has none,
     * from the Contact. The user raising the enquiry owns the Account, so
     * the enquiry goes to them.
     *
     * leads[i] holds the enquiry's details for customers[i]; a null customer
     * or one that already has an Account is left alone. Customers are
     * updated in place (Account Id, name and owner). A Contact found for two
     * Leads gets one Account, built from the first Lead.
     *
     * Returns the reason for each position that could not be given an
     * Account; nothing is left half done for it.
     */
    public static Map<Integer, String> createCustomerAccounts(List<Lead> leads, List<Customer> customers) {
        Map<Integer, String> failures = new Map<Integer, String>();
        Map<Id, Integer> firstPositionByContact = new Map<Id, Integer>();
        for (Integer i = 0; i < customers.size(); i++) {
            Customer customer = customers[i];
            if (customer != null && customer.accountId == null && customer.contactId != null
                && !firstPositionByContact.containsKey(customer.contactId)) {
                firstPositionByContact.put(customer.contactId, i);
            }
        }
        if (firstPositionByContact.isEmpty()) {
            return failures;
        }

        Map<Id, Contact> contacts = new Map<Id, Contact>([
            SELECT Id, FirstName, LastName, Phone, MobilePhone, Email, Description,
                   Birthdate, Anniversary_Date__c, Marital_Status__c,
                   MailingStreet, MailingCity, MailingState, MailingPostalCode, MailingCountry,
                   AccountId, Account.Name, Account.OwnerId, Account.Owner.IsActive
            FROM Contact
            WHERE Id IN :firstPositionByContact.keySet()
            WITH SYSTEM_MODE
        ]);

        // What each Contact ends up with: an Account, or the reason it has none.
        Map<Id, Customer> outcomes = new Map<Id, Customer>();
        Map<Id, String> reasons = new Map<Id, String>();
        List<Id> contactIds = new List<Id>();
        List<Account> accounts = new List<Account>();
        for (Id contactId : firstPositionByContact.keySet()) {
            Contact person = contacts.get(contactId);
            if (person == null) {
                reasons.put(contactId, 'The customer\'s Contact no longer exists.');
            } else if (person.AccountId != null) {
                // Placed under an Account since it was found: use that one.
                Customer outcome = new Customer();
                outcome.accountId = person.AccountId;
                outcome.accountName = person.Account.Name;
                outcome.ownerId = person.Account.Owner.IsActive ? person.Account.OwnerId : null;
                outcomes.put(contactId, outcome);
            } else {
                contactIds.add(contactId);
                accounts.add(newCustomerAccount(leads[firstPositionByContact.get(contactId)], person));
            }
        }

        if (!accounts.isEmpty()) {
            Database.DMLOptions options = new Database.DMLOptions();
            options.optAllOrNone = false;
            // The customer is already known: the platform's duplicate alerts must not stop it.
            options.DuplicateRuleHeader.allowSave = true;

            List<Database.SaveResult> accountSaves = Database.insert(accounts, options, AccessLevel.SYSTEM_MODE);
            List<Id> linkedContactIds = new List<Id>();
            List<Contact> links = new List<Contact>();
            for (Integer i = 0; i < accountSaves.size(); i++) {
                if (accountSaves[i].isSuccess()) {
                    linkedContactIds.add(contactIds[i]);
                    links.add(new Contact(Id = contactIds[i], AccountId = accounts[i].Id));
                } else {
                    reasons.put(contactIds[i], 'The customer Account could not be created: '
                        + errorText(accountSaves[i].getErrors()));
                }
            }

            Map<Id, Account> accountsByContact = new Map<Id, Account>();
            for (Integer i = 0; i < contactIds.size(); i++) {
                accountsByContact.put(contactIds[i], accounts[i]);
            }

            if (!links.isEmpty()) {
                List<Database.SaveResult> linkSaves = Database.update(links, options, AccessLevel.SYSTEM_MODE);
                List<Account> unlinked = new List<Account>();
                for (Integer i = 0; i < linkSaves.size(); i++) {
                    Id contactId = linkedContactIds[i];
                    Account created = accountsByContact.get(contactId);
                    if (linkSaves[i].isSuccess()) {
                        Customer outcome = new Customer();
                        outcome.accountId = created.Id;
                        outcome.accountName = created.Name;
                        outcome.ownerId = created.OwnerId;
                        outcomes.put(contactId, outcome);
                    } else {
                        unlinked.add(created);
                        reasons.put(contactId, 'The customer\'s Contact could not be moved to its new Account: '
                            + errorText(linkSaves[i].getErrors()));
                    }
                }
                // An Account its Contact could not join is taken away again,
                // with its Loyalty Record (master-detail).
                if (!unlinked.isEmpty()) {
                    Database.delete(unlinked, false, AccessLevel.SYSTEM_MODE);
                }
            }
        }

        for (Integer i = 0; i < customers.size(); i++) {
            Customer customer = customers[i];
            if (customer == null || customer.accountId != null || customer.contactId == null) {
                continue;
            }
            Customer outcome = outcomes.get(customer.contactId);
            if (outcome == null) {
                failures.put(i, reasons.get(customer.contactId));
                continue;
            }
            customer.accountId = outcome.accountId;
            customer.accountName = outcome.accountName;
            customer.ownerId = outcome.ownerId;
        }
        return failures;
    }

    /**
     * The new Account for a customer known only as a Contact: the Lead's
     * details first, the Contact's where the Lead has none.
     */
    private static Account newCustomerAccount(Lead leadRecord, Contact person) {
        Lead details = leadRecord == null ? new Lead() : leadRecord;
        Boolean isBusiness = !isSystemCompany(details.Company);

        String name = personName(String.isBlank(details.LastName)
            ? new Lead(FirstName = person.FirstName, LastName = person.LastName)
            : details);

        Account accountRecord = new Account(
            Name = isBusiness ? details.Company.trim() : LeadConversionTransactionService.familyAccountName(name),
            Business_Type__c = isBusiness ? BUSINESS_TYPE_B2B : BUSINESS_TYPE_B2C,
            OwnerId = UserInfo.getUserId(),
            Phone = firstNotBlank(details.Phone, firstNotBlank(person.Phone, person.MobilePhone)),
            Email__c = firstNotBlank(details.Email, person.Email),
            Date_of_Birth__c = details.Date_of_Birth__c != null ? details.Date_of_Birth__c : person.Birthdate,
            Primary_Store__c = details.Store_Association__c,
            Campaign_Attribution__c = details.Campaign_Attribution__c,
            Website = details.Website,
            Description = firstNotBlank(details.Description, person.Description)
        );

        // Marital Status and Anniversary Date belong together: both from the
        // Lead when it has a Marital Status, else both from the Contact.
        if (String.isNotBlank(details.Marital_Status__c)) {
            accountRecord.Marital_Status__c = details.Marital_Status__c;
            accountRecord.Anniversary_Date__c = details.Anniversary_Date__c;
        } else {
            accountRecord.Marital_Status__c = person.Marital_Status__c;
            accountRecord.Anniversary_Date__c = person.Anniversary_Date__c;
        }

        // The address as a whole: the Lead's when it has any part, else the Contact's.
        if (String.isNotBlank(details.Street) || String.isNotBlank(details.City) || String.isNotBlank(details.State)
            || String.isNotBlank(details.PostalCode) || String.isNotBlank(details.Country)) {
            accountRecord.BillingStreet = details.Street;
            accountRecord.BillingCity = details.City;
            accountRecord.BillingState = details.State;
            accountRecord.BillingPostalCode = details.PostalCode;
            accountRecord.BillingCountry = details.Country;
        } else {
            accountRecord.BillingStreet = person.MailingStreet;
            accountRecord.BillingCity = person.MailingCity;
            accountRecord.BillingState = person.MailingState;
            accountRecord.BillingPostalCode = person.MailingPostalCode;
            accountRecord.BillingCountry = person.MailingCountry;
        }
        return accountRecord;
    }

    private static String firstNotBlank(String preferred, String fallback) {
        return String.isNotBlank(preferred) ? preferred : fallback;
    }

    private static String errorText(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error error : errors) {
            messages.add(error.getMessage());
        }
        return String.join(messages, ' ');
    }

    // =====================================================================
    // Matching: open Leads
    // =====================================================================

    /**
     * Unconverted Leads for the given phones (10-digit form) and emails,
     * keyed by phoneKey() / emailKey().
     */
    public static Map<String, Lead> findOpenLeads(Set<String> normalizedPhones, Set<String> emails) {
        Map<String, Lead> leads = new Map<String, Lead>();
        Set<String> phoneForms = storedFormsOf(normalizedPhones == null ? new Set<String>() : normalizedPhones);
        Set<String> lowerEmails = lowerCased(emails);

        if (phoneForms.isEmpty() && lowerEmails.isEmpty()) {
            return leads;
        }

        for (Lead leadRecord : [
            SELECT Id, Name, Phone, Email, Owner.Name
            FROM Lead
            WHERE IsConverted = false
              AND (Phone IN :phoneForms OR Email IN :lowerEmails)
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
        ]) {
            String phoneKey = phoneMatchKey(leadRecord.Phone, normalizedPhones);
            if (phoneKey != null && !leads.containsKey(phoneKey)) {
                leads.put(phoneKey, leadRecord);
            }
            if (String.isNotBlank(leadRecord.Email) && lowerEmails.contains(leadRecord.Email.toLowerCase())) {
                String key = emailKey(leadRecord.Email);
                if (!leads.containsKey(key)) {
                    leads.put(key, leadRecord);
                }
            }
        }
        return leads;
    }

    // =====================================================================
    // Matching: New Lead flow
    // =====================================================================

    public class CheckRequest {
        @InvocableVariable(label='Phone' description='Phone as entered. It is cleaned to 10 digits before matching.')
        public String phone;

        @InvocableVariable(label='Email' description='Email as entered.')
        public String email;

        @InvocableVariable(label='Create Customer Account' description='True when the enquiry is being saved: a customer known only as a Contact (no Account) is given an Account, built from Lead and the Contact, and the Contact is moved under it.')
        public Boolean createCustomerAccount;

        @InvocableVariable(label='Lead' description='The details entered for the new Lead. Used for the new Account when Create Customer Account is true.')
        public Lead leadRecord;
    }

    /** An existing customer's Contact could not be given an Account. */
    public class CustomerAccountException extends Exception {}

    public class CheckResult {
        @InvocableVariable(label='Normalized Phone' description='Phone cleaned to 10 digits (spaces, dashes and a leading +91 or 91 removed).')
        public String normalizedPhone;

        @InvocableVariable(label='Is Phone Valid' description='True when Phone is blank or a 10-digit number.')
        public Boolean isPhoneValid;

        @InvocableVariable(label='Is Existing Customer' description='True when an Account or Contact has this phone or email.')
        public Boolean isExistingCustomer;

        @InvocableVariable(label='Account Id')
        public Id accountId;

        @InvocableVariable(label='Account Name')
        public String accountName;

        @InvocableVariable(label='Contact Id')
        public Id contactId;

        @InvocableVariable(label='Case Owner Id' description='Account owner, or the current user when the owner is inactive.')
        public Id caseOwnerId;

        @InvocableVariable(label='Matching Accounts' description='Every Account with this phone or email, or with a Contact that has it. Most recently changed first.')
        public List<Account> matchingAccounts;

        @InvocableVariable(label='Matching Account Count')
        public Integer matchingAccountCount;

        @InvocableVariable(label='Is Open Lead' description='True when an unconverted Lead has this phone or email.')
        public Boolean isOpenLead;

        @InvocableVariable(label='Open Lead Id')
        public Id openLeadId;

        @InvocableVariable(label='Open Lead Name')
        public String openLeadName;

        @InvocableVariable(label='Open Lead Owner Name')
        public String openLeadOwnerName;
    }

    /**
     * For the New Lead flow: cleans the phone, then reports an existing
     * customer (an enquiry Case is created instead of a Lead) or an open Lead
     * (the new Lead would be a duplicate). An existing customer is checked
     * first.
     *
     * Called again with Create Customer Account just before the enquiry is
     * saved: a customer known only as a Contact is then given an Account
     * (createCustomerAccounts) and reported with it.
     */
    @InvocableMethod(
        label='Check Existing Customer or Lead'
        description='Cleans the phone to 10 digits and finds an existing customer (Account or Contact) or an open Lead with the same phone or email.'
        category='Lead'
    )
    public static List<CheckResult> check(List<CheckRequest> requests) {
        Set<String> phones = new Set<String>();
        Set<String> emails = new Set<String>();
        List<String> normalizedPhones = new List<String>();

        for (CheckRequest request : requests) {
            String normalized = normalizePhone(request.phone);
            normalizedPhones.add(normalized);
            if (isValidPhone(normalized)) {
                phones.add(normalized);
            }
            if (String.isNotBlank(request.email)) {
                emails.add(request.email);
            }
        }

        Map<String, Customer> customers = findCustomers(phones, emails);
        Map<String, List<Account>> accountsByKey = customers.isEmpty()
            ? new Map<String, List<Account>>()
            : findAccounts(phones, emails);
        Map<String, Lead> openLeads = findOpenLeads(phones, emails);

        List<CheckResult> results = new List<CheckResult>();
        List<Customer> customerOf = new List<Customer>();
        List<Lead> accountLeads = new List<Lead>();
        List<Customer> accountCustomers = new List<Customer>();
        for (Integer i = 0; i < requests.size(); i++) {
            CheckRequest request = requests[i];
            CheckResult result = new CheckResult();
            result.normalizedPhone = normalizedPhones[i];
            result.isPhoneValid = String.isBlank(result.normalizedPhone) || isValidPhone(result.normalizedPhone);

            List<String> keys = new List<String>();
            if (isValidPhone(result.normalizedPhone)) {
                keys.add(phoneKey(result.normalizedPhone));
            }
            if (String.isNotBlank(request.email)) {
                keys.add(emailKey(request.email));
            }

            Customer customer;
            Lead openLead;
            Map<Id, Account> matchingAccounts = new Map<Id, Account>();
            for (String key : keys) {
                if (customer == null && customers.containsKey(key)) {
                    customer = customers.get(key);
                }
                if (openLead == null && openLeads.containsKey(key)) {
                    openLead = openLeads.get(key);
                }
                if (accountsByKey.containsKey(key)) {
                    for (Account accountRecord : accountsByKey.get(key)) {
                        if (!matchingAccounts.containsKey(accountRecord.Id)) {
                            matchingAccounts.put(accountRecord.Id, accountRecord);
                        }
                    }
                }
            }
            result.matchingAccounts = matchingAccounts.values();
            result.matchingAccountCount = matchingAccounts.size();

            result.isExistingCustomer = customer != null;
            customerOf.add(customer);
            if (customer != null && request.createCustomerAccount == true) {
                accountLeads.add(request.leadRecord);
                accountCustomers.add(customer);
            }

            result.isOpenLead = openLead != null;
            if (openLead != null) {
                result.openLeadId = openLead.Id;
                result.openLeadName = openLead.Name;
                result.openLeadOwnerName = openLead.Owner.Name;
            }
            results.add(result);
        }

        if (!accountCustomers.isEmpty()) {
            Map<Integer, String> failures = createCustomerAccounts(accountLeads, accountCustomers);
            if (!failures.isEmpty()) {
                throw new CustomerAccountException(failures.values()[0]);
            }
        }

        for (Integer i = 0; i < results.size(); i++) {
            Customer customer = customerOf[i];
            if (customer != null) {
                results[i].accountId = customer.accountId;
                results[i].accountName = customer.accountName;
                results[i].contactId = customer.contactId;
                results[i].caseOwnerId = customer.ownerId == null ? UserInfo.getUserId() : customer.ownerId;
            }
        }
        return results;
    }

    // =====================================================================
    // Matching: helpers
    // =====================================================================

    /** phoneKey() of a stored phone when it is one of the numbers searched for, else null. */
    private static String phoneMatchKey(String storedPhone, Set<String> normalizedPhones) {
        if (String.isBlank(storedPhone) || normalizedPhones == null) {
            return null;
        }
        String normalized = normalizePhone(storedPhone);
        return normalizedPhones.contains(normalized) ? phoneKey(normalized) : null;
    }

    /** emailKey() of a stored email when it is one of the emails searched for, else null. */
    private static String emailMatchKey(String storedEmail, Set<String> lowerEmails) {
        if (String.isBlank(storedEmail) || !lowerEmails.contains(storedEmail.trim().toLowerCase())) {
            return null;
        }
        return emailKey(storedEmail);
    }

    private static void addKey(Map<Id, Set<String>> keysByAccountId, Id accountId, String key) {
        if (key == null) {
            return;
        }
        if (!keysByAccountId.containsKey(accountId)) {
            keysByAccountId.put(accountId, new Set<String>());
        }
        keysByAccountId.get(accountId).add(key);
    }

    private static void putIfAbsent(Map<String, Customer> customers, String key, Customer customer) {
        if (key != null && !customers.containsKey(key)) {
            customers.put(key, customer);
        }
    }

    private static Set<String> lowerCased(Set<String> values) {
        Set<String> lowered = new Set<String>();
        if (values == null) {
            return lowered;
        }
        for (String value : values) {
            if (String.isNotBlank(value)) {
                lowered.add(value.trim().toLowerCase());
            }
        }
        return lowered;
    }
}
