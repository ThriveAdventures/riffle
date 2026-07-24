import Foundation

enum Log {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Riffle")
    }
    static var file: URL { dir.appendingPathComponent("riffle.log") }

    private static let queue = DispatchQueue(label: "riffle.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
    }
}
