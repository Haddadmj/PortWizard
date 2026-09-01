import AppKit

/// Drawing primitives shared by the two renditions of the app's mark.
///
/// The menu-bar mark (`StatusIcon`) and the app icon (`scripts/make-appicon.swift`)
/// have to draw the same arrangement at very different sizes, one as a flat
/// template and one in colour. The *drawing* genuinely differs; the geometry and
/// symbol lookup underneath it does not, so it lives here and the generator
/// script is compiled against this file rather than carrying its own copies.
/// See `scripts/make-appicon.sh`.
enum SymbolDrawing {
    /// The wand glyph. Present since SF Symbols 1.0, so on the macOS 14+ this
    /// package targets it always resolves — a miss means a broken toolchain,
    /// not an older OS, and each caller says so in its own way rather than
    /// quietly substituting a different mark.
    static let wandName = "wand.and.stars"

    /// The globe the wand is badged onto.
    static let globeName = "network"

    static func symbol(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight
    ) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            )
    }

    /// Scale `size` to fill `box` without distorting it, centred.
    static func aspectFit(_ size: NSSize, in box: NSRect) -> NSRect {
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

    /// Punch a transparent disc around `rect` through everything drawn so far,
    /// then restore normal compositing.
    ///
    /// Both glyphs are thin strokes; without a gap between them they read as one
    /// noisy shape rather than a mark with a badge. Clearing rather than filling
    /// keeps whatever is *behind* the layer showing through — the menu bar in
    /// one case, the icon's gradient in the other.
    static func knockOutDisc(
        around rect: NSRect, outset: CGFloat, in context: NSGraphicsContext
    ) {
        context.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -outset, dy: -outset)).fill()
        context.compositingOperation = .sourceOver
    }
}
