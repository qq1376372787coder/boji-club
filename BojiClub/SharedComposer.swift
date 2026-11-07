import SwiftUI
import PhotosUI
import ImageIO
import CryptoKit
import AVFoundation

/// The presented item carries its entry mode atomically, avoiding stale captures on first presentation.
struct ClubComposerMealRoute: Identifiable {
    let id = UUID()
    let date: Date
    let mode: String
}

/// One editing surface for the empty workspace and every conversation state.
/// Voice uses the existing on-device recognizer; opening this view never starts audio.
struct ClubSharedComposer: View {
    @Binding var text: String
    @Binding var attachments: [ClubChatAttachment]
    @Binding var references: [AIContextReference]
    @Binding var deepAnalysis: Bool
    let conversationID: String
    var busy: Bool
    var enabled = true
    var focusRequest = 0
    var errorText: String? = nil
    let onSend: () -> Void
    let onRecordMeal: (String) -> Void
    let onRecordBody: () -> Void
    var waitingForReferences130 = false
    var onCancelWaiting130: (() -> Void)? = nil
    @State private var voicePresented = false
    @StateObject private var speech = MealSpeechInput()
    @State private var voiceDraft: VoiceDraft127?
    @State private var voiceTranscript = ""
    @State private var voiceLease = UUID()
    @State private var localFocusRequest = 0
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPhotoUpload = false
    @State private var referencePicker = false
    @State private var mentionQuery: String?
    @State private var mentionRange131: NSRange?
    @State private var cameraRoute: ClubChatCameraRoute125?
    @State private var albumAfterCamera = false
    @State private var cameraOwner: Int?
    @State private var cameraConversation = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var loadingPhoto = false
    @State private var photoTask: Task<Void, Never>?
    @State private var uploadFeedback: String?
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var account: AccountService
    @State private var providerConsent = false
    @State private var pendingConsentSend = false
    @State private var consentOwner: Int?
    @State private var consentConversation = ""
    @Environment(\.dynamicTypeSize) private var typeSize

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.inline) {
            if waitingForReferences130 {
                HStack { Text("正在读取引用记录…").bojiType(.label); Spacer(); Button("取消发送") { onCancelWaiting130?() }.bojiType(.label) }.padding(.horizontal, BojiLayout.rowGap)
            } else if busy {
                Label("正在回答，你可以继续编辑下一条", systemImage: "hourglass")
                    .bojiType(.label).foregroundStyle(.secondary)
                    .padding(.horizontal, BojiLayout.rowGap).accessibilityIdentifier("coach-processing-status")
            } else if !enabled {
                Text("AI 暂不可用，仍可记录饮食、体重和训练。")
                    .bojiType(.label).foregroundStyle(.secondary).padding(.horizontal, BojiLayout.rowGap)
            }
            if let message = uploadFeedback ?? errorText {
                Text(message)
                    .bojiType(.label).foregroundStyle(.secondary).padding(.horizontal, BojiLayout.rowGap)
            }
            if let query = mentionQuery, FeatureFlagService.shared.referencesEnabled {
                VStack(alignment: .leading, spacing: 0) {
                    Text("引用最近记录").bojiType(.caption).foregroundStyle(.secondary).padding(.horizontal, BojiLayout.rowGap)
                    ForEach(AIReferenceCatalog.recent(store: store, ai: ai, query: query)) { ref in
                        Button {
                            selectReference131(ref)
                        } label: { Label(ref.title, systemImage: "at").bojiType(.secondary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                        .disabled(busy || references.count >= 5).padding(.horizontal, BojiLayout.rowGap)
                    }
                    Button("更多记录…") { referencePicker = true; mentionQuery = nil; cancelVoice() }.bojiType(.label).padding(.horizontal, BojiLayout.rowGap).frame(minHeight: 44)
                }.background(BojiColor.brandMist, in: RoundedRectangle(cornerRadius: 16))
            }
            if !references.isEmpty {
                ClubReferenceChips131(references: $references)
            }
            if !references.isEmpty && trimmed.isEmpty {
                Button {
                    BojiHaptics.tick()
                    text = "请分析我引用的记录，先核对事实，再给建议。"
                } label: {
                    Label("分析引用记录", systemImage: "sparkles")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textPrimary)
                        .padding(.horizontal, BojiLayout.rowGap)
                        .padding(.vertical, BojiLayout.tight)
                        .clubGlassEffect(in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, BojiLayout.rowGap)
            }
            if deepAnalysis {
                Button {
                    BojiHaptics.tick()
                    deepAnalysis = false
                } label: {
                    Label("深入 · 仅下一条  ×", systemImage: "sparkles")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textPrimary)
                        .padding(.horizontal, BojiLayout.rowGap)
                        .padding(.vertical, BojiLayout.tight)
                        .clubGlassEffect(in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, BojiLayout.rowGap)
                .accessibilityLabel("取消下一条深入分析")
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BojiLayout.inline) {
                        ForEach(attachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                if let image = UIImage(data: attachment.data) {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: BojiRadius.control))
                                }
                                Button { attachments.removeAll { $0.id == attachment.id } } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.7)).frame(width: 44, height: 44)
                                }.buttonStyle(.plain).accessibilityLabel("移除待发送照片")
                            }
                        }
                    }.padding(.horizontal, BojiLayout.rowGap)
                }
                Text("\(attachments.count)/3 张待发送照片 · 发送后用于本次 AI 对话")
                    .bojiType(.caption).foregroundStyle(.secondary).padding(.horizontal, BojiLayout.rowGap)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BojiLayout.inline) {
                        quickPhotoIntentButton("记录饮食", prompt: "请帮我估算并记录照片里的饮食食物与大致热量。")
                        quickPhotoIntentButton("问器械/动作", prompt: "请看下这张照片里的健身器械，说说怎么调整和标准动作要点。")
                        quickPhotoIntentButton("看营养成分表", prompt: "请帮我解读这张食品营养标签上的热量和三大营养素。")
                    }
                    .padding(.horizontal, BojiLayout.rowGap)
                }
            }
            if loadingPhoto { Label("正在准备照片…", systemImage: "photo").bojiType(.label).padding(.horizontal, BojiLayout.rowGap) }
            if voicePresented {
                ClubVoiceOverlay127(speech: speech, transcript: $voiceTranscript,
                    onRestart: restartVoice, onCancel: cancelVoice,
                    onUse: { commitVoice(sendNow: false) }, onSend: { commitVoice(sendNow: true) })
            }
            HStack(alignment: .bottom, spacing: BojiLayout.tight) {
                Menu {
                    Button { referencePicker = true } label: { Label("引用记录", systemImage: "doc.text") }.disabled(busy || !FeatureFlagService.shared.referencesEnabled)
                    Button { openCamera() } label: { Label("上传照片", systemImage: "photo") }.disabled(attachments.count >= 3 || loadingPhoto || busy)
                    Button { onRecordMeal("手动") } label: { Label("记录饮食", systemImage: "fork.knife") }
                    Button(action: onRecordBody) { Label("记录体重", systemImage: "scalemass") }
                } label: {
                    Image(systemName: "plus")
                        .bojiType(.body)
                        .foregroundStyle(BojiColor.textPrimary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44).contentShape(Circle())
                .accessibilityLabel("添加或快捷记录")
                .accessibilityIdentifier("v2-composer-plus")
                .disabled(voicePresented)

                ZStack(alignment: .topLeading) {
                    if text.isEmpty { Text("问问 Club AI…").foregroundStyle(BojiColor.textSecondary).padding(.top, BojiLayout.inline).padding(.leading, BojiLayout.tight).allowsHitTesting(false) }
                    ClubReferenceTextEditor(text: $text, references: $references, focusRequest: focusRequest + localFocusRequest, onMention: { mentionQuery = $0 }, onSubmit: send, onMentionRange: { mentionRange131 = $0 })
                        .frame(minHeight: 42)
                        .disabled(voicePresented)
                }

                Button { if voicePresented { cancelVoice() } else { beginVoice() } } label: {
                    Image(systemName: voicePresented ? "mic.fill" : "mic")
                        .bojiType(.body)
                        .foregroundStyle(voicePresented ? ClubBrand.accent : BojiColor.textPrimary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44).contentShape(Circle())
                .accessibilityLabel("语音输入")
                .accessibilityIdentifier("v2-composer-voice")
                .disabled(busy || !enabled || loadingPhoto)

                if !trimmed.isEmpty || !attachments.isEmpty || !references.isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .bojiType(.body)
                            .foregroundStyle(BojiColor.pageBackground)
                            .frame(width: 24, height: 24).contentShape(Rectangle().inset(by: -10))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(BojiColor.textPrimary)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Circle())
                    .disabled(!enabled || busy || voicePresented || loadingPhoto || text.count > 4000)
                    .accessibilityLabel("发送")
                    .accessibilityIdentifier("v2-composer-send")
                }
            }
            .padding(BojiLayout.tight)
            .clubComposerGlass132()

            Text("AI 建议仅供锻炼与生活参考，不构成医疗诊断或专业处方")
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textTertiary)
                .padding(.top, 0)

            if text.count >= 3600 {
                Text("\(text.count)/4000")
                    .bojiType(.caption).foregroundStyle(text.count > 4000 ? Color.red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, BojiLayout.rowGap)
                    .accessibilityLabel("已输入 \(text.count) 字，最多 4000 字")
            }
        }
        .onChange(of: references.map(\.id)) { previous, current in
            if !Set(current).subtracting(previous).isEmpty { BojiInteraction131.referenceAdded() }
        }
        .tint(ClubBrand.accent)
        .sheet(isPresented: $providerConsent, onDismiss: {
            let resume = pendingConsentSend && consentOwner == store.editingAccountID && consentConversation == conversationID && CloudAnalysisConsent.routerVersion(accountID: consentOwner) == 3
            pendingConsentSend = false
            if resume { send() }
        }) { AIProviderConsentSheet() }
         .sheet(isPresented: $referencePicker) {
            ClubCompactReferencePicker(selection: $references)
                .presentationDetents([.height(360), .large]).presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $cameraRoute, onDismiss: {
            if albumAfterCamera {
                albumAfterCamera = false
                if cameraOwner == store.editingAccountID, cameraConversation == conversationID { showPhotoUpload = true }
            }
        }) { route in
            ClubChatCamera125(thumbnail: attachments.last.flatMap { UIImage(data: $0.data) }, onCapture: { data in
                cameraRoute = nil
                guard route.owner == store.editingAccountID, route.conversation == conversationID else { return }
                do {
                    guard attachments.count < 3 else { return }
                    attachments.append(try ClubChatAttachment.prepare(data, owner: route.owner, conversation: route.conversation))
                    uploadFeedback = nil
                } catch { uploadFeedback = AppErrorText.message(error) }
            }, onAlbum: {
                guard route.owner == store.editingAccountID, route.conversation == conversationID else { return }
                cameraOwner = route.owner; cameraConversation = route.conversation
                albumAfterCamera = true; cameraRoute = nil
            }, onCancel: { cameraRoute = nil }).ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoUpload, selection: $photoItems,
            maxSelectionCount: max(1, 3 - attachments.count), matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            photoTask?.cancel()
            let owner = cameraOwner; let conversation = cameraConversation
            guard owner == store.editingAccountID, conversation == conversationID else { return }
            loadingPhoto = true
            photoTask = Task { @MainActor in
                defer { loadingPhoto = false }
                do {
                    for item in items {
                        guard let owner, store.editingAccountID == owner, conversationID == conversation,
                              !Task.isCancelled else { return }
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw AIClientError.message("照片读取失败，请重新选择。") }
                        try Task.checkCancellation()
                        guard store.editingAccountID == owner, conversationID == conversation else { return }
                        let attachment = try ClubChatAttachment.prepare(data, owner: owner, conversation: conversation)
                        guard attachments.count < 3 else { break }
                        attachments.append(attachment)
                    }
                    uploadFeedback = nil
                } catch is CancellationError { }
                catch { if store.editingAccountID == owner, conversationID == conversation { uploadFeedback = AppErrorText.message(error) } }
            }
        }
        .onChange(of: store.editingAccountID) { _, _ in photoTask?.cancel(); photoItems = []; loadingPhoto = false; uploadFeedback = nil; cameraRoute = nil; cameraOwner = nil; cameraConversation = ""; showPhotoUpload = false; albumAfterCamera = false; pendingConsentSend = false; mentionQuery = nil; cancelVoice() }
        .onChange(of: conversationID) { _, _ in photoTask?.cancel(); photoItems = []; loadingPhoto = false; uploadFeedback = nil; cameraRoute = nil; cameraOwner = nil; cameraConversation = ""; showPhotoUpload = false; albumAfterCamera = false; pendingConsentSend = false; mentionQuery = nil; cancelVoice() }
        .onDisappear { photoTask?.cancel(); cancelVoice() }
        .onChange(of: speech.transcript) { _, value in
            guard voicePresented, voiceDraft?.owner == store.editingAccountID, voiceDraft?.conversation == conversationID else { return }
            voiceTranscript = value
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { speech.stop() } }
    }
    private func selectReference131(_ reference: AIContextReference) {
        guard references.count < 5, !references.contains(where: { $0.id == reference.id }) else { return }
        if let range = mentionRange131, range.location != NSNotFound, NSMaxRange(range) <= (text as NSString).length {
            text = (text as NSString).replacingCharacters(in: range, with: "")
        }
        references.append(reference); mentionQuery = nil; mentionRange131 = nil; localFocusRequest += 1
    }
    private func resignInput() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    private func beginVoice() {
        guard enabled, !busy, let owner = store.editingAccountID else { return }
        resignInput(); voiceDraft = .init(owner: owner, conversation: conversationID, prefix: text)
        voiceTranscript = ""; voicePresented = true; voiceLease = UUID()
        restartVoice()
    }
    private func restartVoice() {
        let lease = voiceLease
        Task { guard voicePresented, voiceLease == lease, voiceDraft?.owner == store.editingAccountID, voiceDraft?.conversation == conversationID else { return }; await speech.start() }
    }
    private func cancelVoice() { voiceLease = UUID(); speech.stop(); voicePresented = false; voiceDraft = nil; voiceTranscript = "" }
    private func commitVoice(sendNow: Bool) {
        guard let draft = voiceDraft, text == draft.prefix,
              let value = draft.result(transcript: voiceTranscript, currentOwner: store.editingAccountID, currentConversation: conversationID), value.count <= 1200 else {
            uploadFeedback = "草稿或会话已变化，请核对转写内容。"; return
        }
        text = value; cancelVoice()
        if sendNow { send() } else { localFocusRequest += 1 }
    }

    private func openCamera() {
        guard !busy, attachments.count < 3, let owner = store.editingAccountID else { return }
        resignInput(); uploadFeedback = nil; albumAfterCamera = false; showPhotoUpload = false
        cameraOwner = owner; cameraConversation = conversationID
        cameraRoute = .init(owner: owner, conversation: conversationID)
    }

    private func quickPhotoIntentButton(_ title: String, prompt: String) -> some View {
        Button {
            BojiHaptics.tick()
            if trimmed.isEmpty {
                text = prompt
            } else {
                text += "\n" + prompt
            }
            localFocusRequest += 1
        } label: {
            Text(title)
                .bojiType(.caption)
                .foregroundStyle(BojiColor.textPrimary)
                .padding(.horizontal, BojiLayout.inline)
                .padding(.vertical, BojiLayout.tight)
                .background(BojiColor.subtleSurface, in: Capsule())
                .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
    }

    private func send() {
        guard enabled, !busy, !loadingPhoto, (!trimmed.isEmpty || !attachments.isEmpty || !references.isEmpty), text.count <= 1200 else { return }
        if CloudAnalysisConsent.allowed(accountID: account.user?.id), CloudAnalysisConsent.routerVersion(accountID: account.user?.id) < 3 {
            consentOwner = store.editingAccountID; consentConversation = conversationID
            pendingConsentSend = true; providerConsent = true; return
        }
        BojiHaptics.tick()
        resignInput()
        ClubInlineGuide.complete("chat", owner: store.editingAccountID)
        onSend()
    }
}

