import Foundation

/// A serial executor backed by one dedicated thread.
///
/// SQLite's calls block the calling thread while they run; a `SELECT` over a large table
/// can hold it for seconds. Running them on a cooperative-pool thread would starve every
/// other actor in the process, so each ``SQLiteConnection`` runs on its own thread instead,
/// which is also exactly what SQLite's threading rules want: one connection, one thread.
///
/// The thread stops when the executor is released, which happens when its actor is.
/// `@unchecked`: the thread handle is only ever read, and the mailbox locks itself.
final class SQLiteExecutor: SerialExecutor, @unchecked Sendable {
    /// The shared state between the executor and its thread. Lock-protected so the thread
    /// can outlive the executor by the moment it takes to notice `stopped`.
    private final class Mailbox: @unchecked Sendable {
        let condition = NSCondition()
        var jobs: [UnownedJob] = []
        var stopped = false

        func push(_ job: UnownedJob) {
            condition.lock()
            jobs.append(job)
            condition.signal()
            condition.unlock()
        }

        /// The next job, or nil once the mailbox is stopped and drained.
        func pop() -> UnownedJob? {
            condition.lock()
            defer { condition.unlock() }
            while jobs.isEmpty, !stopped { condition.wait() }
            return jobs.isEmpty ? nil : jobs.removeFirst()
        }

        func stop() {
            condition.lock()
            stopped = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private let mailbox = Mailbox()
    /// The thread's handle on the executor: unowned so the thread never keeps the
    /// executor, and with it the connection, alive.
    private let thread: Thread

    init(name: String) {
        let mailbox = self.mailbox
        // Filled in below; the thread body reads it only after `start()`.
        let reference = Reference()
        thread = Thread {
            while let job = mailbox.pop() {
                guard let executor = reference.executor else { break }
                job.runSynchronously(on: executor.asUnownedSerialExecutor())
            }
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        reference.executor = self
        thread.start()
    }

    deinit {
        mailbox.stop()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        mailbox.push(UnownedJob(job))
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// True when called from this executor's own thread.
    var isCurrentThread: Bool { Thread.current === thread }

    /// A weak back-reference the thread can read without retaining the executor.
    private final class Reference: @unchecked Sendable {
        weak var executor: SQLiteExecutor?
    }
}
