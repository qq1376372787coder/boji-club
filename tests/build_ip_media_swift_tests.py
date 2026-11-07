from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
source=(root/'BojiClub/ExerciseLibraryView.swift').read_text('utf-8')
rules=source[source.index('enum ExerciseLibraryAPI {'):source.index('    private static let aliases:')]+ '\n}\n'
checks=r'''
func check(_ value: Bool, _ label: String) { guard value else { fatalError(label) }; print("PASS \(label)") }
let original="https://dongzuo.gongxiang.cloud/media/videos/a%20b.gif?revision=2"
let result=ExerciseLibraryAPI.mediaURL(original)!
// IP-TEST-20261009 起媒体源在所有构建统一重写到当前服务基址
// （api.gongxiang.cloud 解析落地后此断言随实现一并更新，见 docs/v2 R-21）。
check(result.absoluteString == "https://117.50.119.49/media/videos/a%20b.gif?revision=2", "media origin remaps in every build while preserving encoded path/query")
check(ExerciseLibraryAPI.mediaURL(nil) == nil,"missing media remains missing")
let external="https://example.com/media/videos/sample.gif"
check(ExerciseLibraryAPI.mediaURL(external)?.absoluteString == external,"other hosts are not rewritten")
let unrelated="https://dongzuo.gongxiang.cloud/other/file.gif"
check(ExerciseLibraryAPI.mediaURL(unrelated)?.absoluteString == unrelated,"only media paths are rewritten")
'''
Path(sys.argv[1]).write_text('import Foundation\n'+rules+checks,encoding='utf-8')
