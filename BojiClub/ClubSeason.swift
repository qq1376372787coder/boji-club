import Foundation
import Combine
import CryptoKit
import Security

actor ClubDiskCache {
    static let shared=ClubDiskCache()
    private var keys: [Int:SymmetricKey]=[:]
    private var erasedOwners: Set<Int>=[]
    private func folder(_ owner: Int) -> URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("BojiClub/keepsake-cache/user-\(owner)",isDirectory:true)
    }
    private func hash(_ value: String) -> String { SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined() }
    private func encryptionKey(_ owner: Int, create: Bool) throws -> SymmetricKey? {
        if let key=keys[owner] { return key }
        let query: [String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.bojiclub.keepsake-cache",kSecAttrAccount as String:String(owner)]
        var read=query;read[kSecReturnData as String]=true;read[kSecMatchLimit as String]=kSecMatchLimitOne
        var result: CFTypeRef?;let status=SecItemCopyMatching(read as CFDictionary,&result)
        if status == errSecSuccess, let data=result as? Data, data.count == 32 {
            let key=SymmetricKey(data:data);keys[owner]=key;return key
        }
        guard status == errSecItemNotFound else { throw AccountError.message("本机收藏缓存暂不可读取。") }
        guard create else { return nil }
        let key=SymmetricKey(size:.bits256)
        var item=query;item[kSecValueData as String]=key.withUnsafeBytes{Data($0)}
        item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw AccountError.message("本机收藏缓存暂不可保存。") }
        keys[owner]=key;return key
    }
    func load(_ name: String, owner: Int) -> Data? {
        guard !erasedOwners.contains(owner) else { return nil }
        do {
            guard let key=try encryptionKey(owner,create:false) else { return nil }
            for prefix in ["p-","n-"] {
                let file=folder(owner).appendingPathComponent(prefix+hash(name)+".bin")
                if let data=try? Data(contentsOf:file) {
                    let box=try AES.GCM.SealedBox(combined:data)
                    let value=try AES.GCM.open(box,using:key,authenticating:Data("\(owner):\(name)".utf8))
                    try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:file.path)
                    return value
                }
            }
        } catch { }
        return nil
    }
    func save(_ data: Data, name: String, owner: Int, retained: Bool = false) {
        guard !erasedOwners.contains(owner), data.count <= 4*1024*1024 else { return }
        do {
            guard let key=try encryptionKey(owner,create:true) else { return }
            var location=folder(owner)
            try FileManager.default.createDirectory(at:location,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
            var values=URLResourceValues();values.isExcludedFromBackup=true;try location.setResourceValues(values)
            let digest=hash(name)
            let pinned=location.appendingPathComponent("p-"+digest+".bin")
            let keep=retained || FileManager.default.fileExists(atPath:pinned.path)
            let file=location.appendingPathComponent((keep ? "p-" : "n-")+digest+".bin")
            guard let sealed=try AES.GCM.seal(data,using:key,authenticating:Data("\(owner):\(name)".utf8)).combined else { return }
            try sealed.write(to:file,options:[.atomic,.completeFileProtection])
            if keep { try? FileManager.default.removeItem(at:location.appendingPathComponent("n-"+digest+".bin")) }
            let files=try FileManager.default.contentsOfDirectory(at:location,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])
            let ordered=files.sorted {
                let left=$0.lastPathComponent.hasPrefix("p-");let right=$1.lastPathComponent.hasPrefix("p-")
                if left != right { return !left }
                return ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            var total=files.reduce(0){$0+((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
            for old in ordered where total > 64*1024*1024 && old != file {
                let size=(try? old.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
                try FileManager.default.removeItem(at:old);total-=size
            }
        } catch { }
    }
    func erase(_ owner: Int) -> Bool {
        erasedOwners.insert(owner)
        do {
            let location=folder(owner)
            if FileManager.default.fileExists(atPath:location.path) { try FileManager.default.removeItem(at:location) }
            let query: [String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.bojiclub.keepsake-cache",kSecAttrAccount as String:String(owner)]
            let status=SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { return false }
            keys.removeValue(forKey:owner);return true
        } catch { return false }
    }
}

struct ClubSeason: Decodable, Identifiable {
    let id: Int
    let slug: String
    let title: String
    let subtitle: String
    let officialNote: String
    let rules: String
    let startsOn: String
    let endsOn: String
    let joinDeadline: String
    let accessMode: String

    enum CodingKeys: String, CodingKey {
        case id, slug, title, subtitle, rules
        case officialNote = "official_note"
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case joinDeadline = "join_deadline"
        case accessMode = "access_mode"
    }
}

struct ClubSeasonTask: Decodable, Identifiable {
    let id: Int
    let title: String
    let detail: String
    let metric: String
    let target: Int
    let current: Int
    let completed: Bool
}

struct ClubSeasonReward: Decodable, Identifiable {
    let id: Int
    let title: String
    let detail: String
    let type: String
    let icon: String
    let unlocked: Bool
    let claimStatus: String?
    let trackingCompany: String?
    let trackingNumber: String?
    var taskID: Int? = nil
    var unlockScope: String? = nil
    var shippedAt: String? = nil
    var imagePath: String? = nil
    var imageVersion: String? = nil
    var imageSHA256: String? = nil
    var thumbnailSHA256: String? = nil
    var artworkRevision: ClubArtworkRevision? {
        guard imageVersion != nil || imageSHA256 != nil || thumbnailSHA256 != nil else { return nil }
        return ClubArtworkRevision(version:imageVersion,fullSHA256:imageSHA256,thumbnailSHA256:thumbnailSHA256)
    }
    var claimDeadline: String? = nil
    var maxPerUser: Int? = nil
    var blockedByOtherClaim: Bool? = nil
    var typeLabel: String {
        switch type { case "physical": return "实物纪念品"; case "title": return "成员称号"; default: return "电子徽章" }
    }
    var canClaim: Bool {
        type == "physical" && unlocked && blockedByOtherClaim != true && (claimStatus == nil || claimStatus == "cancelled") && (claimDeadline == nil || ClubDates.serverKey() <= claimDeadline!)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, detail, type, icon, unlocked
        case taskID = "task_id", unlockScope = "unlock_scope"
        case claimStatus = "claim_status"
        case trackingCompany = "tracking_company"
        case trackingNumber = "tracking_number"
        case shippedAt = "shipped_at"
        case blockedByOtherClaim = "blocked_by_other_claim"
        case imagePath = "image_path", claimDeadline = "claim_deadline", maxPerUser = "max_per_user"
        case imageVersion = "image_version", imageSHA256 = "image_sha256", thumbnailSHA256 = "thumbnail_sha256"
    }
}

struct ClubSeasonEnvelope: Decodable {
    let season: ClubSeason?
    let joined: Bool?
    let joinedAt: String?
    let tasks: [ClubSeasonTask]?
    let rewards: [ClubSeasonReward]?
    let announcements: [ClubAnnouncement]?
    let memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case season, joined, tasks, rewards, announcements
        case joinedAt = "joined_at"
        case memberCount = "member_count"
    }
}

enum ClubRewardGrouping {
    static func taskRewards(_ rewards: [ClubSeasonReward], taskID: Int) -> [ClubSeasonReward] {
        rewards.filter { $0.type != "physical" && $0.taskID == taskID && $0.unlockScope != "season" }
    }
    static func finale(_ rewards: [ClubSeasonReward]) -> [ClubSeasonReward] {
        rewards.filter { $0.type == "physical" || $0.unlockScope == "season" }
    }
    static func unlinked(_ rewards: [ClubSeasonReward], taskIDs: Set<Int>) -> [ClubSeasonReward] {
        rewards.filter { $0.type != "physical" && $0.unlockScope != "season" && ($0.taskID == nil || !taskIDs.contains($0.taskID ?? 0)) }
    }
}

struct ClubAnnouncement: Decodable, Identifiable {
    let id: Int
    let title: String
    let body: String
    let publishedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, body
        case publishedAt = "published_at"
    }
}

struct ClubCollectedReward: Decodable, Identifiable {
    let id: Int
    let title: String
    let icon: String
    let rewardType: String
    let seasonTitle: String
    let slug: String
    var detail: String? = nil
    var imagePath: String? = nil
    var imageVersion: String? = nil
    var imageSHA256: String? = nil
    var thumbnailSHA256: String? = nil
    var artworkRevision: ClubArtworkRevision? {
        guard imageVersion != nil || imageSHA256 != nil || thumbnailSHA256 != nil else { return nil }
        return ClubArtworkRevision(version:imageVersion,fullSHA256:imageSHA256,thumbnailSHA256:thumbnailSHA256)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, icon, slug, detail
        case rewardType = "reward_type"
        case seasonTitle = "season_title"
        case imagePath = "image_path"
        case imageVersion = "image_version", imageSHA256 = "image_sha256", thumbnailSHA256 = "thumbnail_sha256"
    }
}

private struct ClubHistoryEnvelope: Decodable { let items: [ClubSeasonEnvelope] }
private struct ClubCollectionEnvelope: Decodable { let items: [ClubCollectedReward] }

struct RewardClaimDraft {
    var recipient = ""
    var phone = ""
    var region = ""
    var address = ""
    var size = ""
}

@MainActor
final class ClubSeasonService: ObservableObject {
    @Published private(set) var envelope: ClubSeasonEnvelope?
    @Published private(set) var history: [ClubSeasonEnvelope] = []
    @Published private(set) var collection: [ClubCollectedReward] = []
    @Published private(set) var loading = false
    @Published var notice: String?

    private var accountID: Int?
    private var generation = UUID()
    private var fetchedCollection=false
    private var fetchedHistory=false
    private var lastProgressRefresh = Date.distantPast
    private var progressRefreshTask: Task<Void,Never>?
    private var pendingProgressRefresh = false

    func activate(_ id: Int?) {
        guard accountID != id else { return }
        clear()
        accountID = id
        fetchedCollection=false;fetchedHistory=false
        guard let id else { return }
        let ticket=generation
        Task {
            if let data=await ClubDiskCache.shared.load("collection",owner:id), let saved=try? JSONDecoder().decode(ClubCollectionEnvelope.self,from:data), generation == ticket, !fetchedCollection { collection=saved.items }
            if let data=await ClubDiskCache.shared.load("history",owner:id), let saved=try? JSONDecoder().decode(ClubHistoryEnvelope.self,from:data), generation == ticket, !fetchedHistory { history=saved.items }
        }
    }

    func clear() {
        progressRefreshTask?.cancel(); progressRefreshTask = nil; pendingProgressRefresh = false
        generation = UUID()
        envelope = nil; history = []; collection = []; loading = false; notice = nil
        lastProgressRefresh = .distantPast
    }

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

    func refresh(account: AccountService) async {
        activate(account.user?.id)
        guard let userID = account.user?.id, !loading else { return }
        if account.isPreviewAccount {
            #if DEBUG
            let auditJoined = ProcessInfo.processInfo.environment["BOJI_AUDIT_SCREEN"] != nil
            #else
            let auditJoined = false
            #endif
            envelope = .debugPreview(joined: envelope?.joined ?? auditJoined)
            return
        }
        let ticket = generation
        loading = true
        lastProgressRefresh = Date()
        defer { if generation == ticket { loading = false } }
        do {
            let value = try await request(account: account, userID: userID, path: "/club/current")
            guard generation == ticket else { return }
            envelope = value; notice = nil
        } catch is CancellationError { }
        catch { if generation == ticket { notice = "暂时无法刷新，保留上次加载的内容。" + AppErrorText.message(error) } }
    }

    func refreshCollection(account: AccountService) async {
        activate(account.user?.id)
        guard let userID = account.user?.id else { collection = []; return }
        if account.isPreviewAccount {
            collection = [ClubCollectedReward(id: -1, title: "First Light", icon: "sparkles", rewardType: "badge", seasonTitle: "十月成长季", slug: "debug-club-season")]
            return
        }
        let ticket = generation
        do {
            let response = try await account.cloudRequest(path: "/club/collection", expectedUserID: userID)
            guard generation == ticket else { return }
            guard response.statusCode == 200 else { throw AccountError.message("收藏暂时无法加载。") }
            collection = try JSONDecoder().decode(ClubCollectionEnvelope.self, from: response.data).items
            fetchedCollection=true
            await ClubDiskCache.shared.save(response.data,name:"collection",owner:userID,retained:true)
            guard generation == ticket else { return }
            notice = nil
        } catch is CancellationError { }
        catch { if generation == ticket { notice = "暂时无法刷新收藏，保留上次加载的内容。" + AppErrorText.message(error) } }
    }

    func refreshHistory(account: AccountService) async {
        activate(account.user?.id)
        guard let userID = account.user?.id else { history = []; return }
        if account.isPreviewAccount { history = [.debugPreview(joined: true)]; return }
        let ticket = generation
        do {
            let response = try await account.cloudRequest(path: "/club/history", expectedUserID: userID)
            guard generation == ticket else { return }
            guard response.statusCode == 200 else { throw AccountError.message("历史成长季暂时无法加载，请重试。") }
            history = try JSONDecoder().decode(ClubHistoryEnvelope.self, from: response.data).items
            fetchedHistory=true
            await ClubDiskCache.shared.save(response.data,name:"history",owner:userID,retained:true)
            guard generation == ticket else { return }
            notice = nil
        } catch is CancellationError { }
        catch { if generation == ticket { notice = AppErrorText.message(error) } }
    }

    func updateClaim(_ reward: ClubSeasonReward, action: String, account: AccountService) async {
        guard let userID = account.user?.id, !loading, ["cancel", "received"].contains(action), !account.isPreviewAccount else { return }
        let ticket = generation; loading = true
        defer { if generation == ticket { loading = false } }
        do {
            let value = try await request(account: account, userID: userID, path: "/club/rewards/\(reward.id)/\(action)", method: "POST", body: Data("{}".utf8))
            guard generation == ticket else { return }
            updateSeason(value)
            notice = action == "cancel" ? "申领已取消。截止日期前可重新选择奖励。" : "已确认收货。"
        } catch { if generation == ticket { notice = AppErrorText.message(error) } }
    }

    private func updateSeason(_ value: ClubSeasonEnvelope) {
        if value.season?.id == envelope?.season?.id { envelope = value }
        if let index = history.firstIndex(where: { $0.season?.id == value.season?.id }) { history[index] = value }
        else if value.season != nil { history.insert(value, at: 0) }
    }

    func join(account: AccountService) async {
        guard let userID = account.user?.id, let seasonID = envelope?.season?.id, !loading else { return }
        if account.isPreviewAccount { envelope = .debugPreview(joined: true); notice = "已加入预览成长季。"; return }
        let ticket = generation
        loading = true
        defer { if generation == ticket { loading = false } }
        do {
            let value = try await request(account: account, userID: userID, path: "/club/seasons/\(seasonID)/join", method: "POST", body: Data("{}".utf8))
            guard generation == ticket else { return }
            envelope = value
            notice = "欢迎加入本月成长季。你的每一次认真记录，都会成为进度。"
        } catch { if generation == ticket { notice = AppErrorText.message(error) } }
    }

    func claim(_ reward: ClubSeasonReward, draft: RewardClaimDraft, account: AccountService) async -> Bool {
        guard let userID = account.user?.id, !loading else { return false }
        if account.isPreviewAccount { notice = "预览账号不会提交真实实物申领。"; return false }
        struct Body: Encodable { let recipient, phone, region, address, size: String }
        let ticket = generation
        loading = true
        defer { if generation == ticket { loading = false } }
        do {
            let data = try JSONEncoder().encode(Body(recipient: draft.recipient, phone: draft.phone, region: draft.region, address: draft.address, size: draft.size))
            let value = try await request(account: account, userID: userID, path: "/club/rewards/\(reward.id)/claim", method: "POST", body: data)
            guard generation == ticket else { return false }
            updateSeason(value)
            notice = "申领已经提交。官方确认后，你可以在这里查看发货进度。"
            return true
        } catch { if generation == ticket { notice = AppErrorText.message(error) }; return false }
    }

    private func request(account: AccountService, userID: Int, path: String, method: String = "GET", body: Data? = nil) async throws -> ClubSeasonEnvelope {
        let response = try await account.cloudRequest(path: path, method: method, body: body, expectedUserID: userID)
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw AccountError.message((try? JSONDecoder().decode(Failure.self, from: response.data).error) ?? "俱乐部服务暂不可用。")
        }
        return try JSONDecoder().decode(ClubSeasonEnvelope.self, from: response.data)
    }
}

extension ClubSeasonEnvelope {
    static func debugPreview(joined: Bool = false) -> ClubSeasonEnvelope {
        let season = ClubSeason(
            id: -1001,
            slug: "debug-club-season",
            title: "十月成长季",
            subtitle: "认真完成这一期，解锁属于你的 俱乐部奖励。",
            officialNote: "这是 Debug 预览数据，不连接真实账号服务器。",
            rules: "任务进度只用于界面演示，不代表真实云端记录。",
            startsOn: "2026-09-30",
            endsOn: "2026-10-30",
            joinDeadline: "2026-10-07",
            accessMode: "included"
        )
        return ClubSeasonEnvelope(
            season: season,
            joined: joined,
            joinedAt: joined ? "2026-09-30" : nil,
            tasks: [
                ClubSeasonTask(id: -1, title: "完成 3 个训练日", detail: "完成真实训练，让节奏稳定下来。", metric: "training_days", target: 3, current: 1, completed: false),
                ClubSeasonTask(id: -2, title: "记录 5 个饮食日", detail: "每天至少记录一餐，让饮食和训练互相印证。", metric: "meal_days", target: 5, current: 2, completed: false),
                ClubSeasonTask(id: -3, title: "完成一次每周回顾", detail: "结合训练、饮食和身体感受看看这一周发生了什么。", metric: "weekly_reviews", target: 1, current: 0, completed: false),
            ],
            rewards: [
                ClubSeasonReward(id: -1, title: "First Light", detail: "俱乐部奖励", type: "badge", icon: "sparkles", unlocked: false, claimStatus: nil, trackingCompany: nil, trackingNumber: nil, taskID: -1, unlockScope: "task"),
                ClubSeasonReward(id: -2, title: "Iron Oath", detail: "俱乐部奖励", type: "badge", icon: "seal", unlocked: false, claimStatus: nil, trackingCompany: nil, trackingNumber: nil, taskID: -2, unlockScope: "task"),
                ClubSeasonReward(id: -3, title: "俱乐部奖励", detail: "本期实体纪念礼", type: "physical", icon: "gift", unlocked: false, claimStatus: nil, trackingCompany: nil, trackingNumber: nil, taskID: -3, unlockScope: "season"),
            ],
            announcements: [
                ClubAnnouncement(id: -1, title: "欢迎来到成长季", body: "完成真实记录，解锁你的 俱乐部奖励。", publishedAt: "2026-09-30")
            ],
            memberCount: 1
        )
    }
}
