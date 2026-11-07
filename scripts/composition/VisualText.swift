import Foundation
import Vision
import AppKit
var rows: [[String: Any]] = []
for file in CommandLine.arguments.dropFirst() {
 let url = URL(fileURLWithPath: file)
 let request = VNRecognizeTextRequest()
 request.recognitionLevel = .accurate
 request.recognitionLanguages = ["zh-Hans", "en-US"]
 do {
  try VNImageRequestHandler(url: url).perform([request])
  let texts = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
  let observations: [[String: Any]] = (request.results ?? []).compactMap { observation in
   guard let text = observation.topCandidates(1).first?.string else { return nil }
   let box = observation.boundingBox
   return ["text": text, "x": box.minX, "y": box.minY, "width": box.width, "height": box.height]
  }
  rows.append(["file": file, "texts": texts, "observations": observations])
 } catch { rows.append(["file":file,"error":error.localizedDescription]) }
}
let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
