package com.interactpak.interact_talk

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.Segmenter
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import io.flutter.FlutterInjector
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

/**
 * In-pipeline compositor for LiveKit/WebRTC camera frames.
 *
 * ML Kit selfie segmentation runs async (latest mask reused). Compositing is
 * sync on the capturer thread so ExternalVideoFrameProcessing stays compliant.
 */
class VirtualBgFrameProcessor(
    private val context: Context,
) : LocalVideoTrack.ExternalVideoFrameProcessing {

    @Volatile
    var mode: String = "none"

    @Volatile
    private var bgBitmap: Bitmap? = null

    private val segmenter: Segmenter = Segmentation.getClient(
        SelfieSegmenterOptions.Builder()
            .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE)
            .enableRawSizeMask()
            .build(),
    )

    private val segmentBusy = AtomicBoolean(false)
    private var frameCounter = 0

    @Volatile
    private var maskBytes: ByteArray? = null

    @Volatile
    private var maskW = 0

    @Volatile
    private var maskH = 0

    fun setBackgroundAsset(asset: String?) {
        if (asset.isNullOrBlank()) {
            bgBitmap = null
            return
        }
        try {
            val key = FlutterInjector.instance().flutterLoader()
                .getLookupKeyForAsset(asset)
            context.assets.open(key).use { stream ->
                bgBitmap = BitmapFactory.decodeStream(stream)
            }
        } catch (_: IOException) {
            bgBitmap = null
        }
    }

    fun close() {
        mode = "none"
        maskBytes = null
        bgBitmap = null
        try {
            segmenter.close()
        } catch (_: Exception) {
            /* ignore */
        }
    }

    override fun onFrame(frame: VideoFrame): VideoFrame {
        if (mode == "none") return frame

        frameCounter++
        if (frameCounter % 2 == 0) {
            maybeSegment(frame)
        }

        val mask = maskBytes
        if (mask == null || maskW <= 0 || maskH <= 0) {
            return frame
        }

        return try {
            composite(frame, mask, maskW, maskH) ?: frame
        } catch (_: Exception) {
            frame
        }
    }

    private fun maybeSegment(frame: VideoFrame) {
        if (!segmentBusy.compareAndSet(false, true)) return
        val i420 = frame.buffer.toI420() ?: run {
            segmentBusy.set(false)
            return
        }
        try {
            val w = i420.width
            val h = i420.height
            val argb = i420ToArgb(i420, w, h)
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            bmp.setPixels(argb, 0, w, 0, 0, w, h)
            val image = InputImage.fromBitmap(bmp, 0)
            segmenter.process(image)
                .addOnSuccessListener { segmentationMask ->
                    try {
                        val mw = segmentationMask.width
                        val mh = segmentationMask.height
                        val buf = segmentationMask.buffer
                        buf.rewind()
                        val floats = FloatArray(mw * mh)
                        buf.asFloatBuffer().get(floats)
                        // Store 0..255 alpha where person is opaque.
                        val bytes = ByteArray(mw * mh)
                        for (i in floats.indices) {
                            bytes[i] = (floats[i].coerceIn(0f, 1f) * 255f).toInt().toByte()
                        }
                        maskBytes = bytes
                        maskW = mw
                        maskH = mh
                    } finally {
                        bmp.recycle()
                        segmentBusy.set(false)
                    }
                }
                .addOnFailureListener {
                    bmp.recycle()
                    segmentBusy.set(false)
                }
        } catch (_: Exception) {
            segmentBusy.set(false)
        } finally {
            i420.release()
        }
    }

    private fun composite(
        frame: VideoFrame,
        mask: ByteArray,
        mw: Int,
        mh: Int,
    ): VideoFrame? {
        val i420 = frame.buffer.toI420() ?: return null
        val w = i420.width
        val h = i420.height
        val argb = i420ToArgb(i420, w, h)
        i420.release()

        val out = IntArray(w * h)
        val bg = bgBitmap
        val scaledBg: Bitmap? = if (mode == "image" && bg != null) {
            Bitmap.createScaledBitmap(bg, w, h, true)
        } else {
            null
        }

        // Soft blur plate: tiny downscale of the camera frame.
        val blurPlate: IntArray? = if (mode == "blur") {
            makeBlurPlate(argb, w, h)
        } else {
            null
        }

        for (y in 0 until h) {
            val my = (y * mh) / h
            for (x in 0 until w) {
                val mx = (x * mw) / w
                val person = (mask[my * mw + mx].toInt() and 0xff) / 255f
                val idx = y * w + x
                if (person >= 0.85f) {
                    out[idx] = argb[idx]
                } else {
                    val bgPx = when {
                        scaledBg != null -> scaledBg.getPixel(x, y)
                        blurPlate != null -> blurPlate[idx]
                        else -> Color.rgb(32, 36, 48)
                    }
                    if (person <= 0.15f) {
                        out[idx] = bgPx
                    } else {
                        out[idx] = lerpColor(bgPx, argb[idx], person)
                    }
                }
            }
        }
        scaledBg?.recycle()

        val newBuf = argbToI420(out, w, h)
        val outFrame = VideoFrame(newBuf, frame.rotation, frame.timestampNs)
        frame.release()
        return outFrame
    }

    private fun makeBlurPlate(argb: IntArray, w: Int, h: Int): IntArray {
        val sw = max(8, w / 16)
        val sh = max(8, h / 16)
        val small = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        small.setPixels(argb, 0, w, 0, 0, w, h)
        val tiny = Bitmap.createScaledBitmap(small, sw, sh, true)
        val soft = Bitmap.createScaledBitmap(tiny, w, h, true)
        val plate = IntArray(w * h)
        soft.getPixels(plate, 0, w, 0, 0, w, h)
        small.recycle()
        tiny.recycle()
        soft.recycle()
        return plate
    }

    private fun lerpColor(a: Int, b: Int, t: Float): Int {
        val u = 1f - t
        val ar = Color.red(a)
        val ag = Color.green(a)
        val ab = Color.blue(a)
        val br = Color.red(b)
        val bg = Color.green(b)
        val bb = Color.blue(b)
        return Color.rgb(
            (ar * u + br * t).toInt().coerceIn(0, 255),
            (ag * u + bg * t).toInt().coerceIn(0, 255),
            (ab * u + bb * t).toInt().coerceIn(0, 255),
        )
    }

    companion object {
        fun i420ToArgb(i420: VideoFrame.I420Buffer, w: Int, h: Int): IntArray {
            val y = i420.dataY
            val u = i420.dataU
            val v = i420.dataV
            val yStride = i420.strideY
            val uStride = i420.strideU
            val vStride = i420.strideV
            val out = IntArray(w * h)
            for (j in 0 until h) {
                for (i in 0 until w) {
                    val yy = (y.get(j * yStride + i).toInt() and 0xff)
                    val uu = (u.get((j / 2) * uStride + (i / 2)).toInt() and 0xff) - 128
                    val vv = (v.get((j / 2) * vStride + (i / 2)).toInt() and 0xff) - 128
                    var r = (yy + 1.370705f * vv).toInt()
                    var g = (yy - 0.337633f * uu - 0.698001f * vv).toInt()
                    var b = (yy + 1.732446f * uu).toInt()
                    r = min(255, max(0, r))
                    g = min(255, max(0, g))
                    b = min(255, max(0, b))
                    out[j * w + i] = Color.argb(255, r, g, b)
                }
            }
            return out
        }

        fun argbToI420(argb: IntArray, w: Int, h: Int): JavaI420Buffer {
            val buf = JavaI420Buffer.allocate(w, h)
            val y = buf.dataY
            val u = buf.dataU
            val v = buf.dataV
            val yStride = buf.strideY
            val uStride = buf.strideU
            val vStride = buf.strideV
            for (j in 0 until h) {
                for (i in 0 until w) {
                    val c = argb[j * w + i]
                    val r = Color.red(c)
                    val g = Color.green(c)
                    val b = Color.blue(c)
                    val yy = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                    y.put(j * yStride + i, yy.coerceIn(0, 255).toByte())
                    if (j % 2 == 0 && i % 2 == 0) {
                        val uu = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                        val vv = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                        u.put((j / 2) * uStride + (i / 2), uu.coerceIn(0, 255).toByte())
                        v.put((j / 2) * vStride + (i / 2), vv.coerceIn(0, 255).toByte())
                    }
                }
            }
            return buf
        }
    }
}
