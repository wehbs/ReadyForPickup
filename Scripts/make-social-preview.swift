#!/usr/bin/env swift
// Draws the project site's link-preview image (the picture X, Slack and others
// show for a link to the site) from the site logo and the app screenshot:
//   docs/logo.png + docs/screenshot.png -> docs/social-preview.png (1200 x 630)
//
// docs/logo.png comes from Scripts/make-app-icon.swift. docs/screenshot.png is
// a 2x capture of the main window with a shadow around it (80 px at the sides,
// 56 above, 104 below). Rerun this after changing either one; a new screenshot
// may also need new shadow sizes and resultsColumnEnd below.
//
// X lays the site's domain over the image's bottom-left corner, so no text
// goes there.
//
// Usage (macOS, from anywhere): swift Scripts/make-social-preview.swift

import AppKit
import CoreGraphics

let imageWidth = 1200, imageHeight = 630
let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func load(_ name: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(docs.appendingPathComponent(name) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: "docs/\(name)"])
    }
    return image
}

struct TextBlock {
    let string: NSAttributedString
    let width: CGFloat
    let spaceAbove: CGFloat

    init(_ text: String, width: CGFloat, font: NSFont, color: CGColor, lineHeight: CGFloat, spaceAbove: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: color)!, .paragraphStyle: paragraph,
        ])
        self.width = width
        self.spaceAbove = spaceAbove
    }

    var height: CGFloat {
        string.boundingRect(with: CGSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).height
    }

    /// Draws the block with its top `top` points below the image's top edge.
    func draw(x: CGFloat, top: CGFloat) {
        string.draw(with: CGRect(x: x, y: CGFloat(imageHeight) - top - height, width: width, height: height),
                    options: [.usesLineFragmentOrigin])
    }
}

let logo = try load("logo.png")
let screenshot = try load("screenshot.png")

let ctx = CGContext(data: nil, width: imageWidth, height: imageHeight, bitsPerComponent: 8, bytesPerRow: 0,
                    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let width = CGFloat(imageWidth), height = CGFloat(imageHeight)

// Background: a pale blue-grey wash, lighter at the top left.
let background = CGGradient(colorsSpace: sRGB, colors: [rgb(0xFAFBFE), rgb(0xDCE5F4)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])

// The app window, bleeding off the bottom edge and cut at the right edge where
// its results column ends. The screenshot is 2x and has the window's shadow
// around it: 80 px at the sides, 56 above and 104 below the window.
let scale: CGFloat = 0.54
let resultsColumnEnd: CGFloat = 1218        // px from the window's left edge, in the 2x capture
let windowLeft = width - resultsColumnEnd * scale, windowTop: CGFloat = 86
let windowHeight = CGFloat(screenshot.height - 56 - 104) * scale
ctx.draw(screenshot, in: CGRect(x: windowLeft - 80 * scale, y: height - windowTop - windowHeight - 104 * scale,
                                width: CGFloat(screenshot.width) * scale, height: CGFloat(screenshot.height) * scale))

// The icon (the logo's tile fills its middle 824/1024), then the name and what
// it does, centred top to bottom.
let left: CGFloat = 64, iconSize: CGFloat = 150
let tileInset = iconSize * 100 / 1024, tileSize = iconSize - 2 * tileInset
let blocks = [
    TextBlock("ReadyForPickup", width: 470, font: .systemFont(ofSize: 58, weight: .bold),
              color: rgb(0x111827), lineHeight: 66, spaceAbove: 28),
    TextBlock("Get an alert when the iPhone or Mac you want is ready for pickup at an Apple Store near you.",
              width: windowLeft - left - 40, font: .systemFont(ofSize: 28, weight: .regular),
              color: rgb(0x374151), lineHeight: 37, spaceAbove: 14),
    TextBlock("Free and open source, for macOS", width: 470, font: .systemFont(ofSize: 22, weight: .semibold),
              color: rgb(0x2563EB), lineHeight: 29, spaceAbove: 18),
]
var top = (height - (tileSize + blocks.reduce(0) { $0 + $1.spaceAbove + $1.height })) / 2
ctx.draw(logo, in: CGRect(x: left - tileInset, y: height - (top - tileInset) - iconSize, width: iconSize, height: iconSize))
top += tileSize
for block in blocks {
    top += block.spaceAbove
    block.draw(x: left, top: top)
    top += block.height
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: imageWidth, height: imageHeight)
guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
try data.write(to: docs.appendingPathComponent("social-preview.png"))
print("Wrote docs/social-preview.png (\(imageWidth) x \(imageHeight))")
