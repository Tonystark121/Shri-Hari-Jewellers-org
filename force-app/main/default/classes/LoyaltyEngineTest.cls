/**
 * Tests for the loyalty programme.
 *
 * Wherever the specification works an example through, the test uses that
 * example's own numbers, so a failure points at a line in the document rather
 * than at an invented scenario.
 *
 * Everything runs through the trigger, because processEarn() is the only way
 * into the engine. Account.Customer_Tier__c is a formula over Last_12M_Spend__c
 * that the nightly batch maintains, so the tests set Last_12M_Spend__c directly
 * to put a household in a known tier — which is what the batch would have done
 * overnight.
 */
@IsTest
private class LoyaltyEngineTest {

    private static Integer billCounter = 0;

    // =====================================================================
    // Helpers
    // =====================================================================

    /** A household whose last 12 months of billing puts it in a known tier. */
    private static Account household(String name, Decimal last12MonthSpend) {
        return new Account(Name = name, Last_12M_Spend__c = last12MonthSpend);
    }

    private static Transaction_Record__c bill(Id accountId, Decimal amount, Boolean redeemPoints) {
        billCounter++;
        return new Transaction_Record__c(
            Account__c = accountId,
            Amount__c = amount,
            Redeem_Points__c = redeemPoints,
            Bill_Number__c = 'BILL-' + String.valueOf(billCounter).leftPad(6, '0'),
            Transaction_Date__c = Datetime.now()
        );
    }

    private static Loyalty_Record__c openingBalance(Id accountId, Integer points) {
        return new Loyalty_Record__c(
            Account__c = accountId,
            Points_Balance__c = points,
            Total_Points_Earned__c = points,
            Total_Points_Redeemed__c = 0
        );
    }

    private static Loyalty_Record__c loyaltyFor(Id accountId) {
        return [
            SELECT Id, Points_Balance__c, Total_Points_Earned__c,
                   Total_Points_Redeemed__c, Last_Transaction_Date__c,
                   Last_Transaction_Type__c
            FROM Loyalty_Record__c
            WHERE Account__c = :accountId
            LIMIT 1
        ];
    }

    // =====================================================================
    // Earning
    // =====================================================================

    /**
     * The document's first worked example: a 2,000 purchase discounted to
     * 1,600 earns 1600 x 2% = 32 points at Silver.
     */
    @IsTest
    static void testEarnPoints() {
        Account acct = household('First Purchase', null);
        insert acct;

        Test.startTest();
        insert bill(acct.Id, 1600, false);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(32, loyalty.Points_Balance__c, '1600 at Silver 2% earns 32 points');
        Assert.areEqual(32, loyalty.Total_Points_Earned__c, 'Lifetime earned should match');
        Assert.areEqual(0, loyalty.Total_Points_Redeemed__c, 'Nothing was redeemed');
        Assert.areEqual(Date.today(), loyalty.Last_Transaction_Date__c, 'Stamped with the bill date');
        Assert.areEqual('Earning', loyalty.Last_Transaction_Type__c, 'Points earned, nothing redeemed');
    }

    /**
     * Each tier's percentage, taken from the slab table. A household is put
     * in the tier by its last 12 months of billing, then billed 10,000.
     */
    @IsTest
    static void testEarnRatePerTier() {
        Account silver = household('Silver', 5000);        // 2%
        Account gold = household('Gold', 10000);           // 4%
        Account platinum = household('Platinum', 30000);   // 7%
        Account diamond = household('Diamond', 150000);    // 10%
        insert new List<Account>{ silver, gold, platinum, diamond };

        Test.startTest();
        insert new List<Transaction_Record__c>{
            bill(silver.Id, 10000, false),
            bill(gold.Id, 10000, false),
            bill(platinum.Id, 10000, false),
            bill(diamond.Id, 10000, false)
        };
        Test.stopTest();

        Assert.areEqual(200, loyaltyFor(silver.Id).Points_Balance__c, 'Silver earns 2%');
        Assert.areEqual(400, loyaltyFor(gold.Id).Points_Balance__c, 'Gold earns 4%');
        Assert.areEqual(700, loyaltyFor(platinum.Id).Points_Balance__c, 'Platinum earns 7%');
        Assert.areEqual(1000, loyaltyFor(diamond.Id).Points_Balance__c, 'Diamond earns 10%');
    }

