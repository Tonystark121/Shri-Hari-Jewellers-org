/**
 * Tests for the last-12-months spend recalculation.
 *
 * The assertions are on what the business cares about — the figure on the
 * household and the tier the formula derives from it.
 *
 * The one guarantee that cannot be read off the data directly is that the job
 * costs a single query per chunk however wide the chunk is, so that is checked
 * by calling execute() with a full scope and counting queries. That also works
 * around a limitation of Apex testing: a batch launched from a test method
 * runs only its first chunk, so queueing hundreds of households would prove
 * nothing about the chunks after the first.
 */
@IsTest
private class ShreeHariTrailingSpendBatchTest {

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

    private static void runBatch() {
        Test.startTest();
        Database.executeBatch(new ShreeHariTrailingSpendBatch(), 200);
        Test.stopTest();
    }

    // =====================================================================
    // Tier slabs
    // =====================================================================

    @IsTest
    static void assignsEachTierFromTheLast365DaysOfBilling() {
        Map<String, Decimal> spendByName = new Map<String, Decimal>{
            'Silver House' => 5000.00,
            'Gold House' => 10000.00,
            'Platinum House' => 30000.00,
            'Diamond House' => 150000.00
        };
        Map<String, String> expectedTier = new Map<String, String>{
            'Silver House' => 'Silver',
            'Gold House' => 'Gold',
            'Platinum House' => 'Platinum',
            'Diamond House' => 'Diamond'
        };

        List<Account> households = new List<Account>();
        for (String name : spendByName.keySet()) {
            households.add(household(name, null));
        }
        insert households;

        List<Transaction_Record__c> purchases = new List<Transaction_Record__c>();
        for (Account acct : households) {
            // Split across two bills, so the job has to sum rather than read one.
            purchases.add(purchase(acct.Id, spendByName.get(acct.Name) * 0.4, 300));
            purchases.add(purchase(acct.Id, spendByName.get(acct.Name) * 0.6, 10));
        }
        insert purchases;

        runBatch();

        for (Account acct : [
            SELECT Name, Last_12M_Spend__c, Customer_Tier__c
            FROM Account
            WHERE Id IN :households
        ]) {
            Assert.areEqual(
                spendByName.get(acct.Name).setScale(2),
                acct.Last_12M_Spend__c,
                acct.Name + ' should carry its full windowed spend'
            );
            Assert.areEqual(
                expectedTier.get(acct.Name),
                acct.Customer_Tier__c,
                acct.Name + ' landed in the wrong slab'
            );
        }
    }

    @IsTest
    static void tierFormulaHoldsAtEverySlabBoundary() {
        Map<Decimal, String> expected = new Map<Decimal, String>{
            0.00 => 'Silver',
            7500.00 => 'Silver',
            7500.01 => 'Gold',
            25000.00 => 'Gold',
            25000.01 => 'Platinum',
            100000.00 => 'Platinum',
            100000.01 => 'Diamond'
        };

        List<Account> households = new List<Account>();
        for (Decimal spend : expected.keySet()) {
            households.add(household('Boundary ' + spend, spend));
        }
        // A household with no figure at all must read as the entry tier.
        households.add(household('Never Purchased', null));
        insert households;

        for (Account acct : [
            SELECT Name, Last_12M_Spend__c, Customer_Tier__c
            FROM Account
            WHERE Id IN :households
        ]) {
            String want = acct.Last_12M_Spend__c == null
                ? 'Silver'
                : expected.get(acct.Last_12M_Spend__c);
            Assert.areEqual(want, acct.Customer_Tier__c, acct.Name + ' sits in the wrong slab');
        }
    }

    // =====================================================================
    // The moving window
    // =====================================================================

    @IsTest
    static void ignoresBillingOlderThanTheWindow() {
        Account acct = household('Lapsed Spender', null);
        insert acct;
        insert new List<Transaction_Record__c>{
            purchase(acct.Id, 200000.00, 400), // well outside the window
            purchase(acct.Id, 366.00, 366),    // a day past the edge
            purchase(acct.Id, 5000.00, 30)     // inside
        };

        runBatch();

        Account refreshed = reload(acct.Id);
        Assert.areEqual(
            5000.00,
            refreshed.Last_12M_Spend__c,
            'Only billing inside the 365 day window counts'
        );
        Assert.areEqual('Silver', refreshed.Customer_Tier__c, 'A lapsed Diamond falls back to Silver');
        Assert.areEqual(
            205366.00,
            [SELECT CLV__c FROM Account WHERE Id = :acct.Id].CLV__c,
            'Lifetime CLV still counts every purchase'
        );
    }

    /**
     * The window runs up to and including today, so a bill raised this
     * morning has to count. A store that sells to a customer sitting at the
     * counter and then quotes them a tier that ignores the sale has the
     * programme wrong.
     */
    @IsTest
    static void countsBillingRaisedToday() {
        Account acct = household('Bought This Morning', null);
        insert acct;
        insert purchase(acct.Id, 30000.00, 0);

        runBatch();

        Account refreshed = reload(acct.Id);
        Assert.areEqual(
            30000.00,
            refreshed.Last_12M_Spend__c,
            'Billing raised today sits inside the last 365 days'
        );
        Assert.areEqual(
            'Platinum',
            refreshed.Customer_Tier__c,
            'The tier should reflect billing raised today'
        );
    }

