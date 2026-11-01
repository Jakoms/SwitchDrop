import Cocoa
let target = CommandLine.arguments[1]
let fm = FileManager.default
try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210).fill()
        NSColor(calibratedRed: 0.35, green: 0.94, blue: 0.72, alpha: 1).setStroke()
        let outline = NSBezierPath(roundedRect: NSRect(x: 210, y: 220, width: 604, height: 350), xRadius: 85, yRadius: 85)
        outline.lineWidth = 36; outline.stroke()
        let divider = NSBezierPath(); divider.move(to: NSPoint(x: 320,y: 230)); divider.line(to: NSPoint(x: 320,y: 560)); divider.move(to: NSPoint(x: 704,y: 230)); divider.line(to: NSPoint(x: 704,y: 560)); divider.lineWidth=24; divider.stroke()
        let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 512,y: 790)); arrow.line(to: NSPoint(x: 512,y: 420)); arrow.move(to: NSPoint(x: 410,y: 525)); arrow.line(to: NSPoint(x: 512,y: 420)); arrow.line(to: NSPoint(x: 614,y: 525)); arrow.lineWidth=52; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: target).appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
