/**
 * Tests for IntegrationLogService and its use by the four inbound REST APIs:
 * one Integration Log per failed call, none for a successful one, and no
 * effect on the response when the log itself cannot be written.
 */
@IsTest
private class IntegrationLogServiceTest {

    private static final String LEADS = '/services/apexrest/shreehari/v1/leads';
    private static final String CUSTOMERS = '/services/apexrest/shreehari/v1/customers';
    private static final String PRODUCTS = '/services/apexrest/shreehari/v1/products';
    private static final String ORDERS = '/services/apexrest/shreehari/v1/orders';

    private static void prepare(String uri, String body) {
        RestRequest request = new RestRequest();
        request.requestURI = uri;
        request.httpMethod = 'POST';
        if (body != null) {
            request.requestBody = Blob.valueOf(body);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    private static List<Integration_Log__c> logs() {
        return [
            SELECT API_Name__c, Class_Name__c, Method_Name__c, Request_Body__c, Response_Body__c,
                Response_Code__c, Success_Log__c, Error_Log__c, Error_Code__c, Error_Field__c,
                Request_Body_Truncated__c
            FROM Integration_Log__c
            WITH SYSTEM_MODE
            ORDER BY Name
        ];
    }

    private static void assertLog(
        String apiName, String className, String methodName, String body,
        Integer code, String errorCode, String errorField
    ) {
        List<Integration_Log__c> found = logs();
        Assert.areEqual(1, found.size(), 'One log per failed call');
        Integration_Log__c log = found[0];
        Assert.areEqual(apiName, log.API_Name__c);
        Assert.areEqual(className, log.Class_Name__c);
        Assert.areEqual(methodName, log.Method_Name__c);
        Assert.areEqual(body, log.Request_Body__c);
        Assert.areEqual(RestContext.response.responseBody.toString(), log.Response_Body__c, 'The body the caller received');
        Assert.areEqual(code, RestContext.response.statusCode);
        Assert.areEqual(code, Integer.valueOf(log.Response_Code__c));
        Assert.areEqual(errorCode, log.Error_Code__c);
        Assert.areEqual(errorField, log.Error_Field__c);
        Assert.isFalse(log.Request_Body_Truncated__c);
        Assert.isNull(log.Success_Log__c);
        Assert.isTrue(log.Error_Log__c.contains('ApiException'), log.Error_Log__c);
    }

    @IsTest
    static void leadFailureIsLogged() {
        String body = '{"lastName":"Mehta","description":"Gold ring","leadSource":"Website"}';
        prepare(LEADS, body);
        ShreeHariLeadRestResource.createLead();
        assertLog('Lead', 'ShreeHariLeadRestResource', 'createLead', body, 400, 'MISSING_REQUIRED_FIELD', 'phone');
    }

    @IsTest
    static void customerFailureIsLogged() {
        String body = '{"first_name":"Asha"}';
        prepare(CUSTOMERS, body);
        ShreeHariCustomerRestResource.receiveCustomer();
        assertLog('Customer', 'ShreeHariCustomerRestResource', 'receiveCustomer', body, 400, 'MISSING_REQUIRED_FIELD', 'id');
    }

    @IsTest
    static void productFailureIsLogged() {
        String body = '{"title":"Classic Gold Ring"}';
        prepare(PRODUCTS, body);
        ShreeHariProductRestResource.receiveProduct();
        assertLog('Product', 'ShreeHariProductRestResource', 'receiveProduct', body, 400, 'MISSING_REQUIRED_FIELD', 'id');
    }

    @IsTest
    static void variantFailureIsLogged() {
        String body = '{"id":"6786188247105","variants":[{"id":"1","price":"10.00"},{"id":"2","price":"abc"}]}';
        prepare(PRODUCTS, body);
        ShreeHariProductRestResource.receiveProduct();
        assertLog('Product', 'ShreeHariProductRestResource', 'receiveProduct', body, 400, 'INVALID_NUMBER', 'variants[1].price');
        Assert.areEqual(0, [SELECT COUNT() FROM Staging_Product__c WITH SYSTEM_MODE], 'Nothing is saved, as before');
    }

    @IsTest
    static void orderFailureIsLogged() {
        String body = '{"id":"5123","total_price":"abc"}';
        prepare(ORDERS, body);
        ShreeHariOrderRestResource.receiveOrder();
        assertLog('Order', 'ShreeHariOrderRestResource', 'receiveOrder', body, 400, 'INVALID_NUMBER', 'total_price');
    }

    @IsTest
    static void bodyThatIsNotJsonIsLoggedAsSent() {
        String body = 'id=5123&name=test';
        prepare(ORDERS, body);
        ShreeHariOrderRestResource.receiveOrder();
        assertLog('Order', 'ShreeHariOrderRestResource', 'receiveOrder', body, 400, 'INVALID_JSON', null);
    }

    @IsTest
    static void emptyBodyIsLogged() {
        prepare(CUSTOMERS, null);
        ShreeHariCustomerRestResource.receiveCustomer();
        assertLog('Customer', 'ShreeHariCustomerRestResource', 'receiveCustomer', null, 400, 'INVALID_JSON', null);
    }

    @IsTest
    static void longRequestBodyIsCut() {
        Integer maxLength = Integration_Log__c.Request_Body__c.getDescribe().getLength();
        String body = '{"note":"' + 'x'.repeat(maxLength) + '"}';
        prepare(ORDERS, body);
        ShreeHariOrderRestResource.receiveOrder();

        Assert.areEqual(400, RestContext.response.statusCode);
        Integration_Log__c log = logs()[0];
        Assert.isTrue(log.Request_Body_Truncated__c);
        Assert.areEqual(maxLength, log.Request_Body__c.length());
        Assert.areEqual(body.left(maxLength), log.Request_Body__c);
    }

    /** A log exists exactly when the call failed. */
    @IsTest
    static void successfulCallIsNotLogged() {
        prepare(CUSTOMERS, '{"id":"7001","first_name":"Asha"}');
        ShreeHariCustomerRestResource.receiveCustomer();

        Integer expected = (RestContext.response.statusCode == 201) ? 0 : 1;
        Assert.areEqual(expected, logs().size(), 'Status ' + RestContext.response.statusCode);
    }

    @IsTest
    static void responseIsUnchangedWhenTheLogCannotBeWritten() {
        String body = '{"first_name":"Asha"}';
        prepare(CUSTOMERS, body);
        ShreeHariCustomerRestResource.receiveCustomer();
        String logged = RestContext.response.responseBody.toString();
        Database.delete(logs(), true, AccessLevel.SYSTEM_MODE);

        IntegrationLogService.failForTest = true;
        prepare(CUSTOMERS, body);
        ShreeHariCustomerRestResource.receiveCustomer();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(logged, RestContext.response.responseBody.toString(), 'Same response with or without a log');
        Assert.areEqual(0, logs().size());
    }

    @IsTest
    static void unexpectedExceptionIsLoggedWithItsStackTrace() {
        prepare(ORDERS, '{"id":"5123"}');
        RestContext.response.statusCode = 500;
        RestContext.response.responseBody = Blob.valueOf('not the envelope');
        try {
            Integer zero = 0;
            Integer broken = 1 / zero;
        } catch (Exception e) {
            IntegrationLogService.logError(IntegrationLogService.API_ORDER, 'ShreeHariOrderRestResource', 'receiveOrder', e);
        }

        Integration_Log__c log = logs()[0];
        Assert.areEqual(500, Integer.valueOf(log.Response_Code__c));
        Assert.areEqual('not the envelope', log.Response_Body__c);
        Assert.isNull(log.Error_Code__c);
        Assert.isTrue(log.Error_Log__c.startsWith('System.MathException: Divide by 0'), log.Error_Log__c);
        Assert.isTrue(log.Error_Log__c.contains('IntegrationLogServiceTest'), 'Stack trace: ' + log.Error_Log__c);
    }

    @IsTest
    static void worksWithoutARestContext() {
        RestContext.request = null;
        RestContext.response = null;
        IntegrationLogService.logError(IntegrationLogService.API_LEAD, 'ShreeHariLeadRestResource', 'createLead', null);

        Integration_Log__c log = logs()[0];
        Assert.areEqual('Lead', log.API_Name__c);
        Assert.isNull(log.Request_Body__c);
        Assert.isNull(log.Response_Code__c);
        Assert.isNull(log.Error_Log__c);
    }
}
