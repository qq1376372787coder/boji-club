import SwiftUI
import UIKit
import AVFoundation

struct ReviewPhotoEditor: View {
    let image: UIImage
    let pose: String
    let save: (Data) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var top = 0.15
    @State private var bottom = 0.0
    @State private var error: String?
    @State private var preview: UIImage?
    private func processed() -> UIImage {
        let ratio = min(1, 1200 / max(image.size.width,image.size.height))
        let full = CGSize(width:max(1,image.size.width*ratio),height:max(1,image.size.height*ratio))
        let size = CGSize(width:full.width,height:max(1,full.height*(1-CGFloat(top)-CGFloat(bottom))))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        // Drawing creates new pixels without the original GPS/EXIF metadata.
        return UIGraphicsImageRenderer(size:size,format:format).image { context in
            UIColor.white.setFill(); context.cgContext.fill(CGRect(origin:.zero,size:size))
            image.draw(in:CGRect(x:0,y:-full.height*CGFloat(top),width:full.width,height:full.height))
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text("\(pose) · 确认这张照片").bojiFont(.pageTitle).foregroundStyle(BojiColor.textPrimary)
                    Group { if let preview { Image(uiImage:preview).resizable().scaledToFit() } else { ClubLoadingCard(title: "正在读取照片…").padding(16) } }.frame(maxHeight:420).frame(maxWidth:.infinity).background(.black.opacity(0.04),in:RoundedRectangle(cornerRadius:18))
                    Text("调整上边缘去掉面部，下边缘去掉多余背景。预览就是保存及发送的画面，请确认衣着完整且身体清晰。原照片不会写入复盘存储。").font(.caption).foregroundStyle(.secondary)
                    Text("裁剪上方（可隐藏面部）").font(.subheadline)
                    Slider(value:$top,in:0...0.4).accessibilityLabel("裁剪上方").accessibilityValue("\(Int(top * 100))百分比")
                    Text("裁剪下方").font(.subheadline)
                    Slider(value:$bottom,in:0...0.25).accessibilityLabel("裁剪下方").accessibilityValue("\(Int(bottom * 100))百分比")
                    Button("保存这张照片到本机") {
                        guard min(image.size.width,image.size.height)>=480 else { error="照片分辨率偏低，请重拍或选择更清晰的原图。"; return }
                        let rendered=processed()
                        guard let data=rendered.jpegData(compressionQuality:0.6),data.count<=550000 else { error="照片内容较复杂或体积过大，请裁剪背景后再保存。"; return }
                        do { try save(data); dismiss() } catch { self.error = AppErrorText.message(error) }
                    }.buttonStyle(PrimaryButton())
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding(ClubUI.pageInset)
            }.task(id: "\(top)-\(bottom)") {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled else { return }; preview = processed()
            }.toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } } }
        }.tint(ClubBrand.accent)
    }
}

struct WeeklyCamera: View {
    let pose: String
    let reference: UIImage?
    let receive: (UIImage?) -> Void
    @State private var allowed = false
    @State private var checked = false
    var body: some View {
        Group {
            if allowed { ReviewCameraController(pose:pose,reference:reference,receive:receive).ignoresSafeArea() }
            else {
                VStack(spacing:20) {
                    Image(systemName:"camera").font(.largeTitle)
                    Text(checked ? "相机暂不可用，可返回选择相册照片，或在系统设置中允许相机权限。" : "正在准备相机…").multilineTextAlignment(.center)
                    if !checked { ClubWaitBar().frame(maxWidth: 240) }
                    Button("返回") { receive(nil) }.buttonStyle(SecondaryButton())
                }.padding(30)
            }
        }.task {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else { checked=true;return }
            allowed=await AVCaptureDevice.requestAccess(for:.video); checked=true
        }
    }
}

