#!/usr/bin/env swift
// Renders the DiskScope app-icon master PNG (1024×1024): a cushioned-treemap motif on a dark
// squircle, colored with the app's real OKLCH file-category palette. Standalone (no engine
// import) so it runs as a plain script. Usage: swift Scripts/render-icon.swift [out.png]
import AppKit

let size = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging/icon-1024.png"

// MARK: - OKLCH → sRGB (Björn Ottosson's OKLab), mirrored from FilePalette so the icon's
// colors are identical to the treemap's. Chroma is nudged up a touch — icons read better
// slightly more saturated at small sizes.
func oklch(_ L: Double, _ C: Double, _ H: Double, chromaBoost: Double = 1.35, lift: Double = 0.03) -> NSColor {
    let Lc = min(1, L + lift), Cc = C * chromaBoost
    let hr = H * .pi / 180
    let a = Cc * cos(hr), b = Cc * sin(hr)
    let l_ = Lc + 0.3963377774 * a + 0.2158037573 * b
    let m_ = Lc - 0.1055613458 * a - 0.0638541728 * b
    let s_ = Lc - 0.0894841775 * a - 1.2914855480 * b
    let l = l_*l_*l_, m = m_*m_*m_, s = s_*s_*s_
    func g(_ x: Double) -> CGFloat {
        let v = max(0, min(1, x))
        return CGFloat(v <= 0.0031308 ? 12.92*v : 1.055*pow(v, 1/2.4) - 0.055)
    }
    let r =  4.0767416621*l - 3.3077115913*m + 0.2309699292*s
    let gg = -1.2684380046*l + 2.6097574011*m - 0.3413193965*s
    let bb = -0.0041960863*l - 0.7034186147*m + 1.7076147010*s
    return NSColor(srgbRed: g(r), green: g(gg), blue: g(bb), alpha: 1)
}

// Category bases (L, C, H) — code/image/web/video/audio/archive — same numbers as FilePalette.
let code    = oklch(0.66, 0.085, 256)
let image   = oklch(0.66, 0.095, 350)
let web     = oklch(0.70, 0.075, 195)
let video   = oklch(0.63, 0.105,  32)
let audio   = oklch(0.70, 0.085, 145)
let archive = oklch(0.74, 0.090,  95)

// MARK: - Canvas
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fputs("failed to create bitmap rep\n", stderr); exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let S = CGFloat(size)
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// Squircle body (Apple-ish icon grid: ~100px margin, generous corner radius), used as a clip.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let bodyRadius: CGFloat = 185
let squircle = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()

// Dark background gradient (#0b0d10 → #14181f), the app canvas color deepened.
let cs = CGColorSpaceCreateDeviceRGB()
let bg = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 0.043, green: 0.051, blue: 0.063, alpha: 1).cgColor,
    NSColor(srgbRed: 0.078, green: 0.094, blue: 0.122, alpha: 1).cgColor
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY),
                       end: CGPoint(x: body.maxX, y: body.minY), options: [])

// MARK: - Treemap tiles. Fractions of the body rect (origin bottom-left), gap-inset, with a
// per-tile "cushion" (diagonal light→dark sheen) and rounded corners.
let tiles: [(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, color: NSColor)] = [
    (0.00, 0.42, 0.58, 1.00, code),     // big, top-left
    (0.60, 0.62, 1.00, 1.00, image),    // top-right
    (0.60, 0.42, 1.00, 0.60, web),      // mid-right
    (0.00, 0.00, 0.30, 0.40, video),    // bottom-left
    (0.32, 0.00, 0.64, 0.40, audio),    // bottom-mid
    (0.66, 0.00, 1.00, 0.40, archive),  // bottom-right
]
let gap = body.width * 0.018
func denorm(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
    CGPoint(x: body.minX + fx * body.width, y: body.minY + fy * body.height)
}

for t in tiles {
    let p0 = denorm(t.x0, t.y0), p1 = denorm(t.x1, t.y1)
    let r = CGRect(x: p0.x + gap, y: p0.y + gap,
                   width: p1.x - p0.x - 2*gap, height: p1.y - p0.y - 2*gap)
    let radius = min(r.width, r.height) * 0.16
    let tilePath = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Base fill.
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    ctx.setFillColor(t.color.cgColor)
    ctx.fill(r)

    // Cushion sheen: white highlight at top-left fading out, then a soft dark at bottom-right.
    let sheen = CGGradient(colorsSpace: cs, colors: [
        NSColor(white: 1, alpha: 0.26).cgColor,
        NSColor(white: 1, alpha: 0.0).cgColor,
        NSColor(white: 0, alpha: 0.18).cgColor
    ] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: r.minX, y: r.maxY),
                           end: CGPoint(x: r.maxX, y: r.minY), options: [])
    ctx.restoreGState()

    // Hairline edge to separate adjacent tiles crisply.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(NSColor(white: 0, alpha: 0.22).cgColor)
    ctx.setLineWidth(2)
    ctx.strokePath()
}

ctx.restoreGState() // drop squircle clip

// Subtle inner rim on the squircle for definition on light wallpapers.
ctx.addPath(squircle)
ctx.setStrokeColor(NSColor(white: 1, alpha: 0.06).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode PNG\n", stderr); exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath) (\(size)×\(size))")
} catch {
    fputs("write failed: \(error)\n", stderr); exit(1)
}
