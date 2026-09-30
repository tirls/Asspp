import Foundation

@main
struct AuthenticationProtocolChecks {
    static func main() throws {
        let auth = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
        _ = try StoreAuthenticationProtocol.authenticationURL(auth)
        _ = try StoreAuthenticationProtocol.authenticationURL(auth.replacingOccurrences(of: "buy.", with: "p25-buy."))
        let initial = try StoreAuthenticationProtocol.initialAuthenticationURL(auth + "?guid=old&x=1&guid=duplicate", guid: "024153535050")
        let query = URLComponents(url: initial, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.filter { $0.name == "guid" }.map { $0.value } == ["024153535050"])
        precondition(query.contains { $0.name == "x" && $0.value == "1" })
        for invalid in [
            auth.replacingOccurrences(of: "https:", with: "http:"),
            auth.replacingOccurrences(of: "buy.itunes.apple.com", with: "buy.itunes.apple.com.attacker.example"),
            auth.replacingOccurrences(of: "buy.itunes.apple.com", with: "attacker-buy.itunes.apple.com"),
            auth.replacingOccurrences(of: "buy.itunes.apple.com", with: "user:password@buy.itunes.apple.com"),
            auth.replacingOccurrences(of: "buy.itunes.apple.com", with: "buy.itunes.apple.com:8080"),
            auth.replacingOccurrences(of: "/wa/authenticate", with: "/wa/buyProduct"),
            auth + "#fragment",
        ] {
            do {
                _ = try StoreAuthenticationProtocol.authenticationURL(invalid)
                fatalError("Accepted an unsafe credential redirect")
            } catch is StoreAuthenticationError {}
        }
        precondition(StoreAuthenticationProtocol.storeIdentifier("143441-1,29") == "143441")
        precondition(StoreAuthenticationProtocol.storeIdentifier("143465-19,32") == "143465")
        // Login's Foundation cookie jar and ApplePackage use different domain forms.
        let cookie = HTTPCookie(properties: [
            .name: "synthetic-session", .value: "fixture", .domain: ".itunes.apple.com",
            .path: "/WebObjects/", .secure: "TRUE",
        ])!
        precondition(StoreProtocol.storeCookieDomain(cookie.domain) == "itunes.apple.com")
        precondition(StoreProtocol.storeCookieDomain(".P25-BUY.ITUNES.APPLE.COM") == "p25-buy.itunes.apple.com")
        precondition(StoreProtocol.storeCookieDomain(nil) == nil)
        precondition(StoreProtocol.storeCookieDomain(".") == "")
        for invalid in [nil, "", ".", "attacker.example", "itunes.apple.com.attacker.example"] as [String?] {
            precondition(StoreProtocol.foundationCookieDomain(invalid) == nil)
        }
        let restored = HTTPCookie(properties: [
            .name: cookie.name, .value: cookie.value, .path: cookie.path, .secure: "TRUE",
            .domain: StoreProtocol.foundationCookieDomain("itunes.apple.com")!,
        ])!
        let jar = URLSessionConfiguration.ephemeral.httpCookieStorage!
        jar.setCookie(restored)
        precondition(jar.cookies(for: URL(string: "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct")!)?.contains(where: { $0.name == cookie.name }) == true)
        for url in ["http://p25-buy.itunes.apple.com/WebObjects/", "https://p25-buy.itunes.apple.com/other/", "https://attacker.example/WebObjects/"] {
            precondition(jar.cookies(for: URL(string: url)!)?.contains(where: { $0.name == cookie.name }) != true)
        }
        let body = try StoreAuthenticationProtocol.body(email: "test@example.invalid", password: "&<测试>", code: " 123 456\n", guid: "024153535050")
        let hardware = try StoreAuthenticationProtocol.hardwareID(guid: "024153535050")
        precondition(hardware == Data("024153535050".utf8) && hardware.count == 12)
        for invalid in ["024153", "02415353505x", "02415353505000"] {
            do {
                _ = try StoreAuthenticationProtocol.hardwareID(guid: invalid)
                fatalError("Accepted an invalid SAP identifier")
            } catch is StoreAuthenticationError {}
        }
        let initialBody = try StoreAuthenticationProtocol.body(email: "test@example.invalid", password: "fixture", code: "", guid: "024153535050")
        precondition(StoreProtocol.plist(initialBody)?["attempt"] as? String == "4")
        let fixture = try Data(contentsOf: URL(fileURLWithPath: "Resources/Tests/WebLoginBody.xml"))
        precondition(body == fixture, "Native request bytes differ from the Web fixture")
        let plist = StoreProtocol.plist(body)!
        precondition(plist["password"] as? String == "&<测试>123456")
        precondition(plist["attempt"] as? String == "2")
        precondition(plist["guid"] as? String == "024153535050")
        let wrapped = Data(("<Document><Protocol>" + String(data: body, encoding: .utf8)! + "</Protocol></Document>").utf8)
        precondition(StoreProtocol.plist(wrapped)?["guid"] as? String == "024153535050")
        let binary = try PropertyListSerialization.data(fromPropertyList: ["failureType": "5005"], format: .binary, options: 0)
        precondition(StoreProtocol.plist(binary)?["failureType"] as? String == "5005")
        precondition(StoreAuthenticationProtocol.rejection(["customerMessage": "MZFinance.BadLogin.Configurator_message"], code: "")?.needsCode == true)
        precondition(StoreAuthenticationProtocol.rejection(["failureType": 5005], code: "123456")?.needsCode == true)
        precondition(StoreAuthenticationProtocol.rejection(["failureType": "-5000", "customerMessage": "Bad credentials"], code: "")?.needsCode == false)
        precondition(StoreAuthenticationError.serviceResponse(403).needsCode == false)
        for status in [204, 404, 429, 500, 503] {
            precondition(StoreAuthenticationProtocol.retryable(status: status, data: Data()))
        }
        for status in [200, 301, 302, 400, 401, 403] {
            precondition(!StoreAuthenticationProtocol.retryable(status: status, data: Data()))
        }
        // Never retry a parsed rejection even when the HTTP layer says 5xx.
        precondition(!StoreAuthenticationProtocol.retryable(status: 500, data: binary))
        precondition(!StoreAuthenticationProtocol.retryable(status: 429, data: binary))
        precondition(StoreAuthenticationProtocol.retryDelay(attempt: 1, retryAfter: nil) == 10)
        precondition(StoreAuthenticationProtocol.retryDelay(attempt: 2, retryAfter: "invalid") == 20)
        precondition(StoreAuthenticationProtocol.retryDelay(attempt: 1, retryAfter: "12") == 12)
        precondition(StoreAuthenticationProtocol.retryDelay(attempt: 1, retryAfter: "9999") == 30)
        precondition(StoreAuthenticationProtocol.retryDelay(attempt: 1, retryAfter: "-10") == 10)
        let diagnostic = HTTPURLResponse(url: initial, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8", "Location": "https://secret-fixture.invalid/private",
            "Set-Cookie": "secret-fixture", "X-Request-ID": "secret-fixture",
        ])!
        let summary = StoreDiagnostics.authenticationResponse(diagnostic, data: Data("secret-fixture".utf8))
        precondition(summary.contains("HTTP 301") && summary.contains("type=text/html") && summary.contains("location=present"))
        precondition(!summary.contains("secret-fixture"))
        precondition(StoreDiagnostics.errorSummary(StoreAuthenticationError.serviceResponse(403)).contains("HTTP=403"))
        let signerError = NSError(domain: "Asspp.SAP", code: 1, userInfo: ["AssppSAPStage": "initialize", "AssppSAPReason": "emulator", NSLocalizedDescriptionKey: "secret-fixture"])
        let safeError = StoreAuthenticationProtocol.signerFailure(signerError)
        precondition(safeError.localizedDescription.contains("initialize"))
        precondition(StoreDiagnostics.errorSummary(safeError) == "SAP stage=initialize reason=emulator")
        precondition(!safeError.localizedDescription.contains("secret-fixture"))
        let unknownError = NSError(domain: "Asspp.SAP", code: 1, userInfo: ["AssppSAPStage": "secret-fixture", "AssppSAPReason": "secret-fixture"])
        precondition(StoreDiagnostics.errorSummary(StoreAuthenticationProtocol.signerFailure(unknownError)) == "SAP stage=unknown reason=runtime")
        print("Authentication protocol regression checks passed.")
    }
}
