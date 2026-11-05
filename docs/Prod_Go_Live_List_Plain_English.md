# Shree Hari CRM: Production Deployment List, in Deployment Order

**Release:** Leads, Customers (Accounts and Contacts) and Enquiries (Cases)
**Prepared:** 5 November 2026
**Technical version:** `docs/Prod_Component_List_Lead_Account_Contact_Case.md`

**How to read this list**

- **Name** is what staff see on screen. **API name** is the name Salesforce uses internally; an admin can search Setup for it.
- **Deploy the steps in the order given.** Each step only uses things deployed in earlier steps.
- **Deploying in one go:** a technical team deploying everything in one package can skip the ordering, because Salesforce sorts it out itself. Two exceptions still apply:
  - Step 2 must include the two master-detail fields with their objects.
  - Step 18 must still come last.

---

## What staff will be able to do after go-live

1. **Add a new lead.** Salesforce first checks the phone, WhatsApp number and email.
   - **Already a customer?** It raises an enquiry for that customer instead of creating a duplicate lead.
   - **Already an open lead?** It stops and says so.
2. **Upload many leads at once** from a spreadsheet (CSV file), with the same checks.
3. **Receive leads from the website** automatically, with the same checks.
4. **Move a lead through its stages:** New → Contacted → Qualified → Converted, or Unqualified.
5. **Convert a lead when they buy.** Staff enter the bill and products.
   - Salesforce creates or updates the customer and saves the bill.
   - It then opens the customer's page.

**Not going live yet:** loyalty points, gift vouchers and the separate "New Purchase" screen.

---

## Before you start: checks in production

| Check | Why |
|---|---|
| The System Administrator profile can see the lead's Mobile field (`Lead.MobilePhone`) | In UAT this was missing and the deploy failed |
| State and Country picklist settings match UAT | Address fields on the New Lead form |

---

## Step 1: Drop-down values (standard picklist value sets)

| Name | API name | What it holds |
|---|---|---|
| Lead Source values | LeadSource | Instagram, Walk-in, Google and the other channels |
| Lead Status values | LeadStatus | New, Contacted, Qualified, Unqualified, Converted |
| Case Type values | CaseType | Enquiry types on a Case |

## Step 2: New objects (record types)

Deploy in this order. The last two take their access from a parent record, so each **must be deployed together with its master-detail field** (shown in the table).

| # | Name | API name | Deploy together with | What it holds |
|---|---|---|---|---|
| 1 | Store Location | Store_Location__c | none | The list of stores |
| 2 | Purchase Record | Transaction_Record__c | Household Account (`Transaction_Record__c.Account__c`) | The bill entered at conversion |
| 3 | Purchase Line Item | Purchase_Line_Item__c | Purchase Record (`Purchase_Line_Item__c.Purchase_Record__c`) | Each product on a bill |

**Production version needed:** for Purchase Record, remove the "New Purchase" list button (`New_Transaction`) and leave the page assignment for Step 14.

## Step 3: Custom fields (53, plus the 2 deployed in Step 2 = 55)

Deploy them in the order of the table. Fields marked † need Step 2. Last 12 Month Spend must come before Customer Tier, because Customer Tier is calculated from it.

