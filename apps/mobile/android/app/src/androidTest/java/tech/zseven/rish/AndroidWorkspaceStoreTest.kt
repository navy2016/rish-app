package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidWorkspaceStore
import tech.zseven.rish.runtime.WorkspaceFailure

/**
 * Device-level acceptance for the Android workspace authority: create, write,
 * read, list, rename, trash and restore all run against the real app context
 * and the real filesystem, exactly as the JS bridge drives them.
 */
@RunWith(AndroidJUnit4::class)
class AndroidWorkspaceStoreTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val store = AndroidWorkspaceStore.get(context)

    @Test
    fun creatingAWorkspaceEnablesFilesOperations() {
        val descriptor = store.create("Acceptance ${System.nanoTime()}")
        val record = store.find(descriptor.getString("workspace_id"))

        assertEquals("ok", descriptor.getString("status"))
        assertEquals("rish_created", descriptor.getString("origin"))
        assertTrue(descriptor.getJSONObject("capabilities").getBoolean("read"))
        assertTrue(descriptor.getJSONObject("capabilities").getBoolean("write"))
        assertEquals(0, store.list(record, "", 100).getJSONArray("entries").length())

        val written = store.write(record, "notes.txt", "hello rish\n", null, true)
        assertTrue(written.getBoolean("created"))
        assertEquals(64, written.getJSONObject("file").getString("revision").length)
        assertEquals("hello rish\n", store.read(record, "notes.txt", 4096).getString("content"))

        store.mkdir(record, "docs")
        store.write(record, "docs/readme.md", "readme", null, true)
        assertEquals(2, store.list(record, "", 100).getJSONArray("entries").length())

        store.rename(record, "docs/readme.md", "docs/guide.md")
        val docs = store.list(record, "docs", 100).getJSONArray("entries")
        assertEquals(1, docs.length())
        assertEquals("guide.md", docs.getJSONObject(0).getString("name"))

        val digest = store.tool(record, "sha256sum", "notes.txt", JSONObject())
        assertEquals(0, digest.getInt("exit_code"))
        assertEquals("portable_applet", digest.getString("path_kind"))
        assertTrue(digest.getString("stdout").startsWith(store.read(record, "notes.txt", 4096).getJSONObject("file").getString("revision")))

        store.remove(record)
        assertTrue(store.listing().getJSONArray("workspaces").length() == 0 || !exists(record.id))
    }

    @Test
    fun pathsOutsideTheRootAndStaleRevisionsAreRefused() {
        val descriptor = store.create("Guards ${System.nanoTime()}")
        val record = store.find(descriptor.getString("workspace_id"))

        val escaped = runCatching { store.read(record, "../escape.txt", 4096) }.exceptionOrNull()
        assertTrue(escaped is WorkspaceFailure)
        assertEquals("E_WORKSPACE_INVALID", (escaped as WorkspaceFailure).code)

        val stale = runCatching {
            store.resolve(
                JSONObject()
                    .put("workspace_id", record.id)
                    .put("expected_binding_revision", record.revision + 5)
                    .put("required_capabilities", JSONArray()),
            )
        }.exceptionOrNull()
        assertTrue(stale is WorkspaceFailure)
        assertEquals("E_WORKSPACE_REVISION_STALE", (stale as WorkspaceFailure).code)

        val git = runCatching {
            store.resolve(
                JSONObject()
                    .put("workspace_id", record.id)
                    .put("expected_binding_revision", record.revision)
                    .put("required_capabilities", JSONArray(listOf("read", "write", "git"))),
            )
        }.exceptionOrNull()
        assertTrue(git is WorkspaceFailure)
        assertEquals("E_WORKSPACE_CAPABILITY", (git as WorkspaceFailure).code)

        store.remove(record)
    }

    @Test
    fun trashRestoresTheSameBytes() {
        val descriptor = store.create("Trash ${System.nanoTime()}")
        val record = store.find(descriptor.getString("workspace_id"))

        store.write(record, "notes.txt", "hello rish\n", null, true)
        val receipt = store.trash(record, "notes.txt").getJSONObject("receipt")
        assertEquals("notes.txt", receipt.getString("original_path"))
        assertEquals("file", receipt.getString("kind"))

        val missing = runCatching { store.read(record, "notes.txt", 4096) }.exceptionOrNull()
        assertTrue(missing is WorkspaceFailure)
        assertEquals("E_WORKSPACE_NOT_FOUND", (missing as WorkspaceFailure).code)

        assertEquals(1, store.listTrash(record, 8).getJSONArray("entries").length())
        val restored = store.restore(record, receipt.getString("trash_id"), null)
        assertEquals("notes.txt", restored.getJSONObject("entry").getString("path"))
        assertEquals("hello rish\n", store.read(record, "notes.txt", 4096).getString("content"))
        assertEquals(0, store.listTrash(record, 8).getJSONArray("entries").length())

        store.remove(record)
    }

    private fun exists(id: String): Boolean {
        val listing = store.listing().getJSONArray("workspaces")
        for (index in 0 until listing.length()) {
            if (listing.getJSONObject(index).getString("workspace_id") == id) return true
        }
        return false
    }
}
