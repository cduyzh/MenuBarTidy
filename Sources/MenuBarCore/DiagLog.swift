import Foundation

/// 轻量诊断日志：追加写入 `~/Library/Logs/cduyzhMenuBar/diag.log`。
/// 只在本机排查问题时使用，不上传任何内容。
public enum DiagLog {
    public static let logURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/cduyzhMenuBar/diag.log")

    private static let queue = DispatchQueue(label: "cduyzhMenuBar.diaglog")

    public static func write(_ text: String) {
        queue.sync {
            guard let url = logURL else { return }
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] \(text)\n"
            if let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }
}
