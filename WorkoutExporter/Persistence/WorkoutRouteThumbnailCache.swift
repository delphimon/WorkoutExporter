import Foundation

struct CachedRoutePresentation: Codable, Sendable {
    var imageData: Data?
    var placeLabel: WorkoutPlaceLabel?
    var createdAt: Date
}

protocol WorkoutRouteThumbnailCaching: Sendable {
    func presentation(for workoutID: UUID) async -> CachedRoutePresentation?
    func store(_ presentation: CachedRoutePresentation, for workoutID: UUID) async
}

actor WorkoutRouteThumbnailCache: WorkoutRouteThumbnailCaching {
    private(set) var lastError: String?
    private let directory: URL
    private let maximumEntryCount: Int
    private let maximumAge: TimeInterval

    init(directory: URL? = nil, maximumEntryCount: Int = 200, maximumAge: TimeInterval = 30 * 86_400) {
        let cacheRoot =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory =
            directory ?? cacheRoot.appending(path: "WorkoutExporter/RouteThumbnails", directoryHint: .isDirectory)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumAge = max(0, maximumAge)
    }

    func presentation(for workoutID: UUID) async -> CachedRoutePresentation? {
        let url = fileURL(for: workoutID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(CachedRoutePresentation.self, from: data) else { return nil }
        guard Date().timeIntervalSince(cached.createdAt) <= maximumAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return cached
    }

    func store(_ presentation: CachedRoutePresentation, for workoutID: UUID) async {
        do {
            try ExportUtilities.createProtectedDirectory(at: directory)
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? protectedDirectory.setResourceValues(values)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try ExportUtilities.writeProtected(encoder.encode(presentation), to: fileURL(for: workoutID))
            pruneIfNeeded()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            // A thumbnail cache miss is non-fatal; the route can be rendered again.
        }
    }

    private func fileURL(for workoutID: UUID) -> URL { directory.appending(path: workoutID.uuidString + ".json") }

    private func pruneIfNeeded() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]),
            files.count > maximumEntryCount
        else { return }
        let ordered = files.sorted {
            let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (left ?? .distantPast) < (right ?? .distantPast)
        }
        for url in ordered.prefix(files.count - maximumEntryCount) { try? FileManager.default.removeItem(at: url) }
    }
}
