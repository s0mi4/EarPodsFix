// Рисует иконку приложения 1024×1024 в PNG: скруглённый квадрат с градиентом и белыми EarPods.
// Запуск: swift make_icon.swift out.png

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Сетка иконок macOS: тело 824×824 с отступом 100, радиус ~185
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// тень
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

// градиент
NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.55, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.93, alpha: 1),
])!.draw(in: path, angle: -60)

// лёгкий блик сверху
NSGraphicsContext.saveGraphicsState()
path.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// белые EarPods
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "earpods", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = sym.size
    let r = NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 10, width: s.width, height: s.height)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
    sh.shadowBlurRadius = 18
    sh.shadowOffset = NSSize(width: 0, height: -6)
    sh.set()
    sym.draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("icon → \(out)")
