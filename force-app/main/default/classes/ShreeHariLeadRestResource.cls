/**
 * Inbound REST endpoint for website and digital-channel lead capture.
 *
 *   POST /services/apexrest/shreehari/v1/leads
 *
 * Contract: "Website -> Salesforce Lead REST API", Draft v1.1, September 2026.
 * Authentication is handled by the platform through the Shree Hari Website API
 * External Client App (OAuth 2.0 client credentials), so an expired or missing
 * token never reaches this class. Any verb other than POST is rejected by the
 * platform with 405, because no other @Http method is declared here.
 *
 * Everything the endpoint needs lives in this one class:
 *
 *   1. HTTP entry point       createLead()
 *   2. Parsing                parse()
 *   3. Validation             validate() and its helpers
 *   4. Mapping                buildLead(), resolveStore/Campaign()
 *   5. Persistence            insertWithAssignment(), translate()
 *   6. Response rendering     buildResponse(), writeError()
 *   7. Inner types            LeadRequest, LeadResponse, ApiException
 *
 * Picklist values and field lengths are read from the Lead describe rather than
 * hard-coded, so adding a Lead Source in Setup needs no code change and the
 * error messages always quote the values the org actually accepts.
 *
 * Runs `with sharing`: the integration user sees only what its profile and
 * sharing rules allow, which is the correct posture for an internet-facing
 * endpoint.
 */
