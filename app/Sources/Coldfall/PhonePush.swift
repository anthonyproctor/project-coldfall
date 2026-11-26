import Foundation
import ColdfallCore

/// Delivers notifications to phones (see WebPush in the core, which decides
/// what is sent and where it may go). The only thing here is the post itself.
final class PhonePush {
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// The allow-list in WebPush checks where a post goes; a redirect would
    /// send it somewhere it never checked, so none is followed.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// COLDFALL_PUSH_DEBUG=1 prints how each send went: the kind, whose
    /// service, and its answer. Never a desk or an address.
    static let debug = ProcessInfo.processInfo.environment["COLDFALL_PUSH_DEBUG"] == "1"

    /// To every device that asked, or to one. Called on the main thread.
    func send(_ kind: WebPush.Kind, desk: String?, waiting: Int, only endpoint: String? = nil) {
        let devices = WebPush.devices().filter { endpoint == nil || $0.endpoint == endpoint }
        guard !devices.isEmpty, let key = WebPush.signingKey() else { return }
        for d in devices {
            guard let out = WebPush.outgoing(to: d, kind: kind, desk: desk, waiting: waiting, key: key),
                  let url = URL(string: out.url) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            for (k, v) in out.headers { req.setValue(v, forHTTPHeaderField: k) }
            req.httpBody = out.body
            session.dataTask(with: req) { data, resp, _ in
                // 0 when the service was never reached.
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let reason = WebPush.reason(data)
                if PhonePush.debug {
                    FileHandle.standardError.write(Data("push: \(kind.rawValue) to \(WebPush.service(d.endpoint) ?? "?"): \(status) \(reason ?? "")\n".utf8))
                }
                DispatchQueue.main.async { WebPush.note(endpoint: d.endpoint, status: status, reason: reason) }
            }.resume()
        }
    }
}
