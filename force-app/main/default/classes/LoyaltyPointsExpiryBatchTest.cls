/**
 * Tests for LoyaltyPointsExpiryBatch: unspent points on Earn and Bonus lots
 * expire the day after their Expiry Date, and the balance drops by them.
 */
@IsTest
private class LoyaltyPointsExpiryBatchTest {

    private static Loyalty_Transaction__c lot(Id loyaltyId, String type, Integer points, Date expiry) {
        return new Loyalty_Transaction__c(
            Loyalty_Record__c = loyaltyId,
            Transaction_Type__c = type,
            Status__c = 'Active',
            Points_Earned__c = points,
            Remaining_Points__c = points,
            Credit_Date__c = Date.today().addDays(-60),
            Expiry_Date__c = expiry
        );
    }

    @IsTest
    static void earnAndBonusLotsPastTheirExpiryDateExpire() {
        Account customer = new Account(Name = 'Expiry Customer');
        insert customer;
        Loyalty_Record__c loyalty = [SELECT Id FROM Loyalty_Record__c WHERE Account__c = :customer.Id WITH SYSTEM_MODE];
        loyalty.Points_Balance__c = 500;
        update as system loyalty;

        Loyalty_Transaction__c earned = lot(loyalty.Id, 'Earn', 200, Date.today().addDays(-1));
        Loyalty_Transaction__c bonus = lot(loyalty.Id, 'Bonus', 100, Date.today().addDays(-1));
        Loyalty_Transaction__c current = lot(loyalty.Id, 'Bonus', 200, Date.today());
        insert as system new List<Loyalty_Transaction__c>{ earned, bonus, current };

        Test.startTest();
        Database.executeBatch(new LoyaltyPointsExpiryBatch());
        Test.stopTest();

        Map<Id, Loyalty_Transaction__c> lots = new Map<Id, Loyalty_Transaction__c>([
            SELECT Id, Status__c, Remaining_Points__c FROM Loyalty_Transaction__c WITH SYSTEM_MODE
        ]);
        Assert.areEqual('Expired', lots.get(earned.Id).Status__c, 'An Earn lot past its expiry date expires');
        Assert.areEqual('Expired', lots.get(bonus.Id).Status__c, 'So does a Bonus lot');
        Assert.areEqual(100, lots.get(bonus.Id).Remaining_Points__c, 'Remaining keeps how many points expired');
        Assert.areEqual('Active', lots.get(current.Id).Status__c, 'A lot is usable on its expiry date');
        Assert.areEqual(
            200,
            [SELECT Points_Balance__c FROM Loyalty_Record__c WHERE Id = :loyalty.Id WITH SYSTEM_MODE].Points_Balance__c,
            '500 - 200 - 100'
        );
    }

    @IsTest
    static void runsOnASchedule() {
        Test.startTest();
        String jobId = System.schedule('Loyalty expiry test', '0 0 1 * * ?', new LoyaltyPointsExpiryBatch());
        Test.stopTest();

        Assert.isNotNull(jobId, 'Scheduled');
    }
}
