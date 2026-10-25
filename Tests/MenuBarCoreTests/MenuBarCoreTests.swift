import AppKit
import CoreGraphics
import MenuBarCore
import Testing

@testable import MenuBarCore

// MARK: - 测试夹具

func makeItem(
    windowID: Int,
    namespace: String = "com.example.app",
    title: String = "",
    x: CGFloat,
    y: CGFloat = 0,
    width: CGFloat,
    height: CGFloat = 22
) -> MenuBarItemSnapshot {
    MenuBarItemSnapshot(
        windowID: windowID,
        identity: ItemIdentity(namespace: namespace, title: title),
        sourcePID: nil,
        ownerPID: 100,
        ownerName: "App",
        displayName: "App",
        bundleIdentifier: nil,
        frame: CGRect(x: x, y: y, width: width, height: height),
        isOnScreen: true
    )
}

// MARK: - 引擎长度数学

@Suite struct MenuBarSectionEngineTests {
    @Test func collapsedLengthBounds() {
        // 覆盖最宽显示器两倍，夹在 [500, 10000]（Hidden Bar PR #354 同款）。
        #expect(MenuBarSectionEngine.collapsedLength >= 500)
        #expect(MenuBarSectionEngine.collapsedLength <= 10_000)
    }

    @Test func expandedLengthIsSmall() {
        #expect(MenuBarSectionEngine.expandedLength == 20)
    }
}

// MARK: - 几何分区

@Suite struct SectionGeometryTests {
    // 布局（左→右）：[AH 条目 x~100][AH 分隔符 x400 w28][隐藏条目 x600][分隔符 x900 w28][可见条目 x1100]
    private let separator = CGRect(x: 900, y: 0, width: 28, height: 22)
    private let ahSeparator = CGRect(x: 400, y: 0, width: 28, height: 22)

    private func section(
        of frame: CGRect,
        ahEnabled: Bool = true
    ) -> MenuBarSection {
        MenuBarSectionEngine.section(
            ofItemFrame: frame,
            separatorFrame: separator,
            alwaysHiddenFrame: ahSeparator,
            alwaysHiddenEnabled: ahEnabled
        )
    }

    @Test func visibleItemsAreRightOfSeparator() {
        #expect(section(of: CGRect(x: 1100, y: 0, width: 30, height: 22)) == .visible)
        #expect(section(of: CGRect(x: 929, y: 0, width: 10, height: 22)) == .visible)
    }

    @Test func hiddenItemsAreBetweenSeparators() {
        #expect(section(of: CGRect(x: 600, y: 0, width: 30, height: 22)) == .hidden)
        #expect(section(of: CGRect(x: 429, y: 0, width: 10, height: 22)) == .hidden)
    }

    @Test func alwaysHiddenItemsAreLeftOfAHSeparator() {
        #expect(section(of: CGRect(x: 100, y: 0, width: 30, height: 22)) == .alwaysHidden)
    }

    @Test func collapsedOffscreenPositions() {
        // 收起态：分隔符左缘被推到很负的位置，隐藏条目悬在屏外但仍在
        // 分隔符矩形内；AH 条目在 AH 分隔符矩形之外（更左）。
        let collapsedSeparator = CGRect(x: -880, y: 0, width: 2000, height: 22)
        let collapsedAHSeparator = CGRect(x: -2880, y: 0, width: 2000, height: 22)
        let hiddenOff = CGRect(x: -72, y: 0, width: 24, height: 22)
        let ahOff = CGRect(x: -3000, y: 0, width: 24, height: 22)

        let hidden = MenuBarSectionEngine.section(
            ofItemFrame: hiddenOff,
            separatorFrame: collapsedSeparator,
            alwaysHiddenFrame: collapsedAHSeparator,
            alwaysHiddenEnabled: true
        )
        #expect(hidden == .hidden)

        let ah = MenuBarSectionEngine.section(
            ofItemFrame: ahOff,
            separatorFrame: collapsedSeparator,
            alwaysHiddenFrame: collapsedAHSeparator,
            alwaysHiddenEnabled: true
        )
        #expect(ah == .alwaysHidden)
    }

