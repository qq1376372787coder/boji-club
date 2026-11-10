# RevenueCat 接入说明 · 0.13.70

价格、截图、苹果本地化、保存与 RevenueCat 关联的最新步骤，统一见“订阅设置与截图操作-先读这里.md”。旧 0.13.60 的半年方案已被年度方案替换。

SDK 使用官方 Swift Package 5.95.0，App Target 同时依赖 RevenueCat 和 RevenueCatUI。三档实际 Apple 商品为 yuefu/nianfu/yongjiu，权益 薄肌俱乐部_pro。苹果 appl_ Key 已配置。服务器已部署 API v2 主动会员核验，使用 APP_STORE + SANDBOX；备案期间无需先接通 Webhook。当前操作步骤见“0.13.70-先读这里.md”。

下面保留历史 Swift 接入示例；当前实现以 BojiClub/MembershipService.swift、AccountService.swift 和 RevenueCatViews.swift 为准。不要把下面的旧示例覆盖到项目，也不要再复制一套 configure 到 App 启动处。

## MembershipService.swift

```swift
import Foundation
import Combine
import RevenueCat

enum MembershipPurchaseState: Equatable {
    case unavailable(String), loading, inactive, active(expiration: Date?), purchasing, failed(String)
}

enum MembershipPlan: String, CaseIterable, Identifiable {
    case monthly, annual, lifetime
    var id: String { rawValue }
    var title: String {
        switch self { case .monthly: return "月度会员"; case .annual: return "年度会员"; case .lifetime: return "永久会员" }
    }
    var detail: String {
        switch self {
        case .monthly: return "每月自动续订"
        case .annual: return "每年自动续订"
        case .lifetime: return "一次购买，不自动续订"
        }
    }
}

/// The store drives purchase UI. Protected APIs use the server's authenticated
/// webhook ledger, never a client-supplied Boolean or UserDefaults flag.
@MainActor
final class MembershipService: ObservableObject {
    static let entitlementFallback = "薄肌俱乐部_pro"
    @Published private(set) var state: MembershipPurchaseState = .loading
    @Published private(set) var isConfigured = false
    @Published private(set) var serverMembershipActive = false
    @Published private(set) var storeMembershipActive = false
    @Published private(set) var currentOffering: Offering?
    @Published private(set) var customerInfo: CustomerInfo?
    @Published private(set) var offeringsError: String?
    @Published private(set) var loadingOfferings = false
    @Published private(set) var reconciliationError: String?
    @Published private(set) var notice: String?
    @Published private(set) var isBusy = false
    @Published private(set) var identityReady = false

    var hasMemberAccess: Bool { serverMembershipActive || isPreview }
    var requiresMembershipPurchase: Bool { accountID != nil && !hasMemberAccess }
    var appUserID: String? { accountID.map { "boji-\($0)" } }
    var canUseStore: Bool { accountID != nil && !isPreview && identityReady && isConfigured && !isBusy }
    var isTestStore: Bool { publicSDKKey.hasPrefix("test_") }
    var entitlementID: String { configuredString("RevenueCatMemberEntitlementID", fallback: Self.entitlementFallback) }

    private var accountID: Int?
    private var isPreview = false
    private var generation = UUID()
    private weak var accountService: AccountService?
    // Never run logIn/logOut concurrently: an old request could switch the global
    // SDK identity after a newer account has already signed in.
    private var identityTask: Task<Void, Never>?
    private var observerTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var reconciliationID = UUID()
    private var offeringsID = UUID()
    private var lastRefresh: Date?
    private var externalStoreOperation = false
    private var publicSDKKey: String { configuredString("RevenueCatPublicSDKKey", fallback: "") }

    private func configuredString(_ key: String, fallback: String) -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value.contains("$(") ? fallback : value
    }

    func activate(account: ClubAccount?, accountService: AccountService) {
        self.accountService = accountService
        serverMembershipActive = account?.membership?.active == true
        let preview = accountService.isPreviewAccount
        if accountID != account?.id || isPreview != preview {
            generation = UUID()
            reconciliationTask?.cancel(); reconciliationTask = nil
            observerTask?.cancel(); observerTask = nil
            accountID = account?.id; isPreview = preview; identityReady = false
            currentOffering = nil; customerInfo = nil; storeMembershipActive = false
            loadingOfferings = false; offeringsID = UUID(); offeringsError = nil
            reconciliationError = nil; notice = nil; lastRefresh = nil
            state = preview ? .active(expiration: nil) : .loading
        }
        if isPreview { state = .active(expiration: nil) }
        if serverMembershipActive { reconciliationError = nil }
        synchronizeIdentity()
    }

    private func synchronizeIdentity() {
        guard identityTask == nil, !isBusy else { return }
        guard !isPreview, let desired = appUserID else {
            if isConfigured && !Purchases.shared.isAnonymous {
                identityTask = Task { [weak self] in
                    do { _ = try await Purchases.shared.logOut() } catch { /* Store UI stays unavailable. */ }
                    self?.identityTask = nil
                    if self?.appUserID != nil && self?.isPreview == false { self?.synchronizeIdentity() }
                }
            }
            return
        }
        guard publicSDKKey.hasPrefix("appl_") || publicSDKKey.hasPrefix("test_") else {
            state = .unavailable("会员购买正在配置，请稍后再试。")
            return
        }
        #if !DEBUG
        guard !isTestStore else {
            state = .unavailable("此安装包的支付配置不正确，请联系开发者。")
            return // SDK intentionally crashes Release apps configured with test_ keys.
        }
        #endif
        if !isConfigured {
            #if DEBUG
            Purchases.logLevel = .debug
            #else
            Purchases.logLevel = .warn
            #endif
            Purchases.configure(with: Configuration.Builder(withAPIKey: publicSDKKey)
                .with(appUserID: desired).with(storeKitVersion: .storeKit2)
                .with(networkTimeout: 20).build())
            isConfigured = true
        }
        if Purchases.shared.appUserID == desired {
            identityReady = true
            observeCustomerInfo(); refresh()
            return
        }
        identityReady = false
        identityTask = Task { [weak self] in
            defer { self?.identityTask = nil }
            while let self, let target = self.appUserID, !self.isPreview {
                do {
                    let result = try await Purchases.shared.logIn(target)
                    guard self.appUserID == target && !self.isPreview else { continue }
                    self.identityReady = Purchases.shared.appUserID == target
                    self.apply(result.customerInfo)
                    self.identityTask = nil
                    self.observeCustomerInfo(); self.loadOfferings()
                    return
                } catch {
                    guard self.appUserID == target && !self.isPreview else { continue }
                    self.state = .failed("会员账号连接失败，请检查网络后重试。")
                    return
                }
            }
            if Purchases.isConfigured && !Purchases.shared.isAnonymous { _ = try? await Purchases.shared.logOut() }
            self?.identityTask = nil
            if self?.appUserID != nil && self?.isPreview == false { self?.synchronizeIdentity() }
        }
    }

    func refresh(force: Bool = false) {
        guard !isPreview, !isBusy else { return }
        guard identityReady, isConfigured, appUserID == Purchases.shared.appUserID else {
            synchronizeIdentity(); return
        }
        loadOfferings()
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 5 { return }
        lastRefresh = Date(); isBusy = true
        let ticket = generation
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.synchronizeIdentityIfNeeded() }
            do {
                let info = try await Purchases.shared.customerInfo(fetchPolicy: force ? .fetchCurrent : .notStaleCachedOrFetched)
                guard self.generation == ticket else { return }
                self.apply(info)
                if force { self.reconcileServerMembership() }
            } catch {
                guard self.generation == ticket else { return }
                self.notice = "暂时无法更新会员状态，已有记录仍然保留。请检查网络后重新查询。"
                if self.customerInfo == nil { self.state = .failed(self.notice!) }
            }
        }
    }

    private func synchronizeIdentityIfNeeded() {
        if !isConfigured || appUserID != Purchases.shared.appUserID || !identityReady { synchronizeIdentity() }
    }

    func package(for plan: MembershipPlan) -> Package? {
        guard let offering = currentOffering else { return nil }
        let standard: Package?
        let key: String
        switch plan {
        case .monthly: standard = offering.monthly; key = "RevenueCatMonthlyProductID"
        case .annual: standard = offering.annual; key = "RevenueCatAnnualProductID"
        case .lifetime: standard = offering.lifetime; key = "RevenueCatLifetimeProductID"
        }
        // Package types work across stores even when their product IDs differ.
        let fallback: String
        switch plan { case .monthly: fallback = "yuefu"; case .annual: fallback = "nianfu"; case .lifetime: fallback = "yongjiu" }
        let productID = configuredString(key, fallback: fallback)
        if let exact = offering.availablePackages.first(where: { $0.storeProduct.productIdentifier == productID }) {
            return packageMatchesPlan(exact, plan: plan) ? exact : nil
        }
        #if DEBUG
        if isTestStore, let standard { return packageMatchesPlan(standard, plan: plan) ? standard : nil }
        #endif
        return nil // Never sell another Apple product merely because its Package type matches.
    }

    private func packageMatchesPlan(_ package: Package, plan: MembershipPlan) -> Bool {
        let product = package.storeProduct
        if plan == .lifetime { return product.productType == .nonConsumable && product.subscriptionPeriod == nil }
        guard product.productType == .autoRenewableSubscription, let period = product.subscriptionPeriod else { return false }
        if plan == .monthly { return period.unit == .month && period.value == 1 }
        return (period.unit == .year && period.value == 1) || (period.unit == .month && period.value == 12)
    }

    func price(for plan: MembershipPlan) -> String? { package(for: plan)?.storeProduct.localizedPriceString }

    func purchase(_ plan: MembershipPlan) {
        guard let package = package(for: plan) else { notice = "会员方案尚未加载完成，请重新加载。"; return }
        Task { _ = await purchasePackage(package) }
    }

    /// Custom purchase buttons use the same SDK as RevenueCatUI.
    func purchasePackage(_ package: Package) async -> (userCancelled: Bool, error: Error?) {
        guard canUseStore, !storeMembershipActive,
              currentOffering?.availablePackages.contains(where: { $0 === package }) == true else {
            return (false, AccountError.message("会员状态或商品已变化，请重新查询后再试。"))
        }
        let ticket = generation
        isBusy = true; state = .purchasing; notice = nil
        defer { isBusy = false; synchronizeIdentityIfNeeded() }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            guard generation == ticket else { return (false, AccountError.message("账号已切换，请在原购买账号中查询结果。")) }
            apply(result.customerInfo)
            if !result.userCancelled {
                if !storeMembershipActive { notice = "购买已返回，但未发现会员权益。请恢复购买或联系客服，勿重复付款。" }
                reconcileServerMembership()
            }
            return (result.userCancelled, nil)
        } catch {
            guard generation == ticket else { return (false, error) }
            if isCancellation(error) { restoreKnownState(); return (true, nil) }
            handleStoreError(error)
            return (false, error)
        }
    }

    func restorePurchases() { Task { _ = await restoreFromStore() } }

    func restoreFromStore() async -> (success: Bool, error: Error?) {
        guard canUseStore else { return (false, AccountError.message("请等待会员账号连接完成。")) }
        let ticket = generation
        isBusy = true; notice = nil
        defer { isBusy = false; synchronizeIdentityIfNeeded() }
        do {
            let info = try await Purchases.shared.restorePurchases()
            guard generation == ticket else { return (false, AccountError.message("账号已切换，请在原账号重新查询。")) }
            apply(info)
            if !storeMembershipActive { notice = "没有找到可恢复的会员购买，请确认使用了购买时的账号。" }
            reconcileServerMembership()
            return (true, nil) // Successful restore is not proof of an active entitlement.
        } catch {
            if generation == ticket { handleStoreError(error) }
            return (false, error)
        }
    }

    func loadOfferings() {
        guard isConfigured, identityReady, !isPreview, !loadingOfferings else { return }
        loadingOfferings = true; offeringsError = nil
        let ticket = generation; let operation = UUID(); offeringsID = operation
        Task { [weak self] in
            do {
                let offerings = try await Purchases.shared.offerings()
                guard let self, self.generation == ticket, self.offeringsID == operation else { return }
                self.loadingOfferings = false; self.currentOffering = offerings.current
                if offerings.current?.availablePackages.isEmpty != false {
                    self.offeringsError = "暂时没有会员方案。请稍后重试或联系客服。"
                }
            } catch {
                guard let self, self.generation == ticket, self.offeringsID == operation else { return }
                self.loadingOfferings = false; self.offeringsError = "会员方案未能加载，请检查网络后重试。"
            }
        }
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(22)) } catch { return }
            guard let self, self.generation == ticket, self.offeringsID == operation, self.loadingOfferings else { return }
            self.offeringsID = UUID(); self.loadingOfferings = false
            self.offeringsError = "加载会员方案的时间较长，请检查网络后重试。"
        }
    }

    private func activeEntitlement(in info: CustomerInfo) -> EntitlementInfo? {
        guard let entitlement = info.entitlements.all[entitlementID], entitlement.isActive else { return nil }
        #if DEBUG
        // Test Store is sandbox even on a device without an Apple sandbox receipt.
        if isTestStore { return entitlement.isSandbox ? entitlement : nil }
        #endif
        return entitlement.isActiveInCurrentEnvironment ? entitlement : nil
    }

    private func apply(_ info: CustomerInfo) {
        guard identityReady, appUserID == Purchases.shared.appUserID else { return }
        customerInfo = info
        let entitlement = activeEntitlement(in: info)
        storeMembershipActive = entitlement != nil
        if let entitlement { state = .active(expiration: entitlement.expirationDate) }
        else { state = .inactive }
        if entitlement != nil, !serverMembershipActive, reconciliationTask == nil, reconciliationError == nil { reconcileServerMembership() }
    }

    private func restoreKnownState() {
        if let info = customerInfo { apply(info) } else { state = .inactive }
    }

    private func isCancellation(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == ErrorCode.errorDomain && value.code == ErrorCode.purchaseCancelledError.rawValue
    }

    func handleStoreError(_ error: Error) {
        restoreKnownState()
        let value = error as NSError
        if isCancellation(error) { return }
        switch value.domain == ErrorCode.errorDomain ? ErrorCode(rawValue: value.code) : nil {
        case .paymentPendingError: notice = "付款正在等待批准。批准后会员会自动更新，请勿重复购买。"
        case .productAlreadyPurchasedError: notice = "此商品已购买，请使用“恢复购买”查询会员。"
        case .receiptAlreadyInUseError, .receiptInUseByOtherSubscriberError, .purchaseBelongsToOtherUser:
            notice = "这份购买可能属于另一个俱乐部账号，请切换原账号或联系客服。"
        case .networkError, .offlineConnectionError, .productRequestTimedOut:
            notice = "网络暂时无法确认购买结果。请重新查询会员状态，勿重复付款。"
        default: notice = "购买或恢复未能完成，请稍后重试。仍有问题时请联系客服。"
        }
    }

    func beginCustomerCenterRestore(expectedUserID: String) -> Bool {
        guard canUseStore, appUserID == expectedUserID else { return false }
        externalStoreOperation = true; isBusy = true; notice = nil
        return true
    }

    func beginPaywallPurchase(_ package: Package, expectedUserID: String) -> Bool {
        guard !storeMembershipActive,
              MembershipPlan.allCases.contains(where: { self.package(for: $0)?.storeProduct.productIdentifier == package.storeProduct.productIdentifier }),
              currentOffering?.availablePackages.contains(where: { $0.identifier == package.identifier && $0.storeProduct.productIdentifier == package.storeProduct.productIdentifier }) == true,
              beginCustomerCenterRestore(expectedUserID: expectedUserID) else { return false }
        state = .purchasing
        return true
    }

    func finishExternalStoreOperation(_ info: CustomerInfo?, error: Error?, expectedUserID: String) {
        guard externalStoreOperation else { return }
        externalStoreOperation = false; isBusy = false
        if appUserID == expectedUserID && identityReady {
            restoreKnownState()
            if let info {
                apply(info)
                if !storeMembershipActive { notice = "未找到可恢复的会员购买。" }
                reconcileServerMembership()
            }
            if let error { handleStoreError(error) }
        }
        synchronizeIdentityIfNeeded()
    }

    func reconcileServerMembership() {
        guard accountID != nil, !isPreview else { return }
        reconciliationError = nil; reconciliationTask?.cancel()
        let ticket = generation; let operation = UUID(); reconciliationID = operation
        reconciliationTask = Task { [weak self] in
            defer { if let self, self.reconciliationID == operation { self.reconciliationTask = nil } }
            for attempt in 0..<12 {
                guard let self, !Task.isCancelled, self.generation == ticket else { return }
                await self.accountService?.refreshAccount()
                guard self.generation == ticket, !Task.isCancelled else { return }
                self.serverMembershipActive = self.accountService?.user?.membership?.active == true
                if self.serverMembershipActive || !self.storeMembershipActive { return }
                do { try await Task.sleep(for: .seconds(attempt < 3 ? 2 : 5)) } catch { return }
            }
            guard let self, self.generation == ticket, !Task.isCancelled else { return }
            self.reconciliationError = "购买已完成，会员仍在同步。请勿重复付款，可稍后重新查询或联系客服。"
        }
    }

    func refreshMembershipStatus() { refresh(force: true) }

    private func observeCustomerInfo() {
        guard observerTask == nil, let userID = appUserID, identityReady else { return }
        let ticket = generation
        observerTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                guard self.identityReady, self.appUserID == userID, Purchases.shared.appUserID == userID, !self.isBusy else { continue }
                self.apply(info)
            }
        }
    }
}

```

