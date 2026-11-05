import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import searchProducts from '@salesforce/apex/SkuSearchController.searchProducts';
import getProducts from '@salesforce/apex/SkuSearchController.getProducts';

const SEARCH_DELAY_MS = 300;

const stockLabelFor = (quantity) => (quantity === null || quantity === undefined ? '—' : String(quantity));

export default class SkuSearcher extends LightningElement {
    @api label = 'SKU Searcher';
    @api required = false;

    searchTerm = '';
    results = [];
    isSearching = false;
    searched = false;
    errorMessage;

    /** { productId, name, sku, stockLabel, quantity } per picked product, in the order picked. */
    items = [];

    /** Products ticked in the list, waiting for Add Selected. Kept across searches. */
    checked = new Map();

    _searchTimeout;
    _searchSequence = 0;

    /** Asset records for the flow: Product2Id, Name and Quantity. */
    @api
    get selectedItems() {
        return this.items.map((item) => ({
            Product2Id: item.productId,
            Name: item.name,
            Quantity: item.quantity
        }));
    }

    set selectedItems(value) {
        const assets = Array.isArray(value) ? value : [];
        this.items = assets
            .filter((asset) => asset && asset.Product2Id)
            .map((asset) => ({
                productId: asset.Product2Id,
                name: asset.Name,
                sku: '',
                stockLabel: '',
                quantity: asset.Quantity
            }));
        this.loadSkus();
    }

    disconnectedCallback() {
        clearTimeout(this._searchTimeout);
    }

    get hasItems() {
        return this.items.length > 0;
    }

    get hasResults() {
        return this.results.length > 0;
    }

    /** Products are listed only once something is typed. */
    get showResults() {
        return this.searchTerm.trim().length > 0;
    }

    get showAddBar() {
        return this.showResults || this.checked.size > 0;
    }

    get noneChecked() {
        return this.checked.size === 0;
    }

    get addSelectedLabel() {
        return this.checked.size ? `Add Selected (${this.checked.size})` : 'Add Selected';
    }

    get checkedSummary() {
        if (this.checked.size) {
            return `${this.checked.size} product(s) ticked. Click Add Selected to add them.`;
        }
        return 'Tick one or more products, then click Add Selected.';
    }

    get selectedHeading() {
        return `Selected Products (${this.items.length})`;
    }

    get noResultsMessage() {
        return `No active product matches "${this.searchTerm.trim()}".`;
    }

    /** Picks restored from an earlier visit carry no SKU; read it back from the Products. */
    async loadSkus() {
        const productIds = this.items.filter((item) => !item.sku).map((item) => item.productId);
        if (!productIds.length) {
            return;
        }
        try {
            const products = await getProducts({ productIds });
            const byId = new Map(products.map((product) => [product.Id, product]));
            this.items = this.items.map((item) => {
                const product = byId.get(item.productId);
                return product
                    ? {
                          ...item,
                          name: product.Name,
                          sku: product.ProductCode,
                          stockLabel: stockLabelFor(product.Available_Quantity__c)
                      }
                    : item;
            });
            this.decorateResults();
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        }
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value || '';
        clearTimeout(this._searchTimeout);

        if (!this.searchTerm.trim()) {
            this._searchSequence++;
            this.results = [];
            this.searched = false;
            this.isSearching = false;
            return;
        }

        this.isSearching = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._searchTimeout = setTimeout(() => this.runSearch(this.searchTerm), SEARCH_DELAY_MS);
    }

    async runSearch(term) {
        const sequence = ++this._searchSequence;
        this.isSearching = true;
        try {
            const products = await searchProducts({ searchTerm: term });
            if (sequence !== this._searchSequence) {
                return;
            }
            this.results = products;
            this.decorateResults();
            this.searched = true;
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            if (sequence === this._searchSequence) {
                this.isSearching = false;
            }
        }
    }

    decorateResults() {
        const picked = new Set(this.items.map((item) => item.productId));
        this.results = this.results.map((product) => {
            const isPicked = picked.has(product.Id);
            const isChecked = !isPicked && this.checked.has(product.Id);
            return {
                ...product,
                stockLabel: stockLabelFor(product.Available_Quantity__c),
                isPicked,
                isChecked,
                rowClass: isChecked ? 'result-row result-row_checked' : 'result-row'
            };
        });
    }

    handleCheck(event) {
        const productId = event.target.dataset.id;
        const product = this.results.find((result) => result.Id === productId);
        const checked = new Map(this.checked);
        if (event.target.checked && product) {
            checked.set(productId, product);
        } else {
            checked.delete(productId);
        }
        this.checked = checked;
        this.decorateResults();
    }

    handleAddSelected() {
        const picked = new Set(this.items.map((item) => item.productId));
        const added = [...this.checked.values()]
            .filter((product) => !picked.has(product.Id))
            .map((product) => ({
                productId: product.Id,
                name: product.Name,
                sku: product.ProductCode,
                stockLabel: stockLabelFor(product.Available_Quantity__c),
                quantity: 1
            }));
        if (!added.length) {
            return;
        }
        this.items = [...this.items, ...added];
        this.checked = new Map();
        this.errorMessage = undefined;
        this.decorateResults();
        this.notifyFlow();
    }

    handleQuantityChange(event) {
        const productId = event.target.dataset.id;
        const raw = event.target.value;
        const quantity = raw === '' || raw === null ? null : Number(raw);
        this.items = this.items.map((item) => (item.productId === productId ? { ...item, quantity } : item));
        this.notifyFlow();
    }

    handleRemove(event) {
        const productId = event.currentTarget.dataset.id;
        this.items = this.items.filter((item) => item.productId !== productId);
        this.decorateResults();
        this.notifyFlow();
    }

    notifyFlow() {
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedItems', this.selectedItems));
    }

    /** Called by the flow on Next. */
    @api
    validate() {
        if (this.checked.size) {
            this.errorMessage = `${this.checked.size} product(s) are ticked but not added. Click Add Selected, or untick them.`;
            return { isValid: false, errorMessage: this.errorMessage };
        }
        if (this.required && !this.hasItems) {
            this.errorMessage = 'Add at least one product.';
            return { isValid: false, errorMessage: this.errorMessage };
        }
        const invalid = this.items.find((item) => !Number.isInteger(item.quantity) || item.quantity < 1);
        if (invalid) {
            this.errorMessage = `Enter a whole-number Quantity of at least 1 for ${invalid.name}.`;
            return { isValid: false, errorMessage: this.errorMessage };
        }
        this.errorMessage = undefined;
        return { isValid: true };
    }

    reduceError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        return error?.message || 'Products could not be loaded.';
    }
}