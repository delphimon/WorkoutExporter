import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VaultSetupView: View {
  @Bindable var model: VaultOnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 28) {
      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: "figure.hiking")
          .font(.system(size: 46))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        Text("Activity Archive")
          .font(.largeTitle.bold())
        Text("A durable, local home for your activity history.")
          .font(.title3)
          .foregroundStyle(.secondary)
      }

      if model.phase == .recoveryRequired {
        Label {
          VStack(alignment: .leading, spacing: 4) {
            Text("Vault access needs to be restored").bold()
            Text(model.message ?? "Choose your existing vault again to continue.")
          }
        } icon: {
          Image(systemName: "externaldrive.badge.exclamationmark")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("vault-recovery-message")
      }

      VStack(alignment: .leading, spacing: 14) {
        Label("Stored only in the folder you choose", systemImage: "internaldrive")
        Label("Original imports remain unchanged", systemImage: "checkmark.seal")
        Label("Protected by your Mac and volume security", systemImage: "lock.shield")
      }
      .font(.headline)

      Text(
        "Choose a folder stored locally on this Mac, not a cloud-synced or network location. Activity Archive does not upload your health or route data. Turn on FileVault and include the vault in a backup you periodically verify. A backup is only trustworthy after you have tested that it can be restored."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("vault-security-guidance")

      HStack(spacing: 12) {
        Button("Create New Vault") { chooseNewVault() }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("create-vault-button")
        Button("Open Existing Vault") { chooseExistingVault() }
          .accessibilityIdentifier("open-vault-button")
      }
      .disabled(model.phase == .opening)
    }
    .padding(48)
    .frame(maxWidth: 680, alignment: .leading)
  }

  private func chooseNewVault() {
    let panel = NSSavePanel()
    panel.title = "Create Activity Archive Vault"
    panel.prompt = "Create Vault"
    panel.nameFieldStringValue = "ActivityArchive"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.folder]
    guard panel.runModal() == .OK, let url = panel.url else {
      model.selectionCancelled()
      return
    }
    Task { await model.createVault(at: url) }
  }

  private func chooseExistingVault() {
    let panel = NSOpenPanel()
    panel.title = "Open Activity Archive Vault"
    panel.prompt = "Open Vault"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else {
      model.selectionCancelled()
      return
    }
    Task { await model.openExistingVault(at: url) }
  }
}
