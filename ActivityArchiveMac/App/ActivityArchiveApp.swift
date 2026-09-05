import SwiftUI

@main
struct ActivityArchiveApp: App {
  @State private var model = ActivityArchiveApplicationModel.makeForCurrentProcess()

  var body: some Scene {
    WindowGroup {
      ActivityArchiveRootView(model: model)
        .frame(minWidth: 760, minHeight: 560)
        .task { await model.restoreVaultIfNeeded() }
    }
    .defaultSize(width: 980, height: 680)
  }
}
