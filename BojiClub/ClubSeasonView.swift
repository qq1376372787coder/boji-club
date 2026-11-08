import SwiftUI
import SceneKit
import UIKit
import ImageIO
import CryptoKit

struct ClubSeasonView: View {
    @EnvironmentObject private var service: ClubSeasonService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingRules = false
    @State private var selectedReward: ClubSeasonReward?
    @State private var badgeReward: ClubSeasonReward?
    @State private var observedOwner: Int?
    @State private var observedSeason: Int?
    @State private var observedKeepsakes: Set<Int> = []
    @State private var unlockFeedback = 0
    private var unlockedKeepsakes: Set<Int> {
        Set((service.envelope?.rewards ?? []).filter { $0.unlocked && $0.type != "physical" }.map(\.id))
    }
    private var rewardSignature: String {
        "\(account.user?.id ?? 0):\(service.envelope?.season?.id ?? 0):\(unlockedKeepsakes.sorted())"
    }

    var body: some View {
        ZStack {
            ClubBackground()
            Group {
                if let season = service.envelope?.season {
                    seasonContent(season).clubReveal()
                } else if service.loading {
                    ClubLoadingSkeleton(title: "正在进入俱乐部…", rows: 3).padding(ClubUI.pageInset).frame(maxWidth: 600)
                } else if service.envelope == nil {
                    ContentUnavailableView {
                        Label("俱乐部暂时没有加载出来", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("请检查网络后重试，已有记录会继续保留。")
                    } actions: {
                        Button("重新加载") { Task { await store.syncNow(); await service.refresh(account: account) } }.buttonStyle(SecondaryButton())
                    }
                } else {
                    ContentUnavailableView("成长季正在准备", systemImage: "seal", description: Text("新一期活动还未开放，稍后可在这里查看。"))
                }
            }
        }
        .navigationTitle("俱乐部")
        .navigationBarTitleDisplayMode(.inline)
        .clubSuccessFeedback("新的 俱乐部奖励 已解锁", trigger: unlockFeedback)
        .sensoryFeedback(.success, trigger: unlockFeedback)
        .onChange(of: rewardSignature, initial: true) { _, _ in
            guard let owner = account.user?.id, let season = service.envelope?.season?.id else {
                observedOwner = nil; observedSeason = nil; observedKeepsakes = []
                return
            }
            let current = unlockedKeepsakes
            if observedOwner == owner && observedSeason == season,
               !current.subtracting(observedKeepsakes).isEmpty { unlockFeedback &+= 1 }
            // Initial load / account switch only establishes a baseline, never celebrates old rewards.
            observedOwner = owner; observedSeason = season; observedKeepsakes = current
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: ClubKeepsakeVaultView(embedded: true).clubPushDestination132()) {
                    HStack(spacing: BojiLayout.tight) {
                        Image(systemName: "seal.fill").bojiType(.caption)
                        Text("收藏").bojiType(.caption)
                    }
                    .foregroundStyle(BojiColor.textPrimary)
                    .padding(.horizontal, BojiSpace.general).padding(.vertical, BojiSpace.tight)
                    .background(BojiColor.subtleSurface, in: Capsule())
                    .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                BojiToolbarCapsuleButton(title: "规则", systemImage: "doc.text") {
                    showingRules = true
                }
                .disabled(service.envelope?.season == nil)
            }
        }
        .task { await store.syncNow(); await service.refresh(account: account) }
        .onChange(of: store.syncStatus) { _, status in
            if case .synced = status { Task { await service.refreshAfterSync(account: account) } }
        }
        .refreshable { await store.syncNow(); await service.refresh(account: account) }
        .sheet(isPresented: $showingRules) { rulesSheet }
        .sheet(item: $selectedReward) { reward in RewardClaimView(reward: reward) }
        .sheet(item: $badgeReward) { reward in ClubKeepsakeDetailView(title: reward.title, detail: reward.detail, icon: reward.icon, rewardType: reward.type, rewardID: reward.id, imagePath: reward.imagePath, revision: reward.artworkRevision, canShare: reward.unlocked) }
        .alert("俱乐部通知", isPresented: Binding(get: { service.notice != nil }, set: { if !$0 { service.notice = nil } })) {
            Button("知道了") { service.notice = nil }
        } message: { Text(service.notice ?? "") }
    }

