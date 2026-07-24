import SwiftUI

struct RootView: View {
    @AppStorage("authorizationRequestCompleted") private var authorizationCompleted = false

    var body: some View {
        NavigationStack {
            if authorizationCompleted {
                WorkoutListView()
            } else {
                AuthorizationView(authorizationCompleted: $authorizationCompleted)
            }
        }
    }
}
