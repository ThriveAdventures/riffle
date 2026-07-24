import AppKit

if let idx = CommandLine.arguments.firstIndex(of: "--hudtest") {
    let prefix = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : nil
    runHudTest(capturePrefix: prefix)
}
if let idx = CommandLine.arguments.firstIndex(of: "--selftest"),
   CommandLine.arguments.count > idx + 1 {
    exit(runSelfTest(wavPath: CommandLine.arguments[idx + 1]))
}
if let idx = CommandLine.arguments.firstIndex(of: "--cleantest"),
   CommandLine.arguments.count > idx + 1 {
    let app = CommandLine.arguments.count > idx + 2 ? CommandLine.arguments[idx + 2] : nil
    exit(runCleanTest(raw: CommandLine.arguments[idx + 1], app: app))
}
if let idx = CommandLine.arguments.firstIndex(of: "--edittest"),
   CommandLine.arguments.count > idx + 2 {
    exit(runEditTest(text: CommandLine.arguments[idx + 1],
                     instruction: CommandLine.arguments[idx + 2]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
