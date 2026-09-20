import ActivityKit
import SwiftUI
import WidgetKit

@main
struct KrisLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        KrisWorkoutLiveActivity()
    }
}

struct KrisWorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(trainingURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isRunning
                        ? "figure.strengthtraining.traditional" : "pause.fill")
                        .font(.headline)
                        .foregroundStyle(brandLime)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    duration(context.state)
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.exerciseName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(setText(context.state))
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        if let until = activeRestDeadline(context.state) {
                            Label {
                                Text(timerInterval: Date()...until, countsDown: true)
                                    .monospacedDigit()
                            } icon: {
                                Image(systemName: "timer")
                            }
                            .foregroundStyle(brandLime)
                        } else {
                            Text("\(context.state.completedSets)/\(max(context.state.totalSets, 1)) 组")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
            } compactLeading: {
                Image(systemName: context.state.isRunning ? "figure.strengthtraining.traditional" : "pause.fill")
                    .foregroundStyle(brandLime)
            } compactTrailing: {
                compactTimer(context.state)
            } minimal: {
                ZStack {
                    Circle().stroke(.white.opacity(0.2), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: progress(context.state))
                        .stroke(brandLime, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.caption2)
                }
            }
            .widgetURL(trainingURL)
            .keylineTint(brandLime)
        }
    }

    private func lockScreen(
        _ context: ActivityViewContext<WorkoutActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("KRIS 训练", systemImage: "figure.strengthtraining.traditional")
                        .font(.caption.bold())
                        .foregroundStyle(brandLime)
                    Text(context.state.planTitle)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    duration(context.state)
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Text(context.state.lifecycle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.exerciseName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(setText(context.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let until = activeRestDeadline(context.state) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("休息")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(timerInterval: Date()...until, countsDown: true)
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(brandLime)
                    }
                } else {
                    Text("\(context.state.completedSets)/\(max(context.state.totalSets, 1)) 组")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }
            ProgressView(
                value: Double(context.state.completedSets),
                total: Double(max(context.state.totalSets, 1))
            )
            .tint(brandLime)
        }
        .padding(14)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func duration(_ state: WorkoutActivityAttributes.ContentState) -> some View {
        if state.isRunning {
            let start = state.updatedAt.addingTimeInterval(-max(0, state.activeDurationSeconds))
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
        } else {
            Text(formattedDuration(state.activeDurationSeconds))
        }
    }

    private func setText(_ state: WorkoutActivityAttributes.ContentState) -> String {
        guard state.setNumber > 0 else { return "计划组次已完成" }
        return "下一组 · 第 \(state.setNumber) 组"
    }

    @ViewBuilder
    private func compactTimer(_ state: WorkoutActivityAttributes.ContentState) -> some View {
        if let until = activeRestDeadline(state) {
            Text(timerInterval: Date()...until, countsDown: true)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(brandLime)
        } else {
            duration(state)
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
    }

    private func activeRestDeadline(
        _ state: WorkoutActivityAttributes.ContentState
    ) -> Date? {
        guard let restUntil = state.restUntil, restUntil > Date() else { return nil }
        return restUntil
    }

    private func progress(_ state: WorkoutActivityAttributes.ContentState) -> Double {
        min(max(Double(state.completedSets) / Double(max(state.totalSets, 1)), 0), 1)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private var brandLime: Color { Color(red: 0.78, green: 0.98, blue: 0.20) }
    private var trainingURL: URL { URL(string: "kriscoach://training")! }
}
