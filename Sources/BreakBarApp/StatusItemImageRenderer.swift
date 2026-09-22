import AppKit

enum StatusItemImageRenderer {
    private static let imageHeight: CGFloat = 18
    private static let representationScales: [CGFloat] = [1, 2]

    static func image(symbolName: String, text: String, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: imageHeight)
        let image = NSImage(size: size)

        for scale in representationScales {
            if let representation = bitmapRepresentation(
                symbolName: symbolName,
                text: text,
                size: size,
                scale: scale
            ) {
                image.addRepresentation(representation)
            }
        }

        image.isTemplate = true
        return image
    }

    private static func bitmapRepresentation(
        symbolName: String,
        text: String,
        size: NSSize,
        scale: CGFloat
    ) -> NSBitmapImageRep? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return nil
        }

        representation.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(
            x: 0,
            y: 0,
            width: CGFloat(representation.pixelsWide),
            height: CGFloat(representation.pixelsHigh)
        ))
        context.cgContext.scaleBy(x: scale, y: scale)

        drawSymbol(named: symbolName, height: size.height)
        drawText(text, height: size.height)

        return representation
    }

    private static func drawSymbol(named symbolName: String, height: CGFloat) {
        guard let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        ) else {
            return
        }

        let symbolSize = NSSize(width: 15, height: 15)
        symbol.draw(in: NSRect(
            x: 1,
            y: floor((height - symbolSize.height) / 2),
            width: symbolSize.width,
            height: symbolSize.height
        ))
    }

    private static func drawText(_ text: String, height: CGFloat) {
        guard let font = NSFont(name: "Menlo-Bold", size: 13)
            ?? NSFont(name: "Menlo", size: 13) else {
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let textHeight = ceil(font.ascender - font.descender)

        (text as NSString).draw(
            at: NSPoint(
                x: 20,
                y: floor((height - textHeight) / 2)
            ),
            withAttributes: attributes
        )
    }
}
