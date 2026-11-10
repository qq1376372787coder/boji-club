import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct JournalScan<Entry> {
    var entries: [Entry]
    var unreadableLines: [Int]
    var committedBytes: Int
    var hasIncompleteTail: Bool
}

enum JournalScanner {
    // Scan into a separate value. The caller decides whether to adopt it;
    // neither a damaged committed line nor a partial append changes live state.
    static func scan<Entry: Decodable>(_ data: Data, as type: Entry.Type) -> JournalScan<Entry> {
        let boundary = data.last == 10 ? data.count : (data.lastIndex(of: 10).map { $0 + 1 } ?? 0)
        var entries: [Entry] = [], unreadable: [Int] = []
        let lines = data.prefix(boundary).split(separator: 10, omittingEmptySubsequences: false)
        for (index, line) in lines.dropLast().enumerated() {
            do { entries.append(try JSONDecoder().decode(Entry.self, from: Data(line))) }
            catch { unreadable.append(index + 1) }
        }
        return JournalScan(entries: entries, unreadableLines: unreadable,
                           committedBytes: boundary, hasIncompleteTail: boundary < data.count)
    }
}

struct LocalRecoverySummary: Equatable {
    var readableEntries: Int
    var unreadableEntries: Int
    var snapshotReadable: Bool
    var detail: String
}

enum LocalRecoveryTransaction {
    private struct Pending: Codable {
        let accountID: Int
        let checkpoint: Data
    }
    static func commit(_ checkpoint: Data, accountID: Int, recordURL: URL) throws {
        let folder = recordURL.deletingLastPathComponent().appendingPathComponent("recovery-\(accountID)-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        for source in [recordURL, recordURL.appendingPathExtension("journal")] where FileManager.default.fileExists(atPath: source.path) {
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        }
        // The marker is durable before either original is changed. If power is
        // lost midway, the next launch completes the user's accepted recovery.
        let marker = recordURL.appendingPathExtension("recovery-pending")
        try JSONEncoder().encode(Pending(accountID: accountID, checkpoint: checkpoint)).write(to: marker, options: [.atomic, .completeFileProtection])
        try finishPending(accountID: accountID, recordURL: recordURL)
    }
    static func finishPending(accountID: Int, recordURL: URL) throws {
        let marker = recordURL.appendingPathExtension("recovery-pending")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: marker))
        guard pending.accountID == accountID else { throw CocoaError(.fileReadNoPermission) }
        try pending.checkpoint.write(to: recordURL, options: [.atomic, .completeFileProtection])
        try Data().write(to: recordURL.appendingPathExtension("journal"), options: [.atomic, .completeFileProtection])
        try FileManager.default.removeItem(at: marker)
    }
}

// One locked cache is safe from both detached workers and UI callers. A timezone
// change creates a new entry; formatters never retain an earlier timezone.
final class ClubDateFormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]
    func string(_ date: Date, format: String, locale: String, timezone: TimeZone = .current) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter(format: format, locale: locale, timezone: timezone).string(from: date)
    }
    func date(_ value: String, timezone: TimeZone = .current) -> Date? {
        lock.lock(); defer { lock.unlock() }
        let f = formatter(format: "yyyy-MM-dd", locale: "en_US_POSIX", timezone: timezone)
        guard let date = f.date(from: value), f.string(from: date) == value else { return nil }
        return date
    }
    private func formatter(format: String, locale: String, timezone: TimeZone) -> DateFormatter {
        let key = locale + "/" + format + "/" + timezone.identifier
        if let found = formatters[key] { return found }
        if formatters.count >= 32 { formatters.removeAll() }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: locale); f.timeZone = timezone
        f.dateFormat = format; f.isLenient = false; formatters[key] = f
        return f
    }
}

struct PhotoSyncIssue: Identifiable, Equatable {
    var dateKey: String
    var mealID: UUID
    var mealName: String
    var detail: String
    var id: String { dateKey + "/" + mealID.uuidString }
}

enum RecordPhoto {
    static func isValidJPEG(_ data: Data) -> Bool {
        guard data.count <= 4 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return valid(source)
    }
    static func isValidJPEG(at url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return valid(source)
    }
    private static func valid(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source), type as String == UTType.jpeg.identifier,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 20_000_000
    }
    // ImageIO bounds decoded pixel memory; never decode a full imported 4 MB+
    // image just to create its upload payload.
    static func jpeg(_ data: Data, pixels: Int = 1400) -> Data? {
        guard data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 4 * 1024 * 1024 else { return nil }
        return output as Data
    }
}

enum AIVisibleError {
    static func message(code: String?, fallback: String?) -> String? {
        switch code {
        case "all_unavailable", "provider_config": return "分析服务暂时不可用，输入已保留，请稍后重试。"
        case "invalid_request": return "这份输入暂时无法处理，请核对日期、资料或照片后重新提交。"
        case "invalid_output": return "返回的分析不完整，原记录已保留，可以重新生成。"
        case "task_timeout", "upstream_timeout": return "这次等待较久，输入已保留，请稍后重试。"
        case "input_expired": return "这份识别输入已过期，请重新选择照片或提交文字。"
        case "maintenance", "capacity": return "分析服务当前较忙，输入已保留，请稍后重试。"
        case "quota_exceeded": return "今日分析次数已用完，北京时间零点恢复。输入已保留，不需要重复提交。"
        case "daily_capacity": return "今日分析服务容量已达上限，北京时间零点恢复。输入已保留，请稍后再试。"
        case "internal_error", "worker_interrupted": return "这次分析未完成，记录已保留，请重新尝试。"
        default:
            guard let fallback, !fallback.isEmpty else { return nil }
            // Future backend changes must not put exception traces, HTTP bodies
            // or implementation fields into the reading experience.
            if fallback.count > 500 || fallback.contains("Traceback") || fallback.contains("{\"") || fallback.contains("<html") {
                return "分析暂未完成，输入已保留，请稍后重试。"
            }
            return fallback
        }
    }
}

