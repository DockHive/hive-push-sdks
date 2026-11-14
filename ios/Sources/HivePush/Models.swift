import Foundation

/// An error from Hive Push or from the SDK itself.
///
/// `code` is the stable error code from the API (for example
/// `platform_not_configured`, `invalid_user_token`, `rate_limited`) or one the
/// SDK adds: `network`, `invalid_options`, `invalid_response`.
/// `status` is the HTTP status, or 0 when no answer was received.
public struct HivePushError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String
    public let status: Int

    public init(code: String, message: String, status: Int = 0) {
        self.code = code
        self.message = message
        self.status = status
    }

    public var description: String { "HivePushError(\(code), status \(status)): \(message)" }
}

/// Which APNs environment the device token belongs to.
public enum APNsEnvironment: String, Sendable {
    /// `sandbox` in DEBUG builds (installed from Xcode), `production` otherwise
    /// (TestFlight and App Store).
    case auto
    case sandbox
    case production

    var resolved: APNsEnvironment {
        guard self == .auto else { return self }
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

/// The type of a notification event reported to Hive Push.
public enum HivePushEventType: String, Sendable {
    case delivered
    case clicked
    case dismissed
}

/// Any JSON value (used for a notification's `data`).
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

/// A button on a notification.
public struct InboxAction: Codable, Equatable, Sendable {
    public let action: String
    public let title: String
    public let url: String?
}

/// One item of a user's in-app inbox.
public struct InboxItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let notificationId: String
    /// RFC 3339 time the item was created.
    public let createdAt: String
    /// RFC 3339 time the item was read, or nil while unread.
    public let readAt: String?
    public let title: String
    public let body: String?
    public let url: String?
    public let icon: String?
    public let image: String?
    public let data: JSONValue?
    public let actions: [InboxAction]?

    public var isRead: Bool { readAt != nil }

    /// `createdAt` as a `Date`.
    public var createdDate: Date? { parseISODate(createdAt) }

    enum CodingKeys: String, CodingKey {
        case id, title, body, url, icon, image, data, actions
        case notificationId = "notification_id"
        case createdAt = "created_at"
        case readAt = "read_at"
    }
}

/// A page of the inbox, newest first.
public struct InboxPage: Codable, Equatable, Sendable {
    public let items: [InboxItem]
    /// The user's total number of unread items.
    public let unread: Int
}

func parseISODate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
