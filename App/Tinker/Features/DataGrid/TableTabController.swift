import AppKit
import DBCore
import DBGrid
import DBSQL
import DBStore
import Foundation
import Observation
import SwiftUI

/// Owns one table tab: its grid model, its selection, and everything the toolbar and
/// context menus act on.
@MainActor
@Observable
public final class TableTabController: DataGridDelegate {
    public private(set) var model: GridModel?
    public var selection = GridSelection()
    /// Bumped whenever the grid's contents changed, which is what makes the view reload.
    public private(set) var revision = 0
    public var columnWidths: [String: Double] = [:]
    /// Columns kept off the grid for this table. Remembered with the widths.
    public var hiddenColumns: Set<String> = []
    public var filterRules: [FilterRule] = []
    /// The quick search across every column. Transient: it is not remembered per table.
    public var quickSearch = ""
    /// Foreign keys, the labels beside their values, and the row picker.
    @ObservationIgnored private let references: ReferenceSupport
    /// The table's foreign keys, for jumping to the row a cell points at.
    public var foreignKeys: [ForeignKeyInfo] { references.foreignKeys }
    public var statusText = ""
    public var errorText: String?
    public var isLoading = false
    public var columnsInfo: [ColumnInfo] = []
    /// On, an edit writes as soon as it is made; off, edits wait for Commit (SPEC §12.3).
    public var autoCommit = true
    /// Asks the user before something irreversible. Set by the workspace that owns the
    /// tab when it creates the controller, not by a view, so it is there before the tab
    /// has appeared. With none set (a headless run) the question is answered "yes".
    @ObservationIgnored public var confirm: ((DestructiveConfirmation) -> Void)?
    /// One write at a time, requests during a write merged into the next (shared with the
    /// query tab's result grids).
    private let writes = GridWriteQueue()
    /// True while an auto-commit write is on the server.
    public var isWriting: Bool { writes.isWriting }

    public let table: TableRef
    public let connectionID: UUID
    private let environment: AppEnvironment
    private let dialect: SQLDialect
    private var saveWidthsTask: Task<Void, Never>?

    public init(
        table: TableRef,
        connectionID: UUID,
        dialect: SQLDialect,
        environment: AppEnvironment
    ) {
        self.table = table
        self.connectionID = connectionID
        self.dialect = dialect
        self.environment = environment
        references = ReferenceSupport(environment: environment, connectionID: connectionID, dialect: dialect)
    }

    /// The session on the table's own database (PostgreSQL) or the connection's (MySQL).
    var session: ConnectionSession? { environment.session(for: connectionID, table: table) }

    @ObservationIgnored private var structureController: StructureController?

    /// The Structure tab's controller, built the first time the user asks for it so
    /// opening a table still costs one round of introspection rather than two.
    public var structure: StructureController {
        if let structureController { return structureController }
        let controller = StructureController(
            table: table, connectionID: connectionID, dialect: dialect, environment: environment
        )
        structureController = controller
        return controller
    }

    /// True when the connection is marked as production, which the preview sheet uses to
    /// delay its Execute button.
    public var isProduction: Bool {
        environment.connections.first { $0.id == connectionID }?.isProduction ?? false
    }

    /// Whether edits write as they are made. Never on a production connection: there
    /// every write goes through the commit sheet, whatever the checkbox says.
    public var autoCommitsEdits: Bool { autoCommit && !isProduction }

