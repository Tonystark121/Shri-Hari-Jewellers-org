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
 *
 * Only points held in earning lots (Earn rows on Loyalty_Transaction__c) can
 * be redeemed, so a household that is to redeem is given its points through
 * withPoints(), which backs the balance with a lot.
 *
 * Every Account gets its Loyalty Record from the "Account: Create Loyalty
 * Record" flow as soon as it is inserted, so tests set an opening balance on
 * that record (openingBalance() + update) rather than inserting their own.
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

    /**
     * The Loyalty Record the Account flow created for this household, with
     * an opening balance of `points`. Not saved: the caller updates it.
     */
    private static Loyalty_Record__c openingBalance(Id accountId, Integer points) {
        Loyalty_Record__c loyalty = [
            SELECT Id, Account__c
            FROM Loyalty_Record__c
            WHERE Account__c = :accountId
            LIMIT 1
        ];
        loyalty.Points_Balance__c = points;
        loyalty.Total_Points_Earned__c = points;
        loyalty.Total_Points_Redeemed__c = 0;
        return loyalty;
    }

    /**
     * An open earning lot of `points`, credited on `creditDate` and valid
     * for the standard 365 days, as the engine would have saved it.
     */
    private static Loyalty_Transaction__c earnedLot(Id loyaltyId, Integer points, Date creditDate) {
        return new Loyalty_Transaction__c(
            Loyalty_Record__c = loyaltyId,
            Transaction_Type__c = 'Earn',
            Status__c = 'Active',
            Points_Earned__c = points,
            Remaining_Points__c = points,
            Credit_Date__c = creditDate,
            Expiry_Date__c = creditDate.addDays(365),
            Earning_Tier__c = 'Silver',
            Earning_Rate__c = 2
        );
    }

    /** A household holding `points`, all in one lot earned 30 days ago. */
    private static Loyalty_Record__c withPoints(Id accountId, Integer points) {
        Loyalty_Record__c loyalty = openingBalance(accountId, points);
        update loyalty;
        insert earnedLot(loyalty.Id, points, Date.today().addDays(-30));
        return loyalty;
    }

    private static Loyalty_Record__c loyaltyFor(Id accountId) {
        return [
            SELECT Id, Points_Balance__c, Total_Points_Earned__c,
                   Total_Points_Redeemed__c, Last_Transaction_Date__c
            FROM Loyalty_Record__c
            WHERE Account__c = :accountId
            LIMIT 1
        ];
    }

    /** Ledger rows for a household, oldest credit first. */
    private static List<Loyalty_Transaction__c> ledgerFor(Id accountId) {
        return [
            SELECT Id, Transaction_Type__c, Status__c, Points_Earned__c,
                   Remaining_Points__c, Credit_Date__c, Expiry_Date__c,
                   Earning_Tier__c, Earning_Rate__c, Net_Loyalty_Amount__c,
                   Redemption_Value__c, Transaction_Record__c, Processed_Date__c
            FROM Loyalty_Transaction__c
            WHERE Loyalty_Record__r.Account__c = :accountId
            WITH SYSTEM_MODE
            ORDER BY Credit_Date__c ASC NULLS LAST, CreatedDate ASC, Id ASC
        ];
    }

    private static Loyalty_Transaction__c ledgerRow(Id accountId, String transactionType) {
        return [
            SELECT Id, Transaction_Type__c, Status__c, Points_Earned__c,
                   Remaining_Points__c, Credit_Date__c, Expiry_Date__c,
                   Earning_Tier__c, Earning_Rate__c, Net_Loyalty_Amount__c,
                   Redemption_Value__c, Transaction_Record__c, Processed_Date__c
            FROM Loyalty_Transaction__c
            WHERE Loyalty_Record__r.Account__c = :accountId
            AND Transaction_Type__c = :transactionType
            AND Transaction_Record__c != null
            WITH SYSTEM_MODE
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
        update openingBalance(acct.Id, 176);

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
        Assert.areEqual(0, ledgerFor(acct.Id).size(), 'No zero-point ledger events');
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
        withPoints(acct.Id, 112);

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
        Assert.areEqual(Date.today(), loyalty.Last_Transaction_Date__c, 'The bill earned points, so it is stamped');
    }

    /**
     * The "Method 2" bill carries its own figures: 112 points redeemed and a
     * net amount of 3,088. A bill with no redemption keeps Net Amount equal
     * to Amount.
     */
    @IsTest
    static void testBillShowsPointsRedeemedAndNetAmount() {
        Account acct = household('Method Two Bill', 5600);
        insert acct;
        withPoints(acct.Id, 112);

        Transaction_Record__c redeeming = bill(acct.Id, 3200, true);
        Transaction_Record__c plain = bill(acct.Id, 1500, false);
        plain.Transaction_Date__c = Datetime.now().addMinutes(1);

        Test.startTest();
        insert new List<Transaction_Record__c>{ redeeming, plain };
        Test.stopTest();

        Map<Id, Transaction_Record__c> saved = new Map<Id, Transaction_Record__c>([
            SELECT Id, Points_Redeemed__c, Net_Amount__c, Voucher_Discount__c
            FROM Transaction_Record__c
            WHERE Account__c = :acct.Id
            WITH SYSTEM_MODE
        ]);
        Assert.areEqual(112, saved.get(redeeming.Id).Points_Redeemed__c, 'All 112 points were spent on the bill');
        Assert.areEqual(3088, saved.get(redeeming.Id).Net_Amount__c, '3,200 - 112');
        Assert.areEqual(0, saved.get(redeeming.Id).Voucher_Discount__c, 'No voucher on this bill');
        Assert.areEqual(0, saved.get(plain.Id).Points_Redeemed__c, 'Nothing redeemed');
        Assert.areEqual(1500, saved.get(plain.Id).Net_Amount__c, 'Net Amount equals Amount without a redemption');
    }

    /**
     * The same "Method 2" bill, read from the ledger: one Redeemed event for
     * the 112 spent, one Earn event (the new lot) for the 60 earned on
     * 3,088, and the lot that held the 112 emptied and marked Redeemed.
     */
    @IsTest
    static void testRedemptionAndEarningAreBothWrittenToTheLedger() {
        Account acct = household('Method Two Ledger', 5600);
        insert acct;
        withPoints(acct.Id, 112);
        Transaction_Record__c purchase = bill(acct.Id, 3200, true);

        Test.startTest();
        insert purchase;
        Test.stopTest();

        List<Loyalty_Transaction__c> ledger = ledgerFor(acct.Id);
        Assert.areEqual(3, ledger.size(), 'Opening lot + Redeemed event + new Earn lot');

        Loyalty_Transaction__c openingLot = ledger[0];
        Assert.areEqual(0, openingLot.Remaining_Points__c, 'All 112 were spent');
        Assert.areEqual('Redeemed', openingLot.Status__c, 'An emptied lot is Redeemed');
        Assert.areEqual(112, openingLot.Points_Earned__c, 'The original points are kept for history');

        Loyalty_Transaction__c redeemed = ledgerRow(acct.Id, 'Redeemed');
        Assert.areEqual('Redeemed', redeemed.Status__c, 'Redeemed event status');
        Assert.areEqual(112, redeemed.Points_Earned__c, 'Points spent');
        Assert.areEqual(0, redeemed.Remaining_Points__c, 'A redemption is not a lot');
        Assert.areEqual(112, redeemed.Redemption_Value__c, 'Rs 1 per point');
        Assert.areEqual(purchase.Id, redeemed.Transaction_Record__c, 'Linked to the bill');
        Assert.isNotNull(redeemed.Processed_Date__c, 'Processed date is stamped');

        Loyalty_Transaction__c earned = ledgerRow(acct.Id, 'Earn');
        Assert.areEqual('Active', earned.Status__c, 'A new lot is Active');
        Assert.areEqual(60, earned.Points_Earned__c, '3,088 at Silver 2% earns 60');
        Assert.areEqual(60, earned.Remaining_Points__c, 'Nothing spent from the new lot');
        Assert.areEqual(Date.today(), earned.Credit_Date__c, 'Credited on the bill date');
        Assert.areEqual(Date.today().addDays(365), earned.Expiry_Date__c, 'Valid for 365 days from credit');
        Assert.areEqual('Silver', earned.Earning_Tier__c, 'Tier snapshot');
        Assert.areEqual(2, earned.Earning_Rate__c, 'Rate snapshot');
        Assert.areEqual(3088, earned.Net_Loyalty_Amount__c, 'Earned on the bill less the points spent');
        Assert.areEqual(purchase.Id, earned.Transaction_Record__c, 'Linked to the bill');
    }

    /** Leaving the box unticked earns on the whole bill and spends nothing. */
    @IsTest
    static void testRedeemUntickedLeavesTheBalanceAlone() {
        Account acct = household('Saving Up', 5000);
        insert acct;
        update openingBalance(acct.Id, 500);

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
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Loyalty_Transaction__c WHERE Loyalty_Record__r.Account__c = :acct.Id AND Transaction_Type__c = 'Redeemed'],
            'No Redeemed event when the box is unticked'
        );
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
        withPoints(acct.Id, 99);

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
    }

    /**
     * The document allows a balance of 102 to be redeemed in full, so the
     * minimum is a floor on the balance, not a rounding step.
     */
    @IsTest
    static void testBalanceOfOneHundredAndTwoIsSpentInFull() {
        Account acct = household('Exactly Over', 5000);
        insert acct;
        withPoints(acct.Id, 102);

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
        withPoints(acct.Id, 5000);

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
        withPoints(acct.Id, 900);

        Test.startTest();
        insert bill(acct.Id, 800, true);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(100, loyalty.Points_Balance__c, '800 of the 900 points settled the bill');
        Assert.areEqual(900, loyalty.Total_Points_Earned__c, 'A bill paid entirely in points earns nothing');
        Assert.isNull(loyalty.Last_Transaction_Date__c, 'A redemption that earned nothing does not move the last earning date');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Loyalty_Transaction__c WHERE Loyalty_Record__r.Account__c = :acct.Id AND Transaction_Type__c = 'Earn' AND Transaction_Record__c != null],
            'No zero-point Earn event'
        );
    }

    /**
     * A bill too small to absorb the 100 point minimum cannot be redeemed
     * against, even when the balance itself is healthy.
     */
    @IsTest
    static void testBillSmallerThanTheMinimumCannotBeRedeemedAgainst() {
        Account acct = household('Tiny Bill', 5000);
        insert acct;
        withPoints(acct.Id, 500);

        Test.startTest();
        insert bill(acct.Id, 50, true);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(500, loyalty.Points_Balance__c, 'The balance is untouched');
        Assert.areEqual(0, loyalty.Total_Points_Redeemed__c, 'A 50 rupee bill cannot carry a 100 point redemption');
    }

    // =====================================================================
    // Last Transaction Date
    // =====================================================================

    /** A back-dated bill does not move the last transaction date back. */
    @IsTest
    static void testBackDatedBillLeavesLastTransactionDateAlone() {
        Account acct = household('Back Dated', 5000);
        insert acct;
        Loyalty_Record__c opening = openingBalance(acct.Id, 500);
        opening.Last_Transaction_Date__c = Date.today();
        update opening;

        Transaction_Record__c oldBill = bill(acct.Id, 3200, false);
        oldBill.Transaction_Date__c = Datetime.now().addDays(-10);

        Test.startTest();
        insert oldBill;
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(Date.today(), loyalty.Last_Transaction_Date__c, 'The later date is kept');
    }

    // =====================================================================
    // FIFO redemption
    // =====================================================================

    /**
     * Lots of 100 (oldest), 200 and 300; a 150 redemption empties the oldest,
     * takes 50 from the next and leaves the newest alone. The part-used lot
     * stays the lot - no new Earn row stands in for its remainder.
     */
    @IsTest
    static void testRedemptionConsumesTheOldestLotFirst() {
        Account acct = household('Three Lots', 5000);
        insert acct;
        Loyalty_Record__c loyalty = openingBalance(acct.Id, 600);
        update loyalty;

        Loyalty_Transaction__c lt001 = earnedLot(loyalty.Id, 100, Date.today().addDays(-30));
        Loyalty_Transaction__c lt002 = earnedLot(loyalty.Id, 200, Date.today().addDays(-20));
        Loyalty_Transaction__c lt003 = earnedLot(loyalty.Id, 300, Date.today().addDays(-10));
        insert new List<Loyalty_Transaction__c>{ lt003, lt001, lt002 };

        Test.startTest();
        insert bill(acct.Id, 150, true);
        Test.stopTest();

        Map<Id, Loyalty_Transaction__c> lots = new Map<Id, Loyalty_Transaction__c>([
            SELECT Id, Status__c, Remaining_Points__c, SystemModstamp, CreatedDate
            FROM Loyalty_Transaction__c
            WHERE Id IN :new List<Id>{ lt001.Id, lt002.Id, lt003.Id }
        ]);

        Assert.areEqual(0, lots.get(lt001.Id).Remaining_Points__c, 'Oldest lot emptied');
        Assert.areEqual('Redeemed', lots.get(lt001.Id).Status__c, 'Emptied lot is Redeemed');
        Assert.areEqual(150, lots.get(lt002.Id).Remaining_Points__c, '50 taken from the second lot');
        Assert.areEqual('Active', lots.get(lt002.Id).Status__c, 'Part-used lot stays Active');
        Assert.areEqual(300, lots.get(lt003.Id).Remaining_Points__c, 'Newest lot untouched');
        Assert.areEqual('Active', lots.get(lt003.Id).Status__c, 'Newest lot still Active');

        Loyalty_Transaction__c redeemed = ledgerRow(acct.Id, 'Redeemed');
        Assert.areEqual(150, redeemed.Points_Earned__c, 'One Redeemed event for the whole 150');
        Assert.areEqual(0, redeemed.Remaining_Points__c, 'A redemption is not a lot');

        Assert.areEqual(
            4,
            [SELECT COUNT() FROM Loyalty_Transaction__c WHERE Loyalty_Record__c = :loyalty.Id],
            'Three lots + one Redeemed event; the 150 bill settled in points earns nothing'
        );
        Assert.areEqual(450, loyaltyFor(acct.Id).Points_Balance__c, '600 - 150');
    }

    /** Only the lots a redemption draws on are saved again. */
    @IsTest
    static void testUntouchedLotsAreNotUpdated() {
        Account acct = household('Leave Me Be', 5000);
        insert acct;
        Loyalty_Record__c loyalty = openingBalance(acct.Id, 400);
        update loyalty;

        Loyalty_Transaction__c oldest = earnedLot(loyalty.Id, 200, Date.today().addDays(-20));
        Loyalty_Transaction__c newest = earnedLot(loyalty.Id, 200, Date.today().addDays(-10));
        insert new List<Loyalty_Transaction__c>{ oldest, newest };

        Datetime newestStampBefore = [SELECT SystemModstamp FROM Loyalty_Transaction__c WHERE Id = :newest.Id].SystemModstamp;

        Test.startTest();
        insert bill(acct.Id, 150, true);
        Test.stopTest();

        Loyalty_Transaction__c newestAfter = [SELECT Remaining_Points__c, SystemModstamp FROM Loyalty_Transaction__c WHERE Id = :newest.Id];
        Assert.areEqual(200, newestAfter.Remaining_Points__c, 'Newest lot keeps its points');
        Assert.areEqual(newestStampBefore, newestAfter.SystemModstamp, 'Newest lot was not saved again');
    }

    /** Expired lots are never redeemed, even when still marked Active. */
    @IsTest
    static void testExpiredLotIsNeverRedeemed() {
        Account acct = household('Stale Points', 5000);
        insert acct;
        Loyalty_Record__c loyalty = openingBalance(acct.Id, 650);
        update loyalty;

        Loyalty_Transaction__c expired = earnedLot(loyalty.Id, 500, Date.today().addDays(-400));
        Loyalty_Transaction__c fresh = earnedLot(loyalty.Id, 150, Date.today().addDays(-10));
        insert new List<Loyalty_Transaction__c>{ expired, fresh };

        Test.startTest();
        insert bill(acct.Id, 1000, true);
        Test.stopTest();

        Assert.areEqual(
            500,
            [SELECT Remaining_Points__c FROM Loyalty_Transaction__c WHERE Id = :expired.Id].Remaining_Points__c,
            'The expired lot is not drawn on'
        );
        Assert.areEqual(
            0,
            [SELECT Remaining_Points__c FROM Loyalty_Transaction__c WHERE Id = :fresh.Id].Remaining_Points__c,
            'Only the unexpired lot is spent'
        );
        Assert.areEqual(150, loyaltyFor(acct.Id).Total_Points_Redeemed__c, 'Redemption capped at the usable lots');
    }

    /** Expiry_Date__c is the last day a lot can be used. */
    @IsTest
    static void testLotIsUsableOnItsExpiryDate() {
        Account lastDay = household('Last Day', 5000);
        Account dayAfter = household('Day After', 5000);
        insert new List<Account>{ lastDay, dayAfter };

        Loyalty_Record__c lastDayLoyalty = openingBalance(lastDay.Id, 200);
        Loyalty_Record__c dayAfterLoyalty = openingBalance(dayAfter.Id, 200);
        update new List<Loyalty_Record__c>{ lastDayLoyalty, dayAfterLoyalty };

        insert new List<Loyalty_Transaction__c>{
            earnedLot(lastDayLoyalty.Id, 200, Date.today().addDays(-365)),  // expires today
            earnedLot(dayAfterLoyalty.Id, 200, Date.today().addDays(-366))  // expired yesterday
        };

        Test.startTest();
        insert new List<Transaction_Record__c>{
            bill(lastDay.Id, 1000, true),
            bill(dayAfter.Id, 1000, true)
        };
        Test.stopTest();

        Assert.areEqual(200, loyaltyFor(lastDay.Id).Total_Points_Redeemed__c, 'Usable on the expiry date itself');
        Assert.areEqual(0, loyaltyFor(dayAfter.Id).Total_Points_Redeemed__c, 'Not usable the day after');
    }

    /**
     * A lot with its own Expiry_Date__c (e.g. a gift voucher coupon) is
     * governed by that date, not by Credit Date + 365.
     */
    @IsTest
    static void testCustomExpiryDateIsRespected() {
        Account extended = household('Extended Validity', 5000);
        Account shortened = household('Short Validity', 5000);
        insert new List<Account>{ extended, shortened };

        Loyalty_Record__c extendedLoyalty = openingBalance(extended.Id, 200);
        Loyalty_Record__c shortenedLoyalty = openingBalance(shortened.Id, 200);
        update new List<Loyalty_Record__c>{ extendedLoyalty, shortenedLoyalty };

        // Credited 400 days ago but still valid for another 30 days.
        Loyalty_Transaction__c extendedLot = earnedLot(extendedLoyalty.Id, 200, Date.today().addDays(-400));
        extendedLot.Expiry_Date__c = Date.today().addDays(30);

        // Credited 10 days ago but already expired yesterday.
        Loyalty_Transaction__c shortenedLot = earnedLot(shortenedLoyalty.Id, 200, Date.today().addDays(-10));
        shortenedLot.Expiry_Date__c = Date.today().addDays(-1);

        insert new List<Loyalty_Transaction__c>{ extendedLot, shortenedLot };

        Test.startTest();
        insert new List<Transaction_Record__c>{
            bill(extended.Id, 1000, true),
            bill(shortened.Id, 1000, true)
        };
        Test.stopTest();

        Assert.areEqual(200, loyaltyFor(extended.Id).Total_Points_Redeemed__c, 'Usable until its own expiry date');
        Assert.areEqual(0, loyaltyFor(shortened.Id).Total_Points_Redeemed__c, 'Not usable after its own expiry date');
    }

    // =====================================================================
    // Ordering
    // =====================================================================

    /** Points earned on a bill are not available to that same bill. */
    @IsTest
    static void testPointsEarnedOnABillCannotBeSpentOnIt() {
        Account acct = household('First Visit Redeemer', 5000);
        insert acct;

        Test.startTest();
        insert bill(acct.Id, 10000, true);
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(200, loyalty.Points_Balance__c, 'The 200 earned stay on the balance');
        Assert.areEqual(0, loyalty.Total_Points_Redeemed__c, 'Nothing was available to redeem');
    }

    /**
     * Bills saved together are processed by Transaction_Date__c, not by
     * their order in Trigger.new: the 10:00 bill earns 100, so the 15:00
     * bill can redeem them, even though it is listed first.
     */
    @IsTest
    static void testBillsInOneSaveAreProcessedInDateOrder() {
        Account acct = household('Morning And Afternoon', 5000);
        insert acct;

        Transaction_Record__c morning = bill(acct.Id, 5000, false);
        morning.Transaction_Date__c = Datetime.newInstance(Date.today(), Time.newInstance(10, 0, 0, 0));

        Transaction_Record__c afternoon = bill(acct.Id, 1000, true);
        afternoon.Transaction_Date__c = Datetime.newInstance(Date.today(), Time.newInstance(15, 0, 0, 0));

        Test.startTest();
        insert new List<Transaction_Record__c>{ afternoon, morning };
        Test.stopTest();

        Loyalty_Record__c loyalty = loyaltyFor(acct.Id);
        Assert.areEqual(100, loyalty.Total_Points_Redeemed__c, 'The afternoon bill spent the morning points');
        Assert.areEqual(118, loyalty.Total_Points_Earned__c, '100 in the morning + 900 net x 2% = 18');
        Assert.areEqual(18, loyalty.Points_Balance__c, '100 - 100 + 18');

        Loyalty_Transaction__c morningLot = [
            SELECT Remaining_Points__c, Status__c
            FROM Loyalty_Transaction__c
            WHERE Transaction_Record__c = :morning.Id AND Transaction_Type__c = 'Earn'
        ];
        Assert.areEqual(0, morningLot.Remaining_Points__c, 'The morning lot was saved already spent');
        Assert.areEqual('Redeemed', morningLot.Status__c, 'And marked Redeemed');
    }

    // =====================================================================
    // Historical snapshot
    // =====================================================================

    /** The Earn row records the tier and rate the points were earned under. */
    @IsTest
    static void testEarnRowSnapshotsTierAndRate() {
        Account acct = household('Gold Snapshot', 10000);
        insert acct;

        Test.startTest();
        insert bill(acct.Id, 5000, false);
        Test.stopTest();

        Loyalty_Transaction__c earned = ledgerRow(acct.Id, 'Earn');
        Assert.areEqual('Gold', earned.Earning_Tier__c, 'Tier held before the bill');
        Assert.areEqual(4, earned.Earning_Rate__c, 'Gold rate');
        Assert.areEqual(200, earned.Points_Earned__c, '5000 x 4%');
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
        // The Account flow already created one Loyalty Record; add a second.
        insert new Loyalty_Record__c(
            Account__c = acct.Id,
            Points_Balance__c = 250,
            Total_Points_Earned__c = 250,
            Total_Points_Redeemed__c = 0
        );

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
