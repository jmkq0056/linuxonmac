// Renders AppIcon.icns. Run: swift scripts/make-icon.swift
// Drawing happens in a 1024pt space and is scaled per slice, so the small
// sizes stay geometrically identical to the large ones rather than being
// resampled down from a single bitmap.
import AppKit
import Foundation

let canvas: CGFloat = 1024

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func oval(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x - w / 2, y: y - h / 2, width: w, height: h))
}

func draw() {
    // macOS icons sit inset inside the canvas rather than bleeding to the edge.
    let plate = NSBezierPath(
        roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
        xRadius: 185,
        yRadius: 185
    )
    NSGradient(starting: color(0x131C2E), ending: color(0x33456B))!.draw(in: plate, angle: 90)

    plate.addClip()

    // Feet first — the body overlaps them, leaving only the toes showing.
    color(0xF2A03D).setFill()
    oval(x: 452, y: 215, w: 175, h: 70).fill()
    oval(x: 572, y: 215, w: 175, h: 70).fill()

    // Body and head as one egg, which reads better at 16pt than separate shapes.
    color(0x11161F).setFill()
    oval(x: 512, y: 520, w: 460, h: 600).fill()

    // Belly and face stay separated by a band of black — merged, they read as
    // one white blob instead of a penguin.
    color(0xFFFFFF).setFill()
    oval(x: 512, y: 415, w: 285, h: 340).fill()
    oval(x: 512, y: 705, w: 245, h: 185).fill()

    // Eyes
    color(0x11161F).setFill()
    oval(x: 466, y: 718, w: 50, h: 56).fill()
    oval(x: 558, y: 718, w: 50, h: 56).fill()

    // Beak
    color(0xF2A03D).setFill()
    oval(x: 512, y: 655, w: 110, h: 60).fill()
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(iconset.path)")