    /// Re-reads the grid after the designer changed the table underneath it, so a new
    /// primary key makes the grid editable without the tab being reopened.
    public func reloadAfterStructureChange() async {
        await start()
        // Edits that have not run yet survive the re-read; only a run replaces them.
        await structure.load(force: true, keepingEdits: true)
    }

    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// Reads the table's shape, restores remembered preferences, and loads the first page.
    ///
    /// Single-flight: the view's `.task` and a "follow this foreign key" both call it when
    /// the model is still nil, and two starts built two grids, the later one silently
    /// replacing the first and any filter applied to it.
    public func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await performStart()
        }
        startTask = task
        await task.value
        startTask = nil
    }

    private func performStart() async {
        guard let session else {
            errorText = "This connection is no longer configured"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let table = table
            let columns = try await session.introspection(.columns(table)) {
                try await $0.columns(of: table)
            }
            let identity =
                try await session.introspection(.primaryKey(table)) {
                    try await $0.rowIdentity(of: table)
                } ?? []
            let estimate = try? await session.introspection(.rowCount(table)) {
                try await $0.approximateRowCount(table)
            }
            columnsInfo = columns
            await references.load(table: table, session: session)

            let preferences = await environment.gridPreferences(
                connectionID: connectionID, table: table.id
            )
            columnWidths = preferences.columnWidths
            hiddenColumns = Set(preferences.hiddenColumns)
            filterRules = preferences.filter.compactMap { stored in
                guard let op = FilterOperator(rawValue: stored.op) else { return nil }
                let conjunction = stored.conjunction.flatMap(FilterConjunction.init(rawValue:)) ?? .and
                return FilterRule(column: stored.column, op: op, values: stored.values, conjunction: conjunction)
            }

            let identityKind =
                identity.count == 1
                ? columns.first { $0.name == identity[0] }?.kind
                : nil
            let model = GridModel(
                source: .table(table),
                dialect: dialect,
                loader: SessionGridLoader(session: session, table: table, dialect: dialect),
                columns: columns.map { column in
                    ColumnMeta(
                        id: column.ordinal - 1,
                        name: column.name,
                        nativeTypeName: column.nativeType,
                        kind: column.kind,
                        isNullable: column.isNullable,
                        isPrimaryKey: column.isPrimaryKey
                    )
                },
                identityColumns: identity,
                identityKind: identityKind
            )
            model.estimatedTotal = estimate ?? nil
            // A table tab pages; a result set streams (SPEC §12.7).
            model.isPaged = true
            model.sort = preferences.sort.map {
                PagePlanner.SortTerm(column: $0.column, ascending: $0.ascending)
            }
            model.filter = effectiveFilter
            self.model = model
            await model.load(page: 0)
            bumpRevision()
            updateStatus()
            // The rows are on screen; read the structure now so the Structure switch is
            // instant. The view's own load waits for this one rather than repeating it.
            Task { [weak self] in await self?.structure.load() }
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    public func bumpRevision() {
        revision &+= 1
        scheduleReferenceLabels()
    }

    public func updateStatus() {
        guard let model else { return }
        var parts: [String] = []
        if let range = model.pageRange {
            // The rows this page covers, and the total only where it is actually known.
            parts.append("Rows \(range.lowerBound)–\(range.upperBound)")
            if let total = exactTotal {
                parts.append("of \(total)")
            } else if model.filter.isEmpty, let estimate = model.estimatedTotal {
                // An estimate is labelled as one; it is not a count (ADR-0030).
                parts.append("of ~\(estimate)")
            }
        } else if let total = model.totalCount {
            parts.append("\(total) row\(total == 1 ? "" : "s")")
        } else if model.filter.isEmpty, let estimate = model.estimatedTotal {
            parts.append("~\(estimate) rows")
        } else {
            parts.append("\(model.rowCount) loaded")
        }
        if let reason = model.readOnlyReason { parts.append(reason) }
        if model.edits.pendingStatementCount > 0 {
            parts.append(
                "\(model.edits.pendingStatementCount) pending change\(model.edits.pendingStatementCount == 1 ? "" : "s")"
            )
        }
        parts.append(model.strategy(forPage: max(0, selection.focusRow / 1_000)).explanation)
        statusText = parts.joined(separator: " • ")
    }

    // MARK: - Pages (SPEC §12.7)

    /// The matching row count, once something has asked for it. `COUNT` is not run to
    /// decorate a status bar; only Last needs it.
    public private(set) var exactTotal: Int64?

    public var currentPage: Int { (model?.pageOffset ?? 0) + 1 }
    public var canGoBack: Bool { model?.hasPreviousPage ?? false }
    /// Once the total is known, the last page is the last page even when it is full.
    public var canGoForward: Bool {
        guard let model, model.hasNextPage else { return false }
        if let total = exactTotal {
            return Int64(currentPage) * Int64(model.pageSize) < total
        }
        return true
    }

    public func goToPage(_ page: Int) async {
        guard let model else { return }
        // Pending edits survive: they are keyed by row identity (ADR-0047).
        await model.goToPage(page)
        surfaceLoadError()
        bumpRevision()
        updateStatus()
    }

    public func goToFirstPage() async { await goToPage(0) }

    public func goToPreviousPage() async {
        await goToPage(max(0, (model?.pageOffset ?? 0) - 1))
    }

    public func goToNextPage() async {
        await goToPage((model?.pageOffset ?? 0) + 1)
    }

    /// Jumping to the end needs the total, which is the one place a `COUNT` is worth it.
    public func goToLastPage() async {
        guard let model else { return }
        isLoading = true
        let total = await model.exactRowCount()
        isLoading = false
        exactTotal = total
        guard let total, total > 0 else { return }
        let size = Int64(model.pageSize)
        await goToPage(Int((total - 1) / size))
    }

    // MARK: - Commands

    public func refresh() async {
        guard let model else { return }
        await session?.invalidateIntrospection(.rowCount(table))
        await model.reload()
        bumpRevision()
        updateStatus()
    }

    /// The conditions the server sees: the filter rows plus the quick search, if any.
    private var effectiveFilter: [FilterRule] {
        // A row whose value is still empty is being typed, not applied.
        let complete = filterRules.filter { rule in
            rule.op.operandCount == 0 || rule.values.contains { !($0.text ?? "").isEmpty }
        }
        let trimmed = quickSearch.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return complete }
        // Every column but binary ones; a hex dump of a blob is not something anyone searches.
        let searchable = columnsInfo.filter { $0.kind != .bytes }.map(\.name)
        return complete + [FilterRule.search(trimmed, in: searchable)]
    }

    @ObservationIgnored private var liveFilterTask: Task<Void, Never>?

    /// Applies the quick search after a short pause in typing, so each keystroke does not
    /// send its own query and a fast typist costs the server one statement, not ten.
    public func applyQuickSearch(_ text: String) async {
        quickSearch = text
        await applyLiveFilter()
    }

    /// Applies the filter rows the same way; incomplete rows (a value still empty) wait.
    public func applyFilterLive(_ rules: [FilterRule]) {
        filterRules = rules
        Task { await applyLiveFilter(persist: true) }
    }

    private func applyLiveFilter(persist: Bool = false) async {
        liveFilterTask?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await model?.setFilter(effectiveFilter)
            guard !Task.isCancelled else { return }
            surfaceLoadError()
            bumpRevision()
            updateStatus()
            if persist { await persistPreferences() }
        }
        liveFilterTask = task
        await task.value
    }

    /// The foreign key a column takes part in, and the value the focused row holds for it.
    ///
    /// Only single-column keys can be followed from one cell; a composite key needs the
    /// whole row, which is what `referenceTarget(row:)` handles.
    public func referenceTarget(row: Int, column: Int) -> (table: TableRef, filter: [FilterRule])? {
        guard let model else { return nil }
        return references.target(row: row, column: column, in: model)
    }

    public func applyFilter(_ rules: [FilterRule]) async {
        filterRules = rules
        await model?.setFilter(effectiveFilter)
        // A filter that the server refuses used to fail silently: the rows never arrived,
        // and the grid drew the unfiltered estimate as empty rows instead of saying why.
        surfaceLoadError()
        bumpRevision()
        updateStatus()
        await persistPreferences()
    }

    /// Shows whatever the last page load failed with, verbatim (SPEC §6).
    private func surfaceLoadError() {
        guard let error = model?.lastError else { return }
        errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
    }

    public func gridDidClickColumnHeader(column: Int, additive: Bool) {
        Task { await cycleSort(columnIndex: column, additive: additive) }
    }

    public func cycleSort(columnIndex: Int, additive: Bool) async {
        guard let model, model.columns.indices.contains(columnIndex) else { return }
        await model.cycleSort(column: model.columns[columnIndex].name, additive: additive)
        surfaceLoadError()
        bumpRevision()
        updateStatus()
        await persistPreferences()
    }

    public func addRow() {
        guard let model, model.addRow() != nil else { return }
        // The new row is where the user is about to type, so focus moves into it; a row
        // added and never entered would otherwise be dropped on the next selection change.
        selection = GridSelection(row: model.displayRowCount - 1, column: 0)
        bumpRevision()
        updateStatus()
    }

    /// Marks the selected rows for deletion. With auto-commit on the DELETE reaches the
    /// server at once, so it asks first: there is no preview sheet and no Discard to
    /// catch a ⌘⌫ meant for a neighbouring key.
    public func deleteSelectedRows() {
        guard let model else { return }
        let rows = selection.rows(totalRows: model.displayRowCount)
        guard !rows.isEmpty else { return }
        let apply = { [weak self] in
            guard let self, let model = self.model else { return }
            model.markDeleted(rows: rows)
            bumpRevision()
            updateStatus()
            writeIfAutoCommit(.loadedRowsOnly)
        }
        guard autoCommitsEdits, let confirm else {
            apply()
            return
        }
        confirm(GridEditPrompts.deleteRows(count: rows.count, from: table.name) { apply() })
    }

    public func setSelectionNull() {
        guard let model else { return }
        for row in selection.rows(totalRows: model.displayRowCount) {
            for column in selection.columns(totalColumns: model.columns.count) {
                model.setValue(.null, row: row, column: column)
            }
        }
        bumpRevision()
        updateStatus()
        writeIfAutoCommit(.loadedRowsOnly)
    }

    // MARK: - Auto-commit

    /// Writes what is pending when auto-commit is on, one write at a time. A change made
    /// while a write is on the server waits for it and then goes as the next write, so
    /// two commits never run at once and no edit is lost between them.
    private func writeIfAutoCommit(_ scope: CommitScope) {
        guard autoCommitsEdits, let model, model.edits.pendingStatementCount(scope) > 0 else { return }
        enqueueWrite(scope)
    }

    /// The one gate every commit goes through — auto-commit, Retry, the toolbar's Commit
    /// and the ⌘⇧S sheet — so two never run at once. A scope asked for while a write is
    /// on the server is merged into the next write; the page is re-read once, after the
    /// queue drains, so an edit made during a write is neither lost nor written twice.
    @discardableResult
    private func enqueueWrite(_ scope: CommitScope) -> Task<Void, Never> {
        writes.enqueue(
            scope,
            hasPending: { [weak self] scope in (self?.model?.edits.pendingStatementCount(scope) ?? 0) > 0 },
            perform: { [weak self] scope in await self?.performCommit(scope) ?? false },
            afterDrain: { [weak self] in await self?.reloadAfterWrite() }
        )
    }

    /// Re-reads the page after a write, so a value the server set (a default, a trigger's
    /// work) is what the grid shows. A new row still being filled in stays.
    private func reloadAfterWrite() async {
        guard let model else { return }
        await model.reload(keepingNewRows: !model.edits.pendingInserts.isEmpty)
        bumpRevision()
        updateStatus()
    }

    /// A new row is written when the user leaves it, not while it is being filled in. A
    /// row the user added and then left untouched holds nothing, so it goes away.
    ///
    /// Not while a write is on the server: its reload empties the row count for a moment,
    /// during which the row the user is in would not read as a new row.
    private func flushNewRowsIfLeft(focusRow: Int) {
        guard autoCommitsEdits, !isWriting, let model, !model.edits.pendingInserts.isEmpty,
            !model.isPendingInsertRow(focusRow)
        else { return }
        model.edits.removeEmptyInserts()
        bumpRevision()
        updateStatus()
        writeIfAutoCommit(.everything)
    }

    /// Turning auto-commit on writes what was waiting, the way the query tab commits its
    /// open transaction.
    public func autoCommitDidChange() {
        guard autoCommitsEdits else { return }
        writeIfAutoCommit(.loadedRowsOnly)
        flushNewRowsIfLeft(focusRow: selection.focusRow)
    }

    /// Drops every pending edit. Refused while a write is on the server: what is on the
    /// wire will land whatever the grid shows, so the answer would be a lie.
    public func discardEdits() {
        guard !isWriting else { return }
        model?.edits.discardAll()
        bumpRevision()
        updateStatus()
    }

    /// The statements a commit would run, for the preview sheet.
    public func pendingStatements() -> [GeneratedStatement] {
        (try? model?.pendingStatements()) ?? []
    }

    /// Commits the pending changes of `scope` and re-reads the page. Goes through the
    /// same single-flight gate as auto-commit, so it waits for a write already on the
    /// server rather than running beside it. Returns what happened, for the status bar.
    public func commit(_ scope: CommitScope = .everything) async -> String? {
        lastCommitMessage = nil
        await enqueueWrite(scope).value
        return lastCommitMessage ?? errorText
    }

    /// The last commit's outcome: a count, or nil when nothing was pending.
    @ObservationIgnored private var lastCommitMessage: String?

    /// Runs one commit. Returns false when the server refused it; the edits stay put
    /// and the message is in `errorText`, which the status bar shows beside Retry.
    private func performCommit(_ scope: CommitScope) async -> Bool {
        guard let model, let session else { return false }
        if await session.isReadOnly {
            errorText = "This connection is read-only"
            return false
        }
        do {
            let runner = SessionStatementRunner(session: session)
            let result = try await model.commit(using: runner, scope: scope)
            if result.statementCount > 0 {
                lastCommitMessage =
                    "Committed \(result.statementCount) statement\(result.statementCount == 1 ? "" : "s")"
            }
            errorText = nil
            bumpRevision()
            updateStatus()
            return true
        } catch let error as GridCommitError {
            errorText = error.description
            return false
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
            return false
        }
    }

    // MARK: - Clipboard

    public func selectedRowsAndColumns() -> (columns: [ColumnMeta], rows: [[DBValue]]) {
        guard let model else { return ([], []) }
        let columnIndices = selection.columns(totalColumns: model.columns.count)
        let rowIndices = selection.rows(totalRows: model.displayRowCount)
        let columns = columnIndices.compactMap { index in
            model.columns.indices.contains(index) ? model.columns[index] : nil
        }
        let rows = rowIndices.map { row in
            columnIndices.map { column in model.value(row: row, column: column) ?? .null }
        }
        return (columns, rows)
    }

    public func copySelection(format: ClipboardFormat, nullText: String = "") {
        let (columns, rows) = selectedRowsAndColumns()
        guard !rows.isEmpty else { return }
        let text = ClipboardFormatter.render(
            columns: columns, rows: rows, format: format,
            options: .init(
                nullText: nullText,
                includeHeader: format == .csv || format == .markdown,
                dialect: dialect,
                table: table
            )
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Pastes tab-separated text into the grid starting at the focused cell, adding rows
    /// when the paste runs past the end (SPEC §12.4).
    public func paste() {
        guard let model, model.isEditable,
            let text = NSPasteboard.general.string(forType: .string)
        else { return }
        let rows = ClipboardFormatter.parseTSV(text)
        guard !rows.isEmpty else { return }
        let startRow = selection.focusRow
        let startColumn = selection.focusColumn
        var invalid = 0

        for (rowOffset, values) in rows.enumerated() {
            let targetRow = startRow + rowOffset
            if targetRow >= model.displayRowCount { model.addRow() }
            for (columnOffset, text) in values.enumerated() {
                let targetColumn = startColumn + columnOffset
                guard model.columns.indices.contains(targetColumn) else { continue }
                let kind = model.columns[targetColumn].kind
                guard let value = Self.coerce(text, to: kind) else {
                    invalid += 1
                    continue
                }
                model.setValue(value, row: targetRow, column: targetColumn)
            }
        }
        bumpRevision()
        updateStatus()
        if invalid > 0 {
            errorText =
                "\(invalid) pasted value\(invalid == 1 ? "" : "s") did not fit the column type and "
                + "\(invalid == 1 ? "was" : "were") left unchanged"
        }
    }

    /// Turns typed text into a value of the column's kind, or nil when it does not fit.
    public static func coerce(_ text: String, to kind: DBValueKind) -> DBValue? {
        ValueCoercion.coerce(text, to: kind)
    }

    // MARK: - Preferences

    func persistPreferences() async {
        guard let model else { return }
        let preferences = GridPreferences(
            columnWidths: columnWidths,
            sort: model.sort.map { GridSortTerm(column: $0.column, ascending: $0.ascending) },
            filter: filterRules.map {
                StoredFilterRule(
                    column: $0.column, op: $0.op.rawValue, values: $0.values, conjunction: $0.conjunction.rawValue)
            },
            hiddenColumns: hiddenColumns.sorted()
        )
        await environment.saveGridPreferences(
            preferences, connectionID: connectionID, table: table.id
        )
    }

    // MARK: - DataGridDelegate

    /// The row the grid asked to see on the map; the view switches to the map for it.
    public var mapRequest: MapRequest?

    public func gridDidRequestShowOnMap(row: Int, column: Int) {
        mapRequest = MapRequest(row: row, column: column)
    }

    public func gridDidChangeSelection(_ selection: GridSelection) {
        self.selection = selection
        updateStatus()
        flushNewRowsIfLeft(focusRow: selection.focusRow)
    }

    public func gridDidRequestLoad(range: Range<Int>) {
        guard let model else { return }
        Task { @MainActor in
            let before = model.rowCount
            await model.ensureLoaded(range: range)
            if model.rowCount != before || model.lastError != nil {
                bumpRevision()
                updateStatus()
            }
        }
    }

    public func gridDidCommitEdit(row: Int, column: Int, text: String) {
        guard let model, model.columns.indices.contains(column) else { return }
        guard let value = Self.coerce(text, to: model.columns[column].kind) else {
            errorText = "\"\(text)\" is not a valid \(model.columns[column].nativeTypeName)"
            return
        }
        model.setValue(value, row: row, column: column)
        bumpRevision()
        updateStatus()
        // A loaded row's edit goes now; a new row's waits until the user leaves the row.
        if !model.isPendingInsertRow(row) { writeIfAutoCommit(.loadedRowsOnly) }
    }

    public func gridDidRequestInspector() {
        onRequestInspector?()
    }

    /// Set by the tab view; the grid asks for the inspector with the space bar.
    @ObservationIgnored public var onRequestInspector: (() -> Void)?
    /// Set by the tab view; the grid's context menu asks to follow a foreign key.
    @ObservationIgnored public var onFollowReference: ((TableRef, [FilterRule]) -> Void)?

    public func gridDidRequestFollowReference(row: Int, column: Int) {
        guard let target = referenceTarget(row: row, column: column) else { return }
        onFollowReference?(target.table, target.filter)
    }

    public func gridHasReference(row: Int, column: Int) -> Bool {
        referenceTarget(row: row, column: column) != nil
    }

    public func gridReferenceLabel(row: Int, column: Int) -> String? {
        guard let model else { return nil }
        return references.label(row: row, column: column, in: model)
    }

    /// Looks up, shortly after the grid changed, the labels of foreign-key values that are
    /// loaded and not known yet; a redraw follows without another round.
    private func scheduleReferenceLabels() {
        guard let model, let session else { return }
        references.scheduleLabels(model: model, session: session) { [weak self] in self?.revision &+= 1 }
    }

    /// Whether the column is (part of) a foreign key, so its value can be picked.
    public func gridColumnReferences(_ column: Int) -> Bool {
        guard let model else { return false }
        return references.columnReferences(column, in: model)
    }

    /// A picker over the referenced table for this cell, seeded with the current value and
    /// the remembered label column.
    public func gridReferencePicker(row: Int, column: Int) -> ReferencePickerModel? {
        guard let session, let model else { return nil }
        return references.picker(row: row, column: column, in: model, session: session) { [weak self] in
            self?.bumpRevision()
        }
    }

    /// Writes a chosen referenced key back to the row's local columns, each through the
    /// Writes a chosen referenced key back to the row's local columns, each through the
    /// grid's ordinary edit path so auto-commit and the production gate apply.
    /// Asks the grid to open the foreign-key picker over a cell, for the inspector's
    /// Choose button. The grid owns the popover so it can anchor to the real cell.
    public func requestReferencePicker(column: Int) {
        NotificationCenter.default.post(
            name: .tinkerPresentReferencePicker, object: self,
            userInfo: ["row": selection.focusRow, "column": column]
        )
    }

    public func gridDidPickReference(row: Int, column: Int, key: [String: DBValue]) {
        guard let model, references.apply(key: key, row: row, column: column, in: model) else { return }
        bumpRevision()
        updateStatus()
        if !model.isPendingInsertRow(row) { writeIfAutoCommit(.loadedRowsOnly) }
    }

    /// Hides or shows one column; the change is drawn at once and remembered.
    public func setColumn(_ name: String, hidden: Bool) {
        if hidden { hiddenColumns.insert(name) } else { hiddenColumns.remove(name) }
        bumpRevision()
        Task { await persistPreferences() }
    }

    public func showAllColumns() {
        guard !hiddenColumns.isEmpty else { return }
        hiddenColumns.removeAll()
        bumpRevision()
        Task { await persistPreferences() }
    }

    public func gridDidRequestHideColumn(_ column: Int) {
        guard let model, model.columns.indices.contains(column) else { return }
        setColumn(model.columns[column].name, hidden: true)
    }

    public func gridDidRequestShowAllColumns() { showAllColumns() }

    public func gridDidRequestCopy(format: ClipboardFormat) {
        copySelection(format: format, nullText: environment.nullDisplayText)
    }

    public func gridDidRequestSetNull() { setSelectionNull() }
    public func gridDidRequestDeleteRows() { deleteSelectedRows() }
    public func gridDidRequestAddRow() { addRow() }

    /// One pending change back or forward. Refused while a write is on the server: what
    /// is on the wire lands whatever the grid shows.
    public func gridDidRequestUndo() {
        guard let model, !isWriting else { return }
        model.undo()
        bumpRevision()
        updateStatus()
    }

    public func gridDidRequestRedo() {
        guard let model, !isWriting else { return }
        model.redo()
        bumpRevision()
        updateStatus()
    }

    public func gridCanUndo() -> Bool { !isWriting && (model?.canUndo ?? false) }
    public func gridCanRedo() -> Bool { !isWriting && (model?.canRedo ?? false) }

    /// The values of one row as the form view edits them, in column order.
    public func rowValues(_ row: Int) -> [DBValue]? {
        guard let model, row >= 0, row < model.displayRowCount else { return nil }
        return (0 ..< model.columns.count).map { model.value(row: row, column: $0) ?? .null }
    }

    public func gridDidChangeColumnWidths(_ widths: [String: Double]) {
        columnWidths = widths
        // Column dragging fires continuously; persist once the user stops.
        saveWidthsTask?.cancel()
        saveWidthsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.persistPreferences()
        }
    }
}
