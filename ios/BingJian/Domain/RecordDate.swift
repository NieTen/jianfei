import Foundation

enum RecordDate {
    static func timestamp(for day: String, profile: BodyProfile, now: Date = Date()) -> Date {
        let today = TimeFormat.day(now, timezone: profile.timezone, startMinutes: profile.dayStartMinutes)
        guard day != today,
              let current = TimeFormat.window(today, timezone: profile.timezone, startMinutes: profile.dayStartMinutes),
              let selected = TimeFormat.window(day, timezone: profile.timezone, startMinutes: profile.dayStartMinutes) else { return now }
        // 补记保留当前在统计日内的时刻，避免所有历史记录都落在固定的中午。
        let elapsed = min(max(0, now.timeIntervalSince(current.start)), selected.duration - 0.001)
        return min(now, selected.start.addingTimeInterval(elapsed))
    }
}
