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
    @Environment(\.clubPushed132) private var pushed132
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var membership: MembershipService
    @State private var showingPurchaseDiagnostics = false
    @State private var showingPaywall = false
    @State private var showingCustomerCenter = false
    @State private var legalDocument: LegalDocument?
    @State private var selectedPlan: MembershipPlan = .annual
    @State private var previewNotice = false
    @State private var confirmingUpgrade = false
    #if DEBUG
    @State private var showingPricePreview = false
    #endif

    var body: some View {
        ClubNavigationStack132 {
            Group {
                if membership.storeMembershipActive && !isPricePreview {
                    List {
                        if isMandatory { Section { requiredAccessNotice } }
                        statusCard
                        actionsCard
                        if !isMandatory && membership.canUpgradeToLifetime {
                            NavigationLink("查看永久会员") {
                                ScrollView { lifetimeUpgradeCard; legalFooter }.padding().navigationTitle("永久会员")
                            }
                        }
                        if let message = membership.notice { Text(message).bojiType(.label).foregroundStyle(.secondary) }
                        Section { legalFooter }
                    }.clubManagementList132()
                } else {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                    requiredAccessNotice
                    header
                    if membership.isTestStore && !isPricePreview {
                        Label("当前为测试购买，不会扣款。", systemImage: "testtube.2")
                            .bojiType(.secondary).foregroundStyle(.secondary)
                    }
                    if !isPricePreview { statusCard }
                    if isPricePreview || !membership.storeMembershipActive { plansCard }
                    else if membership.canUpgradeToLifetime { lifetimeUpgradeCard }
                    if !isPricePreview { actionsCard }
                    if let message = membership.notice, !isPricePreview {
                        Text(message).bojiType(.secondary).foregroundStyle(.secondary)
                            .accessibilityLabel(message)
                    }
                    legalFooter
                    if isPricePreview {
                        Text("开发预览 · 展示拟定价格，不会发起购买。连接商店后请重新核对并截取实际页面。")
                            .bojiType(.label).foregroundStyle(.secondary)
                    }
                }.padding(ClubUI.pageInset)
            }
                }
            }
            .background { ClubBackground() }
            .navigationTitle("俱乐部会员").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isMandatory && !pushed132 { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
                #if DEBUG
                if !isPricePreview && !isMandatory { ToolbarItem(placement: .topBarLeading) { Button("价格预览") { showingPricePreview = true } } }
                #endif
            }
            #if DEBUG
            .sheet(isPresented: $showingPricePreview) { MembershipView(screenshotPreview: true) }
            #endif
            .sheet(isPresented: $showingPurchaseDiagnostics) {
                MembershipPurchaseDiagnosticsView()
            }
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
                showingPaywall = false; showingCustomerCenter = false; confirmingUpgrade = false
            }
            .alert("会员价格页面预览", isPresented: $previewNotice) {
                Button("知道了", role: .cancel) { }
            } message: { Text("这是开发预览，不会扣款或开通会员。实际购买需要连接 Apple 商品与 RevenueCat。") }
            .confirmationDialog("升级永久会员前，请确认", isPresented: $confirmingUpgrade, titleVisibility: .visible) {
                Button("确认购买永久会员") { membership.purchase(.lifetime) }
                Button("暂不升级", role: .cancel) { }
            } message: {
                Text("永久会员是另一次购买，不抵扣已支付订阅费用，也不会自动取消月费或年费。购买后请到 Apple 订阅设置关闭原订阅，避免继续续费。实际价格以购买窗口为准。")
            }
            .task { if !isPricePreview { membership.refresh(force: true) } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("恢复购买") { membership.restorePurchases() }
                        .bojiType(.secondary)
                        .disabled(!membership.canUseStore)
                }
            }
        }
    }

    @ViewBuilder private var requiredAccessNotice: some View {
        if isMandatory {
            Text(membership.isVerifyingMembership ? "购买已完成，正在核验会员。请勿重复付款。" : "资料已保存，会员生效后即可进入 App。")
                .bojiType(.label).foregroundStyle(.secondary)
                .accessibilityIdentifier("membership-required-page")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            BojiBrandSignature(size:28)
            Text("薄肌俱乐部 Pro").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
            Text("训练计划、饮食记录与每周总结。")
                .bojiType(.secondary).foregroundStyle(.secondary)
            HStack(spacing: BojiLayout.inline) {
                Button("使用条款 (EULA)") { legalDocument = .terms }
                Text("·").foregroundStyle(BojiColor.textTertiary)
                Button("隐私政策") { legalDocument = .privacy }
                Text("·").foregroundStyle(BojiColor.textTertiary)
                Button("恢复购买") { membership.restorePurchases() }.disabled(!membership.canUseStore)
            }
            .bojiType(.caption)
            .foregroundStyle(BojiColor.textSecondary)
            .padding(.top, 0)
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch membership.state {
        case .active(let expiration):
            ClubCard {
                Label("会员购买已确认", systemImage: "checkmark.seal.fill").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                if let expiration {
                    Text("有效至 \(expiration.formatted(date: .abbreviated, time: .omitted))").bojiType(.secondary)
                    if let entitlement = membership.customerInfo?.entitlements.all[membership.entitlementID], !entitlement.willRenew {
                        Text("已关闭自动续订；到期前仍可使用。").bojiType(.label).foregroundStyle(.secondary)
                    }
                } else {
                    Text(membership.lifetimeOwned ? "永久会员 · 一次购买，不自动续订" : "当前账号会员权益")
                        .bojiType(.secondary)
                }
                if !membership.serverMembershipActive {
                    Text(membership.reconciliationError ?? "正在同步会员…请勿重复购买。")
                        .bojiType(.secondary).foregroundStyle(.secondary)
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
                Text(message).bojiType(.secondary)
                Button("重新连接") { membership.refreshMembershipStatus() }.buttonStyle(SecondaryButton())
            }
        case .inactive:
            if membership.serverMembershipActive {
                ClubCard {
                    Label("俱乐部会员已生效", systemImage: "checkmark.seal.fill").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("当前权益由俱乐部账号提供，可在这里购买或管理商店会员。")
                        .bojiType(.secondary).foregroundStyle(.secondary)
                }
            } else {
                ClubCard {
                    Label("当前没有生效的会员", systemImage: "seal").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("可以选择下方方案开通，或恢复已有购买。")
                        .bojiType(.secondary).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var lifetimeUpgradeCard: some View {
        ClubCard {
            Text("升级永久会员").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("永久会员 · " + displayPrice(for: .lifetime)).bojiType(.secondary)
            Text("已支付的订阅费用不会抵扣。升级不会自动取消原订阅，请到 Apple 订阅设置关闭自动续费。").bojiType(.secondary).foregroundStyle(.secondary)
            Button("升级永久会员") { confirmingUpgrade = true }.buttonStyle(PrimaryButton())
                .disabled(!membership.canUseStore || membership.package(for: .lifetime) == nil)
            if let message = membership.offeringsError {
                Text(message).bojiType(.label).foregroundStyle(.secondary)
                Button("重新加载价格") { membership.loadOfferings() }.buttonStyle(SecondaryButton())
            }
        }
    }

    private var plansCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                Label("专属训练计划与逐组记录", systemImage: "checkmark.circle.fill")
                Label("拍照、语音饮食登记", systemImage: "checkmark.circle.fill")
                Label("日报与每周回顾", systemImage: "checkmark.circle.fill")
                Label("云端同步与成长记录", systemImage: "checkmark.circle.fill")
            }.bojiType(.secondary)
            Divider().padding(.vertical, BojiLayout.tight)
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
            Text(selectedPlan.detail)
                .bojiType(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
            if let message = membership.offeringsError, !isPricePreview {
                Text(message).bojiType(.secondary).foregroundStyle(.secondary)
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
            if membership.supportsPurchaseDiagnostics {
                Button("检查购买服务（内测）") { showingPurchaseDiagnostics = true }
                    .buttonStyle(SecondaryButton()).disabled(membership.isBusy)
            }
            Text("换手机或重装后，请登录原俱乐部账号，再恢复购买。恢复成功也需要核对会员是否仍有效。")
                .bojiType(.label).foregroundStyle(.secondary)
        }
    }

    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            Text("月度和年度会员自动续订，可在 Apple 订阅设置中取消。永久会员为一次性购买，不自动续订。实际价格以购买窗口为准。购买永久会员不会自动取消已有订阅。")
                .bojiType(.label).foregroundStyle(.secondary)
            HStack(spacing: BojiLayout.cardInset) {
                Button("隐私政策") { legalDocument = .privacy }
                Button("使用条款") { legalDocument = .terms }
                Button("购买与退款") { legalDocument = .purchase }
            }.bojiType(.label)
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
            HStack(spacing: BojiLayout.rowGap) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .bojiType(.section)
                    .foregroundStyle(selected ? ClubBrand.accent : BojiColor.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    HStack(spacing: BojiLayout.tight) {
                        Text(plan.title).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        if plan == .annual {
                            Text("推荐")
                                .bojiType(.caption)
                                .foregroundStyle(ClubBrand.accent)
                                .padding(.horizontal, BojiLayout.tight).padding(.vertical, 0)
                                .background(BojiColor.brandMist, in: Capsule())
                        }
                    }
                    Text(plan.detail).bojiType(.label).foregroundStyle(BojiColor.textSecondary)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(price).bojiFont(.cardTitle, monospacedDigits: true).foregroundStyle(BojiColor.textPrimary)
                    Text(unit).bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                }
            }
            .padding(BojiSpace.workoutCardInset).frame(maxWidth: .infinity, alignment: .leading)
            // 2026-11-08 Chief 拍板：价格卡改不透明 cardSurface，废止「拍板 #6」玻璃豁免
            .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: selected ? 18 : 0, y: selected ? 5 : 0)
            .overlay {
                RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous)
                    .stroke(selected ? ClubBrand.accent : BojiColor.outline, lineWidth: selected ? 1.5 : 0.5)
            }
        }
        .buttonStyle(ClubMotionButton())
        .accessibilityLabel("\(plan.title)，\(price)，\(plan.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(reduceMotion ? nil : BojiMotion2.state, value: selected)
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

private struct MembershipPurchaseDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var membership: MembershipService
    var body: some View {
        ClubNavigationStack132 {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                    Text("读取会员方案和 Apple 商品资料，不会发起购买。检查结果仅显示在本机，可自行分享给开发者。")
                        .bojiType(.secondary).foregroundStyle(.secondary)
                    if membership.checkingPurchaseServices { ProgressView("正在检查…") }
                    Text(membership.purchaseDiagnostics)
                        .bojiType(.label).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("重新检查") { membership.checkPurchaseServices() }
                        .buttonStyle(SecondaryButton())
                        .disabled(membership.checkingPurchaseServices || membership.isBusy)
                    ShareLink(item: membership.purchaseDiagnostics) { Label("分享检查结果", systemImage: "square.and.arrow.up") }
                        .disabled(membership.checkingPurchaseServices)
                }.padding(ClubUI.pageInset)
            }
            .background { ClubBackground() }
            .navigationTitle("购买服务检查").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
            .task { membership.checkPurchaseServices() }
        }
    }
}
