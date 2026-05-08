import SwiftUI
import AppKit

/// Application settings — exposed via the Apple menu's "Settings…" item.
struct SettingsView: View {
    @AppStorage("preferredLanguage") private var preferredLanguage: String = ""
    @State private var pendingRestart = false

    /// Each language is shown in its own native name (Apple convention) so users
    /// can find their language even when the current UI is in another tongue.
    private struct Lang: Identifiable {
        var id: String { code }
        let code: String
        let nativeName: String
    }

    private let languages: [Lang] = [
        .init(code: "",         nativeName: "—"),   // System default placeholder
        .init(code: "en",       nativeName: "English"),
        .init(code: "tr",       nativeName: "Türkçe"),
        .init(code: "zh-Hans",  nativeName: "简体中文"),
        .init(code: "es",       nativeName: "Español"),
        .init(code: "pt-BR",    nativeName: "Português (Brasil)"),
        .init(code: "ru",       nativeName: "Русский"),
        .init(code: "de",       nativeName: "Deutsch"),
        .init(code: "fr",       nativeName: "Français"),
        .init(code: "ja",       nativeName: "日本語"),
    ]

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 260)
        .alert("Restart Required", isPresented: $pendingRestart) {
            Button("Later") {}
            Button("Restart Now") { restartApp() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("OpenMacStorage needs to restart for the language change to take effect.")
        }
    }

    private var generalTab: some View {
        Form {
            Picker(selection: $preferredLanguage) {
                Text("System Default").tag("")
                Divider()
                ForEach(languages.dropFirst()) { lang in
                    Text(lang.nativeName).tag(lang.code)
                }
            } label: {
                Text("Language")
            }
            .pickerStyle(.menu)
            .onChange(of: preferredLanguage) { _, new in
                applyLanguage(new)
            }

            Text("The app will restart to apply the new language.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func applyLanguage(_ code: String) {
        if code.isEmpty {
            // Hand language back to the system.
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        pendingRestart = true
    }

    /// Re-launches the app cleanly so the new locale picks up.
    private func restartApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        // Wait briefly for the current instance to exit, then re-open.
        task.arguments = ["-c", "sleep 0.5 && /usr/bin/open '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
    }
}
