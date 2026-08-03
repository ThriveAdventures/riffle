import Foundation

struct RiffleConfig: Codable {

    // Deterministic find-and-replace applied after the LLM pass.
    // Case-insensitive, whole-word. Guarantees spellings the LLM might miss.
    struct Replacement: Codable, Equatable {
        var find = ""
        var replace = ""
    }

    var hotkey = "fn"                       // fn | right_command | right_option
    var language = "en"                     // whisper language code, or "auto"
    var cleanupEnabled = true
    var cleanupEngine = "ollama"            // ollama | apple (Foundation Models)
    var llmModel = "qwen2.5:7b"
    var summaryModel = ""                   // stronger model for meeting summaries; empty = llm_model
    var ollamaUrl = "http://127.0.0.1:11434"
    var whisperPort = 12391
    var whisperModel = ""                   // empty = default path in Application Support
    var whisperServerBinary = ""            // empty = auto-detect Homebrew install
    var insertMode = "paste"                // paste | type
    var trailingSpace = true
    var restoreClipboard = true
    var sounds = true
    var historyEnabled = true
    var maxRecordSeconds = 240
    var fun = true                          // occasional emoji in the HUD flashes
    var launchAtLogin = true
    var micGraceSeconds = 3.0               // how long the mic stays warm after a dictation
    // Seed with a few examples; put your own names, clients, and jargon here.
    var dictionary: [String] = [
        "Kubernetes", "PostgreSQL", "Ollama", "SKU",
    ]
    var replacements: [Replacement] = []

    enum CodingKeys: String, CodingKey {
        case hotkey
        case language
        case cleanupEnabled = "cleanup_enabled"
        case cleanupEngine = "cleanup_engine"
        case llmModel = "llm_model"
        case summaryModel = "summary_model"
        case ollamaUrl = "ollama_url"
        case whisperPort = "whisper_port"
        case whisperModel = "whisper_model"
        case whisperServerBinary = "whisper_server_binary"
        case insertMode = "insert_mode"
        case trailingSpace = "trailing_space"
        case restoreClipboard = "restore_clipboard"
        case sounds
        case historyEnabled = "history_enabled"
        case maxRecordSeconds = "max_record_seconds"
        case fun
        case launchAtLogin = "launch_at_login"
        case micGraceSeconds = "mic_grace_seconds"
        case dictionary
        case replacements
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RiffleConfig()
        func dec<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        hotkey = dec(.hotkey, d.hotkey)
        language = dec(.language, d.language)
        cleanupEnabled = dec(.cleanupEnabled, d.cleanupEnabled)
        cleanupEngine = dec(.cleanupEngine, d.cleanupEngine)
        llmModel = dec(.llmModel, d.llmModel)
        summaryModel = dec(.summaryModel, d.summaryModel)
        ollamaUrl = dec(.ollamaUrl, d.ollamaUrl)
        whisperPort = dec(.whisperPort, d.whisperPort)
        whisperModel = dec(.whisperModel, d.whisperModel)
        whisperServerBinary = dec(.whisperServerBinary, d.whisperServerBinary)
        insertMode = dec(.insertMode, d.insertMode)
        trailingSpace = dec(.trailingSpace, d.trailingSpace)
        restoreClipboard = dec(.restoreClipboard, d.restoreClipboard)
        sounds = dec(.sounds, d.sounds)
        historyEnabled = dec(.historyEnabled, d.historyEnabled)
        maxRecordSeconds = dec(.maxRecordSeconds, d.maxRecordSeconds)
        fun = dec(.fun, d.fun)
        launchAtLogin = dec(.launchAtLogin, d.launchAtLogin)
        micGraceSeconds = dec(.micGraceSeconds, d.micGraceSeconds)
        dictionary = dec(.dictionary, d.dictionary)
        replacements = dec(.replacements, d.replacements)
    }

    static var dir: URL {
        // Overridable so the CLI test modes can run against a scratch config.
        if let override = ProcessInfo.processInfo.environment["RIFFLE_CONFIG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Riffle")
    }
    static var fileURL: URL { dir.appendingPathComponent("config.json") }
    static var defaultModelPath: String {
        dir.appendingPathComponent("models/ggml-large-v3-turbo.bin").path
    }

    var resolvedWhisperBinary: String {
        if !whisperServerBinary.isEmpty {
            return (whisperServerBinary as NSString).expandingTildeInPath
        }
        for p in ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/opt/homebrew/bin/whisper-server"
    }

    var resolvedWhisperModel: String {
        let p = whisperModel.isEmpty ? RiffleConfig.defaultModelPath : whisperModel
        return (p as NSString).expandingTildeInPath
    }

    static func load() -> RiffleConfig {
        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? JSONDecoder().decode(RiffleConfig.self, from: data) {
            return cfg
        }
        return RiffleConfig()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.fileURL)
        }
    }
}
