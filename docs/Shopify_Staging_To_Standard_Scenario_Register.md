# Shopify Staging → Standard Objects: Scenario Register

This file is the single place that records how every Shopify customer, product and order scenario is handled when a staging record is turned into standard Salesforce records.

| Staging object | Becomes |
|---|---|
| `Staging_Customer__c` | Account + Contact |
| `Staging_Product__c` + `Staging_Product_Variant__c` | Product2 + PricebookEntry (in a Pricebook2) |
| `Staging_Order__c` | Order + OrderItem |

**How to use it:** find the scenario by its ID (C = customer, P = product, O = order, E = engine). Each row says what happens and its status. When a rule changes, change the row and add a line to the change log at the bottom.

**Status values**

| Status | Meaning |
|---|---|
| Proposed | Recommended design. Not confirmed, not built. |
| Open (D-n) | Depends on decision D-n in section 2. The row shows the recommended answer. |
| Confirmed | Agreed. Not built yet. |
| Built | In the repo. |
| Tested | Tested end to end in UAT. |

**Current state (2026-11-24):** design only. Nothing in this file is built or deployed.

---

## 1. Facts this design is based on

Checked in the repo and in UAT on 2026-11-24.

| # | Fact | Why it matters |
|---|---|---|
| F1 | Every API call inserts a new staging row. The same Shopify id appears on several rows (customer `7364019208386` is on SC-1, SC-2 and SC-4). | Staging is a history, not one row per record. The processor must use the newest row per id. |
| F2 | The payloads carry no `updated_at`. | The only ordering available is the order in which rows arrived. |
| F3 | Money arrives in paise (Shopify Liquid format): `12500000` = ₹1,25,000.00. In the order sample, tax `337500` is 3% of subtotal `11250000`. One exception: `store_credit_account.balance.amount` is rupees as text (`"2500.00"`). | Every price and total must be divided by 100. |
| F4 | Only `id` is required by the three APIs. Rows exist with no name, no email, no phone, no `created_at`, and with ids like `gid://shopify/Order/999`. | Each of these needs a defined outcome. |
| F5 | Real variants arrive with a blank SKU (all variants of SP-7, SP-8, SP-9). | SKU cannot be the product key. The Shopify variant id must be. |
| F6 | Staging rows SP-0 to SP-4 and SP-6 have `Variants_Count__c` of 1 or 2 but no variant child rows. | A product can arrive without its variants. |
| F7 | UAT has 12 Product2 records (SKU `SH-NK-001` style), 0 PricebookEntry records, 0 Orders, and only the Standard Price Book. Product2 `Family` has one value, `None`. | Price book entries have to be created from scratch. Product type cannot go into `Family` as it stands. |
| F8 | Order `Status` has two values: Draft and Activated. Order has two record types: `Draft_Order` (default) and `Order_Record`. `EffectiveDate` and `Status` are required. | Shopify's financial and fulfilment statuses need their own fields. |
| F9 | Person Accounts are off. A B2C customer is an Account named `<Surname> Family (<First>)` with a Contact under it (`LeadConversionTransactionService.familyAccountName`). | Shopify customers follow the same shape. |
| F10 | Customer matching already exists: `LeadTriggerHandler.findCustomers` / `findAccounts` match any phone against Account Phone / WhatsApp, Contact Phone / Mobile, and email against Account `Email__c` and Contact Email. Phones are stored as typed and matched on the 10-digit number. | Reused as is, so Shopify matching behaves like Lead, Upload and POS matching. |
| F11 | Standard Account and Contact duplicate rules are active. No validation rules exist on Account, Contact, Order, OrderItem, Product2 or PricebookEntry. | Inserts must be saved with "allow save" (as `LeadConversionTransactionService.saveDespiteDuplicates` does). |
| F12 | Loyalty points, Net Amount and Last 12M Spend are driven by `Transaction_Record__c` (the bill), not by Order. Creating an Account auto-creates its Loyalty Record (flow `Account_Create_Loyalty_Record`). | A Shopify order earns nothing unless a bill is created for it (decision D-4). |
| F13 | Earlier business rules: "Account means a customer which has some purchase", and a Lead converts only when it buys. | Conflicts with creating an Account for a Shopify customer who has never ordered (decision D-1). |
| F14 | The `HIC_ShopifySync` managed package has its own Shopify fields on Account, Contact, Product2, Order and OrderItem. | Not used. All new fields are unmanaged. |

