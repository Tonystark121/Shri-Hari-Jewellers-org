
public without sharing class LeadTriggerHandler {

    @TestVisible
    private static final String BUSINESS_TYPE_B2C = 'B2C';

    private static final String BUSINESS_TYPE_B2B = 'B2B';

    /** The Business Type picklist's default: nobody has said which it is. */
    private static final String BUSINESS_TYPE_UNKNOWN = 'Unknown';

    private static final String B2C_SUFFIX = ' - B2C';
    private static final String B2B_SUFFIX = ' - B2B';

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
            Boolean isB2b = leadRecord.B2B_Lead__c == true;
            if (isAutoCompany(leadRecord.Company, isB2b)) {
                leadRecord.Business_Type__c = isB2b ? BUSINESS_TYPE_B2B : BUSINESS_TYPE_B2C;
                // Placeholder until the Lead Number exists (after insert).
                leadRecord.Company = isB2b ? b2bStem(leadRecord) : companyStem(leadRecord);
            } else if (isB2b) {
                // B2B checkbox with a typed Company: keep the Company, force the type.
                leadRecord.Business_Type__c = BUSINESS_TYPE_B2B;
            }
        }

        blockExistingCustomers(leads);
        applyInsertRules(leads);
    }

    /** Adds the Lead Number to the Company of every new B2C Lead. */
    public static void afterInsert(List<Lead> leads) {
        List<Lead> toStamp = new List<Lead>();
        for (Lead leadRecord : leads) {
            if (leadRecord.Business_Type__c == BUSINESS_TYPE_B2C && leadRecord.Company == companyStem(leadRecord)) {
                toStamp.add(new Lead(Id = leadRecord.Id, Company = b2cCompany(leadRecord)));
            } else if (leadRecord.Business_Type__c == BUSINESS_TYPE_B2B && leadRecord.Company == b2bStem(leadRecord)) {
                toStamp.add(new Lead(Id = leadRecord.Id, Company = b2bCompany(leadRecord)));
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

            if (phoneChanged(leadRecord, oldLead) || whatsAppChanged(leadRecord, oldLead) || emailChanged(leadRecord, oldLead)) {
                contactDetailsChanged.add(leadRecord);
            }
    
            if (stampingCompany) {
                continue;
            }
    
            // B2B Lead checkbox switched on/off after the Lead was created.
            Boolean b2bOn = leadRecord.B2B_Lead__c == true && oldLead.B2B_Lead__c != true;
            Boolean b2bOff = leadRecord.B2B_Lead__c != true && oldLead.B2B_Lead__c == true;
            if (b2bOn || b2bOff) {
                Boolean systemNamed = hasSystemCompany(oldLead);
                if (b2bOn) {
                    leadRecord.Business_Type__c = BUSINESS_TYPE_B2B;
                    if (systemNamed) {
                        leadRecord.Company = b2bCompany(leadRecord);
                    }
                } else if (systemNamed) {
                    leadRecord.Business_Type__c = BUSINESS_TYPE_B2C;
                    leadRecord.Company = b2cCompany(leadRecord);
                }
                continue;
            }
    
            // Only system-named Companies are locked and follow the name.
            if (!hasSystemCompany(oldLead)) {
                continue;
            }
    
            if (leadRecord.Company != oldLead.Company) {
                leadRecord.Company.addError(COMPANY_LOCKED);
                continue;
            }
    
            Boolean nameChanged = leadRecord.FirstName != oldLead.FirstName || leadRecord.LastName != oldLead.LastName;
            if (nameChanged && oldLead.Company == b2cCompany(oldLead)) {
                leadRecord.Company = b2cCompany(leadRecord);
            } else if (nameChanged && oldLead.Company == b2bCompany(oldLead)) {
                leadRecord.Company = b2bCompany(leadRecord);
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
            phones.addAll(phonesOf(leadRecord));
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
            for (String key : matchKeysOf(leadRecord)) {
                if (customer == null && customers.containsKey(key)) {
                    customer = customers.get(key);
                }
            }
            if (customer != null) {
                leadRecord.addError(
                    'An existing customer has this phone, WhatsApp number or email: ' + customer.accountName
                    + '. Raise an enquiry (Case) for that customer instead of creating a Lead.'
                );
            }
        }
    }

    /**
     * The Lead's Phone and WhatsApp Number (MobilePhone) as 10 digits, the
     * valid ones only. Both are the person's numbers, so each is matched
     * against every stored number.
     */
    public static List<String> phonesOf(Lead leadRecord) {
        List<String> phones = new List<String>();
        for (String phone : new List<String>{ normalizePhone(leadRecord.Phone), normalizePhone(leadRecord.MobilePhone) }) {
            if (isValidPhone(phone) && !phones.contains(phone)) {
                phones.add(phone);
            }
        }
        return phones;
    }

    /** phoneKey() of the Lead's Phone and WhatsApp Number, then emailKey() of its Email. */
    public static List<String> matchKeysOf(Lead leadRecord) {
        List<String> keys = new List<String>();
        for (String phone : phonesOf(leadRecord)) {
            keys.add(phoneKey(phone));
        }
        if (String.isNotBlank(leadRecord.Email)) {
            keys.add(emailKey(leadRecord.Email));
        }
        return keys;
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
            if (whatsAppChanged(leadRecord, oldLead)) {
                phones.add(normalizePhone(leadRecord.MobilePhone));
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
            if (whatsAppChanged(leadRecord, oldLead)) {
                String reason = takenReason(
                    leadRecord, phoneKey(normalizePhone(leadRecord.MobilePhone)), 'WhatsApp number', customers, openLeads, takenInThisSave
                );
                if (reason != null) {
                    leadRecord.MobilePhone.addError(reason);
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
        return numberChanged(leadRecord.Phone, oldLead.Phone);
    }

    /** The WhatsApp Number (MobilePhone) now is a valid number that differs, as 10 digits, from before. */
    private static Boolean whatsAppChanged(Lead leadRecord, Lead oldLead) {
        return numberChanged(leadRecord.MobilePhone, oldLead.MobilePhone);
    }

    private static Boolean numberChanged(String now, String before) {
        String phone = normalizePhone(now);
        return isValidPhone(phone) && phone != normalizePhone(before);
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
    // Insert rules (Workbench, Data Loader, CLI and any other direct insert)
    // =====================================================================

    /**
     * Existing tests insert Leads without a Phone or Product Description to
     * exercise other rules, so the insert rules are off in tests unless a
     * test switches them on.
     */
    @TestVisible
    private static Boolean applyInsertRulesInTests = false;

    @TestVisible
    private static final String PHONE_REQUIRED = 'Phone is required.';
    @TestVisible
    private static final String PRODUCT_REQUIRED = 'Product Description is required.';
    @TestVisible
    private static final String BIRTH_DATE_IN_FUTURE = 'Date of Birth cannot be in the future.';
    @TestVisible
    private static final String CONVERTED_STATUS_REFUSED =
        'A Lead cannot be created as Converted. It converts only with its first bill, through the Convert button. '
        + 'Leave Status blank for New, or use another status.';
    @TestVisible
    private static final String SAME_AS_ANOTHER_IN_SAVE =
        'Same phone, WhatsApp number or email as another Lead in this save.';

    /**
     * The checks Upload Leads makes on each row (LeadUploadService), applied
     * to every new Lead so that a direct insert is held to them too. The New
     * Lead screen, Upload Leads and the website API make the same checks
     * before they save, so nothing changes for them.
     *
     * A Lead already refused (existing customer) is left alone. The phone
     * format, the Anniversary Date and the email format are checked by the
     * validation rules and the platform, after this.
     */
    private static void applyInsertRules(List<Lead> leads) {
        if (Test.isRunningTest() && !applyInsertRulesInTests) {
            return;
        }

        List<Lead> passed = new List<Lead>();
        for (Lead leadRecord : leads) {
            if (leadRecord.hasErrors()) {
                continue;
            }
            String reason = insertRuleFailure(leadRecord);
            if (reason != null) {
                leadRecord.addError(reason);
                continue;
            }
            // A typed Company is B2B, as on the New Lead screen and in Upload Leads.
            // (A blank Company was made B2C in beforeInsert.)
            if (String.isBlank(leadRecord.Business_Type__c) || leadRecord.Business_Type__c == BUSINESS_TYPE_UNKNOWN) {
                leadRecord.Business_Type__c = BUSINESS_TYPE_B2B;
            }
            passed.add(leadRecord);
        }

        blockOpenLeadDuplicates(passed);
    }

    /**
     * Why the Lead cannot be created, or null when it can. Picklist values
     * written in another case are corrected to the stored value.
     */
    private static String insertRuleFailure(Lead leadRecord) {
        if (String.isBlank(leadRecord.Phone)) {
            return PHONE_REQUIRED;
        }
        if (String.isBlank(leadRecord.Description)) {
            return PRODUCT_REQUIRED;
        }
        if (leadRecord.Date_of_Birth__c != null && leadRecord.Date_of_Birth__c > Date.today()) {
            return BIRTH_DATE_IN_FUTURE;
        }

        if (String.isNotBlank(leadRecord.Status)) {
            String status = activeValue(Lead.Status, leadRecord.Status);
            if (status == null) {
                List<String> allowed = new List<String>();
                for (String value : activeValues(Lead.Status)) {
                    if (!convertedStatuses.contains(value)) {
                        allowed.add(value);
                    }
                }
                return notValid(leadRecord.Status, 'Status', allowed);
            }
            // The website API (Apex REST) keeps the status it is sent; left as it is.
            if (convertedStatuses.contains(status) && RestContext.request == null) {
                return CONVERTED_STATUS_REFUSED;
            }
            leadRecord.Status = status;
        }

        Map<Schema.SObjectField, String> picklists = new Map<Schema.SObjectField, String>{
            Lead.Salutation => 'Salutation',
            Lead.Marital_Status__c => 'Marital Status',
            Lead.LeadSource => 'Lead Source',
            Lead.Industry => 'Industry'
        };
        for (Schema.SObjectField field : picklists.keySet()) {
            String entered = (String) leadRecord.get(field);
            if (String.isBlank(entered)) {
                continue;
            }
            String value = activeValue(field, entered);
            if (value == null) {
                return notValid(entered, picklists.get(field), activeValues(field));
            }
            leadRecord.put(field, value);
        }
        return null;
    }

    /**
     * Refuses a Lead whose phone, WhatsApp number or email belongs to an open
     * Lead - compared as 10 digits, each number against every stored number,
     * as on the New Lead screen and in Upload Leads - or to an earlier Lead of
     * the same save. (The Lead Duplicate Check duplicate rule only finds a
     * phone stored in exactly the same format.)
     */
    private static void blockOpenLeadDuplicates(List<Lead> leads) {
        Set<String> phones = new Set<String>();
        Set<String> emails = new Set<String>();
        for (Lead leadRecord : leads) {
            phones.addAll(phonesOf(leadRecord));
            if (String.isNotBlank(leadRecord.Email)) {
                emails.add(leadRecord.Email);
            }
        }
        if (phones.isEmpty() && emails.isEmpty()) {
            return;
        }

        Map<String, Lead> openLeads = findOpenLeads(phones, emails);
        Set<String> takenInThisSave = new Set<String>();

        for (Lead leadRecord : leads) {
            List<String> keys = matchKeysOf(leadRecord);

            Lead openLead;
            Boolean repeated = false;
            for (String key : keys) {
                if (openLead == null && openLeads.containsKey(key)) {
                    openLead = openLeads.get(key);
                }
                if (takenInThisSave.contains(key)) {
                    repeated = true;
                }
            }

            if (openLead != null) {
                leadRecord.addError('A Lead with this phone, WhatsApp number or email already exists: ' + openLead.Name
                    + ' (owner ' + openLead.Owner.Name + ').');
            } else if (repeated) {
                leadRecord.addError(SAME_AS_ANOTHER_IN_SAVE);
            } else {
                takenInThisSave.addAll(keys);
            }
        }
    }

    /** Lead Status values that mean converted, read once per transaction. */
    private static Set<String> convertedStatuses {
        get {
            if (convertedStatuses == null) {
                convertedStatuses = new Set<String>();
                for (LeadStatus leadStatus : [SELECT ApiName FROM LeadStatus WHERE IsConverted = true WITH SYSTEM_MODE]) {
                    convertedStatuses.add(leadStatus.ApiName);
                }
            }
            return convertedStatuses;
        }
        set;
    }

    private static Map<Schema.SObjectField, List<String>> activeValuesByField = new Map<Schema.SObjectField, List<String>>();

    /** The field's active picklist values, read once per transaction. */
    private static List<String> activeValues(Schema.SObjectField field) {
        if (!activeValuesByField.containsKey(field)) {
            List<String> values = new List<String>();
            for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
                if (entry.isActive()) {
                    values.add(entry.getValue());
                }
            }
            activeValuesByField.put(field, values);
        }
        return activeValuesByField.get(field);
    }

    /** The active picklist value matching the text (ignoring case), or null. */
    private static String activeValue(Schema.SObjectField field, String text) {
        for (String value : activeValues(field)) {
            if (value.equalsIgnoreCase(text.trim())) {
                return value;
            }
        }
        return null;
    }

    private static String notValid(String entered, String label, List<String> allowed) {
        return '"' + entered + '" is not a valid ' + label + '. Allowed values: ' + String.join(allowed, ', ') + '.';
    }

    // =====================================================================
    // Company
    // =====================================================================

    /** Blank, or the New Lead screen's default "<Name> - B2C". */
    @TestVisible
    private static Boolean isAutoCompany(String company, Boolean isB2b) {
        return String.isBlank(company)
            || company.trim().endsWithIgnoreCase(B2C_SUFFIX)
            || (isB2b && company.trim().endsWithIgnoreCase(B2B_SUFFIX));
    }

    /**
     * True when Company was filled in by the system rather than typed by a
     * user: blank, "<Name> - B2C", "<Name> B2C (<Lead Number>)" or the
     * earlier "<Name> Family (<Lead Number>)" and "<Name> - B2C-<Lead Number>".
     */
    public static Boolean isSystemCompany(String company) {
        return String.isBlank(company)
            || Pattern.matches('(?i).* - B2[CB](-[0-9]+)?|.* (B2C|B2B|Family) [(][0-9]+[)]', company.trim());
    }
    
    /** True when the Lead's Company is maintained by the system (B2C always, B2B only when system-named). */
    private static Boolean hasSystemCompany(Lead leadRecord) {
        return leadRecord.Business_Type__c == BUSINESS_TYPE_B2C
            || (leadRecord.Business_Type__c == BUSINESS_TYPE_B2B && isSystemCompany(leadRecord.Company));
    }
    
    /** "<First Name> <Last Name> - B2B": the placeholder until the Lead Number exists. */
    @TestVisible
    private static String b2bStem(Lead leadRecord) {
        return personName(leadRecord) + B2B_SUFFIX;
    }
    
    /** "<First Name> <Last Name> B2B (<Lead Number>)", e.g. Asha Mehta B2B (000123). */
    public static String b2bCompany(Lead leadRecord) {
        return personName(leadRecord) + ' B2B (' + leadRecord.Lead_Number__c + ')';
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
            SELECT Id, Name, Phone, WhatsApp_Number__c, Email__c, OwnerId, Owner.IsActive
            FROM Account
            WHERE Phone IN :phoneForms
               OR WhatsApp_Number__c IN :phoneForms
               OR Email__c IN :lowerEmails
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
        ]) {
            Customer customer = new Customer();
            customer.accountId = accountRecord.Id;
            customer.accountName = accountRecord.Name;
            customer.ownerId = accountRecord.Owner.IsActive ? accountRecord.OwnerId : null;

            putIfAbsent(customers, phoneMatchKey(accountRecord.Phone, normalizedPhones), customer);
            putIfAbsent(customers, phoneMatchKey(accountRecord.WhatsApp_Number__c, normalizedPhones), customer);
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
            SELECT Id, Phone, WhatsApp_Number__c, Email__c
            FROM Account
            WHERE Phone IN :phoneForms OR WhatsApp_Number__c IN :phoneForms OR Email__c IN :lowerEmails
            WITH SYSTEM_MODE
        ]) {
            addKey(keysByAccountId, accountRecord.Id, phoneMatchKey(accountRecord.Phone, normalizedPhones));
            addKey(keysByAccountId, accountRecord.Id, phoneMatchKey(accountRecord.WhatsApp_Number__c, normalizedPhones));
            addKey(keysByAccountId, accountRecord.Id, emailMatchKey(accountRecord.Email__c, lowerEmails));
        }

        if (keysByAccountId.isEmpty()) {
            return accountsByKey;
        }

        Set<Id> accountIds = keysByAccountId.keySet();
        for (Account accountRecord : [
            SELECT Id, Name, Phone, WhatsApp_Number__c, Email__c, Customer_Tier__c, Last_12M_Spend__c, CASA_ID__c
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
        Boolean isBusiness = details.B2B_Lead__c == true || !isSystemCompany(details.Company);

        Lead named = String.isBlank(details.LastName)
            ? new Lead(FirstName = person.FirstName, LastName = person.LastName)
            : details;

        Account accountRecord = new Account(
            Name = !isBusiness ? LeadConversionTransactionService.familyAccountName(named.FirstName, named.LastName)
            		: (isSystemCompany(details.Company) ? personName(named) + ' B2B' : details.Company.trim()),
            Business_Type__c = isBusiness ? BUSINESS_TYPE_B2B : BUSINESS_TYPE_B2C,
            OwnerId = UserInfo.getUserId(),
            Phone = firstNotBlank(details.Phone, firstNotBlank(person.Phone, person.MobilePhone)),
            WhatsApp_Number__c = firstNotBlank(details.MobilePhone, person.MobilePhone),
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
            SELECT Id, Name, Phone, MobilePhone, Email, Owner.Name
            FROM Lead
            WHERE IsConverted = false
              AND (Phone IN :phoneForms OR MobilePhone IN :phoneForms OR Email IN :lowerEmails)
              AND status != 'Unqualified' AND Status != 'Converted'
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
        ]) {
            for (String storedPhone : new List<String>{ leadRecord.Phone, leadRecord.MobilePhone }) {
                String phoneKey = phoneMatchKey(storedPhone, normalizedPhones);
                if (phoneKey != null && !leads.containsKey(phoneKey)) {
                    leads.put(phoneKey, leadRecord);
                }
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

        @InvocableVariable(label='WhatsApp Number' description='WhatsApp Number as entered. Matched like Phone, against every stored phone and WhatsApp number.')
        public String whatsApp;

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
        description='Cleans the phone to 10 digits and finds an existing customer (Account or Contact) or an open Lead with the same phone, WhatsApp number or email.'
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
            String whatsApp = normalizePhone(request.whatsApp);
            if (isValidPhone(whatsApp)) {
                phones.add(whatsApp);
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
            String whatsApp = normalizePhone(request.whatsApp);
            if (isValidPhone(whatsApp)) {
                keys.add(phoneKey(whatsApp));
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