import Foundation

/// A minimal lock-protected box for sharing a value between the camera's
/// capture-delegate thread and the main thread without paying an actor-hop
/// on every frame (the video-data-output queue runs at up to ~30-60 Hz).
final class ThreadSafeBox<Value> {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}
