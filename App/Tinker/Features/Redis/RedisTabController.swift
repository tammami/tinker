import DBCore
import DBRedis
import Foundation
import Observation

/// The panes of a Redis tab.
public enum RedisTabMode: String, CaseIterable, Identifiable, Sendable {
    case keys = "Keys"
    case console = "Console"
    case server = "Server"
    public var id: String { rawValue }
}

/// One Redis tab: a logical database's keys, a console on it, and the server's own view.
///
/// Every server call goes through the connection's ``RedisSession`` actor; this object
/// only holds what the view shows. Writes refuse on a read-only connection and ask first
/// on a production one, like every write elsewhere in the app.
@MainActor
@Observable
public final class RedisTabController {
    public typealias Mode = RedisTabMode

    public let connectionID: UUID
    public private(set) var database: Int
    private let environment: AppEnvironment
    /// Hands a confirmation to the window, which shows it as a sheet.
    var confirm: (DestructiveConfirmation) -> Void = { _ in }
    /// Called after a change the sidebar's key counts should reflect.
    var onKeyspaceChanged: () -> Void = {}
    /// Called when the tab moves to another logical database, so its title follows.
    var onDatabaseChanged: (Int) -> Void = { _ in }

    public var mode: Mode = .keys
    public private(set) var info: RedisServerInfo?
    /// The last failure, as the server said it.
    public var failure: String?
    /// A short note after something worked ("Saved", "3 keys deleted").
    public var notice: String?

    // MARK: Keys

    public var pattern = "*"
    public var typeFilter: RedisKeyType?
    public private(set) var keys: [RedisKeyInfo] = []
    public private(set) var cursor = "0"
    public private(set) var isScanning = false
    public private(set) var hasScanned = false
    public var selection: Set<Data> = []
    public private(set) var selectedKey: RedisKeyInfo?
    public private(set) var value: RedisValuePage?
    public private(set) var isLoadingValue = false
    /// Groups and TTL of a stream, shown under its entries.
    public private(set) var streamGroups: [RedisStreamGroup] = []
    /// How the server holds the open key: encoding, idle time, access frequency.
    public private(set) var metadata: RedisKeyMetadata?
    /// What the open key is besides its type: a HyperLogLog, a geospatial index.
    public private(set) var facet: RedisFacet?
    /// The open string read as a bitmap, once that view was asked for.
    public private(set) var bitmap: RedisBitmap?
    /// Where the members of the open sorted set are, once that view was asked for.
    public private(set) var positions: [RedisGeoMember] = []
    /// The vector set element last picked, with its vector and attributes.
    public private(set) var vectorElement: RedisVectorElement?
    /// The elements nearest to it.
    public private(set) var vectorMatches: [RedisVectorMatch] = []
    /// What a probabilistic key answered to the last question.
    public private(set) var answer: String?
    /// A filter inside the selected hash or set (HSCAN/SSCAN MATCH).
    public var valueFilter = ""
    /// How many keys one "Load More" asks for.
    static let scanStep = 1_000
    /// Bumped whenever the list starts over (a new pattern, type or database): a scan
    /// that started before it drops its results instead of mixing them into the new list.
    private var scanGeneration = 0
    /// Bumped by every `open`: only the latest key asked for fills the detail pane.
    private var openGeneration = 0

    public var isComplete: Bool { cursor == "0" && hasScanned }
    public var config: ConnectionConfig? { environment.connections.first { $0.id == connectionID } }
    private var session: RedisSession? { environment.redisSession(for: connectionID) }

    public init(connectionID: UUID, database: Int, environment: AppEnvironment) {
        self.connectionID = connectionID
        self.database = database
        self.environment = environment
    }

    // MARK: - Loading

    /// Connects, describes the server and lists the first keys.
    public func start() async {
        guard let session else {
            failure = "This connection is no longer in the list."
            return
        }
        do {
            info = try await session.connect()
            await rescan()
        } catch {
            failure = Self.message(error)
        }
    }

