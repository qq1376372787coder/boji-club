"""Extract production JSON encoders for a standalone macOS Swift regression."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
ai=(root/'BojiClub/AIService.swift').read_text(encoding='utf-8')
cloud=(root/'BojiClub/CloudSync.swift').read_text(encoding='utf-8')
jsonvalue=ai[ai.index('enum JSONValue:'):ai.index('struct AIInput:')]
wire=cloud[cloud.index('private struct CloudWireValue:'):cloud.index('private struct CloudPartChange:')]
tests=r'''
func check(_ ok: Bool, _ label: String) { if !ok { fatalError(label) } }
struct Fixture: Decodable { let version: Int; let protein: Double; let enabled: Bool; let payload: [String: JSONValue]; let names: [String] }
let input: JSONValue = .object(["version": .number(1), "protein": .number(12.5), "enabled": .bool(true), "payload": .object([:]), "names": .array([.string("鸡蛋 \"营养\" 😀")])])
let data = try JSONEncoder().encode(CloudWireValue(value: input))
let decoded = try JSONDecoder().decode(Fixture.self, from: data)
check(decoded.version == 1 && decoded.protein == 12.5 && decoded.enabled, "typed PHP/Swift integer, fraction and Bool contract")
check(decoded.payload.isEmpty && decoded.names == ["鸡蛋 \"营养\" 😀"], "empty dictionaries and Unicode survive")
let text = String(decoding: data, as: UTF8.self)
check(text.range(of: #""version":1([,}])"#, options: .regularExpression) != nil, "version emits an integer JSON token")
for value in [Double(Int64.min), Double(Int64.max), 0, -1, 1.25] {
 let bytes = try JSONEncoder().encode(CloudWireValue(value: .number(value)))
 check(try JSONDecoder().decode(Double.self, from: bytes) == value, "numeric boundaries do not trap or change value")
}
do { _ = try JSONEncoder().encode(CloudWireValue(value: .number(.infinity))); fatalError("non-finite number accepted") } catch { }
print("Storage wire encoding checks passed")
'''
folder=root/'build-check';folder.mkdir(exist_ok=True)
generated='import Foundation\n'+jsonvalue+wire+tests
(folder/'storage-v59-wire.swift').write_text(generated,encoding='utf-8')
# Maintain the common generator contract so CI can compile the requested path.
import sys
if len(sys.argv)>1:
    Path(sys.argv[1]).write_text(generated,encoding='utf-8')
