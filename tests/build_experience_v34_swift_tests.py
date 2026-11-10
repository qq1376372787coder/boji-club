"""Exercise production report layout, chronology and freshness with Foundation."""
from pathlib import Path
import runpy,sys
out=Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_experience_v33_swift_tests.py')))
s=out.read_text('utf-8')
s+=r'''
do {
    let reportText = "## 训练分析\r\n\r\n你完成了三组。\r\n这不是零训练。\r\n\r\n- 保留原重量\r\n* 关注恢复\r\n1. 明天补记饮食\r\n2、不要补造昨天的体重\r\n\r\n**下一步**\r\n自定义动作 #1 和 3.14 kg 也保留。"
    let blocks = ReportTextLayout.blocks(reportText)
    check(blocks.count == 8, "heading, paragraph and lists remain separate readable blocks")
    check(blocks[0].kind == .heading && blocks[0].text == "训练分析", "Markdown heading marker does not appear in report heading")
    check(blocks[1].text == "你完成了三组。\n这不是零训练。", "line breaks within one paragraph are preserved")
    check(blocks[2].kind == .bullet && blocks[2].text == "保留原重量", "bullet content is retained")
    check(blocks[4].kind == .numbered && blocks[4].marker == "1.", "numbered list retains its real number")
    check(blocks[5].marker == "2、" && blocks[5].text == "不要补造昨天的体重", "Chinese list delimiter is supported")
    check(blocks[6].kind == .heading && blocks[6].text == "下一步", "standalone bold heading is readable")
    check(blocks[7].text.contains("#1") && blocks[7].text.contains("3.14 kg"), "hashes and decimals in ordinary prose are not mistaken for structural markers")
    check(ReportTextLayout.blocks(" \n\n").isEmpty, "empty report content does not manufacture a paragraph")
    let longText = String(repeating: "训练记录🙂不能丢失。", count: 1000)
    check(ReportTextLayout.blocks(longText).first?.text == longText, "long Chinese and emoji content is preserved without truncation")
    let input = AIInput(kind: "report", date: "2026-10-09", payload: ["meals": .array([]), "analysis_version": .number(2)])
    var request = AIRequest(id: "fixture", kind: "report", date: input.date, payload: input.payload)
    request.payload["_routing_version"] = .number(2)
    check(ReportFreshness.evaluate(request: request, current: input) == .current, "recipient-routing flag alone does not make a report stale")
    var changed = input; changed.payload["meals"] = .array([.object(["name": .string("早餐")])])
    check(ReportFreshness.evaluate(request: request, current: changed) == .changed, "a meal added after submission makes the old report stale")
    var otherDay = input; otherDay.date = "2026-10-08"
    check(ReportFreshness.evaluate(request: request, current: otherDay) == .changed, "different dates cannot count as the same report snapshot")
    var recovered = request; recovered.payload = [:]
    check(ReportFreshness.evaluate(request: recovered, current: input) == .unavailable, "recovered jobs without input do not claim current data coverage")
    check(ReportFreshness.evaluate(request: request, current: nil) == .unavailable, "missing local snapshot is described conservatively")
    let result = AIResult(kind: "report", notes: [], summary: "合成分析")
    func report(_ id: String, date: String, at: Double, status: String = "succeeded") -> AILocalJob {
        AILocalJob(id: id, digest: id, request: AIRequest(id: id, kind: "report", date: date, payload: [:]), status: status, result: result, created: Date(timeIntervalSince1970: at))
    }
    let history = [report("old", date: "2026-10-08", at: 1), report("latest", date: "2026-10-08", at: 4),
                   report("previous-day", date: "2026-10-07", at: 2), report("deleted", date: "2026-10-09", at: 5),
                   report("failed", date: "2026-10-09", at: 6, status: "failed")]
    let visible = ReportHistory.visible(history, deleted: ["deleted"])
    check(visible.map(\.id) == ["latest", "previous-day", "old"], "history excludes archived and failed jobs and sorts by submission")
    check(ReportHistory.latestPerDay(visible).map(\.id) == ["latest", "previous-day"], "history shows one latest report per date")
    check(ReportHistory.visible(history, dateKey: "2026-10-08").count == 2, "older versions remain available inside their date")
    let tied = [report("a", date: "2026-10-08", at: 2), report("b", date: "2026-10-08", at: 2)]
    check(ReportHistory.latestPerDay(tied).first?.id == "b", "equal timestamps produce a stable latest version")
    let lateBackfill = [report("recent", date: "2026-10-09", at: 9), report("backfilled", date: "2026-10-01", at: 10)]
    check(ReportHistory.latestPerDay(lateBackfill).map(\.id) == ["recent", "backfilled"], "backfilled old report does not jump ahead of a more recent calendar date")
    print("PASS v34 report paragraphs, long-content preservation, snapshot freshness and history visibility")
}
'''
out.write_text(s,'utf-8')
print('v34 production-rule harness generated; execute with xcrun swift on Mac')
