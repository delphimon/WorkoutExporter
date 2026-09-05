import ActivityArchiveVault
import Foundation
import Observation

@MainActor
@Observable
final class ActivityArchiveApplicationModel {
  let onboarding: VaultOnboardingModel
  let imports: VaultImportModel

  init(onboarding: VaultOnboardingModel, imports: VaultImportModel) {
    self.onboarding = onboarding
    self.imports = imports
  }

  func restoreVaultIfNeeded() async {
    await onboarding.restoreIfNeeded()
  }

  static func makeForCurrentProcess() -> ActivityArchiveApplicationModel {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("--ui-testing-onboarding") {
        return testingModel(bookmark: nil)
      }
      if arguments.contains("--ui-testing-recovery") {
        return testingModel(bookmark: Data("invalid".utf8))
      }
      if arguments.contains("--ui-testing-ready") {
        let root = FileManager.default.temporaryDirectory.appending(
          path: "ActivityArchiveUITest-\(ProcessInfo.processInfo.processIdentifier)",
          directoryHint: .isDirectory
        )
        return testingModel(bookmark: Data(root.path.utf8), resolvedURL: root)
      }
    #endif

    let access = SystemSecurityScopedResourceAccess()
    return ActivityArchiveApplicationModel(
      onboarding: VaultOnboardingModel(
        bookmarkStore: KeychainVaultBookmarkStore(),
        bookmarkCoder: SecurityScopedVaultBookmarkCoder(),
        resourceAccess: access,
        opener: DefaultActivityVaultOpener()
      ),
      imports: VaultImportModel(resourceAccess: access)
    )
  }

  #if DEBUG
    private static func testingModel(
      bookmark: Data?,
      resolvedURL: URL? = nil
    ) -> ActivityArchiveApplicationModel {
      let access = TestingSecurityScopedResourceAccess()
      return ActivityArchiveApplicationModel(
        onboarding: VaultOnboardingModel(
          bookmarkStore: TestingVaultBookmarkStore(bookmark: bookmark),
          bookmarkCoder: TestingVaultBookmarkCoder(resolvedURL: resolvedURL),
          resourceAccess: access,
          opener: TestingActivityVaultOpener()
        ),
        imports: VaultImportModel(resourceAccess: access)
      )
    }
  #endif
}

#if DEBUG
  private actor TestingVaultBookmarkStore: VaultBookmarkStoring {
    private var bookmark: Data?

    init(bookmark: Data?) {
      self.bookmark = bookmark
    }

    func load() -> Data? { bookmark }
    func save(_ data: Data) { bookmark = data }
    func remove() { bookmark = nil }
  }

  private struct TestingVaultBookmarkCoder: VaultBookmarkCoding {
    var resolvedURL: URL?

    func encode(url: URL) -> Data { Data(url.path.utf8) }

    func decode(data: Data) throws -> ResolvedVaultBookmark {
      guard let resolvedURL else { throw VaultBookmarkError.invalidBookmark }
      return ResolvedVaultBookmark(url: resolvedURL, isStale: false)
    }
  }

  private struct TestingSecurityScopedResourceAccess: SecurityScopedResourceAccessing {
    func start(url: URL) -> Bool { true }
    func stop(url: URL) {}
  }

  private struct TestingActivityVaultOpener: ActivityVaultOpening {
    func open(url: URL, mode: VaultOpenMode) async throws -> ActivityVault {
      try ActivityVault(rootURL: url, minimumFreeBytes: 0)
    }
  }
#endif
