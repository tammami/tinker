import DBCore
import Foundation

/// Compares two table structures and writes the DDL that would make the target match the
/// source (SPEC §15b.4).
///
/// It is a generator, not an applier: the result is meant for a SQL editor tab, where the
/// user reads it before anything runs. Nothing here executes, and nothing here decides that
/// a drop is acceptable — destructive statements are marked so the caller can list them
/// apart and leave them out.
public struct StructureSync: Sendable {
    /// What comparing two tables found.
    public struct Result: Sendable {
        /// The statements, in the order they must run.
        public let statements: [GeneratedDDL]
        /// The target table the statements would change.
        public let target: TableRef

        public var isIdentical: Bool { statements.isEmpty }
        public var destructive: [GeneratedDDL] { statements.filter(\.isDestructive) }
        public var safe: [GeneratedDDL] { statements.filter { !$0.isDestructive } }

        public init(statements: [GeneratedDDL], target: TableRef) {
            self.statements = statements
            self.target = target
        }

        /// The script, as it would appear in an editor tab.
        ///
        /// `includingDestructive` is false by default because a sync that silently drops a
        /// column the user never looked at is the one thing this must not do.
        public func script(includingDestructive: Bool = false) -> String {
            guard !statements.isEmpty else {
                return "-- The target already matches the source.\n"
            }
            // Not `chosen.isEmpty`: a difference made entirely of drops is still a
            // difference, and saying the target matches would be a lie.
            let chosen = includingDestructive ? statements : safe

            var lines: [String] = []
            if !includingDestructive, !destructive.isEmpty {
                lines.append(
                    "-- \(destructive.count) destructive statement"
                        + (destructive.count == 1 ? " was" : "s were")
                        + " left out. They are listed at the end, commented."
                )
                lines.append("")
            }
            lines.append(contentsOf: chosen.map { "\($0.sql);" })
            if !includingDestructive, !destructive.isEmpty {
                lines.append("")
                lines.append("-- Left out:")
                lines.append(contentsOf: destructive.map { "-- \($0.sql);" })
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    public let dialect: SQLDialect

    public init(dialect: SQLDialect) {
        self.dialect = dialect
    }

    /// The statements that would make `target` match `source`.
    ///
    /// The two definitions come from different servers, so their objects share no identity:
    /// a column in one is the same column as another only when they are named the same.
    /// The definitions are rewritten onto a shared set of identities before diffing, which
    /// is what stops every column being reported as dropped and re-added.
    public func compare(source: TableDefinition, target: TableDefinition) -> Result {
        let (alignedTarget, alignedSource) = alignIdentities(source: source, target: target)
        let statements = DDLGenerator(dialect: dialect).alter(from: alignedTarget, to: alignedSource)
        return Result(statements: statements, target: target.ref)
    }

    /// A table that exists in the source and not in the target.
    public func create(source: TableDefinition, in schema: SchemaRef) -> Result {
        var definition = source
        definition.ref = TableRef(schema: schema, name: source.ref.name)
        return Result(
            statements: DDLGenerator(dialect: dialect).create(definition),
            target: definition.ref
        )
    }

    /// Rewrites both definitions so that objects matched by name share an identity, and
    /// gives the source the target's name so a rename is not generated.
    private func alignIdentities(
        source: TableDefinition, target: TableDefinition
    ) -> (target: TableDefinition, source: TableDefinition) {
        var alignedSource = source
        var alignedTarget = target
        // The sync changes the target in place; it does not rename it to the source's name.
        alignedSource.ref = target.ref

        alignedSource.columns = source.columns.map { column in
            var copy = column
            if let match = target.columns.first(where: { $0.name == column.name }) {
                copy = ColumnDefinition(
                    id: match.id,
                    name: column.name,
                    type: column.type,
                    isNullable: column.isNullable,
                    defaultExpression: column.defaultExpression,
                    isAutoIncrement: column.isAutoIncrement,
                    generatedExpression: column.generatedExpression,
                    isGeneratedStored: column.isGeneratedStored,
                    characterSet: column.characterSet,
                    collation: column.collation,
                    comment: column.comment
                )
            }
            return copy
        }

        alignedSource.indexes = source.indexes.map { index in
            guard let match = target.indexes.first(where: { $0.name == index.name }) else {
                return index
            }
            return IndexDefinition(
                id: match.id,
                name: index.name,
                columns: index.columns,
                isUnique: index.isUnique,
                method: index.method,
                predicate: index.predicate,
                comment: index.comment
            )
        }

        alignedSource.foreignKeys = source.foreignKeys.map { key in
            guard let match = target.foreignKeys.first(where: { $0.name == key.name }) else {
                return key
            }
            return ForeignKeyDefinition(
                id: match.id,
                name: key.name,
                columns: key.columns,
                // The reference points into the target's own schema, not the source's.
                referencedTable: TableRef(
                    database: target.ref.database,
                    schema: target.ref.schema,
                    name: key.referencedTable.name
                ),
                referencedColumns: key.referencedColumns,
                onUpdate: key.onUpdate,
                onDelete: key.onDelete,
                isDeferrable: key.isDeferrable,
                isInitiallyDeferred: key.isInitiallyDeferred
            )
        }

        alignedSource.checks = source.checks.map { check in
            guard let match = target.checks.first(where: { $0.name == check.name }) else {
                return check
            }
            return CheckDefinition(id: match.id, name: check.name, expression: check.expression)
        }

        alignedTarget.ref = target.ref
        return (alignedTarget, alignedSource)
    }
}