    /// Lists keys from the beginning with the current pattern and type.
    public func rescan() async {
        scanGeneration += 1
        keys = []
        cursor = "0"
        hasScanned = false
        selection = []
        isScanning = false
        await loadMore()
    }

    /// Scans on from where the list ended, about ``scanStep`` keys at a time.
    public func loadMore() async {
        guard let session, !isScanning, !(hasScanned && cursor == "0") else { return }
        isScanning = true
        let generation = scanGeneration
        defer { if generation == scanGeneration { isScanning = false } }
        let pattern = pattern.trimmingCharacters(in: .whitespaces).isEmpty ? "*" : pattern
        let type = typeFilter
        let from = cursor
        let database = database
        do {
            let (page, infos) = try await session.withConnection(database: database) { connection in
                let page = try await RedisKeyspace.scan(
                    connection, from: from, match: pattern, type: type, limit: Self.scanStep)
                let infos = try await RedisKeyspace.describe(connection, page.keys.sorted(), memory: false)
                return (page, infos)
            }
            // Another pattern, type or database was asked for meanwhile: these belong to the old one.
            guard generation == scanGeneration else { return }
            let known = Set(keys.map(\.id))
            keys += infos.filter { !known.contains($0.id) }
            // user:2 before user:10, as a person reads them.
            keys.sort { $0.key.display.localizedStandardCompare($1.key.display) == .orderedAscending }
            cursor = page.cursor
            hasScanned = true
        } catch {
            if generation == scanGeneration { failure = Self.message(error) }
        }
    }

    /// Opens a key: its details and the first page of its value.
    public func open(_ key: RedisKey) async {
        guard let session else { return }
        openGeneration += 1
        let request = openGeneration
        let database = database
        isLoadingValue = true
        defer { if request == openGeneration { isLoadingValue = false } }
        valueFilter = ""
        let server = info
        do {
            let opened = try await session.withConnection(database: database) { connection -> OpenedKey? in
                guard var info = try await RedisKeyspace.describe(connection, [key]).first else { return nil }
                let page = try await RedisValues.read(connection, key, type: info.type, server: server)
                var opened = OpenedKey(info: info, page: page)
                if info.type == .stream { opened.groups = (try? await RedisValues.streamGroups(connection, key)) ?? [] }
                if server?.supports("object") ?? true {
                    opened.metadata = try? await RedisFacets.metadata(connection, key)
                }
                switch page {
                case let .string(data) where RedisFacets.isHyperLogLog(data) && (server?.supports("pfcount") ?? true):
                    // A string that is not a HyperLogLog after all answers WRONGTYPE; it stays a string.
                    if let count = try? await RedisFacets.hyperLogLogCount(connection, key) {
                        opened.facet = .hyperLogLog(count: count)
                    }
                case let .zset(members, _)
                where RedisFacets.looksGeospatial(members) && (server?.supports("geopos") ?? true):
                    opened.facet = .geospatial
                case let .timeSeries(series, _, _):
                    info.length = series.totalSamples
                    opened.info = info
                default:
                    break
                }
                return opened
            }
            // A later click asked for another key; this answer is for one no longer shown.
            guard request == openGeneration, database == self.database else { return }
            guard let opened else {
                failure = "\(key.display) no longer exists."
                keys.removeAll { $0.key == key }
                selectedKey = nil
                value = nil
                clearDetails()
                return
            }
            let isSameKey = selectedKey?.key == key
            selectedKey = opened.info
            value = opened.page
            streamGroups = opened.groups
            metadata = opened.metadata
            facet = opened.facet
            // A reload of the same key keeps the views that were asked for up to date.
            if isSameKey {
                if bitmap != nil { await loadBitmap() }
                if !positions.isEmpty { await loadPositions() }
            } else {
                clearDetails()
                metadata = opened.metadata
                facet = opened.facet
            }
            if let index = keys.firstIndex(where: { $0.key == key }) { keys[index] = opened.info }
        } catch {
            if request == openGeneration { failure = Self.message(error) }
        }
    }

