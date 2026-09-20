import SwiftUI

private extension UserIntentKind {
    var composerTitle: String {
        switch self {
        case .createPlan: "新建训练计划"
        case .revisePlan: "调整当前计划"
        case .replaceExercise: "替换一个动作"
        case .adaptToEquipment: "按器械条件调整"
        case .shortenPlan: "缩短训练时间"
        case .explainRecommendation: "解释当前建议"
        }
    }

    var changePlaceholder: String {
        switch self {
        case .replaceExercise: "希望如何替换（选填）"
        case .adaptToEquipment: "补充器械限制（选填）"
        case .shortenPlan: "缩短时优先保留什么（选填）"
        case .revisePlan: "说明希望的具体变更（选填）"
        case .createPlan, .explainRecommendation: "补充说明（选填）"
        }
    }
}

private extension RequestedChangeKind {
    var composerTitle: String {
        switch self {
        case .addExercise: "增加动作"
        case .removeExercise: "移除动作"
        case .replaceExercise: "替换动作"
        case .changeLoad: "调整重量"
        case .changeVolume: "调整组数或次数"
        case .changeDuration: "调整时长"
        }
    }
}

struct AISettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                KrisPageHeader(
                    title: "智能建议",
                    subtitle: "管理智能建议服务与计划生成"
                )

                KrisPanel {
                    KrisSectionHeading("服务状态", trailing: model.aiServiceAvailable ? "可用" : "准备中")
                    KrisStatusRow(
                        title: model.aiServiceAvailable ? "智能建议已连接" : "智能建议尚未接通",
                        detail: model.aiServiceAvailable
                            ? "无需配置密钥，可直接生成并审核候选计划。"
                            : "当前版本仍可正常使用 Apple 健康和训练记录。",
                        tint: model.aiServiceAvailable ? KrisTheme.positive : KrisTheme.caution,
                        systemImage: model.aiServiceAvailable ? "checkmark.shield.fill" : "clock.badge.exclamationmark.fill"
                    )
                    Text("模型供应商密钥由 Kris 服务端安全管理，不会写入 App、iCloud、偏好设置或日志，也不要求用户自行申请。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                KrisPanel {
                    KrisSectionHeading("发送范围", trailing: "最小化")
                    privacyRow("会发送", detail: "目标、可用时间、器械、用户主动反馈，以及日期级健康测量和训练摘要", icon: "checkmark.shield.fill", tint: KrisTheme.positive)
                    Divider()
                    privacyRow("不会发送", detail: "准备度或恢复评分、HealthKit 样本 UUID、设备 ID、逐分钟心率、原始睡眠区间或无关健康数据", icon: "lock.fill", tint: KrisTheme.systemAction)
                    Divider()
                    privacyRow("发布规则", detail: "模型只生成候选；结构校验、安全检查和你的确认缺一不可", icon: "person.badge.shield.checkmark.fill", tint: KrisTheme.caution)
                }

            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(KrisTheme.canvas)
        .navigationTitle("智能建议")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func privacyRow(_ title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AIPlanComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var objective = "减脂优先，同时尽量保留肌肉"
    @State private var availableMinutes = 55
    @State private var availableEquipment = "常规健身房器械"
    @State private var unavailableEquipment = ""
    @State private var unknownEquipment = ""
    @State private var notes = ""
    @State private var symptoms = LocalTrainingSymptoms.notReported
    @State private var reportedEnergy: SubjectiveEnergy?
    @State private var intentKind = UserIntentKind.createPlan
    @State private var requestedExerciseID: UUID?
    @State private var requestedChangeKind = RequestedChangeKind.changeVolume
    @State private var requestedChangeDetail = ""
    @State private var initializedIntent = false
    @State private var showDisclosure = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KrisPageHeader(
                        title: "生成候选计划",
                        subtitle: "先说明今天的实际条件，再检查模型建议"
                    )

                    if !model.aiServiceAvailable {
                        KrisPanel {
                            KrisStatusRow(
                                title: "智能建议服务尚未连接",
                                detail: "当前仍可查看健康数据并手动制定训练计划。",
                                tint: KrisTheme.caution,
                                systemImage: "network.slash"
                            )
                        }
                    }

                    KrisPanel {
                        KrisSectionHeading("今天怎么安排", trailing: "必填")
                        Picker("我希望 Kris", selection: $intentKind) {
                            ForEach(UserIntentKind.allCases, id: \.self) { kind in
                                Text(kind.composerTitle).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("ai-intent-picker")
                        Divider()
                        DatePicker("训练日期", selection: $date, displayedComponents: .date)
                            .frame(minHeight: 44)
                        Divider()
                        labeledField("目标", text: $objective)
                        Divider()
                        Stepper("可用时间 · \(availableMinutes) 分钟", value: $availableMinutes, in: 20...120, step: 5)
                            .frame(minHeight: 44)
                    }

                    KrisPanel {
                        KrisSectionHeading("器械条件", trailing: "未知保持未知")
                        labeledField("可用", text: $availableEquipment)
                        Divider()
                        labeledField("不可用", text: $unavailableEquipment)
                        Divider()
                        labeledField("不确定", text: $unknownEquipment)
                        Text("多个器械用逗号分隔。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if intentKind != .createPlan {
                        KrisPanel {
                            KrisSectionHeading("调整对象")
                            if let plan = model.currentPlan {
                                LabeledContent("当前计划", value: "\(plan.title) · v\(plan.revision)")
                                    .font(.subheadline)
                                if intentKind == .replaceExercise {
                                    Divider()
                                    Picker("目标动作", selection: $requestedExerciseID) {
                                        Text("请选择").tag(nil as UUID?)
                                        ForEach(plan.exercises) { exercise in
                                            Text(exercise.name).tag(exercise.exerciseId as UUID?)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("ai-target-exercise-picker")
                                }
                                if intentKind == .revisePlan {
                                    Divider()
                                    Picker("变更类型", selection: $requestedChangeKind) {
                                        ForEach(RequestedChangeKind.allCases, id: \.self) { kind in
                                            Text(kind.composerTitle).tag(kind)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(minHeight: 44)
                                }
                                if intentKind != .explainRecommendation {
                                    Divider()
                                    TextField(
                                        intentKind.changePlaceholder,
                                        text: $requestedChangeDetail,
                                        axis: .vertical
                                    )
                                    .lineLimit(2...4)
                                    .padding(10)
                                    .background(
                                        KrisTheme.muted,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .accessibilityIdentifier("ai-requested-change")
                                }
                            } else {
                                Label("当前没有可调整的已确认计划。", systemImage: "info.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(KrisTheme.caution)
                            }
                        }
                    }

                    KrisPanel {
                        KrisSectionHeading("训练前确认")
                        Picker("当前身体反馈", selection: $symptoms) {
                            Text("未确认").tag(LocalTrainingSymptoms.notReported)
                            Text("无异常").tag(LocalTrainingSymptoms.noneReported)
                            Text("有影响训练的不适").tag(LocalTrainingSymptoms.limitingDiscomfort)
                            Text("有危险信号").tag(LocalTrainingSymptoms.emergencyReported)
                        }
                        .pickerStyle(.menu)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("ai-symptoms-picker")
                        Divider()
                        Picker("今天的主观精力", selection: $reportedEnergy) {
                            Text("未填写").tag(nil as SubjectiveEnergy?)
                            Text("良好").tag(SubjectiveEnergy.good as SubjectiveEnergy?)
                            Text("正常").tag(SubjectiveEnergy.normal as SubjectiveEnergy?)
                            Text("偏低").tag(SubjectiveEnergy.low as SubjectiveEnergy?)
                            Text("明显疲惫").tag(SubjectiveEnergy.exhausted as SubjectiveEnergy?)
                        }
                        .pickerStyle(.menu)
                        .frame(minHeight: 44)
                        .accessibilityHint("这是你的主动反馈；未填写会保持未知，不会被推断为正常")
                        .accessibilityIdentifier("ai-reported-energy-picker")
                        TextField("补充限制、偏好或想练的部位（选填）", text: $notes, axis: .vertical)
                            .lineLimit(2...5)
                            .padding(10)
                            .background(KrisTheme.muted, in: RoundedRectangle(cornerRadius: 10))
                        if symptoms != .noneReported {
                            Label(symptomMessage, systemImage: "exclamationmark.shield.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(symptoms == .emergencyReported ? KrisTheme.danger : KrisTheme.caution)
                        }
                    }

                    DisclosureGroup(isExpanded: $showDisclosure) {
                        KrisPanel(fill: KrisTheme.surface) {
                            ForEach(disclosureItems, id: \.self) { item in
                                Label(item, systemImage: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("缺失数据保持未知；不会发送原始 HealthKit 样本，也不会发送准备度或恢复评分。")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("预览将发送的数据范围", systemImage: "eye.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("ai-data-disclosure")

                    generationStatus

                    if model.aiGenerationState == .generating {
                        Button(role: .cancel) { model.cancelAIPlanGeneration() } label: {
                            Label("取消生成", systemImage: "xmark")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            model.startAIPlanGeneration(input: input)
                        } label: {
                            Label("生成候选计划", systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(KrisPrimaryButtonStyle())
                        .disabled(!canGenerate)
                        .accessibilityHint("只生成待审核候选，不会直接替换当前计划")
                        .accessibilityIdentifier("generate-ai-plan")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(KrisTheme.canvas)
            .navigationTitle("候选计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        model.cancelAIPlanGeneration()
                        dismiss()
                    }
                }
            }
            .onChange(of: model.aiGenerationState) { _, state in
                if state == .ready { dismiss() }
            }
            .onAppear {
                guard !initializedIntent else { return }
                intentKind = model.currentPlan == nil ? .createPlan : .revisePlan
                requestedExerciseID = model.currentPlan?.exercises.first?.exerciseId
                initializedIntent = true
            }
            .onChange(of: intentKind) { _, kind in
                if kind == .replaceExercise, requestedExerciseID == nil {
                    requestedExerciseID = model.currentPlan?.exercises.first?.exerciseId
                }
            }
            .onDisappear {
                if model.aiGenerationState == .generating {
                    model.cancelAIPlanGeneration()
                }
            }
        }
    }

    private var input: AIPlanUserInput {
        AIPlanUserInput(
            date: Self.dayString(date), objective: objective,
            availableMinutes: availableMinutes,
            equipment: equipment.map(\.name).joined(separator: "，"),
            notes: notes, symptoms: symptoms, reportedEnergy: reportedEnergy,
            intent: AIPlanIntentInput(
                kind: intentKind, equipment: equipment,
                requestedExerciseId: intentKind == .replaceExercise
                    ? requestedExerciseID : nil,
                requestedChanges: requestedChanges
            )
        )
    }

    private var equipment: [EquipmentAvailability] {
        equipmentItems(availableEquipment, status: .available)
            + equipmentItems(unavailableEquipment, status: .unavailable)
            + equipmentItems(unknownEquipment, status: .unknown)
    }

    private var requestedChanges: [RequestedChange] {
        let typedDetail = requestedChangeDetail.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        switch intentKind {
        case .replaceExercise:
            return [RequestedChange(
                kind: .replaceExercise, exerciseId: requestedExerciseID,
                detail: typedDetail.isEmpty ? "为目标动作推荐替换动作" : typedDetail
            )]
        case .adaptToEquipment:
            return [RequestedChange(
                kind: .replaceExercise, exerciseId: nil,
                detail: typedDetail.isEmpty ? "按当前器械可用性调整计划" : typedDetail
            )]
        case .shortenPlan:
            let duration = "将计划调整至 \(availableMinutes) 分钟以内"
            return [RequestedChange(
                kind: .changeDuration, exerciseId: nil,
                detail: typedDetail.isEmpty ? duration : "\(duration)；\(typedDetail)"
            )]
        case .revisePlan where !typedDetail.isEmpty:
            return [RequestedChange(
                kind: requestedChangeKind, exerciseId: nil, detail: typedDetail
            )]
        case .createPlan, .revisePlan, .explainRecommendation:
            return []
        }
    }

    private func equipmentItems(
        _ value: String,
        status: EquipmentAvailabilityStatus
    ) -> [EquipmentAvailability] {
        value.components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { EquipmentAvailability(name: $0, status: status) }
    }

    private var context: TrainingContext { model.makeAITrainingContext(input: input) }

    private var disclosureItems: [String] {
        var items = [
            "你的目标、可用时间、器械和主动填写的反馈",
            "睡眠时长、HRV、静息心率和步数的日期级汇总或明确缺失状态",
            "已确认的 Kris 训练结果与 HealthKit 观察记录（两者会保持区分）",
            "本地安全限制和本地进阶规则结论",
        ]
        if context.currentPlan != nil { items.append("当前计划及其版本") }
        if !context.dataGaps.isEmpty { items.append("当前数据缺口，不会将缺失解释为正常或异常") }
        return items
    }

    private var canGenerate: Bool {
        model.aiServiceAvailable
            && symptoms == .noneReported
            && !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !equipment.isEmpty
            && (intentKind == .createPlan || model.currentPlan != nil)
            && (intentKind != .replaceExercise || requestedExerciseID != nil)
    }

    private var symptomMessage: String {
        switch symptoms {
        case .notReported: "请先确认当前是否有影响训练的不适。"
        case .noneReported: ""
        case .limitingDiscomfort: "先评估不适和受影响动作，本轮不生成训练处方。"
        case .emergencyReported: "停止训练并及时就医；症状严重时立即寻求急救。"
        }
    }

    @ViewBuilder private var generationStatus: some View {
        switch model.aiGenerationState {
        case .idle, .ready: EmptyView()
        case .generating:
            KrisPanel {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在生成候选").font(.subheadline.weight(.semibold))
                        Text("可以取消；首页和健康数据仍可正常使用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(KrisTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text)
                .frame(minHeight: 36)
        }
    }

    private static func dayString(_ date: Date) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

struct AIPlanReviewView: View {
    @Environment(AppModel.self) private var model
    let candidate: TrainingPlanCandidate

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                KrisPageHeader(
                    title: "旧版候选计划",
                    subtitle: "可继续查看或放弃；采用前需要重新生成新版候选",
                    status: "需要迁移"
                )
                KrisPanel {
                    HStack {
                        KrisStatusPill(title: "V1 兼容数据", tint: KrisTheme.caution, systemImage: "clock.arrow.circlepath")
                    }
                    Text(candidate.plan.title).font(.title3.weight(.semibold))
                    Text("\(candidate.plan.estimatedMinutes) 分钟 · \(candidate.plan.exercises.count) 个动作")
                        .font(.caption).foregroundStyle(.secondary)
                    if let rationale = model.aiPlanRationale, !rationale.isEmpty {
                        Text(rationale).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                }

                KrisPanel {
                    KrisSectionHeading("动作与处方")
                    ForEach(Array(candidate.plan.exercises.enumerated()), id: \.element.id) { index, exercise in
                        if index > 0 { Divider() }
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(KrisTheme.brandInk)
                                .frame(width: 24, height: 24)
                                .background(KrisTheme.brandLime, in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(exercise.name).font(.subheadline.weight(.semibold))
                                Text("\(exercise.equipmentVariant) · \(planTarget(exercise)) · 休 \(exercise.restSeconds) 秒")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }

                if let current = model.currentPlan {
                    let changes = TrainingPlanComparison.changes(from: current, to: candidate.plan)
                    if !changes.isEmpty {
                        KrisPanel {
                            KrisSectionHeading("与当前计划相比", trailing: "\(changes.count) 项")
                            ForEach(changes, id: \.self) { change in
                                Label(change, systemImage: "arrow.left.arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                KrisPanel {
                    KrisSectionHeading("采用前检查", trailing: "不可采用")
                    ForEach(publicationErrors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(KrisTheme.danger)
                    }
                    if !model.aiPlanCautions.isEmpty {
                        Divider()
                        ForEach(model.aiPlanCautions, id: \.self) { caution in
                            Label(caution, systemImage: "shield.lefthalf.filled")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Button {} label: {
                    Label("采用为当前计划", systemImage: "checkmark")
                }
                .buttonStyle(KrisPrimaryButtonStyle())
                .disabled(true)
                .accessibilityIdentifier("publish-ai-plan")

                Button(role: .destructive) {
                    _ = model.rejectPlanCandidate()
                } label: {
                    Text("放弃此候选").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("reject-legacy-ai-plan")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(KrisTheme.canvas)
    }

    private var publicationErrors: [String] {
        ["旧版候选缺少 V2 evidence、安全限制与接受时上下文，不能直接采用；请重新生成候选计划。"]
            + AIPlanPolicy.publicationErrors(
                candidate, currentSafetyGate: model.effectiveReadiness?.safetyGate
            )
    }

    private func planTarget(_ exercise: ExercisePlan) -> String {
        let load = exercise.targetWeightKg.map {
            "\($0.formatted(.number.precision(.fractionLength(0...1)))) kg"
        } ?? "自重/待校准"
        return "\(load) · \(exercise.sets)×\(exercise.targetReps)"
    }
}

struct AIRecommendationReviewView: View {
    @Environment(AppModel.self) private var model
    let candidate: TrainingPlanCandidateV2
    @State private var showEditor = false
    @State private var actionMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                KrisPageHeader(
                    title: isAdvisory ? "查看智能建议" : "审核候选计划",
                    subtitle: isAdvisory
                        ? "这条建议不会修改当前训练计划"
                        : "这是 Kris 的建议，不是已发布计划；最终选择由你确认",
                    status: "待你确认"
                )
                recommendationSummary
                planPanel
                reasonsPanel
                evidencePanel
                if !candidate.recommendation.uncertainties.isEmpty { uncertaintyPanel }
                if candidate.recommendation.optionalAdjustment != nil
                    || !candidate.recommendation.alternatives.isEmpty {
                    optionsPanel
                }
                if !candidate.recommendation.safetyConsiderations.isEmpty { aiSafetyPanel }
                localRestrictionsPanel
                validationPanel

                if let actionMessage {
                    Label(actionMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(KrisTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ai-v2-action-error")
                }

                if !isAdvisory {
                    Button { showEditor = true } label: {
                        Label("编辑候选内容", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("保存修改时会重新执行本地校验；采用后会记录为编辑后接受")
                    .accessibilityIdentifier("edit-ai-plan")
                }

                Button {
                    if !model.publishAIRecommendationCandidate() {
                        actionMessage = "采用前检查未通过。请查看本地校验结果，或重新生成候选计划。"
                    }
                } label: {
                    Label(isAdvisory ? "确认已查看" : "采用为当前计划", systemImage: "checkmark")
                }
                .buttonStyle(KrisPrimaryButtonStyle())
                .disabled(!candidate.validationReport.isValid)
                .accessibilityHint(isAdvisory
                    ? "只记录你已查看，不修改当前计划"
                    : "采用前会再次检查数据时效、计划版本和本地安全规则")
                .accessibilityIdentifier(isAdvisory
                    ? "acknowledge-ai-recommendation" : "publish-ai-plan")

                Button(role: .destructive) {
                    _ = model.rejectAIRecommendationCandidate()
                } label: {
                    Text("放弃此候选").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(KrisTheme.canvas)
        .sheet(isPresented: $showEditor) {
            AIRecommendationEditorView(candidate: candidate)
        }
    }

    private var isAdvisory: Bool {
        candidate.recommendation.kind == .noChange
            || candidate.recommendation.kind == .declineUnsafeRequest
    }

    private var recommendationSummary: some View {
        KrisPanel {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { recommendationPills }
                VStack(alignment: .leading, spacing: 8) { recommendationPills }
            }
            Text(candidate.recommendation.recommendation)
                .font(.headline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("AI 只能提出候选内容，不能发布计划、创建安全规则或自动增加重量。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("ai-v2-recommendation-summary")
    }

    @ViewBuilder private var recommendationPills: some View {
        KrisStatusPill(title: "AI 建议", tint: KrisTheme.systemAction, systemImage: "text.bubble.fill")
        KrisStatusPill(
            title: "\(confidenceLabel(candidate.recommendation.confidence))把握",
            tint: confidenceTint(candidate.recommendation.confidence),
            systemImage: "gauge.with.dots.needle.33percent"
        )
        KrisStatusPill(title: "需你确认", tint: KrisTheme.caution, systemImage: "person.crop.circle.badge.checkmark")
    }

    private var planPanel: some View {
        KrisPanel {
            KrisSectionHeading(
                isAdvisory ? "当前计划保持不变" : "候选训练内容",
                trailing: "\(candidate.plan.estimatedMinutes) 分钟 · \(candidate.plan.exercises.count) 个动作"
            )
            Text(candidate.plan.title).font(.title3.weight(.semibold))
            if let goal = candidate.plan.goal, !goal.isEmpty {
                Text(goal).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(candidate.plan.exercises.enumerated()), id: \.element.id) { index, exercise in
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(KrisTheme.brandInk)
                        .frame(width: 24, height: 24)
                        .background(KrisTheme.brandLime, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exercise.name).font(.subheadline.weight(.semibold))
                        Text("\(exercise.equipmentVariant) · \(planTarget(exercise)) · 休 \(exercise.restSeconds) 秒")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("ai-v2-plan")
    }

    private var reasonsPanel: some View {
        KrisPanel {
            KrisSectionHeading("为什么这样建议", trailing: "AI 推理")
            ForEach(Array(candidate.recommendation.reasons.enumerated()), id: \.offset) { index, reason in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason.explanation)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    evidenceReferences(reason.evidenceIds)
                }
            }
        }
        .accessibilityIdentifier("ai-v2-reasons")
    }

    private var evidencePanel: some View {
        KrisPanel {
            KrisSectionHeading("建议依据", trailing: "可追溯")
            if referencedEvidence.isEmpty {
                Text("这条建议没有可展示的依据。")
                    .font(.caption).foregroundStyle(KrisTheme.danger)
            } else {
                ForEach(Array(referencedEvidence.enumerated()), id: \.element.id) { index, evidence in
                    if index > 0 { Divider() }
                    evidenceRow(evidence)
                }
            }
        }
        .accessibilityIdentifier("ai-v2-evidence")
    }

    private var uncertaintyPanel: some View {
        KrisPanel {
            KrisSectionHeading("仍不确定的地方", trailing: "不会补猜")
            ForEach(Array(candidate.recommendation.uncertainties.enumerated()), id: \.offset) { index, uncertainty in
                if index > 0 { Divider() }
                Label(uncertainty.explanation, systemImage: "questionmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                evidenceReferences(uncertainty.evidenceIds)
            }
        }
        .accessibilityIdentifier("ai-v2-uncertainty")
    }

    private var optionsPanel: some View {
        KrisPanel {
            KrisSectionHeading("可选调整与替代", trailing: "由你选择")
            if let adjustment = candidate.recommendation.optionalAdjustment {
                Label(adjustment.summary, systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                evidenceReferences(adjustment.evidenceIds)
            }
            ForEach(Array(candidate.recommendation.alternatives.enumerated()), id: \.element.id) { index, alternative in
                if index > 0 || candidate.recommendation.optionalAdjustment != nil { Divider() }
                Label(alternative.summary, systemImage: "arrow.triangle.branch")
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                evidenceReferences(alternative.evidenceIds)
            }
        }
        .accessibilityIdentifier("ai-v2-options")
    }

    private var aiSafetyPanel: some View {
        KrisPanel {
            KrisSectionHeading("AI 提醒", trailing: "不具备规则权限")
            ForEach(Array(candidate.recommendation.safetyConsiderations.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                Label(item.explanation, systemImage: "text.bubble.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                evidenceReferences(item.evidenceIds)
            }
        }
        .accessibilityIdentifier("ai-v2-safety-considerations")
    }

    private var localRestrictionsPanel: some View {
        KrisPanel {
            KrisSectionHeading("本地安全限制", trailing: "确定性规则")
            if candidate.context.safety.restrictions.isEmpty {
                Label("当前没有额外限制", systemImage: "checkmark.shield.fill")
                    .font(.subheadline).foregroundStyle(KrisTheme.positive)
            } else {
                ForEach(Array(candidate.context.safety.restrictions.enumerated()), id: \.element.id) { index, restriction in
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: restriction.severity == .block ? "hand.raised.fill" : "shield.lefthalf.filled")
                            .foregroundStyle(restriction.severity == .block ? KrisTheme.danger : KrisTheme.caution)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(restriction.message).font(.subheadline.weight(.medium))
                            Text("由本地规则执行，AI 不能移除或放宽")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityIdentifier("ai-v2-local-restrictions")
    }

    private var validationPanel: some View {
        KrisPanel {
            KrisSectionHeading(
                "本地校验",
                trailing: candidate.validationReport.isValid ? "已通过" : "需处理"
            )
            if candidate.validationReport.isValid {
                Label("结构、证据引用、安全限制和训练参数已通过本地检查", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(KrisTheme.positive)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(candidate.validationReport.issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.krisMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(KrisTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("采用时会用最新计划版本、用户反馈和本地规则再次校验。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ai-v2-validation")
    }

    private var referencedEvidence: [Evidence] {
        let ids = candidate.recommendation.evidenceIds
            + candidate.recommendation.reasons.flatMap(\.evidenceIds)
            + candidate.recommendation.uncertainties.flatMap(\.evidenceIds)
            + (candidate.recommendation.optionalAdjustment?.evidenceIds ?? [])
            + candidate.recommendation.alternatives.flatMap(\.evidenceIds)
            + candidate.recommendation.safetyConsiderations.flatMap(\.evidenceIds)
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return candidate.context.evidence.first { $0.id == id }
        }
    }

    @ViewBuilder
    private func evidenceReferences(_ ids: [String]) -> some View {
        let labels = ids.compactMap { id in
            candidate.context.evidence.first { $0.id == id }.map(evidenceTitle)
        }
        if !labels.isEmpty {
            Text("依据：\(labels.joined(separator: "、"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func evidenceRow(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(evidenceTitle(evidence)).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(provenanceLabel(evidence.provenance)) · \(qualityLabel(evidence.quality))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(provenanceTint(evidence.provenance))
            }
            Text(evidenceValue(evidence))
                .font(.caption)
                .foregroundStyle(evidence.quality == .missing ? KrisTheme.caution : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func evidenceTitle(_ evidence: Evidence) -> String {
        switch evidence.key {
        case "sleep_duration": "睡眠时长"
        case "hrv_sdnn": "HRV · SDNN"
        case "resting_heart_rate": "静息心率"
        case "step_count": "步数"
        case "reported_symptoms": "用户报告的不适"
        case "user_reported_energy": "用户报告的精力"
        case "user_notes": "用户补充说明"
        case "confirmed_training_result": "已确认训练结果"
        case "observed_workout": "设备观察到的活动"
        case "progression_rule_result": "本地进阶规则"
        default: evidence.key.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func evidenceValue(_ evidence: Evidence) -> String {
        guard evidence.quality != .missing, let value = evidence.value else {
            return "数据缺失，保持未知"
        }
        switch value {
        case .string(let value):
            if evidence.key == "user_reported_energy" { return energyLabel(value) }
            return value
        case .number(let value):
            switch evidence.key {
            case "sleep_duration":
                let minutes = Int(value.rounded())
                return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
            case "hrv_sdnn": return "\(value.formatted(.number.precision(.fractionLength(0...1)))) ms"
            case "resting_heart_rate": return "\(value.formatted(.number.precision(.fractionLength(0...1)))) 次/分"
            case "step_count": return "\(Int(value.rounded()).formatted()) 步"
            default: return value.formatted(.number.precision(.fractionLength(0...2)))
            }
        case .bool(let value): return value ? "是" : "否"
        case .null: return "数据缺失，保持未知"
        case .array(let values): return values.map(jsonValueText).joined(separator: "、")
        case .object(let values):
            return values.sorted(by: { $0.key < $1.key })
                .map { "\(objectKeyLabel($0.key))：\(jsonValueText($0.value))" }
                .joined(separator: " · ")
        }
    }

    private func jsonValueText(_ value: JSONValue) -> String {
        switch value {
        case .string(let value): return value
        case .number(let value): return value.formatted(.number.precision(.fractionLength(0...2)))
        case .bool(let value): return value ? "是" : "否"
        case .null: return "未知"
        case .array(let values): return values.map(jsonValueText).joined(separator: "、")
        case .object: return "结构化记录"
        }
    }

    private func objectKeyLabel(_ key: String) -> String {
        switch key {
        case "title": "训练"
        case "status": "状态"
        case "completed_sets": "完成组数"
        case "duration_minutes": "时长（分钟）"
        case "activity_type": "活动"
        default: key.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func provenanceLabel(_ provenance: EvidenceProvenance) -> String {
        switch provenance {
        case .objectiveHealth: "客观测量"
        case .subjectiveUser: "用户反馈"
        case .confirmedTraining: "训练结果"
        case .observedWorkout: "设备观察"
        case .deterministicRule: "本地规则"
        }
    }

    private func provenanceTint(_ provenance: EvidenceProvenance) -> Color {
        switch provenance {
        case .objectiveHealth: KrisTheme.systemAction
        case .subjectiveUser: KrisTheme.violet
        case .confirmedTraining: KrisTheme.positive
        case .observedWorkout: KrisTheme.body
        case .deterministicRule: KrisTheme.caution
        }
    }

    private func qualityLabel(_ quality: EvidenceQuality) -> String {
        switch quality {
        case .confirmed: "已确认"
        case .partial: "部分数据"
        case .missing: "缺失"
        case .stale: "已过期"
        }
    }

    private func confidenceLabel(_ confidence: RecommendationConfidence) -> String {
        switch confidence {
        case .low: "低"
        case .medium: "中等"
        case .high: "较高"
        }
    }

    private func confidenceTint(_ confidence: RecommendationConfidence) -> Color {
        switch confidence {
        case .low: KrisTheme.caution
        case .medium: KrisTheme.systemAction
        case .high: KrisTheme.positive
        }
    }

    private func energyLabel(_ raw: String) -> String {
        switch SubjectiveEnergy(rawValue: raw) {
        case .good: "良好"
        case .normal: "正常"
        case .low: "偏低"
        case .exhausted: "明显疲惫"
        case nil: raw
        }
    }

    private func planTarget(_ exercise: ExercisePlan) -> String {
        let load = exercise.targetWeightKg.map {
            "\($0.formatted(.number.precision(.fractionLength(0...1)))) kg"
        } ?? "自重/待校准"
        return "\(load) · \(exercise.sets)×\(exercise.targetReps)"
    }
}

struct AIRecommendationEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TrainingPlanCandidateV2
    @State private var validationIssues: [AIDecisionValidationIssue] = []

    init(candidate: TrainingPlanCandidateV2) {
        _draft = State(initialValue: candidate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KrisPageHeader(
                        title: "编辑候选计划",
                        subtitle: "修改后重新执行本地校验；采用时会明确记录为编辑后接受"
                    )
                    KrisPanel {
                        KrisSectionHeading("计划概要")
                        labeledField("计划名称", text: $draft.plan.title)
                        Divider()
                        labeledField("本次目标", text: goalBinding)
                        Divider()
                        Stepper(
                            "预计时长 · \(draft.plan.estimatedMinutes) 分钟",
                            value: $draft.plan.estimatedMinutes, in: 10...180, step: 5
                        )
                        .frame(minHeight: 44)
                        Text("你填写的可用时间：\(draft.context.intent.availableMinutes) 分钟")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(draft.plan.exercises.indices, id: \.self) { index in
                        exerciseEditor(index: index)
                    }

                    Button { addExercise() } label: {
                        Label("添加动作", systemImage: "plus")
                    }
                    .buttonStyle(KrisOutlineButtonStyle())

                    if !validationIssues.isEmpty {
                        KrisPanel {
                            KrisSectionHeading("需要处理", trailing: "\(validationIssues.count) 项")
                            ForEach(Array(validationIssues.enumerated()), id: \.offset) { _, issue in
                                Label(issue.krisMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(KrisTheme.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityIdentifier("ai-editor-validation")
                    }

                    Button { save() } label: {
                        Label("保存并重新校验", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(KrisPrimaryButtonStyle())
                    .accessibilityIdentifier("save-ai-plan-edits")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(KrisTheme.canvas)
            .navigationTitle("编辑计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var goalBinding: Binding<String> {
        Binding(
            get: { draft.plan.goal ?? "" },
            set: { draft.plan.goal = $0 }
        )
    }

    private func exerciseEditor(index: Int) -> some View {
        KrisPanel {
            HStack {
                Text("动作 \(index + 1)").font(.headline)
                Spacer(minLength: 8)
                editorIconButton("上移动作", systemImage: "arrow.up") {
                    moveExercise(from: index, offset: -1)
                }
                .disabled(index == 0)
                editorIconButton("下移动作", systemImage: "arrow.down") {
                    moveExercise(from: index, offset: 1)
                }
                .disabled(index == draft.plan.exercises.count - 1)
                editorIconButton("删除动作", systemImage: "trash", role: .destructive) {
                    draft.plan.exercises.remove(at: index)
                    normalizeOrder()
                }
            }
            labeledField("动作名称", text: $draft.plan.exercises[index].name)
            Divider()
            labeledField("器械变体", text: $draft.plan.exercises[index].equipmentVariant)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("目标重量（kg）").font(.caption).foregroundStyle(.secondary)
                TextField(
                    "留空为自重或待校准",
                    value: $draft.plan.exercises[index].targetWeightKg,
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.decimalPad)
                .frame(minHeight: 44)
            }
            Divider()
            Stepper(
                "\(draft.plan.exercises[index].sets) 组",
                value: $draft.plan.exercises[index].sets, in: 1...10
            )
            .frame(minHeight: 44)
            Divider()
            Stepper(
                "每组 \(draft.plan.exercises[index].targetReps) 次",
                value: $draft.plan.exercises[index].targetReps, in: 1...50
            )
            .frame(minHeight: 44)
            Divider()
            Stepper(
                "休息 \(draft.plan.exercises[index].restSeconds) 秒",
                value: $draft.plan.exercises[index].restSeconds, in: 0...600, step: 15
            )
            .frame(minHeight: 44)
        }
        .accessibilityIdentifier("ai-exercise-editor-\(index)")
    }

    private func editorIconButton(
        _ label: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).frame(minHeight: 44)
        }
    }

    private func addExercise() {
        draft.plan.exercises.append(ExercisePlan(
            exerciseId: UUID(), order: draft.plan.exercises.count + 1,
            name: "", equipmentVariant: "", targetWeightKg: nil,
            sets: 3, targetReps: 10, restSeconds: 90,
            notes: nil, alternative: nil
        ))
    }

    private func moveExercise(from index: Int, offset: Int) {
        let destination = index + offset
        guard draft.plan.exercises.indices.contains(destination) else { return }
        draft.plan.exercises.swapAt(index, destination)
        normalizeOrder()
    }

    private func normalizeOrder() {
        for index in draft.plan.exercises.indices {
            draft.plan.exercises[index].order = index + 1
        }
    }

    private func save() {
        normalizeOrder()
        draft.status = .awaitingConfirmation
        let report = model.saveAIRecommendationCandidate(draft)
        draft.validationReport = report
        validationIssues = report.issues
        if report.isValid { dismiss() }
    }
}

private extension AIDecisionValidationIssue {
    var krisMessage: String {
        switch code {
        case .unsupportedSchema: "建议格式版本不受支持"
        case .unknownEvidenceReference: "建议引用了不存在或来源不匹配的依据"
        case .duplicateEvidenceId: "上下文中存在重复依据"
        case .missingEvidenceHasValue: "缺失数据被错误填入了数值"
        case .derivedScoreNotAllowed: "候选使用了不允许的身体状态评分"
        case .userConfirmationRequired: "建议未要求用户确认"
        case .restrictionNotAcknowledged: "建议未遵守全部本地安全限制"
        case .unknownRestrictionAcknowledgement: "建议引用了不存在的安全限制"
        case .trainingProhibited: "本地安全规则已阻止本次训练"
        case .durationExceedsAvailability: "候选时长超过你填写的可用时间"
        case .equipmentUnavailable: "候选使用了不可用或受限制的器械"
        case .exerciseExcluded: "候选包含本地规则已排除的动作"
        case .progressionPermissionMissing: "重量增加没有本地进阶许可"
        case .progressionLimitExceeded: "建议重量超过本地进阶上限"
        case .planMissing: "建议没有提供可审核的训练计划"
        case .invalidPlan: "候选包含无效的训练参数"
        case .contextExpired: "建议所依据的数据已经过期"
        case .planRevisionChanged: "当前计划在建议生成后发生了变化"
        case .restrictionSetChanged: "本地安全限制在建议生成后发生了变化"
        case .candidateLinkMismatch: "候选与当前训练意图不匹配"
        case .userInputRequired: "需要补充用户反馈后才能继续"
        case .ruleVersionChanged: "本地安全或进阶规则已经更新"
        }
    }
}

struct TrainingPlanEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TrainingPlan
    @State private var validationMessage: String?

    init(plan: TrainingPlan?) {
        let value = plan ?? TrainingPlan(
            planId: UUID(), revision: 0,
            date: String(DateFormatting.iso().prefix(10)),
            title: "我的训练", estimatedMinutes: 45,
            goal: nil, safetyGates: [], exercises: [], publishedAt: nil
        )
        _draft = State(initialValue: value)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KrisPanel {
                        KrisSectionHeading("计划")
                        labeledField("计划名称", text: $draft.title)
                        Divider()
                        Stepper(
                            "预计 \(draft.estimatedMinutes) 分钟",
                            value: $draft.estimatedMinutes, in: 10...180, step: 5
                        )
                        .frame(minHeight: 44)
                    }

                    ForEach(draft.exercises.indices, id: \.self) { index in
                        exerciseEditor(index: index)
                    }

                    Button {
                        addExercise()
                    } label: {
                        Label("添加动作", systemImage: "plus")
                    }
                    .buttonStyle(KrisOutlineButtonStyle())
                    .accessibilityIdentifier("manual-plan-add-exercise")

                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(KrisTheme.danger)
                    }

                    Button {
                        save()
                    } label: {
                        Label("保存计划", systemImage: "checkmark")
                    }
                    .buttonStyle(KrisPrimaryButtonStyle())
                    .accessibilityIdentifier("save-manual-plan")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(KrisTheme.canvas)
            .navigationTitle("编辑计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func exerciseEditor(index: Int) -> some View {
        KrisPanel {
            HStack {
                Text("动作 \(index + 1)").font(.headline)
                Spacer()
                Button {
                    moveExercise(from: index, offset: -1)
                } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0)
                .accessibilityLabel("上移动作")
                Button {
                    moveExercise(from: index, offset: 1)
                } label: { Image(systemName: "arrow.down") }
                .disabled(index == draft.exercises.count - 1)
                .accessibilityLabel("下移动作")
                Button(role: .destructive) {
                    draft.exercises.remove(at: index)
                    normalizeOrder()
                } label: { Image(systemName: "trash") }
                .accessibilityLabel("删除动作")
            }
            .frame(minHeight: 44)
            labeledField("动作名称", text: $draft.exercises[index].name)
            Divider()
            labeledField("器械", text: $draft.exercises[index].equipmentVariant)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("目标重量（kg）").font(.caption).foregroundStyle(.secondary)
                TextField(
                    "留空为自重或现场调整",
                    value: $draft.exercises[index].targetWeightKg,
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.decimalPad)
                .frame(minHeight: 36)
            }
            Divider()
            Stepper("\(draft.exercises[index].sets) 组", value: $draft.exercises[index].sets, in: 1...20)
                .frame(minHeight: 44)
            Divider()
            Stepper("每组 \(draft.exercises[index].targetReps) 次", value: $draft.exercises[index].targetReps, in: 1...100)
                .frame(minHeight: 44)
            Divider()
            Stepper(
                "休息 \(draft.exercises[index].restSeconds) 秒",
                value: $draft.exercises[index].restSeconds, in: 0...600, step: 15
            )
            .frame(minHeight: 44)
        }
        .accessibilityIdentifier("manual-exercise-editor-\(index)")
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).frame(minHeight: 36)
        }
    }

    private func addExercise() {
        draft.exercises.append(ExercisePlan(
            exerciseId: UUID(), order: draft.exercises.count + 1,
            name: "", equipmentVariant: "",
            targetWeightKg: nil, sets: 3, targetReps: 10,
            restSeconds: 90, notes: nil, alternative: nil
        ))
    }

    private func moveExercise(from index: Int, offset: Int) {
        let destination = index + offset
        guard draft.exercises.indices.contains(destination) else { return }
        draft.exercises.swapAt(index, destination)
        normalizeOrder()
    }

    private func normalizeOrder() {
        for index in draft.exercises.indices { draft.exercises[index].order = index + 1 }
    }

    private func save() {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { validationMessage = "请填写计划名称"; return }
        guard !draft.exercises.isEmpty else { validationMessage = "请至少添加一个动作"; return }
        guard draft.exercises.allSatisfy({
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.equipmentVariant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { validationMessage = "请填写每个动作的名称和器械"; return }
        normalizeOrder()
        draft.title = title
        draft.revision += 1
        draft.date = String(DateFormatting.iso().prefix(10))
        draft.publishedAt = DateFormatting.iso()
        model.savePlan(draft)
        dismiss()
    }
}

struct AIPlanEntryButton: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(KrisTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(KrisTheme.accent.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("生成候选计划").font(.subheadline.weight(.semibold))
                    Text(model.aiServiceAvailable ? "说明今天的条件，生成后由你审核" : "智能建议服务准备中")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(KrisTheme.raised, in: RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous)
                    .stroke(KrisTheme.border, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("模型不会直接发布计划")
        .accessibilityIdentifier("open-ai-plan-composer")
    }
}
