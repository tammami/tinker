import Foundation

/// Splits a typed command line into arguments the way `redis-cli` does.
///
/// Words are separated by spaces; `"double quotes"` understand `\n`, `\r`, `\t`, `\"`,
/// `\\` and `\xNN`; `'single quotes'` are literal except for `\'`. An unterminated quote
/// is an error rather than a guess.
public enum RedisCommandLine {
    public struct ParseError: Error, Hashable, CustomStringConvertible, Sendable {
        public let description: String
    }

    public static func split(_ line: String) throws -> [Data] {
        var arguments: [Data] = []
        var current = Data()
        var inWord = false
        var bytes = Array(line.utf8)[...]
        func take() -> UInt8? {
            guard let first = bytes.first else { return nil }
            bytes = bytes.dropFirst()
            return first
        }
        while let byte = take() {
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                if inWord {
                    arguments.append(current)
                    current = Data()
                    inWord = false
                }
            case UInt8(ascii: "\""):
                inWord = true
                var closed = false
                while let next = take() {
                    if next == UInt8(ascii: "\"") {
                        closed = true
                        break
                    }
                    guard next == UInt8(ascii: "\\"), let escaped = take() else {
                        current.append(next)
                        continue
                    }
                    switch escaped {
                    case UInt8(ascii: "n"): current.append(10)
                    case UInt8(ascii: "r"): current.append(13)
                    case UInt8(ascii: "t"): current.append(9)
                    case UInt8(ascii: "a"): current.append(7)
                    case UInt8(ascii: "b"): current.append(8)
                    case UInt8(ascii: "x"):
                        let hex = String(decoding: bytes.prefix(2), as: UTF8.self)
                        if hex.count == 2, let value = UInt8(hex, radix: 16) {
                            current.append(value)
                            bytes = bytes.dropFirst(2)
                        } else {
                            current.append(escaped)
                        }
                    default: current.append(escaped)
                    }
                }
                guard closed else { throw ParseError(description: "Unbalanced quotes in the command") }
            case UInt8(ascii: "'"):
                inWord = true
                var closed = false
                while let next = take() {
                    if next == UInt8(ascii: "'") {
                        closed = true
                        break
                    }
                    if next == UInt8(ascii: "\\"), bytes.first == UInt8(ascii: "'") {
                        current.append(UInt8(ascii: "'"))
                        bytes = bytes.dropFirst()
                    } else {
                        current.append(next)
                    }
                }
                guard closed else { throw ParseError(description: "Unbalanced quotes in the command") }
            default:
                inWord = true
                current.append(byte)
            }
        }
        if inWord { arguments.append(current) }
        return arguments
    }

    /// Commands that change data or the server. Used to refuse on a read-only
    /// connection and to ask first on a production one. Unknown commands count as
    /// writes: a module command nobody listed is safer treated as one.
    public static func isWrite(_ name: String) -> Bool {
        let command = name.uppercased()
        if readCommands.contains(command) { return false }
        // Module read commands follow a naming pattern.
        for suffix in [".GET", ".MGET", ".INFO", ".SEARCH", ".AGGREGATE", ".EXPLAIN", ".PROFILE", ".RANGE",
            ".REVRANGE", ".QUERYINDEX", ".EXISTS", ".MEXISTS", ".COUNT", ".QUERY", ".LIST", "._LIST", ".TYPE",
            ".STRLEN", ".ARRLEN", ".OBJLEN", ".OBJKEYS", ".RESP", ".DEBUG", ".SCANDUMP", ".CARD", ".VSIM", ".TAGVALS",
            ".SPELLCHECK", ".DICTDUMP", ".SYNDUMP", ".MRANGE", ".MREVRANGE"]
        where command.hasSuffix(suffix) {
            return false
        }
        if ["VSIM", "VCARD", "VDIM", "VEMB", "VGETATTR", "VINFO", "VLINKS", "VRANDMEMBER"].contains(command) {
            return false
        }
        return true
    }

    /// Commands a console cannot sensibly run: they hold the connection and stream.
    public static func isStreaming(_ name: String) -> Bool {
        ["SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR", "SYNC", "PSYNC"].contains(name.uppercased())
    }

    /// What the console may do with a command line.
    public enum Verdict: Sendable, Hashable {
        case read
        case write
        /// Not run, with the reason shown in its place.
        case refused(String)
    }

    /// Classifies a whole command, subcommand included: `CONFIG GET` reads, `CONFIG SET`
    /// changes the server. Commands that would change the connection itself — its
    /// database, its login, whether it answers — or hold it indefinitely are refused:
    /// the console's connection answers commands one by one, and none of those leave it
    /// usable for the next line.
    public static func verdict(_ arguments: [String]) -> Verdict {
        guard let first = arguments.first?.uppercased() else { return .read }
        let sub = arguments.count > 1 ? arguments[1].uppercased() : ""
        if isStreaming(first) {
            return .refused("\(first) holds the connection open and streams; use redis-cli for it.")
        }
        switch first {
        case "RESET", "HELLO", "AUTH", "QUIT", "MULTI", "EXEC", "DISCARD", "WATCH", "UNWATCH", "READONLY",
            "READWRITE":
            return .refused("\(first) changes the console's connection itself; Tinker manages that connection.")
        case "BLPOP", "BRPOP", "BRPOPLPUSH", "BLMOVE", "BLMPOP", "BZPOPMIN", "BZPOPMAX", "BZMPOP", "WAIT", "WAITAOF":
            return .refused("\(first) blocks until something arrives; use its non-blocking form here.")
        case "XREAD", "XREADGROUP":
            if arguments.contains(where: { $0.uppercased() == "BLOCK" }) {
                return .refused("\(first) … BLOCK waits for new entries; leave out BLOCK here.")
            }
            return first == "XREAD" ? .read : .write
        case "CLIENT":
            if ["REPLY", "PAUSE", "UNPAUSE"].contains(sub) {
                return sub == "REPLY"
                    ? .refused("CLIENT REPLY would leave the console waiting for answers that never come.") : .write
            }
            return ["LIST", "INFO", "GETNAME", "ID", "GETREDIR", "TRACKINGINFO", "NO-EVICT", "NO-TOUCH", "SETNAME"]
                .contains(sub) ? .read : .write
        case "CONFIG":
            return sub == "GET" ? .read : .write
        case "SCRIPT":
            return sub == "EXISTS" ? .read : .write
        case "FUNCTION":
            return ["LIST", "DUMP", "STATS"].contains(sub) ? .read : .write
        case "ACL":
            return ["WHOAMI", "LIST", "GETUSER", "CAT", "USERS", "LOG", "DRYRUN", "GENPASS"].contains(sub) ? .read : .write
        case "MODULE":
            return sub == "LIST" ? .read : .write
        case "CLUSTER":
            return ["INFO", "NODES", "SLOTS", "SHARDS", "MYID", "MYSHARDID", "KEYSLOT", "COUNTKEYSINSLOT", "LINKS"]
                .contains(sub) ? .read : .write
        case "SLOWLOG":
            return ["GET", "LEN"].contains(sub) ? .read : .write
        case "LATENCY":
            return ["LATEST", "HISTORY", "GRAPH", "DOCTOR", "HISTOGRAM"].contains(sub) ? .read : .write
        case "MEMORY":
            return sub == "PURGE" ? .write : .read
        case "OBJECT", "COMMAND", "PUBSUB", "XINFO":
            return .read
        case "DEBUG", "SHUTDOWN", "FAILOVER", "REPLICAOF", "SLAVEOF", "BGSAVE", "BGREWRITEAOF", "SAVE":
            return .write
        default:
            return isWrite(first) ? .write : .read
        }
    }

    static let readCommands: Set<String> = [
        "GET", "MGET", "GETRANGE", "SUBSTR", "STRLEN", "EXISTS", "TYPE", "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME",
        "KEYS", "SCAN", "RANDOMKEY", "DBSIZE", "DUMP", "OBJECT", "MEMORY", "LCS",
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSTRLEN", "HSCAN", "HRANDFIELD", "HTTL",
        "HPTTL", "HEXPIRETIME", "HPEXPIRETIME",
        "LRANGE", "LINDEX", "LLEN", "LPOS",
        "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SSCAN", "SRANDMEMBER", "SINTER", "SUNION", "SDIFF",
        "SINTERCARD",
        "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGE", "ZREVRANGEBYSCORE", "ZREVRANGEBYLEX", "ZSCORE",
        "ZMSCORE", "ZRANK", "ZREVRANK", "ZCARD", "ZCOUNT", "ZLEXCOUNT", "ZSCAN", "ZRANDMEMBER", "ZINTER", "ZUNION",
        "ZDIFF", "ZINTERCARD",
        "XRANGE", "XREVRANGE", "XLEN", "XINFO", "XPENDING", "XREAD",
        "GETBIT", "BITCOUNT", "BITPOS", "BITFIELD_RO", "PFCOUNT", "GEOPOS", "GEODIST", "GEOHASH", "GEORADIUS_RO",
        "GEORADIUSBYMEMBER_RO", "GEOSEARCH",
        "PING", "ECHO", "INFO", "TIME", "LASTSAVE", "COMMAND", "SELECT", "ROLE", "LOLWUT", "PUBSUB", "SORT_RO",
        "EVAL_RO", "EVALSHA_RO", "FCALL_RO",
    ]
}

