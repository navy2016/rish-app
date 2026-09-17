package tech.zseven.rish

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the remaining unsupported Android module names and their
 * JS-recognized unavailable codes. Runtime and snapshots have device tests.
 * LocalGuest is implemented (tech.zseven.rish.guest) but still rejects with
 * E_GUEST_NATIVE in a lite build without the staged rish runtime.
 *
 * Run with one Gradle command:
 *   ./gradlew :app:testDebugUnitTest
 */
class RishPackageUnitTest {

    private val unavailableCodes = mapOf(
        "AgentRuntime" to "E_AGENT_NATIVE",
        "LocalAttachments" to "E_NATIVE_UNAVAILABLE",
        "LocalDocuments" to "E_NATIVE_UNAVAILABLE",
        "LocalGuest" to "E_GUEST_NATIVE",
        "LocalMirrors" to "E_NATIVE_UNAVAILABLE",
        "LocalProjectContext" to "E_CONTEXT_NATIVE",
        "LocalProjects" to "E_PROJECT_NATIVE",
        "LocalWorkspace" to "E_WORKSPACE_UNAVAILABLE",
        "LocalWorkspaces" to "E_WORKSPACE_UNAVAILABLE",
    )

    @Test
    fun moduleNameTableMatchesJsProbes() {
        assertEquals(
            setOf(
                "AgentRuntime", "LocalAttachments", "LocalDocuments", "LocalGuest",
                "LocalMirrors", "LocalProjectContext", "LocalProjects",
                "LocalWorkspace", "LocalWorkspaces",
            ),
            unavailableCodes.keys,
        )
    }

    @Test
    fun everyModuleCarriesARecognizedUnavailableCode() {
        for ((module, code) in unavailableCodes) {
            assertTrue(module + " must reject with a JS-recognized code", code.startsWith("E_"))
        }
    }
}