---

## 2. Decisions needed

Each scenario marked `Open (D-n)` waits on one of these. The recommended option is listed first.

| ID | Decision | Options | Status |
|---|---|---|---|
| D-1 | A Shopify customer with no order (`orders_count` = 0): what do they become? | **A. Lead with Lead Source Shopify** (matches F13; becomes Account + Contact on first order). B. Account + Contact straight away. C. Stay in staging until an order arrives. | Open |
| D-2 | What is one Product2? | **A. One Product2 per variant** (each variant has its own SKU, price and stock, and an order line points at a variant). B. One Product2 per Shopify product, variants kept only in staging. | Open |
| D-3 | Which price book holds Shopify prices? | **A. Standard Price Book only.** B. Standard plus a separate "Shopify" price book that Orders use. | Open |
| D-4 | Does a paid Shopify order count for loyalty points, Last 12M Spend and tier? | **A. Not in this phase; Order + OrderItem only. Add the bill in the next phase.** B. Yes now: create one `Transaction_Record__c` per paid order. | Open |
| D-5 | The buyer on an order matches an open Lead. | **A. Convert the Lead into the order's Account.** B. Leave the Lead; create the Account separately. | Open |
| D-6 | Phone and email match two or more different Accounts. | **A. Stop, mark the staging row Failed with the list of matches, staff decide.** B. Use the most recently modified Account. | Open |
| D-7 | A matched existing customer has different values from Shopify. | **A. Contact linked by Shopify id: Shopify updates name, email, phone, address. Account: fill blanks only, never overwrite.** B. Fill blanks only everywhere. C. Shopify overwrites everywhere. | Open |
| D-8 | An order line refers to a product that is not in Salesforce yet. | **A. Create the product from the line item's own data, then save the order.** B. Hold the order as Failed and retry until the product arrives. | Open |
| D-9 | Owner and Primary Store of customers created from Shopify. | Needs a named default owner and, if wanted, an "Online" Store Location. Without a decision the owner is the integration user and Primary Store is blank. | Open |
| D-10 | Order record type. | **A. `Order_Record`.** B. `Draft_Order` (current default). Need to know what each was created for. | Open |
| D-11 | Confirmation from the sender that all money values are always in paise. | Confirm with whoever sends the calls. | Open |
| D-12 | Which customer metafields does the real store send? The sample has `custom.date_of_birth`, `custom.anniversary_date`, `custom.preferred_store`. | Confirm the real keys before they are mapped. | Open |
| D-13 | Gift card products and discount codes: any link to `Gift_Voucher__c`? | **A. No link in this phase.** B. Match discount code to Voucher Code and redeem. | Open |

---

## 3. How processing works

