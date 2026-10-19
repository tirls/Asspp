import Foundation

@main
struct DownloadProtocolChecks {
    static func main() async throws {
        let metadata: [String: Any] = [
            "softwareVersionBundleId": "test.app",
            "softwareVersionExternalIdentifier": "42",
        ]
        let success: [String: Any] = ["songList": [["metadata": metadata]]]
        let empty: [String: Any] = ["status": 0, "songList": []]

        // Both latest and explicitly selected historical downloads keep the resolved version.
        for version in [nil, "42"] as [String?] {
            for emptyHTTP500 in [false, true] {
                var endpoints: [StoreVersionProtocol.Endpoint] = []
                var resolutions = 0
                let response = try await StoreVersionProtocol.fetchWithFallback(
                    version: version, updateAvailable: { true },
                    fetch: { endpoint, requested in
                        endpoints.append(endpoint)
                        switch endpoint {
                        case .volumeStore:
                            precondition(requested == version)
                            return empty
                        case .redownload:
                            precondition(requested == "42")
                            if emptyHTTP500 { throw StoreVersionError.emptyServerResponse(500) }
                            return empty
                        case .update:
                            precondition(requested == "42")
                            return success
                        }
                    }, resolveVersion: {
                        resolutions += 1
                        return "42"
                    }, onFallback: { _ in }
                )
                precondition(endpoints == [.volumeStore, .redownload, .update])
                precondition(resolutions == (version == nil ? 1 : 0))
                _ = try StoreVersionProtocol.packageItem(response, bundleID: "test.app", version: "42")
            }
        }

        // A working primary endpoint, missing license, and account prompts must not be retried.
        for response in [success, ["failureType": "9610"], ["status": 0, "dialog": [:]], ["status": 1]] {
            var calls = 0
            _ = try await StoreVersionProtocol.fetchWithFallback(version: nil, fetch: { endpoint, _ in
                calls += 1
                precondition(endpoint == .volumeStore)
                return response
            }, resolveVersion: {
                fatalError("Must not resolve a version for a terminal response")
            }, onFallback: { _ in fatalError("Must not fall back for a terminal response") })
            precondition(calls == 1)
        }

        // Never request an unpinned package if latest-version resolution fails.
        var calls = 0
        do {
            _ = try await StoreVersionProtocol.fetchWithFallback(version: nil, fetch: { _, _ in
                calls += 1
                return empty
            }, resolveVersion: { throw StoreVersionError.catalogUnavailable }, onFallback: { _ in })
            fatalError("Accepted an unresolved latest version")
        } catch StoreVersionError.catalogUnavailable {}
        precondition(calls == 1)

        for (bundle, version) in [("wrong.app", "42"), ("test.app", "43")] {
            do {
                _ = try StoreVersionProtocol.packageItem(success, bundleID: bundle, version: version)
                fatalError("Accepted mismatched package metadata")
            } catch StoreVersionError.invalidPackage {}
        }
        do {
            _ = try StoreVersionProtocol.packageItem(empty, bundleID: "test.app")
            fatalError("Accepted an empty final response")
        } catch StoreVersionError.empty {}
        for endpoint in [StoreVersionProtocol.Endpoint.redownload, .update] {
            let raw = "https://downloaddispatch.itunes.apple.com" + endpoint.path + "?routing=fixture"
            let url = try StoreVersionProtocol.dispatchURL(raw, endpoint: endpoint, guid: "024153535050")
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "routing", value: "fixture")) == true)
            do {
                _ = try StoreVersionProtocol.dispatchURL(raw.replacingOccurrences(of: "downloaddispatch.itunes.apple.com", with: "attacker.example"), endpoint: endpoint, guid: "024153535050")
                fatalError("Accepted a foreign dispatch host")
            } catch StoreVersionError.invalidRedirect {}
        }
        print("Download recovery regression checks passed.")
    }
}
