/**
 * @description
 * The gift voucher reported by POS on a Transaction Record (bill).
 *
 * A filled-in Voucher Code means POS redeemed a voucher on the bill, with its
 * Offer Type, Face Value (Fixed Price) or Discount Percentage (Percentage),
 * Voucher Discount in rupees and the Redemption Channel. A bill without a
 * Voucher Code is left alone.
 *
 * Only the voucher record is handled here. The bill's figures (Voucher
 * Discount, Points Redeemed, Net Amount) are checked and stamped by
 * TransactionTriggerHandler before this class is called, for every bill.
 *
 * Called by TransactionTriggerHandler, so every bill is checked however it is
 * created (Convert and New Transaction screens, POS API, data load). A bill
 * with a voucher is rejected, with the reason, when:
 *   - the voucher details are incomplete (Offer Type, Face Value or
 *     Percentage, Redemption Channel),
 *   - the voucher code is not in Salesforce, belongs to another customer,
 *     is not Active (already Redeemed, Cancelled or Expired) or is past its
 *     Expiry Date,
 *   - the same voucher is on two bills in one save.
 * The voucher's own offer, face value and bill range are not re-checked:
 * POS applied the offer, and its figures are kept on the bill.
 *
 * Vouchers are read and updated in system mode: the user or integration
 * saving a bill does not need access to the voucher records.
 */
public with sharing class GiftVoucherRedemption {

    @TestVisible
    private static final String REJECTED = TransactionTriggerHandler.REJECTED;

    private static final String STATUS_ACTIVE = 'Active';
    private static final String STATUS_REDEEMED = 'Redeemed';
    private static final String OFFER_FIXED = 'Fixed Price';
    private static final String OFFER_PERCENTAGE = 'Percentage';

    // =====================================================================
    // Trigger: before insert
    // =====================================================================

    /**
     * @description
     * Checks the voucher on each bill that carries a Voucher Code and links
     * it. The vouchers are locked (FOR UPDATE), so two bills saved at the
     * same moment cannot both redeem the same voucher.
     */
    public static void beforeInsert(List<Transaction_Record__c> bills) {
        Set<String> codes = new Set<String>();
        List<Transaction_Record__c> voucherBills = new List<Transaction_Record__c>();

        for (Transaction_Record__c bill : bills) {
            // Only the system links the voucher record.
            bill.Gift_Voucher__c = null;

            // No Voucher Code: no voucher was redeemed on this bill.
            if (String.isBlank(bill.Voucher_Code__c)) {
                continue;
            }

            String problem = problemWithVoucherDetails(bill);
            if (problem != null) {
                bill.addError(REJECTED + problem);
                continue;
            }

            bill.Voucher_Code__c = bill.Voucher_Code__c.trim();
            codes.add(bill.Voucher_Code__c);
            voucherBills.add(bill);
        }

        if (codes.isEmpty()) {
            return;
        }

        Map<String, Gift_Voucher__c> voucherByCode = new Map<String, Gift_Voucher__c>();
        for (Gift_Voucher__c voucher : [
            SELECT Id, Account__c, Voucher_Code__c, Status__c, Expiry_Date__c
            FROM Gift_Voucher__c
            WHERE Voucher_Code__c IN :codes
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            voucherByCode.put(voucher.Voucher_Code__c.toLowerCase(), voucher);
        }

        Set<Id> usedInThisSave = new Set<Id>();
        for (Transaction_Record__c bill : voucherBills) {
            Gift_Voucher__c voucher = voucherByCode.get(bill.Voucher_Code__c.toLowerCase());
            Date billDate = bill.Transaction_Date__c == null ? Date.today() : bill.Transaction_Date__c.date();
            String problem = problemWith(voucher, bill.Voucher_Code__c, bill.Account__c, billDate);

            if (problem == null && usedInThisSave.contains(voucher.Id)) {
                problem = 'voucher ' + bill.Voucher_Code__c + ' is on another bill in the same save.';
            }
            if (problem != null) {
                bill.addError(REJECTED + problem);
                continue;
            }

            usedInThisSave.add(voucher.Id);
            bill.Gift_Voucher__c = voucher.Id;
        }
    }

    // =====================================================================
    // Trigger: after insert
    // =====================================================================

    /**
     * @description
     * Marks each redeemed voucher: Status Redeemed, Redemption Date = bill
     * date, Redemption Channel = the bill's Voucher Redemption Channel.
     */
    public static void afterInsert(List<Transaction_Record__c> bills) {
        List<Gift_Voucher__c> redeemed = new List<Gift_Voucher__c>();
        for (Transaction_Record__c bill : bills) {
            if (bill.Gift_Voucher__c == null) {
                continue;
            }
            redeemed.add(new Gift_Voucher__c(
                Id = bill.Gift_Voucher__c,
                Status__c = STATUS_REDEEMED,
                Redemption_Date__c = bill.Transaction_Date__c == null ? Date.today() : bill.Transaction_Date__c.date(),
                Redemption_Channel__c = bill.Voucher_Redemption_Channel__c
            ));
        }
        if (!redeemed.isEmpty()) {
            update as system redeemed;
        }
    }

    // =====================================================================
    // Rules
    // =====================================================================

    /**
     * Why the reported voucher details are incomplete, or null when they are
     * fine. Voucher Discount is checked with the bill's other figures by
     * TransactionTriggerHandler.
     */
    @TestVisible
    private static String problemWithVoucherDetails(Transaction_Record__c bill) {
        String code = bill.Voucher_Code__c.trim();

        if (bill.Voucher_Offer_Type__c != OFFER_FIXED && bill.Voucher_Offer_Type__c != OFFER_PERCENTAGE) {
            return 'enter the Voucher Offer Type (Fixed Price or Percentage) of voucher ' + code + '.';
        }
        if (bill.Voucher_Offer_Type__c == OFFER_FIXED && (bill.Voucher_Face_Value__c == null || bill.Voucher_Face_Value__c <= 0)) {
            return 'enter the Voucher Face Value of voucher ' + code + '.';
        }
        if (bill.Voucher_Offer_Type__c == OFFER_PERCENTAGE
            && (bill.Voucher_Discount_Percentage__c == null || bill.Voucher_Discount_Percentage__c <= 0 || bill.Voucher_Discount_Percentage__c > 100)) {
            return 'enter the Voucher Discount Percentage (more than 0, up to 100) of voucher ' + code + '.';
        }
        if (String.isBlank(bill.Voucher_Redemption_Channel__c)) {
            return 'select the Voucher Redemption Channel of voucher ' + code + '.';
        }
        return null;
    }

    /** Why the voucher cannot be recorded as redeemed on this bill, or null when it can. */
    @TestVisible
    private static String problemWith(Gift_Voucher__c voucher, String code, Id accountId, Date billDate) {
        if (voucher == null) {
            return 'voucher ' + code + ' is not in Salesforce. Check the code on the POS bill.';
        }
        if (voucher.Account__c != accountId) {
            return 'voucher ' + code + ' belongs to another customer.';
        }
        if (voucher.Status__c != STATUS_ACTIVE) {
            return 'voucher ' + code + ' is ' + (String.isBlank(voucher.Status__c) ? 'not Active' : voucher.Status__c) + ' in Salesforce.';
        }
        if (voucher.Expiry_Date__c != null && voucher.Expiry_Date__c < billDate) {
            return 'voucher ' + code + ' expired on ' + voucher.Expiry_Date__c.format() + '.';
        }
        return null;
    }
}