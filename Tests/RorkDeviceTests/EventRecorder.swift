import Foundation

/// Thread-safe event sink used by async tests.
///
/// Production progress handlers are `@Sendable`, so tests cannot safely mutate
/// a captured array from the callback. `EventRecorder` keeps those events behind
/// a lock and exposes snapshots for assertions after the operation finishes.
final class EventRecorder<Event>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Event] = []

    func append(_ event: Event) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var values: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
