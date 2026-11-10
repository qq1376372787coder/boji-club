"""Cover the real no-photo prompt/validator mismatch without paid provider requests."""
import base64,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
import ai_core

def request(photos=False):
    payload={'profile':{'age':28,'height':175,'weight':68,'daysPerWeek':2,'trainingDays':[1,3],'homeTrainingDays':[],'goal':'增肌塑形','experience':'新手','venue':'健身房','equipment':'','focus':'全身'},
             'survey':{'weight':68,'waist':None,'bodyFat':None,'bodyFatSource':'','fatigue':'适中','pain':'无疼痛','difficulty':'合适','diet':'基本能坚持','notes':'','days':2},
             'days':[],'upcoming':[],'photos':[],'history':[]}
    if photos:payload['photos']=[{'label':'正面','image_base64':base64.b64encode(b'\xff\xd8\xff'+b'synthetic'*10).decode()}]
    return ai_core.validate_request({'kind':'weekly_review','date':'2026-10-02','payload':payload})

def result():
    return {'kind':'weekly_review','summary':'本周记录不足','training':'暂不调整','nutrition':'请继续记录','recovery':'关注身体感受','appearance':'','photoFeedback':[],
            'decision':'insufficient','reason':'暂未提供完整记录','notes':[],'sessions':[]}

class WeeklyNoPhotoRegression(unittest.TestCase):
    def test_text_only_compliant_result_succeeds_with_safe_fallback(self):
        value=ai_core.validate_result(request(),result())
        self.assertEqual(value['decision'],'insufficient')
        self.assertIn('未提供照片',value['appearance'])
        self.assertEqual(value['photoFeedback'],[])
    def test_photo_review_still_requires_observation_text(self):
        with self.assertRaises(ai_core.AIError):ai_core.validate_result(request(True),result())
    def test_other_required_fields_are_not_weakened(self):
        for key in ['summary','training','nutrition','recovery','reason']:
            with self.subTest(key=key):
                value=result();value[key]=''
                with self.assertRaises(ai_core.AIError):ai_core.validate_result(request(),value)



from automation_core import DataIntegrityEngine


