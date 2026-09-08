import Foundation

public enum ActivityVaultSchema {
  public static let currentVersion = 2
}

public enum ActivityVaultError: Error, Equatable, LocalizedError, Sendable {
  case invalidVault(String)
  case unexpectedSymbolicLink(String)
  case objectHashMismatch(String)
  case database(String)
  case unsupportedArtifact(String)
  case invalidArtifact(String)
  case revisionConflict(packageID: UUID, revision: UInt64)
  case insufficientSpace(requiredBytes: UInt64, availableBytes: UInt64)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .invalidVault(let detail): "The archive vault is invalid: \(detail)"
    case .unexpectedSymbolicLink(let path):
      "The archive vault contains an unexpected symbolic link at \(path)."
    case .objectHashMismatch(let hash):
      "The existing immutable object does not match its recorded hash: \(hash)."
    case .database(let detail): "The archive catalog could not be updated: \(detail)"
    case .unsupportedArtifact(let name): "The file type is not supported: \(name)"
    case .invalidArtifact(let detail): "The imported file is invalid: \(detail)"
    case .revisionConflict(let packageID, let revision):
      "Package \(packageID.uuidString) revision \(revision) conflicts with an existing immutable revision."
    case .insufficientSpace(let required, let available):
      "The vault needs \(required) bytes of available space but only \(available) bytes are available."
    case .cancelled: "Import cancelled."
    }
  }
}

public struct ActivityVaultLayout: Equatable, Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
  }

  public var database: URL { root.appending(path: "archive.sqlite") }
  public var objectsRoot: URL { root.appending(path: "objects", directoryHint: .isDirectory) }
  public var objects: URL { root.appending(path: "objects/sha256", directoryHint: .isDirectory) }
  public var packagesRoot: URL { root.appending(path: "packages", directoryHint: .isDirectory) }
  public var incoming: URL {
    root.appending(path: "packages/incoming", directoryHint: .isDirectory)
  }
  public var processed: URL {
    root.appending(path: "packages/processed", directoryHint: .isDirectory)
  }
  public var rejected: URL {
    root.appending(path: "packages/rejected", directoryHint: .isDirectory)
  }
  public var exports: URL { root.appending(path: "exports", directoryHint: .isDirectory) }
  public var backups: URL { root.appending(path: "backups", directoryHint: .isDirectory) }
  public var logs: URL { root.appending(path: "logs", directoryHint: .isDirectory) }

  public var managedDirectories: [URL] {
    [
      root, objectsRoot, objects, packagesRoot, incoming, processed, rejected, exports, backups,
      logs,
    ]
  }

  public func create() throws {
    let manager = FileManager.default
    for directory in managedDirectories {
      if manager.fileExists(atPath: directory.path) {
        try rejectSymbolicLink(directory)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue
        else {
          throw ActivityVaultError.invalidVault("\(directory.path) is not a directory")
        }
        try manager.setAttributes(
          [.posixPermissions: 0o700],
          ofItemAtPath: directory.path
        )
      } else {
        try manager.createDirectory(
          at: directory,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      }
    }
  }

  public func validate() throws {
    for directory in managedDirectories {
      try rejectSymbolicLink(directory)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw ActivityVaultError.invalidVault("Missing directory \(directory.path)")
      }
    }
    if FileManager.default.fileExists(atPath: database.path) {
      try rejectSymbolicLink(database)
    }
  }

  public func objectURL(forSHA256 hash: String) throws -> URL {
    let lowercaseHexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
    guard hash.utf8.count == 64,
      hash.unicodeScalars.allSatisfy(lowercaseHexadecimal.contains)
    else {
      throw ActivityVaultError.invalidVault("Invalid SHA-256 object name")
    }
    return
      objects
      .appending(path: String(hash.prefix(2)), directoryHint: .isDirectory)
      .appending(path: String(hash.dropFirst(2).prefix(2)), directoryHint: .isDirectory)
      .appending(path: hash)
  }

  private func rejectSymbolicLink(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw ActivityVaultError.unexpectedSymbolicLink(url.path)
    }
  }
}

public struct ActivityStoredObject: Equatable, Sendable {
  public var sha256: String
  public var byteLength: UInt64
  public var url: URL
  public var wasCreated: Bool

  public init(sha256: String, byteLength: UInt64, url: URL, wasCreated: Bool) {
    self.sha256 = sha256
    self.byteLength = byteLength
    self.url = url
    self.wasCreated = wasCreated
  }
}

public enum ActivityImportKind: String, Codable, CaseIterable, Sendable {
  case activityPackage
  case gpx
  case geoJSON
}

public enum ActivityImportStatus: String, Codable, CaseIterable, Sendable {
  case importing
  case imported
  case duplicate
  case rejected
  case cancelled
}

public struct ActivityImportJob: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var sourceFilename: String
  public var sourcePath: String?
  public var kind: ActivityImportKind
  public var contentHash: String?
  public var status: ActivityImportStatus
  public var startedAt: Date
  public var completedAt: Date?
  public var errorMessage: String?

  public init(
    id: UUID,
    sourceFilename: String,
    sourcePath: String?,
    kind: ActivityImportKind,
    contentHash: String?,
    status: ActivityImportStatus,
    startedAt: Date,
    completedAt: Date?,
    errorMessage: String?
  ) {
    self.id = id
    self.sourceFilename = sourceFilename
    self.sourcePath = sourcePath
    self.kind = kind
    self.contentHash = contentHash
    self.status = status
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.errorMessage = errorMessage
  }
}

