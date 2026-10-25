import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 辅助功能（Accessibility）访问层。
/// Thaw 通过独立 XPC 服务做同样的事以隔离 WindowServer 卡顿；本实现直接在
/// 进程内后台执行，并以 AXUIElementSetMessagingTimeout 限制单次调用时长。
public enum AXAccess {
    /// 是否已获得辅助功能权限；prompt 为 true 时弹出系统授权引导。
    public static func isProcessTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /// 无弹窗检查权限；若未授权则打开系统设置的隐私页。
    public static func openAccessibilitySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 某个 App 的 AXExtrasMenuBar 中观测到的一个条目元素。
public struct AXElementInfo: Equatable, Sendable {
    public let frame: CGRect
    public let title: String?
    public let identifier: String?
    public let help: String?

    public init(frame: CGRect, title: String?, identifier: String?, help: String?) {
        self.frame = frame
        self.title = title
        self.identifier = identifier
        self.help = help
    }
}

/// 把条目窗口解析回创建它的源 App。
/// 原理：对每个运行中的 App 读取其 AXExtrasMenuBar 的子元素矩形，
/// 与窗口矩形做几何匹配。macOS 26 起 NSStatusItem 窗口统一由
/// Control Center 进程托管，窗口归属 PID 不能代表源 App，因此该步骤必需。
public actor AXSourceResolver {
    public static let frameMatchTolerance: CGFloat = 1.5
    /// 元素缓存的存活时间；App 增删菜单栏条目后最迟此时可见。
    public static let elementCacheTTL: TimeInterval = 15

    private struct AppProbe: Sendable {
        var elements: [AXElementInfo]
        var probedAt: Date
    }

    private var appProbeCache: [pid_t: AppProbe] = [:]
    /// 已按窗口记住的源 PID；窗口存活期间不再重复解析。
    private var resolvedWindowPIDs: [Int: pid_t] = [:]
    private var probeSummaryLogged = false
    private var hitDiagLogged = false
    private var perAppDiagLogged = false
    private let messagingTimeout: Float

    public init(messagingTimeout: Float = 0.3) {
        self.messagingTimeout = messagingTimeout
    }

    /// 某个条目窗口的解析结果：源 App 与可读标题。
    public struct WindowDetail: Equatable, Sendable {
        public let sourcePID: pid_t?
        public let title: String?
        public let identifier: String?

        public init(sourcePID: pid_t?, title: String?, identifier: String?) {
            self.sourcePID = sourcePID
            self.title = title
            self.identifier = identifier
        }
    }

    /// 解析一组条目窗口的源 App 与标题。返回与输入同序的数组。
    public func resolveDetails(for windows: [MenuBarWindowList.ItemWindow]) async -> [WindowDetail] {
        var result = [WindowDetail?](repeating: nil, count: windows.count)
        var toProbeIndices = [Int]()

        for (index, window) in windows.enumerated() {
            if let cached = resolvedWindowPIDs[window.windowID] {
                result[index] = WindowDetail(sourcePID: cached, title: nil, identifier: nil)
            } else {
                toProbeIndices.append(index)
            }
        }
        guard !toProbeIndices.isEmpty else {
            return result.map { $0 ?? WindowDetail(sourcePID: nil, title: nil, identifier: nil) }
        }

        // 主路径：AXExtrasMenuBar 探测。逐 App 读取其菜单条目元素并做
        // 横向几何匹配（在屏与屏外条目都适用，也是 Thaw 的 PID 解析路径）。
        let pendingIndices = toProbeIndices.filter { result[$0]?.sourcePID == nil }

        if !pendingIndices.isEmpty {
            let pendingFrames = pendingIndices.reduce(into: [Int: CGRect]()) { dict, index in
                dict[index] = windows[index].frame
            }
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier != nil {
                guard let probe = await probeElements(of: app.processIdentifier) else { continue }
                for element in probe.elements {
                    guard
                        let matched = pendingFrames.first(where: { _, frame in
                            Self.xAlignMatch(element.frame, frame)
                        })
                    else { continue }
                    let index = matched.key
                    if resolvedWindowPIDs[windows[index].windowID] == nil {
                        resolvedWindowPIDs[windows[index].windowID] = app.processIdentifier
                        result[index] = WindowDetail(
                            sourcePID: app.processIdentifier,
                            title: element.title,
                            identifier: element.identifier
                        )
                    }
                }
            }
        }

        // 兜底：系统级命中测试（帧校验防前台菜单栏元素误报）。extras-bar
        // 探测不到的个别在屏条目在此补齐。
        let leftoverIndices = toProbeIndices.filter { result[$0]?.sourcePID == nil }
        let onScreenIndices = leftoverIndices.filter { windows[$0].frame.minX >= 0 }
        if !onScreenIndices.isEmpty {
            let hits = await hitTestItems(at: onScreenIndices.map { windows[$0] })
            for (offset, hit) in hits.enumerated() {
                let index = onScreenIndices[offset]
                guard let hit else { continue }
                result[index] = hit.detail
                if let pid = hit.detail?.sourcePID {
                    resolvedWindowPIDs[windows[index].windowID] = pid
                }
            }
        }

        // 兜底 2：逐 App 限定域命中测试。部分 App（Electron/自绘条目）的
        // extras-bar 不暴露子元素，但在其自身 AX 树内做坐标命中可以返回
        // 条目元素——命中即证明条目属于该 App，不受前台应用干扰。
        let finalIndices = toProbeIndices.filter { result[$0]?.sourcePID == nil && windows[$0].frame.minX >= 0 }
        if !finalIndices.isEmpty {
            let perAppHits = await perAppHitTest(windows: finalIndices.map { windows[$0] })
            for (offset, hit) in perAppHits.enumerated() {
                let index = finalIndices[offset]
                guard let hit else { continue }
                result[index] = hit
                if let pid = hit.sourcePID {
                    resolvedWindowPIDs[windows[index].windowID] = pid
                }
            }
        }

        logProbeSummaryOnce(
            pending: pendingIndices.count,
            resolvedCount: pendingIndices.filter { result[$0]?.sourcePID != nil }.count
        )

        return result.map { $0 ?? WindowDetail(sourcePID: nil, title: nil, identifier: nil) }
    }

    /// 一次命中测试的结果：候选详情 + 元素矩形（用于帧校验与诊断）。
    struct HitOutcome: Sendable {
        let detail: WindowDetail?
        let elementFrame: CGRect?
        let role: String?
        let pid: pid_t?
    }

    /// 对一批条目窗口的中心点做 AX 命中测试，并做帧校验。
    /// 元素矩形与窗口矩形一致（容差 2 点）才认为命中了条目本身。
    private func hitTestItems(at windows: [MenuBarWindowList.ItemWindow]) async -> [HitOutcome?] {
        let timeout = messagingTimeout
        let requests = windows.map { window in
            (point: CGPoint(x: window.frame.midX, y: window.frame.midY), frame: window.frame)
        }
        let verbose = !hitDiagLogged
        let outcomes: [HitOutcome?] = await Task.detached(priority: .utility) {
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, timeout)

            var results: [HitOutcome?] = []
            for request in requests {
                var element: AXUIElement?
                guard
                    AXUIElementCopyElementAtPosition(systemWide, Float(request.point.x), Float(request.point.y), &element) == .success,
                    let element
                else {
                    if verbose {
                        DiagLog.write("hit x\(Int(request.point.x)): no element")
                    }
                    results.append(nil)
                    continue
                }
                var pid: pid_t = 0
                _ = AXUIElementGetPid(element, &pid)
                let role = stringAttribute(element, "AXRole")
                let elementFrame = frameAttribute(element)

                // 帧校验：命中到的必须是条目本身，而不是菜单栏或前台 App 的元素。
                // AX 元素矩形是按钮内容区，窗口矩形含边距，存在 ~6pt 系统性偏差。
                let accepted: Bool
                if let elementFrame, pid != 0 {
                    accepted = Self.framesMatch(elementFrame, request.frame, tolerance: 6)
                } else {
                    accepted = false
                }
                if verbose {
                    DiagLog.write(
                        "hit x\(Int(request.point.x)): pid=\(pid) role=\(role ?? "-") el=\(elementFrame.map { String(format: "x%.0f w%.0f", $0.minX, $0.width) } ?? "nil") win=\(String(format: "x%.0f w%.0f", request.frame.minX, request.frame.width)) accepted=\(accepted)"
                    )
                }
                if accepted {
                    results.append(
                        HitOutcome(
                            detail: WindowDetail(
                                sourcePID: pid,
                                title: stringAttribute(element, "AXTitle"),
                                identifier: stringAttribute(element, "AXIdentifier")
                            ),
                            elementFrame: elementFrame,
                            role: role,
                            pid: pid
                        )
                    )
                } else {
                    results.append(nil)
                }
            }
            return results
        }.value

        hitDiagLogged = true
        return outcomes
    }

