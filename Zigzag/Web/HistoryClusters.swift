import Foundation

/// History the way people remember it: in sittings, and within a sitting by the site they were on. A break with
/// nothing visited (lunch, a meeting) ends a session; pages visited one after another on the same site fold into
/// one cluster, so an afternoon of reading docs is one row, not forty.
enum HistoryClusters {
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
        let part = switch hour {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<21: "evening"
        case 21...: "night"
        default: "late night"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now)).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch days {
        case ...0:
            return switch hour {
            case 21...: "Tonight"
            case ..<5: "Late last night"
            default: "This \(part)"
            }
        case 1:
            return hour >= 21 ? "Last night" : "Yesterday \(part)"
        case 2..<7:
            formatter.dateFormat = "EEEE"
            return "\(formatter.string(from: start)) \(part)"
        default:
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
            formatter.dateFormat = "EEEE"
            let weekday = formatter.string(from: start)
            formatter.dateFormat = sameYear ? "MMMM d" : "MMMM d, yyyy"
            return "\(weekday) \(part), \(formatter.string(from: start))"
        }
    }
}
