import DBCore
import Foundation

/// What a function does, for grouping in the completion list.
public enum SQLFunctionCategory: String, Sendable, Hashable, CaseIterable {
    case aggregate = "Aggregate"
    case window = "Window"
    case dateTime = "Date and time"
    case string = "String"
    case numeric = "Numeric"
    case conditional = "Control flow"
    case conversion = "Type conversion"
    case json = "JSON"
    case array = "Array"
    case bit = "Bit"
    case encryption = "Encryption and hashing"
    case information = "Information"
    case spatial = "Spatial"
    case fullText = "Full text"
    case xml = "XML"
    case range = "Range"
    case sequence = "Sequence"
    case system = "System"
    case miscellaneous = "Miscellaneous"
}

/// One function the engine offers, as the completion list shows it.
public struct SQLFunction: Sendable, Hashable, Identifiable {
    /// The name in the engine's usual case: `DATE` on MySQL, `date_trunc` on PostgreSQL.
    public let name: String
    /// The argument list as documentation writes it, without the name: `(expr)`,
    /// `(unit FROM date)`, or empty for a function called without parentheses.
    public let arguments: String
    public let category: SQLFunctionCategory
    /// One line on what it returns.
    public let summary: String

    public init(_ name: String, _ arguments: String, _ category: SQLFunctionCategory, _ summary: String) {
        self.name = name
        self.arguments = arguments
        self.category = category
        self.summary = summary
    }

    public var id: String { "\(name)\(arguments)" }

    /// `DATE(expr)`, or the bare name for `CURRENT_DATE`.
    public var signature: String { name + arguments }

    /// True for `CURRENT_TIMESTAMP` and its kin, which take no parentheses.
    public var takesNoParentheses: Bool { arguments.isEmpty }

    /// What the editor inserts: `DATE()` with the caret between the parentheses, or the
    /// bare name.
    public var insertion: String { takesNoParentheses ? name : name + "()" }
}

/// The functions each engine offers, for the SQL editor's completion list (SPEC §13.1).
///
/// The lists follow each engine's own documentation, in the groups a person looks for
/// them: the date functions together, the string functions together. Nothing here is
/// executed; the catalog only says what exists and what it takes.
public enum SQLFunctionCatalog {
    public static func functions(for dialect: SQLDialect) -> [SQLFunction] {
        switch dialect {
        case .postgresql: postgresql
        case .mysql: mysql
        case .sqlite: sqlite
        }
    }

    /// Functions whose name starts with `prefix`, case-insensitively, in catalog order.
    public static func matching(prefix: String, dialect: SQLDialect) -> [SQLFunction] {
        let lowered = prefix.lowercased()
        return functions(for: dialect).filter { lowered.isEmpty || $0.name.lowercased().hasPrefix(lowered) }
    }

    /// The names an engine knows, lower-cased, for the highlighter.
    public static func names(for dialect: SQLDialect) -> Set<String> {
        Set(functions(for: dialect).map { $0.name.lowercased() })
    }

    // MARK: - MySQL / MariaDB

