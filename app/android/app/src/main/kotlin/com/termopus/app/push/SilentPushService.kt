package com.termopus.app.push

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.termopus.app.MainActivity
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Handles incoming FCM data-only (silent) push messages.
 *
 * The relay server sends a data-only push with `{ type: "wake", sessionId: "..." }`
 * when the computer needs phone approval but the phone's WebSocket is disconnected.
 *
 * This service:
 *  1. Receives the silent push (no notification payload — nothing visible from Google).
 *  2. Attempts to reconnect the WebSocket to fetch encrypted content.
 *  3. Creates a **local** notification on-device with the real content.
 *
 * Because the push is data-only, Google/Apple never see any notification text,
 * titles, or content. The user-visible notification is generated entirely on-device
 * after the E2E-encrypted content is fetched and decrypted locally.
 */
class SilentPushService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "SilentPushService"
        private const val CHANNEL_ID = "claude_code_actions"
        private const val CHANNEL_NAME = "Claude Code Actions"
        private const val NOTIFICATION_ID = 1001
        private const val PREFS_NAME = "app.clauderemote.security"
        private const val PEER_KEYS_PREFS_NAME = "termopus_peer_keys"
        private const val KEY_PENDING_FCM_TOKEN = "pending_fcm_token"

        /**
         * Creates EncryptedSharedPreferences using the same prefs name and
         * MasterKey scheme as [SecurityChannel.getSecurePrefs].
         *
         * Returns null if creation fails (e.g. KeyStore unavailable).
         */
        fun getSecurePrefs(context: Context): SharedPreferences? {
            return try {
                val masterKey = MasterKey.Builder(context)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
                EncryptedSharedPreferences.create(
                    context,
                    PEER_KEYS_PREFS_NAME,
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                )
            } catch (e: Exception) {
                Log.e(TAG, "Failed to create EncryptedSharedPreferences", e)
                null
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    /**
     * Called when a data-only push is received.
     *
     * Because there is no `notification` payload, this is called even when
     * the app is in the foreground or background — Android does not auto-
     * display anything.
     */
    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        val data = remoteMessage.data
        Log.d(TAG, "Silent push received: type=${data["type"]}, sessionId=${data["sessionId"]}")

        val type = data["type"]
        val sessionId = data["sessionId"]

        if (type != "wake" || sessionId.isNullOrEmpty()) {
            Log.w(TAG, "Ignoring push with unexpected type or missing sessionId")
            return
        }

        // Show a local notification to bring the user back to the app.
        // The actual encrypted content will be fetched when they open the app
        // and the WebSocket reconnects. If the session's WS is already
        // connected, the notification is harmless — tapping it just opens the app.
        showLocalNotification(sessionId)
    }

    /**
     * Called when the FCM token is refreshed.
     *
     * Persists the new token so it can be sent to the relay when the
     * WebSocket next connects.
     */
    override fun onNewToken(token: String) {
        Log.d(TAG, "FCM token refreshed")

        // Persist for later registration — SecurityChannel will send it
        // to the relay when the next WebSocket connection is established.
        // Use encrypted storage; fall back to plain prefs if unavailable
        // (SecurityChannel migration will move it to encrypted on next connect).
        val securePrefs = getSecurePrefs(this)
        if (securePrefs != null) {
            securePrefs.edit()
                .putString(KEY_PENDING_FCM_TOKEN, token)
                .apply()
        } else {
            Log.w(TAG, "EncryptedSharedPreferences unavailable, falling back to plain prefs")
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_PENDING_FCM_TOKEN, token)
                .apply()
        }
    }

    /**
     * Create a local notification that opens the app.
     *
     * This notification is generated entirely on-device — its content
     * never passes through Google's servers.
     */
    private fun showLocalNotification(sessionId: String) {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("sessionId", sessionId)
            putExtra("fromPush", true)
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Claude Code")
            .setContentText("Action required — tap to respond")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, notification)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Notifications when Claude Code needs your approval"
            }

            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }
}
