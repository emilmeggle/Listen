// Renders the LLMListen app icon at all required sizes and emits AppIcon.iconset/.
// Run: swift gen_icon.swift && iconutil -c icns AppIcon.iconset
import AppKit

func drawIcon(into ctx: CGContext, pixels: CGFloat) {
    let s = pixels / 1024.0
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    // Squircle plate (Apple icon grid: 824×824 centered, ~185 corner radius)
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Plate drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.13, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Dark vertical gradient on the plate
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let bgColors = [CGColor(red: 0.16, green: 0.16, blue: 0.21, alpha: 1),
                    CGColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1)] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    let bgGrad = CGGradient(colorsSpace: space, colors: bgColors, locations: [0, 1])!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100), options: [])

    // Subtle top highlight
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.05))
    ctx.fill(CGRect(x: 100, y: 700, width: 824, height: 224))
    ctx.restoreGState()

    // Red record circle
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 235
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 60,
                  color: CGColor(red: 0.95, green: 0.20, blue: 0.18, alpha: 0.55))
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2))
    ctx.clip()
    let redColors = [CGColor(red: 1.00, green: 0.40, blue: 0.36, alpha: 1),
                     CGColor(red: 0.78, green: 0.12, blue: 0.10, alpha: 1)] as CFArray
    let redGrad = CGGradient(colorsSpace: space, colors: redColors, locations: [0, 1])!
    ctx.drawLinearGradient(redGrad, start: CGPoint(x: 512, y: 512 + radius),
                           end: CGPoint(x: 512, y: 512 - radius), options: [])
    ctx.restoreGState()

    // Thin ring around the circle
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2))

    // White waveform bars inside the circle
    let heights: [CGFloat] = [110, 200, 300, 180, 120]
    let barWidth: CGFloat = 42
    let gap: CGFloat = 30
    let totalW = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = center.x - totalW / 2
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    for h in heights {
        let bar = CGRect(x: x, y: center.y - h / 2, width: barWidth, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2,
                           cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
        x += barWidth + gap
    }

    ctx.restoreGState()
}

func renderPNG(pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    drawIcon(into: gctx.cgContext, pixels: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    renderPNG(pixels: px, to: iconset.appendingPathComponent("\(name).png"))
}
print("AppIcon.iconset written")
