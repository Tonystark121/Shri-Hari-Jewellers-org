/**
 * Tests for TransactionTriggerHandler when a bill is inserted:
 *   - final bill handling: Net Amount for every combination POS reports
 *     (nothing, points, gift voucher, both), and the points earned on it,
 *   - Loyalty Bypass > Disable Earning,
 *   - the real-time Last 12 Month Spend recalculation.
 *
 * Loyalty rules in depth are covered by LoyaltyEngineTest, voucher checks by
 * GiftVoucherRedemptionTest, the nightly recalculation by
 * ShreeHariTrailingSpendBatchTest.
 */
@IsTest
private class TransactionTriggerHandlerTest {

    private static Integer billCounter = 0;

    // =====================================================================
    // Helpers
    // =====================================================================

    private static Account household(String name, Decimal storedSpend) {
        return new Account(Name = name, Last_12M_Spend__c = storedSpend);
    }

    /** A purchase of `amount`, dated `daysAgo` days before now. */
    private static Transaction_Record__c purchase(Id accountId, Decimal amount, Integer daysAgo) {
        billCounter++;
        return new Transaction_Record__c(
            Account__c = accountId,
            Amount__c = amount,
            Bill_Number__c = 'BILL-' + String.valueOf(billCounter).leftPad(6, '0'),
            Transaction_Date__c = Datetime.now().addDays(-daysAgo)
        );
    }

    private static Account reload(Id accountId) {
        return [
            SELECT Last_12M_Spend__c, Customer_Tier__c
            FROM Account
            WHERE Id = :accountId
        ];
    }

    private static Transaction_Record__c savedBill(Id billId) {
        return [
            SELECT Points_Redeemed__c, Voucher_Discount__c, Net_Amount__c, Gift_Voucher__c
            FROM Transaction_Record__c
            WHERE Id = :billId
            WITH SYSTEM_MODE
        ];
    }

    /**
     * The household's Loyalty Record: the one the "Account: Create Loyalty
     * Record" flow made when it is active, otherwise the engine's.
     */
    private static Loyalty_Record__c loyaltyFor(Id accountId) {
        return [
            SELECT Id, Points_Balance__c
            FROM Loyalty_Record__c
            WHERE Account__c = :accountId
            WITH SYSTEM_MODE
        ];
    }

    /** Points earned on the bill (0 when it earned none). */
    private static Decimal earnedOn(Id billId) {
        List<Loyalty_Transaction__c> earned = [
            SELECT Points_Earned__c
            FROM Loyalty_Transaction__c
            WHERE Transaction_Record__c = :billId
              AND Transaction_Type__c = 'Earn'
            WITH SYSTEM_MODE
        ];
        return earned.isEmpty() ? 0 : earned[0].Points_Earned__c;
    }

    /** A household holding `points`, all in one lot earned 30 days ago. */
    private static void withPoints(Id accountId, Integer points) {
        List<Loyalty_Record__c> existing = [
            SELECT Id FROM Loyalty_Record__c WHERE Account__c = :accountId WITH SYSTEM_MODE
        ];
        Loyalty_Record__c loyalty = existing.isEmpty() ? new Loyalty_Record__c(Account__c = accountId) : existing[0];
        loyalty.Points_Balance__c = points;
        loyalty.Total_Points_Earned__c = points;
        loyalty.Total_Points_Redeemed__c = 0;
        upsert as system loyalty;

        Date creditDate = Date.today().addDays(-30);
        insert as system new Loyalty_Transaction__c(
            Loyalty_Record__c = loyalty.Id,
            Transaction_Type__c = 'Earn',
            Status__c = 'Active',
            Points_Earned__c = points,
            Remaining_Points__c = points,
            Credit_Date__c = creditDate,
            Expiry_Date__c = creditDate.addDays(365)
        );
    }

    /** An Active Fixed Price voucher of Rs. 500 for this household. */
    private static Gift_Voucher__c activeVoucher(Id accountId, String code) {
        Gift_Voucher__c voucher = new Gift_Voucher__c(
            Account__c = accountId,
            Voucher_Code__c = code,
            Offer_Type__c = 'Fixed Price',
            Face_Value__c = 500,
            Status__c = 'Active',
            Expiry_Date__c = Date.today().addDays(30)
        );
        insert as system voucher;
        return voucher;
    }

    /** The bill with a Fixed Price voucher reported by POS. */
    private static Transaction_Record__c withVoucher(Transaction_Record__c bill, String code, Decimal discount) {
        bill.Voucher_Code__c = code;
        bill.Voucher_Offer_Type__c = 'Fixed Price';
        bill.Voucher_Face_Value__c = 500;
        bill.Voucher_Discount__c = discount;
        bill.Voucher_Redemption_Channel__c = 'POS';
        return bill;
    }

    // =====================================================================
    // Real-time recalculation on every bill
    // =====================================================================

