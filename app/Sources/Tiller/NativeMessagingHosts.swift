import Foundation

/// Lets extensions reach the Mac apps they talk to, such as 1Password. Those
/// apps install a manifest for Chrome, which Chromium looks for in its own
/// folder, so each launch links Chrome's manifests there. Links follow the
/// apps' updates to them. A file put there by hand is left alone.
enum NativeMessagingHosts {
    /// Chrome's folders, the user's first, as Chrome prefers its manifests.
    private static let sources = [
        NSHomeDirectory() + "/Library/Application Support/Google/Chrome/NativeMessagingHosts",
        "/Library/Google/Chrome/NativeMessagingHosts",
    ]

    static var folder: String { Profiles.chromiumRoot + "/NativeMessagingHosts" }

    static func link() {
        let manager = FileManager.default
        var wanted: [String: String] = [:]
        for source in sources.reversed() {
            for name in (try? manager.contentsOfDirectory(atPath: source)) ?? [] where name.hasSuffix(".json") {
                wanted[name] = source + "/" + name
            }
        }
        try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Drops links whose manifest is gone or now comes from elsewhere.
        for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] {
            let path = folder + "/" + name
            guard let target = try? manager.destinationOfSymbolicLink(atPath: path) else { continue }
            if wanted[name] != target { try? manager.removeItem(atPath: path) }
        }
        for (name, target) in wanted where !manager.fileExists(atPath: folder + "/" + name) {
            try? manager.createSymbolicLink(atPath: folder + "/" + name, withDestinationPath: target)
        }
    }
}
