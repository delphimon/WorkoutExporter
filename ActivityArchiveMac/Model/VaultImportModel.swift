import ActivityArchiveVault
import Foundation
import Observation

protocol ActivityArtifactImporting: Sendable {
  func importArtifact(at source: URL) async throws -> ActivityImportResult
}

extension ActivityVault: ActivityArtifactImporting {}

struct ActivityFileImportFailure: Identifiable, Equatable {
  let id = UUID()
  var filename: String
  var message: String
}

@MainActor
@Observable
final class VaultImportModel {
  private(set) var isImporting = false
  private(set) var currentFilename: String?
  private(set) var completedCount = 0
  private(set) var totalCount = 0
  private(set) var importedCount = 0
  private(set) var duplicateCount = 0
  private(set) var failures: [ActivityFileImportFailure] = []

  private let resourceAccess: any SecurityScopedResourceAccessing
  private var importTask: Task<Void, Never>?

  init(resourceAccess: any SecurityScopedResourceAccessing) {
    self.resourceAccess = resourceAccess
  }

  var progress: Double {
    guard totalCount > 0 else { return 0 }
    return Double(completedCount) / Double(totalCount)
  }

  func start(urls: [URL], importer: any ActivityArtifactImporting) {
    guard !isImporting, !urls.isEmpty else { return }
    failures = []
    completedCount = 0
    importedCount = 0
    duplicateCount = 0
    totalCount = urls.count
    isImporting = true
    importTask = Task { [weak self] in
      guard let self else { return }
      for url in urls {
        if Task.isCancelled { break }
        currentFilename = url.lastPathComponent
        let hasAccess = resourceAccess.start(url: url)
        defer {
          if hasAccess { resourceAccess.stop(url: url) }
        }
        guard hasAccess else {
          failures.append(
            ActivityFileImportFailure(
              filename: url.lastPathComponent,
              message: VaultBookmarkError.inaccessibleLocation.localizedDescription
            )
          )
          completedCount += 1
          continue
        }
        do {
          let result = try await importer.importArtifact(at: url)
          switch result.status {
          case .imported: importedCount += 1
          case .duplicate: duplicateCount += 1
          case .importing, .rejected, .cancelled: break
          }
        } catch is CancellationError {
          break
        } catch let error as ActivityVaultError where error == .cancelled {
          break
        } catch {
          failures.append(
            ActivityFileImportFailure(
              filename: url.lastPathComponent,
              message: error.localizedDescription
            )
          )
        }
        completedCount += 1
      }
      currentFilename = nil
      isImporting = false
      importTask = nil
    }
  }

  func cancel() {
    importTask?.cancel()
  }
}
