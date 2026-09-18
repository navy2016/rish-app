package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.chatReplyRefusal

/**
 * The reply-side half of "let tools reach the model": what a chat reply has to
 * answer before anything reads it.
 *
 * The round that runs tools depends on this: a DeepSeek tool call carries
 * `content: null` and `finish_reason: "tool_calls"`, and the check that called
 * that an empty answer refused the very first call the model ever made. These
 * cases pin the whole table, both what is refused and under which name.
 */
@RunWith(AndroidJUnit4::class)
class AndroidTransportReplyTest {
    @Test
    fun aPlainAnswerIsAccepted() {
        assertNull(chatReplyRefusal("hello", "stop", 0))
        assertNull(chatReplyRefusal("cut off", "length", 0))
    }

    @Test
    fun anEmptyAnswerIsRefusedByName() {
        assertEquals("E_COMPLETION_EMPTY_RESPONSE", chatReplyRefusal("", "stop", 0))
        assertEquals("E_COMPLETION_EMPTY_RESPONSE", chatReplyRefusal("   ", "length", 0))
    }

    @Test
    fun aToolCallReplyIsAccepted() {
        // DeepSeek's tool-only reply: null content, finish_reason tool_calls.
        assertNull(chatReplyRefusal("", "tool_calls", 1))
        assertNull(chatReplyRefusal("", "tool_calls", 4))
        // A truncated tool reply is still a tool reply; the round's parser
        // refuses an incomplete call, not this check.
        assertNull(chatReplyRefusal("", "length", 2))
    }

    @Test
    fun theFinishReasonAndTheCallsMustAgree() {
        // Claims tools and sent none.
        assertEquals("E_COMPLETION_FINISH_RELATION", chatReplyRefusal("answer", "tool_calls", 0))
        // A finish reason this engine cannot act on.
        assertEquals("E_COMPLETION_FINISH_RELATION", chatReplyRefusal("answer", "content_filter", 0))
        // Calls with a stop finish are left to the core's agreement rule.
        assertNull(chatReplyRefusal("answer", "stop", 1))
    }
}
