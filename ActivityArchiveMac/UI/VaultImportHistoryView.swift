import ActivityArchiveVault
import SwiftUI

struct VaultImportHistoryView: View {
  @Bindable var model: VaultCatalogModel
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import History").font(.title.bold())
      CatalogFilters(filter: $model.filter, imports: true)
      catalogStatus(model: model, imports: true)
      if model.jobs.isEmpty && !model.isLoading {
        Text("No matching import jobs. Open files to import, or clear the filters.")
          .foregroundStyle(.secondary)
      }
      LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(model.jobs) { job in
          ImportJobRow(job: job, vault: model.vault)
        }
      }
    }.task(id: model.filter) { await model.refresh(imports: true) }
  }
}

private struct ImportJobRow: View {
  let job: ActivityImportJob
  let vault: ActivityVault
  @State private var expanded = false
  @State private var warnings: [ActivityImportWarning] = []
  @State private var warningError: String?
  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Job: \(job.id.uuidString)")
        Text("Started: \(sourceDate(job.startedAt))")
        if let completed = job.completedAt { Text("Completed: \(sourceDate(completed))") }
        Text(
          job.contentHash.map { "Retained object: \($0)" }
            ?? "No retained object is recorded for this job.")
        if let message = job.errorMessage {
          Label(message, systemImage: "exclamationmark.triangle")
        }
        ForEach(warnings) { Label($0.message, systemImage: "exclamationmark.triangle") }
        if let warningError { Text(warningError) }
        Text(recovery).foregroundStyle(.secondary)
      }
      .font(.callout).textSelection(.enabled)
    } label: {
      Label(
        "\(job.sourceFilename) — \(job.status.rawValue)",
        systemImage: job.status == .rejected ? "exclamationmark.triangle" : "doc")
    }
    .accessibilityIdentifier("import-job-\(job.id.uuidString)")
    .task(id: expanded) {
      guard expanded else { return }
      do {
        let result = try await vault.database.warnings(jobID: job.id)
        try Task.checkCancellation()
        warnings = Array(result.prefix(1000))
        warningError = result.count > 1000 ? "Additional warnings exceed the display limit." : nil
      } catch is CancellationError {} catch { warningError = error.localizedDescription }
    }
  }

  private var recovery: String {
    switch job.status {
    case .duplicate:
      "This delivery was already present. The source observation and original artifacts remain retained."
    case .rejected, .cancelled:
      "Use Open Files to select the original again after resolving the error or freeing disk space. Conflicting revisions need a corrected package revision from the source. Recovery never deletes retained objects."
    case .importing:
      "If this job was interrupted, close and reopen the vault to recover it, then select the source file again."
    case .imported: "Import committed. Source evidence remains immutable."
    }
  }
}

struct VaultIntegrityView: View {
  @Bindable var model: VaultCatalogModel
  let isImporting: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Vault Integrity").font(.largeTitle.bold())
      Text(
        "Checks verify the catalog and immutable object bytes. They never delete or overwrite source evidence."
      )
      Label(
        model.capacityMessage,
        systemImage: model.isLowDisk ? "exclamationmark.triangle" : "internaldrive"
      )
      .accessibilityIdentifier("vault-capacity-status")
      Button("Check Free Space") { Task { await model.checkCapacity() } }
      HStack {
        Button("Check Integrity") { model.checkIntegrity() }
          .disabled(model.isChecking || isImporting).accessibilityIdentifier(
            "check-integrity-button")
        if model.isChecking {
          ProgressView().controlSize(.small).accessibilityLabel("Checking vault integrity")
          Button("Cancel Check") { model.cancelIntegrity() }
        }
      }
      Text(model.integrityMessage ?? "Integrity has not been checked in this session.")
        .accessibilityIdentifier("vault-integrity-status")
      if let report = model.integrity {
        Text(
          "Checked: \(report.checkedObjects) · Missing: \(report.missingObjectCount) · Corrupt: \(report.corruptedObjectCount)"
        )
        DisclosureGroup("Catalog and object details") {
          Text(report.databaseIntegrityMessages.joined(separator: "\n"))
          ForEach(report.missingObjects, id: \.self) { Text("Missing: \($0)") }
          ForEach(report.corruptedObjects, id: \.self) { Text("Corrupt: \($0)") }
          Text("At most 100 hashes per category are displayed. Counts cover the full scan.").font(
            .caption)
        }.textSelection(.enabled)
      }
      Text(
        "Before recovery, preserve this vault and verify your backup. Restore to a separate local folder, use Open Another Vault, and run the check there. A successful integrity check does not prove a backup can be restored."
      )
      .foregroundStyle(.secondary)
    }.padding(24).task { await model.checkCapacity() }
  }
}
