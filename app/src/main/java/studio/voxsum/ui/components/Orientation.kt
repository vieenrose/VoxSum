package studio.voxsum.ui.components

import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalView

/**
 * True when the window is wider than tall. Read from the view's real size: LocalConfiguration is
 * wrapped for the in-app language switch and must not be the source of truth for layout.
 */
@Composable
fun rememberIsLandscape(): Boolean {
    val view = LocalView.current
    var landscape by remember(view) { mutableStateOf(view.width > view.height) }
    DisposableEffect(view) {
        val listener = View.OnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
            val l = v.width > v.height
            if (l != landscape) landscape = l
        }
        view.addOnLayoutChangeListener(listener)
        landscape = view.width > view.height
        onDispose { view.removeOnLayoutChangeListener(listener) }
    }
    return landscape
}
