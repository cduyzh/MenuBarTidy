import AppKit
import CoreGraphics
import MenuBarCore
import SwiftUI

/// 中枢协调器（Hidden Bar 架构）：
/// - 隐藏/唤出 = 分隔符长度膨胀/收缩（MenuBarSectionEngine），零事件合成；
/// - 分区 = 相对分隔符的几何位置，菜单栏本身就是存储；
/// - 拖拽引擎仅在布局编辑器里做跨分区搬移（一次性摆放）。
@MainActor
final class MenuBarCoordinator: ObservableObject {
    struct ApplyReport: Equatable {
        var movedCount = 0
        var failedWindowIDs: [Int] = []
        var trusted = true
    }

    @Published private(set) var items: [MenuBarItemSnapshot] = []
    @Published private(set) var lastReport = ApplyReport()
    @Published private(set) var isExpanded = false
    @Published private(set) var alwaysHiddenEnabled: Bool
    @Published private(set) var isMoving = false
    @Published private(set) var movingWindowID: Int?

    /// macOS 27+ 走原生可见性断言路径；≤26 走分隔符膨胀路径。
    private let useNativePath = NativeVisibility.shouldUseNativePath()
    /// 持有的可见性断言（27.0.1 实测误伤系统条目，保留桥代码但不再使用）。
    private var visibilityAssertion: NativeVisibilityAssertionBox?
    /// 隐藏前各 bundle 的屏内位置（27 路径展开时原位恢复）。
    private var restorePositions: [String: CGFloat] = [:]

    let settings: SettingsStore
    private let engine: MenuBarSectionEngine
    private let resolver = AXSourceResolver()
    private let dragEngine = DragMoveEngine()

    private var separatorItem: NSStatusItem!
    private var alwaysHiddenItem: NSStatusItem!
    private var toggleItem: NSStatusItem!
    private var gearItem: NSStatusItem?

    private var outsideClickMonitors: [Any] = []
    private var rehideWorkItem: DispatchWorkItem?
    private var snapshotDiagLogged = false
    private var lastTrusted = AXAccess.isProcessTrusted()
    private var lastResolveRetry: Date?
    private var trustPollTimer: Timer?

