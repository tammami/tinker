import DBCore
import SwiftUI

/// What a first-run choice asks the workspace to do once the welcome window has closed.
///
/// The window only records the choice: each one presents a sheet or a modal open panel on
/// the workspace window, and neither should start while the welcome window is in front.
enum FirstRunAction: Equatable {
    case addConnection
    case openSQLite
    case restoreBackup
}

/// The welcome window, shown the first time Tinker launches with no connections.
///
/// A window of its own rather than a `SheetFrame`: this is the one moment the app speaks
/// as a brand instead of as a tool, so it is drawn in the icon's world (`DesignTokens.Brand`)
/// — the penguin on a polar night, low-poly facets like its own, an aurora drifting behind.
/// The content stays straight to the point: the three ways in, one click each, then what
/// the app promises about passwords and writes, then the diagnostics opt-in.
struct FirstRunView: View {
    /// The scene id `openWindow` uses.
    static let windowID = "welcome"
    /// The setting that records the welcome has been seen.
    static let seenSettingKey = "firstRun.seen"

    let environment: AppEnvironment
    let crashReporter: CrashReporter

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var choice: FirstRunAction?
    @State private var collectDiagnostics = false
    /// Drives the entrance: the hero resolves out of a blur, then the rest settles in.
    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 0) {
            hero
            tiles
                .padding(.top, DesignTokens.Spacing.xl + DesignTokens.Spacing.xs)
            promises
                .padding(.top, DesignTokens.Spacing.xl)
            Spacer(minLength: DesignTokens.Spacing.lg)
            footer
        }
        .padding(.horizontal, DesignTokens.Spacing.xl * 2)
        .frame(width: DesignTokens.Brand.welcomeWidth, height: DesignTokens.Brand.welcomeHeight)
        // The night runs under the hidden title bar too; the content stays below it.
        .background { PolarNight(isRevealed: isRevealed, reduceMotion: reduceMotion) }
        // The brand world is a night scene whatever the system appearance, so the native
        // controls on it (checkbox, button, key caps) take their dark forms.
        .environment(\.colorScheme, .dark)
        .task {
            // A window restored from an earlier session must not greet twice.
            let seen = await environment.setting(Self.seenSettingKey, default: false)
            if seen, !UIDemo.wantsFirstRun {
                dismissWindow(id: Self.windowID)
                return
            }
            collectDiagnostics = await environment.setting(CrashReporter.optInSettingKey, default: false)
            if reduceMotion {
                isRevealed = true
            } else {
                withAnimation(.spring(response: 1.1, dampingFraction: 0.82)) { isRevealed = true }
            }
        }
        .onDisappear(perform: finish)
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ZStack {
                // The ice it stands on: a soft pool of light under its feet.
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [DesignTokens.Brand.ice.opacity(0.28), .clear],
                            center: .center, startRadius: 0, endRadius: DesignTokens.Brand.heroIcon * 0.5)
                    )
                    .frame(width: DesignTokens.Brand.heroIcon * 1.1, height: DesignTokens.Brand.heroIcon * 0.22)
                    .offset(y: DesignTokens.Brand.heroIcon * 0.46)
                    .opacity(isRevealed ? 1 : 0)
                // Its own light, blooming as it resolves.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [DesignTokens.Brand.glacier.opacity(0.42), .clear],
                            center: .center, startRadius: 0,
                            endRadius: DesignTokens.Brand.heroIcon * 1.2)
                    )
                    .frame(width: DesignTokens.Brand.heroIcon * 2.4, height: DesignTokens.Brand.heroIcon * 2.4)
                    .opacity(isRevealed ? 1 : 0)
                    .scaleEffect(isRevealed ? 1 : 0.6)
                // The icon's penguin without its plate, so it stands in the scene itself
                // (the system may draw the app icon tinted or in its dark variant).
                Image("WelcomePenguin")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: DesignTokens.Brand.heroIcon, height: DesignTokens.Brand.heroIcon)
                    .shadow(color: DesignTokens.Brand.midnight.opacity(0.7), radius: 10, y: 8)
                    .blur(radius: isRevealed ? 0 : 14)
                    .scaleEffect(isRevealed ? 1 : 0.86)
                    .offset(y: isRevealed ? 0 : DesignTokens.Spacing.md)
                    .opacity(isRevealed ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(height: DesignTokens.Brand.heroIcon)

            Text("Welcome to \(Product.name)")
                .font(.system(size: DesignTokens.Typography.display, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(.white)
                .padding(.top, DesignTokens.Spacing.sm)
            Text("\(Product.tagline). PostgreSQL, MySQL, MariaDB and SQLite, native on your Mac.")
                .font(.system(size: DesignTokens.Typography.lede))
                .foregroundStyle(DesignTokens.Brand.ice.opacity(0.72))
                .multilineTextAlignment(.center)
        }
        .settling(isRevealed, order: 0, reduceMotion: reduceMotion)
    }

    private var tiles: some View {
        HStack(spacing: DesignTokens.Spacing.md + 2) {
            StartTile(
                title: "Connect to a server",
                detail: "Local or remote, directly, over TLS or through an SSH tunnel.",
                isPrimary: true,
                action: { choose(.addConnection) }
            ) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    EngineMark(dialect: .postgresql, size: DesignTokens.Brand.tileBadge)
                    EngineMark(dialect: .mysql, size: DesignTokens.Brand.tileBadge)
                    EngineMark(dialect: .mysql, flavor: .mariadb, size: DesignTokens.Brand.tileBadge)
                }
            }
            .keyboardShortcut(.defaultAction)
            .settling(isRevealed, order: 1, reduceMotion: reduceMotion)

            StartTile(
                title: "Open a SQLite file",
                detail: "Browse to a .sqlite or .db file, or drop one on the window later.",
                action: { choose(.openSQLite) }
            ) {
                EngineMark(dialect: .sqlite, size: DesignTokens.Brand.tileBadge)
            }
            .settling(isRevealed, order: 2, reduceMotion: reduceMotion)

            StartTile(
                title: "Restore a backup",
                detail: "Moving from another Mac? Bring your connections from a .think file.",
                action: { choose(.restoreBackup) }
            ) {
                Image(systemName: Icon.restore)
                    .font(.system(size: DesignTokens.Typography.lede, weight: .semibold))
                    .foregroundStyle(DesignTokens.Brand.ice)
                    .frame(width: DesignTokens.Brand.tileBadge, height: DesignTokens.Brand.tileBadge)
                    .background {
                        RoundedRectangle(cornerRadius: DesignTokens.Brand.tileBadge * 0.26, style: .continuous)
                            .fill(.white.opacity(0.1))
                    }
            }
            .settling(isRevealed, order: 3, reduceMotion: reduceMotion)
        }
        // Tiles keep their own height; the window's spare room goes below the promises.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The three promises a database client owes before it asks for a password.
    private var promises: some View {
        HStack(spacing: DesignTokens.Spacing.xl) {
            promise(Icon.key, "Passwords stay in your Keychain")
            promise(Icon.shield, "Every change shown as SQL first")
            promise(Icon.production, "Production asks before it writes")
        }
        .settling(isRevealed, order: 4, reduceMotion: reduceMotion)
    }

    private func promise(_ icon: String, _ text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs + 2) {
            Image(systemName: icon)
                .foregroundStyle(DesignTokens.Brand.glacier)
            Text(text)
                .foregroundStyle(DesignTokens.Brand.ice.opacity(0.7))
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            KeyHint(keys: "⌘K", label: "Commands")
            KeyHint(keys: "⌘⇧O", label: "Find a table")
            KeyHint(keys: "⌘R", label: "Run")
            Spacer(minLength: DesignTokens.Spacing.md)
            Toggle("Keep crash reports on this Mac, never sent", isOn: $collectDiagnostics)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(DesignTokens.Brand.ice.opacity(0.7))
                .help("Written to Application Support. Change it any time in Settings.")
                .onChange(of: collectDiagnostics) { _, value in
                    Task { await crashReporter.setEnabled(value) }
                }
            Button("Later") { choose(nil) }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
        .padding(.vertical, DesignTokens.Spacing.lg)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
        .settling(isRevealed, order: 5, reduceMotion: reduceMotion)
    }

    // MARK: - Choices

    private func choose(_ action: FirstRunAction?) {
        choice = action
        dismissWindow(id: Self.windowID)
    }

    /// Runs when the window goes, however it went (a tile, Later, Esc or the close button):
    /// marks the welcome seen, then hands the choice to the frontmost workspace.
    private func finish() {
        // A demo run shows the welcome on a store that is not a first run; leave it be.
        if !UIDemo.wantsFirstRun {
            Task { await environment.setSetting(true, for: Self.seenSettingKey) }
        }
        guard let action = choice, let controller = CommandCenter.shared.current else { return }
        choice = nil
        switch action {
        case .addConnection: controller.workspace.presentNewConnection()
        case .openSQLite: controller.openSQLiteDatabase()
        case .restoreBackup: controller.chooseConnectionBackup()
        }
    }
}