class TestDataIntegrityEngine(unittest.TestCase):
    def setUp(self):
        self.engine = DataIntegrityEngine()

    def test_clean_state_has_zero_issues(self):
        clean_state = {
            "user_id": "user_123",
            "revision": "rev_100",
            "timeZone": "Asia/Shanghai",
            "profile": {"age": 28, "gender": "male", "height": 178, "weight": 72.5},
            "profiles_table_projection": {"age": 28, "gender": "male", "height": 178, "weight": 72.5},
            "days": {
                "2026-10-18": {
                    "training_confirmed": True,
                    "activeWorkoutSessionID": "sess-1",
                    "exercises": [{"id": "ex-1", "sets": [{"weight": 50, "reps": 10, "completed": True}]}],
                    "workoutSessions": [{"id": "sess-1", "exercises": [{"id": "ex-1", "sets": [{"weight": 50, "reps": 10, "completed": True}]}]}],
                    "meals": [{"id": "meal-1", "components": [{"name": "鸡蛋", "calories": 140, "protein": 12, "carbs": 1, "fat": 10}], "nutrition": {"calories": 140, "protein": 12, "carbs": 1, "fat": 10}}]
                }
            },
            "planCycle": {
                "startDate": "2026-10-18",
                "endDate": "2026-10-24",
                "plannedDates": ["2026-10-18"]
            },
            "training_statistics": {"confirmed_sessions_count": 1},
            "membership": {"is_premium": True},
            "verified_receipts": [{"expires_at": 9999999999}]
        }
        report = self.engine.scan(clean_state)
        self.assertEqual(report.open_issues_count, 0)
        self.assertEqual(len(report.issues), 0)
        self.assertIn("DI-001", report.rules_checked)
        self.assertIn("DI-011", report.rules_deferred)

    def test_stable_issue_ids_on_repeated_scans(self):
        dirty_state = {
            "user_id": "u-42",
            "revision": "v1",
            "days": {
                "2026-10-18": {"exercises": [{"id": "dup-id"}]},
                "2026-10-19": {"exercises": [{"id": "dup-id"}]}
            }
        }
        report1 = self.engine.scan(dirty_state)
        report2 = self.engine.scan(dirty_state)
        self.assertEqual(report1.open_issues_count, 1)
        self.assertEqual(report2.open_issues_count, 1)
        self.assertEqual(report1.issues[0].issue_id, report2.issues[0].issue_id)

    def test_di_001_duplicate_exercise_id_detected_as_type_b(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "days": {
                "2026-10-18": {"exercises": [{"id": "ex-99"}]},
                "2026-10-19": {"exercises": [{"id": "ex-99"}]}
            }
        }
        report = self.engine.scan(state)
        issue = next(i for i in report.issues if i.rule_id == "DI-001")
        self.assertEqual(issue.repair_type, "B")
        self.assertEqual(issue.severity, "critical")
        _, logs = self.engine.repair(state, report.issues)
        self.assertFalse(logs[0].success)
        self.assertEqual(logs[0].action_taken, "blocked")

    def test_di_002_active_session_mirror_repair_type_d(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "days": {
                "2026-10-18": {
                    "activeWorkoutSessionID": "s-1",
                    "exercises": [{"id": "wrong-mirror"}],
                    "workoutSessions": [{"id": "s-1", "exercises": [{"id": "correct-session-ex"}]}]
                }
            }
        }
        report = self.engine.scan(state)
        self.assertTrue(any(i.rule_id == "DI-002" for i in report.issues))
        repaired_state, logs = self.engine.repair(state, report.issues)
        self.assertTrue(logs[0].success)
        self.assertEqual(repaired_state["days"]["2026-10-18"]["exercises"][0]["id"], "correct-session-ex")
        rescan = self.engine.scan(repaired_state)
        self.assertFalse(any(i.rule_id == "DI-002" for i in rescan.issues))

    def test_di_004_started_workout_overwrite_guard_type_b(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "days": {
                "2026-10-18": {"training_confirmed": True, "exercises": [{"id": "done"}]}
            },
            "pending_plan_adoption": {
                "days": {"2026-10-18": {"exercises": [{"id": "new-proposal"}]}}
            }
        }
        report = self.engine.scan(state)
        issue = next(i for i in report.issues if i.rule_id == "DI-004")
        self.assertEqual(issue.repair_type, "B")
        _, logs = self.engine.repair(state, report.issues)
        self.assertFalse(logs[0].success)

    def test_di_007_cycle_planned_dates_rederivation(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "planCycle": {
                "startDate": "2026-10-18",
                "endDate": "2026-10-24",
                "plannedDates": ["2026-10-18", "2026-10-99"]
            },
            "days": {
                "2026-10-18": {"exercises": [{"id": "ex-1"}]},
                "2026-10-20": {"exercises": [{"id": "ex-2"}]}
            }
        }
        report = self.engine.scan(state)
        self.assertTrue(any(i.rule_id == "DI-007" for i in report.issues))
        repaired_state, logs = self.engine.repair(state, report.issues)
        cycle_log = next(l for l in logs if l.rule_id == "DI-007")
        self.assertTrue(cycle_log.success)
        self.assertEqual(repaired_state["planCycle"]["plannedDates"], ["2026-10-18", "2026-10-20"])

    def test_di_008_dual_plan_variant_conflict_detected_as_type_b(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "days": {
                "2026-10-18": {
                    "plan_variants": ["manual_variant_a", "ai_variant_b"]
                }
            }
        }
        report = self.engine.scan(state)
        issue = next(i for i in report.issues if i.rule_id == "DI-008")
        self.assertEqual(issue.repair_type, "B")
        self.assertEqual(issue.severity, "critical")

    def test_di_014_meal_nutrition_recalculation(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "days": {
                "2026-10-18": {
                    "meals": [{
                        "id": "m-1",
                        "components": [
                            {"name": "鸡胸肉", "calories": 150.0, "protein": 30.0, "carbs": 0.0, "fat": 3.0},
                            {"name": "米饭", "calories": 200.0, "protein": 4.0, "carbs": 45.0, "fat": 1.0}
                        ],
                        "nutrition": {"calories": 999.0, "protein": 0.0, "carbs": 0.0, "fat": 0.0}
                    }]
                }
            }
        }
        report = self.engine.scan(state)
        self.assertTrue(any(i.rule_id == "DI-014" for i in report.issues))
        repaired_state, logs = self.engine.repair(state, report.issues)
        meal = repaired_state["days"]["2026-10-18"]["meals"][0]
        self.assertEqual(meal["nutrition"]["calories"], 350.0)
        self.assertEqual(meal["nutrition"]["protein"], 34.0)

    def test_di_017_profile_projection_resync(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "profile": {"age": 30, "gender": "female", "height": 165, "weight": 55},
            "profiles_table_projection": {"age": 25, "gender": "female", "height": 165, "weight": 55}
        }
        report = self.engine.scan(state)
        self.assertTrue(any(i.rule_id == "DI-017" for i in report.issues))
        repaired_state, logs = self.engine.repair(state, report.issues)
        self.assertEqual(repaired_state["profiles_table_projection"]["age"], 30)

    def test_di_024_report_archive_single_current_invariant(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "report_archive": [
                {"job_id": "j-old", "owner": "u-1", "kind": "report", "date": "2026-10-18", "created": 100, "source_status": "current"},
                {"job_id": "j-new", "owner": "u-1", "kind": "report", "date": "2026-10-18", "created": 200, "source_status": "current"}
            ]
        }
        report = self.engine.scan(state)
        self.assertTrue(any(i.rule_id == "DI-024" for i in report.issues))
        repaired_state, logs = self.engine.repair(state, report.issues)
        reports = repaired_state["report_archive"]
        old_r = next(r for r in reports if r["job_id"] == "j-old")
        new_r = next(r for r in reports if r["job_id"] == "j-new")
        self.assertEqual(old_r["source_status"], "stale")
        self.assertEqual(new_r["source_status"], "current")

    def test_source_version_mismatch_aborts_repair(self):
        state = {
            "user_id": "u-1",
            "revision": "rev-1",
            "profile": {"age": 30},
            "profiles_table_projection": {"age": 25}
        }
        report = self.engine.scan(state)
        state["revision"] = "rev-2"
        _, logs = self.engine.repair(state, report.issues)
        self.assertFalse(logs[0].success)
        self.assertEqual(logs[0].action_taken, "aborted_version_mismatch")

    def test_raw_facts_remain_immutable_during_repair(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "days": {
                "2026-10-18": {
                    "training_confirmed": True,
                    "exercises": [{"id": "ex-1", "sets": [{"weight": 100, "reps": 5, "completed": True}]}],
                    "activeWorkoutSessionID": "s-1",
                    "workoutSessions": [{"id": "s-1", "exercises": [{"id": "ex-1", "sets": [{"weight": 100, "reps": 5, "completed": True}]}]}]
                }
            },
            "profile": {"age": 30},
            "profiles_table_projection": {"age": 28}
        }
        repaired_state, _ = self.engine.repair(state)
        ex = repaired_state["days"]["2026-10-18"]["exercises"][0]
        self.assertEqual(ex["sets"][0]["weight"], 100)
        self.assertEqual(ex["sets"][0]["reps"], 5)
        self.assertTrue(ex["sets"][0]["completed"])


    def test_di_011_outbox_missing_event_detected(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "data_operations": [
                {"operation_id": "op-1", "actor": "user", "command_type": "Schedule.Replace", "before_version": "1", "after_version": "2", "status": "succeeded"}
            ],
            "domain_outbox": []  # missing event!
        }
        report = self.engine.scan(state)
        issue = next(i for i in report.issues if i.rule_id == "DI-011")
        self.assertEqual(issue.severity, "high")
        self.assertEqual(issue.aggregate_id, "op-1")

    def test_di_012_consumer_offset_exceeding_revision_detected(self):
        state = {
            "user_id": "u-1",
            "revision": "10",
            "consumer_offsets": {"push_worker": 15}  # 15 > 10!
        }
        report = self.engine.scan(state)
        issue = next(i for i in report.issues if i.rule_id == "DI-012")
        self.assertEqual(issue.severity, "high")
        self.assertEqual(issue.aggregate_id, "push_worker")

    def test_di_020_corrupted_healthkit_anchor_detected(self):
        state = {
            "user_id": "u-1",
            "revision": "v1",
            "healthkit_anchors": [
                {"type": "HKWorkout", "token": "", "status": "corrupted"}
            ]
        }
        report = self.engine.scan(state)
        issue = next(i for i in report.issues if i.rule_id == "DI-020")
        self.assertEqual(issue.severity, "high")
        self.assertEqual(issue.aggregate_id, "HKWorkout")


    def test_full_codebase_audit_fixes_and_ux_enhancements(self):
        from pathlib import Path
        root = Path(__file__).resolve().parents[1]

        # 1. iOS Performance & Memory Fixes
        app_swift = (root / "BojiClub/BojiClubApp.swift").read_text("utf-8")
        self.assertIn("defaultsSyncTask?.cancel()", app_swift)
        self.assertIn("Task.sleep(for: .seconds(120))", app_swift)

        ai_swift = (root / "BojiClub/AIService.swift").read_text("utf-8")
        self.assertIn("let succeededCutoff = Date().addingTimeInterval(-86400)", ai_swift)
        self.assertIn("jobs[index].request.kind != \"food\" || jobs[index].consumed", ai_swift)

        ledger_swift = (root / "BojiClub/ClubInsightLedger.swift").read_text("utf-8")
        self.assertIn("if groupEvents.count > 6 {", ledger_swift)

        # 2. Gym UX Enhancements
        library_swift = (root / "BojiClub/ExerciseLibraryView.swift").read_text("utf-8")
        self.assertIn("struct ExerciseAnatomyGuideCard: View", library_swift)
        self.assertIn("目标肌群与发力节奏", library_swift)
        self.assertIn("sharedConfiguration", library_swift)

        workout_swift = (root / "BojiClub/WorkoutView.swift").read_text("utf-8")
        self.assertIn('restButton("−15秒"', workout_swift)
        self.assertIn('restButton("+30秒"', workout_swift)

        reg_swift = (root / "BojiClub/TrainingRegistrationViews.swift").read_text("utf-8")
        self.assertIn(".swipeActions(edge: .leading, allowsFullSwipe: true)", reg_swift)
        self.assertIn(".contextMenu {", reg_swift)

        meal_swift = (root / "BojiClub/MealEditorView.swift").read_text("utf-8")
        self.assertIn("常吃与最近餐食 · 一键带入", meal_swift)
        self.assertIn("private var recentFrequentMeals: [Meal]", meal_swift)

        # 3. Backend & Account-Server Ops Fixes
        server_py = (root / "backend/server.py").read_text("utf-8")
        self.assertIn("CREATE INDEX IF NOT EXISTS attempts_job ON attempts(job_id)", server_py)
        self.assertIn("if not has_work:", server_py)
        self.assertIn("DELETE FROM jobs WHERE status='deleted' AND updated<?", server_py)

        index_php = (root / "account-server/public/index.php").read_text("utf-8")
        self.assertIn("last_used_at < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 60 SECOND)", index_php)
        self.assertIn("clubRulesUnlock($db);", index_php)

        lock_php = (root / "account-server/public/club-lock.php").read_text("utf-8")
        self.assertIn("function clubRulesUnlock(PDO $db): void", lock_php)


    def test_one_boji_design_system_unification(self):
        from pathlib import Path
        root = Path(__file__).resolve().parents[1]

        tokens = (root / "BojiClub/DesignTokens.swift").read_text("utf-8")
        self.assertIn("struct BojiPageHeader<Trailing: View>: View", tokens)
        self.assertIn("struct BojiToolbarCapsuleButton: View", tokens)
        self.assertIn("struct BojiStatusBanner: View", tokens)
        self.assertIn("struct BojiSectionHeader: View", tokens)
        self.assertIn("func bojiSpecularBorder(", tokens)
        self.assertIn("if !hasActiveWorkout, let top {", tokens)

        design = (root / "BojiClub/Design.swift").read_text("utf-8")
        self.assertIn(".bojiElevated(cornerRadius: ClubUI.cardRadius)", design)
        self.assertIn(".listRowBackground(BojiColor.cardSurface)", design)
        self.assertNotIn(".presentationCornerRadius(BojiRadius.card)", design)
        self.assertNotIn(".presentationBackground(BojiColor.pageBackground)", design)
        self.assertIn("content.glassEffect(.regular.tint(BojiColor.brandMist.opacity(0.45)), in: shape)", design)
        self.assertIn("accessibilityReduceTransparency", design)

        shell = (root / "BojiClub/ClubAIShell.swift").read_text("utf-8")
        self.assertGreaterEqual(shell.count("BojiStatusBanner("), 3)
        self.assertIn("ClubModeCapsulePicker(mode: $mode)", shell)
        self.assertIn(".pickerStyle(.segmented)", shell)
        self.assertIn("ToolbarItem(placement:", shell)

        product = (root / "BojiClub/ProductArchitecture.swift").read_text("utf-8")
        self.assertIn("BojiPageHeader(", product)
        profile = (root / "BojiClub/ProfileView.swift").read_text("utf-8")
        self.assertIn('.navigationTitle("我的")', profile)
        self.assertIn("List {", profile)


    def test_deprecated_views_and_erroneous_jumps_cleaned_up(self):
        from pathlib import Path
        root = Path(__file__).resolve().parents[1]

        workout = (root / "BojiClub/WorkoutView.swift").read_text("utf-8")
        self.assertNotIn('section = "动作库"', workout)
        self.assertIn("onAddNew: { showLibrary = true }", workout)
        self.assertIn(".sheet(isPresented: $showWeight) { WeightEntryEditor(date: snapshot.date) }", workout)

        ai_views = (root / "BojiClub/AIViews.swift").read_text("utf-8")
        self.assertIn("else if let dateKey, !showsVersions, let date = ClubDates.date(fromKey: dateKey)", ai_views)
        self.assertIn(".sheet(isPresented: $showPrivacySheet) { LegalDocumentView(document: .privacy) }", ai_views)
        self.assertNotIn('NavigationLink("前往“我的 → 隐私说明”开启")', ai_views)

        review = (root / "BojiClub/ReviewDashboardView.swift").read_text("utf-8")
        self.assertIn("ReportPreviousAnalysesLink(dateKey: ClubDates.key(day.date))", review)
        self.assertIn("打开当日日报", review)

        profile = (root / "BojiClub/ProfileView.swift").read_text("utf-8")
        self.assertIn('if recordAccessOnly { Section { NavigationLink("历史报告") { ReportLibraryView() } } }', profile)
        self.assertNotIn('profileButton("查看历史报告档案"', profile)
        self.assertNotIn("我的 → 我的复盘档案", profile)
        self.assertNotIn("我的 → 体重记录与变化", profile)

if __name__=='__main__':unittest.main(verbosity=2)