    init(settings: SettingsStore) {
        self.settings = settings
        self.alwaysHiddenEnabled = settings.settings.alwaysHiddenEnabled
        DiagLog.write("path: native=\(useNativePath) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")

        // 屏幕堆叠规则（实测 macOS 26）：新建条目排在最左，即屏幕顺序 =
        // 创建顺序的逆序。要得到 [AH][分隔符][箭头][齿轮]，须按
        // [齿轮, 箭头, 分隔符, AH] 的顺序创建。autosave 用 v2 名，避开
        // 旧版本遗留的 preferred position 污染堆叠。
        let gear = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        gear.autosaveName = "cduyzhMenuBar.v2.gear"
        gearItem = gear

        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "cduyzhMenuBar.v2.toggle"
        toggleItem = toggle

        let sepItem = NSStatusBar.system.statusItem(withLength: MenuBarSectionEngine.expandedLength)
        sepItem.autosaveName = "cduyzhMenuBar.v2.separator"
        separatorItem = sepItem

        let ahItem = NSStatusBar.system.statusItem(withLength: 0)
        ahItem.autosaveName = "cduyzhMenuBar.v2.alwaysHidden"
        alwaysHiddenItem = ahItem

        let ahEnabled = settings.settings.alwaysHiddenEnabled
        engine = MenuBarSectionEngine(
            separatorItem: sepItem,
            alwaysHiddenItem: ahItem,
            toggleItem: toggle,
            alwaysHiddenEnabled: ahEnabled
        )

        configure(gear, icon: "menubar.rectangle", label: "MenuBarTidy 设置", action: #selector(gearClicked))
        configure(toggle, icon: "arrow.right.circle", label: "唤出隐藏分区", action: #selector(toggleClicked))
        configure(sepItem, icon: "chevron.left.2", label: "隐藏分区", action: #selector(separatorClicked))
        configure(ahItem, icon: "eye.slash", label: "始终隐藏分区", action: #selector(alwaysHiddenClicked))
    }

    private func configure(_ item: NSStatusItem, icon: String, label: String, action: Selector) {
        guard let button = item.button else { return }
        button.target = self
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)
        button.setAccessibilityLabel(label)
    }

    // MARK: - 启动

    func start() {
        installGear()
        installOutsideClickMonitors()
        installTrustPoller()
        installReconcileTimer()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.engine.invalidateLayout()
                self?.syncPublishedState()
            }
        }
        Task {
            await refreshSnapshot()
            // 启动 1 秒后收起（Hidden Bar 同款），此后常驻收起态。
            try? await Task.sleep(for: .seconds(1))
            collapseHiddenSection()
            try? await Task.sleep(for: .seconds(4))
            await refreshSnapshot()
        }
    }

    private func installGear() {
        // 齿轮条目已在 init 中创建，这里只挂菜单。
        let menu = NSMenu()
        menu.addItem(withTitle: "打开设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "临时唤出全部隐藏条目", action: #selector(revealAll), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 MenuBarTidy", action: #selector(quitApp), keyEquivalent: "q")
        for menuItem in menu.items {
            menuItem.target = self
        }
        gearItem?.menu = menu
    }

    // MARK: - 控制条目动作

    @objc private func gearClicked() {
        // 菜单条目：menu 属性接管点击，此 action 仅为占位。
    }

    @objc private func toggleClicked() {
        DiagLog.write("toggleClicked: event=\(NSApp.currentEvent.map { Int($0.type.rawValue) } ?? -1)")
        // 右键箭头 = 临时唤出全部（AH 也短暂回归），左键 = 切换隐藏分区。
        if NSApp.currentEvent?.type == .rightMouseUp {
            revealAllSections()
        } else {
            toggleHiddenSection()
        }
    }

    @objc private func separatorClicked() {
        toggleHiddenSection()
    }

    @objc private func alwaysHiddenClicked() {
        toggleHiddenSection()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func revealAll() {
        revealAllSections()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 分区切换

    func toggleHiddenSection() {
        if useNativePath {
            // toggle 语义：展开 → 收起；收起 → 展开。
            isExpanded ? nativeCollapse() : nativeExpand()
            return
        }
        DiagLog.write("toggleHiddenSection: state=\(engine.state) → toggle")
        engine.toggle()
        syncPublishedState()
        DiagLog.write("toggleHiddenSection: now \(engine.state), sep len \(Int(separatorItem.length))")
        if isExpanded {
            scheduleRehideIfNeeded()
        } else {
            cancelScheduledRehide()
        }
        updateControlIcons()
    }

    func collapseHiddenSection() {
        if useNativePath {
            nativeCollapse()
            return
        }
        guard engine.isArrangementValid else {
            DiagLog.write("collapse: 分隔符不在箭头隐藏侧（布局未摆放），放弃收起")
            return
        }
        engine.collapse()
        syncPublishedState()
        cancelScheduledRehide()
        updateControlIcons()
    }

    func revealAllSections() {
        if useNativePath {
            // 全部（含始终隐藏）写回屏内。
            var all = hiddenBundleSet
            all.formUnion(alwaysHiddenBundleSet)
            let screenWidth = NSScreen.main?.frame.width ?? 1512
            if !all.isEmpty {
                Task {
                    for (index, bundle) in all.enumerated() {
                        let fallback = screenWidth - 160 - CGFloat(index) * 40
                        let x = restorePositions[bundle] ?? fallback
                        _ = await resolver.setHorizontalPosition(bundles: [bundle], x: x)
                    }
                    await refreshSnapshot()
                }
            }
            isExpanded = true
            cancelScheduledRehide()
            updateControlIcons()
            return
        }
        engine.expand()
        // AH 分区短暂回归，用户可把条目拖出；8 秒后恢复。
        engine.temporarilyRevealAlwaysHidden()
        syncPublishedState()
        cancelScheduledRehide()
        updateControlIcons()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            Task { @MainActor in
                self?.engine.restoreAlwaysHidden()
            }
        }
    }

    func setAlwaysHiddenEnabled(_ enabled: Bool) {
        alwaysHiddenEnabled = enabled
        if useNativePath {
            settings.settings.alwaysHiddenEnabled = enabled
            reassertCurrentState()
        } else {
            engine.setAlwaysHiddenEnabled(enabled)
        }
        syncPublishedState()
    }

    // MARK: - 原生断言路径（macOS 27+）

    private func releaseAssertion() {
        visibilityAssertion?.invalidate()
        visibilityAssertion = nil
    }

    /// 激活新的断言后再释放旧的，切换间不闪全部条目。
    private func activateAssertion(allowedBundles: [String], completion: (@MainActor (Bool) -> Void)? = nil) {
        NativeVisibility.activate(allowedBundleIdentifiers: allowedBundles) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(newAssertion):
                    let old = self.visibilityAssertion
                    self.visibilityAssertion = newAssertion
                    old?.invalidate()
                    DiagLog.write("native assertion: activated, allowed=\(allowedBundles.count)")
                    completion?(true)
                case let .failure(error):
                    DiagLog.write("native assertion: FAILED \(error.localizedDescription)，fail-open 全显")
                    self.releaseAssertion()
                    completion?(false)
                }
            }
        }
    }

