import Foundation

@main
struct AuthenticationTransportChecks {
    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let transport = StoreAuthenticationTransport()
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
        print("Authentication transport checks passed: fresh connections, retained cookies/body, manual redirect.")
    }
}