| # | Object | Name | API name |
|---|---|---|---|
| 1 | Store Location | Store Code | Store_Location__c.Store_Code__c |
| 2 | Lead | Date of Birth | Lead.Date_of_Birth__c |
| 3 | Lead | Marital Status | Lead.Marital_Status__c |
| 4 | Lead | Anniversary Date | Lead.Anniversary_Date__c |
| 5 | Lead | Business Type | Lead.Business_Type__c |
| 6 | Lead | Lead Number | Lead.Lead_Number__c |
| 7 | Lead | Store Association † | Lead.Store_Association__c |
| 8 | Lead | Campaign Association | Lead.Campaign_Attribution__c |
| 9 | Lead | Walk-In Flag | Lead.Walk_In_Flag__c |
| 10 | Lead | WA Opt In | Lead.WA_Opt_In__c |
| 11 | Lead | SMS Opt In | Lead.SMS_Opt_In__c |
| 12 | Lead | Email Opt In | Lead.Email_Opt_In__c |
| 13 | Lead | Contacted Remark | Lead.Contacted_Remark__c |
| 14 | Lead | Follow-up Date and Time | Lead.Follow_up_Date_Time__c |
| 15 | Lead | Qualification Notes | Lead.Qualification_Notes__c |
| 16 | Lead | Unqualified Date | Lead.Unqualified_Date__c |
| 17 | Lead | Unqualified Remark | Lead.Unqualified_Remark__c |
| 18 | Account | WhatsApp Number | Account.WhatsApp_Number__c |
| 19 | Account | Email | Account.Email__c |
| 20 | Account | Date of Birth | Account.Date_of_Birth__c |
| 21 | Account | Marital Status | Account.Marital_Status__c |
| 22 | Account | Anniversary Date | Account.Anniversary_Date__c |
| 23 | Account | Business Type | Account.Business_Type__c |
| 24 | Account | Primary Store † | Account.Primary_Store__c |
| 25 | Account | Campaign Association | Account.Campaign_Attribution__c |
| 26 | Account | CASA ID | Account.CASA_ID__c |
| 27 | Account | WA Opt In | Account.WA_Opt_In__c |
| 28 | Account | SMS Opt In | Account.SMS_Opt_In__c |
| 29 | Account | Email Opt In | Account.Email_Opt_In__c |
| 30 | Account | Last 12 Month Spend | Account.Last_12M_Spend__c |
| 31 | Account | Customer Tier (calculated from #30) | Account.Customer_Tier__c |
| 32 | Contact | Anniversary Date | Contact.Anniversary_Date__c |
| 33 | Contact | Marital Status | Contact.Marital_Status__c |
| 34 | Case | Lead Source | Case.Lead_Source__c |
| 35 | Case | Store † | Case.Store__c |
| 36 | Case | Campaign | Case.Campaign__c |
| 37 | Task / Event | Follow-up Date and Time | Activity.Follow_up_Date_Time__c |
| 38 | Product | Available Quantity | Product2.Available_Quantity__c |
| 39 | Purchase Record | Amount † | Transaction_Record__c.Amount__c |
| 40 | Purchase Record | Bill Number † | Transaction_Record__c.Bill_Number__c |
| 41 | Purchase Record | POS Reference ID † | Transaction_Record__c.POS_Reference_ID__c |
| 42 | Purchase Record | Payment Mode † | Transaction_Record__c.Payment_Mode__c |
| 43 | Purchase Record | Store † | Transaction_Record__c.Store__c |
| 44 | Purchase Record | Purchase Date † | Transaction_Record__c.Transaction_Date__c |
| 45 | Purchase Record | Points Redeemed* † | Transaction_Record__c.Points_Redeemed__c |
| 46 | Purchase Record | Voucher Code* † | Transaction_Record__c.Voucher_Code__c |
| 47 | Purchase Record | Voucher Discount* † | Transaction_Record__c.Voucher_Discount__c |
| 48 | Purchase Record | Voucher Discount Percentage* † | Transaction_Record__c.Voucher_Discount_Percentage__c |
| 49 | Purchase Record | Voucher Face Value* † | Transaction_Record__c.Voucher_Face_Value__c |
| 50 | Purchase Record | Voucher Offer Type* † | Transaction_Record__c.Voucher_Offer_Type__c |
| 51 | Purchase Record | Voucher Redemption Channel* † | Transaction_Record__c.Voucher_Redemption_Channel__c |
| 52 | Purchase Line Item | Product † | Purchase_Line_Item__c.Product__c |
| 53 | Purchase Line Item | Quantity † | Purchase_Line_Item__c.Quantity__c |

\* Needed only because the Convert screen refers to it. Staff won't see or fill it, because the loyalty section is hidden.

## Step 4: Field label renames (translations)

**Copy these from UAT first.** They are not in the project files.

| Name | API name | What it changes |
|---|---|---|
| Lead label renames | Lead-en_US | "Mobile" → "WhatsApp Number"; "Lead Source" → "Lead Source Channel" |
| Contact label rename | Contact-en_US | "Mobile" → "WhatsApp Number" |

## Step 5: Validation rules

| Name | API name | What it stops |
|---|---|---|
| Phone must be 10 digits | Lead.Phone_Must_Be_10_Digits | Wrong phone numbers on a lead |
| WhatsApp must be 10 digits | Lead.WhatsApp_Must_Be_10_Digits | Wrong WhatsApp numbers on a lead |
| Valid anniversary date | Lead.Valid_Anniversary_Date | An anniversary date unless Married, after the Date of Birth and not in the future |
| Purchase date not in the future | Transaction_Record__c.No_Future_Transaction_Date | Bills dated after today |
| Quantity at least 1 | Purchase_Line_Item__c.Quantity_At_Least_One | Product lines with quantity 0 |

## Step 6: Lead conversion field mapping

| Name | API name | What it does |
|---|---|---|
| Lead convert settings | LeadConvertSettings | On conversion, copies Date of Birth, Anniversary, Marital Status, Business Type, Campaign and Store from the lead to the customer |

## Step 7: Background logic (Apex code and its automatic tests)

Deploy these together. **Production runs the 5 test classes during this step; they must all pass.**

| # | Name | API name | Type | What it does |
|---|---|---|---|---|
| 1 | Lead checks logic | LeadTriggerHandler | Apex class | Duplicate and customer checks, enquiries, B2C company name |
| 2 | Conversion logic | LeadConversionTransactionService | Apex class | Creates the customer, contact, bill and products |
| 3 | CSV upload logic | LeadUploadService | Apex class | Reads the uploaded file and prepares the results file |
| 4 | Website leads | ShreeHariLeadRestResource | Apex class | Receives leads from the website |
| 5 | Product search logic | SkuSearchController | Apex class | Powers the product search box |
| 6 | Lead save checks | LeadTrigger | Trigger | Runs the lead checks whenever a lead is saved |
| 7 | Tests | LeadTriggerHandlerTest | Test class | **Production version needed** (see "Production versions to prepare") |
| 8 | Tests | LeadConversionTransactionServiceTest | Test class | **Production version needed** |
| 9 | Tests | LeadUploadServiceTest | Test class | No change |
| 10 | Tests | ShreeHariLeadRestResourceTest | Test class | No change |
| 11 | Tests | SkuSearchControllerTest | Test class | No change |

## Step 8: Screen components

| Name | API name | What it does |
|---|---|---|
| Product search box | skuSearcher | Finds products on the Convert screen and shows available stock |
| Automatic jump to the new record | recordRedirect | After saving, opens the new lead, enquiry or customer |

## Step 9: Files

| Name | API name | What it is |
|---|---|---|
| Lead upload template | Lead_Upload_Template | The blank CSV file staff download |

## Step 10: Flows (screens and automation)

Deploy in this order and make sure each one is **Active**. Lead Stage opens the Convert screen, so Convert Lead must go before it.

| # | Name | API name | What it does |
|---|---|---|---|
| 1 | Lead follow-up task | Lead_Follow_up_Task | Keeps the lead's follow-up date and remark in step with its task |
| 2 | Convert Lead | Convert_Lead | The Convert screen: bill, products, customer |
| 3 | Lead Stage | Lead_Stage | Moves a lead to its next stage |
| 4 | New Lead | New_Lead | The New Lead form with all checks |
| 5 | Upload Leads | Upload_Leads | The CSV upload screen |

## Step 11: Buttons and actions

| Name | API name | Type | Opens |
|---|---|---|---|
| New | Lead.New_Lead | List button | New Lead form |
| Upload Leads | Lead.Upload_Leads | List button | Upload Leads screen |
| Download Template | Lead.Download_Lead_Template | List button | The CSV template |
| Convert | Lead.Convert_Lead | Quick action | Convert screen |

## Step 12: Page layouts

| Name | API name | Notes |
|---|---|---|
| Lead summary bar | Lead.Lead_Compact_Layout | Key fields at the top of the lead page |
| Lead layout | Lead-Lead Layout | No change |
| Account layout | Account-Account Layout | **Production version needed** |
| Contact layout | Contact-Contact Layout | No change |
| Case layout | Case-Case Layout | No change |
| Store Location layout | Store_Location__c-Store Location Layout | No change |
| Purchase Record layout | Transaction_Record__c-Transaction Record Layout | **Production version needed** |
| Purchase Line Item layout | Purchase_Line_Item__c-Purchase Line Item Layout | **Production version needed** |

## Step 13: Lightning record pages

| Name | API name | Notes |
|---|---|---|
| Lead page | Lead_Record_Page | Includes the Lead Stage tab |
| Purchase Record page | Transaction_Record_Record_Page | The bill page |

## Step 14: Object settings (switch on the pages and buttons)

| Name | API name | What it switches on |
|---|---|---|
| Lead object settings | Lead | Lead page as default, New/Upload/Download buttons on the list, summary bar, field history |
| Purchase Record object settings | Transaction_Record__c | Purchase Record page as default |

## Step 15: Tabs

| Name | API name |
|---|---|
| Store Locations | Store_Location__c |
| Purchase Records | Transaction_Record__c |

## Step 16: App

| Name | API name | Notes |
|---|---|---|
| ShriHari | ShriHari | **Production version needed** |

## Step 17: Access

| # | Name | API name | Type | For whom |
|---|---|---|---|---|
| 1 | ShreeHari CRM User | ShreeHari_CRM_User | Permission set | Store and sales staff. **Production version needed** |
| 2 | Shree Hari Lead API Access | Shree_Hari_Lead_API_Access | Permission set | The website integration user. **Production version needed** |
| 3 | Shree Hari Website API | Shree_Hari_Website_API | External client app | Lets the website log in |
| 4 | Website API login settings | Shree_Hari_Website_API_oauth | External client app OAuth settings | The website's login settings |

## Step 18: Duplicate warning (separate deployment, last)

| # | Name | API name | Type | Notes |
|---|---|---|---|---|
| 1 | Lead matching | Lead.Lead_Duplicate_Rule | Matching rule | Same phone, WhatsApp or email. Deploy it, then **wait until it shows Active** in Setup |
| 2 | Lead duplicate warning | Lead.Lead_Duplicate_Check | Duplicate rule | Deploy only after #1 is Active |

## Step 19: After deployment

| # | Task |
|---|---|
| 1 | Check that all 5 flows from Step 10 are Active |
| 2 | Assign `ShreeHari_CRM_User` to staff, and `Shree_Hari_Lead_API_Access` to the website integration user |
| 3 | Set up the website integration user and share the website app's key and secret with the website team |
| 4 | Load the data below |

## Step 20: Data to load

| Data | Record (API name) | Why |
|---|---|---|
| Stores, with Store Codes (e.g. 000001) | Store_Location__c | Store drop-downs, CSV uploads and website leads |
| Products, with Available Quantity | Product2 | Product search on the Convert screen |
| Campaigns | Campaign | Campaign drop-downs and the "Campaign Name" column in CSV uploads |

---

## Production versions to prepare before deploying

These items in UAT still point at loyalty and gift vouchers, so they need trimmed copies:

| Step | Name | API name | Change |
|---|---|---|---|
| 2 / 14 | Purchase Record object | Transaction_Record__c | Remove the "New Purchase" list button (New_Transaction) |
| 7 | Conversion tests | LeadConversionTransactionServiceTest | Remove the 2 loyalty tests |
| 7 | Lead check tests | LeadTriggerHandlerTest | Remove 1 loyalty check; set aside 9 tests that need the switched-off lead-edit part of `LeadTrigger` |
| 12 | Account layout | Account-Account Layout | Remove the loyalty and gift voucher fields, buttons and related lists, and Relationship Manager |
| 12 | Purchase Record layout | Transaction_Record__c-Transaction Record Layout | Remove Gift_Voucher__c and Net_Amount__c, and the extra product columns |
| 12 | Purchase Line Item layout | Purchase_Line_Item__c-Purchase Line Item Layout | Remove the 6 extra fields |
| 16 | ShriHari app | ShriHari | Remove the Loyalty and Gift Voucher tabs |
| 17 | ShreeHari CRM User | ShreeHari_CRM_User | Remove access to anything not going live |
| 17 | Shree Hari Lead API Access | Shree_Hari_Lead_API_Access | Remove the 6 extra Store Location fields |

## Not going live now, and what that means

| Name | API name | What staff will notice |
|---|---|---|
| Loyalty Records, Loyalty Transactions | Loyalty_Record__c, Loyalty_Transaction__c | No points are earned or shown |
| Loyalty settings | Loyalty_Setting__mdt, Loyalty_Bypass__c | Same as above |
| Gift Vouchers | Gift_Voucher__c | No gift voucher records or buttons |
| New Purchase screen | New_Transaction | Bills can only be entered when converting a lead |
| Loyalty and gift screens | Account_Create_Loyalty_Record, Allot_Loyalty_Points, Create_Gift_Voucher, dynamicFieldSelection, DynamicFieldController | Not available |
| Automatic bill calculations | TransactionRecordTrigger, TransactionTriggerHandler, LoyaltyEngine, GiftVoucherRedemption, LoyaltyPointsExpiryBatch, ShreeHariTrailingSpendBatch | No Net Amount on bills. **Last 12 Month Spend stays empty, so Customer Tier always shows "Silver".** |
| Account: Loyalty Balance, CLV, Relationship Manager | Loyalty_Balance__c, CLV__c, Relationship_Manager__c | Not on the customer page |
| Purchase Record: old fields | Gift_Voucher__c, Net_Amount__c, Metal_Type__c, SKU_Details__c, Redeem_Points__c, Redeem_Gift_Voucher__c | Not needed |
| Purchase Line Item: extra fields | SKU__c, Item_Description__c, Metal_Type__c, Weight_Grams__c, Unit_Price__c, Line_Amount__c | Not filled by anything yet; can be added later |
| Store Location: extra fields | Address__c, City__c, Store_Type__c, Latitude__c, Longitude__c, Is_Active__c | Not used yet; can be added later |
| Account, Contact and Case Lightning pages | Account_Record_Page, Contact_Record_Page, Case_Record_Page | These use the standard page with the Step 12 layouts |

**Two things that behave the same as UAT does today:**

- Changing a lead's phone, WhatsApp or email to one already in use is **not** blocked yet.
- A B2C lead's company name does **not** update when the person's name changes.

Both depend on the update part of `LeadTrigger`, which is switched off on purpose until the business decides how lead edits should work.
