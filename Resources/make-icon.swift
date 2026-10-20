//
// make-icon.swift — draws the Hark app icon and writes it as a 1024×1024 PNG.
//
// Usage: swift Resources/make-icon.swift <output.png>
// make-icon.sh turns that PNG into Resources/AppIcon.icns. Only needed when the icon
// design changes; the .icns is kept in the repo and copied by build.sh.
// Design: dark rounded square, a white sound waveform, and a red "recording" dot.
//

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift make-icon.swift <output.png>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("Could not create the drawing canvas\n".utf8))
    exit(1)
}
NSGraphicsContext.current = context

// why: macOS icons sit inside a ~824 pt rounded square with transparent margins.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1),
           ending: NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))!.draw(in: tilePath, angle: -90)
NSColor.white.withAlphaComponent(0.08).setStroke()
tilePath.lineWidth = 4
tilePath.stroke()

// Waveform bars, centered a little left to leave room for the dot.
let heights: [CGFloat] = [120, 230, 360, 470, 330, 210, 300, 160]
let barWidth: CGFloat = 44, gap: CGFloat = 30
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = tile.midX - totalWidth / 2 - 30
NSColor.white.withAlphaComponent(0.92).setFill()
for height in heights {
    let bar = NSRect(x: x, y: tile.midY - height / 2, width: barWidth, height: height)
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

// Red recording dot, top right.
let dot = NSRect(x: tile.maxX - 250, y: tile.maxY - 250, width: 140, height: 140)
NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1).setFill()
NSBezierPath(ovalIn: dot).fill()

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode PNG\n".utf8))
    exit(1)
}
do {
    try png.write(to: output)
} catch {
    FileHandle.standardError.write(Data("Could not write \(output.path): \(error.localizedDescription)\n".utf8))
    exit(1)
}
