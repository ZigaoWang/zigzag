import Foundation

/// History the way people remember it: in sittings, and within a sitting by the site they were on. A break with
/// nothing visited (lunch, a meeting) ends a session; pages visited one after another on the same site fold into
/// one cluster, so an afternoon of reading docs is one row, not forty.
nonisolated enum HistoryClusters {
    /// How long nothing is visited before the next page starts a new session.
    static let sessionGap: TimeInterval = 40 * 60

    struct Cluster {
        let host: String
        var entries: [HistoryEntry]
    }

    struct Session {
        var clusters: [Cluster]
        var entries: [HistoryEntry] { clusters.flatMap(\.entries) }
        /// The first and last visit.
        var start: Date { clusters.last!.entries.last!.lastVisit }
        var end: Date { clusters[0].entries[0].lastVisit }
    }

    /// Groups entries into sessions, newest first, and each session into runs of the same site. Order comes from the
    /// entries' last visit, so search results (ranked by how often they're visited) group the same way as browsing.
    /// A session never runs past midnight, so its title can name one day.
    static func group(_ entries: [HistoryEntry], calendar: Calendar = .current) -> [Session] {
        var sessions: [Session] = []
        var previous: HistoryEntry?
        for entry in entries.sorted(by: { $0.lastVisit > $1.lastVisit }) {
            let host = HistoryStore.normalizedHost(entry.url)
            if let previous, continues(previous, with: entry, calendar: calendar) {
                let s = sessions.count - 1
                if sessions[s].clusters.last!.host == host {
                    sessions[s].clusters[sessions[s].clusters.count - 1].entries.append(entry)
                } else {
                    sessions[s].clusters.append(Cluster(host: host, entries: [entry]))
                }
            } else {
                sessions.append(Session(clusters: [Cluster(host: host, entries: [entry])]))
            }
            previous = entry
        }
        return sessions
    }

    /// Whether `entry`, visited before `last`, belongs to the same session: the same day, without a long break.
    static func continues(_ last: HistoryEntry, with entry: HistoryEntry, calendar: Calendar = .current) -> Bool {
        last.lastVisit.timeIntervalSince(entry.lastVisit) <= sessionGap && calendar.isDate(last.lastVisit, inSameDayAs: entry.lastVisit)
    }

    /// A session's name, from the day and the time of day it began: "This afternoon", "Yesterday evening",
    /// "Last night", "Tuesday morning", "Sunday afternoon, October 18".
    static func title(startingAt start: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: start)
        let part: Part = switch hour {
        case 5..<12: .morning
        case 12..<17: .afternoon
        case 17..<21: .evening
        case 21...: .night
        default: .lateNight
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now)).day ?? 0
        // Each name whole, so a language can put the day and the time of day in its own order.
        switch days {
        case ...0:
            return switch part {
            case .night: String(localized: "Tonight", comment: "Name of a History session that began today.")
            case .lateNight: String(localized: "Late last night", comment: "Name of a History session that began today. Between midnight and 5 AM.")
            case .morning: String(localized: "This morning", comment: "Name of a History session that began today.")
            case .afternoon: String(localized: "This afternoon", comment: "Name of a History session that began today.")
            case .evening: String(localized: "This evening", comment: "Name of a History session that began today.")
            }
        case 1:
            return switch part {
            case .night: String(localized: "Last night", comment: "Name of a History session that began yesterday.")
            case .lateNight: String(localized: "Yesterday late night", comment: "Name of a History session that began yesterday. Between midnight and 5 AM.")
            case .morning: String(localized: "Yesterday morning", comment: "Name of a History session that began yesterday.")
            case .afternoon: String(localized: "Yesterday afternoon", comment: "Name of a History session that began yesterday.")
            case .evening: String(localized: "Yesterday evening", comment: "Name of a History session that began yesterday.")
            }
        case 2..<7:
            let weekday = formatter("EEEE", calendar: calendar).string(from: start)
            return switch part {
            case .morning: String(localized: "\(weekday) morning", comment: "Name of a History session that began in the last week. The placeholder is the weekday, like “Tuesday”.")
            case .afternoon: String(localized: "\(weekday) afternoon", comment: "Name of a History session that began in the last week. The placeholder is the weekday, like “Tuesday”.")
            case .evening: String(localized: "\(weekday) evening", comment: "Name of a History session that began in the last week. The placeholder is the weekday, like “Tuesday”.")
            case .night: String(localized: "\(weekday) night", comment: "Name of a History session that began in the last week. The placeholder is the weekday, like “Tuesday”.")
            case .lateNight: String(localized: "\(weekday) late night", comment: "Name of a History session that began in the last week. The placeholder is the weekday, like “Tuesday”. Between midnight and 5 AM.")
            }
        default:
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
            let weekday = formatter("EEEE", calendar: calendar).string(from: start)
            // "October 18" or "October 18, 2025"; "10月18日" or "2025年12月12日".
            let date = formatter(sameYear ? "MMMMd" : "yMMMMd", calendar: calendar).string(from: start)
            return switch part {
            case .morning: String(localized: "\(weekday) morning, \(date)", comment: "Name of an older History session: the weekday, then the date, like “Sunday afternoon, October 18”.")
            case .afternoon: String(localized: "\(weekday) afternoon, \(date)", comment: "Name of an older History session: the weekday, then the date, like “Sunday afternoon, October 18”.")
            case .evening: String(localized: "\(weekday) evening, \(date)", comment: "Name of an older History session: the weekday, then the date, like “Sunday afternoon, October 18”.")
            case .night: String(localized: "\(weekday) night, \(date)", comment: "Name of an older History session: the weekday, then the date, like “Sunday afternoon, October 18”.")
            case .lateNight: String(localized: "\(weekday) late night, \(date)", comment: "Name of an older History session: the weekday, then the date, like “Sunday afternoon, October 18”. Between midnight and 5 AM.")
            }
        }
    }

    /// A formatter for each template, kept: making one takes long, and a search can name hundreds of sessions.
    private static func formatter(_ template: String, calendar: Calendar) -> DateFormatter {
        let key = [template, Words.dates.identifier, calendar.identifier.debugDescription, calendar.timeZone.identifier].joined(separator: " ")
        return formattersLock.withLock {
            if let kept = formatters[key] { return kept }
            let formatter = DateFormatter()
            formatter.locale = Words.dates
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            formatters[key] = formatter
            return formatter
        }
    }

    private static let formattersLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    /// The time of day a session began.
    private enum Part { case morning, afternoon, evening, night, lateNight }
}
