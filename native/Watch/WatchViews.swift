import SwiftUI

private enum WatchPalette {
    static let action = Color(red: 0.77, green: 0.95, blue: 0.29)
    static let success = Color.green
    static let panel = Color.white.opacity(0.08)
}

struct WatchRootView: View {
    @Environment(WatchAppModel.self) private var model
    @State private var isConfirmingDiscard = false

    var body: some View {
        Group {
            if model.isComplete { completion }
            else if model.needsFailureRecovery { failureRecovery }
            else if model.executionRecoveryError != nil { unreadableRecovery }
            else if model.isActive { workout }
            else { start }
        }
        .confirmationDialog(
            "确定放弃这次训练记录？",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("确认放弃", role: .destructive) {
                if model.needsFailureRecovery {
                    model.discardFailedExecution()
                } else {
                    model.discardUnreadableExecution()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已完成但尚未归档的组次将无法从手表恢复。")
        }
    }

    private var start: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let plan = model.plan {
                    Label("今日训练", systemImage: "figure.strengthtraining.traditional")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(plan.title).font(.headline.weight(.semibold)).lineLimit(2)
                    HStack {
                        Label("\(plan.exercises.count) 动作", systemImage: "list.number")
                        Label("\(plan.estimatedMinutes) 分", systemImage: "clock")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Button { model.start() } label: { Label("开始训练", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(WatchPalette.action)
                        .disabled(model.workout.isStarting)
                    if model.workout.isStarting {
                        ProgressView("正在准备…")
                            .font(.caption2)
                    } else if let error = model.workout.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else {
                    ContentUnavailableView("暂无计划", systemImage: "applewatch", description: Text("先在 iPhone 同步"))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var workout: some View {
        @Bindable var model = model
        return TabView {
            VStack(spacing: 8) {
                HStack {
                    Label("\(Int(model.workout.heartRate))", systemImage: "heart.fill")
                        .foregroundStyle(.red)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("有效 \(duration(model.workout.activeDuration(at: context.date)))")
                            Text("总计 \(duration(model.workout.elapsedDuration(at: context.date)))")
                                .foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                    }
                }.font(.caption2)
                ProgressView(value: Double(model.completedSets), total: Double(max(model.totalSets, 1)))
                    .tint(WatchPalette.action)
                if let state = model.workout.lifecycle?.state, state != .running, state != .paused {
                    Label(status(state), systemImage: state == .preparing ? "hourglass" : "square.and.arrow.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if model.workout.errorMessage != nil {
                    Label("心率与能量未采集，组次仍会保存", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if let message = model.workout.mirroringMessage {
                    Label(message, systemImage: "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if model.workout.lifecycle?.state == .paused {
                    Label("训练已暂停", systemImage: "pause.circle.fill")
                        .font(.headline)
                        .foregroundStyle(WatchPalette.action)
                } else if model.workout.lifecycle?.state != .running {
                    ProgressView()
                } else if let until = model.restUntil {
                    restCard(until: until)
                } else {
                    activeSet
                }
            }.padding(.horizontal, 2)

            VStack(spacing: 10) {
                if let state = model.workout.lifecycle?.state {
                    Text(status(state)).font(.headline)
                }
                if model.workout.lifecycle?.state == .paused {
                    Button { model.resume() } label: { Label("继续", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(WatchPalette.action)
                } else {
                    Button { model.pause() } label: { Label("暂停", systemImage: "pause.fill") }
                        .buttonStyle(.bordered)
                        .disabled(model.workout.lifecycle?.state != .running)
                }
                Button(role: .destructive) { Task { await model.finish() } } label: {
                    Label("停止并保存", systemImage: "stop.fill")
                }
                .disabled(model.workout.lifecycle?.state != .running && model.workout.lifecycle?.state != .paused)
                Divider()
                Text("末组感受").font(.caption.weight(.semibold))
                Picker("末组感受", selection: $model.feeling) {
                    ForEach(LastSetFeeling.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden()
            }
        }
        .tabViewStyle(.verticalPage)
    }

    @ViewBuilder
    private var activeSet: some View {
        if let exercise = model.currentExercise {
            Text(exercise.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("第 \(model.setNumber) / \(exercise.sets) 组")
                .font(.caption).foregroundStyle(.secondary)
            Text(exercise.targetWeightKg.map { "\($0.formatted()) kg" } ?? "自重")
                .font(.title3.weight(.semibold)).monospacedDigit()
            HStack {
                Button { model.reps = max(0, model.reps - 1) } label: { Image(systemName: "minus") }
                Text("\(model.reps)").font(.title2.weight(.semibold)).monospacedDigit().frame(minWidth: 38)
                Button { model.reps += 1 } label: { Image(systemName: "plus") }
            }
            Button { model.completeCurrentSet() } label: { Label("完成本组", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent)
                .tint(WatchPalette.action)
        }
    }

    private func restCard(until: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
            if seconds > 0 {
                VStack(spacing: 8) {
                    Image(systemName: "timer").foregroundStyle(WatchPalette.action)
                    Text("组间休息").font(.caption.weight(.semibold))
                    Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .font(.title2.bold().monospacedDigit())
                    HStack {
                        Button("+30") { model.extendRest(by: 30) }
                        Button("跳过") { model.skipRest() }
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(WatchPalette.panel, in: RoundedRectangle(cornerRadius: 14))
            } else {
                activeSet
            }
        }
    }

    private var completion: some View {
        VStack(spacing: 10) {
            Image(systemName: model.completedWithWorkoutFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(model.completedWithWorkoutFailure ? .orange : WatchPalette.success)
            Text(model.completedWithWorkoutFailure ? "组次已保留" : "训练已保存").font(.headline)
            Text("\(model.completedSets) 组 · \(duration(model.workout.elapsed))")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.completedWithWorkoutFailure ? "HealthKit 记录可能不完整" : "回到 iPhone 补充整体反馈")
                .font(.caption2)
                .multilineTextAlignment(.center)
            Button("返回计划") { model.dismissCompletion() }
                .buttonStyle(.bordered)
        }
    }

    private var failureRecovery: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("训练恢复失败").font(.headline)
                Text("已完成的 \(model.completedSets) 组仍保存在手表中。")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await model.keepFailedExecution() }
                } label: {
                    Text("结束并保存已有组次")
                }
                .buttonStyle(.borderedProminent)
                .tint(WatchPalette.action)
                Button(role: .destructive) {
                    isConfirmingDiscard = true
                } label: {
                    Text("放弃记录")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var unreadableRecovery: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("无法恢复训练").font(.headline)
                Text(model.executionRecoveryError ?? "训练恢复记录暂时无法读取。")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                Button(role: .destructive) {
                    isConfirmingDiscard = true
                } label: {
                    Text("放弃本地恢复记录")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func duration(_ value: TimeInterval) -> String {
        let total = Int(value)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func status(_ state: WorkoutLifecycleState) -> String {
        switch state {
        case .preparing: "正在准备"
        case .running: "训练中"
        case .paused: "已暂停"
        case .stopped: "已停止"
        case .finalizing: "正在保存"
        case .completed: "已完成"
        case .failed: "训练失败"
        }
    }
}
