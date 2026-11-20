/**
 * Writes Integration_Log__c records for the inbound REST APIs
 * (ShreeHariLeadRestResource, ShreeHariCustomerRestResource,
 * ShreeHariProductRestResource, ShreeHariOrderRestResource).
 *
 * Each API calls logError() from its catch blocks, after the error response
 * has been written, so one log is created for every failed call: what was
 * sent, what was answered and why.
 *
 * Logging never changes what the caller receives:
 *   - the request and response are only read, never modified;
 *   - the log is saved in system mode, so the integration user needs no
 *     access to Integration_Log__c;
 *   - anything that goes wrong while logging is swallowed.
 *
 * Calls refused by the platform before Apex runs (expired token, wrong URL,
 * a verb other than POST) cannot be logged here.
 */
public without sharing class IntegrationLogService {

    public static final String API_LEAD = 'Lead';
    public static final String API_CUSTOMER = 'Customer';
    public static final String API_PRODUCT = 'Product';
    public static final String API_ORDER = 'Order';

    @TestVisible
    private static final String UNREADABLE = '[The request body could not be read as text]';

    /** Set by a test to make the save fail, to prove the caller is unaffected. */
    @TestVisible
    private static Boolean failForTest = false;

    /**
     * Logs the failed call that is being answered right now. Reads the request
     * from RestContext.request and the already written error response from
     * RestContext.response.
     *
     * @param apiName     one of the API_* constants
     * @param className   the REST class
     * @param methodName  its @Http method
     * @param failure     the exception that ended the call
     */
    public static void logError(String apiName, String className, String methodName, Exception failure) {
        try {
            if (Limits.getDmlStatements() >= Limits.getLimitDmlStatements()
                || Limits.getDmlRows() >= Limits.getLimitDmlRows()) {
                return;
            }
            if (failForTest) {
                throw new IllegalArgumentException('Simulated logging failure');
            }

            Integration_Log__c log = new Integration_Log__c(
                API_Name__c = apiName,
                Class_Name__c = fit(className, Integration_Log__c.Class_Name__c),
                Method_Name__c = fit(methodName, Integration_Log__c.Method_Name__c),
                Error_Log__c = fit(describe(failure), Integration_Log__c.Error_Log__c)
            );
            addRequest(log, RestContext.request);
            addResponse(log, RestContext.response);

            Database.insert(log, false, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            // A log that cannot be written must not disturb the API response.
            System.debug(LoggingLevel.ERROR, 'Integration log not written: ' + e.getMessage());
        }
    }

    private static void addRequest(Integration_Log__c log, RestRequest request) {
        if (request == null || request.requestBody == null) {
            return;
        }
        String body;
        try {
            body = request.requestBody.toString();
        } catch (Exception e) {
            body = UNREADABLE;
        }
        Integer maxLength = Integration_Log__c.Request_Body__c.getDescribe().getLength();
        log.Request_Body_Truncated__c = body.length() > maxLength;
        log.Request_Body__c = body.left(maxLength);
    }

    private static void addResponse(Integration_Log__c log, RestResponse response) {
        if (response == null) {
            return;
        }
        log.Response_Code__c = response.statusCode;
        if (response.responseBody == null) {
            return;
        }
        String body = response.responseBody.toString();
        log.Response_Body__c = fit(body, Integration_Log__c.Response_Body__c);

        // The error envelope every API returns: {success, errorCode, message, field, httpStatus}
        try {
            Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(body);
            log.Error_Code__c = fit((String) envelope.get('errorCode'), Integration_Log__c.Error_Code__c);
            log.Error_Field__c = fit((String) envelope.get('field'), Integration_Log__c.Error_Field__c);
        } catch (Exception e) {
            // Not the envelope: the response body is logged as it is.
        }
    }

    /** Exception type, message and where it was raised. */
    private static String describe(Exception failure) {
        if (failure == null) {
            return null;
        }
        String text = failure.getTypeName() + ': ' + failure.getMessage();
        String trace = failure.getStackTraceString();
        if (String.isNotBlank(trace)) {
            text += '\n' + trace;
        }
        return text;
    }

    /** The value cut to the length of its field. */
    private static String fit(String value, Schema.SObjectField field) {
        return (value == null) ? null : value.left(field.getDescribe().getLength());
    }
}
