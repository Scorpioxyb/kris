import Foundation

struct ReadinessRules: Codable, Sendable {
    struct Load: Codable, Sendable {
        var lowRatio: Double
        var highRatio: Double
        var lowScore: Double
        var centerScore: Double
        var centerPenalty: Double
        var highStartScore: Double
        var highPenalty: Double
    }
    struct Threshold: Codable, Sendable {
        var minimum: Double
        var state: String
        var label: String
    }
    struct Confidence: Codable, Sendable {
        var highBaselineDays: Int
        var mediumBaselineDays: Int
        var minimumHistoryCount: Int
        var highCompleteComponents: Int
        var mediumCompleteComponents: Int
    }
    struct Safety: Codable, Sendable {
        var reducePainAtOrAbove: Double
        var emergencyFlags: [String]
    }
    var schemaVersion: String
    var algorithm: String
    var weights: [String: Double]
    var componentScales: [String: Double]
    var neutralScore: Double
    var load: Load
    var thresholds: [Threshold]
    var confidence: Confidence
    var safety: Safety
}

struct ReadinessInput: Codable, Sendable {
    var sleep: Double?
    var sleepBaseline: Double?
    var hrv: Double?
    var hrvBaseline: Double?
    var rhr: Double?
    var rhrBaseline: Double?
    var loadRatio: Double?
    var todayStatus: String
    var dataQuality: String
    var baselineDays: Int
    var historyCounts: [String: Int]
    var fresh: Bool
    var pain: Double
    var flags: [String]
}

struct ReadinessResult: Equatable, Sendable {
    var score: Double?
    var state: String
    var label: String
    var confidence: String
    var safetyGate: String
    var components: [String: Double?]
}

struct ReadinessEngine: Sendable {
    let rules: ReadinessRules

    init(data: Data) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        rules = try decoder.decode(ReadinessRules.self, from: data)
        guard rules.schemaVersion == "ReadinessRules.v1" else { throw CocoaError(.coderReadCorrupt) }
    }

    func evaluate(_ input: ReadinessInput) -> ReadinessResult {
        let components: [String: Double?] = [
            "sleep": component(input.sleep, baseline: input.sleepBaseline, scale: rules.componentScales["sleep"]!),
            "hrv": component(input.hrv, baseline: input.hrvBaseline, scale: rules.componentScales["hrv"]!),
            "rhr": component(input.rhr, baseline: input.rhrBaseline, scale: rules.componentScales["rhr"]!),
            "load": loadScore(input.loadRatio),
        ]
        let available = components.compactMap { key, value -> (Double, Double)? in
            guard let value, let weight = rules.weights[key] else { return nil }
            return (value, weight)
        }
        let score: Double? = available.isEmpty ? nil : rounded(
            available.reduce(0) { $0 + $1.0 * $1.1 } / available.reduce(0) { $0 + $1.1 }
        )
        let state: String
        var label: String
        if let score, let threshold = rules.thresholds.first(where: { score >= $0.minimum }) {
            state = threshold.state
            label = threshold.label
            if input.todayStatus == "partial" || input.dataQuality != "pass" { label += "（临时）" }
        } else {
            state = "insufficient_data"
            label = "数据不足，暂不自动调整"
        }
        return ReadinessResult(
            score: score,
            state: state,
            label: label,
            confidence: confidence(input),
            safetyGate: safety(input),
            components: components
        )
    }

    private func component(_ value: Double?, baseline: Double?, scale: Double) -> Double? {
        guard let value, value.isFinite else { return nil }
        guard let baseline else { return rules.neutralScore }
        return clamped(rules.neutralScore + (value - baseline) * scale)
    }

    private func loadScore(_ ratio: Double?) -> Double? {
        guard let ratio else { return nil }
        if ratio > rules.load.highRatio {
            return clamped(rules.load.highStartScore - (ratio - rules.load.highRatio) * rules.load.highPenalty)
        }
        if ratio < rules.load.lowRatio { return rules.load.lowScore }
        return clamped(rules.load.centerScore - abs(ratio - 1) * rules.load.centerPenalty)
    }

    private func confidence(_ input: ReadinessInput) -> String {
        let complete = ["sleep", "hrv", "rhr"].filter {
            input.historyCounts[$0, default: 0] >= rules.confidence.minimumHistoryCount
        }.count
        if input.todayStatus == "final", input.baselineDays >= rules.confidence.highBaselineDays,
           complete >= rules.confidence.highCompleteComponents, input.fresh { return "high" }
        if input.baselineDays >= rules.confidence.mediumBaselineDays,
           complete >= rules.confidence.mediumCompleteComponents, input.fresh { return "medium" }
        return "low"
    }

    private func safety(_ input: ReadinessInput) -> String {
        if !Set(input.flags).isDisjoint(with: Set(rules.safety.emergencyFlags)) { return "stop_and_seek_care" }
        if input.pain >= rules.safety.reducePainAtOrAbove { return "reduce" }
        return "normal"
    }

    private func clamped(_ value: Double) -> Double { rounded(min(100, max(0, value))) }
    private func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
