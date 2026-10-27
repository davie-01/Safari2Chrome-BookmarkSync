import Foundation

/// Calls `onChange` (on `queue`) when a file may have changed: written in place, or replaced
/// by a rename into its directory (how Safari and our own writer save). It only says "look
/// again"; callers still compare the file themselves, and keep a slow poll for anything a
/// watcher can miss (the folder itself replaced, no permission to watch).
public final class FileWatcher {
    public let url: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    public init(url: URL, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
        queue.setSpecific(key: FileWatcher.queueKey, value: ObjectIdentifier(queue))
    }

    deinit { stop() }

    /// Returns false when the folder cannot be watched (missing, or no Full Disk Access).
    @discardableResult
    public func start() -> Bool {
        onQueue {
            stopSources()
            dirSource = source(url.deletingLastPathComponent().path, [.write]) { [weak self] _ in
                // an entry was added, removed or renamed: maybe a new copy of our file
                self?.watchFile()
                self?.onChange()
            }
            watchFile()
            return dirSource != nil
        }
    }

    public func stop() { onQueue { stopSources() } }

    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    /// Sources are only touched on `queue`; callers may or may not already be on it.
    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: FileWatcher.queueKey) == ObjectIdentifier(queue) ? body() : queue.sync(execute: body)
    }

    private func stopSources() {
        dirSource?.cancel(); dirSource = nil
        fileSource?.cancel(); fileSource = nil
    }

    /// (Re)attaches to the file currently at `url`; the old one may have been renamed away.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = source(url.path, [.write, .extend, .delete, .rename]) { [weak self] events in
            if !events.isDisjoint(with: [.delete, .rename]) { self?.watchFile() }
            self?.onChange()
        }
    }

    private func source(_ path: String, _ mask: DispatchSource.FileSystemEvent,
                        _ handler: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        s.setEventHandler { [weak s] in handler(s?.data ?? []) }
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }
}
