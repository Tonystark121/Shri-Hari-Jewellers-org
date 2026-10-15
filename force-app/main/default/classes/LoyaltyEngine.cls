/**
 * Loyalty points engine.
 *
 * Three objects, three questions:
 *
 *   Transaction_Record__c  - what did the customer purchase?
 *   Loyalty_Transaction__c - what happened to the customer's points?
 *                            (the ledger: one row per Earn / Bonus /
 *                            Redeemed event)
 *   Loyalty_Record__c      - what is the customer's balance right now?
 *                            (materialised current state, kept in step
 *                            with the ledger)
 *
 * Every Earn event (points earned on a bill) and every Bonus event (points
 * given by hand on the Allot Loyalty Points flow) is also a lot.
 * Remaining_Points__c says how much of the lot is still unspent, and
 * redemptions consume lots oldest first (FIFO). A lot earned on a bill gets
 * Expiry_Date__c = Credit Date + 365 days; a Bonus lot carries the Expiry
 * Date chosen when it was given. A separate scheduled job marks lots
 * Expired.
 *
 * The ledger and the balance are system-maintained: the user saving the bill
 * (usually the POS integration user) needs no access to them. Queries and DML
 * therefore run explicitly in system mode (WITH SYSTEM_MODE / AS SYSTEM),
 * because Apex at this API version otherwise enforces the running user's
 * field-level security.
 */
