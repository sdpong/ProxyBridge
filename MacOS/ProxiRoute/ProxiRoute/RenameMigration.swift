import Foundation

// Moves the settings of the app that was called ProxyBridge over to the app
// that is called ProxiRoute.
//
// The bundle id of an app is also the name of its preferences: the proxies,
// the rules, the chains and the profiles of the person who runs it live in
// ~/Library/Preferences/<bundle id>.plist. When the app was given a new name
// and a new bundle id, that file was left behind and the new app started with
// nothing - every rule and every proxy gone, as if it had never been there.
//
// The settings are moved, not copied: the old file is removed afterwards, so
// the machine does not keep two sets of rules that only differ in their name.
// The old app itself is not touched - if it is still installed, it starts with
// an empty set of settings of its own.
//
// The move goes through the preferences API and not through the file: the
// preferences daemon has the old place cached, and a file that is copied
// underneath it would be ignored.
enum RenameMigration {

    // the app before the rename
    private static let oldAppId = "com.interceptsuite.ProxyBridge"
    // the app group before the rename
    private static let oldAppGroup = "group.com.interceptsuite.ProxyBridge"
    // the config file the old build wrote into the app group. Nothing reads it
    // any more - the settings live in the preferences - but it is a copy of the
    // same rules, and it goes with the rest.
    private static let oldGroupConfig = "proxybridge-config.json"

    // the key that says the move happened, so it happens once
    private static let doneKey = "renameMigrationDone"

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        // the flag is set even when there was nothing to move, so a build that
        // starts before the old place exists does not look again every time
        defaults.set(true, forKey: doneKey)

        let moved = moveSettings()
        removeOldPlaces()

        if moved > 0 {
            NSLog("ProxiRoute: moved %d setting(s) from the old name.", moved)
        }
    }

    // Copies every setting of the old app into the new one. A setting the new
    // app already has wins: it is the one the running build wrote.
    @discardableResult
    private static func moveSettings() -> Int {
        let defaults = UserDefaults.standard
        var moved = 0

        // the old place has two of them: the ordinary preferences and, for a
        // build that was sandboxed, the ones in the container
        var sources: [[String: Any]] = []
        if let keys = CFPreferencesCopyKeyList(oldAppId as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            for key in keys {
                if let value = CFPreferencesCopyAppValue(key as CFString, oldAppId as CFString) {
                    sources.append([key: value])
                }
            }
        }
        let containerPlist = containerPreferencesURL()
        if let containerPlist,
           let source = NSDictionary(contentsOf: containerPlist) as? [String: Any] {
            sources.append(source)
        }

        for source in sources {
            for (key, value) in source {
                guard defaults.object(forKey: key) == nil else { continue }
                defaults.set(value, forKey: key)
                moved += 1
            }
        }
        defaults.synchronize()
        return moved
    }

    // The preferences of the old app, wherever they are.
    private static func containerPreferencesURL() -> URL? {
        guard let home = FileManager.default.homeDirectoryForCurrentUser as URL? else { return nil }
        let url = home
            .appendingPathComponent("Library/Containers/\(oldAppId)/Data/Library/Preferences/\(oldAppId).plist")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // Takes the old places away.
    //
    // The preferences daemon keeps the old domain in its cache. A file that is
    // removed underneath it is written back the next time something in that
    // domain changes, so the keys are deleted through the API first and the
    // daemon is told that the domain is empty. The file goes as well, for the
    // case that the daemon keeps it around.
    private static func removeOldPlaces() {
        let fm = FileManager.default

        // every key of the old domain is deleted from the daemon
        if let keys = CFPreferencesCopyKeyList(oldAppId as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            for key in keys {
                CFPreferencesSetAppValue(key as CFString, nil, oldAppId as CFString)
            }
            CFPreferencesAppSynchronize(oldAppId as CFString)
        }

        // the files themselves, in the ordinary place and in the container
        var files: [String] = []
        if let home = fm.homeDirectoryForCurrentUser as URL? {
            files.append(home
                .appendingPathComponent("Library/Preferences/\(oldAppId).plist").path)
            files.append(home
                .appendingPathComponent("Library/Containers/\(oldAppId)/Data/Library/Preferences/\(oldAppId).plist").path)
        }
        for file in files where fm.fileExists(atPath: file) {
            try? fm.removeItem(atPath: file)
        }

        // the config file in the old app group
        if let home = fm.homeDirectoryForCurrentUser as URL? {
            let groupConfig = home
                .appendingPathComponent("Library/Group Containers/\(oldAppGroup)/\(oldGroupConfig)")
            if fm.fileExists(atPath: groupConfig.path) {
                try? fm.removeItem(at: groupConfig)
            }
        }
    }
}