| ID | Scenario | Handling | Status |
|---|---|---|---|
| E-01 | When conversion runs | The API call only saves the staging row and answers 201, as today. Conversion runs afterwards in the background (trigger on the staging object starts a queueable job). A conversion failure never rejects the call. | Proposed |
| E-02 | Status of a staging row | `New` → `Processed` or `Failed`. New value `Superseded` for an older row that was replaced before it was processed. The reason for a failure goes to `Processing_Error__c`. | Proposed |
| E-03 | Several rows for the same Shopify id | Only the newest unprocessed row per id is converted. Older unprocessed rows become `Superseded`. | Proposed |
| E-04 | A row arrives for an id already processed | Converted as an update to the same Salesforce record. No second record is created. | Proposed |
| E-05 | Order of arrival (F2) | The newest row wins. If Shopify sends two changes out of order, the older change can overwrite the newer one. Recommended fix: ask the sender to include `updated_at`; rows with an older `updated_at` than the Salesforce record would then be `Superseded`. | Proposed |
| E-06 | Dependencies between objects | Each order resolves its own customer and products (sections 4 and 6), so an order does not wait for the customer or product call. Within one run: products, then customers, then orders. | Proposed |
| E-07 | One record fails | Only that record is rolled back and marked `Failed`. Other records in the same run continue. A row is written to `Integration_Log__c`. | Proposed |
| E-08 | Retry | A scheduled job picks up rows still `New` after 15 minutes and `Failed` rows whose cause can clear by itself (record locked, product not yet arrived). Maximum 5 attempts, counted in a new field `Retry_Count__c`. | Proposed |
| E-09 | Manual reprocess | Staff set `Processing_Status__c` back to `New` on a Failed row; the trigger queues it again. | Proposed |
| E-10 | Reprocessing a Processed row | Produces the same result. Nothing is duplicated, because every target record is found by its Shopify id first. | Proposed |
| E-11 | Two rows for the same new customer processed at the same time | The unique Shopify id field on Contact stops the second insert; that row is retried and then finds the Contact. | Proposed |
| E-12 | Ids sent as `gid://shopify/Order/999` | The number after the last `/` is used as the id, so `999` and the gid form are the same record. | Proposed |
| E-13 | Traceability | Staging row gets lookups to what it created (Account, Contact, Order) and `Processed_At__c`. Target records hold the Shopify id. | Proposed |
| E-14 | Permissions | Conversion runs in system mode. It does not depend on the integration user's access to Account, Order or Product2. | Proposed |
| E-15 | Existing staging rows in UAT (9 customers, 10 products, 10 orders, all `New`) | Not converted automatically on deployment. Converted by a one-off run when asked. | Proposed |
| E-16 | Historical load from Shopify | Same path as live data, run as a batch. | Proposed |

---

## 4. Customer → Account + Contact

Key: the Shopify customer id is stored on the **Contact** (new field `Shopify_Customer_Id__c`, unique, external id). One Shopify customer is one person. A family Account can hold several of them.

### 4.1 Finding the customer

| ID | Scenario | Handling | Status |
|---|---|---|---|
| C-01 | A Contact already has this Shopify customer id | That Contact and its Account are used. Updated per C-20 to C-22. | Proposed |
| C-02 | No id match; phone or email matches exactly one Account (rules in F10) | That Account is used. If a Contact on it has the same name, phone and email, it gets the Shopify id. Otherwise a new Contact is created under the Account (a family member sharing a phone is a different person, as in Lead conversion). | Proposed |
| C-03 | No id match; phone and email match different Accounts | Row marked `Failed`, error lists the Accounts. Nothing is created. | Open (D-6) |
| C-04 | No id match; matches a Contact that has no Account | An Account is created for that Contact and the Contact moved under it (same rule as New Lead and Upload Leads). The Contact gets the Shopify id. | Proposed |
| C-05 | No match at all, customer has at least one order | New Account + new Contact. | Proposed |
| C-06 | No match at all, customer has no order (`orders_count` 0 or blank) | A Lead is created (Lead Source Shopify), following the existing Lead rules. No Account. | Open (D-1) |
| C-07 | Matches an open Lead, customer has no order | No new Lead. The row is marked `Processed` with a note naming the existing Lead. | Open (D-1) |
| C-08 | Matches an open Lead, customer has orders | The Lead is converted into the customer's Account. | Open (D-5) |
| C-09 | Phone present, email blank (or the reverse) | Matched on whichever is present. | Proposed |
| C-10 | No phone and no email | Cannot be matched or contacted. Row marked `Failed`: "no phone or email". Exception: O-13. | Proposed |
| C-11 | Phone is not an Indian 10-digit number | Not used for matching. Matched on email only. The phone is still saved as sent. | Proposed |
| C-12 | Shopify customer id changed (accounts merged in Shopify) | The new id finds no Contact, then phone/email finds the existing one (C-02). The Contact's Shopify id is replaced with the new id. | Proposed |

### 4.2 Creating the customer

| ID | Scenario | Handling | Status |
|---|---|---|---|
| C-13 | B2C customer (`b2b?` false or missing) | Account name `<Surname> Family (<First>)`, Business Type B2C. Contact with first and last name. | Proposed |
| C-14 | B2B customer (`b2b?` true) | Account name = company name from `current_company`; Business Type B2B. Company name missing → treated as B2C. | Proposed |
| C-15 | `first_name` and `last_name` blank | Last name taken from `name`; else the default address name; else the part of the email before `@`; else the phone number. | Proposed |
| C-16 | Only `first_name` given | Used as the Last Name (same as the abandoned checkout API). | Proposed |
| C-17 | Phone format | Saved exactly as sent (`+919830012345`). Existing matching already finds this form. | Proposed |
| C-18 | Owner and Primary Store | Default owner and store per D-9. | Open (D-9) |
| C-19 | Loyalty Record | Created automatically by the existing Account flow. Balance 0. | Proposed |

