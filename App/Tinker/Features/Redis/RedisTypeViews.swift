import DBCore
import DBRedis
import SwiftUI

// The data types Redis documents beside the classic five: the ones that live inside a
// string or a sorted set (bitmap, HyperLogLog, geospatial), time series, the
// probabilistic types and vector sets. Each is shown the way its own commands see it.

// MARK: - Shared pieces

/// What a type reports about a key, as a grid of names and values.
struct RedisFieldGrid: View {
    let fields: [RedisField]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: DesignTokens.Spacing.md, alignment: .topLeading)],
            alignment: .leading, spacing: DesignTokens.Spacing.sm
        ) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 0) {
                    Text(field.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(field.value.isEmpty ? "—" : field.value)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(field.value)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DesignTokens.Spacing.md)
    }
}

/// The views a key can be read through, as a segmented choice above the value.
struct RedisViewPicker<Mode: Hashable & Identifiable>: View {
    let modes: [Mode]
    let title: (Mode) -> String
    @Binding var selection: Mode

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Picker("View", selection: $selection) {
                ForEach(modes) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: DesignTokens.Metrics.barHeight)
    }
}

/// A note under a view: what the numbers mean and how far they can be trusted.
struct RedisTypeNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: Icon.info)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

// MARK: - String: text, bitmap, HyperLogLog

/// A string, and the two documented types that are strings underneath.
struct RedisStringView: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let data: Data
    let isTruncated: Bool

    enum Mode: String, Identifiable {
        case text = "Text"
        case bitmap = "Bitmap"
        case hyperLogLog = "HyperLogLog"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .text

    private var isHyperLogLog: Bool {
        if case .hyperLogLog = controller.facet { return true }
        return false
    }

    private var modes: [Mode] {
        var modes: [Mode] = isHyperLogLog ? [.hyperLogLog, .text] : [.text]
        if controller.info?.supports("bitcount") ?? true { modes.append(.bitmap) }
        return modes
    }

    var body: some View {
        VStack(spacing: 0) {
            RedisViewPicker(modes: modes, title: \.rawValue, selection: $mode)
            Divider()
            switch mode {
            case .text:
                RedisTextEditor(controller: controller, key: key, data: data, isJSON: false, isTruncated: isTruncated)
            case .bitmap:
                RedisBitmapView(controller: controller, key: key)
            case .hyperLogLog:
                RedisHyperLogLogView(controller: controller, key: key)
            }
        }
        // A HyperLogLog opens as one: its bytes mean nothing as text.
        .onAppear { if isHyperLogLog { mode = .hyperLogLog } }
    }
}

struct RedisHyperLogLogView: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    @State private var element = ""

    private var count: Int64 {
        if case let .hyperLogLog(count) = controller.facet { return count }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RedisFieldGrid(fields: [RedisField(name: "Distinct elements (PFCOUNT)", value: "~\(count)")])
            RedisTypeNote(
                text: "A HyperLogLog counts distinct elements in at most 12 kB, with a standard error of 0.81%. "
                    + "It keeps the count, never the elements: they cannot be listed or removed.")
            Spacer(minLength: 0)
            Divider()
            HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
                RedisValueField(title: "Element", text: $element, multiline: false)
                Button("Add") {
                    let new = RedisText.parse(element)
                    controller.write("Added an element") { try await RedisFacets.addToHyperLogLog($0, key, [new]) }
                    element = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(element.isEmpty)
                .help("PFADD")
            }
            .controlSize(.small)
            .padding(DesignTokens.Spacing.md)
        }
    }
}

