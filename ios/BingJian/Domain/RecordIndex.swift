import Foundation

struct RecordIndex: Sendable {
    var byKind: [String: [AppRecord]]
    var byDay: [String: [AppRecord]]
    var weightDays: [String]
    var weightsByDay: [String: [AppRecord]]
    var profiles: [AppRecord]
    var goal: GoalEntry

    init(records: [AppRecord]) {
        let valid = records.filter { $0.deletedAt == nil }
        byKind = Dictionary(grouping: valid, by: \.kind)
        byDay = Dictionary(grouping: valid, by: \.businessDate)
        profiles = (byKind["profile"] ?? []).sorted { ($0.businessDate, $0.updatedAt) > ($1.businessDate, $1.updatedAt) }
        let weights = (byKind["weight"] ?? []).filter {
            guard let value = $0.decode(WeightEntry.self) else { return false }
            return !value.hidden && !value.sourceDeleted
        }
        weightsByDay = Dictionary(grouping: weights, by: \.businessDate)
        weightDays = weightsByDay.keys.sorted(by: >)
        goal = (byKind["goal"] ?? []).sorted { $0.updatedAt > $1.updatedAt }.first?.decode(GoalEntry.self) ?? GoalEntry()
    }

    func currentProfile(now: Date = Date()) -> BodyProfile {
        profiles.first {
            if let effective = $0.payload["effective_at"]?.string.flatMap(TimeFormat.parse) { return effective <= now }
            return $0.businessDate <= TimeFormat.day(now)
        }?.decode(BodyProfile.self) ?? BodyProfile()
    }

    func forSummary(day: String) -> [AppRecord] {
        var values = byDay[day] ?? []
        var ids = Set(values.map(\.id))
        if let profile = profiles.first(where: { $0.businessDate <= day }), !ids.contains(profile.id) {
            values.append(profile)
            ids.insert(profile.id)
        }
        if let latest = weightDays.first(where: { $0 <= day }) {
            for value in weightsByDay[latest] ?? [] where !ids.contains(value.id) { values.append(value) }
        }
        return values
    }

    func representativeWeight(day: String) -> Double? {
        EnergyCalculator.weight(weightsByDay[day] ?? [], day: day, exactDay: true)
    }
}
