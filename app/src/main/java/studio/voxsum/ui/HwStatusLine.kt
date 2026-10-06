package studio.voxsum.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.voxsum.R
import studio.voxsum.core.hw.hwSamples
import studio.voxsum.ui.theme.LocalVoxSumPalette
import studio.voxsum.ui.theme.VoxSumPalette

/**
 * Hardware status as a row of hairline gauges — `CPU ▬▬▭ RAM ▬▭▭ ⚡ ▬▬▬` — while the engines work.
 * Bars, not numbers: the glance question is "is it maxed out?", not the exact percent. Sampling
 * runs only while this is on screen; a gauge turns red only when it is worth acting on (CPU or RAM
 * over 90 %, battery under 15 % off the charger, or a battery at 42 °C or more).
 */
@Composable
fun HwStatusLine(modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    if (!remember { studio.voxsum.core.config.ThemeStore.loadHwMonitor(ctx) }) return
    val s = remember { hwSamples(ctx) }.collectAsState(initial = null).value ?: return
    val hot = (s.tempC ?: 0) >= 42
    val cd = stringResource(R.string.hw_status_cd, s.cpuPct, s.ramPct, s.batteryPct)
    Row(
        modifier.clearAndSetSemantics { contentDescription = cd },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Gauge("CPU", s.cpuPct, s.cpuPct > 90)
        s.gpuPct?.let { Gauge("GPU", it, it > 90) }
        if (s.npuActive) Gauge("NPU", 100, false)
        Gauge("RAM", s.ramPct, s.ramPct > 90)
        if (s.batteryPct >= 0) Gauge(if (s.charging) "BAT\u2009+" else "BAT", s.batteryPct,
            hot || (!s.charging && s.batteryPct < 15))
    }
}

@Composable
private fun Gauge(label: String, pct: Int, alert: Boolean) {
    val pal = LocalVoxSumPalette.current
    val fill = when {
        alert -> VoxSumPalette.Red
        pal.isEink -> pal.Slate200
        // Grey, not the accent: the blue mic bars right above are the recording's own indicator.
        else -> pal.Slate400
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(label, style = MaterialTheme.typography.labelSmall, fontSize = 9.sp,
            color = pal.Slate400.copy(alpha = 0.7f))
        Box(Modifier.size(width = 16.dp, height = 2.dp).clip(RoundedCornerShape(1.dp))
            .background(pal.Slate400.copy(alpha = 0.2f))) {
            Box(Modifier.fillMaxHeight().fillMaxWidth(pct.coerceIn(0, 100) / 100f).background(fill))
        }
    }
}
