import ApplePackage
import Foundation

/// One isolated transport and signer per login, retained through the 2FA challenge. Credentials only go to validated Apple endpoints.
actor SignedStoreAuthenticator {
    private let transport = StoreAuthenticationTransport()
    private var signer: SAPContext?
    private var signerIdentity: String?
    private var inProgress = false
    private var cookieStorage: HTTPCookieStorage { transport.cookieStorage }
    private let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    func authenticate(email: String, password: String, code: String, guid: String, cookies: [Cookie]) async throws -> ApplePackage.Account {
        guard !inProgress else { throw StoreAuthenticationError.inProgress }
        inProgress = true
        defer { inProgress = false }
        do {
            return try await performAuthentication(email: email, password: password, code: code, guid: guid, cookies: cookies)
        } catch where (error as NSError).domain == "Asspp.SAP" {
            throw StoreAuthenticationProtocol.signerFailure(error as NSError)
        }
    }

    private func performAuthentication(email: String, password: String, code: String, guid: String, cookies: [Cookie]) async throws -> ApplePackage.Account {
        try Task.checkCancellation()
        let normalizedCode = code.filter { !$0.isWhitespace }
        restore(cookies)
        let hardware = try StoreAuthenticationProtocol.hardwareID(guid: guid)
        var bagComponents = URLComponents(string: "https://init.itunes.apple.com/bag.xml")!
        bagComponents.queryItems = [URLQueryItem(name: "guid", value: guid)]
        let bagURL = bagComponents.url!
        let (bagData, bagResponse) = try await send(URLRequest(url: bagURL), stage: "bag")
        guard bagResponse.statusCode == 200, let bag = StoreProtocol.plist(bagData) else {
            throw StoreAuthenticationError.serviceResponse(bagResponse.statusCode)
        }
        let nested = bag["urlBag"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? {
            bag[key] ?? nested[key]
        }
        let endpoint = try StoreAuthenticationProtocol.initialAuthenticationURL(StoreProtocol.string(value("authenticateAccount")), guid: guid)
        guard StoreProtocol.string(value("sign-sap-version")) == "200",
              let certificateURL = publicSAPURL(value("sign-sap-setup-cert"), host: "s.mzstatic.com"),
              let setupURL = publicSAPURL(value("sign-sap-setup"), host: "fpinit.itunes.apple.com"),
              let assets = Bundle.main.resourceURL?.appendingPathComponent("SAPAssets"),
              guid.count == 12
        else { throw StoreAuthenticationError.invalidConfiguration }
        let identity = [guid, certificateURL.absoluteString, setupURL.absoluteString].joined(separator: "|")
        let signer: SAPContext
        if let prepared = self.signer, signerIdentity == identity {
            signer = prepared
            logger.info("Apple authentication: reusing SAP session")
        } else {
            self.signer = nil
            signerIdentity = nil
            signer = try SAPContext(assetsURL: assets, hardwareID: hardware)
            let (certificateData, certificateResponse) = try await send(URLRequest(url: certificateURL), stage: "certificate")
            guard certificateResponse.statusCode == 200,
                  let certificate = StoreProtocol.plist(certificateData)?["sign-sap-setup-cert"] as? Data
            else { throw StoreAuthenticationError.serviceResponse(certificateResponse.statusCode) }
            let exchange = try signer.exchangeData(certificate, version: 200)
            var setup = URLRequest(url: setupURL)
            setup.httpMethod = "POST"
            setup.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
            setup.httpBody = try PropertyListSerialization.data(fromPropertyList: ["sign-sap-setup-buffer": exchange], format: .xml, options: 0)
            let (setupData, setupResponse) = try await send(setup, stage: "setup")
            guard setupResponse.statusCode == 200,
                  let reply = StoreProtocol.plist(setupData)?["sign-sap-setup-buffer"] as? Data
            else { throw StoreAuthenticationError.serviceResponse(setupResponse.statusCode) }
            _ = try signer.exchangeData(reply, version: 200)
            guard signer.complete else { throw StoreAuthenticationError.invalidConfiguration }
            self.signer = signer
            signerIdentity = identity
        }

        var url = endpoint
        var redirects = 0
        var storefront = ""
        var pod: String?
        let body = try StoreAuthenticationProtocol.body(email: email, password: password, code: normalizedCode, guid: guid)
        while redirects <= 3 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            // Match the plist body and the working ApplePackage/Web request profile.
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await sendAuthentication(request, signer: signer)
            if let value = response.value(forHTTPHeaderField: "X-Set-Apple-Store-Front") {
                storefront = value
            }
            if let value = response.value(forHTTPHeaderField: "pod") {
                pod = value
            }
            if (300 ... 399).contains(response.statusCode) {
                guard let location = response.value(forHTTPHeaderField: "Location") else {
                    throw StoreAuthenticationError.serviceResponse(response.statusCode)
                }
                guard let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw StoreAuthenticationError.invalidRedirect }
                url = try StoreAuthenticationProtocol.authenticationURL(next.absoluteString)
                redirects += 1
                continue
            }
            guard let plist = StoreProtocol.plist(data) else {
                throw StoreAuthenticationError.serviceResponse(response.statusCode)
            }
            if let error = StoreAuthenticationProtocol.rejection(plist, code: normalizedCode) {
                throw error
            }
            guard response.statusCode == 200,
                  let info = plist["accountInfo"] as? [String: Any],
                  let address = info["address"] as? [String: Any],
                  let token = plist["passwordToken"] as? String, !token.isEmpty,
                  !StoreProtocol.string(plist["dsPersonId"]).isEmpty
            else { throw StoreAuthenticationError.serviceResponse(response.statusCode) }
            let store = StoreAuthenticationProtocol.storeIdentifier(storefront)
            guard !store.isEmpty else {
                throw StoreAuthenticationError.invalidConfiguration
            }
            return try ApplePackage.Account(
                email: email, password: password,
                appleId: info["appleId"] as? String,
                store: store,
                firstName: address["firstName"] as? String,
                lastName: address["lastName"] as? String,
                passwordToken: token,
                directoryServicesIdentifier: StoreProtocol.string(plist["dsPersonId"]),
                cookie: savedCookies(), pod: pod
            )
        }
        throw StoreAuthenticationError.tooManyAttempts
    }

    private func send(_ request: URLRequest, stage: String) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        // Do not log bodies, signatures, URL query strings, or Set-Cookie headers.
        logger.info("Apple authentication: stage=\(stage) \(StoreDiagnostics.authenticationResponse(response, data: data))")
        return (data, response)
    }

    private func sendAuthentication(_ request: URLRequest, signer: SAPContext) async throws -> (Data, HTTPURLResponse) {
        for attempt in 1 ... 3 {
            var signedRequest = request
            // Retry the identical body with a fresh signature, as ipatool does.
            try signedRequest.setValue(signer.sign(request.httpBody ?? Data()).base64EncodedString(), forHTTPHeaderField: "X-Apple-ActionSignature")
            let result = try await send(signedRequest, stage: "login")
            if attempt == 3 || !StoreAuthenticationProtocol.retryable(status: result.1.statusCode, data: result.0) {
                return result
            }
            let delay = StoreAuthenticationProtocol.retryDelay(attempt: attempt, retryAfter: result.1.value(forHTTPHeaderField: "Retry-After"))
            logger.info("Apple authentication: retry=\(attempt) wait=\(delay)s")
            try await Task.sleep(for: .seconds(delay))
        }
        throw StoreAuthenticationError.tooManyAttempts
    }

    private func publicSAPURL(_ value: Any?, host: String) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              url.scheme == "https", url.host?.lowercased() == host,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }

    private func restore(_ cookies: [Cookie]) {
        for cookie in cookies {
            guard let domain = StoreProtocol.foundationCookieDomain(cookie.domain) else { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name, .value: cookie.value, .path: cookie.path, .domain: domain,
                .secure: cookie.secure ? "TRUE" : "FALSE",
            ]
            if let expires = cookie.expiresAt {
                properties[.expires] = Date(timeIntervalSince1970: expires)
            }
            if cookie.httpOnly {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            if let restored = HTTPCookie(properties: properties) {
                cookieStorage.setCookie(restored)
            }
        }
    }

    private func savedCookies() -> [Cookie] {
        (cookieStorage.cookies ?? []).map {
            Cookie(name: $0.name, value: $0.value, path: $0.path, domain: StoreProtocol.storeCookieDomain($0.domain),
                   expiresAt: $0.expiresDate?.timeIntervalSince1970, httpOnly: $0.isHTTPOnly, secure: $0.isSecure)
        }
    }
}
