import Foundation

enum StoreAuthenticationError: LocalizedError {
    case inProgress
    case codeRequired
    case invalidCode
    case invalidConfiguration
    case invalidRedirect
    case serviceResponse(Int)
    case signingFailed(stage: String, reason: String)
    case rejected(String, String)
    case tooManyAttempts

    var isInProgress: Bool {
        if case .inProgress = self { return true }
        return false
    }

    var needsCode: Bool {
        switch self {
        case .codeRequired, .invalidCode: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .inProgress:
            String(localized: "Authentication is already in progress. Wait for it to finish.")
        case .codeRequired:
            String(localized: "Enter the verification code sent by Apple, then authenticate again.")
        case .invalidCode:
            String(localized: "The verification code was rejected. Enter a new code and try again.")
        case .invalidConfiguration:
            String(localized: "Apple returned an unsupported login configuration. Update the app and try again.")
        case .invalidRedirect:
            String(localized: "Apple returned an invalid login redirect. No credentials were forwarded.")
        case let .serviceResponse(status):
            String(localized: "Apple's login service returned an unexpected response (HTTP \(status)). This response does not indicate an incorrect password or a missing verification code. Try again later.")
        case let .signingFailed(stage, reason):
            String(localized: "The local authentication signer failed (stage: \(stage), reason: \(reason)).")
        case let .rejected(code, message):
            message.isEmpty ? String(localized: "Apple rejected the login (code: \(code)).") : message
        case .tooManyAttempts:
            String(localized: "Apple's login service exceeded the retry limit. Try again later.")
        }
    }
}

/// Pure protocol rules, shared by production requests and regression checks.
enum StoreAuthenticationProtocol {
    static let authenticationPath = "/WebObjects/MZFinance.woa/wa/authenticate"
    static let nativeAuthenticationPath = "/auth/v1/native/fast/"
    static let defaultAuthenticationURL = "https://auth.itunes.apple.com/auth/v1/native/fast/"

    static func signerFailure(_ error: NSError) -> StoreAuthenticationError {
        let stages = ["load", "initialize", "exchange-1", "exchange-2", "sign"]
        let reasons = ["asset-missing", "asset-integrity", "timeout", "guest-stopped", "unsupported-import", "emulator", "guest-result", "handshake-state", "invalid-input", "runtime"]
        let stage = error.userInfo["AssppSAPStage"] as? String ?? "unknown"
        let reason = error.userInfo["AssppSAPReason"] as? String ?? "runtime"
        return .signingFailed(stage: stages.contains(stage) ? stage : "unknown", reason: reasons.contains(reason) ? reason : "runtime")
    }

    static func authenticationURL(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value), let url = components.url, url.scheme == "https",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased()
        else { throw StoreAuthenticationError.invalidRedirect }
        if host == "auth.itunes.apple.com" {
            guard ["/auth/v1/native", "/auth/v1/native/", "/auth/v1/native/fast", nativeAuthenticationPath].contains(url.path) else {
                throw StoreAuthenticationError.invalidRedirect
            }
            // Match Web's bag normalization, including the required trailing slash.
            components.path = nativeAuthenticationPath
            guard let normalized = components.url else { throw StoreAuthenticationError.invalidRedirect }
            return normalized
        }
        guard (host == "buy.itunes.apple.com" || host.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil),
              url.path == authenticationPath
        else { throw StoreAuthenticationError.invalidRedirect }
        return url
    }

    static func hardwareID(guid: String) throws -> Data {
        guard guid.utf8.count == 12, guid.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw StoreAuthenticationError.invalidConfiguration
        }
        // Web's TextEncoder encodes the identifier, rather than hex-decoding it.
        return Data(guid.utf8)
    }

    static func body(email: String, password: String, code: String, guid: String) throws -> Data {
        let normalizedCode = code.filter { !$0.isWhitespace }
        let fields = [
            ("appleId", email),
            ("attempt", normalizedCode.isEmpty ? "4" : "2"),
            ("guid", guid),
            ("password", password + normalizedCode),
            ("rmp", "0"),
            ("why", "signIn"),
        ]
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let dict = fields.map { "<key>\($0.0)</key><string>\(escape($0.1))</string>" }.joined()
        let xml = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
            "<plist version=\"1.0\">",
            "<dict>\(dict)</dict>",
            "</plist>",
        ].joined(separator: "\n")
        return Data(xml.utf8)
    }

    static func initialAuthenticationURL(_ value: String, guid: String) throws -> URL {
        let endpoint = try authenticationURL(value.isEmpty ? defaultAuthenticationURL : value)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw StoreAuthenticationError.invalidRedirect
        }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "guid" }
        query.append(URLQueryItem(name: "guid", value: guid))
        components.queryItems = query
        guard let url = components.url else { throw StoreAuthenticationError.invalidRedirect }
        return url
    }

    static func retryDelay(attempt: Int, retryAfter: String?) -> Int {
        if let retryAfter, let seconds = Int(retryAfter), seconds > 0 {
            return min(seconds, 30)
        }
        return min(max(attempt, 1) * 10, 30)
    }

    static func retryable(status: Int, data: Data) -> Bool {
        // Only retry unstructured transient responses, never a credential/2FA rejection.
        guard StoreProtocol.plist(data) == nil else { return false }
        return status == 204 || status == 404 || status == 429 || (500 ... 599).contains(status)
    }

    static func rejection(_ plist: [String: Any], code: String) -> StoreAuthenticationError? {
        let failure = StoreProtocol.string(plist["failureType"])
        let message = StoreProtocol.string(plist["customerMessage"])
        if failure.isEmpty, code.isEmpty, message == "MZFinance.BadLogin.Configurator_message" {
            return .codeRequired
        }
        if failure == "5005" {
            return .invalidCode
        }
        if !failure.isEmpty {
            return .rejected(failure, message)
        }
        if message == "Your account is disabled." || message == "MZFinance.AccountDisabled_message" {
            return .rejected("", message)
        }
        return nil
    }

    static func storeIdentifier(_ header: String) -> String {
        String(header.split(whereSeparator: { $0 == "-" || $0 == "," }).first ?? "")
    }
}
