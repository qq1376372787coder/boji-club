from pathlib import Path
import runpy, sys

out = Path(sys.argv[1])
runpy.run_path(str(Path(__file__).with_name('build_repair_v46_swift_tests.py')))
source = Path('BojiClub/Models.swift').read_text(encoding='utf-8')
start = source.index('enum EntryValidation {')
opening = source.index('{', start)
depth = 1
end = opening + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
code = source[start:end]
checks = r'''
do {
    let beginning = checks
    let zero = [0.0, 0, 0, 0]
    check(EntryValidation.meal(name:"鸡蛋", nutrition:zero, componentsValid:true) == nil, "unknown nutrition can reach explicit confirmation instead of being rejected")
    check(EntryValidation.meal(name:"  \n ", nutrition:zero, componentsValid:true) != nil, "blank meal has a concrete correction")
    check(EntryValidation.meal(name:String(repeating:"食",count:100), nutrition:zero, componentsValid:true) == nil, "meal name boundary is accepted")
    check(EntryValidation.meal(name:String(repeating:"食",count:101), nutrition:zero, componentsValid:true) != nil, "overlong meal name is explained")
    check(EntryValidation.meal(name:"鸡蛋", nutrition:zero, componentsValid:false) != nil, "invalid component cannot be hidden by valid totals")
    for value in [-1.0, Double.nan, Double.infinity, 100001.0] {
        check(EntryValidation.meal(name:"鸡蛋", nutrition:[value,0,0,0], componentsValid:true) != nil, "invalid nutrient is rejected with a reason")
    }
    check(EntryValidation.reward(recipient:" 王明 ", phone:"138 0013 8000", region:"北京市海淀区", address:" 中关村大街一号 ").isEmpty, "valid claim matches whitespace normalization")
    check(EntryValidation.reward(recipient:"", phone:"", region:"", address:"").count == 4, "all missing claim fields are explained")
    let invalidPhone = EntryValidation.reward(recipient:"王明", phone:"12345678901", region:"北京市", address:"中关村大街一号")
    check(invalidPhone.count == 1 && invalidPhone[0].contains("手机号"), "only the invalid claim field is reported")
    print("PASS \(checks-beginning) additional v47 production input validation checks")
}
'''
existing = out.read_text(encoding='utf-8')
if 'enum EntryValidation {' in existing:
    code = ''
out.write_text(existing + '\n' + code + '\n' + checks, encoding='utf-8')
print('v47 validation harness generated from current production code; execute on Mac to confirm')
