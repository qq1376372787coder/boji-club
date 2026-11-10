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

struct TrainingSet: Identifiable, Codable, Equatable {
    var id = UUID()
    var weight: Double = 0
    var reps: Int = 10
    var completed = false
    var durationSeconds: Int? = nil
    var validCompletion: Bool { completed && (durationSeconds.map { $0 > 0 } ?? (reps > 0)) }
    var volume: Double { validCompletion && durationSeconds == nil ? weight * Double(reps) : 0 }
}

struct AIPlanSet: Codable, Equatable { var weight: Double?; var reps: Int; var durationSeconds: Int? = nil
    var repetitionLabel: String { durationSeconds.map { "\($0) 秒" } ?? "\(reps) 次" }
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

enum NewPlanDateRules {
    static func earliestStart(replacingProfileWeek: Bool = false, now: Date = Date()) -> Date {
        let today = ClubDates.calendar.startOfDay(for: now)
        return replacingProfileWeek ? (ClubDates.calendar.date(byAdding: .day, value: 1, to: today) ?? today) : today
    }
    static func isValidStart(_ key: String, replacingProfileWeek: Bool = false, now: Date = Date()) -> Bool {
        guard let date = ClubDates.date(fromKey: key) else { return false }
        return date >= earliestStart(replacingProfileWeek: replacingProfileWeek, now: now)
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
        if meals.count > 1 { hint.problem = "这段话提到了多餐，请打开“一次识别多餐”，或只填写一餐。" }
        else if let meal = meals.first { hint.category = meal }
        if ["明天", "明早", "明晚", "后天", "明年", "后年"].contains(where: { text.contains($0) }) {
            hint.problem = "这里记录已经吃过的餐食，未来饮食不能记为已吃。"
        }
        let explicit = explicitDates(in: text, now: now)
        hint.requiresDateConfirmation = explicit.mentioned
        if explicit.invalid { hint.problem = "这段话中的日期无效，请核对年月日后再识别。" }
        let uniqueDates = Set(explicit.dates.map(ClubDates.key))
        if uniqueDates.count > 1 { hint.problem = "这段话提到了不同日期，请打开“一次识别多餐”，或分开记录。" }
        else if let day = explicit.dates.first { hint.date = day }
        let relative = [("前天", ["前天"]), ("昨天", ["昨天", "昨晚", "昨早"]), ("今天", ["今天", "今早", "今晚"])].filter { group in group.1.contains { text.contains($0) } }.map { $0.0 }
        if relative.count > 1 { hint.problem = "这段话提到了不同日期，请打开“一次识别多餐”，或分开记录。" }
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


enum RecordLimits { static let maximumWeight = 2000.0
    static let maximumReps = 1000
    static let maximumSeconds = 6 * 3600
    static let maximumNutrition = 100000.0
    static func valid(_ set: TrainingSet) -> Bool {
        set.weight.isFinite && (0...maximumWeight).contains(set.weight) && (0...maximumReps).contains(set.reps)
            && (set.durationSeconds.map { (0...maximumSeconds).contains($0) } ?? true)
    } }


enum AccountError: Error { case message(String) }
enum CloudMerge {
    static func same<T:Encodable>(_ a:T,_ b:T) throws -> Bool {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(a)==encoder.encode(b)
    }
}
struct FixtureExercise { var id:UUID; var sets:[TrainingSet] }
struct FixtureDay {
    var activeWorkoutSessionID:UUID?;var workoutStartedAt:Date?;var exercises:[FixtureExercise]
    var completedSets:Int { exercises.flatMap(\.sets).filter(\.validCompletion).count }
    var trainingLog:FixtureDay { self }
}
final class TimerStore {
    var editingAccountID:Int?=1;var allowBegin=true;var beginCount=0
    var day:FixtureDay
    init(exerciseID:UUID,set:TrainingSet) { day=FixtureDay(exercises:[FixtureExercise(id:exerciseID,sets:[set])]) }
    func log(for date:Date)->FixtureDay { day }
    func beginWorkout(on date:Date)->Bool {
        guard allowBegin else { return false }
        beginCount+=1;day.workoutStartedAt=Date()
        if day.activeWorkoutSessionID==nil { day.activeWorkoutSessionID=UUID() }
        return true
    }
    func takeMessage(fallback:String)->String { fallback }
}
final class TimerFixture {
    var date=Date();let exerciseID=UUID()
    var original=TrainingSet(reps:0,durationSeconds:30)
    lazy var store=TimerStore(exerciseID:exerciseID,set:original)
    var stopwatch=WorkoutStopwatch();var owner:Int?=1;var sessionID:UUID?;var error:String?
    var saveAllowed=true;var saved:TrainingSet?;var dismissed=false
    func save(_ set:TrainingSet)->Bool { if saveAllowed { saved=set };return saveAllowed }
    func dismiss() { dismissed=true }

var unchanged: Bool {
        guard owner != nil, owner == store.editingAccountID, sessionID == store.log(for: date).activeWorkoutSessionID,
              let current = store.log(for: date).trainingLog.exercises.first(where: { $0.id == exerciseID })?.sets.first(where: { $0.id == original.id }) else { return false }
        return (try? CloudMerge.same(current, original)) == true
    }
func toggleTimer() {
        guard unchanged, !ClubDates.isFuture(date) else { error = "账号、日期或训练组已变化，请重新打开。"; return }
        error = nil
        if stopwatch.isRunning { stopwatch.pause(); return }
        let day = store.log(for: date).trainingLog
        if day.workoutStartedAt == nil && day.completedSets == 0 && ClubDates.calendar.isDateInToday(date) {
            guard store.beginWorkout(on: date) else {
                error = store.takeMessage(fallback: "训练开始时间未保存，请重试。"); return
            }
            // This synchronous mutation can assign the first session ID.
            sessionID = store.log(for: date).activeWorkoutSessionID
        }
        guard unchanged else { error = "这组记录已变化，请关闭后重新核对。"; return }
        stopwatch.start()
    }
func registerTimedSet() {
        guard unchanged else { error = "这组记录已变化，计时不会覆盖它，请重新打开核对。"; return }
        stopwatch.pause()
        guard stopwatch.elapsed() >= 1 else { error = "请记录至少 1 秒的实际完成时间。"; return }
        guard stopwatch.elapsed() <= Double(RecordLimits.maximumSeconds) else {
            error = "单组最多登记 6 小时。这次计时已暂停，不会缩短后保存，请核对后分段记录。"; return
        }
        var updated = original
        updated.durationSeconds = max(1, Int(stopwatch.elapsed())); updated.reps = 0; updated.completed = true
        if save(updated) { dismiss() } else { error = store.takeMessage(fallback: "保存失败，计时已暂停，可以重试。") }
    }
}
struct ReviewPhoto: Codable, Identifiable {
    var id = UUID()
    var pose: String
    var filename: String
}
struct WeeklyReview:Codable { var id=UUID();var photos:[ReviewPhoto]=[];var result:String?;var jobID:String? }
final class PhotoFixture {
    var busy=false;var canSave=true;var message:String?;var failPersistence=false
    var reviews:[WeeklyReview]=[];var folder:URL?
    init(_ folder:URL) { self.folder=folder }
    func persist() throws {
        if failPersistence { throw AccountError.message("injected write failure") }
        try JSONEncoder().encode(reviews).write(to:folder!.appendingPathComponent("reviews.json"),options:.atomic)
    }

func photo(_ value: ReviewPhoto) -> Data? {
        guard value.filename == value.id.uuidString.lowercased()+".jpg", let folder else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(value.filename))
    }
func addPhoto(_ data: Data, pose: String, to id: UUID) throws {
        guard !busy, let folder, let i = reviews.firstIndex(where: { $0.id == id && $0.result == nil && $0.jobID == nil }) else { throw AccountError.message("请先创建或重新打开复盘草稿。") }
        let photoID = UUID(); let filename = photoID.uuidString.lowercased()+".jpg"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
        var copy = reviews[i]; copy.photos.removeAll { $0.pose == pose }
        copy.photos.append(ReviewPhoto(id: photoID, pose: pose, filename: filename))
        let previous = reviews[i]; reviews[i] = copy
        do { try persist() }
        catch { reviews[i] = previous; try? FileManager.default.removeItem(at: folder.appendingPathComponent(filename)); throw error }
        // Updated drafts can share a photo with earlier reports. Delete only files
        // that no persisted review still references, after the new JSON is durable.
        if !cleanupUnreferencedPhotos() { message = "新照片已保存，部分不再使用的旧照片会在解锁后继续清理。" }
    }
func removePhotos(_ id: UUID) throws {
        guard !busy, let i = reviews.firstIndex(where: { $0.id == id }), folder != nil else { return }
        let photos = reviews[i].photos; reviews[i].photos = []
        do { try persist() } catch { reviews[i].photos = photos; throw error }
        if !cleanupUnreferencedPhotos() { throw AccountError.message("照片已从记录移除，但本机文件尚未清理；解锁手机后重新打开 App 会继续处理。") }
    }
func cleanupUnreferencedPhotos() -> Bool {
        guard canSave, let folder else { return true }
        guard FileManager.default.fileExists(atPath: folder.path) else { return true }
        let retained = Set(reviews.flatMap(\.photos).map(\.filename))
        do {
            var complete = true
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                guard file.pathExtension == "jpg", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      name == id.uuidString.lowercased()+".jpg", !retained.contains(name) else { continue }
                do { try FileManager.default.removeItem(at: file) } catch { complete = false }
            }
            return complete
        } catch { return false }
    }
}



var checks=0
func check(_ condition:Bool,_ message:String) { guard condition else { fatalError(message) };checks+=1 }
let now=ClubDates.date(fromKey:"2026-10-14")!.addingTimeInterval(12*3600)
func hint(_ text:String)->MealDescriptionHint { MealDescriptionUnderstanding.inspect(text,date:now,category:"早餐",now:now) }
for text in ["10月13日早餐吃了两个鸡蛋","10 月 13 号早餐吃了两个鸡蛋","十月十三日早餐吃了两个鸡蛋","2026年10月13日早餐吃了两个鸡蛋","二〇二六年十月十三日早餐吃了两个鸡蛋","2026-10-13早餐吃了两个鸡蛋","2026/10/13早餐吃了两个鸡蛋"] {
    check(ClubDates.key(hint(text).date)=="2026-10-13" && hint(text).problem==nil,text)
}
check(hint("10月14日早餐吃了鸡蛋").requiresDateConfirmation,"explicit same-day date requires review")
check(hint("10月15日早餐吃了鸡蛋").problem != nil,"future date rejected")
check(hint("明年10月13日吃了鸡蛋").problem != nil,"future year rejected")
check(hint("10月13日今天吃了鸡蛋").problem != nil,"conflicting relative and calendar dates rejected")
check(hint("10月13日昨天吃了鸡蛋").problem==nil,"equivalent dates accepted")
check(hint("10月12日和10月13日吃了鸡蛋").problem != nil,"different dates require batch")
check(hint("2月30日吃了鸡蛋").problem != nil,"invalid day cannot normalize into March")
check(hint("2026年2月29日吃了鸡蛋").problem != nil,"invalid leap date rejected")
check(hint("2024年2月29日吃了鸡蛋").problem==nil,"valid leap date retained")
check(ClubDates.key(hint("去年十月十三日吃了鸡蛋").date)=="2025-10-13","explicit past year")
check(!hint("吃了1/2碗饭和2.5克油").requiresDateConfirmation,"quantities are not dates")
check(ClubDates.key(hint("昨天早餐吃了鸡蛋").date)=="2026-10-13","relative date retained")
check(hint("今天早上加餐吃了鸡蛋").category=="加餐","morning snack remains a snack")
check(NewPlanDateRules.isValidStart("2026-10-14",now:now),"local today valid")
check(!NewPlanDateRules.isValidStart("2026-10-13",now:now),"local past rejected")
check(NewPlanDateRules.isValidStart("2027-01-01",now:now),"future year valid")
check(!NewPlanDateRules.isValidStart("2026-02-30",now:now),"invalid plan date rejected")
check(!NewPlanDateRules.isValidStart("2026-10-14",replacingProfileWeek:true,now:now),"profile replacement protects today before requesting AI")
check(NewPlanDateRules.isValidStart("2026-10-15",replacingProfileWeek:true,now:now),"profile replacement can start tomorrow")
let counted=ExerciseMeasurement.planReplacementSets(count:4,name:"哑铃卧推",query:"dumbbell bench press",recordingUnit:"reps")
check(counted.count==4 && counted.allSatisfy { $0.durationSeconds==nil && $0.reps==10 && $0.weight==nil },"timed -> counted resets target and weight")
let timed=ExerciseMeasurement.planReplacementSets(count:4,name:"平板支撑",query:"plank",recordingUnit:"time")
check(timed.count==4 && timed.allSatisfy { $0.durationSeconds==30 && $0.reps==0 && $0.weight==nil },"counted -> timed resets target and weight")
check(ExerciseMeasurement.planReplacementSets(count:2,name:"跑步",query:"run",recordingUnit:"time",trainingType:"有氧").allSatisfy { $0.durationSeconds==600 },"cardio uses existing catalog defaults")
let timer=TimerFixture()
check(timer.unchanged && timer.sessionID==nil,"first timer accepts no session before start")
timer.toggleTimer()
check(timer.unchanged && timer.sessionID != nil && timer.stopwatch.isRunning,"first start binds newly created session")
timer.toggleTimer()
check(!timer.stopwatch.isRunning && timer.error==nil,"first timer can pause")
timer.toggleTimer()
check(timer.stopwatch.isRunning && timer.store.beginCount==1,"resume never starts another workout")
timer.stopwatch=WorkoutStopwatch();timer.stopwatch.start(at:Date().addingTimeInterval(-3))
timer.saveAllowed=false;timer.registerTimedSet()
check(timer.saved==nil && !timer.dismissed && timer.error != nil && !timer.stopwatch.isRunning,"failed save retains paused timer")
timer.saveAllowed=true;timer.registerTimedSet()
check(timer.saved?.validCompletion==true && timer.dismissed,"failed save can be retried")
let failed=TimerFixture();failed.store.allowBegin=false;failed.toggleTimer()
check(!failed.stopwatch.isRunning && failed.sessionID==nil && failed.error != nil,"start persistence failure does not start clock")
let changed=TimerFixture();changed.toggleTimer();changed.store.day.activeWorkoutSessionID=UUID()
changed.stopwatch.start(at:Date().addingTimeInterval(-3));changed.registerTimedSet()
check(changed.saved==nil && changed.error != nil,"another session cannot accept stale timer")
let other=TimerFixture();other.store.editingAccountID=2;other.toggleTimer()
check(!other.stopwatch.isRunning && other.store.beginCount==0,"account switch cannot start stale timer")
let folder=FileManager.default.temporaryDirectory.appendingPathComponent("boji-v74-"+UUID().uuidString)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:folder) }
let photos=PhotoFixture(folder);let id=UUID()
let old=ReviewPhoto(id:id,pose:"front",filename:id.uuidString.lowercased()+".jpg")
try Data("old-photo".utf8).write(to:folder.appendingPathComponent(old.filename))
var first=WeeklyReview(photos:[old],result:"completed")
let draft=WeeklyReview(photos:[old])
photos.reviews=[first,draft];try photos.persist()
try photos.addPhoto(Data("new-photo".utf8),pose:"front",to:draft.id)
check(photos.photo(old)==Data("old-photo".utf8),"replace draft preserves photo still used by older report")
let new=photos.reviews[1].photos[0]
check(photos.photo(new)==Data("new-photo".utf8),"replacement saved and readable")
try photos.removePhotos(first.id)
check(photos.photo(old)==nil && photos.photo(new) != nil,"only last old reference deletion removes old file")
let before=photos.reviews[1].photos
photos.failPersistence=true
do { try photos.addPhoto(Data("failure-photo".utf8),pose:"front",to:draft.id);fatalError("injected failure was not thrown") } catch {}
check(photos.reviews[1].photos.map(\.id)==before.map(\.id),"failed JSON persistence restores old references")
check(photos.photo(new) != nil,"failed replacement keeps existing photo")
let remaining=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension=="jpg" }
check(remaining.count==1,"failed replacement leaves no new orphan")
print("PASS \(checks) v74 production-rule checks. SwiftUI and device behavior still require TestFlight.")
