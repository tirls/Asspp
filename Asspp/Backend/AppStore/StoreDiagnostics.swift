import Foundation

enum StoreDiagnostics {
    /// NSError userInfo and localized descriptions may contain account names,
    /// signed URLs or Apple response messages. Keep those out of retained logs.
    static func errorSummary(_ error: Error) -> String {
        if let authError = error as? StoreAuthenticationError {
            switch authError {
            case let .signingFailed(stage, reason): return "SAP stage=\(stage) reason=\(reason)"
            case let .serviceResponse(status): return "authentication unexpected-response HTTP=\(status)"
            case .inProgress: return "authentication in-progress"
            case .codeRequired: return "authentication verification-code-required"
            case .invalidCode: return "authentication verification-code-rejected"
            case .invalidConfiguration: return "authentication invalid-configuration"
            case .invalidRedirect: return "authentication invalid-redirect"
            case .rejected: return "authentication rejected"
            case .tooManyAttempts: return "authentication retry-limit"
            }
        }
        return "type=\(String(describing: type(of: error))) code=\((error as NSError).code)"
    }

    static func authenticationResponse(_ response: HTTPURLResponse, data: Data) -> String {
        let rawType = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.lowercased() ?? ""
        let type = ["text/html", "text/xml", "application/xml", "application/x-plist", "application/x-apple-plist"].contains(rawType) ? rawType : "other"
        let location = response.value(forHTTPHeaderField: "Location") == nil ? "absent" : "present"
        return "HTTP \(response.statusCode), \(data.count) bytes, type=\(type), plist=\(StoreProtocol.plist(data) != nil), location=\(location)"
    }
}
