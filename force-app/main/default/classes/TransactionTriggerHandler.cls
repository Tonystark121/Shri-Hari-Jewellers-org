/**
 * Trigger logic for Transaction_Record__c.
 *
 * The trigger itself stays a one-liner and the work happens here.
 *
 * Runs without sharing because Last_12M_Spend__c is a system-maintained
 * figure: the user saving the bill may not have edit access to the
 * household's Account, and the tier must still move. LoyaltyEngine keeps
 * its own sharing rules.
 */
public without sharing class TransactionTriggerHandler {

    /** Start of every message that rejects a bill. */
    public static final String REJECTED = 'The bill was not saved: ';

    /**
     * Final bill handling. POS reports what happened at the till; the bill
     * is recorded accordingly:
     *
     *   - Points Redeemed: 0 when no points were spent.
     *   - Voucher Code filled in: a gift voucher was redeemed, and Voucher
     *     Discount is the rupees it took off. No Voucher Code: no voucher, so
     *     Voucher Discount is 0 and the other voucher details are cleared.
     *
     * Bills with impossible figures are rejected with the reason. Every other
     * bill gets Net Amount = Amount - Voucher Discount - Points Redeemed,
     * which is what the customer paid and what loyalty points are earned on.
     *
     * Net Amount is worked out here, for every bill, whether or not a voucher
     * or points were redeemed. GiftVoucherRedemption then checks and links
     * the voucher on the bills that carry one; it does not change the bill's
     * figures.
     */
    public static void beforeInsert(List<Transaction_Record__c> newTransactions) {

        if (newTransactions == null || newTransactions.isEmpty()) {
            return;
        }

        // ---------------------------------------------------------
        // 1. Check the reported figures and stamp Net Amount
        // ---------------------------------------------------------

        List<Transaction_Record__c> acceptedBills = new List<Transaction_Record__c>();

        for (Transaction_Record__c bill : newTransactions) {

            String problem = problemWithFigures(bill);

            if (problem != null) {
                bill.addError(REJECTED + problem);
                continue;
            }

            bill.Net_Amount__c = amountOf(bill) - bill.Voucher_Discount__c - bill.Points_Redeemed__c;
            acceptedBills.add(bill);
        }

        // ---------------------------------------------------------
        // 2. Check and link the gift vouchers reported on the bills
        // ---------------------------------------------------------

        if (!acceptedBills.isEmpty()) {
            GiftVoucherRedemption.beforeInsert(acceptedBills);
        }
    }

    public static void afterInsert(List<Transaction_Record__c> newTransactions) {

        if (newTransactions == null || newTransactions.isEmpty()) {
            return;
        }

        // ---------------------------------------------------------
        // 1. Mark redeemed gift vouchers
        // ---------------------------------------------------------

        GiftVoucherRedemption.afterInsert(newTransactions);

        // ---------------------------------------------------------
        // 2. Deduct the points POS reported as redeemed, earn new ones
        //
        // Skipped while Loyalty Bypass > Disable Earning is ticked
        // for the running user (historical bills loaded from CASA
        // have already had their loyalty effect).
        // ---------------------------------------------------------

        if (!isEarningDisabled()) {
            LoyaltyEngine.processEarn(newTransactions);
        }

        // ---------------------------------------------------------
        // 3. Recalculate Last 12 Month Spend
        // ---------------------------------------------------------

        recalculateLast12MonthSpend(newTransactions);
    }

    /**
     * Fills in the blanks POS may leave (Points Redeemed and Voucher
     * Discount become 0, voucher details are cleared on a bill without a
     * Voucher Code), then returns why the reported figures are impossible,
     * or null when they are fine.
     */
    @TestVisible
    private static String problemWithFigures(Transaction_Record__c bill) {

        Decimal amount = amountOf(bill);

        if (bill.Points_Redeemed__c == null) {
            bill.Points_Redeemed__c = 0;
        }

        if (bill.Voucher_Discount__c == null) {
            bill.Voucher_Discount__c = 0;
        }

        // No Voucher Code: no voucher was redeemed on this bill.
        if (String.isBlank(bill.Voucher_Code__c)) {

            if (bill.Voucher_Discount__c != 0) {
                return 'a Voucher Discount is reported without a Voucher Code.';
            }

            bill.Voucher_Offer_Type__c = null;
            bill.Voucher_Face_Value__c = null;
            bill.Voucher_Discount_Percentage__c = null;
            bill.Voucher_Redemption_Channel__c = null;

        } else {

            String code = bill.Voucher_Code__c.trim();

            if (bill.Voucher_Discount__c <= 0) {
                return 'enter the Voucher Discount (rupees taken off the bill) of voucher ' + code + '.';
            }

            if (bill.Voucher_Discount__c > amount) {
                return 'the Voucher Discount (' + rupees(bill.Voucher_Discount__c) + ') is more than the bill Amount (' + rupees(amount) + ').';
            }
        }

        Decimal points = bill.Points_Redeemed__c;

        if (points < 0 || points != points.round(System.RoundingMode.DOWN)) {
            return 'Points Redeemed must be a whole number of 0 or more.';
        }

        // A return (negative Amount) reports no points, so only a
        // redemption is compared with the bill.
        Decimal payable = amount - bill.Voucher_Discount__c;

        if (points > 0 && points > payable) {
            return 'Points Redeemed (' + points.intValue() + ') is more than the bill after the voucher discount (' + rupees(payable) + ').';
        }

        return null;
    }

    private static Decimal amountOf(Transaction_Record__c bill) {
        return bill.Amount__c == null ? 0 : bill.Amount__c;
    }

    private static String rupees(Decimal value) {
        return '₹' + (value == null ? '0' : value.setScale(2).format());
    }

    /** True when Loyalty Bypass > Disable Earning is ticked for the running user. */
    private static Boolean isEarningDisabled() {
        Loyalty_Bypass__c bypass = Loyalty_Bypass__c.getInstance();
        return bypass != null && bypass.Disable_Earning__c == true;
    }

    /**
     * Recalculates Last_12M_Spend__c for the households on these bills,
     * so Customer_Tier__c moves as soon as a bill lands instead of waiting
     * for the nightly ShreeHariTrailingSpendBatch.
     *
     * Uses the same rule as the batch: total of Amount__c for bills dated
     * from (today - 364 days) 00:00:00 up to, but not including, tomorrow
     * 00:00:00 - a rolling 365 days that includes all of today's trading -
     * rounded to 2 decimals, written only when the figure has changed.
     *
     * The Accounts are locked with FOR UPDATE so two bills for the same
     * household saved at the same moment cannot each total the window
     * without the other's bill and overwrite each other.
     */
    @TestVisible
    private static void recalculateLast12MonthSpend(List<Transaction_Record__c> newTransactions) {

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
        // 2. Window - same bounds as ShreeHariTrailingSpendBatch
        // ---------------------------------------------------------

        Datetime windowStart = ShreeHariTrailingSpendBatch.windowStartFor(Date.today());
        Datetime windowEndExclusive = ShreeHariTrailingSpendBatch.windowEndExclusiveFor(Date.today());

        // ---------------------------------------------------------
        // 3. Lock the Accounts, then total their windowed billing
        // ---------------------------------------------------------

        List<Account> accounts = [
            SELECT Id, Last_12M_Spend__c
            FROM Account
            WHERE Id IN :accountIds
            FOR UPDATE
        ];

        Map<Id, Decimal> transactionTotals = new Map<Id, Decimal>();
        List<AggregateResult> transactionRecords = [
                SELECT
                    Account__c accountId,
                    SUM(Amount__c) totalAmount
                FROM Transaction_Record__c
                WHERE Account__c IN :accountIds
                AND Transaction_Date__c >= :windowStart
                AND Transaction_Date__c < :windowEndExclusive
                GROUP BY Account__c
            ];

        for (AggregateResult result : transactionRecords) {

            Decimal totalAmount = (Decimal) result.get('totalAmount');

            transactionTotals.put(
                (Id) result.get('accountId'),
                totalAmount == null ? 0 : totalAmount
            );
        }

        // ---------------------------------------------------------
        // 4. Write only the figures that have moved
        // ---------------------------------------------------------

        List<Account> accountsToUpdate = new List<Account>();

        for (Account accountRecord : accounts) {

            Decimal currentValue = accountRecord.Last_12M_Spend__c == null ? 0 : accountRecord.Last_12M_Spend__c;

            Decimal calculatedValue = transactionTotals.containsKey(accountRecord.Id) ? transactionTotals.get(accountRecord.Id) : 0;

            calculatedValue = calculatedValue.setScale(2, System.RoundingMode.HALF_UP);

            if (currentValue != calculatedValue) {
                accountsToUpdate.add(
                    new Account(
                        Id = accountRecord.Id,
                        Last_12M_Spend__c = calculatedValue
                    )
                );
            }
        }

        // ---------------------------------------------------------
        // 5. Save
        //
        // allOrNone = false, same as the batch: an Account that
        // fails validation must not block the bill from saving. The
        // nightly batch corrects any figure missed here.
        // ---------------------------------------------------------

        if (!accountsToUpdate.isEmpty()) {
            Database.update(accountsToUpdate, false);
        }
    }
}