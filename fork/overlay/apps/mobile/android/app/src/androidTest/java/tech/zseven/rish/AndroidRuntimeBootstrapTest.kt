package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.modules.LocalRuntimeModule

/**
 * Device-level acceptance for the JS runtime probe path:
 * `bootstrapForHarness` must answer for every harness the JS layer can select,
 * with a proof whose active_harness matches the request — the contract
 * LocalRuntime.bootstrapForHarness in apps/mobile/src/native/LocalRuntime.ts
 * expects (the sheet then shows the credential/model/process rows from it).
 */
@RunWith(AndroidJUnit4::class)
class AndroidRuntimeBootstrapTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val module = LocalRuntimeModule(ReactApplicationContext(context))

    /** Captures whichever Promise overload the module settles through. */
    private class RecordingPromise : InvocationHandler {
        val latch = CountDownLatch(1)
        @Volatile var value: Any? = null
        @Volatile var rejectionCode: String? = null
        @Volatile var rejectionMessage: String? = null

        override fun invoke(proxy: Any?, method: Method, args: Array<out Any?>?): Any? =
            when {
                method.name == "resolve" -> {
                    value = args?.firstOrNull()
                    latch.countDown()
                    null
                }
                method.name.startsWith("reject") -> {
                    rejectionCode = args?.firstOrNull() as? String
                    rejectionMessage = args?.getOrNull(1)?.toString()
                    latch.countDown()
                    null
                }
                method.name == "toString" -> "RecordingPromise"
                method.name == "hashCode" -> System.identityHashCode(proxy)
                method.name == "equals" -> proxy === args?.firstOrNull()
                else -> null
            }

        fun promise(): Promise = Proxy.newProxyInstance(
            Promise::class.java.classLoader,
            arrayOf(Promise::class.java),
            this,
        ) as Promise
    }

    private fun bootstrap(harnessId: String): ReadableMap {
        val recorder = RecordingPromise()
        module.bootstrapForHarness(harnessId, recorder.promise())
        assertTrue(
            "bootstrapForHarness($harnessId) did not settle",
            recorder.latch.await(30, TimeUnit.SECONDS),
        )
        assertEquals(
            "bootstrapForHarness($harnessId) rejected: ${recorder.rejectionMessage}",
            null,
            recorder.rejectionCode,
        )
        return recorder.value as? ReadableMap
            ?: throw AssertionError("bootstrapForHarness($harnessId) resolved with a non-map value")
    }

    @Test
    fun everyHarnessGetsAProofOfItsOwnAdapter() {
        for (harnessId in listOf("dsh", "claude-code", "codex", "glm")) {
            val result = bootstrap(harnessId)
            val proof = result.getMap("proof")
                ?: throw AssertionError("proof missing for $harnessId")
            assertEquals(2, proof.getInt("schema_version"))
            assertEquals("rish", proof.getString("product"))
            assertEquals(harnessId, proof.getString("active_harness"))
            assertTrue(
                "platform for $harnessId",
                proof.getString("platform")?.startsWith("android") == true,
            )
            assertTrue("process_id for $harnessId", (proof.getInt("process_id") ?: 0) > 0)
            if (proof.getMap("checks") == null) {
                throw AssertionError("checks missing for $harnessId")
            }
            if (result.getMap("rish") == null) {
                throw AssertionError("rish record missing for $harnessId")
            }
        }
    }
}
