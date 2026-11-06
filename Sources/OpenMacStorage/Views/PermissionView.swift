import SwiftUI

/// Guided Full Disk Access flow. Shows live status, deep-links into System
/// Settings, and detects the grant automatically (polling every 1.5 s while
/// visible) — the moment access lands, the UI flips to a success state with a
/// restart button.
struct PermissionView: View {
    let onClose: () -> Void

    @State private var granted: Bool = FullDiskAccess.isGranted()
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if granted {
                grantedContent
            } else {
                stepsContent
            }

            Divider()

            HStack {
                if !granted {
                    Button("Continue with limited access") { onClose() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Spacer()
                if granted {
                    Button("Later") { onClose() }
                    Button {
                        FullDiskAccess.restartApp()
                    } label: {
                        Label("Restart Now", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill((granted ? Color.green : Color.orange).opacity(0.16))
                    .frame(width: 52, height: 52)
                Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(granted ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Full Disk Access")
                    .font(.title2.bold())
                Text(granted
                     ? "Access granted — you're all set."
                     : "Required for a complete scan without permission pop-ups.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Not granted: steps

    private var stepsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Without it, macOS shows a separate permission pop-up for every protected folder (Desktop, Documents, Photos, Mail…) and hides the rest of your disk from the scan. One switch fixes all of it:")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(number: 1,
                 text: "Open **System Settings → Privacy & Security → Full Disk Access**.")
            step(number: 2,
                 text: "Find **OpenMacStorage** in the list and turn it **on**. If it's not listed, click **+** and pick it from Applications, or drag the app in from Finder.")
            step(number: 3,
                 text: "Come back here — the app detects the change automatically.")

            HStack(spacing: 10) {
                Button {
                    FullDiskAccess.openSystemSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gearshape.fill")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    FullDiskAccess.revealAppInFinder()
                } label: {
                    Label("Show App in Finder", systemImage: "magnifyingglass")
                }
                .controlSize(.large)

                Spacer()

                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)

            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.blue)
                Text("Privacy: everything stays on your Mac. The app has no network features, no analytics — the source code is public.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
        }
    }

    private func step(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold().monospaced())
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(.orange)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Granted: success

    private var grantedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "party.popper.fill").foregroundStyle(.green)
                Text("Full Disk Access is on. No more pop-ups, and scans will cover everything — including Mail, Messages, and app containers.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("A restart is recommended so the scanner picks the permission up cleanly.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.10)))
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                let now = FullDiskAccess.isGranted()
                if now != granted {
                    withAnimation(.easeInOut(duration: 0.25)) { granted = now }
                }
            }
        }
    }
}
