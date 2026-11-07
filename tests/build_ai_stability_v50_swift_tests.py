from pathlib import Path
import runpy,sys
out=Path(sys.argv[1]);root=Path(__file__).resolve().parents[1]
runpy.run_path(str(Path(__file__).with_name('build_repair_v48_swift_tests.py')))
s=(root/'BojiClub/AIService.swift').read_text('utf-8')
rules=s[s.index('enum AIClientError'):s.index('@MainActor\nfinal class AIService')]
code=out.read_text('utf-8')+'\n'+rules+'\n'+r"""
do {
    let now=Date(timeIntervalSince1970:1000)
    let first=AIRetryPolicy.decision(URLError(.notConnectedToInternet),previousFailures:nil,now:now)
    check(first.status=="waiting_connection" && first.after.timeIntervalSince(now)==30,"offline input waits 30 seconds")
    let second=AIRetryPolicy.decision(URLError(.timedOut),previousFailures:1,now:now)
    check(second.after.timeIntervalSince(now)==60,"repeated connection failure backs off")
    let capped=AIRetryPolicy.decision(URLError(.timedOut),previousFailures:Int.max,now:now)
    check(capped.after.timeIntervalSince(now)==300,"connection backoff handles even an invalid maximum counter")
    let after=now.addingTimeInterval(10000)
    let quota=AIRetryPolicy.decision(AIClientError.deferred(429,"quota_exceeded","quota",after),previousFailures:nil,now:now)
    check(quota.status=="failed" && quota.after==after,"quota waits for server reset without automatic resubmission")
    let globalQuota=AIRetryPolicy.decision(AIClientError.deferred(429,"daily_capacity","daily capacity",after),previousFailures:nil,now:now)
    check(globalQuota.status=="failed" && globalQuota.after==after,"daily service capacity does not loop before midnight")
    let busy=AIRetryPolicy.decision(AIClientError.deferred(429,"capacity","busy",after),previousFailures:nil,now:now)
    check(busy.status=="waiting_service" && busy.after==after,"busy service respects retry time")
    check(!AIRetryPolicy.isDue(after,now:now) && AIRetryPolicy.isDue(after,now:after),"foreground refresh does not bypass wait")
    for code in [400,403,409,413,422] {
        check(AIRetryPolicy.decision(AIClientError.http(code,nil,"invalid"),previousFailures:nil,now:now).status=="rejected","permanent input rejection does not loop")
    }
    check(AIRetryPolicy.decision(AIClientError.http(400,"input_expired","expired"),previousFailures:nil,now:now).status=="expired","expired input requires new input")
    check(AIVisibleError.message(code:"quota_exceeded",fallback:nil)?.contains("零点")==true,"quota message explains reset")
}
print("ALL \(count) V50 NATIVE STABILITY RULES PASSED")
"""
out.write_text(code,'utf-8')
