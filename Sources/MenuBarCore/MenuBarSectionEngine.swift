import AppKit

/// 分区隐藏引擎：基于 NSStatusItem.length 重排机制实现条目隐藏。
///
/// 原理：macOS ≤ 26 的菜单栏围绕任意 `NSStatusItem.length` 重排——把分隔符
/// 的 length 膨胀到覆盖最宽显示器（上限 10000），其左侧所有条目即被挤出
/// 可见菜单栏；缩回后自动回流。「始终隐藏」分隔符永久膨胀，其左侧条目
/// 永不回归。**不移动其他条目、不与系统的位置记忆对抗。**
///
/// macOS 27 会把过宽分隔符逐出布局（Hidden Bar #360），届时应换用
/// MenuBarClientCore 的 assessment-mode 断言（macOS 27 升级路径）。
public final class MenuBarSectionEngine {
    public enum State: Equatable, Sendable {
        case expanded
        case collapsed
    }

    /// 膨胀后的分隔符长度：覆盖最宽显示器的两倍（系统硬上限 10000pt）。
    public static var collapsedLength: CGFloat {
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        return max(500, min(screenWidth * 2, 10_000))
    }

    /// 展开态的分隔符长度（图标可见）。
    public static let expandedLength: CGFloat = 20

    public private(set) var state: State = .expanded

    /// 分隔符（隐藏分区的右界桩，膨胀主体）。
    public let separatorItem: NSStatusItem
    /// 始终隐藏分隔符（更靠左的界桩，永久膨胀）。
    public let alwaysHiddenItem: NSStatusItem
    /// 箭头（唤出/收回的点击目标，永远可见）。
    public let toggleItem: NSStatusItem

    public private(set) var alwaysHiddenEnabled: Bool

    public init(
        separatorItem: NSStatusItem,
        alwaysHiddenItem: NSStatusItem,
        toggleItem: NSStatusItem,
        alwaysHiddenEnabled: Bool
    ) {
        self.separatorItem = separatorItem
        self.alwaysHiddenItem = alwaysHiddenItem
        self.toggleItem = toggleItem
        self.alwaysHiddenEnabled = alwaysHiddenEnabled
        applyExpandedLengths()
    }

    // MARK: - 状态切换

    /// 收起：隐藏分区条目全部离屏；始终隐藏分区保持离屏。
    public func collapse() {
        state = .collapsed
        separatorItem.length = Self.collapsedLength
        applyAlwaysHiddenLength()
    }

    /// 展开：隐藏分区条目回归；始终隐藏条目保持离屏。
    public func expand() {
        state = .expanded
        separatorItem.length = Self.expandedLength
        applyAlwaysHiddenLength()
    }

    public func toggle() {
        state == .collapsed ? expand() : collapse()
    }

    public func setAlwaysHiddenEnabled(_ enabled: Bool) {
        alwaysHiddenEnabled = enabled
        applyAlwaysHiddenLength()
    }

    /// 显示设置用：临时收起始终隐藏分区（其条目回归，便于拖出）。
    public func temporarilyRevealAlwaysHidden() {
        alwaysHiddenItem.length = Self.expandedLength
    }

    public func restoreAlwaysHidden() {
        applyAlwaysHiddenLength()
    }

    /// 显示器热插拔 / 分辨率变化后重算长度（PR #354 同款防陈旧）。
    public func invalidateLayout() {
        switch state {
        case .collapsed:
            separatorItem.length = Self.collapsedLength
        case .expanded:
            separatorItem.length = Self.expandedLength
        }
        applyAlwaysHiddenLength()
    }

    // MARK: - 私有

    private func applyExpandedLengths() {
        separatorItem.length = state == .collapsed ? Self.collapsedLength : Self.expandedLength
        applyAlwaysHiddenLength()
    }

    private func applyAlwaysHiddenLength() {
        // 「始终隐藏」名副其实：启用即恒定膨胀，其左侧条目在展开/收起
        // 两态下都保持离屏（Hidden Bar 同款）。编辑器搬移时用
        // temporarilyRevealAlwaysHidden() 临时收缩。
        alwaysHiddenItem.length = alwaysHiddenEnabled ? Self.collapsedLength : 0
    }

    // MARK: - 几何分区

    /// 条目窗口按当前分隔符几何划分分区。
    /// 布局（左→右）：[始终隐藏条目][AH 分隔符][隐藏条目][分隔符][可见条目]。
    public static func section(
        ofItemFrame frame: CGRect,
        separatorFrame: CGRect?,
        alwaysHiddenFrame: CGRect?,
        alwaysHiddenEnabled: Bool
    ) -> MenuBarSection {
        guard let separatorFrame else { return .visible }
        if alwaysHiddenEnabled, let ahFrame = alwaysHiddenFrame, frame.maxX <= ahFrame.maxX {
            return .alwaysHidden
        }
        if frame.maxX <= separatorFrame.maxX {
            return .hidden
        }
        return .visible
    }

    /// 引擎能否工作：分隔符位于箭头的隐藏一侧（用户 ⌘-拖拽摆放过）。
    public var isArrangementValid: Bool {
        Self.isItem(separatorItem, onHiddenSideOf: toggleItem)
    }

    public var isAlwaysHiddenSeparatorPlaced: Bool {
        Self.isItem(alwaysHiddenItem, onHiddenSideOf: separatorItem)
    }

    /// `item` 是否在 `boundary` 的隐藏一侧（LTR 布局下即其左侧）。
    /// 任一方未上屏时返回 false（无从判断）。
    public static func isItem(_ item: NSStatusItem?, onHiddenSideOf boundary: NSStatusItem?) -> Bool {
        guard
            let itemX = item?.button?.window?.frame.origin.x,
            let boundaryX = boundary?.button?.window?.frame.origin.x
        else { return false }
        return boundaryX >= itemX
    }
}
