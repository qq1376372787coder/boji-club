import Foundation
var checks=0
func check(_ value:Bool,_ label:String) { guard value else { fatalError(label) };checks+=1;print("PASS \(label)") }

@MainActor final class AccountService { struct User { let id:Int }; var user:User?=User(id:1) }
@MainActor final class SeasonRefreshFixture {
 var generation=UUID();var accountID:Int?=1;var loading=false;var lastProgressRefresh=Date()
 var progressRefreshTask:Task<Void,Never>?;var pendingProgressRefresh=false;var calls=0
 func activate(_ id:Int?) { if id != accountID { generation=UUID();accountID=id;progressRefreshTask?.cancel();progressRefreshTask=nil;pendingProgressRefresh=false } }
 func refresh(account:AccountService) async { calls+=1;loading=true;lastProgressRefresh=Date();try? await Task.sleep(for:.milliseconds(100));loading=false }
    func refreshAfterSync(account: AccountService) async {
        activate(account.user?.id)
        guard let owner=account.user?.id else { return }
        pendingProgressRefresh = true
        guard progressRefreshTask == nil else { return }
        let ticket=generation
        progressRefreshTask = Task {
            defer { if generation == ticket { progressRefreshTask = nil } }
            while pendingProgressRefresh, generation == ticket, account.user?.id == owner, !Task.isCancelled {
                pendingProgressRefresh = false
                let delay=max(0,3-Date().timeIntervalSince(lastProgressRefresh))
                if delay > 0 { do { try await Task.sleep(for:.seconds(delay)) } catch { return } }
                while loading, generation == ticket, !Task.isCancelled {
                    do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
                }
                guard generation == ticket, account.user?.id == owner, !Task.isCancelled else { return }
                await refresh(account: account)
            }
        }
    }
}

let refreshAccount=await AccountService();let refresher=await SeasonRefreshFixture()
await refresher.refreshAfterSync(account:refreshAccount)
await refresher.refreshAfterSync(account:refreshAccount)
try await Task.sleep(for:.seconds(3.4))
check(await refresher.calls == 1,"rapid sync callbacks coalesce without dropping refresh")
await MainActor.run { refresher.loading=true }
await refresher.refreshAfterSync(account:refreshAccount)
try await Task.sleep(for:.milliseconds(100))
await MainActor.run { refresher.loading=false }
try await Task.sleep(for:.seconds(3.2))
check(await refresher.calls == 2,"sync waits for active request then refreshes progress")
await refresher.refreshAfterSync(account:refreshAccount)
await MainActor.run { refreshAccount.user=AccountService.User(id:2);refresher.activate(2) }
try await Task.sleep(for:.seconds(3.3))
check(await refresher.calls == 2,"account switch cancels queued progress refresh")
print("PASS progress refresh rules: \(checks)")
