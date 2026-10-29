# ShreeHari – Production Deployment Checklist

Scope: Lead, Account, Contact, Loyalty, plus what they depend on: the enquiry Case from New Lead, Transactions (bills), Gift Vouchers, Store Locations and access.

Manifest: [`manifest/prod-deploy.xml`](../manifest/prod-deploy.xml) (350 components).

Prepared 2026-10-29 from UAT (`shri_hari_uat`). Checked in UAT on 2026-10-29:
- all 166 Apex tests pass;
- every class and trigger has at least 90% coverage;
- the manifest retrieves completely from UAT.

---

## 1. How to deploy

Deploy **what was tested in UAT**: retrieve the manifest from UAT, then deploy that package to prod.

The repo is behind UAT in places, because some settings were changed in Setup (see section 6). The profiles in the repo are also empty shells. So deploying straight from the repo would not match UAT.

```bash
# 1. Pull the tested versions from UAT into a package folder (don't commit deploy/)
sf project retrieve start -x manifest/prod-deploy.xml -o shri_hari_uat \
  --target-metadata-dir deploy/prod --unzip

# 2. Validate against prod (check-only, nothing is saved)
sf project deploy validate --metadata-dir deploy/prod/unpackaged/unpackaged -o <prod-alias> \
  --test-level RunSpecifiedTests --tests \
  DynamicFieldControllerTest GiftVoucherRedemptionTest LeadConversionTransactionServiceTest \
  LeadTriggerHandlerTest LeadUploadServiceTest LoyaltyEngineTest LoyaltyPointsExpiryBatchTest \
  ShreeHariLeadRestResourceTest ShreeHariTrailingSpendBatchTest TransactionTriggerHandlerTest

# 3. Deploy the validated package
sf project deploy quick --job-id <id from step 2> -o <prod-alias>
```

Profiles must be retrieved **in the same request** as the objects, classes, tabs and layouts. A profile only carries access for components retrieved with it, so don't split the manifest.

---

## 2. Decide before deploying

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Account record page** has a CRM Analytics dashboard (`Claude_Test_Dashboard`) and a DevOps Center tab | These almost certainly don't exist in prod, so the deploy would fail. Remove both from `Account_Record_Page` in UAT, then retrieve. |
| 2 | **Create Gift Voucher flow**: the repo has a newer Minimum Amount change that was never deployed to UAT | The package takes the **UAT** version (active v2, tested). Decide whether the repo change is still wanted. |
| 3 | **Lead Path** (`Lead_Path`, standard "Mark Status" path) is still active on the Lead page | It was planned for removal once the Lead Stage flow went in. Keep it, or remove it from the Lead page and the manifest. |
| 4 | **Lead Status values**: the package sets them to New / Contacted / Unqualified / Qualified / Converted | Deploying a standard value set replaces prod's values. Check that no prod Leads use other values (e.g. "Open - Not Contacted"). |
| 5 | **Account `Business_Type__c` label** is "Type" in UAT and "Business Type" in the repo | The package takes the UAT label. Confirm it is intended. |

---

## 3. Before deploying (in prod, by hand)

- [ ] **Create the six profiles** by cloning the same base profile used in UAT. The deploy then adds their object, field, class, tab and layout access:
  - ShriHari_Analytics_User
  - ShriHari_Integration_User
  - ShriHari_Loyalty_Admin
  - ShriHari_Service_Agent
  - ShriHari_Store_Manager
  - ShriHari_Tele_Calling_Agent
- [ ] **Setup → Path Settings → Enable** (needed for `Lead_Path`, unless it is dropped).
- [ ] **Setup → Process Automation Settings → "Deploy processes and flows as active"**: turn it on. Otherwise activate the 8 flows by hand after the deploy.
- [ ] Confirm **Person Accounts are off** (the design relies on Company and Account + Contact).
- [ ] Settle the decisions in section 2.

---

## 4. What's in the package

### Lead

| Type | Components |
|------|------------|
| Fields | Anniversary_Date__c, Business_Type__c, Campaign_Attribution__c, Contacted_Remark__c, Date_of_Birth__c, Follow_up_Date_Time__c, Lead_Number__c, Marital_Status__c, Qualification_Notes__c, Store_Association__c, Unqualified_Date__c, Unqualified_Remark__c, Walk_In_Flag__c |
| Standard field settings | History tracking and settings on Company, Description, Phone and others |
| Validation rule | Phone_Must_Be_10_Digits |
| Buttons / action | New_Lead, Upload_Leads, Download_Lead_Template; quick action Lead.Convert_Lead |
| Pages | Lead Layout, Lead_Record_Page (Lead Stage flow tab), Lead_Compact_Layout, Lead_Path |
| Picklists | LeadStatus, LeadSource |
| Duplicates | Duplicate rule Lead_Duplicate_Check + matching rule Lead_Duplicate_Rule |
| Lead → Account mapping | LeadConvertSettings (DOB, Anniversary, Marital Status, Business Type, Campaign, Store → Primary Store) |
| Apex | LeadTrigger, LeadTriggerHandler, LeadUploadService, LeadConversionTransactionService, ShreeHariLeadRestResource (+ tests) |
| Flows | New_Lead, Upload_Leads, Lead_Stage, Convert_Lead |
| Other | Static resource Lead_Upload_Template; permission set Shree_Hari_Lead_API_Access (website API user) |

### Enquiry Case (created by New Lead for existing customers)

