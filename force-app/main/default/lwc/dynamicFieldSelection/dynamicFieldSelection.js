import { LightningElement, api, track } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import getFilterFields from '@salesforce/apex/DynamicFieldController.getFilterFields';
import getPicklistValues from '@salesforce/apex/DynamicFieldController.getPicklistValues';
import searchRecords from '@salesforce/apex/DynamicFieldController.searchRecords';
import newVoucherCodePrefix from '@salesforce/apex/DynamicFieldController.newVoucherCodePrefix';

const PAGE_SIZE = 50;
const MAX_RECORDS = 2000;
const MAX_NEXT_DAYS = 90;
const MAX_CODE_PREFIX_LENGTH = 45;
const MAX_ISSUED_BY_LENGTH = 255;

const MODE_OFFER = 'offerSpecification';
const MODE_MAPPING = 'offerMapping';
const MODE_DETAILS = 'voucherDetails';

const OFFER_FIXED = 'Fixed Price';
const OFFER_PERCENTAGE = 'Percentage';

const STEPS = [
    { label: 'Offer Specifications', value: MODE_OFFER },
    { label: 'Offer Mapping', value: MODE_MAPPING },
    { label: 'Voucher Details', value: MODE_DETAILS }
];

const NUMERIC_OPERATORS = [
    { label: 'Equals', value: 'equals' },
    { label: 'Does Not Equal', value: 'doesNotEquals' },
    { label: 'Greater Than', value: 'greaterThan' },
    { label: 'Less Than', value: 'lessThan' },
    { label: 'Greater Than Or Equal', value: 'greaterThanOrEqual' },
    { label: 'Less Than Or Equal', value: 'lessThanOrEqual' },
    { label: 'Between', value: 'between' },
    { label: 'Is Null', value: 'isNull' }
];

// Date operators that compare day and month only (birthdays, anniversaries).
const ANY_YEAR_OPERATORS = [
    { label: 'In Month (any year)', value: 'inMonth' },
    { label: 'This Month (ignoring year)', value: 'thisMonthAnyYear' },
    { label: 'Next Month (ignoring year)', value: 'nextMonthAnyYear' },
    { label: 'Within Next N Days (ignoring year)', value: 'nextNDaysAnyYear' }
];

const DATE_OPERATORS = [...NUMERIC_OPERATORS, ...ANY_YEAR_OPERATORS];

// Operators per field category. Mirrors OPERATORS_BY_CATEGORY in DynamicFieldController.
const fieldToOperatorsMap = {
    string: [
        { label: 'Equals', value: 'equals' },
        { label: 'Does Not Equal', value: 'doesNotEquals' },
        { label: 'Starts With', value: 'startWith' },
        { label: 'Ends With', value: 'endWith' },
        { label: 'Contains', value: 'contains' },
        { label: 'In (comma-separated)', value: 'in' },
        { label: 'Is Null', value: 'isNull' }
    ],
    picklist: [
        { label: 'Equals', value: 'equals' },
        { label: 'Does Not Equal', value: 'doesNotEquals' },
        { label: 'In', value: 'in' },
        { label: 'Is Null', value: 'isNull' }
    ],
    multipicklist: [
        { label: 'Includes', value: 'includes' },
        { label: 'Excludes', value: 'excludes' },
        { label: 'Is Null', value: 'isNull' }
    ],
    boolean: [{ label: 'Equals', value: 'equals' }],
    currency: NUMERIC_OPERATORS,
    number: NUMERIC_OPERATORS,
    percent: NUMERIC_OPERATORS,
    date: DATE_OPERATORS,
    datetime: DATE_OPERATORS
};

const NO_VALUE_OPERATORS = new Set(['thisMonthAnyYear', 'nextMonthAnyYear']);

const BOOLEAN_OPTIONS = [
    { label: 'True', value: 'True' },
    { label: 'False', value: 'False' }
];

const IS_NULL_OPTIONS = [
    { label: 'True (field is empty)', value: 'True' },
    { label: 'False (field has a value)', value: 'False' }
];

const MONTH_OPTIONS = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
].map((label, index) => ({ label, value: String(index + 1) }));

const INR = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });

