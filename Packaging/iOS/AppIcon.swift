// Draws the Orihon app icon (Assets.xcassets/AppIcon.appiconset/icon-1024.png): an accordion-folded book (折本) whose middle valley fold is the spine of a spread,
// with a bookmark ribbon. Usage: swift Packaging/iOS/AppIcon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments[1]

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Top-left origin.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// Background: deep indigo, lighter at the top.
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x2A3570), rgb(0x121838)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: 1024), options: [])

// Folds: x, top, bottom. Outer edges sit mid-depth, the two peaks come forward, the middle valley (the spine) recedes.
struct Fold { let x: CGFloat; let top: CGFloat; let bottom: CGFloat }
let folds = [
    Fold(x: 176, top: 318, bottom: 742),
    Fold(x: 344, top: 262, bottom: 800),
    Fold(x: 512, top: 336, bottom: 728),
    Fold(x: 680, top: 262, bottom: 800),
    Fold(x: 848, top: 318, bottom: 742),
]

// Soft shadow under the book.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 60, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
ctx.setFillColor(rgb(0x0B0F26))
ctx.fillEllipse(in: CGRect(x: 200, y: 770, width: 624, height: 70))
ctx.restoreGState()

func panel(_ a: Fold, _ b: Fold) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: a.x, y: a.top))
    p.addLine(to: CGPoint(x: b.x, y: b.top))
    p.addLine(to: CGPoint(x: b.x, y: b.bottom))
    p.addLine(to: CGPoint(x: a.x, y: a.bottom))
    p.closeSubpath()
    return p
}

// Light from the upper left: panels facing left are lit, those facing right in shade.
let shades: [(UInt32, UInt32)] = [(0xCDBB98, 0xB9A47F), (0xFBF4E6, 0xEFE3CC), (0xE9DCC3, 0xD9C9AB), (0xC7B48F, 0xB29C76)]
for i in 0..<4 {
    let path = panel(folds[i], folds[i + 1])
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [rgb(shades[i].0), rgb(shades[i].1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: folds[i].x, y: 300), end: CGPoint(x: folds[i + 1].x, y: 760), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// Manga panel lines on the spread (the two middle pages), following each page's perspective.
func point(on a: Fold, _ b: Fold, u: CGFloat, v: CGFloat) -> CGPoint {
    let x = a.x + (b.x - a.x) * u
    let top = a.top + (b.top - a.top) * u
    let bottom = a.bottom + (b.bottom - a.bottom) * u
    return CGPoint(x: x, y: top + (bottom - top) * v)
}
ctx.setStrokeColor(rgb(0xCBB993))
ctx.setLineWidth(7)
ctx.setLineCap(.round)
for (a, b, split) in [(folds[1], folds[2], CGFloat(0.42)), (folds[2], folds[3], CGFloat(0.58))] {
    let m: CGFloat = 0.13
    ctx.move(to: point(on: a, b, u: m, v: split)); ctx.addLine(to: point(on: a, b, u: 1 - m, v: split))
    let mid: CGFloat = split < 0.5 ? 0.55 : 0.45
    let (from, to): (CGFloat, CGFloat) = split < 0.5 ? (split + 0.04, 0.9) : (0.1, split - 0.04)
    ctx.move(to: point(on: a, b, u: mid, v: from)); ctx.addLine(to: point(on: a, b, u: mid, v: to))
    ctx.strokePath()
}

// Fold creases.
ctx.setLineWidth(4)
for (i, f) in folds.enumerated() where i > 0 && i < 4 {
    ctx.setStrokeColor(i == 2 ? rgb(0x9C8763) : rgb(0xFFF9EE))
    ctx.move(to: CGPoint(x: f.x, y: f.top)); ctx.addLine(to: CGPoint(x: f.x, y: f.bottom))
    ctx.strokePath()
}

// Bookmark ribbon hanging from the spine, past the bottom edge, with a swallowtail.
let ribbon = CGMutablePath()
let rw: CGFloat = 22
ribbon.move(to: CGPoint(x: 512 - rw, y: 336))
ribbon.addLine(to: CGPoint(x: 512 + rw, y: 336))
ribbon.addLine(to: CGPoint(x: 512 + rw, y: 860))
ribbon.addLine(to: CGPoint(x: 512, y: 832))
ribbon.addLine(to: CGPoint(x: 512 - rw, y: 860))
ribbon.closeSubpath()
ctx.addPath(ribbon)
ctx.setFillColor(rgb(0xE0482E))
ctx.fillPath()
ctx.setFillColor(rgb(0xB5321D))
ctx.fill(CGRect(x: 512 + rw - 8, y: 336, width: 8, height: 506))

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
