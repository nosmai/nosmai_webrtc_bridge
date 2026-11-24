package com.nosmai.webrtc_bridge

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** Nosmai <-> flutter_webrtc bridge. Never captures; only exposes Nosmai's processed output as a track. */
class NosmaiWebRtcBridgePlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "nosmai_webrtc_bridge")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "registerShareContext" -> {
                val h = NosmaiTexturePump.registerShareContext()
                if (h == null) result.error("SHARE_CTX", "see logcat NosmaiTexturePump", null) else result.success(h)
            }
            "startStreaming" -> {
                val id = NosmaiTexturePump.startStreaming(
                    appContext,
                    call.argument<Int>("width") ?: 0,
                    call.argument<Int>("height") ?: 0,
                    call.argument<Int>("fps") ?: 0,
                )
                if (id == null) result.error("START_FAILED", "see logcat NosmaiTexturePump", null)
                else result.success(mapOf("trackId" to id, "label" to "nosmai"))
            }
            "stopStreaming" -> { NosmaiTexturePump.stopStreaming(); result.success(null) }
            "isStreaming" -> result.success(NosmaiTexturePump.streaming)
            "setRotation" -> { NosmaiTexturePump.rotationDegrees = call.argument<Int>("degrees") ?: 0; result.success(null) }
            "setMirror" -> { NosmaiTexturePump.mirrorX = call.argument<Boolean>("mirror") ?: false; result.success(null) }
            "getCounters" -> result.success(NosmaiTexturePump.counters())
            "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        NosmaiTexturePump.stopStreaming()
    }
}
