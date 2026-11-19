// Оформляет снимок панели для README: непрозрачная подложка панели со скруглёнными углами и тенью
// на градиентном фоне (как у иконки). Без прозрачности — хорошо смотрится в светлой и тёмной теме GitHub.
// Запуск: swift frame_screenshot.swift вход.png выход.png

import AppKit

let args = CommandLine.arguments
guard args.count > 2, let img = NSImage(contentsOfFile: args[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("вход.png выход.png") }

let pw = CGFloat(cg.width), ph = CGFloat(cg.height)     // снимок в пикселях (2x)
let pad: CGFloat = 80                                   // поле вокруг панели
let W = pw + pad * 2, H = ph + pad * 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// фон — фирменный градиент
NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.55, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.93, alpha: 1),
])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)

// подложка панели с тенью (как всплывающее окно macOS)
let panel = CGRect(x: pad, y: pad, width: pw, height: ph)
let shape = CGPath(roundedRect: panel, cornerWidth: 36, cornerHeight: 36, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// сам снимок поверх подложки, обрезанный по её форме
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.draw(cg, in: panel)
ctx.restoreGState()

// тонкая светлая обводка
ctx.addPath(shape)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
ctx.setLineWidth(2)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("→ \(args[2])")
