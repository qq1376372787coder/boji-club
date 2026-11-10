import Foundation
enum ClubDates {
    static func isFuture(_ date: Date, now: Date = Date()) -> Bool {
        calendar.startOfDay(for: date) > calendar.startOfDay(for: now)
    }
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }

    private static let formatterCache = ClubDateFormatterCache()
    static func key(_ date: Date) -> String { formatterCache.string(date, format: "yyyy-MM-dd", locale: "en_US_POSIX") }
    static func date(fromKey value: String) -> Date? { formatterCache.date(value) }
    static func label(_ date: Date, format: String = "M月d日") -> String { formatterCache.string(date, format: format, locale: "zh_CN") }

}
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
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
struct TrainingSet: Identifiable, Codable, Equatable {
    var id = UUID()
    var weight: Double = 0
    var reps: Int = 10
    var completed = false
    var durationSeconds: Int? = nil
    var validCompletion: Bool { completed && (durationSeconds.map { $0 > 0 } ?? (reps > 0)) }
    var volume: Double { validCompletion && durationSeconds == nil ? weight * Double(reps) : 0 }
}
struct Exercise: Identifiable, Codable {
    var id = UUID()
    var name: String
    var muscle: String
    var displayName: String { customExerciseID != nil ? name : ExerciseNames.display(name, id: libraryID, query: libraryQuery) }
    var sets: [TrainingSet] = (0..<3).map { _ in TrainingSet() }
    var libraryID: String?
    var equipment: String?
    var imageURL: String?
    var gifURL: String?
    var libraryQuery: String?
    var deletedSetIDs: [String]?
    var workoutSessionID: UUID? = nil
    var customExerciseID: UUID? = nil
    var customUnit: String? = nil
    var restSeconds: Int? = nil
    enum CodingKeys: String, CodingKey { case id, name, muscle, sets, libraryID, equipment, imageURL, gifURL, libraryQuery, deletedSetIDs, workoutSessionID, customExerciseID, customUnit, restSeconds }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(muscle, forKey: .muscle); try c.encode(sets, forKey: .sets)
        try c.encodeIfPresent(libraryID, forKey: .libraryID); try c.encodeIfPresent(equipment, forKey: .equipment)
        try c.encodeIfPresent(imageURL, forKey: .imageURL); try c.encodeIfPresent(gifURL, forKey: .gifURL); try c.encodeIfPresent(libraryQuery, forKey: .libraryQuery)
        try c.encodeIfPresent(deletedSetIDs, forKey: .deletedSetIDs); try c.encodeIfPresent(workoutSessionID, forKey: .workoutSessionID)
        try c.encodeIfPresent(customExerciseID, forKey: .customExerciseID); try c.encodeIfPresent(customUnit, forKey: .customUnit)
        // Explicit null resets an override; old clients omit this key entirely.
        try c.encode(restSeconds, forKey: .restSeconds)
    }
}
struct CustomExercise: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var muscle = ""
    var equipment = ""
    var unit = "次"
    var updatedAt = Date()
    static let muscles = ["胸", "背", "肩", "手臂", "大腿", "臀", "小腿", "核心", "有氧"]
    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN")) }
    var valid: Bool { !normalizedName.isEmpty && name.unicodeScalars.count <= 60 && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && ["次","秒"].contains(unit) && (muscle.isEmpty || Self.muscles.contains(muscle)) && equipment.unicodeScalars.count <= 60 }
    var bodyPart: String { ["胸":"chest", "背":"back", "肩":"shoulders", "手臂":"upper arms", "大腿":"upper legs", "臀":"glutes", "小腿":"lower legs", "核心":"waist", "有氧":"cardio"][muscle] ?? "" }
    var blankSet: TrainingSet { TrainingSet(reps: unit == "秒" ? 0 : 10, durationSeconds: unit == "秒" ? 30 : nil) }
    func exercise() -> Exercise {
        Exercise(name: name, muscle: muscle.isEmpty ? "未指定" : muscle, sets: (0..<3).map { _ in blankSet }, equipment: equipment.isEmpty ? nil : equipment, customExerciseID: id, customUnit: unit)
    }
}
struct WorkoutBaselineSet: Codable, Equatable {
    var id: UUID
    var exerciseID: UUID
    var unit: String
    var targetSeconds: Int?
    var targetReps: Int? = nil
    var targetWeight: Double? = nil
    var targetRestSeconds: Int? = nil
}
struct WorkoutExecutionBaseline: Codable, Equatable {
    var version = 1
    var capturedAt: Date
    var sets: [WorkoutBaselineSet]
    var restSeconds: Int? = nil
}
struct WorkoutSession: Identifiable, Codable {
    var id: UUID
    var startedAt: Date?
    var endedAt: Date?
    var savedAt: Date?
    var linkedDeviceWorkoutID: String?
    var executionBaseline: WorkoutExecutionBaseline? = nil
}
enum ExerciseNames { static func display(_ value:String,id:String?,query:String?)->String { value } }
enum RecordLimits { static let maximumWeight = 2000.0
    static let maximumReps = 1000
    static let maximumSeconds = 6 * 3600
    static let maximumNutrition = 100000.0
    static func valid(_ set: TrainingSet) -> Bool {
        set.weight.isFinite && (0...maximumWeight).contains(set.weight) && (0...maximumReps).contains(set.reps)
            && (set.durationSeconds.map { (0...maximumSeconds).contains($0) } ?? true)
    } }
struct HealthSource: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}
struct DeviceWorkout: Codable, Identifiable {
    var id: String
    var name: String
    var start: Date
    var end: Date
    var minutes: Double
    var calories: Double?
    var source: HealthSource
    var activityKind: String? = nil
    var averageHeartRate: Double? = nil

