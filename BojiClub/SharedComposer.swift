import SwiftUI
import PhotosUI
import ImageIO
import CryptoKit
import AVFoundation

/// The presented item carries its entry mode atomically, avoiding stale captures on first presentation.
struct ClubComposerMealRoute: Identifiable {
    let id = UUID()
    let date: Date
    let mode: String
}

/// One editing surface for the empty workspace and every conversation state.
/// Voice uses the existing on-device recognizer; opening this view never starts audio.
struct ClubChatAttachment: Codable, Equatable, Identifiable {
    let id: UUID
    let ownerID: Int
    let conversation: String
    let data: Data
    let createdAt: Date
    var wire: JSONValue {
        .object(["id": .string(id.uuidString.lowercased()), "mime_type": .string("image/jpeg"),
            "data_base64": .string(data.base64EncodedString()),
            "sha256": .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())])
    }
    static func prepare(_ data: Data, owner: Int, conversation: String) throws -> Self {
        guard owner != 0, UUID(uuidString: conversation) != nil, data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary) else {
            throw AIClientError.message("照片无法读取或文件过大，请选择一张较小的照片。")
        }
        // Fresh JPEG removes EXIF/GPS metadata. Downsampling avoids full-resolution decoding.
        let image = UIImage(cgImage: cg)
        var encoded = image.jpegData(compressionQuality: 0.65)
        if (encoded?.count ?? Int.max) > 1_048_576 { encoded = image.jpegData(compressionQuality: 0.45) }
        guard let encoded, (50...1_048_576).contains(encoded.count) else {
            throw AIClientError.message("照片压缩后仍超过 1 MB，请裁剪后重新选择。")
        }
        return Self(id: UUID(), ownerID: owner, conversation: conversation, data: encoded, createdAt: Date())
    }
    static func payload(_ items: [Self], owner: Int, conversation: String) throws -> JSONValue {
        guard items.count <= 3, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.ownerID == owner && $0.conversation == conversation && (50...1_048_576).contains($0.data.count) }) else {
            throw AIClientError.message("照片所属账号或会话已变化，请重新选择。")
        }
        return .array(items.map(\.wire))
    }
}

/// Backup-excluded, protected account/conversation drafts. Images are only transmitted on Send.
enum ClubChatDraftStorage {
    struct Draft: Codable { let owner: Int; let conversation: String; let attachments: [ClubChatAttachment]; let context: ClubAIEntryContext?; var references: [AIContextReference]? = nil; var source: ClubContextSource? = nil; var scope: ClubReviewScope? = nil }
    static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BojiClub/chat-drafts", isDirectory: true) }
    static func url(owner: Int, conversation: String) -> URL { folder.appendingPathComponent("\(owner)-\(conversation.lowercased()).json") }
    static func load(owner: Int, conversation: String) -> Draft? {
        guard owner != 0, UUID(uuidString: conversation) != nil,
              let data = try? Data(contentsOf: url(owner: owner, conversation: conversation)),
              let draft = try? JSONDecoder().decode(Draft.self, from: data), draft.owner == owner,
              draft.conversation == conversation,
              draft.attachments.allSatisfy({ $0.ownerID == owner && $0.conversation == conversation }) else { return nil }
        return draft
    }
    @discardableResult static func save(owner: Int, conversation: String, attachments: [ClubChatAttachment], context: ClubAIEntryContext?, references: [AIContextReference] = [], source: ClubContextSource? = nil, scope: ClubReviewScope? = nil) -> Bool {
        guard owner != 0, UUID(uuidString: conversation) != nil,
              attachments.allSatisfy({ $0.ownerID == owner && $0.conversation == conversation }),
              context == nil || (context?.ownerID == owner && context?.conversationID == conversation) else { return false }
        if attachments.isEmpty && context == nil && references.isEmpty && source == nil && scope == nil { clear(owner: owner, conversation: conversation); return true }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var root = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            let data = try JSONEncoder().encode(Draft(owner: owner, conversation: conversation, attachments: attachments, context: context, references: references, source: source, scope: scope))
            try data.write(to: url(owner: owner, conversation: conversation), options: [.atomic, .completeFileProtection])
            return true
        } catch { return false }
    }
    static func clear(owner: Int, conversation: String) {
        guard owner != 0, UUID(uuidString: conversation) != nil else { return }
        try? FileManager.default.removeItem(at: url(owner: owner, conversation: conversation))
    }
    static func conversations(owner: Int) -> [String] {
        let prefix = "\(owner)-"
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap { file in
            guard file.lastPathComponent.hasPrefix(prefix) else { return nil }
            let id = String(file.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
            guard let draft = load(owner: owner, conversation: id) else { return nil }
            return !draft.attachments.isEmpty || draft.references?.isEmpty == false ? id : nil
        }
    }
    static func erase(owner: Int) {
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix("\(owner)-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
