import DBCore
import DBRedis
import SwiftUI

/// One key: what it is, how long it lives, and its value in an editor that fits its type.
struct RedisKeyDetailView: View {
    @Bindable var controller: RedisTabController
    let info: RedisKeyInfo

    @State private var name = ""
    @State private var ttlText = ""
    @State private var duplicateName = ""
    @State private var isDuplicating = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if controller.isLoadingValue && controller.value == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let value = controller.value {
                editor(value)
            }
        }
        .onAppear {
            name = info.key.display
            ttlText = info.ttlMilliseconds.map { String($0 / 1_000) } ?? ""
        }
        .alert("Duplicate Key", isPresented: $isDuplicating) {
            TextField("New name", text: $duplicateName)
            Button("Duplicate") { controller.duplicate(info.key, to: duplicateName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                RedisTypeBadge(type: info.type, facet: controller.facet)
                TextField("Key", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { controller.rename(info.key, to: name) }
                    .help("Edit and press Return to rename (RENAMENX: never overwrites another key)")
                IconButton(icon: Icon.copy, label: "Copy the key name") { RedisFormat.copy(info.key.display) }
                IconButton(icon: Icon.duplicate, label: "Duplicate the key") {
                    duplicateName = info.key.display + ":copy"
                    isDuplicating = true
                }
                IconButton(icon: Icon.refresh, label: "Reload") { Task { await controller.reloadSelected() } }
                IconButton(icon: Icon.delete, label: "Delete the key", isDestructive: true) {
                    controller.selection = [info.id]
                    controller.deleteSelectedKeys()
                }
            }
            HStack(spacing: DesignTokens.Spacing.md) {
                Label(RedisFormat.ttl(info.ttlMilliseconds), systemImage: Icon.expiry)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help(info.ttlMilliseconds == nil ? "The key does not expire" : "Time left before the key expires")
                TextField("TTL seconds", text: $ttlText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit { applyTTL() }
                Button("Set TTL") { applyTTL() }
                    .disabled(Int64(ttlText.trimmingCharacters(in: .whitespaces)).map { $0 <= 0 } ?? true)
                Button("Persist") { controller.setTTL(info.key, seconds: nil) }
                    .disabled(info.ttlMilliseconds == nil)
                    .help("Remove the expiry: the key lives until deleted")
                Spacer()
                if let length = info.length {
                    Text(lengthText(length))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let memory = info.memoryBytes {
                    Text(RedisFormat.bytes(memory) + " in memory").font(.caption).foregroundStyle(.secondary)
                        .help("MEMORY USAGE: the key, its value and the server's own overhead")
                }
            }
            .controlSize(.small)
            storage
        }
        .padding(DesignTokens.Spacing.md)
    }

    private func lengthText(_ length: Int64) -> String {
        switch info.type {
        case .string: "\(length) byte\(length == 1 ? "" : "s")"
        case .timeSeries: "\(length) sample\(length == 1 ? "" : "s")"
        default: "\(length) element\(length == 1 ? "" : "s")"
        }
    }

    /// The type by its documented name and by what `TYPE` answers, and how the server
    /// holds the key: its encoding, and how recently or how often it is used.
    private var storage: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Text(typeText).help("The data type as Redis documents it, and what the TYPE command answers")
            if let metadata = controller.metadata {
                if let encoding = metadata.encoding {
                    Text("encoding \(encoding)")
                        .help("OBJECT ENCODING: the representation the server chose for this value")
                }
                if let idle = metadata.idleSeconds {
                    Text("idle \(RedisFormat.ttl(idle * 1_000))")
                        .help("OBJECT IDLETIME: time since the key was last read or written")
                }
                if let frequency = metadata.frequency {
                    Text("frequency \(frequency)")
                        .help("OBJECT FREQ: the logarithmic access counter of an LFU eviction policy")
                }
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var typeText: String {
        let stored = "TYPE \(info.type.scanName)"
        if case .hyperLogLog = controller.facet { return "HyperLogLog · \(stored)" }
        return "\(info.type.displayName) · \(stored)"
    }

    private func applyTTL() {
        guard let seconds = Int64(ttlText.trimmingCharacters(in: .whitespaces)), seconds > 0 else { return }
        controller.setTTL(info.key, seconds: seconds)
    }

    @ViewBuilder
    private func editor(_ value: RedisValuePage) -> some View {
        switch value {
        case let .string(data):
            RedisStringView(
                controller: controller, key: info.key, data: data,
                isTruncated: (info.length ?? 0) > Int64(RedisValues.stringReadLimit))
        case let .json(text):
            RedisTextEditor(controller: controller, key: info.key, data: Data(text.utf8), isJSON: true, isTruncated: false)
        case let .hash(fields, _):
            RedisHashEditor(controller: controller, key: info.key, fields: fields)
        case let .list(items, offset):
            RedisListEditor(controller: controller, key: info.key, items: items, offset: offset)
        case let .set(members, _):
            RedisSetEditor(controller: controller, key: info.key, members: members)
        case let .zset(members, _):
            RedisSortedSetView(controller: controller, key: info.key, members: members)
        case let .stream(entries, _):
            RedisStreamEditor(controller: controller, key: info.key, entries: entries)
        case let .timeSeries(series, samples, _):
            RedisTimeSeriesEditor(controller: controller, key: info.key, info: series, samples: samples)
        case let .summary(summary):
            RedisSummaryView(controller: controller, key: info.key, type: info.type, summary: summary)
        case let .vectorSet(fields, elements, _, isSample):
            RedisVectorSetView(
                controller: controller, key: info.key, fields: fields, elements: elements, isSample: isSample)
        case let .unsupported(typeName, lines):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Label(
                    "\(typeName) belongs to a module Tinker does not know; this is what the server says of the key. "
                        + "Use the Console to read or change it.",
                    systemImage: Icon.info
                )
                .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
    }
}

// MARK: - Shared pieces

/// The row under a collection editor: how much is shown, and more.
struct RedisPagingBar<Actions: View>: View {
    @Bindable var controller: RedisTabController
    let shown: Int
    var filterable = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if filterable {
                Image(systemName: Icon.search).foregroundStyle(.secondary)
                TextField("Filter, e.g. name*", text: $controller.valueFilter)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 180)
                    .onSubmit { Task { await controller.applyValueFilter() } }
            }
            Text("\(shown) shown").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if controller.valueHasMore {
                Button("Load More") { Task { await controller.loadMoreValue() } }
            }
            Spacer()
            actions
        }
        .controlSize(.small)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: DesignTokens.Metrics.statusHeight + DesignTokens.Spacing.xs)
    }
}

