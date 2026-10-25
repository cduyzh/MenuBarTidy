import AppKit
import CoreGraphics
import Foundation

/// 合成 ⌘-拖拽移动引擎。
/// macOS 允许用户按住 ⌘ 拖动任意菜单栏条目；这是唯一公开、系统支持的
/// 重排第三方状态条目的途径（Thaw/Ice 的「标准隐藏」即基于此）。
/// 引擎按忠实拖拽的时序合成事件：warp 光标 → mouseDown(⌘) →
/// 若干插值 mouseDragged(⌘) → mouseUp(⌘)，随后轮询窗口矩形验证落位。
public final class DragMoveEngine {
    public enum MoveError: Error, Equatable, Sendable {
        case windowDisappeared
        case timedOut(targetX: CGFloat, reachedX: CGFloat)
        case notTrusted
    }

    public struct Outcome: Equatable, Sendable {
        public let windowID: Int
        public let success: Bool
        public let attempts: Int
        public let finalFrame: CGRect?

        public init(windowID: Int, success: Bool, attempts: Int, finalFrame: CGRect?) {
            self.windowID = windowID
            self.success = success
            self.attempts = attempts
            self.finalFrame = finalFrame
        }
    }

    public struct Configuration: Sendable {
        public var maxAttempts: Int
        public var verifyTimeout: TimeInterval
        public var verifyInterval: TimeInterval
        public var dragSteps: Int
        public var settleTolerance: CGFloat
        public var interAttemptDelay: TimeInterval

        public init(
            maxAttempts: Int = 3,
            verifyTimeout: TimeInterval = 1.5,
            verifyInterval: TimeInterval = 0.1,
            dragSteps: Int = 8,
            settleTolerance: CGFloat = 3,
            interAttemptDelay: TimeInterval = 0.2
        ) {
            self.maxAttempts = maxAttempts
            self.verifyTimeout = verifyTimeout
            self.verifyInterval = verifyInterval
            self.dragSteps = dragSteps
            self.settleTolerance = settleTolerance
            self.interAttemptDelay = interAttemptDelay
        }
    }

    private let configuration: Configuration
    /// 连续失败的窗口冷却记录：windowID → 允许再次尝试的时间。
    private var failureCooldowns: [Int: Date] = [:]
    private let cooldownInterval: TimeInterval

    public init(configuration: Configuration = Configuration(), cooldownInterval: TimeInterval = 10) {
        self.configuration = configuration
        self.cooldownInterval = cooldownInterval
    }

    /// 把一个条目窗口拖到目标矩形的横向位置（Y 保持不变——菜单栏条目
    /// 只能水平移动，系统会锁定其纵向位置）。
    public func move(windowID: Int, from current: CGRect, to target: CGRect) async -> Outcome {
        func trace(_ s: String) {
            print("DRAG wid=\(windowID): \(s)")
            fflush(stdout)
            DiagLog.write("move wid=\(windowID): \(s)")
        }
        guard AXAccess.isProcessTrusted() else {
            trace("未授权，跳过")
            return Outcome(windowID: windowID, success: false, attempts: 0, finalFrame: current)
        }
        if let until = failureCooldowns[windowID], Date() < until {
            trace("冷却中，跳过")
            return Outcome(windowID: windowID, success: false, attempts: 0, finalFrame: current)
        }

        let start = CGPoint(x: current.midX, y: current.midY)
        let end = CGPoint(x: target.midX, y: current.midY)
        let savedCursor = NSEvent.mouseLocationCG

        var attempts = 0
        var lastFrame = current
        while attempts < configuration.maxAttempts {
            attempts += 1
            // 每次尝试前现读窗口帧：菜单栏在拖拽间隙持续重排，快照帧
            // 会过期，按下落空就等于白拖一次。
            guard let fresh = MenuBarWindowList.frame(ofWindowID: windowID) else {
                trace("窗口已消失")
                return Outcome(windowID: windowID, success: false, attempts: attempts, finalFrame: lastFrame)
            }
            lastFrame = fresh
            let start = CGPoint(x: fresh.midX, y: fresh.midY)
            let end = CGPoint(x: target.midX, y: fresh.midY)
            // 步数按距离缩放：长距离拖拽需要更密的插值才能被 WindowServer 跟上。
            let distance = abs(end.x - start.x)
            let steps = min(60, max(configuration.dragSteps, Int(distance / 40)))
            postFaithfulDrag(from: start, to: end, steps: steps)

            if
                let settled = await verifySettled(
                    windowID: windowID,
                    targetX: target.minX
                )
            {
                lastFrame = settled
                failureCooldowns.removeValue(forKey: windowID)
                restoreCursor(to: savedCursor)
                trace("ok attempts=\(attempts) steps=\(steps) x\(Int(fresh.minX))→x\(Int(settled.minX)) (target \(Int(target.minX)))")
                return Outcome(
                    windowID: windowID,
                    success: true,
                    attempts: attempts,
                    finalFrame: settled
                )
            }

            lastFrame = MenuBarWindowList.frame(ofWindowID: windowID) ?? lastFrame
            trace("attempt \(attempts)/\(configuration.maxAttempts) 未落位 x\(Int(fresh.minX))→x\(Int(target.minX))，当前 x\(Int(lastFrame.minX))")
            if attempts < configuration.maxAttempts {
                try? await Task.sleep(for: .seconds(configuration.interAttemptDelay))
            }
        }

        failureCooldowns[windowID] = Date().addingTimeInterval(cooldownInterval)
        restoreCursor(to: savedCursor)
        let final = MenuBarWindowList.frame(ofWindowID: windowID) ?? lastFrame
        trace("FAILED 进入冷却，最终 x\(Int(final.minX)) (target \(Int(target.minX)))")
        return Outcome(
            windowID: windowID,
            success: false,
            attempts: attempts,
            finalFrame: final
        )
    }

