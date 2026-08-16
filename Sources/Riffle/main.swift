import AppKit

if let idx = CommandLine.arguments.firstIndex(of: "--hudtest") {
    let prefix = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : nil
    runHudTest(capturePrefix: prefix)
}
if let idx = CommandLine.arguments.firstIndex(of: "--hudgif"),
   CommandLine.arguments.count > idx + 1 {
    runHudTest(capturePrefix: nil, framesDir: CommandLine.arguments[idx + 1])
}
if let idx = CommandLine.arguments.firstIndex(of: "--vocabtest"),
   CommandLine.arguments.count > idx + 1 {
    runVocabTest(outputPath: CommandLine.arguments[idx + 1])
}
if let idx = CommandLine.arguments.firstIndex(of: "--selftest"),
   CommandLine.arguments.count > idx + 1 {
    exit(runSelfTest(wavPath: CommandLine.arguments[idx + 1]))
}
if let idx = CommandLine.arguments.firstIndex(of: "--summarizetest"),
   CommandLine.arguments.count > idx + 1 {
    let context = CommandLine.arguments.count > idx + 2
        ? CommandLine.arguments[(idx + 2)...].joined(separator: " ")
        : nil
    exit(runSummarizeTest(path: CommandLine.arguments[idx + 1], context: context))
}
if let idx = CommandLine.arguments.firstIndex(of: "--appletest"),
   CommandLine.arguments.count > idx + 1 {
    exit(runAppleTest(raw: CommandLine.arguments[idx + 1]))
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

// pkill and friends deliver SIGTERM, which skips applicationWillTerminate
// and orphans the whisper-server child (1.7 GB each). Route signals into a
// normal terminate so cleanup always runs.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { NSApp.terminate(nil) }
sigtermSource.resume()
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { NSApp.terminate(nil) }
sigintSource.resume()

app.run()