    /// 逐 App 限定域命中测试：对每个未解析的在屏条目，依次在各 App 的
    /// AX 树内对其中心点做坐标命中；命中且帧吻合即认定归属。
    /// 后台休眠中的 App 首次 AX 应答可能远慢于常规调用，这里用更宽的超时。
    private func perAppHitTest(windows: [MenuBarWindowList.ItemWindow]) async -> [WindowDetail?] {
        let timeout: Float = 1.2
        let verbose = !perAppDiagLogged
        let points = windows.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        let frames = windows.map { $0.frame }
        let appPIDs = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier != nil }
            .map { $0.processIdentifier }

        let outcomes: [WindowDetail?] = await Task.detached(priority: .utility) {
            var results = [WindowDetail?](repeating: nil, count: windows.count)

            // 每个 App 的命中互相独立；8 路并发避免慢 App 拖垮整轮解析。
            func hitIn(appPID: pid_t, point: CGPoint) -> (pid: pid_t, frame: CGRect, title: String?, identifier: String?)? {
                let appElement = AXUIElementCreateApplication(appPID)
                AXUIElementSetMessagingTimeout(appElement, timeout)
                var element: AXUIElement?
                guard
                    AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &element) == .success,
                    let element
                else { return nil }
                guard let elementFrame = frameAttribute(element) else { return nil }
                return (
                    appPID,
                    elementFrame,
                    stringAttribute(element, "AXTitle"),
                    stringAttribute(element, "AXIdentifier")
                )
            }

