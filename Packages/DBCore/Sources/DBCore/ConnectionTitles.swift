import Foundation

extension ConnectionConfig {
    /// The separator between folder names and the connection name in ``qualifiedName``.
    public static let folderSeparator = " › "

    /// The name with its sidebar folders in front — `Office › MySQL` — so two connections
    /// that share a name but sit in different folders read differently in a menu.
    public var qualifiedName: String {
        (groupPath + [name]).joined(separator: Self.folderSeparator)
    }

    /// Where the connection goes: `user@host:port`, or the file name for SQLite.
    public var endpointSummary: String {
        if dialect.isFileBased {
            let file = database ?? host
            return (file as NSString).lastPathComponent
        }
        let userPart = user.isEmpty ? "" : "\(user)@"
        return "\(userPart)\(host):\(port)"
    }

    /// One title per connection that tells every one of them apart.
    ///
    /// The title is the ``qualifiedName``; when two connections still read the same — the
    /// same name in the same folder — the endpoint is added after a dash. A production
    /// connection carries `· PROD`, the sidebar's badge, so a picker in a tool that writes
    /// says which target is the one that hurts.
    public static func distinctTitles(for configs: [ConnectionConfig]) -> [UUID: String] {
        var seen: [String: Int] = [:]
        for config in configs { seen[config.qualifiedName, default: 0] += 1 }
        var titles: [UUID: String] = [:]
        for config in configs {
            var title = config.qualifiedName
            if seen[config.qualifiedName, default: 0] > 1 { title += " — \(config.endpointSummary)" }
            if config.isProduction { title += " · PROD" }
            titles[config.id] = title
        }
        return titles
    }

    /// The ``distinctTitles(for:)`` entry for this connection among `configs`.
    public func distinctTitle(among configs: [ConnectionConfig]) -> String {
        Self.distinctTitles(for: configs)[id] ?? qualifiedName
    }
}
