import SwiftUI

struct ActivityArchiveRootView: View {
  @Bindable var model: ActivityArchiveApplicationModel

  var body: some View {
    Group {
      switch model.onboarding.phase {
      case .checking, .opening:
        ProgressView(
          model.onboarding.phase == .checking ? "Restoring your vault…" : "Opening your vault…"
        )
        .accessibilityIdentifier("vault-opening-progress")
      case .needsSetup, .recoveryRequired:
        VaultSetupView(model: model.onboarding)
      case .ready:
        if let vault = model.onboarding.vault, let url = model.onboarding.vaultURL {
          VaultWorkspaceView(
            vault: vault,
            vaultURL: url,
            onboarding: model.onboarding,
            imports: model.imports
          )
        }
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