    /// 当前各分区 bundle 集合（断言路径的单一真值来自设置持久化）。
    private var hiddenBundleSet: Set<String> { Set(settings.settings.hiddenBundles) }
    private var alwaysHiddenBundleSet: Set<String> {
        alwaysHiddenEnabled ? Set(settings.settings.alwaysHiddenBundles) : []
    }

    /// 可见区 bundle（含未解析占位 nil，供 fail-open 判定）。
    private var visibleBundlesIncludingUnresolved: [String?] {
        var excluded = hiddenBundleSet
        excluded.formUnion(alwaysHiddenBundleSet)
        excluded.formUnion(SectionSetPolicy.systemHostBundles)
        if let own = Bundle.main.bundleIdentifier {
            excluded.insert(own)
        }
        var seen = Set<String>()
        var result: [String?] = []
        for item in items {
            guard let bundle = item.bundleIdentifier else {
                result.append(nil)
                continue
            }
            guard !excluded.contains(bundle), !seen.contains(bundle) else { continue }
            seen.insert(bundle)
            result.append(bundle)
        }
        return result
    }

    /// 27 路径收起：把隐藏与始终隐藏分区的条目 AXPosition 写到屏外负 x。
    private func nativeCollapse() {
        var toHide = hiddenBundleSet
        toHide.formUnion(alwaysHiddenBundleSet)
        guard !toHide.isEmpty else {
            isExpanded = false
            cancelScheduledRehide()
            updateControlIcons()
            return
        }
        // 记住隐藏前的屏内位置，展开时原位恢复。
        for item in items {
            guard let bundle = item.bundleIdentifier, toHide.contains(bundle) else { continue }
            if item.frame.minX >= 0 {
                restorePositions[bundle] = item.frame.minX
            }
        }
        Task {
            let result = await resolver.setHorizontalPosition(bundles: toHide, x: -1000)
            DiagLog.write("nativeCollapse: 写出屏外 moved=\(result.moved) failed=\(result.failed)")
            await refreshSnapshot()
        }
        isExpanded = false
        cancelScheduledRehide()
        updateControlIcons()
    }

