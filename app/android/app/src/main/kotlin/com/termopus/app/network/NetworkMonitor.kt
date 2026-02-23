package com.termopus.app.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Monitors network reachability and transport type changes.
 * Reports changes via callback, debounced to fire only when state actually changes.
 */
object NetworkMonitor {
    private const val TAG = "NetworkMonitor"

    enum class Transport {
        WIFI, CELLULAR, WIRED, NONE;

        override fun toString(): String = name.lowercase()
    }

    data class State(val isReachable: Boolean, val transport: Transport)

    private val mainHandler = Handler(Looper.getMainLooper())
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile
    private var lastState: State? = null
    private var isRunning = false

    /** Called on main thread when network state changes. */
    var onStateChange: ((State) -> Unit)? = null

    fun start(context: Context) {
        if (isRunning) return
        isRunning = true

        connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val cm = connectivityManager ?: return

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                updateState(cm)
            }

            override fun onLost(network: Network) {
                updateState(cm)
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                updateState(cm)
            }
        }

        networkCallback = callback
        cm.registerNetworkCallback(request, callback)

        // Report initial state
        updateState(cm)
    }

    fun stop() {
        if (!isRunning) return
        isRunning = false
        networkCallback?.let { connectivityManager?.unregisterNetworkCallback(it) }
        networkCallback = null
        connectivityManager = null
    }

    val currentState: State
        get() = lastState ?: State(isReachable = false, transport = Transport.NONE)

    @Synchronized
    private fun updateState(cm: ConnectivityManager) {
        val activeNetwork = cm.activeNetwork
        val caps = activeNetwork?.let { cm.getNetworkCapabilities(it) }

        val transport = when {
            caps == null -> Transport.NONE
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Transport.WIFI
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Transport.CELLULAR
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Transport.WIRED
            else -> Transport.NONE
        }

        val isReachable = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
            && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        val newState = State(isReachable = isReachable, transport = transport)

        if (newState != lastState) {
            lastState = newState
            Log.d(TAG, "Network state changed: reachable=$isReachable transport=$transport")
            mainHandler.post { onStateChange?.invoke(newState) }
        }
    }
}
