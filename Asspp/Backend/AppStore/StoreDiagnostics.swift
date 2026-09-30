import Foundation

enum StoreDiagnostics {
    /// NSError userInfo and localized descriptions may contain account names,
    /// signed URLs or Apple response messages. Keep those out of retained logs.
    static func errorSummary(_ error: Error) -> String {
        if let error = error as? StoreAuthenticationError {
            switch error {
            case let .serviceResponse(status): return "authentication unexpected-response HTTP=\(status)"
            case .signingFailed: return "authentication signer-failed"
            case .invalidConfiguration: return "authentication invalid-configuration"
            case .invalidRedirect: return "authentication invalid-redirect"
            case .codeRequired: return "authentication code-required"
            case .invalidCode: return "authentication invalid-code"
            case .rejected: return "authentication rejected"
            case .tooManyAttempts: return "authentication too-many-attempts"
            }
        }
        return "type=\(String(describing: type(of: error))) code=\((error as NSError).code)"
    }
}
