import SwiftUI
import PhotosUI

struct RecordRepairView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var owner: Int?
    @State private var exportURL: URL?
    @State private var feedback: String?
    @State private var busy = false
    @State private var confirmLocal = false
    @State private var confirmCloud = false
    @State private var deleting: PhotoSyncIssue?
    @State private var replacing: PhotoSyncIssue?
    @State private var selection: PhotosPickerItem?
    @State private var showPhotoPicker = false
    private var ownsAccount: Bool { owner != nil && owner == store.editingAccountID }
    var body: some View {
        ClubNavigationStack132 {
            List {
                if let recovery = store.localRecovery {
                    Section("本机记录恢复") {
                        Text(recovery.detail)
                        Text("可读取日志 \(recovery.readableEntries) 条 · 无法读取 \(recovery.unreadableEntries) 条").bojiType(.caption)
                        Button("先导出原文件") { perform { exportURL = try store.exportRecoveryFiles(); feedback = "包含个人记录，请保存到你信任的位置。这个文件用于排查恢复，不能作为普通月度备份导入。" } }.buttonStyle(ClubActionButtonStyle(kind: .row))
                        if let exportURL { ShareLink("保存恢复文件", item: exportURL).buttonStyle(ClubActionButtonStyle(kind: .row)) }
                        Button("重新读取本机记录") { feedback = store.retryLocalRecords() ? "本机记录已恢复。" : store.takeMessage() }.buttonStyle(ClubActionButtonStyle(kind: .row))
                        if recovery.snapshotReadable { Button("恢复已整理的可读内容") { confirmLocal = true }.buttonStyle(ClubActionButtonStyle(kind: .row)) }
                        Button("使用云端副本恢复") { confirmCloud = true }.buttonStyle(ClubActionButtonStyle(kind: .row))
                        Text("恢复前会另存原文件副本。无法读取或尚未同步的修改可能不在恢复结果中，请先备份再选择。").bojiType(.caption).foregroundStyle(.secondary)
                    }
                }
                if let notice = store.mediaCleanupNotice {
                    Section("附件清理") {
                        Text(notice).bojiType(.secondary)
                        Button("重试本机照片清理") { store.retryPhotoCleanup() }.buttonStyle(ClubActionButtonStyle(kind: .row))
                    }
                }
                Section("照片同步") {
                    Text("训练、饮食文字和体重与照片分别同步。个别照片失败时，其他记录继续保存。").bojiType(.secondary)
                    if store.photoSyncIssues.isEmpty { Text("目前没有需要处理的照片。") }
                    else {
                        Button("重试待处理照片") { store.retryPhotos(); feedback = "已安排重试，网络恢复后会继续。" }.buttonStyle(ClubActionButtonStyle(kind: .row))
                        ForEach(store.photoSyncIssues) { issue in
                            VStack(alignment: .leading, spacing: BojiLayout.inline) {
                                Text("\(issue.dateKey) · \(issue.mealName)").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                                Text(issue.detail).bojiType(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("重新选图") { replacing = issue; selection = nil; showPhotoPicker = true }.buttonStyle(SecondaryButton())
                                    Button("移除照片", role: .destructive) { deleting = issue }.buttonStyle(DestructiveButton())
                                }
                            }.padding(.vertical, BojiSpace.tight)
                        }
                    }
                }
                if busy { Section { ClubLoadingCard(title: "正在处理，原记录已保留…") } }
                if let feedback { Section { Text(feedback).bojiType(.secondary).textSelection(.enabled) } }
            }.clubListSurface().disabled(busy || !ownsAccount)
                .navigationTitle("记录与照片修复").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { DismissButton().disabled(busy) } }
                .onAppear { owner = store.editingAccountID }
                .onChange(of: store.editingAccountID) { _, id in if id != owner { dismiss() } }
                .confirmationDialog("恢复可读内容？", isPresented: $confirmLocal, titleVisibility: .visible) {
                    Button("备份原文件并恢复") { perform { try store.restoreReadableRecords(); feedback = "可读取内容已恢复，请核对最近的记录。" } }
                } message: { Text("无法读取条目中的修改可能缺失。原文件会另存为恢复副本。") }
                .confirmationDialog("使用云端副本恢复？", isPresented: $confirmCloud, titleVisibility: .visible) {
                    Button("备份原文件并恢复云端副本") {
                        guard ownsAccount, !busy else { return }; busy = true
                        Task {
                            defer { busy = false }
                            do { try await store.restoreCloudRecords(); if ownsAccount { feedback = "云端记录已恢复，照片会继续下载。请核对最近的记录。" } }
                            catch { if ownsAccount { feedback = AppErrorText.message(error) } }
                        }
                    }
                } message: { Text("尚未上传的本机修改可能不在云端副本中，恢复前会保留原文件。") }
                .confirmationDialog("移除这张照片？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("仅移除附件", role: .destructive) {
                        if ownsAccount, let issue = deleting { feedback = store.removeBrokenPhoto(issue) ? "照片附件已移除，饮食记录保留。" : store.takeMessage() }
                        deleting = nil
                    }
                } message: { Text("食物、份量和营养数字保留；同步后其他设备的这张附件也会移除。") }
                .photosPicker(isPresented: $showPhotoPicker, selection: $selection, matching: .images)
                .task(id: selection) {
                    guard ownsAccount, let selected = selection, let issue = replacing, !busy else { return }
                    busy = true; defer { busy = false }
                    do {
                        guard let data = try await selected.loadTransferable(type: Data.self), ownsAccount else { return }
                        try await store.replaceBrokenPhoto(issue, data: data)
                        if ownsAccount { feedback = "照片已替换并压缩，联网后继续同步。" }
                    } catch { if ownsAccount { feedback = AppErrorText.message(error) } }
                }
        }
    }
    private func perform(_ action: () throws -> Void) {
        guard ownsAccount, !busy else { return }
        do { try action() } catch { feedback = AppErrorText.message(error) }
    }
}

struct TCXPreviewView: View {
    let inspection: TCXInspection
    let confirm: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?
    var body: some View {
        ClubNavigationStack132 {
            List {
                Section("导入预览") {
                    Text("可用 \(inspection.workouts.count) 条 · 跳过 \(inspection.skippedCount) 条").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                    Text("确认后才会写入，重复运动不会重复保存。不读取 GPS，运动热量不叠加到全天活动能量。").bojiType(.secondary)
                    ForEach(inspection.skipped.keys.sorted(), id: \.self) { reason in Text("\(reason)：\(inspection.skipped[reason] ?? 0) 条").bojiType(.caption) }
                }
                Section("有效运动") {
                    ForEach(inspection.workouts) { workout in
                        VStack(alignment: .leading, spacing: BojiLayout.tight) {
                            Text(workout.name).bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                            Text("\(workout.start.formatted(date: .abbreviated, time: .shortened)) · \(Int(workout.minutes)) 分钟").bojiType(.caption)
                        }
                    }
                }
                if let feedback { Section { Text(feedback).foregroundStyle(.red) } }
                Section {
                    Button("确认导入有效记录") { do { try confirm(); dismiss() } catch { feedback = AppErrorText.message(error) } }
                        .buttonStyle(PrimaryButton()).disabled(inspection.workouts.isEmpty)
                }
            }.clubListSurface().navigationTitle("核对运动文件").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
