import ActivityArchiveVault
import Foundation
import Observation

@MainActor
@Observable
final class VaultCatalogModel {
  let vault: ActivityVault
  var filter = ActivityCatalogFilter()
  private(set) var activities: [ActivitySourceObservation] = []
  private(set) var jobs: [ActivityImportJob] = []
  private(set) var nextActivity: ActivityCatalogCursor?
  private(set) var nextImport: ActivityImportCursor?
  private(set) var detail: ActivityObservationDetail?
  private(set) var route: ActivityRouteDisplay?
  private(set) var comparisonRoute: ActivityRouteDisplay?
  private(set) var comparisonName: String?
  private(set) var isLoading = false
  private(set) var isLoadingRoute = false
  private(set) var isChecking = false
  private(set) var integrity: ActivityVaultIntegrityReport?
  private(set) var integrityMessage: String?
  private(set) var capacityMessage = "Capacity has not been checked."
  private(set) var isLowDisk = false
  private(set) var errorMessage: String?
  private var integrityFailed = false
  private var queryGeneration = UUID()
  private var selectionGeneration = UUID()
  private var routeTask: Task<Void, Never>?
  private var integrityTask: Task<Void, Never>?
  private var integrityGeneration = UUID()

  init(vault: ActivityVault) { self.vault = vault }

  var blocksImport: Bool {
    isChecking || isLowDisk || integrityFailed || integrity?.isHealthy == false
  }

  func refresh(imports: Bool, next: Bool = false) async {
    let generation = UUID()
    queryGeneration = generation
    isLoading = true
    errorMessage = nil
    do {
      try await Task.sleep(for: .milliseconds(180))
      if imports {
        let page = try await vault.database.importPage(
          filter: filter, after: next ? nextImport : nil)
        try Task.checkCancellation()
        guard queryGeneration == generation else { return }
        jobs = page.jobs
        nextImport = page.next
      } else {
        let page = try await vault.database.catalogPage(
          filter: filter, after: next ? nextActivity : nil)
        try Task.checkCancellation()
        guard queryGeneration == generation else { return }
        activities = page.observations
        nextActivity = page.next
      }
    } catch is CancellationError {
      // Superseded queries cannot publish stale pages or errors.
    } catch {
      if queryGeneration == generation { errorMessage = error.localizedDescription }
    }
    if queryGeneration == generation { isLoading = false }
  }

  func select(_ id: Int64?) async {
    let generation = UUID()
    selectionGeneration = generation
    routeTask?.cancel()
    isLoadingRoute = false
    detail = nil
    route = nil
    comparisonRoute = nil
    comparisonName = nil
    guard let id else { return }
    do {
      let value = try await vault.database.observationDetail(id: id)
      try Task.checkCancellation()
      guard selectionGeneration == generation else { return }
      detail = value
    } catch is CancellationError {} catch {
      if selectionGeneration == generation { errorMessage = error.localizedDescription }
    }
  }

  func loadRoute(comparing other: ActivitySourceObservation? = nil) {
    guard let id = detail?.observation.id else { return }
    routeTask?.cancel()
    let generation = UUID()
    selectionGeneration = generation
    isLoadingRoute = true
    errorMessage = nil
    routeTask = Task {
      defer { if selectionGeneration == generation { isLoadingRoute = false } }
      do {
        let first = try await vault.routeDisplay(observationID: id)
        let second = try await other.asyncRoute(in: vault)
        try Task.checkCancellation()
        guard selectionGeneration == generation else { return }
        route = first
        comparisonRoute = second
        comparisonName = other.map { "\($0.sourceName) · \($0.sourceActivityID)" }
      } catch is CancellationError {} catch {
        if selectionGeneration == generation { errorMessage = error.localizedDescription }
      }
    }
  }

  func cancelRoute() { routeTask?.cancel() }

  func importsStarted() {
    if integrity?.isHealthy == true {
      integrity = nil
      integrityMessage =
        "New imports began after the last check. Run integrity again to include them."
    }
  }

  func checkCapacity() async {
    do {
      let available = try await vault.availableCapacity()
      try await vault.preflightCapacity(additionalBytes: 0)
      isLowDisk = false
      capacityMessage =
        available.map {
          "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file)) available. Import capacity is checked again for each file."
        } ?? "Available capacity is unknown. Confirm free space before importing."
    } catch {
      isLowDisk = true
      capacityMessage =
        "Low disk space or capacity unavailable: \(error.localizedDescription) Free space on this volume, then check again."
    }
  }

  func checkIntegrity() {
    guard !isChecking else { return }
    isChecking = true
    integrityMessage = "Checking immutable objects and catalog…"
    let generation = UUID()
    integrityGeneration = generation
    integrityTask = Task {
      defer { if integrityGeneration == generation { isChecking = false } }
      do {
        let result = try await vault.integrityCheck()
        try Task.checkCancellation()
        guard integrityGeneration == generation else { return }
        integrityFailed = false
        integrity = result
        integrityMessage =
          result.isHealthy
          ? "Healthy: all \(result.checkedObjects) objects and the catalog passed."
          : "Needs recovery: \(result.missingObjectCount) missing and \(result.corruptedObjectCount) corrupt objects. Imports are paused. Restore a verified backup to a separate local folder and open it; retain this vault for recovery."
      } catch is CancellationError {
        if integrityGeneration == generation {
          integrityMessage =
            "Check cancelled. No new integrity result is available; any earlier result is retained."
        }
      } catch {
        if integrityGeneration == generation {
          integrityFailed = true
          integrityMessage =
            "Integrity check failed. \(error.localizedDescription) Close and reopen the vault, or open a verified backup."
        }
      }
    }
  }

  func cancelIntegrity() { integrityTask?.cancel() }
  func cancelAll() {
    queryGeneration = UUID()
    selectionGeneration = UUID()
    integrityGeneration = UUID()
    routeTask?.cancel()
    integrityTask?.cancel()
    isLoadingRoute = false
    isChecking = false
  }
}

extension Optional where Wrapped == ActivitySourceObservation {
  fileprivate func asyncRoute(in vault: ActivityVault) async throws -> ActivityRouteDisplay? {
    guard let self else { return nil }
    return try await vault.routeDisplay(observationID: self.id)
  }
}
