import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step = 0

    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                brand
                if step == 0 { valueStep } else { healthStep }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
        }
        .safeAreaPadding(.bottom, 130)
        .background(KrisTheme.canvas)
        .safeAreaInset(edge: .bottom) { actions }
        .accessibilityIdentifier("onboarding-flow")
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image("KrisLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("KRIS")
                    .font(.headline.weight(.bold))
                Text("日常健康与专业训练")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .combine)
    }

    private var valueStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("从日常健康开始")
                    .font(.largeTitle.weight(.bold))
                Text("睡得怎样，活动多少，身体有什么变化。训练日和非训练日，都值得关注。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                feature(
                    "今天", detail: "睡眠、日常活动与身体变化",
                    systemImage: "sun.max.fill", tint: KrisTheme.accent
                )
                feature(
                    "训练", detail: "按自己的时间安排，保留实际重量与次数",
                    systemImage: "checkmark.circle.fill", tint: KrisTheme.positive
                )
                feature(
                    "趋势", detail: "解释恢复、负荷与身体变化，而非只给分数",
                    systemImage: "chart.xyaxis.line", tint: KrisTheme.readiness
                )
            }

            Label("健康数据受系统权限保护", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var healthStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("连接 Apple 健康")
                    .font(.largeTitle.weight(.bold))
                Text("一次授权后自动读取；新数据由 HealthKit 通知，回到 App 时再补齐。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            KrisPanel {
                permissionRow("恢复", detail: "睡眠、HRV、静息心率", systemImage: "moon.stars.fill")
                Divider()
                permissionRow("体测", detail: "晨起体重、体脂与去脂体重", systemImage: "figure.stand")
                Divider()
                permissionRow("活动", detail: "步数、能量、VO₂ max 与训练", systemImage: "heart.text.square.fill")
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("健康分析自动完成", systemImage: "waveform.path.ecg")
                Label("健康数据由 Apple 健康自动更新", systemImage: "arrow.triangle.2.circlepath")
                Label("缺失权限只降低置信度，不会伪造正常", systemImage: "shield.lefthalf.filled")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if model.health.state == .authorizing || model.health.state == .importing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: model.health.importProgress)
                        .tint(KrisTheme.accent)
                    Text(model.health.currentImportLabel ?? "等待系统授权")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 8) {
            if step == 0 {
                Button("继续") {
                    withAnimation(.easeInOut(duration: 0.22)) { step = 1 }
                }
                .buttonStyle(KrisPrimaryButtonStyle())
            } else {
                Button {
                    Task {
                        await model.importHealth()
                        onFinish()
                    }
                } label: {
                    Label("允许并开始", systemImage: "heart.text.square.fill")
                }
                .buttonStyle(KrisPrimaryButtonStyle())
                .disabled(model.health.state == .authorizing || model.health.state == .importing)

                Button("暂不连接，先浏览", action: onFinish)
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private func feature(
        _ title: String, detail: String, systemImage: String, tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(KrisTheme.raised, in: RoundedRectangle(cornerRadius: KrisTheme.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: KrisTheme.panelRadius)
                .stroke(KrisTheme.border, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .combine)
    }

    private func permissionRow(
        _ title: String, detail: String, systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(KrisTheme.body)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
