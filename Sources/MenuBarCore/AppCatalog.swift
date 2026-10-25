import AppKit
import CoreGraphics
import Foundation

/// 应用目录：按 PID 查询运行中应用的名字、bundleID 与图标。
/// 用于在设置界面与状态展示中给出可读的条目来源。
public struct AppCatalogEntry: Sendable {
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let localizedName: String?
    public let icon: NSImage?

    public init(pid: pid_t, bundleIdentifier: String?, localizedName: String?, icon: NSImage?) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.icon = icon
    }
}

public enum AppCatalog {
    private static var cache: [pid_t: AppCatalogEntry] = [:]

    public static func entry(for pid: pid_t) -> AppCatalogEntry? {
        if let cached = cache[pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let entry = AppCatalogEntry(
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            icon: app.icon
        )
        cache[pid] = entry
        return entry
    }

    /// 进程退出后清理缓存。
    public static func purge(except alive: Set<pid_t>) {
        cache = cache.filter { alive.contains($0.key) }
    }

    /// App 的显示名：优先本地化名，其次 bundleID 最后一段，再次进程名。
    public static func displayName(for pid: pid_t, fallback ownerName: String?) -> String {
        if let entry = entry(for: pid) {
            if let name = entry.localizedName, !name.isEmpty { return name }
            if
                let bundleID = entry.bundleIdentifier,
                let last = bundleID.split(separator: ".").last
            {
                return String(last)
            }
        }
        return ownerName ?? "未知来源"
    }
}
