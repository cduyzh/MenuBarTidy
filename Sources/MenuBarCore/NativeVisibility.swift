import AppKit
import Foundation

/// 持有的可见性断言：invalidate 或本进程退出前一直生效。
/// 进程退出时 macOS 自行释放并恢复菜单栏。
public final class NativeVisibilityAssertionBox: @unchecked Sendable {
    private var raw: NSObject?
    private let invalidateSEL = Selector(("invalidate"))

    init(raw: NSObject) {
        self.raw = raw
    }

    public func invalidate() {
        guard let raw else { return }
        self.raw = nil
        guard raw.responds(to: invalidateSEL) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend") else { return }
        unsafeBitCast(symbol, to: Fn.self)(raw, invalidateSEL)
    }

    deinit {
        invalidate()
    }
}

public enum NativeVisibilityError: LocalizedError {
    case unavailable
    case configurationFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: "MenuBarClientCore 在此系统上不可用"
        case .configurationFailed: "可见性配置对象创建失败"
        }
    }
}

/// macOS 27 的原生菜单栏可见性断言（参考 dwarvesf/hidden 的
/// HBNativeVisibilityShim，其源头是系统的考试锁定模式）。
///
/// 私有框架 MenuBarClientCore：
/// ```
/// config   = [MBAssessmentModeConfiguration alloc]
///            initWithAllowedSystemItems:allowedBundleIdentifiers:
/// assertion = [MBAssessmentModeAssertion alloc] init
/// [assertion activateWithConfiguration:completionHandler:]
/// [assertion invalidate]
/// ```
/// macOS 自行隐藏不在白名单里的条目并重排菜单栏。
public enum NativeVisibility {
    static let frameworkPath =
        "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"

    /// 框架与所需类/选择器是否齐备（含 dlopen）。
    public static func isAvailable() -> Bool {
        guard dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) != nil else { return false }
        guard
            let configuration = NSClassFromString("MBAssessmentModeConfiguration"),
            let assertion = NSClassFromString("MBAssessmentModeAssertion")
        else { return false }
        // 注意：alloc 是类方法，不能用类对象的 responds(to:) 检查；
        // 只校验三个实例选择器。
        return configuration.instancesRespond(to: Selector(("initWithAllowedSystemItems:allowedBundleIdentifiers:")))
            && assertion.instancesRespond(to: Selector(("activateWithConfiguration:completionHandler:")))
            && assertion.instancesRespond(to: Selector(("invalidate")))
    }

    /// 当前系统是否应走原生路径（27+ 且框架可用）。
    public static func shouldUseNativePath() -> Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 && isAvailable()
    }

    // MARK: - objc_msgSend 桥（按参数个数区分的 C 约定签名）

    private typealias Send0 = @convention(c) (AnyObject, Selector) -> AnyObject
    private typealias Send2Ret = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> AnyObject
    private typealias Send2Void = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void

    private static let msgSendHandle = dlopen(nil, RTLD_NOW)

    private static func msgSendSymbol() -> UnsafeMutableRawPointer? {
        msgSendHandle.flatMap { dlsym($0, "objc_msgSend") }
    }

    private static var send0: Send0? {
        msgSendSymbol().map { unsafeBitCast($0, to: Send0.self) }
    }

    private static var send2Ret: Send2Ret? {
        msgSendSymbol().map { unsafeBitCast($0, to: Send2Ret.self) }
    }

    private static var send2Void: Send2Void? {
        msgSendSymbol().map { unsafeBitCast($0, to: Send2Void.self) }
    }

    /// 激活一条可见性限制。完成回调在主队列。
    /// - Parameters:
    ///   - allowedSystemItems: 保留的系统条目编号（0–63 覆盖各机型组合）。
    ///   - allowedBundleIdentifiers: 允许显示菜单栏条目的 App bundleID。
    public static func activate(
        allowedSystemItems: [Int] = Array(0..<64),
        allowedBundleIdentifiers: [String],
        completion: @escaping (Result<NativeVisibilityAssertionBox, Error>) -> Void
    ) {
        guard
            let configurationClass = NSClassFromString("MBAssessmentModeConfiguration"),
            let assertionClass = NSClassFromString("MBAssessmentModeAssertion"),
            let send0,
            let send2Ret,
            let send2Void
        else {
            completion(.failure(NativeVisibilityError.unavailable))
            return
        }

        let allocSEL = Selector(("alloc"))
        let initSEL = Selector(("initWithAllowedSystemItems:allowedBundleIdentifiers:"))
        let activateSEL = Selector(("activateWithConfiguration:completionHandler:"))

        // 两个列表必须是 NSArray：框架按索引取值，NSSet 会触发未识别选择器。
        let systemItems = allowedSystemItems.map { NSNumber(value: $0) } as NSArray
        let bundles = allowedBundleIdentifiers as NSArray

        guard
            let configuration = (send2Ret(
                send0(configurationClass, allocSEL),
                initSEL,
                systemItems,
                bundles
            ) as? NSObject)
        else {
            completion(.failure(NativeVisibilityError.configurationFailed))
            return
        }
        guard let assertion = send0(assertionClass, allocSEL) as? NSObject else {
            completion(.failure(NativeVisibilityError.configurationFailed))
            return
        }

        let block: @convention(block) (NSError?) -> Void = { error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(NativeVisibilityAssertionBox(raw: assertion)))
                }
            }
        }
        send2Void(assertion, activateSEL, configuration, unsafeBitCast(block, to: AnyObject.self))
    }
}

// MARK: - 分区集合策略（纯函数，供测试）

/// 断言路径的分区数据模型：以 bundleID 集合为唯一真值（macOS 27 上
/// 条目窗口列表已从 CGWindowList 消失，几何位置不再可读）。
public enum SectionSetPolicy {
    /// 系统宿主进程：菜单条目由它们承载，必须始终在白名单里，
    /// 否则时钟/控制中心等系统条目会连同第三方条目一起消失。
    public static let systemHostBundles = [
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
    ]

    /// 计算收起（只显示可见区）时的白名单。
    ///
    /// - Returns:
    ///   - allowed: 应允许显示的 bundleID（含自身与系统宿主）。
    ///   - unresolvedVisible: 位于可见区但 bundleID 未解析的条目——
    ///     按 fail-open 原则，存在此类条目时调用方应放弃收起。
    public static func allowedBundlesForCollapse(
        visibleBundles: [String?],
        ownBundle: String?
    ) -> (allowed: [String], unresolvedVisible: [String?]) {
        var allowed = Set<String>(systemHostBundles)
        var unresolved = [String?]()
        for bundle in visibleBundles {
            guard let bundle, !bundle.isEmpty else {
                unresolved.append(bundle)
                continue
            }
            allowed.insert(bundle)
        }
        if let ownBundle, !ownBundle.isEmpty {
            allowed.insert(ownBundle)
        }
        return (Array(allowed).sorted(), unresolved)
    }

    /// 展开时的白名单：可见 + 隐藏（「始终隐藏」的条目保持隐藏）。
    /// 展开不存在 fail-open 问题：未解析条目不在白名单即保持原状。
    public static func allowedBundlesForExpand(
        visibleBundles: [String?],
        hiddenBundles: [String?],
        ownBundle: String?
    ) -> [String] {
        let result = allowedBundlesForCollapse(
            visibleBundles: visibleBundles + hiddenBundles,
            ownBundle: ownBundle
        )
        return result.allowed
    }
}
