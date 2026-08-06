package com.interactpak.interact_talk

import android.content.Context
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `interact/virtual_bg` — attaches [VirtualBgFrameProcessor] to
 * the LiveKit camera track via FlutterWebRTCPlugin.getLocalTrack.
 */
class VirtualBgPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private var processor: VirtualBgFrameProcessor? = null
    private var attachedTrack: LocalVideoTrack? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "interact/virtual_bg")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        detachInternal()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "attach" -> {
                val trackId = call.argument<String>("trackId")
                val mode = call.argument<String>("mode") ?: "none"
                val asset = call.argument<String>("asset")
                if (trackId.isNullOrBlank()) {
                    result.error("bad_args", "trackId required", null)
                    return
                }
                result.success(attachInternal(trackId, mode, asset))
            }
            "update" -> {
                val mode = call.argument<String>("mode") ?: "none"
                val asset = call.argument<String>("asset")
                val p = processor
                if (p == null) {
                    result.success(false)
                    return
                }
                p.mode = mode
                p.setBackgroundAsset(asset)
                result.success(true)
            }
            "detach" -> {
                detachInternal()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun attachInternal(trackId: String, mode: String, asset: String?): Boolean {
        detachInternal()
        val plugin = FlutterWebRTCPlugin.sharedSingleton ?: return false
        val local = plugin.getLocalTrack(trackId) as? LocalVideoTrack ?: return false
        val p = VirtualBgFrameProcessor(appContext)
        p.mode = mode
        p.setBackgroundAsset(asset)
        local.addProcessor(p)
        processor = p
        attachedTrack = local
        return true
    }

    private fun detachInternal() {
        val p = processor
        val track = attachedTrack
        if (p != null && track != null) {
            try {
                track.removeProcessor(p)
            } catch (_: Exception) {
                /* ignore */
            }
        }
        p?.close()
        processor = null
        attachedTrack = null
    }
}
