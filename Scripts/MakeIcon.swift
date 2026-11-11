import AppKit
import Foundation
let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
func icon(_ pixels: Int) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let outer = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196)
    NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.86, alpha: 1).setFill(); outer.fill()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.20); shadow.shadowBlurRadius = 25; shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor(calibratedRed: 0.99, green: 0.98, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 257, y: 166, width: 510, height: 692), xRadius: 26, yRadius: 26).fill()
    NSGraphicsContext.restoreGraphicsState()
    let colors = [NSColor(calibratedRed: 0.20, green: 0.35, blue: 0.34, alpha: 1), NSColor(calibratedRed: 0.76, green: 0.38, blue: 0.25, alpha: 1), NSColor(calibratedRed: 0.29, green: 0.46, blue: 0.53, alpha: 1)]
    for i in 0..<3 {
        let rect = NSRect(x: 291, y: 202 + i * 210, width: 442, height: 192)
        colors[i].setFill(); NSBezierPath(rect: rect).fill()
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
        NSColor.white.withAlphaComponent(0.12).setFill()
        let mountain = NSBezierPath(); mountain.move(to: NSPoint(x: 260, y: rect.minY)); mountain.line(to: NSPoint(x: 515, y: rect.maxY + 35)); mountain.line(to: NSPoint(x: 790, y: rect.minY)); mountain.close(); mountain.fill()
        if i == 2 { NSColor(calibratedRed: 0.98, green: 0.83, blue: 0.54, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 620, y: 734, width: 60, height: 60)).fill() }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try icon(size).write(to: target.appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size * 2).write(to: target.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
