import Foundation
import HealthKit
import Observation

private final class ObserverCompletion: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}

private struct SendableHealthSamples: @unchecked Sendable {
    var samples: [HKSample]
    var unit: HKUnit
}

private struct PreparedHealthPayload: Sendable {
    var samples: [HealthSampleContract]
    var localSamples: [HealthSampleContract]
    var coverage: [MetricCoverage]
}

private struct PreparedReadiness: Sendable {
    var readiness: LocalReadinessSnapshot
    var today: DailyHealthMetrics
    var trends: SnapshotTrends
}

private struct SampleIndexes: Sendable {
    let workoutSamples: [HealthSampleContract]
    let metricFreshness: [HealthMetricFreshness]
}

private struct CachedHealthPresentation: Codable {
    var readiness: LocalReadinessSnapshot
    var today: DailyHealthMetrics
    var trends: SnapshotTrends
    var lastImportAt: Date?
}

struct HealthRefreshAccumulator: Sendable {
    private(set) var metrics: Set<HealthMetric> = []

    var isEmpty: Bool { metrics.isEmpty }

    mutating func enqueue(_ metric: HealthMetric) {
        metrics.insert(metric)
    }

    mutating func takeAll() -> [HealthMetric] {
        let queued = HealthMetric.allCases.filter(metrics.contains)
        metrics.removeAll(keepingCapacity: true)
        return queued
    }
}

@MainActor
@Observable
final class HealthKitService {
    enum State: String, Sendable, Equatable { case idle, authorizing, importing, ready, noData, unavailable, failed }
    enum FailureAction: String, Sendable, Equatable { case permissions, reinstall, retry }

    struct ImportIssue: Identifiable, Hashable, Sendable {
        var metric: HealthMetric
        var label: String
        var message: String
        var id: HealthMetric { metric }
    }

    private(set) var state: State = .idle
    private(set) var isImporting = false
    private(set) var lastImportAt: Date?
    private(set) var lastError: String?
    private(set) var localReadiness: LocalReadinessSnapshot?
    private(set) var todayMetrics = DailyHealthMetrics()
    private(set) var localTrends = SnapshotTrends(
        latestBody: nil, latestCompleteHealthDay: nil, recovery: nil, fatLoss: nil,
        weight: nil, bodyFat: nil, sleep: nil
    )
    private(set) var totalImportCount = 0
    private(set) var completedImportCount = 0
    private(set) var successfulImportCount = 0
    private(set) var importedSampleCount = 0
    private(set) var currentImportLabel: String?
    private(set) var importIssues: [ImportIssue] = []
    private(set) var importedCounts: [HealthMetric: Int] = [:]
    private(set) var failureAction: FailureAction?
    var onBatch: (@MainActor (HealthBatch) async -> Void)?
    /// Called once after a full or incremental import has drained. Consumers
    /// should refresh derived views here instead of once per HealthKit batch.
    var onImportFinished: (@MainActor () -> Void)?

    // UI tests use the same local presentation path as a real HealthKit
    // import. This keeps the standalone-app contract from depending on a
    // remote coach snapshot just to render evidence fixtures.
    func installReadinessFixture(_ snapshot: CoachSnapshot) {
        localReadiness = LocalReadinessSnapshot(
            readiness: snapshot.readiness,
            evidence: snapshot.evidence,
            dataGaps: snapshot.dataGaps,
            generatedAt: Date()
        )
        localTrends = snapshot.trends
        state = .ready
    }

    private let store = HKHealthStore()
    private let calendar = Calendar.autoupdatingCurrent
    private var observers: [HKObserverQuery] = []
    private var samplesByUUID: [String: HealthSampleContract] = [:]
    // Presentation indexes avoid scanning the full HealthKit cache during
    // every SwiftUI body pass. The dictionary remains the source of truth.
    private var indexedWorkoutSamples: [HealthSampleContract] = []
    private var indexedMetricFreshness: [HealthMetricFreshness] = []
    private var localLoadRatio: Double?
    private var isRefreshingAllMetrics = false
    private(set) var interactiveTrainingActive = false
    private var pendingObserverRefreshes = HealthRefreshAccumulator()
    private var pendingObserverCompletions: [ObserverCompletion] = []
    private var observerRefreshTask: Task<Void, Never>?
    private let anchorPrefix = "kriscoach.health.anchor."
    private let initialImportKey = "kriscoach.health.initial-import-complete"
    private let metricBackfillPrefix = "kriscoach.health.backfill-complete."
    private let localAnalysisBackfillPrefix = "kriscoach.health.local-analysis-v2."
    private let workoutMetadataBackfillKey = "kriscoach.health.workout-metadata-v1.complete"
    private let presentationCacheKey = "kriscoach.health.presentation.v1"
    private let readinessEngine: ReadinessEngine?

