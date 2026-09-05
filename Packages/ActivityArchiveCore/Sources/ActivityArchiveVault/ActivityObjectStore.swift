import CryptoKit
import Foundation

public actor ActivityObjectStore {
  public let layout: ActivityVaultLayout
  private let chunkSize = 256 * 1024

  public init(layout: ActivityVaultLayout) {
    self.layout = layout
  }

  public func store(data: Data) throws -> ActivityStoredObject {
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return try publish(data: data, hash: hash)
  }

  public func store(fileAt source: URL) throws -> ActivityStoredObject {
    try Task.checkCancellation()
    let manager = FileManager.default
    let sourceValues = try source.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
      throw ActivityVaultError.invalidArtifact(
        "Objects can only be created from regular, non-symbolic-link files"
      )
    }
    let temporaryDirectory = layout.incoming.appending(
      path: ".objects",
      directoryHint: .isDirectory
    )
    try manager.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try rejectSymbolicLink(temporaryDirectory)
    let temporary = temporaryDirectory.appending(path: UUID().uuidString + ".partial")
    guard
      manager.createFile(
        atPath: temporary.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw ActivityVaultError.invalidVault("Could not create an incoming object")
    }
    var removeTemporary = true
    defer {
      if removeTemporary { try? manager.removeItem(at: temporary) }
    }

    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: temporary)
    defer {
      try? input.close()
      try? output.close()
    }
    var hasher = SHA256()
    var byteLength: UInt64 = 0
    while let data = try input.read(upToCount: chunkSize), !data.isEmpty {
      try Task.checkCancellation()
      let (newLength, overflow) = byteLength.addingReportingOverflow(UInt64(data.count))
      guard !overflow else {
        throw ActivityVaultError.invalidArtifact("The imported file is too large")
      }
      byteLength = newLength
      hasher.update(data: data)
      try output.write(contentsOf: data)
    }
    try output.synchronize()
    try input.close()
    try output.close()

    let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let destination = try layout.objectURL(forSHA256: hash)
    let wasCreated = try publishTemporary(
      temporary,
      to: destination,
      hash: hash,
      byteLength: byteLength
    )
    removeTemporary = false
    return ActivityStoredObject(
      sha256: hash,
      byteLength: byteLength,
      url: destination,
      wasCreated: wasCreated
    )
  }

  public func verify(hash: String) throws -> Bool {
    let url = try layout.objectURL(forSHA256: hash)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    try rejectSymbolicLink(url)
    return try hashFile(url).hash == hash
  }

  public func objectURL(for hash: String) throws -> URL {
    try layout.objectURL(forSHA256: hash)
  }

  private func publish(data: Data, hash: String) throws -> ActivityStoredObject {
    let destination = try layout.objectURL(forSHA256: hash)
    let manager = FileManager.default
    try ensureObjectParent(for: destination)
    if manager.fileExists(atPath: destination.path) {
      try rejectSymbolicLink(destination)
      let existing = try hashFile(destination)
      guard existing.hash == hash, existing.byteLength == UInt64(data.count) else {
        throw ActivityVaultError.objectHashMismatch(hash)
      }
      return ActivityStoredObject(
        sha256: hash,
        byteLength: UInt64(data.count),
        url: destination,
        wasCreated: false
      )
    }
    let temporary = destination.deletingLastPathComponent().appending(
      path: ".\(hash).\(UUID().uuidString).partial"
    )
    defer { try? manager.removeItem(at: temporary) }
    try data.write(to: temporary, options: [.atomic])
    try setReadOnlyPermissions(temporary)
    try manager.moveItem(at: temporary, to: destination)
    return ActivityStoredObject(
      sha256: hash,
      byteLength: UInt64(data.count),
      url: destination,
      wasCreated: true
    )
  }

  private func publishTemporary(
    _ temporary: URL,
    to destination: URL,
    hash: String,
    byteLength: UInt64
  ) throws -> Bool {
    let manager = FileManager.default
    try ensureObjectParent(for: destination)
    if manager.fileExists(atPath: destination.path) {
      try rejectSymbolicLink(destination)
      let existing = try hashFile(destination)
      guard existing.hash == hash, existing.byteLength == byteLength else {
        throw ActivityVaultError.objectHashMismatch(hash)
      }
      try manager.removeItem(at: temporary)
      return false
    }
    try setReadOnlyPermissions(temporary)
    do {
      try manager.moveItem(at: temporary, to: destination)
      return true
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      let existing = try hashFile(destination)
      guard existing.hash == hash, existing.byteLength == byteLength else {
        throw ActivityVaultError.objectHashMismatch(hash)
      }
      try? manager.removeItem(at: temporary)
      return false
    }
  }

  private func ensureObjectParent(for destination: URL) throws {
    let manager = FileManager.default
    let parent = destination.deletingLastPathComponent()
    var current = layout.objects
    try rejectSymbolicLink(current)
    for component in parent.pathComponents.dropFirst(layout.objects.pathComponents.count) {
      current.append(path: component, directoryHint: .isDirectory)
      if manager.fileExists(atPath: current.path) {
        try rejectSymbolicLink(current)
        let values = try current.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
          throw ActivityVaultError.invalidVault("\(current.path) is not a directory")
        }
      } else {
        try manager.createDirectory(
          at: current,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
      }
    }
  }

  private func setReadOnlyPermissions(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: url.path
    )
  }

  private func rejectSymbolicLink(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw ActivityVaultError.unexpectedSymbolicLink(url.path)
    }
  }

  private func hashFile(_ url: URL) throws -> (hash: String, byteLength: UInt64) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var byteLength: UInt64 = 0
    while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
      try Task.checkCancellation()
      hasher.update(data: data)
      let (newLength, overflow) = byteLength.addingReportingOverflow(UInt64(data.count))
      guard !overflow else {
        throw ActivityVaultError.invalidArtifact("Object size overflow")
      }
      byteLength = newLength
    }
    return (
      hasher.finalize().map { String(format: "%02x", $0) }.joined(),
      byteLength
    )
  }
}