struct RedisBitmapView: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    @State private var offset = ""

    private var parsedOffset: Int64? {
        // SETBIT takes offsets below 2^32.
        UInt32(offset.trimmingCharacters(in: .whitespaces)).map(Int64.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let bitmap = controller.bitmap {
                RedisFieldGrid(fields: [
                    RedisField(name: "Bits", value: "\(bitmap.bytes * 8)"),
                    RedisField(name: "Set bits (BITCOUNT)", value: "\(bitmap.setBits)"),
                    RedisField(name: "Clear bits", value: "\(bitmap.bytes * 8 - bitmap.setBits)"),
                    RedisField(name: "Bytes", value: "\(bitmap.bytes)"),
                ])
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        ForEach(Array(rows(of: bitmap).enumerated()), id: \.offset) { index, row in
                            HStack(spacing: DesignTokens.Spacing.md) {
                                Text("\(index * 64)")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text(row)
                            }
                        }
                        if bitmap.bytes > Int64(RedisBitmap.headLength) {
                            Text("The first \(RedisBitmap.headLength * 8) bits are shown.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(DesignTokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                RedisTypeNote(
                    text: "A bitmap is a string read bit by bit; bit 0 is the first. BITFIELD reads the same bits as "
                        + "integers of any width — run it from the Console.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
                RedisValueField(title: "Bit offset", text: $offset, multiline: false).frame(width: 160)
                Button("Clear Bit") { write(false) }.disabled(parsedOffset == nil)
                Button("Set Bit") { write(true) }.buttonStyle(.borderedProminent).disabled(parsedOffset == nil)
                Spacer()
            }
            .controlSize(.small)
            .padding(DesignTokens.Spacing.md)
        }
        .task { await controller.loadBitmap() }
    }

    /// Sixty-four bits a line, a space between bytes.
    private func rows(of bitmap: RedisBitmap) -> [String] {
        let bits = Array(bitmap.headBits)
        return stride(from: 0, to: bits.count, by: 64).map { start in
            stride(from: start, to: min(start + 64, bits.count), by: 8)
                .map { String(bits[$0 ..< min($0 + 8, bits.count)]) }
                .joined(separator: " ")
        }
    }

    private func write(_ on: Bool) {
        guard let parsedOffset else { return }
        controller.write("\(on ? "Set" : "Cleared") bit \(parsedOffset)") {
            try await RedisFacets.setBit($0, key, offset: parsedOffset, on: on)
        }
    }
}

// MARK: - Sorted set: members, geospatial

/// A sorted set, and the geospatial index it may be.
struct RedisSortedSetView: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let members: [RedisScoredMember]

    enum Mode: String, Identifiable {
        case members = "Members"
        case geospatial = "Geospatial"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .members

    var body: some View {
        if controller.facet == .geospatial {
            VStack(spacing: 0) {
                RedisViewPicker(modes: [Mode.members, .geospatial], title: \.rawValue, selection: $mode)
                    .help("The scores fit the geohashes GEOADD writes, so the members can be read as places")
                Divider()
                switch mode {
                case .members: RedisSortedSetEditor(controller: controller, key: key, members: members)
                case .geospatial: RedisGeoView(controller: controller, key: key, members: members)
                }
            }
        } else {
            RedisSortedSetEditor(controller: controller, key: key, members: members)
        }
    }
}

struct RedisGeoView: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let members: [RedisScoredMember]

    @State private var selection: Set<Data> = []
    @State private var member = ""
    @State private var longitude = ""
    @State private var latitude = ""

    private var selected: RedisGeoMember? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return controller.positions.first { $0.member == id }
    }

    private var isValid: Bool {
        guard let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
            let lat = Double(latitude.trimmingCharacters(in: .whitespaces))
        else { return false }
        return !member.isEmpty && (-180 ... 180).contains(lon) && (-85.05112878 ... 85.05112878).contains(lat)
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(controller.positions, selection: $selection) {
                TableColumn("Member") { row in
                    Text(RedisFormat.text(row.member)).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
                TableColumn("Longitude") { row in Text(row.longitude).monospacedDigit() }
                    .width(min: 90, ideal: 150, max: 200)
                TableColumn("Latitude") { row in Text(row.latitude).monospacedDigit() }
                    .width(min: 90, ideal: 150, max: 200)
            }
            .onChange(of: selection) { _, _ in
                if let selected {
                    member = RedisFormat.text(selected.member)
                    longitude = selected.longitude
                    latitude = selected.latitude
                }
            }
            RedisPagingBar(controller: controller, shown: controller.positions.count) {
                Button {
                    if let selected { RedisFormat.copy("\(selected.latitude), \(selected.longitude)") }
                } label: {
                    Label("Copy Coordinates", systemImage: Icon.copy)
                }
                .disabled(selected == nil)
                Button {
                    if let selected { openInMaps(selected) }
                } label: {
                    Label("Open in Maps", systemImage: Icon.map)
                }
                .disabled(selected == nil)
                Button("Remove") {
                    let chosen = Array(selection)
                    controller.write("Removed \(chosen.count) member\(chosen.count == 1 ? "" : "s")", destructive: true)
                    {
                        try await RedisValues.removeSortedMembers($0, key, chosen)
                    }
                    selection = []
                }
                .disabled(selection.isEmpty)
            }
            Divider()
            HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
                RedisValueField(title: "Longitude", text: $longitude, multiline: false).frame(width: 150)
                RedisValueField(title: "Latitude", text: $latitude, multiline: false).frame(width: 150)
                RedisValueField(title: "Member", text: $member, multiline: false)
                Button(selected == nil ? "Add" : "Move") {
                    let (name, lon, lat) = (
                        RedisText.parse(member), longitude.trimmingCharacters(in: .whitespaces),
                        latitude.trimmingCharacters(in: .whitespaces)
                    )
                    controller.write("Placed \(member)") {
                        try await RedisFacets.addPosition($0, key, member: name, longitude: lon, latitude: lat)
                    }
                    selection = []
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
                .help("GEOADD: longitude -180 to 180, latitude -85.05112878 to 85.05112878")
            }
            .controlSize(.small)
            .padding(DesignTokens.Spacing.md)
        }
        // Read again when more members were loaded, or the set was changed.
        .task(id: members) { await controller.loadPositions() }
    }

    private func openInMaps(_ place: RedisGeoMember) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(place.latitude),\(place.longitude)"),
            URLQueryItem(name: "q", value: RedisFormat.text(place.member)),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Time series

