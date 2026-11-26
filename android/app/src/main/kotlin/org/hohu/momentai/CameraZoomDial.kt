package org.hohu.momentai

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.pow

/** The complete device range stays visible and is reachable in a single drag. */
internal class CameraZoomDial(context: Context) : View(context) {
    private var scale = CameraZoomScale(1f, 1f)
    private var value = 1f
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    var onValueChanged: ((Float) -> Unit)? = null

    init {
        isClickable = true
        isFocusable = true
        contentDescription = NativeStrings.text(R.string.camera_zoom)
    }

    fun configure(minimum: Float, maximum: Float) {
        scale = CameraZoomScale(minimum, maximum)
        isEnabled = maximum > minimum
        updateValue(value)
    }

    fun updateValue(factor: Float) {
        value = factor.coerceIn(scale.minimum, scale.maximum)
        contentDescription = NativeStrings.text(R.string.camera_zoom) + " " + label(value)
        invalidate()
    }

    private val trackStart: Float get() = dp(28f).coerceAtMost(width / 2f)
    private val trackWidth: Float get() = (width - 2 * trackStart).coerceAtLeast(1f)

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        paint.color = if (isEnabled) Color.WHITE else Color.GRAY
        paint.textSize = dp(19f)
        paint.isFakeBoldText = true
        canvas.drawText(label(value), width / 2f, dp(21f), paint)
        paint.isFakeBoldText = false
        paint.strokeWidth = dp(1f)
        val count = (trackWidth / dp(12f)).toInt().coerceAtLeast(1)
        paint.color = Color.DKGRAY
        for (tick in 0..count) {
            val x = trackStart + tick.toFloat() / count * trackWidth
            canvas.drawLine(x, dp(38f), x, dp(50f), paint)
        }
        var lastLabelX = trackStart
        val first = ceil(ln(scale.minimum) / ln(2f)).toInt()
        val last = floor(ln(scale.maximum) / ln(2f)).toInt()
        for (exponent in first..last) {
            val factor = 2f.pow(exponent)
            val x = trackStart + scale.fraction(factor) * trackWidth
            if (x - lastLabelX >= dp(48f) && trackStart + trackWidth - x >= dp(48f)) {
                paint.color = Color.LTGRAY
                canvas.drawLine(x, dp(34f), x, dp(56f), paint)
                drawLabel(canvas, label(factor), x)
                lastLabelX = x
            }
        }
        for (endpoint in listOf(scale.minimum, scale.maximum).distinct()) {
            val x = trackStart + scale.fraction(endpoint) * trackWidth
            paint.color = Color.LTGRAY
            canvas.drawLine(x, dp(34f), x, dp(56f), paint)
            drawLabel(canvas, label(endpoint), x)
        }
        val pointer = trackStart + scale.fraction(value) * trackWidth
        paint.color = Color.WHITE
        canvas.drawRoundRect(pointer - dp(5f), dp(29f), pointer + dp(5f), dp(60f), dp(5f), dp(5f), paint)
    }

    private fun selectZoom(x: Float) {
        updateValue(scale.factorAtFraction((x - trackStart) / trackWidth))
        onValueChanged?.invoke(value)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                selectZoom(event.x)
                parent?.requestDisallowInterceptTouchEvent(true)
            }
            MotionEvent.ACTION_MOVE -> {
                selectZoom(event.x)
            }
            MotionEvent.ACTION_UP -> {
                parent?.requestDisallowInterceptTouchEvent(false)
                performClick()
            }
            MotionEvent.ACTION_CANCEL -> parent?.requestDisallowInterceptTouchEvent(false)
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = android.widget.SeekBar::class.java.name
        info.rangeInfo =
            AccessibilityNodeInfo.RangeInfo.obtain(AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT, scale.minimum, scale.maximum, value)
        if (isEnabled) {
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS)
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD)
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD)
        }
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
        if (isEnabled) {
            when (action) {
                AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> changePosition(scale.position(value) + 0.125f)
                AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> changePosition(scale.position(value) - 0.125f)
                AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id -> {
                    val requested = arguments?.getFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE) ?: return false
                    if (!requested.isFinite()) return false
                    changePosition(scale.position(requested))
                }
                else -> return super.performAccessibilityAction(action, arguments)
            }
            return true
        }
        return super.performAccessibilityAction(action, arguments)
    }

    private fun changePosition(position: Float) {
        updateValue(scale.factor(position))
        onValueChanged?.invoke(value)
    }

    private fun drawLabel(canvas: Canvas, text: String, x: Float) {
        paint.textSize = dp(12f)
        paint.color = Color.LTGRAY
        canvas.drawText(text, x, dp(77f), paint)
    }

    private fun label(factor: Float) = if (abs(factor - factor.toInt()) <
        0.01f
    ) {
        "${factor.toInt()}×"
    } else {
        String.format(Locale.ROOT, "%.1f×", factor)
    }
    private fun dp(value: Float) = value * resources.displayMetrics.density
}
