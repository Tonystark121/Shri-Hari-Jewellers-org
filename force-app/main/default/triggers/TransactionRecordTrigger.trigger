/**
 * Every bill pushed by the POS earns loyalty points as it lands.
 *
 * One trigger per object, no logic in the trigger body.
 */
trigger TransactionRecordTrigger on Transaction_Record__c (after insert) {

    if (Trigger.isAfter && Trigger.isInsert) {
        TransactionTriggerHandler.afterInsert(Trigger.new);
    }
}
