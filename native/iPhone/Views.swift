import Accessibility
import Charts
import SwiftUI
import UIKit

enum ReadinessPresentation {
    static func stateLabel(_ state: String?) -> String {
        switch state {
        case "train_progress": "可推进"
        case "train_maintain": "可训练"
        case "train_reduce": "需降阶"
        case "recover_or_light": "恢复优先"
        case "insufficient_data": "数据不足"
        // A missing local result is a data-availability state, not a loading
        // state. The home screen can render immediately from its cache.
        default: "等待本地数据"
        }
    }

    static func decisionLine(_ readiness: SnapshotReadiness?) -> String {
        guard let readiness else { return "授权 Apple 健康后开始形成个人基线" }
        if readiness.safetyGate == "stop_and_seek_care" {
            return "停止训练并优先处理异常信号"
        }
        if readiness.safetyGate == "reduce" || readiness.state == "train_reduce" {
            return "保留训练习惯，降低今天的训练负荷"
        }
        switch readiness.state {
        case "recover_or_light": return "优先恢复，或只进行轻量活动"
        case "insufficient_data": return "继续补齐恢复数据"
        default: return readiness.score == nil ? "继续补齐恢复数据" : "按当前计划执行，并记录真实组次"
        }
    }
}

/// Consumer-facing language for the home screen. "Readiness" remains the
/// underlying model, but the first screen should answer how today looks before
/// turning that score into a training prescription.
enum TodayStatePresentation {
    static func title(_ readiness: SnapshotReadiness?) -> String {
        guard let readiness else { return "正在建立个人基线" }
        if readiness.safetyGate == "stop_and_seek_care" { return "今天先处理异常信号" }
        if readiness.safetyGate == "reduce" || readiness.state == "train_reduce" {
            return "今天适合放慢一点"
        }
        switch readiness.state {
        case "recover_or_light": return "今天以恢复为主"
        case "insufficient_data": return "个人基线正在校准"
        case "train_progress": return "恢复状态良好"
        default: return readiness.score == nil ? "个人基线正在校准" : "恢复状态稳定"
        }
    }

    static func summary(_ readiness: SnapshotReadiness?, hasTrainingPlan: Bool) -> String {
        guard let readiness else { return "连接 Apple 健康后，Kris 会逐步形成你的近期基线。" }
        if readiness.safetyGate == "stop_and_seek_care" {
            return "当前信号触发安全停止条件，先查看依据并处理不适。"
        }
        if readiness.safetyGate == "reduce" || readiness.state == "train_reduce" {
            return hasTrainingPlan
                ? "恢复信号偏离近期基线，训练建议降低强度或容量。"
                : "恢复信号偏离近期基线，今天更适合轻量活动。"
        }
        if readiness.state == "recover_or_light" {
            return "睡眠、心率或近期负荷提示恢复优先。"
        }
        if readiness.state == "insufficient_data" || readiness.score == nil {
            return "保持日常节奏，状态会随新记录持续校准。"
        }
        return hasTrainingPlan
            ? "恢复信号接近近期基线，今天可以按计划训练。"
            : "恢复信号接近近期基线，保持日常活动即可。"
    }

    static func status(_ readiness: SnapshotReadiness?) -> String {
        guard let readiness else { return "建立中" }
        if readiness.safetyGate == "stop_and_seek_care" { return "需处理" }
        if readiness.safetyGate == "reduce" || readiness.state == "train_reduce" { return "需调整" }
        switch readiness.state {
        case "recover_or_light": return "恢复优先"
        case "insufficient_data": return "校准中"
        default: return readiness.score == nil ? "校准中" : "状态正常"
        }
    }
}

enum ReadinessEvidencePresentation {
    static func label(_ signal: String) -> String {
        switch signal {
        case "sleep": "睡眠"
        case "hrv_sdnn": "HRV · SDNN"
        case "resting_hr": "静息心率"
        case "acute_to_baseline_load": "近期训练负荷"
        default: signal
        }
    }

    static func icon(_ signal: String) -> String {
        switch signal {
        case "sleep": "moon.fill"
        case "hrv_sdnn": "waveform.path.ecg"
        case "resting_hr": "heart.fill"
        case "acute_to_baseline_load": "chart.bar.fill"
        default: "circle.hexagongrid.fill"
        }
    }

    static func valueLine(_ item: ReadinessEvidence) -> String {
        let current = formatted(item.value, unit: item.unit)
        guard item.baseline != nil else { return current }
        return "\(current) · 个人基线 \(formatted(item.baseline, unit: item.unit))"
    }

    static func deltaLine(_ item: ReadinessEvidence) -> String? {
        if let value = item.deltaPct {
            return "较基线 \(signed(value, suffix: "%"))"
        }
        if let value = item.delta {
            return "较基线 \(signed(value, suffix: item.unit.map { " \($0)" } ?? ""))"
        }
        return nil
    }

    static func impactLine(_ item: ReadinessEvidence) -> String? {
        switch item.impact {
        case "中性/支持": "支持按计划训练"
        default: item.impact
        }
    }

    private static func formatted(_ value: Double?, unit: String?) -> String {
        guard let value else { return "—" }
        let digits = abs(value) >= 100 ? 0 : 1
        let number = value.formatted(.number.precision(.fractionLength(digits)))
        return unit.map { "\(number) \($0)" } ?? number
    }

    private static func signed(_ value: Double, suffix: String) -> String {
        let prefix = value > 0 ? "+" : ""
        return "\(prefix)\(value.formatted(.number.precision(.fractionLength(1))))\(suffix)"
    }
}

enum ReadinessComponentPresentation {
    static let order = ["sleep", "hrv", "rhr", "load"]

    static func label(_ key: String) -> String {
        switch key {
        case "sleep": "睡眠"
        case "hrv": "HRV"
        case "rhr": "静息心率"
        case "load": "训练负荷"
        default: key
        }
    }

    static func icon(_ key: String) -> String {
        switch key {
        case "sleep": "moon.fill"
        case "hrv": "waveform.path.ecg"
        case "rhr": "heart.fill"
        case "load": "chart.bar.fill"
        default: "circle.hexagongrid.fill"
        }
    }

    static func interpretation(score: Double?) -> String {
        guard let score else { return "未参与今日计算" }
        if score >= 60 { return "支持训练" }
        if score >= 40 { return "接近个人常态" }
        return "限制今日负荷"
    }
}

private struct TrendChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let unit: String
    let summary: String
    let domain: ClosedRange<Double>
    let data: [SnapshotTrends.Point]

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "日期", categoryOrder: data.map(\.date)
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: title, range: domain, gridlinePositions: []
        ) { value in
            "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
        }
        let points = data.map {
            AXDataPoint(
                x: $0.date, y: $0.value,
                label: "\($0.date)，\($0.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
            )
        }
        let series = AXDataSeriesDescriptor(
            name: title, isContinuous: true, dataPoints: points
        )
        return AXChartDescriptor(
            title: "\(title)趋势", summary: summary,
            xAxis: xAxis, yAxis: yAxis, series: [series]
        )
    }
}

