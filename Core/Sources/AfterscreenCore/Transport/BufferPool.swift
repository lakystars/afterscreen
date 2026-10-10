import Darwin
import Foundation

/// Reusable page-aligned buffers for large payloads
/// Data from `data(capacity:fill:)` returns its buffer on release
/// Steady streaming allocates nothing
/// mmap'd buffers: Metal can wrap them without copying
public final class BufferPool {
    public static let shared = BufferPool(keep: 6)
    /// Capacities round up to this to fit varying frame sizes
    static let granule = 1 << 20

    private let keep: Int
    private let idleSeconds: TimeInterval
    private let lock = NSLock()
    private var free: [(pointer: UnsafeMutableRawPointer, capacity: Int, since: TimeInterval)] = []
    private var owned: [UnsafeMutableRawPointer: Int] = [:]
    private var trimScheduled = false
    private var observers: [(UnsafeMutableRawPointer) -> Void] = []

    /// Free buffers unused for `idleSeconds` are unmapped
    public init(keep: Int, idleSeconds: TimeInterval = 2) {
        self.keep = keep
        self.idleSeconds = idleSeconds
    }

    var freeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return free.count
    }

    /// Mapped size when `pointer` starts a buffer of this pool
    public func capacity(of pointer: UnsafeRawPointer) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return owned[UnsafeMutableRawPointer(mutating: pointer)]
    }

    /// Called with a buffer's address just before unmap
    /// Lets callers drop Metal wrappers of it
    public func addUnmapObserver(_ observer: @escaping (UnsafeMutableRawPointer) -> Void) {
        lock.lock()
        observers.append(observer)
        lock.unlock()
    }

    /// `fill` writes up to `capacity` bytes, returns the count
    public func data(capacity: Int, fill: (UnsafeMutableRawPointer) throws -> Int) rethrows -> Data {
        guard capacity > 0 else { return Data() }
        let (pointer, size) = take(capacity)
        let count: Int
        do {
            count = try fill(pointer)
        } catch {
            recycle(pointer, size)
            throw error
        }
        return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { [self] p, _ in recycle(p, size) })
    }

    /// Smallest free buffer that fits, else a new mapping
    private func take(_ count: Int) -> (UnsafeMutableRawPointer, Int) {
        lock.lock()
        defer { lock.unlock() }
        var fit: Int?
        for i in free.indices where free[i].capacity >= count && fit.map({ free[i].capacity < free[$0].capacity }) ?? true { fit = i }
        if let i = fit {
            let b = free.remove(at: i)
            return (b.pointer, b.capacity)
        }
        let capacity = (count + BufferPool.granule - 1) / BufferPool.granule * BufferPool.granule
        guard let p = mmap(nil, capacity, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), p != MAP_FAILED else {
            fatalError("BufferPool: mmap of \(capacity) bytes failed")
        }
        owned[p] = capacity
        return (p, capacity)
    }

    private func recycle(_ pointer: UnsafeMutableRawPointer, _ capacity: Int) {
        lock.lock()
        free.append((pointer, capacity, ProcessInfo.processInfo.systemUptime))
        var drop: UnsafeMutableRawPointer?
        if free.count > keep, let i = free.indices.min(by: { free[$0].capacity < free[$1].capacity }) {
            drop = free.remove(at: i).pointer
        }
        let arm = !trimScheduled
        trimScheduled = true
        lock.unlock()
        if let d = drop { unmap(d) }
        if arm { scheduleTrim() }
    }

    private func scheduleTrim() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleSeconds + 0.05) { [weak self] in self?.trim() }
    }

    /// Unmaps buffers idle for `idleSeconds`; re-arms while any are left
    func trim() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let old = free.filter { now - $0.since >= idleSeconds }
        free.removeAll { now - $0.since >= idleSeconds }
        let again = !free.isEmpty
        trimScheduled = again
        lock.unlock()
        old.forEach { unmap($0.pointer) }
        if again { scheduleTrim() }
    }

    private func unmap(_ pointer: UnsafeMutableRawPointer) {
        lock.lock()
        let size = owned.removeValue(forKey: pointer)
        let notify = observers
        lock.unlock()
        notify.forEach { $0(pointer) }
        if let size = size { munmap(pointer, size) }
    }
}
