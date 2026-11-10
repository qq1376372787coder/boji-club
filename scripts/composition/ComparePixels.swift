import Foundation
import CoreGraphics
import ImageIO

// Pixel changes are a review cue, never an aesthetic pass/fail score.
func pixels(_ url: URL) -> (Int, Int, [UInt8])? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return rendered ? (width, height, bytes) : nil
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fatalError("Usage: ComparePixels beforeFolder afterFolder output.json") }
let before = URL(fileURLWithPath: arguments[1]), after = URL(fileURLWithPath: arguments[2])
var rows = [[String: Any]]()
for file in try FileManager.default.contentsOfDirectory(at: before, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "png" {
    let other = after.appendingPathComponent(file.lastPathComponent)
    guard FileManager.default.fileExists(atPath: other.path) else { continue }
    guard let a = pixels(file), let b = pixels(other) else { continue }
    var row: [String: Any] = ["file": file.lastPathComponent, "beforeSize": [a.0, a.1], "afterSize": [b.0, b.1], "decision": "human-review-required"]
    if a.0 == b.0 && a.1 == b.1 {
        var changed = 0, totalDifference: Int64 = 0
        for i in stride(from: 0, to: a.2.count, by: 4) {
            let differences = (0..<3).map { abs(Int(a.2[i + $0]) - Int(b.2[i + $0])) }
            if differences.max()! > 16 { changed += 1 }
            totalDifference += Int64(differences.reduce(0, +))
        }
        row["changedPixelFractionThreshold16"] = Double(changed) / Double(a.0 * a.1)
        row["meanAbsoluteRGBDifference"] = Double(totalDifference) / Double(a.0 * a.1 * 3)
    } else { row["reason"] = "different-image-dimensions" }
    rows.append(row)
}
let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: arguments[3]))
print("Compared \(rows.count) matching screenshots; human review required.")
