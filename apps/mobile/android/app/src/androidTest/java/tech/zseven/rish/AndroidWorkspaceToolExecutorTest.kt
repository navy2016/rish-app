package tech.zseven.rish

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import android.app.Application
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.AndroidWorkspaceToolExecutor
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * An agent writing a file into a workspace it is bound to, on the device.
 *
 * This is the layer that does the work the whole feature is for. It runs
 * against a real registry, a real directory under the app's files, and the
 * real core: nothing is faked, and the bytes are read back off the filesystem
 * rather than out of the executor's own reply.
 *
 * What it does not cover: `execute_agent_tool`, which wraps this in the ledger,
 * the batch revision and the approval. A tool cannot be reached from a
 * conversation yet; this proves the tool itself is real.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidWorkspaceToolExecutorTest {

    private fun fixture(body: (AndroidWorkspaceToolExecutor, JSONObject, File) -> Unit) {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val app = ApplicationProvider.getApplicationContext<Application>()
        val home = File(app.cacheDir, "tool-executor-${UUID.randomUUID()}")
        val registry = AndroidWorkspaceRegistry(home)
        val record = registry.create(displayName = "executor test")
        val id = record.getString("workspace_id")
        val root = JSONObject().put("schema_version", 1).put("workspace_id", id)
            .put("binding_revision", record.getInt("binding_revision"))
            .put("project_id", JSONObject.NULL)
        val executor = AndroidWorkspaceToolExecutor(registry, AndroidAgentRootResolver(registry))
        try {
            body(executor, root, registry.rootFor(id)!!)
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun anAgentWritesAFileAndTheBytesAreOnDisk() = fixture { executor, root, directory ->
        val written = executor.execute(
            "write_file",
            JSONObject().put("path", "notes/todo.md").put("content", "one\ntwo\n"),
            root,
        )
        assertEquals("file_write", written.getString("kind"))

        // The reply is not the evidence. The file is.
        val file = File(directory, "notes/todo.md")
        assertTrue("the agent's file must exist under the workspace root", file.isFile)
        assertEquals("one\ntwo\n", file.readText())

        val read = executor.execute("read_file", JSONObject().put("path", "notes/todo.md"), root)
        assertEquals("one\ntwo\n", read.getString("content"))
        assertFalse(read.getBoolean("truncated"))
        // The revision names the state the host read, and a write moves it.
        assertEquals(written.getString("revision"), read.getString("revision"))
    }

    @Test
    fun aListingShowsWhatTheAgentWrote() = fixture { executor, root, _ ->
        executor.execute("write_file", JSONObject().put("path", "a.txt").put("content", "a"), root)
        executor.execute("write_file", JSONObject().put("path", "b.txt").put("content", "b"), root)
        val listing = executor.execute("list_dir", JSONObject(), root)
        val entries = listing.getJSONArray("entries")
        val names = (0 until entries.length()).map { entries.getJSONObject(it).getString("name") }
        assertTrue("$names", names.containsAll(listOf("a.txt", "b.txt")))
    }

    /**
     * The path rule is the core's, and these are the spellings it refuses. If
     * any of them started being accepted, an agent could address a file outside
     * the directory the person bound.
     */
    @Test
    fun aPathThatWouldLeaveTheRootIsRefused() = fixture { executor, root, _ ->
        for (path in listOf(
            "../escape.txt",
            "/etc/hosts",
            "notes/../../escape.txt",
            "a\\b.txt",
            ".git/config",
            ".trash/x",
            "",
        )) {
            val refused = try {
                executor.execute("read_file", JSONObject().put("path", path), root)
                false
            } catch (_: AndroidWorkspaceToolExecutor.Refused) {
                true
            }
            assertTrue("$path must be refused", refused)
        }
    }

    /** A tool that is not one of the three is not a tool. */
    @Test
    fun anUnknownToolIsRefused() = fixture { executor, root, _ ->
        val refused = try {
            executor.execute("delete_everything", JSONObject(), root)
            false
        } catch (_: AndroidWorkspaceToolExecutor.Refused) {
            true
        }
        assertTrue(refused)
    }

    /** A root naming a workspace this device does not hold has no directory. */
    @Test
    fun aRootThisDeviceDoesNotHoldIsRefused() = fixture { executor, _, _ ->
        val stranger = JSONObject().put("schema_version", 1)
            .put("workspace_id", UUID.randomUUID().toString())
            .put("binding_revision", 1).put("project_id", JSONObject.NULL)
        val refused = try {
            executor.execute("list_dir", JSONObject(), stranger)
            false
        } catch (_: AndroidWorkspaceToolExecutor.Refused) {
            true
        }
        assertTrue(refused)
    }

    /**
     * The preparation step is what the batch gate needs before any effect: what
     * the call asserts about the world, and what a person would be approving.
     */
    @Test
    fun preparingACallStatesWhatItAsserts() = fixture { executor, root, _ ->
        executor.execute("write_file", JSONObject().put("path", "a.txt").put("content", "a"), root)

        val read = executor.prepare("read_file", JSONObject().put("path", "a.txt"), root)
        val readCondition = read.getJSONObject("precondition")
        assertEquals("read_file", readCondition.getString("kind"))
        assertTrue(readCondition.getString("source_revision").contains(":"))
        // A preview never carries the file's bytes.
        assertTrue(read.getJSONObject("approval_preview").isNull("content_bytes"))

        val list = executor.prepare("list_dir", JSONObject(), root)
        assertEquals(
            64,
            list.getJSONObject("precondition").getString("directory_fingerprint_sha256").length,
        )
    }

    /**
     * A write asserts the prior it expects, and the disk has to agree. This is
     * the check that makes a stale write a conflict now rather than a silent
     * overwrite later, so it has to refuse both ways round.
     */
    @Test
    fun aWriteWhosePriorIsWrongIsRefusedBeforeAnythingHappens() = fixture { executor, root, directory ->
        // Absent is what a write with no expected_revision asserts.
        val fresh = executor.prepare(
            "write_file",
            JSONObject().put("path", "new.txt").put("content", "hello"),
            root,
        )
        val condition = fresh.getJSONObject("precondition")
        assertEquals("write_file", condition.getString("kind"))
        assertEquals("absent", condition.getJSONObject("prior").getString("kind"))
        assertEquals(5, condition.getInt("content_bytes"))
        assertEquals(64, condition.getString("relative_path_sha256").length)
        assertEquals(64, condition.getString("content_sha256").length)
        // Nothing was written by preparing.
        assertFalse(File(directory, "new.txt").exists())

        // Once the file exists, the same call asserts a prior that is wrong.
        executor.execute("write_file", JSONObject().put("path", "new.txt").put("content", "x"), root)
        val refused = try {
            executor.prepare(
                "write_file",
                JSONObject().put("path", "new.txt").put("content", "hello"),
                root,
            )
            false
        } catch (_: AndroidWorkspaceToolExecutor.Refused) {
            true
        }
        assertTrue("a write asserting absence over an existing file must be refused", refused)
    }
}
