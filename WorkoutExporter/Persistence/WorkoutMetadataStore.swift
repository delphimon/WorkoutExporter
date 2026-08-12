import Foundation
import Observation

struct CachedWorkoutExport: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var workoutIDs: [UUID]
    var createdAt: Date
    var relativePath: String
    var cacheKey: String

    init(
        id: UUID,
        workoutIDs: [UUID],
        createdAt: Date,
        relativePath: String,
        cacheKey: String = "legacy"
    ) {
        self.id = id
        self.workoutIDs = workoutIDs
        self.createdAt = createdAt
        self.relativePath = relativePath
        self.cacheKey = cacheKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, workoutIDs, createdAt, relativePath, cacheKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workoutIDs = try container.decode([UUID].self, forKey: .workoutIDs)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        cacheKey = try container.decodeIfPresent(String.self, forKey: .cacheKey)
            ?? "legacy"
    }
}

@MainActor
@Observable
final class WorkoutMetadataStore {
    private(set) var exportedWorkoutIDs: Set<UUID> = []
    private(set) var customLocationTags: [UUID: String] = [:]
    private(set) var cachedExports: [CachedWorkoutExport] = []
    private(set) var lastPersistenceError: String?

    private let persistenceURL: URL
    private let exportDirectory: URL

    init(
        persistenceURL: URL? = nil,
        exportDirectory: URL
    ) {
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL()
        self.exportDirectory = exportDirectory
        load()
        pruneMissingCachedExports()
    }

    func isExported(_ workoutID: UUID) -> Bool {
        exportedWorkoutIDs.contains(workoutID)
    }

    func customLocationTag(for workoutID: UUID) -> String? {
        customLocationTags[workoutID]
    }

    func setCustomLocationTag(_ name: String?, for workoutID: UUID) throws {
        let previous = customLocationTags
        let normalized = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)
        if let normalized, !normalized.isEmpty {
            customLocationTags[workoutID] = String(normalized)
        } else {
            customLocationTags.removeValue(forKey: workoutID)
        }
        do {
            try persist()
        } catch {
            customLocationTags = previous
            throw error
        }
    }

    func recordExport(
        workoutIDs: some Sequence<UUID>,
        fileURL: URL,
        cachePackage: Bool = true,
        cacheKey: String = "legacy"
    ) throws {
        let identifiers = Self.canonicalIDs(workoutIDs)
        guard !identifiers.isEmpty else { return }
        let standardizedFile = fileURL.standardizedFileURL
        guard managedExportURL(for: standardizedFile.lastPathComponent) == standardizedFile,
              FileManager.default.fileExists(atPath: standardizedFile.path) else {
            throw WorkoutExporterError.fileWriteFailure(
                "The completed export is not available in temporary storage."
            )
        }

        let previousIDs = exportedWorkoutIDs
        let previousExports = cachedExports
        exportedWorkoutIDs.formUnion(identifiers)
        if cachePackage {
            cachedExports.removeAll {
                ($0.workoutIDs == identifiers && $0.cacheKey == cacheKey)
                    || $0.relativePath == standardizedFile.lastPathComponent
            }
            cachedExports.append(CachedWorkoutExport(
                id: UUID(),
                workoutIDs: identifiers,
                createdAt: Date(),
                relativePath: standardizedFile.lastPathComponent,
                cacheKey: cacheKey
            ))
            cachedExports.sort { $0.createdAt > $1.createdAt }
        }
        do {
            try persist()
        } catch {
            exportedWorkoutIDs = previousIDs
            cachedExports = previousExports
            throw error
        }
    }

    func clearExportedFlag(for workoutIDs: some Sequence<UUID>) throws {
        let previous = exportedWorkoutIDs
        exportedWorkoutIDs.subtract(workoutIDs)
        do {
            try persist()
        } catch {
            exportedWorkoutIDs = previous
            throw error
        }
    }

    func cachedExport(
        for workoutIDs: some Sequence<UUID>,
        cacheKey: String? = nil
    ) -> (record: CachedWorkoutExport, url: URL)? {
        let identifiers = Self.canonicalIDs(workoutIDs)
        guard !identifiers.isEmpty else { return nil }
        for record in cachedExports where record.workoutIDs == identifiers
                && (cacheKey == nil || record.cacheKey == cacheKey) {
            if let url = managedExportURL(for: record.relativePath),
               FileManager.default.fileExists(atPath: url.path) {
                return (record, url)
            }
        }
        return nil
    }

    func pruneMissingCachedExports() {
        let previousCount = cachedExports.count
        cachedExports.removeAll {
            guard let url = managedExportURL(for: $0.relativePath) else {
                return true
            }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        guard cachedExports.count != previousCount else { return }
        try? persist()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(
                Snapshot.self,
                from: Data(contentsOf: persistenceURL)
            )
            guard snapshot.schemaVersion == Snapshot.currentSchemaVersion else {
                throw WorkoutExporterError.fileWriteFailure(
                    "Unsupported workout metadata version."
                )
            }
            exportedWorkoutIDs = Set(snapshot.exportedWorkoutIDs)
            customLocationTags = Dictionary(
                uniqueKeysWithValues: snapshot.customLocationTags.compactMap { key, value in
                    UUID(uuidString: key).map { ($0, value) }
                }
            )
            cachedExports = snapshot.cachedExports.sorted { $0.createdAt > $1.createdAt }
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }

    private func persist() throws {
        do {
            let directory = persistenceURL.deletingLastPathComponent()
            try ExportUtilities.createProtectedDirectory(at: directory)
            var protectedDirectory = directory
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(resourceValues)
            let snapshot = Snapshot(
                exportedWorkoutIDs: exportedWorkoutIDs.sorted {
                    $0.uuidString < $1.uuidString
                },
                customLocationTags: Dictionary(
                    uniqueKeysWithValues: customLocationTags.map {
                        ($0.key.uuidString, $0.value)
                    }
                ),
                cachedExports: cachedExports
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try ExportUtilities.writeProtected(
                encoder.encode(snapshot),
                to: persistenceURL
            )
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
            throw error
        }
    }

    private static func canonicalIDs(
        _ workoutIDs: some Sequence<UUID>
    ) -> [UUID] {
        Array(Set(workoutIDs)).sorted { $0.uuidString < $1.uuidString }
    }

    private func managedExportURL(for relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              relativePath != ".",
              relativePath != "..",
              (relativePath as NSString).lastPathComponent == relativePath else {
            return nil
        }
        let directory = exportDirectory.standardizedFileURL
        let url = directory.appending(path: relativePath).standardizedFileURL
        guard url.deletingLastPathComponent() == directory else { return nil }
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values?.isSymbolicLink != true,
              values?.isRegularFile == true || values?.isDirectory == true else {
            return nil
        }
        return url
    }

    private static func defaultPersistenceURL() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appending(path: "WorkoutExporter", directoryHint: .isDirectory)
            .appending(path: "workout-metadata.json")
    }

    private struct Snapshot: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion = currentSchemaVersion
        var exportedWorkoutIDs: [UUID]
        var customLocationTags: [String: String]
        var cachedExports: [CachedWorkoutExport]
    }
}