    @IsTest
    static void demotesAHouseholdWhoseWindowHasEmptied() {
        // Yesterday's figure, with the purchase behind it now aged out.
        Account acct = household('Aged Out', 150000.00);
        insert acct;
        insert purchase(acct.Id, 150000.00, 400);

        runBatch();

        Account refreshed = reload(acct.Id);
        Assert.areEqual(0.00, refreshed.Last_12M_Spend__c, 'A stale figure should be cleared');
        Assert.areEqual('Silver', refreshed.Customer_Tier__c, 'An empty window is the entry tier');
    }

    @IsTest
    static void correctsAFigureThatDriftedOutOfDate() {
        Account acct = household('Drifted', 999.00);
        insert acct;
        insert purchase(acct.Id, 40000.00, 5);

        runBatch();

        Account refreshed = reload(acct.Id);
        Assert.areEqual(40000.00, refreshed.Last_12M_Spend__c, 'The figure is rebuilt from the transactions');
        Assert.areEqual('Platinum', refreshed.Customer_Tier__c, '40,000 sits in the Platinum slab');
    }

    @IsTest
    static void countsReturnsAgainstTheWindow() {
        Account acct = household('Returned Goods', null);
        insert acct;
        insert new List<Transaction_Record__c>{
            purchase(acct.Id, 30000.00, 20),
            purchase(acct.Id, -25000.00, 10) // return credited back at the POS
        };

        runBatch();

        Account refreshed = reload(acct.Id);
        Assert.areEqual(5000.00, refreshed.Last_12M_Spend__c, 'A return reduces the windowed spend');
        Assert.areEqual('Silver', refreshed.Customer_Tier__c, 'The tier follows the net figure');
    }

    // =====================================================================
    // Volume
    // =====================================================================

    @IsTest
    static void recalculatesAFullChunkOnASingleQuery() {
        Integer chunkSize = 200;

        List<Account> households = new List<Account>();
        for (Integer i = 0; i < chunkSize; i++) {
            households.add(household('Bulk ' + i, null));
        }
        insert households;

        List<Transaction_Record__c> purchases = new List<Transaction_Record__c>();
        for (Account acct : households) {
            purchases.add(purchase(acct.Id, 6000.00, 100));
            purchases.add(purchase(acct.Id, 6000.00, 50));
        }
        insert purchases;

        List<Account> scope = [
            SELECT Id, Last_12M_Spend__c
            FROM Account
            WHERE Id IN :households
        ];

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        new ShreeHariTrailingSpendBatch().execute(null, scope);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(
            1,
            queriesUsed,
            'A chunk should cost one aggregate query however many households it holds'
        );
        Assert.areEqual(
            chunkSize,
            [
                SELECT COUNT()
                FROM Account
                WHERE Id IN :households
                  AND Last_12M_Spend__c = 12000
                  AND Customer_Tier__c = 'Gold'
            ],
            'Every household in the chunk should be recalculated'
        );
    }

    /**
     * The skip-if-unchanged rule lives inside execute() now, so it is checked
     * through the one trace it leaves in the data: a household that has never
     * purchased keeps a blank figure instead of being written to 0.00. A job
     * that wrote every row it scanned would leave zero there.
     */
    @IsTest
    static void leavesAloneTheHouseholdsWhoseFigureHasNotMoved() {
        Account unchanged = household('Unchanged', 8000.00);
        Account moved = household('Moved', 8000.00);
        Account cleared = household('Cleared', 8000.00);
        Account neverPurchased = household('Never Purchased', null);
        insert new List<Account>{ unchanged, moved, cleared, neverPurchased };

        insert new List<Transaction_Record__c>{
            purchase(unchanged.Id, 8000.00, 30), // still the stored figure
            purchase(moved.Id, 9000.00, 30)      // a different figure
            // 'Cleared' and 'Never Purchased' have nothing inside the window.
        };

        runBatch();

        Assert.areEqual(
            8000.00,
            reload(unchanged.Id).Last_12M_Spend__c,
            'A figure that has not moved should survive the run unchanged'
        );
        Assert.areEqual(
            9000.00,
            reload(moved.Id).Last_12M_Spend__c,
            'A figure that has moved should be rewritten'
        );
        Assert.areEqual(
            0.00,
            reload(cleared.Id).Last_12M_Spend__c,
            'A household whose window has emptied should be zeroed'
        );
        Assert.isNull(
            reload(neverPurchased.Id).Last_12M_Spend__c,
            'A household that never purchased should stay blank rather than be written to zero'
        );
    }

    // =====================================================================
    // Schedulable entry point
    // =====================================================================

    /**
     * The job is scheduled from Setup, not from Apex, so there is no cron
     * expression to assert. What still has to hold is that the entry point
     * Setup calls actually launches the batch — otherwise a schedule that
     * looks healthy in Setup would quietly do nothing every night.
     */
    @IsTest
    static void schedulableEntryPointLaunchesTheBatch() {
        Account acct = household('Scheduled Run', null);
        insert acct;
        insert purchase(acct.Id, 30000.00, 15);

        Test.startTest();
        new ShreeHariTrailingSpendBatch().execute((SchedulableContext) null);
        Test.stopTest();

        Assert.areEqual(
            30000.00,
            reload(acct.Id).Last_12M_Spend__c,
            'The scheduled entry point should have run the recalculation'
        );
        Assert.areEqual(
            'Platinum',
            reload(acct.Id).Customer_Tier__c,
            'The tier should follow from the recalculated figure'
        );
    }
}
