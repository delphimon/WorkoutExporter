import ActivityArchiveVault
import Foundation
import Observation

enum VaultOnboardingPhase: Equatable {
  case checking
  case needsSetup
  case opening
  case ready
  case recoveryRequired
}

@MainActor
@Observable
final class VaultOnboardingModel {
  private(set) var phase: VaultOnboardingPhase = .checking
  private(set) var vault: ActivityVault?
  private(set) var vaultURL: URL?
  private(set) var message: String?

  private let bookmarkStore: any VaultBookmarkStoring
  private let bookmarkCoder: any VaultBookmarkCoding
  private let resourceAccess: any SecurityScopedResourceAccessing
  private let opener: any ActivityVaultOpening
  private var activeSecurityScopedURL: URL?
  private var hasAttemptedRestore = false

  init(
    bookmarkStore: any VaultBookmarkStoring,
    bookmarkCoder: any VaultBookmarkCoding,
    resourceAccess: any SecurityScopedResourceAccessing,
    opener: any ActivityVaultOpening
  ) {
    self.bookmarkStore = bookmarkStore
    self.bookmarkCoder = bookmarkCoder
    self.resourceAccess = resourceAccess
    self.opener = opener
  }

  func restoreIfNeeded() async {
    guard !hasAttemptedRestore else { return }
    hasAttemptedRestore = true
    phase = .checking
    do {
      guard let data = try await bookmarkStore.load() else {
        phase = .needsSetup
        return
      }
      let resolved = try bookmarkCoder.decode(data: data)
      guard !resolved.isStale else { throw VaultBookmarkError.staleBookmark }
      try await activate(url: resolved.url, mode: .existing, saveBookmark: false)
    } catch is CancellationError {
      phase = .needsSetup
      message = nil
    } catch {
      phase = .recoveryRequired
      message = error.localizedDescription
    }
  }

  func createVault(at url: URL) async {
    await openSelectedVault(url, mode: .create)
  }

  func openExistingVault(at url: URL) async {
    await openSelectedVault(url, mode: .existing)
  }

  func selectionCancelled() {
    if phase == .opening { phase = vault == nil ? .needsSetup : .ready }
    message = nil
  }

  func closeVault() async {
    if let activeSecurityScopedURL {
      resourceAccess.stop(url: activeSecurityScopedURL)
    }
    activeSecurityScopedURL = nil
    vault = nil
    vaultURL = nil
    message = nil
    try? await bookmarkStore.remove()
    phase = .needsSetup
  }

  private func openSelectedVault(_ url: URL, mode: VaultOpenMode) async {
    do {
      try await activate(url: url, mode: mode, saveBookmark: true)
    } catch is CancellationError {
      selectionCancelled()
    } catch {
      phase = .recoveryRequired
      message = error.localizedDescription
    }
  }

  private func activate(
    url: URL,
    mode: VaultOpenMode,
    saveBookmark: Bool
  ) async throws {
    phase = .opening
    message = nil
    guard resourceAccess.start(url: url) else {
      throw VaultBookmarkError.inaccessibleLocation
    }
    var keepAccess = false
    defer {
      if !keepAccess { resourceAccess.stop(url: url) }
    }

    let openedVault = try await opener.open(url: url, mode: mode)
    if saveBookmark {
      let bookmark = try bookmarkCoder.encode(url: url)
      try await bookmarkStore.save(bookmark)
    }
    if let activeSecurityScopedURL, activeSecurityScopedURL != url {
      resourceAccess.stop(url: activeSecurityScopedURL)
    }
    activeSecurityScopedURL = url
    keepAccess = true
    vault = openedVault
    vaultURL = url
    phase = .ready
  }
}