    static let mysql: [SQLFunction] = {
        var list: [SQLFunction] = []
        func add(_ category: SQLFunctionCategory, _ entries: [(String, String, String)]) {
            for (name, arguments, summary) in entries { list.append(SQLFunction(name, arguments, category, summary)) }
        }
        add(.dateTime, [
            ("ADDDATE", "(date, INTERVAL expr unit)", "Adds a time interval to a date"),
            ("ADDTIME", "(expr1, expr2)", "Adds a time to a time or datetime"),
            ("CONVERT_TZ", "(dt, from_tz, to_tz)", "Converts a datetime from one time zone to another"),
            ("CURDATE", "()", "The current date"),
            ("CURRENT_DATE", "", "The current date"),
            ("CURRENT_TIME", "", "The current time"),
            ("CURRENT_TIMESTAMP", "", "The current date and time"),
            ("CURTIME", "()", "The current time"),
            ("DATE", "(expr)", "The date part of a date or datetime"),
            ("DATE_ADD", "(date, INTERVAL expr unit)", "Adds a time interval to a date"),
            ("DATE_FORMAT", "(date, format)", "Formats a date as the format string says"),
            ("DATE_SUB", "(date, INTERVAL expr unit)", "Subtracts a time interval from a date"),
            ("DATEDIFF", "(expr1, expr2)", "The number of days between two dates"),
            ("DAY", "(date)", "The day of the month, 1 to 31"),
            ("DAYNAME", "(date)", "The name of the weekday"),
            ("DAYOFMONTH", "(date)", "The day of the month, 1 to 31"),
            ("DAYOFWEEK", "(date)", "The weekday index, 1 = Sunday"),
            ("DAYOFYEAR", "(date)", "The day of the year, 1 to 366"),
            ("EXTRACT", "(unit FROM date)", "One part of a date: YEAR, MONTH, DAY, HOUR…"),
            ("FROM_DAYS", "(n)", "The date for a day number"),
            ("FROM_UNIXTIME", "(unix_timestamp[, format])", "A Unix timestamp as a datetime"),
            ("GET_FORMAT", "({DATE|TIME|DATETIME}, {'EUR'|'USA'|'JIS'|'ISO'|'INTERNAL'})", "A format string for DATE_FORMAT"),
            ("HOUR", "(time)", "The hour, 0 to 23 (or more for a time interval)"),
            ("LAST_DAY", "(date)", "The last day of the month"),
            ("LOCALTIME", "", "The current date and time"),
            ("LOCALTIMESTAMP", "", "The current date and time"),
            ("MAKEDATE", "(year, dayofyear)", "A date from a year and a day of the year"),
            ("MAKETIME", "(hour, minute, second)", "A time from hour, minute and second"),
            ("MICROSECOND", "(expr)", "The microseconds of a time"),
            ("MINUTE", "(time)", "The minute, 0 to 59"),
            ("MONTH", "(date)", "The month, 1 to 12"),
            ("MONTHNAME", "(date)", "The name of the month"),
            ("NOW", "()", "The current date and time"),
            ("PERIOD_ADD", "(period, n)", "Adds months to a period in YYYYMM form"),
            ("PERIOD_DIFF", "(period1, period2)", "The number of months between two periods"),
            ("QUARTER", "(date)", "The quarter, 1 to 4"),
            ("SEC_TO_TIME", "(seconds)", "Seconds as a time value"),
            ("SECOND", "(time)", "The second, 0 to 59"),
            ("STR_TO_DATE", "(str, format)", "Parses a string into a date with a format"),
            ("SUBDATE", "(date, INTERVAL expr unit)", "Subtracts a time interval from a date"),
            ("SUBTIME", "(expr1, expr2)", "Subtracts a time from a time or datetime"),
            ("SYSDATE", "()", "The time at which the function runs"),
            ("TIME", "(expr)", "The time part of a time or datetime"),
            ("TIME_FORMAT", "(time, format)", "Formats a time as the format string says"),
            ("TIME_TO_SEC", "(time)", "A time as seconds"),
            ("TIMEDIFF", "(expr1, expr2)", "The time between two times or datetimes"),
            ("TIMESTAMP", "(expr[, expr2])", "A datetime from a date, or a date plus a time"),
            ("TIMESTAMPADD", "(unit, interval, datetime)", "Adds an interval to a datetime"),
            ("TIMESTAMPDIFF", "(unit, datetime1, datetime2)", "The difference between two datetimes in a unit"),
            ("TO_DAYS", "(date)", "The day number of a date"),
            ("TO_SECONDS", "(expr)", "The seconds since year 0"),
            ("UNIX_TIMESTAMP", "([date])", "A Unix timestamp"),
            ("UTC_DATE", "()", "The current UTC date"),
            ("UTC_TIME", "()", "The current UTC time"),
            ("UTC_TIMESTAMP", "()", "The current UTC date and time"),
            ("WEEK", "(date[, mode])", "The week number"),
            ("WEEKDAY", "(date)", "The weekday index, 0 = Monday"),
            ("WEEKOFYEAR", "(date)", "The calendar week, 1 to 53"),
            ("YEAR", "(date)", "The year"),
            ("YEARWEEK", "(date[, mode])", "The year and week"),
        ])
        add(.string, [
            ("ASCII", "(str)", "The code of the leftmost character"),
            ("BIN", "(n)", "A number as a binary string"),
            ("BIT_LENGTH", "(str)", "The length in bits"),
            ("CHAR", "(n, … [USING charset])", "Characters for integer codes"),
            ("CHAR_LENGTH", "(str)", "The length in characters"),
            ("CHARACTER_LENGTH", "(str)", "The length in characters"),
            ("CONCAT", "(str1, str2, …)", "Joins strings"),
            ("CONCAT_WS", "(separator, str1, str2, …)", "Joins strings with a separator"),
            ("ELT", "(n, str1, str2, …)", "The n-th string of the list"),
            ("EXPORT_SET", "(bits, on, off[, separator[, number_of_bits]])", "A bit pattern as on/off strings"),
            ("FIELD", "(str, str1, str2, …)", "The index of str in the list that follows"),
            ("FIND_IN_SET", "(str, strlist)", "The index of str in a comma-separated list"),
            ("FORMAT", "(x, d[, locale])", "A number formatted with thousands separators"),
            ("FROM_BASE64", "(str)", "Decodes a base-64 string"),
            ("HEX", "(str | n)", "A string or number as hexadecimal"),
            ("INSERT", "(str, pos, len, newstr)", "Replaces a substring at a position"),
            ("INSTR", "(str, substr)", "The position of the first occurrence of substr"),
            ("LCASE", "(str)", "Lower case"),
            ("LEFT", "(str, len)", "The leftmost characters"),
            ("LENGTH", "(str)", "The length in bytes"),
            ("LOAD_FILE", "(file_name)", "The contents of a file on the server"),
            ("LOCATE", "(substr, str[, pos])", "The position of a substring"),
            ("LOWER", "(str)", "Lower case"),
            ("LPAD", "(str, len, padstr)", "Pads on the left to a length"),
            ("LTRIM", "(str)", "Removes leading spaces"),
            ("MAKE_SET", "(bits, str1, str2, …)", "The strings whose bits are set, comma-separated"),
            ("MID", "(str, pos[, len])", "A substring"),
            ("OCT", "(n)", "A number as an octal string"),
            ("OCTET_LENGTH", "(str)", "The length in bytes"),
            ("ORD", "(str)", "The code of the leftmost character, multibyte aware"),
            ("POSITION", "(substr IN str)", "The position of a substring"),
            ("QUOTE", "(str)", "The string quoted for use in SQL"),
            ("REGEXP_INSTR", "(expr, pat[, pos[, occurrence[, return_option[, match_type]]]])", "Where a pattern matches"),
            ("REGEXP_LIKE", "(expr, pat[, match_type])", "Whether a pattern matches"),
            ("REGEXP_REPLACE", "(expr, pat, repl[, pos[, occurrence[, match_type]]])", "Replaces what a pattern matches"),
            ("REGEXP_SUBSTR", "(expr, pat[, pos[, occurrence[, match_type]]])", "The substring a pattern matches"),
            ("REPEAT", "(str, count)", "The string repeated"),
            ("REPLACE", "(str, from_str, to_str)", "Replaces every occurrence of a substring"),
            ("REVERSE", "(str)", "The characters reversed"),
            ("RIGHT", "(str, len)", "The rightmost characters"),
            ("RPAD", "(str, len, padstr)", "Pads on the right to a length"),
            ("RTRIM", "(str)", "Removes trailing spaces"),
            ("SOUNDEX", "(str)", "A soundex string"),
            ("SPACE", "(n)", "A string of n spaces"),
            ("STRCMP", "(expr1, expr2)", "Compares two strings: -1, 0 or 1"),
            ("SUBSTR", "(str, pos[, len])", "A substring"),
            ("SUBSTRING", "(str, pos[, len])", "A substring"),
            ("SUBSTRING_INDEX", "(str, delim, count)", "The part before the count-th delimiter"),
            ("TO_BASE64", "(str)", "Encodes as base 64"),
            ("TRIM", "([{BOTH|LEADING|TRAILING} [remstr] FROM] str)", "Removes leading and trailing characters"),
            ("UCASE", "(str)", "Upper case"),
            ("UNHEX", "(str)", "Hexadecimal digits as bytes"),
            ("UPPER", "(str)", "Upper case"),
            ("WEIGHT_STRING", "(str)", "The weight string used for sorting"),
        ])
        add(.numeric, [
            ("ABS", "(x)", "The absolute value"),
            ("ACOS", "(x)", "The arc cosine"),
            ("ASIN", "(x)", "The arc sine"),
            ("ATAN", "(x)", "The arc tangent"),
            ("ATAN2", "(y, x)", "The arc tangent of two arguments"),
            ("CEIL", "(x)", "The smallest integer not less than x"),
            ("CEILING", "(x)", "The smallest integer not less than x"),
            ("CONV", "(n, from_base, to_base)", "Converts a number between bases"),
            ("COS", "(x)", "The cosine"),
            ("COT", "(x)", "The cotangent"),
            ("CRC32", "(expr)", "A cyclic redundancy check value"),
            ("DEGREES", "(x)", "Radians as degrees"),
            ("EXP", "(x)", "e raised to the power of x"),
            ("FLOOR", "(x)", "The largest integer not greater than x"),
            ("LN", "(x)", "The natural logarithm"),
            ("LOG", "([b,] x)", "The logarithm, natural or to a base"),
            ("LOG10", "(x)", "The base-10 logarithm"),
            ("LOG2", "(x)", "The base-2 logarithm"),
            ("MOD", "(n, m)", "The remainder"),
            ("PI", "()", "The value of π"),
            ("POW", "(x, y)", "x raised to the power of y"),
            ("POWER", "(x, y)", "x raised to the power of y"),
            ("RADIANS", "(x)", "Degrees as radians"),
            ("RAND", "([seed])", "A random number between 0 and 1"),
            ("ROUND", "(x[, d])", "Rounds to d decimals"),
            ("SIGN", "(x)", "The sign: -1, 0 or 1"),
            ("SIN", "(x)", "The sine"),
            ("SQRT", "(x)", "The square root"),
            ("TAN", "(x)", "The tangent"),
            ("TRUNCATE", "(x, d)", "Truncates to d decimals"),
        ])
        add(.aggregate, [
            ("AVG", "([DISTINCT] expr)", "The average"),
            ("BIT_AND", "(expr)", "The bitwise AND of every value"),
            ("BIT_OR", "(expr)", "The bitwise OR of every value"),
            ("BIT_XOR", "(expr)", "The bitwise XOR of every value"),
            ("COUNT", "(expr | *)", "How many rows"),
            ("GROUP_CONCAT", "([DISTINCT] expr [ORDER BY …] [SEPARATOR str])", "The values joined into one string"),
            ("JSON_ARRAYAGG", "(col_or_expr)", "The values as a JSON array"),
            ("JSON_OBJECTAGG", "(key, value)", "Key/value pairs as a JSON object"),
            ("MAX", "([DISTINCT] expr)", "The largest value"),
            ("MIN", "([DISTINCT] expr)", "The smallest value"),
            ("STD", "(expr)", "The population standard deviation"),
            ("STDDEV", "(expr)", "The population standard deviation"),
            ("STDDEV_POP", "(expr)", "The population standard deviation"),
            ("STDDEV_SAMP", "(expr)", "The sample standard deviation"),
            ("SUM", "([DISTINCT] expr)", "The total"),
            ("VAR_POP", "(expr)", "The population variance"),
            ("VAR_SAMP", "(expr)", "The sample variance"),
            ("VARIANCE", "(expr)", "The population variance"),
        ])
        add(.window, [
            ("CUME_DIST", "() OVER (…)", "The cumulative distribution of a row"),
            ("DENSE_RANK", "() OVER (…)", "The rank without gaps"),
            ("FIRST_VALUE", "(expr) OVER (…)", "The value of the first row of the frame"),
            ("LAG", "(expr[, n[, default]]) OVER (…)", "The value n rows before"),
            ("LAST_VALUE", "(expr) OVER (…)", "The value of the last row of the frame"),
            ("LEAD", "(expr[, n[, default]]) OVER (…)", "The value n rows after"),
            ("NTH_VALUE", "(expr, n) OVER (…)", "The value of the n-th row of the frame"),
            ("NTILE", "(n) OVER (…)", "The bucket number out of n"),
            ("PERCENT_RANK", "() OVER (…)", "The relative rank"),
            ("RANK", "() OVER (…)", "The rank with gaps"),
            ("ROW_NUMBER", "() OVER (…)", "The row's number within its partition"),
        ])
        add(.conditional, [
            ("CASE", " WHEN … THEN … [ELSE …] END", "Picks a result by condition"),
            ("COALESCE", "(value, …)", "The first non-NULL argument"),
            ("GREATEST", "(value1, value2, …)", "The largest argument"),
            ("IF", "(expr, if_true, if_false)", "One of two values by a condition"),
            ("IFNULL", "(expr1, expr2)", "expr1, or expr2 when it is NULL"),
            ("INTERVAL", "(n, n1, n2, …)", "The index of the first value greater than n"),
            ("ISNULL", "(expr)", "1 when the value is NULL"),
            ("LEAST", "(value1, value2, …)", "The smallest argument"),
            ("NULLIF", "(expr1, expr2)", "NULL when the two are equal, else expr1"),
        ])
        add(.conversion, [
            ("BINARY", " expr", "The value as a binary string"),
            ("CAST", "(expr AS type)", "The value converted to a type"),
            ("CONVERT", "(expr, type) | (expr USING charset)", "The value converted to a type or character set"),
        ])
        add(.json, [
            ("JSON_ARRAY", "([val, …])", "A JSON array"),
            ("JSON_ARRAY_APPEND", "(json_doc, path, val, …)", "Appends values to arrays in a document"),
            ("JSON_ARRAY_INSERT", "(json_doc, path, val, …)", "Inserts values into arrays in a document"),
            ("JSON_CONTAINS", "(target, candidate[, path])", "Whether a document contains another"),
            ("JSON_CONTAINS_PATH", "(json_doc, one_or_all, path, …)", "Whether paths exist"),
            ("JSON_DEPTH", "(json_doc)", "The maximum depth"),
            ("JSON_EXTRACT", "(json_doc, path, …)", "The data at the paths"),
            ("JSON_INSERT", "(json_doc, path, val, …)", "Inserts data where nothing is yet"),
            ("JSON_KEYS", "(json_doc[, path])", "The top-level keys as an array"),
            ("JSON_LENGTH", "(json_doc[, path])", "The number of elements"),
            ("JSON_MERGE_PATCH", "(json_doc, json_doc, …)", "Merges documents, replacing on conflict"),
            ("JSON_MERGE_PRESERVE", "(json_doc, json_doc, …)", "Merges documents, keeping every value"),
            ("JSON_OBJECT", "([key, val, …])", "A JSON object"),
            ("JSON_OVERLAPS", "(json_doc1, json_doc2)", "Whether two documents share any value"),
            ("JSON_PRETTY", "(json_val)", "The document pretty-printed"),
            ("JSON_QUOTE", "(string)", "The string as a JSON string literal"),
            ("JSON_REMOVE", "(json_doc, path, …)", "Removes data at the paths"),
            ("JSON_REPLACE", "(json_doc, path, val, …)", "Replaces existing values"),
            ("JSON_SEARCH", "(json_doc, one_or_all, search_str[, escape_char[, path]])", "The path to a string"),
            ("JSON_SET", "(json_doc, path, val, …)", "Inserts or replaces data"),
            ("JSON_STORAGE_SIZE", "(json_val)", "The bytes used to store the document"),
            ("JSON_TABLE", "(expr, path COLUMNS (…))", "A document as a relational table"),
            ("JSON_TYPE", "(json_val)", "The type of a JSON value"),
            ("JSON_UNQUOTE", "(json_val)", "Unquotes a JSON string"),
            ("JSON_VALID", "(val)", "Whether the value is valid JSON"),
            ("JSON_VALUE", "(json_doc, path [RETURNING type])", "The scalar at a path, as a SQL type"),
            ("MEMBER OF", "(json_array)", "Whether a value is an element of the array"),
        ])
        add(.encryption, [
            ("AES_DECRYPT", "(crypt_str, key_str[, init_vector])", "Decrypts with AES"),
            ("AES_ENCRYPT", "(str, key_str[, init_vector])", "Encrypts with AES"),
            ("COMPRESS", "(string_to_compress)", "Compresses a string"),
            ("MD5", "(str)", "The MD5 checksum as hex"),
            ("RANDOM_BYTES", "(len)", "A random byte vector"),
            ("SHA1", "(str)", "The SHA-1 hash as hex"),
            ("SHA2", "(str, hash_length)", "A SHA-2 hash: 224, 256, 384 or 512 bits"),
            ("STATEMENT_DIGEST", "(statement)", "The digest hash of a statement"),
            ("UNCOMPRESS", "(string_to_uncompress)", "Uncompresses a string"),
            ("UNCOMPRESSED_LENGTH", "(compressed_string)", "The length before compression"),
        ])
        add(.information, [
            ("BENCHMARK", "(count, expr)", "Runs an expression repeatedly, for timing"),
            ("CHARSET", "(str)", "The character set of the argument"),
            ("COERCIBILITY", "(str)", "The collation coercibility"),
            ("COLLATION", "(str)", "The collation of the argument"),
            ("CONNECTION_ID", "()", "The id of this connection"),
            ("CURRENT_ROLE", "()", "The active roles"),
            ("CURRENT_USER", "()", "The authenticated user and host"),
            ("DATABASE", "()", "The default database"),
            ("FOUND_ROWS", "()", "Rows the last SELECT would return without LIMIT"),
            ("LAST_INSERT_ID", "([expr])", "The last AUTO_INCREMENT value"),
            ("ROW_COUNT", "()", "Rows changed by the last statement"),
            ("SCHEMA", "()", "The default database"),
            ("SESSION_USER", "()", "The user name and host"),
            ("SYSTEM_USER", "()", "The user name and host"),
            ("USER", "()", "The user name and host"),
            ("VERSION", "()", "The server version"),
        ])
        add(.bit, [
            ("BIT_COUNT", "(n)", "How many bits are set"),
        ])
        add(.spatial, [
            ("ST_AsGeoJSON", "(g[, max_dec_digits[, options]])", "A geometry as GeoJSON"),
            ("ST_AsText", "(g)", "A geometry as WKT"),
            ("ST_Area", "(poly)", "The area"),
            ("ST_Buffer", "(g, d)", "The points within a distance"),
            ("ST_Contains", "(g1, g2)", "Whether g1 contains g2"),
            ("ST_Distance", "(g1, g2)", "The distance"),
            ("ST_Distance_Sphere", "(g1, g2[, radius])", "The distance on a sphere, in metres"),
            ("ST_GeomFromGeoJSON", "(str)", "A geometry from GeoJSON"),
            ("ST_GeomFromText", "(wkt[, srid])", "A geometry from WKT"),
            ("ST_Intersects", "(g1, g2)", "Whether two geometries intersect"),
            ("ST_Latitude", "(p)", "The latitude of a point"),
            ("ST_Length", "(ls)", "The length of a line"),
            ("ST_Longitude", "(p)", "The longitude of a point"),
            ("ST_MakeEnvelope", "(pt1, pt2)", "A rectangle from two points"),
            ("ST_SRID", "(g)", "The spatial reference id"),
            ("ST_Union", "(g1, g2)", "The union of two geometries"),
            ("ST_Within", "(g1, g2)", "Whether g1 is within g2"),
            ("ST_X", "(p)", "The X coordinate of a point"),
            ("ST_Y", "(p)", "The Y coordinate of a point"),
        ])
        add(.fullText, [
            ("MATCH", "(col, …) AGAINST (expr [modifier])", "A full-text search"),
        ])
        add(.xml, [
            ("ExtractValue", "(xml_frag, xpath_expr)", "Text from an XML fragment by XPath"),
            ("UpdateXML", "(xml_target, xpath_expr, new_xml)", "Replaces part of an XML fragment"),
        ])
        add(.miscellaneous, [
            ("ANY_VALUE", "(arg)", "Any value from the group, for ONLY_FULL_GROUP_BY"),
            ("BIN_TO_UUID", "(binary_uuid[, swap_flag])", "A binary UUID as text"),
            ("DEFAULT", "(col_name)", "The default value of a column"),
            ("GET_LOCK", "(str, timeout)", "Takes a named lock"),
            ("GROUPING", "(expr, …)", "Whether a ROLLUP row is a super-aggregate"),
            ("INET_ATON", "(expr)", "An IPv4 address as a number"),
            ("INET_NTOA", "(expr)", "A number as an IPv4 address"),
            ("INET6_ATON", "(expr)", "An IPv6 or IPv4 address as bytes"),
            ("INET6_NTOA", "(expr)", "Bytes as an IPv6 or IPv4 address"),
            ("IS_FREE_LOCK", "(str)", "Whether a named lock is free"),
            ("IS_IPV4", "(expr)", "Whether the text is an IPv4 address"),
            ("IS_IPV6", "(expr)", "Whether the text is an IPv6 address"),
            ("IS_UUID", "(string_uuid)", "Whether the text is a UUID"),
            ("NAME_CONST", "(name, value)", "A column with a given name and value"),
            ("RELEASE_LOCK", "(str)", "Releases a named lock"),
            ("SLEEP", "(duration)", "Pauses for a number of seconds"),
            ("UUID", "()", "A UUID"),
            ("UUID_SHORT", "()", "A short universal identifier"),
            ("UUID_TO_BIN", "(string_uuid[, swap_flag])", "A UUID as 16 bytes"),
            ("VALUES", "(col_name)", "The value INSERT would have used, in ON DUPLICATE KEY UPDATE"),
        ])
        return list
    }()