### 4.3 Field mapping and updates

| ID | Shopify property | Goes to | Rule | Status |
|---|---|---|---|---|
| C-20 | `first_name`, `last_name`, `email`, `phone` | Contact FirstName, LastName, Email, Phone. On a new Account also Account Phone and `Email__c`. | New record: set. Existing Contact linked by Shopify id: updated from Shopify. Existing Account: filled only when blank. | Open (D-7) |
| C-21 | `default_address` | Contact Mailing Address. On a new Account also Billing and Shipping Address. | Same rule as C-20. | Open (D-7) |
| C-22 | `accepts_marketing` | Account `Email_Opt_In__c` | The latest value sent wins, including a change from true to false (an opt-out is always honoured). SMS and WhatsApp opt-in are not touched. | Proposed |
| C-23 | `metafields.custom.date_of_birth`, `anniversary_date` | Account `Date_of_Birth__c`, `Anniversary_Date__c`; Contact Birthdate, `Anniversary_Date__c` | Filled only when blank. An unreadable date is skipped, not a failure. | Open (D-12) |
| C-24 | `metafields.custom.preferred_store` | Account `Primary_Store__c` | Only if the text matches a Store Location; otherwise left blank. | Open (D-12) |
| C-25 | `id` | Contact `Shopify_Customer_Id__c` | Always. | Proposed |
| C-26 | Lead Source / Account Source | `Shopify` | Set on records this process creates. Never changed on existing records. | Proposed |
| C-27 | `addresses` (other than default), `orders`, `last_order`, `orders_count`, `total_spent`, `payment_methods`, `store_credit_account`, `tags`, `has_account`, `has_avatar?`, `tax_exempt`, `company_available_locations`, `current_location` | Not copied | They stay readable on the staging row. Order figures come from the Orders themselves. | Proposed |
| C-28 | A value longer than the target field | Trimmed to the field length; the full value stays in staging. | Proposed |
| C-29 | Customer deleted or redacted in Shopify | No such call exists in the API. Not handled. | Proposed |

---

## 5. Product → Product2 + PricebookEntry

Key: new field `Shopify_Variant_Id__c` on Product2 (unique, external id), plus `Shopify_Product_Id__c` (not unique) to group the variants of one Shopify product.

### 5.1 Finding and creating products

| ID | Scenario | Handling | Status |
|---|---|---|---|
| P-01 | Product with several variants | One Product2 per variant. Name = `<product title> - <variant title>` (the same text Shopify shows on an order line). | Open (D-2) |
| P-02 | Product with only the default variant (`has_only_default_variant` true, or variant title `Default Title`) | One Product2. Name = product title. | Proposed |
| P-03 | Variant id already on a Product2 | That Product2 is updated. | Proposed |
| P-04 | Variant id not found, SKU matches exactly one Product2 that has no Shopify variant id | That Product2 is linked (gets the variant id) and updated. This is how the 12 existing `SH-…` products join up. | Proposed |
| P-05 | Variant id not found, SKU matches more than one Product2 | No SKU match is made. A new Product2 is created. | Proposed |
| P-06 | Variant SKU blank (F5) | No SKU matching. Found by variant id only. Product2 SKU and Product Code left blank. | Proposed |
| P-07 | Two variants share one SKU | Each is its own Product2, found by variant id. | Proposed |
| P-08 | Product arrives with no variants (F6) | One Product2 found by `Shopify_Product_Id__c` with a blank variant id. Price = product `price`. | Proposed |
| P-09 | Variants arrive later for a product created by P-08 | One variant: the existing Product2 takes that variant id. Several variants: the P-08 record is deactivated (kept, because orders may point at it) and one Product2 per variant is created. | Proposed |
| P-10 | A later call leaves out a variant that was sent before | That Product2 is deactivated, only when the call carried a variants list and the number received equals `variants_count`. A partial list deactivates nothing. | Proposed |
| P-11 | Product deleted in Shopify | No such call exists in the API. Not handled. | Proposed |
| P-12 | `title` blank | Name = `handle`; else `Shopify product <id>`. | Proposed |
| P-13 | Gift card product (`gift_card?` true) | Stored as a normal Product2 with a Gift Card flag. No Gift Voucher is created. | Open (D-13) |
| P-14 | Product created from an order line (O-21) and the product call arrives later | Found by variant id and filled in with the full details. | Proposed |

