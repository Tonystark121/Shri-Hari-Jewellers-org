@IsTest
private class SkuSearchControllerTest {

    @TestSetup
    static void setup() {
        insert new List<Product2>{
            new Product2(Name = 'Temple Necklace Set', ProductCode = 'SH-NK-001', IsActive = true, Available_Quantity__c = 25),
            new Product2(Name = 'Kundan Jhumka', ProductCode = 'SH-ER-014', IsActive = true),
            new Product2(Name = 'Retired Bangle', ProductCode = 'SH-BG-099', IsActive = false)
        };
    }

    @IsTest
    static void findsByName() {
        List<Product2> results = SkuSearchController.searchProducts('necklace');

        Assert.areEqual(1, results.size());
        Assert.areEqual('SH-NK-001', results[0].ProductCode);
        Assert.areEqual(25, results[0].Available_Quantity__c);
    }

    @IsTest
    static void findsBySku() {
        List<Product2> results = SkuSearchController.searchProducts(' sh-er ');

        Assert.areEqual(1, results.size());
        Assert.areEqual('Kundan Jhumka', results[0].Name);
    }

    @IsTest
    static void skipsInactiveProducts() {
        Assert.areEqual(0, SkuSearchController.searchProducts('Bangle').size());
    }

    @IsTest
    static void listsActiveProductsForBlankTerm() {
        List<Product2> results = SkuSearchController.searchProducts('  ');

        Assert.areEqual(2, results.size());
        Assert.areEqual('Kundan Jhumka', results[0].Name);
        Assert.areEqual(2, SkuSearchController.searchProducts(null).size());
    }

    @IsTest
    static void searchesSingleCharacter() {
        Assert.areEqual(1, SkuSearchController.searchProducts('j').size());
    }

    @IsTest
    static void treatsWildcardsAsText() {
        Assert.areEqual(0, SkuSearchController.searchProducts('%%').size());
        Assert.areEqual(0, SkuSearchController.searchProducts('__').size());
    }

    @IsTest
    static void reloadsPickedProducts() {
        List<Id> ids = new List<Id>(new Map<Id, Product2>([SELECT Id FROM Product2]).keySet());

        Assert.areEqual(3, SkuSearchController.getProducts(ids).size());
        Assert.areEqual(0, SkuSearchController.getProducts(new List<Id>()).size());
        Assert.areEqual(0, SkuSearchController.getProducts(null).size());
    }
}