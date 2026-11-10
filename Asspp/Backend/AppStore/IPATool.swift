//
//  IPATool.swift
//  Asspp
//
//  Store authentication and download requests through ipatool's local Store AMD
//  and kbsync implementation. Available only in builds that ran
//  Resources/Scripts/build.ipatool.sh (iOS devices); other builds keep the
//  ApplePackage store path.
//

import ApplePackage
import Foundation

#if ASSPP_IPATOOL
    import IPAToolBridge
#endif

/// The ipatool session data Apple returns at sign-in.
struct IPAToolAccount: Codable, Hashable, Sendable {
    var email: String
    var passwordToken: String?
    var directoryServicesIdentifier: String?
    var name: String?
    var storeFront: String?
    var password: String?
    var pod: String?
}

enum IPAToolError: LocalizedError, Equatable {
    case unavailable
    case authCodeRequired
    case passwordTokenExpired
    case licenseRequired
    case canceled
    case failed(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "This build does not include the ipatool Store engine.")
        case .authCodeRequired:
            String(localized: "A verification code is required. Enter the code sent to your trusted device.")
        case .passwordTokenExpired:
            String(localized: "The account session expired. Sign in to this account again.")
        case .licenseRequired:
            String(localized: "This account does not have a license for this app. Acquire a license first.")
        case .canceled:
            String(localized: "The request was canceled.")
        case let .failed(_, message):
            message
        }
    }
}

enum IPATool {
    struct ResolvedDownload: Decodable {
        struct Signature: Decodable {
            var id: Int64
            var data: Data
        }

        var url: String
        var md5: String?
        var sinfs: [Signature]
        var metadata: Data
        var platform: String
    }

    struct VersionList: Decodable {
        var versions: [String]
        var latest: String
    }

    struct VersionInfo: Decodable {
        var displayVersion: String
        var releaseDate: String
    }

    static var isAvailable: Bool {
        #if ASSPP_IPATOOL
            true
        #else
            false
        #endif
    }

