import SwiftUI

/// The first plan has its own recoverable onboarding destination. It never
/// opens a legacy dashboard or resubmits a job when the user returns here.
@MainActor
struct FirstPlanPreviewView: View {
    let initialPlanJobID: String
    let onPlanApplied: () -> Void
    let onReturnToOnboarding: () -> Void
    var completionBusy = false
    var completionError: String?

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var weekly: WeeklyReviewService
    @State private var recovering = false
    @State private var showPlan = false

    // AIService follows replacement IDs, so retrying an expired task continues
    // to display the replacement without losing the original onboarding draft.
    private var job: AILocalJob? { ai.job(initialPlanJobID) }
    private var applied: Bool { job.map { store.hasAppliedAIJob($0.id) } ?? false }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(applied ? "第一份计划已保存" : "准备你的第一份训练计划")
                        .font(.title2.weight(.semibold))
                    Text("核对动作、组数和日期，确认后加入训练日程。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 8)
            }

            Section("计划进度") {
                if let job {
                    AIJobStatusView(id: job.id, animated: true)
                    if let date = ClubDates.date(fromKey: job.request.date) {
                        LabeledContent("开始日期", value: ClubDates.label(date))
                    }
                    if completionError == nil {
                        Button(applied ? "完成加入俱乐部" : job.status == "succeeded" ? "查看并确认计划" : "查看计划进度") {
                            if applied { onPlanApplied() }
                            else { showPlan = true }
                        }
                        .accessibilityIdentifier("first-plan-preview-open")
                    }
                } else {
                    Text("正在恢复原计划任务，原任务不会重复提交。")
                        .foregroundStyle(.secondary)
                    Button(recovering ? "正在恢复…" : "恢复计划进度") { Task { await recoverPlan() } }.disabled(recovering)
                    Button("返回资料与计划", action: onReturnToOnboarding)
                }
            }

            if completionBusy {
                Section {
                    ProgressView("正在完成加入俱乐部…")
                }
            } else if let completionError {
                Section("加入暂未完成") {
                    Text(completionError).foregroundStyle(.secondary)
                    Text("已保存的计划会保留，无需重新生成。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重试完成加入", action: onPlanApplied)
                        .accessibilityIdentifier("first-plan-completion-retry")
                }
            }

            Section {
                Button("修改首次资料", action: onReturnToOnboarding)
            } footer: {
                Text("进入俱乐部后，Club AI 与训练工作区会保留这份安排。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("第一份训练计划")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(completionBusy)
        .sheet(isPresented: $showPlan) {
            if let job, let date = ClubDates.date(fromKey: job.request.date) {
                PlanView(date: date, initialMode: job.request.kind,
                         initialJobID: job.id, onPlanApplied: {
                             showPlan = false
                             onPlanApplied()
                         })
            }
        }
        .task(id: initialPlanJobID) {
            ai.resume()
            if job == nil { await recoverPlan() }
        }
        .accessibilityIdentifier("first-plan-preview")
    }
    private func recoverPlan() async {
        guard !recovering else { return }
        recovering = true
        defer { recovering = false }
        await ai.recoverTasks(account: account, weekly: weekly, store: store, targetID: initialPlanJobID)
    }

}
