# MenuBarTidy（菜单栏管家）

> 原生 macOS 菜单栏管理器——把不常看的状态条目收进分隔符后，点击或热键随时唤回。

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://github.com/cduyzh/MenuBarTidy/releases)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://github.com/cduyzh/MenuBarTidy)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Author](https://img.shields.io/badge/Author-cduyzh-blue?style=flat-square)](https://github.com/cduyzh)

[English](README.md) · **简体中文**

MenuBarTidy 是一个面向 macOS 14 及以上版本的原生菜单栏管理器——Hidden Bar 与 Ice 的现代替代品。它把你不常需要的状态条目收进隐藏分区，点击分隔符或按全局热键即可唤回。在 Control Center 托管全部状态条目、老牌工具相继失效的最新 macOS（最高至 macOS 26）上，它依然正常工作。

## 功能特性

- **隐藏与唤出** —— 点击菜单栏上的分隔符（或按全局热键，默认 ⌘⌃M）在收起与展开间切换。收起瞬时完成：无拖拽、无闪烁。
- **三分区** —— **始终隐藏**（任何状态下都离屏）、**隐藏**（收起时离屏、唤出时回归）、**可见**（分隔符右侧）。
- **分区即摆放** —— 条目属于哪个分区完全由它相对分隔符的位置决定，与 Hidden Bar 交互一致。按住 ⌘ 把条目拖过分隔线即完成分配，菜单栏布局由系统自身的 autosave 持久化。
- **布局编辑器** —— 设置 › 布局 按分区列出全部条目（App 图标 + 来源名称），◀▶ 按钮一步搬移；系统条目显示友好名称（隔空投送、时钟……）。
- **自动收拢** —— 展开后点击菜单栏以外区域即收拢；延迟可选 0（仅手动）– 10 秒，鼠标停留在菜单栏内或菜单打开时自动顺延。
- **全局热键** —— 随处唤出/收拢隐藏分区；热键可在设置中录入。
- **来源识别** —— 三级解析点名每个状态条目的所属 App，在 Control Center 托管一切条目窗口的 macOS 26 上同样有效。
- **切换零权限** —— 隐藏与唤出不需要任何权限。辅助功能权限仅用于编辑器搬移与来源识别。
- **登录启动** —— 以 `SMAppService` 实现，无第三方依赖。
- **真正的菜单栏应用** —— `LSUIElement`：无 Dock 图标、无主窗口。
- **版本管理** —— 版本号唯一来自根目录 `Info.plist`；更新历史见 `CHANGELOG.md`。
- **诊断日志** —— 每次启动记录一次枚举与解析快照，写入 `~/Library/Logs/cduyzhMenuBar/diag.log`。

## 工作原理