    private func seasonContent(_ season: ClubSeason) -> some View {
        ScrollView {
            VStack(spacing: BojiLayout.cardInset) {
                VStack(alignment: .leading, spacing: 0) {
                    seasonHero(season)
                    if service.envelope?.joined == true { progressCard.padding(.top, BojiSpace.workoutCardInset) }
                }
                if service.loading { ClubLoadingCard(title: "正在更新成长季…").padding(.horizontal, ClubUI.pageInset) }
                if service.envelope?.joined == true {
                    taskRoute
                    finalRewards
                    DisclosureGroup("官方来信与公告") { officialCard(season).padding(.top, BojiSpace.general) }
                        .bojiType(.secondary).tint(ClubBrand.accent)
                } else {
                    invitationCard(season)
                    DisclosureGroup("官方来信与公告") { officialCard(season).padding(.top, BojiSpace.general) }
                        .bojiType(.secondary).tint(ClubBrand.accent)
                }
            }
            .padding(.horizontal, ClubUI.pageInset)
            .padding(.bottom, BojiLayout.Rhythm.footerClearance)
        }
    }

    private func seasonHero(_ season: ClubSeason) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
            HStack {
                BojiBrandSignature(size:22,style:.onDark,title:"薄肌俱乐部 / MONTHLY",font:.caption2.weight(.semibold))
                Spacer()
                Image(systemName: "seal.fill").bojiType(.section).foregroundStyle(.white)
            }
            Capsule().fill(ClubBrand.accent).frame(width: 48, height: 4)
            Text(season.title).bojiType(.display).foregroundStyle(.white)
            Text(season.subtitle).bojiType(.secondary).foregroundStyle(.white.opacity(0.72)) // lint-ignore: dark-surface-alpha（深色表面对白有意透明度）
            HStack {
                Label(dateRange(season), systemImage: "calendar")
                Spacer()
                Text(service.envelope?.joined == true ? "已加入" : "会员权益包含")
            }
            .bojiType(.caption).foregroundStyle(.white.opacity(0.8))
        }
        .padding(BojiSpace.showcase)
        .background(BojiColor.coverSurface, in: RoundedRectangle(cornerRadius: BojiRadius.cover, style: .continuous))
        .bojiSpecularBorder(cornerRadius: BojiRadius.cover)
        .overlay {
            RoundedRectangle(cornerRadius: BojiRadius.cover, style: .continuous)
                .stroke(BojiColor.outline, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .clipped()
    }

    private var progressCard: some View {
        let tasks = service.envelope?.tasks ?? []
        let done = tasks.filter(\.completed).count
        let progress = tasks.isEmpty ? 0 : Double(done) / Double(tasks.count)
        return VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack(alignment: .firstTextBaseline) {
                Text("本月进度").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                Spacer()
                Text("\(done) / \(tasks.count)").bojiFont(.cardTitle, monospacedDigits: true)
                    .foregroundStyle(BojiColor.textPrimary)
            }
            ProgressView(value: progress).tint(ClubBrand.accent).scaleEffect(x: 1, y: 1.8).clubMotion(value: done)
        }
        .clubSeasonCard()
    }

    private var taskRoute: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            SectionTitle(title: "成长路线 · 每一站都有纪念", symbol: "point.topleft.down.curvedto.point.bottomright.up")
            ForEach(Array((service.envelope?.tasks ?? []).enumerated()), id: \.element.id) { index, task in
                VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                    HStack(alignment: .top, spacing: BojiLayout.rowGap) {
                        ZStack {
                            Circle().fill(task.completed ? ClubBrand.accent : BojiColor.inputSurface)
                            if task.completed { Image(systemName: "checkmark").bojiType(.section).foregroundStyle(ClubBrand.onAccent) }
                            else { Text("\(index + 1)").bojiFont(.setNumber).foregroundStyle(BojiColor.textPrimary) }
                        }.frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text(task.title).bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
                            Text(task.detail).bojiType(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text("\(task.current)/\(task.target)").bojiType(.caption)
                    }
                    ProgressView(value: Double(task.current), total: Double(max(1, task.target))).tint(ClubBrand.accent)
                        .animation(reduceMotion ? nil : BojiMotion2.celebrate, value: task.current)
                    let linked = ClubRewardGrouping.taskRewards(service.envelope?.rewards ?? [], taskID: task.id)
                    if linked.isEmpty {
                        Text("完成任务，推进本期成长进度").bojiType(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(linked) { reward in rewardRow(reward) }
                    }
                }
                .padding(.vertical, BojiSpace.workoutCardInset)
                if index < (service.envelope?.tasks?.count ?? 0) - 1 { Divider().overlay(BojiColor.divider) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BojiLayout.tight)
    }

    @ViewBuilder private var finalRewards: some View {
        let tasks = Set((service.envelope?.tasks ?? []).map(\.id))
        let rewards = service.envelope?.rewards ?? []
        let finale = ClubRewardGrouping.finale(rewards)
        let unlinked = ClubRewardGrouping.unlinked(rewards, taskIDs: tasks)
        if !finale.isEmpty {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                SectionTitle(title: "终点奖励", symbol: "flag.checkered")
                Text("完成本期全部任务后解锁实物奖励。本期实物限领一件，提交收货信息后由官方核验。").bojiType(.caption).foregroundStyle(.secondary)
                ForEach(finale) { reward in rewardRow(reward) }
            }.clubSeasonCard()
        }
        if !unlinked.isEmpty {
            VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
                SectionTitle(title: "其他本期奖励", symbol: "seal")
                ForEach(unlinked) { reward in rewardRow(reward) }
            }.clubSeasonCard()
        }
    }

    private func rewardRow(_ reward: ClubSeasonReward) -> some View {
        HStack(alignment: .center, spacing: BojiLayout.rowGap) {
            Button { badgeReward = reward } label: {
                HStack(spacing: BojiLayout.rowGap) {
                    ClubRewardArtwork(rewardID: reward.id, imagePath: reward.imagePath, icon: rewardSymbol(reward), revision: reward.artworkRevision)
                        .frame(width: 66, height: 66)
                        .opacity(reward.unlocked ? 1 : 0.65)
                    VStack(alignment: .leading, spacing: BojiLayout.tight) {
                        Text(reward.title).bojiType(.secondary)
                        Text(rewardStatus(reward)).bojiType(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if reward.type == "physical", let deadline = reward.claimDeadline { Text("申领截至 \(deadline)").bojiType(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(ClubMotionButton())
            if reward.canClaim {
                Button("申领") { selectedReward = reward }.buttonStyle(PrimaryButton()).tint(ClubBrand.accent).disabled(service.loading)
            } else {
                Image(systemName: reward.unlocked ? "checkmark.seal.fill" : "lock.fill").foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .contain)
    }

    private func invitationCard(_ season: ClubSeason) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
            Text("本期成长季").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
            Text("加入后，保存并同步的记录会更新任务进度。完成对应任务，可获得本期 俱乐部奖励。")
                .bojiType(.secondary).foregroundStyle(.secondary).lineSpacing(4)
            HStack { Label("已有 \(service.envelope?.memberCount ?? 0) 位成员加入", systemImage: "person.2.fill"); Spacer() }.bojiType(.caption).foregroundStyle(.secondary)
            Button { Task { await service.join(account: account) } } label: {
                if service.loading { HStack { ClubActivityMark(size: 18, tint: .white); Text("正在加入…") } } else { Text("加入本月成长季") }
            }
            .buttonStyle(PrimaryButton()).disabled(service.loading)
            Text("点击加入即表示你已阅读本期规则。成长季已包含在薄肌俱乐部会员中，不再单独收费。")
                .bojiType(.caption).foregroundStyle(.tertiary)
        }
        .clubSeasonCard()
    }

    private func officialCard(_ season: ClubSeason) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack { Image(systemName: "quote.opening"); Text("官方来信").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary); Spacer(); Text("薄肌俱乐部").bojiType(.caption).foregroundStyle(.secondary) }
            Text(season.officialNote).bojiType(.secondary).lineSpacing(5)
            ForEach(service.envelope?.announcements ?? []) { update in
                Divider()
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(update.title).bojiType(.secondary)
                    Text(update.body).bojiType(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(String(update.publishedAt.prefix(10))).bojiType(.caption).foregroundStyle(.tertiary)
                }
            }
            Divider()
            Text("奖励与本期任务有关，无需邀请好友、分享或评价 App。")
                .bojiType(.caption).foregroundStyle(.secondary)
        }
        .clubSeasonCard()
    }

    private var rulesSheet: some View {
        NavigationStack {
            ScrollView { Text(service.envelope?.season?.rules ?? "").bojiType(.body).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading).padding(ClubUI.pageInset) }
                .background { ClubBackground() }
                .navigationTitle("本期规则").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingRules = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func dateRange(_ season: ClubSeason) -> String { "\(season.startsOn.replacingOccurrences(of: "-", with: ".")) — \(season.endsOn.replacingOccurrences(of: "-", with: "."))" }
    private func rewardSymbol(_ reward: ClubSeasonReward) -> String {
        switch reward.icon { case "gift": return "gift.fill"; case "leaf": return "leaf.fill"; case "sparkles": return "sparkles"; default: return "seal.fill" }
    }
    private func rewardStatus(_ reward: ClubSeasonReward) -> String {
        if reward.type == "physical", reward.blockedByOtherClaim == true { return "本期已申领其他实物奖励" }
        if reward.claimStatus == "cancelled", reward.canClaim { return "申领已取消，可重新提交" }
        if let status = reward.claimStatus {
            let labels = ["pending":"已提交，等待人工核验", "confirmed":"已确认，等待打包", "packing":"正在打包", "shipped":"已发货", "delivered":"已送达", "problem":"需要联系官方", "cancelled":"申领已取消"]
            if status == "shipped", let company = reward.trackingCompany, let number = reward.trackingNumber { return "已发货 · \(company) \(number)" }
            return labels[status] ?? "处理中"
        }
        if reward.type == "physical", reward.blockedByOtherClaim == true { return "本期已申领其他实物奖励" }
        if reward.type == "physical", let deadline = reward.claimDeadline, ClubDates.key(Date()) > deadline { return "已超过申领截止日期" }
        if reward.unlocked { return reward.type == "physical" ? "已解锁，点击提交收货信息" : "已收入你的本期收藏" }
        return reward.detail
    }
}

private struct RewardClaimView: View {
    let reward: ClubSeasonReward
    @EnvironmentObject private var service: ClubSeasonService
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var draft = RewardClaimDraft()
    @State private var owner: Int?
    @State private var rewardImage: UIImage?
    @State private var showValidation = false
    @State private var submitting = false
    @State private var claimError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let rewardImage { Image(uiImage: rewardImage).resizable().scaledToFit().frame(maxHeight: 240) }
                    Text(reward.title).bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary)
                    Text(reward.detail).bojiType(.caption).foregroundStyle(.secondary)
                    if let deadline = reward.claimDeadline { Text("申领截止：\(deadline)").bojiType(.caption) }
                    Text("本期实物奖励限领一件，核验通过后安排发货。") .bojiType(.caption)
                }
                Section("收货信息") {
                    TextField("收件人", text: $draft.recipient)
                    TextField("手机号", text: $draft.phone).keyboardType(.phonePad)
                    TextField("省 / 市 / 区", text: $draft.region)
                    TextField("详细地址", text: $draft.address, axis: .vertical).lineLimit(2...4)
                    TextField("尺码或规格（没有可不填）", text: $draft.size)
                }
                Section { Text("收货信息仅用于本次奖励履约。提交后如需修改，请联系官方，避免包裹寄错。") }.bojiType(.caption).foregroundStyle(.secondary)
                Section {
                    if showValidation && !validationIssues.isEmpty {
                        Text("请补充或检查：" + validationIssues.joined(separator: "、"))
                            .bojiType(.label).foregroundStyle(.red)
                    } else { Text("填写收件人、手机号和完整地址后即可提交。").bojiType(.label).foregroundStyle(.secondary) }
                    if let claimError { Text(claimError).bojiType(.label).foregroundStyle(.red) }
                }
                if submitting { Section { ClubLoadingCard(title: "正在提交申领信息…") } }
                else if service.loading { Section { ClubLoadingCard(title: "正在同步奖励状态…", detail: "同步完成后即可提交，收货信息会保留。") } }
            }.clubGroupedSurface()
            .disabled(submitting)
            .navigationTitle("申领奖励").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(submitting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submitClaim) {
                        HStack(spacing: BojiLayout.tight) { if submitting { ClubActivityMark(size: 16) }; Text(submitting ? "提交中…" : "提交") }
                    }.disabled(submitting || service.loading || owner == nil || owner != account.user?.id)
                }
            }
        }
        .onAppear { if owner == nil { owner = account.user?.id } }
        .onChange(of: account.user?.id) { _, _ in draft = RewardClaimDraft(); dismiss() }
        .task(id: account.user?.id) {
            rewardImage = nil
            guard reward.imagePath != nil, let id = account.user?.id, !account.isPreviewAccount else { return }
            guard let response = try? await account.cloudRequest(path: "/club/rewards/\(reward.id)/image", expectedUserID: id), response.statusCode == 200, account.user?.id == id, !Task.isCancelled else { return }
            if let revision = reward.artworkRevision, !revision.accepts(ClubArtworkChecksum.sha256(response.data), thumbnail:false) { return }
            let image = await ClubImage.preview(response.data,pixels:1200)
            guard account.user?.id == id, !Task.isCancelled else { return }
            rewardImage = image
        }
    }

    private var validationIssues: [String] {
        EntryValidation.reward(recipient: draft.recipient, phone: draft.phone, region: draft.region, address: draft.address)
    }
    private func submitClaim() {
        guard !submitting, !service.loading else { return }
        showValidation = true; claimError = nil
        guard validationIssues.isEmpty else {
            ClubAccessibility.announce("请检查收货信息：" + validationIssues.joined(separator: "、")); return
        }
        guard owner != nil, owner == account.user?.id else { claimError = "账号已切换，请重新打开申领。"; return }
        var submitted = draft
        submitted.recipient = draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted.phone = draft.phone.filter { !$0.isWhitespace }
        submitted.region = draft.region.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted.address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
        submitting = true
        Task {
            defer { submitting = false }
            if await service.claim(reward, draft: submitted, account: account) { dismiss() }
            else if owner == account.user?.id { claimError = service.notice ?? "提交未完成，收货信息仍保留，请重试。"; service.notice = nil }
        }
    }
}

