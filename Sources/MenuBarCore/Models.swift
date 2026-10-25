import CoreGraphics

/// 菜单栏分区。语义与 Thaw（Ice 系）一致：
/// 左起依次为「始终隐藏」「隐藏」「可见」，各自以一个控制条目为界。
public enum MenuBarSection: String, Codable, CaseIterable, Sendable {
    case visible
    case hidden
    case alwaysHidden

    public var displayName: String {
        switch self {
        case .visible: "可见"
        case .hidden: "隐藏"
        case .alwaysHidden: "始终隐藏"
        }
    }

    public var iconName: String {
        switch self {
        case .visible: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "eye.slash.fill"
        }
    }
}

/// 条目的稳定身份：源 App 的规范 bundleID（或进程名）+ 窗口标题 + 同名序号。
/// 与窗口 ID（每次创建会变）不同，该身份跨重启稳定，用于持久化分区归属。
public struct ItemIdentity: Hashable, Codable, Sendable, Comparable {
    public var namespace: String
    public var title: String
    public var instanceIndex: Int

    public init(namespace: String, title: String, instanceIndex: Int = 0) {
        self.namespace = namespace
        self.title = title
        self.instanceIndex = instanceIndex
    }

    public var stableID: String {
        let encodedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\c")
        return "\(namespace):\(encodedTitle):\(instanceIndex)"
    }

    public static func < (lhs: ItemIdentity, rhs: ItemIdentity) -> Bool {
        if lhs.namespace != rhs.namespace { return lhs.namespace < rhs.namespace }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.instanceIndex < rhs.instanceIndex
    }
}

/// 一次快照中某菜单栏条目的完整观测值。坐标为 CG 全局坐标（原点左上、Y 向下）。
public struct MenuBarItemSnapshot: Identifiable, Equatable, Sendable {
    public var windowID: Int
    public var identity: ItemIdentity
    public var sourcePID: pid_t?
    public var ownerPID: pid_t
    public var ownerName: String?
    public var displayName: String
    public var bundleIdentifier: String?
    public var frame: CGRect
    public var isOnScreen: Bool

    public var id: Int { windowID }

    public init(
        windowID: Int,
        identity: ItemIdentity,
        sourcePID: pid_t?,
        ownerPID: pid_t,
        ownerName: String?,
        displayName: String,
        bundleIdentifier: String?,
        frame: CGRect,
        isOnScreen: Bool
    ) {
        self.windowID = windowID
        self.identity = identity
        self.sourcePID = sourcePID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}

/// 控制条目（分区分隔符）的标识。
public enum ControlItemKind: String, CaseIterable, Sendable {
    case hiddenDivider
    case alwaysHiddenDivider

    public var autosaveName: String {
        switch self {
        case .hiddenDivider: "cduyzhMenuBar.divider.hidden"
        case .alwaysHiddenDivider: "cduyzhMenuBar.divider.alwaysHidden"
        }
    }
}