    /// 27 路径展开：隐藏分区条目写回屏内；始终隐藏保持离屏。
    private func nativeExpand() {
        guard !hiddenBundleSet.isEmpty else {
            isExpanded = true
            updateControlIcons()
            return
        }
        let screenWidth = NSScreen.main?.frame.width ?? 1512
        Task {
            // 写回位置按序错开，避免多个条目落在同一点互相重叠。
            for (index, bundle) in hiddenBundleSet.enumerated() {
                let fallback = screenWidth - 160 - CGFloat(index) * 40
                let x = restorePositions[bundle] ?? fallback
                _ = await resolver.setHorizontalPosition(bundles: [bundle], x: x)
            }
            DiagLog.write("nativeExpand: 写回屏内 \(hiddenBundleSet.count) 个 bundle")
            await refreshSnapshot()
        }
        isExpanded = true
        scheduleRehideIfNeeded()
        updateControlIcons()
    }

    /// 设置变化后按当前状态重算断言（不改变展开/收起语义）。
    private func reassertCurrentState() {
        guard visibilityAssertion != nil else { return }
        if isExpanded {
            nativeExpand()
        } else {
            nativeCollapse()
        }
    }

    private func syncPublishedState() {
        isExpanded = engine.state == .expanded
        updateControlIcons()
    }

    private func updateControlIcons() {
        let label = isExpanded ? "收拢隐藏分区" : "唤出隐藏分区"
        toggleItem.button?.image = NSImage(
            systemSymbolName: isExpanded ? "arrow.left.circle" : "arrow.right.circle",
            accessibilityDescription: label
        )
        toggleItem.button?.setAccessibilityLabel(label)
        toggleItem.button?.setAccessibilityValue(isExpanded ? "已展开" : "已收拢")
    }

    // MARK: - 自动收回（菜单栏内有交互时顺延）