private extension View {
    func clubSeasonCard() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous).stroke(ClubUI.border, lineWidth: 1).allowsHitTesting(false) }
    }
}


struct ClubKeepsakeDetailView: View {
    let title: String
    let detail: String
    let icon: String
    let rewardType: String
    var rewardID: Int? = nil
    var imagePath: String? = nil
    var revision: ClubArtworkRevision? = nil
    var canShare = false
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var shareArtwork: UIImage?
    @State private var shareDraft: ShareDraft?
    @State private var ownerID: Int?
    private var validOwner: Bool { ownerID != nil && ownerID == account.user?.id && !account.isPreviewAccount }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: BojiLayout.cardInset) {
                if let rewardID, imagePath != nil {
                    ClubRewardArtwork(rewardID: rewardID, imagePath: imagePath, icon: icon, revision: revision, maxPixelSize: 1200,
                        onArtworkChange: { image in shareArtwork = image }).frame(height: 330).padding(.top, BojiLayout.inline).clubReveal()
                } else {
                    ContentUnavailableView("暂无奖励图片", systemImage: "photo", description: Text("奖励名称、领取条件和状态以本期活动为准。")).frame(height: 260)
                }
                Text(title).bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    .clubReveal()
                Text(detail)
                    .bojiType(.secondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if imagePath == nil {
                    Text("官方尚未上传这项奖励的图片。").bojiType(.caption).foregroundStyle(.secondary)
                }
                if canShare {
                    Button {
                        guard validOwner, let shareArtwork else { return }
                        shareDraft = ShareDraft(card: ShareCardView(title: "俱乐部奖励",
                            headline: "\(title)\n\n\(detail)", stats: [], tagline: "每一次坚持，都有来处。",
                            artwork: shareArtwork, brandSymbol: rewardType == "physical" ? "gift.fill" : "seal.fill",
                            footerLabel: rewardType == "physical" ? "成长季 · 已解锁奖励" : "成长季 · 已获得纪念"), ownerID: ownerID)
                    } label: { Label("分享我的 俱乐部奖励", systemImage: "square.and.arrow.up") }
                        .buttonStyle(PrimaryButton()).tint(.primary)
                        .disabled(!validOwner || shareArtwork == nil)
                    if shareArtwork == nil {
                        Text("图片准备好后即可预览分享；没有图片时不会生成空白卡片。")
                            .bojiType(.caption).foregroundStyle(.secondary)
                    }
                }

            }
            }
            .padding(ClubUI.pageInset)
            .background { ClubBackground() }
            .navigationTitle(rewardType == "physical" ? "实物奖励" : "收藏徽章")
            .navigationBarTitleDisplayMode(.inline)
            .task { if ownerID == nil { ownerID = account.user?.id } }
            .sheet(item: $shareDraft) { ShareCardPreview(draft: $0) }
            .onChange(of: account.user?.id) { _, _ in shareArtwork = nil; shareDraft = nil; dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

@MainActor
private enum ClubArtworkCache {
    static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 100
        return cache
    }()
}

