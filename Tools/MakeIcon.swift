import AppKit
import CoreGraphics

// Renders the EnglishAutocorrect mark: a bold "A" over a squiggle that
// resolves into a clean straight line -- the spell-check signal, read as
// "error corrected". Everything is expressed as a fraction of the canvas
// so a single routine serves the 16px menu-bar icon and the 1024px master.

let macOSRed   = (r: 1.00, g: 0.27, b: 0.23)   // system red, the squiggle
let gradTop    = (r: 0.42, g: 0.49, b: 0.99)   // indigo
let gradBottom = (r: 0.37, g: 0.19, b: 0.78)   // violet

/// Squircle body inset, matching Apple's macOS icon grid: an 824pt body
/// with a 185pt corner radius on a 1024pt canvas.
let bodyRatio   = 824.0 / 1024.0
let radiusRatio = 185.0 / 824.0

func makeContext(_ px: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: px, height: px,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return ctx
}

/// The rounded-rect body path, centered on the canvas.
func bodyPath(_ s: CGFloat) -> CGPath {
    let body = s * bodyRatio
    let o = (s - body) / 2
    let rect = CGRect(x: o, y: o, width: body, height: body)
    return CGPath(roundedRect: rect,
                  cornerWidth: body * radiusRatio,
                  cornerHeight: body * radiusRatio,
                  transform: nil)
}

/// The underline: a squiggle across the left portion that flattens into a
/// straight line on the right. `waves` drops at small sizes, where fine
/// oscillation turns to mush.
func underlinePath(_ s: CGFloat, waves: Int, amplitude: CGFloat, span: (CGFloat, CGFloat), y: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let startX = s * span.0
    let endX   = s * span.1
    let yy     = s * y
    p.move(to: CGPoint(x: startX, y: yy))

    // waves == 0 is the small-size artwork: below ~48px an oscillation of
    // any amplitude that still fits collapses into a blur, so the mark
    // keeps only the part that survives -- a red half and a clean half.
    guard waves > 0 else {
        p.addLine(to: CGPoint(x: endX, y: yy))
        return p
    }

    let squiggleEnd = startX + (endX - startX) * 0.52
    let segW = (squiggleEnd - startX) / CGFloat(waves)
    for i in 0..<waves {
        let x0 = startX + segW * CGFloat(i)
        let x1 = x0 + segW
        let dir: CGFloat = (i % 2 == 0) ? 1 : -1
        p.addQuadCurve(to: CGPoint(x: x1, y: yy),
                       control: CGPoint(x: (x0 + x1) / 2, y: yy + amplitude * dir))
    }
    p.addLine(to: CGPoint(x: endX, y: yy))
    return p
}

/// Strokes `path` with a horizontal red-to-white gradient, so the squiggle
/// reads as the error and the flat line as the correction.
func strokeGradient(_ ctx: CGContext, path: CGPath, width: CGFloat, s: CGFloat,
                    span: (CGFloat, CGFloat), sharp: Bool) {
    ctx.saveGState()
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round,
                            lineJoin: .round, miterLimit: 10)
    ctx.addPath(stroked)
    ctx.clip()

    let cs = CGColorSpaceCreateDeviceRGB()
    let red   = CGColor(red: macOSRed.r, green: macOSRed.g, blue: macOSRed.b, alpha: 1)
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let colors = [red, red, white, white] as CFArray
    // A tight crossover keeps the two halves distinct at 16px, where a
    // long blend would just read as one muddy pink bar.
    let stops: [CGFloat] = sharp ? [0.0, 0.46, 0.54, 1.0] : [0.0, 0.30, 0.62, 1.0]
    guard let g = CGGradient(colorsSpace: cs, colors: colors, locations: stops) else { return }
    ctx.drawLinearGradient(g,
                           start: CGPoint(x: s * span.0, y: 0),
                           end: CGPoint(x: s * span.1, y: 0),
                           options: [])
    ctx.restoreGState()
}

/// The letter A, as a glyph path so it renders identically at every size
/// without depending on text layout.
func letterPath(_ s: CGFloat, pointRatio: CGFloat, weight: NSFont.Weight, baselineY: CGFloat) -> CGPath? {
    let pointSize = s * pointRatio
    let desc = NSFont.systemFont(ofSize: pointSize, weight: weight)
        .fontDescriptor.withDesign(.rounded) ?? NSFont.systemFont(ofSize: pointSize, weight: weight).fontDescriptor
    let font = NSFont(descriptor: desc, size: pointSize)
        ?? NSFont.systemFont(ofSize: pointSize, weight: weight)

    let attr = NSAttributedString(string: "A", attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attr)
    guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return nil }

    var glyph = CGGlyph()
    var pos = CGPoint()
    CTRunGetGlyphs(run, CFRangeMake(0, 1), &glyph)
    CTRunGetPositions(run, CFRangeMake(0, 1), &pos)
    guard let gp = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }

    // Center the glyph's actual ink, then sit it above the underline.
    let b = gp.boundingBox
    var t = CGAffineTransform(translationX: (s - b.width) / 2 - b.minX,
                              y: s * baselineY - b.minY)
    return gp.copy(using: &t)
}

func renderIcon(px: Int, withBackground: Bool) -> CGImage {
    let ctx = makeContext(px)
    let s = CGFloat(px)

    if withBackground {
        ctx.saveGState()
        ctx.addPath(bodyPath(s))
        ctx.clip()
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(red: gradTop.r, green: gradTop.g, blue: gradTop.b, alpha: 1),
            CGColor(red: gradBottom.r, green: gradBottom.g, blue: gradBottom.b, alpha: 1),
        ] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s),
                                   end: CGPoint(x: s, y: 0), options: [])
        }
        ctx.restoreGState()
    }

    // Two sets of artwork rather than one scaled design: at menu-bar
    // sizes the mark needs a heavier letter, a larger fill of the body,
    // and an underline with no oscillation left in it.
    let small = px < 48
    let pointRatio: CGFloat = small ? 0.60 : 0.48
    let weight: NSFont.Weight = small ? .black : .bold
    let baselineY: CGFloat = small ? 0.395 : 0.400
    let span: (CGFloat, CGFloat) = small ? (0.200, 0.800) : (0.248, 0.752)
    let underY: CGFloat = small ? 0.268 : 0.292
    let waves = small ? 0 : 3
    let amp = s * 0.055
    let lw = s * (small ? 0.105 : 0.060)

    if let lp = letterPath(s, pointRatio: pointRatio, weight: weight, baselineY: baselineY) {
        ctx.saveGState()
        ctx.addPath(lp)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    strokeGradient(ctx,
                   path: underlinePath(s, waves: waves, amplitude: amp, span: span, y: underY),
                   width: lw, s: s, span: span, sharp: small)

    guard let img = ctx.makeImage() else { fatalError("render failed") }
    return img
}

func writePNG(_ img: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: img.width, height: img.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed")
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

// CLI: MakeIcon <outPath> <px> [--no-bg]
let args = CommandLine.arguments
guard args.count >= 3, let px = Int(args[2]) else {
    FileHandle.standardError.write("usage: MakeIcon <out.png> <px> [--no-bg]\n".data(using: .utf8)!)
    exit(1)
}
let withBG = !args.contains("--no-bg")
writePNG(renderIcon(px: px, withBackground: withBG), to: args[1])
print("wrote \(args[1]) at \(px)px")
