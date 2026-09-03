import Foundation

public enum ActivityPackageError: Error, Equatable, LocalizedError, Sendable {
  case invalidManifest(String)
  case unsupportedSchema(String)
  case invalidPath(String)
  case duplicatePath(String)
  case missingFile(String)
  case unexpectedFile(String)
  case invalidArchive(String)
  case unsupportedArchiveFeature(String)
  case fileTooLarge(String)
  case archiveTooLarge
  case checksumMismatch(String)
  case byteLengthMismatch(String)

  public var errorDescription: String? {
    switch self {
    case .invalidManifest(let reason): "Invalid Activity Package manifest: \(reason)"
    case .unsupportedSchema(let version): "Unsupported Activity Package schema: \(version)"
    case .invalidPath(let path): "Unsafe Activity Package path: \(path)"
    case .duplicatePath(let path): "Duplicate Activity Package path: \(path)"
    case .missingFile(let path): "Activity Package file is missing: \(path)"
    case .unexpectedFile(let path): "Activity Package contains an unlisted file: \(path)"
    case .invalidArchive(let reason): "Invalid Activity Package archive: \(reason)"
    case .unsupportedArchiveFeature(let reason): "Unsupported archive feature: \(reason)"
    case .fileTooLarge(let path): "Activity Package file exceeds the configured limit: \(path)"
    case .archiveTooLarge: "Activity Package exceeds the configured total size limit."
    case .checksumMismatch(let path): "Activity Package checksum mismatch: \(path)"
    case .byteLengthMismatch(let path): "Activity Package byte length mismatch: \(path)"
    }
  }
}

public struct ActivityPackageLimits: Equatable, Sendable {
  public var maximumFileCount: Int
  public var maximumManifestBytes: UInt64
  public var maximumFileBytes: UInt64
  public var maximumTotalBytes: UInt64

  public init(
    maximumFileCount: Int = 1_024,
    maximumManifestBytes: UInt64 = 2 * 1_024 * 1_024,
    maximumFileBytes: UInt64 = 512 * 1_024 * 1_024,
    maximumTotalBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
  ) {
    self.maximumFileCount = maximumFileCount
    self.maximumManifestBytes = maximumManifestBytes
    self.maximumFileBytes = maximumFileBytes
    self.maximumTotalBytes = maximumTotalBytes
  }

  func validate() throws {
    guard maximumFileCount > 0,
      maximumManifestBytes > 0,
      maximumFileBytes > 0,
      maximumTotalBytes > 0
    else {
      throw ActivityPackageError.invalidArchive("Package limits must be positive")
    }
  }
}
