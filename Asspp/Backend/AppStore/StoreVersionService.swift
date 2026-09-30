import ApplePackage
import Foundation

/// Download metadata transport. Keep Apple's raw bodies, cookies and signed
/// asset URLs out of both the Xcode console and the in-app log viewer.
enum StoreVersionService {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_: URLSession, task _: URLSessionTask,
                        willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }

    static func versions(account: inout Account, package: AppStore.AppPackage) async throws -> [String] {
        try await product(account: &account, package: package, version: nil, operation: "versions") { item in
            guard let metadata = item["metadata"] as? [String: Any],
                  let identifiers = metadata["softwareVersionExternalIdentifiers"] as? [Any]
            else { throw StoreVersionError.noVersions }
            let versions = identifiers.map { StoreProtocol.string($0) }.filter { !$0.isEmpty }
            guard !versions.isEmpty else { throw StoreVersionError.noVersions }
            logger.info("Store versions: version identifiers count=\(versions.count)")
            return versions
        }
    }

    static func versionMetadata(account: inout Account, package: AppStore.AppPackage, versionID: String) async throws -> VersionMetadata {
        try await product(account: &account, package: package, version: versionID, operation: "version-metadata") { item in
            guard let metadata = item["metadata"] as? [String: Any],
                  let version = metadata["bundleShortVersionString"] as? String, !version.isEmpty,
                  let releaseDate = parseReleaseDate(metadata["releaseDate"])
            else { throw StoreVersionError.invalidPackage }
            return VersionMetadata(displayVersion: version, releaseDate: releaseDate)
        }
    }

    private static func parseReleaseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private static func product<Result>(account: inout Account, package: AppStore.AppPackage, version: String?, operation: String, parse: ([String: Any]) throws -> Result) async throws -> Result {
        let trace = String(UUID().uuidString.prefix(8))
        let app = package.software
        let version = version.flatMap { $0.isEmpty ? nil : $0 }
        let platform = package.entityType ?? .iPhone
        logger.info("Store versions [\(trace)]: operation=\(operation) app=\(app.id) platform=\(platform.rawValue) store=\(account.store) version=\(version ?? "latest")")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let region = Configuration.countryCode(for: account.store)
            var effectiveVersion = version
            var dispatchURLs: [StoreVersionProtocol.Endpoint: URL] = [:]
            var bagLoaded = false
            let response = try await StoreVersionProtocol.fetchWithFallback(version: version, updateAvailable: {
                dispatchURLs[.update] != nil
            }) { endpoint, requestedVersion in
                if endpoint != .volumeStore, !bagLoaded {
                    dispatchURLs = try await downloadEndpoints(session: session)
                    bagLoaded = true
                }
                effectiveVersion = requestedVersion
                return try await fetch(session: session, endpoint: endpoint, account: &account,
                                       appID: app.id, version: requestedVersion, trace: trace,
                                       dispatchURL: dispatchURLs[endpoint])
            } resolveVersion: {
                // An unpinned redownload can return a tvOS build for an iOS app.
                guard let region else { throw StoreVersionError.catalogUnavailable }
                let metadata: StoreVersionProtocol.CatalogVersion
                do {
                    metadata = try await catalogVersion(session: session, appID: app.id, region: region, platform: platform, trace: trace)
                } catch {
                    try Task.checkCancellation()
                    throw StoreVersionError.catalogUnavailable
                }
                guard !metadata.externalVersionID.isEmpty,
                      metadata.bundleID == nil || metadata.bundleID == app.bundleID
                else { throw StoreVersionError.catalogUnavailable }
                logger.info("Store versions [\(trace)]: catalog version=\(metadata.externalVersionID)")
                return metadata.externalVersionID
            } onFallback: { reason in
                logger.info("Store versions [\(trace)]: fallback, reason=\(reason)")
            }
            // Preserve the existing UI's explicit free-license acquisition flow.
            if StoreVersionProtocol.failureCode(response) == "9610" {
                throw ApplePackageError.licenseRequired
            }
            let item = try StoreVersionProtocol.packageItem(response, bundleID: app.bundleID, version: effectiveVersion)
            let result = try parse(item)
            logger.info("Store versions [\(trace)]: product metadata ready")
            return result
        } catch {
            // localizedDescription and NSError.userInfo can contain Apple messages
            // or a credential-bearing URL. Log only the error type and numeric code.
            logger.error("Store versions [\(trace)]: failed, \(StoreDiagnostics.errorSummary(error))")
            throw error
        }
    }

    private static func catalogVersion(session: URLSession, appID: Int64, region: String, platform: EntityType, trace: String) async throws -> StoreVersionProtocol.CatalogVersion {
        var url = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        url.queryItems = [
            URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "id", value: String(appID)),
            URLQueryItem(name: "p", value: "mdm-lockup"), URLQueryItem(name: "caller", value: "MDM"),
            URLQueryItem(name: "platform", value: platform == .appleTV ? "atv9" : "ios"),
            URLQueryItem(name: "cc", value: region.lowercased()), URLQueryItem(name: "l", value: "en"),
        ]
        var request = URLRequest(url: url.url!)
        request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        // No credentials and no automatic redirects. Foundation verifies TLS in
        // Debug too (ApplePackage 1.2.7 disables verification in its Debug client).
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logger.info("Store versions [\(trace)]: catalog HTTP=\(status) bytes=\(data.count)")
        guard status == 200 else { throw StoreVersionError.catalogUnavailable }
        return try StoreVersionProtocol.catalogVersion(data, appID: appID,
                                                        assetFlavor: platform == .appleTV ? nil : "iosSoftware")
    }

    private static func downloadEndpoints(session: URLSession) async throws -> [StoreVersionProtocol.Endpoint: URL] {
        var components = URLComponents(string: "https://init.itunes.apple.com/bag.xml")!
        components.queryItems = [URLQueryItem(name: "guid", value: Configuration.deviceIdentifier)]
        var request = URLRequest(url: components.url!)
        request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            return [:] // Keep the established redownload endpoint if the public bag is unavailable.
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let bag = StoreProtocol.plist(data) else { return [:] }
        let nested = bag["urlBag"] as? [String: Any] ?? [:]
        var result: [StoreVersionProtocol.Endpoint: URL] = [:]
        for (key, endpoint) in [("redownloadProduct", StoreVersionProtocol.Endpoint.redownload), ("updateProduct", .update)] {
            if let raw = (bag[key] ?? nested[key]) as? String {
                result[endpoint] = try StoreVersionProtocol.dispatchURL(raw, endpoint: endpoint, guid: Configuration.deviceIdentifier)
            }
        }
        return result
    }

    private static func fetch(session: URLSession, endpoint: StoreVersionProtocol.Endpoint,
                              account: inout Account, appID: Int64, version: String?, trace: String,
                              dispatchURL: URL? = nil) async throws -> [String: Any]
    {
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint == .volumeStore ? Configuration.storeAPIHost(pod: account.pod) : "downloaddispatch.itunes.apple.com"
        components.path = endpoint.path
        components.queryItems = [URLQueryItem(name: "guid", value: Configuration.deviceIdentifier)]
        guard var url = dispatchURL ?? components.url else { throw StoreVersionError.invalidRedirect }
        let body = try PropertyListSerialization.data(
            fromPropertyList: StoreVersionProtocol.payload(endpoint: endpoint, appID: appID,
                                                            guid: Configuration.deviceIdentifier, version: version),
            format: .xml, options: 0
        )
        for redirect in 0 ... 3 {
            try Task.checkCancellation()
            url = try StoreVersionProtocol.validatedURL(url)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ", "), forHTTPHeaderField: "Accept-Language")
            request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")
            request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
            for (name, value) in account.cookie.buildCookieHeader(url) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            logger.info("Store versions [\(trace)]: endpoint=\(endpoint.rawValue) hop=\(redirect) sessionCookie=\(request.value(forHTTPHeaderField: "Cookie") != nil)")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw StoreVersionError.response(0) }
            mergeCookies(response: response, url: url, account: &account)
            logger.info("Store versions [\(trace)]: endpoint=\(endpoint.rawValue) HTTP=\(response.statusCode) bytes=\(data.count)")
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard redirect < 3, let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL
                else { throw StoreVersionError.invalidRedirect }
                url = try StoreVersionProtocol.validatedURL(next)
                continue
            }
            let plist = StoreProtocol.plist(data)
            if let plist {
                logger.info("Store versions [\(trace)]: \(StoreVersionProtocol.summary(plist))")
            }
            if endpoint == .redownload, response.statusCode == 500,
               data.isEmpty || String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                throw StoreVersionError.emptyServerResponse(500)
            }
            guard response.statusCode == 200, let plist else { throw StoreVersionError.response(response.statusCode) }
            return plist
        }
        throw StoreVersionError.invalidRedirect
    }

    private static func mergeCookies(response: HTTPURLResponse, url: URL, account: inout Account) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String {
                result[name] = value
            }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let domain = StoreProtocol.storeCookieDomain(cookie.domain)
            account.cookie.removeAll { $0.name == cookie.name && $0.path == cookie.path && StoreProtocol.storeCookieDomain($0.domain) == domain }
            if let expiry = cookie.expiresDate, expiry <= Date() {
                continue
            }
            account.cookie.append(Cookie(name: cookie.name, value: cookie.value, path: cookie.path, domain: domain,
                                         expiresAt: cookie.expiresDate?.timeIntervalSince1970, httpOnly: cookie.isHTTPOnly, secure: cookie.isSecure))
        }
    }

}
