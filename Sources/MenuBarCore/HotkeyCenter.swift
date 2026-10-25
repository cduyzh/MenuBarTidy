import AppKit
import Carbon.HIToolbox
import Foundation

/// Carbon 修饰键位（与 EventManager 的 mask 常量一致）。
public enum CarbonModifierMasks {
    public static let cmdKey = 0x0100
    public static let shiftKey = 0x0200
    public static let alphaLock = 0x0400
    public static let optionKey = 0x0800
    public static let controlKey = 0x1000
}

/// 热键的显示格式化（纯函数）。
public enum HotkeyFormat {
    /// 常用虚拟键码 → 显示字符。未收录的键码显示为 "Key<码>"。
    public static func string(forKeyCode keyCode: Int) -> String {
        let table: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "␣", 50: "`",
            51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return table[keyCode] ?? "Key\(keyCode)"
    }

    /// Carbon 修饰键位掩码 → 符号前缀。
    public static func modifierSymbols(carbonMask: Int) -> String {
        var symbols = ""
        if carbonMask & CarbonModifierMasks.controlKey != 0 { symbols += "⌃" }
        if carbonMask & CarbonModifierMasks.optionKey != 0 { symbols += "⌥" }
        if carbonMask & CarbonModifierMasks.shiftKey != 0 { symbols += "⇧" }
        if carbonMask & CarbonModifierMasks.cmdKey != 0 { symbols += "⌘" }
        return symbols
    }

    public static func display(keyCode: Int, carbonMask: Int) -> String {
        modifierSymbols(carbonMask: carbonMask) + string(forKeyCode: keyCode)
    }

    /// NSEvent 修饰键 → Carbon 位。
    public static func carbonMask(fromCocoaFlags flags: Int) -> Int {
        let cocoa = UInt(flags)
        var mask = 0
        if cocoa & NSEvent.ModifierFlags.command.rawValue != 0 {
            mask |= CarbonModifierMasks.cmdKey
        }
        if cocoa & NSEvent.ModifierFlags.option.rawValue != 0 {
            mask |= CarbonModifierMasks.optionKey
        }
        if cocoa & NSEvent.ModifierFlags.control.rawValue != 0 {
            mask |= CarbonModifierMasks.controlKey
        }
        if cocoa & NSEvent.ModifierFlags.shift.rawValue != 0 {
            mask |= CarbonModifierMasks.shiftKey
        }
        return mask
    }
}

/// 全局热键（Carbon RegisterEventHotKey）。
/// Carbon 事件处理回调无法携带上下文，这里用一个静态注册表按签名分发。
public final class HotkeyCenter {
    public struct Hotkey: Equatable, Sendable {
        public let keyCode: Int
        public let modifiers: Int

        public init(keyCode: Int, modifiers: Int) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    public static let shared = HotkeyCenter()

    private static var handlers: [Int: () -> Void] = [:]
    private static var registeredRefs: [Int: EventHotKeyRef] = [:]
    private static var nextToken = 1
    private static var installed = false
    private let queue = DispatchQueue(label: "cduyzhMenuBar.hotkey")

    /// 注册并启用一个热键。返回用于注销的令牌；注册失败返回 nil。
    @discardableResult
    public func register(_ hotkey: Hotkey, handler: @escaping () -> Void) -> Int? {
        queue.sync {
            installHandlerOnceLocked()

            let token = Self.nextToken
            Self.nextToken += 1
            Self.handlers[token] = handler

            var ref: EventHotKeyRef?
            let ID = EventHotKeyID(signature: OSType(0x434D4252), id: UInt32(token))
            let status = RegisterEventHotKey(
                UInt32(hotkey.keyCode),
                UInt32(hotkey.modifiers),
                ID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            guard status == noErr, let ref else {
                Self.handlers.removeValue(forKey: token)
                return nil
            }
            Self.registeredRefs[token] = ref
            return token
        }
    }

    public func unregister(token: Int) {
        queue.sync {
            if let ref = Self.registeredRefs.removeValue(forKey: token) {
                UnregisterEventHotKey(ref)
            }
            Self.handlers.removeValue(forKey: token)
        }
    }

    public func unregisterAll() {
        queue.sync {
            for (_, ref) in Self.registeredRefs {
                UnregisterEventHotKey(ref)
            }
            Self.registeredRefs.removeAll()
            Self.handlers.removeAll()
        }
    }

    private func installHandlerOnceLocked() {
        guard !Self.installed else { return }
        Self.installed = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var ID = EventHotKeyID()
                guard GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &ID
                ) == noErr else { return noErr }
                let token = Int(ID.id)
                if let handler = HotkeyCenter.handlers[token] {
                    DispatchQueue.main.async { handler() }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }
}
