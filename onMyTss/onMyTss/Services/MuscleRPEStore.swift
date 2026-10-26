import Foundation
import SwiftData

@MainActor
struct MuscleRPEStore {
    let context: ModelContext
    var clock: () -> Date = Date.init

    @discardableResult
    func save(region: Region, side: BodySide, rpe: Int, observedAt: Date) throws -> MuscleRPERecord {
        guard side != .unspecified, MuscleEffortGrade(rpe: rpe) != nil,
              observedAt <= clock() else { throw V2StoreError.invalidObservation }
        let regionRaw = region.rawValue
        let sideRaw = side.rawValue
        var query = FetchDescriptor<MuscleRPERecord>(predicate: #Predicate {
            $0.regionRaw == regionRaw && $0.sideRaw == sideRaw && $0.observedAt == observedAt
        }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        query.fetchLimit = 1
        let existing = try context.fetch(query).first
        let record = existing ?? MuscleRPERecord(regionRaw: regionRaw, sideRaw: sideRaw,
                                                  rpe: rpe, observedAt: observedAt)
        record.rpe = rpe
        record.updatedAt = clock()
        if existing == nil { context.insert(record) }
        try context.save()
        return record
    }
}
