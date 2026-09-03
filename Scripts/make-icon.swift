#!/usr/bin/env swift
//
// Scripts/make-icon.swift — draws the app icon and writes every size the catalogue asks
// for. Run it after changing the artwork:
//
//     swift Scripts/make-icon.swift
//
// The mark is a lightbulb mid-thought: a filled glass bulb with a screw base and three
// thought dots rising beside it, on the blue squircle the rest of the app is keyed to.

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let target = root
    .appendingPathComponent("App/DBStudio/Resources/Assets.xcassets/AppIcon.appiconset")

/// The appearance an image is drawn for.
///
/// macOS 26's adaptive icons — light, dark, tinted and clear — are authored as an
/// Icon Composer `.icon` document. An asset catalogue cannot express them: `actool`
/// rejects `appearances` entries under the `mac` idiom, so only `.any` is written today.
/// The other two are kept because the drawing already supports them, and they are what an
/// `.icon` document would be built from (DECISIONS.md ADR-0027).
enum Appearance: String, CaseIterable {
    case any, dark, tinted
}

/// Every (point size, scale) pair the catalogue asks for.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2),
    (512, 1), (512, 2),
]

func filename(points: Int, scale: Int) -> String {
    scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
}

/// Draws the icon into a bitmap of exactly `size` pixels.
///
/// The drawing goes into an explicitly sized `NSBitmapImageRep` rather than through
/// `NSImage.lockFocus`, which adopts the main display's backing scale and would silently
/// write every 1x image at twice its declared size.
func drawIcon(size: CGFloat, appearance: Appearance) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS icons sit in a rounded square inset from the canvas edge.
    let inset = size * 0.06
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * 0.2237      // the macOS squircle ratio
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    // A vertical blue gradient, lighter at the top.
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let plateColors: [CGColor] = switch appearance {
    case .any: [
        CGColor(red: 0.30, green: 0.56, blue: 0.98, alpha: 1),
        CGColor(red: 0.11, green: 0.31, blue: 0.78, alpha: 1),
    ]
    // Dark mode sits the same glass on a deeper ground so it does not glow on a dark dock.
    case .dark: [
        CGColor(red: 0.16, green: 0.31, blue: 0.60, alpha: 1),
        CGColor(red: 0.06, green: 0.15, blue: 0.36, alpha: 1),
    ]
    // The tinted appearance is monochrome; the system supplies the colour.
    case .tinted: [
        CGColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1),
        CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1),
    ]
    }
    let colors = plateColors as CFArray
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: []
        )
    }
    // A specular sweep across the top and a rim light, which is what makes the plate read
    // as glass rather than as flat paint.
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let sheenTop = CGColor(red: 1, green: 1, blue: 1, alpha: appearance == .tinted ? 0.16 : 0.30)
    let sheenFade = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let sheen = CGGradient(
           colorsSpace: space, colors: [sheenTop, sheenFade] as CFArray, locations: [0, 1]
       ) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.midY - plate.height * 0.05),
            options: []
        )
    }
    context.restoreGState()

    context.saveGState()
    context.addPath(platePath)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    context.setLineWidth(max(1, size * 0.008))
    context.strokePath()
    context.restoreGState()

    // The bulb, drawn in a 100x100 space and scaled, so every size matches.
    context.saveGState()
    let unit = plate.width / 100
    context.translateBy(x: plate.minX, y: plate.minY)
    context.scaleBy(x: unit, y: unit)

    let glass = appearance == .tinted
        ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        : CGColor(red: 1, green: 0.98, blue: 0.88, alpha: 1)
    let base = appearance == .tinted
        ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.75)
        : CGColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 1)

    // Glass: a circle sitting on a short neck that meets the base.
    let bulbCentre = CGPoint(x: 46, y: 60)
    let bulbRadius: CGFloat = 24
    context.setFillColor(glass)
    context.addArc(
        center: bulbCentre, radius: bulbRadius,
        startAngle: 0, endAngle: .pi * 2, clockwise: false
    )
    context.fillPath()

    // Neck: a tapered link down to the screw base.
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 46 - 13, y: 42))
    neck.addLine(to: CGPoint(x: 46 + 13, y: 42))
    neck.addLine(to: CGPoint(x: 46 + 9, y: 32))
    neck.addLine(to: CGPoint(x: 46 - 9, y: 32))
    neck.closeSubpath()
    context.setFillColor(glass)
    context.addPath(neck)
    context.fillPath()

    // Screw base: three bands.
    context.setFillColor(base)
    for (index, y) in [30.0, 24.5, 19.0].enumerated() {
        let halfWidth = 9.0 - Double(index) * 1.1
        let band = CGRect(x: 46 - halfWidth, y: y - 4, width: halfWidth * 2, height: 4.4)
        context.addPath(CGPath(
            roundedRect: band, cornerWidth: 1.6, cornerHeight: 1.6, transform: nil
        ))
    }
    context.fillPath()

    // The filament, so the bulb reads as lit rather than as a plain circle.
    context.setStrokeColor(appearance == .tinted
        ? CGColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1)
        : CGColor(red: 0.95, green: 0.62, blue: 0.16, alpha: 1))
    context.setLineWidth(3.2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    // Two legs rising into one smooth loop. A zigzag here reads as a letter at 16 points;
    // a single arc stays a filament.
    let filament = CGMutablePath()
    filament.move(to: CGPoint(x: 39, y: 44))
    filament.addLine(to: CGPoint(x: 39, y: 54))
    filament.addQuadCurve(to: CGPoint(x: 53, y: 54), control: CGPoint(x: 46, y: 68))
    filament.addLine(to: CGPoint(x: 53, y: 44))
    context.addPath(filament)
    context.strokePath()

    // Three thought dots rising to the upper right: the "thinking" part.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    for (x, y, r) in [(76.0, 62.0, 3.0), (83.0, 71.0, 4.2), (88.0, 83.0, 5.6)] {
        context.addArc(
            center: CGPoint(x: x, y: y), radius: r,
            startAngle: 0, endAngle: .pi * 2, clockwise: false
        )
        context.fillPath()
    }

    context.restoreGState()
    return rep
}

var written = 0
for variant in variants {
    let pixels = CGFloat(variant.points * variant.scale)
    guard let rep = drawIcon(size: pixels, appearance: .any),
          let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("could not encode \(pixels)px\n".utf8))
        exit(1)
    }
    let url = target.appendingPathComponent(filename(points: variant.points, scale: variant.scale))
    try png.write(to: url)
    written += 1
    print("wrote \(url.lastPathComponent) (\(Int(pixels))px)")
}

// Drop anything left over from the single-size experiment.
for file in (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
where file.hasPrefix("icon-") {
    try? FileManager.default.removeItem(at: target.appendingPathComponent(file))
}
print("\(written) images written to \(target.path)")
