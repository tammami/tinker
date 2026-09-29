import AppKit
import DBCore
import DBGrid
import MapKit
import SwiftUI

/// The places a grid holds: geometry columns, latitude/longitude pairs and combined
/// coordinate columns, found from a few sampled rows.
@MainActor
enum MapSources {
    static func detect(in grid: GridModel, dialect: SQLDialect) -> [MapSource] {
        MapSourceDetector.detect(columns: grid.columns, rowCount: grid.rowCount, dialect: dialect) { row, column in
            grid.value(row: row, column: column)
        }
    }

    /// What a right-click on `column` means: the source reading that column, else the first.
    static func source(for column: Int, in grid: GridModel) -> MapSource? {
        MapSourceDetector.source(for: column, among: detect(in: grid, dialect: grid.dialect))
    }

    static func columnNames(_ grid: GridModel) -> [String] { grid.columns.map(\.name) }
}

/// A request from the grid to put one row's location on the map.
public struct MapRequest: Equatable, Sendable {
    public let row: Int
    public let source: MapSource
    /// Distinguishes two requests for the same cell, so the second still switches panes.
    let token = UUID()

    public init(row: Int, source: MapSource) {
        self.row = row
        self.source = source
    }
}

/// Opening a place outside Tinker, or copying where it is. Only ever on the user's click:
/// the coordinates leave the app only when asked to.
enum MapLinks {
    static func appleMaps(_ point: GeoPoint, title: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        var items = [URLQueryItem(name: "ll", value: coordinate(point))]
        if let title, !title.isEmpty { items.append(URLQueryItem(name: "q", value: title)) }
        components.queryItems = items
        return components.url
    }

    static func googleMaps(_ point: GeoPoint) -> URL? {
        var components = URLComponents(string: "https://www.google.com/maps/search/")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: coordinate(point)),
        ]
        return components?.url
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Seven decimals is about a centimetre: all a link can use.
    private static func coordinate(_ point: GeoPoint) -> String {
        String(format: "%.7f,%.7f", point.latitude, point.longitude)
    }
}

/// The map: every loaded row's location from one source — or just the rows asked for —
/// drawn where it belongs, with points clustered and the view fitted to the whole.
///
/// Rows are read from the grid model, never copied: what the map holds are the shapes,
/// converted once per revision, and capped so a table of a million places cannot take
/// the app down with it.
struct MapPaneView: View {
    let grid: GridModel
    let dialect: SQLDialect
    let revision: Int
    @Binding var source: MapSource
    let sources: [MapSource]
    /// The rows on the map; nil is every loaded row.
    @Binding var rows: Set<Int>?
    let onSelectRow: (Int) -> Void

    static let featureCap = 5_000

    @State private var summary = MapSummary()

