import AppKit
import Foundation

/// One-click updates. Totem checks GitHub for a newer VERSION (or finds a downloaded zip in Downloads),
/// downloads it, unpacks it and runs its install.sh, which updates the browser extension in place,
/// rebuilds this app and relaunches it. The extension reloads itself within a minute.
enum Updater {
    static let repo = "sanjuantala/authenticator"

    /// A newer version: either a zip already in Downloads, or one still on GitHub (zip == nil).
    struct Found: Equatable {
        let zip: URL?
        let version: String
        var sourceLabel: String { zip.map { "\($0.lastPathComponent) in Downloads" } ?? "GitHub" }
    }

    /// The version published on GitHub, or nil when offline.
    static func latestOnline() async -> String? {
        guard let url = URL(string: "https://raw.githubusercontent.com/\(repo)/main/VERSION") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("Totem/\(current)", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let v = String(decoding: result.0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil ? v : nil
    }

    /// Downloads the newest source from GitHub into a temporary zip file.
    static func downloadLatest() async throws -> URL {
        guard let url = URL(string: "https://github.com/\(repo)/archive/refs/heads/main.zip") else { throw URLError(.badURL) }
        let (tmp, res) = try await URLSession.shared.download(from: url)
        guard (res as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("totem-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Totem/update.log")

    /// Newest totem*.zip in Downloads whose VERSION is higher than this app's.
    static func findDownloaded() -> Found? {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let files = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let zips = files.filter { url in
            let name = url.lastPathComponent.lowercased()
            return url.pathExtension.lowercased() == "zip" && (name.hasPrefix("totem") || name.hasPrefix("authenticator"))
        }
            .sorted { modified($0) > modified($1) }
        for zip in zips.prefix(5) {
            if let v = version(in: zip), isNewer(v, than: current) { return Found(zip: zip, version: v) }
        }
        return nil
    }

    /// Reads <top folder>/VERSION from the zip. Works for our release zip ("totem/") and GitHub's
    /// "Download ZIP" ("authenticator-main/").
    static func version(in zip: URL) -> String? {
        guard let listing = run("/usr/bin/unzip", ["-Z1", zip.path]) else { return nil }
        guard let entry = listing.split(separator: "\n").map(String.init)
            .first(where: { $0.split(separator: "/").count == 2 && $0.hasSuffix("/VERSION") }) else { return nil }
        guard let v = run("/usr/bin/unzip", ["-p", zip.path, entry])?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return v.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil ? v : nil
    }

    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Unpacks and installs in the background. The installer quits and relaunches Totem when the build is done.
    static func install(_ zip: URL) throws {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: Data("Updating from \(zip.lastPathComponent) at \(Date())\n".utf8))
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // the zip path is passed as $1, never pasted into the script
        p.arguments = ["-c", """
            set -e
            T="$(mktemp -d)"
            /usr/bin/unzip -q "$1" -d "$T"
            /bin/bash "$(find "$T" -mindepth 2 -maxdepth 2 -name install.sh | head -n 1)"
            """, "totem-update", zip.path]
        p.standardOutput = handle
        p.standardError = handle
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        try p.run()
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
