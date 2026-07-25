import CryptoKit
import Foundation

enum ExportUtilities {
    static func safeFilename(
        for workout: WorkoutSummary,
        format: ExportFilenameFormat = .dateActivityIdentifier
    ) -> String {
        let timestamp = String(date(workout.startDate).prefix(19))
            .replacingOccurrences(of: ":", with: "-")
        let activity = sanitize(workout.activityName.lowercased())
        let identifier = workout.id.uuidString.lowercased()
        return switch format {
        case .dateActivityIdentifier: "\(timestamp)_\(activity)_\(identifier)"
        case .activityDateIdentifier: "\(activity)_\(timestamp)_\(identifier)"
        }
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

    static func spreadsheetSafeCSV(_ value: String) -> String {
        let trimmed = value.drop(while: { $0 == " " || $0 == "\t" })
        let protected = if let first = trimmed.first, ["=", "+", "-", "@"].contains(first) {
            "'" + value
        } else {
            value
        }
        return csv(protected)
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

    static func sha256(fileAt url: URL) throws -> (digest: String, byteSize: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteSize = 0
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            byteSize += chunk.count
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, byteSize)
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

    static func createProtectedDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try applyCompleteFileProtection(to: url)
    }

    static func writeProtected(_ data: Data, to url: URL) throws {
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: url, options: .atomic)
#endif
    }

    static func applyCompleteFileProtection(to url: URL) throws {
#if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
#endif
    }

    static func applyCompleteFileProtectionRecursively(to root: URL) throws {
        try applyCompleteFileProtection(to: root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for case let url as URL in enumerator {
            try applyCompleteFileProtection(to: url)
        }
    }
}
