import Foundation
import CryptoKit

struct MealEditorDraft: Codable {
    var id: UUID
    var name: String
    var category: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var components: [FoodComponent]
    var fraction: Double
    var jobID: String?
    var sourceJobID: String?
    var estimateNotes: [String]
    var photoAttached: Bool? = nil
    var updatedAt: Date? = nil
    var createdAt: Date? = nil
    var mealDescription: String? = nil
    var textEntry: Bool? = nil
    var multipleMeals: Bool? = nil
    var previousRecognitionJobID: String? = nil
}

struct MealDraftChoice: Identifiable {
    let draft: MealEditorDraft
    let file: URL
    var id: String { file.lastPathComponent }
}

enum MealDraftLibrary {
    static func choices(in folder: URL, dateKey: String, category: String) throws -> [MealDraftChoice] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])
        return files.compactMap { file -> MealDraftChoice? in
            guard file.pathExtension == "json", file.lastPathComponent == dateKey + ".json" || file.lastPathComponent.hasPrefix(dateKey + "-") else { return nil }
            guard let data = try? Data(contentsOf: file), var draft = try? JSONDecoder().decode(MealEditorDraft.self, from: data) else { return nil }
            let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            draft.createdAt = draft.createdAt ?? values?.creationDate ?? draft.updatedAt ?? values?.contentModificationDate
            return MealDraftChoice(draft: draft, file: file)
        }.sorted {
            let left = $0.draft.category == category, right = $1.draft.category == category
            if left != right { return left }
            let a = $0.draft.updatedAt ?? $0.draft.createdAt ?? .distantPast
            let b = $1.draft.updatedAt ?? $1.draft.createdAt ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }
    }

    // Keep the discarded JSON as a local tombstone, so failed AI persistence cannot revive it.
    static func remove(_ choice: MealDraftChoice, in folder: URL) throws {
        let file = choice.file.standardizedFileURL
        guard file.deletingLastPathComponent() == folder.standardizedFileURL, file.pathExtension == "json" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
        let tombstone = file.deletingPathExtension().appendingPathExtension("discarded")
        // An older tombstone remains valid; a new unique name avoids overwriting it.
        let destination = FileManager.default.fileExists(atPath: tombstone.path)
            ? folder.appendingPathComponent(UUID().uuidString + ".discarded") : tombstone
        try FileManager.default.moveItem(at: file, to: destination)
        try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("jpg"))
    }

    static func abandonedJobIDs(in folder: URL) -> Set<String> {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var live = Set<String>(), discarded = Set<String>()
        for file in files where ["json", "discarded"].contains(file.pathExtension) {
            guard let data = try? Data(contentsOf: file), let draft = try? JSONDecoder().decode(MealEditorDraft.self, from: data) else { return [] }
            let jobs = [draft.jobID, draft.sourceJobID, draft.previousRecognitionJobID].compactMap { $0 }
            if file.pathExtension == "json" { live.formUnion(jobs) } else { discarded.formUnion(jobs) }
        }
        return discarded.subtracting(live)
    }
}

enum MealCategorySuggestion {
    static let categories = ["早餐", "午餐", "晚餐", "加餐"]
    static func recommended(for date: Date, now: Date = Date(), meals: [Meal], calendar: Calendar = ClubDates.calendar) -> String {
        guard calendar.isDate(date, inSameDayAs: now) else {
            return categories.first { category in !meals.contains { $0.category == category } } ?? "加餐"
        }
        let hour = calendar.component(.hour, from: now)
        let category: String
        switch hour {
        case 5..<10: category = "早餐"
        case 10..<15: category = "午餐"
        case 17..<22: category = "晚餐"
        default: category = "加餐"
        }
        return category != "加餐" && meals.contains { $0.category == category } ? "加餐" : category
    }
}

enum CalendarWindow {
    static func dates(centeredOn date: Date, calendar: Calendar = ClubDates.calendar) -> [Date] {
        let center = calendar.startOfDay(for: date)
        return (-3...3).compactMap { calendar.date(byAdding: .day, value: $0, to: center) }
    }
}

enum ClubGuideProgress {
    private static func key(_ id: Int, _ field: String) -> String { "boji.usage-guide.v2.\(id).\(field)" }
    static func shouldShow(_ id: Int, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey:key(id,"completed")), !defaults.bool(forKey:key(id,"muted")) else { return false }
        if let snoozed = defaults.object(forKey:key(id,"snoozed")) as? Date, ClubDates.calendar.isDate(snoozed,inSameDayAs:now) { return false }
        return true
    }
    static func complete(_ id: Int) { UserDefaults.standard.set(true,forKey:key(id,"completed")) }
    static func postpone(_ id: Int) { UserDefaults.standard.set(Date(),forKey:key(id,"snoozed")) }
    static func mute(_ id: Int) { UserDefaults.standard.set(true,forKey:key(id,"muted")) }
}

enum ShareTextPages {
    static func split(_ text: String, fits: (String) -> Bool) -> [String] {
        guard !text.isEmpty else { return [""] }
        let characters=Array(text)
        var pages: [String]=[];var start=0
        while start < characters.count {
            var low=start+1;var high=min(characters.count,start+2000);var end=low
            while low <= high {
                let mid=(low+high)/2
                if fits(String(characters[start..<mid])) { end=mid;low=mid+1 } else { high=mid-1 }
            }
            if end < characters.count {
                let floor=start+max(1,(end-start)*3/4)
                if let boundary=(floor..<end).last(where:{["\n","。","！","？"," "].contains(characters[$0])}) { end=boundary+1 }
            }
            pages.append(String(characters[start..<end]));start=end
        }
        return pages
    }
}

struct ReportShareSection: Equatable {
    let title: String
    let text: String
}