            for (index, point) in points.enumerated() {
                var remaining = appPIDs
                outer: while !remaining.isEmpty {
                    let batch = remaining.prefix(8)
                    remaining.removeFirst(min(8, remaining.count))

                    var matched: WindowDetail?
                    await withTaskGroup(of: (pid: pid_t, frame: CGRect, title: String?, identifier: String?)?.self) { group in
                        for pid in batch {
                            group.addTask { hitIn(appPID: pid, point: point) }
                        }
                        var found: [(pid: pid_t, frame: CGRect, title: String?, identifier: String?)] = []
                        for await hit in group {
                            if let hit { found.append(hit) }
                        }
                        for hit in found {
                            let aligned = AXSourceResolver.xAlignMatch(hit.frame, frames[index])
                                && abs(hit.frame.midY - frames[index].midY) <= 8
                            if verbose {
                                DiagLog.write(
                                    "per-app hit x\(Int(point.x)) in pid \(hit.pid): el=\(String(format: "(%.0f,%.0f,w%.0f,h%.0f)", hit.frame.minX, hit.frame.minY, hit.frame.width, hit.frame.height)) aligned=\(aligned)"
                                )
                            }
                            if aligned {
                                matched = WindowDetail(
                                    sourcePID: hit.pid,
                                    title: hit.title,
                                    identifier: hit.identifier
                                )
                                break
                            }
                        }
                    }
                    if let matched {
                        results[index] = matched
                        break outer
                    }
                }
            }
            return results
        }.value

        perAppDiagLogged = true
        return outcomes
    }

    /// 每次启动最多记录一次解析诊断，供排查「未知来源」类问题。
    private func logProbeSummaryOnce(pending: Int, resolvedCount: Int) {
        guard !probeSummaryLogged else { return }
        probeSummaryLogged = true

        var lines: [String] = []
        lines.append("resolve extras-bar: \(resolvedCount)/\(pending) 个待解析窗口经探测补齐")
        for app in NSWorkspace.shared.runningApplications.prefix(60) where app.bundleIdentifier != nil {
            guard let probe = appProbeCache[app.processIdentifier] else { continue }
            if !probe.elements.isEmpty {
                let sample = probe.elements.prefix(6)
                    .map { element in
                        let title = element.title.flatMap { $0.isEmpty ? nil : $0 } ?? "-"
                        return "\(title)@(\(Int(element.frame.minX)),\(Int(element.frame.minY)),w\(Int(element.frame.width)),h\(Int(element.frame.height)))"
                    }
                    .joined(separator: ", ")
                lines.append("  extras[\(app.bundleIdentifier ?? "?") pid \(app.processIdentifier)] \(probe.elements.count) children: \(sample)")
            }
        }
        DiagLog.write(lines.joined(separator: "\n"))
    }

    /// 解析一组条目窗口的源 App PID。返回与输入同序的数组；无法解析的项为 nil。
    public func resolveSourcePIDs(for windows: [MenuBarWindowList.ItemWindow]) async -> [pid_t?] {
        await resolveDetails(for: windows).map(\.sourcePID)
    }

    /// 清理已消失窗口的解析缓存，只保留仍在枚举中的窗口。
    public func forget(exceptAlive alive: Set<Int>) {
        resolvedWindowPIDs = resolvedWindowPIDs.filter { alive.contains($0.key) }
    }

    public func forgetAll() {
        resolvedWindowPIDs.removeAll()
        appProbeCache.removeAll()
    }

    /// 读取某 App 的 AXExtrasMenuBar 子元素（带 TTL 缓存）。
    public func elements(ofPID pid: pid_t) async -> [AXElementInfo] {
        await probeElements(of: pid)?.elements ?? []
    }

    /// macOS 27 隐藏机制：把指定 bundle 集合的全部条目元素 AXPosition
    /// 写到目标横坐标。写负 x 即隐藏（系统自身的隐藏条目也停泊在负 x），
    /// 写回屏内坐标即恢复。实测返回 -25200 错误码但位置实际生效。
    ///
    /// 每次都现读该 App 的 extras 子元素并全部写入——不做缓存帧匹配，
    /// App 自主刷新条目或上次写入后缓存过期都不会导致写入落空。
    /// - Returns: (moved, failed) = (写出的条目数, 未写出任何条目的 App 数)。
    public func setHorizontalPosition(bundles: Set<String>, x: CGFloat) async -> (moved: Int, failed: Int) {
        var moved = 0
        var failed = 0
        let timeout = messagingTimeout

        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, bundles.contains(bundle) else { continue }
            let written = await Task.detached(priority: .utility) { () -> Int in
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(appElement, timeout)
                var extrasRef: CFTypeRef?
                guard
                    AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
                    extrasRef != nil
                else { return 0 }
                let extras = unsafeBitCast(extrasRef!, to: AXUIElement.self)
                var childrenRef: CFTypeRef?
                guard
                    AXUIElementCopyAttributeValue(extras, "AXChildren" as CFString, &childrenRef) == .success,
                    let children = childrenRef as? [AnyObject]
                else { return 0 }
                var written = 0
                for child in children {
                    let element = unsafeBitCast(child, to: AXUIElement.self)
                    // 保持当前纵向位置（菜单栏条目只水平移动）。
                    var currentY: CGFloat = 4.5
                    if let frame = frameAttribute(element) {
                        currentY = frame.minY == 0 ? 4.5 : frame.minY
                    }
                    var point = CGPoint(x: x, y: currentY)
                    guard let value = AXValueCreate(.cgPoint, &point) else { continue }
                    _ = AXUIElementSetAttributeValue(element, "AXPosition" as CFString, value)
                    written += 1
                }
                return written
            }.value
            if written > 0 {
                moved += written
            } else {
                failed += 1
            }
        }
        return (moved, failed)
    }

    /// 枚举所有运行中 App 的菜单栏条目元素（macOS 27 上条目窗口列表已从
    /// CGWindowList 消失，AXExtrasMenuBar 是唯一可靠的枚举来源）。
    public struct ExtrasEntry: Sendable {
        public let pid: pid_t
        public let bundleIdentifier: String?
        public let localizedName: String?
        public let elements: [AXElementInfo]
    }

    public func enumerateAllExtras() async -> [ExtrasEntry] {
        var entries: [ExtrasEntry] = []
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier != nil {
            guard let probe = await probeElements(of: app.processIdentifier) else { continue }
            guard !probe.elements.isEmpty else { continue }
            entries.append(
                ExtrasEntry(
                    pid: app.processIdentifier,
                    bundleIdentifier: app.bundleIdentifier,
                    localizedName: app.localizedName,
                    elements: probe.elements
                )
            )
        }
        return entries
    }

    private func probeElements(of pid: pid_t) async -> AppProbe? {
        if let cached = appProbeCache[pid], Date().timeIntervalSince(cached.probedAt) < Self.elementCacheTTL {
            return cached
        }

        let timeout = messagingTimeout
        let elements: [AXElementInfo] = await Task.detached(priority: .utility) {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, timeout)

            guard
                let extras = copyAttribute(appElement, "AXExtrasMenuBar"),
                CFGetTypeID(extras) == AXUIElementGetTypeID()
            else { return [] }
            let extrasElement = unsafeBitCast(extras, to: AXUIElement.self)

            guard
                let children = copyAttribute(extrasElement, "AXChildren"),
                CFGetTypeID(children) == CFArrayGetTypeID()
            else { return [] }
            let childArray = unsafeBitCast(children, to: CFArray.self)

            var infos: [AXElementInfo] = []
            let count = CFArrayGetCount(childArray)
            for index in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(childArray, index) else { continue }
                let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
                guard CFGetTypeID(object) == AXUIElementGetTypeID() else { continue }
                let element = unsafeBitCast(raw, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(element, timeout)

                guard let frameRef = copyAttribute(element, "AXFrame"),
                      CFGetTypeID(frameRef) == AXValueGetTypeID()
                else { continue }
                let value = unsafeBitCast(frameRef, to: AXValue.self)
                var rect = CGRect.zero
                guard AXValueGetValue(value, .cgRect, &rect) else { continue }

                infos.append(
                    AXElementInfo(
                        frame: rect,
                        title: stringAttribute(element, "AXTitle"),
                        identifier: stringAttribute(element, "AXIdentifier"),
                        help: stringAttribute(element, "AXHelp")
                    )
                )
            }
            return infos
        }.value

        let probe = AppProbe(elements: elements, probedAt: Date())
        appProbeCache[pid] = probe
        return probe
    }

    /// 纯几何匹配（供测试）：元素矩形与窗口矩形在容差内一致。
    public static func framesMatch(_ elementFrame: CGRect, _ windowFrame: CGRect) -> Bool {
        framesMatch(
            elementFrame,
            windowFrame,
            tolerance: frameMatchTolerance
        )
    }

    public static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    /// extras-bar 子元素与条目窗口的横向匹配：AX 元素纵向度量与窗口
    /// （含边距）不可比，只比较 X 与宽度（对十几个条目已足够区分）。
    public static func xAlignMatch(_ elementFrame: CGRect, _ windowFrame: CGRect) -> Bool {
        abs(elementFrame.minX - windowFrame.minX) <= 6
            && abs(elementFrame.width - windowFrame.width) <= 8
    }
}

private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else { return nil }
    return value
}

private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    guard let raw = copyAttribute(element, attribute) else { return nil }
    return raw as? String
}

private func frameAttribute(_ element: AXUIElement) -> CGRect? {
    guard
        let raw = copyAttribute(element, "AXFrame"),
        CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    let value = unsafeBitCast(raw, to: AXValue.self)
    var rect = CGRect.zero
    return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
}
