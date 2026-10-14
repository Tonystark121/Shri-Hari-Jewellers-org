/**
 * Tests for redemptions reported by POS on Transaction Records: the gift
 * voucher and points on the bill are recorded as reported, and a bill that
 * cannot be recorded is rejected with the reason.
 *
 * Vouchers and bills are written and read in system mode, so the tests do not
 * depend on the running user's field access.
 */
@IsTest
private class GiftVoucherRedemptionTest {

    private static Integer billCounter = 0;

    @TestSetup
    static void makeData() {
        Account customer = new Account(Name = 'Voucher Customer');
        Account other = new Account(Name = 'Other Customer');
        insert new List<Account>{ customer, other };

        Date inAMonth = Date.today().addDays(30);
        insert as system new List<Gift_Voucher__c>{
            // Salesforce says bills from 5,000 to 10,000; POS's figures are kept regardless
            voucher(customer.Id, 'FIX-RANGE', 'Fixed Price', 500, null, 5000, 10000, 'Active', inAMonth),
            voucher(customer.Id, 'PCT-TEN', 'Percentage', null, 10, null, 5000, 'Active', inAMonth),
            voucher(other.Id, 'OTHER-CUST', 'Fixed Price', 500, null, null, 1000, 'Active', inAMonth),
            voucher(customer.Id, 'USED', 'Fixed Price', 500, null, null, 1000, 'Redeemed', inAMonth),
            voucher(customer.Id, 'CANCELLED', 'Fixed Price', 500, null, null, 1000, 'Cancelled', inAMonth),
            voucher(customer.Id, 'EXPIRED', 'Fixed Price', 500, null, null, 1000, 'Active', Date.today().addDays(-1))
        };
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    private static Gift_Voucher__c voucher(
        Id accountId, String code, String offerType, Decimal faceValue, Decimal percentage,
        Decimal minimum, Decimal maximum, String status, Date expiry
    ) {
        return new Gift_Voucher__c(
            Account__c = accountId,
            Voucher_Code__c = code,
            Offer_Type__c = offerType,
            Face_Value__c = faceValue,
            Discount_Percentage__c = percentage,
            Minimum_Amount__c = minimum,
            Maximum_Amount__c = maximum,
            Status__c = status,
            Expiry_Date__c = expiry
        );
    }

    private static Id customerId() {
        return [SELECT Id FROM Account WHERE Name = 'Voucher Customer' LIMIT 1].Id;
    }

    private static Gift_Voucher__c voucherWithCode(String code) {
        return [
            SELECT Id, Status__c, Redemption_Date__c, Redemption_Channel__c
            FROM Gift_Voucher__c
            WHERE Voucher_Code__c = :code
            WITH SYSTEM_MODE
        ];
    }

    private static Transaction_Record__c plainBill(Decimal amount) {
        billCounter++;
        return new Transaction_Record__c(
            Account__c = customerId(),
            Amount__c = amount,
            Bill_Number__c = 'GVR-' + String.valueOf(billCounter).leftPad(6, '0'),
            Transaction_Date__c = Datetime.now()
        );
    }

    /** A bill on which POS reports a Fixed Price voucher of Rs. 500 face value. */
    private static Transaction_Record__c voucherBill(String code, Decimal amount, Decimal discount) {
        Transaction_Record__c bill = plainBill(amount);
        bill.Voucher_Code__c = code;
        bill.Voucher_Offer_Type__c = 'Fixed Price';
        bill.Voucher_Face_Value__c = 500;
        bill.Voucher_Discount__c = discount;
        bill.Voucher_Redemption_Channel__c = 'POS';
        return bill;
    }

    private static Transaction_Record__c saved(Id billId) {
        return [
            SELECT Gift_Voucher__c, Voucher_Code__c, Voucher_Offer_Type__c, Voucher_Face_Value__c,
                   Voucher_Discount_Percentage__c, Voucher_Discount__c, Voucher_Redemption_Channel__c,
                   Points_Redeemed__c, Net_Amount__c
            FROM Transaction_Record__c
            WHERE Id = :billId
            WITH SYSTEM_MODE
        ];
    }

    private static String saveError(Transaction_Record__c bill) {
        Database.SaveResult result = Database.insert(bill, false, AccessLevel.SYSTEM_MODE);
        return result.isSuccess() ? null : result.getErrors()[0].getMessage();
    }

    private static void assertRejected(Transaction_Record__c bill, String expected) {
        String error = saveError(bill);
        Assert.isNotNull(error, 'Should be rejected: ' + expected);
        Assert.isTrue(error.startsWith(GiftVoucherRedemption.REJECTED), 'Says the bill was not saved: ' + error);
        Assert.isTrue(error.contains(expected), error);
    }

    // =====================================================================
    // Recording what POS reports
    // =====================================================================

    @IsTest
    static void theReportedVoucherIsRecordedAndRedeemed() {
        Transaction_Record__c bill = voucherBill('fix-range', 6000, 500);

        Test.startTest();
        Assert.isNull(saveError(bill), 'A reported voucher saves');
        Test.stopTest();

        Transaction_Record__c record = saved(bill.Id);
        Gift_Voucher__c voucher = voucherWithCode('FIX-RANGE');
        Assert.areEqual(voucher.Id, record.Gift_Voucher__c, 'The bill links to the voucher');
        Assert.areEqual('Fixed Price', record.Voucher_Offer_Type__c, 'Offer type kept');
        Assert.areEqual(500, record.Voucher_Face_Value__c, 'Face value kept');
        Assert.areEqual(500, record.Voucher_Discount__c, 'Discount kept');
        Assert.areEqual(0, record.Points_Redeemed__c, 'No points on this bill');
        Assert.areEqual(5500, record.Net_Amount__c, '6,000 - 500');
        Assert.areEqual('Redeemed', voucher.Status__c, 'The voucher is used up');
        Assert.areEqual(Date.today(), voucher.Redemption_Date__c, 'Redeemed on the bill date');
        Assert.areEqual('POS', voucher.Redemption_Channel__c, 'Channel copied from the bill');
    }

    /** POS applied the offer: its discount is kept even outside the voucher's range in Salesforce. */
    @IsTest
    static void theDiscountReportedByPosIsKept() {
        Transaction_Record__c bill = voucherBill('FIX-RANGE', 4000, 300);

        Assert.isNull(saveError(bill), 'Saves; Salesforce does not re-check the offer');
        Assert.areEqual(300, saved(bill.Id).Voucher_Discount__c, 'The reported discount');
        Assert.areEqual(3700, saved(bill.Id).Net_Amount__c, '4,000 - 300');
    }

    @IsTest
    static void aPercentageVoucherCarriesItsPercentage() {
        Transaction_Record__c withoutPercentage = voucherBill('PCT-TEN', 8000, 800);
        withoutPercentage.Voucher_Offer_Type__c = 'Percentage';
        withoutPercentage.Voucher_Face_Value__c = null;
        assertRejected(withoutPercentage, 'Voucher Discount Percentage');

        Transaction_Record__c complete = voucherBill('PCT-TEN', 8000, 800);
        complete.Voucher_Offer_Type__c = 'Percentage';
        complete.Voucher_Face_Value__c = null;
        complete.Voucher_Discount_Percentage__c = 10;
        Assert.isNull(saveError(complete), 'Saves with the percentage');
        Assert.areEqual(10, saved(complete.Id).Voucher_Discount_Percentage__c, 'Percentage kept');
        Assert.areEqual(7200, saved(complete.Id).Net_Amount__c, '8,000 - 800');
    }

    @IsTest
    static void pointsAreEarnedOnTheNetAmount() {
        Test.startTest();
        Assert.isNull(saveError(voucherBill('FIX-RANGE', 6000, 500)), 'Saves');
        Test.stopTest();

        Loyalty_Transaction__c earned = [
            SELECT Net_Loyalty_Amount__c
            FROM Loyalty_Transaction__c
            WHERE Transaction_Type__c = 'Earn'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        Assert.areEqual(5500, earned.Net_Loyalty_Amount__c, 'Points are earned on the amount after the voucher');
    }

    /** POS may apply a voucher and points on the same bill. */
    @IsTest
    static void aVoucherAndPointsOnOneBillAreBothRecorded() {
        Loyalty_Record__c loyalty = [SELECT Id FROM Loyalty_Record__c WHERE Account__c = :customerId() WITH SYSTEM_MODE];
        loyalty.Points_Balance__c = 300;
        update as system loyalty;
        insert as system new Loyalty_Transaction__c(
            Loyalty_Record__c = loyalty.Id,
            Transaction_Type__c = 'Earn',
            Status__c = 'Active',
            Points_Earned__c = 300,
            Remaining_Points__c = 300,
            Credit_Date__c = Date.today().addDays(-10),
            Expiry_Date__c = Date.today().addDays(355)
        );
        Transaction_Record__c bill = voucherBill('FIX-RANGE', 6000, 500);
        bill.Points_Redeemed__c = 200;

        Test.startTest();
        Assert.isNull(saveError(bill), 'Both are recorded');
        Test.stopTest();

        Assert.areEqual(5300, saved(bill.Id).Net_Amount__c, '6,000 - 500 voucher - 200 points');
    }

    @IsTest
    static void aBillWithoutAVoucherClearsStrayVoucherDetails() {
        Id voucherId = voucherWithCode('FIX-RANGE').Id;
        Transaction_Record__c bill = plainBill(6000);
        bill.Gift_Voucher__c = voucherId;
        bill.Voucher_Offer_Type__c = 'Fixed Price';
        bill.Voucher_Face_Value__c = 500;

        Assert.isNull(saveError(bill), 'Saves as a plain bill');

        Transaction_Record__c record = saved(bill.Id);
        Assert.isNull(record.Gift_Voucher__c, 'Only the system links a voucher');
        Assert.isNull(record.Voucher_Offer_Type__c, 'No code, no voucher details');
        Assert.areEqual(0, record.Voucher_Discount__c, 'No discount');
        Assert.areEqual(6000, record.Net_Amount__c, 'Full amount');
        Assert.areEqual('Active', voucherWithCode('FIX-RANGE').Status__c, 'The voucher is untouched');
    }

    // =====================================================================
    // Rejected, with the reason
    // =====================================================================

    @IsTest
    static void aVoucherSalesforceCannotRecordIsRejected() {
        assertRejected(voucherBill('NO-SUCH-CODE', 6000, 500), 'is not in Salesforce');
        assertRejected(voucherBill('OTHER-CUST', 6000, 500), 'belongs to another customer');
        assertRejected(voucherBill('USED', 6000, 500), 'is Redeemed in Salesforce');
        assertRejected(voucherBill('CANCELLED', 6000, 500), 'is Cancelled in Salesforce');
        assertRejected(voucherBill('EXPIRED', 6000, 500), 'expired on');
    }

    @IsTest
    static void aVoucherCannotBeRedeemedTwice() {
        Assert.isNull(saveError(voucherBill('FIX-RANGE', 6000, 500)), 'First redemption saves');
        assertRejected(voucherBill('FIX-RANGE', 7000, 500), 'is Redeemed in Salesforce');
    }

    @IsTest
    static void theSameVoucherTwiceInOneSaveIsRejected() {
        List<Database.SaveResult> results = Database.insert(new List<Transaction_Record__c>{
            voucherBill('FIX-RANGE', 6000, 500),
            voucherBill('FIX-RANGE', 7000, 500)
        }, false, AccessLevel.SYSTEM_MODE);

        Assert.isTrue(results[0].isSuccess(), 'The first bill redeems the voucher');
        Assert.isFalse(results[1].isSuccess(), 'The second cannot');
        Assert.isTrue(results[1].getErrors()[0].getMessage().contains('another bill in the same save'), results[1].getErrors()[0].getMessage());
    }

    @IsTest
    static void incompleteOrImpossibleVoucherDetailsAreRejected() {
        Transaction_Record__c noOfferType = voucherBill('FIX-RANGE', 6000, 500);
        noOfferType.Voucher_Offer_Type__c = null;
        assertRejected(noOfferType, 'Voucher Offer Type');

        Transaction_Record__c noFaceValue = voucherBill('FIX-RANGE', 6000, 500);
        noFaceValue.Voucher_Face_Value__c = null;
        assertRejected(noFaceValue, 'Voucher Face Value');

        assertRejected(voucherBill('FIX-RANGE', 6000, null), 'enter the Voucher Discount');
        assertRejected(voucherBill('FIX-RANGE', 400, 500), 'is more than the bill Amount');

        Transaction_Record__c noChannel = voucherBill('FIX-RANGE', 6000, 500);
        noChannel.Voucher_Redemption_Channel__c = null;
        assertRejected(noChannel, 'Voucher Redemption Channel');

        Transaction_Record__c discountWithoutCode = plainBill(6000);
        discountWithoutCode.Voucher_Discount__c = 500;
        assertRejected(discountWithoutCode, 'without a Voucher Code');
    }
}
