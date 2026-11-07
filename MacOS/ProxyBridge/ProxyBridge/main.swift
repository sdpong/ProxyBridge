import SwiftUI

// one executable, two modes. started with a command line option (--profile, --version, ...)
// it runs without a window (CLIRunner.swift). started normally, from Finder or the Dock,
// it is the app.
//
// The settings of a build that was sandboxed live in the container, and a build
// without the sandbox keeps them in the ordinary place. They are moved over
// before anything reads them, or the person would find their rules and proxies
// gone.
PreferencesMigration.migrateIfNeeded()

if CLIArguments.isCLI(CommandLine.arguments) {
    CLI.run(arguments: CommandLine.arguments)
} else {
    ProxyBridgeGUIApp.main()
}
