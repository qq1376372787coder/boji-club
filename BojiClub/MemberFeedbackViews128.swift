import SwiftUI
import PhotosUI
import AVKit

private func feedbackDate128(_ value: String) -> String {
    guard let date=ISO8601DateFormatter().date(from:value) else { return value }
    return date.formatted(.dateTime.month().day().hour().minute())
}
struct MemberFeedbackHub128: View {
    @EnvironmentObject private var account: AccountService
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var owner: Int?
    @State private var items:[MemberFeedbackTicket128]=[]
    @State private var page=1; @State private var more=false; @State private var busy=false
    @State private var problem:String?; @State private var compose=false
    @State private var selected:MemberFeedbackTicket128?
    var body: some View {
        List {
                Button("提交反馈",systemImage:"square.and.pencil") { compose=true }.accessibilityIdentifier("feedback-new")
                if let problem { Text(problem).bojiType(.secondary).foregroundStyle(.secondary);Button("重新加载") { Task { await load(reset:true) } } }
                if busy { ProgressView() }
                if items.isEmpty && !busy && problem == nil { ContentUnavailableView("还没有反馈",systemImage:"bubble.left.and.text.bubble.right",description:Text("遇到问题或有新想法，随时告诉我们。")) }
                ForEach(items) { ticket in
                    NavigationLink { FeedbackDetailView128(ticket:ticket).onDisappear { Task { await load(reset:true) } } } label: {
                        VStack(alignment:.leading,spacing: BojiLayout.inline) {
                            HStack { Text(ticket.statusLabel).bojiType(.caption).foregroundStyle(.secondary);Spacer();if ticket.unread { Label("有新回复",systemImage:"circle.fill").bojiType(.caption).foregroundStyle(.primary) } }
                            Text(ticket.title).bojiType(.bodyStrong).foregroundStyle(.primary).lineLimit(2)
                            Text(feedbackDate128(ticket.updated_at)).bojiType(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }.buttonStyle(.plain)
                }
                if more { Button("加载更多") { Task { await load(reset:false) } }.disabled(busy) }

        }.clubManagementList132().background { ClubBackground() }.navigationTitle("反馈与回复").navigationBarTitleDisplayMode(.inline)
            .task(id:account.user?.id) { owner=account.user?.id;items=[];await load(reset:true) }
            .refreshable { await load(reset:true) }
            .onChange(of:phase) { _,value in if value == .active { Task { await load(reset:true) } } }
            .onChange(of:account.user?.id) { _,value in if value != owner { dismiss() } }
            .sheet(isPresented:$compose) {
                if let owner { ClubNavigationStack132 { FeedbackComposer128(owner:owner,ticket:nil) { result in selected=result.ticket;Task { await load(reset:true) } } } }
            }
            .navigationDestination(item:$selected) { ticket in FeedbackDetailView128(ticket:ticket).onDisappear { Task { await load(reset:true) } } }
            .tint(.primary)
    }
    @MainActor private func load(reset:Bool) async {
        guard !busy,let owner,owner==account.user?.id else { return }
        if account.isPreviewAccount { items=[];more=false;return }
        busy=true;defer { busy=false }
        do {
            let next=reset ? 1:page+1
            let result:MemberFeedbackList128=try await MemberFeedbackAPI128.get(account,owner:owner,path:"/me/feedback?page=\(next)")
            guard owner==account.user?.id,!Task.isCancelled else { return }
            items=reset ? result.items:items+result.items;page=next;more=result.has_more;problem=nil
        } catch is CancellationError { } catch { if account.user?.id==owner { problem=error.localizedDescription } }
    }
}
struct FeedbackComposer128: View {
    @StateObject private var model: FeedbackComposerModel128
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var photos:[PhotosPickerItem]=[]
    @State private var work:Task<Void,Never>?
    @State private var discard=false
    let completed:(MemberFeedbackDetail128)->Void
    init(owner:Int,ticket:String?,completed:@escaping(MemberFeedbackDetail128)->Void) {
        _model=StateObject(wrappedValue:FeedbackComposerModel128(owner:owner,ticket:ticket));self.completed=completed
    }
    var body: some View {
        Form {
                if model.ticket == nil {
                    Picker("反馈类型",selection:$model.draft.category) { Text("遇到问题").tag("problem");Text("功能建议").tag("suggestion");Text("其他").tag("other") }.pickerStyle(.menu).disabled(model.busy||model.draft.pending)
                }
                Section {
                TextEditor(text:$model.draft.text).frame(minHeight:160)
                    .overlay(alignment: .topLeading) {
                        if model.draft.text.isEmpty { Text("发生了什么？你希望的结果是什么？").foregroundStyle(.tertiary).padding(.top, BojiLayout.inline).padding(.leading, BojiLayout.tight).allowsHitTesting(false) }
                    }
                    .disabled(model.busy||model.draft.pending).accessibilityLabel("反馈内容").accessibilityIdentifier("feedback-text")
                }
                HStack { Text("可说明出现问题的页面与操作步骤。").bojiType(.caption).foregroundStyle(.secondary);Spacer();Text("\(model.draft.text.count)/4000").bojiType(.caption).foregroundStyle(model.draft.text.count>4000 ? Color.red:Color.secondary) }
                ForEach(model.draft.attachments) { a in
                    HStack(spacing: BojiLayout.rowGap) {
                        if !a.isVideo,let image=UIImage(contentsOfFile:a.url(owner:model.owner).path) { Image(uiImage:image).resizable().scaledToFit().frame(width:64,height:64).clipShape(RoundedRectangle(cornerRadius: BojiRadius.thumb)) }
                        else { Image(systemName:"play.rectangle").bojiType(.section).frame(width:64,height:64).background(BojiColor.brandMist,in:RoundedRectangle(cornerRadius: BojiRadius.thumb)) }
                        VStack(alignment:.leading) { Text(a.isVideo ? "视频":"照片");Text(String(format:"%.1f MB",Double(a.bytes)/1048576)).bojiType(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("移除",role:.destructive) { model.remove(a,account:account) }.buttonStyle(.borderless).disabled(model.busy||model.draft.pending)
                    }
                }
                PhotosPicker(selection:$photos,maxSelectionCount:max(1,4-model.draft.attachments.count),matching:.any(of:[.images,.videos])) {
                    Label("添加照片或视频",systemImage:"photo.badge.plus").frame(minHeight:44)
                }.disabled(model.busy||model.draft.pending||model.draft.attachments.count>=4)
                Text("最多 4 个附件，视频最长 60 秒。仅供反馈处理，不用于 AI 分析。").bojiType(.label).foregroundStyle(.secondary)
                if model.busy { ProgressView(model.activity).frame(maxWidth:.infinity) }
                if let error=model.error { Text(error).bojiType(.secondary).foregroundStyle(.secondary).accessibilityIdentifier("feedback-error") }
                if model.draft.pending { Text("上次提交结果待确认，暂时保留原内容以便核对，重试不会重复提交。").bojiType(.label).foregroundStyle(.secondary) }
                Button {
                    work=Task { if let result=await model.submit(account:account) { dismiss();completed(result) } }
                } label: { Text(model.draft.pending ? "核对并重试":"提交反馈").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).disabled(model.busy || !model.draft.canSubmit).accessibilityIdentifier("feedback-submit")
                if model.busy { Button("暂停上传") { work?.cancel() } }
                if !model.draft.pending { Button("清空草稿",role:.destructive) { discard=true }.disabled(model.busy) }

        }.clubManagementList132().background { ClubBackground() }.navigationTitle(model.ticket == nil ? "提交反馈":"补充反馈").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("稍后继续") { work?.cancel();dismiss() } } }
            .interactiveDismissDisabled(model.busy)
            .onChange(of:photos) { _,items in guard !items.isEmpty else { return };photos=[];work=Task { await model.add(items,account:account) } }
            .onChange(of:account.user?.id) { _,value in if value != model.owner { work?.cancel();dismiss() } }
            .onDisappear { work?.cancel() }
            .confirmationDialog("清空这条未提交的草稿？",isPresented:$discard,titleVisibility:.visible) { Button("清空草稿",role:.destructive) { model.discard(account:account) };Button("保留",role:.cancel) {} }
            .tint(ClubBrand.accent)
    }
}
struct FeedbackDetailView128: View {
    let ticket:MemberFeedbackTicket128
    @EnvironmentObject private var account:AccountService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var owner:Int?;@State private var detail:MemberFeedbackDetail128?
    @State private var messages:[MemberFeedbackMessage128]=[];@State private var problem:String?
    @State private var busy=false;@State private var compose=false
    @State private var media:MemberFeedbackAttachment128?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing: BojiLayout.cardInset) {
                Text((detail?.ticket ?? ticket).title).bojiType(.section)
                HStack { Text((detail?.ticket ?? ticket).statusLabel);Text(feedbackDate128(ticket.created_at)) }.bojiType(.caption).foregroundStyle(.secondary)
                if let problem { Text(problem).foregroundStyle(.secondary);Button("重新加载") { Task { await load() } } }
                if busy { ProgressView() }
                if detail?.has_older == true { Button("加载更早消息") { Task { await load(older:true) } }.disabled(busy) }
                ForEach(messages) { message in
                    VStack(alignment:.leading,spacing: BojiLayout.rowGap) {
                        HStack { Text(message.author=="admin" ? "薄肌俱乐部回复":"我的反馈").bojiType(.secondary);Spacer();Text(feedbackDate128(message.created_at)).bojiType(.caption).foregroundStyle(.secondary) }
                        if !message.text.isEmpty { Text(message.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                        ForEach(message.attachments) { attachment in
                            Button { media=attachment } label: { Label(attachment.kind=="video" ? "播放视频":"查看照片",systemImage:attachment.kind=="video" ? "play.rectangle":"photo").frame(minHeight:44) }.buttonStyle(.bordered)
                        }
                    }.padding(BojiLayout.cardInset).background(message.author=="admin" ? BojiColor.brandMist.opacity(0.55):BojiColor.cardSurface,in:RoundedRectangle(cornerRadius: BojiRadius.cardSmall))
                }
                Button("补充反馈",systemImage:"square.and.pencil") { compose=true }.buttonStyle(.borderedProminent).disabled(busy)
                if (detail?.ticket ?? ticket).status=="closed" { Text("这条反馈已标记为已解决。如仍有问题，可以继续补充。").bojiType(.label).foregroundStyle(.secondary) }
            }.padding(BojiLayout.blockGap)
        }.background { ClubBackground() }.navigationTitle("反馈详情").navigationBarTitleDisplayMode(.inline)
            .task(id:account.user?.id) { owner=account.user?.id;await load() }
            .refreshable { await load() }
            .onChange(of:phase) { _,value in if value == .active { Task { await load() } } }
            .onChange(of:account.user?.id) { _,value in if value != owner { dismiss() } }
            .sheet(isPresented:$compose) { if let owner { ClubNavigationStack132 { FeedbackComposer128(owner:owner,ticket:ticket.id) { _ in Task { await load() } } } } }
            .sheet(item:$media) { attachment in if let owner { FeedbackMediaPreview128(attachment:attachment,owner:owner) } }
            .tint(ClubBrand.accent)
    }
    @MainActor private func load(older:Bool=false) async {
        guard !busy,let owner,owner==account.user?.id else { return };busy=true;defer { busy=false }
        do {
            let suffix=older ? "?before=\(messages.first?.id ?? 0)":""
            let result:MemberFeedbackDetail128=try await MemberFeedbackAPI128.get(account,owner:owner,path:"/me/feedback/"+ticket.id+suffix)
            guard owner==account.user?.id,!Task.isCancelled else { return }
            messages=older ? result.messages+messages:result.messages;detail=result;problem=nil
            if !older {
                let _: [String:Bool]=try await MemberFeedbackAPI128.post(account,owner:owner,path:"/me/feedback/"+ticket.id+"/read",body:["message_id":.number(Double(result.ticket.last_message_id))])
            }
        } catch is CancellationError {} catch { if owner==account.user?.id { problem=error.localizedDescription } }
    }
}
private struct FeedbackMediaPreview128: View {
    let attachment:MemberFeedbackAttachment128;let owner:Int
    @EnvironmentObject private var account:AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var image:UIImage?;@State private var player:AVPlayer?;@State private var file:URL?
    @State private var error:String?;@State private var loading=true
    var body: some View {
        ClubNavigationStack132 {
            Group {
                if let image { ScrollView([.horizontal,.vertical]) { Image(uiImage:image).resizable().scaledToFit().containerRelativeFrame(.horizontal) } }
                else if let player { VideoPlayer(player:player) }
                else if let error { ContentUnavailableView("附件暂不可用",systemImage:"exclamationmark.circle",description:Text(error)) }
                else { ProgressView("正在读取附件…") }
            }.navigationTitle(attachment.kind=="video" ? "反馈视频":"反馈照片").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }.task(id:attachment.id) {
            do {
                let raw=try await account.cloudRequest(path:"/me/feedback/attachments/"+attachment.id,expectedUserID:owner)
                guard raw.statusCode==200,raw.data.count<=21*1024*1024,account.user?.id==owner,!Task.isCancelled else { throw AccountError.message("附件读取失败，请返回重试。") }
                if attachment.kind=="image" { guard let value=UIImage(data:raw.data) else { throw AccountError.message("照片无法显示。") };image=value }
                else {
                    let url=FileManager.default.temporaryDirectory.appendingPathComponent("fb128-preview-"+UUID().uuidString+".mp4")
                    try raw.data.write(to:url,options:[.atomic,.completeFileProtection]);file=url;player=AVPlayer(url:url)
                }
            } catch is CancellationError {} catch { self.error=error.localizedDescription };loading=false
        }.onDisappear { player?.pause();player=nil;if let file { try? FileManager.default.removeItem(at:file) } }
            .onChange(of:account.user?.id) { _,id in if id != owner { player?.pause();dismiss() } }
    }
}
extension MemberFeedbackTicket128: Hashable {
    static func == (a:Self,b:Self)->Bool { a.id==b.id }
    func hash(into hasher:inout Hasher) { hasher.combine(id) }
}
