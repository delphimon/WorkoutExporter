import SwiftUI
import UIKit

struct AuthorizationView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var authorizationCompleted: Bool
    @State private var isRequesting = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Your workouts.\nYour files.")
                    .font(.largeTitle.bold())

                Text("Workout Exporter reads workouts and associated route, heart-rate, energy, distance, cadence, power, and other workout data from Apple Health.")
                    .font(.title3)

                PrivacyPoint(
                    icon: "iphone",
                    title: "Processed on this iPhone",
                    detail: "No account, analytics, advertising, or server upload."
                )
                PrivacyPoint(
                    icon: "square.and.arrow.up",
                    title: "Export only when you choose",
                    detail: "You decide where files go using the system share sheet."
                )
                PrivacyPoint(
                    icon: "hand.raised",
                    title: "Read only",
                    detail: "The app does not write workouts or samples to Health."
                )

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Authorization error: \(errorMessage)")
                }

                Button {
                    requestAccess()
                } label: {
                    HStack {
                        if isRequesting { ProgressView().tint(.white) }
                        Text("Review Health Access")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequesting)

                #if DEBUG
                Button("Explore with Sample Workouts") {
                    environment.useSyntheticData()
                    authorizationCompleted = true
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.bordered)
                #endif

                Button("Review permissions in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote)
            }
            .padding(24)
        }
        .navigationTitle("Welcome")
    }

    private func requestAccess() {
        isRequesting = true
        errorMessage = nil
        Task {
            defer { isRequesting = false }
            do {
                try await environment.healthClient.requestReadAuthorization()
                authorizationCompleted = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PrivacyPoint: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}
