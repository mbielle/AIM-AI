import XCTest
import ImageIO
@testable import AIMCore

final class StaticSVGIconRendererTests: XCTestCase {
    // Synthetic geometry exercising the same static features as DispatchAI's public icon;
    // it does not redistribute that site's artwork.
    private let gradientIcon = ##"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="Synthetic icon">
      <defs>
        <linearGradient id="panel" x1="0" y1="0" x2="64" y2="64" gradientUnits="userSpaceOnUse">
          <stop offset="0%" stop-color="#202040"/><stop offset="100%" stop-color="#101020"/>
        </linearGradient>
        <radialGradient id="glow" cx="30%" cy="24%" r="58%">
          <stop offset="0%" stop-color="#00ff00" stop-opacity="0.4"/>
          <stop offset="100%" stop-color="#00ff00" stop-opacity="0"/>
        </radialGradient>
      </defs>
      <rect width="64" height="64" rx="8" fill="url(#panel)"/>
      <rect width="64" height="64" rx="8" fill="url(#glow)"/>
      <path d="M8 16H24M40 48H56M16 8L24 16" fill="none" stroke="#ffffff" stroke-width="3" stroke-linecap="square"/>
      <circle cx="32" cy="32" r="6" fill="#ff0000"/>
    </svg>
    """##

    func testStaticGradientIconProducesSmallPNGAndExpectedCenter() throws {
        let png = try XCTUnwrap(StaticSVGIconRenderer.png(Data(gradientIcon.utf8)))
        XCTAssertTrue(SourceFaviconStore.isRenderableImage(png))
        XCTAssertLessThan(png.count, 65_536)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 128); XCTAssertEqual(image.height, 128)
        let center = pixel(image, x: 64, y: 64)
        XCTAssertGreaterThan(center[0], 245); XCTAssertLessThan(center[1], 10); XCTAssertLessThan(center[2], 10)
    }

    func testRelativePathsTransformsAndEvenOddGeometryAreSupported() throws {
        let source = ##"<svg viewBox="0 0 20 20"><g transform="translate(2 2) scale(2)"><path d="m0 0h8v8h-8z m2 2h4v4h-4z" fill="#00ff00" fill-rule="evenodd"/></g><path d="M1 1C2 2 3 3 4 4S5 5 6 6Q7 7 8 8T9 9" fill="none" stroke="#ff0000"/></svg>"##
        XCTAssertNotNil(StaticSVGIconRenderer.png(Data(source.utf8)))
    }

    func testActiveExternalAndUnsupportedSVGRejectsWholeIcon() {
        let fragments = [
            ##"<script>alert(1)</script>"##,
            ##"<image href="https://tracker.example/logo.png" width="1" height="1"/>"##,
            ##"<use href="#other"/>"##,
            ##"<foreignObject><div>text</div></foreignObject>"##,
            ##"<style>@import url(https://tracker.example/x);</style>"##,
            ##"<path d="M0 0H2" onload="alert(1)"/>"##,
            ##"<rect width="10" height="10" fill="url(https://tracker.example/x)"/>"##,
            ##"<rect width="10" height="10" filter="url(#blur)"/>"##,
            ##"<path d="M0 0A10 10 0 0 0 10 10"/>"##,
            ##"<text x="0" y="10">External font dependency</text>"##,
            ##"<rect width="10" height="10" style="fill:red;animation:spin 1s"/>"##
        ]
        for fragment in fragments {
            let xml = "<svg viewBox=\"0 0 10 10\">\(fragment)</svg>"
            XCTAssertNil(StaticSVGIconRenderer.png(Data(xml.utf8)), fragment)
        }
        XCTAssertNil(StaticSVGIconRenderer.png(Data(##"<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg viewBox="0 0 10 10"><title>&x;</title></svg>"##.utf8)))
        XCTAssertNil(StaticSVGIconRenderer.png(Data(##"<?xml-stylesheet href="https://tracker.example/style.css"?><svg viewBox="0 0 10 10"/>"##.utf8)))
    }

    func testSizeComplexityAndNonFiniteNumbersFailClosed() {
        for box in ["0 0 0 10", "0 0 NaN 10", "0 0 1e99 10"] {
            XCTAssertNil(StaticSVGIconRenderer.png(Data("<svg viewBox=\"\(box)\"><rect width=\"10\" height=\"10\"/></svg>".utf8)))
        }
        let nested = "<svg viewBox=\"0 0 10 10\">" + String(repeating: "<g>", count: 40) + "<circle r=\"1\"/>" + String(repeating: "</g>", count: 40) + "</svg>"
        XCTAssertNil(StaticSVGIconRenderer.png(Data(nested.utf8)))
        let oversized = Data(("<svg viewBox=\"0 0 10 10\">" + String(repeating: " ", count: 262_144) + "</svg>").utf8)
        XCTAssertNil(StaticSVGIconRenderer.png(oversized))
        XCTAssertNil(StaticSVGIconRenderer.png(Data(gradientIcon.utf8), pixelSize: 10_000))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        rgba.withUnsafeMutableBytes { pointer in
            let context = CGContext(data: pointer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let start = (y * image.width + x) * 4
        return Array(rgba[start..<start+4])
    }
}
