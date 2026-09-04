import ActivityArchiveVault
import Foundation
import XCTest

@testable import ActivityArchive

@MainActor
final class VaultOnboardingModelTests: XCTestCase {
  func testFirstRunShowsSetupWithoutPersistingAnything() async throws {
    let store = MemoryBookmarkStore()
    let model = makeModel(store: store)

    await model.restoreIfNeeded()

    let savedData = await store.savedData()
    XCTAssertEqual(model.phase, .needsSetup)
    XCTAssertNil(model.vault)
    XCTAssertNil(savedData)
  }

  func testValidBookmarkRestoresVaultAndRecoversInterruptedImports() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try ActivityVault(rootURL: root, minimumFreeBytes: 0)
    try await vault.database.startImport(
      id: UUID(),
      filename: "interrupted.gpx",
      sourcePath: nil,
      kind: .gpx
    )
    let store = MemoryBookmarkStore(data: Data("bookmark".utf8))
    let access = RecordingResourceAccess()
    let model = makeModel(
      store: store,
      coder: TestBookmarkCoder(result: .success(ResolvedVaultBookmark(url: root, isStale: false))),
      access: access
    )

    await model.restoreIfNeeded()

    XCTAssertEqual(model.phase, .ready)
    XCTAssertEqual(model.vaultURL, root)
    XCTAssertNotNil(model.vault)
    XCTAssertEqual(access.startedURLs, [root])
    let jobs = try await model.vault?.database.importJobs()
    XCTAssertEqual(jobs?.first?.status, .rejected)
  }

  func testStaleOrInvalidBookmarkRequiresExplicitRecovery() async {
    let store = MemoryBookmarkStore(data: Data("stale".utf8))
    let model = makeModel(
      store: store,
      coder: TestBookmarkCoder(
        result: .success(
          ResolvedVaultBookmark(url: URL(fileURLWithPath: "/missing"), isStale: true)
        )
      )
    )

    await model.restoreIfNeeded()

    XCTAssertEqual(model.phase, .recoveryRequired)
    XCTAssertTrue(model.message?.contains("expired") == true)
    XCTAssertNil(model.vault)
  }

  func testCancelledSelectionReturnsToSetupWithoutAnError() async {
    let model = makeModel(store: MemoryBookmarkStore())
    await model.restoreIfNeeded()

    model.selectionCancelled()

    XCTAssertEqual(model.phase, .needsSetup)
    XCTAssertNil(model.message)
  }

  func testOpeningSelectionPersistsBookmarkAndCloseReleasesAccess() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryBookmarkStore()
    let access = RecordingResourceAccess()
    let coder = TestBookmarkCoder(
      result: .success(ResolvedVaultBookmark(url: root, isStale: false))
    )
    let model = makeModel(store: store, coder: coder, access: access)

    await model.createVault(at: root)

    let savedData = await store.savedData()
    XCTAssertEqual(model.phase, .ready)
    XCTAssertEqual(savedData, Data(root.path.utf8))
    await model.closeVault()
    let clearedData = await store.savedData()
    XCTAssertEqual(model.phase, .needsSetup)
    XCTAssertEqual(access.stoppedURLs, [root])
    XCTAssertNil(clearedData)
  }

  private func makeModel(
    store: MemoryBookmarkStore,
    coder: TestBookmarkCoder = TestBookmarkCoder(
      result: .failure(VaultBookmarkError.invalidBookmark)),
    access: RecordingResourceAccess = RecordingResourceAccess()
  ) -> VaultOnboardingModel {
    VaultOnboardingModel(
      bookmarkStore: store,
      bookmarkCoder: coder,
      resourceAccess: access,
      opener: TestVaultOpener()
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "VaultOnboardingModelTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private actor MemoryBookmarkStore: VaultBookmarkStoring {
  private var data: Data?

  init(data: Data? = nil) { self.data = data }

  func load() -> Data? { data }
  func save(_ data: Data) { self.data = data }
  func remove() { data = nil }
  func savedData() -> Data? { data }
}

private struct TestBookmarkCoder: VaultBookmarkCoding {
  var result: Result<ResolvedVaultBookmark, Error>

  func encode(url: URL) -> Data { Data(url.path.utf8) }
  func decode(data: Data) throws -> ResolvedVaultBookmark { try result.get() }
}

private final class RecordingResourceAccess: SecurityScopedResourceAccessing, @unchecked Sendable {
  private(set) var startedURLs: [URL] = []
  private(set) var stoppedURLs: [URL] = []

  func start(url: URL) -> Bool {
    startedURLs.append(url)
    return true
  }

  func stop(url: URL) {
    stoppedURLs.append(url)
  }
}

private struct TestVaultOpener: ActivityVaultOpening {
  func open(url: URL, mode: VaultOpenMode) async throws -> ActivityVault {
    let vault = try ActivityVault(rootURL: url, minimumFreeBytes: 0)
    _ = try await vault.recoverInterruptedImports()
    return vault
  }
}