    /// What one round of opening a key read.
    private struct OpenedKey: Sendable {
        var info: RedisKeyInfo
        var page: RedisValuePage
        var groups: [RedisStreamGroup] = []
        var metadata: RedisKeyMetadata?
        var facet: RedisFacet?
    }

    /// Forgets what belonged to the key that was open.
    private func clearDetails() {
        metadata = nil
        facet = nil
        bitmap = nil
        positions = []
        vectorElement = nil
        vectorMatches = []
        answer = nil
    }

    /// Reads the next page of the open key's value and appends it.
    public func loadMoreValue() async {
        guard let session, let selected = selectedKey, let current = value else { return }
        let filter = valueFilter
        let (request, server) = (openGeneration, info)
        do {
            let next = try await session.withConnection(database: database) { connection in
                try await RedisValues.read(
                    connection, selected.key, type: selected.type, continuing: current, match: filter, server: server)
            }
            // Another key was opened while this page was on its way: it is not that key's.
            guard request == openGeneration, value == current else { return }
            value = Self.merge(current, next)
        } catch {
            failure = Self.message(error)
        }
    }

    /// Re-reads the open key's value with the filter applied.
    public func applyValueFilter() async {
        guard let session, let selected = selectedKey else { return }
        let filter = valueFilter
        let (request, server) = (openGeneration, info)
        do {
            let page = try await session.withConnection(database: database) { connection in
                try await RedisValues.read(connection, selected.key, type: selected.type, match: filter, server: server)
            }
            guard request == openGeneration else { return }
            value = page
        } catch {
            failure = Self.message(error)
        }
    }

    // MARK: - Views of a key beside its value

    /// Runs a read for the open key and hands the result over only if that key is still open.
    private func readDetail<T: Sendable>(
        _ body: @escaping @Sendable (RedisConnection, RedisKey) async throws -> T, then store: (T) -> Void
    ) async {
        guard let session, let key = selectedKey?.key else { return }
        let request = openGeneration
        do {
            let result = try await session.withConnection(database: database) { try await body($0, key) }
            guard request == openGeneration else { return }
            store(result)
        } catch {
            if request == openGeneration { failure = Self.message(error) }
        }
    }

    /// The open string as a bitmap: size, set bits, first bits.
    public func loadBitmap() async {
        await readDetail({ try await RedisFacets.bitmap($0, $1) }, then: { bitmap = $0 })
    }

    /// Where the members read so far are (`GEOPOS`), a page at a time.
    public func loadPositions() async {
        guard case let .zset(members, _) = value else { return }
        await readDetail(
            { connection, key in
                var found: [RedisGeoMember] = []
                for start in stride(from: 0, to: members.count, by: RedisValues.pageSize) {
                    let page = Array(members[start ..< min(start + RedisValues.pageSize, members.count)])
                    found += try await RedisFacets.positions(connection, key, of: page)
                }
                return found
            }, then: { positions = $0 })
    }

    /// One element of the open vector set: its vector, its attributes and its neighbours.
    public func loadVectorElement(_ element: Data) async {
        let canSearch = info?.supports("vsim") ?? true
        await readDetail(
            { connection, key in
                let detail = try await RedisModuleValues.vectorElement(connection, key, element: element)
                let matches = canSearch ? try await RedisModuleValues.similar(connection, key, to: element) : []
                return (detail, matches)
            },
            then: { result in
                vectorElement = result.0
                // The element itself is its own nearest neighbour; it is not news.
                vectorMatches = result.1.filter { $0.element != element }
            })
    }

    public func clearAnswer() { answer = nil }

    /// Asks the open probabilistic key about one item.
    public func ask(_ item: String) async {
        guard let type = selectedKey?.type, !item.isEmpty else { return }
        answer = nil
        await readDetail({ try await RedisModuleValues.ask($0, $1, type: type, item: item) }, then: { answer = $0 })
    }