    /// State lives in Application Support, outside Documents and iCloud backups.
    static let stateDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("IPATool", isDirectory: true)
    }()

    static func configure(deviceIdentifier: String) {
        guard isAvailable else { return }
        do {
            try prepareStateDirectory()
            struct Request: Encodable {
                var stateDirectory: String
                var deviceIdentifier: String
            }
            let _: Empty = try invoke("configure", Request(stateDirectory: stateDirectory.path, deviceIdentifier: deviceIdentifier))
            logger.info("ipatool Store engine configured")
            startLogPump()
        } catch {
            logger.error("ipatool Store engine configuration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Operations

    static func login(email: String, password: String, code: String) async throws -> IPAToolAccount {
        struct Request: Encodable {
            var email: String
            var password: String
            var authCode: String
        }
        var account: IPAToolAccount = try await run("login", Request(email: email, password: password, authCode: code))
        // Re-authentication after the session expires needs the password again.
        account.password = password
        if account.email.isEmpty {
            account.email = email
        }
        return account
    }

    static func resolveDownload(account: IPAToolAccount, package: AppStore.AppPackage) async throws -> DownloadOutput {
        let resolved: ResolvedDownload = try await run(
            "resolveDownload",
            ProductRequest(account: account, package: package, versionID: package.externalVersionID),
        )
        return try downloadOutput(resolved, email: account.email)
    }

    static func versions(account: IPAToolAccount, package: AppStore.AppPackage) async throws -> [String] {
        let list: VersionList = try await run("listVersions", ProductRequest(account: account, package: package, versionID: nil))
        return list.versions
    }

    static func versionMetadata(account: IPAToolAccount, package: AppStore.AppPackage, versionID: String) async throws -> VersionMetadata {
        let info: VersionInfo = try await run("versionMetadata", ProductRequest(account: account, package: package, versionID: versionID))
        guard let date = ISO8601DateFormatter().date(from: info.releaseDate) else {
            throw IPAToolError.failed(code: "invalidResponse", message: String(localized: "Apple returned incomplete version information."))
        }
        return VersionMetadata(displayVersion: info.displayVersion, releaseDate: date)
    }

    static func purchase(account: IPAToolAccount, package: AppStore.AppPackage) async throws {
        let _: Empty = try await run("purchase", ProductRequest(account: account, package: package, versionID: nil))
    }

    static func forget(email: String) {
        guard isAvailable else { return }
        struct Request: Encodable { var email: String }
        do {
            let _: Empty = try invoke("forget", Request(email: email))
        } catch {
            logger.error("ipatool failed to remove account state: \(error.localizedDescription)")
        }
    }

    // MARK: - Request shapes

    private struct Empty: Decodable {}

    private struct ProductRequest: Encodable {
        struct App: Encodable {
            var id: Int64
            var bundleId: String
        }

        var requestId = UUID().uuidString
        var account: IPAToolAccount
        var app: App
        var platform: String
        var versionId: String?

        init(account: IPAToolAccount, package: AppStore.AppPackage, versionID: String?) {
            self.account = account
            app = App(id: package.software.id, bundleId: package.software.bundleID)
            platform = switch package.entityType ?? .iPhone {
            case .iPhone: "iphone"
            case .iPad: "ipad"
            case .appleTV: "appletv"
            }
            versionId = versionID.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private static func downloadOutput(_ resolved: ResolvedDownload, email: String) throws -> DownloadOutput {
        let invalid = IPAToolError.failed(
            code: "invalidPackage",
            message: String(localized: "Apple returned incomplete or mismatched package information."),
        )
        guard let url = URL(string: resolved.url), url.scheme == "https" || url.scheme == "http", url.host != nil,
              !resolved.sinfs.isEmpty,
              var metadata = try PropertyListSerialization.propertyList(from: resolved.metadata, format: nil) as? [String: Any],
              let version = metadata["bundleShortVersionString"] as? String,
              let build = metadata["bundleVersion"] as? String
        else { throw invalid }
        metadata["apple-id"] = email
        metadata["userName"] = email
        return try DownloadOutput(
            downloadURL: resolved.url,
            sinfs: resolved.sinfs.map { Sinf(id: $0.id, sinf: $0.data) },
            bundleShortVersionString: version,
            bundleVersion: build,
            iTunesMetadata: PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0),
        )
    }

    // MARK: - Transport

    private struct Response<Output: Decodable>: Decodable {
        struct Failure: Decodable {
            var code: String
            var message: String
        }

        var ok: Bool
        var result: Output?
        var error: Failure?
    }

    private static func prepareStateDirectory() throws {
        var directory = stateDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path,
            )
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    /// Runs a blocking bridge call off the cooperative pool and forwards
    /// Swift task cancellation to the Go context.
    private static func run<Output: Decodable>(_ operation: String, _ request: some Encodable) async throws -> Output {
        guard isAvailable else { throw IPAToolError.unavailable }
        let body = try JSONEncoder().encode(request)
        let requestID = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["requestId"] as? String
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result<Output, Error> {
                        try decode(operation: operation, response: call(operation: operation, body: body))
                    })
                }
            }
        } onCancel: {
            if let requestID { cancel(requestID: requestID) }
        }
    }

    private static func invoke<Output: Decodable>(_ operation: String, _ request: some Encodable) throws -> Output {
        guard isAvailable else { throw IPAToolError.unavailable }
        return try decode(operation: operation, response: call(operation: operation, body: JSONEncoder().encode(request)))
    }

    private static func decode<Output: Decodable>(operation: String, response: Data) throws -> Output {
        let decoded = try JSONDecoder().decode(Response<Output>.self, from: response)
        if decoded.ok, let result = decoded.result {
            return result
        }
        let failure = decoded.error ?? .init(code: "failed", message: "empty response")
        // Messages can contain Apple's customer text; log the code only.
        logger.error("ipatool \(operation) failed: code=\(failure.code)")
        switch failure.code {
        case "authCodeRequired": throw IPAToolError.authCodeRequired
        case "passwordTokenExpired": throw IPAToolError.passwordTokenExpired
        case "licenseRequired": throw IPAToolError.licenseRequired
        case "canceled": throw IPAToolError.canceled
        default: throw IPAToolError.failed(code: failure.code, message: failure.message)
        }
    }

    private static func call(operation: String, body: Data) -> Data {
        #if ASSPP_IPATOOL
            let request = String(decoding: body, as: UTF8.self)
            guard let output = operation.withCString({ op in
                request.withCString { AssppIPAToolCall(UnsafeMutablePointer(mutating: op), UnsafeMutablePointer(mutating: $0)) }
            }) else {
                return Data(#"{"ok":false,"error":{"code":"internal","message":"no response"}}"#.utf8)
            }
            defer { AssppIPAToolFree(output) }
            return Data(String(cString: output).utf8)
        #else
            return Data(#"{"ok":false,"error":{"code":"unavailable","message":"unavailable"}}"#.utf8)
        #endif
    }

    private static func cancel(requestID: String) {
        #if ASSPP_IPATOOL
            requestID.withCString { AssppIPAToolCancel(UnsafeMutablePointer(mutating: $0)) }
        #endif
    }

    // MARK: - Diagnostics

    /// Moves the bridge's progress lines (operation timing, first-use download
    /// of Apple components) into the app log and the visible status. Swift
    /// initializes a static stored property exactly once, which starts one pump.
    private static let logPump: Void = {
        _ = Task.detached(priority: .utility) {
            while true {
                let lines = drainLog()
                if !lines.isEmpty {
                    for line in lines {
                        logger.info("[ipatool] \(line)")
                    }
                    let latest = lines.last
                    await MainActor.run { IPAToolStatus.shared.message = latest }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }()

    private static func startLogPump() {
        _ = logPump
    }

    private static func drainLog() -> [String] {
        #if ASSPP_IPATOOL
            guard let output = AssppIPAToolDrainLog() else { return [] }
            defer { AssppIPAToolFree(output) }
            return String(cString: output)
                .split(separator: "\n")
                .map(String.init)
        #else
            return []
        #endif
    }
}

/// Latest ipatool progress line, shown while a long first-time sign-in runs.
@Observable
@MainActor
final class IPAToolStatus {
    static let shared = IPAToolStatus()
    var message: String?
}