    private func scheduleRehideIfNeeded() {
        let delay = settings.settings.autoRehideSeconds
        guard delay > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isMouseInMenuBar || self.isAnyMenuOpen {
                    self.scheduleRehideIfNeeded()
                } else {
                    self.collapseHiddenSection()
                }
            }
        }
        rehideWorkItem?.cancel()
        rehideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelScheduledRehide() {
        rehideWorkItem?.cancel()
        rehideWorkItem = nil
    }

    private var isMouseInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= screen.visibleFrame.maxY && mouse.y <= screen.frame.maxY
        }
    }

    private var isAnyMenuOpen: Bool {
        // 菜单跟踪窗口是普通 NSWindow（层级很高），按窗口名识别足够可靠。
        NSApp.windows.contains { $0.isVisible && $0.className.contains("NSMenuWindow") }
    }

    private func installOutsideClickMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isExpanded else { return }
                if self.isMouseInMenuBar {
                    self.scheduleRehideIfNeeded()
                } else if self.settings.settings.autoRehideSeconds > 0 {
                    self.collapseHiddenSection()
                }
            }
        }
        outsideClickMonitors.append(
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler)
        )
    }

    // MARK: - 周期对账

    private func installReconcileTimer() {
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.reconcileIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 27 路径：收起状态下隐藏分区的条目被系统/App 拉回屏内时重写屏外。
    /// （App 刷新自身 status item 会顶掉 AX 写入的位置，需持续对账。）
    private func reconcileIfNeeded() async {
        guard useNativePath else { return }
        guard !isExpanded else { return }

        var toHide = hiddenBundleSet
        toHide.formUnion(alwaysHiddenBundleSet)
        guard !toHide.isEmpty else { return }

        let escaped = items.filter { item in
            guard let bundle = item.bundleIdentifier else { return false }
            return toHide.contains(bundle) && item.frame.minX >= 0
        }
        if !escaped.isEmpty {
            let escapedBundles = Set(escaped.compactMap(\.bundleIdentifier))
            DiagLog.write("native reconcile: \(escapedBundles.count) 个隐藏条目被拉回，重写屏外")
            _ = await resolver.setHorizontalPosition(bundles: escapedBundles, x: -1000)
            await refreshSnapshot()
        } else if items.isEmpty || Date().timeIntervalSince(lastSnapshotAt) > 30 {
            await refreshSnapshot()
        }
    }

    private var lastSnapshotAt = Date()

    // MARK: - 权限监听

    private func installTrustPoller() {
        let poller = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = AXAccess.isProcessTrusted()
                defer { self.lastTrusted = now }
                guard now, !self.lastTrusted else { return }
                await self.resolver.forgetAll()
                self.snapshotDiagLogged = false
                await self.refreshSnapshot()
            }
        }
        RunLoop.main.add(poller, forMode: .common)
        trustPollTimer = poller
    }

    // MARK: - 快照（编辑器展示 + 来源解析）

    /// 枚举 + 源解析 + 几何分区。分区完全由条目相对分隔符的位置决定。
    func refreshSnapshot() async {
        if useNativePath {
            await refreshSnapshotNative()
            return
        }
        let windows = MenuBarWindowList.itemWindows()

        // 自身的四个控制条目按 AppKit 帧排除（macOS 26 上它们挂在
        // Control Center 名下，窗口编号与 CG 列表不对应）。
        let ownFrames = controlItemFrames()
        let candidates = windows.filter { window in
            !ownFrames.contains { own in
                abs(own.origin.x - window.frame.origin.x) < 2
                    && abs(own.width - window.frame.width) < 2
                    && abs(own.origin.y - window.frame.origin.y) < 4
            }
        }

        let details = await resolver.resolveDetails(for: candidates)

        var snapshots: [MenuBarItemSnapshot] = []
        for (window, detail) in zip(candidates, details) {
            let namespace: String
            if
                let pid = detail.sourcePID,
                let entry = AppCatalog.entry(for: pid),
                let bundleID = entry.bundleIdentifier
            {
                namespace = bundleID
            } else if let pid = detail.sourcePID, let entry = AppCatalog.entry(for: pid) {
                namespace = entry.localizedName ?? window.ownerName ?? "unknown"
            } else {
                namespace = window.ownerName ?? "unknown"
            }

            let title = detail.title
                ?? detail.identifier
                ?? window.title
                ?? ""

            let name: String
            if detail.sourcePID != nil {
                name = displayName(namespace: namespace, title: title, pid: detail.sourcePID, ownerName: window.ownerName)
            } else if let windowTitle = window.title, !windowTitle.isEmpty {
                name = windowTitle
            } else {
                name = "未识别条目 · 宽 \(Int(window.frame.width))pt"
            }

            snapshots.append(
                MenuBarItemSnapshot(
                    windowID: window.windowID,
                    identity: ItemIdentity(namespace: namespace, title: title),
                    sourcePID: detail.sourcePID,
                    ownerPID: window.ownerPID,
                    ownerName: window.ownerName,
                    displayName: name,
                    bundleIdentifier: AppCatalog.entry(for: detail.sourcePID ?? -1)?.bundleIdentifier,
                    frame: window.frame,
                    isOnScreen: window.isOnScreen
                )
            )
        }

        let alive = Set(snapshots.map(\.windowID))
        await resolver.forget(exceptAlive: alive)

        items = snapshots

        if !snapshotDiagLogged {
            snapshotDiagLogged = true
            var lines = ["snapshot trusted=\(AXAccess.isProcessTrusted()) items=\(snapshots.count)"]
            for item in snapshots {
                lines.append(
                    "  \(String(format: "x%.0f w%.0f", item.frame.minX, item.frame.width)) pid=\(item.sourcePID.map(String.init) ?? "nil") ns=\(item.identity.namespace) title=\(item.identity.title)"
                )
            }
            DiagLog.write(lines.joined(separator: "\n"))
        }
    }

    /// 条目当前几何分区（断言路径按 bundle 集合判定）。
    func section(for item: MenuBarItemSnapshot) -> MenuBarSection {
        if useNativePath {
            guard let bundle = item.bundleIdentifier else { return .visible }
            if alwaysHiddenBundleSet.contains(bundle) { return .alwaysHidden }
            if hiddenBundleSet.contains(bundle) { return .hidden }
            return .visible
        }
        return MenuBarSectionEngine.section(
            ofItemFrame: item.frame,
            separatorFrame: itemFrame(separatorItem),
            alwaysHiddenFrame: itemFrame(alwaysHiddenItem),
            alwaysHiddenEnabled: alwaysHiddenEnabled
        )
    }

    /// 断言路径快照：AXExtrasMenuBar 全量枚举（macOS 27 上条目窗口列表
    /// 已从 CGWindowList 消失）。断言激活期间隐藏条目的 frame 可能过期，
    /// 展示以名称与 bundle 集合为准。
    private func refreshSnapshotNative() async {
        let entries = await resolver.enumerateAllExtras()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var snapshots: [MenuBarItemSnapshot] = []

        for entry in entries where entry.pid != ownPID {
            let namespace = entry.bundleIdentifier ?? entry.localizedName ?? "unknown"
            for element in entry.elements {
                let title = element.title ?? element.identifier ?? ""
                let frame = element.frame
                let stableID = abs((namespace + title).hashValue)
                snapshots.append(
                    MenuBarItemSnapshot(
                        windowID: stableID == 0 ? 1 : stableID,
                        identity: ItemIdentity(namespace: namespace, title: title),
                        sourcePID: entry.pid,
                        ownerPID: entry.pid,
                        ownerName: entry.localizedName,
                        displayName: displayName(
                            namespace: namespace,
                            title: title,
                            pid: entry.pid,
                            ownerName: entry.localizedName
                        ),
                        bundleIdentifier: entry.bundleIdentifier,
                        frame: frame,
                        isOnScreen: frame.minX >= 0
                    )
                )
            }
        }

        items = snapshots
        lastSnapshotAt = Date()

        if !snapshotDiagLogged {
            snapshotDiagLogged = true
            var lines = ["snapshot(native) items=\(snapshots.count)"]
            for item in snapshots {
                lines.append("  x\(Int(item.frame.minX)) pid=\(item.sourcePID.map(String.init) ?? "nil") ns=\(item.identity.namespace) title=\(item.identity.title)")
            }
            DiagLog.write(lines.joined(separator: "\n"))
        }
    }

    private func itemFrame(_ item: NSStatusItem?) -> CGRect? {
        guard
            let window = item?.button?.window,
            let screen = window.screen ?? NSScreen.main
        else { return nil }
        let frame = window.frame
        return CGRect(
            x: frame.origin.x,
            y: screen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func controlItemFrames() -> [CGRect] {
        [gearItem, toggleItem, separatorItem, alwaysHiddenItem].compactMap { itemFrame($0) }
    }

    private func displayName(namespace: String, title: String, pid: pid_t?, ownerName: String?) -> String {
        let appName = pid.flatMap { AppCatalog.displayName(for: $0, fallback: ownerName) }
            ?? ownerName
            ?? namespace
        if title.hasPrefix("com.apple.menuextra.") {
            let friendly = Self.menuExtraNames[title] ?? String(title.dropFirst("com.apple.menuextra.".count))
            return friendly == appName ? appName : "\(appName) · \(friendly)"
        }
        if title.isEmpty || title == appName {
            return appName
        }
        return "\(appName) · \(title)"
    }

    private static let menuExtraNames: [String: String] = [
        "com.apple.menuextra.airdrop": "隔空投送",
        "com.apple.menuextra.controlcenter": "控制中心",
        "com.apple.menuextra.clock": "时钟",
        "com.apple.menuextra.wifi": "无线局域网",
        "com.apple.menuextra.battery": "电池",
        "com.apple.menuextra.bluetooth": "蓝牙",
        "com.apple.menuextra.focus": "专注模式",
        "com.apple.menuextra.nowplaying": "正在播放",
        "com.apple.menuextra.user": "快速用户切换",
        "com.apple.menuextra.textinput": "输入法",
        "com.apple.menuextra.volume": "音量",
        "com.apple.menuextra.timemachine": "时间机器",
        "com.apple.menuextra.siri": "Siri",
        "com.apple.menuextra.spotlight": "聚焦搜索",
        "com.apple.menuextra.screen": "屏幕镜像",
        "com.apple.menuextra.accessibility": "辅助功能快捷键",
        "com.apple.menuextra.keyboardbrightness": "键盘亮度",
        "com.apple.menuextra.hearing": "听觉",
        "com.apple.menuextra.music": "音乐",
        "com.apple.menuextra.sound": "声音",
    ]

    // MARK: - 编辑器搬移（跨分区一次性摆放）

    /// 把条目拖到目标分区的落点。收起态先展开，AH 分区先临时收起其膨胀。
    func move(_ item: MenuBarItemSnapshot, to section: MenuBarSection) async {
        guard !useNativePath else {
            // 断言路径：分区是 bundle 集合，改集合即改分区，瞬时生效。
            guard let bundle = item.bundleIdentifier else { return }
            isMoving = true
            movingWindowID = item.windowID
            defer {
                isMoving = false
                movingWindowID = nil
            }
            var hidden = settings.settings.hiddenBundles
            var alwaysHidden = settings.settings.alwaysHiddenBundles
            hidden.removeAll { $0 == bundle }
            alwaysHidden.removeAll { $0 == bundle }
            switch section {
            case .hidden: hidden.append(bundle)
            case .alwaysHidden: alwaysHidden.append(bundle)
            case .visible: break
            }
            settings.settings.hiddenBundles = hidden
            settings.settings.alwaysHiddenBundles = alwaysHidden
            if section == .visible {
                // 移回可见：立即写回屏内。
                let screenWidth = NSScreen.main?.frame.width ?? 1512
                let x = restorePositions[bundle] ?? (screenWidth - 200)
                _ = await resolver.setHorizontalPosition(bundles: [bundle], x: x)
            } else if !isExpanded || section == .alwaysHidden {
                // 收起态移入隐藏，或任何时候移入始终隐藏：写出屏外。
                if item.frame.minX >= 0 {
                    restorePositions[bundle] = item.frame.minX
                }
                _ = await resolver.setHorizontalPosition(bundles: [bundle], x: -1000)
            }
            await refreshSnapshot()
            return
        }
        isMoving = true
        movingWindowID = item.windowID
        defer {
            isMoving = false
            movingWindowID = nil
        }
        let wasCollapsed = engine.state == .collapsed
        let ahWasInflated = alwaysHiddenItem.length > MenuBarSectionEngine.expandedLength

        if wasCollapsed { engine.expand() }
        if section == .alwaysHidden, ahWasInflated { engine.temporarilyRevealAlwaysHidden() }
        syncPublishedState()
        try? await Task.sleep(for: .milliseconds(250))

        guard
            let current = MenuBarWindowList.frame(ofWindowID: item.windowID),
            let separatorFrame = itemFrame(separatorItem)
        else { return }

        let targetX: CGFloat
        switch section {
        case .visible:
            targetX = separatorFrame.maxX + 8
        case .hidden:
            targetX = separatorFrame.minX - item.frame.width - 8
        case .alwaysHidden:
            guard let ahFrame = itemFrame(alwaysHiddenItem) else { return }
            targetX = ahFrame.minX - item.frame.width - 8
        }

        let target = CGRect(x: targetX, y: current.minY, width: current.width, height: current.height)
        let outcome = await dragEngine.move(windowID: item.windowID, from: current, to: target)

        var report = ApplyReport(trusted: true)
        if outcome.success {
            report.movedCount += 1
        } else {
            report.failedWindowIDs.append(item.windowID)
        }
        lastReport = report

        // 恢复膨胀与收起状态。
        if section == .alwaysHidden, ahWasInflated { engine.restoreAlwaysHidden() }
        if wasCollapsed {
            try? await Task.sleep(for: .milliseconds(200))
            collapseHiddenSection()
        } else {
            syncPublishedState()
        }
        await refreshSnapshot()
    }

    func reapplyNow() {
        engine.invalidateLayout()
        syncPublishedState()
    }
}