private struct ClubVoiceOverlay127: View {
    @ObservedObject var speech: MealSpeechInput
    @Binding var transcript: String
    let onRestart: () -> Void
    let onCancel: () -> Void
    let onUse: () -> Void
    let onSend: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(ClubBrand.accent)
                Text(speech.isRecording ? "正在听你说…" : speech.isPreparing ? "正在准备文字…" : "核对后发送").bojiType(.secondary)
                Spacer()
                Menu {
                    Picker("识别语言", selection: $speech.language) {
                        ForEach(MealSpeechInput.languages, id: \.0) { code, title in Text(title).tag(code) }
                    }
                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                .disabled(speech.isRecording || speech.isPreparing).accessibilityLabel("语音选项")
                Button("取消", action: onCancel).bojiType(.secondary).frame(minHeight: 44)
            }
            if speech.isRecording {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        ProgressView(value: Double(speech.audioLevel)).tint(ClubBrand.accent)
                        Text("\(Int(max(0,context.date.timeIntervalSince(speech.startedAt ?? context.date))))秒").bojiType(.caption)
                    }
                }
            }
            TextField("识别后的文字会显示在这里", text: $transcript, axis: .vertical).lineLimit(2...4)
                .disabled(speech.isRecording || speech.isPreparing).accessibilityIdentifier("voice-transcript")
            if let message = speech.message { Text(message.replacingOccurrences(of: "核对文字后即可识别餐食", with: "核对后即可发送"))
                .bojiType(.caption).foregroundStyle(.secondary) }
            HStack {
                if speech.isRecording { Button("结束录音") { speech.finishRecording() }.buttonStyle(.bordered) }
                else {
                    Button("重录", action: onRestart).disabled(speech.isPreparing)
                    Spacer()
                    Button("使用文字", action: onUse).disabled(speech.isPreparing || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("发送", action: onSend).buttonStyle(.borderedProminent)
                        .disabled(speech.isPreparing || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.bojiType(.secondary).frame(minHeight: 44)
        }.padding(BojiLayout.cardInset).clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.card))
            .accessibilityElement(children: .contain).accessibilityIdentifier("voice-inline-panel")
    }
}

