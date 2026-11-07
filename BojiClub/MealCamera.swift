import SwiftUI
import AVFoundation
import UIKit

enum MealCameraStatus: Equatable {
    case preparing, ready, denied, unavailable, interrupted, failed
    var message: String {
        switch self {
        case .preparing: return "正在打开相机…"
        case .ready: return "让餐食完整入镜"
        case .denied: return "相机权限未开启。可以选择照片或手动记录。"
        case .unavailable: return "当前设备没有可用相机。可以选择照片或手动记录。"
        case .interrupted: return "相机暂时被占用，请稍后重试或选择照片。"
        case .failed: return "相机暂未准备好，可以重试或选择照片。"
        }
    }
}

struct MealCameraPreview: UIViewRepresentable {
    let active: Bool
    let captureID: Int
    let receive: (UIImage) -> Void
    let status: (MealCameraStatus) -> Void
    let captureFinished: (String?) -> Void
    func makeCoordinator() -> MealCaptureDriver {
        let driver = MealCaptureDriver(); driver.lastCaptureID = captureID; return driver
    }
    func makeUIView(context: Context) -> MealPreviewSurface {
        let view = MealPreviewSurface()
        view.preview.videoGravity = .resizeAspectFill
        view.preview.session = context.coordinator.session
        return view
    }
    func updateUIView(_ view: MealPreviewSurface, context: Context) {
        view.applyPortraitRotation()
        let driver = context.coordinator
        driver.receive = receive; driver.status = status; driver.captureFinished = captureFinished
        driver.setActive(active)
        if captureID != driver.lastCaptureID {
            driver.lastCaptureID = captureID
            if active { driver.capture() }
        }
    }
    static func dismantleUIView(_ view: MealPreviewSurface, coordinator: MealCaptureDriver) {
        coordinator.close(); view.preview.session = nil
    }
}

final class MealPreviewSurface: UIView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(preview)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.addSublayer(preview)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
        applyPortraitRotation()
    }
    func applyPortraitRotation() {
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}

// Mutable capture state is confined to `queue`. UI callbacks and lastCaptureID
// belong to the main actor. The capture delegate and permission callbacks may
// arrive on other threads; they enqueue state work before accessing it.
final class MealCaptureDriver: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "club.meal-camera", qos: .userInitiated)
    // Camera configuration, start/stop and capture are serialized off the UI thread.
    private var configured = false
    private var permissionRequested = false
    private var requestedActive = false
    private var closed = false
    private var capturing = false
    private var observers: [NSObjectProtocol] = []
    @MainActor var lastCaptureID = 0
    // These callbacks are installed, invoked and cleared only on the main queue.
    @MainActor var receive: ((UIImage) -> Void)?
    @MainActor var status: ((MealCameraStatus) -> Void)?
    @MainActor var captureFinished: ((String?) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in self?.publish(.interrupted) })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in self?.resume() })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in self?.publish(.failed) })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func setActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.requestedActive = active
            guard active else {
                if self.session.isRunning { self.session.stopRunning() }; return
            }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.start()
            case .notDetermined:
                guard !self.permissionRequested else { return }
                self.permissionRequested = true
                AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.closed else { return }
                        if allowed, self.requestedActive { self.start() }
                        else if !allowed { self.publish(.denied) }
                    }
                }
            default: self.publish(.denied)
            }
        }
    }
    private func start() {
        guard requestedActive, !closed else { return }
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video) else { publish(.unavailable); return }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                session.sessionPreset = .photo
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration(); publish(.unavailable); return
                }
                session.addInput(input); session.addOutput(output)
                session.commitConfiguration(); configured = true
            } catch { publish(.failed); return }
        }
        if !session.isRunning { session.startRunning() }
        publish(session.isRunning && !session.isInterrupted ? .ready : .interrupted)
    }
    private func resume() {
        queue.async { [weak self] in self?.start() }
    }
    func capture() {
        queue.async { [weak self] in
            guard let self, !self.closed, self.requestedActive, self.session.isRunning, !self.session.isInterrupted, !self.capturing else {
                self?.finish("相机尚未准备好，请稍后重试。"); return
            }
            self.capturing = true
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // Extract Sendable bytes before leaving the delegate callback; do not
        // move AVCapturePhoto or Error across a dispatch queue boundary.
        let data = error == nil ? photo.fileDataRepresentation() : nil
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.capturing = false
            guard self.requestedActive else { self.finish(nil); return }
            guard let data else { self.finish("拍照失败，请重试。"); return }
            Task { @MainActor [weak self] in
                let image = await ClubImage.preview(data, pixels: 1400)
                guard let self, self.receive != nil else { return }
                if let image { self.receive?(image); self.captureFinished?(nil) }
                else { self.captureFinished?("无法处理这张照片，请重试。") }
            }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard error != nil else { return }
        queue.async { [weak self] in
            guard let self, !self.closed, self.capturing else { return }
            self.capturing = false; self.finish("拍照中断，请重试或选择照片。")
        }
    }
    private func publish(_ value: MealCameraStatus) {
        DispatchQueue.main.async { [weak self] in self?.status?(value) }
    }
    private func finish(_ message: String?) {
        DispatchQueue.main.async { [weak self] in self?.captureFinished?(message) }
    }
    @MainActor func close() {
        receive = nil; status = nil; captureFinished = nil
        queue.async { [self] in
            closed = true; requestedActive = false
            if session.isRunning { session.stopRunning() }
        }
    }
}
