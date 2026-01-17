import Foundation
import ObjectiveC

/// URLSession wrapper that uses HTTP/2 to avoid QUIC MTU issues.
/// HTTP/3 is disabled until Apple exposes proper PMTUD configuration.
final class ResilientSession: Sendable {
    private let session: URLSession
    
    init(configuration: URLSessionConfiguration = .default) {
        let config = configuration
        // Disable HTTP/3 (QUIC) - Apple's implementation doesn't handle MTU issues gracefully.
        // QUIC fails hard with EMSGSIZE on networks with non-standard MTU (VPNs, etc).
        // HTTP/2 over TCP fragments properly and just works.
        let selector = NSSelectorFromString("set_allowsHTTP3:")
        if let method = class_getInstanceMethod(type(of: config), selector) {
            let impl = method_getImplementation(method)
            typealias SetBoolFunc = @convention(c) (Any, Selector, Bool) -> Void
            let setter = unsafeBitCast(impl, to: SetBoolFunc.self)
            setter(config, selector, false)
        }
        self.session = URLSession(configuration: config)
    }

    /// For testing - inject a mock session
    init(session: URLSession) {
        self.session = session
    }
    
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
    
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await session.bytes(for: request)
    }
}