/// A value field that shows bytes as text and says so when they are not text.
struct RedisValueField: View {
    let title: String
    @Binding var text: String
    var multiline = true

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if multiline {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius)
                            .strokeBorder(Color.primary.opacity(0.1)))
            } else {
                TextField(title, text: $text).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            }
        }
    }
}

// MARK: - String and JSON

struct RedisTextEditor: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let data: Data
    let isJSON: Bool
    let isTruncated: Bool

    @State private var text = ""
    @State private var isBinary = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            if isTruncated {
                Label(
                    "Only the first \(RedisValues.stringReadLimit / 1_048_576) MiB is shown; the value is read-only here.",
                    systemImage: Icon.warning
                )
                .font(.caption).foregroundStyle(.orange).padding(DesignTokens.Spacing.sm)
            } else if isBinary {
                Label("Binary value: shown with \\x escapes; saving writes the escaped bytes back.", systemImage: Icon.info)
                    .font(.caption).foregroundStyle(.secondary).padding(DesignTokens.Spacing.sm)
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(DesignTokens.Spacing.xs)
            Divider()
            HStack(spacing: DesignTokens.Spacing.sm) {
                if let problem { Text(problem).font(.caption).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Button {
                    formatJSON()
                } label: {
                    Label("Format JSON", systemImage: Icon.format)
                }
                .help("Pretty-print the value when it is JSON")
                Button("Revert") { load() }
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isTruncated)
            }
            .controlSize(.small)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: DesignTokens.Metrics.statusHeight + DesignTokens.Spacing.sm)
        }
        .onAppear(perform: load)
        // Reload, or a save, brings the server's value back: the editor shows it, so a
        // later Save never writes back text older than what the server holds.
        .onChange(of: data) { _, _ in load() }
    }

    private func load() {
        isBinary = !RedisText.isText(data)
        text = isBinary ? RedisText.display(data) : String(decoding: data, as: UTF8.self)
        problem = nil
    }

    private func formatJSON() {
        let pretty = RedisValues.prettyJSON(text)
        if pretty == text, (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) == nil {
            problem = "Not valid JSON"
        } else {
            text = pretty
            problem = nil
        }
    }

    private func save() {
        if isJSON {
            guard (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil else {
                problem = "Not valid JSON; nothing was saved."
                return
            }
            let value = text
            controller.write("Saved \(key.display)") { connection in
                try await RedisValues.setJSON(connection, key, value)
            }
        } else {
            let bytes = isBinary ? RedisText.parse(text) : Data(text.utf8)
            controller.write("Saved \(key.display)") { connection in
                try await RedisValues.setString(connection, key, bytes)
            }
        }
    }
}

