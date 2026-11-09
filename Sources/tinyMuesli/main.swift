import Foundation
import TinyMuesliCore

Settings.noteFirstLaunch()
Settings.migrateFromMuesli()

// One binary: the menu bar app when started with no arguments (or only Cocoa's own, like
// `-NSDocumentRevisionsDebugMode YES` from Xcode), otherwise a CLI. A mistyped command prints the
// usage instead of opening a second menu bar app.
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, CLI.commands.contains(command) || !command.hasPrefix("-") || command.hasPrefix("--") {
    exit(CLI.run(arguments))
}
SingleInstance.claimOrExit()
TinyMuesliApp.main()
