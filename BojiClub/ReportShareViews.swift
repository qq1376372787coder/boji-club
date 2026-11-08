import SwiftUI
import UIKit

// Sharing is independent of the app home so reports, training and Club exports share one renderer.
struct ShareCardView: View {
    let title: String
    let headline: String
    let stats: [String]
    let tagline: String
    var sections: [ReportShareSection] = []
    var sectionTitle = ""
    var pageNumber = 1
    var pageCount = 1
    var identity: MemberProfile? = nil
    var artwork: UIImage? = nil
    var brandSymbol = "dumbbell.fill"
    var footerLabel = "所选记录 · 已记录内容"
    var trainingFeedback: TrainingFeedback? = nil
    var summaryPage: ShareCardView {
        let height: CGFloat = (identity == nil ? 640 : 570) - (trainingFeedback == nil ? 0 : 84)
        let text = ReportShareContent.summary(headline) { ShareCardPagination.fits($0, width: 928, height: height) }
        return ShareCardView(title: title, headline: text, stats: [], tagline: tagline,
            sectionTitle: "核心结论", identity: identity, brandSymbol: brandSymbol,
            footerLabel: "重点摘要 · 完整分析请在 App 查看", trainingFeedback: trainingFeedback)
    }
    var paginated: [ShareCardView] {
        let text=([headline]+stats).filter { !$0.isEmpty }.joined(separator:"\n\n")
        let groups = sections.isEmpty ? [ReportShareSection(title:"",text:text)] : sections
        // Reserve space for a two-line title, section heading, footer and all card margins.
        let bodyHeight: CGFloat = (identity == nil ? 640 : 570) - (artwork == nil ? 0 : 380)
        let chunks = ReportShareContent.pages(groups) { ShareCardPagination.fits($0,width:928,height:bodyHeight) }
        return chunks.enumerated().map { index,chunk in ShareCardView(title:title,headline:chunk.text,stats:[],tagline:tagline,sectionTitle:chunk.title,pageNumber:index+1,pageCount:chunks.count,identity:identity,artwork:artwork,brandSymbol:brandSymbol,footerLabel:footerLabel) }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.04), Color(white: 0.16), Color(white: 0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: BojiLayout.sectionGap) {
                HStack {
                    BojiBrandSignature(size:48,style:.onDark,font:.system(size:34,weight:.semibold,design:.monospaced))
                    Spacer()
                    Image(systemName: brandSymbol)
                        .bojiType(.hero)
                }
                .foregroundStyle(.white)
                .overlay(alignment: .bottomLeading) {
                    Capsule().fill(ClubBrand.accent).frame(width: 108, height: 6).offset(y: 12)
                }

                VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                    Text(title)
                        .bojiType(.hero)
                        .foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.8)
                    if let trainingFeedback { TrainingFeedbackBadge(feedback: trainingFeedback, large: true) }
                    if !sectionTitle.isEmpty {
                        Text(sectionTitle).bojiType(.section).foregroundStyle(.white.opacity(0.6)) // lint-ignore: dark-surface-alpha（深色表面对白有意透明度）
                    }
                    if let artwork {
                        Image(uiImage: artwork).resizable().scaledToFit()
                            .frame(maxWidth: .infinity).frame(height: 350)
                    }
                    Text(headline)
                        .bojiType(.display)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(8).fixedSize(horizontal:false,vertical:true)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }

                VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                        HStack(spacing: BojiLayout.cardInset) {
                            Circle()
                                .fill(.white.opacity(0.9))
                                .frame(width: 10, height: 10)
                            Text(stat)
                                .bojiType(.display)
                                .foregroundStyle(.white)
                        }
                    }
                }

                Spacer()

                if let identity {
                    HStack(spacing: BojiLayout.rowGap) {
                        ClubAvatarView(profile: identity, size: 48)
                        Text(identity.nickname).bojiType(.section).foregroundStyle(.white.opacity(0.85)) // lint-ignore: dark-surface-alpha（深色表面对白有意透明度）.lineLimit(1)
                    }
                }
                HStack {
                    Text(tagline)
                        .bojiType(.display)
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Text(pageCount > 1 ? "\(pageNumber) / \(pageCount)" : footerLabel)
                        .bojiType(.body)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(48)
        }
        .frame(width: 1080, height: 1350)
        .clipped()
    }
}

