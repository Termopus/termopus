import Foundation

/// Persistent message queue backed by UserDefaults + JSON.
///
/// When the WebSocket is disconnected, outgoing messages are enqueued here
/// and replayed automatically on reconnect. Responses (permission decisions)
/// have a shorter TTL than regular messages since they become stale quickly.
final class MessageQueue {
    static let shared = MessageQueue()

    struct QueuedMessage: Codable {
        let id: String          // UUID
        let sessionId: String
        let data: Data          // The plaintext JSON message bytes (encrypted at send time by SecureWebSocket)
        let messageType: String // "response", "message", "key", "input", "command", etc.
        let timestamp: Date
    }

    private let defaults = UserDefaults.standard
    private let queueKey = "com.termopus.messageQueue"
    private let lock = NSLock()
    private let maxMessages = 50
    private let responseTTL: TimeInterval = 30   // responses expire in 30s
    private let regularTTL: TimeInterval = 60    // regular messages expire in 60s

    private init() {}

    /// Add a message to the queue.
    func enqueue(sessionId: String, data: Data, messageType: String) {
        lock.lock()
        defer { lock.unlock() }
        var queue = loadQueue()

        // Purge stale messages first
        purgeStale(&queue)

        let msg = QueuedMessage(
            id: UUID().uuidString,
            sessionId: sessionId,
            data: data,
            messageType: messageType,
            timestamp: Date()
        )
        queue.append(msg)

        // Enforce max size — drop oldest non-response first
        while queue.count > maxMessages {
            if let idx = queue.firstIndex(where: { $0.messageType != "response" }) {
                queue.remove(at: idx)
            } else {
                queue.removeFirst()  // all responses, drop oldest
            }
        }

        saveQueue(queue)
        NSLog("[MessageQueue] Enqueued \(messageType) for session \(sessionId.prefix(12)) (queue: \(queue.count))")
    }

    /// Return non-stale messages for a session, removing them from the queue.
    func drain(sessionId: String) -> [QueuedMessage] {
        lock.lock()
        defer { lock.unlock() }
        var queue = loadQueue()
        purgeStale(&queue)

        let matching = queue.filter { $0.sessionId == sessionId }
        queue.removeAll { $0.sessionId == sessionId }
        saveQueue(queue)

        NSLog("[MessageQueue] Drained \(matching.count) messages for session \(sessionId.prefix(12))")
        return matching
    }

    /// Return non-stale messages for a session WITHOUT removing them from the queue.
    func loadForSession(sessionId: String) -> [QueuedMessage] {
        lock.lock()
        defer { lock.unlock() }
        var queue = loadQueue()
        purgeStale(&queue)
        return queue.filter { $0.sessionId == sessionId }
    }

    /// Remove the first `count` messages for a session from the queue.
    func removeFirst(sessionId: String, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        var queue = loadQueue()
        var removed = 0
        queue.removeAll { msg in
            guard msg.sessionId == sessionId, removed < count else { return false }
            removed += 1
            return true
        }
        saveQueue(queue)
    }

    /// Clear all messages for a session.
    func clear(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        var queue = loadQueue()
        queue.removeAll { $0.sessionId == sessionId }
        saveQueue(queue)
    }

    // MARK: - Private

    private func loadQueue() -> [QueuedMessage] {
        guard let data = defaults.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder().decode([QueuedMessage].self, from: data)) ?? []
    }

    private func saveQueue(_ queue: [QueuedMessage]) {
        if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: queueKey)
        }
    }

    private func purgeStale(_ queue: inout [QueuedMessage]) {
        let now = Date()
        queue.removeAll { msg in
            let ttl = msg.messageType == "response" ? responseTTL : regularTTL
            return now.timeIntervalSince(msg.timestamp) > ttl
        }
    }
}
