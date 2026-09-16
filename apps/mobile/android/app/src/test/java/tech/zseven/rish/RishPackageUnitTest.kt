package tech.zseven.rish

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins which Android bridges are real implementations and which still fail
 * closed with a JS-recognized unavailable code.
 *
 * LocalMirrors, LocalWorkspace and LocalWorkspaces are implemented by the
 * Android workspace/mirror modules; the remaining names reject explicitly.
 * LocalGuest is implemented (tech.zseven.rish.guest) but still rejects with
 * E_GUEST_NATIVE in a lite build without the staged rish runtime.
 *
 * Run with one Gradle command:
 *   ./gradlew :app:testDebugUnitTest
 */
class RishPackageUnitTest {

    private val implemented = setOf("LocalMirrors", "LocalWorkspace", "LocalWorkspaces")

    private val unavailableCodes = mapOf(
        "AgentRuntime" to "E_AGENT_NATIVE",
        "LocalAttachments" to "E_NATIVE_UNAVAILABLE",
        "LocalDocuments" to "E_NATIVE_UNAVAILABLE",
        "LocalGuest" to "E_GUEST_NATIVE",
        "LocalProjectContext" to "E_CONTEXT_NATIVE",
        "LocalProjects" to "E_PROJECT_NATIVE",
    )

    @Test
    fun moduleNameTableMatchesJsProbes() {
        assertEquals(
            setOf(
                "AgentRuntime", "LocalAttachments", "LocalDocuments", "LocalGuest",
                "LocalMirrors", "LocalProjectContext", "LocalProjects",
                "LocalWorkspace", "LocalWorkspaces",
            ),
            implemented + unavailableCodes.keys,
        )
    }

    @Test
    fun everyModuleCarriesARecognizedUnavailableCode() {
        for ((module, code) in unavailableCodes) {
            assertTrue(module + " must reject with a JS-recognized code", code.startsWith("E_"))
        }
    }
}
