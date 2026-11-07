import Foundation
import Combine
import Speech
import AVFoundation

/// Audio is never persisted or sent to the app's backend. No network fallback.
@MainActor
final class MealSpeechInput: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isFinishing = false
    @Published private(set) var message: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var sessionConfigured = false
    private var generation = UUID()
    private var timeoutTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    @Published var language = "zh-CN"
    static let languages = [("zh-CN", "普通话"), ("zh-HK", "粤语"), ("zh-TW", "台湾国语"), ("en-US", "英语") ]

    func start() async {
        guard !isRecording, !isPreparing else { return }
        stop()
        let token = generation
        transcript = ""; message = nil; isPreparing = true
        defer { if generation == token { isPreparing = false } }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.supportsOnDeviceRecognition else {
            message = "这台手机暂不支持所选语言的本地语音识别，请直接打字；录音不会上传。"; return
        }
        let microphone = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == token else { return }
        guard microphone else { message = "麦克风权限未开启，可在系统设置中开启，或直接打字。"; return }
        let authorization = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == token else { return }
        guard authorization == .authorized else { message = "语音识别权限未开启，可以直接打字。"; return }
        guard recognizer.isAvailable else { message = "本地语音识别暂不可用，请稍后重试或直接打字。"; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            sessionConfigured = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                stop(); message = "麦克风暂不可用，请直接打字。"; return
            }
            let audio = SFSpeechAudioBufferRecognitionRequest()
            audio.requiresOnDeviceRecognition = true
            audio.shouldReportPartialResults = true
            request = audio
            recognitionTask = recognizer.recognitionTask(with: audio) { [weak self] result, error in
                let words = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if let words { self.transcript = String(words.prefix(2000)) }
                    if finished || failed || (words?.count ?? 0) >= 2000 {
                        self.stop()
                        if failed { self.message = "本地识别已停止，已识别文字保留，可以修改后继续。" }
                    }
                }
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                audio.append(buffer)
                guard let channel = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else { return }
                let count = Int(buffer.frameLength)
                var energy: Float = 0
                for i in stride(from: 0, to: count, by: 8) { energy += channel[i] * channel[i] }
                let level = min(1, sqrt(energy / Float(max(1,count/8))) * 8)
                Task { @MainActor [weak self] in guard let self, self.generation == token else { return }; self.audioLevel = level }
            }
            tapInstalled = true
            engine.prepare(); try engine.start(); startedAt = Date(); isRecording = true
            timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.generation == token else { return }
                self.finishRecording(); self.message = "已结束本次录音，核对文字后即可识别餐食。"
            }
        } catch {
            stop(); message = "无法启动本地语音识别，文字已保留，请重试或直接打字。"
        }
    }

    func finishRecording() {
        guard isRecording else { return }
        timeoutTask?.cancel(); timeoutTask = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        isRecording = false; isPreparing = true; isFinishing = true
        let token = generation
        finishTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, self.generation == token else { return }
            self.stop()
        }
    }

    func stop() {
        generation = UUID()
        finishTask?.cancel(); finishTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); recognitionTask?.cancel(); recognitionTask = nil; request = nil
        if sessionConfigured {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionConfigured = false
        }
        audioLevel = 0; isRecording = false; isPreparing = false; isFinishing = false
    }
}

struct MealDescriptionHint {
    var date: Date
    var category: String
    var problem: String?
    var requiresDateConfirmation = false
}

