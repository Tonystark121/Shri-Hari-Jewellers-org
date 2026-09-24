public with sharing class LoyaltyEngine {

    /**
     * Raised when the loyalty data cannot be trusted - currently only when a
     * household somehow holds more than one loyalty record, because the
     * balance is a household total and there is no safe way to guess which
     * record owns it.
     */
    public class LoyaltyException extends Exception {}


    @TestVisible
    private static final Integer MINIMUM_REDEEMABLE_POINTS = 100;

    @TestVisible
    private static final Decimal EARNING_BLOCK = 100;

    @TestVisible
    private static final String DEFAULT_TIER = 'Silver';


    /**
     * Main loyalty processing method.
     *
     * Called from TransactionTriggerHandler.afterInsert().
     */
    public static void processEarn(
        List<Transaction_Record__c> newTransactions
    ) {

        if (newTransactions == null || newTransactions.isEmpty()) {
            return;
        }


        // ---------------------------------------------------------
        // 1. Collect Account IDs
        // ---------------------------------------------------------

        Set<Id> accountIds = new Set<Id>();

        for (Transaction_Record__c transactionRecord : newTransactions) {

            if (transactionRecord.Account__c != null) {
                accountIds.add(transactionRecord.Account__c);
            }
        }

        if (accountIds.isEmpty()) {
            return;
        }


        // ---------------------------------------------------------
        // 2. Get Account Tier
        // ---------------------------------------------------------

        Map<Id, Account> accountsById = new Map<Id, Account>([
            SELECT
                Id,
                Customer_Tier__c
            FROM Account
            WHERE Id IN :accountIds
        ]);


        // ---------------------------------------------------------
        // 3. Get earning rates from Custom Metadata
        // ---------------------------------------------------------

        Map<String, Decimal> ratesByTier = earningRates();


        // ---------------------------------------------------------
        // 4. Get Loyalty Records
        //
        // FOR UPDATE prevents two concurrent transactions from
        // reading the same loyalty balance and overwriting each
        // other's changes.
        // ---------------------------------------------------------

        Map<Id, Loyalty_Record__c> loyaltyByAccount = loyaltyRecordsFor (accountIds);


        // ---------------------------------------------------------
        // 5. Process each transaction
        // ---------------------------------------------------------

        for (Transaction_Record__c transactionRecord :
             newTransactions) {

            if (transactionRecord.Account__c == null) {
                continue;
            }


            Account accountRecord = accountsById.get(transactionRecord.Account__c);

            if (accountRecord == null) {
                continue;
            }


            Loyalty_Record__c loyalty = loyaltyByAccount.get(transactionRecord.Account__c);

            if (loyalty == null) {
                continue;
            }


            // -----------------------------------------------------
            // Current points balance
            // -----------------------------------------------------

            Integer currentBalance = whole(loyalty.Points_Balance__c);


            // -----------------------------------------------------
            // Redemption
            //
            // Redeem only when:
            //
            // 1. Redeem_Points__c = true
            // 2. Balance >= 100
            // 3. Applicable redemption amount >= 100
            //
            // Points are worth Rs. 1 each.
            // -----------------------------------------------------

            Integer pointsRedeemed = 0;

            if (transactionRecord.Redeem_Points__c == true) {
                pointsRedeemed = pointsToApply( currentBalance, transactionRecord.Amount__c );
            }


            // -----------------------------------------------------
            // Net bill after redemption
            // -----------------------------------------------------

            Decimal netAmount = netAmountOf( transactionRecord.Amount__c, pointsRedeemed );


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
            // Calculate points earned
            // -----------------------------------------------------

            Integer pointsEarned = pointsFor( netAmount, earningRate );


            // -----------------------------------------------------
            // Update loyalty balance
            //
            // New Balance =
            // Old Balance
            // + Points Earned
            // - Points Redeemed
            // -----------------------------------------------------

            loyalty.Points_Balance__c = currentBalance + pointsEarned - pointsRedeemed;


            loyalty.Total_Points_Earned__c = whole(loyalty.Total_Points_Earned__c) + pointsEarned;


            loyalty.Total_Points_Redeemed__c = whole(loyalty.Total_Points_Redeemed__c) + pointsRedeemed;


            // -----------------------------------------------------
            // Transaction Date
            //
            // Transaction_Date__c is DateTime.
            //
            // .date() converts DateTime -> Date.
            // -----------------------------------------------------

            Date transactionDate = transactionRecord.Transaction_Date__c == null ? Date.today()
                    : transactionRecord.Transaction_Date__c.date();


            if (
                loyalty.Last_Transaction_Date__c == null || loyalty.Last_Transaction_Date__c < transactionDate
            ) {
                loyalty.Last_Transaction_Date__c = transactionDate;
            }
        }


        // ---------------------------------------------------------
        // 6. Save Loyalty Records
        // ---------------------------------------------------------

        if (!loyaltyByAccount.isEmpty()) {

            upsert loyaltyByAccount.values();
        }


    }

    /**
     * Determines how many points can actually be redeemed.
     *
     * Rules:
     * - Balance must be >= 100.
     * - Bill must be positive.
     * - 1 point = Rs. 1.
     * - Cannot redeem more points than bill amount.
     * - If applicable redemption is < 100, no redemption occurs.
     */
    @TestVisible
    private static Integer pointsToApply( Integer balance, Decimal grossAmount ) {

        if (balance < MINIMUM_REDEEMABLE_POINTS) {
            return 0;
        }

        if (grossAmount == null || grossAmount <= 0) {
            return 0;
        }


        // Only whole rupees can be redeemed.
        Integer billAmount = Integer.valueOf( grossAmount.round( System.RoundingMode.DOWN ) );


        // Customer cannot redeem more than bill amount.
        Integer applicablePoints = Math.min( balance, billAmount );


        // Minimum redemption is 100 points.
        if (applicablePoints < MINIMUM_REDEEMABLE_POINTS) {
            return 0;
        }
        return applicablePoints;
    }
    /**
     * Calculates loyalty points.
     *
     * Example:
     *
     * netAmount = 3088
     * tierPercentage = 2
     *
     * floor(3088 / 100) = 30
     *
     * 30 * 2 = 60 points
     */
    @TestVisible
    private static Integer pointsFor( Decimal netAmount, Decimal tierPercentage) {

        if (netAmount == null || netAmount <= 0 || tierPercentage <= 0) {
            return 0;
        }

        Decimal completeHundreds = netAmount.divide(EARNING_BLOCK,0,System.RoundingMode.DOWN);


        Decimal points = completeHundreds * tierPercentage;


        return Integer.valueOf( points.setScale(0, System.RoundingMode.DOWN)
        );
    }

    /**
     * Net amount after loyalty-point redemption.
     */
    private static Decimal netAmountOf(Decimal grossAmount,Integer pointsRedeemed) {

        Decimal gross = grossAmount == null? 0 : grossAmount;


        Decimal redeemed = pointsRedeemed == null ? 0 : pointsRedeemed;


        Decimal net = gross - redeemed;


        return net < 0 ? 0 : net;
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
     *
     * If the metadata happens to contain "2%", "4%", etc.,
     * the '%' is removed.
     */
    @TestVisible
    private static Map<String, Decimal> earningRates() {

        Map<String, Decimal> rates = new Map<String, Decimal>();
        Loyalty_Setting__mdt records = [
                SELECT
                    Tier__c,
                    Earning_Rate__c
                FROM Loyalty_Setting__mdt
                WHERE Tier__c != null
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
        
        Loyalty_Record__c loyaltyList = [
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

    private static Integer whole(  Decimal value ) {
        if (value == null) { return 0; }
        return Integer.valueOf( value.setScale( 0, System.RoundingMode.DOWN ) );
    }
}