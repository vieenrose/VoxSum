package studio.voxsum

import org.junit.Assert.assertEquals
import org.junit.Test
import studio.voxsum.core.reader.SpeakerRefs

class SpeakerRefsTest {
    private val zh: (Int) -> String = { "語者 ${it + 1}" }

    @Test fun replacesIsolatedRefsInChinese() =
        assertEquals("語者 2 負責聯絡攝影師，語者 1 回覆樂團",
            SpeakerRefs.resolve("S2 負責聯絡攝影師，S1 回覆樂團", zh, setOf(0, 1)))

    @Test fun replacesRefsGluedToHanAndPunctuation() =
        assertEquals("由語者 2負責（語者 1）", SpeakerRefs.resolve("由S2負責（S1）", zh))

    @Test fun leavesCodesAndWordsAlone() =
        assertEquals("S20X AS2 S2B iOS2", SpeakerRefs.resolve("S20X AS2 S2B iOS2", zh))

    @Test fun keepsUnknownSpeakers() =
        assertEquals("語者 1 與 S9", SpeakerRefs.resolve("S1 與 S9", zh, setOf(0, 1)))

    @Test fun usesGivenNames() =
        assertEquals("王經理 決定", SpeakerRefs.resolve("S1 決定", { if (it == 0) "王經理" else "Speaker ${it + 1}" }))

    @Test fun dropsTheSpaceBeforeAChineseName() =
        assertEquals("而語者 1 則回覆", SpeakerRefs.resolve("而 S1 則回覆", zh))

    @Test fun keepsTheSpaceBeforeALatinName() =
        assertEquals("而 Mary 則回覆", SpeakerRefs.resolve("而 S1 則回覆", { "Mary" }))

    @Test fun wrapsForMarkdown() =
        assertEquals("而**語者 1**則", SpeakerRefs.resolve("而 S1則", zh, wrap = { "**$it**" }))

    @Test fun spaceAfterALatinNameBeforeChinese() =
        assertEquals("由 Speaker 1 負責，Mary 將回覆", SpeakerRefs.resolve("由 S1負責，S2將回覆", { if (it == 0) "Speaker 1" else "Mary" }))

    @Test fun englishLabel() =
        assertEquals("Speaker 3 will call", SpeakerRefs.resolve("S3 will call", { "Speaker ${it + 1}" }))
}
