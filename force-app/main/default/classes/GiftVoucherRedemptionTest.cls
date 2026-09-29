/**
 * Tests for gift voucher redemption on Transaction Records: the live check
 * used by the New Transaction flow and the checks run when a bill is saved.
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
            // Min and Max: bills from 5,000 to 10,000, Rs. 500 off
            voucher(customer.Id, 'FIX-RANGE', 'Fixed Price', 500, null, 5000, 10000, 'Active', inAMonth),
            // Max only: bills of 5,000 or more, 10% off the total bill
            voucher(customer.Id, 'PCT-MAXONLY', 'Percentage', null, 10, null, 5000, 'Active', inAMonth),
            // Min saved as 0 counts as Max only: bills of 3,000 or more
            voucher(customer.Id, 'FIX-MINZERO', 'Fixed Price', 250, null, 0, 3000, 'Active', inAMonth),
            // Face value above the bill: the discount is capped at the bill
            voucher(customer.Id, 'FIX-BIG', 'Fixed Price', 900, null, null, 300, 'Active', inAMonth),
            voucher(other.Id, 'OTHER-CUST', 'Fixed Price', 500, null, null, 1000, 'Active', inAMonth),
            voucher(customer.Id, 'USED', 'Fixed Price', 500, null, null, 1000, 'Redeemed', inAMonth),
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
        List<Gift_Voucher__c> found = [
            SELECT Id, Account__c, Voucher_Code__c, Status__c, Expiry_Date__c, Offer_Type__c,
                   Face_Value__c, Discount_Percentage__c, Minimum_Amount__c, Maximum_Amount__c
            FROM Gift_Voucher__c
            WHERE Voucher_Code__c = :code
            WITH SYSTEM_MODE
        ];
        return found.isEmpty() ? null : found[0];
    }

    /** Why the voucher cannot be used on a bill of this amount today (null = it can). */
    private static String problem(String code, Decimal amount) {
        return GiftVoucherRedemption.problemWith(voucherWithCode(code), customerId(), amount, Date.today());
    }

    private static Decimal discount(String code, Decimal amount) {
        return GiftVoucherRedemption.discountFor(voucherWithCode(code), amount);
    }

    private static Transaction_Record__c voucherBill(String code, Decimal amount) {
        billCounter++;
        return new Transaction_Record__c(
            Account__c = customerId(),
            Amount__c = amount,
            Bill_Number__c = 'GVR-' + String.valueOf(billCounter).leftPad(6, '0'),
            Transaction_Date__c = Datetime.now(),
            Redeem_Gift_Voucher__c = true,
            Voucher_Code__c = code,
            Voucher_Redemption_Channel__c = 'POS'
        );
    }

    private static String saveError(Transaction_Record__c bill) {
        Database.SaveResult result = Database.insert(bill, false, AccessLevel.SYSTEM_MODE);
        return result.isSuccess() ? null : result.getErrors()[0].getMessage();
    }

    // =====================================================================
    // Rules (the same ones the New Transaction flow filters its list on)
    // =====================================================================

    @IsTest
    static void fixedVoucherWithinRangeIsValid() {
        Assert.isNull(problem('FIX-RANGE', 6000), 'Within 5,000 to 10,000');
        Assert.areEqual(500, discount('FIX-RANGE', 6000), 'Face value off');
    }

    @IsTest
    static void minAndMaxAreInclusive() {
        Assert.isNull(problem('FIX-RANGE', 5000), 'Exactly Min is allowed');
        Assert.isNull(problem('FIX-RANGE', 10000), 'Exactly Max is allowed');
        Assert.isTrue(problem('FIX-RANGE', 10001).contains('from'), 'Above Max is refused when a Min is set');
        Assert.isNotNull(problem('FIX-RANGE', 4999), 'Below Min is refused');
    }

    @IsTest
    static void maxOnlyVoucherNeedsABillOfMaxOrMore() {
        Assert.isNull(problem('PCT-MAXONLY', 8000), 'Above Max is fine without a Min');
        Assert.areEqual(800, discount('PCT-MAXONLY', 8000), '10% of the total 8,000 bill');
        Assert.isNull(problem('PCT-MAXONLY', 5000), 'Exactly Max is allowed');
        Assert.isTrue(problem('PCT-MAXONLY', 4999).contains('or more'), 'Below Max is refused');
    }

    @IsTest
    static void minimumOfZeroCountsAsBlank() {
        Assert.isNull(problem('FIX-MINZERO', 3500), 'Min 0: bills of Max (3,000) or more');
        Assert.isNotNull(problem('FIX-MINZERO', 2000), 'Min 0 is not a 0-to-Max range');
    }

    @IsTest
    static void discountNeverExceedsTheBill() {
        Assert.isNull(problem('FIX-BIG', 400), 'Bill of Max (300) or more');
        Assert.areEqual(400, discount('FIX-BIG', 400), 'A 900 voucher on a 400 bill takes 400 off');
    }

    @IsTest
    static void explainsWhyAVoucherIsInvalid() {
        Map<String, String> expectedByCode = new Map<String, String>{
            'NO-SUCH-CODE' => 'no voucher has this code',
            'OTHER-CUST'   => 'belongs to another customer',
            'USED'         => 'this voucher is Redeemed',
            'EXPIRED'      => 'expired on'
        };
        for (String code : expectedByCode.keySet()) {
            String reason = problem(code, 2000);
            Assert.isNotNull(reason, code + ' should be invalid');
            Assert.isTrue(reason.contains(expectedByCode.get(code)), code + ': ' + reason);
        }
    }

    // =====================================================================
    // Saving a bill (trigger)
    // =====================================================================

    @IsTest
    static void savingABillRedeemsTheVoucher() {
        Transaction_Record__c bill = voucherBill('fix-range', 6000);

        Test.startTest();
        Assert.isNull(saveError(bill), 'A valid voucher bill saves');
        Test.stopTest();

        Transaction_Record__c saved = [
            SELECT Gift_Voucher__c, Voucher_Discount__c, Points_Redeemed__c, Net_Amount__c, Voucher_Code__c
            FROM Transaction_Record__c
            WHERE Id = :bill.Id
            WITH SYSTEM_MODE
        ];
        Gift_Voucher__c voucher = [
            SELECT Id, Status__c, Redemption_Date__c, Redemption_Channel__c
            FROM Gift_Voucher__c
            WHERE Voucher_Code__c = 'FIX-RANGE'
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(voucher.Id, saved.Gift_Voucher__c, 'The bill links to the redeemed voucher');
        Assert.areEqual(500, saved.Voucher_Discount__c, 'Voucher discount stamped');
        Assert.areEqual(0, saved.Points_Redeemed__c, 'No points on a voucher bill');
        Assert.areEqual(5500, saved.Net_Amount__c, '6,000 - 500');
        Assert.areEqual('Redeemed', voucher.Status__c, 'The voucher is used up');
        Assert.areEqual(Date.today(), voucher.Redemption_Date__c, 'Redeemed on the bill date');
        Assert.areEqual('POS', voucher.Redemption_Channel__c, 'Channel copied from the bill');
    }

    @IsTest
    static void pointsAreEarnedOnTheNetAmount() {
        Test.startTest();
        Assert.isNull(saveError(voucherBill('FIX-RANGE', 6000)), 'Saves');
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

    @IsTest
    static void aVoucherCannotBeRedeemedTwice() {
        Assert.isNull(saveError(voucherBill('FIX-RANGE', 6000)), 'First redemption saves');

        String error = saveError(voucherBill('FIX-RANGE', 7000));
        Assert.isNotNull(error, 'Second redemption is refused');
        Assert.isTrue(error.contains('this voucher is Redeemed'), error);
    }

    @IsTest
    static void theSameVoucherTwiceInOneSaveIsRefused() {
        List<Transaction_Record__c> bills = new List<Transaction_Record__c>{
            voucherBill('FIX-RANGE', 6000),
            voucherBill('FIX-RANGE', 7000)
        };

        List<Database.SaveResult> results = Database.insert(bills, false, AccessLevel.SYSTEM_MODE);

        Assert.isTrue(results[0].isSuccess(), 'The first bill redeems the voucher');
        Assert.isFalse(results[1].isSuccess(), 'The second cannot');
        Assert.isTrue(results[1].getErrors()[0].getMessage().contains('another bill'), results[1].getErrors()[0].getMessage());
    }

    @IsTest
    static void pointsAndVoucherTogetherAreRefused() {
        Transaction_Record__c bill = voucherBill('FIX-RANGE', 6000);
        bill.Redeem_Points__c = true;

        String error = saveError(bill);
        Assert.isNotNull(error, 'Both redemptions are refused');
        Assert.isTrue(error.contains('Only one redemption is allowed per transaction'), error);
    }

    @IsTest
    static void invalidOrIncompleteVoucherBillsAreRefused() {
        Assert.isTrue(saveError(voucherBill('NO-SUCH-CODE', 6000)).contains('Voucher code is invalid'), 'Unknown code');
        Assert.isTrue(saveError(voucherBill('OTHER-CUST', 6000)).contains('another customer'), 'Another customer\'s voucher');
        Assert.isTrue(saveError(voucherBill('EXPIRED', 6000)).contains('expired'), 'Expired voucher');

        Transaction_Record__c noCode = voucherBill(null, 6000);
        Assert.isTrue(saveError(noCode).contains('Enter the Voucher Code'), 'Code required');

        Transaction_Record__c noChannel = voucherBill('FIX-RANGE', 6000);
        noChannel.Voucher_Redemption_Channel__c = null;
        Assert.isTrue(saveError(noChannel).contains('Redemption Channel'), 'Channel required');
    }

    @IsTest
    static void systemFieldsCannotBeSetByTheCaller() {
        Id voucherId = [SELECT Id FROM Gift_Voucher__c WHERE Voucher_Code__c = 'FIX-RANGE' WITH SYSTEM_MODE].Id;
        billCounter++;
        Transaction_Record__c bill = new Transaction_Record__c(
            Account__c = customerId(),
            Amount__c = 6000,
            Bill_Number__c = 'GVR-SPOOF',
            Transaction_Date__c = Datetime.now(),
            Gift_Voucher__c = voucherId,
            Voucher_Discount__c = 999
        );

        Assert.isNull(saveError(bill), 'Saves as a plain bill');

        Transaction_Record__c saved = [
            SELECT Gift_Voucher__c, Voucher_Discount__c, Net_Amount__c
            FROM Transaction_Record__c
            WHERE Id = :bill.Id
            WITH SYSTEM_MODE
        ];
        Assert.isNull(saved.Gift_Voucher__c, 'Only a ticked, valid voucher is linked');
        Assert.areEqual(0, saved.Voucher_Discount__c, 'Discount is always calculated, never taken from the caller');
        Assert.areEqual(6000, saved.Net_Amount__c, 'Full amount');
        Assert.areEqual('Active', [SELECT Status__c FROM Gift_Voucher__c WHERE Id = :voucherId WITH SYSTEM_MODE].Status__c, 'The voucher is untouched');
    }
}