/// A local, explicitly selected chat draft. It is never a Meal and has no remote URL to reuse across accounts.
struct ClubChatAttachment: Codable, Equatable, Identifiable {
    let id: UUID
    let ownerID: Int
    let conversation: String
    let data: Data
    let createdAt: Date
    var wire: JSONValue {
        .object(["id": .string(id.uuidString.lowercased()), "mime_type": .string("image/jpeg"),
            "data_base64": .string(data.base64EncodedString()),
            "sha256": .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())])
    }
    static func prepare(_ data: Data, owner: Int, conversation: String) throws -> Self {
        guard owner != 0, UUID(uuidString: conversation) != nil, data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary) else {
            throw AIClientError.message("照片无法读取或文件过大，请选择一张较小的照片。")
        }
        // Fresh JPEG removes EXIF/GPS metadata. Downsampling avoids full-resolution decoding.
        let image = UIImage(cgImage: cg)
        var encoded = image.jpegData(compressionQuality: 0.65)
        if (encoded?.count ?? Int.max) > 1_048_576 { encoded = image.jpegData(compressionQuality: 0.45) }
        guard let encoded, (50...1_048_576).contains(encoded.count) else {
            throw AIClientError.message("照片压缩后仍超过 1 MB，请裁剪后重新选择。")
        }
        return Self(id: UUID(), ownerID: owner, conversation: conversation, data: encoded, createdAt: Date())
    }
    static func payload(_ items: [Self], owner: Int, conversation: String) throws -> JSONValue {
        guard items.count <= 3, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.ownerID == owner && $0.conversation == conversation && (50...1_048_576).contains($0.data.count) }) else {
            throw AIClientError.message("照片所属账号或会话已变化，请重新选择。")
        }
        return .array(items.map(\.wire))
    }
}

