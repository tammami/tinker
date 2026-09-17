import DBCore
import SwiftUI

/// The badge that tells a PostgreSQL connection from a MySQL or SQLite one at a glance.
///
/// The marks are drawn here rather than shipped as vendor artwork: the logos are
/// trademarks and are not ours to bundle. What each engine is known by — the elephant and
/// the dolphin, the feather — in that project's own colour, is enough to read the row
/// without reproducing anyone's logo (DECISIONS.md ADR-0026).
struct EngineMark: View {
    let dialect: SQLDialect
    /// MySQL and MariaDB share a dialect; only a live server says which. Nil until it has.
    var flavor: ServerFlavor?
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Self.plate(for: dialect, flavor: flavor))
            mark
                .frame(width: size * 0.66, height: size * 0.66)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Self.name(for: dialect, flavor: flavor))
    }

    private var isMariaDB: Bool { flavor == .mariadb }

    @ViewBuilder
    private var mark: some View {
        switch dialect {
        case .postgresql: ElephantMark().fill(Color.white)
        case .mysql: isMariaDB ? AnyView(SealMark().fill(Color.white)) : AnyView(DolphinMark().fill(Color.white))
        case .sqlite: FeatherMark().fill(Color.white)
        }
    }

    /// Each engine's own colour, so the badge is recognisable before the shape is.
    static func plate(for dialect: SQLDialect, flavor: ServerFlavor? = nil) -> Color {
        switch dialect {
        // PostgreSQL's slate blue.
        case .postgresql: Color(red: 0.20, green: 0.40, blue: 0.57)
        // MySQL's teal, and MariaDB's navy.
        case .mysql:
            flavor == .mariadb
                ? Color(red: 0.11, green: 0.20, blue: 0.40) : Color(red: 0.00, green: 0.46, blue: 0.56)
        // SQLite's steel blue, darkened so white reads on it.
        case .sqlite: Color(red: 0.24, green: 0.44, blue: 0.62)
        }
    }

    static func name(for dialect: SQLDialect, flavor: ServerFlavor? = nil) -> String {
        switch dialect {
        case .postgresql: "PostgreSQL"
        case .mysql: flavor == .mariadb ? "MariaDB" : "MySQL"
        case .sqlite: "SQLite"
        }
    }
}

/// Slonik: two broad ears held off the head by a gap, a brow between them, and a trunk
/// down the middle. Three disjoint pieces, so the plate shows through where the real mark
/// draws its white lines — that separation is what makes it an elephant and not a blob at
/// sixteen points.
private struct ElephantMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        path.move(to: p(0.42, 0.10))
        path.addCurve(to: p(0.02, 0.30), control1: p(0.22, 0.02), control2: p(0.02, 0.10))
        path.addCurve(to: p(0.14, 0.64), control1: p(0.02, 0.48), control2: p(0.04, 0.60))
        path.addCurve(to: p(0.38, 0.58), control1: p(0.26, 0.68), control2: p(0.35, 0.66))
        path.addCurve(to: p(0.42, 0.10), control1: p(0.33, 0.42), control2: p(0.35, 0.18))
        path.closeSubpath()
        path.move(to: p(0.58, 0.10))
        path.addCurve(to: p(0.98, 0.30), control1: p(0.78, 0.02), control2: p(0.98, 0.10))
        path.addCurve(to: p(0.86, 0.64), control1: p(0.98, 0.48), control2: p(0.96, 0.60))
        path.addCurve(to: p(0.62, 0.58), control1: p(0.74, 0.68), control2: p(0.65, 0.66))
        path.addCurve(to: p(0.58, 0.10), control1: p(0.67, 0.42), control2: p(0.65, 0.18))
        path.closeSubpath()
        path.move(to: p(0.50, 0.02))
        path.addCurve(to: p(0.60, 0.52), control1: p(0.58, 0.08), control2: p(0.61, 0.30))
        path.addCurve(to: p(0.62, 0.94), control1: p(0.60, 0.68), control2: p(0.63, 0.84))
        path.addCurve(to: p(0.38, 0.94), control1: p(0.60, 1.03), control2: p(0.40, 1.03))
        path.addCurve(to: p(0.40, 0.52), control1: p(0.37, 0.84), control2: p(0.40, 0.68))
        path.addCurve(to: p(0.50, 0.02), control1: p(0.39, 0.30), control2: p(0.42, 0.08))
        path.closeSubpath()
        return path
    }
}

/// A dolphin leaping: head high on the left, back arching down to a forked fluke.
private struct DolphinMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        path.move(to: p(0.06, 0.16))
        path.addCurve(to: p(0.30, 0.06), control1: p(0.10, 0.06), control2: p(0.20, 0.02))
        path.addCurve(to: p(0.62, 0.44), control1: p(0.46, 0.12), control2: p(0.56, 0.28))
        path.addCurve(to: p(0.86, 0.66), control1: p(0.70, 0.54), control2: p(0.78, 0.60))
        path.addLine(to: p(1.00, 0.56))
        path.addLine(to: p(0.92, 0.78))
        path.addLine(to: p(1.00, 1.00))
        path.addLine(to: p(0.74, 0.84))
        path.addCurve(to: p(0.40, 0.56), control1: p(0.60, 0.78), control2: p(0.48, 0.68))
        path.addLine(to: p(0.28, 0.70))
        path.addLine(to: p(0.26, 0.46))
        path.addCurve(to: p(0.06, 0.16), control1: p(0.14, 0.40), control2: p(0.06, 0.28))
        path.closeSubpath()
        return path
    }
}

/// MariaDB's sea lion: head up at the top right, body sloping away to the left, flippers.
private struct SealMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        path.move(to: p(0.92, 0.02))
        path.addCurve(to: p(0.74, 0.22), control1: p(0.80, 0.02), control2: p(0.74, 0.10))
        path.addCurve(to: p(0.70, 0.46), control1: p(0.74, 0.32), control2: p(0.72, 0.40))
        path.addCurve(to: p(0.34, 0.66), control1: p(0.60, 0.56), control2: p(0.46, 0.60))
        path.addCurve(to: p(0.02, 0.86), control1: p(0.20, 0.72), control2: p(0.06, 0.80))
        path.addLine(to: p(0.18, 0.94))
        path.addLine(to: p(0.04, 1.00))
        path.addCurve(to: p(0.52, 0.86), control1: p(0.22, 1.00), control2: p(0.40, 0.94))
        path.addLine(to: p(0.72, 1.00))
        path.addLine(to: p(0.78, 0.76))
        path.addCurve(to: p(0.86, 0.46), control1: p(0.86, 0.68), control2: p(0.88, 0.58))
        path.addCurve(to: p(0.92, 0.02), control1: p(0.84, 0.30), control2: p(0.86, 0.12))
        path.closeSubpath()
        return path
    }
}

/// A feather: a quill rising from the lower left, its vane swept to the upper right.
private struct FeatherMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        path.move(to: p(0.96, 0.04))
        path.addCurve(to: p(0.26, 0.74), control1: p(0.99, 0.46), control2: p(0.68, 0.76))
        path.addCurve(to: p(0.96, 0.04), control1: p(0.22, 0.28), control2: p(0.56, 0.02))
        path.closeSubpath()
        path.move(to: p(0.30, 0.64))
        path.addLine(to: p(0.40, 0.72))
        path.addLine(to: p(0.06, 1.00))
        path.addLine(to: p(0.00, 0.92))
        path.closeSubpath()
        return path
    }
}
