package com.velo.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray

class VeloVpnService : VpnService() {

    companion object {
        const val ACTION_START = "com.velo.app.action.START"
        const val ACTION_STOP = "com.velo.app.action.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_LABEL = "label"

        private const val TAG = "Velo"
        private const val CHANNEL_ID = "velo_tunnel"
        private const val NOTIFICATION_ID = 4711
        private const val PRIVATE_ADDRESS = "10.13.37.1"
        private const val PRIVATE_ADDRESS_V6 = "fdfe:dcba:9876::1"
        private const val MTU = 1500

        @Volatile
        var running: Boolean = false

        fun launch(context: Context, config: String, label: String) {
            val intent = Intent(context, VeloVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG, config)
                putExtra(EXTRA_LABEL, label)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun terminate(context: Context) {
            val intent = Intent(context, VeloVpnService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    private var tunnel: ParcelFileDescriptor? = null
    private var controller: CoreController? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            shutdown()
            return START_NOT_STICKY
        }

        val config = intent?.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrEmpty()) {
            shutdown()
            return START_NOT_STICKY
        }

        val label = intent.getStringExtra(EXTRA_LABEL) ?: "Velo"
        return if (bringUp(config, label)) {
            START_STICKY
        } else {
            shutdown()
            START_NOT_STICKY
        }
    }

    override fun onRevoke() {
        shutdown()
        super.onRevoke()
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }

    private fun bringUp(config: String, label: String): Boolean {
        try {
            CoreBridge.init(applicationContext)
            startForegroundNotice(label)

            val descriptor = establishTunnel() ?: return false
            tunnel = descriptor

            val core = Libv2ray.newCoreController(object : CoreCallbackHandler {
                override fun startup(): Long = 0

                override fun shutdown(): Long {
                    this@VeloVpnService.shutdown()
                    return 0
                }

                override fun onEmitStatus(code: Long, message: String?): Long {
                    if (message != null && message.isNotEmpty()) {
                        Log.i(TAG, message)
                    }
                    return 0
                }
            })
            controller = core
            core.startLoop(config, descriptor.fd)

            if (!core.isRunning) {
                return false
            }

            running = true
            return true
        } catch (error: Throwable) {
            Log.e(TAG, "tunnel failed to start", error)
            return false
        }
    }

    private fun establishTunnel(): ParcelFileDescriptor? {
        val builder = Builder()
            .setMtu(MTU)
            .setSession("Velo")
            .addAddress(PRIVATE_ADDRESS, 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")

        try {
            builder.addAddress(PRIVATE_ADDRESS_V6, 126)
            builder.addRoute("::", 0)
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "ipv6 was not accepted, staying on ipv4")
        }

        try {
            builder.addDisallowedApplication(packageName)
        } catch (error: Exception) {
            Log.w(TAG, "could not exclude the app itself", error)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        return try {
            builder.establish()
        } catch (error: Throwable) {
            Log.e(TAG, "could not establish the interface", error)
            null
        }
    }

    private fun startForegroundNotice(label: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Tunnel",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }

        val open = Intent(this, MainActivity::class.java)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pending = PendingIntent.getActivity(this, 0, open, flags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = builder
            .setContentTitle("Velo is connected")
            .setContentText(label)
            .setSmallIcon(android.R.drawable.stat_sys_vpn_ic)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun shutdown() {
        running = false

        try {
            controller?.stopLoop()
        } catch (error: Throwable) {
            Log.w(TAG, "core did not stop cleanly", error)
        }
        controller = null

        try {
            tunnel?.close()
        } catch (error: Throwable) {
            Log.w(TAG, "interface did not close cleanly", error)
        }
        tunnel = null

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (error: Throwable) {
            Log.w(TAG, "foreground state was already cleared", error)
        }

        stopSelf()
    }
}
