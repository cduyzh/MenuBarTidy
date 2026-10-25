import AppKit
import MenuBarCore
import ServiceManagement
import SwiftUI

// MARK: - 设置窗口容器

private enum SettingsSection: String, CaseIterable, Identifiable {
    case layout
    case general
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .layout: "布局"
        case .general: "通用"
        case .permissions: "权限"
        case .about: "关于"
        }
    }

    var icon: String {
        switch self {
        case .layout: "menubar.rectangle"
        case .general: "slider.horizontal.3"
        case .permissions: "hand.raised"
        case .about: "info.circle"
        }
    }

    var detail: String {
        switch self {
        case .layout: "分配菜单栏条目"
        case .general: "行为、热键与启动"
        case .permissions: "辅助功能授权"
        case .about: "版本与说明"
        }
    }
}

private enum LayoutSectionFilter: String, CaseIterable, Identifiable {
    case all
    case visible
    case hidden
    case alwaysHidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部条目"
        case .visible: MenuBarSection.visible.displayName
        case .hidden: MenuBarSection.hidden.displayName
        case .alwaysHidden: MenuBarSection.alwaysHidden.displayName
        }
    }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .visible: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "eye.slash.fill"
        }
    }
}

/// 设置窗口使用侧边栏导航，页面切换时保持统一尺寸和层级。
struct SettingsView: View {
    @State private var selection: SettingsSection? = .layout

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("MenuBarTidy") {
                    ForEach(SettingsSection.allCases) { section in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                Text(section.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: section.icon)
                                .frame(width: 20)
                        }
                        .tag(section)
                        .padding(.vertical, 3)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("设置")
        } detail: {
            Group {
                switch selection ?? .layout {
                case .layout: LayoutEditorView()
                case .general: GeneralSettingsView()
                case .permissions: PermissionsView()
                case .about: AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620)
    }
}

// MARK: - 布局编辑器（侧边栏 + 可搜索列表）

struct LayoutEditorView: View {
    @EnvironmentObject private var coordinator: MenuBarCoordinator
    @AppStorage("cduyzhMenuBar.onboarded") private var onboarded = false
    @State private var searchText = ""
    @State private var sectionFilter: LayoutSectionFilter = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader
                if !onboarded {
                    OnboardingCard { onboarded = true }
                }
                operationStatus
                if AXAccess.isProcessTrusted() {
                    summaryCards
                    filterBar
                    itemList
                } else {
                    untrustedPlaceholder
                }
                footer
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("布局")
        .navigationSubtitle("分配菜单栏条目")
        .onAppear {
            Task { await coordinator.refreshSnapshot() }
        }
    }

