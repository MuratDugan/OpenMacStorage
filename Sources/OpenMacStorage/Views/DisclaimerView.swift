import SwiftUI
import AppKit

/// First-launch (and on-demand) liability disclaimer.
/// Stored acceptance lives in `UserDefaults` under `hasAcceptedDisclaimer`.
struct DisclaimerView: View {
    @State private var checked = false
    let onAccept: () -> Void
    /// `true` when shown after first launch (re-opened from Help menu).
    /// In that case the "Quit" button becomes "Close" and acceptance is read-only.
    var isReview: Bool = false
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Before You Continue")
                    .font(.title.bold())
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("OpenMacStorage helps you find and delete files. While we've designed it to be careful — destructive actions ask for confirmation, **Move to Trash** is recoverable, and system-critical paths are skipped by default — **you are ultimately responsible for what gets deleted.**")

                    Text("By using OpenMacStorage you agree:")
                        .font(.headline)

                    bullet("This software is provided **\"as is\"**, without warranty of any kind (MIT License).")
                    bullet("The author is **not liable** for any data loss, broken applications, or system issues caused by using this app.")
                    bullet("You will keep recent backups (Time Machine or similar) before running cleanup operations.")
                    bullet("You will review what is about to be deleted before confirming.")
                    bullet("This app was built with AI assistance by a non-professional developer. The source code is open and auditable on GitHub — please review it if your situation requires it.")

                    Text("Operations that **cannot be undone**:")
                        .font(.headline)
                        .padding(.top, 4)

                    bullet("Empty Trash")
                    bullet("Empty Contents on directories")
                    bullet("Deleting APFS local snapshots")
                    bullet("Deleting Xcode DerivedData, archives, or simulators")
                    bullet("Permanently removing application support / cache files via Uninstall App")
                }
                .padding(.trailing, 8)
            }
            .frame(maxHeight: 360)

            Divider()

            if !isReview {
                Toggle(isOn: $checked) {
                    Text("I understand and accept these terms.")
                        .font(.body.bold())
                }
            }

            HStack {
                if isReview {
                    Spacer()
                    Button("Close") { onClose?() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Quit") {
                        // The disclaimer is presented as a modal sheet which can
                        // sometimes block `NSApp.terminate`. Hop to the next
                        // runloop tick first, and fall back to `exit(0)` if the
                        // graceful path doesn't fire within a moment.
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            exit(0)
                        }
                    }
                    Spacer()
                    Button("Continue") { onAccept() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!checked)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 580)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
        }
    }
}