enum MealDescriptionUnderstanding {
    static func inspect(_ text: String, date: Date, category: String, now: Date = Date()) -> MealDescriptionHint {
        var hint = MealDescriptionHint(date: date, category: category)
        let groups: [(String, [String])] = [
            ("早餐", ["早餐", "早饭"]), ("午餐", ["午餐", "午饭"]),
            ("晚餐", ["晚餐", "晚饭"]), ("加餐", ["加餐", "夜宵", "宵夜", "下午茶"])
        ]
        var meals = groups.filter { group in group.1.contains { text.contains($0) } }.map { $0.0 }
        let timeMeals = [("早餐", ["早上", "早晨", "上午", "今早", "昨早"]), ("午餐", ["中午"]), ("晚餐", ["晚上", "傍晚", "今晚", "昨晚"])].filter { group in
                group.1.contains { text.contains($0) }
            }.map { $0.0 }
        // A morning snack remains a snack; mixed named/time meals still need splitting.
        if !(meals == ["加餐"] && timeMeals.count <= 1) { meals = Array(Set(meals + timeMeals)) }
        if meals.count > 1 { hint.problem = "这段话提到了多餐，请使用“识别餐食”自动分餐，或只填写一餐名称。" }
        else if let meal = meals.first { hint.category = meal }
        if ["明天", "明早", "明晚", "后天", "明年", "后年"].contains(where: { text.contains($0) }) {
            hint.problem = "这里记录已经吃过的餐食，未来饮食不能记为已吃。"
        }
        let explicit = explicitDates(in: text, now: now)
        hint.requiresDateConfirmation = explicit.mentioned
        if explicit.invalid { hint.problem = "这段话中的日期无效，请核对年月日后再识别。" }
        let uniqueDates = Set(explicit.dates.map(ClubDates.key))
        if uniqueDates.count > 1 { hint.problem = "这段话提到了不同日期，请使用“识别餐食”自动分餐，或分开记录名称。" }
        else if let day = explicit.dates.first { hint.date = day }
        let relative = [("前天", ["前天"]), ("昨天", ["昨天", "昨晚", "昨早"]), ("今天", ["今天", "今早", "今晚"])].filter { group in group.1.contains { text.contains($0) } }.map { $0.0 }
        if relative.count > 1 { hint.problem = "这段话提到了不同日期，请使用“识别餐食”自动分餐，或分开记录名称。" }
        else if let value = relative.first,
                let day = ClubDates.calendar.date(byAdding: .day, value: value == "前天" ? -2 : value == "昨天" ? -1 : 0, to: now) {
            if let explicitDay = explicit.dates.first, ClubDates.key(explicitDay) != ClubDates.key(day) {
                hint.problem = "具体日期和“今天／昨天”等说法不一致，请核对日期后再识别。"
            } else { hint.date = day }
        }
        if ClubDates.calendar.startOfDay(for: hint.date) > ClubDates.calendar.startOfDay(for: now) {
            hint.problem = "这里记录已经吃过的餐食，未来饮食不能记为已吃。请核对日期。"
        }
        return hint
    }

    // Parse unambiguous calendar dates only. Do not mistake "1/2碗" for a date.
    // An omitted year means the current year; future dates need clarification,
    // rather than silently being moved into a previous year.
    private static func explicitDates(in text: String, now: Date) -> (dates: [Date], mentioned: Bool, invalid: Bool) {
        let patterns = [
            #"(?<![0-9])([0-9]{4})\s*[-/.]\s*([0-9]{1,2})\s*[-/.]\s*([0-9]{1,2})(?![0-9])"#,
            #"(?<![0-9零〇一二两三四五六七八九十])(?:([0-9零〇一二两三四五六七八九]{4})\s*年\s*)?([0-9零〇一二两三四五六七八九十]{1,3})\s*月\s*([0-9零〇一二两三四五六七八九十]{1,3})\s*[日号]?"#
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var dates: [Date] = []; var mentioned = false; var invalid = false
        let calendar = ClubDates.calendar
        let currentYear = calendar.component(.year, from: now)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: range) {
                mentioned = true
                func value(_ index: Int) -> String? {
                    guard let range = Range(match.range(at: index), in: text) else { return nil }
                    return String(text[range])
                }
                let yearText = value(1)
                let implicitYear = text.contains("前年") ? currentYear - 2 : text.contains("去年") ? currentYear - 1 : currentYear
                let yearValue: Int?
                if let yearText { yearValue = integer(yearText) } else { yearValue = implicitYear }
                guard let year = yearValue,
                      let monthText = value(2), let month = integer(monthText),
                      let dayText = value(3), let day = integer(dayText),
                      (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
                      let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                      calendar.component(.year, from: date) == year,
                      calendar.component(.month, from: date) == month,
                      calendar.component(.day, from: date) == day else { invalid = true; continue }
                dates.append(date)
            }
        }
        return (dates, mentioned, invalid)
    }

    private static func integer(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零":0, "〇":0, "一":1, "二":2, "两":2, "三":3, "四":4, "五":5, "六":6, "七":7, "八":8, "九":9]
        if text.contains("十") {
            let parts = text.components(separatedBy: "十")
            guard parts.count == 2, parts.allSatisfy({ $0.count <= 1 }) else { return nil }
            let tens = parts[0].isEmpty ? 1 : parts[0].first.flatMap { digits[$0] }
            let ones = parts[1].isEmpty ? 0 : parts[1].first.flatMap { digits[$0] }
            guard let tens, let ones, tens > 0 else { return nil }
            return tens * 10 + ones
        }
        var value = 0
        for character in text {
            guard let digit = digits[character] else { return nil }
            value = value * 10 + digit
        }
        return text.isEmpty ? nil : value
    }
}