    var body: some View {
        let names = MapSources.columnNames(grid)
        VStack(spacing: 0) {
            PaneBar {
                Label("Map", systemImage: Icon.map).font(.caption.weight(.semibold))
                if sources.count > 1 {
                    Picker("Location", selection: $source) {
                        ForEach(sources, id: \.self) { source in
                            Text(source.title(columnNames: names)).tag(source)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                } else {
                    Text(source.title(columnNames: names)).font(.caption).foregroundStyle(.secondary)
                }
                if case .pair(_, _, true) = source {
                    Badge(text: "SWAPPED", color: .orange)
                        .help(
                            "The column named latitude holds longitudes and the other the latitudes; the map reads them the right way round."
                        )
                }
                if let rows {
                    Badge(
                        text: rows.count == 1 ? "ROW \((rows.first ?? 0) + 1) ONLY" : "\(rows.count) ROWS ONLY",
                        color: .accentColor)
                    Button("Show All") { self.rows = nil }
                        .help("Put every loaded row back on the map")
                }
                Spacer()
                if summary.unplaceable > 0 {
                    Label(
                        "\(summary.unplaceable) not on the map — their SRID is not longitude/latitude; use ST_Transform(…, 4326)",
                        systemImage: Icon.warning
                    )
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
                if summary.outOfRange > 0 {
                    Label("\(summary.outOfRange) out of range", systemImage: Icon.warning)
                        .font(.caption).foregroundStyle(.orange).lineLimit(1)
                        .help("Latitude beyond ±90° or longitude beyond ±180°, so these rows have no place on the map")
                }
                if summary.unreadable > 0 {
                    Label("\(summary.unreadable) unreadable", systemImage: Icon.warning)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help("Values that are neither coordinates nor a geometry, or only half of a pair")
                }
                Text(
                    summary.capped
                        ? "First \(Self.featureCap.formatted()) on the map" : "\(summary.placed) on the map"
                )
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .controlSize(.small)
            Divider()
            MapCanvas(
                grid: grid, dialect: dialect, revision: revision, source: source, rows: rows,
                onSelectRow: onSelectRow, summary: $summary
            )
            .clipped()
        }
        // The window's title bar takes its backdrop from what scrolls beneath it; a map
        // would tint it, so the bar keeps its own background while the map is up.
        .toolbarBackground(.visible, for: .windowToolbar)
    }
}

struct MapSummary: Equatable {
    var placed = 0
    var unplaceable = 0
    var unreadable = 0
    var outOfRange = 0
    var capped = false
}

/// The `MKMapView`, rebuilt only when the grid's revision or the chosen source changes.
struct MapCanvas: NSViewRepresentable {
    let grid: GridModel
    let dialect: SQLDialect
    let revision: Int
    let source: MapSource
    let rows: Set<Int>?
    let onSelectRow: (Int) -> Void
    @Binding var summary: MapSummary

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsZoomControls = true
        map.showsScale = true
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "row")
        map.register(
            MKAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        context.coordinator.map = map
        context.coordinator.onSelectRow = onSelectRow
        context.coordinator.reload(
            grid: grid, dialect: dialect, source: source, rows: rows, revision: revision, summary: $summary)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelectRow = onSelectRow
        context.coordinator.reload(
            grid: grid, dialect: dialect, source: source, rows: rows, revision: revision, summary: $summary)
    }

    func makeCoordinator() -> MapCoordinator { MapCoordinator() }
}

/// A map pin that remembers which grid row it came from.
final class RowAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let row: Int
    let title: String?
    /// The row's coordinates as the server wrote them.
    let subtitle: String?

    init(coordinate: CLLocationCoordinate2D, row: Int, title: String?, subtitle: String?) {
        self.coordinate = coordinate
        self.row = row
        self.title = title
        self.subtitle = subtitle
    }
}

/// The callout's button: the pin it belongs to, for the menu it opens.
final class CalloutMenuButton: NSButton {
    weak var annotation: RowAnnotation?
}

@MainActor
final class MapCoordinator: NSObject, MKMapViewDelegate {
    weak var map: MKMapView?
    var onSelectRow: ((Int) -> Void)?
    private var loadedRevision = -1
    private var loadedSource: MapSource?
    private var loadedRows: Set<Int>?
    private var hasFitted = false

    /// Converts the source's values to pins and overlays. Skipped when nothing changed. A
    /// change of source or of the row subset fits the view to what is now shown.
    func reload(
        grid: GridModel, dialect: SQLDialect, source: MapSource, rows: Set<Int>?, revision: Int,
        summary: Binding<MapSummary>
    ) {
        guard let map, revision != loadedRevision || source != loadedSource || rows != loadedRows,
            source.columns.allSatisfy(grid.columns.indices.contains)
        else { return }
        let sourceChanged = source != loadedSource || rows != loadedRows
        loadedRevision = revision
        loadedSource = source
        loadedRows = rows
        map.removeAnnotations(map.annotations)
        map.removeOverlays(map.overlays)

        var result = MapSummary()
        var bounds: GeoBounds?
        var annotations: [MKAnnotation] = []
        var overlays: [MKOverlay] = []
        let labelColumn = MapSourceDetector.labelColumn(columnNames: MapSources.columnNames(grid))

        func add(_ shape: GeoShape, row: Int) {
            let title = labelColumn.flatMap { grid.value(row: row, column: $0)?.text } ?? "Row \(row + 1)"
            switch shape {
            case let .point(point):
                let subtitle = MapSourceDetector.coordinateText(source, dialect: dialect) {
                    grid.value(row: row, column: $0)
                }
                annotations.append(
                    RowAnnotation(coordinate: point.coordinate, row: row, title: title, subtitle: subtitle))
            case let .multiPoint(points):
                for point in points {
                    annotations.append(
                        RowAnnotation(coordinate: point.coordinate, row: row, title: title, subtitle: nil))
                }
            case let .line(points):
                let line = RowPolyline(coordinates: points.map(\.coordinate), count: points.count)
                line.row = row
                overlays.append(line)
            case let .multiLine(lines):
                for points in lines {
                    let line = RowPolyline(coordinates: points.map(\.coordinate), count: points.count)
                    line.row = row
                    overlays.append(line)
                }
            case let .polygon(rings):
                if let polygon = Self.polygon(rings, row: row) { overlays.append(polygon) }
            case let .multiPolygon(polygons):
                for rings in polygons { if let polygon = Self.polygon(rings, row: row) { overlays.append(polygon) } }
            case let .collection(shapes):
                for inner in shapes { add(inner, row: row) }
            }
            if let shapeBounds = shape.bounds {
                if bounds == nil { bounds = shapeBounds } else { bounds?.include(shapeBounds) }
            }
        }

        for row in 0 ..< grid.rowCount {
            if let rows, !rows.contains(row) { continue }
            if result.placed >= MapPaneView.featureCap {
                result.capped = true
                break
            }
            switch MapSourceDetector.read(source, dialect: dialect, value: { grid.value(row: row, column: $0) }) {
            case .empty:
                continue
            case .unreadable:
                result.unreadable += 1
            case .outOfRange:
                result.outOfRange += 1
            case let .feature(feature):
                if feature.isUnplaceable {
                    result.unplaceable += 1
                    continue
                }
                add(feature.shape, row: row)
                result.placed += 1
            }
        }
        map.addAnnotations(annotations)
        map.addOverlays(overlays)
        if let bounds, !hasFitted || sourceChanged {
            map.setRegion(Self.region(for: bounds), animated: false)
            hasFitted = true
        }
        // Reload runs inside SwiftUI's update of the map view; the summary is state of the
        // pane around it, so it is written once that update has finished.
        Task { @MainActor in summary.wrappedValue = result }
    }

    private static func polygon(_ rings: [[GeoPoint]], row: Int) -> RowPolygon? {
        guard let outer = rings.first, outer.count >= 3 else { return nil }
        let holes = rings.dropFirst().filter { $0.count >= 3 }.map { ring in
            MKPolygon(coordinates: ring.map(\.coordinate), count: ring.count)
        }
        let polygon = RowPolygon(coordinates: outer.map(\.coordinate), count: outer.count, interiorPolygons: holes)
        polygon.row = row
        return polygon
    }

    private static func region(for bounds: GeoBounds) -> MKCoordinateRegion {
        let center = CLLocationCoordinate2D(
            latitude: (bounds.minLatitude + bounds.maxLatitude) / 2,
            longitude: (bounds.minLongitude + bounds.maxLongitude) / 2
        )
        // A little air around the data; a single point still gets a neighbourhood.
        let span = MKCoordinateSpan(
            latitudeDelta: max((bounds.maxLatitude - bounds.minLatitude) * 1.3, 0.01),
            longitudeDelta: max((bounds.maxLongitude - bounds.minLongitude) * 1.3, 0.01)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: Callout menu

    @objc private func showCalloutMenu(_ sender: CalloutMenuButton) {
        guard let annotation = sender.annotation else { return }
        let point = GeoPoint(longitude: annotation.coordinate.longitude, latitude: annotation.coordinate.latitude)
        let menu = PlaceMenu.make(point: point, title: annotation.title, coordinates: annotation.subtitle)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // MARK: MKMapViewDelegate

    nonisolated func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        // MapKit calls its delegate on the main thread; the annotation is handed straight
        // back to the same map view and never crosses to another isolation.
        nonisolated(unsafe) let annotation = annotation
        return MainActor.assumeIsolated {
            if annotation is MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: annotation)
                view.displayPriority = .defaultHigh
                return view
            }
            let view =
                mapView.dequeueReusableAnnotationView(withIdentifier: "row", for: annotation) as? MKMarkerAnnotationView
            view?.clusteringIdentifier = "rows"
            view?.markerTintColor = NSColor.controlAccentColor
            view?.canShowCallout = true
            if let row = annotation as? RowAnnotation {
                let button =
                    (view?.rightCalloutAccessoryView as? CalloutMenuButton)
                    ?? CalloutMenuButton(
                        image: NSImage(systemSymbolName: Icon.openExternally, accessibilityDescription: "Open in…")
                            ?? NSImage(),
                        target: self, action: #selector(showCalloutMenu(_:)))
                button.isBordered = false
                button.toolTip = "Open in Maps, or copy the coordinates"
                button.annotation = row
                view?.rightCalloutAccessoryView = button
            }
            return view
        }
    }

    nonisolated func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        MainActor.assumeIsolated {
            if let annotation = view.annotation as? RowAnnotation { onSelectRow?(annotation.row) }
        }
    }

    nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        // Renderers are plain objects with no actor of their own; nothing here touches
        // the coordinator's state, so the method stays where MapKit calls it.
        if let polygon = overlay as? MKPolygon {
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
            renderer.strokeColor = NSColor.controlAccentColor
            renderer.lineWidth = 2
            return renderer
        }
        if let line = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = NSColor.controlAccentColor
            renderer.lineWidth = 3
            renderer.lineCap = .round
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}

/// Open in Apple Maps, open in Google Maps, copy the coordinates: one menu, used by a
/// pin's callout and by the row popover.
@MainActor
enum PlaceMenu {
    static func make(point: GeoPoint, title: String?, coordinates: String?) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            MenuAction.item(title: "Open in Apple Maps", symbol: Icon.map) {
                if let url = MapLinks.appleMaps(point, title: title) { NSWorkspace.shared.open(url) }
            })
        menu.addItem(
            MenuAction.item(title: "Open in Google Maps", symbol: Icon.openExternally) {
                if let url = MapLinks.googleMaps(point) { NSWorkspace.shared.open(url) }
            })
        if let coordinates {
            menu.addItem(.separator())
            menu.addItem(MenuAction.item(title: "Copy Coordinates", symbol: Icon.copy) { MapLinks.copy(coordinates) })
        }
        return menu
    }
}

