#!/usr/bin/env swift
// Draws ReadyForPickup's app icon with CoreGraphics and writes every size
// the asset catalog needs, plus the project site's logo and favicon:
//   ReadyForPickup/Assets.xcassets/AppIcon.appiconset/icon_*.png + Contents.json
//   docs/logo.png (512 px)
//   docs/favicon.png (64 px, the tile alone, so it fills a browser tab's icon)
//
// The icon is a white paper shopping bag with grey rope handles and a green
// check on its front, on a blue macOS icon tile. It is drawn from scratch:
// Apple's logo (and anything close to it) and SF Symbols may not be used in
// app icons. Below 64 px the rope braid and paper folds are left out, since
// they only blur at that size.
//
// Usage (macOS, from anywhere): swift Scripts/make-app-icon.swift

import AppKit
import CoreGraphics

/// Design canvas: Apple's 1024 px macOS icon template (tile in the middle 824 px).
let canvas: CGFloat = 1024
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = repoRoot.appendingPathComponent("ReadyForPickup/Assets.xcassets/AppIcon.appiconset")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// The macOS icon shape: a superellipse.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...1440 {
        let t = CGFloat(i) / 1440 * 2 * .pi, c = cos(t), s = sin(t)
        let point = CGPoint(x: rect.midX + a * copysign(pow(abs(c), 2 / n), c),
                            y: rect.midY + b * copysign(pow(abs(s), 2 / n), s))
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

/// Fills `path` with a vertical gradient from y0 to y1.
func fillGradient(_ ctx: CGContext, _ path: CGPath, _ from: CGColor, _ to: CGColor, y0: CGFloat, y1: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from, to] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    ctx.restoreGState()
}

/// The blue tile, with the template's soft drop shadow and a faint top highlight.
func drawTile(_ ctx: CGContext) {
    let body = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.30))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x1E4FD6))
    ctx.fillPath()
    ctx.restoreGState()
    fillGradient(ctx, body, rgb(0x4C8DFF), rgb(0x1E4FD6), y0: 100, y1: 924)
    fillGradient(ctx, body, rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0), y0: 100, y1: 520)
}

/// A grey rope: dark edge, lighter core and, when `fine`, a low-contrast braid.
/// `inShadow` darkens it for the handle behind the bag's front.
func drawRope(_ ctx: CGContext, _ path: CGPath, width w: CGFloat, inShadow: Bool, fine: Bool) {
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(inShadow ? 0x6C7178 : 0x7F848B))
    ctx.setLineWidth(w)
    ctx.strokePath()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(inShadow ? 0x959AA1 : 0xACB0B6))
    ctx.setLineWidth(w * 0.68)
    ctx.strokePath()
    if fine {
        ctx.setLineDash(phase: 0, lengths: [w * 0.14, w * 0.30])
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(inShadow ? 0xA7ACB2 : 0xC0C4C9))
        ctx.setLineWidth(w * 0.26)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

