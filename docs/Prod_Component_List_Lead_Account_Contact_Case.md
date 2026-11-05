# Production Component List: Lead, Account, Contact and Case

Prepared 2026-11-05 from the UAT org (`shri_hari_uat`) and the local repo.
Manifest: `manifest/prod-lead-account-contact-case.xml`

## What works in production after this deploy

- **New Lead.** Covers duplicate and customer checks on Phone, WhatsApp and Email.
  - When the person is already a customer, an enquiry Case is raised instead.
  - When only a Contact is found, an Account is created for it first.
- **Upload Leads (CSV)** and the **Website Lead API**, both following the same rules.
- **Lead Stage tab.** Moves a lead through Contacted, Qualified, Unqualified and Converted; a follow-up Task is created when needed.
- **Convert Lead with a bill.** Creates or picks the Account and creates the Contact.
  - Merges names into B2B and B2C Accounts.
  - Carries over WhatsApp and opt-ins.
  - Saves the bill (Transaction Record) with its products as Purchase Line Items and Assets.
  - Opens the new Account when done.

Not part of this deploy: loyalty, gift vouchers, New Purchase (New Transaction) and the bill trigger.

---

## 1. Apex

| Component | Type | Why it is needed |
|---|---|---|
| LeadTrigger | Trigger | Runs all Lead checks: duplicates, customer match, B2C Company name |
| LeadTriggerHandler | Class | Trigger logic, plus the "Check Customer" action used by New Lead and Convert Lead |
| LeadConversionTransactionService | Class | "Convert Lead with Bill" action: Account, Contact, bill, line items, Assets |
| LeadUploadService | Class | Upload Leads CSV processing |
| ShreeHariLeadRestResource | Class | Website Lead API |
| SkuSearchController | Class | Product search on the Convert screen |
| LeadTriggerHandlerTest | Test | Production version needed (section 9) |
| LeadConversionTransactionServiceTest | Test | Production version needed (section 9) |
| LeadUploadServiceTest | Test | No change |
| ShreeHariLeadRestResourceTest | Test | No change |
| SkuSearchControllerTest | Test | No change |

## 2. Lightning Web Components

| Component | Why it is needed |
|---|---|
| recordRedirect | Opens the new Lead, Case or Account at the end of New Lead and Convert Lead |
| skuSearcher | Product picker on the Convert screen |

## 3. Flows (deploy as Active)

| Flow | Type | Why it is needed |
|---|---|---|
| New_Lead | Screen | New Lead button |
| Upload_Leads | Screen | Upload Leads button |
| Lead_Stage | Screen | Lead Stage tab on the Lead record page; calls Convert_Lead |
| Convert_Lead | Screen | Convert button and the "Converted" stage; Loyalty Redemption section stays hidden |
| Lead_Follow_up_Task | Record-triggered (Task) | Keeps the follow-up date and remark in step with the Lead |

## 4. Objects and fields (55 custom fields)

Account, Contact and Case are deployed **as fields only**. Their object files are not deployed, because the UAT versions point to record pages that are not in this scope.

**Lead.** The object file is deployed. It brings the Lead_Record_Page override, the list buttons, the compact layout, field history and list views.

Fields (16): Anniversary_Date__c, Business_Type__c, Campaign_Attribution__c, Contacted_Remark__c, Date_of_Birth__c, Email_Opt_In__c, Follow_up_Date_Time__c, Lead_Number__c, Marital_Status__c, Qualification_Notes__c, SMS_Opt_In__c, Store_Association__c, Unqualified_Date__c, Unqualified_Remark__c, WA_Opt_In__c, Walk_In_Flag__c.

**Account** fields (14): Anniversary_Date__c, Business_Type__c, CASA_ID__c, Campaign_Attribution__c, Customer_Tier__c, Date_of_Birth__c, Email__c, Email_Opt_In__c, Last_12M_Spend__c, Marital_Status__c, Primary_Store__c, SMS_Opt_In__c, WA_Opt_In__c, WhatsApp_Number__c.
- Customer_Tier__c and Last_12M_Spend__c are read by the customer match table and the Check Customer action.

**Contact** fields (2): Anniversary_Date__c, Marital_Status__c.

**Case** fields (3): Campaign__c, Lead_Source__c, Store__c.

**Activity** field (1): Follow_up_Date_Time__c.

**Product2** field (1): Available_Quantity__c, used by the product search.

**Store_Location__c (new object).** The store picker on Lead, Case, Account and the bill.
- Field (1): Store_Code__c, used by Upload and the API.

**Transaction_Record__c (new object; the bill saved at conversion).** Production version needed: remove the `New_Transaction` list button.

Fields (14):
- Account__c, Amount__c, Bill_Number__c, POS_Reference_ID__c, Payment_Mode__c, Store__c, Transaction_Date__c.
- Points_Redeemed__c and the 6 Voucher fields:
  - Voucher_Code__c
  - Voucher_Discount__c
  - Voucher_Discount_Percentage__c
  - Voucher_Face_Value__c
  - Voucher_Offer_Type__c
  - Voucher_Redemption_Channel__c
