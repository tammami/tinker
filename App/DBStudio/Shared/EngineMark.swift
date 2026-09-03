import DBCore
import SwiftUI

/// The badge that tells a PostgreSQL connection from a MySQL one at a glance.
///
/// The marks are drawn here rather than shipped as vendor artwork: the logos are
/// trademarks and are not ours to bundle. What each engine is known by — the elephant and
/// the dolphin, in that project's own colour — is enough to read the row without
/// reproducing anyone's logo (DECISIONS.md ADR-0026).
struct EngineMark: View {
    let dialect: SQLDialect
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Self.plate(for: dialect))
            mark
                .frame(width: size * 0.66, height: size * 0.66)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Self.name(for: dialect))
    }

    @ViewBuilder
    private var mark: some View {
        switch dialect {
        case .postgresql: ElephantMark().fill(Color.white)
        case .mysql: DolphinMark().fill(Color.white)
        }
    }

    /// Each engine's own colour, so the badge is recognisable before the shape is.
    static func plate(for dialect: SQLDialect) -> Color {
        switch dialect {
        // PostgreSQL's slate blue.
        case .postgresql: Color(red: 0.20, green: 0.40, blue: 0.57)
        // MySQL's teal.
        case .mysql: Color(red: 0.00, green: 0.46, blue: 0.56)
        }
    }

    static func name(for dialect: SQLDialect) -> String {
        switch dialect {
        case .postgresql: "PostgreSQL"
        case .mysql: "MySQL"
        }
    }
}

/// An elephant's head: a broad dome, an ear either side, and a thick trunk.
///
/// Deliberately coarse. At sixteen points a faithful silhouette turns to mush, so the
/// features are few and large enough to survive the size the sidebar draws it at.
private struct ElephantMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        // Head: a dome across the top two thirds.
        path.move(to: p(0.14, 0.62))
        path.addCurve(to: p(0.86, 0.62), control1: p(0.14, 0.02), control2: p(0.86, 0.02))
        path.addLine(to: p(0.68, 0.62))
        path.addLine(to: p(0.32, 0.62))
        path.closeSubpath()
        // Ears: one bump either side, sitting below the widest part of the dome.
        path.addEllipse(in: CGRect(
            x: rect.minX, y: rect.minY + h * 0.30, width: w * 0.26, height: h * 0.40
        ))
        path.addEllipse(in: CGRect(
            x: rect.minX + w * 0.74, y: rect.minY + h * 0.30, width: w * 0.26, height: h * 0.40
        ))
        // Trunk: straight down the middle, thick enough to stay visible.
        path.addRoundedRect(
            in: CGRect(x: rect.minX + w * 0.38, y: rect.minY + h * 0.52,
                       width: w * 0.24, height: h * 0.48),
            cornerSize: CGSize(width: w * 0.12, height: w * 0.12)
        )
        return path
    }
}

/// A dolphin: a crescent body with one dorsal fin and a forked tail.
private struct DolphinMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        // Body: nose low left, arching over to the tail low right.
        path.move(to: p(0.00, 0.78))
        path.addCurve(to: p(0.62, 0.22), control1: p(0.12, 0.44), control2: p(0.36, 0.22))
        // Dorsal fin.
        path.addLine(to: p(0.60, 0.00))
        path.addLine(to: p(0.80, 0.30))
        // Tail fluke.
        path.addLine(to: p(1.00, 0.44))
        path.addLine(to: p(0.88, 0.72))
        path.addLine(to: p(1.00, 0.98))
        path.addLine(to: p(0.72, 0.80))
        // Belly back to the nose.
        path.addCurve(to: p(0.00, 0.78), control1: p(0.46, 0.98), control2: p(0.18, 0.94))
        path.closeSubpath()
        return path
    }
}
