package studio.voxsum.ui

import androidx.compose.animation.core.animateFloat

import androidx.compose.ui.draw.alpha

import androidx.compose.foundation.shape.CircleShape

import androidx.compose.foundation.layout.IntrinsicSize

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.voxsum.R
import studio.voxsum.data.speakerColorOn
import studio.voxsum.data.speakerLabel
import studio.voxsum.core.events.TranscriptEvent
import studio.voxsum.ui.theme.LocalVoxSumPalette
import studio.voxsum.ui.theme.VoxSumPalette

/**
 * Full-screen capture — the studio's recording booth. Fixed layout with two GIANT buttons
 * (⏭ Next talk / ⏹ Stop & save) sized for a conference table and an e-ink screen: nothing
 * shifts position with state, unlike the old top-bar icon strip. A collapsible live-transcript
 * panel fills the space between the name field and the buttons, auto-following the newest line;
 * back leaves the recording running (Studio shows a live banner to return here).
 */
@Composable
fun CaptureScreen(
    isRecording: Boolean,
    recSeconds: Int,
    micLevel: Float,
    utterances: List<TranscriptEvent.Utterance>,
    /** Leading [utterances] that are settled; the rest are provisional (speaker may still change). */
    stable: Int = 0,
    /** The meeting-reading agent, when it runs live alongside the recording. */
    agent: AgentUiState? = null,
    /** Shown under the waiting state, e.g. a first-run model download (the mic records meanwhile). */
    notice: String? = null,
    onNextTalk: () -> Unit,
    onStop: () -> Unit,
    onBack: () -> Unit,
) {
    val pal = LocalVoxSumPalette.current
    // A meeting is watched, not touched: keep the screen on while recording.
    val keepOnView = androidx.compose.ui.platform.LocalView.current
    androidx.compose.runtime.DisposableEffect(isRecording) {
        keepOnView.keepScreenOn = isRecording
        onDispose { keepOnView.keepScreenOn = false }
    }
    val conf = LocalConfiguration.current
    val landscape = studio.voxsum.ui.components.rememberIsLandscape()
    Column(
        Modifier
            .fillMaxSize()
            .background(pal.Slate900Grad)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(horizontal = 16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp)) {
            IconButton(onClick = onBack) {
                Icon(Icons.Filled.ArrowBack, contentDescription = stringResource(R.string.back), tint = pal.Slate200)
            }
            if (isRecording) {
                RecDot()
                Spacer(Modifier.width(8.dp))
            }
            Text(
                stringResource(if (isRecording) R.string.status_recording else R.string.capture_title),
                style = MaterialTheme.typography.titleMedium,
                color = if (isRecording) VoxSumPalette.Red else pal.Slate200,
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.height(8.dp))
        if (landscape) {
            // Two columns: timer/name/buttons left, live transcript right — stacking them
            // vertically left the transcript panel with zero height on phone landscape.
            Row(Modifier.weight(1f)) {
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    TimerRow(recSeconds, micLevel, Modifier.align(Alignment.CenterHorizontally))
                    HwStatusLine(Modifier.align(Alignment.CenterHorizontally))
                    Spacer(Modifier.height(12.dp))
                    Spacer(Modifier.weight(1f))
                    CaptureButtons(isRecording, onNextTalk, onStop, buttonHeight = 72.dp)
                }
                Spacer(Modifier.width(24.dp))
                Column(Modifier.weight(1.2f).fillMaxHeight()) {
                    LivePanel(utterances, stable, agent, notice)
                }
            }
            Spacer(Modifier.height(12.dp))
        } else {
            TimerRow(recSeconds, micLevel, Modifier.align(Alignment.CenterHorizontally))
            HwStatusLine(Modifier.align(Alignment.CenterHorizontally))
            Spacer(Modifier.height(12.dp))
            // Live transcript: a first-class panel filling everything between the timer and
            // the buttons — the full running transcript, auto-following the newest line.
            LivePanel(utterances, stable, agent, notice)
            Spacer(Modifier.height(16.dp))
            CaptureButtons(isRecording, onNextTalk, onStop, buttonHeight = 72.dp)
            Spacer(Modifier.height(16.dp))
        }
    }
}