enum ClubArtworkChecksum {
    static func sha256(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
}

struct ClubRewardArtwork: View {
    let rewardID: Int
    let imagePath: String?
    let icon: String
    var revision: ClubArtworkRevision? = nil
    var maxPixelSize: Int = 240
    var onArtworkChange: ((UIImage?) -> Void)? = nil
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var service: ClubSeasonService
    @State private var artwork: UIImage?
    @State private var loading = false
    @State private var failed = false
    @State private var retry = 0
    @State private var handledRetry = 0
    @State private var showingOlderCache = false
    @State private var refreshedRevision: ClubArtworkRevision?
    @State private var refreshedIdentity = ""
    @State private var loadTicket = UUID()
    private var artworkIdentity: String { "\(account.user?.id ?? 0):\(rewardID):\(imagePath ?? ""):\(revision?.cacheIdentity ?? "legacy")" }
    private var currentRevision: ClubArtworkRevision? { refreshedIdentity == artworkIdentity ? refreshedRevision ?? revision : revision }
    private var keepsakeNumber: String? {
        guard maxPixelSize <= 300, let imagePath, imagePath.hasPrefix("club-keepsake-") else { return nil }
        let parts = imagePath.split(separator: "-")
        guard parts.count > 2, let number = Int(parts[2]), (1...30).contains(number) else { return nil }
        return String(format: "%02d", number)
    }
    var body: some View {
        Group {
            if let artwork { Image(uiImage: artwork).resizable().scaledToFit() }
            else if imagePath != nil {
                if loading { ClubCompactWait() }
                else if failed { Button { retry += 1 } label: { Label("重试图片", systemImage: "arrow.clockwise") }.buttonStyle(ClubIconButtonStyle()).bojiType(.caption) }
                else { Image(systemName: icon).bojiType(.section) }
            } else { Image(systemName: "photo").bojiType(.section).foregroundStyle(.secondary).accessibilityLabel("暂无奖励图片") }
        }
        .overlay(alignment: .bottomTrailing) {
            if let keepsakeNumber, artwork != nil {
                Text(keepsakeNumber).bojiType(.caption)
                    .foregroundStyle(BojiColor.textPrimary).padding(.horizontal, BojiLayout.tight).padding(.vertical, 0)
                    .background(BojiColor.cardSurface, in: Capsule()).accessibilityLabel("俱乐部奖励 第 \(keepsakeNumber) 枚")
            }
        }
        .overlay(alignment: .topLeading) {
            if showingOlderCache, artwork != nil {
                Button { retry += 1 } label: { Text(loading ? "更新图片中…" : "缓存图片 · 重试更新").bojiType(.caption).padding(BojiLayout.tight).clubGlassEffect(in: Capsule()) }.buttonStyle(ClubIconButtonStyle()).disabled(loading).tint(.primary)
            }
        }
        .onChange(of: artwork) { _, image in onArtworkChange?(image) }
        .task(id: "\(account.user?.id ?? 0)-\(rewardID)-\(imagePath ?? "")-\(currentRevision?.cacheIdentity ?? "legacy")-\(maxPixelSize)-\(retry)") {
            let ticket = UUID(); loadTicket = ticket
            artwork = nil; failed = false; loading = false; showingOlderCache = false
            guard let path = imagePath, let id = account.user?.id, !account.isPreviewAccount else { return }
            if retry > handledRetry {
                handledRetry = retry
                if let response = try? await account.cloudRequest(path:"/club/rewards/\(rewardID)/image-info",expectedUserID:id), response.statusCode == 200,
                   let latest = try? JSONDecoder().decode(ClubArtworkRevision.self,from:response.data), ClubArtworkRevision.validHash(latest.version) {
                    guard loadTicket == ticket, account.user?.id == id, !Task.isCancelled else { return }
                    refreshedIdentity = artworkIdentity; refreshedRevision = latest
                }
                guard loadTicket == ticket, account.user?.id == id, !Task.isCancelled else { return }
            }
            let revision = currentRevision
            let version = revision?.cacheIdentity ?? "legacy"
            let key = "\(id):\(rewardID):\(path):\(version):\(maxPixelSize)" as NSString
            if let cached = ClubArtworkCache.images.object(forKey: key) { artwork = cached; return }
            let diskName = revision == nil ? "artwork:\(rewardID):\(path):thumbnail-v1" : "artwork:\(rewardID):\(path):\(version):thumbnail-v2"
            let fallbackName = "artwork:\(rewardID):\(path):last-thumbnail-v2"
            if let data=await ClubDiskCache.shared.load(diskName,owner:id) {
                let cached=await ClubImage.preview(data,pixels:maxPixelSize)
                guard loadTicket == ticket, account.user?.id == id, !Task.isCancelled else { return }
                artwork=cached
                if maxPixelSize <= 300, let cached, let cg=cached.cgImage {
                    ClubArtworkCache.images.setObject(cached,forKey:key,cost:cg.bytesPerRow*cg.height);return
                }
            }
            if artwork == nil {
                let fallback = await ClubDiskCache.shared.load(fallbackName,owner:id)
                let legacy = fallback == nil ? await ClubDiskCache.shared.load("artwork:\(rewardID):\(path):thumbnail-v1",owner:id) : nil
                if let data = fallback ?? legacy {
                    let cached = await ClubImage.preview(data,pixels:maxPixelSize)
                    guard loadTicket == ticket, account.user?.id == id, !Task.isCancelled else { return }
                    artwork = cached; showingOlderCache = cached != nil
                }
            }
            loading = true
            defer { if loadTicket == ticket { loading = false } }
            do {
                var query = maxPixelSize <= 300 ? ["size=thumb"] : []
                if let revision {
                    guard ClubArtworkRevision.validHash(revision.version), let version = revision.version else { failed = artwork == nil; return }
                    query.append("version=" + version)
                }
                let endpoint = "/club/rewards/\(rewardID)/image" + (query.isEmpty ? "" : "?" + query.joined(separator:"&"))
                let response = try await account.cloudRequest(path: endpoint, expectedUserID: id)
                guard loadTicket == ticket, account.user?.id == id, !Task.isCancelled else { return }
                if response.statusCode == 409 { failed = artwork == nil; return }
                guard response.statusCode == 200 else { failed = artwork == nil; return }
                if let revision, !revision.accepts(ClubArtworkChecksum.sha256(response.data),thumbnail:maxPixelSize <= 300) { failed = artwork == nil; return }
                let value = await ClubImage.preview(response.data, pixels: maxPixelSize)
                guard loadTicket == ticket, account.user?.id == id, !Task.isCancelled else { return }
                guard let value else { failed = artwork == nil; return }
                artwork = value; failed = false; showingOlderCache = false
                if let cg = value.cgImage {
                    ClubArtworkCache.images.setObject(value, forKey: key, cost: cg.bytesPerRow * cg.height)
                    let small=await ClubImage.preview(response.data,pixels:300)
                    guard loadTicket == ticket, account.user?.id == id, !Task.isCancelled else { return }
                    if let bytes=small?.pngData() {
                        let retained=service.collection.contains(where:{$0.id == rewardID}) || service.envelope?.rewards?.contains(where:{$0.id == rewardID && $0.unlocked}) == true
                        await ClubDiskCache.shared.save(bytes,name:diskName,owner:id,retained:retained)
                        guard loadTicket == ticket, account.user?.id == id, !Task.isCancelled else { return }
                        await ClubDiskCache.shared.save(bytes,name:fallbackName,owner:id,retained:retained)
                    }
                }
            } catch is CancellationError { }
            catch { if loadTicket == ticket && !Task.isCancelled { failed = artwork == nil } }
        }
    }
}

struct ClubHistoryView: View {
    @EnvironmentObject private var service: ClubSeasonService
    @EnvironmentObject private var account: AccountService
    @State private var selectedReward: ClubSeasonReward?
    @State private var detailReward: ClubSeasonReward?
    @State private var pendingAction: ClubSeasonReward?
    @State private var action = ""
    @State private var loading = true
    var body: some View {
        List {
            if loading && service.history.isEmpty { ClubLoadingSkeleton(title: "正在加载历史…", rows: 2) }
            else if service.history.isEmpty { Text(service.notice ?? "参加过的成长季和奖励会保留在这里。").foregroundStyle(.secondary) }
            ForEach(service.history, id: \.season?.id) { entry in
                if let season = entry.season {
                    Section {
                        Text("\(season.startsOn) 至 \(season.endsOn)").bojiType(.caption).foregroundStyle(.secondary)
                        ForEach(entry.rewards ?? []) { reward in
                            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                                Button { detailReward = reward } label: {
                                    HStack {
                                        ClubRewardArtwork(rewardID: reward.id, imagePath: reward.imagePath, icon: reward.type == "physical" ? "gift.fill" : "seal.fill", revision: reward.artworkRevision).frame(width: 54, height: 54)
                                        VStack(alignment: .leading, spacing: BojiLayout.tight) { Text(reward.title).bojiFont(.exerciseName).foregroundStyle(BojiColor.textPrimary); Text(status(reward)).bojiType(.caption).foregroundStyle(.secondary) }
                                    }
                                }.buttonStyle(ClubMotionButton())
                                if let company = reward.trackingCompany, let number = reward.trackingNumber, !number.isEmpty {
                                    Text("物流：\(company) \(number)").bojiType(.caption).textSelection(.enabled)
                                }
                                if reward.canClaim {
                                    Button("申领奖励") { selectedReward = reward }.buttonStyle(ClubActionButtonStyle(kind: .row)).disabled(service.loading)
                                }
                                if let claim = reward.claimStatus, ["pending", "confirmed", "packing", "problem"].contains(claim), reward.shippedAt == nil, (reward.trackingNumber ?? "").isEmpty {
                                    Button("取消本次申领", role: .destructive) { action = "cancel"; pendingAction = reward }.buttonStyle(ClubActionButtonStyle(kind: .row)).disabled(service.loading)
                                }
                                if reward.shippedAt != nil, ["shipped", "problem"].contains(reward.claimStatus ?? "") {
                                    Button("我已收到奖品") { action = "received"; pendingAction = reward }.buttonStyle(ClubActionButtonStyle(kind: .row)).disabled(service.loading)
                                }
                            }.padding(.vertical, BojiLayout.tight)
                        }
                        DisclosureGroup("本期规则") { Text(season.rules).bojiType(.caption) }
                    } header: { Text(season.title) }
                }
            }
        }.clubListSurface()
        .navigationTitle("成长季与奖品记录").navigationBarTitleDisplayMode(.inline)
        .task(id: account.user?.id) { loading = true; await service.refreshHistory(account: account); loading = false }
        .onChange(of: account.user?.id) { _, _ in selectedReward = nil; detailReward = nil; pendingAction = nil }
        .refreshable { await service.refreshHistory(account: account) }
        .sheet(item: $selectedReward) { reward in RewardClaimView(reward: reward) }
        .sheet(item: $detailReward) { reward in ClubKeepsakeDetailView(title: reward.title, detail: reward.detail, icon: reward.icon, rewardType: reward.type, rewardID: reward.id, imagePath: reward.imagePath, revision: reward.artworkRevision, canShare: reward.unlocked) }
        .confirmationDialog(action == "cancel" ? "确认取消申领？" : "确认已收到奖品？", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button(action == "cancel" ? "确认取消" : "确认收货", role: action == "cancel" ? .destructive : nil) {
                if let reward = pendingAction { let chosen = action; let owner = account.user?.id; Task { guard owner != nil, account.user?.id == owner else { return }; await service.updateClaim(reward, action: chosen, account: account) } }
                pendingAction = nil
            }
        }
        .alert("奖品通知", isPresented: Binding(get: { service.notice != nil }, set: { if !$0 { service.notice = nil } })) { Button("知道了") { service.notice = nil } } message: { Text(service.notice ?? "") }
    }
    private func status(_ reward: ClubSeasonReward) -> String {
        if let claim = reward.claimStatus { return ["pending":"等待确认", "confirmed":"等待打包", "packing":"正在打包", "shipped":"已发货", "delivered":"已收货", "problem":"需要联系官方处理", "cancelled":"申领已取消"][claim] ?? "处理中" }
        if reward.canClaim { return "已解锁 · 申领截止 \(reward.claimDeadline ?? "")" }
        if reward.type == "physical", reward.unlocked {
            if reward.blockedByOtherClaim == true { return "本期已申领其他实物" }
            if let deadline = reward.claimDeadline, deadline < ClubDates.key(Date()) { return "已超过申领期限" }
            return "暂时无法申领，请查看活动规则"
        }
        return reward.unlocked ? "已收入收藏" : "本期未解锁"
    }
}

#if DEBUG
enum SeasonAuditFactory {
 @ViewBuilder static func claim() -> some View {
     if let reward = ClubSeasonEnvelope.debugPreview(joined: true).rewards?.last {
         RewardClaimView(reward: reward)
     } else {
         EmptyView()
     }
 }
}
#endif
