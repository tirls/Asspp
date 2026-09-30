import Foundation

/// Serialization and cookie conventions shared by store authentication and product requests.
enum StoreProtocol {
    static func plist(_ data: Data) -> [String: Any]? {
        var payload = data
        // ipatool also accepts Document-wrapped XML and bare dictionary replies.
        // Foundation requires an outer <plist> even when Apple's payload omits it.
        if var xml = String(data: data, encoding: .utf8) {
            let documentPattern = try? NSRegularExpression(pattern: #"(?is)<Document\b[^>]*>(.*)</Document>"#)
            if let match = documentPattern?.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
               let range = Range(match.range(at: 1), in: xml)
            {
                xml = String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let range = xml.range(of: #"(?is)<plist\b[^>]*>.*?</plist>"#, options: .regularExpression) {
                payload = Data(xml[range].utf8)
            } else if let range = xml.range(of: #"(?is)<dict\b[^>]*>.*</dict>"#, options: .regularExpression) {
                payload = Data("<plist version=\"1.0\">\(xml[range])</plist>".utf8)
            } else if xml.contains("<key>") {
                payload = Data("<plist version=\"1.0\"><dict>\(xml)</dict></plist>".utf8)
            }
        }
        return (try? PropertyListSerialization.propertyList(from: payload, format: nil)) as? [String: Any]
    }

    static func storeCookieDomain(_ domain: String?) -> String? {
        domain.map { String($0.drop(while: { $0 == "." })).lowercased() }
    }

    static func foundationCookieDomain(_ domain: String?) -> String? {
        guard let domain = storeCookieDomain(domain),
              domain == "itunes.apple.com" || domain.hasSuffix(".itunes.apple.com")
        else { return nil }
        return "." + domain
    }

    static func string(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }
}
