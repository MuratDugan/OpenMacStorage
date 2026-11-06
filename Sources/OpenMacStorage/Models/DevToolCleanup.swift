import Foundation
import SwiftUI

/// Package managers and dev tools that ship their **own** cleanup command.
/// Running the tool's command (instead of deleting folders by hand) keeps
/// its internal indexes consistent and only drops data it can re-download.
struct DevTool: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: LocalizedStringResource
    let symbol: String
    let color: Color
    /// Binary names to look for, in order of preference.
    let binaries: [String]
    let arguments: [String]
    /// Cache folders measured before/after (relative to the home folder).
    let cachePaths: [String]
    /// The command only removes *part* of the measured folder (e.g. pnpm
    /// prunes unreferenced packages), so the size is an upper bound.
    var sizeIsUpperBound = false
    var environment: [String: String] = [:]

    var absoluteCachePaths: [String] {
        cachePaths.map { NSHomeDirectory() + "/" + $0 }
    }

    static let all: [DevTool] = [
        DevTool(id: "brew", name: "Homebrew",
                detail: "Downloaded bottles and outdated versions. Installed packages stay.",
                symbol: "mug.fill", color: .orange,
                binaries: ["brew"], arguments: ["cleanup", "--prune=all"],
                cachePaths: ["Library/Caches/Homebrew"],
                environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]),
        DevTool(id: "npm", name: "npm",
                detail: "Package download cache. Projects keep their node_modules.",
                symbol: "shippingbox.fill", color: .red,
                binaries: ["npm"], arguments: ["cache", "clean", "--force"],
                cachePaths: [".npm/_cacache"]),
        DevTool(id: "pnpm", name: "pnpm",
                detail: "Removes packages no project references any more.",
                symbol: "shippingbox.circle.fill", color: .yellow,
                binaries: ["pnpm"], arguments: ["store", "prune"],
                cachePaths: ["Library/pnpm/store"],
                sizeIsUpperBound: true),
        DevTool(id: "yarn", name: "Yarn",
                detail: "Package download cache.",
                symbol: "shippingbox", color: .blue,
                binaries: ["yarn"], arguments: ["cache", "clean"],
                cachePaths: ["Library/Caches/Yarn"]),
        DevTool(id: "bun", name: "Bun",
                detail: "Package download cache.",
                symbol: "takeoutbag.and.cup.and.straw.fill", color: .pink,
                binaries: ["bun"], arguments: ["pm", "cache", "rm"],
                cachePaths: [".bun/install/cache"]),
        DevTool(id: "pip", name: "pip",
                detail: "Downloaded wheels. Installed Python packages stay.",
                symbol: "chevron.left.forwardslash.chevron.right", color: .teal,
                binaries: ["pip3", "pip"], arguments: ["cache", "purge"],
                cachePaths: ["Library/Caches/pip"]),
        DevTool(id: "uv", name: "uv",
                detail: "Python package cache. Virtual environments stay.",
                symbol: "bolt.fill", color: .purple,
                binaries: ["uv"], arguments: ["cache", "clean"],
                cachePaths: [".cache/uv"]),
        DevTool(id: "go", name: "Go",
                detail: "Build cache. Rebuilt automatically on the next build.",
                symbol: "hare.fill", color: .cyan,
                binaries: ["go"], arguments: ["clean", "-cache"],
                cachePaths: ["Library/Caches/go-build"]),
        DevTool(id: "pod", name: "CocoaPods",
                detail: "Downloaded pod sources.",
                symbol: "leaf.fill", color: .red,
                binaries: ["pod"], arguments: ["cache", "clean", "--all"],
                cachePaths: ["Library/Caches/CocoaPods"]),
        DevTool(id: "docker", name: "Docker",
                detail: "Stopped containers, dangling images, unused networks and build cache. Volumes and tagged images stay.",
                symbol: "cube.box.fill", color: .blue,
                binaries: ["docker"], arguments: ["system", "prune", "-f"],
                cachePaths: []),
    ]
}

enum DevToolCleanup {
    /// GUI apps don't inherit the shell's PATH, so look in the usual places.
    static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        var dirs = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin",
            home + "/.orbstack/bin", home + "/.local/bin", home + "/.bun/bin",
            home + "/.cargo/bin", home + "/go/bin", "/usr/bin", "/bin"
        ]
        // nvm: newest installed Node first.
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                dirs.insert(nvm + "/" + v + "/bin", at: 0)
            }
        }
        return dirs
    }

    static func locate(_ tool: DevTool) -> String? {
        let fm = FileManager.default
        for name in tool.binaries {
            for dir in searchDirectories {
                let p = dir + "/" + name
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Human-readable command line, shown before anything runs.
    static func commandLine(_ tool: DevTool) -> String {
        ([tool.binaries[0]] + tool.arguments).joined(separator: " ")
    }

    static func measure(_ tool: DevTool) -> Int64 {
        tool.absoluteCachePaths.reduce(0) { $0 + SystemDataAnalyzer.directorySize(at: $1) }
    }

    static func run(_ tool: DevTool) async -> CleanupActions.Result {
        let title = LocalizedStringResource(stringLiteral: tool.name)
        guard let binary = locate(tool) else {
            return .init(title: title, bytesFreed: 0, success: false, message: "Not installed")
        }
        let before = measure(tool)
        let (status, output) = await execute(binary, tool.arguments, extraEnv: tool.environment)
        let after = measure(tool)
        let lastLine = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        let summary = String(lastLine.prefix(200))
        return .init(title: title,
                     bytesFreed: max(0, before - after),
                     success: status == 0,
                     message: status == 0
                        ? (summary.isEmpty ? "Done" : "\(summary)")
                        : "Exited with code \(Int(status)): \(summary)")
    }

    private static func execute(_ binary: String, _ args: [String],
                                extraEnv: [String: String]) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binary)
                proc.arguments = args
                var env = ProcessInfo.processInfo.environment
                // Tools like npm are scripts that need their interpreter on PATH.
                let binDir = (binary as NSString).deletingLastPathComponent
                env["PATH"] = ([binDir] + searchDirectories + [env["PATH"] ?? ""]).joined(separator: ":")
                env["CI"] = "1"   // never wait for interactive prompts
                for (k, v) in extraEnv { env[k] = v }
                proc.environment = env
                proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                proc.standardInput = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                    return
                }
                // Read before waiting so a chatty tool can't fill the pipe and stall.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