    // MARK: - PostgreSQL

    static let postgresql: [SQLFunction] = {
        var list: [SQLFunction] = []
        func add(_ category: SQLFunctionCategory, _ entries: [(String, String, String)]) {
            for (name, arguments, summary) in entries { list.append(SQLFunction(name, arguments, category, summary)) }
        }
        add(.dateTime, [
            ("age", "(timestamp[, timestamp])", "The interval between two timestamps, or since midnight today"),
            ("clock_timestamp", "()", "The time now, changing within a statement"),
            ("current_date", "", "The current date"),
            ("current_time", "", "The current time with time zone"),
            ("current_timestamp", "", "The transaction's start time"),
            ("date_bin", "(stride, source, origin)", "The source binned into strides from an origin"),
            ("date_part", "(field, source)", "One part of a date or interval, as a number"),
            ("date_trunc", "(field, source[, time_zone])", "The value truncated to a precision"),
            ("extract", "(field FROM source)", "One part of a date or interval: year, month, day, hour, dow…"),
            ("isfinite", "(date | timestamp | interval)", "Whether the value is finite"),
            ("justify_days", "(interval)", "Days over 30 turned into months"),
            ("justify_hours", "(interval)", "Hours over 24 turned into days"),
            ("justify_interval", "(interval)", "Both adjustments, with signs normalised"),
            ("localtime", "", "The current time"),
            ("localtimestamp", "", "The transaction's start time, without zone"),
            ("make_date", "(year, month, day)", "A date from its parts"),
            ("make_interval", "(years, months, weeks, days, hours, mins, secs)", "An interval from its parts"),
            ("make_time", "(hour, min, sec)", "A time from its parts"),
            ("make_timestamp", "(year, month, day, hour, min, sec)", "A timestamp from its parts"),
            ("make_timestamptz", "(year, month, day, hour, min, sec[, timezone])", "A timestamp with zone from its parts"),
            ("now", "()", "The transaction's start time"),
            ("statement_timestamp", "()", "The current statement's start time"),
            ("timeofday", "()", "The time now, as text"),
            ("to_char", "(timestamp | interval | number, format)", "Formats a date, interval or number"),
            ("to_date", "(text, format)", "Parses a date with a format"),
            ("to_timestamp", "(text, format) | (double)", "Parses a timestamp with a format, or from Unix epoch"),
            ("transaction_timestamp", "()", "The transaction's start time"),
        ])
        add(.string, [
            ("ascii", "(text)", "The code of the first character"),
            ("btrim", "(string[, characters])", "Removes the longest string of characters from both ends"),
            ("char_length", "(text)", "The length in characters"),
            ("character_length", "(text)", "The length in characters"),
            ("chr", "(int)", "The character with a code"),
            ("concat", "(val1, …)", "Joins the text of the arguments, ignoring NULL"),
            ("concat_ws", "(sep, val1, …)", "Joins with a separator, ignoring NULL"),
            ("format", "(formatstr, args…)", "Formats arguments like sprintf"),
            ("initcap", "(text)", "The first letter of each word in upper case"),
            ("left", "(string, n)", "The first n characters"),
            ("length", "(text)", "The length in characters"),
            ("lower", "(text)", "Lower case"),
            ("lpad", "(string, length[, fill])", "Pads on the left"),
            ("ltrim", "(string[, characters])", "Removes leading characters"),
            ("md5", "(text)", "The MD5 hash as hex"),
            ("octet_length", "(text)", "The length in bytes"),
            ("overlay", "(string PLACING newsubstring FROM start [FOR count])", "Replaces a substring"),
            ("parse_ident", "(qualified_identifier)", "Splits a qualified name into its parts"),
            ("position", "(substring IN string)", "The position of a substring"),
            ("quote_ident", "(text)", "The text quoted as an identifier"),
            ("quote_literal", "(text)", "The text quoted as a string literal"),
            ("quote_nullable", "(text)", "The text quoted, or NULL"),
            ("regexp_count", "(string, pattern[, start[, flags]])", "How many times a pattern matches"),
            ("regexp_instr", "(string, pattern[, start[, N[, endoption[, flags]]]])", "Where a pattern matches"),
            ("regexp_like", "(string, pattern[, flags])", "Whether a pattern matches"),
            ("regexp_match", "(string, pattern[, flags])", "The first match's captures"),
            ("regexp_matches", "(string, pattern[, flags])", "Every match's captures, as rows"),
            ("regexp_replace", "(string, pattern, replacement[, start[, N]][, flags])", "Replaces what a pattern matches"),
            ("regexp_split_to_array", "(string, pattern[, flags])", "Splits on a pattern into an array"),
            ("regexp_split_to_table", "(string, pattern[, flags])", "Splits on a pattern into rows"),
            ("regexp_substr", "(string, pattern[, start[, N[, flags]]])", "The substring a pattern matches"),
            ("repeat", "(string, number)", "The string repeated"),
            ("replace", "(string, from, to)", "Replaces every occurrence of a substring"),
            ("reverse", "(text)", "The characters reversed"),
            ("right", "(string, n)", "The last n characters"),
            ("rpad", "(string, length[, fill])", "Pads on the right"),
            ("rtrim", "(string[, characters])", "Removes trailing characters"),
            ("split_part", "(string, delimiter, n)", "The n-th field after splitting"),
            ("starts_with", "(string, prefix)", "Whether the string starts with a prefix"),
            ("string_to_array", "(string, delimiter[, null_string])", "Splits into an array"),
            ("string_to_table", "(string, delimiter[, null_string])", "Splits into rows"),
            ("strpos", "(string, substring)", "The position of a substring"),
            ("substr", "(string, start[, count])", "A substring"),
            ("substring", "(string [FROM start] [FOR count])", "A substring, or a regular-expression match"),
            ("to_ascii", "(string[, encoding])", "Converts to ASCII from another encoding"),
            ("to_hex", "(number)", "A number as hexadecimal"),
            ("translate", "(string, from, to)", "Replaces characters one for one"),
            ("trim", "([LEADING | TRAILING | BOTH] [characters] FROM string)", "Removes leading and trailing characters"),
            ("unistr", "(text)", "Unicode escapes in the text evaluated"),
            ("upper", "(text)", "Upper case"),
        ])
        add(.numeric, [
            ("abs", "(x)", "The absolute value"),
            ("acos", "(x)", "The arc cosine"),
            ("asin", "(x)", "The arc sine"),
            ("atan", "(x)", "The arc tangent"),
            ("atan2", "(y, x)", "The arc tangent of y/x"),
            ("cbrt", "(x)", "The cube root"),
            ("ceil", "(x)", "The nearest integer greater than or equal"),
            ("ceiling", "(x)", "The nearest integer greater than or equal"),
            ("cos", "(x)", "The cosine"),
            ("cot", "(x)", "The cotangent"),
            ("degrees", "(x)", "Radians as degrees"),
            ("div", "(y, x)", "The integer quotient"),
            ("exp", "(x)", "The exponential"),
            ("factorial", "(bigint)", "The factorial"),
            ("floor", "(x)", "The nearest integer less than or equal"),
            ("gcd", "(a, b)", "The greatest common divisor"),
            ("lcm", "(a, b)", "The least common multiple"),
            ("ln", "(x)", "The natural logarithm"),
            ("log", "([b,] x)", "The base-10 logarithm, or to a base"),
            ("log10", "(x)", "The base-10 logarithm"),
            ("min_scale", "(numeric)", "The smallest scale that keeps the value exact"),
            ("mod", "(y, x)", "The remainder"),
            ("pi", "()", "The value of π"),
            ("power", "(a, b)", "a raised to the power of b"),
            ("radians", "(x)", "Degrees as radians"),
            ("random", "()", "A random value between 0 and 1"),
            ("round", "(v[, s])", "Rounds to s decimal places"),
            ("scale", "(numeric)", "The scale of the value"),
            ("setseed", "(x)", "Seeds random()"),
            ("sign", "(x)", "The sign: -1, 0 or 1"),
            ("sin", "(x)", "The sine"),
            ("sqrt", "(x)", "The square root"),
            ("tan", "(x)", "The tangent"),
            ("trim_scale", "(numeric)", "Trailing zeroes removed from the scale"),
            ("trunc", "(v[, s])", "Truncates to s decimal places"),
            ("width_bucket", "(operand, low, high, count)", "The bucket number in an equal-width histogram"),
        ])
        add(.aggregate, [
            ("array_agg", "(expression)", "The values as an array"),
            ("avg", "(expression)", "The average"),
            ("bit_and", "(expression)", "The bitwise AND of every value"),
            ("bit_or", "(expression)", "The bitwise OR of every value"),
            ("bit_xor", "(expression)", "The bitwise XOR of every value"),
            ("bool_and", "(expression)", "True when every value is true"),
            ("bool_or", "(expression)", "True when any value is true"),
            ("corr", "(Y, X)", "The correlation coefficient"),
            ("count", "(expression | *)", "How many rows"),
            ("covar_pop", "(Y, X)", "The population covariance"),
            ("covar_samp", "(Y, X)", "The sample covariance"),
            ("every", "(expression)", "True when every value is true"),
            ("json_agg", "(expression)", "The values as a JSON array"),
            ("json_object_agg", "(name, value)", "Pairs as a JSON object"),
            ("jsonb_agg", "(expression)", "The values as a jsonb array"),
            ("jsonb_object_agg", "(name, value)", "Pairs as a jsonb object"),
            ("max", "(expression)", "The largest value"),
            ("min", "(expression)", "The smallest value"),
            ("mode", "() WITHIN GROUP (ORDER BY …)", "The most frequent value"),
            ("percentile_cont", "(fraction) WITHIN GROUP (ORDER BY …)", "A continuous percentile"),
            ("percentile_disc", "(fraction) WITHIN GROUP (ORDER BY …)", "A discrete percentile"),
            ("range_agg", "(value)", "The values as a multirange"),
            ("regr_slope", "(Y, X)", "The slope of the regression line"),
            ("regr_intercept", "(Y, X)", "The intercept of the regression line"),
            ("regr_r2", "(Y, X)", "The square of the correlation coefficient"),
            ("stddev", "(expression)", "The sample standard deviation"),
            ("stddev_pop", "(expression)", "The population standard deviation"),
            ("stddev_samp", "(expression)", "The sample standard deviation"),
            ("string_agg", "(value, delimiter [ORDER BY …])", "The values joined into one string"),
            ("sum", "(expression)", "The total"),
            ("var_pop", "(expression)", "The population variance"),
            ("var_samp", "(expression)", "The sample variance"),
            ("variance", "(expression)", "The sample variance"),
            ("xmlagg", "(xml)", "The values concatenated as XML"),
        ])
        add(.window, [
            ("cume_dist", "() OVER (…)", "The cumulative distribution of a row"),
            ("dense_rank", "() OVER (…)", "The rank without gaps"),
            ("first_value", "(value) OVER (…)", "The value of the first row of the frame"),
            ("lag", "(value[, offset[, default]]) OVER (…)", "The value offset rows before"),
            ("last_value", "(value) OVER (…)", "The value of the last row of the frame"),
            ("lead", "(value[, offset[, default]]) OVER (…)", "The value offset rows after"),
            ("nth_value", "(value, n) OVER (…)", "The value of the n-th row of the frame"),
            ("ntile", "(num_buckets) OVER (…)", "The bucket number"),
            ("percent_rank", "() OVER (…)", "The relative rank"),
            ("rank", "() OVER (…)", "The rank with gaps"),
            ("row_number", "() OVER (…)", "The row's number within its partition"),
        ])
        add(.conditional, [
            ("CASE", " WHEN … THEN … [ELSE …] END", "Picks a result by condition"),
            ("coalesce", "(value, …)", "The first non-NULL argument"),
            ("greatest", "(value, …)", "The largest argument"),
            ("least", "(value, …)", "The smallest argument"),
            ("nullif", "(value1, value2)", "NULL when the two are equal, else value1"),
            ("num_nonnulls", "(VARIADIC \"any\")", "How many arguments are not NULL"),
            ("num_nulls", "(VARIADIC \"any\")", "How many arguments are NULL"),
        ])
        add(.conversion, [
            ("CAST", "(expression AS type)", "The value converted to a type"),
            ("to_char", "(value, format)", "Formats a number, date or interval"),
            ("to_number", "(text, format)", "Parses a number with a format"),
            ("convert", "(bytea, src_encoding, dest_encoding)", "Converts bytes between encodings"),
            ("convert_from", "(bytea, src_encoding)", "Bytes as text in the database encoding"),
            ("convert_to", "(text, dest_encoding)", "Text as bytes in an encoding"),
            ("encode", "(bytea, format)", "Bytes as base64, hex or escape text"),
            ("decode", "(text, format)", "Text in base64, hex or escape form as bytes"),
            ("pg_typeof", "(any)", "The data type of a value"),
        ])
        add(.json, [
            ("json_array_elements", "(json)", "The elements of an array as rows"),
            ("json_array_elements_text", "(json)", "The elements of an array as text rows"),
            ("json_array_length", "(json)", "How many elements an array has"),
            ("json_build_array", "(VARIADIC \"any\")", "A JSON array from the arguments"),
            ("json_build_object", "(VARIADIC \"any\")", "A JSON object from key/value arguments"),
            ("json_each", "(json)", "The key/value pairs of an object as rows"),
            ("json_each_text", "(json)", "The key/value pairs as text rows"),
            ("json_extract_path", "(from_json, VARIADIC path_elems)", "The value at a path"),
            ("json_extract_path_text", "(from_json, VARIADIC path_elems)", "The value at a path, as text"),
            ("json_object_keys", "(json)", "The keys of an object as rows"),
            ("json_populate_record", "(base, from_json)", "An object as a row of a composite type"),
            ("json_to_record", "(json)", "An object as a row with columns you define"),
            ("json_typeof", "(json)", "The type of the outermost value"),
            ("jsonb_array_elements", "(jsonb)", "The elements of an array as rows"),
            ("jsonb_array_length", "(jsonb)", "How many elements an array has"),
            ("jsonb_build_array", "(VARIADIC \"any\")", "A jsonb array from the arguments"),
            ("jsonb_build_object", "(VARIADIC \"any\")", "A jsonb object from key/value arguments"),
            ("jsonb_each", "(jsonb)", "The key/value pairs of an object as rows"),
            ("jsonb_extract_path", "(from_json, VARIADIC path_elems)", "The value at a path"),
            ("jsonb_extract_path_text", "(from_json, VARIADIC path_elems)", "The value at a path, as text"),
            ("jsonb_insert", "(target, path, new_value[, insert_after])", "Inserts a value at a path"),
            ("jsonb_object_keys", "(jsonb)", "The keys of an object as rows"),
            ("jsonb_path_exists", "(target, path[, vars[, silent]])", "Whether a JSON path yields anything"),
            ("jsonb_path_match", "(target, path[, vars[, silent]])", "The boolean result of a JSON path predicate"),
            ("jsonb_path_query", "(target, path[, vars[, silent]])", "Every item a JSON path yields, as rows"),
            ("jsonb_path_query_array", "(target, path[, vars[, silent]])", "Every item a JSON path yields, as an array"),
            ("jsonb_path_query_first", "(target, path[, vars[, silent]])", "The first item a JSON path yields"),
            ("jsonb_pretty", "(jsonb)", "The document pretty-printed"),
            ("jsonb_set", "(target, path, new_value[, create_if_missing])", "Replaces or adds a value at a path"),
            ("jsonb_set_lax", "(target, path, new_value[, create_if_missing[, null_value_treatment]])", "jsonb_set with a rule for NULL"),
            ("jsonb_strip_nulls", "(jsonb)", "Removes object fields whose value is null"),
            ("jsonb_to_record", "(jsonb)", "An object as a row with columns you define"),
            ("jsonb_typeof", "(jsonb)", "The type of the outermost value"),
            ("row_to_json", "(record[, pretty])", "A row as a JSON object"),
            ("to_json", "(anyelement)", "A value as JSON"),
            ("to_jsonb", "(anyelement)", "A value as jsonb"),
        ])
        add(.array, [
            ("array_append", "(anyarray, anyelement)", "Appends an element"),
            ("array_cat", "(anyarray, anyarray)", "Concatenates two arrays"),
            ("array_dims", "(anyarray)", "The dimensions as text"),
            ("array_fill", "(anyelement, int[][, int[]])", "An array filled with a value"),
            ("array_length", "(anyarray, int)", "The length of a dimension"),
            ("array_lower", "(anyarray, int)", "The lower bound of a dimension"),
            ("array_ndims", "(anyarray)", "The number of dimensions"),
            ("array_position", "(anyarray, anyelement[, int])", "The first position of an element"),
            ("array_positions", "(anyarray, anyelement)", "Every position of an element"),
            ("array_prepend", "(anyelement, anyarray)", "Prepends an element"),
            ("array_remove", "(anyarray, anyelement)", "Removes every occurrence of an element"),
            ("array_replace", "(anyarray, anyelement, anyelement)", "Replaces an element"),
            ("array_to_string", "(anyarray, text[, text])", "Joins the elements with a delimiter"),
            ("array_upper", "(anyarray, int)", "The upper bound of a dimension"),
            ("cardinality", "(anyarray)", "The total number of elements"),
            ("generate_series", "(start, stop[, step])", "A series of values as rows"),
            ("generate_subscripts", "(anyarray, dim)", "The subscripts of a dimension as rows"),
            ("trim_array", "(anyarray, int)", "The array without its last n elements"),
            ("unnest", "(anyarray)", "The elements as rows"),
        ])
        add(.range, [
            ("isempty", "(anyrange)", "Whether the range is empty"),
            ("lower", "(anyrange)", "The lower bound"),
            ("lower_inc", "(anyrange)", "Whether the lower bound is inclusive"),
            ("range_merge", "(anyrange, anyrange)", "The smallest range containing both"),
            ("upper", "(anyrange)", "The upper bound"),
            ("upper_inc", "(anyrange)", "Whether the upper bound is inclusive"),
        ])
        add(.fullText, [
            ("phraseto_tsquery", "([config,] query)", "A phrase as a text-search query"),
            ("plainto_tsquery", "([config,] query)", "Plain words as a text-search query"),
            ("to_tsquery", "([config,] query)", "Text as a text-search query"),
            ("to_tsvector", "([config,] document)", "Text as a searchable vector"),
            ("ts_headline", "([config,] document, query[, options])", "The document with matches highlighted"),
            ("ts_rank", "([weights,] vector, query[, normalization])", "How well a document matches"),
            ("ts_rank_cd", "([weights,] vector, query[, normalization])", "Cover-density ranking"),
            ("websearch_to_tsquery", "([config,] query)", "Web-search syntax as a text-search query"),
        ])
        add(.encryption, [
            ("gen_random_uuid", "()", "A random UUID"),
            ("md5", "(text | bytea)", "The MD5 hash as hex"),
            ("sha224", "(bytea)", "The SHA-224 hash"),
            ("sha256", "(bytea)", "The SHA-256 hash"),
            ("sha384", "(bytea)", "The SHA-384 hash"),
            ("sha512", "(bytea)", "The SHA-512 hash"),
        ])
        add(.sequence, [
            ("currval", "(regclass)", "The value the sequence last returned in this session"),
            ("lastval", "()", "The value any sequence last returned in this session"),
            ("nextval", "(regclass)", "The next value of a sequence"),
            ("setval", "(regclass, bigint[, boolean])", "Sets a sequence's current value"),
        ])
        add(.information, [
            ("col_description", "(table oid, column_number)", "The comment on a column"),
            ("current_database", "()", "The current database"),
            ("current_schema", "()", "The first schema in the search path"),
            ("current_schemas", "(boolean)", "The schemas in the search path"),
            ("current_setting", "(setting_name[, missing_ok])", "The value of a setting"),
            ("current_user", "", "The user of the current execution context"),
            ("inet_client_addr", "()", "The client's address"),
            ("inet_server_addr", "()", "The server's address"),
            ("obj_description", "(oid, catalog)", "The comment on an object"),
            ("pg_backend_pid", "()", "The pid of this session's backend"),
            ("pg_conf_load_time", "()", "When the configuration was last loaded"),
            ("pg_current_xact_id", "()", "The current transaction id"),
            ("pg_database_size", "(name | oid)", "The size of a database in bytes"),
            ("pg_get_functiondef", "(func oid)", "The CREATE FUNCTION statement of a function"),
            ("pg_get_viewdef", "(view oid[, pretty])", "The SELECT behind a view"),
            ("pg_indexes_size", "(regclass)", "The size of a table's indexes"),
            ("pg_postmaster_start_time", "()", "When the server started"),
            ("pg_relation_size", "(regclass[, fork])", "The size of a relation's main fork"),
            ("pg_size_pretty", "(bigint | numeric)", "Bytes as a human-readable size"),
            ("pg_table_size", "(regclass)", "The size of a table without its indexes"),
            ("pg_total_relation_size", "(regclass)", "The size of a table with its indexes and TOAST"),
            ("session_user", "", "The session user"),
            ("set_config", "(setting_name, new_value, is_local)", "Sets a setting"),
            ("txid_current", "()", "The current transaction id (legacy form)"),
            ("version", "()", "The server version"),
        ])
        add(.system, [
            ("pg_advisory_lock", "(key)", "Takes a session-level advisory lock"),
            ("pg_advisory_unlock", "(key)", "Releases a session-level advisory lock"),
            ("pg_cancel_backend", "(pid)", "Cancels a backend's current query"),
            ("pg_sleep", "(seconds)", "Pauses for a number of seconds"),
            ("pg_terminate_backend", "(pid[, timeout])", "Terminates a backend"),
            ("pg_try_advisory_lock", "(key)", "Takes an advisory lock if it is free"),
        ])
        add(.xml, [
            ("xmlcomment", "(text)", "An XML comment"),
            ("xmlconcat", "(xml, …)", "Concatenates XML values"),
            ("xmlelement", "(NAME name[, XMLATTRIBUTES(…)][, content…])", "An XML element"),
            ("xmlforest", "(content [AS name], …)", "A forest of elements"),
            ("xpath", "(xpath, xml[, nsarray])", "Nodes matching an XPath"),
            ("xpath_exists", "(xpath, xml[, nsarray])", "Whether an XPath matches"),
            ("xmltable", "(row_expression PASSING document COLUMNS …)", "An XML document as a table"),
        ])
        return list
    }()

