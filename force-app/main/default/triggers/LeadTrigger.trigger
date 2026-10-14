/**
 * Cleans the phone, assigns the B2C Company and stops Leads for existing
 * customers. See LeadTriggerHandler.
 *
 * One trigger per object, no logic in the trigger body.
 */
trigger LeadTrigger on Lead (before insert, after insert, before update) {

    if (Trigger.isBefore && Trigger.isInsert) {
        LeadTriggerHandler.beforeInsert(Trigger.new);
    }

    if (Trigger.isAfter && Trigger.isInsert) {
        LeadTriggerHandler.afterInsert(Trigger.new);
    }

    if (Trigger.isBefore && Trigger.isUpdate) {
        LeadTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
    }
}