    /** The figure and tier move when the bill is saved, without the batch. */
    @IsTest
    static void recalculatesSpendAndTierAsSoonAsABillLands() {
        Account acct = household('Walk In', null);
        insert acct;

        Test.startTest();
        insert purchase(acct.Id, 30000.00, 0);
        Test.stopTest();

        Account refreshed = reload(acct.Id);
        Assert.areEqual(30000.00, refreshed.Last_12M_Spend__c, 'The bill counts the moment it is saved');
        Assert.areEqual('Platinum', refreshed.Customer_Tier__c, 'The tier follows without waiting for the nightly run');
    }

    /** A bill that sits outside the window does not add to the figure. */
    @IsTest
    static void aBackDatedBillOutsideTheWindowDoesNotCount() {
        Account acct = household('Old Import', null);
        insert acct;
        insert purchase(acct.Id, 5000.00, 30);

        Test.startTest();
        insert purchase(acct.Id, 200000.00, 400);
        Test.stopTest();

        Account refreshed = reload(acct.Id);
        Assert.areEqual(5000.00, refreshed.Last_12M_Spend__c, 'Only billing inside the 365 day window counts');
        Assert.areEqual('Silver', refreshed.Customer_Tier__c, 'The old bill does not lift the tier');
    }

    /** A return reduces the figure straight away. */
    @IsTest
    static void aReturnReducesTheFigureStraightAway() {
        Account acct = household('Returned Goods', null);
        insert acct;
        insert purchase(acct.Id, 30000.00, 20);

        Test.startTest();
        insert purchase(acct.Id, -25000.00, 0);
        Test.stopTest();

        Account refreshed = reload(acct.Id);
        Assert.areEqual(5000.00, refreshed.Last_12M_Spend__c, 'The return is netted off');
        Assert.areEqual('Silver', refreshed.Customer_Tier__c, 'The tier follows the net figure');
    }

    /**
     * The bill that crosses a slab still earns at the tier held before it;
     * only the next bill earns at the new tier.
     *
     * 7,000 at Silver 2%  = 140 points, spend 7,000 (Silver)
     * 1,000 at Silver 2%  =  20 points, spend 8,000 (Gold)
     * 1,000 at Gold 4%    =  40 points, spend 9,000 (Gold)
     */
    @IsTest
    static void theNextBillEarnsAtTheNewTier() {
        Account acct = household('Moving Up', null);
        insert acct;

        Test.startTest();
        insert purchase(acct.Id, 7000.00, 0);
        Assert.areEqual('Silver', reload(acct.Id).Customer_Tier__c, '7,000 is Silver');

        insert purchase(acct.Id, 1000.00, 0);
        Assert.areEqual('Gold', reload(acct.Id).Customer_Tier__c, '8,000 crosses into Gold');

        insert purchase(acct.Id, 1000.00, 0);
        Test.stopTest();

        Assert.areEqual(9000.00, reload(acct.Id).Last_12M_Spend__c, 'All three bills count');
        Assert.areEqual(200, loyaltyFor(acct.Id).Points_Balance__c, '140 + 20 at Silver, then 40 at Gold');
    }

    // =====================================================================
    // Final bill handling: whatever POS reports, Net Amount is stamped and
    // points are earned on it
    //
    // Each household is Silver (2%): Last 12 Month Spend 5,000.
    // =====================================================================

    /** No redemption: Net Amount is the Amount. 6,000 x 2% = 120 points. */
    @IsTest
    static void aBillWithNoRedemptionEarnsOnTheFullAmount() {
        Account acct = household('No Redemption', 5000);
        insert acct;
        Transaction_Record__c bill = purchase(acct.Id, 6000.00, 0);

        Test.startTest();
        insert bill;
        Test.stopTest();

        Transaction_Record__c saved = savedBill(bill.Id);
        Assert.areEqual(0, saved.Points_Redeemed__c, 'No points reported: 0');
        Assert.areEqual(0, saved.Voucher_Discount__c, 'No voucher reported: 0');
        Assert.areEqual(6000, saved.Net_Amount__c, 'Net Amount = Amount');
        Assert.areEqual(120, earnedOn(bill.Id), '6,000 x 2% = 120');
        Assert.areEqual(120, loyaltyFor(acct.Id).Points_Balance__c, 'Balance 0 + 120');
    }

    /** Points only: 6,000 - 200 points = 5,800; x 2% = 116, so 110 points. */
    @IsTest
    static void aBillWithPointsOnlyEarnsOnTheAmountAfterThePoints() {
        Account acct = household('Points Only', 5000);
        insert acct;
        withPoints(acct.Id, 300);
        Transaction_Record__c bill = purchase(acct.Id, 6000.00, 0);
        bill.Points_Redeemed__c = 200;

        Test.startTest();
        insert bill;
        Test.stopTest();

        Transaction_Record__c saved = savedBill(bill.Id);
        Assert.areEqual(0, saved.Voucher_Discount__c, 'No voucher reported: 0');
        Assert.isNull(saved.Gift_Voucher__c, 'No voucher linked');
        Assert.areEqual(5800, saved.Net_Amount__c, '6,000 - 200 points');
        Assert.areEqual(110, earnedOn(bill.Id), '5,800 x 2% = 116, down to 110');
        Assert.areEqual(210, loyaltyFor(acct.Id).Points_Balance__c, '300 - 200 + 110');
    }

