/**
 * @description
 * Server side of the skuSearcher LWC (SKU Searcher on the Convert Lead
 * screen): lists active Products, or those whose name or Product Code (SKU)
 * contains the search term, and reloads the products already picked when the
 * screen is shown again.
 *
 * The Product catalogue is read in system mode: staff converting a Lead pick
 * from the full catalogue even when their profile has no Product access,
 * and the flow saving the picks runs in system mode too.
 */
public with sharing class SkuSearchController {

    @TestVisible
    private static final Integer MAX_RESULTS = 50;

    /**
     * Active Products by Name: all of them (up to MAX_RESULTS) for a blank
     * term, else those whose Name or Product Code contains it.
     */
    @AuraEnabled(cacheable=true)
    public static List<Product2> searchProducts(String searchTerm) {
        String term = searchTerm == null ? '' : searchTerm.trim();
        if (String.isBlank(term)) {
            return [
                SELECT Id, Name, ProductCode, Family, Description, Available_Quantity__c
                FROM Product2
                WHERE IsActive = true
                WITH SYSTEM_MODE
                ORDER BY Name
                LIMIT :MAX_RESULTS
            ];
        }
        String pattern = '%' + term.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%';
        return [
            SELECT Id, Name, ProductCode, Family, Description, Available_Quantity__c
            FROM Product2
            WHERE IsActive = true
              AND (Name LIKE :pattern OR ProductCode LIKE :pattern)
            WITH SYSTEM_MODE
            ORDER BY Name
            LIMIT :MAX_RESULTS
        ];
    }

    /** The given Products, for showing picks made on an earlier visit. */
    @AuraEnabled(cacheable=true)
    public static List<Product2> getProducts(List<Id> productIds) {
        if (productIds == null || productIds.isEmpty()) {
            return new List<Product2>();
        }
        return [
            SELECT Id, Name, ProductCode, Family, Description, Available_Quantity__c
            FROM Product2
            WHERE Id IN :productIds
            WITH SYSTEM_MODE
        ];
    }
}