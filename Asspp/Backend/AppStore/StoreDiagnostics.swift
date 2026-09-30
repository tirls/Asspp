import Foundation

enum StoreDiagnostics {
    /// NSError userInfo and localized descriptions may contain account names,
    /// signed URLs or Apple response messages. Keep those out of retained logs.
    static func errorSummary(_ error: Error) -> String {
        if let authError = error as? StoreAuthenticationError, case let .signingFailed(stage, reason) = authError {
            return "SAP stage=\(stage) reason=\(reason)"
        }
        return "type=\(String(describing: type(of: error))) code=\((error as NSError).code)"
    }
}
