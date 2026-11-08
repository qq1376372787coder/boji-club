import Foundation
import Combine
import RevenueCat
import StoreKit

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

/// The server-confirmed entitlement controls entry. Store purchase state only
/// describes purchase progress and cannot unlock protected app features.
enum MembershipAccessPolicy {
    static func grantsAccess(serverActive: Bool, storeActive: Bool) -> Bool { serverActive }

    static func canEnterApp(requestedAccountID: Int?, verifiedAccountID: Int?, serverActive: Bool) -> Bool {
        guard let requestedAccountID, requestedAccountID == verifiedAccountID else { return false }
        return serverActive
    }

    static func expiration(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: raw) { return date }
        let sql = DateFormatter()
        sql.locale = Locale(identifier: "en_US_POSIX")
        sql.timeZone = TimeZone(secondsFromGMT: 0)
        sql.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sql.isLenient = false
        return sql.date(from: raw)
    }

    static func serverEntitlementValid(active: Bool, expiresAt: String?, lifetime: Bool?, now: Date = Date()) -> Bool {
        guard active else { return false }
        if lifetime == true { return true }
        guard let end = expiration(expiresAt) else { return false }
        return end > now
    }
}

/// The store drives purchase UI. Protected APIs use the server's authenticated
/// verified server state, never a client-supplied Boolean or UserDefaults flag.
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
    @Published private(set) var purchaseDiagnostics = "尚未运行检查。"
    @Published private(set) var checkingPurchaseServices = false
    private var purchaseDiagnosticsID = UUID()
    private var purchaseDiagnosticsTask: Task<Void, Never>?
    private var lastOfferingFailure: String?
    var supportsPurchaseDiagnostics: Bool {
        #if DEBUG || BOJI_TESTFLIGHT
        return true
        #else
        return false
        #endif
    }
    @Published private(set) var loadingOfferings = false
    @Published private(set) var reconciliationError: String?
    @Published private(set) var notice: String?
    @Published private(set) var isBusy = false
    @Published private(set) var identityReady = false

    private var expirationTask: Task<Void, Never>?

    var isVerifyingMembership: Bool { storeMembershipActive && !serverMembershipActive }
    var hasMemberAccess: Bool {
        MembershipAccessPolicy.grantsAccess(serverActive: serverMembershipActive, storeActive: storeMembershipActive)
    }
    func hasMemberAccess(for requestedAccountID: Int?) -> Bool {
        MembershipAccessPolicy.canEnterApp(requestedAccountID: requestedAccountID,
                                            verifiedAccountID: accountID, serverActive: hasMemberAccess)
    }
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
        let preview = accountService.isPreviewAccount
        if accountID != account?.id || isPreview != preview {
            generation = UUID()
            reconciliationTask?.cancel(); reconciliationTask = nil
            observerTask?.cancel(); observerTask = nil
            expirationTask?.cancel(); expirationTask = nil
            accountID = account?.id; isPreview = preview; identityReady = false
            purchaseDiagnosticsID = UUID()
            purchaseDiagnosticsTask?.cancel(); purchaseDiagnosticsTask = nil
            checkingPurchaseServices = false; purchaseDiagnostics = "尚未运行检查。"; lastOfferingFailure = nil
            currentOffering = nil; customerInfo = nil; storeMembershipActive = false
            loadingOfferings = false; offeringsID = UUID(); offeringsError = nil
            reconciliationError = nil; notice = nil; lastRefresh = nil
            state = preview ? .active(expiration: nil) : .loading
        }
        updateServerMembership()
        if isPreview {
            #if DEBUG
            let scenario = ProcessInfo.processInfo.environment["BOJI_PREVIEW_MEMBERSHIP"]
            if scenario == "inactive" || scenario == "verifying" {
                serverMembershipActive = false
                storeMembershipActive = scenario == "verifying"
                state = storeMembershipActive ? .active(expiration: nil) : .inactive
            } else { state = .active(expiration: nil) }
            #else
            state = .inactive
            serverMembershipActive = false
            #endif
        }
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
        updateServerMembership()
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
                let fallback = "暂时无法更新会员状态，请检查网络后重新查询。"
                if self.customerInfo == nil { self.state = .failed(self.notice ?? fallback) }
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

    var lifetimeOwned: Bool {
        // The server marks 9999-12-31 entitlements explicitly; use it when
        // RevenueCat reports a monthly entitlement alongside a lifetime one.
        if accountService?.user?.membership?.active == true,
           accountService?.user?.membership?.lifetime == true { return true }
        let identifier = configuredString("RevenueCatLifetimeProductID", fallback: "yongjiu")
        // Historical purchases alone do not establish current ownership (refunds).
        return customerInfo?.entitlements.active[entitlementID]?.productIdentifier == identifier
    }
    var canUpgradeToLifetime: Bool { storeMembershipActive && !lifetimeOwned && customerInfo != nil }
    private func permitsPurchase(_ package: Package) -> Bool {
        let permanent = canUpgradeToLifetime && self.package(for: .lifetime)?.storeProduct.productIdentifier == package.storeProduct.productIdentifier
        return MembershipUpgradePolicy.permitsPurchase(activeMember: storeMembershipActive, lifetimeOwned: lifetimeOwned, lifetimePackage: permanent)
    }

    func price(for plan: MembershipPlan) -> String? { package(for: plan)?.storeProduct.localizedPriceString }

    func purchase(_ plan: MembershipPlan) {
        guard let package = package(for: plan) else { notice = "会员方案尚未加载完成，请重新加载。"; return }
        Task { _ = await purchasePackage(package) }
    }

    /// Custom purchase buttons use the same SDK as RevenueCatUI.
    func purchasePackage(_ package: Package) async -> (userCancelled: Bool, error: Error?) {
        guard canUseStore, permitsPurchase(package),
              currentOffering?.availablePackages.contains(where: { $0 === package }) == true else {
            return (false, AccountError.message("会员状态或商品已变化，请重新查询后再试。"))
        }
        let ticket = generation
        isBusy = true; state = .purchasing; notice = nil
        let purchasingLifetime = self.package(for: .lifetime)?.storeProduct.productIdentifier == package.storeProduct.productIdentifier
        defer { isBusy = false; synchronizeIdentityIfNeeded() }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            guard generation == ticket else { return (false, AccountError.message("账号已切换，请在原购买账号中查询结果。")) }
            apply(result.customerInfo)
            if !result.userCancelled {
                if purchasingLifetime {
                    notice = lifetimeOwned
                        ? "永久会员权益已确认。请到 Apple 订阅设置关闭原订阅，避免继续续费。"
                        : "购买已返回，永久会员权益仍待确认。请重新查询或恢复购买，勿重复付款。"
                } else if !storeMembershipActive { notice = "购买已返回，但未发现会员权益。请恢复购买或联系客服，勿重复付款。" }
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
                self.lastOfferingFailure = nil
                if offerings.current?.availablePackages.isEmpty != false {
                    self.lastOfferingFailure = "RC_EMPTY_OFFERING"
                    self.offeringsError = "暂时没有可用的会员方案，请稍后重试。"
                } else if MembershipPlan.allCases.contains(where: { self.package(for: $0) == nil }) {
                    self.lastOfferingFailure = "RC_PARTIAL_OR_MISMATCHED_PRODUCTS"
                    self.offeringsError = "部分会员方案暂不可用，你仍可选择已显示价格的方案。"
                }
            } catch {
                guard let self, self.generation == ticket, self.offeringsID == operation else { return }
                self.loadingOfferings = false
                self.lastOfferingFailure = MembershipOfferingFailure.codes(error)
                self.offeringsError = MembershipOfferingFailure.message(error)
            }
        }
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(22)) } catch { return }
            guard let self, self.generation == ticket, self.offeringsID == operation, self.loadingOfferings else { return }
            self.offeringsID = UUID(); self.loadingOfferings = false
            self.lastOfferingFailure = "APP_OFFERINGS_TIMEOUT_22S"
            self.offeringsError = "加载会员方案的时间较长，请检查网络后重试。"
        }
    }

    /// Read-only checks for TestFlight support. No purchase, restore, entitlement
    /// mutation or receipt upload; the report contains no account ID or credential.
    func checkPurchaseServices() {
        guard supportsPurchaseDiagnostics, !checkingPurchaseServices, !isBusy else { return }
        let operation = UUID(); purchaseDiagnosticsID = operation
        checkingPurchaseServices = true
        let productIDs = [configuredString("RevenueCatMonthlyProductID", fallback: "yuefu"),
                          configuredString("RevenueCatAnnualProductID", fallback: "nianfu"),
                          configuredString("RevenueCatLifetimeProductID", fallback: "yongjiu")]
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        purchaseDiagnostics = "版本：\(version) (\(build))\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\nBundle ID：\(Bundle.main.bundleIdentifier ?? "?")\n最近方案请求：\(lastOfferingFailure ?? "未记录错误")\n\n检查中…"
        let header = purchaseDiagnostics.replacingOccurrences(of: "\n检查中…", with: "")
        let sdkKey = publicSDKKey
        purchaseDiagnosticsTask = Task { [weak self] in
            let api = await Self.checkOfferingAPI(key: sdkKey)
            guard let self, self.purchaseDiagnosticsID == operation, !Task.isCancelled else { return }
            self.purchaseDiagnostics = header + "\n" + api + "\n\n正在向 Apple 查询商品…"
            let storefront = await Storefront.current
            guard self.purchaseDiagnosticsID == operation, !Task.isCancelled else { return }
            let region = "Apple 商店地区：\(storefront?.countryCode ?? "未返回")"
            self.purchaseDiagnostics = header + "\n" + api + "\n" + region + "\n\n正在向 Apple 查询商品…"
            do {
                let products = try await StoreKit.Product.products(for: productIDs)
                guard self.purchaseDiagnosticsID == operation, !Task.isCancelled else { return }
                let found = Set(products.map(\.id))
                let rows = products.sorted { $0.id < $1.id }.map {
                    "\($0.id)：\($0.displayPrice)，类型 \($0.type.rawValue)"
                }
                let missing = productIDs.filter { !found.contains($0) }
                self.purchaseDiagnostics = header + "\n" + api + "\n" + region
                    + "\nApple 返回商品：\(products.count)/\(productIDs.count)\n" + rows.joined(separator: "\n")
                    + (missing.isEmpty ? "" : "\nApple 未返回：" + missing.joined(separator: ", "))
                    + "\n\n检查只读取商品资料，不会扣费或开通会员。"
            } catch {
                guard self.purchaseDiagnosticsID == operation, !Task.isCancelled else { return }
                self.purchaseDiagnostics = header + "\n" + api + "\n" + region
                    + "\nApple 查询失败：" + MembershipOfferingFailure.codes(error)
            }
            self.checkingPurchaseServices = false; self.purchaseDiagnosticsTask = nil
        }
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.purchaseDiagnosticsID == operation, self.checkingPurchaseServices else { return }
            self.purchaseDiagnosticsID = UUID()
            self.purchaseDiagnosticsTask?.cancel(); self.purchaseDiagnosticsTask = nil
            self.checkingPurchaseServices = false
            self.purchaseDiagnostics += "\n检查超过 30 秒，已停止等待；以上保留已完成步骤。"
        }
    }

    private static func checkOfferingAPI(key: String) async -> String {
        guard key.hasPrefix("appl_") else { return "RevenueCat：安装包未配置 Apple 公共 SDK Key。" }
        // A fixed diagnostic identifier avoids transmitting the signed-in user's ID.
        // 固定诊断地址，格式固定；异常时给出可读诊断而不是崩溃。
        guard let url = URLComponents(string: "https://api.revenuecat.com/v1/subscribers/boji-connectivity-check/offerings")?.url else {
            return "RevenueCat：诊断地址无效，请检查安装包配置。"
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return "RevenueCat：HTTP \(status)（不输出响应内容）" }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "RevenueCat：HTTP 200，响应格式无效。"
            }
            let current = json["current_offering_id"] as? String
            let offerings = json["offerings"] as? [[String: Any]] ?? []
            let selected = offerings.first { $0["identifier"] as? String == current }
            let ids = (selected?["packages"] as? [[String: Any]] ?? [])
                .compactMap { $0["platform_product_identifier"] as? String }.sorted()
            // Only known product IDs are included; no arbitrary backend text is shared.
            let known = ids.filter { ["yuefu", "nianfu", "yongjiu"].contains($0) }
            return "RevenueCat：HTTP 200，当前方案\(current == nil ? "不存在" : "存在")，\(ids.count) 个商品\n已识别 ID：\(known.joined(separator: ", "))"
        } catch { return "RevenueCat 连接失败：" + MembershipOfferingFailure.codes(error) }
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

    private func updateServerMembership() {
        expirationTask?.cancel(); expirationTask = nil
        guard accountID == accountService?.user?.id else { serverMembershipActive = false; return }
        let entitlement = accountService?.user?.membership
        #if DEBUG
        if isPreview {
            let scenario = ProcessInfo.processInfo.environment["BOJI_PREVIEW_MEMBERSHIP"]
            serverMembershipActive = entitlement?.active == true && scenario != "inactive" && scenario != "verifying"
            return
        }
        #endif
        serverMembershipActive = MembershipAccessPolicy.serverEntitlementValid(active: entitlement?.active == true,
            expiresAt: entitlement?.expiresAt, lifetime: entitlement?.lifetime)
        guard serverMembershipActive, entitlement?.lifetime != true,
              let end = MembershipAccessPolicy.expiration(entitlement?.expiresAt) else { return }
        let ticket = generation
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(min(86400, max(0, end.timeIntervalSinceNow)))) } catch { return }
            guard let self, self.generation == ticket else { return }
            self.updateServerMembership()
        }
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
        guard permitsPurchase(package),
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
        guard accountID != nil, !isPreview,
              storeMembershipActive || accountService?.user?.membership?.source == "apple" else { return }
        reconciliationError = nil; reconciliationTask?.cancel()
        let ticket = generation; let operation = UUID(); reconciliationID = operation
        reconciliationTask = Task { [weak self] in
            defer { if let self, self.reconciliationID == operation { self.reconciliationTask = nil } }
            let deadline = Date().addingTimeInterval(60)
            var lastError: String?
            for attempt in 0..<12 {
                guard let self, !Task.isCancelled, self.generation == ticket, Date() < deadline else { break }
                do {
                    guard let account = self.accountService else { return }
                    let verified = try await account.verifyMembership()
                    guard self.generation == ticket, !Task.isCancelled else { return }
                    self.updateServerMembership()
                    if verified && (self.serverMembershipActive || !self.storeMembershipActive) { return }
                } catch {
                    guard self.generation == ticket, !Task.isCancelled else { return }
                    lastError = AppErrorText.message(error)
                    if self.serverMembershipActive { return } // Retain previously verified paid access during an outage.
                }
                guard self.generation == ticket, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(attempt < 3 ? 2 : 5)) } catch { return }
            }
            guard let self, self.generation == ticket, !Task.isCancelled else { return }
            self.reconciliationError = self.storeMembershipActive
                ? "购买已完成，会员仍在核验。请勿重复付款，可稍后重新查询或联系客服。"
                : (lastError ?? "会员状态暂时未能核验，请稍后重新查询。")
        }
    }

    func refreshMembershipStatus() {
        guard !isBusy else { return }
        let ticket = generation
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            await self.accountService?.refreshAccount()
            self.isBusy = false
            self.synchronizeIdentityIfNeeded()
            guard self.generation == ticket else { return }
            self.updateServerMembership()
            self.refresh(force: true)
        }
    }

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

