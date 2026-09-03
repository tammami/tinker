/// The SQL dialect a driver speaks. Used to select quoting, paging, DML generation
/// and introspection strategies without the caller knowing the concrete driver.
public enum SQLDialect: String, Sendable, Hashable, Codable, CaseIterable {
    case postgresql
    case mysql
}
