// Generates Resources/AppIcon.icns — the network glyph with a wand badged into
// its lower-right corner, on a macOS-style rounded-rect ground.
//
// This mirrors the arrangement in Sources/PortWizard/StatusIcon.swift so the
// Finder icon and the menu-bar mark read as the same thing. The drawing is kept
// separate because the menu-bar mark is a flat template image (the menu bar
// supplies the colour) while this one has to carry its own; the geometry and
// symbol lookup underneath both is shared, via SymbolDrawing.swift.
//
// That shared file is why this is compiled rather than interpreted. Run it with
// ./scripts/make-appicon.sh, not `swift scripts/make-appicon.swift`.
//
// Run it after changing the mark; the .icns is committed so a plain build
// doesn't need Xcode or a designer in the loop.

import AppKit

// MARK: - Geometry

/// macOS app icons don't fill their canvas: the rounded rect occupies the
/// middle ~80%, and the rest is the breathing room the Dock expects.
let contentRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 185.0 / 824.0

/// Recolour a template symbol inside its own transparent layer.
///
/// Tinting with `sourceAtop` directly on the shared mark layer would clip to
/// that rect rather than to the glyph, so any pixel of an *earlier* glyph
/// sharing the rect gets recoloured too — which speckled the globe gold in the
/// corners the wand's knockout disc doesn't reach.
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

/// Look up a symbol, or bail out naming it.
///
/// A missing glyph here would bake a wrong mark into a committed binary asset,
/// so this fails the run rather than substituting something else.
func requireSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
    guard let image = SymbolDrawing.symbol(name, pointSize: pointSize, weight: weight) else {
        FileHandle.standardError.write(
            Data("error: SF Symbol '\(name)' is unavailable on this system\n".utf8)
        )
        exit(1)
    }
    return image
}

// MARK: - Drawing

/// The globe-and-wand mark on its own transparent layer.
///
/// Built separately from the ground so the gap between wand and globe can be
/// punched straight through to the gradient, exactly as the menu-bar mark
/// punches through to the menu bar behind it.
func markLayer(side: CGFloat, weight: NSFont.Weight) -> NSImage {
    let globe = requireSymbol(SymbolDrawing.globeName, pointSize: side * 0.62, weight: weight)
    let stick = requireSymbol(SymbolDrawing.wandName, pointSize: side * 0.40, weight: weight)

    return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        guard let context = NSGraphicsContext.current else { return false }

        let globeBox = NSRect(
            x: rect.width * 0.06, y: rect.height * 0.16,
            width: rect.width * 0.70, height: rect.height * 0.70
        )
        tinted(globe, .white).draw(in: SymbolDrawing.aspectFit(globe.size, in: globeBox))

        let wandBox = NSRect(
            x: rect.width * 0.50, y: rect.height * 0.04,
            width: rect.width * 0.44, height: rect.height * 0.44
        )
        let wandRect = SymbolDrawing.aspectFit(stick.size, in: wandBox)

        SymbolDrawing.knockOutDisc(around: wandRect, outset: side * 0.035, in: context)

        let gold = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.35, alpha: 1)
        tinted(stick, gold).draw(in: wandRect)
        return true
    }
}

func appIcon(pixels: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
        let side = rect.width * contentRatio
        let ground = NSRect(
            x: (rect.width - side) / 2, y: (rect.height - side) / 2,
            width: side, height: side
        )
        let radius = side * cornerRatio
        let path = NSBezierPath(roundedRect: ground, xRadius: radius, yRadius: radius)

        let gradient = NSGradient(
            colors: [
                NSColor(srgbRed: 0.42, green: 0.53, blue: 0.99, alpha: 1),
                NSColor(srgbRed: 0.29, green: 0.24, blue: 0.72, alpha: 1),
            ]
        )
        path.addClip()
        gradient?.draw(in: ground, angle: -90)

        // The globe is a grid of hairlines. At 16 and 32 pixels a regular
        // weight falls below one device pixel per stroke and the whole glyph
        // resolves as a grey blob, so the small renditions are drawn heavier.
        // This is why each size is redrawn rather than resampled from 1024.
        let weight: NSFont.Weight = rect.width <= 64 ? .bold : .regular
        markLayer(side: side, weight: weight).draw(
            in: ground, from: .zero, operation: .sourceOver, fraction: 1
        )
        return true
    }
}

// MARK: - Emit

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

@main
enum MakeAppIcon {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(
            at: iconset, withIntermediateDirectories: true
        )

        // Each size is redrawn rather than resampled from 1024, so the strokes
        // stay crisp at 16pt instead of turning to grey mush.
        for point in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = point * scale
                let suffix = scale == 1 ? "" : "@2x"
                let name = "icon_\(point)x\(point)\(suffix).png"
                let data = png(appIcon(pixels: CGFloat(pixels)), pixels: pixels)
                try data.write(to: iconset.appendingPathComponent(name))
            }
        }

        let icns = root.appendingPathComponent("Resources/AppIcon.icns")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("error: iconutil failed\n".utf8))
            exit(1)
        }
        print("wrote \(icns.path)")
    }
}
