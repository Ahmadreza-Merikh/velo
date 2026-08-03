package com.velo.app

import android.content.Context
import go.Seq
import libv2ray.Libv2ray
import java.io.File

object CoreBridge {
    private var ready = false

    @Synchronized
    fun init(context: Context) {
        if (ready) {
            return
        }
        Seq.setContext(context.applicationContext)
        val assets = File(context.filesDir, "assets")
        if (!assets.exists()) {
            assets.mkdirs()
        }
        Libv2ray.initCoreEnv(assets.absolutePath, "")
        ready = true
    }

    fun version(): String {
        return try {
            Libv2ray.checkVersionX()
        } catch (error: Throwable) {
            ""
        }
    }

    fun measure(config: String, url: String): Long {
        return try {
            Libv2ray.measureOutboundDelay(config, url)
        } catch (error: Throwable) {
            -1L
        }
    }
}
