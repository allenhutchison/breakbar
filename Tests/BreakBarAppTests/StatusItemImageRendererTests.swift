import AppKit
@testable import BreakBarApp
import XCTest

final class StatusItemImageRendererTests: XCTestCase {
    func testImageIsEagerlyRenderedAtStandardAndRetinaScales() {
        let image = StatusItemImageRenderer.image(
            symbolName: "timer",
            text: "32:09",
            width: 62
        )

        XCTAssertEqual(image.size, NSSize(width: 62, height: 18))
        XCTAssertTrue(image.isTemplate)
        XCTAssertFalse(image.representations.contains { $0 is NSCustomImageRep })

        let bitmapRepresentations = image.representations.compactMap { $0 as? NSBitmapImageRep }
        XCTAssertEqual(bitmapRepresentations.count, 2)
        XCTAssertEqual(
            bitmapRepresentations.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) },
            [NSSize(width: 62, height: 18), NSSize(width: 124, height: 36)]
        )
        for representation in bitmapRepresentations {
            let scale = representation.pixelsWide / 62
            XCTAssertTrue(hasVisiblePixel(
                representation,
                xRange: 0..<(16 * scale)
            ))
            XCTAssertTrue(hasVisiblePixel(
                representation,
                xRange: (20 * scale)..<representation.pixelsWide
            ))
        }
    }

    func testRendererSupportsEveryStatusItemWidthAndLabelShape() {
        let cases: [(symbol: String, text: String, width: CGFloat)] = [
            ("figure.stand", "BreakBar", 86),
            ("timer", "0:10", 62),
            ("exclamationmark.circle.fill", "+32:09", 70),
            ("figure.walk", "AWAY", 62),
            ("car.fill", "Leave 0:50", 104),
        ]

        for item in cases {
            let image = StatusItemImageRenderer.image(
                symbolName: item.symbol,
                text: item.text,
                width: item.width
            )

            XCTAssertEqual(image.size, NSSize(width: item.width, height: 18))
            XCTAssertFalse(image.representations.contains { $0 is NSCustomImageRep })
        }
    }

    private func hasVisiblePixel(
        _ representation: NSBitmapImageRep,
        xRange: Range<Int>
    ) -> Bool {
        for x in xRange {
            for y in 0..<representation.pixelsHigh {
                if let color = representation.colorAt(x: x, y: y), color.alphaComponent > 0 {
                    return true
                }
            }
        }
        return false
    }
}
