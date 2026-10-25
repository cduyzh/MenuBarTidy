import Foundation

/// 应用设置（UserDefaults 持久化）。全部键集中在此，避免散落字符串。
public struct MenuBarSettings: Codable, Equatable, Sendable {
    /// 「隐藏」分区唤出后，点击菜单栏以外区域多少秒收回；0 表示仅手动。
    public var autoRehideSeconds: Double
    /// 是否启用「始终隐藏」分区。
    public var alwaysHiddenEnabled: Bool
    /// 全局热键开关。
    public var hotkeyEnabled: Bool
    /// 热键的虚拟键码（Carbon VirtualKeyCode）。
    public var hotkeyKeyCode: Int
    /// 热键修饰键（Carbon modifier mask，含 cmdKey 位等）。
    public var hotkeyModifiers: Int
    /// 断言路径（macOS 27+）的隐藏分区 bundleID 集合。
    public var hiddenBundles: [String]
    /// 断言路径的「始终隐藏」bundleID 集合。
    public var alwaysHiddenBundles: [String]

    public init(
        autoRehideSeconds: Double = 2,
        alwaysHiddenEnabled: Bool = true,
        hotkeyEnabled: Bool = true,
        hotkeyKeyCode: Int = 46,
        hotkeyModifiers: Int = 4352,
        hiddenBundles: [String] = [],
        alwaysHiddenBundles: [String] = []
    ) {
        self.autoRehideSeconds = autoRehideSeconds
        self.alwaysHiddenEnabled = alwaysHiddenEnabled
        self.hotkeyEnabled = hotkeyEnabled
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.hiddenBundles = hiddenBundles
        self.alwaysHiddenBundles = alwaysHiddenBundles
    }
}

/// 默认热键 ⌘⌃M：46 为虚拟键码 M，4352 = cmdKey(256) + controlKey(4096)。
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore(defaults: .standard)

    private let defaults: UserDefaults
    private let key = "cduyzhMenuBar.settings"

    @Published public var settings: MenuBarSettings {
        didSet { persist() }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if
            let data = defaults.data(forKey: key),
            var decoded = try? JSONDecoder().decode(MenuBarSettings.self, from: data)
        {
            // 兼容旧版本编码里缺失的新字段。
            if decoded.hiddenBundles.isEmpty, let legacy = try? JSONDecoder().decode(MenuBarSettings.self, from: data) {
                decoded = legacy
            }
            settings = decoded
        } else {
            settings = MenuBarSettings()
            if let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: key)
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
