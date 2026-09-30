package studio.voxsum.ui

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
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            pluralStringResource(R.plurals.speaker_count, stats.totalSpeakers, stats.totalSpeakers),
            style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = pal.Slate400,
        )
        Row(Modifier.fillMaxWidth().height(8.dp).clip(CircleShape).background(pal.Slate700)) {
            shares.forEach { s ->
                val w = (s.percentage / 100.0).toFloat()
                if (w > 0f) Box(
                    Modifier.weight(w).fillMaxHeight()
                        .background(Color(speakerColorOn(s.speaker, pal.isDark))),
                )
            }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
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
