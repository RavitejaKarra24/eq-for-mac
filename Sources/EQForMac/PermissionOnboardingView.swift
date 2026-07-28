import SwiftUI

@available(macOS 14.2, *)
struct PermissionOnboardingView: View {
    @ObservedObject var model: EQViewModel
    @ObservedObject private var permission = PermissionMonitor.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: permission.isGranted ? "checkmark.shield.fill" : "waveform.badge.mic")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(permission.isGranted ? Color.green : Color.accentColor)
                    .symbolEffect(
                        .bounce,
                        options: .nonRepeating,
                        value: permission.isGranted && !reduceMotion
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(permission.isGranted ? "You’re ready" : "Let EQ hear system audio")
                        .font(.title3.weight(.semibold))
                    Text(
                        permission.isGranted
                            ? "Access is confirmed. Audio stays entirely on this Mac."
                            : "macOS calls this Screen & System Audio Recording. EQ for Mac captures audio only long enough to process it—nothing is recorded, stored, or uploaded."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !permission.isGranted {
                VStack(alignment: .leading, spacing: 12) {
                    onboardingStep(
                        number: 1,
                        title: "Request access",
                        detail: "Approve EQ for Mac in the macOS prompt."
                    )
                    onboardingStep(
                        number: 2,
                        title: "Check System Settings",
                        detail: "Enable EQ for Mac under Privacy & Security if macOS opens Settings."
                    )
                    onboardingStep(
                        number: 3,
                        title: "Confirm the audio probe",
                        detail: "Return here and check again. The engine confirms access with a real system-audio tap."
                    )
                }
                .padding(14)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            }

            if let error = model.audioEngine.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if permission.isGranted {
                    Spacer()
                    Button("Start using EQ") {
                        model.completePermissionOnboarding()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Request Access") {
                        model.requestPermissionIfNeeded()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open System Settings") {
                        model.openPermissionSettings()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Check Again") {
                        model.refreshPermission()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.regular)
        }
        .padding(22)
        .frame(width: 470)
        .background(.regularMaterial)
        .onAppear {
            model.refreshPermission()
        }
        .accessibilityElement(children: .contain)
    }

    private func onboardingStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.13), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