    var comparableKind: String? {
        if let activityKind, activityKind != "other" { return activityKind }
        return ["跑步": "running", "步行": "walking", "骑行": "cycling", "游泳": "swimming",
                "力量训练": "strength", "间歇训练": "interval", "瑜伽": "yoga", "徒步": "hiking", "划船": "rowing",
                "椭圆机": "elliptical", "爬楼梯": "stairs", "跳绳": "jumpRope", "舞蹈": "dance"][name]
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

struct Meal:Codable { var id=UUID();var photoRemoteID:String?;var photoFilename:String? }
struct Review:Codable { var id=UUID() }
struct HealthDay:Codable { var workouts:[DeviceWorkout]=[] }
struct NutritionTarget:Codable { var calories=0;var generalGuidanceOnly:Bool?=nil }
struct DayLog:Codable {
 var exercises:[Exercise]=[];var meals:[Meal]=[];var health:HealthDay?
 var workoutStartedAt:Date?;var workoutEndedAt:Date?;var workoutSavedAt:Date?;var linkedDeviceWorkoutID:String?
 var workoutSessions:[WorkoutSession]?;var activeWorkoutSessionID:UUID?;var nutritionTarget:NutritionTarget?
 var weeklyReviewHistory:[Review]?;var weeklyReviews:[Review] { weeklyReviewHistory ?? [] }
 var completedSets:Int { exercises.flatMap(\.sets).filter(\.validCompletion).count }

var trainingLog: DayLog {
        guard let active = activeWorkoutSessionID, workoutSessions?.contains(where: { $0.id == active }) == true else { return self }
        var result = self
        result.exercises = exercises.filter { $0.workoutSessionID == active }
        result.workoutSessions = nil; result.activeWorkoutSessionID = nil
        return result
    }
}
enum EmptyWorkoutSessionRules {
    static func canRemove(_ id: UUID, from day: DayLog) -> Bool {
        guard let sessions = day.workoutSessions, sessions.count > 1,
              let value = sessions.first(where: { $0.id == id }),
              value.startedAt == nil, value.endedAt == nil, value.savedAt == nil, value.executionBaseline == nil,
              value.linkedDeviceWorkoutID == nil else { return false }
        return !day.exercises.contains { $0.workoutSessionID == id }
    }
}
enum CustomBackupRules {
    static func recover(_ incoming: [CustomExercise], into existing: [CustomExercise], deleted: [String]) -> [CustomExercise] {
        let removed = Set(deleted.map { $0.uppercased() })
        var result = existing
        var ids = Set(existing.map(\.id))
        for value in incoming where value.valid && !removed.contains(value.id.uuidString.uppercased()) {
            if ids.insert(value.id).inserted { result.append(value) }
        }
        return result
    }
}
enum PlanWeightReference {
    static func kilograms(_ value: JSONValue?) -> Double? {
        guard case .object(let fields)? = value, case .string(let date)? = fields["date"],
              ClubDates.date(fromKey: date) != nil, case .number(let kg)? = fields["kilograms"],
              kg.isFinite, (20...400).contains(kg) else { return nil }
        return kg
    }
    static func description(_ value: JSONValue?) -> String? {
        guard let kg = kilograms(value), case .object(let fields)? = value, case .string(let date)? = fields["date"] else { return nil }
        return "制定时采用 \(date) 实测体重 \(kg.formatted(.number.precision(.fractionLength(0...1)))) kg；与资料体重区分保存，不代表之后每天都称过。"
    }
}
enum WorkoutAssociation {
    private static let catalogKinds: [String: String] = ["0001": "strength", "0002": "strength", "0003": "strength", "0006": "strength", "0007": "strength", "0009": "strength", "0011": "strength", "0015": "strength", "0017": "strength", "0019": "strength", "0024": "strength", "0025": "strength", "0026": "strength", "0027": "strength", "0030": "strength", "0031": "strength", "0032": "strength", "0033": "strength", "0038": "strength", "0041": "strength", "0042": "strength", "0043": "strength", "0044": "strength", "0047": "strength", "0049": "strength", "0054": "strength", "0060": "strength", "0063": "strength", "0069": "strength", "0070": "strength", "0072": "strength", "0073": "strength", "0074": "strength", "0076": "strength", "0078": "strength", "0080": "strength", "0081": "strength", "0082": "strength", "0084": "strength", "0085": "strength", "0088": "strength", "0091": "strength", "0092": "strength", "0094": "strength", "0095": "strength", "0098": "strength", "0099": "strength", "0104": "strength", "0106": "strength", "0113": "strength", "0114": "strength", "0116": "strength", "0117": "strength", "0118": "strength", "0120": "strength", "0122": "strength", "0123": "strength", "0124": "strength", "0126": "strength", "0129": "strength", "0150": "strength", "0151": "strength", "0154": "strength", "0158": "strength", "0160": "strength", "0162": "strength", "0165": "strength", "0167": "strength", "0168": "strength", "0169": "strength", "0171": "strength", "0173": "strength", "0175": "strength", "0177": "strength", "0178": "strength", "0179": "strength", "0184": "strength", "0185": "strength", "0188": "strength", "0189": "strength", "0190": "strength", "0192": "strength", "0193": "strength", "0194": "strength", "0195": "strength", "0196": "strength", "0200": "strength", "0201": "strength", "0202": "strength", "0203": "strength", "0206": "strength", "0207": "strength", "0208": "strength", "0209": "strength", "0210": "strength", "0212": "strength", "0214": "strength", "0215": "strength", "0216": "strength", "0218": "strength", "0219": "strength", "0220": "strength", "0222": "strength", "0223": "strength", "0225": "strength", "0226": "strength", "0228": "strength", "0230": "strength", "0233": "strength", "0234": "strength", "0235": "strength", "0237": "strength", "0238": "strength", "0241": "strength", "0242": "strength", "0243": "strength", "0245": "strength", "0246": "strength", "0247": "strength", "0251": "strength", "0253": "strength", "0259": "strength", "0260": "strength", "0262": "strength", "0267": "strength", "0271": "strength", "0272": "strength", "0274": "strength", "0276": "strength", "0277": "strength", "0279": "strength", "0282": "strength", "0283": "strength", "0284": "strength", "0285": "strength", "0289": "strength", "0291": "strength", "0292": "strength", "0293": "strength", "0294": "strength", "0297": "strength", "0298": "strength", "0299": "strength", "0300": "strength", "0301": "strength", "0302": "strength", "0303": "strength", "0308": "strength", "0310": "strength", "0313": "strength", "0314": "strength", "0315": "strength", "0319": "strength", "0320": "strength", "0321": "strength", "0323": "strength", "0326": "strength", "0327": "strength", "0329": "strength", "0330": "strength", "0333": "strength", "0334": "strength", "0336": "strength", "0339": "strength", "0340": "strength", "0344": "strength", "0351": "strength", "0355": "strength", "0356": "strength", "0358": "strength", "0359": "strength", "0361": "strength", "0364": "strength", "0369": "strength", "0372": "strength", "0375": "strength", "0377": "strength", "0381": "strength", "0383": "strength", "0384": "strength", "0387": "strength", "0388": "strength", "0389": "strength", "0391": "strength", "0392": "strength", "0396": "strength", "0398": "strength", "0399": "strength", "0400": "strength", "0404": "strength", "0405": "strength", "0407": "strength", "0409": "strength", "0410": "strength", "0411": "strength", "0413": "strength", "0414": "strength", "0417": "strength", "0425": "strength", "0426": "strength", "0427": "strength", "0430": "strength", "0431": "strength", "0437": "strength", "0439": "strength", "0443": "strength", "0446": "strength", "0447": "strength", "0449": "strength", "0451": "strength", "0452": "strength", "0453": "strength", "0454": "strength", "0455": "strength", "0459": "strength", "0464": "strength", "0474": "strength", "0475": "strength", "0476": "strength", "0488": "strength", "0489": "strength", "0490": "strength", "0491": "strength", "0493": "strength", "0495": "strength", "0496": "strength", "0498": "strength", "0499": "strength", "0507": "strength", "0514": "strength", "0519": "strength", "0520": "strength", "0521": "strength", "0522": "strength", "0528": "strength", "0532": "strength", "0533": "strength", "0534": "strength", "0537": "strength", "0540": "strength", "0541": "strength", "0542": "strength", "0546": "strength", "0549": "strength", "0552": "strength", "0553": "strength", "0554": "strength", "0562": "strength", "0570": "strength", "0571": "strength", "0573": "strength", "0575": "strength", "0577": "strength", "0578": "strength", "0579": "strength", "0581": "strength", "0582": "strength", "0583": "strength", "0584": "strength", "0585": "strength", "0586": "strength", "0588": "strength", "0590": "strength", "0592": "strength", "0593": "strength", "0594": "strength", "0595": "strength", "0596": "strength", "0597": "strength", "0598": "strength", "0599": "strength", "0600": "strength", "0601": "strength", "0602": "strength", "0603": "strength", "0604": "strength", "0605": "strength", "0606": "strength", "0607": "strength", "0620": "strength", "0628": "strength", "0634": "strength", "0635": "strength", "0641": "strength", "0650": "strength", "0651": "strength", "0652": "strength", "0659": "strength", "0660": "strength", "0662": "strength", "0663": "strength", "0664": "strength", "0675": "strength", "0677": "strength", "0684": "running", "0685": "running", "0687": "strength", "0688": "strength", "0689": "strength", "0691": "strength", "0696": "strength", "0699": "strength", "0705": "strength", "0710": "strength", "0717": "strength", "0730": "strength", "0735": "strength", "0738": "strength", "0739": "strength", "0740": "strength", "0741": "strength", "0743": "strength", "0744": "strength", "0748": "strength", "0750": "strength", "0751": "strength", "0752": "strength", "0753": "strength", "0755": "strength", "0756": "strength", "0757": "strength", "0761": "strength", "0762": "strength", "0763": "strength", "0764": "strength", "0765": "strength", "0767": "strength", "0768": "strength", "0770": "strength", "0773": "strength", "0774": "strength", "0775": "strength", "0795": "strength", "0805": "strength", "0806": "strength", "0807": "strength", "0808": "strength", "0809": "strength", "0811": "strength", "0812": "strength", "0814": "strength", "0815": "strength", "0818": "strength", "0826": "strength", "0830": "strength", "0832": "strength", "0833": "strength", "0834": "strength", "0841": "strength", "0845": "strength", "0846": "strength", "0856": "strength", "0857": "strength", "0859": "strength", "0860": "strength", "0861": "strength", "0862": "strength", "0863": "strength", "0864": "strength", "0865": "strength", "0866": "strength", "0868": "strength", "0871": "strength", "0872": "strength", "0873": "strength", "0874": "strength", "0968": "strength", "0969": "strength", "0970": "strength", "0971": "strength", "0972": "strength", "0974": "strength", "0975": "strength", "0976": "strength", "0978": "strength", "0979": "strength", "0980": "strength", "0983": "strength", "0984": "strength", "0985": "strength", "0988": "strength", "0989": "strength", "0990": "strength", "0991": "strength", "0993": "strength", "0994": "strength", "0997": "strength", "0998": "strength", "0999": "strength", "1000": "strength", "1001": "strength", "1002": "strength", "1004": "strength", "1005": "strength", "1007": "strength", "1008": "strength", "1009": "strength", "1011": "strength", "1015": "strength", "1016": "strength", "1017": "strength", "1022": "strength", "1253": "strength", "1254": "strength", "1261": "strength", "1265": "strength", "1273": "strength", "1274": "strength", "1275": "strength", "1281": "strength", "1297": "strength", "1298": "strength", "1299": "strength", "1300": "strength", "1302": "strength", "1306": "strength", "1311": "strength", "1313": "strength", "1314": "strength", "1316": "strength", "1317": "strength", "1318": "strength", "1323": "strength", "1326": "strength", "1327": "strength", "1328": "strength", "1329": "strength", "1331": "strength", "1345": "strength", "1347": "strength", "1348": "strength", "1350": "strength", "1351": "strength", "1356": "strength", "1359": "strength", "1360": "strength", "1361": "strength", "1362": "strength", "1372": "strength", "1373": "strength", "1375": "strength", "1376": "strength", "1379": "strength", "1383": "strength", "1384": "strength", "1387": "strength", "1392": "strength", "1393": "strength", "1396": "strength", "1408": "strength", "1409": "strength", "1410": "strength", "1413": "strength", "1415": "strength", "1422": "strength", "1423": "strength", "1425": "strength", "1427": "strength", "1429": "strength", "1431": "strength", "1433": "strength", "1434": "strength", "1435": "strength", "1436": "strength", "1437": "strength", "1451": "strength", "1452": "strength", "1456": "strength", "1458": "strength", "1459": "strength", "1460": "strength", "1468": "strength", "1471": "strength", "1489": "strength", "1490": "strength", "1615": "strength", "1630": "strength", "1631": "strength", "1632": "strength", "1633": "strength", "1634": "strength", "1636": "strength", "1639": "strength", "1641": "strength", "1663": "strength", "1669": "strength", "1674": "strength", "1678": "strength", "1688": "strength", "1700": "strength", "1705": "strength", "1717": "strength", "1719": "strength", "1722": "strength", "1723": "strength", "1724": "strength", "1726": "strength", "1728": "strength", "1729": "strength", "1748": "strength", "1749": "strength", "1751": "strength", "1755": "strength", "1756": "strength", "1757": "strength", "1758": "strength", "1759": "strength", "1760": "strength", "1761": "strength", "1764": "strength", "1771": "strength", "1774": "strength", "2135": "strength", "2137": "strength", "2138": "cycling", "2141": "elliptical", "2144": "strength", "2186": "strength", "2204": "strength", "2285": "strength", "2286": "strength", "2288": "strength", "2300": "strength", "2311": "stairs", "2317": "strength", "2329": "strength", "2333": "strength", "2355": "strength", "2368": "strength", "2398": "strength", "2399": "strength", "2400": "strength", "2429": "strength", "2611": "strength", "2612": "jumpRope", "2616": "strength", "2736": "strength", "2741": "strength", "2796": "strength", "2799": "strength", "2802": "strength", "2803": "strength", "2805": "strength", "2963": "strength", "3006": "strength", "3007": "strength", "3010": "strength", "3011": "strength", "3013": "strength", "3017": "strength", "3021": "strength", "3122": "strength", "3123": "strength", "3124": "strength", "3132": "strength", "3142": "strength", "3144": "strength", "3145": "strength", "3193": "strength", "3195": "strength", "3200": "strength", "3202": "strength", "3211": "strength", "3213": "strength", "3236": "strength", "3237": "strength", "3239": "strength", "3294": "strength", "3470": "strength", "3523": "strength", "3541": "strength", "3544": "strength", "3545": "strength", "3548": "strength", "3561": "strength", "3563": "strength", "3582": "strength", "3635": "strength", "3640": "strength", "3645": "strength", "3656": "running", "3663": "strength", "3666": "walking", "3667": "strength", "3670": "strength", "3679": "strength", "3699": "strength", "3759": "strength", "3769": "strength", "5201": "strength", "boji-basic-bird-dog": "strength", "boji-basic-plank": "strength", "boji-basic-squat": "strength", "boji-basic-wall-sit": "strength", "boji-cardio-cycle": "cycling", "boji-cardio-dance": "dance", "boji-cardio-row": "rowing", "boji-cardio-stairs": "stairs", "boji-cardio-swim-breast": "swimming", "boji-cardio-swim-free": "swimming", "boji-cardio-walk": "walking"]
    static func activityKind(for exercise: Exercise) -> String? {
        guard exercise.customExerciseID == nil else { return nil }
        if let id = exercise.libraryID { return catalogKinds[id] }
        // Legacy strength records without a catalog ID retain the previous matching behavior.
        return exercise.sets.contains { $0.validCompletion && $0.durationSeconds == nil } ? "strength" : nil
    }
    static func expectedKind(for day: DayLog) -> String? {
        let completed = day.trainingLog.exercises.filter { $0.sets.contains(where: \.validCompletion) }
        let values = completed.compactMap(activityKind)
        guard !completed.isEmpty, values.count == completed.count, Set(values).count == 1 else { return nil }
        return values.first
    }
    static func suggestedIDs(for day: DayLog, workouts: [DeviceWorkout]) -> Set<String> {
        let reserved=Set((day.workoutSessions ?? []).filter { $0.id != day.activeWorkoutSessionID }.compactMap(\.linkedDeviceWorkoutID))
        guard let expected = expectedKind(for: day) else { return [] }
        let day = day.trainingLog
        guard let start = day.workoutStartedAt, let end = day.workoutEndedAt,
              end > start, end.timeIntervalSince(start) <= 6 * 3600 else { return [] }
        return Set(workouts.filter { workout in
            guard workout.comparableKind == expected, !reserved.contains(workout.id) else { return false }
            let longest = max(end.timeIntervalSince(start), workout.end.timeIntervalSince(workout.start))
            let overlap = min(end, workout.end).timeIntervalSince(max(start, workout.start))
            return longest > 0 && overlap / longest >= 0.5
        }.map(\.id))
    }
}

struct Job:Codable { var id:String }
struct CloudState:Codable {
 var days:[String:DayLog]=[:];var customExercises:[CustomExercise]?;var deletedCustomExerciseIDs:[String]?
 var deletedExerciseIDs:[String]?;var deletedMealIDs:[String]?;var deletedAIJobIDs:[String]?;var aiJobs:[Job]?
}
// Outside the tested merge/deletion scope, keep validation and unrelated domain rules inert.
enum TrainingExecutionCapture { static func reconcile(_ day:inout DayLog,base:DayLog?,local:DayLog?,remote:DayLog?) {} }
enum RecordIntegrity { static func validateConfirmation(_ day:inout DayLog,local:DayLog?,remote:DayLog?) throws {} }
enum WeeklyVersions { static func reconcile(_ day:inout DayLog) {} }
enum MealPlacement { static func reconcile(days:inout [String:DayLog],base:[String:DayLog]) {} }

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
        let active = sessions.contains { $0.id == day.activeWorkoutSessionID } ? day.activeWorkoutSessionID! : sessions[0].id
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
        let selected = sessions.first { $0.id == day.activeWorkoutSessionID } ?? sessions[0]
        day.activeWorkoutSessionID = selected.id
        day.workoutStartedAt = selected.startedAt; day.workoutEndedAt = selected.endedAt
        day.workoutSavedAt = selected.savedAt; day.linkedDeviceWorkoutID = selected.linkedDeviceWorkoutID
    }
    static func select(_ id: UUID, in day: inout DayLog) -> Bool {
        guard day.workoutSessions?.contains(where: { $0.id == id }) == true else { return false }
        synchronize(&day); day.activeWorkoutSessionID = id; restoreActiveFields(&day); return true
    }
}
enum CloudMerge {
    static func merge(local: CloudState, remote: CloudState, base: CloudState?) throws -> CloudState {
        let localValue = try JSONValue.encode(local)
        let remoteValue = try JSONValue.encode(remote)
        let baseValue = try base.map { try JSONValue.encode($0) }
        let combined = mergeValue(localValue, remoteValue, baseValue) ?? remoteValue
        var result = try JSONDecoder().decode(CloudState.self, from: JSONEncoder().encode(combined))
        let deletedCustom = Set((result.deletedCustomExerciseIDs ?? []).map { $0.uppercased() })
        result.customExercises?.removeAll { deletedCustom.contains($0.id.uuidString.uppercased()) }
        let deletedExercises = Set((result.deletedExerciseIDs ?? []).map { $0.uppercased() })
        let deletedMeals = Set((result.deletedMealIDs ?? []).map { $0.uppercased() })
        for date in Array(result.days.keys) {
            result.days[date]?.exercises.removeAll { deletedExercises.contains($0.id.uuidString) }
            result.days[date]?.meals.removeAll { deletedMeals.contains($0.id.uuidString) }
            if var day = result.days[date] {
                for index in day.exercises.indices {
                    let deleted = Set((day.exercises[index].deletedSetIDs ?? []).map { $0.uppercased() })
                    day.exercises[index].sets.removeAll { deleted.contains($0.id.uuidString) }
                }
                // A filename without a remote ID is meaningful only on its own device.
                let localMeals: [UUID: Meal] = Dictionary(local.days[date]?.meals.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
                for index in day.meals.indices where day.meals[index].photoRemoteID == nil {
                    day.meals[index].photoFilename = localMeals[day.meals[index].id]?.photoFilename
                }
                if day.completedSets == 0 { day.linkedDeviceWorkoutID = nil }
                if let linked = day.linkedDeviceWorkoutID, day.health?.workouts.contains(where: { $0.id == linked }) != true {
                    day.linkedDeviceWorkoutID = nil
                }
                // A concurrent device may start a formerly empty session during deletion.
                // Restore any nonempty/started source session instead of deleting its real record.
                for source in [local.days[date], remote.days[date]].compactMap({ $0 }) {
                    for session in source.workoutSessions ?? [] where day.workoutSessions?.contains(where: { $0.id == session.id }) != true {
                        if !EmptyWorkoutSessionRules.canRemove(session.id, from: source) {
                            day.workoutSessions = (day.workoutSessions ?? []) + [session]
                        }
                    }
                }
                TrainingExecutionCapture.reconcile(&day, base: base?.days[date], local: local.days[date], remote: remote.days[date])
                result.days[date] = day
                if day.workoutSessions?.isEmpty == false {
                    WorkoutSessions.restoreActiveFields(&day)
                    WorkoutSessions.synchronize(&day)
                }
                try RecordIntegrity.validateConfirmation(&day, local: local.days[date], remote: remote.days[date])
                // Concurrent new reports can have different IDs. Retain both observations,
                // including the former latest; explicit tombstones decide deletion.
                day.weeklyReviewHistory = (day.weeklyReviewHistory ?? []) +
                    (local.days[date]?.weeklyReviews ?? []) + (remote.days[date]?.weeklyReviews ?? [])
                WeeklyVersions.reconcile(&day)
                result.days[date] = day
            }
        }
        let archivedJobs = Set(result.deletedAIJobIDs ?? [])
        result.aiJobs?.removeAll { archivedJobs.contains($0.id) }
        MealPlacement.reconcile(days: &result.days, base: base?.days ?? [:])
        return result
    }

    static func conflictCount(local: CloudState, remote: CloudState, base: CloudState?) throws -> Int {
        guard let base else { return 0 }
        func count(_ l: JSONValue?, _ r: JSONValue?, _ b: JSONValue?, key: String = "") -> Int {
            if l == r || l == b || r == b || key.hasPrefix("deleted") || key == "appliedAIJobs" || key == "aiJobs" { return 0 }
            if case .object(let left)? = l, case .object(let right)? = r {
                let baseline: [String: JSONValue]; if case .object(let value)? = b { baseline = value } else { baseline = [:] }
                return Set(left.keys).union(right.keys).reduce(0) { $0 + count(left[$1], right[$1], baseline[$1], key: $1) }
            }
            if ["exercises","sets","meals","drafts","workoutSessions","customExercises"].contains(key), case .array(let left)? = l, case .array(let right)? = r {
                let baseline: [JSONValue]; if case .array(let value)? = b { baseline = value } else { baseline = [] }
                let lm = indexed(left), rm = indexed(right), bm = indexed(baseline)
                return Set(lm.keys).union(rm.keys).reduce(0) { $0 + count(lm[$1],rm[$1],bm[$1]) }
            }
            return 1
        }
        return count(try JSONValue.encode(local), try JSONValue.encode(remote), try JSONValue.encode(base))
    }

    static func same<T: Encodable>(_ left: T, _ right: T) throws -> Bool {
        try JSONValue.encode(left) == JSONValue.encode(right)
    }

    private static func mergeValue(_ local: JSONValue?, _ remote: JSONValue?, _ base: JSONValue?, key: String = "") -> JSONValue? {
        if key == "coach" {
            // A finished task's response is immutable. Old readers omit this field.
            if let base { return base }
            return remote ?? local
        }
        if ["goalVersions", "planVersions", "insightEvents", "insightFeedback"].contains(key) {
            func values(_ item: JSONValue?) -> [JSONValue] { if case .array(let items)? = item { return items }; return [] }
            var records: [String: JSONValue] = [:]
            for value in values(base) + values(remote) + values(local) {
                if let id = id(value)?.lowercased(), records[id] == nil { records[id] = value }
            }
            return records.isEmpty && local == nil && remote == nil && base == nil ? nil : .array(records.keys.sorted().compactMap { records[$0] })
        }
        let unions = ["appliedAIJobs", "deletedExerciseIDs", "deletedMealIDs", "deletedMediaIDs", "deletedAIJobIDs", "deletedSetIDs", "deletedCustomExerciseIDs", "deletedWeeklyReviewIDs"]
        if unions.contains(key) {
            let l = strings(local); let r = strings(remote)
            return .array(Array(Set(l + r)).sorted().map { .string($0) })
        }
        // Never let a one-sided edit or an old client's omission rewrite a committed start target.
        if key == "executionBaseline" {
            if let base, case .object = base { return base }
            if case .object(let l)? = local, case .object(let r)? = remote {
                if case .number(let lt)? = l["capturedAt"], case .number(let rt)? = r["capturedAt"] { return lt <= rt ? local : remote }
            }
            return local ?? remote
        }
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        // Health summaries are indivisible observations, never merge metric fragments.
        if ["health", "weeklyReview", "bodyWeight", "mealCompletion", "planCycle", "nutritionTarget"].contains(key), case .object(let l)? = local, case .object(let r)? = remote {
            if case .number(let lt)? = l["updatedAt"], case .number(let rt)? = r["updatedAt"] {
                return lt >= rt ? local : remote
            }
            return local
        }
        if case .object(let l)? = local, case .object(let r)? = remote, l["unit"] != nil, r["unit"] != nil, l["updatedAt"] != nil, r["updatedAt"] != nil {
            if case .number(let lt)? = l["updatedAt"], case .number(let rt)? = r["updatedAt"] { return lt >= rt ? local : remote }
            return local
        }
        if case .object(let l)? = local, case .object(let r)? = remote, l["survey"] != nil, r["survey"] != nil {
            if case .number(let lt)? = l["updatedAt"], case .number(let rt)? = r["updatedAt"] { return lt >= rt ? local : remote }
            return local
        }
        if case .object(let l)? = local, case .object(let r)? = remote {
            let b: [String: JSONValue]
            if case .object(let values)? = base { b = values } else { b = [:] }
            var output: [String: JSONValue] = [:]
            for field in Set(l.keys).union(r.keys).union(b.keys) {
                output[field] = mergeValue(l[field], r[field], b[field], key: field)
            }
            // An avatar choice is one observation. Do not combine a new
            // default avatar with an old uploaded photo from another device.
            if l["nickname"] != nil && r["nickname"] != nil {
                let avatarKeys = ["avatarID", "avatarImage", "identityVersion"]
                let source = avatarKeys.allSatisfy { l[$0] == b[$0] } ? r : l
                for field in avatarKeys { output[field] = source[field] }
            }
            // A meal's values and known/unknown status form one observation, including manual meals.
            if l["category"] != nil, l["calories"] != nil {
                let nutritionKeys = ["components", "consumedFraction", "calories", "protein", "carbs", "fat", "nutritionKnown"]
                let source = nutritionKeys.allSatisfy { l[$0] == b[$0] } ? r : l
                for field in nutritionKeys { output[field] = source[field] }
                let placementKeys = ["placementConfirmedAt", "placementConflictDates"]
                let placementSource = placementKeys.allSatisfy { l[$0] == b[$0] } ? r : l
                for field in placementKeys { output[field] = placementSource[field] }
            }
            return .object(output)
        }
        if ["exercises", "sets", "meals", "drafts", "aiJobs", "workoutSessions", "customExercises", "weeklyReviewHistory"].contains(key),
           case .array(let l)? = local, case .array(let r)? = remote {
            let b: [JSONValue]
            if case .array(let values)? = base { b = values } else { b = [] }
            let lm = indexed(l), rm = indexed(r), bm = indexed(b)
            var seen = Set<String>()
            let order = (r + l + b).compactMap(id).filter { seen.insert($0).inserted }
            return .array(order.compactMap { mergeValue(lm[$0], rm[$0], bm[$0]) })
        }
        // Deletion wins when the record was present at the common baseline.
        if base != nil && (local == nil || remote == nil) { return nil }
        return local ?? remote
    }

    private static func id(_ value: JSONValue) -> String? {
        guard case .object(let fields) = value else { return nil }
        return fields["id"]?.string
    }
    private static func indexed(_ values: [JSONValue]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for value in values { if let key = id(value) { result[key] = value } }
        return result
    }
    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(\.string)
    }
}
struct CloudMergeWork: @unchecked Sendable {
    let local: CloudState
    let remote: CloudState
    let base: CloudState?
}
struct CloudMergeComputation: @unchecked Sendable {
    let state: CloudState
    let conflictBackup: Data?
    let conflicts: Int
}
struct CloudComparisonWork: @unchecked Sendable {
    let left: CloudState
    let right: CloudState
}
enum CloudBackgroundWork {
    static func merge(_ input: CloudMergeWork) async throws -> CloudMergeComputation {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let count = try CloudMerge.conflictCount(local: input.local, remote: input.remote, base: input.base)
            let merged = try CloudMerge.merge(local: input.local, remote: input.remote, base: input.base)
            let backup: Data?
            if count > 0 { backup = try JSONEncoder().encode(input.remote) } else { backup = nil }
            try Task.checkCancellation()
            return CloudMergeComputation(state: merged, conflictBackup: backup, conflicts: count)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func same(_ input: CloudComparisonWork) async throws -> Bool {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try CloudMerge.same(input.left, input.right)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
enum CloudSyncError: LocalizedError {
    case message(String), busy(String)
    var errorDescription: String? {
        switch self { case .message(let text), .busy(let text): return text }
    }
}

@MainActor final class StoreFixture {
 var state:CloudState;var generation=UUID();var localEditRevision=UUID();var aiService:JobsFixture?=JobsFixture()
 init(_ state:CloudState) { self.state=state }
 func snapshot(includeLocalPhotos:Bool=false)->CloudState { state }
 func checkContext(_ ticket:UUID,_ id:Int)throws { if ticket != generation { throw CancellationError() } }
}
@MainActor final class JobsFixture { var cloudChangeID=UUID() }
enum ControlledWork {
 @MainActor static var calls=0
 @MainActor static var before:((Int)->Void)?
 @MainActor static func merge(_ input:CloudMergeWork) async throws -> CloudMergeComputation {
  calls+=1;before?(calls);return try await CloudBackgroundWork.merge(input)
 }
}
extension StoreFixture {

func mergeCloudSnapshot(_ remote: CloudState, base: CloudState?, ticket: UUID, userID: Int) async throws -> CloudMergeComputation {
        for _ in 0..<4 {
            let revision = localEditRevision, jobsRevision = aiService?.cloudChangeID
            let input = CloudMergeWork(local: snapshot(includeLocalPhotos: true), remote: remote, base: base)
            let result = try await ControlledWork.merge(input)
            try checkContext(ticket, userID)
            if revision == localEditRevision && jobsRevision == aiService?.cloudChangeID { return result }
        }
        throw CloudSyncError.busy("记录仍在更新，稍后继续同步。")
    }
}

struct TargetState { var nutritionTarget:NutritionTarget? }
struct TargetStore { var state=TargetState();var day=DayLog();func log(for date:Date)->DayLog { day }

func reportNutritionTarget(on date: Date) -> NutritionTarget? {
        let historical = log(for: date).nutritionTarget
        let current = state.nutritionTarget
        if historical?.generalGuidanceOnly == true { return historical }
        if current?.generalGuidanceOnly == true { return current }
        return historical ?? current
    }
}

final class RemovalStore {
 var day:DayLog;var message:String?;var writesAllowed=true
 init(_ day:DayLog) { self.day=day }
 func log(for date:Date)->DayLog { day }
 // Only persistence is substituted: production deletion and session rules run below.
 func mutate(_ date:Date,edit:(inout DayLog)->Void)->Bool {
  let before=day;edit(&day)
  if !writesAllowed { day=before;return false }
  WorkoutSessions.synchronize(&day);return true
 }

func removeEmptyWorkoutSession(_ id: UUID, on date: Date) -> Bool {
        guard EmptyWorkoutSessionRules.canRemove(id, from: log(for: date)) else {
            message = "只有未开始、没有动作的空白场次可以删除；已有训练记录会保留。"; return false
        }
        return mutate(date) { day in
            WorkoutSessions.synchronize(&day)
            day.workoutSessions?.removeAll { $0.id == id }
            if day.activeWorkoutSessionID == id { day.activeWorkoutSessionID = day.workoutSessions?.last?.id }
            WorkoutSessions.restoreActiveFields(&day)
        }
    }
}

var checks=0
func check(_ value:Bool,_ label:String) { if !value { fatalError(label) };checks+=1 }
let now=Date(timeIntervalSince1970:1_800_000_000)
var timer=WorkoutStopwatch();timer.start(at:now);timer.pause(at:now.addingTimeInterval(7200))
check(timer.elapsed(at:now)==7200,"two-hour timer not truncated")
timer.start(at:now);timer.pause(at:now.addingTimeInterval(300));check(timer.elapsed(at:now)==7500,"paused timer resumes consistently")
check(RecordLimits.valid(TrainingSet(reps:300)),"actual repetition range includes 300")
check(RecordLimits.valid(TrainingSet(reps:0,durationSeconds:21600)),"six-hour actual timer accepted")
check(!RecordLimits.valid(TrainingSet(reps:0,durationSeconds:21601)),"invalid actual time rejected")
check(!RecordLimits.valid(TrainingSet(weight:.infinity)),"non-finite actual weight rejected")
let first=UUID(),second=UUID()
var empty=DayLog(workoutSessions:[WorkoutSession(id:first),WorkoutSession(id:second)],activeWorkoutSessionID:second)
check(EmptyWorkoutSessionRules.canRemove(second,from:empty),"blank extra session removable")
var started=empty;started.workoutSessions?[1].startedAt=now
check(!EmptyWorkoutSessionRules.canRemove(second,from:started),"started session protected")
var occupied=empty;occupied.exercises=[Exercise(name:"训练",muscle:"胸",sets:[TrainingSet()],workoutSessionID:second)]
check(!EmptyWorkoutSessionRules.canRemove(second,from:occupied),"unstarted session with action protected")
var only=empty;only.workoutSessions=[WorkoutSession(id:second)]
check(!EmptyWorkoutSessionRules.canRemove(second,from:only),"last session protected")
let removal=RemovalStore(empty)
check(removal.removeEmptyWorkoutSession(second,on:now) && removal.day.activeWorkoutSessionID==first && removal.day.workoutSessions?.count==1,"deletion restores the remaining active session")
let failedRemoval=RemovalStore(empty);failedRemoval.writesAllowed=false
check(!failedRemoval.removeEmptyWorkoutSession(second,on:now) && failedRemoval.day.workoutSessions?.count==2 && failedRemoval.day.activeWorkoutSessionID==second,"failed storage keeps original sessions")
var custom=CustomExercise(name:"私人动作",muscle:"胸",unit:"次")
let restored=CustomBackupRules.recover([custom,custom],into:[],deleted:[])
check(restored.count==1 && restored[0].id==custom.id,"definitions restored once with original ID")
var edited=custom;edited.name="本机修改"
check(CustomBackupRules.recover([custom],into:[edited],deleted:[]).first?.name=="本机修改","backup cannot replace current definition")
check(CustomBackupRules.recover([custom],into:[],deleted:[custom.id.uuidString.lowercased()]).isEmpty,"deleted definition cannot resurrect")
custom.name="";check(CustomBackupRules.recover([custom],into:[],deleted:[]).isEmpty,"invalid definition rejected")
let running=Exercise(name:"跑步",muscle:"有氧",sets:[TrainingSet(reps:0,completed:true,durationSeconds:1200)],libraryID:"0685",workoutSessionID:first)
let lifting=Exercise(name:"卧推",muscle:"胸",sets:[TrainingSet(reps:10,completed:true)],libraryID:"0001",workoutSessionID:first)
var day=DayLog(exercises:[running],workoutStartedAt:now,workoutEndedAt:now.addingTimeInterval(1200),workoutSessions:[WorkoutSession(id:first),WorkoutSession(id:second,linkedDeviceWorkoutID:"reserved")],activeWorkoutSessionID:first)
let source=HealthSource(id:"watch",name:"手表")
func watch(_ id:String,_ kind:String)->DeviceWorkout { DeviceWorkout(id:id,name:"测试",start:now,end:now.addingTimeInterval(1200),minutes:20,source:source,activityKind:kind) }
let candidates=[watch("run","running"),watch("lift","strength"),watch("reserved","running")]
check(WorkoutAssociation.suggestedIDs(for:day,workouts:candidates)==["run"],"cardio matches running and excludes other session's linked workout")
day.exercises=[lifting];check(WorkoutAssociation.suggestedIDs(for:day,workouts:candidates)==["lift"],"strength still matches strength")
day.exercises=[lifting,running];check(WorkoutAssociation.suggestedIDs(for:day,workouts:candidates).isEmpty,"mixed workout requires explicit selection")
day.exercises[0].customExerciseID=UUID();check(WorkoutAssociation.expectedKind(for:day)==nil,"unknown private movement not guessed")
let key="2027-01-15"
let base=CloudState(days:[key:empty]);var local=base;local.days[key]?.workoutSessions?.removeLast()
let deleted=try CloudMerge.merge(local:local,remote:base,base:base)
check(deleted.days[key]?.workoutSessions?.count==1,"sync preserves intended blank deletion")
var remote=base;remote.days[key]?.workoutSessions?[1].startedAt=now
let concurrent=try CloudMerge.merge(local:local,remote:remote,base:base)
check(concurrent.days[key]?.workoutSessions?.count==2 && concurrent.days[key]?.workoutSessions?.last?.startedAt==now,"concurrent start survives blank deletion")
var target=TargetStore();target.state.nutritionTarget=NutritionTarget(calories:2100);target.day.nutritionTarget=NutritionTarget(calories:1800)
check(target.reportNutritionTarget(on:now)?.calories==1800,"historical target takes precedence")
target.state.nutritionTarget=NutritionTarget(generalGuidanceOnly:true)
check(target.reportNutritionTarget(on:now)?.generalGuidanceOnly==true,"special-background safeguard retained")
let background=try await CloudBackgroundWork.merge(.init(local:local,remote:base,base:base))
check(try CloudMerge.same(background.state,deleted),"background merge equals synchronous production merge")
let races=Task { @MainActor in
 let fixture=StoreFixture(base);let ticket=fixture.generation;ControlledWork.calls=0
 ControlledWork.before={ call in if call==1 { fixture.state.days[key]?.exercises=[lifting];fixture.localEditRevision=UUID() } }
 let merged=try await fixture.mergeCloudSnapshot(base,base:base,ticket:ticket,userID:1)
 check(ControlledWork.calls==2 && merged.state.days[key]?.exercises.count==1,"edit during detached merge retries and retains new record")
 ControlledWork.calls=0;ControlledWork.before={ _ in fixture.localEditRevision=UUID() }
 do { _=try await fixture.mergeCloudSnapshot(base,base:base,ticket:ticket,userID:1);fatalError("unbounded changing state should wait") }
 catch CloudSyncError.busy(_) { check(ControlledWork.calls==4,"continual changes produce bounded retry and keep records") }
 ControlledWork.before=nil
}
try await races.value
print("v77 production rule checks passed: \(checks)")