### 5.2 Field mapping

| ID | Shopify property | Goes to | Rule | Status |
|---|---|---|---|---|
| P-15 | variant `sku` | Product2 `StockKeepingUnit` and `ProductCode` | Updated on each call. | Proposed |
| P-16 | `description` | Product2 `Description` | HTML tags removed, cut to 4,000 characters. | Proposed |
| P-17 | `type` | New text field `Shopify_Product_Type__c` | `Family` is not used: its only value is `None` and a new type would be rejected. | Proposed |
| P-18 | `vendor`, `handle`, `url` | New fields on Product2; `DisplayUrl` gets the storefront URL when the store domain is known. | Updated on each call. | Proposed |
| P-19 | variant `inventory_quantity` | Existing `Available_Quantity__c` | Updated on each call. This is Shopify stock only, not showroom stock. | Proposed |
| P-20 | `available`, `published_at` | Do not change `IsActive` | Out of stock is not inactive. `IsActive` stays true so the product can still be put on an order. | Proposed |
| P-21 | variant `weight`, `weight_unit`, `option1`–`option3`, `barcode` | New fields on Product2 (Weight, Weight Unit, Option 1–3, Barcode) | Updated on each call. | Proposed |
| P-22 | `images`, `media`, `collections`, `tags`, `metafields`, `options_with_values`, selling plan properties | Not copied | Stay on the staging rows. | Proposed |

### 5.3 Price book

| ID | Scenario | Handling | Status |
|---|---|---|---|
| P-23 | Price of a new Product2 | PricebookEntry in the Standard Price Book, Unit Price = variant `price` ÷ 100, active. | Open (D-3, D-11) |
| P-24 | Price changes on a later call | The PricebookEntry's Unit Price is updated. Existing orders do not change: each order line keeps the price it was sold at. | Proposed |
| P-25 | Variant `price` blank | Unit Price 0. The entry is still created so the product can be put on an order. | Proposed |
| P-26 | `compare_at_price` | New field `Compare_At_Price__c` on Product2 (÷ 100). Not a price book entry. | Proposed |
| P-27 | `price_min`, `price_max`, `price_varies` | Not copied. Each variant carries its own price. | Proposed |
| P-28 | Existing 12 products with no price book entry | An entry is created the first time Shopify sends a price for them (P-04). Until then they have none. | Proposed |

---

## 6. Order → Order + OrderItem

Key: new field `Shopify_Order_Id__c` on Order and `Shopify_Line_Item_Id__c` on OrderItem (both unique, external id).

### 6.1 The order header

| ID | Scenario | Handling | Status |
|---|---|---|---|
| O-01 | New order | One Order, Account = the buyer's Account, Bill To Contact = the buyer's Contact, price book per D-3. | Proposed |
| O-02 | Same order id arrives again | The existing Order is updated: statuses, totals, addresses, lines (O-25). | Proposed |
| O-03 | `name` (`#1042`), `order_number`, `confirmation_number` | `name` → Order Name and Order Reference Number. The other two → new fields. | Proposed |
| O-04 | `created_at` | Order Start Date (`EffectiveDate`) = the date in India time. New field `Shopify_Created_At__c` keeps date and time. | Proposed |
| O-05 | `created_at` blank (F4) | Order Start Date = the date the staging row was received. | Proposed |
| O-06 | Order Status | Saved as Draft, lines added, then Activated. Shopify statuses are kept in their own fields (O-07). | Proposed |
| O-07 | `financial_status`, `fulfillment_status`, `cancelled`, `cancelled_at`, `cancel_reason` | New picklist and date fields on Order with the Shopify values spelled exactly as Shopify sends them. | Proposed |
| O-08 | Order not yet paid (`pending`, `authorized`, `unpaid`) | Converted like any other order. It is a real order. | Proposed |
| O-09 | Order cancelled, first seen already cancelled | Order created with the cancelled fields set, so the history is complete. | Proposed |
| O-10 | Order cancelled after it was converted | Cancelled fields updated on the existing Order. The Order is not deleted. | Proposed |
| O-11 | Refund (`refunded`, `partially_refunded`, `total_refunded_amount`) | Financial status and Total Refunded updated. No reduction order and no change to lines. | Proposed |
| O-12 | `billing_address`, `shipping_address` | Order Billing Address and Shipping Address. | Proposed |
| O-13 | Record type | Per D-10. | Open (D-10) |
| O-14 | `note`, `tags`, `attributes`, `pickup_in_store?` | `note` → Order Description. `pickup_in_store?` → new checkbox. `tags`, `attributes` not copied. | Proposed |
| O-15 | `transactions` (payments) | Gateway names joined into one new text field `Payment_Gateway__c` (for example `Razorpay`). Individual payments not copied. | Proposed |

