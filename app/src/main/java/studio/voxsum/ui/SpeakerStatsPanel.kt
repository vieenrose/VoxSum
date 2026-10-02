package studio.voxsum.ui

import androidx.compose.foundation.layout.padding

import androidx.compose.runtime.setValue

import androidx.compose.runtime.getValue

import androidx.compose.material.icons.filled.ExpandMore

import androidx.compose.material.icons.filled.ExpandLess

import androidx.compose.material3.Icon

import androidx.compose.foundation.clickable

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import studio.voxsum.R
import studio.voxsum.data.DiarizationStats
import studio.voxsum.data.speakerColorOn
import studio.voxsum.ui.theme.LocalVoxSumPalette

/**
 * Who talked how much: the speaker count, one stacked bar of talk-time shares in the speakers'
 * colours (the same colours as the transcript chips and the player's timeline), and a legend.
 * [label] names a speaker (user-set name, or "Speaker n").
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SpeakerStatsPanel(
    stats: DiarizationStats,
    modifier: Modifier = Modifier,
    label: @Composable (Int) -> String = { stringResource(R.string.speaker_n, it + 1) },
) {
    val pal = LocalVoxSumPalette.current
    if (stats.perSpeaker.isEmpty()) return
    val shares = stats.perSpeaker.sortedByDescending { it.percentage }
    // Compact by default: ONE line — the count beside the share bar. The per-speaker legend is a
    // tap away (it took three or four lines under every summary for something glanced at once).
    var showLegend by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    Column(
        modifier.fillMaxWidth().clickable { showLegend = !showLegend },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                pluralStringResource(R.plurals.speaker_count, stats.totalSpeakers, stats.totalSpeakers),
                style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = pal.Slate400,
            )
            Spacer(Modifier.width(12.dp))
            Row(Modifier.weight(1f).height(8.dp).clip(CircleShape).background(pal.Slate700)) {
                shares.forEach { s ->
                    val w = (s.percentage / 100.0).toFloat()
                    if (w > 0f) Box(
                        Modifier.weight(w).fillMaxHeight()
                            .background(Color(speakerColorOn(s.speaker, pal.isDark))),
                    )
                }
            }
            Icon(
                if (showLegend) androidx.compose.material.icons.Icons.Filled.ExpandLess else androidx.compose.material.icons.Icons.Filled.ExpandMore,
                contentDescription = null, tint = pal.Slate400, modifier = Modifier.padding(start = 6.dp).size(18.dp),
            )
        }
        if (showLegend) FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            shares.forEach { s ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(8.dp).clip(RoundedCornerShape(2.dp)).background(Color(speakerColorOn(s.speaker, pal.isDark))))
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "${label(s.speaker)} · %.0f%%".format(s.percentage),
                        style = MaterialTheme.typography.labelMedium, color = pal.Slate400,
                    )
                }
            }
        }
    }
}