- These 7 are included only because the Convert_Lead flow refers to them. The section that fills them is hidden, so they always save as 0 or blank.

**Purchase_Line_Item__c (new object; one row per product on the bill).**
- Fields (3): Product__c, Purchase_Record__c (master-detail to the bill), Quantity__c.

**Asset** (standard): no changes; conversion creates one Asset per product.

## 5. Rules, picklists and settings

| Component | Type | Why it is needed |
|---|---|---|
| Lead.Phone_Must_Be_10_Digits | Validation rule | Phone format |
| Lead.WhatsApp_Must_Be_10_Digits | Validation rule | WhatsApp format |
| Lead.Valid_Anniversary_Date | Validation rule | Married only, after Date of Birth, not in the future |
| Transaction_Record__c.No_Future_Transaction_Date | Validation rule | Bill date check |
| Purchase_Line_Item__c.Quantity_At_Least_One | Validation rule | Quantity check |
| Lead.Lead_Duplicate_Rule | Matching rule | Phone OR Email OR WhatsApp; **second deploy** (section 10) |
| Lead.Lead_Duplicate_Check | Duplicate rule | Uses the matching rule; **second deploy** |
| LeadConvertSettings | Settings | Lead → Account mapping for DOB, Anniversary, Marital Status, Business Type, Campaign and Store → Primary Store |
| LeadSource | Standard value set | Lead Source channel values used in the flows, CSV and API |
| LeadStatus | Standard value set | New, Contacted, Qualified, Unqualified, Converted |
| CaseType | Standard value set | Enquiry Case type |
| Lead-en_US, Contact-en_US | Object translation | Renames Mobile to "WhatsApp Number" and Lead Source to "Lead Source Channel"; **not in the repo, retrieve from UAT** |

## 6. Pages, layouts, buttons, tabs and app

| Component | Type | Notes |
|---|---|---|
| Lead_Record_Page | Lightning page | Includes the Lead Stage tab |
| Transaction_Record_Record_Page | Lightning page | The bill object's View override points to it |
| Lead-Lead Layout | Layout | No change |
| Account-Account Layout | Layout | **Production version** (section 9) |
| Contact-Contact Layout | Layout | Personal Details section; no change |
| Case-Case Layout | Layout | Shows Lead Source; no change |
| Transaction_Record__c-Transaction Record Layout | Layout | **Production version** (section 9) |
| Purchase_Line_Item__c-Purchase Line Item Layout | Layout | **Production version** (section 9) |
| Store_Location__c-Store Location Layout | Layout | No change |
| Lead.Convert_Lead | Quick action | Convert button |
| Lead.New_Lead, Lead.Upload_Leads, Lead.Download_Lead_Template | List buttons | Lead list view buttons |
| Lead_Upload_Template | Static resource | CSV template, including the WhatsApp Number column |
| Store_Location__c, Transaction_Record__c | Tabs | Used by the app |
| ShriHari | App | **Production version** (section 9) |

## 7. Access

| Component | Notes |
|---|---|
| ShreeHari_CRM_User (permission set) | Staff access; **production version** (section 9) |
| Shree_Hari_Lead_API_Access (permission set) | Website API user; **production version**: remove the 6 Store Location fields that are not deployed |
| Shree_Hari_Website_API (External Client App) + Shree_Hari_Website_API_oauth | Website API login |

## 8. Not included

These are left out on purpose. Nothing in the Lead, Account, Contact or Case process needs them.

| Left out | Effect in production |
|---|---|
| TransactionRecordTrigger, TransactionTriggerHandler, LoyaltyEngine, GiftVoucherRedemption, LoyaltyPointsExpiryBatch, ShreeHariTrailingSpendBatch | Bills earn no points and Net Amount is not calculated. **Last 12M Spend stays blank, so Customer Tier always shows "Silver"** in the Convert match table. |
| DynamicFieldController, dynamicFieldSelection | Only used by loyalty and gift voucher screens |
| Flows: New_Transaction, Account_Create_Loyalty_Record, Allot_Loyalty_Points, Create_Gift_Voucher | No New Purchase button; no Loyalty Record on new Accounts |
| Objects: Loyalty_Record__c, Loyalty_Transaction__c, Gift_Voucher__c, Loyalty_Setting__mdt (+ records), Loyalty_Bypass__c | None |
| Account: CLV__c, Loyalty_Balance__c | Roll-ups on loyalty objects and Net Amount |
| Account: Relationship_Manager__c | Not used by any code. It is on the UAT Account layout, so the production layout leaves it out. Tell me if you want it kept. |
| Transaction_Record__c: Gift_Voucher__c, Net_Amount__c, Metal_Type__c, SKU_Details__c, Redeem_Points__c, Redeem_Gift_Voucher__c | Old or loyalty fields; nothing in scope reads or writes them |
| Purchase_Line_Item__c: SKU__c, Item_Description__c, Metal_Type__c, Weight_Grams__c, Unit_Price__c, Line_Amount__c | Conversion fills only Product and Quantity. Add these back if you want them visible for later. |
| Store_Location__c: Address__c, City__c, Is_Active__c, Latitude__c, Longitude__c, Store_Type__c | Not used by any code or layout |
| Account_Record_Page, Contact_Record_Page, Case_Record_Page, Loyalty_Record_Record_Page | Account, Contact and Case use the standard page with the deployed layouts |
| Lead_Path (Path setting) | The Lead page's path component works without it |