/**
 * All three screens of the Create Gift Voucher flow, chosen by screenMode:
 *
 *   offerSpecification  Fixed Price / Percentage cards, Min / Max amount and
 *                       the offer amount or % off.
 *   offerMapping        Rules on any filterable field of objectAPIName,
 *                       optional Rule Logic, Filter Records, and a paginated
 *                       table (50 per page, up to 2,000) to tick records.
 *   voucherDetails      Voucher code prefix (pre-filled, editable,
 *                       regenerable), Expiry Date and Issued By.
 *
 * Every value is mapped back into the flow and in again, so it survives the
 * user going Previous and Next.
 */
export default class DynamicFieldSelection extends LightningElement {
    @api screenMode = MODE_MAPPING;

    // Offer Mapping inputs
    @api objectAPIName = 'Account';
    @api columnFields = 'Name';

    @track state = {
        // Offer Specifications
        offerType: OFFER_FIXED,
        minAmount: '',
        maxAmount: '',
        offerAmount: '',
        discountPercentage: '',
        // Offer Mapping
        ruleListJSON: '',
        ruleLogic: '',
        // Voucher Details
        voucherCode: '',
        expiryDate: null,
        issuedBy: ''
    };

    // ---- Public properties: getters/setters over state, so the component
    // ---- never reassigns what the flow passed in.

    @api get offerType() { return this.state.offerType; }
    set offerType(value) { this.setState('offerType', value || OFFER_FIXED); }

    @api get minAmount() { return this.state.minAmount; }
    set minAmount(value) { this.setState('minAmount', this.asText(value)); }

    @api get maxAmount() { return this.state.maxAmount; }
    set maxAmount(value) { this.setState('maxAmount', this.asText(value)); }

    @api get offerAmount() { return this.state.offerAmount; }
    set offerAmount(value) { this.setState('offerAmount', this.asText(value)); }

    @api get discountPercentage() { return this.state.discountPercentage; }
    set discountPercentage(value) { this.setState('discountPercentage', this.asText(value)); }

    @api get ruleListJSON() { return this.state.ruleListJSON; }
    set ruleListJSON(value) { this.setState('ruleListJSON', value || ''); }

    @api get ruleLogic() { return this.state.ruleLogic; }
    set ruleLogic(value) { this.setState('ruleLogic', value || ''); }

    @api get voucherCode() { return this.state.voucherCode; }
    set voucherCode(value) { this.setState('voucherCode', value || ''); }

    @api get expiryDate() { return this.state.expiryDate; }
    set expiryDate(value) { this.setState('expiryDate', value || null); }

    @api get issuedBy() { return this.state.issuedBy; }
    set issuedBy(value) { this.setState('issuedBy', value || ''); }

    @api
    get selectedRecordIds() {
        return [...this.selectedIds];
    }
    set selectedRecordIds(value) {
        this.selectedIds = new Set(Array.isArray(value) ? value : []);
    }

    @api
    get selectedCount() {
        return this.selectedIds.size;
    }
    set selectedCount(value) {
        // Output only: always follows the selection.
    }

    // Offer Mapping state
    @track rules = [];
    fieldOptions = [];
    fieldsByName = new Map();
    picklistCache = new Map();
    selectedIds = new Set();
    columns = [];
    records = [];
    truncated = false;
    hasSearched = false;
    currentPage = 1;
    isLoadingFields = false;
    isSearching = false;
    errorMessage;
    maxRecords = MAX_RECORDS;

    // Voucher Details state
    isGeneratingCode = false;

    steps = STEPS;

    // =====================================================================
    // Lifecycle
    // =====================================================================

    connectedCallback() {
        if (this.isMappingMode) {
            this.initMapping();
        }
    }

    // =====================================================================
    // Flow validation: Next is blocked while this returns isValid false
    // =====================================================================

    @api
    validate() {
        let message;
        if (this.isOfferMode) {
            message = this.offerValidationMessage();
        } else if (this.isMappingMode) {
            message = this.selectedIds.size > 0
                ? undefined
                : 'Filter the records and select at least one customer before continuing.';
        } else if (this.isDetailsMode) {
            message = this.detailsValidationMessage();
        }
        return message ? { isValid: false, errorMessage: message } : { isValid: true };
    }

