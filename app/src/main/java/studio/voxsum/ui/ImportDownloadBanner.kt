package studio.voxsum.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import studio.voxsum.R
import studio.voxsum.online.ImportDownloads
import studio.voxsum.ui.components.DownloadStatusBar
import studio.voxsum.ui.theme.LocalVoxSumPalette

/**
 * Compact download card shown over any screen while a podcast/YouTube import downloads in the
 * service. A non-focusable popup, so the rest of the app stays usable; Cancel keeps the `.part`.
 */
@Composable
fun ImportDownloadBanner(state: ImportDownloads.State.Running, onCancel: () -> Unit) {
    val pal = LocalVoxSumPalette.current
    Popup(alignment = Alignment.BottomCenter) {
        Surface(
            color = pal.PanelSurface,
            shape = MaterialTheme.shapes.medium,
            tonalElevation = 6.dp,
            border = BorderStroke(1.dp, pal.Hairline),
            modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Column(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth()) {
                    Text(state.title ?: stringResource(R.string.import_download_title), color = pal.Slate200,
                        style = MaterialTheme.typography.titleSmall, maxLines = 1,
                        modifier = Modifier.weight(1f).padding(end = 8.dp))
                    TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) }
                }
                DownloadStatusBar(state.stageRes, state.progress, Modifier.padding(end = 8.dp, bottom = 8.dp))
            }
        }
    }
}
