/**
 * Trigger logic for Transaction_Record__c.
 *
 * The trigger itself stays a one-liner and the work happens here, so the
 * behaviour is callable from tests and from a data fix without going through
 * a DML operation.
 */
public with sharing class TransactionTriggerHandler {

    /**
     * Set true to suppress loyalty processing for a single transaction —
     * used by data loads that carry their own historical point balances and
     * must not earn points a second time.
     */
    public static Boolean bypassLoyalty = false;

    public static void afterInsert(List<Transaction_Record__c> newTransactions) {

        if (bypassLoyalty) {
            return;
        }

        LoyaltyEngine.processEarn(newTransactions);
    }
}
