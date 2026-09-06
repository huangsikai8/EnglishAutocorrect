import Cocoa
import InputMethodKit

private let appDelegate = AppDelegate()

autoreleasepool {
    NSApplication.shared.delegate = appDelegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