- **分隔符膨胀式隐藏** —— macOS ≤ 26 的菜单栏围绕任意 `NSStatusItem.length` 重排。收起时把分隔符长度设为 `max(500, min(最宽显示器 × 2, 10000))` pt，系统自身的菜单栏布局即把其左侧所有条目挤出可见区；展开时缩回 20 pt，条目自动回流。全程只改自己条目的长度——不合成事件、不移动其他条目、不与系统的条目位置记忆对抗。「始终隐藏」分隔符恒定膨胀，其左侧条目在展开与收起两态都保持离屏。
- **分区语义** —— 屏幕顺序为 `[始终隐藏条目][AH 分隔符][隐藏条目][分隔符][箭头][齿轮][可见条目]`。归属判定纯几何：AH 分隔符右侧（且在主分隔符左侧）为隐藏、更左为始终隐藏、主分隔符右侧为可见。菜单栏布局由系统 autosave 持久化，应用自身不保存分区分配表。
- **控制条目堆叠** —— 在 macOS 26 上经实测确认：新建状态条目排在最左（屏幕顺序 = 创建顺序的逆序），因此控制条目按 `[齿轮, 箭头, 分隔符, AH 分隔符]` 的顺序创建以得到所需布局；收起前校验分隔符位于箭头的隐藏侧。
- **Fail-open** —— 布局未摆放时不隐藏任何东西。宁可什么都不做，也不隐藏错东西。
- **三级来源识别** —— ① 逐 App 读取 `AXExtrasMenuBar` 子元素并与条目窗口做横向几何匹配（AX 元素矩形是内容区、窗口含边距，按 X ±6 pt / 宽度 ±8 pt 容差对齐）；② 逐 App 限定域 AX 命中测试，用于不暴露 extras-bar 的 Electron / 自绘条目（在其自身 AX 树内命中即可返回条目元素）；③ 系统级命中测试，帧校验防止前台菜单栏误报。每个 AX 调用都有 0.3–1.2 秒超时与缓存，窗口存活期间记住源 PID。
- **仅编辑器搬移** —— 合成 ⌘-拖拽只在布局编辑器内使用：忠实拖拽时序、落位验证、失败冷却与屏幕边缘 mouseUp 释放兜底，每次搬移一次性完成。
- **窗口编号 64 位承载** —— macOS 26 起窗口编号可能超出 32 位（且 `NSStatusItem` 窗口编号高位编码槽位序号），全链路以 `Int` 承载，不做 `UInt32` 截断。
- **已知边界** —— macOS 27 会把过宽分隔符逐出菜单栏（上游 Hidden Bar #360），届时需切换到 `MenuBarClientCore` 的 assessment-mode 断言（已记录为升级路径）。菜单栏条目极多时，收起/展开的重排由系统完成，个别条目落点可能有几 pt 偏差。

## 权限

- **切换（隐藏/唤出）：零权限。** 分隔符的膨胀与收缩是纯 AppKit 行为，完全不需要授权。
- **辅助功能** 仅用于两项功能：布局编辑器中的条目搬移，以及解析每个状态条目的来源 App。
- **绝不截屏。** 应用不捕获屏幕，也永远不会申请屏幕录制权限。
- 一切都在本机运行，没有网络遥测。

## 下载与安装

1. 从 [Releases](https://github.com/cduyzh/MenuBarTidy/releases) 下载最新的 `cduyzhMenuBar-*.dmg`。
2. 打开 DMG，把 **MenuBarTidy** 拖入 `/Applications`。
3. 启动应用。如需编辑器搬移与来源识别，按提示授予辅助功能权限（系统设置 › 隐私与安全性 › 辅助功能）。
4. 打开 设置 › 布局，把不想常驻可见的条目移入「隐藏」或「始终隐藏」。
5. 点击菜单栏上的双箭头分隔符（或按 ⌘⌃M）唤出 / 收起隐藏分区。

## 从源码构建

需要 macOS 14+ 上的 Xcode 或 Command Line Tools（Swift 5.9+）。

```bash
git clone https://github.com/cduyzh/MenuBarTidy.git
cd MenuBarTidy
./build_app.sh          # 编译 Release 并打包 cduyzhMenuBar.app
```

构建只在本地生成应用包，不自动安装；`scripts/install-local.sh` 会验签后原子安装到 `/Applications`，带备份与回滚。开发时直接 `swift build` 与 `swift test` 也可。

## 版本历史

当前版本为 **0.2.0**（构建 6），取自根目录 `Info.plist`——版本号与构建号的唯一真值。完整历史见 [CHANGELOG.md](CHANGELOG.md)。

## 隐私

一切都在你的 Mac 上本地完成。应用不含任何分析统计，自身不发起网络请求；每次启动写入 `~/Library/Logs/cduyzhMenuBar/diag.log` 的诊断日志只留在本机。

## 许可证

以 [MIT License](LICENSE) 发布。

## 作者

**cduyzh**

- GitHub：<https://github.com/cduyzh>
- 个人网站：<https://www.cduyzh.top>
- Goal：<https://www.cduyzh.top/goal>
