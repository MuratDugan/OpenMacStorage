import SwiftUI
import AppKit

extension Notification.Name {
    static let showDisclaimer = Notification.Name("OpenMacStorage.showDisclaimer")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first {
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OpenMacStorageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var model = ScanModel()

    private static let githubURL = URL(string: "https://github.com/MuratDugan/OpenMacStorage")!
    private static let issuesURL = URL(string: "https://github.com/MuratDugan/OpenMacStorage/issues/new")!

    /// Languages exposed in the menubar's Language submenu. Each is shown in
    /// its own native name (Apple convention).
    struct SupportedLanguage {
        let code: String
        let nativeName: String
    }
    static let supportedLanguages: [SupportedLanguage] = [
        .init(code: "en",      nativeName: "English"),
        .init(code: "tr",      nativeName: "Türkçe"),
        .init(code: "zh-Hans", nativeName: "简体中文"),
        .init(code: "es",      nativeName: "Español"),
        .init(code: "pt-BR",   nativeName: "Português (Brasil)"),
        .init(code: "ru",      nativeName: "Русский"),
        .init(code: "de",      nativeName: "Deutsch"),
        .init(code: "fr",      nativeName: "Français"),
        .init(code: "ja",      nativeName: "日本語"),
    ]

    var body: some Scene {
        WindowGroup("OpenMacStorage") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
                .task { model.loadLastScan() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // Replace the Apple-menu "About OpenMacStorage" with a richer panel.
            CommandGroup(replacing: .appInfo) {
                Button("About OpenMacStorage") { showAbout() }
            }
            // Add a "Language" submenu directly in the app menu (right after
            // About), so users don't need to dig through Settings to switch.
            // Each entry shows the language in its own native name.
            CommandGroup(after: .appInfo) {
                Menu("Language") {
                    Button("System Default") { changeLanguage("") }
                    Divider()
                    ForEach(Self.supportedLanguages, id: \.code) { lang in
                        Button(lang.nativeName) { changeLanguage(lang.code) }
                    }
                }
            }
            // Replace the default Help menu (which would otherwise launch a
            // missing help book) with useful links.
            CommandGroup(replacing: .help) {
                Button("OpenMacStorage on GitHub") { open(Self.githubURL) }
                Button("Report an Issue") { open(Self.issuesURL) }
                Button("Send Feedback…") {
                    open(URL(string: "mailto:muratkaya665@gmail.com?subject=OpenMacStorage%20Feedback")!)
                }
                Divider()
                Button("Disclaimer & Liability…") {
                    NotificationCenter.default.post(name: .showDisclaimer, object: nil)
                }
            }
        }

        // Apple menu's "Settings…" item — auto-added by SwiftUI when a Settings
        // scene exists. macOS picks the right keyboard shortcut (⌘,) and label.
        Settings {
            SettingsView()
        }
    }

    // MARK: - About panel

    /// Shows the standard macOS About panel with custom credits + a clickable link.
    private func showAbout() {
        let creditsString = NSMutableAttributedString()

        let body = NSAttributedString(
            string: NSLocalizedString(
                "A free, open-source disk space analyzer for macOS.\n\nMade by Murat Duğan with AI assistance.\nLicensed under MIT.\n\n",
                comment: "About panel body"
            ),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor
            ]
        )
        creditsString.append(body)

        let linkText = "github.com/MuratDugan/OpenMacStorage"
        let link = NSAttributedString(
            string: linkText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.linkColor,
                .link: Self.githubURL
            ]
        )
        creditsString.append(link)

        // Center-align everything in the panel.
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        creditsString.addAttribute(.paragraphStyle,
                                   value: para,
                                   range: NSRange(location: 0, length: creditsString.length))

        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.credits: creditsString,
            NSApplication.AboutPanelOptionKey.applicationName: "OpenMacStorage",
            NSApplication.AboutPanelOptionKey.applicationVersion: "1.0",
            NSApplication.AboutPanelOptionKey.version: "1",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                "© 2026 Murat Duğan. MIT License."
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Language switching from the menubar

    /// Persists the new language preference and prompts the user to restart so
    /// SwiftUI/Bundle pick up the new locale (a clean restart is the only way
    /// macOS reliably reloads `Localizable.strings`).
    private func changeLanguage(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()

        let alert = NSAlert()
        alert.messageText = String(localized: "Restart Required")
        alert.informativeText = String(localized: "OpenMacStorage needs to restart for the language change to take effect.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            let path = Bundle.main.bundlePath
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "sleep 0.5 && /usr/bin/open '\(path)'"]
            try? task.run()
            NSApp.terminate(nil)
        }
    }
}