/// Formats replies the way `redis-cli` prints them, so the console reads like the tool
/// people already know.
public enum RedisReplyFormatter {
    public static func format(_ value: RESPValue) -> String {
        lines(value).joined(separator: "\n")
    }

    public static func lines(_ value: RESPValue, indent: String = "") -> [String] {
        switch value {
        case let .simpleString(text): return [text]
        case let .error(text): return ["(error) " + text]
        case let .integer(number): return ["(integer) \(number)"]
        case let .bigNumber(text): return ["(big number) " + text]
        case let .double(text): return ["(double) " + text]
        case let .boolean(flag): return [flag ? "(true)" : "(false)"]
        case .null: return ["(nil)"]
        case let .bulkString(data): return [quoted(data)]
        case let .verbatim(text): return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        case let .array(items), let .set(items), let .push(items):
            guard !items.isEmpty else { return ["(empty array)"] }
            return numbered(items, indent: indent)
        case let .map(items):
            guard !items.isEmpty else { return ["(empty hash)"] }
            var result: [String] = []
            let pairs = stride(from: 0, to: items.count - 1, by: 2).map { (items[$0], items[$0 + 1]) }
            let width = String(pairs.count).count
            for (number, pair) in pairs.enumerated() {
                let label = String(repeating: " ", count: width - String(number + 1).count) + "\(number + 1)# "
                let key = lines(pair.0).first ?? ""
                let valueLines = lines(pair.1, indent: indent + String(repeating: " ", count: label.count))
                result.append(label + key + " => " + (valueLines.first ?? ""))
                result += valueLines.dropFirst().map { String(repeating: " ", count: label.count) + $0 }
            }
            return result
        }
    }

