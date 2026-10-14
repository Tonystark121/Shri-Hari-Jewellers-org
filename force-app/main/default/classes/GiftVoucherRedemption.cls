/**
 * @description
 * Redemptions on a Transaction Record (bill), as reported by POS.
 *
 * POS decides the redemption; Salesforce records it. The bill carries what
 * happened at the till:
 *   - Points Redeemed (any whole number, 0 for none) - LoyaltyEngine deducts
 *     them from the balance after the bill is saved,
 *   - a gift voucher: Voucher Code, Offer Type, Face Value (Fixed Price) or
 *     Discount Percentage (Percentage), Voucher Discount in rupees and the
 *     Redemption Channel.
 * Both may appear on the same bill.
 *
 * Called by TransactionTriggerHandler, so every bill is checked however it is
 * created (Convert and New Transaction screens, POS API, data load). A bill
 * is rejected, with the reason, when:
 *   - a reported figure is missing or impossible (negative points, a voucher
 *     discount or points above the bill),
 *   - the voucher code is not in Salesforce, belongs to another customer,
 *     is not Active (already Redeemed, Cancelled or Expired) or is past its
 *     Expiry Date,
 *   - the same voucher is on two bills in one save.
 * The voucher's own offer, face value and bill range are not re-checked:
 * POS applied the offer, and its figures are kept on the bill.
 *
 * Net Amount = Amount - Voucher Discount - Points Redeemed; points are earned
 * on it.
 *
 * Vouchers are read and updated in system mode: the user or integration
 * saving a bill does not need access to the voucher records.
 */
public with sharing class GiftVoucherRedemption {

    @TestVisible
    private static final String REJECTED = 'The bill was not saved: ';

    private static final String STATUS_ACTIVE = 'Active';
    private static final String STATUS_REDEEMED = 'Redeemed';
    private static final String OFFER_FIXED = 'Fixed Price';
    private static final String OFFER_PERCENTAGE = 'Percentage';

    // =====================================================================
    // Trigger: before insert
    // =====================================================================

    /**
     * @description
     * Checks the reported redemptions, links the voucher and stamps Net
     * Amount. The vouchers are locked (FOR UPDATE), so two bills saved at the
     * same moment cannot both redeem the same voucher.
     */
    public static void beforeInsert(List<Transaction_Record__c> bills) {
        Set<String> codes = new Set<String>();
        List<Transaction_Record__c> voucherBills = new List<Transaction_Record__c>();

        for (Transaction_Record__c bill : bills) {
            // Only the system links the voucher record.
            bill.Gift_Voucher__c = null;
            bill.Points_Redeemed__c = bill.Points_Redeemed__c == null ? 0 : bill.Points_Redeemed__c;

            String problem = String.isBlank(bill.Voucher_Code__c) ? problemWithoutVoucher(bill) : problemWithVoucherDetails(bill);
            if (problem == null) {
                problem = problemWithPoints(bill);
            }
            if (problem != null) {
                bill.addError(REJECTED + problem);
                continue;
            }

            Decimal amount = bill.Amount__c == null ? 0 : bill.Amount__c;
            bill.Net_Amount__c = amount - bill.Voucher_Discount__c - bill.Points_Redeemed__c;

            if (String.isNotBlank(bill.Voucher_Code__c)) {
                bill.Voucher_Code__c = bill.Voucher_Code__c.trim();
                codes.add(bill.Voucher_Code__c);
                voucherBills.add(bill);
            }
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

    /** A bill without a voucher code must not carry a voucher discount; other voucher details are cleared. */
    private static String problemWithoutVoucher(Transaction_Record__c bill) {
        if (bill.Voucher_Discount__c != null && bill.Voucher_Discount__c != 0) {
            return 'a Voucher Discount is reported without a Voucher Code.';
        }
        bill.Voucher_Discount__c = 0;
        bill.Voucher_Offer_Type__c = null;
        bill.Voucher_Face_Value__c = null;
        bill.Voucher_Discount_Percentage__c = null;
        bill.Voucher_Redemption_Channel__c = null;
        return null;
    }

    /** Why the reported voucher details are incomplete or impossible, or null when they are fine. */
    @TestVisible
    private static String problemWithVoucherDetails(Transaction_Record__c bill) {
        String code = bill.Voucher_Code__c.trim();
        Decimal amount = bill.Amount__c == null ? 0 : bill.Amount__c;

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
        if (bill.Voucher_Discount__c == null || bill.Voucher_Discount__c <= 0) {
            return 'enter the Voucher Discount (rupees taken off the bill) of voucher ' + code + '.';
        }
        if (bill.Voucher_Discount__c > amount) {
            return 'the Voucher Discount (' + rupees(bill.Voucher_Discount__c) + ') is more than the bill Amount (' + rupees(amount) + ').';
        }
        if (String.isBlank(bill.Voucher_Redemption_Channel__c)) {
            return 'select the Voucher Redemption Channel of voucher ' + code + '.';
        }
        return null;
    }

    /** Why the reported points are impossible on this bill, or null when they are fine. */
    @TestVisible
    private static String problemWithPoints(Transaction_Record__c bill) {
        Decimal points = bill.Points_Redeemed__c;
        if (points < 0 || points != points.round(System.RoundingMode.DOWN)) {
            return 'Points Redeemed must be a whole number of 0 or more.';
        }
        // A return (negative Amount) reports no points, so only a redemption is compared with the bill.
        Decimal payable = (bill.Amount__c == null ? 0 : bill.Amount__c) - (bill.Voucher_Discount__c == null ? 0 : bill.Voucher_Discount__c);
        if (points > 0 && points > payable) {
            return 'Points Redeemed (' + points.intValue() + ') is more than the bill after the voucher discount (' + rupees(payable) + ').';
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

    private static String rupees(Decimal value) {
        return '₹' + (value == null ? '0' : value.setScale(2).format());
    }
}