/** Pulsing red "on air" dot (static on e-ink). */
@Composable
private fun RecDot() {
    val pal = LocalVoxSumPalette.current
    val a = if (pal.isEink) 1f else {
        val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "rec")
        t.animateFloat(1f, 0.25f, androidx.compose.animation.core.infiniteRepeatable(
            androidx.compose.animation.core.tween(700), androidx.compose.animation.core.RepeatMode.Reverse), label = "rec-a").value
    }
    Box(Modifier.size(10.dp).alpha(a).clip(CircleShape).background(VoxSumPalette.Red))
}

@Composable
private fun TimerRow(recSeconds: Int, micLevel: Float, modifier: Modifier = Modifier) {
    val pal = LocalVoxSumPalette.current
    // Compact header: timer + mic bars on one line — still readable from across a table, but
    // the vertical space goes to the live transcript instead of empty padding.
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        Text(
            "%d:%02d".format(recSeconds / 60, recSeconds % 60),
            fontSize = 64.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,   // tabular: no layout shift per tick
            color = pal.Slate200,
        )
        Spacer(Modifier.width(20.dp))
        // 2x: at 1x the bars are a speck beside 64sp digits — scale to visually balance them.
        MicLevelBars(micLevel, pal.Sky, scale = 2f)
    }
}

/** The transcript panel body — takes all remaining column height. Declared as a ColumnScope
 *  extension for the weight modifier. */
