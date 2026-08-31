import AppKit

/// Builds the app's mark: the network glyph, with a magic wand badged into its
/// lower-right corner.
///
/// SF Symbols has no combined network-and-wand glyph, so the two are composed
/// here rather than looked up by name. The wand is what makes the status item
/// recognisably *this* app — a bare `network` symbol is the same glyph a dozen
/// other utilities and several system menus already use.
///
/// The result is a template image. Every pixel is drawn opaque and the menu bar
/// supplies the colour, which is what keeps it legible in a light menu bar, a
/// dark one, and while the status item is highlighted.
enum StatusIcon {
    /// 18pt is the tallest a status item image can be before AppKit scales it
    /// down for us, and scaling a two-part mark is what turns the badge to mush.
    private static let canvas = NSSize(width: 18, height: 18)

    /// The wand has been renamed across SF Symbols releases, so resolve by
    /// preference and take whatever this OS actually ships.
    private static let wandNames = [
        "wand.and.stars", "wand.and.sparkles", "wand.and.rays", "sparkles"
    ]

    /// The menu-bar status item image.
    static func menuBar() -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { rect in
            guard let context = NSGraphicsContext.current,
                  let globe = symbol("network", pointSize: 14, weight: .regular),
                  let wand = resolveWand(pointSize: 10, weight: .bold)
            else { return false }

            // The globe takes the top-left, deliberately smaller than the
            // canvas, so the wand has a corner to occupy without overlapping
            // the part of the glyph that carries its meaning.
            let globeBox = NSRect(x: 0, y: rect.height - 15, width: 15, height: 15)
            globe.draw(in: aspectFit(globe.size, in: globeBox))

            let wandBox = NSRect(x: rect.width - 10, y: 0, width: 10, height: 10)
            let wandRect = aspectFit(wand.size, in: wandBox)

            // Clear a disc under the wand before drawing it. Both glyphs are
            // thin strokes; without a gap between them they read as one noisy
            // shape at menu-bar size instead of a mark with a badge.
            context.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: wandRect.insetBy(dx: -1.5, dy: -1.5)).fill()

            context.compositingOperation = .sourceOver
            wand.draw(in: wandRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Port Wizard"
        return image
    }

    // MARK: - Composition

    private static func symbol(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight
    ) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            )
    }

    private static func resolveWand(
        pointSize: CGFloat, weight: NSFont.Weight
    ) -> NSImage? {
        for name in wandNames {
            if let image = symbol(name, pointSize: pointSize, weight: weight) {
                return image
            }
        }
        return nil
    }

    /// Scale `size` to fill `box` without distorting it, centred.
    private static func aspectFit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: box.midX - fitted.width / 2,
            y: box.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
