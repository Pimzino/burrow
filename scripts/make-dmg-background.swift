// Renders a placeholder DMG background in the Burrow brand colours (night-soil ground, lantern glow).
// Used by scripts/make-dmg.sh only when art/brand/out/dmg-background.png is missing.
//   swift scripts/make-dmg-background.swift <out.png> <out@2x.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: make-dmg-background.swift <out.png> <out@2x.png>\n".data(using: .utf8)!)
    exit(2)
}

// Window content size in points (must match scripts/make-dmg.sh). The composition sits in the top-left
// corner of a much larger canvas: Finder pins the picture there and paints white wherever it runs out,
// so the ground has to carry on for any size the window is dragged to.
let size = CGSize(width: 660, height: 420)
let canvas = CGSize(width: 3200, height: 2000)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(scale: CGFloat, to path: String) {
    let px = (w: Int(canvas.width * scale), h: Int(canvas.height * scale))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px.w, pixelsHigh: px.h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // burrow (#231B2B) round the composition, easing into flat night-soil (#15111B) for the rest of the canvas.
    ctx.setFillColor(color(0x15111B))
    ctx.fill(CGRect(origin: .zero, size: canvas))
    ctx.translateBy(x: 0, y: canvas.height - size.height)   // origin at the composition's bottom-left
    let ground = CGGradient(colorsSpace: space, colors: [color(0x231B2B), color(0x15111B)] as CFArray, locations: [0, 1])!
    let middle = CGPoint(x: size.width / 2, y: size.height / 2)
    ctx.drawRadialGradient(ground, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: 560, options: [])

    // Lantern (#FFB23F) glow between the two icons.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFB23F, 0.28), color(0xF2703A, 0.08), color(0xF2703A, 0)] as CFArray,
                          locations: [0, 0.5, 1])!
    let centre = CGPoint(x: size.width / 2, y: size.height - 210)
    ctx.drawRadialGradient(glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 260, options: [])

    // Simple arrow from the app (x 170) towards Applications (x 490).
    ctx.setStrokeColor(color(0xFFF4E2, 0.55))
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let y = size.height - 210
    ctx.move(to: CGPoint(x: 270, y: y)); ctx.addLine(to: CGPoint(x: 390, y: y))
    ctx.move(to: CGPoint(x: 376, y: y + 12)); ctx.addLine(to: CGPoint(x: 390, y: y)); ctx.addLine(to: CGPoint(x: 376, y: y - 12))
    ctx.strokePath()

    // Hint text.
    let text = NSAttributedString(string: "Drag Burrow to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: NSColor(cgColor: color(0xFFF4E2, 0.8))!,
    ])
    let bounds = text.size()
    text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: 52))

    NSGraphicsContext.restoreGraphicsState()
    rep.size = canvas   // 72 dpi at 1x, 144 dpi at 2x, so tiffutil pairs them correctly
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: args[1])
render(scale: 2, to: args[2])
