import Foundation

/// Brings over what each profile kept for itself that every profile now
/// shares: where tabs go, the tab sidebar, unloading inactive tabs, and the
/// agent's setup, providers and run_task settings move to the app's defaults,
/// and the profiles' skill libraries join one in the root folder. The default
/// profile's settings win and the others' are dropped; its skills come first,
/// then the others' whose names aren't taken. Runs before any profile opens.
@MainActor
enum SharedSettingsMigration {
    private static let keys: Set<String> = [
        "tabLayout", "sidebarCollapsed", "sidebarWidth", "unloadInactiveTabs", "tabUnloadDelay",
        "agent", "agentProviders", "agentInstructions", "agentFolder", "agentTabs",
        "jevModel", "jevTextBaseURL", "jevTextModel", "jevTextReasoning",
    ]
    private static let keyPrefixes = ["agentPath.", "agentTool.", "agentModelOptions."]

    static func run() {
        moveSettings()
        mergeSkills()
    }

    /// The default profile first, or the oldest if it was deleted.
    private static var profiles: [String] {
        let ids = Profiles.all.map(\.id)
        guard ids.contains(Profiles.defaultID) else { return ids }
        return [Profiles.defaultID] + ids.filter { $0 != Profiles.defaultID }
    }

    private static func isShared(_ key: String) -> Bool {
        keys.contains(key) || keyPrefixes.contains { key.hasPrefix($0) }
    }

    /// Takes each shared setting from the first profile, unless the app has
    /// it already, and removes the shared settings from every profile.
    private static func moveSettings() {
        let standard = UserDefaults.standard
        let app = Bundle.main.bundleIdentifier.flatMap(standard.persistentDomain(forName:)) ?? [:]
        for (index, id) in profiles.enumerated() {
            let suite = Profiles.suiteName(for: id)
            guard var domain = standard.persistentDomain(forName: suite) else { continue }
            let shared = domain.keys.filter(isShared)
            guard !shared.isEmpty else { continue }
            for key in shared {
                if index == 0 && app[key] == nil { standard.set(domain[key], forKey: key) }
                domain.removeValue(forKey: key)
            }
            standard.setPersistentDomain(domain, forName: suite)
        }
    }

    /// Moves each profile's skills into the root's library, once, while it
    /// has none. A profile's `agent-skills` goes once all its skills moved;
    /// one whose name was taken stays there.
    private static func mergeSkills() {
        let manager = FileManager.default
        let target = Profiles.root + "/agent-skills"
        guard !manager.fileExists(atPath: target + "/skills.json") else { return }
        var merged: [AgentSkillStore.Entry] = []
        for id in profiles {
            let source = Profiles.folder(for: id) + "/agent-skills"
            guard let data = manager.contents(atPath: source + "/skills.json"),
                let entries = try? JSONDecoder().decode([AgentSkillStore.Entry].self, from: data)
            else { continue }
            var movedAll = true
            for entry in entries {
                if merged.contains(where: { $0.name == entry.name }) {
                    movedAll = false
                    continue
                }
                do {
                    try manager.createDirectory(atPath: target + "/library", withIntermediateDirectories: true)
                    try manager.moveItem(atPath: source + "/library/" + entry.name, toPath: target + "/library/" + entry.name)
                    merged.append(entry)
                } catch {
                    NSLog("Tiller: could not move the skill %@: %@", entry.name, error.localizedDescription)
                    movedAll = false
                }
            }
            if movedAll { try? manager.removeItem(atPath: source) }
        }
        guard !merged.isEmpty else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(merged).write(to: URL(fileURLWithPath: target + "/skills.json"), options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target + "/skills.json")
        } catch {
            NSLog("Tiller: could not merge skills: %@", error.localizedDescription)
        }
    }
}
