package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactMethod
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.modules.LocalRuntimeModule
import tech.zseven.rish.runtime.AndroidProviderConfiguration
import tech.zseven.rish.runtime.AndroidRuntimeState

/**
 * Device-level acceptance for the JS runtime probe path.
 *
 * Two layers: the bridge surface is pinned reflectively (@ReactMethod
 * `bootstrapForHarness` taking (String, Promise)), and the behaviour the method
 * delegates to — harness -> credential slot -> proof.active_harness — runs
 * against the real runtime state and storage. Together they cover what
 * LocalRuntime.bootstrapForHarness in apps/mobile/src/native/LocalRuntime.ts
 * calls; the local-proof sheet renders these proofs.
 */
@RunWith(AndroidJUnit4::class)
class AndroidRuntimeBootstrapTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val harnesses = listOf("dsh", "claude-code", "codex", "glm")

    @Test
    fun theBridgeExposesBootstrapForHarness() {
        val method = LocalRuntimeModule::class.java.methods
            .firstOrNull { it.name == "bootstrapForHarness" }
            ?: throw AssertionError("LocalRuntimeModule.bootstrapForHarness is missing from the bridge")
        assertTrue(
            "bootstrapForHarness must be @ReactMethod",
            method.isAnnotationPresent(ReactMethod::class.java),
        )
        val parameters = method.parameterTypes
        assertEquals(2, parameters.size)
        assertEquals(String::class.java, parameters[0])
        assertEquals(Promise::class.java, parameters[1])
    }

    @Test
    fun everyHarnessSelectsItsSlotAndNamesTheProof() {
        val runtime = AndroidRuntimeState.get(context)
        for (harnessId in harnesses) {
            runtime.selectedSlot = AndroidProviderConfiguration.slot(harnessId)
            val proof = runtime.proof().getJSONObject("proof")
            assertEquals(harnessId, proof.getString("active_harness"))
            assertEquals(2, proof.getInt("schema_version"))
            assertEquals("rish", proof.getString("product"))
            assertTrue(
                "platform for $harnessId",
                proof.getString("platform").startsWith("android"),
            )
            assertTrue("process_id for $harnessId", proof.getInt("process_id") > 0)
            assertTrue("checks for $harnessId", proof.has("checks"))
        }
    }
}
