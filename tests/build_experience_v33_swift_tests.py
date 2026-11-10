"""Append v33 regressions to the production Foundation rule harness."""
from pathlib import Path
import runpy,sys
out=Path(sys.argv[1]);runpy.run_path(str(Path(__file__).with_name('build_phase1_swift_tests.py')))
s=out.read_text('utf-8')
s+=r'''
do {
    let measured = AppStore()
    var profile = measured.state.profile; profile.weight = 72.4
    check(measured.saveProfile(profile, initialWeightDate: Date()), "onboarding saves profile and confirmed weight together")
    let date = ClubDates.key(Date())
    check(measured.state.days[date]?.bodyWeight?.kilograms == 72.4, "confirmed onboarding weight becomes a daily measurement")
    profile.weight = 73
    check(measured.saveProfile(profile, initialWeightDate: Date()), "onboarding retry succeeds")
    check(measured.state.days[date]?.bodyWeight?.kilograms == 72.4, "existing measurement is never overwritten on retry")
    let unmeasured = AppStore()
    check(unmeasured.saveProfile(profile), "estimated profile can be saved without measurement")
    check(unmeasured.state.days[date]?.bodyWeight == nil, "profile default does not manufacture a weight record")
    let failing = AppStore(); failing.allowPersistence = false
    let previous = failing.state
    check(!failing.saveProfile(profile, initialWeightDate: Date()), "measurement persistence failure is reported")
    check(try CloudMerge.same(previous, failing.state), "failed transaction rolls back profile and weight")
    let future = ClubDates.calendar.date(byAdding: .day, value: 1, to: Date())!
    check(!unmeasured.saveProfile(profile, initialWeightDate: future), "future onboarding measurement is rejected")
    let past = ClubDates.calendar.date(byAdding: .day, value: -1, to: Date())!
    check(unmeasured.saveProfile(profile, initialWeightDate: past), "actual recent measurement keeps its date")
    check(unmeasured.state.days[ClubDates.key(past)]?.bodyWeight?.kilograms == 73, "past measurement is not assigned to today")
    var identity = profile; identity.avatarID = "avatar-12"; identity.avatarImage = Data([1,2,3])
    let roundtrip = try JSONDecoder().decode(MemberProfile.self, from: JSONEncoder().encode(identity))
    check(roundtrip.avatarID == identity.avatarID && roundtrip.avatarImage == identity.avatarImage, "avatar survives Codable roundtrip")
    check(identity.aiProfile.avatarImage == nil && identity.aiProfile.avatarID == nil, "avatar is excluded from AI input")
    var renamed = identity; renamed.nickname = "另一个昵称"
    check(try CloudMerge.same(identity.aiProfile, renamed.aiProfile), "identity edits do not orphan a plan job")
    let legacyData = try JSONSerialization.data(withJSONObject: ["nickname":"旧成员","age":28,"height":175,"weight":68,"goal":"增肌","experience":"新手","venue":"健身房","daysPerWeek":3,"focus":"全身"])
    let legacy = try JSONDecoder().decode(MemberProfile.self, from: legacyData)
    check(legacy.avatarID == nil && legacy.avatarImage == nil, "old profile decodes without avatar fields")
    let oldExercise = Exercise(name: "English-only legacy name", muscle: "手臂", libraryID: "0294")
    check(oldExercise.displayName != oldExercise.name && oldExercise.displayName.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) }, "historical library exercise resolves to Chinese")
    check(oldExercise.name == "English-only legacy name", "translation preserves historical raw records")
    check(ExerciseNames.display("自定义划船") == "自定义划船", "custom Chinese name remains readable")
    var avatarBase = CloudState(SavedState())
    avatarBase.profile.identityVersion = 1
    avatarBase.profile.avatarImage = Data([9,8,7])
    var avatarLocal = avatarBase; avatarLocal.profile.avatarImage = nil; avatarLocal.profile.avatarID = "avatar-06"
    var avatarRemote = avatarBase; avatarRemote.profile.avatarImage = Data([6,5,4]); avatarRemote.profile.nickname = "云端新昵称"
    let avatarMerged = try CloudMerge.merge(local: avatarLocal, remote: avatarRemote, base: avatarBase)
    check(avatarMerged.profile.avatarImage == nil && avatarMerged.profile.avatarID == "avatar-06", "concurrent avatar edits never combine default choice and old photo")
    check(avatarMerged.profile.nickname == "云端新昵称", "unrelated cloud nickname edit survives avatar merge")
    let remoteOnly = try CloudMerge.merge(local: avatarBase, remote: avatarRemote, base: avatarBase)
    check(remoteOnly.profile.avatarImage == Data([6,5,4]), "remote-only avatar change is accepted")
    print("PASS v33 confirmed measurements, rollback, avatar compatibility and Chinese display rules")
}
'''
out.write_text(s,'utf-8')
print('v33 production-rule Swift harness generated; run with xcrun swift on Mac')