    // =====================================================================
    // Mode and progress
    // =====================================================================

    get isOfferMode() {
        return this.screenMode === MODE_OFFER;
    }

    get isMappingMode() {
        return this.screenMode === MODE_MAPPING;
    }

    get isDetailsMode() {
        return this.screenMode === MODE_DETAILS;
    }

    // =====================================================================
    // Screen 1: Offer Specifications
    // =====================================================================

    get isFixedPrice() {
        return this.state.offerType === OFFER_FIXED;
    }

    get isPercentage() {
        return this.state.offerType === OFFER_PERCENTAGE;
    }

    get fixedAriaChecked() {
        return String(this.isFixedPrice);
    }

    get percentageAriaChecked() {
        return String(this.isPercentage);
    }

    get fixedTileClass() {
        return this.tileClass(this.isFixedPrice);
    }

    get percentageTileClass() {
        return this.tileClass(this.isPercentage);
    }

    tileClass(selected) {
        return selected ? 'offer-tile offer-tile_selected' : 'offer-tile';
    }

    get offerCardTitle() {
        return this.isFixedPrice ? 'Fixed Amount' : 'Percentage';
    }

    get offerCardSubtitle() {
        return this.isFixedPrice
            ? 'A fixed rupee amount off the bill, when the bill is between the minimum and maximum amount.'
            : 'A percentage off the bill, when the bill is between the minimum and maximum amount.';
    }

    handleOfferTypeSelect(event) {
        const value = event.currentTarget.dataset.value;
        if (value && value !== this.state.offerType) {
            this.setState('offerType', value);
            this.notify('offerType', value);
        }
    }

    handleOfferTileKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleOfferTypeSelect(event);
        }
    }

    handleOfferInput(event) {
        const name = event.target.dataset.name;
        const value = this.asText(event.detail.value);
        event.target.setCustomValidity('');
        this.setState(name, value);
        this.notify(name, value);
    }

    /** Plain-language preview of the offer, shown under the inputs and on screen 3. */
    get offerSummary() {
        const min = this.toNumber(this.state.minAmount) ?? 0;
        const max = this.toNumber(this.state.maxAmount);
        const range = max === null
            ? `on bills from ${INR.format(min)}`
            : `on bills from ${INR.format(min)} to ${INR.format(max)}`;
        if (this.isFixedPrice) {
            const amount = this.toNumber(this.state.offerAmount);
            return amount === null ? '' : `${INR.format(amount)} off ${range}`;
        }
        const pct = this.toNumber(this.state.discountPercentage);
        return pct === null ? '' : `${pct}% off ${range}`;
    }

    offerValidationMessage() {
        const inputs = [...this.template.querySelectorAll('lightning-input[data-group="offer"]')];
        inputs.forEach((input) => input.setCustomValidity(''));
        const byName = (name) => inputs.find((input) => input.dataset.name === name);

        const min = this.toNumber(this.state.minAmount);
        const max = this.toNumber(this.state.maxAmount);
        const problems = [];

        if (min !== null && min < 0) {
            problems.push(['minAmount', 'Min Amount cannot be negative.']);
        }
        if (max === null) {
            problems.push(['maxAmount', 'Enter the Max Amount.']);
        } else if (max <= (min ?? 0)) {
            problems.push(['maxAmount', 'Max Amount must be greater than Min Amount.']);
        }
        if (this.isFixedPrice) {
            const amount = this.toNumber(this.state.offerAmount);
            if (amount === null || amount <= 0) {
                problems.push(['offerAmount', 'Enter an Offer Amount greater than 0.']);
            }
        } else {
            const pct = this.toNumber(this.state.discountPercentage);
            if (pct === null || pct <= 0 || pct > 100) {
                problems.push(['discountPercentage', '% Off must be greater than 0 and at most 100.']);
            }
        }

        problems.forEach(([name, message]) => {
            const input = byName(name);
            if (input) {
                input.setCustomValidity(message);
            }
        });
        inputs.forEach((input) => input.reportValidity());
        return problems.length ? problems[0][1] : undefined;
    }

    // =====================================================================
    // Screen 2: Offer Mapping
    // =====================================================================

    async initMapping() {
        this.isLoadingFields = true;
        try {
            const fields = await getFilterFields({ objectApiName: this.objectAPIName });
            this.fieldOptions = fields.map((f) => ({ label: `${f.label} (${f.dataType})`, value: f.value }));
            fields.forEach((f) => this.fieldsByName.set(f.value, f));
        } catch (error) {
            this.errorMessage = this.messageOf(error);
            this.isLoadingFields = false;
            return;
        }
        this.isLoadingFields = false;

        await this.restoreRules();

        // Coming back to this screen with customers already chosen:
        // show the same results again, keeping the selection.
        if (this.selectedIds.size > 0) {
            await this.runSearch(true);
        }
    }

    get isDeleteDisabled() {
        return this.rules.length <= 1;
    }

    get logicPlaceholder() {
        const numbers = this.rules.map((r) => r.id);
        return numbers.length > 1 ? `e.g. ${numbers.join(' AND ')}` : 'e.g. 1 AND (2 OR 3)';
    }

    newRule(id) {
        return this.decorate({ id, field: null, dataType: null, operator: null, value: '', valueTo: '', values: [] });
    }

    handleAddRules() {
        this.rules = [...this.rules, this.newRule(this.rules.length + 1)];
        this.publishRules();
    }

    handleRemoveRule(event) {
        if (this.rules.length <= 1) {
            return;
        }
        const ruleId = Number(event.currentTarget.dataset.id);
        this.rules = this.rules
            .filter((rule) => rule.id !== ruleId)
            .map((rule, index) => this.decorate({ ...rule, id: index + 1 }));
        this.publishRules();
    }

    async handleRuleFieldChange(event) {
        const ruleId = Number(event.target.dataset.id);
        const fieldName = event.detail.value;
        const meta = this.fieldsByName.get(fieldName);
        if (!meta) {
            return;
        }
        this.updateRule(ruleId, () => ({
            field: fieldName,
            dataType: meta.dataType,
            operator: null,
            value: '',
            valueTo: '',
            values: []
        }));

        if (meta.dataType === 'picklist' || meta.dataType === 'multipicklist') {
            await this.loadPicklistValues(fieldName);
            this.updateRule(ruleId, () => ({}));
        }
    }

    handleOperatorChange(event) {
        const ruleId = Number(event.target.dataset.id);
        const operator = event.detail.value;
        this.updateRule(ruleId, () => ({ operator, value: '', valueTo: '', values: [] }));
    }

    handleValueChange(event) {
        const ruleId = Number(event.target.dataset.id);
        const part = event.target.dataset.part;
        const value = event.detail.value;
        if (part === 'values') {
            this.updateRule(ruleId, () => ({ values: Array.isArray(value) ? [...value] : [] }));
        } else if (part === 'valueTo') {
            this.updateRule(ruleId, () => ({ valueTo: value }));
        } else {
            this.updateRule(ruleId, () => ({ value }));
        }
    }

    handleLogicChange(event) {
        const value = event.detail.value;
        this.setState('ruleLogic', value);
        this.notify('ruleLogic', value);
    }

    updateRule(ruleId, change) {
        this.rules = this.rules.map((rule) => (rule.id === ruleId ? this.decorate({ ...rule, ...change(rule) }) : rule));
        this.publishRules();
    }

    /** Adds the properties the template needs to render one rule. */
    decorate(rule) {
        const type = rule.dataType;
        const op = rule.operator;
        const isNumeric = type === 'number' || type === 'currency' || type === 'percent';
        const isDate = type === 'date' || type === 'datetime';

        const showNoValue = NO_VALUE_OPERATORS.has(op);
        const showSingleSelect =
            !!op &&
            (op === 'isNull' ||
                op === 'inMonth' ||
                type === 'boolean' ||
                (type === 'picklist' && (op === 'equals' || op === 'doesNotEquals')));
        const showDualListbox =
            !!op && op !== 'isNull' && ((type === 'picklist' && op === 'in') || type === 'multipicklist');
        const showRange = op === 'between';
        const isDaysInput = op === 'nextNDaysAnyYear';
        const showTextInput = !!op && !showNoValue && !showSingleSelect && !showDualListbox && !showRange;

        let singleSelectOptions = [];
        if (op === 'isNull') {
            singleSelectOptions = IS_NULL_OPTIONS;
        } else if (op === 'inMonth') {
            singleSelectOptions = MONTH_OPTIONS;
        } else if (type === 'boolean') {
            singleSelectOptions = BOOLEAN_OPTIONS;
        } else if (type === 'picklist') {
            singleSelectOptions = this.picklistCache.get(rule.field) || [];
        }

        let inputType = 'text';
        if (isNumeric || isDaysInput) {
            inputType = 'number';
        } else if (isDate) {
            inputType = 'date';
        }

        let formatter;
        if (!isDaysInput && type === 'currency') {
            formatter = 'currency';
        } else if (!isDaysInput && type === 'percent') {
            formatter = 'percent-fixed';
        }

        let placeholder = 'Enter a value';
        if (op === 'in') {
            placeholder = 'Values separated by commas';
        } else if (isDaysInput) {
            placeholder = `Days (1-${MAX_NEXT_DAYS})`;
        }

        let noValueText = '';
        if (op === 'thisMonthAnyYear') {
            noValueText = 'Matches any year, this calendar month.';
        } else if (op === 'nextMonthAnyYear') {
            noValueText = 'Matches any year, next calendar month.';
        }

        return {
            ...rule,
            operatorOptions: type ? fieldToOperatorsMap[type] || [] : [],
            isOperatorDisabled: !rule.field,
            isValueDisabled: !op,
            showNoValue,
            noValueText,
            showSingleSelect,
            showDualListbox,
            showRange,
            showTextInput,
            singleSelectOptions,
            picklistOptions: this.picklistCache.get(rule.field) || [],
            inputType,
            formatter,
            step: isDaysInput ? '1' : isNumeric ? 'any' : undefined,
            min: isDaysInput ? 1 : undefined,
            max: isDaysInput ? MAX_NEXT_DAYS : undefined,
            fieldLevelHelp: isDaysInput ? 'Today through today + N days, comparing day and month only.' : undefined,
            placeholder
        };
    }

    async loadPicklistValues(fieldName) {
        if (this.picklistCache.has(fieldName)) {
            return;
        }
        try {
            const values = await getPicklistValues({ objectApiName: this.objectAPIName, fieldApiName: fieldName });
            this.picklistCache.set(fieldName, values.map((v) => ({ label: v.label, value: v.value })));
        } catch (error) {
            this.errorMessage = this.messageOf(error);
        }
    }

    /** Only what the server needs, and what is needed to rebuild the rules. */
    get plainRules() {
        return this.rules.map((r) => ({
            field: r.field,
            operator: r.operator,
            value: r.value === null || r.value === undefined ? '' : String(r.value),
            valueTo: r.valueTo === null || r.valueTo === undefined ? '' : String(r.valueTo),
            values: r.values || []
        }));
    }

    publishRules() {
        const json = JSON.stringify(this.plainRules);
        this.setState('ruleListJSON', json);
        this.notify('ruleListJSON', json);
    }

    async restoreRules() {
        let saved = [];
        try {
            saved = this.state.ruleListJSON ? JSON.parse(this.state.ruleListJSON) : [];
        } catch {
            saved = [];
        }
        const valid = (Array.isArray(saved) ? saved : []).filter((r) => r && this.fieldsByName.has(r.field));

        for (const r of valid) {
            const type = this.fieldsByName.get(r.field).dataType;
            if (type === 'picklist' || type === 'multipicklist') {
                // Sequential on purpose: the cache must be filled before decorate().
                // eslint-disable-next-line no-await-in-loop
                await this.loadPicklistValues(r.field);
            }
        }

        this.rules = valid.length
            ? valid.map((r, index) =>
                  this.decorate({
                      id: index + 1,
                      field: r.field,
                      dataType: this.fieldsByName.get(r.field).dataType,
                      operator: r.operator || null,
                      value: r.value || '',
                      valueTo: r.valueTo || '',
                      values: r.values || []
                  })
              )
            : [this.newRule(1)];
    }

    handleFilterRecords() {
        this.runSearch(false);
    }

    /** First incomplete rule's message, or undefined when every rule is complete. */
    get incompleteRuleMessage() {
        for (const rule of this.rules) {
            if (!rule.field) {
                return `Rule ${rule.id}: select a field.`;
            }
            if (!rule.operator) {
                return `Rule ${rule.id}: select an operator.`;
            }
            if (rule.showDualListbox && (!rule.values || rule.values.length === 0)) {
                return `Rule ${rule.id}: select at least one value.`;
            }
            if (rule.showRange && (this.isBlank(rule.value) || this.isBlank(rule.valueTo))) {
                return `Rule ${rule.id}: enter both From and To.`;
            }
            if ((rule.showTextInput || rule.showSingleSelect) && this.isBlank(rule.value)) {
                return `Rule ${rule.id}: enter a value.`;
            }
            if (rule.operator === 'nextNDaysAnyYear') {
                const days = Number(rule.value);
                if (!Number.isInteger(days) || days < 1 || days > MAX_NEXT_DAYS) {
                    return `Rule ${rule.id}: enter a number of days from 1 to ${MAX_NEXT_DAYS}.`;
                }
            }
        }
        return undefined;
    }

    async runSearch(keepSelection) {
        const incomplete = this.incompleteRuleMessage;
        if (incomplete) {
            this.errorMessage = incomplete;
            return;
        }

        this.errorMessage = undefined;
        this.isSearching = true;
        try {
            const result = await searchRecords({
                objectApiName: this.objectAPIName,
                columnFields: this.columnFields,
                rulesJson: JSON.stringify(this.plainRules),
                ruleLogic: this.state.ruleLogic
            });

            this.columns = result.columns.map((c) => ({
                label: c.label,
                fieldName: c.fieldName,
                type: c.type,
                typeAttributes: c.type === 'currency' ? { currencyCode: 'INR' } : undefined
            }));
            this.records = result.records;
            this.truncated = result.truncated;
            this.hasSearched = true;
            this.currentPage = 1;

            const found = new Set(this.records.map((r) => r.Id));
            const kept = keepSelection ? [...this.selectedIds].filter((id) => found.has(id)) : [];
            this.setSelection(new Set(kept));
        } catch (error) {
            this.records = [];
            this.truncated = false;
            this.hasSearched = false;
            this.errorMessage = this.messageOf(error);
        } finally {
            this.isSearching = false;
        }
    }

    get showResults() {
        return this.hasSearched && !this.isSearching && this.records.length > 0;
    }

    get showNoResults() {
        return this.hasSearched && !this.isSearching && this.records.length === 0;
    }

    get showResultsPlaceholder() {
        return !this.hasSearched && !this.isSearching;
    }

    get totalRecords() {
        return this.records.length;
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.records.length / PAGE_SIZE));
    }

    get pageStart() {
        return this.records.length ? (this.currentPage - 1) * PAGE_SIZE + 1 : 0;
    }

    get pageEnd() {
        return Math.min(this.currentPage * PAGE_SIZE, this.records.length);
    }

    get pageRecords() {
        return this.records.slice((this.currentPage - 1) * PAGE_SIZE, this.currentPage * PAGE_SIZE);
    }

    get pageSelectedIds() {
        return this.pageRecords.map((r) => r.Id).filter((id) => this.selectedIds.has(id));
    }

    get isFirstPage() {
        return this.currentPage <= 1;
    }

    get isLastPage() {
        return this.currentPage >= this.totalPages;
    }

    get hasNoSelection() {
        return this.selectedIds.size === 0;
    }

    get selectAllLabel() {
        return `Select All ${this.records.length}`;
    }

    handlePrevious() {
        if (!this.isFirstPage) {
            this.currentPage -= 1;
        }
    }

    handleNext() {
        if (!this.isLastPage) {
            this.currentPage += 1;
        }
    }

    /** The table reports the ticked rows of the current page only. */
    handleRowSelection(event) {
        const tickedOnPage = new Set(event.detail.selectedRows.map((row) => row.Id));
        const next = new Set(this.selectedIds);
        this.pageRecords.forEach((row) => {
            if (tickedOnPage.has(row.Id)) {
                next.add(row.Id);
            } else {
                next.delete(row.Id);
            }
        });
        this.setSelection(next);
    }

    handleSelectAll() {
        this.setSelection(new Set(this.records.map((r) => r.Id)));
    }

    handleClearSelection() {
        this.setSelection(new Set());
    }

    setSelection(ids) {
        this.selectedIds = ids;
        this.notify('selectedRecordIds', [...ids]);
        this.notify('selectedCount', ids.size);
    }

    // =====================================================================
    // Screen 3: Voucher Details
    // =====================================================================

    get customerCount() {
        return this.selectedIds.size;
    }

    get codeExample() {
        const prefix = (this.state.voucherCode || '').trim();
        return prefix ? `${prefix}-7KM3` : 'CODE-7KM3';
    }

    get minExpiryDate() {
        const tomorrow = new Date();
        tomorrow.setDate(tomorrow.getDate() + 1);
        return this.isoDate(tomorrow);
    }

    handleDetailsInput(event) {
        const name = event.target.dataset.name;
        const value = event.detail.value;
        event.target.setCustomValidity('');
        this.setState(name, value);
        this.notify(name, value);
    }

    async handleGenerateCode() {
        this.isGeneratingCode = true;
        try {
            const code = await newVoucherCodePrefix();
            this.setState('voucherCode', code);
            this.notify('voucherCode', code);
            const input = this.template.querySelector('lightning-input[data-name="voucherCode"]');
            if (input) {
                input.setCustomValidity('');
                input.reportValidity();
            }
        } catch (error) {
            this.errorMessage = this.messageOf(error);
        } finally {
            this.isGeneratingCode = false;
        }
    }

    detailsValidationMessage() {
        const inputs = [...this.template.querySelectorAll('lightning-input[data-group="details"]')];
        inputs.forEach((input) => input.setCustomValidity(''));
        const byName = (name) => inputs.find((input) => input.dataset.name === name);

        const code = (this.state.voucherCode || '').trim();
        const issuedBy = this.state.issuedBy || '';
        const problems = [];

        if (!code) {
            problems.push(['voucherCode', 'Enter a Voucher Code.']);
        } else if (code.length > MAX_CODE_PREFIX_LENGTH) {
            problems.push(['voucherCode', `Voucher Code can be at most ${MAX_CODE_PREFIX_LENGTH} characters.`]);
        }
        if (!this.state.expiryDate) {
            problems.push(['expiryDate', 'Enter an Expiry Date.']);
        } else if (this.state.expiryDate <= this.isoDate(new Date())) {
            problems.push(['expiryDate', 'Expiry Date must be after today.']);
        }
        if (issuedBy.length > MAX_ISSUED_BY_LENGTH) {
            problems.push(['issuedBy', `Issued By can be at most ${MAX_ISSUED_BY_LENGTH} characters.`]);
        }

        problems.forEach(([name, message]) => {
            const input = byName(name);
            if (input) {
                input.setCustomValidity(message);
            }
        });
        inputs.forEach((input) => input.reportValidity());
        return problems.length ? problems[0][1] : undefined;
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    setState(name, value) {
        this.state = { ...this.state, [name]: value };
    }

    notify(name, value) {
        this.dispatchEvent(new FlowAttributeChangeEvent(name, value));
    }

    asText(value) {
        return value === null || value === undefined ? '' : String(value);
    }

    toNumber(value) {
        if (this.isBlank(value)) {
            return null;
        }
        const number = Number(value);
        return Number.isFinite(number) ? number : null;
    }

    isBlank(value) {
        return value === null || value === undefined || String(value).trim() === '';
    }

    /** YYYY-MM-DD in the browser's local time. */
    isoDate(date) {
        const month = String(date.getMonth() + 1).padStart(2, '0');
        const day = String(date.getDate()).padStart(2, '0');
        return `${date.getFullYear()}-${month}-${day}`;
    }

    messageOf(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        return error && error.message ? error.message : 'Something went wrong. Please try again.';
    }
}
