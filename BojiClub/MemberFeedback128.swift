import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import AVKit
import ImageIO
import CryptoKit

struct MemberFeedbackAttachment128: Codable, Identifiable, Equatable {
    let id: String; let kind: String; let mime: String; let bytes: Int64
    let duration_seconds: Double?
}
struct MemberFeedbackTicket128: Codable, Identifiable {
    let id: String; let category: String; let status: String; let title: String
    let last_message_id: Int; let unread: Bool; let created_at: String; let updated_at: String
    var statusLabel: String { ["open":"待回复","replied":"已回复","closed":"已解决"][status] ?? "处理中" }
}
struct MemberFeedbackMessage128: Codable, Identifiable {
    let id: Int; let client_id: String; let author: String; let text: String; let created_at: String
    let attachments: [MemberFeedbackAttachment128]
}
struct MemberFeedbackDetail128: Codable { let ticket: MemberFeedbackTicket128; let messages: [MemberFeedbackMessage128]; let has_older: Bool }
struct MemberFeedbackList128: Decodable { let items: [MemberFeedbackTicket128]; let has_more: Bool }
struct FeedbackHTTPError128: LocalizedError {
    let status: Int; let message: String
    var errorDescription: String? { message }
}
@MainActor enum MemberFeedbackAPI128 {
    static func decode<T: Decodable>(_ response: AccountRawResponse, as type: T.Type = T.self) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            let error = (try? JSONDecoder().decode([String:String].self, from: response.data))?["error"]
            throw FeedbackHTTPError128(status: response.statusCode, message: error ?? "反馈服务暂不可用，请稍后再试。")
        }
        return try JSONDecoder().decode(T.self, from: response.data)
    }
    static func get<T: Decodable>(_ account: AccountService, owner: Int, path: String) async throws -> T {
        let raw = try await account.cloudRequest(path: path, expectedUserID: owner)
        return try decode(raw)
    }
    static func post<T: Decodable>(_ account: AccountService, owner: Int, path: String, body: [String: JSONValue]) async throws -> T {
        let raw = try await account.cloudRequest(path: path, method: "POST", body: JSONEncoder().encode(body), expectedUserID: owner)
        return try decode(raw)
    }
}
struct FeedbackLocalAttachment128: Codable, Identifiable, Equatable {
    let id: String; let mime: String; let bytes: Int64; let sha256: String
    var isVideo: Bool { mime == "video/mp4" }
    func url(owner: Int) -> URL { FeedbackDraftStore128.folder(owner).appendingPathComponent(id + (isVideo ? ".mp4" : ".jpg")) }
}
struct FeedbackDraft128: Codable {
    var id = UUID().uuidString.lowercased()
    var text = ""; var category = "problem"; var attachments: [FeedbackLocalAttachment128] = []
    var metadata: [String:String]?
    var pending = false
    var canSubmit: Bool { text.count <= 4000 && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }
}
enum FeedbackDraftStore128 {
    static func folder(_ owner: Int) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BojiClub/feedback-drafts/\(owner)", isDirectory: true)
    }
    static func key(_ owner: Int, ticket: String?) -> URL { folder(owner).appendingPathComponent((ticket ?? "new") + ".json") }
    static func load(owner: Int, ticket: String?) -> FeedbackDraft128 {
        guard let data = try? Data(contentsOf: key(owner, ticket: ticket)), let value = try? JSONDecoder().decode(FeedbackDraft128.self, from: data) else { return .init() }
        return value
    }
    static func prepare(_ owner: Int) throws {
        let dir = folder(owner); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
        var url = dir; var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
    }
    static func save(_ draft: FeedbackDraft128, owner: Int, ticket: String?) throws {
        try prepare(owner); try JSONEncoder().encode(draft).write(to: key(owner, ticket: ticket), options: [.atomic,.completeFileProtection])
    }
    static func clear(_ draft: FeedbackDraft128, owner: Int, ticket: String?) {
        for item in draft.attachments { try? FileManager.default.removeItem(at: item.url(owner: owner)) }
        try? FileManager.default.removeItem(at: key(owner, ticket: ticket))
    }
    static func erase(owner: Int) { try? FileManager.default.removeItem(at: folder(owner)) }
}
struct FeedbackMovie128: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { file in
            let originalSize = try file.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard originalSize > 0, originalSize <= 250 * 1024 * 1024 else { throw AccountError.message("原视频过大，请先在相册裁剪或压缩。") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fb128-" + UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: file.file, to: url)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            return .init(url: url)
        }
    }
}
enum FeedbackMedia128 {
    static func picture(_ data: Data, owner: Int) throws -> FeedbackLocalAttachment128 {
        guard data.count <= 60 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData,nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2200] as CFDictionary),
              let jpeg = UIImage(cgImage:cg).jpegData(compressionQuality:0.85), jpeg.count <= 3 * 1024 * 1024 else { throw AccountError.message("照片无法读取或过大，请换一张照片。") }
        try FeedbackDraftStore128.prepare(owner)
        let id = UUID().uuidString.lowercased(); let url = FeedbackDraftStore128.folder(owner).appendingPathComponent(id + ".jpg")
        try jpeg.write(to:url,options:[.atomic,.completeFileProtection])
        return .init(id:id,mime:"image/jpeg",bytes:Int64(jpeg.count),sha256:SHA256.hash(data:jpeg).map { String(format:"%02x",$0) }.joined())
    }
    static func video(_ source: URL, owner: Int) async throws -> FeedbackLocalAttachment128 {
        let asset = AVURLAsset(url:source); let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 60 else { throw AccountError.message("视频请控制在 60 秒以内，可先在相册中裁剪。") }
        try FeedbackDraftStore128.prepare(owner)
        let id = UUID().uuidString.lowercased(); let url = FeedbackDraftStore128.folder(owner).appendingPathComponent(id + ".mp4")
        guard let exporter = AVAssetExportSession(asset:asset,presetName:AVAssetExportPreset1280x720) else { throw AccountError.message("这个视频暂时无法转换，请换一个视频。") }
        exporter.outputURL = url; exporter.outputFileType = .mp4; exporter.shouldOptimizeForNetworkUse = true; exporter.metadata = []
        do {
            return try await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void,Never>) in exporter.exportAsynchronously { c.resume() } }
                try Task.checkCancellation()
                guard exporter.status == .completed else { throw AccountError.message("视频处理未完成，请重新选择。") }
                let size = (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
                guard size >= 50, size <= 20 * 1024 * 1024 else { throw AccountError.message("压缩后的视频仍超过 20 MB，请先裁短。") }
                try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
                let data = try Data(contentsOf:url,options:.mappedIfSafe)
                return FeedbackLocalAttachment128(id:id,mime:"video/mp4",bytes:Int64(size),sha256:SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined())
            } onCancel: { exporter.cancelExport() }
        } catch { try? FileManager.default.removeItem(at:url); throw error }
    }
}
@MainActor final class FeedbackComposerModel128: ObservableObject {
    let owner: Int; let ticket: String?
    @Published var draft: FeedbackDraft128 { didSet { persist() } }
    @Published var busy = false; @Published var activity = ""; @Published var error: String?
    init(owner: Int, ticket: String?) { self.owner=owner;self.ticket=ticket;draft=FeedbackDraftStore128.load(owner:owner,ticket:ticket) }
    private func persist() { do { try FeedbackDraftStore128.save(draft,owner:owner,ticket:ticket) } catch { self.error="草稿未能保存在本机，请保持此页并重试。" } }
    func add(_ items: [PhotosPickerItem], account: AccountService) async {
        guard !busy,!draft.pending else { return };busy=true;defer { busy=false;activity="" }
        for item in items {
            guard !Task.isCancelled,account.user?.id==owner,draft.attachments.count<4 else { return }
            activity="正在处理照片或视频…"
            do {
                let attachment: FeedbackLocalAttachment128
                if item.supportedContentTypes.contains(where:{ $0.conforms(to:.movie) }) {
                    guard let movie=try await item.loadTransferable(type:FeedbackMovie128.self) else { throw AccountError.message("视频读取失败。") }
                    defer { try? FileManager.default.removeItem(at:movie.url) }
                    attachment=try await FeedbackMedia128.video(movie.url,owner:owner)
                } else {
                    guard let data=try await item.loadTransferable(type:Data.self) else { throw AccountError.message("照片读取失败。") }
                    attachment=try FeedbackMedia128.picture(data,owner:owner)
                }
                guard !Task.isCancelled,account.user?.id==owner else { try? FileManager.default.removeItem(at:attachment.url(owner:owner));return }
                draft.attachments.append(attachment);error=nil
            } catch is CancellationError { return } catch { self.error=error.localizedDescription;return }
        }
    }
    func submit(account: AccountService) async -> MemberFeedbackDetail128? {
        guard !busy,draft.canSubmit,account.user?.id==owner else { return nil }
        guard !account.isPreviewAccount else { error="预览模式不会上传或提交反馈，请使用正式账号。";return nil }
        busy=true;error=nil;defer { busy=false;activity="" }
        do {
            for (index,a) in draft.attachments.enumerated() {
                try Task.checkCancellation();guard account.user?.id==owner else { throw CancellationError() }
                activity="正在上传附件 \(index+1)/\(draft.attachments.count)…"
                let response=try await account.feedbackUpload128(file:a.url(owner:owner),id:a.id,mime:a.mime,sha256:a.sha256,expectedUserID:owner)
                struct Uploaded: Decodable { let attachment: MemberFeedbackAttachment128 }
                let _: Uploaded=try MemberFeedbackAPI128.decode(response)
            }
            activity=draft.pending ? "正在核对提交结果…":"正在提交反馈…"
            draft.pending=true
            if draft.metadata == nil {
                draft.metadata=["app_version":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "", "build":Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "", "os_version":UIDevice.current.systemVersion,"device_family":UIDevice.current.userInterfaceIdiom == .pad ? "iPad":"iPhone"]
            }
            let meta = (draft.metadata ?? [:]).mapValues { JSONValue.string($0) }
            let body:[String:JSONValue]=["client_id":.string(draft.id),"text":.string(draft.text),"category":.string(draft.category),"attachments":.array(draft.attachments.map { .string($0.id) }),"metadata":.object(meta)]
            let path="/me/feedback/"+(ticket ?? draft.id)+(ticket == nil ? "":"/messages")
            let result: MemberFeedbackDetail128=try await MemberFeedbackAPI128.post(account,owner:owner,path:path,body:body)
            guard account.user?.id==owner,!Task.isCancelled else { throw CancellationError() }
            FeedbackDraftStore128.clear(draft,owner:owner,ticket:ticket);return result
        } catch let e as FeedbackHTTPError128 { if (400..<500).contains(e.status) { draft.pending=false };error=e.localizedDescription }
        catch is CancellationError { error="操作已暂停，草稿已保留。" }
        catch { self.error=draft.pending ? "提交结果尚未确认，内容已保留。请点“核对并重试”，不会重复生成同一反馈。":error.localizedDescription }
        return nil
    }
    func remove(_ item: FeedbackLocalAttachment128, account: AccountService) {
        guard !busy,!draft.pending else { return };draft.attachments.removeAll { $0.id==item.id };try? FileManager.default.removeItem(at:item.url(owner:owner))
        Task { _ = try? await account.cloudRequest(path:"/me/feedback/attachments/"+item.id,method:"DELETE",expectedUserID:owner) }
    }
    func discard(account: AccountService) {
        guard !busy,!draft.pending else { return };let old=draft;FeedbackDraftStore128.clear(old,owner:owner,ticket:ticket);draft = .init()
        for a in old.attachments { Task { _ = try? await account.cloudRequest(path:"/me/feedback/attachments/"+a.id,method:"DELETE",expectedUserID:owner) } }
    }
}
