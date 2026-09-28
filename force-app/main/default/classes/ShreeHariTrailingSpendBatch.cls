public without sharing class ShreeHariTrailingSpendBatch
    implements Database.Batchable<sObject>, Schedulable {

    public static final Integer WINDOW_DAYS = 365;

    /**
     * Transaction_Date__c is a DateTime, so both bounds are DateTimes too.
     *
     * The window is a rolling 365 days ending with today:
     *
     *   Transaction_Date__c >= (today - 364 days) 00:00:00
     *   Transaction_Date__c <  tomorrow 00:00:00
     *
     * The exclusive upper bound takes in all of today's trading. A bound of
     * `<= today 00:00:00` would drop every bill raised later today.
     */
    private final Datetime windowStart;
    private final Datetime windowEndExclusive;

    
    public ShreeHariTrailingSpendBatch() {

        Date today = Date.today();

        this.windowStart = windowStartFor(today);
        this.windowEndExclusive = windowEndExclusiveFor(today);
    }

    /** First instant inside the window: (today - 364 days) 00:00:00. */
    public static Datetime windowStartFor(Date today) {

        return Datetime.newInstance(
            today.addDays(-(WINDOW_DAYS - 1)),
            Time.newInstance(0, 0, 0, 0)
        );
    }

    /** First instant after the window: tomorrow 00:00:00. */
    public static Datetime windowEndExclusiveFor(Date today) {

        return Datetime.newInstance(
            today.addDays(1),
            Time.newInstance(23, 59, 59, 59)
        );
    }

    // =====================================================================
    // SCHEDULABLE
    // =====================================================================

    public void execute(SchedulableContext context) {

        Database.executeBatch(
            new ShreeHariTrailingSpendBatch(),
            200
        );
    }

    // =====================================================================
    // BATCHABLE
    // =====================================================================

    public Database.QueryLocator start(Database.BatchableContext context) {

        return Database.getQueryLocator([
            SELECT Id, Last_12M_Spend__c
            FROM Account
        ]);
    }

    public void execute( Database.BatchableContext context, List<Account> scope ) {

        if (scope.isEmpty()) {
            return;
        }

        Set<Id> accountIds = new Map<Id, Account>(scope).keySet();

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

            Id accountId = (Id) result.get('accountId');

            Decimal totalAmount = (Decimal) result.get('totalAmount');

            transactionTotals.put( accountId, totalAmount == null ? 0 : totalAmount );
        }

        List<Account> accountsToUpdate = new List<Account>();

        for (Account accountRecord : scope) {

            Decimal currentValue = accountRecord.Last_12M_Spend__c == null ? 0 : accountRecord.Last_12M_Spend__c;

            Decimal calculatedValue = transactionTotals.containsKey(accountRecord.Id) ? transactionTotals.get(accountRecord.Id) : 0;

            calculatedValue = calculatedValue.setScale( 2, System.RoundingMode.HALF_UP );

            if (currentValue != calculatedValue) {

                accountsToUpdate.add(
                    new Account( Id = accountRecord.Id, Last_12M_Spend__c = calculatedValue )
                );
            }
        }


        if (!accountsToUpdate.isEmpty()) {
            Database.update(accountsToUpdate, false);
        }
    }

    /**
     * Called after all batch chunks have completed.
     *
     * No Database.Stateful is required because we are not carrying
     * counters or collections between execute() transactions.
     */
    public void finish(Database.BatchableContext context) {

        System.debug(
            LoggingLevel.INFO,
            'ShreeHariTrailingSpendBatch completed. ' +
            'Window: ' +
            String.valueOf(windowStart) +
            ' up to (excluding) ' +
            String.valueOf(windowEndExclusive)
        );
    }
}