@RestResource(urlMapping='/shreehari/v1/leads/*')
global with sharing class ShreeHariLeadRestResource {

    private static final String CONTENT_TYPE = 'application/json; charset=UTF-8';
    @TestVisible
    private static final String DEFAULT_STATUS = 'New';
    /** Company is required on Lead; every enquiry without one is filed under this. */
    @TestVisible
    private static final String DEFAULT_COMPANY = 'Halsa Global';
    @TestVisible
    private static final String DEFAULT_BUSINESS_TYPE = 'Unknown';
    private static final Pattern EMAIL_PATTERN = Pattern.compile(
        '^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$'
    );
    private static final Pattern DATE_PATTERN = Pattern.compile('^\\d{4}-\\d{2}-\\d{2}$');
    @TestVisible
    private static final String MARITAL_STATUS_UNMARRIED = 'Unmarried';

    // =====================================================================
    // 1. HTTP entry point
    // =====================================================================

    /**
     * Creates one Lead from a website enquiry.
     *
     * Responds 201 with the new record Id, or one of the documented 4xx/5xx
     * error bodies. Nothing is thrown out of this method: a caller always
     * receives JSON it can branch on.
     */
    @HttpPost
    global static void createLead() {
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

            LeadRequest payload = parse(body);
            validate(payload);

            Lead record = buildLead(payload);
            insertWithAssignment(record);

            response.statusCode = 201;
            response.responseBody = Blob.valueOf(
                JSON.serialize(buildResponse(record.Id), true)
            );

        } catch (ApiException e) {
            writeError(response, e.errorCode, e.httpStatus, e.jsonField, e.getMessage());

        } catch (Exception e) {
            // Nothing below this point is expected. It is reported with the same
            // 500 code the specification gives platform failures, so the caller
            // still receives a parseable body and can retry.
            writeError(response, 'DML_EXCEPTION', 500, null, e.getMessage());
        }
    }

    // =====================================================================
    // 2. Parsing
    // =====================================================================

    /**
     * Parses and normalises a request body.
     *
     * JSON.deserialize is used rather than deserializeStrict so that unknown
     * keys are ignored, which is what the specification promises callers.
     *
     * @param body  raw JSON request body
     * @return      the payload with every text value trimmed
     * @throws ApiException INVALID_JSON when the body is empty, is not a JSON
     *         object, or carries a value of the wrong type
     */
    private static LeadRequest parse(String body) {
        if (String.isBlank(body)) {
            throw badRequest(
                'INVALID_JSON',
                null,
                'Request body is empty. Send a JSON object with at least lastName and leadSource.'
            );
        }
        LeadRequest payload;
        try {
            payload = (LeadRequest) JSON.deserialize(body, LeadRequest.class);
        } catch (Exception e) {
            throw badRequest(
                'INVALID_JSON',
                null,
                'Request body could not be parsed as JSON: ' + e.getMessage()
            );
        }
        if (payload == null) {
            throw badRequest('INVALID_JSON', null, 'Request body must be a JSON object.');
        }
        payload.normalise();
        return payload;
    }

    // =====================================================================
    // 3. Validation
    // =====================================================================

    private static void validate(LeadRequest p) {
        // Required fields -------------------------------------------------
        if (String.isBlank(p.lastName)) {
            throw badRequest(
                'MISSING_REQUIRED_FIELD',
                'lastName',
                'lastName is required. Send the customer name, or the full name when the form captures only one.'
            );
        }
        if (String.isBlank(p.leadSource)) {
            throw badRequest(
                'MISSING_REQUIRED_FIELD',
                'leadSource',
                'leadSource is required. ' + allowedValuesSentence(Lead.LeadSource)
            );
        }

        // At least one way to reach the customer ---------------------------
        if (String.isBlank(p.phone) && String.isBlank(p.email)) {
            throw badRequest(
                'CONTACT_INFO_REQUIRED',
                'phone',
                'Send at least one of phone or email so the tele-calling team can reach the customer.'
            );
        }

        // Picklists --------------------------------------------------------
        validatePicklist(Lead.LeadSource, 'leadSource', p.leadSource);
        validatePicklist(Lead.Status, 'status', p.status);
        validatePicklist(Lead.Rating, 'rating', p.rating);
        validatePicklist(Lead.Industry, 'industry', p.industry);
        validatePicklist(Lead.Salutation, 'salutation', p.salutation);
        validatePicklist(Lead.Marital_Status__c, 'maritalStatus', p.maritalStatus);
        validatePicklist(Lead.Business_Type__c, 'businessType', p.businessType);

        // Email format -----------------------------------------------------
        if (String.isNotBlank(p.email) && !EMAIL_PATTERN.matcher(p.email).matches()) {
            throw badRequest(
                'INVALID_EMAIL_FORMAT',
                'email',
                '\'' + p.email + '\' is not a valid email address.'
            );
        }

        // Address ----------------------------------------------------------
        if (String.isNotBlank(p.state) && String.isBlank(p.country)) {
            throw badRequest(
                'INVALID_ADDRESS',
                'country',
                'country is required whenever state is sent. Use "India" for Indian addresses.'
            );
        }

        // Personal dates ---------------------------------------------------
        Date dateOfBirth = parseDate('dateOfBirth', p.dateOfBirth);
        Date anniversaryDate = parseDate('anniversaryDate', p.anniversaryDate);

        if (anniversaryDate != null && MARITAL_STATUS_UNMARRIED.equals(p.maritalStatus)) {
            throw badRequest(
                'ANNIVERSARY_NOT_ALLOWED',
                'anniversaryDate',
                'anniversaryDate can only be sent when maritalStatus is Married or omitted.'
            );
        }
        if (anniversaryDate != null && dateOfBirth != null && anniversaryDate <= dateOfBirth) {
            throw badRequest(
                'INVALID_DATE',
                'anniversaryDate',
                'anniversaryDate must be after dateOfBirth.'
            );
        }

        // Lengths ----------------------------------------------------------
        checkLength(Lead.LastName, 'lastName', p.lastName);
        checkLength(Lead.FirstName, 'firstName', p.firstName);
        checkLength(Lead.Company, 'company', p.company);
        checkLength(Lead.Phone, 'phone', p.phone);
        checkLength(Lead.Email, 'email', p.email);
        checkLength(Lead.Website, 'website', p.website);
        checkLength(Lead.Street, 'street', p.street);
        checkLength(Lead.City, 'city', p.city);
        checkLength(Lead.State, 'state', p.state);
        checkLength(Lead.PostalCode, 'postalCode', p.postalCode);
        checkLength(Lead.Country, 'country', p.country);
        checkLength(Lead.Description, 'description', p.description);
        checkLength(Lead.Qualification_Notes__c, 'qualificationNotes', p.qualificationNotes);
        checkLength(Campaign.Name, 'campaignName', p.campaignName);
    }

    /**
     * Rejects any value outside the active picklist entries of the given field.
     * Null and blank pass, because every picklist in this payload is optional
     * once its own required check has run.
     */
    @TestVisible
    private static void validatePicklist(
        Schema.SObjectField field,
        String jsonName,
        String value
    ) {
        if (String.isBlank(value)) {
            return;
        }
        if (!activeValues(field).contains(value)) {
            throw badRequest(
                'INVALID_PICKLIST_VALUE',
                jsonName,
                '\'' + value + '\' is not a valid ' + jsonName + '. ' + allowedValuesSentence(field)
            );
        }
    }

    private static void checkLength(
        Schema.SObjectField field,
        String jsonName,
        String value
    ) {
        if (String.isBlank(value)) {
            return;
        }
        Integer maxLength = field.getDescribe().getLength();
        if (maxLength > 0 && value.length() > maxLength) {
            throw badRequest(
                'VALUE_TOO_LONG',
                jsonName,
                jsonName + ' is ' + value.length() + ' characters. The maximum is ' + maxLength + '.'
            );
        }
    }

    /**
     * Parses a YYYY-MM-DD date. Null and blank pass. The value must be a real
     * calendar date (Date.valueOf would silently roll 2026-02-30 into March)
     * and must not be in the future.
     */
    @TestVisible
    private static Date parseDate(String jsonName, String value) {
        if (String.isBlank(value)) {
            return null;
        }
        Date parsed;
        if (DATE_PATTERN.matcher(value).matches()) {
            try {
                parsed = Date.valueOf(value);
            } catch (Exception e) {
                parsed = null;
            }
        }
        if (parsed == null || String.valueOf(parsed) != value) {
            throw badRequest(
                'INVALID_DATE',
                jsonName,
                '\'' + value + '\' is not a valid ' + jsonName + '. Send a real date as YYYY-MM-DD, e.g. 1990-08-25.'
            );
        }
        if (parsed > Date.today()) {
            throw badRequest(
                'INVALID_DATE',
                jsonName,
                jsonName + ' cannot be in the future.'
            );
        }
        return parsed;
    }

    private static Set<String> activeValues(Schema.SObjectField field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    private static String allowedValuesSentence(Schema.SObjectField field) {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return 'Allowed values: ' + String.join(values, ', ') + '.';
    }

    // =====================================================================
    // 4. Mapping
    // =====================================================================

    private static Lead buildLead(LeadRequest p) {
        Lead record = new Lead();

        record.Salutation = p.salutation;
        record.FirstName = p.firstName;
        record.LastName = p.lastName;
        record.Company = String.isBlank(p.company) ? DEFAULT_COMPANY : p.company;

        record.Date_of_Birth__c = parseDate('dateOfBirth', p.dateOfBirth);
        record.Marital_Status__c = p.maritalStatus;
        record.Anniversary_Date__c = parseDate('anniversaryDate', p.anniversaryDate);

        record.Phone = p.phone;
        record.Email = p.email;
        record.Website = p.website;

        record.Street = p.street;
        record.City = p.city;
        record.State = p.state;
        record.PostalCode = p.postalCode;
        record.Country = p.country;

        record.LeadSource = p.leadSource;
        record.Status = String.isBlank(p.status) ? DEFAULT_STATUS : p.status;
        record.Business_Type__c = String.isBlank(p.businessType) ? DEFAULT_BUSINESS_TYPE : p.businessType;
        record.Rating = p.rating;
        record.Industry = p.industry;
        record.Walk_In_Flag__c = (p.walkInFlag == true);
        record.Store_Association__c = resolveStore(p.storeCode);
        record.Campaign_Attribution__c = resolveCampaign(p.campaignName);

        record.Description = p.description;
        record.Qualification_Notes__c = p.qualificationNotes;
        record.AnnualRevenue = p.annualRevenue;
        record.NumberOfEmployees = p.numberOfEmployees;

        return record;
    }

    /** Resolves a store code to its Store Location, or rejects it. */
    private static Id resolveStore(String storeCode) {
        if (String.isBlank(storeCode)) {
            return null;
        }
        List<Store_Location__c> stores = [
            SELECT Id
            FROM Store_Location__c
            WHERE Store_Code__c = :storeCode
            LIMIT 1
        ];
        if (stores.isEmpty()) {
            throw badRequest(
                'STORE_NOT_FOUND',
                'storeCode',
                'No Store Location has the store code \'' + storeCode + '\'.'
            );
        }
        return stores[0].Id;
    }

    /**
     * Resolves a campaign name to its Campaign, or rejects it. The match is
     * case-insensitive. Should two campaigns share a name, the active one is
     * preferred, then the most recently created.
     */
    private static Id resolveCampaign(String campaignName) {
        if (String.isBlank(campaignName)) {
            return null;
        }
        List<Campaign> campaigns = [
            SELECT Id
            FROM Campaign
            WHERE Name = :campaignName
            ORDER BY IsActive DESC, CreatedDate DESC
            LIMIT 1
        ];
        if (campaigns.isEmpty()) {
            throw badRequest(
                'CAMPAIGN_NOT_FOUND',
                'campaignName',
                'No Campaign is named \'' + campaignName + '\'.'
            );
        }
        return campaigns[0].Id;
    }

    // =====================================================================
    // 5. Persistence
    // =====================================================================

    /**
     * Inserts the Lead, letting the active assignment rule route it. The rule is
     * looked up first because switching the header on when no active rule exists
     * is pointless work, and it keeps behaviour predictable in a sandbox where
     * routing has not been configured yet.
     */
    private static void insertWithAssignment(Lead record) {
        if (hasActiveLeadAssignmentRule()) {
            Database.DMLOptions options = new Database.DMLOptions();
            options.assignmentRuleHeader.useDefaultRule = true;
            record.setOptions(options);
        }
        try {
            insert record;
        } catch (DmlException e) {
            throw translate(e);
        }
    }

    private static Boolean hasActiveLeadAssignmentRule() {
        List<AssignmentRule> rules = [
            SELECT Id
            FROM AssignmentRule
            WHERE SobjectType = 'Lead' AND Active = TRUE
            LIMIT 1
        ];
        return !rules.isEmpty();
    }

    /** Maps a platform DML failure onto the documented error codes. */
    private static ApiException translate(DmlException e) {
        String message = e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage();

        if (e.getNumDml() > 0) {
            if (e.getDmlType(0) == StatusCode.DUPLICATES_DETECTED) {
                return error(
                    'DUPLICATE_DETECTED',
                    409,
                    null,
                    'A Salesforce duplicate rule blocked this Lead: ' + message
                );
            }
            if (isAddressFailure(e.getDmlFieldNames(0))) {
                return badRequest(
                    'INVALID_ADDRESS',
                    'state',
                    'The address was rejected by Salesforce: ' + message
                );
            }
        }
        return error('DML_EXCEPTION', 500, null, message);
    }

    private static Boolean isAddressFailure(List<String> fieldNames) {
        if (fieldNames == null) {
            return false;
        }
        for (String name : fieldNames) {
            String lower = name.toLowerCase();
            if (lower == 'state' || lower == 'country'
                || lower == 'statecode' || lower == 'countrycode') {
                return true;
            }
        }
        return false;
    }

    // =====================================================================
    // 6. Response rendering
    // =====================================================================

    /**
     * Reads the inserted Lead back so the response reports the owner the
     * assignment rule actually chose, rather than the value held in memory
     * before the insert.
     */
    private static LeadResponse buildResponse(Id leadId) {
        Lead saved = [
            SELECT Id, Status, Company, Store_Association__c, OwnerId
            FROM Lead
            WHERE Id = :leadId
            LIMIT 1
        ];

        LeadResponse result = new LeadResponse();
        result.success = true;
        result.action = 'CREATED';
        result.leadId = saved.Id;
        result.status = saved.Status;
        result.company = saved.Company;
        result.storeAssociationId = saved.Store_Association__c;
        result.ownerId = saved.OwnerId;
        result.message = 'Lead created successfully.';
        return result;
    }

    /**
     * Renders the standard error envelope from section 06 of the specification,
     * in the documented key order.
     */
    private static void writeError(
        RestResponse response,
        String errorCode,
        Integer httpStatus,
        String jsonField,
        String message
    ) {
        Integer status = (httpStatus == null) ? 500 : httpStatus;

        JSONGenerator json = JSON.createGenerator(true);
        json.writeStartObject();
        json.writeBooleanField('success', false);
        json.writeStringField('errorCode', errorCode);
        json.writeStringField('message', message);
        if (String.isNotBlank(jsonField)) {
            json.writeStringField('field', jsonField);
        }
        json.writeNumberField('httpStatus', status);
        json.writeEndObject();

        response.statusCode = status;
        response.responseBody = Blob.valueOf(json.getAsString());
    }

    // ---------------------------------------------------------------------
    // Error factories. Apex does not allow custom constructors or static
    // members on exception classes, so ApiException is populated from here.
    // ---------------------------------------------------------------------

    private static ApiException error(
        String errorCode,
        Integer httpStatus,
        String jsonField,
        String message
    ) {
        ApiException e = new ApiException(message);
        e.errorCode = errorCode;
        e.httpStatus = httpStatus;
        e.jsonField = jsonField;
        return e;
    }

    private static ApiException badRequest(String errorCode, String jsonField, String message) {
        return error(errorCode, 400, jsonField, message);
    }

    // =====================================================================
    // 7. Inner types
    // =====================================================================

    /**
     * Inbound payload. Member names match the JSON keys in section 04 of the
     * specification exactly; any key not declared here is ignored.
     */
    public class LeadRequest {
        // Customer identity
        public String salutation;
        public String firstName;
        public String lastName;
        public String company;
        // Personal details
        public String dateOfBirth;
        public String maritalStatus;
        public String anniversaryDate;
        // Contact details
        public String phone;
        public String email;
        public String website;
        // Address
        public String street;
        public String city;
        public String state;
        public String postalCode;
        public String country;
        // Classification and routing
        public String leadSource;
        public String status;
        public String businessType;
        public String rating;
        public String industry;
        public String storeCode;
        public Boolean walkInFlag;
        public String campaignName;
        // Enquiry detail
        public String description;
        public String qualificationNotes;
        public Decimal annualRevenue;
        public Integer numberOfEmployees;

        /**
         * Trims every text value and turns blanks into nulls, so validation can
         * treat "missing" and "sent as spaces" identically.
         */
        public void normalise() {
            salutation = clean(salutation);
            firstName = clean(firstName);
            lastName = clean(lastName);
            company = clean(company);
            dateOfBirth = clean(dateOfBirth);
            maritalStatus = clean(maritalStatus);
            anniversaryDate = clean(anniversaryDate);
            phone = clean(phone);
            email = clean(email);
            website = clean(website);
            street = clean(street);
            city = clean(city);
            state = clean(state);
            postalCode = clean(postalCode);
            country = clean(country);
            leadSource = clean(leadSource);
            status = clean(status);
            businessType = clean(businessType);
            rating = clean(rating);
            industry = clean(industry);
            storeCode = clean(storeCode);
            campaignName = clean(campaignName);
            description = clean(description);
            qualificationNotes = clean(qualificationNotes);
        }

        private String clean(String value) {
            return String.isBlank(value) ? null : value.trim();
        }
    }

    /** Success payload, serialised straight to the 201 response body. */
    public class LeadResponse {
        public Boolean success;
        public String action;
        public String leadId;
        public String status;
        public String company;
        public String storeAssociationId;
        public String ownerId;
        public String message;
    }

    /**
     * Carries the three things the documented error envelope needs, so the
     * entry point can render a response without inspecting message text.
     */
    public class ApiException extends Exception {
        public String errorCode;
        public Integer httpStatus;
        public String jsonField;
    }
}
