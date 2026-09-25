/**
 * Tests for the real-time Last 12 Month Spend recalculation done by
 * TransactionTriggerHandler when a bill is inserted.
 *
 * Loyalty earning itself is covered by LoyaltyEngineTest; the nightly
 * recalculation by ShreeHariTrailingSpendBatchTest.
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
        Assert.areEqual(
            200,
            [SELECT Points_Balance__c FROM Loyalty_Record__c WHERE Account__c = :acct.Id].Points_Balance__c,
            '140 + 20 at Silver, then 40 at Gold'
        );
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