    private static func numbered(_ items: [RESPValue], indent: String) -> [String] {
        var result: [String] = []
        let width = String(items.count).count
        for (number, item) in items.enumerated() {
            let label = String(repeating: " ", count: width - String(number + 1).count) + "\(number + 1)) "
            let inner = lines(item, indent: indent + String(repeating: " ", count: label.count))
            result.append(label + (inner.first ?? ""))
            result += inner.dropFirst().map { String(repeating: " ", count: label.count) + $0 }
        }
        return result
    }

    /// A bulk string in double quotes, with the escapes `redis-cli` uses.
    public static func quoted(_ data: Data) -> String {
        var result = "\""
        if let text = String(data: data, encoding: .utf8) {
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"": result += "\\\""
                case "\\": result += "\\\\"
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\t": result += "\\t"
                case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                    result += String(format: "\\x%02x", scalar.value)
                default: result.unicodeScalars.append(scalar)
                }
            }
        } else {
            for byte in data {
                switch byte {
                case UInt8(ascii: "\""): result += "\\\""
                case UInt8(ascii: "\\"): result += "\\\\"
                case 0x20 ... 0x7E: result.append(Character(Unicode.Scalar(byte)))
                default: result += String(format: "\\x%02x", byte)
                }
            }
        }
        return result + "\""
    }
}
