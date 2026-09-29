/**
 * @description
 * Gift voucher redemption on a Transaction Record (bill).
 *
 * Called by TransactionTriggerHandler, so no bill can be saved with an
 * invalid voucher however it is created (New Transaction flow, API, data
 * load). The New Transaction flow lists only the vouchers that pass these
 * same rules; this check still runs on save.
 *
 * A voucher can be redeemed on a bill when:
 *   - its code matches (case does not matter; codes are unique),
 *   - it belongs to the bill's Account,
 *   - its Status is Active,
 *   - its Expiry Date is on or after the transaction date,
 *   - the bill amount meets its range:
 *       Min and Max set  ->  Min <= amount <= Max
 *       Max only         ->  amount >= Max   (a Min of 0 counts as blank)
 *
 * Discount:
 *   Fixed Price  Face Value, never more than the bill
 *   Percentage   Discount Percentage of the total bill amount
 *
 * Only one redemption per bill: Redeem Points and Redeem Gift Voucher cannot
 * both be ticked.
 *
 * Vouchers are read and updated in system mode: the user saving a bill does
 * not need access to the voucher records to redeem one.
 */
public with sharing class GiftVoucherRedemption {

    @TestVisible
    private static final String ONE_REDEMPTION_ONLY =
        'Only one redemption is allowed per transaction. Select either Redeem Points or Redeem Gift Voucher.';
    @TestVisible
    private static final String INVALID_PREFIX = 'Voucher code is invalid: ';

    private static final String STATUS_ACTIVE = 'Active';
    private static final String STATUS_REDEEMED = 'Redeemed';
    private static final String OFFER_FIXED = 'Fixed Price';
    private static final String OFFER_PERCENTAGE = 'Percentage';

    // =====================================================================
    // Trigger: before insert
    // =====================================================================

    /**
     * @description
     * Rejects bills that tick both redemptions or carry an invalid voucher,
     * and stamps Gift Voucher, Voucher Discount, Points Redeemed (0) and Net
     * Amount (Amount - Voucher Discount) on every bill. LoyaltyEngine later
     * lowers Net Amount by any points redeemed.
     *
     * The vouchers are locked (FOR UPDATE), so two bills saved at the same
     * moment cannot both redeem the same voucher.
     */
    public static void beforeInsert(List<Transaction_Record__c> bills) {
        Set<String> codes = new Set<String>();

        for (Transaction_Record__c bill : bills) {
            // Only the system sets these.
            bill.Gift_Voucher__c = null;
            bill.Voucher_Discount__c = 0;
            bill.Points_Redeemed__c = 0;
            bill.Net_Amount__c = bill.Amount__c;

            if (bill.Redeem_Gift_Voucher__c != true) {
                continue;
            }
            if (bill.Redeem_Points__c == true) {
                bill.addError(ONE_REDEMPTION_ONLY);
                continue;
            }
            if (String.isBlank(bill.Voucher_Code__c)) {
                bill.Voucher_Code__c.addError('Enter the Voucher Code, or untick Redeem Gift Voucher.');
                continue;
            }
            if (String.isBlank(bill.Voucher_Redemption_Channel__c)) {
                bill.Voucher_Redemption_Channel__c.addError('Select the Voucher Redemption Channel.');
                continue;
            }
            bill.Voucher_Code__c = bill.Voucher_Code__c.trim();
            codes.add(bill.Voucher_Code__c);
        }

        if (codes.isEmpty()) {
            return;
        }

        Map<String, Gift_Voucher__c> voucherByCode = new Map<String, Gift_Voucher__c>();
        for (Gift_Voucher__c voucher : [
            SELECT Id, Account__c, Voucher_Code__c, Status__c, Expiry_Date__c, Offer_Type__c,
                   Face_Value__c, Discount_Percentage__c, Minimum_Amount__c, Maximum_Amount__c
            FROM Gift_Voucher__c
            WHERE Voucher_Code__c IN :codes
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            voucherByCode.put(voucher.Voucher_Code__c.toLowerCase(), voucher);
        }

        Set<Id> usedInThisSave = new Set<Id>();
        for (Transaction_Record__c bill : bills) {
            if (bill.Redeem_Gift_Voucher__c != true || bill.Redeem_Points__c == true
                || String.isBlank(bill.Voucher_Code__c) || String.isBlank(bill.Voucher_Redemption_Channel__c)) {
                continue;
            }

            Gift_Voucher__c voucher = voucherByCode.get(bill.Voucher_Code__c.toLowerCase());
            Date billDate = bill.Transaction_Date__c == null ? Date.today() : bill.Transaction_Date__c.date();
            String problem = problemWith(voucher, bill.Account__c, bill.Amount__c, billDate);

            if (problem == null && usedInThisSave.contains(voucher.Id)) {
                problem = 'this voucher is already being redeemed on another bill in the same save.';
            }
            if (problem != null) {
                bill.Voucher_Code__c.addError(INVALID_PREFIX + problem);
                continue;
            }

            usedInThisSave.add(voucher.Id);
            Decimal discount = discountFor(voucher, bill.Amount__c);
            bill.Gift_Voucher__c = voucher.Id;
            bill.Voucher_Discount__c = discount;
            bill.Net_Amount__c = bill.Amount__c - discount;
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

    /** Why the voucher cannot be redeemed on this bill, or null when it can. */
    @TestVisible
    private static String problemWith(Gift_Voucher__c voucher, Id accountId, Decimal amount, Date billDate) {
        if (voucher == null) {
            return 'no voucher has this code.';
        }
        if (voucher.Account__c != accountId) {
            return 'this voucher belongs to another customer.';
        }
        if (voucher.Status__c != STATUS_ACTIVE) {
            return 'this voucher is ' + (String.isBlank(voucher.Status__c) ? 'not Active' : voucher.Status__c) + '.';
        }
        if (voucher.Expiry_Date__c != null && voucher.Expiry_Date__c < billDate) {
            return 'this voucher expired on ' + voucher.Expiry_Date__c.format() + '.';
        }
        if (voucher.Offer_Type__c != OFFER_FIXED && voucher.Offer_Type__c != OFFER_PERCENTAGE) {
            return 'this voucher has no Offer Type set.';
        }
        if (voucher.Offer_Type__c == OFFER_FIXED && (voucher.Face_Value__c == null || voucher.Face_Value__c <= 0)) {
            return 'this voucher has no offer amount set.';
        }
        if (voucher.Offer_Type__c == OFFER_PERCENTAGE && (voucher.Discount_Percentage__c == null || voucher.Discount_Percentage__c <= 0)) {
            return 'this voucher has no discount percentage set.';
        }
        if (voucher.Maximum_Amount__c == null) {
            return 'this voucher has no Maximum Amount set.';
        }

        Decimal billAmount = amount == null ? 0 : amount;
        Decimal minimum = minimumOf(voucher);
        if (minimum != null) {
            if (billAmount < minimum || billAmount > voucher.Maximum_Amount__c) {
                return 'this voucher applies only to bills from ' + rupees(minimum) + ' to ' + rupees(voucher.Maximum_Amount__c)
                    + '; this bill is ' + rupees(billAmount) + '.';
            }
        } else if (billAmount < voucher.Maximum_Amount__c) {
            return 'this voucher applies only to bills of ' + rupees(voucher.Maximum_Amount__c)
                + ' or more; this bill is ' + rupees(billAmount) + '.';
        }
        return null;
    }

    /** Rupees off the bill. Never more than the bill. */
    @TestVisible
    private static Decimal discountFor(Gift_Voucher__c voucher, Decimal amount) {
        Decimal billAmount = amount == null ? 0 : amount;
        Decimal discount = voucher.Offer_Type__c == OFFER_FIXED
            ? voucher.Face_Value__c
            : (billAmount * voucher.Discount_Percentage__c / 100).setScale(2, System.RoundingMode.HALF_UP);
        return Math.min(discount, billAmount);
    }

    /** Minimum Amount, with 0 treated as blank. */
    private static Decimal minimumOf(Gift_Voucher__c voucher) {
        return (voucher.Minimum_Amount__c == null || voucher.Minimum_Amount__c == 0) ? null : voucher.Minimum_Amount__c;
    }

    private static String rupees(Decimal value) {
        return '₹' + (value == null ? '0' : value.setScale(2).format());
    }
}