// MARK: - Hash

struct RedisHashEditor: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let fields: [RedisPair]

    struct Row: Identifiable {
        let pair: RedisPair
        var id: Data { pair.field }
    }

    @State private var selection: Set<Data> = []
    @State private var field = ""
    @State private var value = ""
    @State private var fieldTTL = ""

    private var selectedPair: RedisPair? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return fields.first { $0.field == id }
    }

    /// Redis 7.4 lets a single field expire; older servers have no such thing to show.
    private var hasFieldExpiry: Bool { controller.info?.hasHashFieldExpiry ?? false }

    @ViewBuilder
    private var table: some View {
        if hasFieldExpiry {
            Table(fields.map(Row.init), selection: $selection) {
                TableColumn("Field") { row in
                    Text(RedisFormat.text(row.pair.field)).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
                TableColumn("Value") { row in
                    Text(RedisFormat.text(row.pair.value)).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
                TableColumn("TTL") { row in
                    Text(RedisFormat.ttl(row.pair.ttlMilliseconds))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 40, ideal: 70, max: 100)
            }
        } else {
            Table(fields.map(Row.init), selection: $selection) {
                TableColumn("Field") { row in
                    Text(RedisFormat.text(row.pair.field)).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
                TableColumn("Value") { row in
                    Text(RedisFormat.text(row.pair.value)).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            table
            .onChange(of: selection) { _, _ in
                if let pair = selectedPair {
                    field = RedisFormat.text(pair.field)
                    value = RedisFormat.text(pair.value)
                    fieldTTL = pair.ttlMilliseconds.map { String(max(1, $0 / 1_000)) } ?? ""
                }
            }
            RedisPagingBar(controller: controller, shown: fields.count, filterable: true) {
                Button("Delete") {
                    let chosen = Array(selection)
                    controller.write("Deleted \(chosen.count) field\(chosen.count == 1 ? "" : "s")", destructive: true) {
                        try await RedisValues.deleteHashFields($0, key, chosen)
                    }
                    selection = []
                }
                .disabled(selection.isEmpty)
            }
            Divider()
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                RedisValueField(title: "Field", text: $field, multiline: false)
                RedisValueField(title: "Value", text: $value)
                HStack {
                    if hasFieldExpiry, let pair = selectedPair {
                        Image(systemName: Icon.expiry).foregroundStyle(.secondary)
                        TextField("Field TTL seconds", text: $fieldTTL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                            .onSubmit { setFieldTTL(pair) }
                            .help("HEXPIRE: this field alone expires; the rest of the hash stays")
                        Button("Set Field TTL") { setFieldTTL(pair) }
                            .disabled((Int64(fieldTTL.trimmingCharacters(in: .whitespaces)) ?? 0) <= 0)
                        Button("Persist Field") {
                            let name = pair.field
                            controller.write("Removed the expiry of \(RedisFormat.text(name))") {
                                try await RedisFacets.setFieldExpiry($0, key, field: name, milliseconds: nil)
                            }
                        }
                        .disabled(pair.ttlMilliseconds == nil)
                        .help("HPERSIST: the field lives as long as the hash")
                    }
                    Spacer()
                    Button("Clear") {
                        selection = []
                        field = ""
                        value = ""
                        fieldTTL = ""
                    }
                    if let pair = selectedPair {
                        Button("Update") { update(pair) }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Add Field") { add() }.buttonStyle(.borderedProminent).disabled(field.isEmpty)
                    }
                }
                .controlSize(.small)
            }
            .padding(DesignTokens.Spacing.md)
        }
    }

    private func setFieldTTL(_ pair: RedisPair) {
        guard let seconds = Int64(fieldTTL.trimmingCharacters(in: .whitespaces)), seconds > 0 else { return }
        let name = pair.field
        controller.write("Set the expiry of \(RedisFormat.text(name))") {
            try await RedisFacets.setFieldExpiry($0, key, field: name, milliseconds: seconds * 1_000)
        }
    }

    private func add() {
        let newField = RedisText.parse(field)
        let newValue = RedisText.parse(value)
        controller.write("Set \(field)") { try await RedisValues.setHashField($0, key, field: newField, value: newValue) }
        field = ""
        value = ""
    }

    private func update(_ pair: RedisPair) {
        let newField = RedisText.parse(field)
        let newValue = RedisText.parse(value)
        // The time the field had left when the page was read; HSET alone would drop it.
        let ttl = hasFieldExpiry ? pair.ttlMilliseconds : nil
        if newField == pair.field {
            controller.write("Updated \(field)") {
                try await RedisValues.setHashField($0, key, field: newField, value: newValue, keepingTTL: ttl)
            }
        } else {
            controller.write("Renamed field to \(field)") {
                try await RedisValues.renameHashField(
                    $0, key, from: pair.field, to: newField, value: newValue, keepingTTL: ttl)
            }
        }
        selection = []
    }
}

// MARK: - List

struct RedisListEditor: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let items: [Data]
    let offset: Int

    struct Row: Identifiable {
        let index: Int
        let value: Data
        var id: Int { index }
    }

    @State private var selection: Set<Int> = []
    @State private var value = ""

    private var rows: [Row] { items.enumerated().map { Row(index: offset + $0.offset, value: $0.element) } }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("#") { row in Text("\(row.index)").monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 30, ideal: 50, max: 80)
                TableColumn("Value") { row in
                    Text(RedisFormat.text(row.value)).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
            }
            .onChange(of: selection) { _, selected in
                if selected.count == 1, let index = selected.first, let row = rows.first(where: { $0.index == index }) {
                    value = RedisFormat.text(row.value)
                }
            }
            RedisPagingBar(controller: controller, shown: items.count) {
                Button("Remove") {
                    let chosen = rows.filter { selection.contains($0.index) }.map { (index: $0.index, expected: $0.value) }
                    controller.write("Removed \(chosen.count) element\(chosen.count == 1 ? "" : "s")", destructive: true) {
                        try await RedisValues.removeListItems($0, key, items: chosen)
                    }
                    selection = []
                }
                .disabled(selection.isEmpty)
            }
            Divider()
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                RedisValueField(title: "Value", text: $value)
                HStack {
                    Spacer()
                    if selection.count == 1, let index = selection.first, let row = rows.first(where: { $0.index == index }) {
                        Button("Update #\(index)") {
                            let newValue = RedisText.parse(value)
                            controller.write("Updated element \(index)") {
                                try await RedisValues.setListItem($0, key, index: index, expected: row.value, value: newValue)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Push to Head") { push(.head) }
                    Button("Push to Tail") { push(.tail) }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .padding(DesignTokens.Spacing.md)
        }
    }

    private func push(_ end: RedisValues.ListEnd) {
        let newValue = RedisText.parse(value)
        controller.write(end == .head ? "Pushed to the head" : "Pushed to the tail") {
            try await RedisValues.push($0, key, [newValue], at: end)
        }
        value = ""
    }
}

// MARK: - Set

struct RedisSetEditor: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let members: [Data]

    struct Row: Identifiable {
        let member: Data
        var id: Data { member }
    }

    @State private var selection: Set<Data> = []
    @State private var member = ""

    var body: some View {
        VStack(spacing: 0) {
            Table(members.map(Row.init), selection: $selection) {
                TableColumn("Member") { row in
                    Text(RedisFormat.text(row.member)).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
            }
            .onChange(of: selection) { _, selected in
                if selected.count == 1, let first = selected.first { member = RedisFormat.text(first) }
            }
            RedisPagingBar(controller: controller, shown: members.count, filterable: true) {
                Button("Remove") {
                    let chosen = Array(selection)
                    controller.write("Removed \(chosen.count) member\(chosen.count == 1 ? "" : "s")", destructive: true) {
                        try await RedisValues.removeSetMembers($0, key, chosen)
                    }
                    selection = []
                }
                .disabled(selection.isEmpty)
            }
            Divider()
            HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
                RedisValueField(title: "Member", text: $member, multiline: false)
                if selection.count == 1, let old = selection.first {
                    Button("Replace") {
                        let new = RedisText.parse(member)
                        controller.write("Replaced a member") { try await RedisValues.replaceSetMember($0, key, old: old, new: new) }
                        selection = []
                    }
                }
                Button("Add") {
                    let new = RedisText.parse(member)
                    controller.write("Added a member") { try await RedisValues.addSetMembers($0, key, [new]) }
                    member = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(member.isEmpty)
            }
            .controlSize(.small)
            .padding(DesignTokens.Spacing.md)
        }
    }
}

// MARK: - Sorted set

struct RedisSortedSetEditor: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let members: [RedisScoredMember]

    struct Row: Identifiable {
        let item: RedisScoredMember
        var id: Data { item.member }
    }

    @State private var selection: Set<Data> = []
    @State private var member = ""
    @State private var score = ""

    private var isScoreValid: Bool {
        let trimmed = score.trimmingCharacters(in: .whitespaces).lowercased()
        return Double(trimmed) != nil || ["inf", "+inf", "-inf"].contains(trimmed)
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(members.map(Row.init), selection: $selection) {
                TableColumn("Score") { row in Text(row.item.score).monospacedDigit() }
                    .width(min: 60, ideal: 100, max: 180)
                TableColumn("Member") { row in
                    Text(RedisFormat.text(row.item.member)).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
            }
            .onChange(of: selection) { _, selected in
                if selected.count == 1, let id = selected.first, let row = members.first(where: { $0.member == id }) {
                    member = RedisFormat.text(row.member)
                    score = row.score
                }
            }
            RedisPagingBar(controller: controller, shown: members.count) {
                Button("Remove") {
                    let chosen = Array(selection)
                    controller.write("Removed \(chosen.count) member\(chosen.count == 1 ? "" : "s")", destructive: true) {
                        try await RedisValues.removeSortedMembers($0, key, chosen)
                    }
                    selection = []
                }
                .disabled(selection.isEmpty)
            }
            Divider()
            HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
                RedisValueField(title: "Score", text: $score, multiline: false).frame(width: 120)
                RedisValueField(title: "Member", text: $member, multiline: false)
                if selection.count == 1, let old = selection.first {
                    Button("Update") {
                        let new = RedisScoredMember(member: RedisText.parse(member), score: score.trimmingCharacters(in: .whitespaces))
                        controller.write("Updated a member") {
                            try await RedisValues.replaceSortedMember($0, key, old: old, new: new)
                        }
                        selection = []
                    }
                    .disabled(!isScoreValid)
                }
                Button("Add") {
                    let new = RedisScoredMember(member: RedisText.parse(member), score: score.trimmingCharacters(in: .whitespaces))
                    controller.write("Added a member") { try await RedisValues.addSortedMembers($0, key, [new]) }
                    member = ""
                    score = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(member.isEmpty || !isScoreValid)
            }
            .controlSize(.small)
            .padding(DesignTokens.Spacing.md)
        }
    }
}

// MARK: - Stream

struct RedisStreamEditor: View {
    @Bindable var controller: RedisTabController
    let key: RedisKey
    let entries: [RedisStreamEntry]

    @State private var selection: Set<String> = []
    @State private var fieldsText = ""
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            Table(entries, selection: $selection) {
                TableColumn("ID") { entry in Text(entry.id).font(.system(.body, design: .monospaced)) }
                    .width(min: 120, ideal: 170, max: 240)
                TableColumn("Fields") { entry in
                    Text(entry.fields.map { "\(RedisFormat.text($0.field))=\(RedisFormat.text($0.value))" }.joined(separator: "  "))
                        .font(.system(.body, design: .monospaced)).lineLimit(1)
                }
            }
            RedisPagingBar(controller: controller, shown: entries.count) {
                Button("Delete") {
                    let ids = Array(selection)
                    controller.write("Deleted \(ids.count) entr\(ids.count == 1 ? "y" : "ies")", destructive: true) {
                        try await RedisValues.deleteStreamEntries($0, key, ids: ids)
                    }
                    selection = []
                }
                .disabled(selection.isEmpty)
            }
            if !controller.streamGroups.isEmpty {
                Divider()
                SimpleTable(
                    columns: [
                        .init(title: "Consumer group", width: 180), .init(title: "Consumers", width: 90, isNumeric: true),
                        .init(title: "Pending", width: 80, isNumeric: true), .init(title: "Last delivered"),
                    ],
                    rows: controller.streamGroups.map {
                        [$0.name, String($0.consumers), String($0.pending), $0.lastDeliveredID]
                    }
                )
                .frame(height: min(CGFloat(controller.streamGroups.count + 1) * DesignTokens.Metrics.gridRowHeight + 8, 120))
            }
            Divider()
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                RedisValueField(title: "New entry: one field=value per line", text: $fieldsText)
                HStack {
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    Button("Add Entry") { add() }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .padding(DesignTokens.Spacing.md)
        }
    }

    private func add() {
        let pairs = RedisNewKeyParsing.pairs(fieldsText)
        guard !pairs.isEmpty else {
            problem = "Write at least one field=value line."
            return
        }
        problem = nil
        controller.write("Added an entry") { try await RedisValues.addStreamEntry($0, key, fields: pairs) }
        fieldsText = ""
    }
}
