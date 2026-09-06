import Cocoa
import InputMethodKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        SymSpellChecker.shared.loadIfNeeded()
        HunspellChecker.shared.loadIfNeeded()

        guard let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            fatalError("Missing InputMethodConnectionName or bundle identifier in Info.plist")
        }
        server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)
    }
}
