// Renders one line of text as a white-on-transparent PNG using the system fonts (CoreText).
// Used by build.py so the logotype is real SF Pro Rounded Heavy rather than a Blender approximation.
//
//   swift text.swift <out.png> <text> <pointSize> <weight: regular|medium|semibold|bold|heavy|black>
//                    <design: default|rounded|mono> <tracking (fraction of size, e.g. -0.01)>
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 7 else {
    FileHandle.standardError.write("usage: text.swift out text size weight design tracking\n".data(using: .utf8)!)
    exit(2)
}
let out = a[1], text = a[2]
let size = CGFloat(Double(a[3]) ?? 100)
let weights: [String: NSFont.Weight] = ["regular": .regular, "medium": .medium, "semibold": .semibold,
                                        "bold": .bold, "heavy": .heavy, "black": .black]
let weight = weights[a[4]] ?? .regular
let designs: [String: NSFontDescriptor.SystemDesign] = ["default": .default, "rounded": .rounded, "mono": .monospaced]
let tracking = CGFloat(Double(a[6]) ?? 0)

var font = NSFont.systemFont(ofSize: size, weight: weight)
if let d = font.fontDescriptor.withDesign(designs[a[5]] ?? .default), let f = NSFont(descriptor: d, size: size) {
    font = f
}
let attr = NSAttributedString(string: text, attributes: [
    .font: font,
    .kern: tracking * size,
    .foregroundColor: NSColor.white,
])
let line = CTLineCreateWithAttributedString(attr)
var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
let pad = ceil(size * 0.25)
let W = Int(ceil(width + 2 * pad)), H = Int(ceil(ascent + descent + 2 * pad))
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.setAllowsAntialiasing(true)
ctx.setShouldSmoothFonts(false)
ctx.textPosition = CGPoint(x: pad, y: pad + descent)
CTLineDraw(line, ctx)
let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
// baseline position from the top of the image, in pixels, for aligning lines of text
print("baseline \(Double(CGFloat(H) - pad - descent)) capheight \(Double(font.capHeight)) xheight \(Double(font.xHeight))")
