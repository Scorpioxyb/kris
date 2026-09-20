import SwiftUI

enum KrisTheme {
    /// Kris 的识别色。亮荧黄只承担品牌与主操作，不参与图表数据编码。
    static let brandLime = Color(red: 0.77, green: 0.95, blue: 0.29)
    static let brandInk = Color(red: 0.04, green: 0.05, blue: 0.04)
    static let accent = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.77, green: 0.95, blue: 0.29, alpha: 1)
        }
        return UIColor(red: 0.28, green: 0.37, blue: 0.02, alpha: 1)
    })
    static let systemAction = Color(uiColor: .systemBlue)
    static let positive = Color(uiColor: .systemGreen)
    static let caution = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    static let readiness = Color(uiColor: .systemBlue)
    static let recovery = Color(uiColor: .systemIndigo)
    static let body = Color(uiColor: .systemTeal)

    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let raised = Color(uiColor: .secondarySystemGroupedBackground)
    static let muted = Color(uiColor: .secondarySystemFill)
    static let border = Color(uiColor: .separator).opacity(0.55)
    static let subtleText = Color(uiColor: .secondaryLabel)
    static let axisText = Color(uiColor: .secondaryLabel)
    static let axisGrid = Color(uiColor: .separator)
    static let panelRadius: CGFloat = 14

    // Compatibility aliases for supporting surfaces that keep their existing behavior.
    static let ink = Color(uiColor: .label)
    static let lime = brandLime
    static let forest = positive
    static let clay = danger
    static let steel = recovery
    static let violet = Color(uiColor: .systemPurple)
    static let sage = muted
}

/// Short, deliberate motion shared by the native interface. Brand motion only
/// confirms that the interface is alive; it never loops in the background.
enum KrisMotion {
    static let enter = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let press = Animation.easeOut(duration: 0.12)
}

/// The mark is intentionally small. It gives the product a recognisable
/// signature without turning every health screen into a branded dashboard.
struct KrisBrandMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var size: CGFloat = 34
    var active: Bool = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(KrisTheme.brandInk)
            Image("KrisLogo")
                .resizable()
                .scaledToFill()
                .padding(size * 0.08)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            if active {
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .stroke(KrisTheme.brandLime.opacity(0.88), lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(hasAppeared ? 1 : 0.86)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            guard !hasAppeared else { return }
            guard !reduceMotion else {
                hasAppeared = true
                return
            }
            withAnimation(KrisMotion.enter) { hasAppeared = true }
        }
        .accessibilityHidden(true)
    }
}

struct KrisPanel<Content: View>: View {
    let fill: Color
    let content: Content

    init(fill: Color = KrisTheme.raised, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: KrisTheme.panelRadius, style: .continuous)
                .stroke(KrisTheme.border, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        // Dashboard cards contain several related values. Capping their type
        // ramp at AX2 keeps the task flow navigable at AX5 without shrinking
        // text below an accessibility size; page titles remain independently
        // scaled and VoiceOver still exposes the complete content.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

struct KrisBrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            KrisBrandMark(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("KRIS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(KrisTheme.accent)
                Text("今日")
                    .font(.title2.weight(.bold))
            }
            Spacer(minLength: 8)
            Text("个人健康")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Kris，今日个人健康")
    }

}

struct KrisPageHeader: View {
    let title: String
    let subtitle: String
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.title2.weight(.bold))
                Spacer(minLength: 8)
                if let status {
                    Text(status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
    }
}

struct KrisPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(KrisTheme.brandInk)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                KrisTheme.brandLime.opacity(configuration.isPressed ? 0.74 : 1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(KrisMotion.press, value: configuration.isPressed)
    }
}

struct KrisOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(KrisTheme.accent)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                KrisTheme.accent.opacity(configuration.isPressed ? 0.12 : 0.06),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

struct KrisSectionHeading: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let trailing: String?

    init(_ title: String, eyebrow: String = "", trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline.weight(.semibold))
                    if let trailing {
                        Text(trailing).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline.weight(.semibold))
                    Spacer()
                    if let trailing {
                        Text(trailing).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct KrisStatusPill: View {
    let title: String
    var tint: Color = KrisTheme.accent
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.10), in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

struct KrisStatusRow: View {
    let title: String
    let detail: String
    let tint: Color
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