    @Test func ahDisabledCollapsesIntoHidden() {
        // AH 分区停用（长度 0）时，其条目归入隐藏分区。
        let ahItem = CGRect(x: 100, y: 0, width: 30, height: 22)
        #expect(
            MenuBarSectionEngine.section(
                ofItemFrame: ahItem,
                separatorFrame: separator,
                alwaysHiddenFrame: nil,
                alwaysHiddenEnabled: false
            ) == .hidden
        )
    }

    @Test func missingSeparatorYieldsVisible() {
        #expect(
            MenuBarSectionEngine.section(
                ofItemFrame: CGRect(x: 100, y: 0, width: 30, height: 22),
                separatorFrame: nil,
                alwaysHiddenFrame: ahSeparator,
                alwaysHiddenEnabled: true
            ) == .visible
        )
    }
}

// MARK: - 身份与热键

@Suite struct IdentityAndHotkeyTests {
    @Test func stableIDEscapesSeparator() {
        let a = ItemIdentity(namespace: "com.example", title: "Wi-Fi: On", instanceIndex: 0)
        let b = ItemIdentity(namespace: "com.example", title: "Wi\\Fi", instanceIndex: 0)
        #expect(a.stableID.contains("Wi-Fi\\c On"))
        #expect(a.stableID.split(separator: ":", omittingEmptySubsequences: false).count == 3)
        #expect(b.stableID.split(separator: ":", omittingEmptySubsequences: false).count == 3)
        #expect(ItemIdentity(namespace: "x", title: "t") < ItemIdentity(namespace: "x", title: "t", instanceIndex: 1))
    }

    @Test func hotkeyDisplay() {
        #expect(HotkeyFormat.string(forKeyCode: 46) == "M")
        #expect(HotkeyFormat.display(keyCode: 46, carbonMask: 4352) == "⌃⌘M")
        #expect(HotkeyFormat.carbonMask(fromCocoaFlags: Int(NSEvent.ModifierFlags.command.rawValue)) == CarbonModifierMasks.cmdKey)
    }

    @Test func frameMatchingTolerance() {
        let frame = CGRect(x: 100, y: 5, width: 28, height: 22)
        #expect(AXSourceResolver.framesMatch(frame, frame.offsetBy(dx: 1, dy: 0)))
        #expect(!AXSourceResolver.framesMatch(frame, frame.offsetBy(dx: 5, dy: 0)))
        #expect(!AXSourceResolver.framesMatch(frame, frame.insetBy(dx: -3, dy: 0)))
        #expect(AXSourceResolver.xAlignMatch(frame, frame.offsetBy(dx: 3, dy: 2)))
        #expect(!AXSourceResolver.xAlignMatch(frame, frame.offsetBy(dx: 30, dy: 0)))
    }
}


// MARK: - 断言路径分区集合策略

@Suite struct SectionSetPolicyTests {
    @Test func collapseWhitelist() {
        let result = SectionSetPolicy.allowedBundlesForCollapse(
            visibleBundles: ["io.github.clash", nil, "com.cduyzh.process-tool"],
            ownBundle: "com.cduyzh.menu-bar"
        )
        #expect(result.allowed.contains("io.github.clash"))
        #expect(result.allowed.contains("com.cduyzh.process-tool"))
        #expect(result.allowed.contains("com.cduyzh.menu-bar"))
        // 系统宿主必须始终在白名单。
        #expect(result.allowed.contains("com.apple.MenuBarAgent"))
        #expect(result.allowed.contains("com.apple.controlcenter"))
        // 可见区存在未解析条目 → fail-open 信号。
        #expect(result.unresolvedVisible.count == 1)
    }

    @Test func collapseCleanWhenAllResolved() {
        let result = SectionSetPolicy.allowedBundlesForCollapse(
            visibleBundles: ["a.x", "b.y"],
            ownBundle: "com.cduyzh.menu-bar"
        )
        #expect(result.unresolvedVisible.isEmpty)
        #expect(result.allowed.count == 5)  // 两个 App + 自身 + 两个系统宿主
    }

    @Test func expandIncludesHiddenBundles() {
        let allowed = SectionSetPolicy.allowedBundlesForExpand(
            visibleBundles: ["a.x"],
            hiddenBundles: ["h.hidden"],
            ownBundle: "com.cduyzh.menu-bar"
        )
        #expect(allowed.contains("h.hidden"))
        #expect(allowed.contains("a.x"))
    }

    @Test func deduplicatesBundles() {
        let result = SectionSetPolicy.allowedBundlesForCollapse(
            visibleBundles: ["a.x", "a.x", "a.x"],
            ownBundle: nil
        )
        #expect(result.allowed.filter { $0 == "a.x" }.count == 1)
    }
}