| Type | Components |
|------|------------|
| Fields | Campaign__c, Lead_Source__c, Store__c (+ standard Case fields) |
| Pages | Case Layout, Case_Record_Page, Case_Easy_Compact_Layout, list views |
| Picklists | CaseType, CaseOrigin, CaseStatus, CasePriority |
| Queue | service_case ("Unassigned", no members; the Unassigned list view needs it) |

### Account

| Type | Components |
|------|------------|
| Fields | Anniversary_Date__c, Business_Type__c, CASA_ID__c, CLV__c, Campaign_Attribution__c, Customer_Tier__c, Date_of_Birth__c, Email__c, Last_12M_Spend__c, Loyalty_Balance__c, Marital_Status__c, Primary_Store__c, Relationship_Manager__c, WA_Opt_In__c |
| Pages | Account Layout, Account_Record_Page, Account_Compact_Layout |
| Automation | Flow Account_Create_Loyalty_Record; ShreeHariTrailingSpendBatch (+ test) |

### Contact

| Type | Components |
|------|------------|
| Fields | Anniversary_Date__c, Marital_Status__c (Lead DOB goes to standard Birthdate) |
| Pages | Contact Layout (Personal Details section), Contact_Record_Page, Contact_Compact_Layout, list views |

### Loyalty

| Type | Components |
|------|------------|
| Loyalty_Record__c | Object, 8 fields, All list view, Allot_Points button, layout, tab, Loyalty_Record_Record_Page |
| Loyalty_Transaction__c | Object, 16 fields, list view, layout, tab |
| Loyalty_Setting__mdt | Custom metadata type (Tier__c, Earning_Rate__c), layout, records Silver / Gold / Platinum / Diamond |
| Apex | LoyaltyEngine, LoyaltyPointsExpiryBatch (+ tests) |
| Flow | Allot_Loyalty_Points |

### Transactions (bills) and Gift Vouchers

| Type | Components |
|------|------------|
| Transaction_Record__c | Object, 20 fields, validation No_Future_Transaction_Date, New_Transaction button, layout, tab, Transaction_Record_Record_Page |
| Gift_Voucher__c | Object, 13 fields, New_Gift_Voucher button, list view, layout, tab |
| Apex | TransactionRecordTrigger, TransactionTriggerHandler, GiftVoucherRedemption, DynamicFieldController (+ tests) |
| LWC | dynamicFieldSelection |
| Flows | New_Transaction, Create_Gift_Voucher |

### Store Location

| Type | Components |
|------|------------|
| Store_Location__c | Object, 7 fields, list view, layout, tab |

### Access

| Type | Components |
|------|------------|
| Permission sets | ShreeHari_CRM_User, Shree_Hari_Lead_API_Access |
| Profiles | The six ShriHari_* profiles (access to the components above) |

### Not in the package (on purpose)

- **External Client App "Shree Hari Website API"**: the repo copy is tied to the UAT org ID and has no OAuth settings. Create it in prod by hand (section 5).
- **Profiles' full permission set**: only access to the components above is deployed. Other profile permissions come from the clone in section 3.

---

## 5. After deploying (in prod, by hand)

- [ ] **Flows**: confirm all 8 are active (Account_Create_Loyalty_Record must be active, or new Accounts get no Loyalty Record).
- [ ] **Website API**:
  - create the integration user (ShriHari_Integration_User profile + Shree_Hari_Lead_API_Access permission set);
  - create the External Client App with OAuth client credentials, running as that user;
  - send the new client ID, client secret and prod domain to the website team.
- [ ] **Users**: assign ShreeHari_CRM_User and the right ShriHari_* profile.
- [ ] **Contact Anniversary Date / Marital Status access**: not granted anywhere, as in UAT. Add it to a permission set or profile if users should see these fields.
- [ ] **Data**: load Store Location records (Store Code is used by Lead Upload) and Campaigns. The loyalty tiers come with the deploy.
- [ ] **Scheduled jobs**: schedule ShreeHariTrailingSpendBatch and LoyaltyPointsExpiryBatch (Setup → Apex Classes → Schedule Apex). Neither is scheduled in UAT, so agree run times first.
- [ ] **App navigation**: add the Transaction Record, Loyalty Record, Loyalty Transaction, Gift Voucher and Store Location tabs to the app users work in.
- [ ] **Smoke test**:
  - New Lead: plain lead, existing customer → enquiry Case, open Lead → blocked;
  - Upload Leads;
  - Lead Stage (Contacted with follow-up, Qualified, Unqualified);
  - Convert with a bill: new customer, and picked existing Account → new Contact with DOB/Anniversary/Marital Status;
  - New Transaction with points/voucher;
  - Create Gift Voucher;
  - Allot Points;
  - website API call.

---

## 6. Repo vs UAT (found 2026-10-29)

Apex classes, triggers and the LWC are identical in the repo and UAT. These differ, and the package takes the UAT version:

- **Changed in UAT Setup, not in the repo**:
  - history tracking on Lead Company, Description, Phone, Contacted Remark, Follow-up, Qualification Notes, Unqualified Date/Remark;
  - Account Layout ("Demographic Insight" section, Transaction related list with New Transaction button);
  - Lead Layout history related list;
  - Loyalty Record "All" list view columns;
  - Account Business Type label;
  - hidden standard buttons on several objects.
- **Only in UAT**: the 6 record pages, 5 tabs, 5 layouts, Loyalty_Setting__mdt type, matching rule, Lead_Path, LeadConvertSettings, picklist value sets, service_case queue, Shree_Hari_Lead_API_Access.
- **Flows**: UAT copies only add screen layout properties, except Create_Gift_Voucher (decision 2 in section 2).
- **Profiles**: the repo copies are empty shells.

After the deploy, refresh the repo from UAT so the two match again.