    public func reloadSelected() async {
        guard let key = selectedKey?.key else { return }
        await open(key)
    }

    /// Whether the open value has more to read.
    public var valueHasMore: Bool {
        switch value {
        case let .hash(_, cursor), let .set(_, cursor): cursor != "0"
        case let .list(items, _): items.count >= RedisValues.pageSize && items.count < Int(selectedKey?.length ?? 0)
        case let .zset(members, _):
            members.count >= RedisValues.pageSize && members.count < Int(selectedKey?.length ?? 0)
        case let .stream(_, next): next != nil
        case let .timeSeries(_, _, next): next != nil
        case let .vectorSet(_, _, next, _): next != nil
        default: false
        }
    }

    static func merge(_ old: RedisValuePage, _ new: RedisValuePage) -> RedisValuePage {
        switch (old, new) {
        case let (.hash(a, _), .hash(b, cursor)):
            let seen = Set(a.map(\.field))
            return .hash(fields: a + b.filter { !seen.contains($0.field) }, cursor: cursor)
        case let (.set(a, _), .set(b, cursor)):
            let seen = Set(a)
            return .set(members: a + b.filter { !seen.contains($0) }, cursor: cursor)
        case let (.list(a, offset), .list(b, _)):
            return .list(items: a + b, offset: offset)
        case let (.zset(a, offset), .zset(b, _)):
            return .zset(members: a + b, offset: offset)
        case let (.stream(a, _), .stream(b, next)):
            return .stream(entries: a + b, next: next)
        case let (.timeSeries(_, a, _), .timeSeries(info, b, next)):
            return .timeSeries(info: info, samples: a + b, next: next)
        case let (.vectorSet(_, a, _, _), .vectorSet(info, b, next, isSample)):
            return .vectorSet(info: info, elements: a + b, next: next, isSample: isSample)
        default:
            return new
        }
    }

    // MARK: - Writing