struct RedisTimeSeriesEditor: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let info: RedisTimeSeriesInfo
    let samples: [RedisSample]

    @State private var selection: Set<Int64> = []
    @State private var timestamp = ""
    @State private var value = ""

    private var canDelete: Bool { controller.info?.supports("ts.del") ?? true }

    /// The headline facts first, then the rest as the server reports them.
    private var fields: [RedisField] {
        var fields = [
            RedisField(name: "Samples", value: "\(info.totalSamples)"),
            RedisField(
                name: "Retention",
                value: info.retentionMilliseconds == 0
                    ? "for ever" : RedisFormat.ttl(info.retentionMilliseconds) + " (\(info.retentionMilliseconds) ms)"),
        ]
        if info.totalSamples > 0 {
            fields.append(RedisField(name: "First sample", value: Self.time(info.firstTimestamp)))
            fields.append(RedisField(name: "Last sample", value: Self.time(info.lastTimestamp)))
        }
        if !info.labels.isEmpty {
            fields.append(
                RedisField(name: "Labels", value: info.labels.map { "\($0.name)=\($0.value)" }.joined(separator: " ")))
        }
        let shown: Set<String> = ["totalSamples", "retentionTime", "firstTimestamp", "lastTimestamp", "labels"]
        return fields + info.fields.filter { !shown.contains($0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            RedisFieldGrid(fields: fields)
            Divider()
            Table(samples, selection: $selection) {
                TableColumn("Timestamp (ms)") { sample in
                    Text(String(sample.timestamp)).font(.system(.body, design: .monospaced))
                }
                .width(min: 110, ideal: 150, max: 200)
                TableColumn("Time") { sample in Text(Self.time(sample.timestamp)).foregroundStyle(.secondary) }
                    .width(min: 120, ideal: 190, max: 260)
                TableColumn("Value") { sample in
                    Text(sample.value).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
            }
            RedisPagingBar(controller: controller, shown: samples.count) {
                Button("Delete") {
                    let chosen = selection.sorted()
                    controller.write("Deleted \(chosen.count) sample\(chosen.count == 1 ? "" : "s")", destructive: true)
                    {
                        try await RedisModuleValues.deleteSamples($0, key, timestamps: chosen)
                    }
                    selection = []
                }
                .disabled(selection.isEmpty || !canDelete)
            }
            Divider()
            HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
                RedisValueField(title: "Timestamp (ms), empty for now", text: $timestamp, multiline: false)
                    .frame(width: 220)
                RedisValueField(title: "Value", text: $value, multiline: false)
                Button("Add Sample") {
                    let when = timestamp.trimmingCharacters(in: .whitespaces)
                    let number = value.trimmingCharacters(in: .whitespaces)
                    controller.write("Added a sample") {
                        try await RedisModuleValues.addSample(
                            $0, key, timestamp: when.isEmpty ? "*" : when, value: number)
                    }
                    timestamp = ""
                    value = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(Double(value.trimmingCharacters(in: .whitespaces)) == nil)
                .help("TS.ADD")
            }
            .controlSize(.small)
            .padding(DesignTokens.Spacing.md)
        }
    }

    /// A timestamp as a moment, for reading; the milliseconds beside it are the value.
    static func time(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            .formatted(
                .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second().secondFraction(
                    .fractional(3)))
    }
}

// MARK: - Probabilistic types

/// A Bloom filter, a Cuckoo filter, a Top-K, a Count-min sketch or a t-digest: what it
/// reports, what it can list, and one question at a time.
struct RedisSummaryView: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let type: RedisKeyType
    let summary: RedisTypeSummary

    @State private var item = ""

    private var note: String {
        switch type {
        case .bloomFilter:
            "A Bloom filter answers whether an item may have been added. It can say yes by mistake, at the error "
                + "rate it was reserved with, and never says no by mistake. Items cannot be listed or removed."
        case .cuckooFilter:
            "A Cuckoo filter answers whether an item may have been added, and can forget one. Items cannot be listed."
        case .topK: "A Top-K keeps the k most frequent items it has seen; the counts are estimates."
        case .countMinSketch:
            "A Count-min sketch estimates how often an item was counted. It can count too high, never too low."
        case .tDigest:
            "A t-digest estimates quantiles of the numbers it has observed; the tails are the most accurate."
        default: ""
        }
    }

    private var question: (field: String, ask: String, add: String?) {
        switch type {
        case .bloomFilter: ("Item", "Check", "Add")
        case .cuckooFilter: ("Item", "Check", "Add")
        case .topK: ("Item", "Check", "Add")
        case .countMinSketch: ("Item", "Count", "Increment")
        case .tDigest: ("Quantile (0 to 1) or a number to add", "Quantile", "Add Observation")
        default: ("Item", "Check", nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RedisFieldGrid(fields: summary.fields)
            if !summary.columns.isEmpty {
                Divider()
                SimpleTable(
                    columns: summary.columns.enumerated().map { index, title in
                        .init(title: title, width: index == summary.columns.count - 1 ? nil : 220)
                    },
                    rows: summary.rows)
            } else {
                Spacer(minLength: 0)
            }
            RedisTypeNote(text: note)
            if let answer = controller.answer {
                InlineBanner(kind: .info, message: answer) { controller.clearAnswer() }
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.bottom, DesignTokens.Spacing.sm)
            }
            Divider()
            HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
                RedisValueField(title: question.field, text: $item, multiline: false)
                    .onSubmit { Task { await controller.ask(item) } }
                if type == .cuckooFilter {
                    Button("Remove") {
                        let bytes = RedisText.parse(item)
                        controller.write("Removed \(item)", destructive: true) {
                            try await RedisModuleValues.removeFromCuckoo($0, key, item: bytes)
                        }
                    }
                    .disabled(item.isEmpty)
                    .help("CF.DEL")
                }
                if let add = question.add {
                    Button(add) { addItem() }.disabled(!canAdd)
                }
                Button(question.ask) { Task { await controller.ask(item) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAsk)
            }
            .controlSize(.small)
            .padding(DesignTokens.Spacing.md)
        }
    }

    private var number: Double? { Double(item.trimmingCharacters(in: .whitespaces)) }

    private var canAsk: Bool {
        guard type == .tDigest else { return !item.isEmpty }
        return number.map { (0 ... 1).contains($0) } ?? false
    }

    private var canAdd: Bool { type == .tDigest ? number != nil : !item.isEmpty }

    private func addItem() {
        let text = item.trimmingCharacters(in: .whitespaces)
        if type == .tDigest {
            controller.write("Added \(text)") { try await RedisModuleValues.addObservations($0, key, values: [text]) }
        } else {
            let bytes = RedisText.parse(item)
            let type = type
            controller.write("Added \(item)") { try await RedisModuleValues.add($0, key, type: type, items: [bytes]) }
        }
        item = ""
    }
}

