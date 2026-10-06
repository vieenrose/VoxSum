package studio.voxsum.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class ReleaseNotesTest {
    @Test fun dropsLinksImagesHtmlAndRules() {
        val md = "## Fixes\r\n- **Summary (#5).** See [the guide](https://x.y/z).\n\n\n\n<img src=\"a.png\">\n---\n![shot](a.png)\n<!-- hidden -->\nDone"
        assertEquals("## Fixes\n- **Summary (#5).** See the guide.\n\n\nDone".replace("\n\n\n", "\n\n"), cleanReleaseNotes(md))
    }

    @Test fun keepsPlainMarkdown() {
        assertEquals("## A\n- `x` **b**", cleanReleaseNotes("## A\n- `x` **b**"))
    }
}