enum ShareCardPagination {
    static func split(_ text: String, width: CGFloat, height: CGFloat) -> [String] {
        ShareTextPages.split(text) { fits($0,width:width,height:height) }
    }
    static func fits(_ text: String, width: CGFloat, height: CGFloat) -> Bool {
        let style=NSMutableParagraphStyle();style.lineSpacing=8
        let attributes: [NSAttributedString.Key:Any]=[.font:UIFont.systemFont(ofSize:34,weight:.semibold),.paragraphStyle:style]
        let size=(text as NSString).boundingRect(with:CGSize(width:width,height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attributes,context:nil)
        return ceil(size.height) <= height
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
func renderShareImage(_ content: ShareCardView) -> UIImage? {
    let renderer = ImageRenderer(content: content.environment(\.colorScheme, .light).dynamicTypeSize(.large))
    renderer.proposedSize = ProposedViewSize(width: 1080, height: 1350)
    renderer.scale = 1
    renderer.isOpaque = true
    guard let image = renderer.uiImage, image.size.width > 0, image.size.height > 0 else { return nil }
    return image
}


struct ShareDraft: Identifiable {
    let id = UUID()
    let card: ShareCardView
    var ownerID: Int? = nil
}

private struct PreparedShare: Identifiable {
    let id = UUID()
    let files: [URL]
}

struct ShareCardPreview: View {
    @EnvironmentObject private var store: AppStore
    @State private var includeIdentity = true
    @State private var includeFullReport = false
    let draft: ShareDraft
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var preparing = false
    @State private var attempt = 0
    @State private var preparedShare: PreparedShare?
    @State private var files: [URL] = []
    @State private var selectedPage = 0
    @State private var generatedPages = 0
    @State private var exportFolder: URL?
    @State private var renderTicket = UUID()
    @State private var ownerID: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BojiLayout.blockGap) {
                    if !draft.card.sections.isEmpty {
                        Picker("分享内容", selection: $includeFullReport) {
                            Text("重点摘要 · 一张图").tag(false)
                            Text("完整分析 · 多图").tag(true)
                        }.clubAdaptivePicker().disabled(preparing)
                            .onChange(of: includeFullReport) { _, _ in attempt += 1 }
                    }
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: BojiRadius.image, style: .continuous))
                            .accessibilityLabel("即将分享的记录卡片")
                        Text("分享前请检查卡片内容。").bojiType(.caption).foregroundStyle(.secondary)
                        Toggle("显示头像与昵称", isOn: $includeIdentity).disabled(preparing)
                            .onChange(of: includeIdentity) { _, _ in attempt += 1 }
                        if files.count > 1 {
                            HStack {
                                Button("上一张") { selectPage(selectedPage-1) }.disabled(selectedPage == 0)
                                Spacer();Text("\(selectedPage+1) / \(files.count)").bojiType(.caption);Spacer()
                                Button("下一张") { selectPage(selectedPage+1) }.disabled(selectedPage+1 >= files.count)
                            }.buttonStyle(SecondaryButton()).tint(.primary)
                        }
                    } else if let error {
                        ContentUnavailableView("分享卡片暂未生成", systemImage: "photo", description: Text(error))
                        Button("重新生成") { attempt += 1 }.buttonStyle(SecondaryButton())
                    } else {
                        ClubLoadingCard(title: "正在生成分享卡片…", detail: "生成后可先预览，再选择分享方式。")
                        if generatedPages > 0 { Text("已生成 \(generatedPages) 张").bojiType(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(BojiLayout.blockGap)
            }
            .background { ClubBackground() }
            .navigationTitle("分享预览").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if image != nil && !files.isEmpty {
                    Button { preparedShare = PreparedShare(files:files) } label: {
                        Label(files.count > 1 ? "分享全部 \(files.count) 张" : "选择分享方式", systemImage: "square.and.arrow.up")
                    }.buttonStyle(PrimaryButton()).padding().clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous))
                }
            }
            .task(id: attempt) {
                if ownerID == nil { ownerID = draft.ownerID ?? store.editingAccountID }
                guard let ownerID, ownerID == store.editingAccountID else { dismiss(); return }
                let ticket = UUID(); renderTicket = ticket
                preparing = true; error = nil; image = nil; files = []; generatedPages = 0; selectedPage = 0
                if let exportFolder { try? FileManager.default.removeItem(at: exportFolder) }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boji-share-" + UUID().uuidString, isDirectory: true)
                exportFolder = folder
                // Freeze the identity with this rendering pass. A later account
                // or avatar change cannot mix two identities across pages.
                var content = draft.card
                content.identity = includeIdentity ? store.state.profile : nil
                defer { if renderTicket == ticket { preparing = false } }
                await Task.yield()
                do {
                    try Task.checkCancellation()
                    guard renderTicket == ticket, ownerID == store.editingAccountID else { throw CancellationError() }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
                    var rendered: [URL] = []
                    let cards: [ShareCardView] = !draft.card.sections.isEmpty && !includeFullReport ? [content.summaryPage] : content.paginated
                    for (index, card) in cards.enumerated() {
                        try Task.checkCancellation()
                        guard renderTicket == ticket, ownerID == store.editingAccountID else { throw CancellationError() }
                        // Release intermediate UIKit images per page instead of
                        // retaining a whole long report in the autorelease pool.
                        let data = autoreleasepool { renderShareImage(card)?.jpegData(compressionQuality: 0.9) }
                        guard let data else { throw AccountError.message("图片生成失败，请重试。") }
                        let file = folder.appendingPathComponent(String(format: "BojiClub-%03d.jpg", index + 1))
                        try data.write(to: file, options: [.atomic, .completeFileProtection])
                        rendered.append(file); generatedPages = index + 1
                        await Task.yield()
                    }
                    try Task.checkCancellation()
                    guard renderTicket == ticket, ownerID == store.editingAccountID else { throw CancellationError() }
                    files = rendered; selectPage(0)
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: folder)
                } catch {
                    if renderTicket == ticket, ownerID == store.editingAccountID { self.error = AppErrorText.message(error) }
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            .sheet(item: $preparedShare) { item in ShareSheet(items:item.files) }
            .onChange(of: store.editingAccountID) { _, id in
                if id != ownerID { renderTicket = UUID(); preparedShare = nil; dismiss() }
            }
            .onDisappear { if preparedShare == nil, let exportFolder { try? FileManager.default.removeItem(at:exportFolder) } }
        }
    }
    private func selectPage(_ index: Int) {
        guard files.indices.contains(index) else { return }
        selectedPage=index;image=UIImage(contentsOfFile:files[index].path)
        if image == nil { error="分享图片读取失败，请重新生成。" }
    }
}

