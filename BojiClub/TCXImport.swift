import Foundation
import CryptoKit

enum HealthImportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct TCXInspection: Identifiable {
    let id = UUID()
    let workouts: [DeviceWorkout]
    let skipped: [String: Int]
    var skippedCount: Int { skipped.values.reduce(0, +) }
}

final class TCXImport: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private var start: Date?
    private var seconds = 0.0
    private var calories = 0.0
    private var hasCalories = false
    private var sport = "运动"
    private var results: [DeviceWorkout] = []
    private var invalid = false
    private var activityInvalid = false
    private var skipped: [String: Int] = [:]
    private var now = Date()
    static func read(_ data: Data) throws -> [DeviceWorkout] {
        let inspection = try inspect(data)
        guard !inspection.workouts.isEmpty else { throw HealthImportError.message("没有有效运动，请检查文件的开始时间和每圈时长。") }
        return inspection.workouts
    }
    static func inspect(_ data: Data, now: Date = Date()) throws -> TCXInspection {
        guard data.count <= 5_000_000 else { throw HealthImportError.message("文件超过 5 MB，请选择较小的运动文件。") }
        // Disallow DTD/entity expansion; only UTF-8 TCX is accepted, no GPS is retained.
        guard let xml = String(data: data, encoding: .utf8), !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw HealthImportError.message("这个运动文件暂时无法读取。请从设备 App 重新导出 TCX 文件后再试。") }
        let delegate = TCXImport(); delegate.now = now; let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.invalid else { throw HealthImportError.message("运动文件结构损坏，尚未导入任何记录，请重新导出。") }
        return TCXInspection(workouts: delegate.results, skipped: delegate.skipped)
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if name == "Activity", path.contains("Activity") { invalid = true; parser.abortParsing(); return }
        path.append(name); text = ""
        if path.count > 40 { invalid = true; parser.abortParsing() }
        if name == "Activity" { start = nil; seconds = 0; calories = 0; hasCalories = false; activityInvalid = false; sport = attributes["Sport"] ?? "运动" }
        if name == "Lap", start == nil, let value = attributes["StartTime"] { start = Self.date(value) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if text.count < 1024 { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let parent = path.dropLast().last
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "Id", parent == "Activity" { start = Self.date(value) }
        if name == "TotalTimeSeconds", parent == "Lap" {
            if let n = Double(value), n.isFinite, n > 0 { seconds += n } else { activityInvalid = true }
        }
        if name == "Calories", parent == "Lap" {
            if let n = Double(value), n.isFinite, n >= 0 { calories += n; hasCalories = true } else { activityInvalid = true }
        }
        if name == "Activity" {
            if activityInvalid || start == nil || !seconds.isFinite || seconds <= 0 || seconds > 604800 || !calories.isFinite || calories > 100_000 {
                skipped["时间、时长或能量无效", default: 0] += 1
            } else if let start, start > now || start.addingTimeInterval(seconds) > now {
                skipped["运动尚未结束或日期在未来", default: 0] += 1
            } else if results.count >= 200 {
                skipped["超过单次 200 条导入上限", default: 0] += 1
            } else if let start {
                let fingerprint = "\(sport)|\(start.timeIntervalSince1970)|\(seconds)"
                let id = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
                let title = ["Running": "跑步", "Biking": "骑行", "Other": "运动"][sport] ?? "运动"
                results.append(DeviceWorkout(id: "tcx-" + id, name: title, start: start, end: start.addingTimeInterval(seconds), minutes: seconds / 60, calories: hasCalories ? calories : nil, source: HealthSource(id: "tcx", name: "TCX 文件")))
            }
        }
        _ = path.popLast(); text = ""
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds); return formatter.date(from: value)
    }
}
