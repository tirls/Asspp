import Foundation

@main
struct AuthenticationTransportChecks {
    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let ca = URL(fileURLWithPath: CommandLine.arguments[2])
        let publicCA = URL(fileURLWithPath: CommandLine.arguments[3])
        let transport = StoreAuthenticationTransport(caBundleURL: ca)
        precondition(CurlAuthenticationClient.runtimeDescription().contains("mbedTLS/3.6.6"))
        var request = URLRequest(url: base.appendingPathComponent("login"))
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic-body".utf8)
        request.setValue("synthetic-signature", forHTTPHeaderField: "X-Apple-ActionSignature")
        let (_, first) = try await transport.send(request)
        precondition(first.statusCode == 204)
        let (_, redirect) = try await transport.send(request)
        precondition(redirect.statusCode == 302)
        precondition(redirect.value(forHTTPHeaderField: "Location") == "/pod")
        request.url = base.appendingPathComponent("pod")
        let (data, final) = try await transport.send(request)
        precondition(final.statusCode == 200 && data == Data("fixture-success".utf8))
        precondition(transport.cookieStorage.cookies?.contains { $0.name == "synthetic-session" } == true)
        precondition(transport.cookieStorage.cookies?.contains { $0.name == "second-session" } == true)
        do {
            _ = try await StoreAuthenticationTransport(caBundleURL: publicCA).send(URLRequest(url: base))
            fatalError("Accepted an untrusted TLS certificate")
        } catch let error as NSError {
            precondition(error.domain == "Asspp.CurlTransport" && error.code == 60)
        }
        print("Authentication transport checks passed: Mbed TLS, HTTP/1.1, verified certificates, retained cookies/body, manual redirect.")
    }
}
