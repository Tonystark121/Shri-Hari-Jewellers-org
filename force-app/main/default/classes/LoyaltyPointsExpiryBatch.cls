/**
 * Daily loyalty points expiry.
 *
 * An earning lot (Loyalty_Transaction__c, Transaction_Type__c = Earn) can be
 * spent up to and including its Expiry_Date__c (Credit Date + 365 for
 * points earned on a bill, or a custom date e.g. for gift vouchers) - see
 * LoyaltyEngine.eligibleLots(). From the next day on, whatever is still
 * unspent on the lot is lost:
 *
 *   Loyalty_Transaction__c.Status__c        Active -> Expired
 *   Loyalty_Transaction__c.Remaining_Points__c  left as it is: it records
 *                                           how many points expired
 *   Loyalty_Record__c.Points_Balance__c     reduced by those points
 *   Loyalty_Record__c.Total_Points_Expired__c  roll-up summary of
 *                                           Remaining_Points__c over the
 *                                           Expired lots - recalculated by
 *                                           the platform, not written here
 *
 * The engine already refuses to redeem from expired lots, so redemptions are
 * correct even before this job runs. The job brings the stored balance and
 * the lot statuses in line with that.
 *
 * Scheduled daily from Setup > Apex Classes > Schedule Apex.
 */
public without sharing class LoyaltyPointsExpiryBatch
    implements Database.Batchable<sObject>, Schedulable {

    @TestVisible
    private static final String LEDGER_TYPE_EARN = 'Earn';

    @TestVisible
    private static final String LEDGER_STATUS_ACTIVE = 'Active';

    @TestVisible
    private static final String LEDGER_STATUS_EXPIRED = 'Expired';

    /**
     * A lot whose Expiry_Date__c is before this date has expired. Fixed when
     * the batch is created, so every chunk uses the same date even if the
     * run crosses midnight.
     */
    private final Date asOf;

    public LoyaltyPointsExpiryBatch() {
        this(Date.today());
    }

    @TestVisible
    private LoyaltyPointsExpiryBatch(Date asOf) {
        this.asOf = asOf;
    }

    // =====================================================================
    // SCHEDULABLE
    // =====================================================================

    public void execute(SchedulableContext context) {

        Database.executeBatch(
            new LoyaltyPointsExpiryBatch(),
            200
        );
    }

    // =====================================================================
    // BATCHABLE
    // =====================================================================

    /**
     * Only the Loyalty Records holding at least one lot to expire.
     *
     * The batch runs over the parent, not the lots, so that all of a
     * household's expired lots are handled in one chunk and its balance is
     * reduced once.
     */
    public Database.QueryLocator start(Database.BatchableContext context) {

        String earnType = LEDGER_TYPE_EARN;
        String activeStatus = LEDGER_STATUS_ACTIVE;
        Date cutOff = asOf;

        return Database.getQueryLocator([
            SELECT Id
            FROM Loyalty_Record__c
            WHERE Id IN (
                SELECT Loyalty_Record__c
                FROM Loyalty_Transaction__c
                WHERE Transaction_Type__c = :earnType
                  AND Status__c = :activeStatus
                  AND Remaining_Points__c > 0
                  AND Expiry_Date__c < :cutOff
            )
            WITH SYSTEM_MODE
        ]);
    }

    public void execute(Database.BatchableContext context, List<Loyalty_Record__c> scope) {

        if (scope.isEmpty()) {
            return;
        }

        Set<Id> loyaltyIds = new Map<Id, Loyalty_Record__c>(scope).keySet();

        // ---------------------------------------------------------
        // 1. Lock the Loyalty Records
        //
        // LoyaltyEngine locks the same rows before it spends lots
        // and moves the balance. Locking here means a bill saved
        // while this job runs cannot interleave with it, and the
        // lots and balance read below are current.
        // ---------------------------------------------------------

        Map<Id, Loyalty_Record__c> loyaltyById = new Map<Id, Loyalty_Record__c>([
            SELECT Id, Points_Balance__c
            FROM Loyalty_Record__c
            WHERE Id IN :loyaltyIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ]);

        // ---------------------------------------------------------
        // 2. Expire the lots
        //
        // Re-read after the lock: a redemption since start() may
        // have emptied a lot (it is then Redeemed and skipped).
        // ---------------------------------------------------------

        String earnType = LEDGER_TYPE_EARN;
        String activeStatus = LEDGER_STATUS_ACTIVE;

        List<Loyalty_Transaction__c> expiredLots = [
            SELECT Id, Loyalty_Record__c, Remaining_Points__c
            FROM Loyalty_Transaction__c
            WHERE Loyalty_Record__c IN :loyaltyIds
              AND Transaction_Type__c = :earnType
              AND Status__c = :activeStatus
              AND Remaining_Points__c > 0
              AND Expiry_Date__c < :asOf
            WITH SYSTEM_MODE
        ];

        if (expiredLots.isEmpty()) {
            return;
        }

        Map<Id, Integer> expiredPointsByLoyalty = new Map<Id, Integer>();

        for (Loyalty_Transaction__c lot : expiredLots) {

            lot.Status__c = LEDGER_STATUS_EXPIRED;

            Integer expired = whole(lot.Remaining_Points__c);
            Integer soFar = expiredPointsByLoyalty.containsKey(lot.Loyalty_Record__c) ? expiredPointsByLoyalty.get(lot.Loyalty_Record__c) : 0;

            expiredPointsByLoyalty.put(lot.Loyalty_Record__c, soFar + expired);
        }

        // ---------------------------------------------------------
        // 3. Reduce the balance
        //
        // New Balance = Old Balance - Points Expired, never negative.
        // ---------------------------------------------------------

        List<Loyalty_Record__c> loyaltyToUpdate = new List<Loyalty_Record__c>();

        for (Id loyaltyId : expiredPointsByLoyalty.keySet()) {

            Loyalty_Record__c loyalty = loyaltyById.get(loyaltyId);

            loyaltyToUpdate.add(
                new Loyalty_Record__c(
                    Id = loyaltyId,
                    Points_Balance__c = Math.max(0, whole(loyalty.Points_Balance__c) - expiredPointsByLoyalty.get(loyaltyId))
                )
            );
        }

        // ---------------------------------------------------------
        // 4. Save
        //
        // All or nothing: a lot marked Expired without its balance
        // reduced (or the reverse) would double-count or lose points.
        // A failure rolls back this chunk only, and tomorrow's run
        // picks the same lots up again.
        // ---------------------------------------------------------

        update as system expiredLots;
        update as system loyaltyToUpdate;
    }

    public void finish(Database.BatchableContext context) {

        System.debug(
            LoggingLevel.INFO,
            'LoyaltyPointsExpiryBatch completed. Lots with Expiry Date before ' +
            String.valueOf(asOf) +
            ' expired.'
        );
    }

    private static Integer whole(Decimal value) {
        if (value == null) { return 0; }
        return Integer.valueOf(value.setScale(0, System.RoundingMode.DOWN));
    }
}
