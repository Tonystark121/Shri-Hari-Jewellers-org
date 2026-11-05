import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { FlowNavigationFinishEvent } from 'lightning/flowSupport';

/**
 * Flow screen component: opens a record as soon as it is shown, then
 * finishes the flow unless Don't Finish Flow is on.
 *
 * Used at the end of Convert Lead (the customer Account) and New Lead (the
 * new Lead, or the enquiry Case).
 *
 * The record replaces the current page in the browser history, so Back
 * does not return to the flow. The flow is then finished, which closes the
 * Convert window or ends the flow on the Lead page - unless Don't Finish
 * Flow is on: flows started from a URL with a return address (New Lead),
 * where finishing would take the user back to that address instead.
 *
 * Navigation starts once the component is on screen. Inside Lightning
 * pages (Convert Lead) in-app navigation is used. A flow opened from a
 * /flow/ URL (New Lead) runs inside a frame on the my.salesforce.com domain,
 * where in-app navigation cannot reach the Lightning page and record pages
 * refuse to load inside the frame - so the whole window is sent to the
 * record page instead. The link (also aimed at the whole window) is a
 * fallback the user can always click, e.g. if the browser blocks a window
 * change it did not see the user ask for.
 */
export default class RecordRedirect extends NavigationMixin(LightningElement) {
    /** Id of the record to open, e.g. the customer Account. */
    @api recordToOpen;

    /** Leave the flow open instead of finishing it after opening the record. */
    @api skipFinish = false;

    /** Set by the flow: the navigation actions it allows (FINISH, ...). */
    @api availableActions = [];

    started = false;

    /** The record page's address: works for any object. */
    get recordUrl() {
        return this.recordToOpen ? '/lightning/r/' + this.recordToOpen + '/view' : '#';
    }

    renderedCallback() {
        if (this.started || !this.recordToOpen) {
            return;
        }
        this.started = true;
        this.openRecord();
    }

    /** True when the flow runs as a full page opened from a /flow/ URL. */
    get isFullPageFlow() {
        return window.location.pathname.startsWith('/flow/');
    }

    openRecord() {
        if (this.isFullPageFlow) {
            window.open(this.recordUrl, '_top');
            return;
        }
        this[NavigationMixin.Navigate](
            {
                type: 'standard__recordPage',
                attributes: { recordId: this.recordToOpen, actionName: 'view' }
            },
            true
        );
        if (!this.skipFinish && Array.isArray(this.availableActions) && this.availableActions.includes('FINISH')) {
            this.dispatchEvent(new FlowNavigationFinishEvent());
        }
    }
}