/// Backup-excluded, protected account/conversation drafts. Images are only transmitted on Send.
enum ClubChatDraftStorage {
    struct Draft: Codable { let owner: Int; let conversation: String; let attachments: [ClubChatAttachment]; let context: ClubAIEntryContext?; var references: [AIContextReference]? = nil; var source: ClubContextSource? = nil; var scope: ClubReviewScope? = nil }
    static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BojiClub/chat-drafts", isDirectory: true) }
    static func url(owner: Int, conversation: String) -> URL { folder.appendingPathComponent("\(owner)-\(conversation.lowercased()).json") }
    static func load(owner: Int, conversation: String) -> Draft? {
        guard owner != 0, UUID(uuidString: conversation) != nil,
              let data = try? Data(contentsOf: url(owner: owner, conversation: conversation)),
              let draft = try? JSONDecoder().decode(Draft.self, from: data), draft.owner == owner,
              draft.conversation == conversation,
              draft.attachments.allSatisfy({ $0.ownerID == owner && $0.conversation == conversation }) else { return nil }
        return draft
    }
    @discardableResult static func save(owner: Int, conversation: String, attachments: [ClubChatAttachment], context: ClubAIEntryContext?, references: [AIContextReference] = [], source: ClubContextSource? = nil, scope: ClubReviewScope? = nil) -> Bool {
        guard owner != 0, UUID(uuidString: conversation) != nil,
              attachments.allSatisfy({ $0.ownerID == owner && $0.conversation == conversation }),
              context == nil || (context?.ownerID == owner && context?.conversationID == conversation) else { return false }
        if attachments.isEmpty && context == nil && references.isEmpty && source == nil && scope == nil { clear(owner: owner, conversation: conversation); return true }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var root = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            let data = try JSONEncoder().encode(Draft(owner: owner, conversation: conversation, attachments: attachments, context: context, references: references, source: source, scope: scope))
            try data.write(to: url(owner: owner, conversation: conversation), options: [.atomic, .completeFileProtection])
            return true
        } catch { return false }
    }
    static func clear(owner: Int, conversation: String) {
        guard owner != 0, UUID(uuidString: conversation) != nil else { return }
        try? FileManager.default.removeItem(at: url(owner: owner, conversation: conversation))
    }
    static func conversations(owner: Int) -> [String] {
        let prefix = "\(owner)-"
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap { file in
            guard file.lastPathComponent.hasPrefix(prefix) else { return nil }
            let id = String(file.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
            guard let draft = load(owner: owner, conversation: id) else { return nil }
            return !draft.attachments.isEmpty || draft.references?.isEmpty == false ? id : nil
        }
    }
    static func erase(owner: Int) {
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix("\(owner)-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