    // MARK: 页面头部

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("菜单栏布局")
                    .font(.title2.weight(.semibold))
                Text("把不常用的条目收进隐藏分区，菜单栏只保留你需要的内容。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    Task { await coordinator.refreshSnapshot() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("重新枚举菜单栏条目并解析来源")
                Button {
                    coordinator.toggleHiddenSection()
                } label: {
                    Label(
                        coordinator.isExpanded ? "收拢分区" : "唤出分区",
                        systemImage: coordinator.isExpanded ? "arrow.left" : "arrow.right"
                    )
                }
                .buttonStyle(.borderedProminent)
                .help("在菜单栏上立即唤出或收拢隐藏分区")
            }
        }
    }

    private var summaryCards: some View {
        let visible = items(in: .visible).count
        let hidden = items(in: .hidden).count
        let alwaysHidden = items(in: .alwaysHidden).count
        return HStack(spacing: 10) {
            LayoutStatCard(title: "可见", value: visible, icon: "eye", tint: .blue)
            LayoutStatCard(title: "隐藏", value: hidden, icon: "eye.slash", tint: .orange)
            LayoutStatCard(title: "始终隐藏", value: alwaysHidden, icon: "eye.slash.fill", tint: .purple)
        }
    }

    @ViewBuilder
    private var operationStatus: some View {
        if coordinator.isMoving {
            Label("正在移动条目…", systemImage: "arrow.triangle.2.circlepath")
                .font(.callout)
                .foregroundStyle(.tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        } else if !coordinator.lastReport.failedWindowIDs.isEmpty {
            Label("有条目未能移动，请重试或检查辅助功能权限", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        } else if coordinator.lastReport.movedCount > 0 {
            Label("已更新 \(coordinator.lastReport.movedCount) 个条目的分区", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索应用、来源或条目名称", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 18)
            Picker("筛选", selection: $sectionFilter) {
                ForEach(LayoutSectionFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.icon).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: 列表

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("菜单栏条目")
                    .font(.headline)
                Spacer()
                Text("\(filteredItems.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List(filteredItems) { item in
            ItemRow(item: item, currentSection: coordinator.section(for: item))
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quinary.opacity(0.48))
            )
            .frame(minHeight: 220, maxHeight: 390)
            .overlay {
                if coordinator.items.isEmpty {
                    emptyOverlay
                } else if filteredItems.isEmpty {
                    noMatchOverlay
                }
            }
        }
    }

    private var filteredItems: [MenuBarItemSnapshot] {
        coordinator.items.filter { item in
            let sectionMatches: Bool
            switch sectionFilter {
            case .all: sectionMatches = true
            case .visible: sectionMatches = coordinator.section(for: item) == .visible
            case .hidden: sectionMatches = coordinator.section(for: item) == .hidden
            case .alwaysHidden: sectionMatches = coordinator.section(for: item) == .alwaysHidden
            }
            guard sectionMatches else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return item.displayName.localizedCaseInsensitiveContains(query)
                || item.identity.namespace.localizedCaseInsensitiveContains(query)
                || item.identity.title.localizedCaseInsensitiveContains(query)
                || (item.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var emptyOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "menubar.rectangle")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("没有枚举到菜单栏条目")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("请确认其他应用的状态栏图标已显示，然后点「刷新」")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private var noMatchOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("没有匹配的条目")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("试试其他关键词或切换分区筛选")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private var untrustedPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.title)
                .foregroundStyle(.orange)
            Text("需要辅助功能权限")
                .font(.title3.weight(.semibold))
            Text("布局编辑器读取条目来源与搬移条目需要辅助功能权限。菜单栏上的唤出/收拢不受影响，随时可用。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("打开系统设置…") { AXAccess.openAccessibilitySettings() }
                    .buttonStyle(.borderedProminent)
                Button("我已授权，重新检查") {
                    Task { await coordinator.refreshSnapshot() }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: 底部说明

    private var footer: some View {
        Label("分配会立即生效并被系统记住。也可以在菜单栏上按住 ⌘，把条目拖过分隔线。", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func items(in section: MenuBarSection) -> [MenuBarItemSnapshot] {
        coordinator.items.filter { coordinator.section(for: $0) == section }
    }
}

private struct LayoutStatCard: View {
    let title: String
    let value: Int
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(value)")
                    .font(.headline.monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.34), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 首次上手引导卡

private struct OnboardingCard: View {
    let dismiss: () -> Void

    private let steps: [(icon: String, title: String, detail: String)] = [
        ("hand.tap", "点分隔符唤出", "菜单栏上的细箭头分隔符（或按 ⌘⌃M）切换隐藏分区"),
        ("square.split.2x1", "在下方分配条目", "选择每个条目的分区：可见 / 隐藏 / 始终隐藏"),
        ("clock.arrow.circlepath", "自动收拢", "唤出后默认 2 秒收拢，可在「通用」里调整"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("快速上手", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button("开始使用", action: dismiss)
                    .buttonStyle(.borderedProminent)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Image(systemName: step.icon)
                                .foregroundStyle(.tint)
                            Text(step.title).font(.callout.bold())
                        }
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if index < steps.count - 1 {
                        Divider().frame(height: 32)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.tint.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.tint.opacity(0.25))
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

// MARK: - 条目行

private struct ItemRow: View {
    @EnvironmentObject private var coordinator: MenuBarCoordinator
    let item: MenuBarItemSnapshot
    let currentSection: MenuBarSection

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if coordinator.isMoving && coordinator.movingWindowID == item.windowID {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 138)
            } else {
                Menu {
                    sectionButton(.visible)
                    sectionButton(.hidden)
                    sectionButton(.alwaysHidden)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: currentSection.iconName)
                        Text(currentSection.displayName)
                    }
                    .font(.callout)
                    .frame(width: 126, alignment: .leading)
                }
                .menuStyle(.borderedButton)
                .disabled(coordinator.isMoving)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func sectionButton(_ section: MenuBarSection) -> some View {
        Button {
            guard section != currentSection else { return }
            Task {
                await coordinator.move(item, to: section)
                await coordinator.refreshSnapshot()
            }
        } label: {
            Label {
                Text(section.displayName)
            } icon: {
                Image(systemName: section.iconName)
            }
        }
        .disabled(section == currentSection)
    }

    @ViewBuilder
    private var icon: some View {
        if
            let pid = item.sourcePID,
            let appIcon = AppCatalog.entry(for: pid)?.icon
        {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
        }
    }

    /// 主标题：系统条目直接用友好名（隔空投送/时钟…），其余用 App 名。
    private var titleText: String {
        if item.identity.title.hasPrefix("com.apple.menuextra.") {
            let raw = String(item.identity.title.dropFirst("com.apple.menuextra.".count))
            return Self.menuExtraNames[item.identity.title] ?? raw
        }
        if item.identity.title.isEmpty {
            return item.displayName
        }
        return item.displayName
    }

    /// 副标题：来源信息或宽度兜底。
    private var subtitleText: String {
        if item.identity.title.hasPrefix("com.apple.menuextra.") {
            return "系统条目"
        }
        if let bundle = item.bundleIdentifier, !bundle.isEmpty {
            return bundle
        }
        if item.sourcePID == nil {
            return "宽 \(Int(item.frame.width))pt · 来源未识别"
        }
        if !item.identity.title.isEmpty {
            return item.identity.title
        }
        return "宽 \(Int(item.frame.width))pt"
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
}

// MARK: - 通用设置

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var coordinator: MenuBarCoordinator
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var recordingHotkey = false

    var body: some View {
        Form {
            Section("分区行为") {
                Text("决定隐藏分区被唤出后何时自动收拢。鼠标停留在菜单栏或菜单打开时会自动顺延。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("唤出后自动收拢", selection: Binding(
                    get: { settings.settings.autoRehideSeconds },
                    set: { settings.settings.autoRehideSeconds = $0 }
                )) {
                    Text("仅手动（点击分隔符收回）").tag(0.0)
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("5 秒").tag(5.0)
                    Text("10 秒").tag(10.0)
                }
                Toggle("启用「始终隐藏」分区", isOn: Binding(
                    get: { settings.settings.alwaysHiddenEnabled },
                    set: { newValue in
                        settings.settings.alwaysHiddenEnabled = newValue
                        coordinator.setAlwaysHiddenEnabled(newValue)
                    }
                ))
            }

            Section("全局热键（唤出/收拢隐藏分区）") {
                Text("使用任意带修饰键的组合键，录入后立即生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("启用热键", isOn: Binding(
                    get: { settings.settings.hotkeyEnabled },
                    set: { newValue in
                        settings.settings.hotkeyEnabled = newValue
                        AppDelegate.instance?.applyHotkey()
                    }
                ))
                HStack {
                    Label {
                        Text(currentHotkeyText)
                            .monospaced()
                    } icon: {
                        Image(systemName: recordingHotkey ? "record.circle.fill" : "keyboard")
                            .foregroundStyle(recordingHotkey ? .red : .secondary)
                    }
                    Spacer()
                    Button(recordingHotkey ? "按下组合键…（⎋ 取消）" : "录入热键") {
                        if recordingHotkey {
                            recordingHotkey = false
                        } else {
                            recordingHotkey = true
                            installRecorder()
                        }
                    }
                    .disabled(!settings.settings.hotkeyEnabled)
                }
                if recordingHotkey {
                    Text("请按下新的组合键；按 Esc 取消。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("启动") {
                Text("登录后自动在菜单栏运行，无需打开主窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin.toggle()
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
        .navigationSubtitle("行为、热键与启动")
        .onDisappear {
            recordingHotkey = false
        }
    }

    private var currentHotkeyText: String {
        HotkeyFormat.display(
            keyCode: settings.settings.hotkeyKeyCode,
            carbonMask: settings.settings.hotkeyModifiers
        )
    }

    private func installRecorder() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let carbonMask = HotkeyFormat.carbonMask(fromCocoaFlags: Int(event.modifierFlags.rawValue))
            if event.keyCode == 53 { // ⎋ 取消录入
                Task { @MainActor in recordingHotkey = false }
                return nil
            }
            // 没有修饰键的按键不算热键，继续等待录入。
            guard carbonMask != 0 else { return event }
            Task { @MainActor in recordingHotkey = false }
            settings.settings.hotkeyKeyCode = Int(event.keyCode)
            settings.settings.hotkeyModifiers = carbonMask
            AppDelegate.instance?.applyHotkey()
            return nil
        }
        Task { @MainActor in
            while recordingHotkey {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - 权限

struct PermissionsView: View {
    @State private var trusted = AXAccess.isProcessTrusted()
    @State private var timer: Timer?

    var body: some View {
        Form {
            Section("辅助功能（仅布局编辑器需要）") {
                Label {
                    Text(trusted ? "已授权" : "未授权")
                } icon: {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(trusted ? .green : .red)
                }
                Text("菜单栏上的唤出/收拢不需要任何权限。辅助功能仅用于读取条目名称来源，以及在布局编辑器里合成 ⌘-拖拽搬移条目。授权后无需重启应用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("打开系统设置…") {
                        AXAccess.openAccessibilitySettings()
                    }
                }
            }

            Section("屏幕录制（不需要）") {
                Text("本应用不截取屏幕内容：条目图标取自所属 App 的应用图标，不做实时像素捕获。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("权限")
        .navigationSubtitle("辅助功能授权")
        .onAppear {
            let poller = Timer(timeInterval: 2, repeats: true) { _ in
                Task { @MainActor in
                    trusted = AXAccess.isProcessTrusted()
                }
            }
            RunLoop.main.add(poller, forMode: .common)
            timer = poller
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - 关于

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("MenuBarTidy")
                .font(.title2.bold())
            Text("版本 \(versionText)（构建 \(buildText)）")
                .foregroundStyle(.secondary)
            Text("原生 macOS 菜单栏管理器：隐藏杂项、保留所需。隐藏机制与 Hidden Bar（dwarvesf/hidden）交互兼容，适配最新 macOS（含 Control Center 托管状态条目的版本）。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("关于")
        .navigationSubtitle("版本与说明")
    }

    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    }

    private var buildText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
