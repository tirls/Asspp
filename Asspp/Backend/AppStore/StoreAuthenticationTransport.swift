import Foundation

/// Login requests use separate connections but retain one private cookie jar.
final class StoreAuthenticationTransport {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_: URLSession, task _: URLSessionTask,
                        willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }

    let cookieStorage: HTTPCookieStorage

    init() {
        cookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage!
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpCookieStorage = cookieStorage
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = request
        // HTTP/1.1 also explicitly disables keep-alive; each session owns its HTTP/2 pool.
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw StoreAuthenticationError.serviceResponse(0)
        }
        return (data, response)
    }
}
