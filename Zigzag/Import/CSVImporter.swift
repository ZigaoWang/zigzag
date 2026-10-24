import Foundation

/// Password exports: Apple Passwords, Chrome and its relatives, Firefox, Bitwarden, LastPass, 1Password's CSV.
/// The format is told apart by its header row; fields are found by name, not position.
nonisolated enum CSVImporter {
    enum Format: String, Sendable {
        case applePasswords = "Apple Passwords"
        case chrome = "Chrome"
        case firefox = "Firefox"
        case bitwarden = "Bitwarden"
        case lastPass = "LastPass"
        case onePassword = "1Password"
    }

    /// Column names for each field, in each format (all compared in lower case).
    private struct Columns {
        let url: String
        let username: String
        let password: String
        var title: String?
        var notes: String?
        var otp: String?
    }

    private static let formats: [(Format, Set<String>, Columns)] = [
        (.applePasswords, ["title", "url", "username", "password", "otpauth"], Columns(url: "url", username: "username", password: "password", title: "title", notes: "notes", otp: "otpauth")),
        (.bitwarden, ["login_uri", "login_username", "login_password"], Columns(url: "login_uri", username: "login_username", password: "login_password", title: "name", notes: "notes", otp: "login_totp")),
        (.lastPass, ["url", "username", "password", "extra", "grouping"], Columns(url: "url", username: "username", password: "password", title: "name", notes: "extra", otp: "totp")),
        (.firefox, ["url", "username", "password", "httprealm", "formactionorigin"], Columns(url: "url", username: "username", password: "password")),
        (.onePassword, ["title", "url", "username", "password"], Columns(url: "url", username: "username", password: "password", title: "title", notes: "notes", otp: "otpauth")),
        (.chrome, ["name", "url", "username", "password"], Columns(url: "url", username: "username", password: "password", title: "name", notes: "note")),
    ]

    enum Failure: Error { case unreadable, unknownFormat, empty }

    static func read(_ file: URL) -> Result<(Format, ImportBatch), Failure> {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return .failure(.unreadable)
        }
        return parse(text)
    }

    static func parse(_ text: String) -> Result<(Format, ImportBatch), Failure> {
        let table = rows(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard let header = table.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return .failure(.empty) }
        let names = Set(header)
        guard let (format, _, columns) = formats.first(where: { $0.1.isSubset(of: names) }) else { return .failure(.unknownFormat) }
        func index(_ name: String?) -> Int? { name.flatMap { header.firstIndex(of: $0) } }
        guard let urlIndex = index(columns.url), let userIndex = index(columns.username), let passIndex = index(columns.password) else {
            return .failure(.unknownFormat)
        }
        let notesIndex = index(columns.notes), otpIndex = index(columns.otp)
        var batch = ImportBatch()
        var skipped = 0
        for row in table.dropFirst() where row.count > max(urlIndex, userIndex, passIndex) {
            let password = row[passIndex]
            guard !password.isEmpty, let url = URL(string: row[urlIndex].trimmingCharacters(in: .whitespaces)),
                  url.scheme == "https" || url.scheme == "http" else { skipped += 1; continue }
            var login = ImportBatch.Login(url: url, username: row[userIndex], password: SecretString(password), created: nil)
            if let notesIndex, notesIndex < row.count { login.notes = row[notesIndex] }
            if let otpIndex, otpIndex < row.count { login.otpAuth = row[otpIndex] }
            batch.logins.append(login)
        }
        if skipped > 0 {
            batch.problems.append(ImportProblem(message: "\(skipped) entr\(skipped == 1 ? "y" : "ies") had no website or no password, so \(skipped == 1 ? "it was" : "they were") left out.", fix: .none))
        }
        return batch.logins.isEmpty && skipped == 0 ? .failure(.empty) : .success((format, batch))
    }

    /// RFC 4180: quoted fields may hold commas, quotes ("") and line breaks.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let char = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"" where field.isEmpty: quoted = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n", "\r":
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            default: field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
