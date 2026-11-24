
@RestResource(urlMapping='/shreehari/v1/abandoned-checkouts/*')
global with sharing class ShreeHariCheckoutRestResource {

    private static final String CONTENT_TYPE = 'application/json; charset=UTF-8';
    /** The events handled here, both in exactly the same way. */
    @TestVisible
    private static final Set<String> EVENT_TYPES = new Set<String>{ 'checkout.abandoned', 'cart.abandoned' };
    @TestVisible
    private static final String LEAD_SOURCE = 'Shopify';
    @TestVisible
    private static final String DEFAULT_STATUS = 'New';
    @TestVisible
    private static final String DEFAULT_DESCRIPTION = 'Abandon Checkout Lead';
    @TestVisible
    private static final String DUPLICATE_LEAD = 'A duplicate Lead already exists';
    private static final Pattern EMAIL_PATTERN = Pattern.compile(
        '^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$'
    );

    // =====================================================================
    // 1. HTTP entry point
    // =====================================================================

    /**
     * Handles one abandoned checkout or abandoned cart. Responds 201 with what was created, 200
     * when an open Lead already exists, or an error body; nothing is thrown
     * out of this method.
     */
    @HttpPost
    global static void receiveCheckout() {
        RestResponse response = RestContext.response;
        if (response == null) {
            response = new RestResponse();
            RestContext.response = response;
        }
        response.addHeader('Content-Type', CONTENT_TYPE);

        try {
            RestRequest request = RestContext.request;
            String body = (request != null && request.requestBody != null)
                ? request.requestBody.toString()
                : null;

            Lead record = buildLead(parse(body));
            LeadTriggerHandler.Customer customer = existingCustomerOrLead(record);

            CheckoutResponse result;
            Integer status = 201;
            if (customer != null) {
                result = insertEnquiry(record, customer);
            } else if (duplicateLead != null) {
                // Answered 200, not an error: the sender retries every non-2xx
                // response, and a retry would find the same open Lead again.
                result = buildDuplicateResponse(duplicateLead);
                status = 200;
            } else {
                insertLead(record);
                result = buildLeadResponse(record.Id);
            }

            response.statusCode = status;
            response.responseBody = Blob.valueOf(JSON.serialize(result, true));

        } catch (ShreeHariLeadRestResource.ApiException e) {
            ShreeHariLeadRestResource.writeError(response, e.errorCode, e.httpStatus, e.jsonField, e.getMessage());
            IntegrationLogService.logError(
                IntegrationLogService.API_ABANDONED_CHECKOUT, 'ShreeHariCheckoutRestResource', 'receiveCheckout', e
            );

        } catch (Exception e) {
            ShreeHariLeadRestResource.writeError(response, 'DML_EXCEPTION', 500, null, e.getMessage());
            IntegrationLogService.logError(
                IntegrationLogService.API_ABANDONED_CHECKOUT, 'ShreeHariCheckoutRestResource', 'receiveCheckout', e
            );
        }
    }

    // =====================================================================
    // 2. Parsing
    // =====================================================================

    /**
     * The "data" object of a checkout.abandoned or cart.abandoned event.
     *
     * @throws ApiException INVALID_JSON when the body is empty or not a JSON
     *         object, UNSUPPORTED_EVENT for any other event type,
     *         MISSING_REQUIRED_FIELD when data.user is not sent
     */
    private static Map<String, Object> parse(String body) {
        if (String.isBlank(body)) {
            throw ShreeHariLeadRestResource.badRequest('INVALID_JSON', null, 'Request body is empty. Send the checkout.abandoned or cart.abandoned event as JSON.');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(body);
        } catch (Exception e) {
            throw ShreeHariLeadRestResource.badRequest('INVALID_JSON', null, 'Request body could not be parsed as JSON: ' + e.getMessage());
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw ShreeHariLeadRestResource.badRequest('INVALID_JSON', null, 'Request body must be a JSON object.');
        }
        Map<String, Object> payload = (Map<String, Object>) parsed;

        String eventType = text(objectAt(payload, 'event').get('type'));
        if (!EVENT_TYPES.contains(eventType)) {
            throw ShreeHariLeadRestResource.badRequest(
                'UNSUPPORTED_EVENT',
                'event.type',
                'event.type must be checkout.abandoned or cart.abandoned'
                    + (eventType == null ? '.' : '; \'' + eventType + '\' was sent.')
            );
        }

        Map<String, Object> data = objectAt(payload, 'data');
        if (objectAt(data, 'user').isEmpty()) {
            throw ShreeHariLeadRestResource.badRequest('MISSING_REQUIRED_FIELD', 'data.user', 'data.user is required: the customer who left the checkout or cart.');
        }
        return data;
    }

    /** The object under the key, or an empty one when it is missing or not an object. */
    private static Map<String, Object> objectAt(Map<String, Object> parent, String key) {
        Object value = parent.get(key);
        return (value instanceof Map<String, Object>) ? (Map<String, Object>) value : new Map<String, Object>();
    }

    /** A text or number as trimmed text; null when missing, blank, an object or a list. */
    private static String text(Object value) {
        if (value == null || value instanceof Map<String, Object> || value instanceof List<Object>) {
            return null;
        }
        String asText = String.valueOf(value).trim();
        return String.isBlank(asText) ? null : asText;
    }

    private static Boolean isTrue(Object value) {
        return value instanceof Boolean && (Boolean) value;
    }

    // =====================================================================
    // 3. Validation and mapping
    // =====================================================================

    /** Checks data.user and builds the unsaved Lead. */
    private static Lead buildLead(Map<String, Object> data) {
        Map<String, Object> user = objectAt(data, 'user');
        Map<String, Object> address = objectAt(user, 'address');
        Map<String, Object> consent = objectAt(data, 'consent');

        String phone = text(user.get('contact'));
        if (phone == null) {
            throw ShreeHariLeadRestResource.badRequest(
                'MISSING_REQUIRED_FIELD',
                'data.user.contact',
                'data.user.contact is required: a 10-digit phone number, optionally starting with +91 or 91.'
            );
        }
        if (!LeadTriggerHandler.isValidPhone(LeadTriggerHandler.normalizePhone(phone))) {
            throw ShreeHariLeadRestResource.badRequest(
                'INVALID_PHONE',
                'data.user.contact',
                '\'' + phone + '\' is not a valid phone. Send a 10-digit number, optionally starting with +91 or 91.'
            );
        }

        String email = text(user.get('email'));
        if (email != null && !EMAIL_PATTERN.matcher(email).matches()) {
            throw ShreeHariLeadRestResource.badRequest('INVALID_EMAIL_FORMAT', 'data.user.email', '\'' + email + '\' is not a valid email address.');
        }

        // Last Name is required on a Lead: the first name alone becomes it,
        // and with no name at all the phone number does.
        String firstName = text(user.get('first_name'));
        String lastName = text(user.get('last_name'));
        if (lastName == null) {
            lastName = firstName != null ? firstName : phone;
            firstName = null;
        }

        List<String> streetLines = new List<String>();
        for (String key : new List<String>{ 'line1', 'line2' }) {
            String line = text(address.get(key));
            if (line != null) {
                streetLines.add(line);
            }
        }
        String street = streetLines.isEmpty() ? null : String.join(streetLines, '\n');
        String userId = text(user.get('user_id'));

        Lead record = new Lead(
            FirstName = firstName,
            LastName = lastName,
            Phone = phone,
            Email = email,
            Street = street,
            City = text(address.get('city')),
            State = text(address.get('state')),
            Country = text(address.get('country')),
            PostalCode = text(address.get('pincode')),
            LeadSource = LEAD_SOURCE,
            Status = DEFAULT_STATUS,
            Description = productDescription(objectAt(data, 'session').get('products_viewed')),
            User_Id__c = userId,
            WA_Opt_In__c = isTrue(consent.get('whatsapp')),
            Email_Opt_In__c = isTrue(consent.get('email')),
            SMS_Opt_In__c = isTrue(consent.get('sms'))
        );

        ShreeHariLeadRestResource.checkLength(Lead.FirstName, 'data.user.first_name', record.FirstName);
        ShreeHariLeadRestResource.checkLength(Lead.LastName, 'data.user.last_name', record.LastName);
        ShreeHariLeadRestResource.checkLength(Lead.Phone, 'data.user.contact', record.Phone);
        ShreeHariLeadRestResource.checkLength(Lead.Email, 'data.user.email', record.Email);
        ShreeHariLeadRestResource.checkLength(Lead.User_Id__c, 'data.user.user_id', record.User_Id__c);
        ShreeHariLeadRestResource.checkLength(Lead.Street, 'data.user.address.line1', record.Street);
        ShreeHariLeadRestResource.checkLength(Lead.City, 'data.user.address.city', record.City);
        ShreeHariLeadRestResource.checkLength(Lead.State, 'data.user.address.state', record.State);
        ShreeHariLeadRestResource.checkLength(Lead.Country, 'data.user.address.country', record.Country);
        ShreeHariLeadRestResource.checkLength(Lead.PostalCode, 'data.user.address.pincode', record.PostalCode);
        return record;
    }

    /**
     * The titles of data.session.products_viewed, each once, in the order
     * sent, separated by ", " and cut to the length of Description.
     * DEFAULT_DESCRIPTION when there are none.
     */
    @TestVisible
    private static String productDescription(Object productsViewed) {
        List<String> titles = new List<String>();
        if (productsViewed instanceof List<Object>) {
            for (Object product : (List<Object>) productsViewed) {
                if (!(product instanceof Map<String, Object>)) {
                    continue;
                }
                String title = text(((Map<String, Object>) product).get('title'));
                if (title != null && !titles.contains(title)) {
                    titles.add(title);
                }
            }
        }
        if (titles.isEmpty()) {
            return DEFAULT_DESCRIPTION;
        }
        return String.join(titles, ', ').left(Lead.Description.getDescribe().getLength());
    }

    // =====================================================================
    // 4. Persistence
    // =====================================================================

    /**
     * The existing customer - an Account, a Contact, or both - this phone,
     * WhatsApp number or email belongs to (an enquiry is raised for them
     * instead of a Lead), or null for a new customer. An open Lead with any of them is kept in duplicateLead and no
     * Lead is created. Matching is the same as on the New Lead screen and in
     * Upload Leads (LeadTriggerHandler).
     */
    private static Lead duplicateLead;

    private static LeadTriggerHandler.Customer existingCustomerOrLead(Lead record) {
        duplicateLead = null;
        Set<String> phones = new Set<String>(LeadTriggerHandler.phonesOf(record));
        Set<String> emails = String.isBlank(record.Email) ? new Set<String>() : new Set<String>{ record.Email };
        List<String> keys = LeadTriggerHandler.matchKeysOf(record);

        Map<String, LeadTriggerHandler.Customer> customers = LeadTriggerHandler.findCustomers(phones, emails);
        // The best match among the person's details: an Account with its
        // Contact, then an Account alone (it is given a Contact), then a
        // Contact without an Account (it is given an Account).
        LeadTriggerHandler.Customer accountOnly;
        LeadTriggerHandler.Customer contactOnly;
        for (String key : keys) {
            LeadTriggerHandler.Customer match = customers.get(key);
            if (match == null) {
                continue;
            }
            if (match.accountId != null && match.contactId != null) {
                return match;
            }
            if (match.accountId != null && accountOnly == null) {
                accountOnly = match;
            }
            if (match.accountId == null && contactOnly == null) {
                contactOnly = match;
            }
        }
        if (accountOnly != null) {
            return accountOnly;
        }
        if (contactOnly != null) {
            return contactOnly;
        }

        Map<String, Lead> openLeads = LeadTriggerHandler.findOpenLeads(phones, emails);
        for (String key : keys) {
            if (openLeads.containsKey(key)) {
                duplicateLead = openLeads.get(key);
                return null;
            }
        }
        return null;
    }

    /** Inserts the Lead, letting the active assignment rule route it. */
    private static void insertLead(Lead record) {
        Database.DMLOptions options = new Database.DMLOptions();
        options.optAllOrNone = true;
        if (ShreeHariLeadRestResource.hasActiveLeadAssignmentRule()) {
            options.assignmentRuleHeader.useDefaultRule = true;
        }
        try {
            Database.insert(record, options, AccessLevel.SYSTEM_MODE);
        } catch (DmlException e) {
            throw ShreeHariLeadRestResource.translate(e);
        }
    }

    /**
     * Raises the enquiry Case for an existing customer, on its Account and
     * Contact. A customer that is only a Contact is given an Account first
     * (LeadTriggerHandler.createCustomerAccounts, as on the New Lead screen
     * and in Upload Leads); a customer that is only an Account is given a
     * Contact first. All or nothing: a failure leaves no new Account or
     * Contact behind.
     */
    private static CheckoutResponse insertEnquiry(Lead record, LeadTriggerHandler.Customer customer) {
        Boolean accountCreated = customer.accountId == null;
        Boolean contactCreated = customer.contactId == null;
        Savepoint beforeEnquiry = Database.setSavepoint();
        try {
            if (accountCreated) {
                // Named and filled as on the New Lead screen and in Upload
                // Leads; the Contact is moved under it.
                Map<Integer, String> failures = LeadTriggerHandler.createCustomerAccounts(
                    new List<Lead>{ record },
                    new List<LeadTriggerHandler.Customer>{ customer }
                );
                if (!failures.isEmpty()) {
                    throw ShreeHariLeadRestResource.error('DML_EXCEPTION', 500, null, failures.get(0));
                }
            }
            if (contactCreated) {
                customer.contactId = insertContact(record, customer);
            }

            Case enquiry = LeadUploadService.enquiryFor(record, customer);
            Database.insert(enquiry, true, AccessLevel.SYSTEM_MODE);

            Case saved = [SELECT Id, CaseNumber, AccountId, ContactId FROM Case WHERE Id = :enquiry.Id WITH SYSTEM_MODE];
            CheckoutResponse result = new CheckoutResponse();
            result.success = true;
            result.action = 'ENQUIRY_CREATED';
            result.caseId = saved.Id;
            result.caseNumber = saved.CaseNumber;
            result.accountId = saved.AccountId;
            result.contactId = saved.ContactId;
            result.accountCreated = accountCreated;
            result.contactCreated = contactCreated;
            result.message = 'Customer already exists; an enquiry Case was created.';
            return result;

        } catch (DmlException e) {
            Database.rollback(beforeEnquiry);
            throw ShreeHariLeadRestResource.translate(e);
        } catch (Exception e) {
            Database.rollback(beforeEnquiry);
            throw e;
        }
    }

    /**
     * The Contact for a customer known only as an Account, from the user's
     * details, owned like the enquiry: by the account owner, or the caller
     * when that owner is inactive.
     */
    private static Id insertContact(Lead record, LeadTriggerHandler.Customer customer) {
        Contact person = new Contact(
            AccountId = customer.accountId,
            FirstName = record.FirstName,
            LastName = record.LastName,
            Phone = record.Phone,
            Email = record.Email,
            MailingStreet = record.Street,
            MailingCity = record.City,
            MailingState = record.State,
            MailingCountry = record.Country,
            MailingPostalCode = record.PostalCode,
            LeadSource = record.LeadSource
        );
        if (customer.ownerId != null) {
            person.OwnerId = customer.ownerId;
        }

        Database.DMLOptions options = new Database.DMLOptions();
        options.optAllOrNone = true;
        // The customer is already known: the platform's duplicate alerts must not stop it.
        options.DuplicateRuleHeader.allowSave = true;
        Database.insert(person, options, AccessLevel.SYSTEM_MODE);
        return person.Id;
    }

    // =====================================================================
    // 5. Response rendering
    // =====================================================================

    /** An open Lead already has this phone, WhatsApp number or email: nothing is saved or changed. */
    private static CheckoutResponse buildDuplicateResponse(Lead openLead) {
        CheckoutResponse result = new CheckoutResponse();
        result.success = true;
        result.action = 'DUPLICATE_LEAD';
        result.leadId = openLead.Id;
        result.message = DUPLICATE_LEAD + ': ' + openLead.Name + ' (' + openLead.Id + ').';
        return result;
    }

    /** Reads the Lead back, so the response reports the Company and owner it ended up with. */
    private static CheckoutResponse buildLeadResponse(Id leadId) {
        Lead saved = [SELECT Id, Status, Company, OwnerId FROM Lead WHERE Id = :leadId WITH SYSTEM_MODE LIMIT 1];

        CheckoutResponse result = new CheckoutResponse();
        result.success = true;
        result.action = 'CREATED';
        result.leadId = saved.Id;
        result.status = saved.Status;
        result.company = saved.Company;
        result.ownerId = saved.OwnerId;
        result.message = 'Lead created successfully.';
        return result;
    }

    // =====================================================================
    // 6. Inner types
    // =====================================================================

    /**
     * Success payload. A new Lead (201, action CREATED) fills leadId, status,
     * company and ownerId; an existing customer's enquiry (201, action
     * ENQUIRY_CREATED) fills caseId, caseNumber, accountId, contactId,
     * accountCreated and contactCreated; an open Lead (200, action
     * DUPLICATE_LEAD) fills leadId. Blank fields are left out.
     */
    public class CheckoutResponse {
        public Boolean success;
        public String action;
        public String leadId;
        public String caseId;
        public String caseNumber;
        public String accountId;
        public String contactId;
        public Boolean accountCreated;
        public Boolean contactCreated;
        public String status;
        public String company;
        public String ownerId;
        public String message;
    }
}
