import SwiftUI
import SwiftData
import os

enum AppPerformanceTrace {
    private static let log = OSLog(
        subsystem: "com.albertdaisy.kriscoach",
        category: "performance"
    )

    static func mark(_ phase: String) {
        os_signpost(.event, log: log, name: "launch_phase", "%{public}@", phase)
    }
}

@main
struct KrisCoachApp: App {
    private static let onboardingKey = "kriscoach.onboarding.v1.completed"

    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    @State private var onboardingCompleted: Bool
    private let testingColorScheme: ColorScheme?

    init() {
        AppPerformanceTrace.mark("process_start")
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("-ui-testing")
        let forcesOnboarding = arguments.contains("-onboarding-fixture")
        testingColorScheme = isUITesting && arguments.contains("-force-dark-appearance")
            ? .dark : nil
        let alreadyUsesHealth = UserDefaults.standard.bool(
            forKey: "kriscoach.health.initial-import-complete"
        )
        _model = State(initialValue: AppModel(inMemory: isUITesting))
        _onboardingCompleted = State(initialValue:
            !forcesOnboarding && (
                isUITesting
                || alreadyUsesHealth
                || UserDefaults.standard.bool(forKey: Self.onboardingKey)
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingCompleted {
                    RootTabView()
                } else {
                    OnboardingView {
                        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
                        withAnimation(.easeInOut(duration: 0.24)) {
                            onboardingCompleted = true
                        }
                    }
                }
            }
                .environment(model)
                .preferredColorScheme(testingColorScheme)
                .onAppear {
                    AppPerformanceTrace.mark("first_frame")
                }
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "kriscoach" else { return }
                    switch url.host?.lowercased() {
                    case "training":
                        model.selectedTab = 2
                    default:
                        return
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await model.handleAppBecameActive() }
                    case .inactive, .background:
                        model.handleAppBecameInactive()
                    @unknown default:
                        break
                    }
                }
        }
        .modelContainer(model.container)
    }
}
