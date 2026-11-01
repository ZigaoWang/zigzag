import Foundation

/// Why a file couldn't be written, in a few plain words, for the cases people can do something about.
enum SaveFailure {
    /// "Not enough space on your Mac", or nil when the error says nothing a person could act on.
    static func reason(for error: Error) -> String? {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteOutOfSpaceError: return "Not enough space on your Mac"
            case NSFileWriteNoPermissionError: return "Zigzag isn’t allowed to save in that folder"
            case NSFileWriteVolumeReadOnlyError: return "That disk can’t be written to"
            default: break
            }
        }
        // The system's own code, on the error or the one beneath it.
        let posix = [error, error.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }.first { $0.domain == NSPOSIXErrorDomain }?.code
        switch posix.map(Int32.init) {
        case ENOSPC, EDQUOT: return "Not enough space on your Mac"
        case EACCES, EPERM: return "Zigzag isn’t allowed to save in that folder"
        case EROFS: return "That disk can’t be written to"
        case EBUSY, ETXTBSY: return "Another app is using the file"
        default: return nil
        }
    }

    /// "Couldn’t save the page. Not enough space on your Mac."
    static func message(_ what: String, _ error: Error) -> String {
        reason(for: error).map { "\(what). \($0)." } ?? what
    }
}