// MARK: - Vector set

struct RedisVectorSetView: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let fields: [RedisField]
    let elements: [Data]
    let isSample: Bool

    struct Row: Identifiable {
        let element: Data
        var id: Data { element }
    }

    @State private var selection: Set<Data> = []
    /// How many components of a vector are written out; the rest are counted.
    private static let shownComponents = 24

    var body: some View {
        VStack(spacing: 0) {
            RedisFieldGrid(fields: fields)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    Table(elements.map(Row.init), selection: $selection) {
                        TableColumn("Element") { row in
                            Text(RedisFormat.text(row.element)).font(.system(.body, design: .monospaced)).lineLimit(1)
                        }
                    }
                    RedisPagingBar(controller: controller, shown: elements.count) {
                        Button("Remove") {
                            let chosen = Array(selection)
                            controller.write(
                                "Removed \(chosen.count) element\(chosen.count == 1 ? "" : "s")", destructive: true
                            ) {
                                try await RedisModuleValues.removeVectorElements($0, key, chosen)
                            }
                            selection = []
                        }
                        .disabled(selection.isEmpty || !(controller.info?.supports("vrem") ?? true))
                    }
                }
                .frame(minWidth: 200, idealWidth: 260)
                detail.frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            }
            if isSample {
                RedisTypeNote(text: "This server cannot list a vector set in order; these are random elements of it.")
            }
        }
        .onChange(of: selection) { _, selected in
            guard selected.count == 1, let element = selected.first else { return }
            Task { await controller.loadVectorElement(element) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let element = controller.vectorElement, selection == [element.element] {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        SectionHeading(text: "Vector", trailing: "\(element.vector.count) dimensions", inset: 0)
                        Text(vectorText(element.vector))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let attributes = element.attributes {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            SectionHeading(text: "Attributes", inset: 0)
                            Text(RedisValues.prettyJSON(attributes))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !controller.vectorMatches.isEmpty {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            SectionHeading(text: "Nearest elements", trailing: "VSIM", inset: 0)
                            ForEach(controller.vectorMatches) { match in
                                HStack {
                                    Text(RedisFormat.text(match.element))
                                        .font(.system(.callout, design: .monospaced)).lineLimit(1)
                                    Spacer()
                                    Text(match.score).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
        } else {
            EmptyStateView(
                icon: Icon.redisKey, title: "Choose an element",
                message: "Its vector, its attributes and the elements nearest to it are shown here.")
        }
    }

    private func vectorText(_ vector: [String]) -> String {
        let shown = vector.prefix(Self.shownComponents).joined(separator: ", ")
        let rest = vector.count - Self.shownComponents
        return rest > 0 ? "\(shown), … \(rest) more" : shown
    }
}
