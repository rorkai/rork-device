import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(FoundationNetworking) || canImport(Darwin)
/// Prevents URLSession requests from following redirects to plaintext HTTP.
///
/// Initial request URLs are validated by their callers. Centralizing redirect
/// handling keeps archive downloads and Apple TSS requests on authenticated
/// transport after the first response.
class HTTPSOnlyURLSessionDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    /// Returns the proposed redirect only when it preserves HTTPS transport.
    static func approvedRedirectRequest(
        _ request: URLRequest
    ) -> URLRequest? {
        guard request.url?.scheme?.lowercased() == "https" else {
            return nil
        }
        return request
    }

    /// Rejects redirects that would downgrade an authenticated HTTPS request.
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.approvedRedirectRequest(request))
    }
}
#endif
