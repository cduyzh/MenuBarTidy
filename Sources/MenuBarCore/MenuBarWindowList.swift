import AppKit
import CoreGraphics
import Foundation

/// 菜单栏条目窗口的原始枚举。使用公开的 CGWindowList API：
/// 状态条目窗口位于状态窗口层级（25），贴着某个显示器顶部的菜单栏条带。
/// 隐藏条目被水平移出屏幕（x < 0）但保留 Y 与宽度，因此同样能被枚举到。
public enum MenuBarWindowList {
    public struct ItemWindow: Equatable, Sendable {
        public let windowID: Int
        public let ownerPID: pid_t
        public let ownerName: String?
        public let title: String?
        public let frame: CGRect
        public let isOnScreen: Bool
        public let layer: Int

        public init(
            windowID: Int,
            ownerPID: pid_t,
            ownerName: String?,
            title: String?,
            frame: CGRect,
            isOnScreen: Bool,
            layer: Int
        ) {
            self.windowID = windowID
            self.ownerPID = ownerPID
            self.ownerName = ownerName
            self.title = title
            self.frame = frame
            self.isOnScreen = isOnScreen
            self.layer = layer
        }
    }

    /// 状态条目窗口所在层级（NSStatusWindowLevel）。
    public static let statusWindowLevel = 25
    /// 菜单栏条带的最大高度（点）。
    public static let menuBarStripHeight: CGFloat = 40

    /// 枚举当前所有菜单栏条目窗口（含屏外隐藏条目与自身控制条目）。
    /// 返回按 x 升序排列的列表。读取 owner/层级/矩形不需要任何权限；
    /// 窗口标题（kCGWindowName）自 macOS 10.15 起需要屏幕录制权限，读不到时为 nil。
    public static func itemWindows(owningPIDFilter pid: pid_t? = nil) -> [ItemWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) else {
            return []
        }
        guard let entries = raw as? [[String: Any]] else { return [] }

        let strips = menuBarStrips()
        var windows: [ItemWindow] = []

        for entry in entries {
            guard let number = entry[kCGWindowNumber as String] as? Int else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int else { continue }
            guard layer == statusWindowLevel else { continue }
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int else { continue }
            if let pid, ownerPID != pid { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            guard let frame = CGRect(windowListBounds: boundsDict) else { continue }
            guard frame.width > 0, frame.height > 0, frame.height <= menuBarStripHeight else { continue }

            let midY = frame.midY
            let inSomeStrip = strips.contains { strip in
                midY >= strip.minY && midY <= strip.maxY
            }
            guard inSomeStrip else { continue }

            windows.append(
                ItemWindow(
                    windowID: Int(number),
                    ownerPID: pid_t(ownerPID),
                    ownerName: entry[kCGWindowOwnerName as String] as? String,
                    title: entry[kCGWindowName as String] as? String,
                    frame: frame,
                    isOnScreen: (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                    layer: layer
                )
            )
        }

        return windows.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// 读取单个窗口的当前矩形。窗口消失（App 退出/条目移除）时返回 nil。
    /// macOS 26 起窗口编号可为 64 位，不能经 UInt32 的 CGWindowID 传参查询，
    /// 因此在完整列表中按编号匹配。
    public static func frame(ofWindowID windowID: Int) -> CGRect? {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) else { return nil }
        guard let entries = raw as? [[String: Any]] else { return nil }
        for entry in entries {
            guard let number = entry[kCGWindowNumber as String] as? Int else { continue }
            guard number == windowID else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(windowListBounds: boundsDict)
        }
        return nil
    }

    /// 各显示器顶部菜单栏条带（CG 全局坐标，原点左上）。
    public static func menuBarStrips() -> [CGRect] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &ids, nil) == .success else { return [] }
        return ids.map { id in
            let bounds = CGDisplayBounds(id)
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: menuBarStripHeight)
        }
    }
}

extension CGRect {
    /// 从 CGWindowList 的 bounds 字典构造矩形。
    init?(windowListBounds dict: [String: Any]) {
        guard
            let x = dict["X"] as? CGFloat ?? dict["x"] as? CGFloat,
            let y = dict["Y"] as? CGFloat ?? dict["y"] as? CGFloat,
            let width = dict["Width"] as? CGFloat ?? dict["width"] as? CGFloat,
            let height = dict["Height"] as? CGFloat ?? dict["height"] as? CGFloat
        else { return nil }
        self.init(x: x, y: y, width: width, height: height)
    }
}
