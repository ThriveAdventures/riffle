import AppKit

if let idx = CommandLine.arguments.firstIndex(of: "--selftest"),
   CommandLine.arguments.count > idx + 1 {
    exit(runSelfTest(wavPath: CommandLine.arguments[idx + 1]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
