import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The pairing QR code: an `aim://remote/pair` link carrying only the one-time,
/// 5-minute pairing code and this Mac's display name — never the machine secret.
/// The iPhone camera opens it in the AIM app, which asks for confirmation.
public enum RemotePairingLink {
    public static func url(code: String, machineName: String) -> URL {
        var components = URLComponents()
        components.scheme = "aim"
        components.host = "remote"
        components.path = "/pair"
        components.queryItems = [URLQueryItem(name: "code", value: code),
                                 URLQueryItem(name: "name", value: String(machineName.prefix(60))),
                                 URLQueryItem(name: "v", value: "1")]
        return components.url!
    }

    /// A crisp QR image (no interpolation) of the link.
    public static func image(for url: URL, size: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
