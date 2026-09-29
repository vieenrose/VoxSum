package studio.voxsum.ui

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
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
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
    sessionName: String,
    onSessionName: (String) -> Unit,
    utterances: List<TranscriptEvent.Utterance>,
    /** Leading [utterances] that are settled; the rest are provisional (speaker may still change). */
    stable: Int = 0,
    onNextTalk: () -> Unit,
    onStop: () -> Unit,
    onBack: () -> Unit,
) {
    val pal = LocalVoxSumPalette.current
    var showLive by remember { mutableStateOf(true) }
    val conf = LocalConfiguration.current
    val landscape = conf.screenWidthDp > conf.screenHeightDp
    Column(
        Modifier
            .fillMaxSize()
            .background(pal.Slate900Grad)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(horizontal = 24.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp)) {
            IconButton(onClick = onBack) {
                Icon(Icons.Filled.ArrowBack, contentDescription = stringResource(R.string.back), tint = pal.Slate200)
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
                    Spacer(Modifier.height(12.dp))
                    NameField(sessionName, onSessionName)
                    Spacer(Modifier.weight(1f))
                    CaptureButtons(isRecording, onNextTalk, onStop, buttonHeight = 72.dp)
                }
                Spacer(Modifier.width(24.dp))
                Column(Modifier.weight(1.2f).fillMaxHeight()) {
                    LiveHeader(showLive, pal) { showLive = !showLive }
                    LivePanel(showLive, utterances, stable)
                }
            }
            Spacer(Modifier.height(12.dp))
        } else {
            TimerRow(recSeconds, micLevel, Modifier.align(Alignment.CenterHorizontally))
            Spacer(Modifier.height(16.dp))
            NameField(sessionName, onSessionName)
            Spacer(Modifier.height(16.dp))
            // Live transcript: a first-class panel filling everything between the name field and
            // the buttons — the full running transcript, auto-following the newest line.
            LiveHeader(showLive, pal) { showLive = !showLive }
            LivePanel(showLive, utterances, stable)
            Spacer(Modifier.height(16.dp))
            CaptureButtons(isRecording, onNextTalk, onStop, buttonHeight = 96.dp)
            Spacer(Modifier.height(16.dp))
        }
    }
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

@Composable
private fun NameField(sessionName: String, onSessionName: (String) -> Unit) {
    val pal = LocalVoxSumPalette.current
    OutlinedTextField(
        value = sessionName,
        onValueChange = onSessionName,
        singleLine = true,
        label = { Text(stringResource(R.string.capture_session_name), color = pal.Slate400) },
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = pal.Slate200, unfocusedTextColor = pal.Slate200,
            focusedBorderColor = pal.Sky, unfocusedBorderColor = pal.Slate700,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun LiveHeader(showLive: Boolean, pal: studio.voxsum.ui.theme.VoxSumColors, onToggle: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(pal.Slate800).padding(horizontal = 12.dp),
    ) {
        Text(
            stringResource(R.string.capture_live_transcript),
            style = MaterialTheme.typography.labelMedium,
            color = pal.Slate400,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onToggle) {
            Icon(
                if (showLive) Icons.Filled.ExpandMore else Icons.Filled.ExpandLess,
                contentDescription = null,
                tint = pal.Slate400,
            )
        }
    }
}

/** The transcript panel body — takes all remaining column height (collapsed → a spacer keeps
 *  the geometry stable). Declared as a ColumnScope extension for the weight modifier. */
@Composable
private fun androidx.compose.foundation.layout.ColumnScope.LivePanel(
    showLive: Boolean,
    utterances: List<TranscriptEvent.Utterance>,
    stable: Int,
) {
    val pal = LocalVoxSumPalette.current
    if (!showLive) {
        Spacer(Modifier.weight(1f))
        return
    }
    if (utterances.isEmpty()) {
        // Centered waiting state: a corner-anchored one-liner made the big empty panel
        // look unfinished — center it with a quiet mic glyph so the space reads intentional.
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    Icons.Filled.Mic, contentDescription = null,
                    tint = pal.Slate700, modifier = Modifier.size(44.dp),
                )
                Spacer(Modifier.height(10.dp))
                Text(stringResource(R.string.capture_live_waiting), color = pal.Slate400, style = MaterialTheme.typography.titleMedium)
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
            modifier = Modifier.fillMaxWidth().weight(1f).padding(horizontal = 4.dp, vertical = 8.dp),
        ) {
            items(utterances.size) { i ->
                val u = utterances[i]
                // Tag only where the speaker changes; a speaker the diarizer has not reached yet
                // (the newest ~5 s) has no tag at all rather than a guess.
                val showTag = u.speaker != null && (i == 0 || utterances[i - 1].speaker != u.speaker)
                Column(Modifier.padding(top = if (showTag && i > 0) 8.dp else 2.dp, bottom = 2.dp)) {
                    if (showTag) {
                        // Provisional (not yet settled) lines draw their tag dimmed — same 0.55 alpha
                        // the session screen uses for de-emphasis; no animation (e-ink).
                        val color = Color(speakerColorOn(u.speaker, pal.isDark))
                            .copy(alpha = if (i < stable) 1f else 0.55f)
                        Text(
                            speakerLabel(u.speaker, emptyMap()).orEmpty(),
                            color = color,
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                    Text(u.text, color = pal.Slate200, style = MaterialTheme.typography.bodyMedium)
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
            // On a batch day ⏭ is tapped ten times for every ⏹ — it gets the primary width.
            modifier = Modifier.weight(1.5f).height(buttonHeight),
            // Minimal padding: on narrow phones the default 24dp sides forced CJK labels to wrap.
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Filled.SkipNext, contentDescription = null, modifier = Modifier.size(36.dp))
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
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.size(36.dp))
                Text(stringResource(R.string.capture_stop), fontWeight = FontWeight.Bold, maxLines = 1)
            }
        }
    }
}