## RevenueCatViews.swift

```swift
import SwiftUI
import RevenueCat
import RevenueCatUI

struct MembershipView: View {
    let isMandatory: Bool
    init(isMandatory: Bool = false) { self.isMandatory = isMandatory }
    #if DEBUG
    private var screenshotPreview = false
    init(screenshotPreview: Bool) { self.isMandatory = false; self.screenshotPreview = screenshotPreview }
    #endif
    private var isPricePreview: Bool {
        #if DEBUG
        return screenshotPreview
        #else
        return false
        #endif
    }
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var membership: MembershipService
    @State private var showingPaywall = false
    @State private var showingCustomerCenter = false
    @State private var legalDocument: LegalDocument?
    @State private var selectedPlan: MembershipPlan = .annual
    @State private var previewNotice = false
    #if DEBUG
    @State private var showingPricePreview = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if membership.isTestStore && !isPricePreview {
                        Label("当前为测试购买，不会扣款。", systemImage: "testtube.2")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !isPricePreview { statusCard }
                    if isPricePreview || !membership.storeMembershipActive { plansCard }
                    if !isPricePreview { actionsCard }
                    if let message = membership.notice, !isPricePreview {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityLabel(message)
                    }
                    legalFooter
                    if isPricePreview {
                        Text("开发预览 · 展示拟定价格，不会发起购买。连接商店后请重新核对并截取实际页面。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(ClubUI.pageInset)
            }
            .background { ClubBackground() }
            .navigationTitle("俱乐部会员").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isMandatory { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
                #if DEBUG
                if !isPricePreview { ToolbarItem(placement: .topBarLeading) { Button("价格预览") { showingPricePreview = true } } }
                #endif
            }
            #if DEBUG
            .sheet(isPresented: $showingPricePreview) { MembershipView(screenshotPreview: true) }
            #endif
            .sheet(isPresented: $showingPaywall) {
                if let offering = membership.currentOffering {
                    ClubRevenueCatPaywall(offering: offering, appUserID: membership.appUserID ?? "")
                }
            }
            .sheet(isPresented: $showingCustomerCenter, onDismiss: { membership.refresh(force: true) }) {
                ClubCustomerCenterView(appUserID: membership.appUserID ?? "")
            }
            .sheet(item: $legalDocument) { LegalDocumentView(document: $0) }
            .onChange(of: membership.appUserID) { _, _ in
                showingPaywall = false; showingCustomerCenter = false
            }
            .alert("会员价格页面预览", isPresented: $previewNotice) {
                Button("知道了", role: .cancel) { }
            } message: { Text("这是开发预览，不会扣款或开通会员。实际购买需要连接 Apple 商品与 RevenueCat。") }
            .task { if !isPricePreview { membership.refresh(force: true) } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BOJI CLUB").font(.caption.weight(.bold)).tracking(3).foregroundStyle(.secondary)
            Text("薄肌俱乐部Pro").font(.largeTitle.bold())
            Text("把认真记录，变成你的进步。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch membership.state {
        case .active(let expiration):
            ClubCard {
                Label("会员购买已确认", systemImage: "checkmark.seal.fill").font(.headline)
                if let expiration {
                    Text("有效至 \(expiration.formatted(date: .abbreviated, time: .omitted))").font(.subheadline)
                    if let entitlement = membership.customerInfo?.entitlements.all[membership.entitlementID], !entitlement.willRenew {
                        Text("已关闭自动续订；到期前仍可使用。").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text(membership.storeMembershipActive ? "永久会员 · 一次购买，不自动续订" : "当前账号会员权益")
                        .font(.subheadline)
                }
                if !membership.serverMembershipActive {
                    Text(membership.reconciliationError ?? "正在同步俱乐部会员，完成后即可使用。请勿重复购买。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("重新查询会员状态") { membership.refreshMembershipStatus() }
                        .buttonStyle(SecondaryButton()).disabled(membership.isBusy)
                }
            }
        case .loading:
            ClubLoadingCard(title: "正在连接会员服务…", detail: "获取账号权益与会员方案。")
        case .purchasing:
            ClubLoadingCard(title: "正在确认购买…", detail: "请完成购买窗口中的操作。")
        case .unavailable(let message), .failed(let message):
            ClubCard {
                Text(message).font(.subheadline)
                Button("重新连接") { membership.refreshMembershipStatus() }.buttonStyle(SecondaryButton())
            }
        case .inactive:
            if membership.serverMembershipActive {
                ClubCard {
                    Label("俱乐部会员已生效", systemImage: "checkmark.seal.fill").font(.headline)
                    Text("当前权益由俱乐部账号提供，可在这里购买或管理商店会员。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var plansCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("专属训练计划与逐组记录", systemImage: "checkmark.circle.fill")
                Label("拍照、语音饮食登记", systemImage: "checkmark.circle.fill")
                Label("每日复盘与每周回顾", systemImage: "checkmark.circle.fill")
                Label("云端同步与成长记录", systemImage: "checkmark.circle.fill")
            }.font(.subheadline)
            Divider().padding(.vertical, 4)
            SectionTitle(title: "选择适合你的方案", symbol: "crown")
            if membership.loadingOfferings && !isPricePreview { ProgressView("正在加载价格…") }
            ForEach(MembershipPlan.allCases) { plan in
                MembershipPlanOption(plan: plan, price: displayPrice(for: plan), selected: selectedPlan == plan) {
                    selectedPlan = plan
                }
            }
            Button("开通\(selectedPlan.title)") {
                if isPricePreview { previewNotice = true }
                else { membership.purchase(selectedPlan) }
            }.buttonStyle(PrimaryButton())
                .disabled(!isPricePreview && (!membership.canUseStore || membership.package(for: selectedPlan) == nil))
            Text(selectedPlan.detail).font(.footnote).foregroundStyle(.secondary)
            if let message = membership.offeringsError, !isPricePreview {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                Button("重新加载会员方案") { membership.loadOfferings() }.buttonStyle(SecondaryButton())
            }
            if !isPricePreview {
                Button("查看完整会员介绍") { showingPaywall = true }
                    .buttonStyle(SecondaryButton())
                    .disabled(!membership.canUseStore || membership.currentOffering?.availablePackages.isEmpty != false)
            }
        }
    }

    private func displayPrice(for plan: MembershipPlan) -> String {
        #if DEBUG
        if isPricePreview {
            switch plan { case .monthly: return "¥12"; case .annual: return "¥28"; case .lifetime: return "¥38" }
        }
        #endif
        return membership.price(for: plan) ?? (membership.loadingOfferings ? "获取中" : "暂不可用")
    }

    private var actionsCard: some View {
        ClubCard {
            Button("恢复购买") { membership.restorePurchases() }
                .buttonStyle(SecondaryButton()).disabled(!membership.canUseStore)
            Button("管理会员与购买记录") { showingCustomerCenter = true }
                .buttonStyle(SecondaryButton()).disabled(!membership.canUseStore)
            Text("换手机或重装后，请登录原俱乐部账号，再恢复购买。恢复成功也需要核对会员是否仍有效。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("月度和年度会员自动续订，可在 Apple 订阅设置中取消。永久会员为一次性购买，不自动续订。实际价格以购买窗口为准。购买永久会员不会自动取消已有订阅。")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                Button("隐私政策") { legalDocument = .privacy }
                Button("使用条款") { legalDocument = .terms }
            }.font(.footnote.weight(.medium))
        }
    }
}

private struct MembershipPlanOption: View {
    let plan: MembershipPlan
    let price: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var unit: String {
        switch plan { case .monthly: return "/ 月"; case .annual: return "/ 年"; case .lifetime: return "一次付费" }
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(plan.title).font(.headline)
                    Text(plan.detail).font(.footnote).opacity(0.75)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(price).font(.title2.bold())
                    Text(unit).font(.caption).opacity(0.75)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.black : Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(selected ? Color.black : Color.black.opacity(0.1), lineWidth: 1) }
        }
        .buttonStyle(ClubMotionButton())
        .accessibilityLabel("\(plan.title)，\(price)，\(plan.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selected)
    }
}

/// Use the actual current Offering; RevenueCat provides its native default UI if
/// a custom paywall has not yet been published on this Offering.
private struct ClubRevenueCatPaywall: View {
    let offering: Offering
    let appUserID: String
    @EnvironmentObject private var membership: MembershipService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PaywallView(offering: offering, displayCloseButton: true)
            .onPurchaseInitiated { package, resume in
                Task { @MainActor in
                    resume(shouldProceed: membership.beginPaywallPurchase(package, expectedUserID: appUserID))
                }
            }
            .onRestoreInitiated { resume in
                Task { @MainActor in
                    resume(shouldProceed: membership.beginCustomerCenterRestore(expectedUserID: appUserID))
                }
            }
            .onPurchaseCompleted { info in
                membership.finishExternalStoreOperation(info, error: nil, expectedUserID: appUserID)
                if membership.storeMembershipActive { dismiss() }
            }
            .onRestoreCompleted { info in
                membership.finishExternalStoreOperation(info, error: nil, expectedUserID: appUserID)
                if membership.storeMembershipActive { dismiss() }
            }
            .onPurchaseCancelled {
                membership.finishExternalStoreOperation(nil, error: nil, expectedUserID: appUserID)
            }
            .onPurchaseFailure { error in
                membership.finishExternalStoreOperation(nil, error: error, expectedUserID: appUserID)
            }
            .onRestoreFailure { error in
                membership.finishExternalStoreOperation(nil, error: error, expectedUserID: appUserID)
            }
            .interactiveDismissDisabled(membership.isBusy)
    }
}

private struct ClubCustomerCenterView: View {
    let appUserID: String
    @EnvironmentObject private var membership: MembershipService
    var body: some View {
        CustomerCenterView()
            .onCustomerCenterRestoreInitiated { resume in
                resume(shouldProceed: membership.beginCustomerCenterRestore(expectedUserID: appUserID))
            }
            .onCustomerCenterRestoreCompleted { info in
                membership.finishExternalStoreOperation(info, error: nil, expectedUserID: appUserID)
            }
            .onCustomerCenterRestoreFailed { error in
                membership.finishExternalStoreOperation(nil, error: error, expectedUserID: appUserID)
            }
            .interactiveDismissDisabled(membership.isBusy)
    }
}

```
