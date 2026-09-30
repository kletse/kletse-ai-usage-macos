import Foundation

/// A single limit, e.g. the 5-hour session or the weekly cap.
struct UsageWindow: Sendable, Identifiable, Hashable {
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    /// Extra context, e.g. "$120.00 of $500.00".
    var detail: String?
    /// True when the reset time is a guess (e.g. the Enterprise monthly cap).
    var resetIsEstimate = false

    var id: String { label }
    /// Used percentage clamped to 0...100 for display.
    var displayUsedPercent: Double { max(0, min(100, usedPercent)) }
}

struct UsageSnapshot: Sendable {
    var windows: [UsageWindow]
    /// Who is logged in, e.g. an email address.
    var identity: String?
    /// Plan name, e.g. "Max" or "Team".
    var plan: String?
    var fetchedAt: Date
    /// Set when this came from a local cache instead of a live request.
    var staleReason: String?

    /// The binding limit: the highest used percentage over all windows.
    var maxUsedPercent: Double? { windows.map(\.displayUsedPercent).max() }
}

struct FetchError: Error, CustomStringConvertible {
    var description: String
    /// If set, don't call the API again before this time.
    var retryAfter: Date?

    init(_ description: String, retryAfter: Date? = nil) {
        self.description = description
        self.retryAfter = retryAfter
    }
}

enum Dates {
    /// Parses ISO 8601 dates with or without fractional seconds of any length.
    static func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    static func startOfNextMonth(after date: Date = Date()) -> Date? {
        let calendar = Calendar.current
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: start)
    }
}

/// Decodes the payload of a JWT without verifying it. Only used for non-secret claims like email.
func jwtClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

let sharedSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
}()

func retryAfterDate(_ response: HTTPURLResponse) -> Date {
    if let value = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(value) {
        return Date().addingTimeInterval(max(60, seconds))
    }
    return Date().addingTimeInterval(10 * 60)
}
