package com.velo.app

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "velo/engine"
        private const val VPN_REQUEST = 8801
    }

    private var pendingPermission: MethodChannel.Result? = null
    private val workers: ExecutorService = Executors.newFixedThreadPool(16)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> dispatch(call, result) }
    }

    override fun onDestroy() {
        workers.shutdownNow()
        super.onDestroy()
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareCore" -> {
                CoreBridge.init(applicationContext)
                result.success(null)
            }

            "coreVersion" -> result.success(CoreBridge.version())

            "isActive" -> result.success(VeloVpnService.running)

            "requestVpnPermission" -> requestVpnPermission(result)

            "measure" -> measure(call, result)

            "start" -> start(call, result)

            "stop" -> {
                VeloVpnService.terminate(applicationContext)
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun measure(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config")
        val url = call.argument<String>("url")
        if (config == null || url == null) {
            result.error("arguments", "config and url are required", null)
            return
        }

        workers.execute {
            val delay = CoreBridge.measure(config, url)
            runOnUiThread { result.success(delay.toInt()) }
        }
    }

    private fun requestVpnPermission(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        startActivityForResult(intent, VPN_REQUEST)
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config")
        if (config.isNullOrEmpty()) {
            result.error("arguments", "config is required", null)
            return
        }
        val label = call.argument<String>("label") ?: "Velo"

        if (VpnService.prepare(this) != null) {
            result.error("permission", "vpn permission is missing", null)
            return
        }

        VeloVpnService.launch(applicationContext, config, label)

        workers.execute {
            var attempts = 0
            while (attempts < 60 && !VeloVpnService.running) {
                Thread.sleep(100)
                attempts += 1
            }
            val running = VeloVpnService.running
            runOnUiThread { result.success(running) }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_REQUEST) {
            val waiting = pendingPermission
            pendingPermission = null
            waiting?.success(resultCode == Activity.RESULT_OK)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