    /// 解除某窗口的失败冷却（用户显式重试时调用）。
    public func resetCooldown(windowID: Int) {
        failureCooldowns.removeValue(forKey: windowID)
    }

    public func resetAllCooldowns() {
        failureCooldowns.removeAll()
    }

    /// 连续失败冷却中的窗口集合（诊断用）。
    public var cooldownWindowIDs: Set<Int> {
        Set(failureCooldowns.filter { Date() < $0.value }.keys)
    }

    // MARK: - 事件合成

    /// 在屏内安全点补发一次 mouseUp：macOS 26 的 WindowServer 会拒收
    /// 负坐标的 mouseUp，留下「按钮仍按住」的卡死状态——后续 mouseDown
    /// 全部被吞，系统还会把正在拖的条目救回菜单栏。幂等的释放是前提。
    private func postStuckRelease() {
        let source = CGEventSource(stateID: .combinedSessionState)
        if
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: CGPoint(x: 700, y: 400),
                mouseButton: .left
            )
        {
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
        usleep(30_000)
    }

    /// 按忠实时序合成一次水平 ⌘-拖拽。
    private func postFaithfulDrag(from start: CGPoint, to end: CGPoint, steps: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)

        postStuckRelease()
        CGWarpMouseCursorPosition(start)
        shortPause()

        postEvent(source, .leftMouseDown, at: start)
        let count = max(1, steps)
        for index in 1...count {
            let t = CGFloat(index) / CGFloat(count + 1)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            postEvent(source, .leftMouseDragged, at: point)
            shortPause(pulses: 1)
        }
        postEvent(source, .leftMouseDragged, at: end)
        shortPause()
        postEvent(source, .leftMouseUp, at: end)
        // mouseUp 在负坐标会被拒收：紧接一次屏内释放兜底。
        postStuckRelease()
    }

    private func postEvent(_ source: CGEventSource?, _ type: CGEventType, at point: CGPoint) {
        guard
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else { return }
        event.flags = .maskCommand
        event.post(tap: .cghidEventTap)
    }

    private func shortPause(pulses: Int = 4) {
        // 每个脉冲约 16ms：事件之间留出 WindowServer 处理时间。
        var remaining = pulses
        while remaining > 0 {
            usleep(16_000)
            remaining -= 1
        }
    }

    private func restoreCursor(to point: CGPoint) {
        // 用户在移动期间若有真实输入，则不回拉光标，尊重物理位移。
        let moved: Double = min(
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDragged)
        )
        if moved < 1 {
            CGWarpMouseCursorPosition(point)
        }
    }

    // MARK: - 落位验证

    private func verifySettled(windowID: Int, targetX: CGFloat) async -> CGRect? {
        let deadline = Date().addingTimeInterval(configuration.verifyTimeout)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            if let frame = MenuBarWindowList.frame(ofWindowID: windowID) {
                if abs(frame.minX - targetX) <= configuration.settleTolerance {
                    return frame
                }
            } else {
                return nil
            }
            try? await Task.sleep(for: .seconds(configuration.verifyInterval))
        }
        return nil
    }
}

private extension NSEvent {
    /// 当前鼠标位置（CG 全局坐标，原点左上）。
    static var mouseLocationCG: CGPoint {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.main else { return location }
        let maxY = screen.frame.origin.y + screen.frame.height
        return CGPoint(x: location.x, y: maxY - location.y)
    }
}
