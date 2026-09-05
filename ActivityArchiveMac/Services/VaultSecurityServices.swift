import ActivityArchiveVault
import Foundation
import Security

enum VaultBookmarkError: Error, LocalizedError {
  case keychain(OSStatus)
  case invalidBookmark
  case staleBookmark
  case inaccessibleLocation

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "The saved vault access could not be read (Keychain error \(status))."
    case .invalidBookmark:
      "The saved vault access is invalid. Choose the vault again to restore access."
    case .staleBookmark:
      "The saved vault access has expired. Choose the vault again to restore access."
    case .inaccessibleLocation:
      "Activity Archive could not obtain secure access to that folder."
    }
  }
}

protocol VaultBookmarkStoring: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
  func remove() async throws
}

actor KeychainVaultBookmarkStore: VaultBookmarkStoring {
  private let service = "com.delphimon.ActivityArchive.vault-bookmark"
  private let account = "primary-vault"

  func load() throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw VaultBookmarkError.keychain(status)
    }
    return data
  }

  func save(_ data: Data) throws {
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var insertion = identity
      insertion.merge(attributes) { _, new in new }
      let insertionStatus = SecItemAdd(insertion as CFDictionary, nil)
      guard insertionStatus == errSecSuccess else {
        throw VaultBookmarkError.keychain(insertionStatus)
      }
    } else if status != errSecSuccess {
      throw VaultBookmarkError.keychain(status)
    }
  }

  func remove() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw VaultBookmarkError.keychain(status)
    }
  }
}

struct ResolvedVaultBookmark: Sendable {
  var url: URL
  var isStale: Bool
}

protocol VaultBookmarkCoding: Sendable {
  func encode(url: URL) throws -> Data
  func decode(data: Data) throws -> ResolvedVaultBookmark
}

struct SecurityScopedVaultBookmarkCoder: VaultBookmarkCoding {
  func encode(url: URL) throws -> Data {
    try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: [.isDirectoryKey],
      relativeTo: nil
    )
  }

  func decode(data: Data) throws -> ResolvedVaultBookmark {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    return ResolvedVaultBookmark(url: url, isStale: isStale)
  }
}

protocol SecurityScopedResourceAccessing: Sendable {
  func start(url: URL) -> Bool
  func stop(url: URL)
}

struct SystemSecurityScopedResourceAccess: SecurityScopedResourceAccessing {
  func start(url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
  func stop(url: URL) { url.stopAccessingSecurityScopedResource() }
}

enum VaultOpenMode: Sendable {
  case create
  case existing
}

protocol ActivityVaultOpening: Sendable {
  func open(url: URL, mode: VaultOpenMode) async throws -> ActivityVault
}

struct DefaultActivityVaultOpener: ActivityVaultOpening {
  func open(url: URL, mode: VaultOpenMode) async throws -> ActivityVault {
    try Task.checkCancellation()
    let manager = FileManager.default
    try validateLocalVaultLocation(url, fileManager: manager)
    switch mode {
    case .create:
      var isDirectory: ObjCBool = false
      if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
          throw ActivityVaultError.invalidVault("The selected location is not a folder")
        }
        let contents = try manager.contentsOfDirectory(atPath: url.path)
        guard contents.isEmpty || contents == [".DS_Store"] else {
          throw ActivityVaultError.invalidVault(
            "Choose a new or empty folder so existing files are not mixed into the vault"
          )
        }
      } else {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
      }
    case .existing:
      let database = url.appending(path: "archive.sqlite")
      let values = try database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ActivityVaultError.invalidVault(
          "The selected folder does not contain an Activity Archive catalog"
        )
      }
    }
    let vault = try ActivityVault(rootURL: url)
    _ = try await vault.recoverInterruptedImports()
    return vault
  }

  private func validateLocalVaultLocation(_ url: URL, fileManager: FileManager) throws {
    let existingLocation =
      fileManager.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
    let values = try existingLocation.resourceValues(
      forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey]
    )
    guard values.isUbiquitousItem != true, values.volumeIsLocal != false else {
      throw ActivityVaultError.invalidVault(
        "Choose a local folder outside iCloud Drive and network storage"
      )
    }
  }
}