    /**
     * The tier is the one the household held *before* this bill. In the
     * document the third purchase still earns at Silver even though it pushes
     * the running total into Gold; only the fourth purchase earns 4%. Here
     * the household is already Gold on 8,800 of billing, so its next bill of
     * 2,400 earns 2400 x 4% = 96.
     */
    @IsTest
    static void testEarnsAtTheTierHeldBeforeTheBill() {
        Account acct = household('Fourth Purchase', 8800);
        insert acct;
        insert openingBalance(acct.Id, 176);

        Test.startTest();
        insert bill(acct.Id, 2400, false);
        Test.stopTest();

        Assert.areEqual(
            272,
            loyaltyFor(acct.Id).Points_Balance__c,
            'The document: 2400 x 4% = 96, on top of the 176 already held'
        );
    }

    /** Points accrue per whole Rs 100; the remainder earns nothing. */
    @IsTest
    static void testPartialHundredsAreRoundedDown() {
        Account acct = household('Rounding', null);
        insert acct;

        Test.startTest();
        insert bill(acct.Id, 3099, false);
        Test.stopTest();

        Assert.areEqual(
            60,
            loyaltyFor(acct.Id).Points_Balance__c,
            '3,099 at 2% is 30 whole hundreds x 2, not 61.98'
        );
    }

    /** A household with no billing history earns at the entry tier. */
    @IsTest
    static void testUnknownTierEarnsAtSilver() {
        Account acct = household('Brand New', null);
        insert acct;

        Test.startTest();
        insert bill(acct.Id, 5000, false);
        Test.stopTest();

        Assert.areEqual(100, loyaltyFor(acct.Id).Points_Balance__c, 'Entry tier is Silver at 2%');
    }

    /** A bill of nothing earns nothing rather than failing. */
    @IsTest
    static void testZeroValueBillEarnsNothing() {
        Account acct = household('Zero Bill', 5000);
        insert acct;

        Test.startTest();
        insert bill(acct.Id, 0, true);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(0, loyalty.Points_Balance__c, 'Nothing billed, nothing earned');
        Assert.areEqual(0, loyalty.Total_Points_Redeemed__c, 'And nothing redeemed');
        Assert.isNull(loyalty.Last_Transaction_Type__c, 'Nothing earned or redeemed leaves the type blank');
    }

    @IsTest
    static void testEarningIsBulkSafe() {
        List<Account> households = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            households.add(household('Bulk ' + i, 10000)); // Gold, 4%
        }
        insert households;

        List<Transaction_Record__c> bills = new List<Transaction_Record__c>();
        for (Account acct : households) {
            bills.add(bill(acct.Id, 5000, false));
        }

        Test.startTest();
        insert bills;
        Test.stopTest();