    /** Gift voucher only: 6,000 - 500 voucher = 5,500; x 2% = 110 points. */
    @IsTest
    static void aBillWithAVoucherOnlyEarnsOnTheAmountAfterTheVoucher() {
        Account acct = household('Voucher Only', 5000);
        insert acct;
        Gift_Voucher__c voucher = activeVoucher(acct.Id, 'TTH-VOUCHER-ONLY');
        Transaction_Record__c bill = withVoucher(purchase(acct.Id, 6000.00, 0), 'TTH-VOUCHER-ONLY', 500);

        Test.startTest();
        // System mode, like GiftVoucherRedemptionTest: the result must not depend on the test user's field access.
        insert as system bill;
        Test.stopTest();

        Transaction_Record__c saved = savedBill(bill.Id);
        Assert.areEqual(0, saved.Points_Redeemed__c, 'No points reported: 0');
        Assert.areEqual(voucher.Id, saved.Gift_Voucher__c, 'The voucher is linked');
        Assert.areEqual(5500, saved.Net_Amount__c, '6,000 - 500 voucher');
        Assert.areEqual(110, earnedOn(bill.Id), '5,500 x 2% = 110');
        Assert.areEqual(110, loyaltyFor(acct.Id).Points_Balance__c, 'Balance 0 + 110');
        Assert.areEqual('Redeemed', [SELECT Status__c FROM Gift_Voucher__c WHERE Id = :voucher.Id WITH SYSTEM_MODE].Status__c, 'The voucher is used up');
    }

    /** Both: 6,000 - 500 voucher - 200 points = 5,300; x 2% = 106, so 100 points. */
    @IsTest
    static void aBillWithAVoucherAndPointsEarnsOnTheAmountAfterBoth() {
        Account acct = household('Voucher And Points', 5000);
        insert acct;
        withPoints(acct.Id, 300);
        Gift_Voucher__c voucher = activeVoucher(acct.Id, 'TTH-VOUCHER-BOTH');
        Transaction_Record__c bill = withVoucher(purchase(acct.Id, 6000.00, 0), 'TTH-VOUCHER-BOTH', 500);
        bill.Points_Redeemed__c = 200;

        Test.startTest();
        // System mode, like GiftVoucherRedemptionTest: the result must not depend on the test user's field access.
        insert as system bill;
        Test.stopTest();

        Transaction_Record__c saved = savedBill(bill.Id);
        Assert.areEqual(voucher.Id, saved.Gift_Voucher__c, 'The voucher is linked');
        Assert.areEqual(5300, saved.Net_Amount__c, '6,000 - 500 voucher - 200 points');
        Assert.areEqual(100, earnedOn(bill.Id), '5,300 x 2% = 106, down to 100');
        Assert.areEqual(200, loyaltyFor(acct.Id).Points_Balance__c, '300 - 200 + 100');
    }

    /**
     * Loyalty Bypass > Disable Earning (the CASA history load): the bill is
     * saved and stamped, the spend still counts, but no points move.
     */
    @IsTest
    static void disableEarningSavesTheBillWithoutAnyPoints() {
        Account acct = household('Historical Load', 5000);
        insert acct;
        insert new Loyalty_Bypass__c(SetupOwnerId = UserInfo.getUserId(), Disable_Earning__c = true);
        Transaction_Record__c bill = purchase(acct.Id, 6000.00, 0);

        Test.startTest();
        insert bill;
        Test.stopTest();

        Assert.areEqual(6000, savedBill(bill.Id).Net_Amount__c, 'The bill is still stamped');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Loyalty_Transaction__c WHERE Transaction_Record__c = :bill.Id WITH SYSTEM_MODE],
            'No loyalty event for the bill'
        );
        Assert.areEqual(6000.00, reload(acct.Id).Last_12M_Spend__c, 'The spend still counts towards the tier');
    }

    /** A full trigger chunk of households is recalculated in one go. */
    @IsTest
    static void recalculatesEveryHouseholdInABulkInsert() {
        List<Account> households = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            households.add(household('Bulk Bill ' + i, null));
        }
        insert households;

        List<Transaction_Record__c> purchases = new List<Transaction_Record__c>();
        for (Account acct : households) {
            purchases.add(purchase(acct.Id, 10000.00, 0));
        }

        Test.startTest();
        insert purchases;
        Test.stopTest();

        Assert.areEqual(
            200,
            [
                SELECT COUNT()
                FROM Account
                WHERE Id IN :households
                  AND Last_12M_Spend__c = 10000
                  AND Customer_Tier__c = 'Gold'
            ],
            'Every household in the insert should be recalculated'
        );
    }
}