public with sharing class LoyaltyEngine {

    /**
     * Raised when the loyalty data cannot be trusted - currently only when a
     * household somehow holds more than one loyalty record, because the
     * balance is a household total and there is no safe way to guess which
     * record owns it.
     */
    public class LoyaltyException extends Exception {}


    // Points earned on a bill are taken down to a multiple of this.
    @TestVisible
    private static final Decimal EARNED_POINTS_STEP = 10;

    @TestVisible
    private static final String DEFAULT_TIER = 'Silver';

    // Points earned on a bill can be used for this many days after the
    // credit date (inclusive).
    @TestVisible
    private static final Integer EARNED_POINTS_VALIDITY_DAYS = 365;

    // Loyalty_Transaction__c.Transaction_Type__c values
    @TestVisible
    private static final String LEDGER_TYPE_EARN = 'Earn';

    @TestVisible
    private static final String LEDGER_TYPE_BONUS = 'Bonus';

    @TestVisible
    private static final String LEDGER_TYPE_REDEEMED = 'Redeemed';

    /** Ledger types that are lots: points that can be spent and that expire. */
    public static final Set<String> LOT_TYPES = new Set<String>{ LEDGER_TYPE_EARN, LEDGER_TYPE_BONUS };

    @TestVisible
    private static final String SOURCE_MANUAL = 'Manual';

    @TestVisible
    private static final String ALLOT_FIXED = 'Fixed Points';

    @TestVisible
    private static final String ALLOT_PERCENTAGE = 'Percentage';

    // Loyalty_Transaction__c.Status__c values
    @TestVisible
    private static final String LEDGER_STATUS_ACTIVE = 'Active';

    @TestVisible
    private static final String LEDGER_STATUS_REDEEMED = 'Redeemed';


    /**
     * Main loyalty processing method.
     *
     * Called from TransactionTriggerHandler.afterInsert().
     *
     * For each bill, in chronological order:
     *
     *   1. Take the points POS reported as redeemed (Points Redeemed). A
     *      bill reporting more than the customer can use on the bill date is
     *      rejected with the reason.
     *   2. Consume eligible earning lots, oldest first.
     *   3. Create the Redeemed event.
     *   4. Calculate the points earned on the Net Amount.
     *   5. Create the Earn event (the new earning lot).
     *   6. Update the Loyalty Record.
     *
     * Net Amount (Amount - Voucher Discount - Points Redeemed) is stamped
     * before the bill is saved, by GiftVoucherRedemption.
     *
     * Points earned by a bill are never available to that same bill, but a
     * later bill in the same batch can spend them.
     */
    public static void processEarn( List<Transaction_Record__c> newTransactions ) {

        if (newTransactions == null || newTransactions.isEmpty()) {
            return;
        }

        // ---------------------------------------------------------
        // 1. Bills with a household, earliest first
        //
        // Trigger.new order is arbitrary. An earlier bill must have
        // its loyalty effect first, so a later bill can redeem the
        // points it earned.
        // ---------------------------------------------------------

        List<Transaction_Record__c> bills = new List<Transaction_Record__c>();
        Set<Id> accountIds = new Set<Id>();

        for (Transaction_Record__c transactionRecord : newTransactions) {

            if (transactionRecord.Account__c != null) {
                bills.add(transactionRecord);
                accountIds.add(transactionRecord.Account__c);
            }
        }

        if (bills.isEmpty()) {
            return;
        }

        bills.sort(new ChronologicalOrder());


        // ---------------------------------------------------------
        // 2. Get Account Tier
        //
        // Customer_Tier__c is a formula over Last_12M_Spend__c,
        // which TransactionTriggerHandler recalculates only after
        // this method returns - so this is the tier held before
        // these bills.
        // ---------------------------------------------------------

        Map<Id, Account> accountsById = new Map<Id, Account>([
            SELECT Id, Customer_Tier__c FROM Account WHERE Id IN :accountIds WITH SYSTEM_MODE
        ]);


        // ---------------------------------------------------------
        // 3. Get earning rates from Custom Metadata
        // ---------------------------------------------------------

        Map<String, Decimal> ratesByTier = earningRates();


        // ---------------------------------------------------------
        // 4. Lock the Loyalty Records
        //
        // FOR UPDATE prevents two concurrent transactions from
        // reading the same balance and earning lots and overwriting
        // each other's changes. Everything below reads from the
        // locked state.
        //
        // Households without a record get one now: the ledger rows
        // are master-detail children and need its Id.
        // ---------------------------------------------------------

        Map<Id, Loyalty_Record__c> loyaltyByAccount = loyaltyRecordsFor(accountIds);

        insertNewLoyaltyRecords(loyaltyByAccount.values());


        // ---------------------------------------------------------
        // 5. Load the open earning lots, in FIFO order
        // ---------------------------------------------------------

        Map<Id, List<Loyalty_Transaction__c>> lotsByLoyalty = openLotsFor(loyaltyByAccount.values());


        // ---------------------------------------------------------
        // 6. Process each bill
        // ---------------------------------------------------------

        Datetime processedAt = Datetime.now();

        // Existing lots a redemption touched - only these are updated.
        Map<Id, Loyalty_Transaction__c> consumedLots = new Map<Id, Loyalty_Transaction__c>();

        List<Loyalty_Transaction__c> newEvents = new List<Loyalty_Transaction__c>();

        for (Transaction_Record__c transactionRecord : bills) {

            Account accountRecord = accountsById.get(transactionRecord.Account__c);

            if (accountRecord == null) {
                continue;
            }

            Loyalty_Record__c loyalty = loyaltyByAccount.get(transactionRecord.Account__c);
            List<Loyalty_Transaction__c> lots = lotsByLoyalty.get(loyalty.Id);

            Integer currentBalance = whole(loyalty.Points_Balance__c);

            // -----------------------------------------------------
            // Transaction Date
            //
            // Transaction_Date__c is DateTime.
            //
            // .date() converts DateTime -> Date.
            // -----------------------------------------------------

            Date transactionDate = transactionRecord.Transaction_Date__c == null ? Date.today() : transactionRecord.Transaction_Date__c.date();


            // -----------------------------------------------------
            // Redemption, as reported by POS
            //
            // Points are worth Rs. 1 each, and only points held in
            // earning lots still usable on the bill date can be
            // spent. POS decided the redemption; a bill reporting
            // more than the customer holds is rejected, never cut
            // down, so the books match the till.
            // -----------------------------------------------------

            Integer pointsRedeemed = whole(transactionRecord.Points_Redeemed__c);

            if (pointsRedeemed > 0) {

                List<Loyalty_Transaction__c> eligible = eligibleLots(lots, transactionDate);
                Integer available = Math.min( currentBalance, remainingIn(eligible) );

                if (pointsRedeemed > available) {
                    transactionRecord.addError(
                        'The bill was not saved: Points Redeemed (' + pointsRedeemed + ') is more than the points '
                        + 'this customer can use on ' + transactionDate.format() + ' (' + available + ').'
                    );
                    continue;
                }

                consumeOldestFirst( eligible, pointsRedeemed, consumedLots );
                newEvents.add( redemptionEvent( loyalty, transactionRecord, pointsRedeemed, processedAt ) );
            }

            // Stamped before insert by GiftVoucherRedemption.
            Decimal netAmount = transactionRecord.Net_Amount__c == null ? 0 : transactionRecord.Net_Amount__c;

            // -----------------------------------------------------
            // Tier used for THIS purchase
            //
            // Important:
            // We use the Account tier that existed before this
            // transaction.
            //
            // Example from PDF:
            //
            // Customer is Silver with cumulative spend Rs. 5,600.
            // Third purchase takes cumulative spend above Rs. 7,500.
            //
            // Third purchase still earns at Silver rate.
            // Next purchase uses Gold.
            // -----------------------------------------------------

            String tier = String.isBlank(accountRecord.Customer_Tier__c) ? DEFAULT_TIER :  accountRecord.Customer_Tier__c;

            Decimal earningRate = ratesByTier.get(tier);

            // -----------------------------------------------------
            // Calculate points earned, and open a new earning lot
            //
            // The lot joins the FIFO list only after this bill's
            // redemption, so it is spendable from the next bill on.
            // -----------------------------------------------------

            Integer pointsEarned = pointsFor( netAmount, earningRate );

            if (pointsEarned > 0) {

                Loyalty_Transaction__c lot = earningLot( loyalty, transactionRecord, transactionDate, pointsEarned, tier, earningRate, netAmount, processedAt );

                newEvents.add(lot);
                addInFifoOrder(lots, lot);
            }


            // -----------------------------------------------------
            // Update loyalty balance
            //
            // New Balance =
            // Old Balance
            // + Points Earned
            // - Points Redeemed
            //
            // Never negative.
            // -----------------------------------------------------

            loyalty.Points_Balance__c = Math.max( 0, currentBalance + pointsEarned - pointsRedeemed );
            loyalty.Total_Points_Earned__c = whole(loyalty.Total_Points_Earned__c) + pointsEarned;
            loyalty.Total_Points_Redeemed__c = whole(loyalty.Total_Points_Redeemed__c) + pointsRedeemed;

            // -----------------------------------------------------
            // Last Transaction Date
            //
            // Last_Transaction_Date__c is the latest bill that
            // EARNED points, so a bill that earned nothing (for
            // example one settled entirely in points) leaves it
            // alone, as does a back-dated bill.
            // -----------------------------------------------------

            if (pointsEarned > 0 && (loyalty.Last_Transaction_Date__c == null || loyalty.Last_Transaction_Date__c <= transactionDate)) {
                loyalty.Last_Transaction_Date__c = transactionDate;
            }
        }


        // ---------------------------------------------------------
        // 7. Save
        //
        // Consumed lots first, then the new ledger events, then the
        // current state. Lots created and consumed within this batch
        // are inserted already carrying their consumed figures.
        // ---------------------------------------------------------

        if (!consumedLots.isEmpty()) {
            update as system consumedLots.values();
        }

        if (!newEvents.isEmpty()) {
            insert as system newEvents;
        }

        update as system loyaltyByAccount.values();
    }

    /**
     * Calculates loyalty points: the tier percentage of the net amount,
     * taken down to the nearest multiple of 10 at or below it.
     *
     * Example:
     *
     * netAmount = 3088
     * tierPercentage = 2
     *
     * 3088 x 2% = 61.76
     *
     * 61.76 taken down to a multiple of 10 = 60 points
     */
    @TestVisible
    private static Integer pointsFor( Decimal netAmount, Decimal tierPercentage) {

        if (netAmount == null || netAmount <= 0 || tierPercentage == null || tierPercentage <= 0) {
            return 0;
        }

        Decimal calculatedPoints = netAmount * tierPercentage / 100;
        Decimal completeSteps = calculatedPoints.divide(EARNED_POINTS_STEP, 0, System.RoundingMode.DOWN);

        return Integer.valueOf( completeSteps * EARNED_POINTS_STEP );
    }

    /**
     * The earning lots a redemption on `redemptionDate` may consume, in
     * FIFO order. A lot qualifies only when it is an Active Earn or Bonus lot with
     * points remaining, was credited on or before the redemption date, and
     * has not expired - Expiry_Date__c is the last usable day.
     */
    @TestVisible
    private static List<Loyalty_Transaction__c> eligibleLots( List<Loyalty_Transaction__c> lots, Date redemptionDate ) {

        List<Loyalty_Transaction__c> eligible = new List<Loyalty_Transaction__c>();

        for (Loyalty_Transaction__c lot : lots) {

            if (LOT_TYPES.contains(lot.Transaction_Type__c)
                && lot.Status__c == LEDGER_STATUS_ACTIVE
                && whole(lot.Remaining_Points__c) > 0
                && lot.Credit_Date__c != null
                && lot.Credit_Date__c <= redemptionDate
                && lot.Expiry_Date__c != null
                && lot.Expiry_Date__c >= redemptionDate) {

                eligible.add(lot);
            }
        }

        return eligible;
    }

    private static Integer remainingIn( List<Loyalty_Transaction__c> lots ) {

        Integer total = 0;

        for (Loyalty_Transaction__c lot : lots) {
            total += whole(lot.Remaining_Points__c);
        }

        return total;
    }

    /**
     * Spends `points` from `eligible`, oldest lot first. Only the lots
     * actually drawn on change; a lot emptied to zero becomes Redeemed, a
     * part-used lot stays Active with the rest still on it.
     *
     * Lots already saved are collected in `consumedLots` for update. Lots
     * created earlier in this batch have no Id yet and are simply inserted
     * carrying the new figures.
     */
    private static void consumeOldestFirst( List<Loyalty_Transaction__c> eligible, Integer points, Map<Id, Loyalty_Transaction__c> consumedLots ) {

        Integer outstanding = points;

        for (Loyalty_Transaction__c lot : eligible) {

            if (outstanding == 0) {
                break;
            }

            Integer remaining = whole(lot.Remaining_Points__c);
            Integer taken = Math.min(remaining, outstanding);

            lot.Remaining_Points__c = remaining - taken;

            if (lot.Remaining_Points__c == 0) {
                lot.Status__c = LEDGER_STATUS_REDEEMED;
            }

            outstanding -= taken;

            if (lot.Id != null) {
                consumedLots.put(lot.Id, lot);
            }
        }
    }

    /**
     * Places a new lot in the FIFO list: after every lot credited on the
     * same day or earlier, before the first lot credited later.
     */
    private static void addInFifoOrder( List<Loyalty_Transaction__c> lots, Loyalty_Transaction__c newLot ) {

        for (Integer i = 0; i < lots.size(); i++) {

            if (lots[i].Credit_Date__c > newLot.Credit_Date__c) {
                lots.add(i, newLot);
                return;
            }
        }

        lots.add(newLot);
    }

    /**
     * Ledger row for points spent against a bill. Remaining is zero: a
     * redemption is an event, not a lot.
     */
    private static Loyalty_Transaction__c redemptionEvent( Loyalty_Record__c loyalty, Transaction_Record__c transactionRecord, Integer pointsRedeemed, Datetime processedAt ) {

        return new Loyalty_Transaction__c(
            Loyalty_Record__c = loyalty.Id,
            Transaction_Record__c = transactionRecord.Id,
            Transaction_Type__c = LEDGER_TYPE_REDEEMED,
            Status__c = LEDGER_STATUS_REDEEMED,
            Points_Earned__c = pointsRedeemed,
            Remaining_Points__c = 0,
            Redemption_Value__c = pointsRedeemed,
            Processed_Date__c = processedAt
        );
    }

    /**
     * Ledger row for points earned on a bill - also the new earning lot.
     *
     * Earning_Tier__c and Earning_Rate__c are a snapshot of the terms the
     * points were earned under and are never rewritten when the tier moves.
     * Expiry_Date__c is the last usable day: credit date + 365 days.
     */
    private static Loyalty_Transaction__c earningLot( Loyalty_Record__c loyalty, Transaction_Record__c transactionRecord, Date creditDate, Integer pointsEarned, String tier, Decimal earningRate, Decimal netAmount, Datetime processedAt ) {

        return new Loyalty_Transaction__c(
            Loyalty_Record__c = loyalty.Id,
            Transaction_Record__c = transactionRecord.Id,
            Transaction_Type__c = LEDGER_TYPE_EARN,
            Status__c = LEDGER_STATUS_ACTIVE,
            Points_Earned__c = pointsEarned,
            Remaining_Points__c = pointsEarned,
            Credit_Date__c = creditDate,
            Expiry_Date__c = creditDate.addDays(EARNED_POINTS_VALIDITY_DAYS),
            Earning_Tier__c = tier,
            Earning_Rate__c = earningRate,
            Net_Loyalty_Amount__c = netAmount,
            Processed_Date__c = processedAt
        );
    }

    /**
     * Reads tier earning rates from Loyalty_Setting__mdt.
     *
     * Expected metadata values:
     *
     * Silver   -> 2
     * Gold     -> 4
     * Platinum -> 7
     * Diamond  -> 10
     */
    @TestVisible
    private static Map<String, Decimal> earningRates() {

        Map<String, Decimal> rates = new Map<String, Decimal>();
        List<Loyalty_Setting__mdt> records = [
                SELECT Tier__c, Earning_Rate__c FROM Loyalty_Setting__mdt WHERE Tier__c != null
            ];

        for ( Loyalty_Setting__mdt setting :records ) {

            if (String.isBlank( setting.Earning_Rate__c )) {
                continue;
            }

            try {

                String rawRate = setting.Earning_Rate__c;
                Decimal rate = Decimal.valueOf(rawRate);

                rates.put( setting.Tier__c, rate );

            } catch (Exception e) {

                System.debug(
                    LoggingLevel.ERROR,
                    'Invalid loyalty earning rate. ' +
                    'Tier=' + setting.Tier__c +
                    ', Rate=' + setting.Earning_Rate__c
                );
            }
        }

        return rates;
    }

    /**
     * Gets the Loyalty_Record__c for each Account.
     *
     * Existing records are locked using FOR UPDATE so that
     * concurrent transactions cannot overwrite the same balance.
     */
    private static Map<Id, Loyalty_Record__c> loyaltyRecordsFor( Set<Id> accountIds) {

        Map<Id, Loyalty_Record__c> byAccount = new Map<Id, Loyalty_Record__c>();

        List<Loyalty_Record__c> loyaltyList = [
                SELECT
                    Id,
                    Account__c,
            		Tier__c,
                    Points_Balance__c,
                    Total_Points_Earned__c,
                    Total_Points_Redeemed__c,
                    Last_Transaction_Date__c
                FROM Loyalty_Record__c
                WHERE Account__c IN :accountIds
                WITH SYSTEM_MODE
                FOR UPDATE
            ];

        for ( Loyalty_Record__c loyalty : loyaltyList ) {

            // There should be exactly one Loyalty Record
            // per Account.
            if ( byAccount.containsKey( loyalty.Account__c ) ) {

                throw new LoyaltyException(
                    'Multiple Loyalty Records found for Account ' +
                    loyalty.Account__c +
                    '. Expected exactly one.'
                );
            }


            byAccount.put(  loyalty.Account__c, loyalty );
        }


        // Create an in-memory Loyalty Record when one does
        // not already exist.
        for (Id accountId : accountIds) {

            if (!byAccount.containsKey(accountId)) {

                byAccount.put(
                    accountId,
                    new Loyalty_Record__c(
                        Account__c = accountId,
                        Points_Balance__c = 0,
                        Total_Points_Earned__c = 0,
                        Total_Points_Redeemed__c = 0
                    )
                );
            }
        }


        return byAccount;
    }

    private static void insertNewLoyaltyRecords( List<Loyalty_Record__c> loyaltyRecords ) {

        List<Loyalty_Record__c> newRecords = new List<Loyalty_Record__c>();

        for (Loyalty_Record__c loyalty : loyaltyRecords) {

            if (loyalty.Id == null) {
                newRecords.add(loyalty);
            }
        }

        if (!newRecords.isEmpty()) {
            insert as system newRecords;
        }
    }

    /**
     * Open earning lots per Loyalty Record, in FIFO order: Credit Date,
     * then CreatedDate, then Id so lots saved in one DML still have a
     * fixed order. Expiry is checked per bill in eligibleLots(), because
     * the bills in a batch can fall on different dates.
     *
     * The parent Loyalty Records are already locked, so no other
     * transaction can be consuming these lots at the same time.
     */
    private static Map<Id, List<Loyalty_Transaction__c>> openLotsFor( List<Loyalty_Record__c> loyaltyRecords ) {

        Map<Id, List<Loyalty_Transaction__c>> byLoyalty = new Map<Id, List<Loyalty_Transaction__c>>();

        for (Loyalty_Record__c loyalty : loyaltyRecords) {
            byLoyalty.put(loyalty.Id, new List<Loyalty_Transaction__c>());
        }

        Set<Id> loyaltyIds = new Set<Id>(byLoyalty.keySet());
        Set<String> lotTypes = LOT_TYPES;
        String activeStatus = LEDGER_STATUS_ACTIVE;

        List<Loyalty_Transaction__c> openLots = [
            SELECT
                Id,
                Loyalty_Record__c,
                Transaction_Type__c,
                Status__c,
                Remaining_Points__c,
                Credit_Date__c,
                Expiry_Date__c
            FROM Loyalty_Transaction__c
            WHERE Loyalty_Record__c IN :loyaltyIds
            AND Transaction_Type__c IN :lotTypes
            AND Status__c = :activeStatus
            AND Remaining_Points__c > 0
            WITH SYSTEM_MODE
            ORDER BY Credit_Date__c ASC, CreatedDate ASC, Id ASC
        ];

        for (Loyalty_Transaction__c lot : openLots) {
            byLoyalty.get(lot.Loyalty_Record__c).add(lot);
        }

        return byLoyalty;
    }

    // =====================================================================
    // Bonus points (Allot Loyalty Points flow)
    // =====================================================================

    public class AllotRequest {
        @InvocableVariable(label='Account Ids' description='The customers to give points to.' required=true)
        public List<String> accountIds;

        @InvocableVariable(label='Allotment Type' description='Fixed Points, or Percentage of Last 12 Month Spend.' required=true)
        public String allotmentType;

        @InvocableVariable(label='Points' description='Fixed Points: the points every customer gets.')
        public Decimal points;

        @InvocableVariable(label='Percentage' description='Percentage: the % of each customer\'s Last 12 Month Spend given as points.')
        public Decimal percentage;

        @InvocableVariable(label='Expiry Date' description='Last day the points can be redeemed.' required=true)
        public Date expiryDate;

        @InvocableVariable(label='Reason' description='Why the points are given, e.g. Diwali bonus.' required=true)
        public String reason;
    }

    public class AllotResult {
        @InvocableVariable(label='Is Success' description='True when the points were given. Nothing is saved otherwise.')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message' description='Why nothing was saved. Blank on success.')
        public String errorMessage;

        @InvocableVariable(label='Customers Given Points')
        public Integer customersGiven;

        @InvocableVariable(label='Customers Skipped' description='Customers whose percentage came to 0 points.')
        public Integer customersSkipped;

        @InvocableVariable(label='Total Points')
        public Integer totalPoints;
    }

    /**
     * Gives Bonus points to each selected customer: a fixed number, or a
     * percentage of their Last 12 Month Spend taken down to a multiple of 10
     * like points earned on a bill (customers it comes to 0 for are
     * skipped). Each customer gets one Bonus lot (Source Manual, with the
     * Reason and Expiry Date) and their balance and Total Points Earned go
     * up; Last Transaction Date and tier are untouched, as no purchase was
     * made. All or nothing.
     */
    @InvocableMethod(
        label='Allot Loyalty Points'
        description='Gives Bonus loyalty points to the selected customers: a fixed number, or a % of Last 12 Month Spend.'
        category='Loyalty'
    )
    public static List<AllotResult> allotBonusPoints(List<AllotRequest> requests) {
        List<AllotResult> results = new List<AllotResult>();
        for (AllotRequest request : requests) {
            results.add(allot(request));
        }
        return results;
    }

    private static AllotResult allot(AllotRequest request) {
        AllotResult result = new AllotResult();
        result.isSuccess = false;
        result.customersGiven = 0;
        result.customersSkipped = 0;
        result.totalPoints = 0;

        result.errorMessage = problemWithAllotment(request);
        if (result.errorMessage != null) {
            return result;
        }

        Set<Id> accountIds = new Set<Id>();
        for (String accountId : request.accountIds) {
            if (String.isNotBlank(accountId)) {
                accountIds.add(Id.valueOf(accountId));
            }
        }

        Boolean isFixed = request.allotmentType == ALLOT_FIXED;
        Map<Id, Integer> pointsByAccount = new Map<Id, Integer>();
        Map<Id, Decimal> spendByAccount = new Map<Id, Decimal>();
        for (Account accountRecord : [
            SELECT Id, Last_12M_Spend__c FROM Account WHERE Id IN :accountIds WITH SYSTEM_MODE
        ]) {
            Integer points = isFixed
                ? request.points.intValue()
                : pointsFor(accountRecord.Last_12M_Spend__c, request.percentage);
            if (points > 0) {
                pointsByAccount.put(accountRecord.Id, points);
                spendByAccount.put(accountRecord.Id, accountRecord.Last_12M_Spend__c);
            } else {
                result.customersSkipped++;
            }
        }

        if (pointsByAccount.isEmpty()) {
            result.errorMessage = 'None of the selected customers gets any points: '
                + request.percentage + '% of their Last 12 Month Spend comes to less than '
                + EARNED_POINTS_STEP.intValue() + ' points.';
            return result;
        }

        Savepoint beforeAllotment = Database.setSavepoint();
        try {
            Map<Id, Loyalty_Record__c> loyaltyByAccount = loyaltyRecordsFor(pointsByAccount.keySet());
            insertNewLoyaltyRecords(loyaltyByAccount.values());

            Datetime processedAt = Datetime.now();
            List<Loyalty_Transaction__c> lots = new List<Loyalty_Transaction__c>();
            for (Id accountId : pointsByAccount.keySet()) {
                Loyalty_Record__c loyalty = loyaltyByAccount.get(accountId);
                Integer points = pointsByAccount.get(accountId);

                Loyalty_Transaction__c lot = new Loyalty_Transaction__c(
                    Loyalty_Record__c = loyalty.Id,
                    Transaction_Type__c = LEDGER_TYPE_BONUS,
                    Status__c = LEDGER_STATUS_ACTIVE,
                    Source__c = SOURCE_MANUAL,
                    Reason__c = request.reason.trim(),
                    Points_Earned__c = points,
                    Remaining_Points__c = points,
                    Credit_Date__c = Date.today(),
                    Expiry_Date__c = request.expiryDate,
                    Processed_Date__c = processedAt
                );
                if (!isFixed) {
                    // Snapshot of what the points were worked out on.
                    lot.Earning_Rate__c = request.percentage;
                    lot.Net_Loyalty_Amount__c = spendByAccount.get(accountId);
                }
                lots.add(lot);

                loyalty.Points_Balance__c = whole(loyalty.Points_Balance__c) + points;
                loyalty.Total_Points_Earned__c = whole(loyalty.Total_Points_Earned__c) + points;
                result.totalPoints += points;
            }

            insert as system lots;
            update as system loyaltyByAccount.values();
        } catch (Exception failure) {
            Database.rollback(beforeAllotment);
            result.errorMessage = 'No points were given: ' + failure.getMessage();
            result.totalPoints = 0;
            return result;
        }

        result.isSuccess = true;
        result.customersGiven = pointsByAccount.size();
        return result;
    }

    /** Why the allotment cannot be made, or null when it can. */
    private static String problemWithAllotment(AllotRequest request) {
        if (request.accountIds == null || request.accountIds.isEmpty()) {
            return 'Select at least one customer.';
        }
        for (String accountId : request.accountIds) {
            if (String.isNotBlank(accountId) && !(accountId instanceof Id)) {
                return 'A selected customer could not be read. Filter and select the customers again.';
            }
        }
        if (request.allotmentType == ALLOT_FIXED) {
            if (request.points == null || request.points <= 0 || request.points != request.points.round(System.RoundingMode.DOWN)) {
                return 'Points must be a whole number greater than 0.';
            }
        } else if (request.allotmentType == ALLOT_PERCENTAGE) {
            if (request.percentage == null || request.percentage <= 0 || request.percentage > 100) {
                return 'Percentage must be greater than 0 and at most 100.';
            }
        } else {
            return 'Choose Fixed Points or Percentage.';
        }
        if (request.expiryDate == null || request.expiryDate <= Date.today()) {
            return 'Expiry Date must be after today.';
        }
        if (String.isBlank(request.reason)) {
            return 'Enter the Reason.';
        }
        if (request.reason.trim().length() > 255) {
            return 'Reason can be at most 255 characters.';
        }
        return null;
    }

    private static Integer whole(  Decimal value ) {
        if (value == null) { return 0; }
        return Integer.valueOf( value.setScale( 0, System.RoundingMode.DOWN ) );
    }

    /**
     * Transaction_Date__c ascending, then CreatedDate, then Id - so bills
     * are processed in the order they happened, not the order they arrived
     * in Trigger.new.
     */
    @TestVisible
    private class ChronologicalOrder implements Comparator<Transaction_Record__c> {

        public Integer compare( Transaction_Record__c a, Transaction_Record__c b ) {

            Integer byDate = compareDatetimes( a.Transaction_Date__c, b.Transaction_Date__c );

            if (byDate != 0) {
                return byDate;
            }

            Integer byCreated = compareDatetimes( a.CreatedDate, b.CreatedDate );

            if (byCreated != 0) {
                return byCreated;
            }

            String idA = a.Id == null ? '' : String.valueOf(a.Id);
            String idB = b.Id == null ? '' : String.valueOf(b.Id);

            return idA.compareTo(idB);
        }

        private Integer compareDatetimes( Datetime a, Datetime b ) {

            if (a == b) {
                return 0;
            }

            if (a == null) {
                return 1;
            }

            if (b == null) {
                return -1;
            }

            return a < b ? -1 : 1;
        }
    }
}