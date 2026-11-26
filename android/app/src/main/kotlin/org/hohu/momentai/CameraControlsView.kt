package org.hohu.momentai

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/** Camera chrome owns no camera or audio resources. All hit targets are at least 48 dp. */
internal class CameraControlsView(context: Context) : LinearLayout(context) {
    val preview = FrameLayout(context).apply {
        clipChildren = true
        clipToPadding = true
    }
    val back = button("←  " + NativeStrings.text(R.string.camera_back_to_recording)).apply {
        contentDescription = NativeStrings.text(R.string.camera_back_to_recording)
    }
    val status = TextView(context).apply {
        setTextColor(Color.WHITE)
        textSize = 13f
        gravity = Gravity.END or Gravity.CENTER_VERTICAL
        setPadding(dp(12), 0, 0, 0)
    }
    val shutter = Button(context).apply {
        contentDescription = NativeStrings.text(R.string.native_take_and_save_a_photo_20)
        background = rounded(Color.WHITE, 40, 4)
        backgroundTintList = null
        isEnabled = false
    }
    val zoomDial = CameraZoomDial(context)
    private val content = LinearLayout(context)
    private val panel = LinearLayout(context).apply {
        orientation = VERTICAL
        gravity = Gravity.CENTER
        setPadding(dp(12), dp(4), dp(12), dp(4))
    }
    private val focusRing = View(context).apply {
        background = rounded(Color.TRANSPARENT, 8, 2, Color.YELLOW)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        visibility = INVISIBLE
    }
    private val hideFocus = Runnable { focusRing.visibility = INVISIBLE }

    init {
        orientation = VERTICAL
        setBackgroundColor(Color.BLACK)
        val header = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(6), dp(12), dp(6))
            addView(back, LayoutParams(LayoutParams.WRAP_CONTENT, dp(52)))
            addView(status, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))
        }
        addView(header, LayoutParams(LayoutParams.MATCH_PARENT, dp(68)))
        addView(content, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        preview.addView(focusRing, FrameLayout.LayoutParams(dp(64), dp(64)))
        panel.addView(zoomDial, LayoutParams(LayoutParams.MATCH_PARENT, dp(84)))
        panel.addView(shutter, LayoutParams(dp(76), dp(76)).apply { gravity = Gravity.CENTER_HORIZONTAL })
        arrange(false)
    }

    fun arrange(landscape: Boolean) {
        content.orientation = if (landscape) HORIZONTAL else VERTICAL
        if (preview.parent == null) content.addView(preview)
        if (panel.parent == null) content.addView(panel)
        preview.layoutParams =
            if (landscape) LayoutParams(0, LayoutParams.MATCH_PARENT, 1f) else LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f)
        panel.layoutParams =
            if (landscape) LayoutParams(dp(284), LayoutParams.MATCH_PARENT) else LayoutParams(LayoutParams.MATCH_PARENT, dp(172))
    }

    fun configureZoom(min: Float, max: Float, select: (Float) -> Unit) {
        zoomDial.configure(min, max)
        zoomDial.onValueChanged = select
    }

    fun updateZoom(value: Float) = zoomDial.updateValue(value)

    fun showFocus(x: Float, y: Float) {
        preview.removeCallbacks(hideFocus)
        focusRing.x = (x - dp(32)).coerceIn(0f, (preview.width - dp(64)).coerceAtLeast(0).toFloat())
        focusRing.y = (y - dp(32)).coerceIn(0f, (preview.height - dp(64)).coerceAtLeast(0).toFloat())
        focusRing.visibility = VISIBLE
        focusRing.bringToFront()
        preview.postDelayed(hideFocus, 1800)
    }

    private fun button(label: String) = Button(context).apply {
        text = label
        isAllCaps = false
        textSize = 15f
        setTextColor(Color.WHITE)
        minWidth = dp(48)
        minHeight = dp(48)
        minimumWidth = dp(48)
        minimumHeight = dp(48)
        setPadding(dp(14), 0, dp(14), 0)
        background = rounded(0xff303030.toInt(), 24)
        backgroundTintList = ColorStateList.valueOf(0xff303030.toInt())
    }

    private fun rounded(color: Int, radius: Int, stroke: Int = 0, strokeColor: Int = Color.LTGRAY) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        setColor(color)
        cornerRadius = dp(radius).toFloat()
        if (stroke > 0) setStroke(dp(stroke), strokeColor)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