@Composable
private fun androidx.compose.foundation.layout.ColumnScope.LivePanel(
    utterances: List<TranscriptEvent.Utterance>,
    stable: Int,
    agent: AgentUiState?,
    notice: String? = null,
) {
    val pal = LocalVoxSumPalette.current
    // The summarizing agent works alongside ASR + diarization: its status stays pinned on top.
    agent?.let {
        // The live notes name speakers as the booth does (S2 → 語者 2 / 说话人 2 / Speaker 2).
        val ctx = androidx.compose.ui.platform.LocalContext.current
        val known = utterances.mapNotNull { u -> u.speaker }.toSet().ifEmpty { null }
        CompositionLocalProvider(LocalSpeakerRefs provides { t ->
            studio.voxsum.core.reader.SpeakerRefs.resolve(t, { id -> ctx.getString(R.string.speaker_n, id + 1) }, known)
        }) { AgentStrip(it) }
    }
    // A model still downloading (e.g. the 3 GB summary model on a first run, while the meeting is
    // already being transcribed): say so on the booth, not only in the notification shade.
    if (utterances.isNotEmpty()) notice?.takeIf { it.isNotBlank() }?.let {
        Text(it, color = pal.Slate400, style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(vertical = 4.dp))
    }
    if (utterances.isEmpty()) {
        // Centered waiting state: a corner-anchored one-liner made the big empty panel
        // look unfinished — center it with a quiet mic glyph so the space reads intentional.
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    Icons.Filled.Mic, contentDescription = null,
                    tint = pal.Sky.copy(alpha = 0.5f), modifier = Modifier.size(44.dp),
                )
                Spacer(Modifier.height(10.dp))
                Text(stringResource(R.string.capture_live_waiting), color = pal.Slate400, style = MaterialTheme.typography.titleMedium)
                notice?.takeIf { it.isNotBlank() }?.let {
                    Spacer(Modifier.height(6.dp))
                    Text(it, color = pal.Slate400, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    } else {
        val listState = rememberLazyListState()
        // Follow the newest words. The last line grows in place (a line closes only on a speaker change
        // or after ~10 s), so key on its length too. Instant jump, not animate: e-ink hates animated
        // scrolls. The large offset pins the BOTTOM of a tall last line into view.
        LaunchedEffect(utterances.size, utterances.lastOrNull()?.text?.length) {
            listState.scrollToItem(utterances.lastIndex, scrollOffset = Int.MAX_VALUE / 2)
        }
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxWidth().weight(1f)
                .then(if (pal.isEink) Modifier else Modifier.fadeTop(14.dp))
                .padding(horizontal = 4.dp, vertical = 8.dp),
        ) {
            items(utterances.size) { i ->
                val u = utterances[i]
                // Text is live; a speaker tag appears only once the line is settled (i < stable, i.e.
                // the configured speaker delay has passed) — never a guess that may still flip. Tag
                // only where the speaker changes.
                val settled = i < stable
                val showTag = settled && u.speaker != null &&
                    (i == 0 || utterances[i - 1].speaker != u.speaker)
                // Settled lines carry their speaker's colour rail (like the session transcript);
                // the provisional tail has none yet, and its text is a shade lighter.
                val rail = if (settled && u.speaker != null) Color(speakerColorOn(u.speaker, pal.isDark)) else pal.Hairline
                Row(Modifier.padding(top = if (showTag && i > 0) 10.dp else 2.dp, bottom = 2.dp).height(IntrinsicSize.Min)) {
                    Box(Modifier.width(3.dp).fillMaxHeight().clip(RoundedCornerShape(2.dp)).background(rail))
                    Spacer(Modifier.width(10.dp))
                    Column {
                        if (showTag) {
                            val color = Color(speakerColorOn(u.speaker, pal.isDark))
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    stringResource(R.string.speaker_n, u.speaker + 1),
                                    color = color,
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.Bold,
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    "%d:%02d".format(u.startSec.toInt() / 60, u.startSec.toInt() % 60),
                                    color = pal.Slate400, style = MaterialTheme.typography.labelSmall,
                                )
                            }
                        }
                        Text(u.text, color = if (settled) pal.Slate200 else pal.Slate400, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        }
    }
}

@Composable
private fun CaptureButtons(
    isRecording: Boolean,
    onNextTalk: () -> Unit,
    onStop: () -> Unit,
    buttonHeight: androidx.compose.ui.unit.Dp,
) {
    val pal = LocalVoxSumPalette.current
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        // ⏭ Next talk — the batch-recording workhorse: auto-save this capture, defer its
        // processing, and roll straight into the next session.
        Button(
            onClick = onNextTalk,
            enabled = isRecording,
            shape = RoundedCornerShape(20.dp),
            colors = ButtonDefaults.buttonColors(containerColor = pal.Sky),
            modifier = Modifier.weight(1f).height(buttonHeight),
            // Minimal padding: on narrow phones the default 24dp sides forced CJK labels to wrap.
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.SkipNext, contentDescription = null, modifier = Modifier.size(28.dp))
                Text(stringResource(R.string.capture_next_talk), fontWeight = FontWeight.Bold, maxLines = 1)
            }
        }
        // ⏹ Stop & save — always safe: the capture is in the library before processing starts.
        Button(
            onClick = onStop,
            enabled = isRecording,
            shape = RoundedCornerShape(20.dp),
            colors = ButtonDefaults.buttonColors(containerColor = VoxSumPalette.Red),
            modifier = Modifier.weight(1f).height(buttonHeight),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.size(28.dp))
                Text(stringResource(R.string.capture_stop), fontWeight = FontWeight.Bold, maxLines = 1)
            }
        }
    }
}

/** Dissolves the first [height] of a scrolling list into the ground, so a line cut by the panel's
 *  top edge fades instead of being sliced. */
private fun Modifier.fadeTop(height: androidx.compose.ui.unit.Dp): Modifier = this
    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
    .drawWithContent {
        drawContent()
        drawRect(
            Brush.verticalGradient(listOf(Color.Transparent, Color.Black), endY = height.toPx()),
            blendMode = BlendMode.DstIn,
        )
    }