// MARK: - Start tile

/// One way in: a tall tile with the engines it opens on top, lifting toward the pointer.
private struct StartTile<Badge: View>: View {
    let title: String
    let detail: String
    var isPrimary = false
    let action: () -> Void
    @ViewBuilder let badge: Badge

    @State private var isHovered = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Brand.tileCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                badge
                Spacer(minLength: DesignTokens.Spacing.md)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Brand.ice.opacity(0.66))
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DesignTokens.Spacing.xs)
                HStack(spacing: DesignTokens.Spacing.xs + 2) {
                    if isPrimary {
                        KeyCap(keys: "↩")
                        Text("Return").font(.caption2).foregroundStyle(DesignTokens.Brand.ice.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: Icon.nextPage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isHovered || isPrimary ? DesignTokens.Brand.glacier : .white.opacity(0.35))
                        .offset(x: isHovered ? DesignTokens.Spacing.xs - 1 : 0)
                }
                .frame(height: DesignTokens.Metrics.iconWidth)
                .padding(.top, DesignTokens.Spacing.md)
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Brand.tileHeight, alignment: .topLeading)
            .background { shape.fill(fill) }
            .overlay { shape.strokeBorder(border, lineWidth: 1) }
            .contentShape(shape)
            .shadow(
                color: DesignTokens.Brand.midnight.opacity(isHovered ? 0.55 : 0.3),
                radius: isHovered ? 22 : 12, y: isHovered ? 14 : 8
            )
            .offset(y: isHovered ? -3 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(detail)
    }

    private var fill: some ShapeStyle {
        LinearGradient(
            colors: isPrimary
                ? [DesignTokens.Brand.cobalt.opacity(isHovered ? 0.5 : 0.38), DesignTokens.Brand.navy.opacity(0.5)]
                : [.white.opacity(isHovered ? 0.11 : 0.065), .white.opacity(isHovered ? 0.05 : 0.025)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var border: some ShapeStyle {
        LinearGradient(
            colors: isPrimary
                ? [DesignTokens.Brand.glacier.opacity(0.9), DesignTokens.Brand.cobalt.opacity(0.35)]
                : [.white.opacity(isHovered ? 0.3 : 0.16), .white.opacity(0.04)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Backdrop

/// The polar night behind the welcome: a deep gradient, an aurora, and a field of low-poly
/// facets that a single glint crosses as the window opens.
///
/// Everything is still once the glint has passed. An aurora drifting forever looked alive
/// but cost a third of a core for as long as the window stayed open, and the app is held
/// to being cheap at rest.
private struct PolarNight: View {
    let isRevealed: Bool
    let reduceMotion: Bool

    @State private var glintCrossed = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [DesignTokens.Brand.navy, DesignTokens.Brand.midnight],
                            startPoint: .top, endPoint: .bottom)
                    )

                aurora(in: size)

                FacetField(edgesOnly: false)
                    .mask(facetMask)
                    .opacity(isRevealed ? 1 : 0)

                // The glint: a band of light that runs across the facet edges once.
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, DesignTokens.Brand.ice.opacity(0.9), .clear],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: size.width * 0.22)
                    .rotationEffect(.degrees(18))
                    .offset(x: glintCrossed ? size.width * 0.75 : -size.width * 0.75)
                    .frame(width: size.width, height: size.height)
                    .mask(FacetField(edgesOnly: true).mask(facetMask))
                    .opacity(reduceMotion ? 0 : 1)
            }
        }
        .drawingGroup()
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.6).delay(0.45)) { glintCrossed = true }
        }
    }

    /// Facets are brightest behind the penguin and fade out before the tiles.
    private var facetMask: some View {
        RadialGradient(
            colors: [.white, .white.opacity(0.35), .clear],
            center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0, endRadius: 460)
    }

    private func aurora(in size: CGSize) -> some View {
        ZStack {
            glow(DesignTokens.Brand.cobalt, 0.55, diameter: 640)
                .offset(x: -size.width * 0.3, y: -size.height * 0.34)
            glow(DesignTokens.Brand.glacier, 0.32, diameter: 520)
                .offset(x: size.width * 0.3, y: -size.height * 0.28)
            glow(DesignTokens.Brand.beak, 0.1, diameter: 380)
                .offset(x: size.width * 0.42, y: size.height * 0.42)
            glow(DesignTokens.Brand.cobalt, 0.22, diameter: 460)
                .offset(x: -size.width * 0.4, y: size.height * 0.4)
        }
        .frame(width: size.width, height: size.height)
    }

    /// A soft oval of light. Drawn on a rectangle, not a circle, so the gradient fades out
    /// completely instead of being cut off at the shape's edge.
    private func glow(_ color: Color, _ strength: Double, diameter: CGFloat) -> some View {
        Rectangle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(strength), color.opacity(strength * 0.3), .clear],
                    center: .center, startRadius: 0, endRadius: diameter / 2)
            )
            .frame(width: diameter, height: diameter)
            .scaleEffect(x: 1, y: 0.7)
    }
}

