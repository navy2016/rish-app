package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.AndroidWorkspaceStore
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RuntimeJson
import java.io.File
import java.util.UUID

/**
 * The bridge the Files surface runs through: a workspace the shared registry
 * holds, opened for bounded file operations by the fork's store.
 *
 * This is the seam the LocalWorkspace module performs per request (registry
 * record -> revision check -> proven root -> store record), so a regression
 * here fails the smoke run where the module itself cannot be driven without a
 * live React bridge.
 */
@RunWith(AndroidJUnit4::class)
class AndroidWorkspaceBridgeTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun registryWorkspaceServesBoundedFileOperations() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val container = File(context.filesDir, "bridge-test-" + UUID.randomUUID())
        try {
            val registry = AndroidWorkspaceRegistry(container)
            val workspaceId = UUID.randomUUID().toString()
            val record = registry.create(
                displayName = "Bridge",
                workspaceId = workspaceId,
                now = RuntimeJson.now(),
                operationId = UUID.randomUUID().toString(),
            )
            assertEquals(workspaceId, record.getString("workspace_id"))
            assertEquals(1, record.getInt("binding_revision"))
            val root = registry.rootFor(workspaceId)
            assertNotNull("the registry proves the directory it created", root)

            val store = AndroidWorkspaceStore.get(context)
            val fileRecord =
                AndroidWorkspaceStore.recordForRegistryWorkspace(workspaceId, 1L, root!!)
            val written = store.write(fileRecord, "notes/todo.md", "hello bridge", null, false)
            assertTrue(written.getBoolean("created"))
            // The evidence is the filesystem: the bytes are on the disk the
            // registry proved, not only in the reply.
            assertEquals("hello bridge", File(root, "notes/todo.md").readText())

            val read = store.read(fileRecord, "notes/todo.md", 1024)
            assertEquals("hello bridge", read.getString("content"))
            assertEquals("notes/todo.md", read.getJSONObject("file").getString("path"))

            val listing = store.list(fileRecord, "notes", 100)
            val entries = listing.getJSONArray("entries")
            assertEquals(1, entries.length())
            assertEquals("todo.md", entries.getJSONObject(0).getString("name"))

            // A path that escapes the proven root is refused before a file is
            // touched, whoever authored the record.
            try {
                store.write(fileRecord, "../escape.md", "no", null, false)
                fail("an escaping path was accepted")
            } catch (_: Exception) {
            }
            assertFalse(File(container, "escape.md").exists())
            assertFalse(File(root.parentFile, "escape.md").exists())
        } finally {
            container.deleteRecursively()
        }
    }
}
