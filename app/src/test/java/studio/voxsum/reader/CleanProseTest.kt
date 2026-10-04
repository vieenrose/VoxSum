package studio.voxsum.reader

import org.junit.Assert.assertEquals
import org.junit.Test
import studio.voxsum.core.reader.ReaderLane

class CleanProseTest {
    private val known = setOf("1:34", "12:28")

    @Test fun cutOffReplyEndsAtLastSentence() {
        val raw = "會議最後決定採用報價八萬的表演團隊，語者 1 明天回覆 [1:34]。新人獎可由總經理加碼決定，結果再加進抽獎流 [12:28"
        assertEquals("會議最後決定採用報價八萬的表演團隊，語者 1 明天回覆 [1:34]。", ReaderLane.cleanProse(raw, known))
    }

    @Test fun finishedReplyIsKeptWhole() {
        val raw = "會議決定採用八萬的團隊 [1:34]。新人獎由總經理加碼決定 [12:28]<turn|>"
        assertEquals("會議決定採用八萬的團隊 [1:34]。新人獎由總經理加碼決定 [12:28]", ReaderLane.cleanProse(raw, known))
    }

    @Test fun strippedTimestampLeavesNoSpaceBeforePunctuation() {
        val raw = "語者 2 會後傳送流程草案，下週一早上發問卷調查 [9:99]。<turn|>"
        assertEquals("語者 2 會後傳送流程草案，下週一早上發問卷調查。", ReaderLane.cleanProse(raw, known))
    }

    @Test fun timestampAfterTheFinalStopIsKept() {
        val raw = "The team picked the 80k troupe. Speaker 1 replies tomorrow。 [1:34] Then they"
        assertEquals("The team picked the 80k troupe. Speaker 1 replies tomorrow。 [1:34]", ReaderLane.cleanProse(raw, known))
    }
}
