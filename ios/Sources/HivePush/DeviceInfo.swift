import Foundation

/// The optional app version / locale / time zone sent with a registration.
struct DeviceInfo: Equatable {
    var appVersion: String?
    var locale: String?
    var timezone: String?

    static func current(bundle: Bundle = .main) -> DeviceInfo {
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        return DeviceInfo(
            appVersion: sanitizeVersion(version),
            locale: sanitizeLocale(Locale.current.identifier),
            timezone: sanitizeTimezone(TimeZone.current.identifier)
        )
    }

    func fields() -> [String: Any] {
        var out: [String: Any] = [:]
        if let v = appVersion { out["app_version"] = v }
        if let v = locale { out["locale"] = v }
        if let v = timezone { out["timezone"] = v }
        return out
    }

    static func sanitizeVersion(_ v: String?) -> String? {
        guard let v = v, !v.isEmpty, v.count <= 32,
              v.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }) else { return nil }
        return v
    }

    /// "en_NG@calendar=gregorian" -> "en-NG"; nil when it is not a language tag.
    static func sanitizeLocale(_ id: String) -> String? {
        let base = id.split(separator: "@").first.map(String.init) ?? id
        let tag = base.replacingOccurrences(of: "_", with: "-")
        guard tag.count <= 35,
              tag.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8}){0,4}$", options: .regularExpression) != nil else { return nil }
        return tag
    }

    static func sanitizeTimezone(_ id: String) -> String? {
        guard id.range(of: "^[A-Za-z0-9_+\\-/]{1,64}$", options: .regularExpression) != nil else { return nil }
        return id
    }
}

extension Data {
    /// The APNs device token as lowercase hex.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