/// A low-poly triangle mesh, like the penguin's own facets, drawn once from a fixed seed so
/// it never shifts between launches.
private struct FacetField: View {
    /// Edges only is the glint's stencil; otherwise faintly shaded faces with hairline edges.
    let edgesOnly: Bool

    var body: some View {
        Canvas { context, size in
            for facet in Self.facets {
                var path = Path()
                path.move(to: CGPoint(x: facet.a.x * size.width, y: facet.a.y * size.height))
                path.addLine(to: CGPoint(x: facet.b.x * size.width, y: facet.b.y * size.height))
                path.addLine(to: CGPoint(x: facet.c.x * size.width, y: facet.c.y * size.height))
                path.closeSubpath()
                if edgesOnly {
                    context.stroke(path, with: .color(.white), lineWidth: 1.2)
                } else {
                    context.fill(path, with: .color(.white.opacity(0.012 + facet.shade * 0.05)))
                    context.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
                }
            }
        }
    }

    private struct Facet {
        let a: CGPoint
        let b: CGPoint
        let c: CGPoint
        let shade: Double
    }

    private static let facets: [Facet] = mesh(columns: 12, rows: 8)

    /// A jittered grid split into triangles, in unit coordinates. Border points stay on the
    /// border so the mesh always covers the whole window.
    private static func mesh(columns: Int, rows: Int) -> [Facet] {
        var points: [[CGPoint]] = []
        for row in 0 ... rows {
            var line: [CGPoint] = []
            for column in 0 ... columns {
                let jitterX = column == 0 || column == columns ? 0 : (noise(column, row, 1) - 0.5) * 0.75
                let jitterY = row == 0 || row == rows ? 0 : (noise(column, row, 2) - 0.5) * 0.75
                line.append(
                    CGPoint(
                        x: (Double(column) + jitterX) / Double(columns),
                        y: (Double(row) + jitterY) / Double(rows)))
            }
            points.append(line)
        }
        var facets: [Facet] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let topLeft = points[row][column]
                let topRight = points[row][column + 1]
                let bottomLeft = points[row + 1][column]
                let bottomRight = points[row + 1][column + 1]
                let first = noise(column, row, 3)
                let second = noise(column, row, 4)
                if (row + column).isMultiple(of: 2) {
                    facets.append(Facet(a: topLeft, b: topRight, c: bottomRight, shade: first))
                    facets.append(Facet(a: topLeft, b: bottomRight, c: bottomLeft, shade: second))
                } else {
                    facets.append(Facet(a: topLeft, b: topRight, c: bottomLeft, shade: first))
                    facets.append(Facet(a: topRight, b: bottomRight, c: bottomLeft, shade: second))
                }
            }
        }
        return facets
    }

    /// A stable value in 0..<1 for a grid point and a channel.
    private static func noise(_ x: Int, _ y: Int, _ channel: Int) -> Double {
        var value = UInt64(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663 ^ channel &* 83_492_791)
        value ^= value >> 33
        value &*= 0xff51_afd7_ed55_8ccd
        value ^= value >> 33
        return Double(value % 10_000) / 10_000
    }
}

// MARK: - Entrance

extension View {
    /// Rises a few points into place after the hero, in `order`; still with Reduce Motion.
    fileprivate func settling(_ isRevealed: Bool, order: Int, reduceMotion: Bool) -> some View {
        opacity(isRevealed ? 1 : 0)
            .offset(y: isRevealed || reduceMotion ? 0 : DesignTokens.Spacing.sm)
            .animation(
                reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.86).delay(0.12 + Double(order) * 0.06),
                value: isRevealed)
    }
}