    // MARK: - SQLite

    static let sqlite: [SQLFunction] = {
        var list: [SQLFunction] = []
        func add(_ category: SQLFunctionCategory, _ entries: [(String, String, String)]) {
            for (name, arguments, summary) in entries { list.append(SQLFunction(name, arguments, category, summary)) }
        }
        add(.dateTime, [
            ("date", "(time-value[, modifier, …])", "A date as YYYY-MM-DD"),
            ("time", "(time-value[, modifier, …])", "A time as HH:MM:SS"),
            ("datetime", "(time-value[, modifier, …])", "A date and time as YYYY-MM-DD HH:MM:SS"),
            ("julianday", "(time-value[, modifier, …])", "The Julian day number"),
            ("unixepoch", "(time-value[, modifier, …])", "Seconds since 1970-01-01"),
            ("strftime", "(format, time-value[, modifier, …])", "A date formatted: %Y year, %m month, %d day, %H hour…"),
            ("timediff", "(time-value, time-value)", "The difference between two times"),
            ("CURRENT_DATE", "", "The current date, in UTC"),
            ("CURRENT_TIME", "", "The current time, in UTC"),
            ("CURRENT_TIMESTAMP", "", "The current date and time, in UTC"),
        ])
        add(.string, [
            ("char", "(X1, X2, …)", "Characters for Unicode code points"),
            ("concat", "(X, …)", "Joins the text of the arguments"),
            ("concat_ws", "(SEP, X, …)", "Joins with a separator"),
            ("format", "(FORMAT, …)", "Formats arguments like printf"),
            ("glob", "(X, Y)", "Whether Y matches the GLOB pattern X"),
            ("hex", "(X)", "A blob or text as hexadecimal"),
            ("instr", "(X, Y)", "The position of Y in X"),
            ("length", "(X)", "The length in characters, or bytes for a blob"),
            ("like", "(X, Y[, Z])", "Whether Y matches the LIKE pattern X"),
            ("lower", "(X)", "Lower case (Unicode-aware in Tinker)"),
            ("ltrim", "(X[, Y])", "Removes leading characters"),
            ("octet_length", "(X)", "The length in bytes"),
            ("printf", "(FORMAT, …)", "Formats arguments like printf"),
            ("quote", "(X)", "The value as a SQL literal"),
            ("replace", "(X, Y, Z)", "Replaces every Y in X with Z"),
            ("rtrim", "(X[, Y])", "Removes trailing characters"),
            ("soundex", "(X)", "A soundex string"),
            ("substr", "(X, Y[, Z])", "A substring"),
            ("substring", "(X, Y[, Z])", "A substring"),
            ("trim", "(X[, Y])", "Removes leading and trailing characters"),
            ("unhex", "(X[, Y])", "Hexadecimal digits as a blob"),
            ("unicode", "(X)", "The code point of the first character"),
            ("upper", "(X)", "Upper case (Unicode-aware in Tinker)"),
            ("zeroblob", "(N)", "A blob of N zero bytes"),
        ])
        add(.numeric, [
            ("abs", "(X)", "The absolute value"),
            ("acos", "(X)", "The arc cosine"),
            ("acosh", "(X)", "The inverse hyperbolic cosine"),
            ("asin", "(X)", "The arc sine"),
            ("asinh", "(X)", "The inverse hyperbolic sine"),
            ("atan", "(X)", "The arc tangent"),
            ("atan2", "(Y, X)", "The arc tangent of Y/X"),
            ("atanh", "(X)", "The inverse hyperbolic tangent"),
            ("ceil", "(X)", "The smallest integer not less than X"),
            ("ceiling", "(X)", "The smallest integer not less than X"),
            ("cos", "(X)", "The cosine"),
            ("cosh", "(X)", "The hyperbolic cosine"),
            ("degrees", "(X)", "Radians as degrees"),
            ("exp", "(X)", "e raised to the power of X"),
            ("floor", "(X)", "The largest integer not greater than X"),
            ("ln", "(X)", "The natural logarithm"),
            ("log", "([B,] X)", "The base-10 logarithm, or to a base"),
            ("log10", "(X)", "The base-10 logarithm"),
            ("log2", "(X)", "The base-2 logarithm"),
            ("mod", "(X, Y)", "The remainder"),
            ("pi", "()", "The value of π"),
            ("pow", "(X, Y)", "X raised to the power of Y"),
            ("power", "(X, Y)", "X raised to the power of Y"),
            ("radians", "(X)", "Degrees as radians"),
            ("random", "()", "A random 64-bit integer"),
            ("randomblob", "(N)", "N random bytes"),
            ("round", "(X[, Y])", "Rounds to Y decimals"),
            ("sign", "(X)", "The sign: -1, 0 or 1"),
            ("sin", "(X)", "The sine"),
            ("sinh", "(X)", "The hyperbolic sine"),
            ("sqrt", "(X)", "The square root"),
            ("tan", "(X)", "The tangent"),
            ("tanh", "(X)", "The hyperbolic tangent"),
            ("trunc", "(X)", "The integer part"),
        ])
        add(.aggregate, [
            ("avg", "(X)", "The average"),
            ("count", "(X | *)", "How many rows"),
            ("group_concat", "(X[, Y])", "The values joined with a separator"),
            ("string_agg", "(X, Y)", "The values joined with a separator"),
            ("max", "(X)", "The largest value"),
            ("min", "(X)", "The smallest value"),
            ("sum", "(X)", "The total, as an integer when every value is one"),
            ("total", "(X)", "The total, always as a floating-point number"),
            ("json_group_array", "(value)", "The values as a JSON array"),
            ("json_group_object", "(name, value)", "Pairs as a JSON object"),
        ])
        add(.window, [
            ("cume_dist", "() OVER (…)", "The cumulative distribution of a row"),
            ("dense_rank", "() OVER (…)", "The rank without gaps"),
            ("first_value", "(expr) OVER (…)", "The value of the first row of the frame"),
            ("lag", "(expr[, offset[, default]]) OVER (…)", "The value offset rows before"),
            ("last_value", "(expr) OVER (…)", "The value of the last row of the frame"),
            ("lead", "(expr[, offset[, default]]) OVER (…)", "The value offset rows after"),
            ("nth_value", "(expr, N) OVER (…)", "The value of the N-th row of the frame"),
            ("ntile", "(N) OVER (…)", "The bucket number out of N"),
            ("percent_rank", "() OVER (…)", "The relative rank"),
            ("rank", "() OVER (…)", "The rank with gaps"),
            ("row_number", "() OVER (…)", "The row's number within its partition"),
        ])
        add(.conditional, [
            ("CASE", " WHEN … THEN … [ELSE …] END", "Picks a result by condition"),
            ("coalesce", "(X, Y, …)", "The first non-NULL argument"),
            ("ifnull", "(X, Y)", "X, or Y when X is NULL"),
            ("iif", "(X, Y, Z)", "Y when X is true, else Z"),
            ("max", "(X, Y, …)", "The largest argument"),
            ("min", "(X, Y, …)", "The smallest argument"),
            ("nullif", "(X, Y)", "NULL when the two are equal, else X"),
        ])
        add(.conversion, [
            ("CAST", "(expr AS type)", "The value converted to a type"),
            ("typeof", "(X)", "The storage class of a value: integer, real, text, blob or null"),
        ])
        add(.json, [
            ("json", "(X)", "The text as minified JSON, checked for validity"),
            ("jsonb", "(X)", "The text as binary JSON"),
            ("json_array", "(value, …)", "A JSON array"),
            ("json_array_length", "(json[, path])", "How many elements an array has"),
            ("json_error_position", "(json)", "Where the text stops being valid JSON, or 0"),
            ("json_extract", "(json, path, …)", "The values at the paths"),
            ("json_insert", "(json, path, value, …)", "Inserts values where nothing is yet"),
            ("json_object", "(label, value, …)", "A JSON object"),
            ("json_patch", "(json, patch)", "Applies an RFC 7396 merge patch"),
            ("json_pretty", "(json[, indent])", "The document pretty-printed"),
            ("json_quote", "(value)", "A SQL value as a JSON value"),
            ("json_remove", "(json, path, …)", "Removes the values at the paths"),
            ("json_replace", "(json, path, value, …)", "Replaces existing values"),
            ("json_set", "(json, path, value, …)", "Inserts or replaces values"),
            ("json_type", "(json[, path])", "The type of a JSON value"),
            ("json_valid", "(json[, flags])", "Whether the text is valid JSON"),
            ("json_each", "(json[, path])", "The top-level elements as rows"),
            ("json_tree", "(json[, path])", "Every element, recursively, as rows"),
        ])
        add(.information, [
            ("changes", "()", "Rows changed by the last INSERT, UPDATE or DELETE"),
            ("last_insert_rowid", "()", "The rowid of the last insert"),
            ("sqlite_compileoption_get", "(N)", "The N-th compile option"),
            ("sqlite_compileoption_used", "(X)", "Whether a compile option is set"),
            ("sqlite_source_id", "()", "The library's source identifier"),
            ("sqlite_version", "()", "The library version"),
            ("total_changes", "()", "Rows changed since the connection opened"),
        ])
        add(.miscellaneous, [
            ("likelihood", "(X, Y)", "A planner hint: X with probability Y"),
            ("likely", "(X)", "A planner hint: X is probably true"),
            ("unlikely", "(X)", "A planner hint: X is probably false"),
            ("load_extension", "(X[, Y])", "Loads an extension library"),
            ("sqlite_offset", "(X)", "The byte offset of a column's record in the file"),
        ])
        return list
    }()
}
