import Foundation

enum HistorySection: String, CaseIterable, Identifiable {
    case pinned = "Pinned", today = "Today", yesterday = "Yesterday", earlier = "Earlier"
    var id: String { rawValue }
}

enum ClipboardPresentation {
    static func section(createdAt: Date, pinned: Bool, now: Date = .now, calendar: Calendar = .current) -> HistorySection {
        if pinned { return .pinned }
        if calendar.isDate(createdAt, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(createdAt, inSameDayAs: yesterday) { return .yesterday }
        return .earlier
    }

    static func isWebLink(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return false }
        return true
    }

    static func selection<ID: Equatable>(_ current: ID?, in visibleIDs: [ID]) -> ID? {
        if let current, visibleIDs.contains(current) { return current }
        return visibleIDs.first
    }
}