private struct ReviewCameraController: UIViewControllerRepresentable {
    let pose: String
    let reference: UIImage?
    let receive: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(receive:receive) }
    func makeUIViewController(context:Context) -> UIImagePickerController {
        let picker=UIImagePickerController(); picker.sourceType = .camera
        picker.cameraDevice = .rear; picker.showsCameraControls=false; picker.delegate=context.coordinator
        context.coordinator.picker=picker
        let overlay=UIView(frame: picker.view.bounds); overlay.backgroundColor = .clear
        let label=UILabel(); label.text="\(pose) · 自然站立，身体放在框内\n穿合身不透明运动服，无需露脸\n固定手机，相同光线与距离"; label.numberOfLines=0; label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .footnote); label.adjustsFontForContentSizeCategory = true
        label.textColor = .white; label.backgroundColor=UIColor.black.withAlphaComponent(0.45);label.translatesAutoresizingMaskIntoConstraints=false
        let guide=UIView();guide.isUserInteractionEnabled=false;guide.layer.borderColor=UIColor.white.withAlphaComponent(0.8).cgColor;guide.layer.borderWidth=1;guide.layer.cornerRadius=35;guide.translatesAutoresizingMaskIntoConstraints=false
        let counter=UILabel();counter.textAlignment = .center;counter.textColor = .white;counter.font = .systemFont(ofSize:64,weight:.light);counter.translatesAutoresizingMaskIntoConstraints=false
        let capture=UIButton(type:.system);capture.setTitle("3 秒倒计时拍摄",for:.normal);capture.tintColor = .black;capture.backgroundColor = .white;capture.layer.cornerRadius=ClubUI.controlRadius;capture.translatesAutoresizingMaskIntoConstraints=false
        capture.addTarget(context.coordinator,action:#selector(Coordinator.capture),for:.touchUpInside)
        let cancel=UIButton(type:.system);cancel.setTitle("取消",for:.normal);cancel.tintColor = .white;cancel.translatesAutoresizingMaskIntoConstraints=false
        cancel.addTarget(context.coordinator,action:#selector(Coordinator.cancel),for:.touchUpInside)
        let flip=UIButton(type:.system);flip.setTitle("切换镜头",for:.normal);flip.tintColor = .white;flip.translatesAutoresizingMaskIntoConstraints=false
        flip.addTarget(context.coordinator,action:#selector(Coordinator.flip),for:.touchUpInside)
        for button in [capture, cancel, flip] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
        }
        let overlays: [UIView] = [label,guide,counter,capture,cancel,flip]
        for view in overlays { overlay.addSubview(view) }
        if let reference {
            let ghost=UIImageView(image:reference);ghost.contentMode = .scaleAspectFit;ghost.alpha=0.18;ghost.translatesAutoresizingMaskIntoConstraints=false;ghost.isUserInteractionEnabled=false
            overlay.insertSubview(ghost,belowSubview:guide)
            NSLayoutConstraint.activate([ghost.topAnchor.constraint(equalTo:guide.topAnchor),ghost.bottomAnchor.constraint(equalTo:guide.bottomAnchor),ghost.leadingAnchor.constraint(equalTo:guide.leadingAnchor),ghost.trailingAnchor.constraint(equalTo:guide.trailingAnchor)])
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo:overlay.safeAreaLayoutGuide.topAnchor,constant:20),label.leadingAnchor.constraint(equalTo:overlay.leadingAnchor,constant:ClubUI.pageInset),label.trailingAnchor.constraint(equalTo:overlay.trailingAnchor,constant:-ClubUI.pageInset),label.heightAnchor.constraint(greaterThanOrEqualToConstant:82),
            guide.topAnchor.constraint(equalTo:label.bottomAnchor,constant:12),guide.centerXAnchor.constraint(equalTo:overlay.centerXAnchor),guide.widthAnchor.constraint(equalTo:overlay.widthAnchor,multiplier:0.58),guide.bottomAnchor.constraint(equalTo:cancel.topAnchor,constant:-12),
            counter.centerXAnchor.constraint(equalTo:guide.centerXAnchor),counter.centerYAnchor.constraint(equalTo:guide.centerYAnchor),
            capture.leadingAnchor.constraint(equalTo:overlay.leadingAnchor,constant:ClubUI.pageInset),capture.trailingAnchor.constraint(equalTo:overlay.trailingAnchor,constant:-ClubUI.pageInset),capture.heightAnchor.constraint(greaterThanOrEqualToConstant:ClubUI.primaryHeight),capture.bottomAnchor.constraint(equalTo:overlay.safeAreaLayoutGuide.bottomAnchor,constant:-32),
            cancel.leadingAnchor.constraint(equalTo:overlay.leadingAnchor,constant:ClubUI.pageInset),cancel.bottomAnchor.constraint(equalTo:capture.topAnchor,constant:-12),cancel.heightAnchor.constraint(greaterThanOrEqualToConstant:ClubUI.minimumTap),cancel.widthAnchor.constraint(greaterThanOrEqualToConstant:ClubUI.minimumTap),
            flip.trailingAnchor.constraint(equalTo:overlay.trailingAnchor,constant:-ClubUI.pageInset),flip.bottomAnchor.constraint(equalTo:cancel.bottomAnchor),flip.heightAnchor.constraint(greaterThanOrEqualToConstant:ClubUI.minimumTap),flip.widthAnchor.constraint(greaterThanOrEqualToConstant:ClubUI.minimumTap),cancel.trailingAnchor.constraint(lessThanOrEqualTo:flip.leadingAnchor,constant:-12)
        ])
        context.coordinator.counter=counter;context.coordinator.captureButton=capture
        picker.cameraOverlayView=overlay;return picker
    }
    func updateUIViewController(_ controller:UIImagePickerController,context:Context) {}
    static func dismantleUIViewController(_ controller:UIImagePickerController,coordinator:Coordinator) { coordinator.timer?.invalidate() }
    final class Coordinator:NSObject,UIImagePickerControllerDelegate,UINavigationControllerDelegate {
        let receive:(UIImage?)->Void
        weak var picker:UIImagePickerController?
        weak var counter:UILabel?
        weak var captureButton:UIButton?
        var timer:Timer?
        var count=3
        init(receive:@escaping(UIImage?)->Void){self.receive=receive}
        @objc func capture(){
            guard timer==nil else{return};count=3;counter?.text="3";captureButton?.isEnabled=false
            ClubAccessibility.announce("三秒后拍照。")
            timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in
                guard let self else{return};self.count-=1
                if self.count==0{self.timer?.invalidate();self.timer=nil;self.counter?.text=nil;self.picker?.takePicture()}
                else{self.counter?.text=String(self.count)}
            }
        }
        @objc func cancel(){timer?.invalidate();timer=nil;receive(nil)}
        @objc func flip(){guard timer==nil,let picker else{return};let device:UIImagePickerController.CameraDevice=picker.cameraDevice == .rear ? .front:.rear;if UIImagePickerController.isCameraDeviceAvailable(device){picker.cameraDevice=device}}
        func imagePickerController(_ picker:UIImagePickerController,didFinishPickingMediaWithInfo info:[UIImagePickerController.InfoKey:Any]){captureButton?.isEnabled=true;ClubAccessibility.announce("照片已拍摄，请核对。");receive(info[.originalImage] as? UIImage)}
        func imagePickerControllerDidCancel(_ picker:UIImagePickerController){cancel()}
    }
}
