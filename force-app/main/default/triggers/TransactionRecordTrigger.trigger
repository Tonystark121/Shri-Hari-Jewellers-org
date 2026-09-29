/**
 * Every bill pushed by the POS earns loyalty points as it lands; a gift
 * voucher on the bill is checked before it is saved.
 *
 * One trigger per object, no logic in the trigger body.
 */
trigger TransactionRecordTrigger on Transaction_Record__c (before insert, after insert) {

    if (Trigger.isBefore && Trigger.isInsert) {
        TransactionTriggerHandler.beforeInsert(Trigger.new);
    }

    if (Trigger.isAfter && Trigger.isInsert) {
        TransactionTriggerHandler.afterInsert(Trigger.new);
    }
}
