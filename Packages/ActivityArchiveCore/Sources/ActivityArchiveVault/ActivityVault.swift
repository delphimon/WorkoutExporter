import Foundation

public actor ActivityVault {
  public nonisolated let layout: ActivityVaultLayout
  public nonisolated let objectStore: ActivityObjectStore
  public nonisolated let database: ActivityVaultDatabase
  public nonisolated let minimumFreeBytes: UInt64

  public init(
    rootURL: URL,
    minimumFreeBytes: UInt64 = 512 * 1024 * 1024
  ) throws {
    let layout = ActivityVaultLayout(root: rootURL)
    try layout.create()
    try layout.validate()
    self.layout = layout
    self.minimumFreeBytes = minimumFreeBytes
    objectStore = ActivityObjectStore(layout: layout)
    database = try ActivityVaultDatabase(layout: layout)
  }

  public func importArtifact(at source: URL) async throws -> ActivityImportResult {
    let kind = try ActivityArtifactParser.kind(for: source)
    let values = try source.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ActivityVaultError.invalidArtifact("Imports must be regular, non-symbolic-link files")
    }
    let fileSize = UInt64(max(0, values.fileSize ?? 0))
    try preflightCapacity(additionalBytes: fileSize)

    let jobID = UUID()
    try await database.startImport(
      id: jobID,
      filename: source.lastPathComponent,
      sourcePath: source.path,
      kind: kind
    )
    var storedObject: ActivityStoredObject?
    do {
      try Task.checkCancellation()
      let object = try await objectStore.store(fileAt: source)
      storedObject = object
      try await database.recordArtifact(
        object: object,
        kind: kind,
        originalFilename: source.lastPathComponent
      )
      let originalFilename = source.lastPathComponent
      let parsingTask = Task.detached(priority: .utility) {
        try Task.checkCancellation()
        return try ActivityArtifactParser.parse(
          kind: kind,
          object: object,
          originalFilename: originalFilename
        )
      }
      let draft = try await withTaskCancellationHandler {
        try await parsingTask.value
      } onCancel: {
        parsingTask.cancel()
      }
      try Task.checkCancellation()
      let (status, observationID) = try await database.commitImport(
        jobID: jobID,
        object: object,
        draft: draft
      )
      do {
        try writeReceipt(
          jobID: jobID,
          filename: source.lastPathComponent,
          objectHash: object.sha256,
          status: status,
          message: nil,
          directory: layout.processed
        )
      } catch {
        try? await database.recordWarning(
          jobID: jobID,
          code: "receipt-write-failed",
          message: error.localizedDescription
        )
      }
      return ActivityImportResult(
        jobID: jobID,
        status: status,
        object: object,
        observationID: observationID
      )
    } catch is CancellationError {
      try? await database.cancelImport(id: jobID)
      throw ActivityVaultError.cancelled
    } catch let error as ActivityVaultError where error == .cancelled {
      try? await database.cancelImport(id: jobID)
      throw error
    } catch {
      let message = error.localizedDescription
      try? await database.rejectImport(
        id: jobID,
        contentHash: storedObject?.sha256,
        message: message
      )
      try? writeReceipt(
        jobID: jobID,
        filename: source.lastPathComponent,
        objectHash: storedObject?.sha256,
        status: .rejected,
        message: message,
        directory: layout.rejected
      )
      if let error = error as? ActivityVaultError { throw error }
      throw ActivityVaultError.invalidArtifact(message)
    }
  }

  public func recoverInterruptedImports() async throws -> Int {
    try removePartialFiles(in: layout.incoming)
    return try await database.recoverInterruptedImports()
  }

  public func integrityCheck() async throws -> ActivityVaultIntegrityReport {
    try layout.validate()
    let records = try await database.objectRecords()
    var missing: [String] = []
    var corrupted: [String] = []
    for record in records {
      try Task.checkCancellation()
      let url = try await objectStore.objectURL(for: record.hash)
      if !FileManager.default.fileExists(atPath: url.path) {
        missing.append(record.hash)
        continue
      }
      do {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let actualByteLength = UInt64(max(0, values.fileSize ?? 0))
        let hashMatches = try await objectStore.verify(hash: record.hash)
        if actualByteLength != record.byteLength || !hashMatches {
          corrupted.append(record.hash)
        }
      } catch {
        corrupted.append(record.hash)
      }
    }
    return ActivityVaultIntegrityReport(
      checkedObjects: records.count,
      missingObjects: missing,
      corruptedObjects: corrupted,
      databaseIntegrityMessages: try await database.integrityCheck()
    )
  }

  public func preflightCapacity(additionalBytes: UInt64) throws {
    let values = try layout.root.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
    )
    let reportedCapacity =
      values.volumeAvailableCapacityForImportantUsage
      ?? values.volumeAvailableCapacity.map(Int64.init)
    guard let reportedCapacity else { return }
    let available = UInt64(max(0, reportedCapacity))
    let (required, overflow) = additionalBytes.addingReportingOverflow(minimumFreeBytes)
    guard !overflow, available >= required else {
      throw ActivityVaultError.insufficientSpace(
        requiredBytes: overflow ? UInt64.max : required,
        availableBytes: available
      )
    }
  }

  private func writeReceipt(
    jobID: UUID,
    filename: String,
    objectHash: String?,
    status: ActivityImportStatus,
    message: String?,
    directory: URL
  ) throws {
    var value: [String: Any] = [
      "jobID": jobID.uuidString.lowercased(),
      "filename": filename,
      "status": status.rawValue,
      "recordedAt": ISO8601DateFormatter().string(from: Date()),
    ]
    if let objectHash { value["objectHash"] = objectHash }
    if let message { value["message"] = message }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let destination = directory.appending(path: jobID.uuidString.lowercased() + ".json")
    try data.write(to: destination, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
  }

  private func removePartialFiles(in directory: URL) throws {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: []
      )
    else { return }
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        url.lastPathComponent.hasSuffix(".partial")
      else { continue }
      try FileManager.default.removeItem(at: url)
    }
  }
}
