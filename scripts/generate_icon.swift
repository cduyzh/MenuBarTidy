#!/usr/bin/env swift
import AppKit
import Foundation

// 原创矢量绘制，所有尺寸均由 1024 点设计坐标直接重绘。
// 主题：菜单栏条带 + 双箭头分隔符 + 分区条目，对应「隐藏 · 唤出 · 分区」。
// 用法：swift scripts/generate_icon.swift [资源目录]
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)
let fileManager = FileManager.default
try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius)
}

func gradient(_ path: NSBezierPath, _ first: UInt32, _ last: UInt32, angle: CGFloat = -90) {
    NSGradient(starting: color(first), ending: color(last))?.draw(in: path, angle: angle)
}

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "IconRenderer", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)

    // 深板岩色圆角底板。
    let plate = rounded(72, 72, 880, 880, 198)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 22, color: color(0x101A2C, 0.28).cgColor)
    gradient(plate, 0x27354D, 0x141C2E)
    cg.restoreGState()
    plate.lineWidth = 3
    color(0xFFFFFF, 0.12).setStroke()
    plate.stroke()

    // 菜单栏条带：一块浅色横向面板。
    let bar = rounded(168, 404, 688, 216, 54)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: color(0x0B1220, 0.35).cgColor)
    gradient(bar, 0xF4F7FB, 0xD8E0EC)
    cg.restoreGState()
    color(0xFFFFFF, 0.75).setStroke()
    bar.lineWidth = 4
    bar.stroke()

    // 可见区条目：实心圆角块。
    color(0x2C6BD8).setFill()
    rounded(216, 470, 96, 84, 20).fill()
    color(0x6FA0F0).setFill()
    rounded(332, 470, 60, 84, 18).fill()

    // 分隔符（双箭头）底座。
    color(0x1E2A40).setFill()
    let dividerBase = rounded(430, 448, 88, 128, 26)
    dividerBase.fill()

    // 双箭头：收起向左、唤出向右，点出「切换」语义。
    color(0xEAF1FF).setFill()
    let chevronLeft = NSBezierPath()
    chevronLeft.move(to: NSPoint(x: 478, y: 556))
    chevronLeft.line(to: NSPoint(x: 452, y: 512))
    chevronLeft.line(to: NSPoint(x: 478, y: 468))
    chevronLeft.lineWidth = 16
    chevronLeft.lineCapStyle = .round
    chevronLeft.stroke()
    color(0x9FC2FF).setStroke()
    chevronLeft.stroke()

    let chevronLeftInner = NSBezierPath()
    chevronLeftInner.move(to: NSPoint(x: 450, y: 556))
    chevronLeftInner.line(to: NSPoint(x: 424, y: 512))
    chevronLeftInner.line(to: NSPoint(x: 450, y: 468))
    chevronLeftInner.lineWidth = 16
    chevronLeftInner.lineCapStyle = .round
    chevronLeftInner.stroke()

    // 隐藏区条目：两个半透明块（隐藏 = 淡出）。
    color(0x9FB4D8, 0.55).setFill()
    rounded(548, 470, 74, 84, 18).fill()
    color(0x9FB4D8, 0.32).setFill()
    rounded(644, 470, 46, 84, 16).fill()

    // 底部三枚分区指示点：可见 / 隐藏 / 始终隐藏。
    let dots: [(CGFloat, UInt32, CGFloat)] = [
        (404, 0x6FA0F0, 1), (512, 0x9FC2FF, 1), (620, 0x9FB4D8, 0.45),
    ]
    for (x, hex, alpha) in dots {
        let dot = NSBezierPath(ovalIn: NSRect(x: x - 17, y: 318, width: 34, height: 34))
        color(hex, alpha).setFill()
        dot.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRenderer", code: 2)
    }
    return png
}

let mainIcon = output.appendingPathComponent("AppIcon_1024.png")
try drawIcon(size: 1024).write(to: mainIcon)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    try drawIcon(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try drawIcon(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", output.appendingPathComponent("AppIcon.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw NSError(domain: "IconRenderer", code: Int(process.terminationStatus))
}
print("已生成 \(mainIcon.path) 与 AppIcon.icns")
