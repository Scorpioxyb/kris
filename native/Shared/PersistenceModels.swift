import Foundation
import SwiftData

@Model
final class SyncQueueItem {
    @Attribute(.unique) var id: UUID
    var kind: String
    var payload: Data
    var createdAt: Date
    var attempts: Int
    var lastError: String?

    init(id: UUID = UUID(), kind: String, payload: Data, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
        self.attempts = 0
    }
}

@Model
final class CachedPlanRecord {
    @Attribute(.unique) var key: String
    var planId: UUID
    var revision: Int
    var payload: Data
    var isActive: Bool
    var receivedAt: Date

    init(plan: TrainingPlan, payload: Data) {
        self.key = "\(plan.planId.uuidString):\(plan.revision)"
        self.planId = plan.planId
        self.revision = plan.revision
        self.payload = payload
        self.isActive = true
        self.receivedAt = Date()
    }
}

@Model
final class TrainingPlanCandidateRecord {
    @Attribute(.unique) var candidateId: UUID
    var payload: Data
    var status: String
    var createdAt: Date

    init(candidate: TrainingPlanCandidate, payload: Data) {
        self.candidateId = candidate.candidateId
        self.payload = payload
        self.status = candidate.status.rawValue
        self.createdAt = Date()
    }

    init(candidate: TrainingPlanCandidateV2, payload: Data) {
        self.candidateId = candidate.candidateId
        self.payload = payload
        self.status = candidate.status.rawValue
        self.createdAt = DateFormatting.parse(candidate.createdAt) ?? Date()
    }
}

@Model
final class ActiveTrainingRecord {
    @Attribute(.unique) var sessionId: UUID
    var planId: UUID
    var planRevision: Int
    var startedAt: Date
    var draftPayload: Data

    init(sessionId: UUID, planId: UUID, planRevision: Int, startedAt: Date, draftPayload: Data) {
        self.sessionId = sessionId
        self.planId = planId
        self.planRevision = planRevision
        self.startedAt = startedAt
        self.draftPayload = draftPayload
    }
}

@Model
final class ArchivedSessionRecord {
    @Attribute(.unique) var sessionId: UUID
    var payload: Data
    var endedAt: Date
    var macArchivedAt: Date?

    init(sessionId: UUID, payload: Data, endedAt: Date) {
        self.sessionId = sessionId
        self.payload = payload
        self.endedAt = endedAt
    }
}

@Model
final class WatchEventRecord {
    @Attribute(.unique) var eventId: UUID
    var receivedAt: Date
    var payload: Data?
    var appliedAt: Date?

    init(eventId: UUID, receivedAt: Date = Date(), payload: Data? = nil, appliedAt: Date? = nil) {
        self.eventId = eventId
        self.receivedAt = receivedAt
        self.payload = payload
        self.appliedAt = appliedAt
    }
}

@Model
final class HealthAnchorRecord {
    @Attribute(.unique) var metric: String
    var anchorData: Data
    var updatedAt: Date

    init(metric: String, anchorData: Data, updatedAt: Date = Date()) {
        self.metric = metric
        self.anchorData = anchorData
        self.updatedAt = updatedAt
    }
}

@Model
final class CachedHealthSampleRecord {
    @Attribute(.unique) var sampleUuid: String
    var metric: String
    var startAt: String
    var payload: Data

    init(sample: HealthSampleContract, payload: Data) {
        self.sampleUuid = sample.sampleUuid
        self.metric = sample.metric.rawValue
        self.startAt = sample.startAt
        self.payload = payload
    }
}