/// Never include localized descriptions/userInfo: SDK errors may contain URLs,
/// user identifiers or credentials. Support gets bounded domain/code chains only.
enum MembershipOfferingFailure {
    static func codes(_ error: Error) -> String {
        var current: NSError? = error as NSError
        var result: [String] = []
        for _ in 0..<4 {
            guard let value = current else { break }
            let allowed = value.domain.range(of: "^[A-Za-z0-9._-]{1,120}$", options: .regularExpression) != nil
            result.append("\(allowed ? value.domain : "Error")/\(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result.joined(separator: " → ")
    }

    static func message(_ error: Error) -> String {
        let value = error as NSError
        if value.domain == ErrorCode.errorDomain {
            switch ErrorCode(rawValue: value.code) {
            case .configurationError, .productNotAvailableForPurchaseError:
                return "商店商品暂时未能取得，请稍后重试；若持续出现，请联系开发者检查商品配置。"
            case .invalidCredentialsError, .invalidAppleSubscriptionKeyError:
                return "会员服务验证未通过，请联系开发者检查支付配置。"
            case .networkError, .offlineConnectionError, .apiEndpointBlockedError:
                return "暂时无法连接会员服务，请切换网络后重试。"
            case .productRequestTimedOut:
                return "Apple 商店响应超时，请稍后重试。"
            case .storeProblemError:
                return "Apple 商店暂时无法返回商品，请稍后重试。"
            default: break
            }
        }
        if value.domain == NSURLErrorDomain { return "暂时无法连接会员服务，请切换网络后重试。" }
        return "会员方案加载失败，请稍后重试；若持续出现，请联系开发者。"
    }
}
