package com.termopus.app.network

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Persistent message queue for offline sends.
 * Messages are stored in EncryptedSharedPreferences as JSON and replayed on reconnect.
 */
object MessageQueue {
    private const val TAG = "MessageQueue"
    private const val PREFS_NAME = "termopus_message_queue"
    private const val QUEUE_KEY = "queue"
    private const val MAX_MESSAGES = 50
    private const val RESPONSE_TTL_MS = 30_000L   // 30s for responses
    private const val REGULAR_TTL_MS = 60_000L    // 60s for regular messages

    class QueuedMessage(
        val id: String,
        val sessionId: String,
        val data: ByteArray,       // The plaintext JSON message bytes (encrypted at send time by SecureWebSocket)
        val messageType: String,   // "response", "message", "key", "input", "command", etc.
        val timestamp: Long        // System.currentTimeMillis()
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is QueuedMessage) return false
            return id == other.id
        }

        override fun hashCode(): Int = id.hashCode()

        fun isExpired(): Boolean {
            val ttl = if (messageType == "response") RESPONSE_TTL_MS else REGULAR_TTL_MS
            return System.currentTimeMillis() - timestamp > ttl
        }
    }

    private var prefs: SharedPreferences? = null

    fun init(context: Context) {
        prefs = try {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                context,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create EncryptedSharedPreferences, falling back to plain", e)
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        }
    }

    @Synchronized
    fun enqueue(sessionId: String, data: ByteArray, messageType: String) {
        val queue = loadQueue().toMutableList()
        purgeStale(queue)

        queue.add(QueuedMessage(
            id = UUID.randomUUID().toString(),
            sessionId = sessionId,
            data = data,
            messageType = messageType,
            timestamp = System.currentTimeMillis()
        ))

        // Enforce max size — drop oldest non-response first
        while (queue.size > MAX_MESSAGES) {
            val idx = queue.indexOfFirst { it.messageType != "response" }
            if (idx >= 0) queue.removeAt(idx) else queue.removeAt(0)
        }

        saveQueue(queue)
        Log.d(TAG, "Enqueued $messageType for session ${sessionId.take(12)} (queue: ${queue.size})")
    }

    @Synchronized
    fun drain(sessionId: String): List<QueuedMessage> {
        val queue = loadQueue().toMutableList()
        purgeStale(queue)

        val matching = queue.filter { it.sessionId == sessionId }
        queue.removeAll { it.sessionId == sessionId }
        saveQueue(queue)

        Log.d(TAG, "Drained ${matching.size} messages for session ${sessionId.take(12)}")
        return matching
    }

    @Synchronized
    fun clear(sessionId: String) {
        val queue = loadQueue().toMutableList()
        queue.removeAll { it.sessionId == sessionId }
        saveQueue(queue)
    }

    @Synchronized
    fun loadForSession(sessionId: String): List<QueuedMessage> {
        val queue = loadQueue()
        return queue.filter { it.sessionId == sessionId && !it.isExpired() }
    }

    @Synchronized
    fun removeFirst(sessionId: String, count: Int) {
        val queue = loadQueue().toMutableList()
        var removed = 0
        val iter = queue.iterator()
        while (iter.hasNext() && removed < count) {
            if (iter.next().sessionId == sessionId) {
                iter.remove()
                removed++
            }
        }
        saveQueue(queue)
    }

    // --- Private ---

    private fun loadQueue(): List<QueuedMessage> {
        val json = prefs?.getString(QUEUE_KEY, null) ?: return emptyList()
        return try {
            val arr = JSONArray(json)
            (0 until arr.length()).map { i ->
                val obj = arr.getJSONObject(i)
                QueuedMessage(
                    id = obj.getString("id"),
                    sessionId = obj.getString("sessionId"),
                    data = android.util.Base64.decode(obj.getString("data"), android.util.Base64.NO_WRAP),
                    messageType = obj.getString("messageType"),
                    timestamp = obj.getLong("timestamp")
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load queue", e)
            emptyList()
        }
    }

    private fun saveQueue(queue: List<QueuedMessage>) {
        val arr = JSONArray()
        for (msg in queue) {
            arr.put(JSONObject().apply {
                put("id", msg.id)
                put("sessionId", msg.sessionId)
                put("data", android.util.Base64.encodeToString(msg.data, android.util.Base64.NO_WRAP))
                put("messageType", msg.messageType)
                put("timestamp", msg.timestamp)
            })
        }
        prefs?.edit()?.putString(QUEUE_KEY, arr.toString())?.apply()
    }

    private fun purgeStale(queue: MutableList<QueuedMessage>) {
        val now = System.currentTimeMillis()
        queue.removeAll { msg ->
            val ttl = if (msg.messageType == "response") RESPONSE_TTL_MS else REGULAR_TTL_MS
            now - msg.timestamp > ttl
        }
    }
}