public struct ActivitySourceObservation: Identifiable, Equatable, Sendable {
  public var id: Int64
  public var packageID: UUID
  public var packageRevision: UInt64
  public var sourceActivityID: String
  public var contentHash: String
  public var objectHash: String
  public var kind: ActivityImportKind
  public var workoutTypeIdentifier: UInt?
  public var workoutTypeName: String
  public var title: String?
  public var startDate: Date?
  public var endDate: Date?
  public var timeZoneIdentifier: String?
  public var durationSeconds: Double?
  public var sourceName: String
  public var sourceBundleIdentifier: String?
  public var completeness: String
  public var routeState: String
  public var metricsState: String
  public var importedAt: Date

  public init(
    id: Int64,
    packageID: UUID,
    packageRevision: UInt64,
    sourceActivityID: String,
    contentHash: String,
    objectHash: String,
    kind: ActivityImportKind,
    workoutTypeIdentifier: UInt?,
    workoutTypeName: String,
    title: String?,
    startDate: Date?,
    endDate: Date?,
    timeZoneIdentifier: String?,
    durationSeconds: Double?,
    sourceName: String,
    sourceBundleIdentifier: String?,
    completeness: String,
    routeState: String,
    metricsState: String,
    importedAt: Date
  ) {
    self.id = id
    self.packageID = packageID
    self.packageRevision = packageRevision
    self.sourceActivityID = sourceActivityID
    self.contentHash = contentHash
    self.objectHash = objectHash
    self.kind = kind
    self.workoutTypeIdentifier = workoutTypeIdentifier
    self.workoutTypeName = workoutTypeName
    self.title = title
    self.startDate = startDate
    self.endDate = endDate
    self.timeZoneIdentifier = timeZoneIdentifier
    self.durationSeconds = durationSeconds
    self.sourceName = sourceName
    self.sourceBundleIdentifier = sourceBundleIdentifier
    self.completeness = completeness
    self.routeState = routeState
    self.metricsState = metricsState
    self.importedAt = importedAt
  }
}

public struct ActivitySourceRouteSummary: Identifiable, Equatable, Sendable {
  public var id: Int64
  public var observationID: Int64
  public var trackID: String
  public var pointCount: UInt64
  public var minimumLatitude: Double?
  public var maximumLatitude: Double?
  public var minimumLongitude: Double?
  public var maximumLongitude: Double?
  public var hasTimestamps: Bool

  public init(
    id: Int64,
    observationID: Int64,
    trackID: String,
    pointCount: UInt64,
    minimumLatitude: Double?,
    maximumLatitude: Double?,
    minimumLongitude: Double?,
    maximumLongitude: Double?,
    hasTimestamps: Bool
  ) {
    self.id = id
    self.observationID = observationID
    self.trackID = trackID
    self.pointCount = pointCount
    self.minimumLatitude = minimumLatitude
    self.maximumLatitude = maximumLatitude
    self.minimumLongitude = minimumLongitude
    self.maximumLongitude = maximumLongitude
    self.hasTimestamps = hasTimestamps
  }
}

public struct ActivityImportWarning: Identifiable, Equatable, Sendable {
  public var id: Int64
  public var jobID: UUID
  public var code: String
  public var message: String

  public init(id: Int64, jobID: UUID, code: String, message: String) {
    self.id = id
    self.jobID = jobID
    self.code = code
    self.message = message
  }
}

public struct ActivityImportResult: Equatable, Sendable {
  public var jobID: UUID
  public var status: ActivityImportStatus
  public var object: ActivityStoredObject
  public var observationID: Int64?

  public init(
    jobID: UUID,
    status: ActivityImportStatus,
    object: ActivityStoredObject,
    observationID: Int64?
  ) {
    self.jobID = jobID
    self.status = status
    self.object = object
    self.observationID = observationID
  }
}

public struct ActivityVaultIntegrityReport: Equatable, Sendable {
  public var missingObjectCount: Int
  public var corruptedObjectCount: Int
  public var checkedObjects: Int
  public var missingObjects: [String]
  public var corruptedObjects: [String]
  public var databaseIntegrityMessages: [String]

  public init(
    checkedObjects: Int,
    missingObjects: [String],
    corruptedObjects: [String],
    databaseIntegrityMessages: [String],
    missingObjectCount: Int? = nil,
    corruptedObjectCount: Int? = nil
  ) {
    self.missingObjectCount = missingObjectCount ?? missingObjects.count
    self.corruptedObjectCount = corruptedObjectCount ?? corruptedObjects.count
    self.checkedObjects = checkedObjects
    self.missingObjects = missingObjects
    self.corruptedObjects = corruptedObjects
    self.databaseIntegrityMessages = databaseIntegrityMessages
  }

  public var isHealthy: Bool {
    missingObjectCount == 0 && corruptedObjectCount == 0
      && databaseIntegrityMessages == ["ok"]
  }
}