        Assert.areEqual(
            200,
            [
                SELECT COUNT()
                FROM Loyalty_Record__c
                WHERE Account__c IN :households AND Points_Balance__c = 200
            ],
            'Every household in the batch should have earned 5000 x 4% = 200'
        );
    }

    // =====================================================================
    // Redemption at the till
    // =====================================================================

    /**
     * The document's "Method 2": the customer holds 112 points and ticks the
     * box against a 3,200 bill, so all 112 are spent and the bill earns on
     * 3,088. The document writes the result as "3088 X 2% = 61.76 (60)" —
     * rounded down to whole hundreds of rupees — and carries 60 forward.
     */
    @IsTest
    static void testRedeemTickedSpendsTheBalanceAndEarnsOnTheNetAmount() {
        Account acct = household('Method Two', 5600);
        insert acct;
        insert openingBalance(acct.Id, 112);

        Test.startTest();
        insert bill(acct.Id, 3200, true);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(
            60,
            loyalty.Points_Balance__c,
            '112 spent, 60 earned on the net 3,088: the document carries 60 forward'
        );
        Assert.areEqual(172, loyalty.Total_Points_Earned__c, 'Lifetime earned is 112 + 60');
        Assert.areEqual(112, loyalty.Total_Points_Redeemed__c, 'Lifetime redeemed is the 112 spent');
        Assert.areEqual('Redemption', loyalty.Last_Transaction_Type__c, 'Points were redeemed on this bill');
    }

    /** Leaving the box unticked earns on the whole bill and spends nothing. */
    @IsTest
    static void testRedeemUntickedLeavesTheBalanceAlone() {
        Account acct = household('Saving Up', 5000);
        insert acct;
        insert openingBalance(acct.Id, 500);

        Test.startTest();
        insert bill(acct.Id, 3200, false);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(
            564,
            loyalty.Points_Balance__c,
            'The 500 is untouched and the full 3,200 earns 64 at Silver'
        );
        Assert.areEqual(0, loyalty.Total_Points_Redeemed__c, 'Nothing was redeemed');
    }

    /**
     * Ticking the box with fewer than 100 points is not an error: the
     * customer pays in full and keeps them. The document is explicit that
     * 99 points cannot be redeemed.
     */
    @IsTest
    static void testRedeemTickedBelowMinimumProceedsWithoutRedeeming() {
        Account acct = household('Just Short', 5000);
        insert acct;
        insert openingBalance(acct.Id, 99);

        Test.startTest();
        insert bill(acct.Id, 3200, true);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(
            163,
            loyalty.Points_Balance__c,
            '99 kept, and the full 3,200 earns 64 at Silver'
        );
        Assert.areEqual(0, loyalty.Total_Points_Redeemed__c, 'Nothing was redeemed');
        Assert.areEqual('Earning', loyalty.Last_Transaction_Type__c, 'A refused redemption is an Earning');
    }

    /**
     * The document allows a balance of 102 to be redeemed in full, so the
     * minimum is a floor on the balance, not a rounding step.
     */
    @IsTest
    static void testBalanceOfOneHundredAndTwoIsSpentInFull() {
        Account acct = household('Exactly Over', 5000);
        insert acct;
        insert openingBalance(acct.Id, 102);

        Test.startTest();
        insert bill(acct.Id, 3200, true);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(102, loyalty.Total_Points_Redeemed__c, 'All 102 points are spent');
        Assert.areEqual(
            60,
            loyalty.Points_Balance__c,
            '3200 - 102 = 3098, which is 30 whole hundreds x 2%'
        );
    }

    /** Points cannot exceed the bill; a bill never goes negative. */
    @IsTest
    static void testRedemptionIsCappedAtTheBillAmount() {
        Account acct = household('Points Rich', 5000);
        insert acct;
        insert openingBalance(acct.Id, 5000);

        Test.startTest();
        insert bill(acct.Id, 3200, true);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(
            1800,
            loyalty.Points_Balance__c,
            'Only the 3,200 the bill can absorb is spent; the rest stays on the balance'
        );
        Assert.areEqual(3200, loyalty.Total_Points_Redeemed__c, 'Lifetime redeemed is the 3,200 applied');
    }

    /** A bill settled entirely in points earns nothing. */
    @IsTest
    static void testBillSettledEntirelyInPointsEarnsNothing() {
        Account acct = household('All Points', 5000);
        insert acct;
        insert openingBalance(acct.Id, 900);

        Test.startTest();
        insert bill(acct.Id, 800, true);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(100, loyalty.Points_Balance__c, '800 of the 900 points settled the bill');
        Assert.areEqual(900, loyalty.Total_Points_Earned__c, 'A bill paid entirely in points earns nothing');
        Assert.areEqual('Redemption', loyalty.Last_Transaction_Type__c, 'Redeemed with nothing earned is still a Redemption');
    }

    /**
     * A bill too small to absorb the 100 point minimum cannot be redeemed
     * against, even when the balance itself is healthy.
     */
    @IsTest
    static void testBillSmallerThanTheMinimumCannotBeRedeemedAgainst() {
        Account acct = household('Tiny Bill', 5000);
        insert acct;
        insert openingBalance(acct.Id, 500);

        Test.startTest();
        insert bill(acct.Id, 50, true);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(500, loyalty.Points_Balance__c, 'The balance is untouched');
        Assert.areEqual(0, loyalty.Total_Points_Redeemed__c, 'A 50 rupee bill cannot carry a 100 point redemption');
    }

    // =====================================================================
    // Last Transaction Type
    // =====================================================================

    /** A later bill on the same date replaces the type. */
    @IsTest
    static void testSameDayBillUpdatesTransactionType() {
        Account acct = household('Same Day', 5000);
        insert acct;
        Loyalty_Record__c opening = openingBalance(acct.Id, 500);
        opening.Last_Transaction_Date__c = Date.today();
        opening.Last_Transaction_Type__c = 'Earning';
        insert opening;

        Test.startTest();
        insert bill(acct.Id, 3200, true);
        Test.stopTest();

        Assert.areEqual(
            'Redemption',
            loyaltyFor(acct.Id).Last_Transaction_Type__c,
            'The latest bill on the same date sets the type'
        );
    }

    /** A back-dated bill changes neither the date nor the type. */
    @IsTest
    static void testBackDatedBillLeavesTransactionTypeAlone() {
        Account acct = household('Back Dated', 5000);
        insert acct;
        Loyalty_Record__c opening = openingBalance(acct.Id, 500);
        opening.Last_Transaction_Date__c = Date.today();
        opening.Last_Transaction_Type__c = 'Redemption';
        insert opening;

        Transaction_Record__c oldBill = bill(acct.Id, 3200, false);
        oldBill.Transaction_Date__c = Datetime.now().addDays(-10);

        Test.startTest();
        insert oldBill;
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(Date.today(), loyalty.Last_Transaction_Date__c, 'The later date is kept');
        Assert.areEqual('Redemption', loyalty.Last_Transaction_Type__c, 'The type still matches the later date');
    }

    // =====================================================================
    // Data integrity and plumbing
    // =====================================================================

    /**
     * The balance is a household total, so two loyalty records for one
     * household is a state the engine refuses to guess its way through.
     */
    @IsTest
    static void testDuplicateLoyaltyRecordsAreRejected() {
        Account acct = household('Double Enrolled', 5000);
        insert acct;
        insert new List<Loyalty_Record__c>{
            openingBalance(acct.Id, 100),
            openingBalance(acct.Id, 250)
        };

        String message;
        Test.startTest();
        try {
            insert bill(acct.Id, 3200, false);
            Assert.fail('A household with two loyalty records should have been rejected');
        } catch (DmlException e) {
            message = e.getDmlMessage(0);
        }
        Test.stopTest();

        Assert.isTrue(
            message.contains('Multiple Loyalty Records'),
            'The error should name the problem. Got: ' + message
        );
    }

    /** Every tier in the slab table has a rate configured. */
    @IsTest
    static void testEveryTierHasAnEarningRate() {
        Map<String, Decimal> rates = LoyaltyEngine.earningRates();

        Assert.areEqual(2, rates.get('Silver'), 'Silver is 2%');
        Assert.areEqual(4, rates.get('Gold'), 'Gold is 4%');
        Assert.areEqual(7, rates.get('Platinum'), 'Platinum is 7%');
        Assert.areEqual(10, rates.get('Diamond'), 'Diamond is 10%');
    }
}