### 6.2 Money

All values ÷ 100 (F3, D-11).

| ID | Shopify property | Goes to | Status |
|---|---|---|---|
| O-16 | `line_items_subtotal_price` | Equals the standard Order Amount (sum of lines). Not stored separately. | Proposed |
| O-17 | `total_discounts`, `subtotal_price`, `tax_price`, `shipping_price`, `total_duties`, `total_price`, `total_net_amount`, `total_refunded_amount` | New currency fields on Order with the same names. | Proposed |
| O-18 | Standard Order Amount vs what the customer paid | Order Amount is the sum of the lines before order-level discount, tax and shipping. **`Total_Price__c` is what the customer paid.** In the sample: Order Amount ₹1,25,000.00, Total Price ₹1,15,875.00. | Proposed |
| O-19 | Discount codes (`discount_applications`) | Code names joined into a new text field `Discount_Codes__c`. No Gift Voucher redemption. | Open (D-13) |

### 6.3 The buyer

| ID | Scenario | Handling | Status |
|---|---|---|---|
| O-20 | `customer.id` matches a Contact | That Contact and its Account. | Proposed |
| O-21 | No id match | Matched by the order's email and phone (order `email`, `phone`, then `customer`, then billing and shipping address phone), using the customer rules C-02 to C-04. | Proposed |
| O-22 | No match at all | Account + Contact created from the order's own data (name from `customer`, else billing address, else shipping address). An order is a purchase, so D-1 does not apply. | Proposed |
| O-23 | Guest checkout (`customer` blank) | Same as O-21 and O-22 using the order's email and phone. No Shopify customer id is saved. | Proposed |
| O-24 | Order has no customer, no email and no phone (SO-2, SO-3, SO-4) | Row marked `Failed`: "no customer details". Nothing is created. | Proposed |
| O-25 | Customer id present but no email or phone anywhere | Account + Contact created and keyed on the Shopify customer id. A real order is not dropped. | Proposed |
| O-26 | Buyer matches an open Lead | Lead converted into the order's Account. | Open (D-5) |
| O-27 | Buyer was a Shopify-sourced Lead from C-06 | Same as O-26. | Open (D-1, D-5) |
| O-28 | Buyer matches several Accounts | Row marked `Failed` with the list of matches. | Open (D-6) |
| O-29 | The customer call arrives after the order | It finds the Contact (by id, or by phone/email for a guest) and updates it. No duplicate. | Proposed |

### 6.4 Order lines

