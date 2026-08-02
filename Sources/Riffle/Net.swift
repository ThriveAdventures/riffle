import Foundation

// All service calls go through an ephemeral session: no cookies, no cache,
// no CFNetwork storage database, and therefore no periodic power
// assertions from cache flushes.
enum Net {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
}
