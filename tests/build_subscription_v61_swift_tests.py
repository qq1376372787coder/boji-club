from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
source=(root/'BojiClub/MembershipService.swift').read_text('utf-8')
plan=source[source.index('enum MembershipPlan:'):source.index('/// The store drives')]
start=source.index('    private func packageMatchesPlan(')
opening=source.index('{',start);depth=1;end=opening+1
while depth:
    if source[end]=='{':depth+=1
    elif source[end]=='}':depth-=1
    end+=1
rules=source[start:end].replace('private func','func',1)
mocks='''
enum ProductType { case nonConsumable, consumable, autoRenewableSubscription, nonRenewingSubscription }
struct SubscriptionPeriod {
    enum Unit { case day, week, month, year }
    let value: Int
    let unit: Unit
}
struct StoreProduct { let productType: ProductType; let subscriptionPeriod: SubscriptionPeriod? }
struct Package { let storeProduct: StoreProduct }
func make(_ type: ProductType, _ value: Int? = nil, _ unit: SubscriptionPeriod.Unit = .month) -> Package {
    Package(storeProduct: StoreProduct(productType: type, subscriptionPeriod: value.map { SubscriptionPeriod(value: $0, unit: unit) }))
}
func check(_ value: Bool, _ label: String) { precondition(value, label); print("PASS \\(label)") }
'''
checks='''
check(packageMatchesPlan(make(.autoRenewableSubscription, 1), plan: .monthly), "monthly accepts one month")
check(!packageMatchesPlan(make(.autoRenewableSubscription, 1, .year), plan: .monthly), "monthly rejects year")
check(packageMatchesPlan(make(.autoRenewableSubscription, 1, .year), plan: .annual), "annual accepts one year")
check(packageMatchesPlan(make(.autoRenewableSubscription, 12), plan: .annual), "annual accepts twelve months")
check(!packageMatchesPlan(make(.autoRenewableSubscription, 6), plan: .annual), "annual rejects six months")
check(packageMatchesPlan(make(.nonConsumable), plan: .lifetime), "lifetime accepts non-consumable")
check(!packageMatchesPlan(make(.consumable), plan: .lifetime), "lifetime rejects consumable")
check(!packageMatchesPlan(make(.autoRenewableSubscription, 1, .year), plan: .lifetime), "lifetime rejects annual subscription")
check(!packageMatchesPlan(make(.nonRenewingSubscription), plan: .lifetime), "lifetime rejects non-renewing subscription")
check(!packageMatchesPlan(make(.nonConsumable), plan: .monthly), "monthly rejects non-consumable")
'''
Path(sys.argv[1]).write_text('import Foundation\n'+plan+mocks+rules+'\n'+checks,'utf-8')