struct RootTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            TodayView()
                .tabItem { rootTabLabel("今日", systemImage: "sun.max.fill") }
                .tag(0)
            HealthView()
                .tabItem { rootTabLabel("健康", systemImage: "heart.text.square.fill") }
                .tag(1)
            TrainingView()
                .tabItem { rootTabLabel("训练", systemImage: "figure.strengthtraining.traditional") }
                .tag(2)
            TrendsView()
                .tabItem { rootTabLabel("趋势", systemImage: "chart.xyaxis.line") }
                .tag(3)
            SettingsView()
                .tabItem { rootTabLabel("设置", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(KrisTheme.accent)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    private func rootTabLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            // Keep all five destinations visible at the largest accessibility
            // sizes while preserving the user's preferred size in page content.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDomain: HealthDomain?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KrisBrandHeader()
                    todayStateHero
                    if let plan = model.homeTrainingPlan, model.activeDraft != nil {
                        planSummary(plan)
                    }
                    coreMetrics
                    activityPanel
                    if let plan = model.homeTrainingPlan, model.activeDraft == nil {
                        planSummary(plan)
                    }
                    if model.healthAttentionMessage != nil { healthAttentionBanner }
                    freshness
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(KrisTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedDomain) { domain in
                HealthDomainDetailView(domain: domain)
            }
        }
    }

    private var todayStateHero: some View {
        let readiness = model.effectiveReadiness
        let tint = readinessTint(readiness)
        return KrisPanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: heroIcon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(heroTitle)
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(heroSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                homeSignal("睡眠", value: metric(model.health.todayMetrics.sleepHours, digits: 1, unit: "h"))
                homeSignal("HRV", value: metric(model.health.todayMetrics.hrvMs, digits: 0, unit: "ms"))
                homeSignal("静息心率", value: metric(model.health.todayMetrics.restingHeartRate, digits: 0, unit: ""))
            }

            Button(action: primaryStateAction) {
                HStack {
                    Text(primaryStateActionTitle)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(KrisTheme.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("daily-action-recommendation")

            if readiness?.safetyGate != "stop_and_seek_care" {
                Button { model.selectedTab = 1 } label: {
                    Label("查看身体数据", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(KrisOutlineButtonStyle())
                .accessibilityIdentifier("daily-health-action")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-state-hero")
    }

    private var heroTitle: String {
        if model.activeDraft != nil { return "继续今天的训练" }
        if model.effectiveReadiness?.safetyGate == "stop_and_seek_care" { return "先停下来处理不适" }
        return "今天想做什么？"
    }

    private var heroSummary: String {
        if model.activeDraft != nil { return "训练还在进行，随时回去继续。" }
        if model.effectiveReadiness?.safetyGate == "stop_and_seek_care" {
            return "检测到需要优先处理的异常信号，今天先暂停训练。"
        }
        if model.homeTrainingPlan != nil { return "已有训练计划，也可以先查看身体数据。" }
        return "从训练计划或身体数据开始安排今天。"
    }

    private var heroIcon: String {
        if model.activeDraft != nil { return "play.fill" }
        if model.effectiveReadiness?.safetyGate == "stop_and_seek_care" { return "cross.case.fill" }
        return model.homeTrainingPlan == nil ? "figure.walk.motion" : "figure.strengthtraining.traditional"
    }

    private func homeSignal(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(KrisTheme.muted.opacity(0.65), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var healthUpdateLabel: String {
        guard let date = model.health.lastImportAt else {
            return model.healthAttentionMessage == nil ? "自动更新" : "需处理"
        }
        return date.formatted(date: .omitted, time: .shortened) + " 更新"
    }

    private var primaryStateActionTitle: String {
        if model.effectiveReadiness?.safetyGate == "stop_and_seek_care" { return "查看异常信号" }
        if model.activeDraft != nil { return "继续训练" }
        if model.homeTrainingPlan != nil { return "查看今天的计划" }
        return "安排训练"
    }

    private func primaryStateAction() {
        if model.effectiveReadiness?.safetyGate == "stop_and_seek_care" {
            selectedDomain = .recovery
        } else {
            model.selectedTab = 2
        }
    }

    private func readinessTint(_ readiness: SnapshotReadiness?) -> Color {
        guard let readiness else { return .secondary }
        if readiness.safetyGate == "stop_and_seek_care" { return KrisTheme.danger }
        if readiness.safetyGate == "reduce" || readiness.state == "train_reduce"
            || readiness.state == "recover_or_light" { return KrisTheme.caution }
        if readiness.state == "insufficient_data" || readiness.score == nil { return .secondary }
        return KrisTheme.positive
    }

    private var coreMetrics: some View {
        KrisPanel {
            KrisSectionHeading("今日核心指标", trailing: coreMetricCoverage)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8),
                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
                ),
                spacing: 8
            ) {
                metricTile(
                    "睡眠", value: metric(metricValue(model.health.todayMetrics.sleepHours, signal: "sleep"), digits: 1, unit: "h"),
                    note: comparison(for: "sleep") ?? "尚无可比基线", icon: "moon.fill",
                    tint: KrisTheme.recovery, domain: .sleep
                )
                metricTile(
                    "HRV", value: metric(metricValue(model.health.todayMetrics.hrvMs, signal: "hrv_sdnn"), digits: 0, unit: "ms"),
                    note: comparison(for: "hrv_sdnn") ?? "尚无可比基线", icon: "waveform.path.ecg",
                    tint: KrisTheme.recovery, domain: .recovery
                )
                metricTile(
                    "静息心率", value: metric(metricValue(model.health.todayMetrics.restingHeartRate, signal: "resting_hr"), digits: 0, unit: "bpm"),
                    note: comparison(for: "resting_hr") ?? "尚无可比基线", icon: "heart.fill",
                    tint: KrisTheme.danger, domain: .recovery
                )
                metricTile(
                    "晨起体测", value: metric(model.health.todayMetrics.bodyMassKg, digits: 1, unit: "kg"),
                    note: bodyFatNote, icon: "figure.stand", tint: KrisTheme.body, domain: .body
                )
            }
        }
        .accessibilityIdentifier("today-core-metrics")
    }

    private var coreMetricCoverage: String {
        return "自动更新"
    }

    private func comparison(for signal: String) -> String? {
        guard let item = model.effectiveEvidence.first(where: { $0.signal == signal }) else { return nil }
        return ReadinessEvidencePresentation.deltaLine(item)
    }

    private func metricValue(_ local: Double?, signal: String) -> Double? {
        local ?? model.effectiveEvidence.first(where: { $0.signal == signal })?.value
    }

    private var activityPanel: some View {
        KrisPanel {
            KrisSectionHeading("今日活动", trailing: "实时，非日结")
            HStack(spacing: 0) {
                activityValue(
                    title: "步数", value: metric(model.health.todayMetrics.steps, digits: 0, unit: ""),
                    icon: "figure.walk", tint: KrisTheme.positive
                )
                Divider().frame(height: 42).padding(.horizontal, 14)
                activityValue(
                    title: "活动能量", value: metric(model.health.todayMetrics.activeKcal, digits: 0, unit: "kcal"),
                    icon: "flame.fill", tint: KrisTheme.caution
                )
            }
            Text("截至目前的活动记录")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let total = model.health.todayMetrics.totalKcal {
                Label(
                    "当前总消耗约 \(total.formatted(.number.precision(.fractionLength(0)))) kcal（当天未结束）",
                    systemImage: "gauge.with.dots.needle.50percent"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("today-activity")
    }

    private func activityValue(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var hasDecisionExplanation: Bool {
        !model.effectiveEvidence.isEmpty
            || model.effectiveDecisionTrace != nil
            || (model.activeDraft == nil && !model.planChanges.isEmpty)
    }

    private var decisionExplanation: some View {
        let trace = model.effectiveDecisionTrace
        let actions = trace?.actions ?? []
        return KrisPanel {
            KrisSectionHeading("今天为什么这样安排", trailing: "可追溯")
            if trace != nil || model.effectiveReadiness != nil {
                Text(ReadinessPresentation.decisionLine(model.effectiveReadiness))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.effectiveEvidence.isEmpty {
                Text("影响今天判断")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(model.effectiveEvidence.prefix(3).enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider() }
                        ReadinessEvidenceRow(item: item)
                    }
                }
            }

            if !actions.isEmpty {
                Divider()
                Text("处方响应")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(actions.prefix(2).enumerated()), id: \.offset) { _, action in
                    Label(action, systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.activeDraft == nil, !model.planChanges.isEmpty {
                Divider()
                Text("计划变化")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(model.planChanges.prefix(2).enumerated()), id: \.offset) { _, change in
                    Label(change, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            NavigationLink {
                DecisionTraceView()
            } label: {
                HStack {
                    Text("查看完整决策依据").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .foregroundStyle(KrisTheme.accent)
                .frame(minHeight: 44)
            }
        }
        .accessibilityIdentifier("decision-explanation")
    }

    private func metricTile(_ title: String, value: String, note: String, icon: String, tint: Color, domain: HealthDomain) -> some View {
        Button {
            selectedDomain = domain
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
                    Text(title)
                    Spacer()
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(value).font(.headline.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.72)
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(KrisTheme.muted.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today-metric-\(icon)")
    }

    private var bodyFatNote: String {
        guard let value = model.health.todayMetrics.bodyFatPercent else { return "今日暂无体测" }
        return "体脂 \(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    private func metric(_ value: Double?, digits: Int, unit: String) -> String {
        guard let value else { return "—" }
        let number = value.formatted(.number.precision(.fractionLength(digits)))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    private var healthAttentionBanner: some View {
        Button { model.selectedTab = 1 } label: {
            HStack(spacing: 11) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KrisTheme.caution)
                    .frame(width: 32, height: 32)
                    .background(KrisTheme.caution.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple 健康需要处理")
                        .font(.subheadline.weight(.semibold))
                    Text(model.healthAttentionMessage ?? "打开健康页查看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(KrisTheme.raised, in: RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous)
                    .stroke(KrisTheme.border, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today-health-attention")
        .accessibilityHint("打开健康页处理 Apple 健康连接")
    }

    private func planSummary(_ plan: TrainingPlan) -> some View {
        KrisPanel {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(KrisTheme.brandInk)
                    .frame(width: 34, height: 34)
                    .background(KrisTheme.brandLime, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日训练").font(.headline.weight(.semibold))
                    Text("\(plan.estimatedMinutes) 分钟 · \(plan.exercises.count) 个动作")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                KrisStatusPill(
                    title: model.activeDraft == nil ? "待开始" : "进行中",
                    tint: model.activeDraft == nil ? KrisTheme.accent : KrisTheme.positive,
                    systemImage: model.activeDraft == nil ? "clock" : "record.circle"
                )
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.title).font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text((plan.goal?.isEmpty == false ? plan.goal : nil) ?? "今日训练安排")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(plan.exercises.prefix(3)) { exercise in
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(exercise.order). \(exercise.name)")
                            .font(.subheadline.weight(.semibold))
                        Text(target(exercise))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    HStack(spacing: 10) {
                        Text("\(exercise.order)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(KrisTheme.accent)
                            .frame(width: 20, height: 20)
                            .background(KrisTheme.accent.opacity(0.08), in: Circle())
                        Text(exercise.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text(target(exercise)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 30)
                }
            }
            Button {
                model.selectedTab = 2
            } label: {
                Label(model.activeDraft == nil ? "查看并开始" : "继续训练", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KrisPrimaryButtonStyle())
        }
    }

    private var freshness: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
            Text(healthLabel)
            Spacer()
            Text("已更新")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var healthLabel: String {
        if let date = model.health.lastImportAt { return "健康数据 \(date.formatted(date: .omitted, time: .shortened))" }
        return model.healthAttentionMessage == nil ? "健康数据自动更新" : "Apple 健康需要处理"
    }
}

struct HealthView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDomain: HealthDomain?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KrisPageHeader(
                        title: "健康",
                        subtitle: "看清恢复、活动与身体变化",
                        status: healthFreshness
                    )
                    .accessibilityIdentifier("health-page-header")
                    recoveryOverview
                    domainGrid
                    if model.healthAttentionMessage != nil { healthAttention }
                    Button {
                        model.selectedTab = 3
                    } label: {
                        Label("查看全部趋势", systemImage: "chart.xyaxis.line")
                    }
                    .buttonStyle(KrisOutlineButtonStyle())
                    .accessibilityIdentifier("health-open-trends")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(KrisTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedDomain) { domain in
                HealthDomainDetailView(domain: domain)
            }
        }
    }

    private var recoveryOverview: some View {
        let readiness = model.effectiveReadiness
        return Button { selectedDomain = .recovery } label: {
            KrisPanel {
                KrisSectionHeading("恢复状态", trailing: "个人基线")
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        readinessScore(readiness)
                        recoverySummary(readiness)
                    }
                } else {
                    HStack(spacing: 16) {
                        readinessScore(readiness)
                        recoverySummary(readiness)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看恢复信号与判断依据")
        .accessibilityIdentifier("health-recovery-overview")
    }

    private func readinessScore(_ readiness: SnapshotReadiness?) -> some View {
        let tint: Color = if readiness?.safetyGate == "stop_and_seek_care" {
            KrisTheme.danger
        } else if readiness?.safetyGate == "reduce" || readiness?.state == "train_reduce"
            || readiness?.state == "recover_or_light" {
            KrisTheme.caution
        } else {
            KrisTheme.readiness
        }
        return VStack(spacing: 6) {
            Image(systemName: readiness?.safetyGate == "stop_and_seek_care"
                ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.10), in: Circle())
            Text("恢复信号")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 86)
        .frame(minHeight: 86)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
    }

    private func recoverySummary(_ readiness: SnapshotReadiness?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ReadinessPresentation.decisionLine(readiness))
                .font(.headline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("结合睡眠、HRV、静息心率与近期负荷")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.effectiveEvidence.isEmpty {
                KrisStatusPill(
                    title: "\(model.effectiveEvidence.count) 项信号",
                    tint: KrisTheme.recovery,
                    systemImage: "waveform.path.ecg"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func healthSummaryCell(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var domainGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 10),
                count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
            ),
            spacing: 10
        ) {
            healthDomain(
                title: "睡眠",
                value: metric(value(.sleepHours), digits: 1, unit: "h"),
                detail: "HRV " + metric(value(.hrv), digits: 0, unit: "ms"),
                icon: "moon.fill", tint: KrisTheme.recovery,
                identifier: "health-domain-sleep", domain: .sleep
            )
            healthDomain(
                title: "身体组成",
                value: metric(latestBodyMass, digits: 1, unit: "kg"),
                detail: latestBodyFat.map {
                    "体脂 \($0.formatted(.number.precision(.fractionLength(1))))%"
                } ?? "等待晨起成套体测",
                icon: "figure.stand", tint: KrisTheme.body,
                identifier: "health-domain-body", domain: .body
            )
            healthDomain(
                title: "日常活动",
                value: metric(latestSteps, digits: 0, unit: "步"),
                detail: "活动 " + metric(latestActiveEnergy, digits: 0, unit: "kcal"),
                icon: "figure.walk", tint: KrisTheme.positive,
                identifier: "health-domain-activity", domain: .activity
            )
            healthDomain(
                title: "心肺能力",
                value: metric(latestVO2Max, digits: 1, unit: ""),
                detail: "静息心率 " + metric(value(.restingHeartRate), digits: 0, unit: "bpm"),
                icon: "heart.fill", tint: KrisTheme.danger,
                identifier: "health-domain-cardio", domain: .cardio
            )
        }
    }

    private func healthDomain(
        title: String, value: String, detail: String, icon: String, tint: Color,
        identifier: String, domain: HealthDomain
    ) -> some View {
        Button { selectedDomain = domain } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.10), in: Circle())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(title).font(.subheadline.weight(.semibold))
                Text(value)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .leading)
            .background(KrisTheme.raised, in: RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous)
                    .stroke(KrisTheme.border, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityIdentifier(identifier)
    }

    private var healthAttention: some View {
        Button { model.selectedTab = 4 } label: {
            KrisStatusRow(
                title: "Apple 健康需要处理",
                detail: model.healthAttentionMessage ?? "打开设置查看",
                tint: KrisTheme.caution,
                systemImage: "heart.slash.fill"
            )
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(KrisTheme.raised, in: RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("health-attention")
    }

    private func healthMetricFreshnessRow(_ item: HealthMetricFreshness) -> some View {
        let hasSamples = item.sampleCount > 0
        let automaticUpdates = model.health.automaticUpdatesEnabled
        let stateTitle: String
        let stateTint: Color
        let stateIcon: String
        if hasSamples {
            stateTitle = "已读取 · \(item.sampleCount) 个样本"
            stateTint = KrisTheme.positive
            stateIcon = "checkmark.circle.fill"
        } else if automaticUpdates {
            stateTitle = "暂无样本"
            stateTint = KrisTheme.caution
            stateIcon = "clock.arrow.circlepath"
        } else {
            stateTitle = "未读取"
            stateTint = .secondary
            stateIcon = "minus.circle"
        }

        return HStack(alignment: .center, spacing: 9) {
            Image(systemName: healthMetricIcon(item.metric))
                .font(.caption.weight(.semibold))
                .foregroundStyle(healthMetricTint(item.metric))
                .frame(width: 25, height: 25)
                .background(healthMetricTint(item.metric).opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(healthMetricLabel(item.metric))
                    .font(.caption.weight(.semibold))
                Text(item.latestAt.map {
                    "最近 \($0.formatted(date: .abbreviated, time: .shortened))"
                } ?? "尚无本地采样时间")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Label(stateTitle, systemImage: stateIcon)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(stateTint)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 42)
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            "\(stateTitle)，\(item.latestAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚无采样")"
        )
    }

    private func healthMetricIcon(_ metric: HealthMetric) -> String {
        switch metric {
        case .sleep: "moon.fill"
        case .hrvSdnn: "waveform.path.ecg"
        case .restingHeartRate: "heart.fill"
        case .stepCount: "figure.walk"
        case .activeEnergy, .basalEnergy: "flame.fill"
        case .bodyMass, .bodyFatPercentage, .leanBodyMass, .bmi: "figure.stand"
        case .vo2Max: "lungs.fill"
        case .workout: "figure.strengthtraining.traditional"
        }
    }

    private func healthMetricTint(_ metric: HealthMetric) -> Color {
        switch metric {
        case .sleep, .hrvSdnn: KrisTheme.recovery
        case .restingHeartRate: KrisTheme.danger
        case .stepCount, .workout: KrisTheme.positive
        case .activeEnergy, .basalEnergy: KrisTheme.caution
        case .bodyMass, .bodyFatPercentage, .leanBodyMass, .bmi: KrisTheme.body
        case .vo2Max: KrisTheme.systemAction
        }
    }

    private func healthMetricLabel(_ metric: HealthMetric) -> String {
        switch metric {
        case .sleep: "睡眠"
        case .hrvSdnn: "HRV"
        case .restingHeartRate: "静息心率"
        case .stepCount: "步数"
        case .activeEnergy: "活动能量"
        case .basalEnergy: "静息能量"
        case .bodyMass: "体重"
        case .bodyFatPercentage: "体脂"
        case .leanBodyMass: "去脂体重"
        case .bmi: "BMI"
        case .vo2Max: "VO₂ max"
        case .workout: "训练记录"
        }
    }

    private enum HealthValue {
        case sleepHours, hrv, restingHeartRate
    }

    private func value(_ kind: HealthValue) -> Double? {
        switch kind {
        case .sleepHours:
            return model.health.todayMetrics.sleepHours
                ?? model.effectiveEvidence.first(where: { $0.signal == "sleep" })?.value
        case .hrv:
            return model.health.todayMetrics.hrvMs
                ?? model.effectiveEvidence.first(where: { $0.signal == "hrv_sdnn" })?.value
        case .restingHeartRate:
            return model.health.todayMetrics.restingHeartRate
                ?? model.effectiveEvidence.first(where: { $0.signal == "resting_hr" })?.value
        }
    }

    private func metric(_ value: Double?, digits: Int, unit: String) -> String {
        guard let value else { return "—" }
        let number = value.formatted(.number.precision(.fractionLength(digits)))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    private var pressureSignalSummary: String {
        guard !model.effectiveEvidence.isEmpty else { return "数据不足" }
        let count = model.effectiveEvidence.filter {
            guard let impact = $0.impact else { return false }
            return impact != "中性/支持" && !impact.contains("支持按计划")
        }.count
        if count == 0 { return "未见明显偏离" }
        return "\(count) 项偏离"
    }

    private var healthFreshness: String {
        guard let date = model.health.lastImportAt else {
            return model.healthAttentionMessage == nil ? "自动更新" : "需要处理"
        }
        return date.formatted(date: .omitted, time: .shortened) + " 更新"
    }

    private var latestBodyMass: Double? {
        model.health.todayMetrics.bodyMassKg ?? model.effectiveTrends.weight?.last?.value
    }

    private var latestBodyFat: Double? {
        model.health.todayMetrics.bodyFatPercent ?? model.effectiveTrends.bodyFat?.last?.value
    }

    private var latestSteps: Double? {
        model.health.todayMetrics.steps ?? model.effectiveTrends.steps?.last?.value
    }

    private var latestActiveEnergy: Double? {
        model.health.todayMetrics.activeKcal ?? model.effectiveTrends.activeEnergy?.last?.value
    }

    private var latestTotalEnergy: Double? {
        model.health.todayMetrics.totalKcal ?? model.effectiveTrends.totalEnergy?.last?.value
    }

    private var latestVO2Max: Double? {
        model.health.todayMetrics.vo2Max ?? model.effectiveTrends.vo2Max?.last?.value
    }
}

enum HealthDomain: String, Identifiable {
    case recovery, sleep, activity, body, cardio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recovery: "恢复与压力"
        case .sleep: "睡眠"
        case .activity: "日常活动"
        case .body: "身体组成"
        case .cardio: "心肺能力"
        }
    }

    var icon: String {
        switch self {
        case .recovery: "waveform.path.ecg"
        case .sleep: "moon.fill"
        case .activity: "figure.walk"
        case .body: "figure.stand"
        case .cardio: "heart.fill"
        }
    }

    var tint: Color {
        switch self {
        case .recovery, .sleep: KrisTheme.recovery
        case .activity: KrisTheme.positive
        case .body: KrisTheme.body
        case .cardio: KrisTheme.danger
        }
    }

    var metrics: [HealthMetric] {
        switch self {
        case .recovery: [.sleep, .hrvSdnn, .restingHeartRate]
        case .sleep: [.sleep, .hrvSdnn]
        case .activity: [.stepCount, .activeEnergy, .basalEnergy]
        case .body: [.bodyMass, .bodyFatPercentage, .leanBodyMass, .bmi]
        case .cardio: [.vo2Max, .restingHeartRate]
        }
    }
}

struct HealthDomainDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let domain: HealthDomain

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                KrisPanel {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: domain.icon)
                            .foregroundStyle(domain.tint)
                            .frame(width: 36, height: 36)
                            .background(domain.tint.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(domain.title).font(.title3.weight(.bold))
                            Text("来自 Apple 健康")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider().padding(.vertical, 4)
                    HStack(spacing: 8) {
                        updateStamp(
                            title: "最近测量",
                            value: displayDate(latestMeasurementAt),
                            icon: "waveform.path.ecg"
                        )
                        updateStamp(
                            title: "App 更新",
                            value: displayDate(model.health.lastImportAt),
                            icon: "arrow.triangle.2.circlepath"
                        )
                    }
                }
                content
                KrisPanel {
                    KrisSectionHeading("怎么看")
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        dismiss()
                        model.selectedTab = 3
                    } label: {
                        Label("在趋势中查看变化", systemImage: "chart.xyaxis.line")
                    }
                    .buttonStyle(KrisOutlineButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(KrisTheme.canvas)
        .navigationTitle(domain.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("health-domain-detail-\(domain.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
        switch domain {
        case .recovery:
            KrisPanel {
                KrisSectionHeading("当前信号", trailing: confidenceLabel)
                ForEach(Array(model.effectiveEvidence.enumerated()), id: \.offset) { _, evidence in
                    metricRow(
                        ReadinessEvidencePresentation.label(evidence.signal),
                        value: ReadinessEvidencePresentation.valueLine(evidence),
                        detail: ReadinessEvidencePresentation.impactLine(evidence),
                        icon: ReadinessEvidencePresentation.icon(evidence.signal)
                    )
                }
                if let message = model.healthAttentionMessage {
                    Divider()
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(KrisTheme.caution)
                }
                Divider()
                NavigationLink {
                    DecisionTraceView()
                } label: {
                    HStack {
                        Text("查看判断依据")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("health-open-decision")
            }
        case .sleep:
            KrisPanel {
                KrisSectionHeading("今日睡眠")
                metricRow("睡眠时长", value: formatted(model.health.todayMetrics.sleepHours, unit: "h", digits: 1), icon: "moon.fill")
                Divider()
                metricRow("HRV", value: formatted(model.health.todayMetrics.hrvMs, unit: "ms", digits: 0), icon: "waveform.path.ecg")
            }
        case .activity:
            KrisPanel {
                KrisSectionHeading("今日活动", trailing: "实时累积")
                metricRow("步数", value: formatted(model.health.todayMetrics.steps, unit: "步", digits: 0), icon: "figure.walk")
                Divider()
                metricRow("活动能量", value: formatted(model.health.todayMetrics.activeKcal, unit: "kcal", digits: 0), icon: "flame.fill")
                Divider()
                metricRow("静息能量", value: formatted(model.health.todayMetrics.basalKcal, unit: "kcal", digits: 0), icon: "bed.double.fill")
                Divider()
                metricRow("今日总消耗", value: formatted(model.health.todayMetrics.totalKcal, unit: "kcal", digits: 0), detail: "持续更新", icon: "sum")
            }
        case .body:
            KrisPanel {
                KrisSectionHeading("最近体测")
                metricRow("体重", value: formatted(model.health.todayMetrics.bodyMassKg, unit: "kg", digits: 1), icon: "scalemass.fill")
                Divider()
                metricRow("体脂", value: formatted(model.health.todayMetrics.bodyFatPercent, unit: "%", digits: 1), icon: "percent")
                Divider()
                metricRow("去脂体重", value: formatted(model.health.todayMetrics.leanBodyMassKg, unit: "kg", digits: 1), icon: "figure.strengthtraining.traditional")
            }
        case .cardio:
            KrisPanel {
                KrisSectionHeading("心肺能力")
                metricRow("VO₂ max", value: formatted(model.health.todayMetrics.vo2Max, unit: "ml/kg/min", digits: 1), icon: "lungs.fill")
                Divider()
                metricRow("静息心率", value: formatted(model.health.todayMetrics.restingHeartRate, unit: "bpm", digits: 0), icon: "heart.fill")
            }
        }
    }

    private func updateStamp(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(domain.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(KrisTheme.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(title == "最近测量" ? "health-last-measurement" : "health-app-updated")
    }

    private func metricRow(_ title: String, value: String, detail: String? = nil, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(domain.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .minimumScaleFactor(0.75)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var confidenceLabel: String {
        switch model.effectiveReadiness?.confidence {
        case "high": "高置信度"
        case "medium": "中置信度"
        case "low": "低置信度"
        default: "待建立基线"
        }
    }

    private var latestMeasurementAt: Date? {
        model.health.metricFreshness
            .filter { domain.metrics.contains($0.metric) }
            .compactMap(\.latestAt)
            .max()
    }

    private func displayDate(_ date: Date?) -> String {
        guard let date else { return "暂无记录" }
        if Calendar.autoupdatingCurrent.isDateInToday(date) {
            return "今天 \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var explanation: String {
        switch domain {
        case .recovery: "结合睡眠、HRV、静息心率和近期活动，判断今天的身体恢复状态。"
        case .sleep: "重点看连续多天的睡眠时长和规律变化，偶尔一晚不代表长期状态。"
        case .activity: "步数和能量会在一天中持续增加，完整日数据更适合与过去比较。"
        case .body: "体重与体脂看连续趋势。一天的水分、进食和测量时间都会造成波动。"
        case .cardio: "VO₂ max 和静息心率更适合与个人长期水平比较，不用单次读数下结论。"
        }
    }

    private func formatted(_ value: Double?, unit: String, digits: Int) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(unit)"
    }
}

struct ReadinessEvidenceRow: View {
    let item: ReadinessEvidence

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: ReadinessEvidencePresentation.icon(item.signal))
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ReadinessEvidencePresentation.label(item.signal))
                    .font(.subheadline.weight(.semibold))
                Text(ReadinessEvidencePresentation.valueLine(item))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let impact = ReadinessEvidencePresentation.impactLine(item) {
                Text(impact)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        guard let impact = item.impact else { return .secondary }
        if impact.contains("限制") { return KrisTheme.caution }
        if impact.contains("支持") { return KrisTheme.positive }
        return .secondary
    }
}

struct DecisionTraceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                decisionSummary
                if hasComponents { readinessComponents }
                if !model.effectiveEvidence.isEmpty { evidence }
                if hasPrescriptionResponse { prescriptionResponse }
                if hasPlanBasis { planBasis }
                decisionTimeline
                Text("缺失数据不会被补成正常；异常症状仍以实际感受和医疗建议为准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(KrisTheme.canvas)
        .navigationTitle("决策依据")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var decisionSummary: some View {
        let readiness = model.effectiveReadiness
        return KrisPanel {
            KrisSectionHeading("今日结论", trailing: model.effectiveDecisionTrace?.asOf)
            HStack(spacing: 10) {
                Text("恢复判断")
                    .font(.headline.weight(.semibold))
                Spacer(minLength: 8)
                KrisStatusPill(
                    title: ReadinessPresentation.stateLabel(readiness?.state),
                    tint: decisionTint(readiness)
                )
            }
            Text(ReadinessPresentation.decisionLine(readiness))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(confidenceLabel(readiness?.confidence))置信度 · \(model.readinessSource)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var evidence: some View {
        KrisPanel {
            KrisSectionHeading("数据证据", trailing: "\(model.effectiveEvidence.count) 项")
            VStack(spacing: 0) {
                ForEach(Array(model.effectiveEvidence.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider() }
                    ReadinessEvidenceRow(item: item)
                }
            }
        }
    }

    private var hasComponents: Bool {
        model.effectiveReadiness?.components?.isEmpty == false
    }

    private var readinessComponents: some View {
        let components = model.effectiveReadiness?.components ?? [:]
        return KrisPanel {
            KrisSectionHeading("恢复信号", trailing: "同日综合")
            ForEach(ReadinessComponentPresentation.order, id: \.self) { key in
                let score = components[key] ?? nil
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        Image(systemName: ReadinessComponentPresentation.icon(key))
                            .foregroundStyle(componentTint(score))
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Text(ReadinessComponentPresentation.label(key))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(score == nil ? "未纳入" : "已纳入")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(ReadinessComponentPresentation.interpretation(score: score))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(ReadinessComponentPresentation.label(key))，\(score == nil ? "未参与今日判断" : "已参与今日判断")，\(ReadinessComponentPresentation.interpretation(score: score))"
                )
            }
            Text("缺失项不会被当作正常信号。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("readiness-components")
    }

    private func componentTint(_ score: Double?) -> Color {
        guard let score else { return .secondary }
        if score >= 60 { return KrisTheme.positive }
        if score >= 40 { return KrisTheme.body }
        return KrisTheme.caution
    }

    private var hasPrescriptionResponse: Bool {
        !(model.effectiveDecisionTrace?.actions ?? []).isEmpty || !model.planChanges.isEmpty
    }

    private var prescriptionResponse: some View {
        KrisPanel {
            KrisSectionHeading("处方响应")
            ForEach(Array((model.effectiveDecisionTrace?.actions ?? []).enumerated()), id: \.offset) { _, action in
                Label(action, systemImage: "arrow.turn.down.right")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.planChanges.isEmpty {
                Divider()
                Text("相对上一修订").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(model.planChanges.enumerated()), id: \.offset) { _, change in
                    Label(change, systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var hasPlanBasis: Bool {
        let trace = model.effectiveDecisionTrace
        return trace?.planBasis?.isEmpty == false || trace?.adjustmentNote?.isEmpty == false
    }

    private var planBasis: some View {
        KrisPanel {
            KrisSectionHeading("计划依据")
            if let basis = model.effectiveDecisionTrace?.planBasis, !basis.isEmpty {
                decisionText("为什么选这节课", basis, icon: "text.magnifyingglass")
            }
            if let note = model.effectiveDecisionTrace?.adjustmentNote, !note.isEmpty {
                Divider()
                decisionText("执行与回退条件", note, icon: "arrow.uturn.backward.circle")
            }
        }
    }

    private var decisionTimeline: some View {
        KrisPanel {
            KrisSectionHeading("本次决策时间线", trailing: "事实顺序")
            if let training = model.effectiveTrainingHistory.first {
                timelineRow(
                    number: 1, title: "最近确认训练",
                    detail: "\(training.title) · \(shortDate(training.date))"
                )
            } else {
                timelineRow(number: 1, title: "最近确认训练", detail: "暂无可确认记录")
            }
            timelineRow(number: 2, title: "恢复数据", detail: healthTimelineDetail)
            timelineRow(number: 3, title: "当前处方", detail: planTimelineDetail)
        }
        .accessibilityIdentifier("decision-timeline")
    }

    private func decisionText(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(KrisTheme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func timelineRow(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(KrisTheme.brandInk)
                .frame(width: 24, height: 24)
                .background(KrisTheme.brandLime, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var healthTimelineDetail: String {
        if let date = model.health.lastImportAt {
            return "Apple 健康 · \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        if let generated = model.snapshot?.generatedAt {
            return "计划快照 · \(shortDate(generated))"
        }
        return "等待健康数据"
    }

    private var planTimelineDetail: String {
        guard let plan = model.currentPlan else { return "暂无已发布计划" }
        return "\(plan.title) · R\(plan.revision) · \(shortDate(plan.publishedAt ?? plan.date))"
    }

    private func shortDate(_ raw: String) -> String {
        if let date = DateFormatting.parse(raw) {
            return date.formatted(
                .dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()
            )
        }
        let parts = raw.prefix(10).split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else {
            return String(raw.prefix(16))
        }
        return "\(month)月\(day)日"
    }

    private func decisionTint(_ readiness: SnapshotReadiness?) -> Color {
        guard let readiness else { return .secondary }
        if readiness.safetyGate == "stop_and_seek_care" { return KrisTheme.danger }
        if readiness.safetyGate == "reduce" || readiness.state == "train_reduce"
            || readiness.state == "recover_or_light" { return KrisTheme.caution }
        if readiness.state == "insufficient_data" || readiness.score == nil { return .secondary }
        return KrisTheme.positive
    }
}

struct TrainingView: View {
    @Environment(AppModel.self) private var model
    @State private var showAIComposer = false
    @State private var showManualEditor = false

    var body: some View {
        NavigationStack {
            Group {
                if let draft = model.activeDraft { ExecutionView(draft: draft) }
                else if let session = model.lastCompletedSession {
                    TrainingCompletionView(session: session)
                }
                else if let candidate = model.aiRecommendationCandidate,
                        candidate.status == .draft || candidate.status == .awaitingConfirmation {
                    AIRecommendationReviewView(candidate: candidate)
                }
                else if let candidate = model.planCandidate,
                        candidate.status == .draft || candidate.status == .awaitingConfirmation {
                    AIPlanReviewView(candidate: candidate)
                }
                else if let plan = model.currentPlan { PlanDetailView(plan: plan) }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            KrisPageHeader(
                                title: "训练",
                                subtitle: "记录实际重量、次数和末组感受"
                            )
                            ContentUnavailableView(
                                "暂无计划", systemImage: "dumbbell",
                                description: Text("你可以手动创建，或生成一份待审核的候选计划。")
                            )
                            .frame(maxWidth: .infinity, minHeight: 280)
                            Button {
                                showManualEditor = true
                            } label: {
                                Label("自己制定计划", systemImage: "square.and.pencil")
                            }
                            .buttonStyle(KrisPrimaryButtonStyle())
                            .accessibilityIdentifier("create-manual-plan")
                            AIPlanEntryButton(isPresented: $showAIComposer)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(KrisTheme.canvas)
            .sheet(isPresented: $showAIComposer) {
                AIPlanComposerView()
            }
            .sheet(isPresented: $showManualEditor) {
                TrainingPlanEditorView(plan: nil)
            }
        }
    }
}

struct PlanDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showWatchHelp = false
    @State private var showManualEditor = false
    @State private var showAIComposer = false
    let plan: TrainingPlan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                KrisPageHeader(
                    title: "训练",
                    subtitle: plan.title,
                    status: "约 \(plan.estimatedMinutes) 分钟"
                )
                watchTrainingEntry
                HStack(spacing: 8) {
                    Button { showManualEditor = true } label: {
                        Label("自己编辑", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KrisOutlineButtonStyle())
                    .accessibilityIdentifier("edit-training-plan")
                    Button { showAIComposer = true } label: {
                        Label("智能生成", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KrisOutlineButtonStyle())
                    .accessibilityIdentifier("generate-training-plan")
                }
                KrisPanel {
                    KrisSectionHeading("今日动作", trailing: "\(plan.exercises.count) 个")
                    VStack(spacing: 0) {
                        ForEach(Array(plan.exercises.enumerated()), id: \.element.id) { index, exercise in
                            if index > 0 { Divider() }
                            Group {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(alignment: .top, spacing: 10) {
                                            exerciseOrder(exercise)
                                            exerciseIdentity(exercise)
                                        }
                                        Text(target(exercise))
                                            .font(.subheadline.weight(.semibold).monospacedDigit())
                                            .padding(.leading, 30)
                                    }
                                } else {
                                    HStack(alignment: .center, spacing: 10) {
                                        exerciseOrder(exercise)
                                        exerciseIdentity(exercise)
                                        Spacer(minLength: 8)
                                        Text(target(exercise))
                                            .font(.subheadline.weight(.semibold).monospacedDigit())
                                            .multilineTextAlignment(.trailing)
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                        }
                    }
                }
                KrisPanel {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 9) {
                            if let goal = plan.goal, !goal.isEmpty {
                                Text(goal).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(plan.safetyGates, id: \.self) { gate in
                                Label(gate, systemImage: "shield.checkered")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            NavigationLink {
                                DecisionTraceView()
                            } label: {
                                Label("查看调整依据", systemImage: "list.bullet.clipboard")
                                    .frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("training-open-decision")
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("计划详情", systemImage: "ellipsis.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("training-plan-details")
                    }
                }
                if !model.effectiveTrainingHistory.isEmpty {
                    NavigationLink {
                        TrainingHistoryView(items: model.effectiveTrainingHistory)
                    } label: {
                        HStack(spacing: 10) {
                            Label("训练记录", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(KrisTheme.raised, in: RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("双击查看全部训练记录")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            // Keep the final rows above the floating action bar without
            // asking the parent TabView to add another safe-area region.
            .padding(.bottom, 82)
        }
        .background(KrisTheme.canvas)
        .overlay(alignment: .bottom) {
            Button { model.startTraining() } label: {
                Label("开始训练", systemImage: "play.fill")
            }
            .buttonStyle(KrisPrimaryButtonStyle())
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
            .background(.bar)
        }
        .alert("Apple Watch 训练", isPresented: $showWatchHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(watchHelpMessage)
        }
        .sheet(isPresented: $showManualEditor) {
            TrainingPlanEditorView(plan: plan)
        }
        .sheet(isPresented: $showAIComposer) {
            AIPlanComposerView()
        }
    }

    private func exerciseOrder(_ exercise: ExercisePlan) -> some View {
        Text("\(exercise.order)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 20)
    }

    private func exerciseIdentity(_ exercise: ExercisePlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(exercise.name).font(.subheadline.weight(.semibold))
            Text(exercise.equipmentVariant).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var watchTrainingEntry: some View {
        Button {
            model.sendCurrentPlanToWatch()
            showWatchHelp = true
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "applewatch")
                    .font(.title3)
                    .foregroundStyle(model.watch.isWatchAppInstalled ? KrisTheme.positive : KrisTheme.caution)
                    .frame(width: 32, height: 32)
                    .background(
                        (model.watch.isWatchAppInstalled ? KrisTheme.positive : KrisTheme.caution).opacity(0.10),
                        in: Circle()
                    )
                Text("Apple Watch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(watchEntryStatus)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(KrisTheme.raised, in: RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch-training-entry")
    }

    private var watchEntryStatus: String {
        model.watch.connectionStatus.shortLabel
    }

    private var watchHelpMessage: String {
        switch model.watch.connectionStatus {
        case .reachable, .installed:
            return "计划已同步。打开 Apple Watch 上的 Kris，点击“开始训练”即可采集心率、时长并记录组次。"
        case .needsInstallation:
            return "打开 iPhone 上的 Watch App，在“可用 App”中安装 Kris，然后回到这里开始训练。"
        case .checking:
            return "正在检查 Apple Watch 状态，请稍后再试。iPhone 端训练不受影响。"
        case .unavailable:
            return "暂时无法读取 Apple Watch 状态，请保持 iPhone 与手表蓝牙开启后重试。"
        case .noPairedWatch:
            return "当前没有检测到已配对的 Apple Watch。完成系统配对后，Kris 会自动同步训练计划。"
        case .unsupported:
            return "当前设备不支持 Apple Watch 训练联动，仍可直接在 iPhone 完成训练。"
        }
    }
}

private struct SetInput: Hashable {
    var weight: Double
    var reps: Int
}

struct ExecutionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let draft: TrainingDraft
    @State private var inputs: [String: SetInput] = [:]
    @State private var completed: Set<String> = []
    @State private var feelings: [UUID: LastSetFeeling] = [:]
    @State private var showFinish = false
    @State private var showWatchHelp = false
    @State private var editingExercise: ExercisePlan?
    @State private var hydratedSessionID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                KrisPageHeader(
                    title: draft.lifecycleState == .paused ? "训练已暂停" : "训练中",
                    subtitle: draft.plan.title
                )
                KrisPanel {
                    HStack {
                        KrisStatusPill(
                            title: lifecycleTitle,
                            tint: lifecycleTint,
                            systemImage: lifecycleSymbol
                        )
                        if draft.workoutManagedByWatch == true {
                            KrisStatusPill(
                                title: model.workoutMirror.isConnected ? "双端实时" : "手表执行",
                                tint: model.workoutMirror.isConnected ? KrisTheme.positive : .secondary,
                                systemImage: model.workoutMirror.isConnected
                                    ? "applewatch.radiowaves.left.and.right"
                                    : "applewatch"
                            )
                        }
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(alignment: .trailing, spacing: 1) {
                                Label(activeDurationText(at: context.date), systemImage: "timer")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                Text("总计 \(elapsedDurationText(at: context.date))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Text(draft.plan.title).font(.headline.weight(.semibold))
                        Spacer()
                        Text(completionText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: completionFraction)
                        .tint(KrisTheme.brandLime)
                        .accessibilityLabel("训练完成进度")
                        .accessibilityValue(completionText)
                    if let nextSet {
                        Label(
                            "下一组：\(nextSet.exercise.name) · 第 \(nextSet.number)/\(nextSet.exercise.sets) 组 · \(setTarget(nextSet.exercise, number: nextSet.number))",
                            systemImage: "arrow.down.right.circle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KrisTheme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("计划组次已全部记录，可以结束训练", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KrisTheme.positive)
                    }
                    if draft.lifecycleState == .paused {
                        Label("暂停时间不计入有效训练时长", systemImage: "pause.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KrisTheme.caution)
                    }
                    if model.watch.isWatchAppInstalled,
                       draft.workoutManagedByWatch != true {
                        Divider()
                        Button {
                            model.sendCurrentPlanToWatch()
                            showWatchHelp = true
                        } label: {
                            HStack {
                                Label("在 Apple Watch 继续", systemImage: "applewatch")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("continue-on-watch")
                    }
                }
                .accessibilityIdentifier("training-session-progress")
                HStack(spacing: 10) {
                    Button {
                        if draft.lifecycleState == .paused {
                            model.resumeTraining()
                        } else {
                            model.pauseTraining()
                        }
                    } label: {
                        Label(
                            draft.lifecycleState == .paused ? "继续" : "暂停",
                            systemImage: draft.lifecycleState == .paused ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KrisTheme.brandLime)
                    .foregroundStyle(KrisTheme.brandInk)
                    .disabled(draft.lifecycleState != .running && draft.lifecycleState != .paused)
                    .accessibilityIdentifier("training-pause-resume")

                    Button(role: .destructive) {
                        model.requestStopTraining()
                        if model.canFinalizeTraining { showFinish = true }
                    } label: {
                        Label("结束", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(draft.lifecycleState != .running && draft.lifecycleState != .paused)
                    .accessibilityLabel("结束训练")
                    .accessibilityIdentifier("training-stop")
                }
                if let restUntil = draft.restUntil, restUntil > Date() {
                    RestTimer(
                        until: restUntil,
                        addThirty: { model.setRestUntil(restUntil.addingTimeInterval(30)) },
                        skip: { model.setRestUntil(nil) }
                    )
                }
                ForEach(draft.executionExercises) { exercise in
                    exerciseBlock(exercise)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(KrisTheme.canvas)
        .sheet(isPresented: $showFinish) { FinishTrainingView() }
        .alert("Apple Watch 训练", isPresented: $showWatchHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("计划和当前训练已同步。打开 Apple Watch 上的 Kris，点击“开始训练”即可接管心率、时长和组次记录。")
        }
        .sheet(item: $editingExercise) { exercise in
            if let planned = draft.plan.exercises.first(where: { $0.exerciseId == exercise.exerciseId }) {
                ExerciseAdjustmentView(
                    planned: planned,
                    execution: exercise,
                    adjustment: draft.override(for: exercise.exerciseId),
                    minimumSets: max(
                        1,
                        draft.completedSets[exercise.exerciseId]?.map(\.setNumber).max() ?? 1
                    ),
                    save: applyAdjustment,
                    restore: { restorePlannedExercise(planned) }
                )
            }
        }
        .onAppear {
            hydrateIfNeeded()
            if model.canFinalizeTraining { showFinish = true }
        }
        .onChange(of: draft.lifecycleState) { _, state in
            if state == .stopped || state == .completed || state == .failed {
                showFinish = true
            }
        }
    }

    @ViewBuilder
    private func exerciseBlock(_ exercise: ExercisePlan) -> some View {
        KrisPanel {
            HStack(alignment: .top, spacing: 11) {
                Text("\(exercise.order)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(exercise.name).font(.headline)
                    Text(exercise.equipmentVariant).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    if nextSet?.exercise.id == exercise.id {
                        KrisStatusPill(title: "当前动作", tint: KrisTheme.accent, systemImage: "scope")
                    } else {
                        Text("休 \(exercise.restSeconds) 秒")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button("调整") { editingExercise = exercise }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("调整 \(exercise.name) 的动作或器械")
                        .accessibilityIdentifier("adjust-exercise-\(exercise.exerciseId.uuidString)")
                }
            }
            if draft.override(for: exercise.exerciseId) != nil {
                Label("已调整", systemImage: "arrow.triangle.branch")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(KrisTheme.accent)
            }
            ForEach(1...exercise.sets, id: \.self) { setNumber in
                setRow(exercise, setNumber: setNumber)
            }
            HStack {
                Text("末组感受")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("末组感受", selection: feelingBinding(for: exercise)) {
                    ForEach(LastSetFeeling.allCases, id: \.self) { feeling in
                        Text(feeling.label).tag(feeling)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private func setRow(_ exercise: ExercisePlan, setNumber: Int) -> some View {
        let key = key(exercise, setNumber)
        let isNext = nextSet?.exercise.id == exercise.id && nextSet?.number == setNumber
        let binding = Binding(
            get: { inputs[key] ?? SetInput(weight: exercise.targetWeightKg ?? 0, reps: exercise.targetReps) },
            set: { value in
                inputs[key] = value
                if completed.contains(key) {
                    model.recordSet(
                        exercise: exercise, setNumber: setNumber,
                        weight: exercise.targetWeightKg == nil ? nil : value.weight,
                        reps: value.reps,
                        feeling: setNumber == exercise.sets ? feelings[exercise.id] : nil
                    )
                }
            }
        )
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        completionButton(exercise, setNumber: setNumber, binding: binding)
                        Text("第 \(setNumber) 组")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Spacer()
                        if completed.contains(key) {
                            Text("已记录")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(KrisTheme.positive)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if exercise.targetWeightKg != nil {
                            Stepper(value: binding.weight, in: 0...500, step: 2.5) {
                                Text(
                                    "重量 \(binding.wrappedValue.weight.formatted(.number.precision(.fractionLength(0...1)))) kg"
                                )
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            .accessibilityLabel("第 \(setNumber) 组重量")
                            .accessibilityValue("\(binding.wrappedValue.weight.formatted()) 公斤")
                        }
                        Stepper(value: binding.reps, in: 0...100) {
                            Text("次数 \(binding.wrappedValue.reps)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    completionButton(exercise, setNumber: setNumber, binding: binding)
                    Text("\(setNumber)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    if exercise.targetWeightKg != nil {
                        weightEditor(binding, setNumber: setNumber)
                    }
                    repsEditor(binding, setNumber: setNumber)
                }
            }
        }
        .padding(.vertical, 3)
        .frame(minHeight: 48)
        .background(
            completed.contains(key)
                ? KrisTheme.positive.opacity(0.07)
                : (isNext ? KrisTheme.brandLime.opacity(0.12) : Color.clear),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isNext ? KrisTheme.brandLime.opacity(0.9) : .clear, lineWidth: 1.25)
        }
        .contextMenu {
            if setNumber == exercise.sets {
                ForEach(LastSetFeeling.allCases, id: \.self) { feeling in
                    Button(feeling.label) { feelings[exercise.id] = feeling }
                }
            }
        }
    }

    private func completionButton(
        _ exercise: ExercisePlan, setNumber: Int, binding: Binding<SetInput>
    ) -> some View {
        let rowKey = key(exercise, setNumber)
        return Button {
            if completed.contains(rowKey) {
                completed.remove(rowKey)
                model.removeSet(exercise: exercise, setNumber: setNumber)
                model.setRestUntil(nil)
            } else {
                completed.insert(rowKey)
                model.recordSet(
                    exercise: exercise, setNumber: setNumber,
                    weight: exercise.targetWeightKg == nil ? nil : binding.wrappedValue.weight,
                    reps: binding.wrappedValue.reps,
                    feeling: setNumber == exercise.sets ? feelings[exercise.id] : nil
                )
                if setNumber < exercise.sets {
                    let nextKey = key(exercise, setNumber + 1)
                    if !completed.contains(nextKey) {
                        inputs[nextKey] = binding.wrappedValue
                    }
                }
                model.setRestUntil(
                    hasIncompleteSet
                        ? Date().addingTimeInterval(TimeInterval(exercise.restSeconds))
                        : nil
                )
            }
        } label: {
            Image(systemName: completed.contains(rowKey) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(completed.contains(rowKey) ? KrisTheme.positive : .secondary)
        .frame(width: 36, height: 44)
        .accessibilityLabel("\(exercise.name)，第 \(setNumber) 组完成")
        .accessibilityValue(completed.contains(rowKey) ? "已记录" : "未记录")
        .accessibilityHint(completed.contains(rowKey) ? "双击可撤销本组" : "双击保存本组实际重量和次数")
        .accessibilityIdentifier("training-set-\(exercise.exerciseId.uuidString)-\(setNumber)")
    }

    private func weightEditor(_ binding: Binding<SetInput>, setNumber: Int) -> some View {
        HStack(spacing: 1) {
            Button {
                binding.weight.wrappedValue = max(0, binding.weight.wrappedValue - 2.5)
            } label: {
                Image(systemName: "minus").frame(width: 26, height: 40)
            }
            .accessibilityLabel("第 \(setNumber) 组重量减少 2.5 公斤")
            TextField(
                "kg", value: binding.weight,
                format: .number.precision(.fractionLength(0...1))
            )
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .frame(width: 52, height: 36)
            .background(KrisTheme.muted, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("第 \(setNumber) 组重量，公斤")
            Button {
                binding.weight.wrappedValue += 2.5
            } label: {
                Image(systemName: "plus").frame(width: 26, height: 40)
            }
            .accessibilityLabel("第 \(setNumber) 组重量增加 2.5 公斤")
            Text("kg")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }

    private func repsEditor(_ binding: Binding<SetInput>, setNumber: Int) -> some View {
        Stepper(value: binding.reps, in: 0...100) {
            Text("\(binding.wrappedValue.reps) 次")
                .font(.subheadline.monospacedDigit())
        }
        .controlSize(.small)
        .accessibilityLabel("第 \(setNumber) 组次数")
        .accessibilityValue("\(binding.wrappedValue.reps) 次")
    }

    private func feelingBinding(for exercise: ExercisePlan) -> Binding<LastSetFeeling> {
        Binding(
            get: { feelings[exercise.id] ?? .appropriate },
            set: { feeling in
                feelings[exercise.id] = feeling
                if completed.contains(key(exercise, exercise.sets)) {
                    model.updateLastSetFeeling(exercise: exercise, feeling: feeling)
                }
            }
        )
    }

    private func hydrateIfNeeded() {
        guard hydratedSessionID != draft.sessionId else { return }
        inputs.removeAll(keepingCapacity: true)
        completed.removeAll(keepingCapacity: true)
        feelings.removeAll(keepingCapacity: true)
        hydratedSessionID = draft.sessionId
        for exercise in draft.executionExercises {
            for number in 1...exercise.sets {
                let key = key(exercise, number)
                inputs[key] = SetInput(weight: exercise.targetWeightKg ?? 0, reps: exercise.targetReps)
            }
            for item in draft.completedSets[exercise.exerciseId] ?? [] {
                let key = key(exercise, item.setNumber)
                inputs[key] = SetInput(weight: item.weightKg ?? 0, reps: item.reps)
                completed.insert(key)
                if let feeling = item.lastSetFeeling { feelings[exercise.id] = feeling }
            }
        }
    }

    private func key(_ exercise: ExercisePlan, _ set: Int) -> String { "\(exercise.id.uuidString)-\(set)" }

    private var completionText: String {
        let total = draft.executionExercises.reduce(0) { $0 + $1.sets }
        return "\(completed.count)/\(total) 组"
    }

    private var completionFraction: Double {
        let total = draft.executionExercises.reduce(0) { $0 + $1.sets }
        guard total > 0 else { return 0 }
        return Double(completed.count) / Double(total)
    }

    private var nextSet: (exercise: ExercisePlan, number: Int)? {
        for exercise in draft.executionExercises {
            for number in 1...exercise.sets where !completed.contains(key(exercise, number)) {
                return (exercise, number)
            }
        }
        return nil
    }

    private var hasIncompleteSet: Bool { nextSet != nil }

    private func setTarget(_ exercise: ExercisePlan, number: Int) -> String {
        let input = inputs[key(exercise, number)]
            ?? SetInput(weight: exercise.targetWeightKg ?? 0, reps: exercise.targetReps)
        let weight = exercise.targetWeightKg == nil
            ? "自重"
            : "\(input.weight.formatted(.number.precision(.fractionLength(0...1)))) kg"
        return "\(weight) × \(input.reps) 次"
    }

    private func activeDurationText(at date: Date) -> String {
        durationText(draft.activeDuration(at: date))
    }

    private func elapsedDurationText(at date: Date) -> String {
        durationText(draft.elapsedDuration(at: date))
    }

    private func durationText(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private var lifecycleTitle: String {
        switch draft.lifecycleState {
        case .preparing: "准备中"
        case .running: "进行中"
        case .paused: "已暂停"
        case .stopped: "已停止"
        case .finalizing: "正在保存"
        case .completed: "待反馈"
        case .failed: "采集异常"
        }
    }

    private var lifecycleTint: Color {
        switch draft.lifecycleState {
        case .running: KrisTheme.positive
        case .paused, .preparing, .finalizing: KrisTheme.caution
        case .completed: KrisTheme.positive
        case .stopped, .failed: KrisTheme.danger
        }
    }

    private var lifecycleSymbol: String {
        switch draft.lifecycleState {
        case .preparing: "hourglass"
        case .running: "record.circle"
        case .paused: "pause.circle"
        case .stopped: "stop.circle"
        case .finalizing: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func applyAdjustment(_ adjustment: ExerciseExecutionOverride) {
        model.updateExerciseExecution(
            plannedExerciseId: adjustment.plannedExerciseId,
            name: adjustment.name,
            equipmentVariant: adjustment.equipmentVariant,
            targetWeightKg: adjustment.targetWeightKg,
            sets: adjustment.sets,
            targetReps: adjustment.targetReps,
            restSeconds: adjustment.restSeconds,
            kind: adjustment.kind
        )
        for number in 1...adjustment.sets {
            let itemKey = "\(adjustment.plannedExerciseId.uuidString)-\(number)"
            guard !completed.contains(itemKey) else { continue }
            inputs[itemKey] = SetInput(
                weight: adjustment.targetWeightKg ?? 0,
                reps: adjustment.targetReps
            )
        }
    }

    private func restorePlannedExercise(_ planned: ExercisePlan) {
        model.resetExerciseExecution(plannedExerciseId: planned.exerciseId)
        for number in 1...planned.sets {
            let itemKey = key(planned, number)
            guard !completed.contains(itemKey) else { continue }
            inputs[itemKey] = SetInput(
                weight: planned.targetWeightKg ?? 0,
                reps: planned.targetReps
            )
        }
    }
}

private struct ExerciseAdjustmentView: View {
    @Environment(\.dismiss) private var dismiss
    let planned: ExercisePlan
    let execution: ExercisePlan
    let adjustment: ExerciseExecutionOverride?
    let minimumSets: Int
    let save: (ExerciseExecutionOverride) -> Void
    let restore: () -> Void

    @State private var name: String
    @State private var equipmentVariant: String
    @State private var recordsWeight: Bool
    @State private var targetWeightKg: Double
    @State private var sets: Int
    @State private var targetReps: Int
    @State private var restSeconds: Int

    init(
        planned: ExercisePlan,
        execution: ExercisePlan,
        adjustment: ExerciseExecutionOverride?,
        minimumSets: Int,
        save: @escaping (ExerciseExecutionOverride) -> Void,
        restore: @escaping () -> Void
    ) {
        self.planned = planned
        self.execution = execution
        self.adjustment = adjustment
        self.minimumSets = minimumSets
        self.save = save
        self.restore = restore
        _name = State(initialValue: execution.name)
        _equipmentVariant = State(initialValue: execution.equipmentVariant)
        _recordsWeight = State(initialValue: execution.targetWeightKg != nil)
        _targetWeightKg = State(initialValue: execution.targetWeightKg ?? 0)
        _sets = State(initialValue: execution.sets)
        _targetReps = State(initialValue: execution.targetReps)
        _restSeconds = State(initialValue: execution.restSeconds)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("原动作", value: planned.name)
                    LabeledContent("原器械", value: planned.equipmentVariant)
                    if let alternative = planned.alternative, !alternative.isEmpty {
                        Button {
                            name = alternative
                            equipmentVariant = alternative
                        } label: {
                            Label("换成 \(alternative)", systemImage: "arrow.triangle.branch")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier("use-planned-alternative")
                    }
                } header: {
                    Text("原计划动作")
                }

                Section("本次实际动作") {
                    TextField("动作名称", text: $name)
                        .accessibilityIdentifier("actual-exercise-name")
                    TextField("器械或变体", text: $equipmentVariant)
                        .accessibilityIdentifier("actual-equipment-variant")
                }

                Section("本次目标") {
                    Toggle("记录负重", isOn: $recordsWeight)
                    if recordsWeight {
                        Stepper(value: $targetWeightKg, in: 0...1_000, step: 2.5) {
                            LabeledContent(
                                "目标重量",
                                value: "\(targetWeightKg.formatted(.number.precision(.fractionLength(0...1)))) kg"
                            )
                        }
                    }
                    Stepper(value: $sets, in: minimumSets...20) {
                        LabeledContent("目标组数", value: "\(sets) 组")
                    }
                    Stepper(value: $targetReps, in: 0...500) {
                        LabeledContent("每组次数", value: "\(targetReps) 次")
                    }
                    Stepper(value: $restSeconds, in: 0...600, step: 15) {
                        LabeledContent("组间休息", value: "\(restSeconds) 秒")
                    }
                }

                if adjustment != nil {
                    Section {
                        Button("恢复计划动作", role: .destructive) {
                            restore()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("调整本次动作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save(ExerciseExecutionOverride(
                            plannedExerciseId: planned.exerciseId,
                            name: name,
                            equipmentVariant: equipmentVariant,
                            targetWeightKg: recordsWeight ? targetWeightKg : nil,
                            sets: sets,
                            targetReps: targetReps,
                            restSeconds: restSeconds,
                            kind: adjustmentKind
                        ))
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || trimmedEquipment.isEmpty)
                    .accessibilityIdentifier("save-exercise-adjustment")
                }
            }
        }
        .presentationDetents([.large])
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEquipment: String {
        equipmentVariant.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var adjustmentKind: ExerciseAdjustmentKind {
        if trimmedName == planned.alternative { return .plannedAlternative }
        if trimmedName == planned.name { return .equipmentChange }
        return .custom
    }
}

struct RestTimer: View {
    let until: Date
    let addThirty: () -> Void
    let skip: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
            VStack(spacing: 10) {
                HStack {
                    Label(seconds == 0 ? "休息结束" : "组间休息", systemImage: "timer")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .font(.title3.monospacedDigit().bold())
                }
                HStack(spacing: 8) {
                    Button("+30 秒", action: addThirty)
                        .buttonStyle(.bordered)
                    Button(seconds == 0 ? "继续下一组" : "跳过休息", action: skip)
                        .buttonStyle(.borderedProminent)
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
            .padding(14)
            .background(KrisTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct FinishTrainingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var energy: SessionEnergy = .notRecorded
    @State private var response: MuscleResponse = .notRecorded
    @State private var symptoms = ""
    @State private var notes = ""
    @State private var stoppedEarly = false
    @State private var symptomState: SymptomState = .notRecorded
    @State private var showDiscardConfirmation = false

    private enum SymptomState: String, CaseIterable {
        case notRecorded = "未填写"
        case none = "无不适"
        case present = "有不适"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KrisPageHeader(
                        title: "训练反馈",
                        subtitle: "几秒钟记录真实状态，用于下一次负荷判断"
                    )
                    .padding(.trailing, 42)
                    KrisPanel {
                        KrisSectionHeading("完成情况")
                        Picker("完成情况", selection: $stoppedEarly) {
                            Text("按计划结束").tag(false)
                            Text("提前停止").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    KrisPanel {
                        KrisSectionHeading("训练后精力", trailing: energy == .notRecorded ? "未填写" : nil)
                        LazyVGrid(columns: feedbackColumns, spacing: 8) {
                            ForEach(
                                [SessionEnergy.good, .normal, .slightlyTired, .exhausted],
                                id: \.self
                            ) { option in
                                feedbackChoice(
                                    energyLabel(option),
                                    selected: energy == option,
                                    action: { energy = option }
                                )
                            }
                        }
                    }
                    KrisPanel {
                        KrisSectionHeading("目标肌群反应", trailing: response == .notRecorded ? "未填写" : nil)
                        LazyVGrid(columns: feedbackColumns, spacing: 8) {
                            feedbackChoice(
                                "反应可以", selected: response == .good,
                                action: { response = .good }
                            )
                            feedbackChoice(
                                "反应偏弱", selected: response == .weak,
                                action: { response = .weak }
                            )
                        }
                    }
                    KrisPanel {
                        KrisSectionHeading("身体反应", trailing: symptomState.rawValue)
                        Picker("身体反应", selection: $symptomState) {
                            ForEach(SymptomState.allCases, id: \.self) { state in
                                Text(state.rawValue).tag(state)
                            }
                        }
                        .pickerStyle(.segmented)
                        if symptomState == .present {
                            TextField("腰骶、肩肘腕或其他不适", text: $symptoms, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                        } else if symptomState == .notRecorded {
                            Text("未填写不会被解释为无症状。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    KrisPanel {
                        KrisSectionHeading("补充反馈", trailing: "可选")
                        TextField("例如时间受限、器械差异或动作感受", text: $notes, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(KrisTheme.canvas)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if model.isTrainingDiscardPending {
                        Label("正在结束训练并放弃记录", systemImage: "applewatch.radiowaves.left.and.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("training-discard-pending")
                    }
                    if let error = model.trainingCompletionError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KrisTheme.caution)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("training-archive-error")
                    }
                    if !model.canFinalizeTraining {
                        Label("正在等待 Apple Watch 完成训练存档", systemImage: "applewatch.radiowaves.left.and.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Button("保存本次训练") { save() }
                        .buttonStyle(KrisPrimaryButtonStyle())
                        .disabled(!model.canFinalizeTraining || model.isTrainingDiscardPending)
                    Button(model.isTrainingDiscardPending ? "正在放弃记录…" : "放弃本次记录", role: .destructive) {
                        showDiscardConfirmation = true
                    }
                    .disabled(model.isTrainingDiscardPending)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityHint("结束训练且不加入训练历史")
                    .accessibilityIdentifier("discard-training-record")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(KrisTheme.raised)
            }
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog(
                "放弃本次训练记录？",
                isPresented: $showDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("放弃记录", role: .destructive) {
                    if model.discardTraining() { dismiss() }
                }
                Button("继续填写", role: .cancel) {}
            } message: {
                Text("本次组次和反馈不会加入训练历史。")
            }
            .onChange(of: model.activeDraft?.sessionId) { _, sessionID in
                if sessionID == nil { dismiss() }
            }
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭训练反馈")
                .padding(.top, 10)
                .padding(.trailing, 16)
            }
        }
    }

    private var feedbackColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible()), count: count)
    }

    private func feedbackChoice(
        _ title: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? KrisTheme.brandInk : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                selected ? KrisTheme.brandLime : KrisTheme.muted,
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }

    private func energyLabel(_ value: SessionEnergy) -> String {
        switch value {
        case .good: "良好"
        case .normal: "正常"
        case .slightlyTired: "稍微疲惫"
        case .exhausted: "明显疲惫"
        case .notRecorded: "未填写"
        }
    }

    private func save() {
        let symptomText = switch symptomState {
        case .notRecorded: ""
        case .none: "无不适"
        case .present: symptoms.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let saved = model.finishTraining(
            feedback: SessionFeedback(
                energy: energy, targetMuscleResponse: response,
                symptoms: symptomText, notes: notes
            ),
            stoppedEarly: stoppedEarly
        )
        if saved { dismiss() }
    }
}

struct TrainingCompletionView: View {
    @Environment(AppModel.self) private var model
    let session: TrainingSessionContract

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                KrisPageHeader(
                    title: "训练完成",
                    subtitle: "训练记录已更新，可立即复盘"
                )
                KrisPanel(fill: KrisTheme.brandLime.opacity(0.13)) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundStyle(KrisTheme.accent)
                            .frame(width: 46, height: 46)
                            .background(KrisTheme.brandLime, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("训练已保存")
                                .font(.title3.weight(.bold))
                            Text(syncDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                TrainingSessionOverview(
                    session: session,
                    plannedSetCount: model.planForSession(session).map {
                        $0.exercises.reduce(0) { $0 + $1.sets }
                    }
                )
                TrainingSessionBreakdown(session: session)
                TrainingSessionFeedbackPanel(feedback: session.feedback)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(KrisTheme.canvas)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.dismissTrainingReceipt()
            } label: {
                Label("返回训练", systemImage: "arrow.right")
            }
            .buttonStyle(KrisPrimaryButtonStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(KrisTheme.raised)
        }
        .accessibilityIdentifier("training-completion-receipt")
    }

    private var syncDetail: String {
        "已加入训练历史，可随时查看。"
    }
}

private struct TrainingSessionOverview: View {
    let session: TrainingSessionContract
    let plannedSetCount: Int?

    var body: some View {
        let performance = TrainingIntelligence.sessionPerformance(
            session, plannedSetCount: plannedSetCount
        )
        KrisPanel {
            KrisSectionHeading("本次概览", trailing: statusLabel)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { metrics }
                VStack(spacing: 10) { metrics }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { performanceMetrics(performance) }
                VStack(spacing: 10) { performanceMetrics(performance) }
            }
            Text("负重容量只汇总有明确重量的组；仅用于同动作、同器械复盘。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var metrics: some View {
        metric("用时", value: durationText, icon: "timer")
        Divider().frame(height: 40).padding(.horizontal, 10)
        metric("完成组", value: setText, icon: "checkmark.circle")
        Divider().frame(height: 40).padding(.horizontal, 10)
        metric("活动能量", value: kcalText, icon: "flame")
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func performanceMetrics(_ summary: TrainingSessionPerformance) -> some View {
        compactMetric("总次数", value: "\(summary.totalRepetitions) 次")
        Divider().frame(height: 34).padding(.horizontal, 10)
        compactMetric(
            "负重容量",
            value: summary.loadedVolumeKg.map {
                "\($0.formatted(.number.precision(.fractionLength(0)))) kg"
            } ?? "未记录"
        )
        Divider().frame(height: 34).padding(.horizontal, 10)
        compactMetric(
            "末组反馈",
            value: "\(summary.feedbackExercises)/\(summary.completedExercises) 动作"
        )
    }

    private func compactMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var durationText: String {
        let duration: Double?
        if let workout = session.workout { duration = workout.durationSeconds }
        else if let start = DateFormatting.parse(session.startedAt),
                let end = DateFormatting.parse(session.endedAt) {
            duration = max(0, end.timeIntervalSince(start))
        } else { duration = nil }
        guard let duration else { return "—" }
        return "\(Int((duration / 60).rounded())) 分"
    }

    private var setText: String {
        let completed = session.exerciseResults.flatMap(\.sets).count
        return plannedSetCount.map { "\(completed)/\($0) 组" } ?? "\(completed) 组"
    }

    private var kcalText: String {
        session.workout?.activeKcal.map {
            "\($0.formatted(.number.precision(.fractionLength(0)))) kcal"
        } ?? "未采集"
    }

    private var statusLabel: String {
        switch session.status {
        case .completed: "按计划结束"
        case .stoppedEarly: "提前停止"
        case .cancelled: "已取消"
        }
    }
}

private struct TrainingSessionBreakdown: View {
    let session: TrainingSessionContract

    var body: some View {
        KrisPanel {
            KrisSectionHeading(
                "动作实绩",
                trailing: "\(session.exerciseResults.flatMap(\.sets).count) 组"
            )
            if session.exerciseResults.isEmpty {
                KrisStatusRow(
                    title: "没有已完成组次",
                    detail: "本次结束状态仍已保留，不会把计划组次当作实际完成。",
                    tint: KrisTheme.caution,
                    systemImage: "exclamationmark.circle"
                )
            } else {
                ForEach(Array(session.exerciseResults.enumerated()), id: \.element.id) { index, result in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name).font(.subheadline.weight(.semibold))
                                Text(result.equipmentVariant)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(result.sets.count) 组")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let planned = result.planned,
                           planned.name != result.name
                            || planned.equipmentVariant != result.equipmentVariant {
                            Label(
                                "原计划：\(planned.name) · \(planned.equipmentVariant)",
                                systemImage: "arrow.triangle.branch"
                            )
                            .font(.caption)
                            .foregroundStyle(KrisTheme.accent)
                        }
                        ForEach(result.sets.sorted(by: { $0.setNumber < $1.setNumber })) { set in
                            HStack(spacing: 8) {
                                Text("\(set.setNumber)")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(setLine(set))
                                    .font(.subheadline.monospacedDigit())
                                Spacer()
                                if let feeling = set.lastSetFeeling {
                                    KrisStatusPill(title: feeling.label, tint: feelingTint(feeling))
                                }
                            }
                            .frame(minHeight: 36)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "第 \(set.setNumber) 组，\(setLine(set))\(set.lastSetFeeling.map { "，末组感受 \($0.label)" } ?? "")"
                            )
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private func setLine(_ set: CompletedSet) -> String {
        let load = set.weightKg.map {
            "\($0.formatted(.number.precision(.fractionLength(0...1)))) kg"
        } ?? "自重"
        return "\(load) × \(set.reps) 次"
    }

    private func feelingTint(_ feeling: LastSetFeeling) -> Color {
        switch feeling {
        case .easy, .appropriate: KrisTheme.positive
        case .veryHard: KrisTheme.caution
        case .formBreakdown: KrisTheme.danger
        }
    }
}

private struct TrainingSessionFeedbackPanel: View {
    let feedback: SessionFeedback

    var body: some View {
        KrisPanel {
            KrisSectionHeading("训练反馈")
            feedbackRow("训练后精力", value: energyLabel, icon: "bolt.fill")
            Divider()
            feedbackRow("目标肌群", value: responseLabel, icon: "scope")
            Divider()
            feedbackRow("身体反应", value: symptomLabel, icon: "figure.mind.and.body")
            if !feedback.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                feedbackRow("补充", value: feedback.notes, icon: "text.bubble")
            }
        }
    }

    private func feedbackRow(_ title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(KrisTheme.body)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var energyLabel: String {
        switch feedback.energy {
        case .good: "良好"
        case .normal: "正常"
        case .slightlyTired: "稍微疲惫"
        case .exhausted: "明显疲惫"
        case .notRecorded: "未填写"
        }
    }

    private var responseLabel: String {
        switch feedback.targetMuscleResponse {
        case .good: "反应可以"
        case .weak: "反应偏弱"
        case .notRecorded: "未填写"
        }
    }

    private var symptomLabel: String {
        let value = feedback.symptoms.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未填写" : value
    }
}

struct TrendsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedMetric: TrendMetric = .sleep
    @State private var selectedCategory: TrendCategory = .recovery
    @State private var selectedDays = 28
    @State private var selectedTrendDate: String?
    @State private var selectedLoadDate: String?
    @State private var selectedHistoryItem: SnapshotTrainingSummary?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KrisPageHeader(
                        title: "趋势",
                        subtitle: "查看个人数据的长期变化",
                        status: "个人趋势"
                    )
                    .accessibilityIdentifier("trend-page-header")
                    Picker("时间范围", selection: $selectedDays) {
                        Text("7 天").tag(7)
                        Text("28 天").tag(28)
                        Text("42 天").tag(42)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedDays) { _, _ in
                        selectedTrendDate = nil
                        selectedLoadDate = nil
                    }

                    overview
                    Picker("指标分类", selection: $selectedCategory) {
                        ForEach(TrendCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedCategory) { _, category in
                        if !category.metrics.contains(selectedMetric) {
                            selectedMetric = category.metrics[0]
                        }
                        selectedTrendDate = nil
                    }
                    metricPicker
                    detailChart
                    weeklyTraining
                    trainingLoad
                    recentTraining
                    trainingProgression

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("体脂秤单日波动不用于调整热量；决策至少看 7–14 天可比记录。")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(KrisTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: historyDetailIsPresented) {
                if let selectedHistoryItem {
                    TrainingHistoryDetailView(item: selectedHistoryItem)
                }
            }
        }
    }

    private var historyDetailIsPresented: Binding<Bool> {
        Binding(
            get: { selectedHistoryItem != nil },
            set: { isPresented in
                if !isPresented { selectedHistoryItem = nil }
            }
        )
    }

    private enum TrendCategory: String, CaseIterable, Identifiable {
        case recovery, body, activity

        var id: String { rawValue }
        var title: String {
            switch self {
            case .recovery: "恢复"
            case .body: "体成分"
            case .activity: "活动"
            }
        }
        var metrics: [TrendMetric] {
            switch self {
            case .recovery: [.sleep, .hrv, .restingHeartRate]
            case .body: [.weight, .bodyFat]
            case .activity: [.steps, .activeEnergy, .basalEnergy, .totalEnergy, .vo2Max]
            }
        }
    }

    private enum TrendMetric: String, CaseIterable, Identifiable {
        case readiness, weight, bodyFat, sleep, hrv, restingHeartRate, steps
        case activeEnergy, basalEnergy, totalEnergy, vo2Max
        var id: String { rawValue }
        var title: String {
            switch self {
            case .readiness: "准备度"
            case .weight: "体重"
            case .bodyFat: "体脂"
            case .sleep: "睡眠"
            case .hrv: "HRV"
            case .restingHeartRate: "静息心率"
            case .steps: "步数"
            case .activeEnergy: "活动能量"
            case .basalEnergy: "静息能量"
            case .totalEnergy: "总消耗"
            case .vo2Max: "VO₂ max"
            }
        }
        var unit: String {
            switch self {
            case .readiness: "分"
            case .weight: "kg"
            case .bodyFat: "%"
            case .sleep: "h"
            case .hrv: "ms"
            case .restingHeartRate: "bpm"
            case .steps: "步"
            case .activeEnergy, .basalEnergy, .totalEnergy: "kcal"
            case .vo2Max: "ml/kg/min"
            }
        }
        var color: Color {
            switch self {
            case .readiness: KrisTheme.readiness
            case .weight: KrisTheme.body
            case .bodyFat: KrisTheme.caution
            case .sleep, .hrv: KrisTheme.recovery
            case .restingHeartRate: KrisTheme.danger
            case .steps: KrisTheme.positive
            case .activeEnergy: KrisTheme.caution
            case .basalEnergy: KrisTheme.recovery
            case .totalEnergy: KrisTheme.body
            case .vo2Max: KrisTheme.positive
            }
        }
        var stableThreshold: Double {
            switch self {
            case .readiness: 2
            case .weight: 0.05
            case .bodyFat, .sleep: 0.1
            case .hrv: 2
            case .restingHeartRate: 1
            case .steps: 300
            case .activeEnergy, .basalEnergy, .totalEnergy: 50
            case .vo2Max: 0.5
            }
        }
    }

    private var overview: some View {
        KrisPanel {
            KrisSectionHeading("周期概览", trailing: "\(selectedDays) 天")
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { overviewMetrics }
            } else {
                HStack(spacing: 0) { overviewMetrics }
            }
        }
        .accessibilityIdentifier("trend-overview")
    }

    @ViewBuilder private var overviewMetrics: some View {
        summaryCell(
            title: "HRV", value: latestValue(periodData(.hrv), unit: "ms"),
            detail: changeText(periodData(.hrv), unit: "ms")
        )
        Divider().frame(height: dynamicTypeSize.isAccessibilitySize ? 1 : 54).padding(.horizontal, 10)
        summaryCell(
            title: "体重", value: latestValue(periodData(.weight), unit: "kg"),
            detail: changeText(periodData(.weight), unit: "kg")
        )
        Divider().frame(height: dynamicTypeSize.isAccessibilitySize ? 1 : 54).padding(.horizontal, 10)
        summaryCell(
            title: "平均睡眠", value: averageValue(periodData(.sleep), unit: "h"),
            detail: "\(periodData(.sleep).count) 天有记录"
        )
    }

    private func summaryCell(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedCategory.metrics) { metric in
                    Button {
                        selectedMetric = metric
                        selectedTrendDate = nil
                    } label: {
                        Text(metric.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selectedMetric == metric ? .white : .primary)
                            .padding(.horizontal, 13)
                            .frame(height: 34)
                            .background(
                                selectedMetric == metric ? metric.color : KrisTheme.raised,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .contentMargins(.horizontal, 1, for: .scrollContent)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityIdentifier("trend-metric-picker")
    }

    private var detailChart: some View {
        let data = periodData(selectedMetric)
        let baseline = personalBaseline(for: selectedMetric)
        let domainData = baseline.map {
            data + [SnapshotTrends.Point(date: "baseline", value: $0)]
        } ?? data
        let yDomain = selectedMetric == .readiness
            ? readinessChartYDomain(data) : chartYDomain(domainData)
        let selectedPoint = data.first { $0.date == selectedTrendDate }
        return KrisPanel {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedMetric.title).font(.headline.weight(.semibold))
                    Text(trendNarrative(data, metric: selectedMetric))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(selectedPoint.map { formattedPoint($0, unit: selectedMetric.unit) }
                        ?? latestValue(data, unit: selectedMetric.unit))
                        .font(.headline.monospacedDigit())
                    if let selectedPoint {
                        Text(shortDateLabel(selectedPoint.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if data.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title3)
                        .foregroundStyle(selectedMetric.color)
                        .frame(width: 42, height: 42)
                        .background(selectedMetric.color.opacity(0.10), in: Circle())
                    Text("等待趋势数据").font(.subheadline.weight(.semibold))
                    Text("在设置中授权 Apple 健康即可开始累积").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 176)
            } else {
                Chart {
                    if let baseline {
                        RuleMark(y: .value("个人基线", baseline))
                            .foregroundStyle(KrisTheme.axisText.opacity(0.68))
                            .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("个人基线")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                    }
                    ForEach(data) { point in
                        AreaMark(
                            x: .value("日期", point.date),
                            yStart: .value("下界", yDomain.lowerBound),
                            yEnd: .value(selectedMetric.title, point.value)
                        )
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [selectedMetric.color.opacity(0.14), selectedMetric.color.opacity(0.005)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        LineMark(
                            x: .value("日期", point.date),
                            y: .value(selectedMetric.title, point.value)
                        )
                            .foregroundStyle(selectedMetric.color)
                            .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                        if data.count <= 7 || point.date == data.last?.date {
                            PointMark(
                                x: .value("日期", point.date),
                                y: .value(selectedMetric.title, point.value)
                            )
                            .foregroundStyle(selectedMetric.color)
                            .symbolSize(point.date == data.last?.date ? 28 : 14)
                        }
                    }
                    if let selectedPoint {
                        RuleMark(x: .value("选中日期", selectedPoint.date))
                            .foregroundStyle(selectedMetric.color.opacity(0.55))
                            .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                        PointMark(
                            x: .value("选中日期", selectedPoint.date),
                            y: .value(selectedMetric.title, selectedPoint.value)
                        )
                        .foregroundStyle(selectedMetric.color)
                        .symbolSize(58)
                    }
                }
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(KrisTheme.axisGrid.opacity(0.5))
                        AxisValueLabel().foregroundStyle(KrisTheme.axisText)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: chartXAxisValues(data)) { value in
                        if let date = value.as(String.self) {
                            AxisValueLabel(collisionResolution: .greedy) {
                                Text(shortDateLabel(date)).font(.caption2).lineLimit(1)
                            }
                            .foregroundStyle(KrisTheme.axisText)
                        }
                    }
                }
                .chartXScale(range: .plotDimension(padding: 20))
                .frame(height: 210)
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(KrisTheme.muted.opacity(0.22))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .chartXSelection(value: $selectedTrendDate)
                .chartGesture { proxy in
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            selectedTrendDate = proxy.value(atX: value.location.x, as: String.self)
                        }
                }
                .accessibilityChartDescriptor(
                    TrendChartDescriptor(
                        title: selectedMetric.title,
                        unit: selectedMetric.unit,
                        summary: trendNarrative(data, metric: selectedMetric),
                        domain: yDomain,
                        data: data
                    )
                )
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityIdentifier("trend-detail-chart")
                .accessibilityLabel("\(selectedMetric.title)趋势图")
                .accessibilityValue(
                    selectedPoint.map {
                        "\(shortDateLabel($0.date))，\(formattedPoint($0, unit: selectedMetric.unit))"
                    } ?? "当前值 \(latestValue(data, unit: selectedMetric.unit))"
                )

                HStack(spacing: 0) {
                    chartStat("周期均值", averageValue(data, unit: selectedMetric.unit))
                    Divider().frame(height: 34).padding(.horizontal, 14)
                    chartStat("净变化", changeText(data, unit: selectedMetric.unit))
                    Divider().frame(height: 34).padding(.horizontal, 14)
                    chartStat("有效样本", "\(data.count) 天")
                }
                if let baseline {
                    Label(
                        "个人基线 \(baseline.formatted(.number.precision(.fractionLength(0...1)))) \(selectedMetric.unit)",
                        systemImage: "line.diagonal"
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                if selectedMetric == .readiness {
                    Text("同一版规则下的个人恢复趋势；分数变化需结合睡眠、HRV、静息心率和训练负荷解释。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if selectedMetric == .basalEnergy || selectedMetric == .totalEnergy {
                    Text("只显示静息能量覆盖至少 20 小时的完整日；不按单日手表数值直接调整饮食。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var trainingProgression: some View {
        KrisPanel {
            KrisSectionHeading("力量进阶", trailing: "同动作·同器械")
            if !model.effectiveProgression.isEmpty {
                ForEach(Array(model.effectiveProgression.prefix(3))) { decision in
                            KrisStatusRow(
                        title: "\(decision.exercise) · \(decision.equipmentVariant)",
                        detail: decision.nextAction,
                        tint: decision.state == "increase_smallest_step" ? KrisTheme.positive : KrisTheme.body,
                        systemImage: decision.state == "increase_smallest_step" ? "arrow.up.right" : "scope"
                    )
                }
                Text("根据同动作、同器械、实际重量×次数与末组反馈判断。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.hasEffectiveProgression {
                KrisStatusRow(
                    title: "已获取最新进阶判定",
                    detail: "加重仍需连续两次完成次数上限，且末组反馈为轻松或合适。",
                    tint: KrisTheme.positive,
                    systemImage: "arrow.up.right"
                )
            } else {
                KrisStatusRow(
                    title: "暂无可开放加重的动作",
                    detail: "继续记录实际重量×次数和末组感受。",
                    tint: .secondary,
                    systemImage: "dumbbell"
                )
            }
        }
    }

    private var trainingLoad: some View {
        let short = Array((model.effectiveTrends.trainingLoad7D ?? []).suffix(selectedDays))
        let long = Array((model.effectiveTrends.trainingLoad42D ?? []).suffix(selectedDays))
        let combined = short + long
        let domain = chartYDomain(combined)
        return KrisPanel {
            KrisSectionHeading("训练负荷", trailing: "7 / 42 日")
            if combined.isEmpty {
                KrisStatusRow(
                    title: "训练负荷待建立",
                    detail: "授权 Apple 健康训练记录，或在 App 内完成训练后自动累积。",
                    tint: .secondary,
                    systemImage: "chart.xyaxis.line"
                )
            } else {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) { loadSummaryMetrics(short: short, long: long) }
                } else {
                    HStack(spacing: 0) { loadSummaryMetrics(short: short, long: long) }
                }

                Chart {
                    ForEach(short) { point in
                        AreaMark(
                            x: .value("日期", point.date),
                            yStart: .value("下界", domain.lowerBound),
                            yEnd: .value("短期 7 日", point.value)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [KrisTheme.body.opacity(0.16), KrisTheme.body.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("日期", point.date),
                            y: .value("短期 7 日", point.value),
                            series: .value("趋势", "短期 7 日")
                        )
                        .foregroundStyle(KrisTheme.body)
                        .lineStyle(.init(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    }
                    ForEach(long) { point in
                        LineMark(
                            x: .value("日期", point.date),
                            y: .value("长期 42 日", point.value),
                            series: .value("趋势", "长期 42 日")
                        )
                        .foregroundStyle(KrisTheme.recovery)
                        .lineStyle(.init(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [5, 4]))
                        .interpolationMethod(.monotone)
                    }
                    if let selectedLoadDate,
                       let selected = (short + long).first(where: { $0.date == selectedLoadDate }) {
                        RuleMark(x: .value("选中日期", selectedLoadDate))
                            .foregroundStyle(KrisTheme.axisText.opacity(0.55))
                            .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                        PointMark(
                            x: .value("选中日期", selected.date),
                            y: .value("负荷", selected.value)
                        )
                        .foregroundStyle(KrisTheme.body)
                        .symbolSize(48)
                    }
                }
                .chartYScale(domain: domain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(KrisTheme.axisGrid.opacity(0.5))
                        AxisValueLabel().foregroundStyle(KrisTheme.axisText)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: chartXAxisValues(short.isEmpty ? long : short)) { value in
                        if let date = value.as(String.self) {
                            AxisValueLabel(collisionResolution: .greedy) {
                                Text(shortDateLabel(date)).font(.caption2).lineLimit(1)
                            }
                                .foregroundStyle(KrisTheme.axisText)
                        }
                    }
                }
                .chartXScale(range: .plotDimension(padding: 20))
                .frame(height: 150)
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(KrisTheme.muted.opacity(0.22))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .chartXSelection(value: $selectedLoadDate)
                .chartGesture { proxy in
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            selectedLoadDate = proxy.value(atX: value.location.x, as: String.self)
                        }
                }
                .accessibilityLabel("7 日与 42 日训练负荷趋势图")
                .accessibilityValue(selectedLoadAccessibilityValue(short: short, long: long))

                HStack(spacing: 8) {
                    Circle().fill(loadStatusTint).frame(width: 7, height: 7)
                    Text(loadStatusTitle).font(.caption.weight(.medium))
                    Spacer(minLength: 8)
                    Text("时长×类型系数").font(.caption2).foregroundStyle(.secondary)
                }
                Text("仅用于比较个人近期训练刺激，不等同于疲劳、伤病风险或加量许可。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("training-load-panel")
    }

    @ViewBuilder private func loadSummaryMetrics(
        short: [SnapshotTrends.Point], long: [SnapshotTrends.Point]
    ) -> some View {
        loadSummaryCell("短期 7 日", value: selectedLoadPoint(short)?.value, tint: KrisTheme.body)
        Divider().frame(height: dynamicTypeSize.isAccessibilitySize ? 1 : 42).padding(.horizontal, 14)
        loadSummaryCell("长期 42 日", value: selectedLoadPoint(long)?.value, tint: KrisTheme.recovery)
        Divider().frame(height: dynamicTypeSize.isAccessibilitySize ? 1 : 42).padding(.horizontal, 14)
        loadSummaryCell(
            "相对基线", value: loadRatio.map { $0 * 100 },
            suffix: "%", tint: loadStatusTint
        )
    }

    private var recentTraining: some View {
        let history = model.effectiveTrainingHistory
        return KrisPanel {
            KrisSectionHeading("最近训练", trailing: history.isEmpty ? nil : "\(history.count) 次")
            if history.isEmpty {
                KrisStatusRow(
                    title: "还没有可确认的训练记录",
                    detail: "计划不等于完成；结束训练并保存后才会出现在这里。",
                    tint: .secondary,
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                ForEach(Array(history.prefix(3).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    Button {
                        selectedHistoryItem = item
                    } label: {
                        TrainingHistoryRow(item: item, showsDisclosure: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("training-history-item-\(item.id)")
                    .accessibilityHint("双击查看训练详情")
                }
                if history.count > 3 {
                    Divider()
                    NavigationLink {
                        TrainingHistoryView(items: history)
                    } label: {
                        HStack {
                            Text("查看全部训练").font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(KrisTheme.forest)
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("training-history-panel")
    }

    private var weeklyTraining: some View {
        let summary = model.weeklyTrainingSummary
        return KrisPanel {
            KrisSectionHeading("近 7 天执行", trailing: summary.hasTraining ? "已确认训练" : "等待实绩")
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { weeklySummaryMetrics(summary) }
            } else {
                HStack(spacing: 0) { weeklySummaryMetrics(summary) }
            }
            if summary.stoppedEarlySessions > 0 {
                Label(
                    "其中 \(summary.stoppedEarlySessions) 次提前停止；这里只记录事实，不把它解释为恢复不足。",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if !summary.hasTraining {
                Text("设备运动记录与 App 已保存训练会合并去重；计划本身不计入执行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weekly-training-summary")
    }

    @ViewBuilder private func weeklySummaryMetrics(_ summary: WeeklyTrainingSummary) -> some View {
        trainingSummaryCell("训练", value: "\(summary.completedSessions) 次")
        Divider().frame(height: dynamicTypeSize.isAccessibilitySize ? 1 : 40).padding(.horizontal, 10)
        trainingSummaryCell("用时", value: "\(Int(summary.trainingMinutes.rounded())) 分")
        Divider().frame(height: dynamicTypeSize.isAccessibilitySize ? 1 : 40).padding(.horizontal, 10)
        trainingSummaryCell("完成组", value: "\(summary.completedSets) 组")
    }

    private func trainingSummaryCell(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func loadSummaryCell(
        _ title: String, value: Double?, suffix: String = "点", tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(value.map {
                "\($0.formatted(.number.precision(.fractionLength(0...1)))) \(suffix)"
            } ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadRatio: Double? {
        model.effectiveLoadRatio
    }

    private func selectedLoadPoint(_ data: [SnapshotTrends.Point]) -> SnapshotTrends.Point? {
        guard let selectedLoadDate else { return data.last }
        return data.first(where: { $0.date == selectedLoadDate }) ?? data.last
    }

    private func selectedLoadAccessibilityValue(
        short: [SnapshotTrends.Point], long: [SnapshotTrends.Point]
    ) -> String {
        let shortPoint = selectedLoadPoint(short)
        let longPoint = selectedLoadPoint(long)
        let date = shortPoint?.date ?? longPoint?.date
        let prefix = date.map { "\(shortDateLabel($0))，" } ?? ""
        let shortValue = shortPoint?.value.formatted(.number.precision(.fractionLength(0...1))) ?? "暂无"
        let longValue = longPoint?.value.formatted(.number.precision(.fractionLength(0...1))) ?? "暂无"
        return "\(prefix)短期 \(shortValue) 点，长期 \(longValue) 点"
    }

    private var loadStatus: String? {
        model.effectiveLoadStatus
    }

    private var loadStatusTitle: String {
        switch loadStatus {
        case "elevated_recent_load": "近期负荷明显高于基线"
        case "above_28d_baseline": "近期负荷高于基线"
        case "within_28d_baseline": "近期负荷接近个人基线"
        case "below_28d_baseline": "近期负荷低于个人基线"
        case "baseline_building": "负荷基线建立中"
        default: "训练负荷仅作个人趋势参考"
        }
    }

    private var loadStatusTint: Color {
        switch loadStatus {
        case "elevated_recent_load": KrisTheme.caution
        case "above_28d_baseline": KrisTheme.body
        case "within_28d_baseline": KrisTheme.positive
        default: .secondary
        }
    }

    private func chartStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func periodData(_ metric: TrendMetric) -> [SnapshotTrends.Point] {
        let trends = model.effectiveTrends
        let source: [SnapshotTrends.Point]
        switch metric {
        case .readiness:
            source = (trends.readiness ?? []).map {
                SnapshotTrends.Point(date: $0.date, value: $0.score)
            }
        case .weight: source = trends.weight ?? []
        case .bodyFat: source = trends.bodyFat ?? []
        case .sleep: source = trends.sleep ?? []
        case .hrv: source = trends.hrv ?? []
        case .restingHeartRate: source = trends.restingHeartRate ?? []
        case .steps: source = trends.steps ?? []
        case .activeEnergy: source = trends.activeEnergy ?? []
        case .basalEnergy: source = trends.basalEnergy ?? []
        case .totalEnergy: source = trends.totalEnergy ?? []
        case .vo2Max: source = trends.vo2Max ?? []
        }
        return Array(source.suffix(selectedDays))
    }

    private var readinessStateDetail: String {
        guard let latest = model.effectiveTrends.readiness?.last else { return "等待恢复数据" }
        return "\(ReadinessPresentation.stateLabel(latest.state)) · \(confidenceLabel(latest.confidence))置信度"
    }

    private func latestValue(_ data: [SnapshotTrends.Point], unit: String) -> String {
        guard let latest = data.last else { return "—" }
        return formattedPoint(latest, unit: unit)
    }

    private func formattedPoint(_ point: SnapshotTrends.Point, unit: String) -> String {
        "\(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
    }

    private func averageValue(_ data: [SnapshotTrends.Point], unit: String) -> String {
        guard !data.isEmpty else { return "—" }
        let value = data.map(\.value).reduce(0, +) / Double(data.count)
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
    }

    private func changeText(_ data: [SnapshotTrends.Point], unit: String) -> String {
        guard let first = data.first, let last = data.last, data.count > 1 else { return "样本不足" }
        let change = last.value - first.value
        let prefix = change > 0 ? "+" : ""
        return "\(prefix)\(change.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
    }

    private func trendNarrative(_ data: [SnapshotTrends.Point], metric: TrendMetric) -> String {
        guard let first = data.first, let last = data.last, data.count >= 3 else {
            return "至少需要 3 个有效日才解读变化"
        }
        let change = last.value - first.value
        if abs(change) < metric.stableThreshold { return "周期内基本持平" }
        let direction = change > 0 ? "上升" : "下降"
        return "较期初\(direction) \(abs(change).formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)"
    }

    private func personalBaseline(for metric: TrendMetric) -> Double? {
        let signal: String?
        switch metric {
        case .sleep: signal = "sleep"
        case .hrv: signal = "hrv_sdnn"
        case .restingHeartRate: signal = "resting_hr"
        default: signal = nil
        }
        guard let signal else { return nil }
        return model.effectiveEvidence.first(where: { $0.signal == signal })?.baseline
    }

    private func readinessChartYDomain(_ data: [SnapshotTrends.Point]) -> ClosedRange<Double> {
        guard !data.isEmpty else { return 0...100 }
        let padded = chartYDomain(data)
        let lower = max(0, floor((padded.lowerBound - 2) / 5) * 5)
        let upper = min(100, ceil((padded.upperBound + 2) / 5) * 5)
        return lower < upper ? lower...upper : max(0, lower - 5)...min(100, upper + 5)
    }

    private func chartYDomain(_ data: [SnapshotTrends.Point]) -> ClosedRange<Double> {
        guard let minimum = data.map(\.value).min(), let maximum = data.map(\.value).max() else {
            return 0...1
        }
        let spread = maximum - minimum
        let padding = max(spread * 0.18, abs((minimum + maximum) / 2) * 0.005, 0.25)
        return (minimum - padding)...(maximum + padding)
    }

    private func chartXAxisValues(_ data: [SnapshotTrends.Point]) -> [String] {
        guard !data.isEmpty else { return [] }
        let candidates = [data.first?.date, data.last?.date].compactMap { $0 }
        return candidates.reduce(into: []) { values, date in
            if !values.contains(date) { values.append(date) }
        }
    }

    private func shortDateLabel(_ date: String) -> String {
        let normalized = date.replacingOccurrences(of: "-", with: "/")
        let parts = normalized.split(separator: "/")
        return parts.suffix(2).compactMap { Int($0) }.map(String.init).joined(separator: ".")
    }
}

struct TrainingHistoryView: View {
    @Environment(AppModel.self) private var model
    let items: [SnapshotTrainingSummary]
    @State private var pendingDeletion: SnapshotTrainingSummary?
    @State private var hiddenItemIDs: Set<String> = []

    var body: some View {
        List(items.filter { !hiddenItemIDs.contains($0.id) }) { item in
            NavigationLink {
                TrainingHistoryDetailView(item: item)
            } label: {
                TrainingHistoryRow(item: item)
            }
                .accessibilityIdentifier("training-history-item-\(item.id)")
                .listRowBackground(KrisTheme.surface)
                .listRowSeparatorTint(KrisTheme.border)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("删除", role: .destructive) {
                        pendingDeletion = item
                    }
                }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(KrisTheme.canvas)
        .navigationTitle("训练历史")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "删除这条训练记录？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除记录", role: .destructive) {
                guard let item = pendingDeletion else { return }
                if model.deleteLocalSession(id: item.id) { hiddenItemIDs.insert(item.id) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("这条记录会从 Kris 中移除；Apple 健康中的运动数据不会改变。")
        }
    }
}

struct TrainingHistoryRow: View {
    let item: SnapshotTrainingSummary
    var showsDisclosure = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: TrainingActivityPresentation.icon(for: item.title))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TrainingActivityPresentation.tint(for: item.title))
                .frame(width: 34, height: 34)
                .background(
                    TrainingActivityPresentation.tint(for: item.title).opacity(0.10),
                    in: Circle()
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(displayDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    KrisStatusPill(
                        title: syncLabel,
                        tint: KrisTheme.positive,
                        systemImage: "checkmark.circle"
                    )
                    if showsDisclosure {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }

                if !metrics.isEmpty {
                    Text(metrics.joined(separator: " · "))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title)，\(displayDate)，\(metrics.joined(separator: "，"))，\(syncLabel)")
    }

    private var metrics: [String] {
        var values: [String] = []
        if let duration = item.durationMinutes {
            values.append("\(duration.formatted(.number.precision(.fractionLength(0...1)))) 分钟")
        }
        if let distance = item.workoutDetails?.distanceKilometers {
            values.append("\(distance.formatted(.number.precision(.fractionLength(2)))) km")
        }
        if let sets = item.completedSetCount { values.append("\(sets) 组") }
        if let kcal = item.activeKcal {
            values.append("\(kcal.formatted(.number.precision(.fractionLength(0)))) kcal")
        }
        if let heartRate = item.averageHeartRate {
            values.append("均心 \(heartRate.formatted(.number.precision(.fractionLength(0))))")
        }
        return values
    }

    private var syncLabel: String {
        if item.source == "iphone_healthkit" { return "健康记录" }
        return item.source == "kris_coach_app" ? "Kris 记录" : "历史记录"
    }

    private var displayDate: String {
        if let date = DateFormatting.parse(item.date) {
            return date.formatted(
                .dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()
            )
        }
        let parts = item.date.prefix(10).split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else {
            return String(item.date.prefix(10))
        }
        return "\(month)月\(day)日"
    }
}

struct TrainingHistoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    let item: SnapshotTrainingSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                historyHeader
                if let session = model.localSession(id: item.id) {
                    TrainingSessionOverview(
                        session: session,
                        plannedSetCount: model.planForSession(session).map {
                            $0.exercises.reduce(0) { $0 + $1.sets }
                        }
                    )
                    TrainingSessionBreakdown(session: session)
                    TrainingSessionFeedbackPanel(feedback: session.feedback)
                } else {
                    historyMetrics
                    if item.workoutDetails != nil { workoutSourcePanel }
                    KrisPanel {
                        KrisStatusRow(
                            title: "仅有训练摘要",
                            detail: remoteDetail,
                            tint: .secondary,
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(KrisTheme.canvas)
        .navigationTitle("训练详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除训练记录")
            }
        }
        .confirmationDialog(
            "删除这条训练记录？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除记录", role: .destructive) {
                if model.deleteLocalSession(id: item.id) { dismiss() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法在 Kris 中恢复；Apple 健康中的运动数据不会改变。")
        }
        .accessibilityIdentifier("training-history-detail")
    }

    private var historyHeader: some View {
        KrisPanel {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(.title3.weight(.bold))
                Spacer()
                KrisStatusPill(
                    title: statusLabel,
                    tint: KrisTheme.positive,
                    systemImage: "checkmark.circle"
                )
            }
            Text(displayDate)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(sourceLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var historyMetrics: some View {
        KrisPanel {
            KrisSectionHeading("训练概览")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                historyMetric(
                    "用时",
                    item.durationMinutes.map {
                        "\($0.formatted(.number.precision(.fractionLength(0...1)))) 分"
                    } ?? "—",
                    icon: "timer"
                )
                historyMetric(
                    "距离",
                    item.workoutDetails?.distanceKilometers.map {
                        "\($0.formatted(.number.precision(.fractionLength(2)))) km"
                    } ?? "未记录",
                    icon: "point.topleft.down.to.point.bottomright.curvepath"
                )
                historyMetric(
                    "活动能量",
                    item.activeKcal.map {
                        "\($0.formatted(.number.precision(.fractionLength(0)))) kcal"
                    } ?? "未记录",
                    icon: "flame.fill"
                )
                historyMetric(
                    "平均心率",
                    item.averageHeartRate.map {
                        "\($0.formatted(.number.precision(.fractionLength(0)))) bpm"
                    } ?? "未记录",
                    icon: "heart.fill"
                )
                historyMetric(
                    "最高心率",
                    item.maximumHeartRate.map {
                        "\($0.formatted(.number.precision(.fractionLength(0)))) bpm"
                    } ?? "未记录",
                    icon: "waveform.path.ecg"
                )
            }
        }
    }

    private func historyMetric(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(KrisTheme.muted.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var workoutSourcePanel: some View {
        KrisPanel {
            KrisSectionHeading("记录信息")
            if let details = item.workoutDetails {
                LabeledContent("运动类型", value: item.title)
                LabeledContent("来源", value: details.sourceName)
                    .accessibilityIdentifier("workout-source")
                if let device = details.deviceName {
                    LabeledContent("设备", value: device)
                }
                if let indoor = details.indoor {
                    LabeledContent("环境", value: indoor ? "室内" : "户外")
                        .accessibilityIdentifier("workout-environment")
                }
                LabeledContent("开始", value: formattedDateTime(details.startAt))
                LabeledContent("结束", value: formattedDateTime(details.endAt))
            }
        }
        .font(.subheadline)
    }

    private func formattedDateTime(_ raw: String) -> String {
        guard let date = DateFormatting.parse(raw) else { return String(raw.prefix(16)) }
        return date.formatted(
            .dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()
        )
    }

    private var remoteDetail: String {
        if item.source == "iphone_healthkit" {
            return "这条记录由 Apple 健康读取。运动类型、时长、距离、心率和能量按系统实际覆盖显示；重量、次数与末组反馈只在 Kris 内训练时记录。"
        }
        return "这条记录来自已导入的长期历史，目前只包含训练摘要。"
    }

    private var statusLabel: String {
        switch item.status {
        case "stopped_early": return "提前停止"
        case "cancelled": return "已取消"
        default: return "已完成"
        }
    }

    private var sourceLabel: String {
        switch item.source {
        case "kris_coach_app": return "Kris 实绩记录"
        case "iphone_healthkit": return "Apple 健康训练摘要"
        default: return "长期档案摘要"
        }
    }

    private var displayDate: String {
        if let date = DateFormatting.parse(item.date) {
            return date.formatted(
                .dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute()
            )
        }
        return String(item.date.prefix(16))
    }
}

private enum TrainingActivityPresentation {
    static func icon(for title: String) -> String {
        if title.contains("跑") { return "figure.run" }
        if title.contains("走") || title.contains("徒步") { return "figure.walk" }
        if title.contains("游泳") { return "figure.pool.swim" }
        if title.contains("骑行") { return "figure.outdoor.cycle" }
        if title.contains("椭圆") { return "figure.elliptical" }
        if title.contains("划船") { return "figure.rower" }
        if title.contains("楼梯") { return "figure.stair.stepper" }
        if title.contains("瑜伽") || title.contains("柔韧") || title.contains("恢复") {
            return "figure.mind.and.body"
        }
        if title.contains("力量") || title.contains("上肢") || title.contains("下肢") {
            return "figure.strengthtraining.traditional"
        }
        return "figure.mixed.cardio"
    }

    static func tint(for title: String) -> Color {
        if title.contains("跑") || title.contains("间歇") { return KrisTheme.danger }
        if title.contains("游泳") { return KrisTheme.systemAction }
        if title.contains("骑行") || title.contains("椭圆") || title.contains("划船") {
            return KrisTheme.body
        }
        if title.contains("力量") || title.contains("上肢") || title.contains("下肢") {
            return KrisTheme.recovery
        }
        return KrisTheme.positive
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KrisPageHeader(
                        title: "设置",
                        subtitle: "管理设备、权限与隐私"
                    )
                    .accessibilityIdentifier("settings-page-header")
                    KrisPanel {
                        KrisSectionHeading("设备与服务", trailing: overallDataState)
                        KrisStatusRow(
                            title: "Apple 健康 · \(healthState)",
                            detail: healthSourceDetail,
                            tint: healthStatusTint,
                            systemImage: "heart.text.square.fill"
                        )
                        Divider()
                        KrisStatusRow(
                            title: "Apple Watch · \(watchState)",
                            detail: watchDetail,
                            tint: watchStatusTint,
                            systemImage: "applewatch"
                        )
                        Divider()
                        KrisStatusRow(
                            title: "计划更新",
                            detail: "新计划准备好后会自动出现在今日页。",
                            tint: KrisTheme.positive,
                            systemImage: "calendar.badge.checkmark"
                        )
                        if model.queueCount > 0 {
                            Divider()
                            KrisStatusRow(
                                title: "离线队列 · \(model.queueCount) 项待处理",
                                detail: "数据已安全保留在 iPhone，后台处理恢复后自动继续",
                                tint: model.queueSummary.latestError == nil ? KrisTheme.caution : KrisTheme.danger,
                                systemImage: "tray.full.fill"
                            )
                        }
                    }
                    .accessibilityIdentifier("settings-device-overview")

                    NavigationLink {
                        AISettingsView()
                    } label: {
                        KrisPanel {
                            KrisSectionHeading("智能建议", trailing: model.aiServiceAvailable ? "可用" : "准备中")
                            KrisStatusRow(
                                title: "Kris 智能建议",
                                detail: "解释健康趋势、生成候选计划；安全检查后仍由你确认。",
                                tint: model.aiServiceAvailable ? KrisTheme.positive : KrisTheme.systemAction,
                                systemImage: "text.bubble.fill"
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("查看智能建议服务与隐私说明")
                    .accessibilityIdentifier("open-ai-settings")

                    KrisPanel {
                        KrisSectionHeading("Apple 健康", trailing: "自动采集")
                        if model.health.state == .importing || model.health.state == .authorizing {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(value: model.health.importProgress)
                                    .tint(KrisTheme.forest)
                                HStack {
                                    Text(model.health.currentImportLabel ?? "等待系统授权")
                                    Spacer()
                                    Text("\(model.health.completedImportCount)/\(model.health.totalImportCount)")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        LazyVGrid(columns: dataStatColumns, spacing: 8) {
                            importStat("指标", value: "\(model.health.successfulImportCount)")
                            importStat("本次新增", value: "\(model.health.importedSampleCount)")
                            importStat("缓存样本", value: "\(model.health.cachedSampleCount)")
                        }
                        if model.health.automaticUpdatesEnabled {
                            KrisStatusRow(
                                title: healthNeedsAction ? "后台更新已开启，但需要处理异常" : "后台自动更新已开启",
                                detail: "Apple 健康出现新数据时增量读取；回到 App 时自动补齐。",
                                tint: healthNeedsAction ? KrisTheme.caution : KrisTheme.positive,
                                systemImage: "bolt.heart.fill"
                            )
                        } else {
                            Text("首次授权后，系统会自动更新；不需要每天手动导入。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button { Task { await model.importHealth() } } label: {
                                Label(importButtonTitle, systemImage: "heart.text.square")
                            }
                            .buttonStyle(KrisPrimaryButtonStyle())
                            .disabled(model.health.state == .authorizing || model.health.state == .importing)
                            .accessibilityIdentifier("connect-apple-health-button")
                        }
                        if let error = model.health.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(KrisTheme.clay)
                        }
                        if !model.health.importIssues.isEmpty && model.health.lastError == nil {
                            Label(
                                "\(model.health.importIssues.count) 项当前未覆盖，已获取的数据仍可使用",
                                systemImage: "exclamationmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(KrisTheme.caution)
                        }
                    }

                    if model.isPaired && (model.queueCount > 0 || model.queueSummary.latestError != nil) {
                        KrisPanel {
                            KrisSectionHeading("开发导出队列", trailing: "\(model.queueCount) 项")
                            LazyVGrid(columns: dataStatColumns, spacing: 8) {
                                importStat("健康批次", value: "\(model.queueSummary.healthBatches)")
                                importStat("训练记录", value: "\(model.queueSummary.trainingSessions)")
                                importStat("待重试", value: "\(model.queueSummary.retryItems)")
                            }
                            syncStatus
                            if let error = model.queueSummary.latestError {
                                Label(error, systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                                    .font(.footnote).foregroundStyle(KrisTheme.danger)
                                // History processing is local-first. A queued
                                // item can remain here without exposing the
                                // development companion as a product feature.
                            }
                            Text("导出失败不会影响健康数据或训练历史。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    KrisPanel {
                        KrisSectionHeading("连接与诊断", trailing: "按需展开")
                        DisclosureGroup("Apple 健康") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("系统授权、历史回填与逐项导入结果。日常不需要在这里手动更新。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let date = model.health.lastImportAt {
                                    Label(
                                        "最近自动检查 \(date.formatted(date: .abbreviated, time: .shortened))",
                                        systemImage: "clock"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                if model.health.state == .noData || model.health.failureAction == .permissions {
                                    Button {
                                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                                    } label: {
                                        Label("打开系统权限", systemImage: "gearshape.fill")
                                    }
                                    .buttonStyle(KrisOutlineButtonStyle())
                                } else if model.health.failureAction == .reinstall {
                                    Label(
                                        "此问题不能通过重复导入解决",
                                        systemImage: "iphone.and.arrow.forward.inward"
                                    )
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                }
                                if model.health.failureAction != .reinstall
                                    && (model.health.state == .ready || model.health.state == .noData || model.health.state == .failed) {
                                    Button { Task { await model.importHealth(forceBackfill: true) } } label: {
                                        Label(
                                            "重新回填最近 42 天",
                                            systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                                        )
                                    }
                                    .buttonStyle(KrisOutlineButtonStyle())
                                }
                                if !model.health.importedCounts.isEmpty {
                                    DisclosureGroup("本次查询明细") {
                                        ForEach(HealthMetric.allCases, id: \.self) { metric in
                                            if let count = model.health.importedCounts[metric] {
                                                LabeledContent(
                                                    healthMetricLabel(metric), value: "\(count) 个新样本"
                                                )
                                                .font(.caption)
                                            }
                                        }
                                    }
                                    .font(.subheadline)
                                }
                                if !model.health.importIssues.isEmpty {
                                    DisclosureGroup("未导入项目（\(model.health.importIssues.count)）") {
                                        ForEach(model.health.importIssues) { issue in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(issue.label).font(.subheadline.weight(.semibold))
                                                Text(issue.message).font(.caption).foregroundStyle(.secondary)
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }
                                    .font(.subheadline)
                                }
                                DisclosureGroup("数据覆盖与新鲜度") {
                                    ForEach(model.health.metricFreshness) { item in
                                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(healthMetricLabel(item.metric))
                                                    .font(.subheadline.weight(.semibold))
                                                Text(item.sampleCount == 0 ? "暂无样本" : "\(item.sampleCount) 个样本")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 8)
                                            Text(freshnessLabel(item.latestAt))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(freshnessTint(item.latestAt))
                                        }
                                        .frame(minHeight: 44)
                                        .accessibilityElement(children: .combine)
                                    }
                                }
                                .font(.subheadline)
                                .accessibilityIdentifier("health-metric-freshness")
                            }
                            .padding(.top, 8)
                        }
                        .font(.subheadline.weight(.semibold))
                        Divider()
                        KrisStatusRow(
                            title: "计划更新",
                            detail: "新计划准备好后会自动出现在今日页。",
                            tint: KrisTheme.positive,
                            systemImage: "calendar.badge.checkmark"
                        )
                    }

                    KrisPanel {
                        KrisSectionHeading("隐私与分析", trailing: "端侧优先")
                        KrisStatusRow(
                            title: "健康分析留在 iPhone",
                            detail: "健康分析与训练记录留在 iPhone；不依赖第三方同步服务。",
                            tint: KrisTheme.positive,
                            systemImage: "lock.shield.fill"
                        )
                        Divider()
                        LabeledContent("规则版本", value: "ReadinessRules.v1")
                            .font(.subheadline)
                        LabeledContent("健康缓存", value: "\(model.health.cachedSampleCount) 个样本")
                            .font(.subheadline)
                    }
                    .accessibilityIdentifier("settings-privacy")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(KrisTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func importStat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(KrisTheme.muted, in: RoundedRectangle(cornerRadius: 10))
    }

    private var dataStatColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 3
        )
    }

    private var healthSourceDetail: String {
        if let date = model.health.lastImportAt {
            return "\(date.formatted(date: .omitted, time: .shortened)) 更新 · \(model.health.cachedSampleCount) 个样本"
        }
        if model.health.automaticUpdatesEnabled && model.health.cachedSampleCount == 0 {
            return "自动监听已开启，尚未读取到可用样本"
        }
        return model.health.automaticUpdatesEnabled
            ? "已有可用数据，等待下次自动补齐"
            : "由 Apple 健康读取，无需额外同步服务"
    }

    private var watchState: String {
        if model.workoutMirror.isConnected { return "训练同步中" }
        return model.watch.connectionStatus.shortLabel
    }

    private var watchDetail: String {
        if model.workoutMirror.isConnected { return "系统训练已与 iPhone 实时联动" }
        switch model.watch.connectionStatus {
        case .reachable: return "可在手表启动训练并回传组次"
        case .installed: return "Kris 已安装；手表恢复连接后会自动传回记录"
        case .needsInstallation: return "请在 iPhone 的 Watch App 中安装 Kris"
        case .checking: return "正在读取手表安装与连接状态"
        case .unavailable: return "暂时无法读取状态；不影响 iPhone 端训练"
        case .noPairedWatch: return "未检测到系统已配对的 Apple Watch"
        case .unsupported: return "当前设备不支持 Apple Watch 联动"
        }
    }

    private var watchStatusTint: Color {
        if model.workoutMirror.isConnected { return KrisTheme.positive }
        switch model.watch.connectionStatus {
        case .reachable: return KrisTheme.positive
        case .installed: return KrisTheme.positive
        case .needsInstallation, .unavailable: return KrisTheme.caution
        case .checking: return KrisTheme.accent
        case .noPairedWatch, .unsupported: return .secondary
        }
    }

    private var healthStatusTint: Color {
        switch model.health.state {
        case .ready: KrisTheme.positive
        case .authorizing, .importing: KrisTheme.accent
        case .noData, .failed: KrisTheme.caution
        default: .secondary
        }
    }

    private var healthNeedsAction: Bool {
        switch model.health.state {
        case .noData, .failed, .unavailable: true
        default: false
        }
    }

    private var overallDataState: String {
        if model.queueSummary.latestError != nil { return "处理待重试" }
        if healthNeedsAction { return "需要处理" }
        if !model.health.automaticUpdatesEnabled { return "待授权" }
        return "运行正常"
    }

    private var importButtonTitle: String {
        switch model.health.state {
        case .ready: "检查 Apple 健康数据"
        case .noData: "检查 Apple 健康权限"
        case .failed: "重新连接 Apple 健康"
        case .authorizing: "等待系统授权"
        case .importing: "正在读取 Apple 健康"
        default: "连接 Apple 健康"
        }
    }

    private var healthState: String {
        if model.health.automaticUpdatesEnabled {
            switch model.health.state {
            case .failed: return model.health.cachedSampleCount > 0
                ? "缓存可用 · 更新需检查" : "监听已开启 · 更新需检查"
            case .noData: return "监听已开启 · 尚无样本"
            case .unavailable: return "当前设备不可用"
            case .authorizing: return "正在核对权限"
            case .importing: return "正在自动更新"
            case .idle, .ready: return "自动更新已开启"
            }
        }
        return switch model.health.state {
        case .idle: "未授权"
        case .authorizing: "等待授权"
        case .importing: "正在导入"
        case .ready: "自动更新已开启"
        case .noData: "未读取到样本"
        case .unavailable: "设备不支持"
        case .failed: "导入失败"
        }
    }

    private func healthMetricLabel(_ metric: HealthMetric) -> String {
        switch metric {
        case .sleep: "睡眠"
        case .hrvSdnn: "HRV"
        case .restingHeartRate: "静息心率"
        case .stepCount: "步数"
        case .activeEnergy: "活动能量"
        case .basalEnergy: "静息能量"
        case .bodyMass: "体重"
        case .bodyFatPercentage: "体脂"
        case .leanBodyMass: "去脂体重"
        case .bmi: "BMI"
        case .vo2Max: "VO₂ max"
        case .workout: "训练记录"
        }
    }

    private func freshnessLabel(_ date: Date?) -> String {
        guard let date else { return "未覆盖" }
        let interval = Date().timeIntervalSince(date)
        if interval < 0 || interval < 3_600 { return "1 小时内" }
        if interval < 86_400 { return "\(max(1, Int(interval / 3_600))) 小时前" }
        return "\(max(1, Int(interval / 86_400))) 天前"
    }

    private func freshnessTint(_ date: Date?) -> Color {
        guard let date else { return .secondary }
        let interval = Date().timeIntervalSince(date)
        if interval < 86_400 { return KrisTheme.positive }
        if interval < 3 * 86_400 { return KrisTheme.caution }
        return .secondary
    }

    @ViewBuilder private var syncStatus: some View {
        switch model.syncState {
        case .idle: LabeledContent("最近处理", value: "尚未处理").font(.subheadline)
        case .syncing: HStack { ProgressView(); Text("正在处理") }
        case .success(let date): LabeledContent("最近处理", value: date.formatted(date: .omitted, time: .shortened)).font(.subheadline)
        case .failed(let error): Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(KrisTheme.clay)
        }
    }
}

private func target(_ exercise: ExercisePlan) -> String {
    let weight = exercise.targetWeightKg.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) kg · " } ?? ""
    return "\(weight)\(exercise.sets)×\(exercise.targetReps)"
}

private func confidenceLabel(_ value: String?) -> String {
    switch value { case "high": "高"; case "medium": "中"; default: "低" }
}

private func sectionTitle(_ title: String, icon: String) -> some View {
    Label(title, systemImage: icon).font(.headline)
}

private struct TinyBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5))
            configuration.title
        }
    }
}
