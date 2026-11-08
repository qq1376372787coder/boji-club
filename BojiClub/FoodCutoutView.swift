import SwiftUI
import Vision
import CoreImage
import UIKit
import CryptoKit

private actor FoodCutoutCache {
    static let shared = FoodCutoutCache()
    private var images: [String: Data] = [:]
    private var order: [String] = []
    private var bytes = 0
    private var generation = UUID()
    func token() -> UUID { generation }
    func clear() { images.removeAll(); order.removeAll(); bytes = 0; generation = UUID() }
    func get(_ key: String) -> Data? { images[key] }
    func put(_ data: Data, for key: String, token: UUID) {
        guard token == generation else { return }
        guard data.count <= 8 * 1024 * 1024 else { return }
        if let old = images.removeValue(forKey: key) { bytes -= old.count }
        order.removeAll { $0 == key }; order.append(key)
        images[key] = data; bytes += data.count
        while bytes > 20 * 1024 * 1024 || order.count > 8 {
            let oldest = order.removeFirst()
            if let removed = images.removeValue(forKey: oldest) { bytes -= removed.count }
        }
    }
}

enum FoodCutout {
    static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])
    static func clearCache() async { await FoodCutoutCache.shared.clear() }
    // All Vision work is performed away from the main actor. No photo leaves the device here.
    static func make(_ data: Data) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let token = await FoodCutoutCache.shared.token()
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let cached = await FoodCutoutCache.shared.get(key) { return cached }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let worker = Task.detached(priority: .utility) {
            autoreleasepool {
                do {
                    let handler = VNImageRequestHandler(data: data, options: [:])
                    try Task.checkCancellation()
                    try handler.perform([request])
                    try Task.checkCancellation()
                    guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil as Data? }
                    let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: true)
                    let ci = CIImage(cvPixelBuffer: buffer)
                    guard let cg = FoodCutout.sharedContext.createCGImage(ci, from: ci.extent) else { return nil as Data? }
                    return UIImage(cgImage: cg).pngData()
                } catch { return nil as Data? }
            }
        }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
            worker.cancel(); request.cancel()
        })
        guard !Task.isCancelled else { return nil }
        if let result { await FoodCutoutCache.shared.put(result, for: key, token: token) }
        return result
    }
}

struct FoodCutoutView: View {
    let data: Data
    @State private var cutout: Data?
    @State private var image: UIImage?
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BojiRadius.card).fill(BojiColor.inputSurface)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(cutout == nil ? 10 : 24)
                    .shadow(color: .black.opacity(cutout == nil ? 0 : 0.12), radius: 14, y: 10)
            }
        }.frame(height: 250).clipShape(RoundedRectangle(cornerRadius: BojiRadius.card))
            .overlay(alignment: .bottomTrailing) {
                if !finished { ClubCompactWait(title: "正在处理餐食照片…").padding(BojiSpace.general).clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous)).padding(BojiSpace.general) }
            }
            .task(id: data) {
                cutout = nil; finished = false
                let original = await ClubImage.preview(data,pixels:900)
                guard !Task.isCancelled else { return }; image = original
                let result = await FoodCutout.make(data)
                guard !Task.isCancelled else { return }
                let rendered = await ClubImage.preview(result ?? data,pixels:900)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : BojiMotion2.transition) { cutout = result; image = rendered; finished = true }
            }
    }
}
