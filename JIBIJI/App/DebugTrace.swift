import Foundation

#if DEBUG
/// Debug-only step log written to Documents/trace.log so a hang on a physical iPad can be located without a console.
enum DebugTrace {
    private static let lock = NSLock()
    static func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("trace.log")
        // Keep the log small: start over past 1 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let line = "\(Date().timeIntervalSince1970) [\(Thread.isMainThread ? "main" : "bg")] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.synchronize(); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
#endif