struct ClubArtworkRevision: Decodable, Equatable {
    let version: String?
    let fullSHA256: String?
    let thumbnailSHA256: String?
    enum CodingKeys: String, CodingKey {
        case version = "image_version", fullSHA256 = "image_sha256", thumbnailSHA256 = "thumbnail_sha256"
    }
    var cacheIdentity: String { version ?? [fullSHA256 ?? "", thumbnailSHA256 ?? ""].joined(separator: ":") }
    static func validHash(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
    func accepts(_ checksum: String, thumbnail: Bool) -> Bool {
        let expected = thumbnail ? thumbnailSHA256 : fullSHA256
        return Self.validHash(version) && Self.validHash(expected) && checksum == expected
    }
}

enum ReportShareContent {
    // Bound text measurement to logarithmic work even for a very long report.
    // Character boundaries preserve Chinese and composed emoji in the preview.
    static func summary(_ value: String, fits: (String) -> Bool) -> String {
        let original = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if original.isEmpty || fits(original) { return original }
        guard fits("…") else { return "" }
        let characters = Array(original)
        var low = 0, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(characters.prefix(middle)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            if fits(candidate) { low = middle } else { high = middle - 1 }
        }
        return String(characters.prefix(low)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
    static func sections(summary: String?, training: String?, nutrition: String?, recovery: String?, facts: [String] = [], planReason: String? = nil) -> [ReportShareSection] {
        func present(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        var overview = [present(summary)].compactMap { $0 } + facts.filter { !$0.isEmpty }
        if let reason = present(planReason) { overview.append("计划结论：" + reason) }
        if let recovery = present(recovery) {
            // A clearly labelled excerpt; the complete recovery text remains in its own section.
            let first = recovery.split(whereSeparator: { "。！？\n".contains($0) }).first.map(String.init) ?? recovery
            overview.append("下一步摘录：" + String(first.prefix(200)) + (first.count > 200 ? "…" : ""))
        }
        var sections: [ReportShareSection] = []
        if !overview.isEmpty { sections.append(.init(title: "结论与记录", text: overview.joined(separator: "\n\n"))) }
        if let text = present(training) { sections.append(.init(title: "训练分析", text: text)) }
        let food = [present(nutrition).map { "饮食\n" + $0 }, present(recovery).map { "恢复与下一步\n" + $0 }].compactMap { $0 }
        if !food.isEmpty { sections.append(.init(title: "饮食与恢复", text: food.joined(separator: "\n\n"))) }
        return sections
    }

    static func pages(_ sections: [ReportShareSection], fits: (String) -> Bool) -> [ReportShareSection] {
        sections.flatMap { section in
            ShareTextPages.split(section.text, fits: fits).enumerated().map { index, text in
                ReportShareSection(title: section.title + (index == 0 ? "" : " · 续"), text: text)
            }
        }
    }
}

enum ExerciseMeasurement {
    // Generated from the reviewed catalog; exact queries override keyword guesses.
    private static let catalogUnits: [String: Bool] = ["pull-up": false, "wide grip pull-up": false, "chin-up": false, "pull up (neutral grip)": false, "chin-ups (narrow parallel grip)": false, "assisted pull-up": false, "assisted parallel close grip pull-up": false, "band assisted pull-up": false, "weighted pull-up": false, "inverted row": false, "inverted row bent knees": false, "suspended row": false, "scapular pull-up": false, "barbell bent over row": false, "barbell reverse grip bent over row": false, "barbell pendlay row": false, "barbell rack pull": false, "dumbbell bent over row": false, "dumbbell one arm bent-over row": false, "dumbbell incline row": false, "dumbbell incline y-raise": false, "cable bar lateral pulldown": false, "cable lateral pulldown with v-bar": false, "cable underhand pulldown": false, "twin handle parallel grip lat pulldown": false, "cable one arm pulldown": false, "cable straight arm pulldown": false, "cable straight arm pulldown (with rope)": false, "cable seated row": false, "cable seated wide-grip row": false, "cable seated one arm alternate row": false, "cable one arm bent over row": false, "lever front pulldown": false, "lever high row": false, "lever narrow grip seated row": false, "lever seated row": false, "lever unilateral row": false, "lever t bar row": false, "lever bent-over row with v-bar": false, "smith bent over row": false, "smith reverse grip bent over row": false, "kettlebell one arm row": false, "kettlebell two arm row": false, "resistance band seated straight back row": false, "band close-grip pulldown": false, "band kneeling one arm pulldown": false, "hyperextension": false, "lever back extension": false, "kneeling lat stretch": true, "upper back stretch": true, "barbell full squat": false, "barbell high bar squat": false, "barbell low bar squat": false, "barbell front squat": false, "barbell bench squat": false, "barbell lunge": false, "barbell rear lunge": false, "barbell single leg split squat": false, "barbell step-up": false, "dumbbell goblet squat": false, "dumbbell squat": false, "dumbbell lunge": false, "dumbbell rear lunge": false, "dumbbell single leg split squat": false, "dumbbell step-up": false, "kettlebell goblet squat": false, "kettlebell front squat": false, "split squats": false, "forward lunge (male)": false, "walking lunge": false, "curtsey squat": false, "jump squat": false, "lunge with jump": false, "single leg squat (pistol) male": false, "band squat": false, "band single leg split squat": false, "smith squat": false, "smith front squat (clean grip)": false, "smith chair squat": false, "smith single leg split squat": false, "smith sumo squat": false, "sled hack squat": false, "sled 45в° leg press": false, "sled 45в° leg wide press": false, "sled 45 degrees one leg press": false, "lever leg extension": false, "resistance band leg extension": false, "lever lying leg curl": false, "lever seated leg curl": false, "lever kneeling leg curl": false, "dumbbell lying femoral": false, "glute-ham raise": false, "inverse leg curl (bench support)": false, "self assisted inverse leg curl (on floor)": false, "lever seated hip adduction": false, "cable hip adduction": false, "side lying hip adduction (male)": false, "hamstring stretch": true, "lying (side) quads stretch": true, "butterfly yoga pose": true, "world greatest stretch": false, "leg up hamstring stretch": true, "crunch floor": false, "sit-up v. 2": false, "decline sit-up": false, "crunch (on stability ball)": false, "cross body crunch": false, "oblique crunches floor": false, "alternate heel touchers": false, "air bike": false, "reverse crunch": false, "tuck crunch": false, "jackknife sit-up": false, "flutter kicks": false, "assisted hanging knee raise": false, "hanging straight leg raise": false, "hanging oblique knee raise": false, "captains chair straight leg raise": false, "lying leg raise flat bench": false, "lying leg-hip raise": false, "seated leg raise": false, "dead bug": false, "russian twist": false, "weighted russian twist": false, "weighted russian twist (legs up)": false, "weighted crunch": false, "weighted front plank": true, "front plank with twist": false, "shoulder tap": false, "kneeling plank tap shoulder (male)": false, "side bridge v. 2": true, "reverse plank with leg lift": false, "wheel rollerout": false, "pull-in (on stability ball)": false, "suspended reverse crunch": false, "suspended abdominal fallout": false, "cable kneeling crunch": false, "cable twist (up-down)": false, "cable standing lift": false, "cable twist": false, "band horizontal pallof press": false, "band standing crunch": false, "dumbbell side bend": false, "lever seated crunch": false, "pelvic tilt": false, "inchworm": false, "dumbbell standing overhead press": false, "dumbbell seated shoulder press": false, "dumbbell seated shoulder press (parallel grip)": false, "dumbbell standing palms in press": false, "dumbbell one arm shoulder press": false, "dumbbell arnold press": false, "dumbbell push press": false, "dumbbell lateral raise": false, "dumbbell seated lateral raise": false, "dumbbell one arm lateral raise with support": false, "dumbbell front raise": false, "dumbbell seated front raise": false, "dumbbell reverse fly": false, "dumbbell incline rear lateral raise": false, "dumbbell rear delt row_shoulder": false, "dumbbell upright row": false, "dumbbell lying external shoulder rotation": false, "dumbbell upright shoulder external rotation": false, "barbell seated overhead press": false, "barbell standing close grip military press": false, "barbell wide-grip upright row": false, "cable lateral raise": false, "cable one arm lateral raise": false, "cable front raise": false, "cable cross-over revers fly": false, "cable rear delt row (with rope)": false, "cable standing shoulder external rotation": false, "cable upright row": false, "lever shoulder press": false, "lever lateral raise": false, "lever seated reverse fly": false, "lever seated reverse fly (parallel grip)": false, "smith seated shoulder press": false, "smith standing military press": false, "band shoulder press": false, "band front raise": false, "band reverse fly": false, "band y-raise": false, "kettlebell two arm military press": false, "kettlebell seated press": false, "rear deltoid stretch": true, "neck side stretch": true, "barbell curl": false, "barbell reverse curl": false, "barbell preacher curl": false, "ez barbell curl": false, "ez barbell reverse grip curl": false, "ez barbell spider curl": false, "dumbbell biceps curl": false, "dumbbell alternate biceps curl": false, "dumbbell hammer curl": false, "dumbbell cross body hammer curl": false, "dumbbell concentration curl": false, "dumbbell incline biceps curl": false, "dumbbell incline hammer curl": false, "dumbbell seated curl": false, "dumbbell seated hammer curl": false, "dumbbell preacher curl": false, "dumbbell zottman curl": false, "cable curl": false, "cable hammer curl (with rope)": false, "cable one arm curl": false, "cable preacher curl": false, "cable reverse curl": false, "lever bicep curl": false, "lever preacher curl": false, "band alternating biceps curl": false, "barbell close-grip bench press": false, "barbell lying triceps extension skull crusher": false, "barbell seated overhead triceps extension": false, "ez barbell seated triceps extension": false, "dumbbell lying triceps extension": false, "dumbbell standing triceps extension": false, "dumbbell seated bench extension": false, "dumbbell kickback": false, "cable pushdown": false, "cable pushdown (with rope attachment)": false, "cable triceps pushdown (v-bar)": false, "cable reverse-grip pushdown": false, "cable one arm tricep pushdown": false, "cable overhead triceps extension (rope attachment)": false, "lever triceps extension": false, "lever seated dip": false, "smith close-grip bench press": false, "triceps dip": false, "assisted triceps dip (kneeling)": false, "weighted tricep dips": false, "bench dip (knees bent)": false, "diamond push-up": false, "close-grip push-up (on knees)": false, "close-grip push-up": false, "barbell wrist curl": false, "barbell reverse wrist curl": false, "dumbbell over bench wrist curl": false, "cable wrist curl": false, "wrist rollerer": false, "overhead triceps stretch": true, "side wrist pull stretch": true, "wrist circles": false, "barbell deadlift": false, "barbell romanian deadlift": false, "barbell sumo deadlift": false, "barbell straight leg deadlift": false, "barbell single leg deadlift": false, "barbell good morning": false, "barbell glute bridge": false, "barbell shrug": false, "dumbbell deadlift": false, "dumbbell romanian deadlift": false, "dumbbell single leg deadlift": false, "low glute bridge on floor": false, "single leg bridge with outstretched leg": false, "glute bridge march": false, "glute bridge two legs on bench (male)": false, "reverse hyper on flat bench": false, "lever reverse hyperextension": false, "lever seated hip abduction": false, "lever hip extension v. 2": false, "cable standing hip extension": false, "cable pull through (with rope)": false, "resistance band seated hip abduction": false, "band bent-over hip extension": false, "band hip lift": false, "monster walk": false, "side hip abduction": false, "side bridge hip abduction": false, "kettlebell swing": false, "trap bar deadlift": false, "smith deadlift": false, "seated glute stretch": true, "seated piriformis stretch": true, "rocking frog stretch": true, "barbell bench press": false, "barbell incline bench press": false, "barbell decline bench press": false, "dumbbell bench press": false, "dumbbell incline bench press": false, "dumbbell decline bench press": false, "dumbbell lying hammer press": false, "dumbbell incline hammer press": false, "dumbbell fly": false, "dumbbell incline fly": false, "dumbbell pullover": false, "push-up": false, "kneeling push-up (male)": false, "push-up (wall)": false, "incline push-up": false, "decline push-up": false, "wide hand push up": false, "scapula push-up": false, "clap push up": false, "suspended push-up": false, "chest dip": false, "assisted chest dip (kneeling)": false, "cable middle fly": false, "cable low fly": false, "cable decline fly": false, "cable incline fly": false, "cable seated chest press": false, "lever chest press": false, "lever incline chest press": false, "lever decline chest press": false, "lever seated fly": false, "smith bench press": false, "smith incline bench press": false, "smith decline bench press": false, "band bench press": false, "resistance band seated chest press": false, "weighted svend press": false, "chest and front of shoulder stretch": true, "dynamic chest stretch (male)": false, "bodyweight standing calf raise": false, "one leg floor calf raise": false, "standing calf raise (on a staircase)": false, "dumbbell standing calf raise": false, "dumbbell single leg calf raise": false, "dumbbell seated calf raise": false, "barbell standing calf raise": false, "lever standing calf raise": false, "lever seated calf raise": false, "sled 45в° calf press": false, "sled one leg calf press on leg press": false, "smith standing leg calf raise": false, "band single leg calf raise": false, "calf stretch with hands against wall": true, "seated calf stretch (male)": true, "ankle circles": false, "run": true, "run (equipment)": true, "walking on incline treadmill": true, "walk elliptical cross trainer": true, "stationary bike run v. 3": true, "walking on stepmill": true, "jump rope": true, "burpee": true, "mountain climber": true, "jack jump (male)": true, "skater hops": true, "bear crawl": true, "battling ropes": true, "farmers walk": true, "medicine ball overhead slam": false, "barbell thruster": false, "kettlebell thruster": false, "alternate lateral pulldown": false, "assisted standing chin-up": false, "back extension on exercise ball": false, "band one arm standing low row": false, "band one arm twisting seated row": false, "barbell bent arm pullover": false, "barbell incline row": false, "barbell pullover": false, "barbell reverse grip incline bench row": false, "cable floor seated wide-grip row": false, "cable high row (kneeling)": false, "cable incline bench row": false, "cable lateral pulldown (with rope attachment)": false, "cable lying extension pullover (with rope attachment)": false, "cable one arm straight back high row (kneeling)": false, "cable reverse-grip straight back seated high row": false, "cable rope seated row": false, "cable shrug": false, "cable squat row (with rope attachment)": false, "cable standing row (v-bar)": false, "close grip chin-up": false, "dumbbell incline shrug": false, "dumbbell lying rear delt row": false, "dumbbell palm rotational bent over row": false, "dumbbell reverse grip incline bench two arm row": false, "exercise ball lat stretch": true, "ez bar lying bent arms pullover": false, "hyperextension (on bench)": false, "inverted row with straps": false, "kettlebell alternating renegade row": false, "kettlebell alternating row": false, "lever alternating narrow grip seated row": false, "lever one arm lateral high row": false, "lever one arm lateral wide pulldown": false, "lever pullover": false, "lever reverse grip lateral pulldown": false, "lever reverse grip vertical row": false, "lever t-bar reverse grip row": false, "lever shrug": false, "roller back stretch": true, "seated lower back stretch": true, "smith narrow row": false, "smith one arm row": false, "smith shrug": false, "sphinx": false, "standing lateral stretch": true, "upward facing dog": true, "archer push up": false, "band one arm twisting chest press": false, "barbell wide bench press": false, "cable bench press": false, "cable decline press": false, "cable incline bench press": false, "cable lying fly": false, "cable one arm incline press": false, "chest stretch with exercise ball": true, "deep push up": false, "drop push up": false, "dumbbell decline fly": false, "dumbbell decline hammer press": false, "dumbbell incline alternate press": false, "dumbbell incline one arm press": false, "incline scapula push up": false, "isometric chest squeeze": true, "kettlebell alternating press on floor": false, "kettlebell one arm floor press": false, "medicine ball chest pass": false, "plyo push up": false, "push-up medicine ball": false, "push-up plus": false, "shoulder tap push-up": false, "smith reverse-grip press": false, "band reverse wrist curl": false, "band wrist curl": false, "barbell standing back wrist curl": false, "cable reverse wrist curl": false, "dumbbell finger curls": false, "dumbbell one arm reverse wrist curl": false, "dumbbell one arm seated neutral wrist curl": false, "dumbbell one arm wrist curl": false, "dumbbell seated one arm rotate": false, "finger curls": false, "lever gripper hands": false, "band close-grip push-up": false, "band concentration curl": false, "band side triceps extension": false, "barbell drag curl": false, "barbell incline close grip bench press": false, "barbell pin presses": false, "barbell prone incline curl": false, "barbell reverse preacher curl": false, "barbell standing close grip curl": false, "barbell standing wide-grip curl": false, "bodyweight kneeling triceps extension": false, "cable close grip curl": false, "cable concentration curl": false, "cable drag curl": false, "cable high pulley overhead tricep extension": false, "cable incline triceps extension": false, "cable kickback": false, "cable lying bicep curl": false, "cable one arm preacher curl": false, "cable overhead curl": false, "cable reverse one arm curl": false, "cable reverse preacher curl": false, "cable rope hammer preacher curl": false, "cable rope high pulley overhead tricep extension": false, "cable rope lying on floor tricep extension": false, "cable seated curl": false, "cable two arm tricep kickback": false, "dumbbell incline triceps extension": false, "dumbbell lying alternate extension": false, "dumbbell lying one arm pronated triceps extension": false, "dumbbell one arm hammer preacher curl": false, "dumbbell one arm seated hammer curl": false, "dumbbell prone incline hammer curl": false, "dumbbell reverse preacher curl": false, "dumbbell seated one arm kickback": false, "dumbbell standing one arm reverse curl": false, "dumbbell waiter biceps curl": false, "ez bar lying close grip triceps extension behind head": false, "ez bar standing french press": false, "ez barbell close-grip curl": false, "ez barbell decline triceps extension": false, "ez barbell incline triceps extension": false, "ez barbell reverse grip preacher curl": false, "ez barbell seated curls": false, "ez-barbell standing wide grip biceps curl": false, "incline close-grip push-up": false, "lever hammer grip preacher curl": false, "push-up close-grip off dumbbell": false, "resistance band seated biceps curl": false, "ring dips": false, "side push-up": false, "triceps dip (bench leg)": false, "triceps dips floor": false, "weighted bench dip": false, "band standing rear delt row": false, "barbell front raise": false, "barbell rear delt row": false, "barbell upright row": false, "cable rear delt row (stirrups)": false, "cable seated rear lateral raise": false, "cable seated shoulder internal rotation": false, "cable shoulder press": false, "cable standing cross-over high reverse fly": false, "cable standing rear delt row (with rope)": false, "dumbbell cuban press": false, "dumbbell incline one arm lateral raise": false, "dumbbell one arm lateral raise": false, "dumbbell one arm reverse fly (with support)": false, "dumbbell seated alternate front raise": false, "dumbbell seated alternate press": false, "dumbbell seated bent arm lateral raise": false, "dumbbell single arm overhead carry": false, "dumbbell standing alternate overhead press": false, "kettlebell alternating press": false, "kettlebell double push press": false, "kettlebell one arm clean and jerk": false, "kettlebell one arm push press": false, "kettlebell one arm snatch": false, "kettlebell two arm clean": false, "landmine lateral raise": false, "lever one arm shoulder press": false, "resistance band seated shoulder press": false, "smith rear delt row": false, "smith upright row": false, "weighted front raise": false, "band single leg reverse calf raise": false, "barbell seated calf raise": false, "cable standing calf raise": false, "cable standing one leg calf raise": false, "calf push stretch with hands against wall": true, "calf stretch with rope": true, "donkey calf raise": false, "dumbbell seated one leg calf raise": false, "hack calf raise": false, "hack one leg calf raise": false, "lever donkey calf raise": false, "smith one leg floor calf raise": false, "smith reverse calf raises": false, "smith toe raise": false, "weighted donkey calf raise": false, "all fours squad stretch": true, "assisted prone hamstring": true, "assisted prone lying quads stretch": true, "assisted side lying adductor stretch": true, "barbell bench front squat": false, "barbell lateral lunge": false, "barbell narrow stance squat": false, "barbell overhead squat": false, "barbell side split squat": false, "barbell wide squat": false, "chair leg extended stretch": true, "dumbbell bench squat": false, "dumbbell contralateral forward lunge": false, "dumbbell single leg deadlift with stepbox support": false, "dumbbell single leg squat": false, "dumbbell step-up lunge": false, "dumbbell supported squat": false, "exercise ball seated hamstring stretch": true, "inverse leg curl (on pull-up cable machine)": false, "lever lying two-one leg curl": false, "potty squat with support": false, "reclining big toe pose with rope": true, "runners stretch": true, "seated wide angle pose sequence": true, "single leg platform slide": false, "sissy squat": false, "sled closer hack squat": false, "sled lying squat": false, "smith hack squat": false, "smith low bar squat": false, "squat on bosu ball": false, "standing hamstring and calf stretch with strap": true, "standing single leg curl": false, "suspended split squat": false, "assisted lying glutes stretch": true, "assisted lying gluteus and piriformis stretch": true, "band lying hip internal rotation": false, "band pull through": false, "band step-up": false, "band stiff leg deadlift": false, "hug keens to chest": true, "iron cross stretch": true, "lever deadlift": false, "lever horizontal one leg press": false, "lever seated good morning": false, "pelvic tilt into bridge": false, "resistance band hip thrusts on knees (female)": false, "reverse hyper extension (on stability ball)": false, "roller hip stretch": true, "smith hip raise": false, "straight leg outer hip abductor": false, "3/4 sit-up": false, "45° side bend": false, "arm slingers hanging bent knee legs": false, "arm slingers hanging straight legs": false, "assisted sit-up": false, "band alternating v-up": false, "band assisted wheel rollerout": false, "band bicycle crunch": false, "band kneeling twisting crunch": false, "band lying straight leg raise": false, "band seated twist": false, "band standing twisting crunch": false, "band vertical pallof press": false, "barbell rollerout": false, "barbell seated twist": false, "barbell sitted alternate leg raise": false, "bodyweight incline side plank": true, "cable reverse crunch": false, "cable seated crunch": false, "cable seated twist": false, "cable side bend": false, "cable side crunch": false, "cable standing crunch": false, "cable standing crunch (with rope attachment)": false, "cable tuck reverse crunch": false, "cocoons": false, "crab twist toe touch": false, "crunch (hands overhead)": false, "crunch (on stability ball, arms straight)": false, "decline crunch": false, "elbow-to-knee": false, "frog crunch": false, "half sit-up (male)": false, "hanging leg hip raise": false, "hanging straight leg hip raise": false, "hanging straight twisting leg hip raise": false, "incline leg hip raise (leg straight)": false, "incline twisting sit-up": false, "kettlebell figure 8": false, "kettlebell windmill": false, "knee touch crunch": false, "landmine 180": false, "leg pull in flat bench": false, "lever kneeling twist": false, "lever seated crunch (chest pad)": false, "lever seated leg raise crunch": false, "lunge with twist": false, "negative crunch": false, "otis up": false, "posterior step to overhead reach": false, "push-up to side plank": false, "roller body saw": false, "seated side crunch (wall)": false, "side-to-side toe touch (male)": false, "sit-up with arms on chest": false, "spine twist": false, "twisted leg raise": false, "vertical leg raise (on parallel bars)": false, "weighted decline sit-up": false, "weighted hanging leg-hip raise": false, "astride jumps (male)": true, "back and forth step": true, "dumbbell burpee": true, "high knee against wall": true, "jack burpee": true, "push to run": true, "scissor jumps (male)": true, "semi squat jump (male)": true, "short stride run": true, "ski step": true, "star jump (male)": true, "walking high knees lunge": true, "hands bike": true, "ski ergometer": true, "quick feet v. 2": true, "wind sprints": true, "forward jump": false, "medicine ball catch and overhead throw": false, "one arm slam (with medicine ball)": false, "sledge hammer": false, "tire flip": false, "brisk walking": true, "outdoor cycling": true, "rowing machine": true, "freestyle swimming": true, "breaststroke swimming": true, "stair climbing": true, "marching in place": true, "aerobic dance": true, "low impact step jack": true, "bodyweight squat": false, "forearm plank": true, "bird dog": false, "wall sit": true, "跪姿背阔肌拉伸": true, "上背部拉伸": true, "腘绳肌拉伸": true, "侧卧股四头肌拉伸": true, "蝴蝶式内收肌拉伸": true, "仰卧抬腿腘绳肌拉伸": true, "负重平板支撑": true, "侧桥": true, "肩后侧拉伸": true, "颈侧拉伸": true, "肱三头肌过顶拉伸": true, "手腕拉伸": true, "坐姿臀部拉伸": true, "坐姿梨状肌拉伸": true, "青蛙式拉伸": true, "胸肌与肩前侧拉伸": true, "靠墙小腿拉伸": true, "坐姿小腿拉伸": true, "跑步": true, "跑步机跑步": true, "跑步机爬坡走": true, "椭圆机": true, "固定单车骑行": true, "楼梯机": true, "跳绳": true, "波比跳": true, "登山跑": true, "开合跳": true, "滑冰跳": true, "熊爬": true, "战绳": true, "农夫行走": true, "健身球背阔肌拉伸": true, "泡沫轴背部放松": true, "坐姿下背部拉伸": true, "站姿侧屈拉伸": true, "上犬式伸展": true, "健身球胸肌拉伸": true, "胸前等长挤压": true, "屈膝扶墙小腿拉伸": true, "拉伸带小腿拉伸": true, "四足跪姿股四头肌拉伸": true, "辅助俯卧大腿后侧拉伸": true, "辅助俯卧股四头肌拉伸": true, "辅助侧卧大腿内侧拉伸": true, "坐姿伸腿拉伸": true, "健身球坐姿大腿后侧拉伸": true, "仰卧拉伸带大腿后侧拉伸": true, "跑者弓步拉伸": true, "坐姿宽距前屈伸展": true, "拉伸带站姿大腿后侧与小腿拉伸": true, "辅助仰卧臀部拉伸": true, "辅助仰卧梨状肌拉伸": true, "仰卧抱膝拉伸": true, "仰卧交叉转体拉伸": true, "泡沫轴臀部放松": true, "上斜侧平板支撑": true, "跨步开合跳": true, "前后踏步": true, "哑铃波比跳": true, "靠墙高抬腿": true, "开合波比跳": true, "前倾加速跑": true, "剪刀跳": true, "半蹲跳": true, "小步跑": true, "滑雪步": true, "星形跳": true, "行走高抬腿弓步": true, "手摇功率车": true, "滑雪机": true, "原地快速碎步": true, "原地冲刺跑": true, "快走": true, "户外骑行": true, "划船机": true, "自由泳": true, "蛙泳": true, "爬楼梯": true, "原地踏步": true, "健身操": true, "低冲击开合步": true, "前臂平板支撑": true, "靠墙静蹲": true]
    private static let aerobicQueries: Set<String> = ["run", "run (equipment)", "walking on incline treadmill", "walk elliptical cross trainer", "stationary bike run v. 3", "walking on stepmill", "jump rope", "back and forth step", "short stride run", "hands bike", "ski ergometer", "brisk walking", "outdoor cycling", "rowing machine", "freestyle swimming", "breaststroke swimming", "stair climbing", "marching in place", "aerobic dance", "low impact step jack"]
    // Conservative defaults; dynamic variants override static-hold keywords.
    static func usesSeconds(name: String, query: String? = nil) -> Bool {
        let exactQuery = (query ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = catalogUnits[exactQuery] { return seconds }
        if let seconds = catalogUnits[name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)] { return seconds }
        let raw = [name, query ?? ""].joined(separator: " ").lowercased()
        let candidates = [name, query ?? ""].map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        if candidates.contains("side bridge v. 2") || candidates.contains("侧桥") { return true }
        let countedVariants: Set<String> = ["isometric wipers", "power point plank", "dynamic chest stretch (male)", "circles knee stretch", "rocking frog stretch", "world greatest stretch", "weighted stretch lunge"]
        if candidates.contains(where: { countedVariants.contains($0) }) { return false }
        let timedCardio: Set<String> = ["run", "run (equipment)", "short stride run", "hands bike", "farmers walk", "walking on stepmill", "跑步", "慢跑", "农夫行走", "农夫走", "登楼机"]
        if candidates.contains(where: { timedCardio.contains($0) }) { return true }
        let dynamic = ["plank jack", "plank to", "plank up", "plank with", "plank leg", "plank knee", "plank twist", "plank reach", "plank shoulder", "plank hip", "side plank dip", "side plank rotation", "side plank raise", "to plank", "平板开合", "平板支撑转", "平板支撑交替", "平板支撑抬", "平板支撑提", "平板支撑摸", "平板支撑点", "平板支撑登", "侧平板抬", "侧平板提", "侧平板转", "侧平板下沉"]
        if dynamic.contains(where: { raw.contains($0) }) || raw.contains("plank tap") || raw.contains("to side plank") { return false }
        let timed = ["plank", "wall sit", "dead hang", "isometric", "static hold", "stretch", "treadmill", "stationary bike", "elliptical", "rowing machine", "jump rope", "battle rope", "平板支撑", "侧支撑", "靠墙静蹲", "静态", "悬垂保持", "拉伸", "跑步机", "动感单车", "椭圆机", "划船机", "跳绳", "战绳"]
        return timed.contains { token in
            if token.unicodeScalars.allSatisfy({ $0.isASCII }) {
                let pattern = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: token) + "(?![a-z])"
                return raw.range(of: pattern, options: .regularExpression) != nil
            }
            return raw.contains(token)
        }
    }
    static func blankSet(name: String, query: String? = nil) -> TrainingSet {
        usesSeconds(name: name, query: query) ? TrainingSet(reps: 0, durationSeconds: 30) : TrainingSet()
    }
    static func initialSets(name: String, query: String? = nil, recordingUnit: String? = nil, trainingType: String? = nil) -> [TrainingSet] {
        let exactQuery = (query ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if recordingUnit != "reps" && (trainingType == "有氧" || aerobicQueries.contains(exactQuery)) { return [TrainingSet(reps: 0, durationSeconds: 600)] }
        if recordingUnit == "time" { return (0..<3).map { _ in TrainingSet(reps: 0, durationSeconds: 30) } }
        if recordingUnit == "reps" { return (0..<3).map { _ in TrainingSet() } }
        return (0..<3).map { _ in blankSet(name: name, query: query) }
    }
    static func planReplacementSets(count: Int, name: String, query: String? = nil, recordingUnit: String? = nil, trainingType: String? = nil) -> [AIPlanSet] {
        let defaults = initialSets(name: name, query: query, recordingUnit: recordingUnit, trainingType: trainingType)
        let target = defaults.first ?? TrainingSet()
        return (0..<max(1, count)).map { _ in
            AIPlanSet(weight: nil, reps: target.reps, durationSeconds: target.durationSeconds)
        }
    }
    // Imported/AI records retain their explicit units until the user replaces an action.
}

struct BodyWeightEntry: Codable, Equatable {
    var kilograms: Double?
    var updatedAt: Date
    var id: UUID? = nil
    var externalSampleID: String? = nil
    var sourceBundle: String? = nil
    /// F06：同一测量记录可带可选体脂率与腰围；来源与采样时间明确，
    /// 不与 Apple 健康或资料值混用，也不把缺失值补成 0。
    var bodyFatPercentage: Double? = nil
    var waistCircumferenceCM: Double? = nil
    var recordedAt: Date? = nil
    var source: String? = nil
    private var fatValid: Bool { bodyFatPercentage.map { $0.isFinite && (0...70).contains($0) } ?? true }
    private var waistValid: Bool { waistCircumferenceCM.map { $0.isFinite && (30...300).contains($0) } ?? true }
    var isValid: Bool { (kilograms.map { $0.isFinite && (20...400).contains($0) } ?? true) && fatValid && waistValid }
    /// A valid weight observation is distinct from a waist/body-fat observation.
    var measuredKilograms: Double? { isValid ? kilograms : nil }
    var hasWeightMeasurement: Bool { measuredKilograms != nil }
    /// 删除体重会留下 kilograms == nil 的墓碑记录；只有任一实际测量存在才算记录。
    var hasMeasurement: Bool {
        isValid && (kilograms != nil || bodyFatPercentage != nil || waistCircumferenceCM != nil)
    }
}

struct BodyWeightPoint: Identifiable {
    let date: Date
    let kilograms: Double
    var dayKey: String? = nil
    var measurementID: String? = nil
    var id: String { measurementID ?? ClubDates.key(date) }
}

enum BodyWeightHistory {
    static func points(days: [String: DayLog], through date: Date, limit: Int = 30) -> [BodyWeightPoint] {
        let end = ClubDates.key(date)
        return days.keys.sorted().filter { $0 <= end }.flatMap { key -> [BodyWeightPoint] in
            guard let day = days[key], let date = ClubDates.date(fromKey: key) else { return [] }
            let rows = day.bodyMeasurements ?? [day.bodyWeight].compactMap { $0 }
            let deleted = Set(day.deletedBodyMeasurementIDs ?? [])
            return rows.filter { !($0.id.map { deleted.contains($0.uuidString.lowercased()) } ?? false) }.compactMap { row in
                guard let kg = row.measuredKilograms else { return nil }
                return BodyWeightPoint(date: row.recordedAt ?? date, kilograms: kg, dayKey: key, measurementID: (row.id ?? BodyMeasurementIdentity.legacy(row, date: key)).uuidString)
            }
        }.sorted { $0.date < $1.date }.suffix(max(0, limit)).map { $0 }

    }
}

struct MealEntryRequest: Identifiable {
    let id = UUID()
    let date: Date
    var category: String? = nil
}


/// Period-level record facts. Confirmed results and in-progress counts are
/// deliberately separate; pages must choose the labeled meaning explicitly.
struct ReviewMetrics {
    let confirmedTrainingDays, confirmedSets, confirmedRepetitions: Int
    let confirmedTimedSeconds, confirmedElapsedSeconds, weightMeasurements: Int
    let confirmedVolume: Double
    let plannedSets, completedSets, trainingDays, finishedDays, mealDays, meals, healthDays: Int
    let averageCalories, averageProtein: Double?
    let nutritionDays: Int
    var remainingSets: Int { max(0, plannedSets - completedSets) }
    var completionLabel: String {
        guard plannedSets > 0 else { return "—" }
        return "\(Int((Double(completedSets) / Double(plannedSets) * 100).rounded()))%"
    }
    init(logs: [DayLog]) {
        let training = logs.map(\.confirmedTraining)
        confirmedTrainingDays = training.filter(\.hasTraining).count
        confirmedSets = training.reduce(0) { $0 + $1.completedSets }
        confirmedRepetitions = training.reduce(0) { $0 + $1.repetitions }
        confirmedTimedSeconds = training.reduce(0) { $0 + $1.timedSeconds }
        confirmedElapsedSeconds = training.reduce(0) { $0 + $1.elapsedSeconds }
        confirmedVolume = training.reduce(0) { $0 + $1.volume }
        weightMeasurements = logs.filter { $0.bodyWeight?.hasWeightMeasurement == true }.count
        plannedSets = logs.reduce(0) { $0 + $1.totalSets }
        completedSets = logs.reduce(0) { $0 + $1.completedSets }
        trainingDays = logs.filter { $0.completedSets > 0 }.count
        finishedDays = logs.filter { $0.totalSets > 0 && $0.completedSets == $0.totalSets }.count
        let foodDays = logs.filter { !$0.knownMeals.isEmpty }
        nutritionDays=foodDays.count
        mealDays = logs.filter { !$0.meals.isEmpty }.count
        meals = logs.reduce(0) { $0 + $1.meals.count }
        healthDays = logs.filter { $0.health?.hasData == true }.count
        averageCalories = foodDays.isEmpty ? nil : foodDays.reduce(0) { $0 + $1.calories } / Double(foodDays.count)
        averageProtein = foodDays.isEmpty ? nil : foodDays.reduce(0) { $0 + $1.protein } / Double(foodDays.count)
    }
}

enum DailyReportEligibility {
    static func hasRecords(_ log: DayLog) -> Bool {
        log.completedSets > 0 || !log.meals.isEmpty || log.bodyWeight?.hasMeasurement == true || log.health?.hasData == true
    }
    static let missingMessage = "这一天还没有实际记录。先记一餐、完成一组训练、登记体重或确认分享健康数据，再生成复盘。"
}

enum DailyAnalysisReadiness {
    static func warnings(_ log: DayLog) -> [String] {
        var messages: [String] = []
        if !log.exercises.isEmpty {
            if log.completedSets == 0 {
                messages.append("今天安排了训练，但还没有完成记录；本次不会把计划当成已完成训练。")
            } else if log.hasUnconfirmedTraining {
                messages.append("训练还没有点击完成保存。建议先完成本次训练，分析依据会更完整。")
            } else if log.completedSets < log.totalSets {
                messages.append("已保存的训练只完成了部分组数；本次仅分析实际完成的部分。")
            }
        }
        if !log.mealsComplete {
            messages.append(log.meals.isEmpty ? "还没有饮食记录，本次无法评价全天饮食。" : "目前只登记了 \(log.meals.count) 餐，尚未确认全天记录齐全；不会据此判断全天吃多或吃少。")
        }
        if log.unknownNutritionMeals > 0 {
            messages.append("另有 \(log.unknownNutritionMeals) 餐营养数据未知，会作为缺失说明，不能当作零热量。")
        }
        return messages
    }
}

enum ReviewWeek {
    static func key(_ date: Date) -> String {
        ClubDates.key(ClubDates.calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date)
    }
    static func contains(_ dateKey: String, inWeekOf date: Date) -> Bool {
        ClubDates.date(fromKey: dateKey).map { key($0) == key(date) } ?? false
    }
}

struct WorkoutStopwatch: Codable, Equatable {
    private(set) var accumulated: TimeInterval = 0
    private(set) var runningSince: Date?
    var isRunning: Bool { runningSince != nil }
    func elapsed(at now: Date = Date()) -> TimeInterval {
        max(0, accumulated + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0))
    }
    mutating func start(at now: Date = Date()) { if runningSince == nil { runningSince = now } }
    mutating func pause(at now: Date = Date()) { accumulated = elapsed(at: now); runningSince = nil }
}

enum WorkoutTiming {
    // A saved timestamp is not an end time. Backfilled and incomplete timings
    // must not manufacture elapsed time, including invalid clock values.
    static func completedDuration(_ log: DayLog, on date: Date, now: Date = Date()) -> TimeInterval? {
        let training = log.trainingLog
        guard !ClubDates.isFuture(date, now: now), training.completedSets > 0,
              let end = training.workoutEndedAt, end <= now,
              hasRecentStart(training, on: date, now: end),
              let start = training.workoutStartedAt else { return nil }
        let session = log.workoutSessions?.first(where: { $0.id == log.activeWorkoutSessionID })
        let duration = end.timeIntervalSince(start) - (session?.pausedSeconds(through: end) ?? 0)
        return duration.isFinite && duration > 0 ? duration : nil
    }
    static func durationLabel(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0, duration <= 12 * 60 * 60 else { return "未记录" }
        let seconds = max(1, Int(duration.rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "\(seconds) 秒"
    }
    // A recent session can finish after midnight while keeping its starting date.
    static func hasRecentStart(_ log: DayLog, on date: Date, now: Date = Date()) -> Bool {
        guard let start=log.workoutStartedAt, ClubDates.calendar.isDate(start,inSameDayAs:date) else { return false }
        let elapsed=now.timeIntervalSince(start)
        return elapsed >= 0 && elapsed <= 12*60*60
    }
    /// A workout is ongoing only until it has been ended. Saving/ending writes
    /// workoutEndedAt; a later edit invalidates only the confirmation
    /// (workoutSavedAt), so the ended workout must not reappear as ongoing while
    /// its duration remains anchored to the original end time.
    static func isOngoing(_ log: DayLog, on date: Date, now: Date = Date()) -> Bool {
        !log.exercises.isEmpty && log.workoutSavedAt == nil && log.workoutEndedAt == nil
            && hasRecentStart(log,on:date,now:now)
    }
}

/// Resolves which day a workout entry point must open. An in-progress session can
/// have started before midnight, so the persisted session date wins over "today".
enum WorkoutEntryRules {
    static func date(selected: Date, activeDateKey: String?) -> Date {
        guard let activeDateKey, let date = ClubDates.date(fromKey: activeDateKey) else { return selected }
        return date
    }
}

struct ActiveWorkoutSnapshot: Equatable {
    let dateKey: String
    let sessionID: UUID
    let startedAt: Date
    let workoutName: String
    let currentExerciseName: String?
    let currentSetNumber: Int?
    let completedSets: Int
    let totalSets: Int
    let isPaused: Bool
    let accumulatedPaused: TimeInterval
    let elapsed: TimeInterval
    let restEndsAt: Date?
    var progress: Double { totalSets > 0 ? min(1, Double(completedSets) / Double(totalSets)) : 0 }
    func elapsed(at now: Date) -> TimeInterval {
        isPaused ? elapsed : max(0, now.timeIntervalSince(startedAt) - accumulatedPaused)
    }
}

enum ActiveWorkoutRules {
    /// 只从已持久化的记录重建，不依赖内存 Timer。跨午夜训练允许落在昨天。
    static func snapshot(state: SavedState, now: Date = Date(), pause: WorkoutPauseState? = nil,
                         restEndsAt: Date? = nil) -> ActiveWorkoutSnapshot? {
        let calendar = ClubDates.calendar
        let today = calendar.startOfDay(for: now)
        let candidates = [today, calendar.date(byAdding: .day, value: -1, to: today)].compactMap { $0 }
        for date in candidates {
            let key = ClubDates.key(date)
            guard let day = state.days[key] else { continue }
            let training = day.trainingLog
            // endedAt is terminal: an edited saved workout keeps its end time and
            // must not be reconstructed as an active session.
            guard training.workoutSavedAt == nil, training.workoutEndedAt == nil,
                  let startedAt = training.workoutStartedAt,
                  WorkoutTiming.hasRecentStart(day, on: date, now: now),
                  let sessionID = day.activeWorkoutSessionID ?? day.workoutSessions?.first?.id,
                  day.workoutSessions?.first(where: { $0.id == sessionID })?.savedAt == nil else { continue }
            let exercises = training.exercises.filter { !$0.sets.isEmpty }
            guard !exercises.isEmpty else { continue }
            let total = exercises.reduce(0) { $0 + $1.sets.count }
            let completed = exercises.flatMap(\.sets).filter(\.validCompletion).count
            let currentExercise = exercises.first { exercise in exercise.sets.contains { !$0.validCompletion } } ?? exercises.last
            let currentSet = currentExercise?.sets.firstIndex { !$0.validCompletion }
            let pauseState = pause?.sessionID == sessionID ? pause : nil
            let elapsed = pauseState?.elapsed(startedAt: startedAt, now: now) ?? max(0, now.timeIntervalSince(startedAt))
            return ActiveWorkoutSnapshot(
                dateKey: key, sessionID: sessionID, startedAt: startedAt,
                workoutName: currentExercise?.displayName ?? exercises.first?.displayName ?? "训练",
                currentExerciseName: currentExercise?.displayName,
                currentSetNumber: currentSet.map { $0 + 1 },
                completedSets: completed, totalSets: total,
                isPaused: pauseState?.isPaused == true,
                accumulatedPaused: pauseState?.accumulated ?? 0, elapsed: elapsed,
                restEndsAt: restEndsAt.flatMap { $0 > now ? $0 : nil })
        }
        return nil
    }
}

enum HomeTrainingState: Equatable {
    case planned(title: String, exerciseCount: Int, setCount: Int)
    case inProgress(ActiveWorkoutSnapshot)
    case completed(sessionID: UUID?)
    /// The workout was ended but later edited; its confirmation is pending.
    case needsConfirmation
    case restDay
    case none

    var isInProgress: Bool { if case .inProgress = self { return true }; return false }

    static func resolve(date: Date, state: SavedState, now: Date = Date(),
                        pause: WorkoutPauseState? = nil, restEndsAt: Date? = nil) -> HomeTrainingState {
        let key = ClubDates.key(date)
        if calendarIsToday(date, now: now), let active = ActiveWorkoutRules.snapshot(state: state, now: now, pause: pause, restEndsAt: restEndsAt) {
            return .inProgress(active)
        }
        let day = state.days[key] ?? DayLog()
        if day.hasUnconfirmedTraining, day.trainingLog.workoutEndedAt != nil { return .needsConfirmation }
        if day.hasConfirmedTraining {
            return .completed(sessionID: day.confirmedWorkoutSessions.first?.id)
        }
        if day.workoutEndedAt != nil, day.workoutSavedAt == nil, day.completedSets > 0 {
            return .needsConfirmation
        }
        if !day.exercises.isEmpty {
            let title = day.exercises.first?.displayName ?? "训练"
            return .planned(title: title, exerciseCount: day.exercises.count, setCount: day.totalSets)
        }
        if let cycle = day.planCycle, cycle.dates.contains(key), !cycle.plannedDates.contains(key) {
            return .restDay
        }
        return .none
    }
    private static func calendarIsToday(_ date: Date, now: Date) -> Bool {
        ClubDates.calendar.isDate(date, inSameDayAs: now)
    }
}

enum TrainingExecutionCapture {
    static func reconcile(_ day: inout DayLog, base: DayLog?, local: DayLog?, remote: DayLog?) {
        guard var sessions = day.workoutSessions else { return }
        for index in sessions.indices {
            let id = sessions[index].id
            if let committed = base?.workoutSessions?.first(where: { $0.id == id })?.executionBaseline {
                sessions[index].executionBaseline = committed
            } else {
                let snapshots = [local, remote].compactMap { $0?.workoutSessions?.first(where: { $0.id == id })?.executionBaseline }
                if let earliest = snapshots.min(by: { $0.capturedAt < $1.capturedAt }) { sessions[index].executionBaseline = earliest }
            }
        }
        day.workoutSessions = sessions
    }
    // Freeze before the first started/completed mutation, never backfill old training.
    static func capture(before: DayLog, after: inout DayLog, on date: Date, restSeconds: Int? = nil) {
        guard ClubDates.calendar.isDateInToday(date),
              before.activeWorkoutSessionID == after.activeWorkoutSessionID else { return }
        let original = before.trainingLog
        guard !original.exercises.isEmpty, original.workoutStartedAt == nil,
              original.completedSets == 0, original.workoutSavedAt == nil, original.workoutEndedAt == nil else { return }
        let updated = after.trainingLog
        guard updated.workoutStartedAt != nil || updated.completedSets > 0 else { return }
        let targets = original.exercises.flatMap { exercise in
            exercise.sets.map { set in WorkoutBaselineSet(id: set.id, exerciseID: exercise.id,
                unit: set.durationSeconds == nil ? "reps" : "time", targetSeconds: set.durationSeconds,
                targetReps: set.durationSeconds == nil && (1...RecordLimits.maximumReps).contains(set.reps) ? set.reps : nil,
                targetWeight: set.durationSeconds == nil && set.weight.isFinite && (0...RecordLimits.maximumWeight).contains(set.weight) ? set.weight : nil, targetRestSeconds: exercise.restSeconds ?? restSeconds) }
        }
        guard !targets.isEmpty, targets.count <= 1500,
              Set(targets.map(\.id)).count == targets.count,
              targets.allSatisfy({ $0.unit != "time" || ($0.targetSeconds.map { (1...RecordLimits.maximumSeconds).contains($0) } ?? false) }) else { return }
        WorkoutSessions.initialize(&after)
        guard let index = after.workoutSessions?.firstIndex(where: { $0.id == after.activeWorkoutSessionID }),
              after.workoutSessions?[index].executionBaseline == nil else { return }
        after.workoutSessions?[index].executionBaseline = WorkoutExecutionBaseline(
            capturedAt: updated.workoutStartedAt ?? updated.workoutSavedAt ?? Date(), sets: targets,
            restSeconds: restSeconds.flatMap { (0...3600).contains($0) ? $0 : nil })
    }
}

enum WorkoutSessions {
    static func initialize(_ day: inout DayLog) {
        guard day.workoutSessions?.isEmpty != false else { return }
        let id = day.exercises.first?.id ?? UUID()
        day.workoutSessions = [WorkoutSession(id: id, startedAt: day.workoutStartedAt, endedAt: day.workoutEndedAt, savedAt: day.workoutSavedAt, linkedDeviceWorkoutID: day.linkedDeviceWorkoutID)]
        day.activeWorkoutSessionID = id
        for index in day.exercises.indices { day.exercises[index].workoutSessionID = id }
    }
    static func synchronize(_ day: inout DayLog) {
        guard var sessions = day.workoutSessions, !sessions.isEmpty else { return }
        guard let chosen = sessions.first(where: { $0.id == day.activeWorkoutSessionID && $0.cancelledAt == nil }) ?? sessions.first(where: { $0.cancelledAt == nil }) else { day.activeWorkoutSessionID = nil; day.workoutStartedAt = nil; day.workoutEndedAt = nil; day.workoutSavedAt = nil; return }
        let active = chosen.id
        day.activeWorkoutSessionID = active
        for index in day.exercises.indices where day.exercises[index].workoutSessionID == nil {
            day.exercises[index].workoutSessionID = active
        }
        if let index = sessions.firstIndex(where: { $0.id == active }) {
            let completed = day.exercises.filter { $0.workoutSessionID == active }.flatMap(\.sets).contains(where: \.validCompletion)
            sessions[index].startedAt = day.workoutStartedAt
            sessions[index].endedAt = day.workoutEndedAt
            sessions[index].savedAt = completed ? day.workoutSavedAt : nil
            sessions[index].linkedDeviceWorkoutID = completed ? day.linkedDeviceWorkoutID : nil
        }
        var linkedDevices = Set<String>()
        for index in sessions.indices.sorted(by: { sessions[$0].id.uuidString < sessions[$1].id.uuidString }) {
            let completed = day.exercises.filter { $0.workoutSessionID == sessions[index].id }.flatMap(\.sets).contains(where: \.validCompletion)
            if !completed { sessions[index].savedAt = nil; sessions[index].linkedDeviceWorkoutID = nil }
            if let linked = sessions[index].linkedDeviceWorkoutID, day.health?.workouts.contains(where: { $0.id == linked }) != true { sessions[index].linkedDeviceWorkoutID = nil }
            if let linked = sessions[index].linkedDeviceWorkoutID, !linkedDevices.insert(linked).inserted { sessions[index].linkedDeviceWorkoutID = nil }
        }
        day.workoutSessions = sessions
        restoreActiveFields(&day)
    }
    static func restoreActiveFields(_ day: inout DayLog) {
        guard let sessions = day.workoutSessions, !sessions.isEmpty else { return }
        guard let selected = sessions.first(where: { $0.id == day.activeWorkoutSessionID && $0.cancelledAt == nil }) ?? sessions.first(where: { $0.cancelledAt == nil }) else { day.activeWorkoutSessionID = nil; day.workoutStartedAt = nil; day.workoutEndedAt = nil; day.workoutSavedAt = nil; return }
        day.activeWorkoutSessionID = selected.id
        day.workoutStartedAt = selected.startedAt; day.workoutEndedAt = selected.endedAt
        day.workoutSavedAt = selected.savedAt; day.linkedDeviceWorkoutID = selected.linkedDeviceWorkoutID
    }
    static func select(_ id: UUID, in day: inout DayLog) -> Bool {
        guard day.workoutSessions?.contains(where: { $0.id == id && $0.cancelledAt == nil }) == true else { return false }
        synchronize(&day); day.activeWorkoutSessionID = id; restoreActiveFields(&day); return true
    }
}

// A confirmation belongs to the exact recorded exercise contents, not just a time field.
enum RecordIntegrity {
    static func validateConfirmation(_ day: inout DayLog, local: DayLog?, remote: DayLog?) throws {
        func matches(_ source: DayLog?, sessionID: UUID?, savedAt: Date) throws -> Bool {
            guard let source else { return false }
            let sourceTime = sessionID.flatMap { id in source.workoutSessions?.first { $0.id == id }?.savedAt } ?? (sessionID == nil ? source.workoutSavedAt : nil)
            guard sourceTime == savedAt else { return false }
            let actual = day.exercises.filter { sessionID == nil || $0.workoutSessionID == sessionID }
            let original = source.exercises.filter { sessionID == nil || $0.workoutSessionID == sessionID }
            return try CloudMerge.same(actual, original)
        }
        if var sessions = day.workoutSessions, !sessions.isEmpty {
            for index in sessions.indices {
                guard let time = sessions[index].savedAt else { continue }
                let id = sessions[index].id
                let localMatches = try matches(local, sessionID: id, savedAt: time)
                let remoteMatches = try matches(remote, sessionID: id, savedAt: time)
                if !localMatches && !remoteMatches { sessions[index].savedAt = nil }
            }
            day.workoutSessions = sessions
            WorkoutSessions.restoreActiveFields(&day)
        } else if let time = day.workoutSavedAt {
            let localMatches = try matches(local, sessionID: nil, savedAt: time)
            let remoteMatches = try matches(remote, sessionID: nil, savedAt: time)
            if !localMatches && !remoteMatches { day.workoutSavedAt = nil }
        }
    }
}

enum RecordLimits {
    static let maximumWeight = 2000.0
    static let maximumReps = 1000
    static let maximumSeconds = 6 * 3600
    static let maximumNutrition = 100000.0
    static func valid(_ set: TrainingSet) -> Bool {
        set.weight.isFinite && (0...maximumWeight).contains(set.weight) && (0...maximumReps).contains(set.reps)
            && (set.durationSeconds.map { (0...maximumSeconds).contains($0) } ?? true)
    }
    static func valid(_ meal: Meal) -> Bool {
        [meal.calories, meal.protein, meal.carbs, meal.fat].allSatisfy { $0.isFinite && (0...maximumNutrition).contains($0) }
    }
}

struct MealPlacementIssue: Identifiable {
    let date: String
    let meal: Meal
    var id: UUID { meal.id }
}
enum MealPlacement {
    static func reconcile(days: inout [String: DayLog], base: [String: DayLog]) {
        var groups: [String: [MealPlacementIssue]] = [:]
        for date in days.keys.sorted() {
            for meal in days[date]?.meals ?? [] {
                guard let source = meal.sourceAIJobID, !source.isEmpty else { continue }
                groups[source + "/" + meal.id.uuidString.lowercased(), default: []].append(MealPlacementIssue(date: date, meal: meal))
            }
        }
        for (_, candidates) in groups where candidates.count > 1 {
            let entryID = candidates[0].meal.id
            let prior = base.keys.sorted().flatMap { date in
                (base[date]?.meals ?? []).filter { $0.id == entryID }.map { MealPlacementIssue(date: date, meal: $0) }
            }.first
            let ordered = candidates.sorted {
                let left = $0.meal.placementConfirmedAt ?? .distantPast
                let right = $1.meal.placementConfirmedAt ?? .distantPast
                if left != right { return left > right }
                if ($0.date == prior?.date) != ($1.date == prior?.date) { return $0.date == prior?.date }
                return $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
            }
            guard let winner = ordered.first else { continue }
            var kept = winner.meal
            let simultaneousChoices = ordered.dropFirst().contains { item in
                guard let chosen = item.meal.placementConfirmedAt else { return false }
                return chosen != prior?.meal.placementConfirmedAt && winner.meal.placementConfirmedAt != prior?.meal.placementConfirmedAt
            }
            if winner.meal.placementConfirmedAt == nil || simultaneousChoices {
                let dates = Set(candidates.map(\.date) + candidates.flatMap { $0.meal.placementConflictDates ?? [] })
                kept.placementConflictDates = dates.sorted()
            }
            for date in Set(candidates.map(\.date)) {
                days[date]?.meals.removeAll { $0.id == entryID }
            }
            days[winner.date]?.meals.append(kept)
        }
    }
}

enum TrainingRecordText {
    static func completedSets(_ log: DayLog, on date: Date, now: Date = Date()) -> Int {
        ClubDates.isFuture(date,now:now) ? 0 : log.completedSets
    }
    static func measurements(_ log: DayLog) -> [String] {
        var values: [String]=[]
        if log.volume > 0 { values.append("负重训练量 \(log.volume.formatted(.number.precision(.fractionLength(0)))) kg·次") }
        if log.timedSeconds > 0 {
            let minutes=log.timedSeconds/60;let seconds=log.timedSeconds%60
            let duration=minutes == 0 ? "\(seconds) 秒" : seconds == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(seconds) 秒"
            values.append("计时动作合计 \(duration)")
        }
        if values.isEmpty && log.completedSets > 0 { values.append("按次训练，以完成组数统计") }
        return values
    }
    static func summary(_ log: DayLog) -> [String] {
        ["\(log.completedSets)/\(log.totalSets) 组", "\(log.exercises.count) 个动作"] + measurements(log)
    }
}

// Reading layout preserves report content and only interprets simple headings
// and list markers. It does not fetch links or alter the stored AI response.
struct ReportTextBlock: Identifiable, Equatable {
    enum Kind: Equatable { case paragraph, heading, bullet, numbered }
    let id: Int
    let kind: Kind
    let text: String
    let marker: String
}

enum ReportTextLayout {
    static func blocks(_ text: String) -> [ReportTextBlock] {
        var result: [ReportTextBlock] = []
        var paragraph: [String] = []
        func append(_ kind: ReportTextBlock.Kind, _ text: String, marker: String = "") {
            result.append(ReportTextBlock(id: result.count, kind: kind, text: text, marker: marker))
        }
        func flush() {
            if !paragraph.isEmpty { append(.paragraph, paragraph.joined(separator: "\n")); paragraph = [] }
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush(); append(.heading, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)); continue
            }
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4,
               !line.dropFirst(2).dropLast(2).contains("**") {
                flush(); append(.heading, String(line.dropFirst(2).dropLast(2))); continue
            }
            if ["- ", "* ", "• "].contains(where: { line.hasPrefix($0) }) {
                flush(); append(.bullet, String(line.dropFirst(2)), marker: "•"); continue
            }
            if let range = line.range(of: "^[0-9]{1,3}(?:[.)]\\s+|、\\s*)", options: .regularExpression) {
                flush()
                let marker = String(line[range]).trimmingCharacters(in: .whitespaces)
                append(.numbered, String(line[range.upperBound...]), marker: marker); continue
            }
            paragraph.append(line)
        }
        flush(); return result
    }
}

enum ReportFreshness: Equatable {
    case current, changed, unavailable
    static func evaluate(request: AIRequest, current: AIInput?) -> ReportFreshness {
        guard !request.payload.isEmpty, let current else { return .unavailable }
        var original = request.payload; var latest = current.payload
        original.removeValue(forKey: "_routing_version"); latest.removeValue(forKey: "_routing_version")
        if original["goal_context"] == nil { latest.removeValue(forKey: "goal_context") }
        return request.kind == current.kind && request.date == current.date && original == latest ? .current : .changed
    }
}

enum ReportHistory {
    static func visible(_ jobs: [AILocalJob], dateKey: String? = nil, deleted: Set<String> = []) -> [AILocalJob] {
        jobs.filter {
            $0.request.kind == "report" && $0.status == "succeeded" && $0.result?.kind == "report" &&
            !deleted.contains($0.id) && (dateKey == nil || $0.request.date == dateKey)
        }.sorted {
            $0.created == $1.created ? $0.id > $1.id : $0.created > $1.created
        }
    }
    static func latestPerDay(_ reports: [AILocalJob]) -> [AILocalJob] {
        var seen = Set<String>()
        let latest = reports.sorted {
            $0.created == $1.created ? $0.id > $1.id : $0.created > $1.created
        }.filter { seen.insert($0.request.date).inserted }
        return latest.sorted { $0.request.date > $1.request.date }
    }
}


// Seven calendar days, including rest days; this is independent of the calendar week.
struct TrainingCycle: Codable, Equatable, Identifiable {
    var start: String
    var plannedDates: [String]
    var sourceJobID: String? = nil
    var explanationVersion: Int? = nil
    // A new plan may split a previous cycle. Keep its actual remaining interval.
    var endDate: String? = nil
    var id: String { start }
    var dates: [String] {
        guard let date = ClubDates.date(fromKey: start) else { return [] }
        let full = (0..<7).compactMap { ClubDates.calendar.date(byAdding: .day, value: $0, to: date) }.map(ClubDates.key)
        guard let endDate else { return full }
        return full.filter { $0 <= endDate }
    }
    var end: String { dates.last ?? start }
    var label: String { start + " — " + end }
    func ended(now: Date = Date()) -> Bool { end < ClubDates.key(now) }
    static func available(days: [String: DayLog], now: Date = Date()) -> [TrainingCycle] {
        var byStart: [String: TrainingCycle] = [:]
        for cycle in ownedIntervals(days: days) { byStart[cycle.start] = cycle }
        // Legacy plans have no cycle marker. Anchor to their first actual schedule,
        // keep seven-day boundaries stable, and include the latest completed period.
        if byStart.isEmpty {
            let first = days.keys.filter { !(days[$0]?.exercises.isEmpty ?? true) }.sorted().first
            let today = ClubDates.calendar.startOfDay(for: now)
            let start = first.flatMap(ClubDates.date(fromKey:)) ?? today
            let elapsed = max(0, ClubDates.calendar.dateComponents([.day], from: start, to: today).day ?? 0)
            let last = elapsed / 7
            for index in max(0, last - 12)...last {
                guard let anchor = ClubDates.calendar.date(byAdding: .day, value: index * 7, to: start) else { continue }
                var cycle = TrainingCycle(start: ClubDates.key(anchor), plannedDates: [])
                cycle.plannedDates = cycle.dates.filter { !(days[$0]?.exercises.isEmpty ?? true) }
                byStart[cycle.start] = cycle
            }
        }
        // Old/manual/imported schedules can coexist with newly stamped AI cycles.
        var covered = Set(byStart.values.flatMap(\.dates))
        for key in days.keys.sorted() where !covered.contains(key) && !(days[key]?.exercises.isEmpty ?? true) {
            var cycle = TrainingCycle(start: key, plannedDates: [])
            cycle.plannedDates = cycle.dates.filter { !(days[$0]?.exercises.isEmpty ?? true) }
            guard !cycle.dates.contains(where: { covered.contains($0) }) else { continue }
            byStart[key] = cycle; covered.formUnion(cycle.dates)
        }
        return byStart.values.sorted { $0.start > $1.start }
    }
    static func preferred(days: [String: DayLog], now: Date = Date()) -> TrainingCycle {
        let all = available(days: days, now: now)
        return all.first(where: { $0.ended(now: now) && days[$0.end]?.weeklyReview?.result == nil })
            ?? all.first(where: { $0.dates.contains(ClubDates.key(now)) })
            ?? all.first ?? TrainingCycle(start: ClubDates.key(now), plannedDates: [])
    }
    /// 覆盖某一天的有效周期。顺延跨周时用于把目标日归到真正包含它的周期，
    /// 而不是把源周期的 start/end 原样复制到一个它并不覆盖的日期。
    static func covering(_ key: String, in days: [String: DayLog], now: Date = Date()) -> TrainingCycle? {
        let all = available(days: days, now: now)
        return all.first(where: { $0.dates.contains(key) && $0.plannedDates.contains(key) })
            ?? all.first(where: { $0.dates.contains(key) })
    }
    /// 以某一天为锚点的完整七天周期（用于目标日不属于任何现有周期的情况）。
    static func week(anchoredAt start: String, sourceJobID: String? = nil, explanationVersion: Int? = nil) -> TrainingCycle? {
        guard ClubDates.date(fromKey: start) != nil else { return nil }
        var cycle = TrainingCycle(start: start, plannedDates: [])
        cycle.endDate = cycle.dates.last
        cycle.sourceJobID = sourceJobID
        cycle.explanationVersion = explanationVersion ?? 1
        return cycle
    }
    // Actual per-day ownership is authoritative, including old overlapping markers.
    // Split at ownership changes/gaps; never combine provenance from different jobs.
    static func ownedIntervals(days: [String: DayLog]) -> [TrainingCycle] {
        let keys = days.keys.sorted().filter { key in days[key]?.planCycle?.dates.contains(key) == true }
        var result: [TrainingCycle] = []
        var group: [String] = []
        func appendGroup() {
            guard let first = group.first, let last = group.last, var source = days[first]?.planCycle else { return }
            source.start = first; source.endDate = last
            source.plannedDates = source.plannedDates.filter { group.contains($0) }
            result.append(source)
        }
        for key in keys {
            if let previous = group.last {
                let previousCycle = days[previous]?.planCycle
                let currentCycle = days[key]?.planCycle
                let next = ClubDates.date(fromKey: previous).flatMap { ClubDates.calendar.date(byAdding: .day, value: 1, to: $0) }.map(ClubDates.key)
                if next != key || previousCycle?.start != currentCycle?.start || previousCycle?.sourceJobID != currentCycle?.sourceJobID {
                    appendGroup(); group = []
                }
            }
            group.append(key)
        }
        appendGroup()
        return result
    }
    // Called inside the same persistence transaction as plan changes.
    /// Manual exercise add/remove changes which dates actually contain a plan.
    /// plannedDates is derived from that content (the same rule used by stamp and
    /// the rest-day action), so refresh every day copy of the covering cycle in
    /// the same persistence transaction. History/version records are untouched.
    static func refreshPlannedDates(covering key: String, in days: inout [String: DayLog]) -> Set<String> {
        guard let marker = days[key]?.planCycle, marker.dates.contains(key) else { return [] }
        var cycles: [TrainingCycle] = []
        for candidate in days.values {
            guard let cycle = candidate.planCycle, cycle.start == marker.start,
                  cycle.dates.contains(key),
                  !cycles.contains(where: { $0.start == cycle.start }) else { continue }
            cycles.append(cycle)
        }
        var changed = Set<String>()
        for cycle in cycles {
            var value = cycle
            value.plannedDates = cycle.dates.filter { !(days[$0]?.exercises.isEmpty ?? true) }
            for dayKey in value.dates {
                // Do not move a date that already belongs to a different cycle
                // marker; overlapping legacy intervals must stay readable.
                if let current = days[dayKey]?.planCycle, current.start != value.start { continue }
                guard days[dayKey]?.planCycle != value else { continue }
                days[dayKey, default: DayLog()].planCycle = value
                changed.insert(dayKey)
            }
        }
        return changed
    }
    static func stamp(days: inout [String: DayLog], start: Date, plannedDates: [String], sourceJobID: String? = nil) -> [String] {
        var cycle = TrainingCycle(start: ClubDates.key(start), plannedDates: plannedDates.sorted())
        cycle.endDate = cycle.end
        cycle.sourceJobID = sourceJobID
        cycle.explanationVersion = 1
        cycle.plannedDates = cycle.dates.filter { !(days[$0]?.exercises.isEmpty ?? true) }
        var changed = Set(cycle.dates)
        // Remove only cycle markers inside the new interval, never training data.
        // Normalize the surviving prefixes/suffixes and retain their source jobs.
        for key in cycle.dates { days[key]?.planCycle = nil }
        for survivor in ownedIntervals(days: days) {
            for key in survivor.dates where days[key]?.planCycle != survivor {
                days[key]?.planCycle = survivor; changed.insert(key)
            }
        }
        for key in cycle.dates { days[key, default: DayLog()].planCycle = cycle }
        return changed.sorted()
    }
}

enum ExperienceDigest {
    // Stable, non-security fingerprint. sortedKeys also makes it device-independent.
    static func of<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "invalid" }
        var hash: UInt64 = 14695981039346656037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}
struct MealCompletion: Codable {
    var signature: String
    var updatedAt: Date = Date()
    static func signature(_ meals: [Meal]) -> String {
        // Media upload/download and provenance do not alter what the person ate.
        let content = meals.sorted { $0.id.uuidString < $1.id.uuidString }.map { meal -> Meal in
            var copy = meal; copy.photoFilename = nil; copy.photoRemoteID = nil
            copy.estimateNotes = nil; copy.estimated = nil; copy.sourceAIJobID = nil
            return copy
        }
        return ExperienceDigest.of(content)
    }
}
struct WeeklyReadiness {
    let cycle: TrainingCycle
    let trainingDays: Int
    let foodDays: Int
    let recordedFoodDays: Int
    let neededTrainingDays: Int
    let ended: Bool
    let allPlannedCompleted: Bool
    let isCycleEndDay: Bool
    var cycleReady: Bool { ended || allPlannedCompleted || isCycleEndDay }
    var trainingReady: Bool { cycleReady && trainingDays >= neededTrainingDays }
    var combinedReady: Bool { trainingReady && foodDays >= 3 }
    func allowed(scope: String) -> Bool { scope == "training" ? trainingReady : combinedReady }
    var adjustmentNotice: String? {
        trainingDays < 2 ? "达到复盘条件后可以看训练分析；自动调整下周安排需要至少两个真实完成的训练日。只有一练时，可以继续原计划或手动安排，不需要为解锁功能凑训练。" : nil
    }
    var explanation: String {
        if !cycleReady { return "本周期尚未结束。完成本周全部计划训练日或周期结束后即可开始复盘；现在可以看小结或提前安排下周。" }
        if trainingDays < neededTrainingDays { return "还需要 \(neededTrainingDays - trainingDays) 个真实完成并保存的训练日。请只补录实际训练，不要为解锁复盘凑记录。" }
        if foodDays < 3 { return "综合复盘还需要 \(3-foodDays) 天已确认记完、营养数据完整的饮食。可以先做训练复盘。" }
        return "记录已达到复盘条件。分析会注明覆盖天数，不把缺失记录当作未执行。"
    }
    init(cycle: TrainingCycle, days: [String: DayLog], now: Date = Date()) {
        self.cycle = cycle; ended = cycle.ended(now: now)
        let todayKey = ClubDates.key(now)
        isCycleEndDay = todayKey == cycle.end
        allPlannedCompleted = !cycle.plannedDates.isEmpty && cycle.plannedDates.allSatisfy { $0 <= todayKey && days[$0]?.hasConfirmedTraining == true }
        let records = cycle.dates.filter { $0 <= todayKey }.compactMap { days[$0] }
        trainingDays = records.filter(\.hasConfirmedTraining).count
        foodDays = records.filter { $0.mealsComplete && $0.unknownNutritionMeals == 0 }.count
        recordedFoodDays = records.filter { !$0.meals.isEmpty }.count
        neededTrainingDays = cycle.plannedDates.count == 1 ? 1 : 2
    }
}
enum BodyProfileAssessment {
    static let activityOptions = ["主要久坐", "经常站立走动", "日常体力活动较多"]
    static let contextOptions = ["普通成人", "孕期或哺乳期", "需按医生建议饮食"]
    static func bmi(_ p: MemberProfile) -> Double? {
        guard p.hasConfirmedBasics, p.age >= 18, p.nutritionContext != "孕期或哺乳期", p.height.isFinite, (100...250).contains(p.height), p.weight.isFinite, (20...400).contains(p.weight) else { return nil }
        return ((p.weight / pow(p.height / 100, 2)) * 10).rounded() / 10
    }
    static func category(_ p: MemberProfile) -> String {
        guard let value = bmi(p) else { return "不适用成人 BMI 分类" }
        if value < 18.5 { return "偏轻" }; if value < 24 { return "适中" }
        return value < 28 ? "超重范围" : "肥胖范围"
    }
    static func suggestedGoal(_ p: MemberProfile) -> String {
        guard let value = bmi(p), p.nutritionContext == nil || p.nutritionContext == "普通成人" else { return "养成运动习惯" }
        return value < 18.5 ? "增肌塑形" : value >= 24 ? "减脂瘦身" : "增肌塑形"
    }
    static func explanation(_ p: MemberProfile) -> String {
        if !p.hasConfirmedBasics { return "年龄、身高或资料体重尚未确认，不显示 BMI 或据此推荐目标；未填写不会用示例数代替。" }
        if p.nutritionContext == "孕期或哺乳期" { return "孕期或哺乳期不使用当前体重的成人 BMI 分类来推荐减脂目标，请结合个人情况评估。" }
        if p.age < 18 { return "未成年人不使用成人 BMI 分类和减脂热量目标，身体发育情况需要结合年龄评估。" }
        guard bmi(p) != nil else { return "请核对身高与体重后查看 BMI 参考；超出适用范围时不提供分类。" }
        return "BMI 只反映身高与体重关系，不能区分肌肉和脂肪。建议还要结合腰围、训练经验与个人目标；不会替你更改选择。"
    }
}

/// Stable migration identity matches the server, preserving old single-value days.
enum BodyMeasurementIdentity {
    static func legacy(_ entry: BodyWeightEntry, date: String) -> UUID {
        let time = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), (entry.recordedAt ?? entry.updatedAt).timeIntervalSinceReferenceDate)
        let weight = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), entry.kilograms ?? 0)
        let hex = SHA256.hash(data: Data(("legacy-weight/" + date + "/" + time + "/" + weight).utf8)).map { String(format: "%02x", $0) }.joined()
        let a = Array(hex)
        let value = String(a[0..<8]) + "-" + String(a[8..<12]) + "-4" + String(a[13..<16]) + "-a" + String(a[17..<20]) + "-" + String(a[20..<32])
        return UUID(uuidString: value) ?? UUID()
    }
}
