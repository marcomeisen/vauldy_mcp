import Foundation

enum SetupText {
    static func documents(_ count: Int) -> String { "\(count) \(count == 1 ? "Dokument" : "Dokumente")" }
    static func pages(_ count: Int) -> String { "\(count) \(count == 1 ? "Seite" : "Seiten")" }

    static func importTimestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite, date != .distantPast, date != .distantFuture else {
            return "Importzeitpunkt nicht bekannt"
        }
        let style = Date.FormatStyle(date: .numeric, time: .standard, locale: Locale(identifier: "de_DE"),
                                     calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
            .day(.twoDigits).month(.twoDigits).year()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        return "Importiert: " + style.format(date)
    }
}
