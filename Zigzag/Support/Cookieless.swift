import Foundation

nonisolated extension URLSessionConfiguration {
    /// A session that keeps no cookies and sends none. `.ephemeral` alone still keeps the cookies a site sets, in
    /// memory, for as long as the session lives: every request after the first would carry them, whichever
    /// profile or window it was made for.
    static var cookieless: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.dropsCookies()
        return configuration
    }

    func dropsCookies() {
        httpCookieStorage = nil
        httpShouldSetCookies = false
        httpCookieAcceptPolicy = .never
    }
}
