import SwiftUI

/// An agent's own mark, where a pane's row would wear a plain terminal
/// glyph: Claude Code's, Codex's. Drawn from the mark's vector outline in
/// the font's size and the row's ink, so it sits in a line as a symbol
/// does, on the Mac's sidebar and the phone alike (both apps compile this
/// folder). Which face a pane wears is VigilWire's one rule (`PaneFace`):
/// the emoji a person gave it, else its agent's mark, else the terminal.
struct AgentMark: View {
    let agent: String
    /// The em it is drawn in.
    var size: CGFloat

    var body: some View {
        if let mark = Self.marks[agent] {
            mark.path
                .fill(mark.tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary), style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
                .accessibilityLabel(mark.name)
        }
    }

    /// Whether `agent` has a mark here (a row falls back to its glyph when not).
    static func knows(_ agent: String) -> Bool { marks[agent] != nil }

    private struct Mark {
        let name: String
        /// Its outline on a 24 by 24 grid.
        let outline: String
        /// The mark's own color, when it has one that reads on both grounds.
        let tint: Color?
        var path: ScaledOutline { ScaledOutline(path: SVGOutline.path(outline)) }
    }

    /// The outline scaled from its 24-unit grid to whatever it is given.
    struct ScaledOutline: Shape {
        let path: Path
        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 24
            return path.applying(
                CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
        }
    }

    private static let marks: [String: Mark] = [
        // Claude Code's terminal figure, in Claude's coral.
        "claude": Mark(
            name: "Claude Code",
            outline: "M21 10.5h3v3h-3v3h-1.5v3H18v-3h-1.5v3H15v-3H9v3H7.5v-3H6v3H4.5v-3H3v-3H0v-3h3v-6h18Zm-15 0h1.5v-3H6Zm10.5 0H18v-3h-1.5z",
            tint: Color(red: 0.851, green: 0.467, blue: 0.341)),
        // Codex's cloud with its prompt.
        "codex": Mark(
            name: "Codex",
            outline: "M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z",
            tint: nil),
    ]
}

/// An SVG path's `d` as a SwiftUI `Path`: the commands a mark's outline
/// uses (move, line, horizontal, vertical, cubic, smooth cubic, quadratic,
/// arc, close; absolute and relative), numbers packed as SVG allows
/// (`.117.117`, `013.046` after an arc's two flags). A command it does not
/// know stops the outline there and traps in a debug build: a mark is
/// data checked once, never input.
enum SVGOutline {
    static func path(_ d: String) -> Path {
        var path = Path()
        var reader = Reader(Array(d.utf8))
        var command: UInt8 = 0
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?

        while reader.skipSpace() {
            if reader.atCommand { command = reader.takeByte() }
            let relative = command >= UInt8(ascii: "a")
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                current = point(reader.number(), reader.number())
                start = current
                path.move(to: current)
                // Further pairs after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
                lastControl = nil
            case UInt8(ascii: "l"):
                current = point(reader.number(), reader.number())
                path.addLine(to: current)
                lastControl = nil
            case UInt8(ascii: "h"):
                let x = reader.number()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case UInt8(ascii: "v"):
                let y = reader.number()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case UInt8(ascii: "c"):
                let a = point(reader.number(), reader.number())
                let b = point(reader.number(), reader.number())
                let end = point(reader.number(), reader.number())
                path.addCurve(to: end, control1: a, control2: b)
                lastControl = b
                current = end
            case UInt8(ascii: "s"):
                let a = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let b = point(reader.number(), reader.number())
                let end = point(reader.number(), reader.number())
                path.addCurve(to: end, control1: a, control2: b)
                lastControl = b
                current = end
            case UInt8(ascii: "q"):
                let a = point(reader.number(), reader.number())
                let end = point(reader.number(), reader.number())
                path.addQuadCurve(to: end, control: a)
                lastControl = nil
                current = end
            case UInt8(ascii: "a"):
                let rx = reader.number(), ry = reader.number(), turn = reader.number()
                let large = reader.flag(), sweep = reader.flag()
                let end = point(reader.number(), reader.number())
                arc(&path, from: current, to: end, rx: rx, ry: ry, degrees: turn, large: large, sweep: sweep)
                lastControl = nil
                current = end
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                assertionFailure("SVGOutline: command \(UnicodeScalar(command)) is not drawn")
                return path
            }
        }
        return path
    }

    /// An elliptical arc by its endpoints (SVG 1.1, F.6.5), as SwiftUI's
    /// arc on the unit circle under the ellipse's transform.
    private static func arc(
        _ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, degrees: CGFloat, large: Bool,
        sweep: Bool
    ) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { return path.addLine(to: p1) }
        let phi = degrees * .pi / 180
        let (cosPhi, sinPhi) = (cos(phi), sin(phi))
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        // Radii too small to span the endpoints are scaled up to just reach.
        let reach = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if reach > 1 {
            rx *= sqrt(reach)
            ry *= sqrt(reach)
        }
        let top = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let bottom = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let factor = (large == sweep ? -1 : 1) * sqrt(max(0, top / bottom))
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let center = CGPoint(
            x: cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2, y: sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2)
        let from = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
        let to = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx)
        let ellipse = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: phi).scaledBy(x: rx, y: ry)
        // SwiftUI's `clockwise` is named for a y-up plane: in a view's
        // y-down one, SVG's sweep (increasing angle) is `clockwise: false`.
        path.addArc(
            center: .zero, radius: 1, startAngle: .radians(from), endAngle: .radians(to), clockwise: !sweep,
            transform: ellipse)
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        /// Past spaces and commas; false at the end.
        mutating func skipSpace() -> Bool {
            while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x2C || bytes[at] == 0x0A || bytes[at] == 0x09 { at += 1 }
            return at < bytes.count
        }
        var atCommand: Bool {
            let byte = bytes[at] | 0x20
            return byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") && byte != UInt8(ascii: "e")
        }
        mutating func takeByte() -> UInt8 {
            defer { at += 1 }
            return bytes[at]
        }
        /// An arc's flag: one character, `0` or `1`, with or without a
        /// separator after it.
        mutating func flag() -> Bool {
            _ = skipSpace()
            guard at < bytes.count else { return false }
            return takeByte() == UInt8(ascii: "1")
        }
        /// One number: a sign, digits, one point, digits, an exponent. A
        /// second point or a sign begins the next number.
        mutating func number() -> CGFloat {
            _ = skipSpace()
            let begin = at
            var seenPoint = false
            if at < bytes.count, bytes[at] == UInt8(ascii: "-") || bytes[at] == UInt8(ascii: "+") { at += 1 }
            while at < bytes.count {
                let byte = bytes[at]
                if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                    at += 1
                } else if byte == UInt8(ascii: "."), !seenPoint {
                    seenPoint = true
                    at += 1
                } else if byte | 0x20 == UInt8(ascii: "e"), at + 1 < bytes.count {
                    at += 1
                    if bytes[at] == UInt8(ascii: "-") || bytes[at] == UInt8(ascii: "+") { at += 1 }
                } else {
                    break
                }
            }
            let text = String(decoding: bytes[begin..<at], as: UTF8.self)
            guard let value = Double(text) else {
                assertionFailure("SVGOutline: not a number at \(begin): \(text)")
                // Never loop on what is not a number.
                if at == begin { at += 1 }
                return 0
            }
            return CGFloat(value)
        }
    }
}