    /// Runs a write on this database's connection, after the read-only check and, on a
    /// production connection, the user's confirmation.
    func write(
        _ title: String, detail: String? = nil, destructive: Bool = false, typedName: String? = nil,
        reload: Bool = true, after: (@MainActor () async -> Void)? = nil,
        _ body: @escaping @Sendable (RedisConnection) async throws -> Void
    ) {
        guard let session else { return }
        let run: @MainActor () async -> Void = { [weak self] in
            guard let self else { return }
            if await session.isReadOnly {
                failure = "This connection is read-only. Unlock it with ⌘⇧L to change data."
                return
            }
            do {
                try await session.withConnection(database: database) { try await body($0) }
                notice = title
                if reload { await reloadSelected() }
                await after?()
            } catch {
                failure = Self.message(error)
            }
        }
        let isProduction = config?.isProduction ?? false
        if destructive || isProduction {
            let confirm = confirm
            // Often asked from an alert or a sheet that is closing: the question waits for
            // it to be gone, or the window would have two sheets at once and show neither.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                confirm(
                    DestructiveConfirmation(
                        title: isProduction ? "\(title) on production?" : "\(title)?",
                        message: isProduction
                            ? "\(config?.name ?? "This connection") is a production server. db\(database)."
                            : "db\(database) on \(config?.name ?? "the server").",
                        detail: detail,
                        requiredTypedName: typedName ?? (isProduction ? config?.name : nil),
                        confirmTitle: destructive ? "Delete" : "Apply",
                        action: run))
            }
        } else {
            Task { await run() }
        }
    }

    public func deleteSelectedKeys() {
        let chosen = keys.filter { selection.contains($0.id) }.map(\.key)
        guard !chosen.isEmpty else { return }
        let detail = chosen.prefix(50).map(\.display).joined(separator: "\n") + (chosen.count > 50 ? "\n…" : "")
        write(
            "Delete \(chosen.count) key\(chosen.count == 1 ? "" : "s")", detail: detail, destructive: true,
            reload: false,
            after: { [weak self] in await self?.afterKeyspaceChange(removing: chosen) }
        ) { connection in
            _ = try await RedisKeyspace.delete(connection, chosen)
        }
    }

    /// Deletes every key matching a pattern, SCAN by SCAN — never `KEYS`, which blocks the server.
    public func deleteMatching(_ pattern: String) {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !Self.matchesEverything(pattern) else {
            failure = "\(pattern) matches every key. To delete everything, use Empty db\(database)."
            return
        }
        write(
            "Delete every key matching \(pattern)", detail: "UNLINK in batches of the keys SCAN finds for \(pattern)",
            // On production the server's name is typed, not just the pattern.
            destructive: true, typedName: config?.isProduction == true ? config?.name : pattern, reload: false,
            after: { [weak self] in await self?.afterKeyspaceChange(removing: nil) }
        ) { connection in
            var cursor = "0"
            repeat {
                let page = try await RedisKeyspace.scan(connection, cursor: cursor, match: pattern, count: 1_000)
                cursor = page.cursor
                _ = try await RedisKeyspace.delete(connection, page.keys)
            } while cursor != "0"
        }
    }

    /// `FLUSHDB`: empties this logical database. Always asks, with the database typed.
    public func flushDatabase() {
        write(
            "Empty db\(database)", detail: "FLUSHDB ASYNC — every key in db\(database) is deleted.", destructive: true,
            typedName: "db\(database)", reload: false,
            after: { [weak self] in await self?.afterKeyspaceChange(removing: nil) }
        ) { connection in
            try await connection.send(["FLUSHDB", "ASYNC"])
        }
    }

    /// Patterns that match everything; deleting by one of them is Empty Database, which
    /// asks for the database's name instead.
    static func matchesEverything(_ pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.allSatisfy { $0 == "*" }
    }

    public func rename(_ key: RedisKey, to name: String) {
        let target = RedisKey(RedisText.parse(name))
        guard target != key, !target.bytes.isEmpty else { return }
        write(
            "Rename \(key.display)", reload: false,
            after: { [weak self] in
                await self?.rescan()
                await self?.open(target)
            }
        ) { connection in
            try await RedisKeyspace.rename(connection, key, to: target)
        }
    }

    public func setTTL(_ key: RedisKey, seconds: Int64?) {
        write(seconds == nil ? "Remove the expiry of \(key.display)" : "Set the expiry of \(key.display)") {
            connection in
            try await RedisKeyspace.setTTL(connection, key, milliseconds: seconds.map { $0 * 1_000 })
        }
    }

    public func duplicate(_ key: RedisKey, to name: String) {
        let target = RedisKey(RedisText.parse(name))
        guard !target.bytes.isEmpty, target != key else {
            failure = "A copy needs a name of its own."
            return
        }
        write(
            "Duplicate \(key.display)", reload: false,
            after: { [weak self] in
                await self?.rescan()
                self?.onKeyspaceChanged()
            }
        ) { connection in
            try await RedisKeyspace.duplicate(connection, key, to: target)
        }
    }

    public func create(
        name: String, kind: RedisNewKeyKind, initial: RedisInitialValue,
        settings: [RedisNewKeySetting.Name: String] = [:], ttlSeconds: Int64?
    ) async -> Bool {
        // On production the New Key sheet itself asks for the server's name (its
        // ProductionGate) before this is called: a second sheet cannot open over it.
        guard let session else { return false }
        let key = RedisKey(RedisText.parse(name))
        guard !key.bytes.isEmpty else {
            failure = "A key needs a name."
            return false
        }
        if await session.isReadOnly {
            failure = "This connection is read-only. Unlock it with ⌘⇧L to change data."
            return false
        }
        do {
            try await session.withConnection(database: database) { connection in
                try await RedisValues.create(
                    connection, key, kind: kind, initial: initial, settings: settings, ttlSeconds: ttlSeconds)
            }
            notice = "Created \(key.display)"
            await rescan()
            await open(key)
            onKeyspaceChanged()
            return true
        } catch {
            failure = Self.message(error)
            return false
        }
    }

    /// After keys went: the open one closes if it was among them, and the list is re-read.
    private func afterKeyspaceChange(removing removed: [RedisKey]?) async {
        if removed == nil || (selectedKey.map { removed?.contains($0.key) ?? false } ?? false) {
            selectedKey = nil
            value = nil
            clearDetails()
        }
        await rescan()
        onKeyspaceChanged()
    }

    /// Switches the tab to another logical database.
    public func switchDatabase(_ index: Int) async {
        guard index != database else { return }
        guard index >= 0, index < (info?.databaseCount ?? 16) else {
            failure = "db\(index) does not exist; this server has \(info?.databaseCount ?? 16) databases."
            return
        }
        database = index
        // Whatever was being read belongs to the database that was left.
        openGeneration += 1
        selectedKey = nil
        value = nil
        clearDetails()
        onDatabaseChanged(index)
        await consoleConnection?.close()
        consoleConnection = nil
        await rescan()
    }

    // MARK: - Console

    public struct ConsoleEntry: Identifiable, Hashable {
        public let id = UUID()
        public let command: String
        public let output: String
        public let isError: Bool
        public let milliseconds: Int
    }

    public private(set) var console: [ConsoleEntry] = []
    /// The console's own connection: what a user types never changes the state of the
    /// connection the key browser relies on.
    private var consoleConnection: RedisConnection?
    /// The last command queued: each waits for the one before, so lines typed while one
    /// runs are answered in order instead of being dropped.
    private var consoleQueue: Task<Void, Never>?
    public var consoleInput = ""
    public private(set) var isRunningCommand = false
    private var history: [String] = []
    private var historyIndex: Int?

    /// Runs the typed line. Writes on a read-only connection are refused before they go;
    /// on a production connection they are confirmed first.
    public func runConsole() {
        let line = consoleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        consoleInput = ""
        if history.last != line { history.append(line) }
        historyIndex = nil
        if line.lowercased() == "clear" {
            console = []
            return
        }
        let arguments: [Data]
        do {
            arguments = try RedisCommandLine.split(line)
        } catch {
            console.append(ConsoleEntry(command: line, output: "(error) \(error)", isError: true, milliseconds: 0))
            return
        }
        guard let first = arguments.first.map({ String(decoding: $0, as: UTF8.self) }) else { return }
        if first.uppercased() == "SELECT" {
            guard arguments.count == 2, let index = Int(String(decoding: arguments[1], as: UTF8.self)),
                index >= 0, index < (info?.databaseCount ?? 16)
            else {
                console.append(
                    ConsoleEntry(
                        command: line, output: "(error) ERR DB index is out of range", isError: true, milliseconds: 0))
                return
            }
            Task {
                await switchDatabase(index)
                console.append(ConsoleEntry(command: line, output: "OK", isError: false, milliseconds: 0))
            }
            return
        }
        let isWrite: Bool
        switch RedisCommandLine.verdict(arguments.map { String(decoding: $0, as: UTF8.self) }) {
        case .read: isWrite = false
        case .write: isWrite = true
        case let .refused(reason):
            console.append(ConsoleEntry(command: line, output: "(error) " + reason, isError: true, milliseconds: 0))
            return
        }
        let send: @MainActor () async -> Void = { [weak self] in
            guard let self, let session else { return }
            if isWrite, await session.isReadOnly {
                console.append(
                    ConsoleEntry(
                        command: line,
                        output:
                            "(error) This connection is read-only. Unlock it with ⌘⇧L to run \(first.uppercased()).",
                        isError: true, milliseconds: 0))
                return
            }
            isRunningCommand = true
            defer { isRunningCommand = false }
            let started = ContinuousClock.now
            do {
                let connection = try await consoleConnection(session)
                let reply: RESPValue
                do {
                    reply = try await connection.sendRaw(arguments.map(RedisArgument.init))
                } catch {
                    // A dropped console connection is opened afresh next time; the command
                    // is not re-sent, since the server may have run it.
                    consoleConnection = nil
                    await connection.close()
                    throw error
                }
                let elapsed = ContinuousClock.now - started
                var isError = false
                if case .error = reply { isError = true }
                console.append(
                    ConsoleEntry(
                        command: line, output: RedisReplyFormatter.format(reply), isError: isError,
                        milliseconds: Int(
                            elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                    ))
                if isWrite, !isError { onKeyspaceChanged() }
            } catch {
                console.append(
                    ConsoleEntry(
                        command: line, output: "(error) " + Self.message(error), isError: true, milliseconds: 0))
            }
        }
        if isWrite, config?.isProduction == true {
            confirm(
                DestructiveConfirmation(
                    title: "Run \(first.uppercased()) on production?",
                    message: "\(config?.name ?? "This connection") is a production server. db\(database).",
                    detail: line, requiredTypedName: config?.name, confirmTitle: "Run", action: send))
        } else {
            let previous = consoleQueue
            consoleQueue = Task {
                await previous?.value
                await send()
            }
        }
    }

    private func consoleConnection(_ session: RedisSession) async throws -> RedisConnection {
        if let consoleConnection, await consoleConnection.isOpen { return consoleConnection }
        let connection = try await session.dedicatedConnection(database: database)
        consoleConnection = connection
        return connection
    }

    /// Closes what the tab holds of its own; the session's shared connections stay.
    public func close() {
        let connection = consoleConnection
        consoleConnection = nil
        Task { await connection?.close() }
    }

    /// ↑ and ↓ in the console input walk the history.
    public func historyStep(_ delta: Int) {
        guard !history.isEmpty else { return }
        let next = (historyIndex ?? history.count) + delta
        guard next >= 0 else { return }
        if next >= history.count {
            historyIndex = nil
            consoleInput = ""
        } else {
            historyIndex = next
            consoleInput = history[next]
        }
    }

    public func clearConsole() { console = [] }

    // MARK: - Server

    public private(set) var serverInfo: RedisInfo?
    public private(set) var clients: [[String: String]] = []
    public private(set) var slowlog: [[String]] = []
    public private(set) var configuration: [(String, String)] = []

    public func loadServer() async {
        guard let session else { return }
        do {
            let replies = try await session.withConnection(database: database) { connection in
                try await connection.pipeline([
                    ["INFO", "everything"], ["CLIENT", "LIST"], ["SLOWLOG", "GET", "64"], ["CONFIG", "GET", "*"],
                ])
            }
            serverInfo = RedisInfo.parse(replies[0].string ?? "")
            clients = (replies[1].string ?? "").split(whereSeparator: \.isNewline).map { line in
                var fields: [String: String] = [:]
                for part in line.split(separator: " ") {
                    let pair = part.split(separator: "=", maxSplits: 1)
                    if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
                }
                return fields
            }
            slowlog = (replies[2].array ?? []).map { entry in
                let parts = entry.array ?? []
                let when =
                    parts.count > 1
                    ? parts[1].integer.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted() } ?? "" : ""
                let micros = parts.count > 2 ? parts[2].integer.map { "\($0) µs" } ?? "" : ""
                let command = parts.count > 3 ? (parts[3].array ?? []).compactMap(\.string).joined(separator: " ") : ""
                return [when, micros, command]
            }
            configuration = replies[3].pairs.compactMap { pair in
                guard let key = pair.0.string else { return nil }
                return (key, pair.1.string ?? "")
            }.sorted { $0.0 < $1.0 }
        } catch {
            failure = Self.message(error)
        }
    }

    // MARK: -

    static func message(_ error: any Error) -> String {
        (error as? DBError)?.errorDescription ?? (error as? RedisCommandLine.ParseError)?.description
            ?? String(describing: error)
    }
}
