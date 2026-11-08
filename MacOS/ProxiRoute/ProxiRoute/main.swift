import SwiftUI

// one executable, two modes. started with a command line option (--profile, --version, ...)
// it runs without a window (CLIRunner.swift). started normally, from Finder or the Dock,
// it is the app.
//
// The app was called ProxyBridge before, and it is called ProxiRoute now. The
// bundle id is the name of the preferences, so the settings of the old app are
// moved over before anything reads them - or the person would find their rules
// and their proxies gone.
RenameMigration.migrateIfNeeded()

// The settings of a build that was sandboxed live in the container, and a build
// without the sandbox keeps them in the ordinary place. They are moved over
// before anything reads them, or the person would find their rules and proxies
// gone.
PreferencesMigration.migrateIfNeeded()

// the menus macOS brings itself are drawn by the system, in the language of
// the app bundle. the bundle says which languages it speaks, and the language
// the app is in is put in front of them, so that those menus follow the
// language that was chosen in the app and not the one of the system.
UserDefaults.standard.set([L10n.language.rawValue], forKey: "AppleLanguages")

if CLIArguments.isCLI(CommandLine.arguments) {
    CLI.run(arguments: CommandLine.arguments)
} else {
    ProxiRouteGUIApp.main()
}