## 9. Production versions to prepare before deploying

The repo copies of these components refer to things left out above, so the deploy would fail as they are.

1. **Account-Account Layout**:
   - remove CLV__c, Loyalty_Balance__c and Relationship_Manager__c
   - remove the Loyalty Records and Gift Vouchers related lists
   - remove the New_Transaction and New_Gift_Voucher buttons
   - remove the Net_Amount__c column on the Transactions related list
2. **Transaction_Record__c object**: remove the `New_Transaction` list view button.
3. **Transaction Record Layout**:
   - remove Gift_Voucher__c and Net_Amount__c
   - in the Purchase Line Items related list, keep only Name, Product and Quantity
4. **Purchase Line Item Layout**: remove the 6 fields that are not deployed.
5. **ShriHari app**: remove the Loyalty Record, Gift Voucher and Loyalty Transaction tabs.
6. **ShreeHari_CRM_User**: remove everything that is not deployed:
   - the DynamicFieldController, LoyaltyEngine and GiftVoucherRedemption classes
   - the Loyalty and Gift Voucher objects and tabs, and Loyalty_Setting__mdt access
   - the excluded fields
7. **Shree_Hari_Lead_API_Access**: remove the 6 Store Location fields that are not deployed.
8. **LeadConversionTransactionServiceTest**: remove `theFirstBillEarnsLoyaltyPoints` and `pointsRedeemedOnTheConversionBillAreRecorded`. They query loyalty objects, so the class would not compile in production.
9. **LeadTriggerHandlerTest**:
   - remove the Loyalty Record assert (line 483)
   - set aside the 9 tests that need the commented-out Lead update trigger:
     - aB2cCompanyCannotBeChangedByHand
     - aFamilyFormatCompanyFollowsANameChange
     - anEarlierFormatCompanyFollowsANameChange
     - changingTheEmailToACustomerKnownOnlyAsAContactIsRefused
     - changingThePhoneToACustomersIsRefused
     - changingThePhoneToAnotherOpenLeadsIsRefusedInAnyFormat
     - changingTheWhatsAppNumberToATakenOneIsRefused
     - theB2cCompanyFollowsANameChange
     - twoLeadsCannotTakeTheSameNewPhoneInOneSave
10. **Lead-en_US / Contact-en_US**: retrieve them from UAT. They are not in the repo.

Deploy from a **production-only copy** of the source folder. A CustomObject entry in the manifest brings every field file in that object's folder, so the excluded fields must not be in that copy.

**Test results in UAT today (2026-11-05)**, for the 5 test classes above (139 tests):

- 130 pass, 9 fail; the 9 failures are the tests listed in item 9.
- Coverage:
  - LeadTrigger 100%
  - LeadTriggerHandler 79%
  - LeadConversionTransactionService 94%
  - LeadUploadService 94%
  - ShreeHariLeadRestResource 90%
  - SkuSearchController 100%

**Because the Lead update trigger stays off, production behaves like UAT does today:**
- editing a Lead's phone, WhatsApp or email to a taken number or email is **not** blocked
- a B2C Company name does **not** follow a name change and is **not** locked

## 10. Deployment order

**Before the deploy:**

1. **Check the System Administrator profile.** It must have field access to Lead.MobilePhone (in UAT it had none, and the deploy failed).
2. **Check address settings.** Make sure State and Country picklists match UAT, if addresses use them.

**Deploy 1:** everything in the manifest except the matching rule and duplicate rule.
- Validate first (`--dry-run`) with RunSpecifiedTests for the 5 test classes.

**Deploy 2:** the matching rule `Lead.Lead_Duplicate_Rule`.
- Wait until it shows **Active** in Setup.
- Then deploy the duplicate rule `Lead.Lead_Duplicate_Check`.

**After the deploy:**

1. **Flows.** Check that all 5 flows are Active.
2. **Permission sets.** Assign ShreeHari_CRM_User to staff and Shree_Hari_Lead_API_Access to the API integration user.
3. **Website API.** Set up the integration user, and share the consumer key and secret with the website team (both are created in production).

## 11. Data needed in production

| Data | Why |
|---|---|
| Store Location records, with Store Code (e.g. 000001) | Store pickers, CSV Store Code and API Store Code |
| Products (Product2), with Available Quantity | Product search on the Convert screen |
| Campaigns | CSV "Campaign Name" and the Campaign pickers |
