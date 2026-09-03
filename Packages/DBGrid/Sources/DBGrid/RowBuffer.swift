import DBCore
import Foundation

/// Windowed storage for a result set's rows.
///
/// The grid must scroll a million-row table at 60 fps without ever holding it all
/// (SPEC §12.1), so rows live in fixed-size pages and pages far from the viewport are
/// evicted and refetched. The buffer never holds more than ``rowCapacity`` rows.
public struct RowBuffer: Sendable {
    /// Rows per page. Matches the page size the planner queries with.
    public let pageSize: Int
    /// Hard ceiling on rows held in memory.
    public let rowCapacity: Int
    /// Pages this far from the most recently touched page are kept; others may be evicted.
    public let residentPageRadius: Int

    private var pages: [Int: [[DBValue]]] = [:]
    /// Insertion order of page loads, used to decide what to evict.
    private var recency: [Int] = []
    private var lastTouchedPage = 0

    public init(pageSize: Int = 1_000, rowCapacity: Int = 200_000, residentPageRadius: Int = 20) {
        self.pageSize = pageSize
        self.rowCapacity = rowCapacity
        self.residentPageRadius = residentPageRadius
    }

    /// Rows currently held.
    public var count: Int { pages.values.reduce(0) { $0 + $1.count } }
    public var loadedPages: Set<Int> { Set(pages.keys) }
    public var isEmpty: Bool { pages.isEmpty }

    public func page(containing row: Int) -> Int { row / pageSize }

    /// The row at an absolute index, or nil when its page is not resident.
    public func row(at index: Int) -> [DBValue]? {
        guard index >= 0 else { return nil }
        guard let page = pages[page(containing: index)] else { return nil }
        let offset = index % pageSize
        return offset < page.count ? page[offset] : nil
    }

    public func isLoaded(_ index: Int) -> Bool {
        row(at: index) != nil
    }

    /// True when every row in `range` is resident.
    public func isLoaded(range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return true }
        return range.allSatisfy(isLoaded)
    }

    /// Pages covering `range` that are not resident, in ascending order.
    public func missingPages(for range: Range<Int>) -> [Int] {
        guard !range.isEmpty else { return [] }
        let first = page(containing: range.lowerBound)
        let last = page(containing: range.upperBound - 1)
        return (first ... last).filter { pages[$0] == nil }
    }

    /// Stores one page, evicting distant pages if that pushes the buffer past its cap.
    public mutating func store(page index: Int, rows: [[DBValue]]) {
        pages[index] = rows
        recency.removeAll { $0 == index }
        recency.append(index)
        lastTouchedPage = index
        evictIfNeeded()
    }

    /// Appends rows arriving from a stream, filling pages in order.
    ///
    /// Used by query results, where rows come as batches rather than pages and the total
    /// is unknown until the stream ends.
    public mutating func append(_ rows: [[DBValue]], startingAt index: Int) {
        var cursor = index
        var remaining = rows[...]
        while !remaining.isEmpty {
            let pageIndex = page(containing: cursor)
            let offset = cursor % pageSize
            let room = pageSize - offset
            let slice = Array(remaining.prefix(room))
            var existing = pages[pageIndex] ?? []
            if existing.count < offset {
                // A gap would misalign every later row; pad so indices stay exact.
                existing.append(contentsOf: Array(repeating: [], count: offset - existing.count))
            }
            if existing.count == offset {
                existing.append(contentsOf: slice)
            } else {
                for (position, row) in slice.enumerated() {
                    let target = offset + position
                    if target < existing.count { existing[target] = row } else { existing.append(row) }
                }
            }
            pages[pageIndex] = existing
            recency.removeAll { $0 == pageIndex }
            recency.append(pageIndex)
            lastTouchedPage = pageIndex
            cursor += slice.count
            remaining = remaining.dropFirst(slice.count)
        }
        evictIfNeeded()
    }

    /// Records which page the viewport is on, so eviction keeps the right neighbourhood.
    public mutating func noteViewport(page index: Int) {
        lastTouchedPage = index
        if pages[index] != nil {
            recency.removeAll { $0 == index }
            recency.append(index)
        }
    }

    /// Replaces one row in place, for a refetch after a commit.
    public mutating func replaceRow(at index: Int, with row: [DBValue]) {
        let pageIndex = page(containing: index)
        guard var page = pages[pageIndex] else { return }
        let offset = index % pageSize
        guard offset < page.count else { return }
        page[offset] = row
        pages[pageIndex] = page
    }

    public mutating func removeAll() {
        pages.removeAll()
        recency.removeAll()
        lastTouchedPage = 0
    }

    /// Drops the pages furthest from the viewport until the buffer fits its cap.
    ///
    /// Pages inside ``residentPageRadius`` of the viewport are kept whatever happens, so
    /// scrolling never evicts what is on screen.
    private mutating func evictIfNeeded() {
        guard count > rowCapacity else { return }
        let protectedRange = (lastTouchedPage - residentPageRadius) ... (lastTouchedPage + residentPageRadius)
        // Evict furthest-from-viewport first; ties break on age.
        let candidates =
            recency
            .filter { !protectedRange.contains($0) }
            .sorted { abs($0 - lastTouchedPage) > abs($1 - lastTouchedPage) }
        for page in candidates {
            guard count > rowCapacity else { break }
            pages.removeValue(forKey: page)
            recency.removeAll { $0 == page }
        }
    }
}
