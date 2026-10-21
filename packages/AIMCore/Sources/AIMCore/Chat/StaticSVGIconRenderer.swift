import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Deliberately small, offline SVG icon renderer. No WebKit, JavaScript, CSS engine,
/// fonts, images, links, external resources, entities or general-purpose SVG imports.
/// Unsupported syntax rejects the whole icon instead of silently changing its logo.
enum StaticSVGIconRenderer {
    static let version = 1
    static let maximumBytes = 262_144
    private static var colorSpace: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() }
    static func png(_ data: Data, pixelSize: Int = 128) -> Data? {
        guard !data.isEmpty, data.count <= maximumBytes, (16...256).contains(pixelSize),
              let xml = String(data: data, encoding: .utf8),
              !xml.lowercased().contains("<!doctype"), !xml.lowercased().contains("<!entity") else { return nil }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), !builder.failed, let root = builder.root,
              let bounds = viewBox(root.attributes), bounds.width > 0, bounds.height > 0,
              let context = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8,
                  bytesPerRow: pixelSize * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(CGFloat(pixelSize) / bounds.width, CGFloat(pixelSize) / bounds.height)
        context.translateBy(x: (CGFloat(pixelSize) - bounds.width * scale) / 2, y: CGFloat(pixelSize) - (CGFloat(pixelSize) - bounds.height * scale) / 2)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        do { try draw(root, context: context, inherited: [:], gradients: builder.gradients) } catch { return nil }
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { return nil }
        return output as Data
    }

    private enum Invalid: Error { case unsupported }
    private final class Node {
        let name: String; var attributes: [String: String]; var children: [Node] = []
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
    }
    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?; var stack: [Node] = []; var gradients: [String: Node] = [:]; var failed = false; var count = 0
        private let shapes: Set<String> = ["svg", "g", "defs", "linearGradient", "radialGradient", "stop", "path", "rect", "circle", "ellipse", "line", "polygon", "polyline", "title", "desc"]
        private let attributes: Set<String> = ["xmlns", "viewBox", "width", "height", "role", "aria-label", "id", "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "opacity", "transform", "style", "d", "x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "r", "rx", "ry", "points", "gradientUnits", "offset", "stop-color", "stop-opacity", "version"]
        func reject(_ parser: XMLParser) { failed = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes raw: [String: String]) {
            count += 1
            guard count <= 1024, stack.count < 32, shapes.contains(name), raw.keys.allSatisfy({ attributes.contains($0) }),
                  raw.values.allSatisfy({ $0.utf8.count <= 65_536 }), raw["xmlns"] == nil || raw["xmlns"] == "http://www.w3.org/2000/svg" else { reject(parser); return }
            var values = raw
            if let style = values.removeValue(forKey: "style") {
                let allowed: Set<String> = ["fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "opacity", "stop-color", "stop-opacity"]
                for declaration in style.split(separator: ";") where !declaration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard pair.count == 2, allowed.contains(pair[0]) else { reject(parser); return }
                    values[pair[0]] = pair[1]
                }
            }
            let node = Node(name, values)
            if let parent = stack.last {
                let parentName = parent.name
                let legal = parentName == "svg" || parentName == "g" || (parentName == "defs" && ["linearGradient", "radialGradient"].contains(name)) || (["linearGradient", "radialGradient"].contains(parentName) && name == "stop")
                guard legal, name != "svg", !(name == "stop" && !["linearGradient", "radialGradient"].contains(parentName)) else { reject(parser); return }
                parent.children.append(node)
            } else {
                guard root == nil, name == "svg" else { reject(parser); return }
                root = node
            }
            if ["linearGradient", "radialGradient"].contains(name) {
                guard let id = values["id"], !id.isEmpty, gradients[id] == nil else { reject(parser); return }
                gradients[id] = node
            }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { if !stack.isEmpty { stack.removeLast() } }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !["title", "desc"].contains(stack.last?.name ?? ""), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser) }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { reject(parser) }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser); return nil }
    }

    private static func viewBox(_ values: [String: String]) -> CGRect? {
        if let raw = values["viewBox"], let n = numbers(raw), n.count == 4, (0.001...16_384).contains(n[2]), (0.001...16_384).contains(n[3]) { return CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
        guard values["viewBox"] == nil, let w = scalar(values["width"]), let h = scalar(values["height"]), (0.001...16_384).contains(w), (0.001...16_384).contains(h) else { return nil }
        return CGRect(x: 0, y: 0, width: w, height: h)
    }
    private static func scalar(_ raw: String?) -> CGFloat? {
        guard let raw, let n = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), n.isFinite, abs(n) <= 1_000_000 else { return nil }
        return CGFloat(n)
    }
    private static func numbers(_ raw: String) -> [CGFloat]? {
        var scanner = NumberScanner(raw)
        var result: [CGFloat] = []
        while !scanner.finished { guard let value = scanner.number(), result.count < 16_384 else { return nil }; result.append(value) }
        return result
    }
    private static func color(_ raw: String, opacity: CGFloat) -> CGColor? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = ["black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000", "blue": "#0000ff", "transparent": "#00000000"]
        let text = names[value] ?? value
        guard text.hasPrefix("#") else { return nil }
        let hex = String(text.dropFirst())
        let expanded: String
        if hex.count == 3 || hex.count == 4 { expanded = hex.map { "\($0)\($0)" }.joined() } else { expanded = hex }
        guard expanded.count == 6 || expanded.count == 8, let integer = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        return CGColor(colorSpace: colorSpace, components: [CGFloat((integer >> (16 + shift)) & 255) / 255, CGFloat((integer >> (8 + shift)) & 255) / 255,
                       CGFloat((integer >> shift) & 255) / 255, opacity * (hasAlpha ? CGFloat(integer & 255) / 255 : 1)])
    }
    private static func opacity(_ raw: String?) throws -> CGFloat {
        guard let raw else { return 1 }
        guard let value = scalar(raw), (0...1).contains(value) else { throw Invalid.unsupported }; return value
    }
    private static func draw(_ node: Node, context: CGContext, inherited: [String: String], gradients: [String: Node]) throws {
        if ["defs", "linearGradient", "radialGradient", "stop", "title", "desc"].contains(node.name) { return }
        let styleKeys: Set<String> = ["fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit"]
        var style = inherited
        for (key, value) in node.attributes where styleKeys.contains(key) { style[key] = value }
        context.saveGState(); defer { context.restoreGState() }
        if let raw = node.attributes["transform"] { context.concatenate(try transform(raw)) }
        let alpha = try opacity(node.attributes["opacity"])
        // Transparency layers preserve group opacity across overlapping child shapes.
        if alpha != 1 { context.setAlpha(alpha); context.beginTransparencyLayer(auxiliaryInfo: nil) }
        defer { if alpha != 1 { context.endTransparencyLayer() } }
        if node.name == "svg" || node.name == "g" {
            for child in node.children { try draw(child, context: context, inherited: style, gradients: gradients) }; return
        }
        let path = try shape(node)
        let fill = style["fill"] ?? "#000000", stroke = style["stroke"] ?? "none"
        let rule: CGPathFillRule
        switch style["fill-rule"] ?? "nonzero" { case "nonzero": rule = .winding; case "evenodd": rule = .evenOdd; default: throw Invalid.unsupported }
        if fill != "none" {
            let fillAlpha = try opacity(style["fill-opacity"])
            if fill.hasPrefix("url(#"), fill.hasSuffix(")") {
                let id = String(fill.dropFirst(5).dropLast())
                guard let gradient = gradients[id] else { throw Invalid.unsupported }
                context.saveGState(); context.addPath(path); context.clip(using: rule)
                try drawGradient(gradient, bounds: path.boundingBoxOfPath, opacity: fillAlpha, context: context)
                context.restoreGState()
            } else {
                guard let value = color(fill, opacity: fillAlpha) else { throw Invalid.unsupported }
                context.setFillColor(value); context.addPath(path); context.drawPath(using: rule == .evenOdd ? .eoFill : .fill)
            }
        }
        if stroke != "none" {
            guard let value = color(stroke, opacity: try opacity(style["stroke-opacity"])), let width = scalar(style["stroke-width"] ?? "1"), width >= 0 else { throw Invalid.unsupported }
            context.setStrokeColor(value); context.setLineWidth(width)
            switch style["stroke-linecap"] ?? "butt" { case "butt": context.setLineCap(.butt); case "round": context.setLineCap(.round); case "square": context.setLineCap(.square); default: throw Invalid.unsupported }
            switch style["stroke-linejoin"] ?? "miter" { case "miter": context.setLineJoin(.miter); case "round": context.setLineJoin(.round); case "bevel": context.setLineJoin(.bevel); default: throw Invalid.unsupported }
            guard let miter = scalar(style["stroke-miterlimit"] ?? "4"), miter >= 1 else { throw Invalid.unsupported }
            context.setMiterLimit(miter); context.addPath(path); context.strokePath()
        }
    }
    private static func shape(_ node: Node) throws -> CGPath {
        let a = node.attributes
        func n(_ key: String, _ fallback: String = "0") throws -> CGFloat { guard let v = scalar(a[key] ?? fallback) else { throw Invalid.unsupported }; return v }
        let path = CGMutablePath()
        switch node.name {
        case "path": guard let d = a["d"], let parsed = pathData(d) else { throw Invalid.unsupported }; return parsed
        case "rect":
            let x = try n("x"), y = try n("y"), w = try n("width"), h = try n("height")
            let rx = try n("rx", a["ry"] ?? "0"), ry = try n("ry", a["rx"] ?? "0")
            guard w >= 0, h >= 0, rx >= 0, ry >= 0 else { throw Invalid.unsupported }
            path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerWidth: min(rx, w / 2), cornerHeight: min(ry, h / 2))
        case "circle", "ellipse":
            let x = try n("cx"), y = try n("cy"), rx = try n(node.name == "circle" ? "r" : "rx"), ry = try n(node.name == "circle" ? "r" : "ry")
            guard rx >= 0, ry >= 0 else { throw Invalid.unsupported }; path.addEllipse(in: CGRect(x: x-rx, y: y-ry, width: rx*2, height: ry*2))
        case "line": path.move(to: CGPoint(x: try n("x1"), y: try n("y1"))); path.addLine(to: CGPoint(x: try n("x2"), y: try n("y2")))
        case "polygon", "polyline":
            guard let raw = a["points"], let points = numbers(raw), points.count >= 4, points.count % 2 == 0 else { throw Invalid.unsupported }
            path.move(to: CGPoint(x: points[0], y: points[1])); for i in stride(from: 2, to: points.count, by: 2) { path.addLine(to: CGPoint(x: points[i], y: points[i+1])) }
            if node.name == "polygon" { path.closeSubpath() }
        default: throw Invalid.unsupported
        }
        return path
    }
    private static func drawGradient(_ node: Node, bounds: CGRect, opacity: CGFloat, context: CGContext) throws {
        let a = node.attributes
        let user = a["gradientUnits"] == "userSpaceOnUse"
        guard a["gradientUnits"] == nil || user || a["gradientUnits"] == "objectBoundingBox", !bounds.isEmpty else { throw Invalid.unsupported }
        var locations: [CGFloat] = [], colors: [CGColor] = []
        for stop in node.children {
            guard stop.name == "stop", let offset = fraction(stop.attributes["offset"] ?? "0"), (0...1).contains(offset), offset >= (locations.last ?? 0),
                  let value = color(stop.attributes["stop-color"] ?? "black", opacity: opacity * (try self.opacity(stop.attributes["stop-opacity"]))) else { throw Invalid.unsupported }
            locations.append(offset); colors.append(value)
        }
        guard colors.count >= 2, colors.count <= 64, let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else { throw Invalid.unsupported }
        func coordinate(_ name: String, _ defaultValue: String, horizontal: Bool) throws -> CGFloat {
            guard let raw = a[name] ?? Optional(defaultValue) else { throw Invalid.unsupported }
            if user {
                // User-space percentages depend on the root viewport, not this shape; reject that unsupported case.
                guard !raw.hasSuffix("%"), let value = scalar(raw) else { throw Invalid.unsupported }; return value
            }
            guard let value = fraction(raw) else { throw Invalid.unsupported }
            return (horizontal ? bounds.minX : bounds.minY) + value * (horizontal ? bounds.width : bounds.height)
        }
        if node.name == "linearGradient" {
            let start = CGPoint(x: try coordinate("x1", "0%", horizontal: true), y: try coordinate("y1", "0%", horizontal: false))
            let end = CGPoint(x: try coordinate("x2", "100%", horizontal: true), y: try coordinate("y2", "0%", horizontal: false))
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            let x = try coordinate("cx", "50%", horizontal: true), y = try coordinate("cy", "50%", horizontal: false)
            guard let r = fraction(a["r"] ?? "50%"), r > 0 else { throw Invalid.unsupported }
            // Object-bounding-box radial gradients are circular in normalized box coordinates.
            if !user {
                context.translateBy(x: bounds.minX, y: bounds.minY); context.scaleBy(x: bounds.width, y: bounds.height)
                context.drawRadialGradient(gradient, startCenter: CGPoint(x: (x-bounds.minX)/bounds.width, y: (y-bounds.minY)/bounds.height), startRadius: 0,
                    endCenter: CGPoint(x: (x-bounds.minX)/bounds.width, y: (y-bounds.minY)/bounds.height), endRadius: r, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else { context.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]) }
        }
    }
    private static func fraction(_ raw: String) -> CGFloat? { raw.hasSuffix("%") ? scalar(String(raw.dropLast())).map { $0 / 100 } : scalar(raw) }

    private static func transform(_ raw: String) throws -> CGAffineTransform {
        let pattern = try NSRegularExpression(pattern: #"([a-zA-Z]+)\s*\(([^)]*)\)"#)
        var cursor = raw.startIndex; var result = CGAffineTransform.identity
        let matches = pattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        guard !matches.isEmpty, matches.count <= 32 else { throw Invalid.unsupported }
        for match in matches {
            guard let full = Range(match.range, in: raw), raw[cursor..<full.lowerBound].allSatisfy({ $0.isWhitespace || $0 == "," }),
                  let name = Range(match.range(at: 1), in: raw), let arguments = Range(match.range(at: 2), in: raw), let n = numbers(String(raw[arguments])) else { throw Invalid.unsupported }
            let next: CGAffineTransform
            switch raw[name] {
            case "translate" where n.count == 1 || n.count == 2: next = .init(translationX: n[0], y: n.count == 2 ? n[1] : 0)
            case "scale" where n.count == 1 || n.count == 2: next = .init(scaleX: n[0], y: n.count == 2 ? n[1] : n[0])
            case "matrix" where n.count == 6: next = .init(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            case "rotate" where n.count == 1 || n.count == 3:
                let angle = n[0] * .pi / 180
                next = n.count == 1 ? .init(rotationAngle: angle) : CGAffineTransform(translationX: n[1], y: n[2]).rotated(by: angle).translatedBy(x: -n[1], y: -n[2])
            default: throw Invalid.unsupported
            }
            result = next.concatenating(result); cursor = full.upperBound
            guard [result.a, result.b, result.c, result.d, result.tx, result.ty].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw Invalid.unsupported }
        }
        guard raw[cursor...].allSatisfy({ $0.isWhitespace || $0 == "," }) else { throw Invalid.unsupported }
        return result
    }

    private struct NumberScanner {
        let values: [UInt8]; var index = 0
        init(_ raw: String) { values = Array(raw.utf8) }
        mutating func space() { while index < values.count && [9,10,13,32,44].contains(values[index]) { index += 1 } }
        var finished: Bool { mutating get { space(); return index == values.count } }
        mutating func number() -> CGFloat? {
            space(); let start = index
            if index < values.count && (values[index] == 43 || values[index] == 45) { index += 1 }
            var digits = 0
            while index < values.count && (48...57).contains(values[index]) { index += 1; digits += 1 }
            if index < values.count && values[index] == 46 { index += 1; while index < values.count && (48...57).contains(values[index]) { index += 1; digits += 1 } }
            guard digits > 0 else { index = start; return nil }
            if index < values.count && (values[index] == 69 || values[index] == 101) {
                index += 1; if index < values.count && (values[index] == 43 || values[index] == 45) { index += 1 }
                let exponent = index; while index < values.count && (48...57).contains(values[index]) { index += 1 }
                guard index > exponent else { return nil }
            }
            return scalar(String(decoding: values[start..<index], as: UTF8.self))
        }
    }
    /// Path commands M/L/H/V/C/S/Q/T/Z, absolute/relative; arcs are intentionally unsupported.
    private static func pathData(_ raw: String) -> CGPath? {
        var s = NumberScanner(raw), command: UInt8?; let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero, control = CGPoint.zero, previous: UInt8 = 0, segments = 0
        func reflected() -> CGPoint { CGPoint(x: current.x * 2 - control.x, y: current.y * 2 - control.y) }
        while !s.finished {
            segments += 1; guard segments <= 16_384 else { return nil }
            if s.index < s.values.count, (65...90).contains(s.values[s.index]) || (97...122).contains(s.values[s.index]) { command = s.values[s.index]; s.index += 1 }
            guard let c = command else { return nil }
            let upper = c >= 97 ? c - 32 : c, relative = c >= 97
            guard [77,76,72,86,67,83,81,84,90].contains(upper), previous != 0 || upper == 77 else { return nil }
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + (relative ? current.x : 0), y: y + (relative ? current.y : 0)) }
            if upper == 90 { path.closeSubpath(); current = start; command = nil; previous = upper; continue }
            let count = upper == 72 || upper == 86 ? 1 : upper == 67 ? 6 : upper == 83 || upper == 81 ? 4 : 2
            var n: [CGFloat] = []; for _ in 0..<count { guard let v = s.number() else { return nil }; n.append(v) }
            switch upper {
            case 77: current = point(n[0], n[1]); start = current; path.move(to: current); command = relative ? 108 : 76
            case 76: current = point(n[0], n[1]); path.addLine(to: current)
            case 72: current.x = n[0] + (relative ? current.x : 0); path.addLine(to: current)
            case 86: current.y = n[0] + (relative ? current.y : 0); path.addLine(to: current)
            case 67: let first = point(n[0], n[1]), second = point(n[2], n[3]), end = point(n[4], n[5]); path.addCurve(to: end, control1: first, control2: second); control = second; current = end
            case 83: let first = [67,83].contains(previous) ? reflected() : current, second = point(n[0], n[1]), end = point(n[2], n[3]); path.addCurve(to: end, control1: first, control2: second); control = second; current = end
            case 81: let first = point(n[0], n[1]), end = point(n[2], n[3]); path.addQuadCurve(to: end, control: first); control = first; current = end
            case 84: let first = [81,84].contains(previous) ? reflected() : current, end = point(n[0], n[1]); path.addQuadCurve(to: end, control: first); control = first; current = end
            default: return nil
            }
            previous = upper
        }
        return path.isEmpty ? nil : path
    }
}
