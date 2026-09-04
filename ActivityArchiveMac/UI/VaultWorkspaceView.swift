import ActivityArchiveVault
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VaultWorkspaceView: View {
  let vault: ActivityVault
  let vaultURL: URL
  @Bindable var onboarding: VaultOnboardingModel
  @Bindable var imports: VaultImportModel
  @State private var isDropTargeted = false

  private var importTypes: [UTType] {
    [
      UTType(importedAs: "com.delphimon.activity-archive.package"),
      UTType(importedAs: "com.topografix.gpx"),
      UTType(importedAs: "public.geo-json"),
      .json,
    ]
  }

  var body: some View {
    NavigationSplitView {
      List {
        Label("Activities", systemImage: "figure.hiking")
        Label("Review", systemImage: "checklist")
        Label("Trips", systemImage: "mountain.2")
        Label("Map", systemImage: "map")
        Label("Imports", systemImage: "tray.and.arrow.down")
        Label("Analytics", systemImage: "chart.xyaxis.line")
        Label("Settings", systemImage: "gearshape")
      }
      .navigationTitle("Activity Archive")
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          header
          importZone
          importProgress
          failureList
          securityReminder
        }
        .padding(32)
        .frame(maxWidth: 820, alignment: .leading)
      }
      .navigationTitle("Imports")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Import Activities")
        .font(.largeTitle.bold())
      Text(vaultURL.path(percentEncoded: false))
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityLabel("Open vault \(vaultURL.lastPathComponent)")
    }
  }

  private var importZone: some View {
    VStack(spacing: 14) {
      Image(systemName: "square.and.arrow.down.on.square")
        .font(.system(size: 42))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text("Drop Activity Packages, GPX, or GeoJSON files here")
        .font(.title3.bold())
      Text("Original files are copied into immutable storage before they are inspected.")
        .foregroundStyle(.secondary)
      Button("Open Files…") { chooseFiles() }
        .buttonStyle(.borderedProminent)
        .disabled(imports.isImporting)
        .accessibilityIdentifier("open-import-files-button")
    }
    .padding(36)
    .frame(maxWidth: .infinity)
    .background(
      isDropTargeted ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 16)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .strokeBorder(isDropTargeted ? Color.accentColor : .secondary.opacity(0.3), lineWidth: 2)
    }
    .dropDestination(for: URL.self) { urls, _ in
      startImport(urls)
      return !urls.isEmpty
    } isTargeted: {
      isDropTargeted = $0
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("file-import-drop-zone")
  }

  @ViewBuilder
  private var importProgress: some View {
    if imports.isImporting || imports.completedCount > 0 {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(imports.currentFilename.map { "Importing \($0)" } ?? "Import complete")
            .font(.headline)
          Spacer()
          if imports.isImporting {
            Button("Cancel") { imports.cancel() }
              .accessibilityIdentifier("cancel-import-button")
          }
        }
        ProgressView(value: imports.progress)
          .accessibilityLabel("Import progress")
          .accessibilityValue("\(imports.completedCount) of \(imports.totalCount) files")
        Text(
          "\(imports.importedCount) imported · \(imports.duplicateCount) already present · \(imports.failures.count) failed"
        )
        .foregroundStyle(.secondary)
      }
      .padding()
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
      .accessibilityIdentifier("import-progress-summary")
    }
  }

  @ViewBuilder
  private var failureList: some View {
    if !imports.failures.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Label("Files that need attention", systemImage: "exclamationmark.triangle")
          .font(.headline)
          .foregroundStyle(.orange)
        ForEach(imports.failures) { failure in
          VStack(alignment: .leading, spacing: 2) {
            Text(failure.filename).bold()
            Text(failure.message).foregroundStyle(.secondary)
          }
        }
      }
      .accessibilityIdentifier("import-errors")
    }
  }

  private var securityReminder: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Keep this archive protected", systemImage: "lock.shield")
        .font(.headline)
      Text(
        "Data remains in your locally stored vault. Keep it outside cloud-synced and network folders. Use FileVault and a backup system, and periodically verify that the backup can be restored."
      )
      .foregroundStyle(.secondary)
      HStack {
        Button("Open Another Vault…") { chooseExistingVault() }
        Button("Close Vault") { Task { await onboarding.closeVault() } }
      }
    }
    .padding()
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
  }

  private func chooseFiles() {
    let panel = NSOpenPanel()
    panel.title = "Import Activity Files"
    panel.prompt = "Import"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = importTypes
    guard panel.runModal() == .OK else { return }
    startImport(panel.urls)
  }

  private func chooseExistingVault() {
    let panel = NSOpenPanel()
    panel.title = "Open Activity Archive Vault"
    panel.prompt = "Open Vault"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await onboarding.openExistingVault(at: url) }
  }

  private func startImport(_ urls: [URL]) {
    let accepted = urls.filter { url in
      ["activitypkg", "gpx", "geojson", "json"].contains(url.pathExtension.lowercased())
    }
    imports.start(urls: accepted, importer: vault)
  }
}