    var importProgress: Double {
        totalImportCount == 0 ? 0 : Double(completedImportCount) / Double(totalImportCount)
    }

    var cachedSampleCount: Int { samplesByUUID.count }
    var automaticUpdatesEnabled: Bool {
        UserDefaults.standard.bool(forKey: initialImportKey)
    }
    var localWorkoutSamples: [HealthSampleContract] { indexedWorkoutSamples }
    var metricFreshness: [HealthMetricFreshness] { indexedMetricFreshness }

    init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "readiness.v1", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            readinessEngine = try? ReadinessEngine(data: data)
        } else {
            readinessEngine = nil
        }
        if let data = UserDefaults.standard.data(forKey: presentationCacheKey),
           let cached = try? ContractCoding.decoder.decode(
               CachedHealthPresentation.self, from: data
           ) {
            localReadiness = cached.readiness
            todayMetrics = cached.today
            localTrends = cached.trends
            lastImportAt = cached.lastImportAt
            state = .ready
        }
    }

    private var quantityTypes: [(HealthMetric, HKQuantityTypeIdentifier, HKUnit)] {
        [
            (.hrvSdnn, .heartRateVariabilitySDNN, .secondUnit(with: .milli)),
            (.restingHeartRate, .restingHeartRate, HKUnit.count().unitDivided(by: .minute())),
            (.stepCount, .stepCount, .count()),
            (.activeEnergy, .activeEnergyBurned, .kilocalorie()),
            (.basalEnergy, .basalEnergyBurned, .kilocalorie()),
            (.bodyMass, .bodyMass, .gramUnit(with: .kilo)),
            (.bodyFatPercentage, .bodyFatPercentage, .percent()),
            (.leanBodyMass, .leanBodyMass, .gramUnit(with: .kilo)),
            (.bmi, .bodyMassIndex, .count()),
            (.vo2Max, .vo2Max, HKUnit(from: "ml/kg*min")),
        ]
    }

    func requestAuthorizationAndImport(forceBackfill: Bool = false) async {
        guard HKHealthStore.isHealthDataAvailable() else { state = .unavailable; return }
        guard state != .authorizing, state != .importing else { return }
        resetImportStatus()
        state = .authorizing
        let types = readTypes
        do {
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType()], read: Set<HKObjectType>(types)
            )
            let initial = !UserDefaults.standard.bool(forKey: initialImportKey)
            registerObserversIfNeeded(types)
            await runFullRefresh(initial: initial, forceBackfill: forceBackfill)
            await enableBackgroundDelivery(types)
        } catch {
            state = .failed
            let presentation = Self.present(error)
            lastError = presentation.message
            failureAction = presentation.action
            currentImportLabel = nil
        }
    }

    func resumeIfPreviouslyEnabled() async {
        await refreshAutomatically()
    }

    func beginObservingIfPreviouslyEnabled() {
        guard automaticUpdatesEnabled, HKHealthStore.isHealthDataAvailable() else { return }
        registerObserversIfNeeded(readTypes)
    }

    func setInteractiveTrainingActive(_ active: Bool) {
        guard interactiveTrainingActive != active else { return }
        interactiveTrainingActive = active
        if !active { scheduleObserverRefreshIfNeeded() }
    }

    /// HealthKit observer delivery is the normal update path. A foreground
    /// refresh closes any gap if iOS deferred a background delivery.
    func refreshAutomatically() async {
        guard HKHealthStore.isHealthDataAvailable() else { state = .unavailable; return }
        guard Self.shouldRefreshAutomatically(
            hasImportedBefore: automaticUpdatesEnabled, state: state,
            interactiveTrainingActive: interactiveTrainingActive
        ) else { return }
        let types = readTypes
        registerObserversIfNeeded(types)
        await runFullRefresh(initial: false, forceBackfill: false)
        // Background delivery registration is durable system configuration,
        // not part of the interactive refresh. Let the first frame remain
        // responsive while iOS accepts these registrations.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.enableBackgroundDelivery(types)
        }
    }

    func restoreCachedSamples(_ samples: [HealthSampleContract]) async {
        // Normalize and merge off the main actor. Assigning the completed
        // dictionary once is substantially cheaper than doing tens of
        // thousands of individual writes while the first screen is live.
        let existing = samplesByUUID
        let merged = await Task.detached(priority: .utility) {
            var result = existing
            result.reserveCapacity(existing.count + samples.count)
            for sample in samples {
                var normalized = sample
                if normalized.metric == .bodyFatPercentage,
                   normalized.value > 0, normalized.value <= 1 {
                    normalized.value *= 100
                }
                result[normalized.sampleUuid] = normalized
            }
            return result
        }.value
        samplesByUUID = merged
        await rebuildSampleIndexes()
        await recomputeLocalReadiness()
        AppPerformanceTrace.mark("health_cache_restored")
    }

    func updateLocalTrainingLoadRatio(_ ratio: Double?) async {
        guard localLoadRatio != ratio else { return }
        localLoadRatio = ratio
        await recomputeLocalReadiness()
    }

    nonisolated static func resolvedState(
        successful: Int, failedMetrics: Set<HealthMetric>, usefulSampleCount: Int? = nil
    ) -> State {
        let core: Set<HealthMetric> = [.sleep, .hrvSdnn, .restingHeartRate]
        if successful == 0 || core.isSubset(of: failedMetrics) { return .failed }
        if usefulSampleCount == 0 { return .noData }
        return .ready
    }

    nonisolated static func shouldRefreshAutomatically(
        hasImportedBefore: Bool, state: State,
        interactiveTrainingActive: Bool = false
    ) -> Bool {
        hasImportedBefore && !interactiveTrainingActive
            && state != .authorizing && state != .importing
    }

    nonisolated static func shouldEnableAutomaticUpdates(
        successfulMetricQueries: Int
    ) -> Bool {
        successfulMetricQueries > 0
    }

    nonisolated static func needsWorkoutMetadataBackfill(
        metric: HealthMetric, hasCompletedBackfill: Bool
    ) -> Bool {
        metric == .workout && !hasCompletedBackfill
    }

    private var readTypes: Set<HKSampleType> {
        Set<HKSampleType>(quantityTypes.compactMap {
            HKObjectType.quantityType(forIdentifier: $0.1)
        })
        .union([HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!])
        .union([HKObjectType.workoutType()])
    }

    private func runFullRefresh(initial: Bool, forceBackfill: Bool) async {
        guard !isRefreshingAllMetrics else { return }
        isRefreshingAllMetrics = true
        isImporting = true
        defer {
            isImporting = false
            onImportFinished?()
        }
        resetImportStatus()
        state = .importing
        let result = await importAll(initial: initial, days: 42, forceBackfill: forceBackfill)
        if result.successful > 0 { lastImportAt = Date() }
        await rebuildSampleIndexes()
        await recomputeLocalReadiness()
        // Authorization is a capability, not a sample-count check. A new user
        // may legitimately have no samples yet; keep observers active so the
        // first future HealthKit sample arrives without another manual import.
        if Self.shouldEnableAutomaticUpdates(successfulMetricQueries: result.successful) {
            UserDefaults.standard.set(true, forKey: initialImportKey)
        }
        state = Self.resolvedState(
            successful: result.successful,
            failedMetrics: Set(importIssues.map(\.metric)),
            usefulSampleCount: samplesByUUID.count
        )
        currentImportLabel = nil
        if state == .noData {
            lastError = "42 天查询已完成，但 HealthKit 没有返回可读取样本。请检查本 App 的健康权限后重新回填。"
            failureAction = .permissions
        } else if importIssues.isEmpty {
            lastError = nil
        } else {
            lastError = "\(importIssues.count) 项未导入，其余数据已保留，可自动重试。"
        }
        isRefreshingAllMetrics = false
        scheduleObserverRefreshIfNeeded()
    }

    private func resetImportStatus() {
        lastError = nil
        totalImportCount = HealthMetric.allCases.count
        completedImportCount = 0
        successfulImportCount = 0
        importedSampleCount = 0
        currentImportLabel = nil
        importIssues = []
        importedCounts = [:]
        failureAction = nil
    }

    private func importAll(initial: Bool, days: Int, forceBackfill: Bool) async -> (successful: Int, failed: Int) {
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: Date()))!
        for (metric, identifier, unit) in quantityTypes {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            await importMetric(
                type: type, metric: metric, unit: unit, initial: initial,
                forceBackfill: forceBackfill, historyStart: start
            )
        }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            await importMetric(
                type: sleep, metric: .sleep, unit: .second(), initial: initial,
                forceBackfill: forceBackfill, historyStart: start
            )
        }
        await importMetric(
            type: HKObjectType.workoutType(), metric: .workout, unit: .second(),
            initial: initial, forceBackfill: forceBackfill, historyStart: start
        )
        return (successfulImportCount, importIssues.count)
    }

    private func importMetric(
        type: HKSampleType, metric: HealthMetric, unit: HKUnit,
        initial: Bool, forceBackfill: Bool, historyStart: Date
    ) async {
        currentImportLabel = metricLabel(metric)
        do {
            let backfillKey = metricBackfillPrefix + metric.rawValue
            let localKey = localAnalysisBackfillPrefix + metric.rawValue
            let needsBoundedFallback = !UserDefaults.standard.bool(forKey: backfillKey)
            let needsLocalAnalysisBackfill = [.basalEnergy, .vo2Max, .workout].contains(metric)
                && !UserDefaults.standard.bool(forKey: localKey)
            let needsWorkoutMetadataBackfill = Self.needsWorkoutMetadataBackfill(
                metric: metric,
                hasCompletedBackfill: UserDefaults.standard.bool(forKey: workoutMetadataBackfillKey)
            )
            let boundedBackfill = initial || forceBackfill || needsBoundedFallback
                || needsLocalAnalysisBackfill || needsWorkoutMetadataBackfill
            let count = try await fetch(
                type: type, metric: metric, unit: unit,
                start: boundedBackfill ? historyStart : nil,
                useAnchor: !boundedBackfill
            )
            importedCounts[metric] = count
            importedSampleCount += count
            successfulImportCount += 1
            let hasCachedWorkout = samplesByUUID.values.contains { $0.metric == .workout }
            if needsWorkoutMetadataBackfill && (count > 0 || !hasCachedWorkout) {
                UserDefaults.standard.set(true, forKey: workoutMetadataBackfillKey)
            }
            // HealthKit intentionally does not reveal read-denied status. An
            // empty result must stay eligible for bounded backfill so granting
            // permission later cannot strand the previous anchor at "now".
            if count > 0 {
                UserDefaults.standard.set(true, forKey: backfillKey)
                if needsLocalAnalysisBackfill {
                    UserDefaults.standard.set(true, forKey: localKey)
                }
            }
        } catch {
            let presentation = Self.present(error)
            importIssues.append(ImportIssue(metric: metric, label: metricLabel(metric), message: presentation.message))
            failureAction = dominant(failureAction, presentation.action)
        }
        completedImportCount += 1
    }

    private func registerObserversIfNeeded(_ types: Set<HKSampleType>) {
        guard observers.isEmpty else { return }
        observers = types.map { type in
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard let self else { completion(); return }
                let completion = ObserverCompletion(completion)
                Task { @MainActor in
                    guard error == nil else {
                        if let error {
                            let presentation = Self.present(error)
                            self.lastError = presentation.message
                            self.failureAction = presentation.action
                        }
                        completion.call()
                        return
                    }
                    self.enqueueObserverRefresh(type: type, completion: completion)
                }
            }
            store.execute(query)
            return query
        }
    }

    private func enableBackgroundDelivery(_ types: Set<HKSampleType>) async {
        for type in types {
            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
            } catch {
                // The foreground anchored query remains usable when iOS does
                // not support background delivery for an individual type.
            }
        }
    }

    private func enqueueObserverRefresh(type: HKSampleType, completion: ObserverCompletion) {
        guard let metric = metric(for: type) else {
            completion.call()
            return
        }
        pendingObserverRefreshes.enqueue(metric)
        if interactiveTrainingActive || isRefreshingAllMetrics {
            completion.call()
            return
        }
        pendingObserverCompletions.append(completion)
        scheduleObserverRefreshIfNeeded()
    }

    private func scheduleObserverRefreshIfNeeded() {
        guard !interactiveTrainingActive, !isRefreshingAllMetrics,
              !pendingObserverRefreshes.isEmpty, observerRefreshTask == nil else { return }
        observerRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            await self.drainObserverRefreshes()
        }
    }

    private func drainObserverRefreshes() async {
        defer {
            observerRefreshTask = nil
            if !interactiveTrainingActive { scheduleObserverRefreshIfNeeded() }
        }
        guard !interactiveTrainingActive, !isRefreshingAllMetrics else { return }
        let metrics = pendingObserverRefreshes.takeAll()
        let completions = pendingObserverCompletions
        pendingObserverCompletions.removeAll(keepingCapacity: true)
        await incrementalImport(metrics: metrics)
        completions.forEach { $0.call() }
    }

    private func incrementalImport(metrics: [HealthMetric]) async {
        guard !metrics.isEmpty else { return }
        isImporting = true
        defer {
            isImporting = false
            onImportFinished?()
        }
        var importedAnyMetric = false
        for metric in metrics {
            do {
                if let definition = quantityTypes.first(where: { $0.0 == metric }),
                   let type = HKQuantityType.quantityType(forIdentifier: definition.1) {
                    _ = try await fetch(
                        type: type, metric: metric, unit: definition.2,
                        start: nil, useAnchor: true
                    )
                } else if metric == .sleep,
                          let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
                    _ = try await fetch(
                        type: type, metric: .sleep, unit: .second(),
                        start: nil, useAnchor: true
                    )
                } else if metric == .workout {
                    _ = try await fetch(
                        type: HKObjectType.workoutType(), metric: .workout, unit: .second(),
                        start: nil, useAnchor: true
                    )
                } else {
                    continue
                }
                importedAnyMetric = true
            } catch {
                let presentation = Self.present(error)
                lastError = presentation.message
                failureAction = presentation.action
            }
        }
        if importedAnyMetric {
            lastImportAt = Date()
            await rebuildSampleIndexes()
            await recomputeLocalReadiness()
        }
    }

    private func rebuildSampleIndexes() async {
        let samples = Array(samplesByUUID.values)
        let indexes = await Task.detached(priority: .utility) {
            var counts: [HealthMetric: Int] = [:]
            var latest: [HealthMetric: Date] = [:]
            var workouts: [HealthSampleContract] = []
            workouts.reserveCapacity(samples.reduce(into: 0) { count, sample in
                if sample.metric == .workout { count += 1 }
            })

            for sample in samples {
                counts[sample.metric, default: 0] += 1
                if let end = DateFormatting.parse(sample.endAt),
                   end > (latest[sample.metric] ?? .distantPast) {
                    latest[sample.metric] = end
                }
                if sample.metric == .workout { workouts.append(sample) }
            }

            return SampleIndexes(
                workoutSamples: workouts,
                metricFreshness: HealthMetric.allCases.map { metric in
                    HealthMetricFreshness(
                        metric: metric,
                        sampleCount: counts[metric, default: 0],
                        latestAt: latest[metric]
                    )
                }
            )
        }.value
        indexedWorkoutSamples = indexes.workoutSamples
        indexedMetricFreshness = indexes.metricFreshness
    }

    private func metric(for type: HKSampleType) -> HealthMetric? {
        if let quantity = type as? HKQuantityType,
           let definition = quantityTypes.first(where: {
               HKQuantityType.quantityType(forIdentifier: $0.1) == quantity
           }) {
            return definition.0
        }
        if type == HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { return .sleep }
        if type == HKObjectType.workoutType() { return .workout }
        return nil
    }

    nonisolated static func present(_ error: Error) -> (message: String, action: FailureAction) {
        let raw = error.localizedDescription
        let lowered = raw.lowercased()
        if lowered.contains("entitlement") || lowered.contains("com.apple.developer.healthkit") {
            return ("当前安装包缺少 HealthKit 能力，请安装包含健康权限的正确签名版本。", .reinstall)
        }
        if lowered.contains("authorization") || lowered.contains("not authorized")
            || lowered.contains("protected health") || lowered.contains("health data is restricted") {
            return ("系统没有允许读取健康数据。请检查本 App 的健康权限后重试。", .permissions)
        }
        return ("健康数据读取暂时失败，请稍后重试。\n\(raw)", .retry)
    }

    private func dominant(_ current: FailureAction?, _ incoming: FailureAction) -> FailureAction {
        if current == .reinstall || incoming == .reinstall { return .reinstall }
        if current == .permissions || incoming == .permissions { return .permissions }
        return .retry
    }

    private func fetch(type: HKSampleType, metric: HealthMetric, unit: HKUnit, start: Date?, useAnchor: Bool) async throws -> Int {
        let predicate = start.map { HKQuery.predicateForSamples(withStart: $0, end: nil) }
        let previous = useAnchor ? loadAnchor(metric) : nil
        let result: ([HKSample], HKQueryAnchor?) = try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: previous, limit: HKObjectQueryNoLimit) {
                _, samples, _, anchor, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (samples ?? [], anchor)) }
            }
            store.execute(query)
        }
        if let anchor = result.1 { saveAnchor(anchor, metric: metric) }
        let transferable = SendableHealthSamples(samples: result.0, unit: unit)
        let prepared = await Task.detached(priority: .utility) {
            Self.prepare(
                transferable, metric: metric,
                calendar: Calendar.autoupdatingCurrent, now: Date()
            )
        }.value
        let samples = prepared.samples
        guard !samples.isEmpty else { return 0 }
        let batch = HealthBatch(
            batchId: UUID(), deviceId: Self.deviceID, createdAt: DateFormatting.iso(), anchor: nil,
            samples: samples, coverage: prepared.coverage
        )
        for sample in prepared.localSamples { samplesByUUID[sample.sampleUuid] = sample }
        for chunk in batch.chunked() { await onBatch?(chunk) }
        return samples.count
    }

    private func recomputeLocalReadiness() async {
        guard let readinessEngine else { return }
        let samples = Array(samplesByUUID.values)
        let now = Date()
        let loadRatio = localLoadRatio
        let prepared = await Task.detached(priority: .utility) {
            PreparedReadiness(
                readiness: HealthReducers.localReadiness(
                    samples: samples, engine: readinessEngine,
                    loadRatio: loadRatio,
                    now: now, calendar: Calendar.autoupdatingCurrent
                ),
                today: HealthReducers.dailyMetrics(
                    samples: samples, now: now, calendar: Calendar.autoupdatingCurrent
                ),
                trends: HealthReducers.dailyTrends(
                    samples: samples, engine: readinessEngine,
                    now: now, calendar: Calendar.autoupdatingCurrent
                )
            )
        }.value
        localReadiness = prepared.readiness
        todayMetrics = prepared.today
        localTrends = prepared.trends
        cachePresentation()
    }

    private func cachePresentation() {
        guard let localReadiness,
              let data = try? ContractCoding.encoder.encode(
                  CachedHealthPresentation(
                      readiness: localReadiness,
                      today: todayMetrics,
                      trends: localTrends,
                      lastImportAt: lastImportAt
                  )
              ) else { return }
        UserDefaults.standard.set(data, forKey: presentationCacheKey)
    }

    nonisolated private static func prepare(
        _ input: SendableHealthSamples,
        metric: HealthMetric,
        calendar: Calendar,
        now: Date
    ) -> PreparedHealthPayload {
        let samples = input.samples.compactMap {
            contract($0, metric: metric, unit: input.unit)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let dates = Set(samples.compactMap { DateFormatting.parse($0.startAt) }.map(formatter.string(from:)))
        let coverage = dates.map {
            MetricCoverage(
                date: $0, metric: metric.rawValue,
                status: $0 == today ? .partial : .complete,
                reason: $0 == today ? "当天尚未结束" : nil
            )
        }
        let localSamples: [HealthSampleContract]
        switch metric {
        case .sleep, .hrvSdnn, .restingHeartRate,
             .bodyMass, .bodyFatPercentage, .leanBodyMass, .bmi:
            localSamples = samples
        case .stepCount, .activeEnergy:
            // 首次查询本身已经限制为 42 天。保留这段窗口，手机端才能在
            // 没有 Mac 的情况下生成步数与活动能量趋势，而不只显示今天。
            localSamples = samples
        case .basalEnergy, .vo2Max, .workout:
            localSamples = samples
        }
        return PreparedHealthPayload(samples: samples, localSamples: localSamples, coverage: coverage)
    }

    private func metricLabel(_ metric: HealthMetric) -> String {
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

    nonisolated private static func contract(
        _ sample: HKSample, metric: HealthMetric, unit: HKUnit
    ) -> HealthSampleContract? {
        if metric == .sleep, let category = sample as? HKCategorySample {
            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            ]
            guard asleepValues.contains(category.value) else { return nil }
        }
        let value: Double
        if let quantity = sample as? HKQuantitySample {
            value = quantity.quantity.doubleValue(for: unit)
        } else {
            value = sample.endDate.timeIntervalSince(sample.startDate)
        }
        var metadata: [String: JSONValue]?
        if let workout = sample as? HKWorkout {
            var values: [String: JSONValue] = [
                "activity_name": .string(workoutActivityLabel(workout.workoutActivityType)),
                "activity_type": .number(Double(workout.workoutActivityType.rawValue)),
                "source_name": .string(sample.sourceRevision.source.name),
            ]
            if let device = sample.device {
                values["device_name"] = .string(
                    device.name ?? device.model ?? device.manufacturer ?? "Apple Watch"
                )
            }
            if let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? NSNumber {
                values["indoor"] = .bool(indoor.boolValue)
            }
            if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
               let energy = workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                values["active_kcal"] = .number(energy)
            }
            if let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
               let statistics = workout.statistics(for: heartRateType) {
                let unit = HKUnit.count().unitDivided(by: .minute())
                if let average = statistics.averageQuantity()?.doubleValue(for: unit) {
                    values["average_heart_rate"] = .number(average)
                }
                if let maximum = statistics.maximumQuantity()?.doubleValue(for: unit) {
                    values["maximum_heart_rate"] = .number(maximum)
                }
            }
            for identifier in workoutDistanceIdentifiers(workout.workoutActivityType) {
                guard let type = HKQuantityType.quantityType(forIdentifier: identifier),
                      let distance = workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .meter()),
                      distance > 0 else { continue }
                values["distance_km"] = .number(distance / 1_000)
                break
            }
            metadata = values
        }
        let normalizedValue = metric == .bodyFatPercentage && value > 0 && value <= 1
            ? value * 100 : value
        return HealthSampleContract(
            sampleUuid: sample.uuid.uuidString, metric: metric,
            startAt: DateFormatting.iso(sample.startDate), endAt: DateFormatting.iso(sample.endDate),
            value: normalizedValue, unit: unit.unitString, source: sample.sourceRevision.source.name,
            metadata: metadata
        )
    }

    nonisolated private static func workoutActivityLabel(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .traditionalStrengthTraining: "传统力量训练"
        case .functionalStrengthTraining: "功能性力量训练"
        case .running: "跑步"
        case .walking: "步行"
        case .hiking: "徒步"
        case .swimming: "游泳"
        case .cycling: "骑行"
        case .elliptical: "椭圆机"
        case .rowing: "划船"
        case .stairClimbing, .stairs, .stepTraining: "楼梯训练"
        case .mixedCardio: "混合有氧"
        case .crossTraining: "交叉训练"
        case .highIntensityIntervalTraining: "高强度间歇"
        case .coreTraining: "核心训练"
        case .flexibility: "柔韧训练"
        case .yoga: "瑜伽"
        case .pilates: "普拉提"
        case .jumpRope: "跳绳"
        case .dance: "舞蹈"
        case .cooldown, .preparationAndRecovery: "恢复训练"
        case .badminton: "羽毛球"
        case .basketball: "篮球"
        case .soccer: "足球"
        case .tableTennis: "乒乓球"
        case .tennis: "网球"
        case .pickleball: "匹克球"
        default: "其他训练"
        }
    }

    nonisolated private static func workoutDistanceIdentifiers(
        _ type: HKWorkoutActivityType
    ) -> [HKQuantityTypeIdentifier] {
        switch type {
        case .running, .walking, .hiking:
            [.distanceWalkingRunning]
        case .cycling, .handCycling:
            [.distanceCycling]
        case .swimming:
            [.distanceSwimming]
        case .wheelchairRunPace, .wheelchairWalkPace:
            [.distanceWheelchair]
        default:
            [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
        }
    }

    private func loadAnchor(_ metric: HealthMetric) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: anchorPrefix + metric.rawValue) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor, metric: HealthMetric) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: anchorPrefix + metric.rawValue)
        }
    }

    static var deviceID: String {
        if let value = KeychainStore.read(account: "device-id") { return value }
        let value = UUID().uuidString
        try? KeychainStore.save(value, account: "device-id")
        return value
    }
}