/// The bag in three-quarter view: white front, shaded side gusset with its
/// centre fold, the open top, the rope handle behind (from the back panel)
/// and the one in front (through two eyelets).
func drawBag(_ ctx: CGContext, x0: CGFloat, x1: CGFloat, top: CGFloat, bottom: CGFloat, fine: Bool) {
    let depth = CGPoint(x: 96, y: -36)
    func back(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + depth.x, y: p.y + depth.y) }
    let frontTopLeft = CGPoint(x: x0, y: top), frontTopRight = CGPoint(x: x1, y: top)
    let frontBottomRight = CGPoint(x: x1, y: bottom), frontBottomLeft = CGPoint(x: x0, y: bottom)
    let ropeWidth: CGFloat = fine ? 26 : 34

    // Inside of the bag, seen through the open top.
    let opening = polygon([frontTopLeft, frontTopRight, back(frontTopRight), back(frontTopLeft)])
    fillGradient(ctx, opening, rgb(0xC9CDD3), rgb(0xE2E5E9), y0: top + depth.y, y1: top)

    // The handle behind, rising from the back panel.
    let backLeft = CGPoint(x: back(frontTopLeft).x + 78, y: back(frontTopLeft).y + 16)
    let backRight = CGPoint(x: back(frontTopRight).x - 78, y: back(frontTopRight).y + 16)
    let backHandle = CGMutablePath()
    backHandle.move(to: backLeft)
    backHandle.addCurve(to: backRight, control1: CGPoint(x: backLeft.x - 26, y: top - 262),
                        control2: CGPoint(x: backRight.x + 26, y: top - 262))
    drawRope(ctx, backHandle, width: ropeWidth, inShadow: true, fine: fine)

    // Front and side, with a soft shadow on the tile.
    let front = polygon([frontTopLeft, frontTopRight, frontBottomRight, frontBottomLeft])
    let side = polygon([frontTopRight, back(frontTopRight), back(frontBottomRight), frontBottomRight])
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: rgb(0x000000, 0.30))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(front)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.addPath(side)
    ctx.setFillColor(rgb(0xDDE0E4))
    ctx.fillPath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    fillGradient(ctx, front, rgb(0xFFFFFF), rgb(0xEEF0F3), y0: top, y1: bottom)
    ctx.saveGState()
    ctx.addPath(side)
    ctx.clip()
    let sideGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [rgb(0xE8EAED), rgb(0xCDD1D6)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sideGradient, start: CGPoint(x: x1, y: 0), end: CGPoint(x: x1 + depth.x, y: 0), options: [])
    ctx.restoreGState()

    if fine {
        // The gusset's centre fold, and the folded band at the top of the front.
        let fold = CGMutablePath()
        fold.move(to: CGPoint(x: x1 + depth.x / 2, y: top + depth.y / 2))
        fold.addLine(to: CGPoint(x: x1 + depth.x / 2, y: bottom + depth.y / 2 - 30))
        fold.addLine(to: CGPoint(x: x1 + 6, y: bottom - 4))
        ctx.addPath(fold)
        ctx.setStrokeColor(rgb(0xBEC3C9))
        ctx.setLineWidth(3)
        ctx.strokePath()
        let band = CGMutablePath()
        band.move(to: CGPoint(x: x0, y: top + 40))
        band.addLine(to: CGPoint(x: x1, y: top + 40))
        ctx.addPath(band)
        ctx.setStrokeColor(rgb(0xE3E6EA))
        ctx.setLineWidth(3)
        ctx.strokePath()
    }
    let edge = CGMutablePath()
    edge.addLines(between: [frontTopLeft, frontTopRight, back(frontTopRight)])
    ctx.addPath(edge)
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // The front handle, through two eyelets near the top edge.
    let left = CGPoint(x: x0 + 74, y: top + 26), right = CGPoint(x: x1 - 74, y: top + 26)
    for eyelet in [left, right] {
        ctx.addEllipse(in: CGRect(x: eyelet.x - 11, y: eyelet.y - 11, width: 22, height: 22))
        ctx.setFillColor(rgb(0xA9AEB4))
        ctx.fillPath()
    }
    let frontHandle = CGMutablePath()
    frontHandle.move(to: left)
    frontHandle.addCurve(to: right, control1: CGPoint(x: left.x - 26, y: top - 248),
                         control2: CGPoint(x: right.x + 26, y: top - 248))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: rgb(0x000000, 0.18))
    drawRope(ctx, frontHandle, width: ropeWidth, inShadow: false, fine: fine)
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext, fine: Bool) {
    drawTile(ctx)
    let x0: CGFloat = 330, x1: CGFloat = 626, top: CGFloat = 412, bottom: CGFloat = 852
    drawBag(ctx, x0: x0, x1: x1, top: top, bottom: bottom, fine: fine)
    // The green check, where a store bag carries its logo.
    let c = CGPoint(x: (x0 + x1) / 2, y: top + (bottom - top) * 0.56)
    let check = CGMutablePath()
    check.addLines(between: [CGPoint(x: c.x - 74, y: c.y + 2), CGPoint(x: c.x - 22, y: c.y + 54), CGPoint(x: c.x + 78, y: c.y - 58)])
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: rgb(0x0B6B2E, 0.25))
    ctx.addPath(check)
    ctx.setStrokeColor(rgb(0x22B455))
    ctx.setLineWidth(fine ? 44 : 60)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

/// Renders the icon at `pixels` x `pixels` (top-left origin, like the design).
func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(pixels) / canvas
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawIcon(ctx, fine: pixels >= 64)
    return ctx.makeImage()!
}

/// Renders just the tile (the design's middle 824 px), filling the image.
func renderTile(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(pixels) / 824
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: -100, y: -100)
    drawIcon(ctx, fine: pixels >= 64)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

// The asset catalog's macOS sizes: points x scale.
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try writePNG(render(pixels: points * scale), to: iconSet.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))
try writePNG(render(pixels: 512), to: repoRoot.appendingPathComponent("docs/logo.png"))
try writePNG(renderTile(pixels: 64), to: repoRoot.appendingPathComponent("docs/favicon.png"))
print("Wrote \(sizes.count) icon sizes to \(iconSet.path), docs/logo.png and docs/favicon.png")