// Main-actor owner; immutable blobs first, atomic index last. A failed write
// cannot make the previously committed index point at half-written content.
final class AIJobDiskStore {
    private(set) var unreadableJobIDs: Set<String> = []
    private struct Entry: Codable { var id: String; var file: String }
    private struct Index: Codable { var version = 2; var entries: [Entry] }
    private struct Record: Codable { var job: AILocalJob; var photo: String? }
    private var currentURL: URL?
    private var cachedJobs: [String: AILocalJob] = [:]
    private var cachedEntries: [String: Entry] = [:]
    private var cachedPhotos: [String: String] = [:]
    func reset() { currentURL = nil; cachedJobs = [:]; cachedEntries = [:]; cachedPhotos = [:]; unreadableJobIDs = [] }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func valid(_ name: String, suffix: String) -> Bool { name.range(of: "^[a-f0-9]{64}\\." + suffix + "$", options: .regularExpression) != nil }
    func load(_ url: URL) throws -> [AILocalJob] {
        currentURL = url; cachedJobs = [:]; cachedEntries = [:]; cachedPhotos = [:]
        unreadableJobIDs = []
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let legacy = try? JSONDecoder().decode([AILocalJob].self, from: data) { return legacy }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.version == 2, Set(index.entries.map(\.id)).count == index.entries.count else { throw CocoaError(.fileReadCorruptFile) }
        let parts = url.appendingPathExtension("parts")
        var jobs: [AILocalJob] = []
        for entry in index.entries {
            do {
            guard valid(entry.file, suffix: "job") else { throw CocoaError(.fileReadCorruptFile) }
            let bytes = try Data(contentsOf: parts.appendingPathComponent(entry.file))
            guard hash(bytes) + ".job" == entry.file else { throw CocoaError(.fileReadCorruptFile) }
            var record = try JSONDecoder().decode(Record.self, from: bytes)
            guard record.job.id == entry.id else { throw CocoaError(.fileReadCorruptFile) }
            if let photo = record.photo {
                guard valid(photo, suffix: "input") else { throw CocoaError(.fileReadCorruptFile) }
                let input = try Data(contentsOf: parts.appendingPathComponent(photo), options: .mappedIfSafe)
                guard hash(input) + ".input" == photo, let value = String(data: input, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                record.job.request.payload["image_base64"] = .string(value); cachedPhotos[entry.id] = photo
            }
            jobs.append(record.job); cachedJobs[entry.id] = record.job; cachedEntries[entry.id] = entry
            } catch {
                unreadableJobIDs.insert(entry.id)
                // Keep the committed index and every original blob intact. Healthy
                // entries remain readable, but partial loads must never be saved.
            }
        }
        return jobs
    }
    func save(_ jobs: [AILocalJob], to url: URL) throws {
        if currentURL != url { _ = try load(url) }
        guard unreadableJobIDs.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        guard Set(jobs.map(\.id)).count == jobs.count else { throw CocoaError(.fileWriteUnknown) }
        let folder = url.appendingPathExtension("parts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var protected = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true; try protected.setResourceValues(values)
        var entries: [Entry] = [], photos: [String: String] = [:], retained = Set<String>()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for job in jobs {
            if cachedJobs[job.id] == job, let entry = cachedEntries[job.id] {
                entries.append(entry); retained.insert(entry.file)
                if let photo = cachedPhotos[job.id] { photos[job.id] = photo; retained.insert(photo) }
                continue
            }
            var copy = job, photo: String?
            if let input = copy.request.payload.removeValue(forKey: "image_base64")?.string {
                let bytes = Data(input.utf8)
                photo = hash(bytes) + ".input"
                if let photo {
                    let destination = folder.appendingPathComponent(photo)
                    if !FileManager.default.fileExists(atPath: destination.path) { try bytes.write(to: destination, options: [.atomic, .completeFileProtection]) }
                    photos[job.id] = photo; retained.insert(photo)
                }
            }
            let data = try encoder.encode(Record(job: copy, photo: photo)), name = hash(data) + ".job"
            try data.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
            entries.append(Entry(id: job.id, file: name)); retained.insert(name)
        }
        // First migration keeps the old format as a protected recovery copy.
        if FileManager.default.fileExists(atPath: url.path), cachedEntries.isEmpty,
           let bytes = try? Data(contentsOf: url), (try? JSONDecoder().decode([AILocalJob].self, from: bytes)) != nil {
            let legacy = url.appendingPathExtension("legacy")
            if !FileManager.default.fileExists(atPath: legacy.path) { try bytes.write(to: legacy, options: [.atomic, .completeFileProtection]) }
        }
        try encoder.encode(Index(entries: entries)).write(to: url, options: [.atomic, .completeFileProtection])
        cachedJobs = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedEntries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); cachedPhotos = photos
        do {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where !retained.contains(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
        } catch { NSLog("AI task storage cleanup deferred") }
    }
}