/// A menu item that runs a closure, so a menu built on the fly needs no target object.
/// The item holds its action as its represented object; its target is only weak.
@MainActor
final class MenuAction: NSObject {
    private let handler: @MainActor () -> Void

    private init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    static func item(title: String, symbol: String, handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func run(_ sender: Any?) { handler() }
}

final class RowPolyline: MKPolyline {
    var row = 0
}

final class RowPolygon: MKPolygon {
    var row = 0
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// One row's location, shown over its cell: the place, its coordinates, ways to take it
/// elsewhere, and the full map pane for that row alone.
struct MapPeekView: View {
    let grid: GridModel
    let row: Int
    let source: MapSource
    let onOpenPane: () -> Void

    @State private var summary = MapSummary()

    private var reading: MapReading {
        MapSourceDetector.read(source, dialect: grid.dialect) { grid.value(row: row, column: $0) }
    }

    private var coordinates: String? {
        MapSourceDetector.coordinateText(source, dialect: grid.dialect) { grid.value(row: row, column: $0) }
    }

    private var title: String? {
        MapSourceDetector.labelColumn(columnNames: MapSources.columnNames(grid)).flatMap {
            grid.value(row: row, column: $0)?.text
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let problem {
                EmptyStateView(icon: Icon.location, title: problem)
            } else {
                MapCanvas(
                    grid: grid, dialect: grid.dialect, revision: 0, source: source, rows: [row],
                    onSelectRow: { _ in }, summary: $summary
                )
            }
            Divider()
            HStack(spacing: DesignTokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title ?? "Row \(row + 1)").font(.caption.weight(.semibold)).lineLimit(1)
                    Text(coordinates ?? source.title(columnNames: MapSources.columnNames(grid)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer(minLength: DesignTokens.Spacing.sm)
                if let point = anchor {
                    Menu {
                        Button("Open in Apple Maps") {
                            if let url = MapLinks.appleMaps(point, title: title) { NSWorkspace.shared.open(url) }
                        }
                        Button("Open in Google Maps") {
                            if let url = MapLinks.googleMaps(point) { NSWorkspace.shared.open(url) }
                        }
                        if let coordinates {
                            Divider()
                            Button("Copy Coordinates") { MapLinks.copy(coordinates) }
                        }
                    } label: {
                        Label("Open In", systemImage: Icon.openExternally)
                    }
                    .fixedSize()
                    .help("Open this place in Apple Maps or Google Maps, or copy its coordinates")
                }
                Button("Open in Map Pane", action: onOpenPane)
            }
            .controlSize(.small)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: DesignTokens.Metrics.statusHeight + DesignTokens.Spacing.md)
        }
    }

    /// Where the links point: the place itself, or the middle of a shape.
    private var anchor: GeoPoint? {
        guard case let .feature(feature) = reading, !feature.isUnplaceable else { return nil }
        return feature.shape.anchor
    }

    /// Why nothing is on the map, in words, when nothing is.
    private var problem: String? {
        switch reading {
        case .empty: "This row has no location"
        case .unreadable: "Not a coordinate or a geometry"
        case .outOfRange: "Latitude or longitude out of range"
        case let .feature(feature):
            feature.isUnplaceable ? "Not longitude/latitude; use ST_Transform(…, 4326)" : nil
        }
    }
}
