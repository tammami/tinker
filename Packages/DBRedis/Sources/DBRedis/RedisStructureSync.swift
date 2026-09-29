import DBCore
import Foundation

/// A difference in structure between two Redis databases, with the commands that make
/// the target match.
///
/// A Redis "structure" is what is not a value: the search indexes (RediSearch, built
/// into Redis 8 and Redis Stack) and the consumer groups of streams. Keys themselves are
/// data, and belong to Data Synchronization.
public struct RedisStructureChange: Sendable, Hashable, Identifiable {
    public enum Action: String, Sendable, Hashable {
        case create, drop, recreate
    }

    public enum Object: Sendable, Hashable {
        case searchIndex(String)
        case consumerGroup(stream: RedisKey, group: String)
    }

    public let action: Action
    public let object: Object
    /// One line for the list: what differs.
    public let summary: String
    /// Run in order on the target.
    public let commands: [[RedisArgument]]

    public var id: String {
        switch object {
        case let .searchIndex(name): "index/\(name)/\(action.rawValue)"
        case let .consumerGroup(stream, group): "group/\(stream.display)/\(group)/\(action.rawValue)"
        }
    }

    /// The commands as `redis-cli` would take them, for the preview.
    public var preview: String {
        commands.map { command in
            command.map { argument in
                let text = RedisText.display(argument.bytes)
                return text.isEmpty || text.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" })
                    ? RedisReplyFormatter.quoted(argument.bytes) : text
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

public enum RedisStructureSync {
    /// Compares search indexes and the consumer groups of matching streams.
    public static func compare(
        source: RedisEndpoint, target: RedisEndpoint, pattern: String = "*", dropExtras: Bool = false
    ) async throws -> [RedisStructureChange] {
        let (reader, other) = try await RedisEndpoint.pair(source, target)
        defer {
            Task {
                await reader.close()
                await other.close()
            }
        }
        var changes = try await compareIndexes(reader, other, dropExtras: dropExtras)
        changes += try await compareGroups(reader, other, pattern: pattern, dropExtras: dropExtras)
        return changes
    }

    /// Runs the chosen changes on the target, stopping at the first the server refuses.
    public static func apply(_ changes: [RedisStructureChange], target: RedisEndpoint) async throws {
        let writer = try await target.session.dedicatedConnection(database: target.database)
        defer { Task { await writer.close() } }
        for change in changes {
            for command in change.commands { try await writer.send(command) }
        }
    }

    // MARK: - Search indexes

    static func indexNames(_ connection: RedisConnection) async throws -> [String] {
        let reply = try await connection.sendRaw(["FT._LIST"])
        // No search module: no indexes to compare, on this side.
        if case .error = reply { return [] }
        return (reply.array ?? []).compactMap(\.string).sorted()
    }

    private static func compareIndexes(_ source: RedisConnection, _ target: RedisConnection, dropExtras: Bool)
        async throws -> [RedisStructureChange]
    {
        let mine = try await indexNames(source)
        let theirs = Set(try await indexNames(target))
        var changes: [RedisStructureChange] = []
        for name in mine {
            let definition = try await indexDefinition(source, name)
            guard theirs.contains(name) else {
                changes.append(
                    RedisStructureChange(
                        action: .create, object: .searchIndex(name), summary: "Search index \(name) is missing",
                        commands: [definition]))
                continue
            }
            let existing = try await indexDefinition(target, name)
            if existing != definition {
                // Dropped without DD: the documents stay, and the new index re-reads them.
                changes.append(
                    RedisStructureChange(
                        action: .recreate, object: .searchIndex(name),
                        summary: "Search index \(name) is defined differently",
                        commands: [["FT.DROPINDEX", RedisArgument(name)], definition]))
            }
        }
        if dropExtras {
            for name in theirs.subtracting(mine).sorted() {
                changes.append(
                    RedisStructureChange(
                        action: .drop, object: .searchIndex(name), summary: "Search index \(name) is only on the target",
                        commands: [["FT.DROPINDEX", RedisArgument(name)]]))
            }
        }
        return changes
    }

    static func indexDefinition(_ connection: RedisConnection, _ name: String) async throws -> [RedisArgument] {
        try createCommand(name: name, info: try await connection.send(["FT.INFO", RedisArgument(name)]))
    }

    /// Rebuilds `FT.CREATE` from `FT.INFO`. Throws for an attribute type it does not know,
    /// rather than create an index that differs from the one described.
    public static func createCommand(name: String, info: RESPValue) throws -> [RedisArgument] {
        var fields: [String: RESPValue] = [:]
        for (key, value) in info.pairs { if let key = key.string { fields[key] = value } }
        var definition: [String: RESPValue] = [:]
        for (key, value) in fields["index_definition"]?.pairs ?? [] { if let key = key.string { definition[key] = value } }

        var command: [RedisArgument] = ["FT.CREATE", RedisArgument(name)]
        command += ["ON", RedisArgument(definition["key_type"]?.string ?? "HASH")]
        let prefixes = (definition["prefixes"]?.array ?? []).compactMap(\.string)
        if !prefixes.isEmpty, prefixes != [""] {
            command += ["PREFIX", RedisArgument(prefixes.count)] + prefixes.map { RedisArgument($0) }
        }
        if let filter = definition["filter"]?.string, !filter.isEmpty { command += ["FILTER", RedisArgument(filter)] }
        if let language = definition["default_language"]?.string, language.lowercased() != "english" {
            command += ["LANGUAGE", RedisArgument(language)]
        }
        if let field = definition["language_field"]?.string { command += ["LANGUAGE_FIELD", RedisArgument(field)] }
        if let score = definition["default_score"]?.string, Double(score) != 1 {
            command += ["SCORE", RedisArgument(score)]
        }
        if let field = definition["score_field"]?.string { command += ["SCORE_FIELD", RedisArgument(field)] }
        if let field = definition["payload_field"]?.string { command += ["PAYLOAD_FIELD", RedisArgument(field)] }
        for option in (fields["index_options"]?.array ?? []).compactMap(\.string) {
            command.append(RedisArgument(option))
        }
        if let stopwords = fields["stopwords_list"]?.array {
            command += ["STOPWORDS", RedisArgument(stopwords.count)] + stopwords.compactMap(\.string).map { RedisArgument($0) }
        }
        command.append("SCHEMA")
        for attribute in fields["attributes"]?.array ?? [] {
            command += try attributeArguments(attribute.array ?? [])
        }
        return command
    }

    private static func attributeArguments(_ items: [RESPValue]) throws -> [RedisArgument] {
        var identifier = ""
        var alias = ""
        var type = ""
        var rest: [RESPValue] = []
        var index = 0
        while index < items.count {
            let key = items[index].string ?? ""
            switch key {
            case "identifier" where index + 1 < items.count:
                identifier = items[index + 1].string ?? ""
                index += 2
            case "attribute" where index + 1 < items.count:
                alias = items[index + 1].string ?? ""
                index += 2
            case "type" where index + 1 < items.count:
                type = (items[index + 1].string ?? "").uppercased()
                index += 2
            default:
                rest.append(items[index])
                index += 1
            }
        }
        var arguments: [RedisArgument] = [RedisArgument(identifier)]
        if alias != identifier, !alias.isEmpty { arguments += ["AS", RedisArgument(alias)] }
        arguments.append(RedisArgument(type))
        let flags = Set(rest.compactMap { $0.string?.uppercased() })
        func value(after name: String) -> String? {
            guard let position = rest.firstIndex(where: { $0.string?.uppercased() == name }), position + 1 < rest.count
            else { return nil }
            return rest[position + 1].string
        }
        func flag(_ name: String) { if flags.contains(name) { arguments.append(RedisArgument(name)) } }
        switch type {
        case "TEXT":
            flag("NOSTEM")
            if let weight = value(after: "WEIGHT"), Double(weight) != 1 { arguments += ["WEIGHT", RedisArgument(weight)] }
            if let phonetic = value(after: "PHONETIC") { arguments += ["PHONETIC", RedisArgument(phonetic)] }
            flag("WITHSUFFIXTRIE")
        case "TAG":
            if let separator = value(after: "SEPARATOR"), separator != "," {
                arguments += ["SEPARATOR", RedisArgument(separator)]
            }
            flag("CASESENSITIVE")
            flag("WITHSUFFIXTRIE")
        case "NUMERIC", "GEO":
            break
        case "GEOSHAPE":
            if let system = value(after: "COORD_SYSTEM") { arguments += [RedisArgument(system)] }
        case "VECTOR":
            // FT.INFO lists the vector's parameters as lowercase pairs after the algorithm.
            guard let algorithm = value(after: "ALGORITHM") else {
                throw DBError.protocolError("A vector attribute without an algorithm cannot be recreated.")
            }
            var parameters: [RedisArgument] = []
            var position = 0
            while position + 1 < rest.count {
                let key = (rest[position].string ?? "").lowercased()
                let text = rest[position + 1].string ?? ""
                position += 2
                switch key {
                case "algorithm": continue
                case "data_type": parameters += ["TYPE", RedisArgument(text)]
                case "dim": parameters += ["DIM", RedisArgument(text)]
                case "distance_metric": parameters += ["DISTANCE_METRIC", RedisArgument(text)]
                case "m": parameters += ["M", RedisArgument(text)]
                case "ef_construction": parameters += ["EF_CONSTRUCTION", RedisArgument(text)]
                case "ef_runtime": parameters += ["EF_RUNTIME", RedisArgument(text)]
                case "epsilon": parameters += ["EPSILON", RedisArgument(text)]
                case "initial_cap": parameters += ["INITIAL_CAP", RedisArgument(text)]
                case "block_size": parameters += ["BLOCK_SIZE", RedisArgument(text)]
                default:
                    // FT.INFO reports sizes and statistics next to the parameters; they
                    // are not part of the definition.
                    continue
                }
            }
            arguments += [RedisArgument(algorithm.uppercased()), RedisArgument(parameters.count)] + parameters
            return arguments
        default:
            throw DBError.protocolError("Search attribute type \(type) is not one Tinker can recreate.")
        }
        flag("INDEXEMPTY")
        flag("INDEXMISSING")
        if flags.contains("SORTABLE") {
            arguments.append("SORTABLE")
            // NUMERIC SORTABLE is always UNF; saying so again is harmless and keeps both sides equal.
            if flags.contains("UNF") { arguments.append("UNF") }
        }
        flag("NOINDEX")
        return arguments
    }

    // MARK: - Consumer groups

    private static func compareGroups(
        _ source: RedisConnection, _ target: RedisConnection, pattern: String, dropExtras: Bool
    ) async throws -> [RedisStructureChange] {
        var changes: [RedisStructureChange] = []
        var cursor = "0"
        repeat {
            let page = try await RedisKeyspace.scan(source, cursor: cursor, match: pattern, type: .stream, count: 500)
            cursor = page.cursor
            for stream in page.keys {
                let mine = try await RedisValues.streamGroups(source, stream)
                guard !mine.isEmpty || dropExtras else { continue }
                let targetType = try await target.send(["TYPE", stream.argument]).string ?? "none"
                // A stream the target does not have is data: Transfer or Data Sync copies it
                // with its groups. Creating it empty here would make a later transfer that
                // leaves existing keys alone skip the real one.
                guard targetType == "stream" else { continue }
                let theirs = try await RedisValues.streamGroups(target, stream)
                let existing = Dictionary(theirs.map { ($0.name, $0.lastDeliveredID) }, uniquingKeysWith: { a, _ in a })
                for group in mine {
                    if let delivered = existing[group.name] {
                        guard delivered != group.lastDeliveredID else { continue }
                        changes.append(
                            RedisStructureChange(
                                action: .recreate, object: .consumerGroup(stream: stream, group: group.name),
                                summary: "Consumer group \(group.name) of \(stream.display) has read to \(delivered), not \(group.lastDeliveredID)",
                                commands: [
                                    ["XGROUP", "SETID", stream.argument, RedisArgument(group.name), RedisArgument(group.lastDeliveredID)]
                                ]))
                        continue
                    }
                    changes.append(
                        RedisStructureChange(
                            action: .create, object: .consumerGroup(stream: stream, group: group.name),
                            summary: "Consumer group \(group.name) of \(stream.display) is missing",
                            commands: [
                                [
                                    "XGROUP", "CREATE", stream.argument, RedisArgument(group.name),
                                    RedisArgument(group.lastDeliveredID),
                                ]
                            ]))
                }
                if dropExtras {
                    let names = Set(mine.map(\.name))
                    for group in theirs where !names.contains(group.name) {
                        changes.append(
                            RedisStructureChange(
                                action: .drop, object: .consumerGroup(stream: stream, group: group.name),
                                summary: "Consumer group \(group.name) of \(stream.display) is only on the target",
                                commands: [["XGROUP", "DESTROY", stream.argument, RedisArgument(group.name)]]))
                    }
                }
            }
        } while cursor != "0"
        return changes
    }
}