| ID | Scenario | Handling | Status |
|---|---|---|---|
| O-30 | Normal line | One OrderItem: product found by `variant_id`, Quantity = `quantity`, Unit Price = `final_price` ÷ 100. List Price comes from the price book. | Proposed |
| O-31 | Variant not found by id | Found by `sku` (rules P-04, P-05). | Proposed |
| O-32 | Product not in Salesforce at all | Product2 and price book entry created from the line item (title, sku, variant id, product id, price), then the line is saved. | Open (D-8) |
| O-33 | Line has no variant and no product (custom item, or the product was deleted in Shopify) | Linked to one fixed placeholder Product2, `Shopify Custom Item`. The line title goes to the line Description. | Proposed |
| O-34 | Product exists but has no active price book entry | The entry is created or reactivated with the line's price. | Proposed |
| O-35 | Product is inactive in Salesforce (P-09, P-10) | The line is still saved. A past sale stays on record. | Proposed |
| O-36 | `quantity` 0 | No OrderItem (an order line cannot have quantity 0). An existing OrderItem for that line is removed. | Proposed |
| O-37 | Line discounts and tax | New fields on OrderItem: `Original_Price__c`, `Line_Discount__c`, `Tax__c`. | Proposed |
| O-38 | Line `properties` (engraving, gift box) | Written into the line Description as `Engraving: A & R; Gift box: Red velvet`. | Proposed |
| O-39 | Line `title`, `sku`, variant title | New fields on OrderItem, kept as sold even if the product is renamed later. | Proposed |
| O-40 | Order has no line items (SO-2 to SO-6) | Order created as Draft with no lines and left Draft (an order with no lines cannot be activated). Row marked `Processed` with a note. | Proposed |
| O-41 | Lines changed on a later call (item added, removed, quantity changed) | Order set back to Draft, lines matched by `Shopify_Line_Item_Id__c` (update, add, remove), Order activated again. | Proposed |
| O-42 | `line_items` too long for the staging field (about 7 lines in the full Shopify form) | The API already rejects the call with `VALUE_TOO_LONG`, so staging never holds a cut-off list. The sender must use the slimmer line shape. | Built (existing API) |
| O-43 | Gift card line (`gift_card` true) | Normal line. No Gift Voucher created. | Open (D-13) |
| O-44 | Line `fulfillment` (tracking number, courier) | Not copied in this phase. | Proposed |

### 6.5 Loyalty and spend

| ID | Scenario | Handling | Status |
|---|---|---|---|
| O-45 | Paid Shopify order and loyalty points, Last 12M Spend, tier | No effect in this phase. Only `Transaction_Record__c` bills drive these (F12). | Open (D-4) |
| O-46 | If D-4 is answered "yes" | One bill per order, created the first time the order is seen as `paid`, Bill Number `SHOPIFY-<order id>` (unique, so it can never be created twice), Amount = Total Price. Refund and cancellation after the bill exists need their own rule before this is built. | Open (D-4) |

---

## 7. New components this design needs

Nothing here exists yet.

| Type | Component |
|---|---|
| Fields on Contact | `Shopify_Customer_Id__c` (unique, external id) |
| Fields on Product2 | `Shopify_Variant_Id__c` (unique, external id), `Shopify_Product_Id__c`, `Shopify_Product_Type__c`, `Vendor__c`, `Handle__c`, `Compare_At_Price__c`, `Weight__c`, `Weight_Unit__c`, `Option1__c`–`Option3__c`, `Barcode__c`, `Gift_Card__c` |
| Fields on Order | `Shopify_Order_Id__c` (unique, external id), `Order_Number__c`, `Confirmation_Number__c`, `Shopify_Created_At__c`, `Financial_Status__c`, `Fulfillment_Status__c`, `Cancelled__c`, `Cancelled_At__c`, `Cancel_Reason__c`, `Pickup_In_Store__c`, `Payment_Gateway__c`, `Discount_Codes__c`, `Total_Discounts__c`, `Subtotal_Price__c`, `Tax_Price__c`, `Shipping_Price__c`, `Total_Duties__c`, `Total_Price__c`, `Total_Net_Amount__c`, `Total_Refunded_Amount__c` |
| Fields on OrderItem | `Shopify_Line_Item_Id__c` (unique, external id), `Title__c`, `SKU__c`, `Variant_Title__c`, `Original_Price__c`, `Line_Discount__c`, `Tax__c` |
| Fields on the three staging objects | `Processed_At__c`, `Retry_Count__c`; picklist value `Superseded`; lookups to the records created |
| Apex | One trigger per staging object; a processor (queueable + scheduled retry); one sync class each for customer, product and order; tests. Reuses `LeadTriggerHandler` matching, `LeadConversionTransactionService` naming and `IntegrationLogService`. |
| Data | Product2 `Shopify Custom Item` (O-33) |
| Access | Field access for the profiles and permission sets that should see the new fields |

---

## 8. Change log

| Date | Change |
|---|---|
| 2026-11-24 | First version. Design only; all scenarios Proposed or Open. |
