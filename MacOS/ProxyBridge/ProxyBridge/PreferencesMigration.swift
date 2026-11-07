import Foundation

// Moves the settings of a sandboxed build over to the place a build without the
// sandbox keeps them.
//
// A sandboxed app keeps its preferences in its container
// (~/Library/Containers/<bundle id>/Data/Library/Preferences/<bundle id>.plist)
// and an app without the sandbox keeps them in the ordinary place
// (~/Library/Preferences/<bundle id>.plist).
//
// The settings of the person who runs the app - their proxies, their rules,
// their profile - must not be lost when the build changes, so they are copied
// over once. The copy goes through the defaults API and not through the file:
// the preferences daemon has the new place cached, and a file that is copied
// underneath it would be ignored.
enum PreferencesMigration {
    // the key that says the move happened, so it happens once
    private static let doneKey = "containerPreferencesMigrated"

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        // the flag is set even when there was nothing to move, so a build that
        // starts before the container exists does not look again every time
        defaults.set(true, forKey: doneKey)

        let fm = FileManager.default
        guard let bundleID = Bundle.main.bundleIdentifier,
              let home = fm.homeDirectoryForCurrentUser as URL? else { return }

        let containerPlist = home
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")
        guard fm.fileExists(atPath: containerPlist.path),
              let source = NSDictionary(contentsOf: containerPlist) as? [String: Any] else { return }

        var moved = 0
        for (key, value) in source {
            // the new place wins when it already has the key: it is the one the
            // running build wrote
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            moved += 1
        }
        defaults.synchronize()

        if moved > 0 {
            NSLog("ProxyBridge: moved %d setting(s) out of the old container.", moved)
        }
    }
}
