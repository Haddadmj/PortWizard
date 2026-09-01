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
///
/// The geometry helpers are in `SymbolDrawing`, shared with the app-icon
/// generator so the two renditions of the mark can't drift apart.
enum StatusIcon {
    /// 18pt is the tallest a status item image can be before AppKit scales it
    /// down for us, and scaling a two-part mark is what turns the badge to mush.
    private static let canvas = NSSize(width: 18, height: 18)

    /// The mark, built once.
    ///
    /// Shared by the status item and the popover's header so the two can't
    /// drift into showing different marks for the same app.
    @MainActor static let shared: NSImage = menuBar()

    /// The menu-bar status item image.
    ///
    /// If the badged mark can't be composed the plain globe is used instead. It
    /// is the same glyph this app shipped with before the badge, so the status
    /// item stays correct and legible — it just loses the wand.
    static func menuBar() -> NSImage {
        let image = badgedMark() ?? plainGlobe()
        image.isTemplate = true
        image.accessibilityDescription = "Port Wizard"
        return image
    }

    // MARK: - Composition

    private static func badgedMark() -> NSImage? {
        guard
            let globe = SymbolDrawing.symbol(
                SymbolDrawing.globeName, pointSize: 14, weight: .regular
            ),
            let wand = SymbolDrawing.symbol(
                SymbolDrawing.wandName, pointSize: 10, weight: .bold
            )
        else { return nil }

        return NSImage(size: canvas, flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }

            // The globe takes the top-left, deliberately smaller than the
            // canvas, so the wand has a corner to occupy without overlapping
            // the part of the glyph that carries its meaning.
            let globeBox = NSRect(x: 0, y: rect.height - 15, width: 15, height: 15)
            globe.draw(in: SymbolDrawing.aspectFit(globe.size, in: globeBox))

            let wandBox = NSRect(x: rect.width - 10, y: 0, width: 10, height: 10)
            let wandRect = SymbolDrawing.aspectFit(wand.size, in: wandBox)

            SymbolDrawing.knockOutDisc(around: wandRect, outset: 1.5, in: context)
            wand.draw(in: wandRect)
            return true
        }
    }

    private static func plainGlobe() -> NSImage {
        SymbolDrawing.symbol(SymbolDrawing.globeName, pointSize: 14, weight: .regular)
            ?? NSImage(size: canvas)
    }
}
