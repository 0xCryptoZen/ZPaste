import Foundation

@main
struct PresentationTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 10))!
        let lastNight = now.addingTimeInterval(-20 * 60)
        precondition(ClipboardPresentation.section(createdAt: now, pinned: false, now: now, calendar: calendar) == .today)
        precondition(ClipboardPresentation.section(createdAt: lastNight, pinned: false, now: now, calendar: calendar) == .yesterday)
        precondition(ClipboardPresentation.section(createdAt: now.addingTimeInterval(-3 * 86400), pinned: false, now: now, calendar: calendar) == .earlier)
        precondition(ClipboardPresentation.section(createdAt: lastNight, pinned: true, now: now, calendar: calendar) == .pinned)
        precondition(ClipboardPresentation.isWebLink(" https://example.com/path?q=a "))
        precondition(!ClipboardPresentation.isWebLink("An example: https://example.com"))
        precondition(!ClipboardPresentation.isWebLink("file:///tmp/example"))
        precondition(!ClipboardPresentation.isWebLink("https://example.com\nMore text"))
        precondition(ClipboardPresentation.selection(2, in: [1, 2, 3]) == 2)
        precondition(ClipboardPresentation.selection(2, in: [1, 3]) == 1)
        precondition(ClipboardPresentation.selection(nil as Int?, in: []) == nil)
        print("Presentation tests passed: local date grouping, link detection, and filtered keyboard selection")
    }
}
