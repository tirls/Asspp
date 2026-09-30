import Foundation

/// Browser-style HTTP/1.1 and Mbed TLS, with an account's private cookie jar.
final class StoreAuthenticationTransport {
    let cookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage!
    private let caBundleURL: URL?

    init(caBundleURL: URL? = Bundle.main.resourceURL?.appendingPathComponent("AuthenticationTLS/cacert.pem")) {
        self.caBundleURL = caBundleURL
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, let caBundleURL,
              FileManager.default.fileExists(atPath: caBundleURL.path) else {
            throw StoreAuthenticationError.invalidConfiguration
        }
        var request = request
        if let cookies = cookieStorage.cookies(for: url), !cookies.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        let transfer = CurlAuthenticationClient()
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try transfer.performRequest(request, caBundlePath: caBundleURL.path)
            }.value
        } onCancel: {
            transfer.cancel()
        }
        try Task.checkCancellation()
        var fields: [String: String] = [:]
        for pair in result.headers where pair.count == 2 {
            if pair[0] == "set-cookie" {
                // Parse separately: Expires dates contain commas.
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": pair[1]], for: url)
                cookieStorage.setCookies(cookies, for: url, mainDocumentURL: nil)
            } else {
                fields[pair[0]] = pair[1]
            }
        }
        guard result.httpVersion == 2,
              let response = HTTPURLResponse(url: url, statusCode: result.statusCode,
                                             httpVersion: "HTTP/1.1", headerFields: fields) else {
            throw StoreAuthenticationError.serviceResponse(result.statusCode)
        }
        return (result.data, response)
    }
}
