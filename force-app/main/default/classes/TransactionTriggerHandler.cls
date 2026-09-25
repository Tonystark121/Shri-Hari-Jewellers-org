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

    public static void afterInsert(List<Transaction_Record__c> newTransactions) {

        if (newTransactions == null || newTransactions.isEmpty()) {
            return;
        }

        // ---------------------------------------------------------
        // 1. Earn / redeem loyalty points
        // ---------------------------------------------------------

        LoyaltyEngine.processEarn(newTransactions);

        // ---------------------------------------------------------
        // 2. Recalculate Last 12 Month Spend
        // ---------------------------------------------------------

        recalculateLast12MonthSpend(newTransactions);
    }

    /**
     * Recalculates Last_12M_Spend__c for the households on these bills,
     * so Customer_Tier__c moves as soon as a bill lands instead of waiting
     * for the nightly ShreeHariTrailingSpendBatch.
     *
     * Uses the same rule as the batch: total of Amount__c for bills dated
     * from (today - 365 days) 00:00:00 to today 23:59:59.999, rounded to
     * 2 decimals, written only when the figure has changed.
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

        Date today = Date.today();

        Datetime windowEnd = Datetime.newInstance(
            today, Time.newInstance(23,59,59,99)
        );

        Datetime windowStart = Datetime.newInstance(
            today.addDays(-365), Time.newInstance(0, 0, 0, 0)
        );

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
                AND Transaction_Date__c <= :windowEnd
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
