import CryptoKit
import Foundation

enum ExportUtilities {
    static func safeFilename(for workout: WorkoutSummary) -> String {
        let timestamp = String(date(workout.startDate).prefix(19))
            .replacingOccurrences(of: ":", with: "-")
        let activity = sanitize(workout.activityName.lowercased())
        return "\(timestamp)_\(activity)_\(workout.id.uuidString.lowercased())"
    }

    static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let collapsed = String(mapped).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return String(collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).prefix(180))
    }

    static func csv(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func xml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func date(_ value: Date) -> String {
        value.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: true).timeSeparator(.colon)
            .timeZone(separator: .colon))
    }

    static func metadataJSON(_ metadata: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
