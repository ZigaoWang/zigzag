import Foundation

/// Why a file couldn't be written, in a few plain words, for the cases people can do something about.
enum SaveFailure {
    /// "Not enough space on your Mac", or nil when the error says nothing a person could act on.
    static func reason(for error: Error) -> String? {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteOutOfSpaceError: return String(localized: "Not enough space on your Mac", comment: "Why a file couldn't be saved, said after what failed, like “Couldn’t save the page. Not enough space on your Mac.”")
            case NSFileWriteNoPermissionError: return String(localized: "Zigzag isn’t allowed to save in that folder", comment: "Why a file couldn't be saved, said after what failed, like “Couldn’t save the page. Not enough space on your Mac.”")
            case NSFileWriteVolumeReadOnlyError: return String(localized: "That disk can’t be written to", comment: "Why a file couldn't be saved, said after what failed, like “Couldn’t save the page. Not enough space on your Mac.”")
            default: break
            }
        }
        // The system's own code, on the error or the one beneath it.
        let posix = [error, error.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }.first { $0.domain == NSPOSIXErrorDomain }?.code
        switch posix.map(Int32.init) {
        case ENOSPC, EDQUOT: return String(localized: "Not enough space on your Mac", comment: "Why a file couldn't be saved, said after what failed, like “Couldn’t save the page. Not enough space on your Mac.”")
        case EACCES, EPERM: return String(localized: "Zigzag isn’t allowed to save in that folder", comment: "Why a file couldn't be saved, said after what failed, like “Couldn’t save the page. Not enough space on your Mac.”")
        case EROFS: return String(localized: "That disk can’t be written to", comment: "Why a file couldn't be saved, said after what failed, like “Couldn’t save the page. Not enough space on your Mac.”")
        case EBUSY, ETXTBSY: return String(localized: "Another app is using the file", comment: "Why a file couldn't be saved, said after what failed, like “Couldn’t save the page. Not enough space on your Mac.”")
        default: return nil
        }
    }

    /// "Couldn’t save the page. Not enough space on your Mac." Two sentences, so each ends with a period.
    static func message(_ what: String, _ error: Error) -> String {
        reason(for: error).map { reason in
            String(localized: "\(what). \(reason).", comment: "A save that failed, then why, as two sentences: “Couldn’t save the page. Not enough space on your Mac.”")
        } ?? what
    }
}
