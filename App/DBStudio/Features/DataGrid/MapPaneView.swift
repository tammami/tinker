import DBCore
import DBGrid
import MapKit
import SwiftUI

/// The geometry columns a grid holds: typed as such, or text that parses as one.
@MainActor
enum GeometryColumns {
    /// Column indices worth offering on a map, cheapest test first.
    static func detect(in grid: GridModel, dialect: SQLDialect) -> [Int] {
        var found: [Int] = []
        for (index, column) in grid.columns.enumerated() {
            if GeometryParser.isGeometryType(column.nativeTypeName) {
                found.append(index)
                continue
            }
            // A text column is a geometry column when its first values say so; only a few
            // rows are looked at, so an unrelated wide text column costs nothing.
            guard column.kind == .string || column.kind == .raw else { continue }
            var sampled = 0
            var parsed = 0
            for row in 0 ..< min(grid.rowCount, 12) {
                guard let value = grid.value(row: row, column: index), !value.isNull else { continue }
                sampled += 1
                if GeometryParser.parse(value, dialect: dialect) != nil { parsed += 1 }
                if sampled == 4 { break }
            }
            if sampled > 0, parsed == sampled { found.append(index) }
        }
        return found
    }
}

/// The map: every loaded row's geometry from one column, drawn where it belongs, with
/// points clustered and the view fitted to the whole.
///
/// Rows are read from the grid model, never copied: what the map holds are the shapes,
/// converted once per revision, and capped so a table of a million geometries cannot
/// take the app down with it.
struct MapPaneView: View {
    let grid: GridModel
    let dialect: SQLDialect
    let revision: Int
    @Binding var column: Int
    let columns: [Int]
    let onSelectRow: (Int) -> Void

    static let featureCap = 5_000

    @State private var summary = MapSummary()

    var body: some View {
        VStack(spacing: 0) {
            PaneBar {
                Label("Map", systemImage: Icon.map).font(.caption.weight(.semibold))
                if columns.count > 1 {
                    Picker("Column", selection: $column) {
                        ForEach(columns, id: \.self) { index in
                            Text(grid.columns[index].name).tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                } else if let first = columns.first {
                    Text(grid.columns[first].name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if summary.unplaceable > 0 {
                    Label(
                        "\(summary.unplaceable) not on the map — their SRID is not longitude/latitude; use ST_Transform(…, 4326)",
                        systemImage: Icon.warning
                    )
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
                if summary.unreadable > 0 {
                    Label("\(summary.unreadable) unreadable", systemImage: Icon.warning)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(summary.placed) on the map").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .controlSize(.small)
            Divider()
            MapCanvas(
                grid: grid, dialect: dialect, revision: revision, column: column,
                onSelectRow: onSelectRow, summary: $summary
            )
        }
    }
}

struct MapSummary: Equatable {
    var placed = 0
    var unplaceable = 0
    var unreadable = 0
    var capped = false
}

/// The `MKMapView`, rebuilt only when the grid's revision or the chosen column changes.
struct MapCanvas: NSViewRepresentable {
    let grid: GridModel
    let dialect: SQLDialect
    let revision: Int
    let column: Int
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
        context.coordinator.reload(grid: grid, dialect: dialect, column: column, revision: revision, summary: $summary)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelectRow = onSelectRow
        context.coordinator.reload(grid: grid, dialect: dialect, column: column, revision: revision, summary: $summary)
    }

    func makeCoordinator() -> MapCoordinator { MapCoordinator() }
}

/// A map pin that remembers which grid row it came from.
final class RowAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let row: Int
    let title: String?

    init(coordinate: CLLocationCoordinate2D, row: Int, title: String?) {
        self.coordinate = coordinate
        self.row = row
        self.title = title
    }
}

@MainActor
final class MapCoordinator: NSObject, MKMapViewDelegate {
    weak var map: MKMapView?
    var onSelectRow: ((Int) -> Void)?
    private var loadedRevision = -1
    private var loadedColumn = -1
    private var hasFitted = false

    /// Converts the column's values to overlays. Skipped when nothing changed.
    func reload(grid: GridModel, dialect: SQLDialect, column: Int, revision: Int, summary: Binding<MapSummary>) {
        guard let map, revision != loadedRevision || column != loadedColumn, grid.columns.indices.contains(column)
        else { return }
        let columnChanged = column != loadedColumn
        loadedRevision = revision
        loadedColumn = column
        map.removeAnnotations(map.annotations)
        map.removeOverlays(map.overlays)

        var result = MapSummary()
        var bounds: GeoBounds?
        var annotations: [MKAnnotation] = []
        var overlays: [MKOverlay] = []
        let labelColumn = grid.columns.firstIndex { ["name", "title", "label"].contains($0.name.lowercased()) }

        func add(_ shape: GeoShape, row: Int) {
            let title = labelColumn.flatMap { grid.value(row: row, column: $0)?.text } ?? "Row \(row + 1)"
            switch shape {
            case let .point(point):
                annotations.append(RowAnnotation(coordinate: point.coordinate, row: row, title: title))
            case let .multiPoint(points):
                for point in points {
                    annotations.append(RowAnnotation(coordinate: point.coordinate, row: row, title: title))
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
            if result.placed >= MapPaneView.featureCap {
                result.capped = true
                break
            }
            guard let value = grid.value(row: row, column: column), !value.isNull else { continue }
            guard let feature = GeometryParser.parse(value, dialect: dialect) else {
                result.unreadable += 1
                continue
            }
            if feature.isUnplaceable {
                result.unplaceable += 1
                continue
            }
            add(feature.shape, row: row)
            result.placed += 1
        }
        map.addAnnotations(annotations)
        map.addOverlays(overlays)
        if let bounds, !hasFitted || columnChanged {
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

final class RowPolyline: MKPolyline {
    var row = 0
}

final class RowPolygon: MKPolygon {
    var row = 0
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
