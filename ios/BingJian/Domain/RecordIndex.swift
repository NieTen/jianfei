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

    /// 只重建受影响的类型和日期；历史正文与未涉及的桶继续复用。
    func replacing(_ previous: [AppRecord], with updates: [AppRecord]) -> RecordIndex {
        var result = self
        let ids = Set(previous.map(\.id)).union(updates.map(\.id))
        let valid = updates.filter { $0.deletedAt == nil }
        let kinds = Set(previous.map(\.kind)).union(updates.map(\.kind))
        let days = Set(previous.map(\.businessDate)).union(updates.map(\.businessDate))
        for kind in kinds {
            let values = Self.merging(byKind[kind] ?? [], updates: valid.filter { $0.kind == kind }, removing: ids)
            result.byKind[kind] = values.isEmpty ? nil : values
        }
        for day in days {
            let values = Self.merging(byDay[day] ?? [], updates: valid.filter { $0.businessDate == day }, removing: ids)
            result.byDay[day] = values.isEmpty ? nil : values
        }
        let weightDays = Set(previous.filter { $0.kind == "weight" }.map(\.businessDate))
            .union(updates.filter { $0.kind == "weight" }.map(\.businessDate))
        let weights = valid.filter {
            guard $0.kind == "weight", let value = $0.decode(WeightEntry.self) else { return false }
            return !value.hidden && !value.sourceDeleted
        }
        for day in weightDays {
            let values = Self.merging(weightsByDay[day] ?? [], updates: weights.filter { $0.businessDate == day }, removing: ids)
            result.weightsByDay[day] = values.isEmpty ? nil : values
        }
        if !weightDays.isEmpty { result.weightDays = result.weightsByDay.keys.sorted(by: >) }
        if kinds.contains("profile") {
            result.profiles = (result.byKind["profile"] ?? []).sorted { ($0.businessDate, $0.updatedAt) > ($1.businessDate, $1.updatedAt) }
        }
        if kinds.contains("goal") {
            result.goal = (result.byKind["goal"] ?? []).sorted { $0.updatedAt > $1.updatedAt }.first?.decode(GoalEntry.self) ?? GoalEntry()
        }
        return result
    }

    /// 现有数组沿用数据库日期倒序/id正序，少量更新排序后线性合并，避免整库再次排序。
    static func merging(_ previous: [AppRecord], updates: [AppRecord], removing ids: Set<String>) -> [AppRecord] {
        let inserted = updates.sorted(by: precedes)
        var result: [AppRecord] = []
        result.reserveCapacity(previous.count + inserted.count)
        var next = 0
        for record in previous where !ids.contains(record.id) {
            while next < inserted.count, precedes(inserted[next], record) {
                result.append(inserted[next]); next += 1
            }
            result.append(record)
        }
        result.append(contentsOf: inserted.dropFirst(next))
        return result
    }

    private static func precedes(_ left: AppRecord, _ right: AppRecord) -> Bool {
        left.businessDate == right.businessDate ? left.id < right.id : left.businessDate > right.businessDate
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
