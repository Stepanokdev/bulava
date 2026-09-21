//
//  main.swift — the app icon, generated from the logo geometry.
//
//  Run it from the repo root:
//
//      bash tools/icongen/build.sh
//
//  It compiles `Night Shift/Design/BulavaGlyph.swift` alongside this file, so the icon in the Dock
//  and the mark in the sidebar are literally the same curves. Nothing here is hand-pixelled: every
//  size is drawn from the vector at that size rather than downsampled from a master, which is what
//  keeps the 16pt icon from turning into a smear.
//
//      bash tools/icongen/build.sh <icon-dir> <svg-path>
//
//  writes elsewhere, which is how the brand-mark test regenerates both without touching the repo.
//
//  The plate follows Apple's macOS geometry — an 824pt continuous-corner squircle inside a 1024pt
//  canvas — because an icon that ignores it looks oversized next to every other app in the Dock.
//  `RoundedRectangle(style: .continuous)` gives us the real Apple curve rather than an approximation.
//

import AppKit
import SwiftUI

// The brand: lime on deep green, the same pair the app's palette carries.
let lime = CGColor(srgbRed: 0xC7 / 255, green: 0xF1 / 255, blue: 0x83 / 255, alpha: 1)
let fieldCenter = CGColor(srgbRed: 0x1F / 255, green: 0x3A / 255, blue: 0x28 / 255, alpha: 1)
let fieldEdge = CGColor(srgbRed: 0x0C / 255, green: 0x18 / 255, blue: 0x11 / 255, alpha: 1)

/// Apple's continuous-corner squircle, at icon proportions: 824/1024 of the canvas, radius 185.4.
@MainActor func plate(side: CGFloat) -> CGPath {
    let inset = side * 100 / 1024
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    return RoundedRectangle(cornerRadius: side * 185.4 / 1024, style: .continuous)
        .path(in: rect).cgPath
}

@MainActor func icon(side: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    let plate = plate(side: side)
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()

    // The field: a radial lift behind the mark, dark at the corners. Flat dark green reads as a
    // black square at 32pt; the lift is what gives the plate a centre.
    let field = CGGradient(colorsSpace: cs, colors: [fieldCenter, fieldEdge] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(field,
                           startCenter: CGPoint(x: side * 0.5, y: side * 0.56), startRadius: 0,
                           endCenter: CGPoint(x: side * 0.5, y: side * 0.56), endRadius: side * 0.72,
                           options: [.drawsAfterEndLocation])

    // A lime bloom, so the mark sits in light rather than on top of a flat plate.
    let bloom = CGGradient(colorsSpace: cs,
                           colors: [lime.copy(alpha: 0.20)!, lime.copy(alpha: 0)!] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(bloom,
                           startCenter: CGPoint(x: side * 0.52, y: side * 0.5), startRadius: 0,
                           endCenter: CGPoint(x: side * 0.52, y: side * 0.5), endRadius: side * 0.46,
                           options: [])

    // The mark. CoreGraphics has y up and the glyph is described y down, so flip it.
    let markHeight = side * 0.56
    let box = CGRect(x: 0, y: (side - markHeight) / 2, width: side, height: markHeight)
    ctx.saveGState()
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)
    ctx.addPath(BulavaGlyph.cgPath(in: CGRect(x: box.minX, y: side - box.maxY,
                                              width: box.width, height: box.height)))
    ctx.setFillColor(lime)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.restoreGState()

    // A hairline rim: the plate needs an edge of its own on a dark Dock.
    ctx.addPath(plate)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07))
    ctx.setLineWidth(max(1, side / 512))
    ctx.strokePath()

    return ctx.makeImage()!
}

// MARK: - Write the set

let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Night Shift/Assets.xcassets/AppIcon.appiconset"

let wanted: [(String, CGFloat)] = [
    ("icon_16x16@1x", 16), ("icon_16x16@2x", 32),
    ("icon_32x32@1x", 32), ("icon_32x32@2x", 64),
    ("icon_128x128@1x", 128), ("icon_128x128@2x", 256),
    ("icon_256x256@1x", 256), ("icon_256x256@2x", 512),
    ("icon_512x512@1x", 512), ("icon_512x512@2x", 1024),
]

// The engine renders its reports in Python and cannot ask Swift for the geometry, so the mark is
// emitted here as an SVG asset it can read. Generated, committed, and checked by
// engine/tests/test-brand-mark.sh — which regenerates into a temp path and fails if the committed
// asset and the geometry have drifted apart.
let svgOut = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "engine/assets/brand-mark.svg"
if !svgOut.isEmpty {
    let svg = BulavaGlyph.svg(size: 100) + "\n"
    let path = svgOut
    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    do {
        try svg.write(toFile: path, atomically: true, encoding: .utf8)
        print("brand-mark.svg")
    } catch {
        FileHandle.standardError.write(Data("icongen: \(path): \(error)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    for (name, side) in wanted {
        let image = icon(side: side)
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: side, height: side)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("icongen: could not encode \(name)\n".utf8))
            exit(1)
        }
        let url = URL(fileURLWithPath: "\(out)/\(name).png")
        do {
            try data.write(to: url)
            print("\(name).png  \(Int(side))×\(Int(side))")
        } catch {
            FileHandle.standardError.write(Data("icongen: \(url.path): \(error)\n".utf8))
            exit(1)
        }
    }
}
