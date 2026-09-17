package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentWal
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidPreparedAttemptStore
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.AndroidSessionStore
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * `prepare_agent_attempt` is the only operation that reads the committed
 * session and writes the agent WAL in one breath, and the two stores are not
 * atomic with each other: the session is SQLite, the WAL is a file. The window
 * between "the session says generation N" and "the WAL has committed an
 * operation bound to N" is the one place in the engine where a crash can leave
 * them disagreeing, and until now nothing exercised it on either platform.
 *
 * **What these cover, exactly.** The rootless tests cover the seam on the
 * **rejection** path: the core commits a rootless attempt as `not_agent` /
 * `E_AGENT_NO_ROOT` with the operation in state `rejected` — no authority, no
 * transcript — and they exercise the session read, the checkpoint relation,
 * the durable WAL write, replay, and recovery after an interrupted write.
 *
 * The rooted tests cover the same seam on the path that **writes**: a session
 * bound to a workspace this device holds resolves to a root, and the core
 * commits an authority and a transcript against it. A binding that cannot be
 * proven is stale, and nothing is written.
 *
 * Still uncovered here: rebinding, and project roots. Neither exists on this
 * platform.
 */
@RunWith(AndroidJUnit4::class)
class AndroidPreparedAttemptStoreTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun walRoot(): File =
        File(context.noBackupFilesDir, "prepared-test-${UUID.randomUUID()}").apply { mkdirs() }

    /**
     * A schema-9 session carrying the conversation and the attempt the request
     * names. An empty session would be refused as a mismatch long before the
     * cross-store seam, which is the thing under test.
     */
    private fun session(ids: Ids, epoch: Int = 0, workspace: String? = null): JSONObject {
        val message = JSONObject().put("id", ids.message).put("role", "user")
            .put("text", "hello").put("created_at", STAMP)
            .put("attachments", JSONArray())
        val attempt = JSONObject().put("schema_version", 3)
            .put("attempt_id", ids.attempt).put("turn_id", ids.task)
            .put("status", "prepared")
            .put("visible_message_ids", JSONArray().put(ids.message))
            // A prepared attempt with no rounds carries no history digest:
            // the digest only becomes meaningful once a round was sent, and
            // the session schema refuses one without that provenance.
            .put("visible_history_sha256", JSONObject.NULL)
            .put("attachment_ids", JSONArray())
            .put("model_id", MODEL).put("thinking_mode", THINKING)
            .put("context_disposition", "unbound")
            .put("context_project_id", JSONObject.NULL)
            .put("project_context", JSONObject.NULL)
            .put("active_round", JSONObject.NULL).put("rounds", JSONArray())
            .put("assistant_message_id", JSONObject.NULL)
            .put("failure_code", JSONObject.NULL)
            .put("created_at", STAMP).put("updated_at", STAMP)
            .put("workspace_id", workspace ?: JSONObject.NULL)
            .put("workspace_binding_revision", if (workspace == null) JSONObject.NULL else 1)
            .put("journal_revision", 0).put("agent", JSONObject.NULL)
        val conversation = JSONObject().put("id", ids.conversation)
            .put("project_id", JSONObject.NULL)
            .put("workspace_id", workspace ?: JSONObject.NULL)
            .put("runtime_context_id", JSONObject.NULL)
            .put("project_context", JSONObject.NULL)
            .put("title", "t").put("title_source", "auto")
            .put("model_id", MODEL).put("thinking_mode", THINKING)
            .put("messages", JSONArray().put(message))
            // An attempt must belong to a turn, and the turn's user message
            // is what fixes the visible history the attempt may claim.
            .put("turns", JSONArray().put(JSONObject().put("schema_version", 1)
                .put("turn_id", ids.task).put("user_message_id", ids.message)
                .put("attempt_ids", JSONArray().put(ids.attempt))
                .put("created_at", STAMP)))
            .put("attempts", JSONArray().put(attempt))
            .put("created_at", STAMP).put("updated_at", STAMP)
            .put(
                "workspace_binding",
                if (workspace == null) JSONObject.NULL
                else JSONObject().put("schema_version", 1)
                    .put("workspace_id", workspace).put("binding_revision", 1)
                    .put("project_id", JSONObject.NULL),
            )
            .put("workspace_bootstrap_state", "none")
            .put("agent_grants", JSONArray())
        return JSONObject().put("schema_version", 9)
            .put("workspace_authority_outbox", JSONArray())
            .put("agent_transcript_cleanup_outbox", JSONArray())
            .put("project_context_destructive_epoch", epoch)
            .put("project_context_destructive_transition", JSONObject.NULL)
            .put("active_conversation_id", JSONObject.NULL)
            .put("conversations", JSONArray().put(conversation))
            .put("messages", JSONArray())
            .put("session_events", JSONArray())
            .put("preferences", JSONObject().put("schema_version", 1)
                .put("theme_mode", "system").put("locale", "system")
                .put("default_model", MODEL).put("thinking_mode", THINKING)
                .put("tool_permission", "read-only").put("show_reasoning", false)
                .put("auto_expand_tools", false)
                .put("confirm_destructive_file_actions", true))
    }

    /**
     * Commits a session carrying `ids` and answers the checkpoint. The bytes
     * are canonicalised first: the prepared-attempt store reads the committed
     * session's *exact* bytes and refuses anything that is not its own
     * canonical form, which is also what the real controller writes.
     */
    private fun commitSession(store: AndroidSessionStore, ids: Ids, epoch: Int = 0,
                              expected: JSONObject? = null,
                              workspace: String? = null): JSONObject {
        val candidate = RishAgentCoreNative.canonical(session(ids, epoch, workspace).toString())
            ?: error("the session fixture is not canonicalisable")
        val reply = store.persist(JSONObject().put("schema_version", 1)
            .put("operation_id", UUID.randomUUID().toString())
            .put("expected", expected ?: JSONObject().put("schema_version", 1)
                .put("kind", "missing"))
            .put("candidate_json", candidate))
        assertEquals("committed", reply.getString("status"))
        return reply.getJSONObject("snapshot")
    }

    private fun request(snapshot: JSONObject, ids: Ids, workspace: String? = null): JSONObject {
        val cas = JSONObject().put("schema_version", 1)
            .put("conversation_id", ids.conversation).put("task_id", ids.task)
            .put("attempt_id", ids.attempt)
            .put("expected_controller_generation", 0)
            .put("expected_journal_revision", 0)
            .put("expected_session_generation", snapshot.getLong("generation"))
            .put("expected_session_sha256", snapshot.getString("session_sha256"))
        val checkpoint = JSONObject().put("schema_version", 1)
            .put("journal_revision", 0)
            .put("session_generation", snapshot.getLong("generation"))
            .put("session_sha256", snapshot.getString("session_sha256"))
        return JSONObject().put("schema_version", 2)
            .put("operation_id", ids.operation)
            .put("controller_cas", cas).put("committed_checkpoint", checkpoint)
            .put("task_id", ids.task).put("conversation_id", ids.conversation)
            .put("attempt_id", ids.attempt)
            .put("workspace_id", workspace ?: JSONObject.NULL)
            .put("project_id", JSONObject.NULL)
            .put("workspace_binding_revision", if (workspace == null) JSONObject.NULL else 1)
            .put("transport_schema_version", 2)
            .put("model", MODEL).put("thinking_mode", THINKING)
            .put("visible_message_ids", JSONArray().put(ids.message))
            .put("visible_history_sha256", visibleDigest())
            .put("visible_message_count", 1)
            .put("project_context_sha256", JSONObject.NULL)
            .put("registry_version", 2)
            .put("expected_policy_version", JSONObject.NULL)
            .put("expected_transcript", JSONObject.NULL)
    }

    private data class Ids(
        val operation: String = UUID.randomUUID().toString(),
        val task: String = UUID.randomUUID().toString(),
        val conversation: String = UUID.randomUUID().toString(),
        val attempt: String = UUID.randomUUID().toString(),
        val message: String = UUID.randomUUID().toString(),
    )

    /**
     * The same fixture with a real workspace registry behind it, so a rooted
     * request resolves against a root that actually exists on this device.
     */
    private fun <T> rootedFixture(
        body: (AndroidSessionStore, AndroidAgentWal, AndroidPreparedAttemptStore, AndroidWorkspaceRegistry) -> T,
    ): T {
        assertTrue("the agent core is not staged", RishAgentCoreNative.available)
        val name = "prepared-session-${UUID.randomUUID()}.db"
        val root = walRoot()
        val workspaceRoot = File(context.noBackupFilesDir, "prepared-ws-${UUID.randomUUID()}")
            .apply { mkdirs() }
        val sessions = AndroidSessionStore(context, name)
        try {
            val wal = AndroidAgentWal(root)
            val workspaces = AndroidWorkspaceRegistry(workspaceRoot)
            val store = AndroidPreparedAttemptStore(
                sessions, wal, AndroidAgentRootResolver(workspaces),
            )
            return body(sessions, wal, store, workspaces)
        } finally {
            sessions.close()
            context.deleteDatabase(name)
            root.deleteRecursively()
            workspaceRoot.deleteRecursively()
        }
    }

    private fun <T> fixture(body: (AndroidSessionStore, AndroidAgentWal, AndroidPreparedAttemptStore) -> T): T {
        assertTrue("the agent core is not staged", RishAgentCoreNative.available)
        val name = "prepared-session-${UUID.randomUUID()}.db"
        val root = walRoot()
        val sessions = AndroidSessionStore(context, name)
        try {
            val wal = AndroidAgentWal(root)
            return body(sessions, wal, AndroidPreparedAttemptStore(sessions, wal))
        } finally {
            sessions.close()
            context.deleteDatabase(name)
            root.deleteRecursively()
        }
    }

    @Test fun aRootlessAttemptCommitsItsRejectionDurablyAndReplays() = fixture { sessions, wal, store ->
        val ids = Ids()
        val snapshot = commitSession(sessions, ids)
        val first = store.prepareAgentAttempt(request(snapshot, ids))
        // The rootless outcome, named so nobody reads this as success.
        assertEquals("not_agent", first.optString("status"))
        assertEquals("E_AGENT_NO_ROOT", first.optString("failure_code"))

        val state = wal.snapshot()
        val operations = state.getJSONArray("operations")
        assertEquals(1, operations.length())
        assertEquals("rejected", operations.getJSONObject(0).getString("state"))
        assertEquals("prepare_agent_attempt",
            operations.getJSONObject(0).getString("operation_kind"))
        assertEquals(1, state.getJSONArray("operation_results").length())
        // No authority and no transcript: a rootless attempt grants nothing.
        assertEquals(0, state.getJSONArray("authorities").length())
        assertEquals(0, state.getJSONArray("transcripts").length())

        // The same operation replays its stored result and writes nothing.
        val generation = wal.snapshot().getLong("generation")
        val replay = store.prepareAgentAttempt(request(snapshot, ids))
        assertEquals(first.toString(), replay.toString())
        assertEquals(generation, wal.snapshot().getLong("generation"))
        assertEquals(1, wal.snapshot().getJSONArray("operations").length())
    }

    /**
     * The seam itself: the session moves after the checkpoint was taken. The
     * attempt must not commit against a session that no longer exists, and the
     * caller must be able to recover by re-reading rather than being told the
     * request was malformed.
     */
    @Test fun aSessionThatMovedUnderTheAttemptIsAConflictAndWritesNothing() = fixture { sessions, wal, store ->
        val ids = Ids()
        val stale = commitSession(sessions, ids)
        // The controller re-commits the session between taking the checkpoint
        // and preparing the attempt.
        val moved = commitSession(sessions, ids, epoch = 1,
            expected = JSONObject().put("schema_version", 1).put("kind", "present")
                .put("snapshot", JSONObject().put("schema_version", 1)
                    .put("generation", stale.getLong("generation"))
                    .put("session_sha256", stale.getString("session_sha256"))))
        assertNotEquals(stale.getLong("generation"), moved.getLong("generation"))

        val before = wal.snapshot().getLong("generation")
        val result = store.prepareAgentAttempt(request(stale, ids))
        assertEquals("conflict", result.optString("status"))
        assertEquals("E_AGENT_CONFLICT", result.optString("failure_code"))
        // Nothing was written: the WAL never learned about this attempt.
        assertEquals(before, wal.snapshot().getLong("generation"))
    }

    /**
     * A crash after the WAL committed but before anything acted on the result
     * looks exactly like a fresh process. The committed operation has to be
     * found by a new store over the same files, not written a second time.
     */
    @Test fun aNewProcessFindsTheCommittedOperationRatherThanRepeatingIt() {
        assertTrue(RishAgentCoreNative.available)
        val name = "prepared-session-${UUID.randomUUID()}.db"
        val root = walRoot()
        try {
            val ids = Ids()
            val snapshot: JSONObject
            run {
                val sessions = AndroidSessionStore(context, name)
                val wal = AndroidAgentWal(root)
                snapshot = commitSession(sessions, ids)
                AndroidPreparedAttemptStore(sessions, wal)
                    .prepareAgentAttempt(request(snapshot, ids))
                sessions.close()
            }
            // Fresh objects over the same database and the same file, as a
            // relaunch would build them.
            val sessions = AndroidSessionStore(context, name)
            val wal = AndroidAgentWal(root)
            val generation = wal.snapshot().getLong("generation")
            assertEquals(1, wal.snapshot().getJSONArray("operations").length())
            val replay = AndroidPreparedAttemptStore(sessions, wal)
                .prepareAgentAttempt(request(snapshot, ids))
            assertEquals("not_agent", replay.optString("status"))
            assertEquals(generation, wal.snapshot().getLong("generation"))
            assertEquals(1, wal.snapshot().getJSONArray("operations").length())
            sessions.close()
        } finally {
            context.deleteDatabase(name)
            root.deleteRecursively()
        }
    }

    /**
     * A request naming a workspace the *session* does not name is refused as a
     * **conflict**, not as a stale root — and the order is the point.
     * `session_matches` runs before the root is consulted, so a request that
     * disagrees with the stored attempt is answered on that disagreement, even
     * when the workspace it names is one this device could resolve.
     *
     * The root-stale branch is exercised by the rooted tests below, where the
     * session and the request agree and it is the *root* that cannot be
     * proven.
     */
    @Test fun anAttemptNamingAWorkspaceIsRefusedAndWritesNothing() = fixture { sessions, wal, store ->
        val ids = Ids()
        val snapshot = commitSession(sessions, ids)
        val rooted = request(snapshot, ids)
            .put("workspace_id", UUID.randomUUID().toString())
            .put("workspace_binding_revision", 1)
        val before = wal.snapshot().getLong("generation")
        val result = store.prepareAgentAttempt(rooted)
        assertEquals("conflict", result.optString("status"))
        assertEquals("E_AGENT_CONFLICT", result.optString("failure_code"))
        assertEquals(before, wal.snapshot().getLong("generation"))
    }

    /**
     * The bridge module serves the operation rather than rejecting it, and the
     * answer that reaches JS is the core's own: `not_agent` / `E_AGENT_NO_ROOT`
     * for a rootless attempt. `implemented` stays false, because one served
     * operation is not the whole agent surface and the JS layer reads that
     * constant as "all of it is here".
     */
    @Test fun theBridgeServesAPreparedAttemptOnTheRealRuntimeState() {
        assertTrue(RishAgentCoreNative.available)
        val runtime = AndroidRuntimeState.get(context)
        val ids = Ids()
        // The shared session store is whatever this device already has, so the
        // checkpoint is taken from a session committed through it.
        val snapshot = commitSession(runtime.sessions, ids)
        val before = runtime.agentWal.snapshot().getLong("generation")
        val result = runtime.preparedAttempts.prepareAgentAttempt(request(snapshot, ids))
        assertEquals("not_agent", result.optString("status"))
        assertEquals("E_AGENT_NO_ROOT", result.optString("failure_code"))
        // It is a durable commit, not an in-memory answer.
        assertNotEquals(before, runtime.agentWal.snapshot().getLong("generation"))
        val operations = runtime.agentWal.snapshot().getJSONArray("operations")
        assertEquals(
            "rejected",
            operations.getJSONObject(operations.length() - 1).getString("state"),
        )
    }

    @Test fun anAttemptHasNoAuthorityToFind() = fixture { sessions, _, store ->
        val ids = Ids()
        val snapshot = commitSession(sessions, ids)
        store.prepareAgentAttempt(request(snapshot, ids))
        assertNull(store.authorityFor(ids.task, ids.attempt))
    }

    /** The digest the core takes over the visible history, from the core. */
    private fun visibleDigest(): String = RishAgentCoreNative.hash(
        "visible-history", JSONObject().put("messages", JSONArray().put(
            JSONObject().put("role", "user").put("content", "hello")
                .put("attachments", JSONArray()))))

    private companion object {
        const val MODEL = "deepseek-v4-flash"
        const val THINKING = "off"
        const val STAMP = "2026-09-16T00:00:00.000Z"
    }

    /**
     * The first prepared attempt on Android that is *not* a rejection. A
     * session bound to a workspace this device actually holds resolves to a
     * root, and the core commits an authority and a transcript against it.
     *
     * Everything before this exercised the cross-store seam on the rejection
     * path only. This is the same seam on the path that writes.
     */
    @Test fun aRootedAttemptResolvesItsWorkspaceAndPreparesForReal() = rootedFixture { sessions, wal, store, workspaces ->
        val workspace = workspaces.create("Scratch").getString("workspace_id")
        val ids = Ids()
        val snapshot = commitSession(sessions, ids, workspace = workspace)
        val before = wal.snapshot().getLong("generation")
        val result = store.prepareAgentAttempt(request(snapshot, ids, workspace))
        assertEquals("prepared", result.optString("status"))
        assertTrue(result.isNull("failure_code"))
        // The authority names the root that was resolved, not one invented
        // here: its fingerprint is the registry's.
        val state = wal.snapshot()
        assertTrue(state.getLong("generation") > before)
        val authorities = state.getJSONArray("authorities")
        assertEquals(1, authorities.length())
        val authority = authorities.getJSONObject(0)
        assertEquals("prepared", authority.getString("state"))
        val root = authority.getJSONObject("root")
        assertEquals(workspace, root.getString("workspace_id"))
        assertEquals(1, root.getInt("workspace_binding_revision"))
        assertEquals(
            workspaces.fingerprintFor(workspace),
            root.getString("root_fingerprint_sha256"),
        )
        assertEquals(1, state.getJSONArray("transcripts").length())
    }

    /**
     * The same request against a root that can no longer be proven is stale,
     * and nothing is written. A binding the device cannot back is never
     * quietly downgraded to a rootless attempt: that would run the turn
     * somewhere the person did not ask for.
     */
    @Test fun aRootedAttemptWhoseRootCannotBeProvenIsStale() = rootedFixture { sessions, wal, store, workspaces ->
        val workspace = workspaces.create("Scratch").getString("workspace_id")
        val ids = Ids()
        val snapshot = commitSession(sessions, ids, workspace = workspace)
        // Break the authority so the root stops proving out.
        val file = File(File(workspaces.root, "bindings"), "owned-$workspace-r1.json")
        val authority = JSONObject(file.readText())
        authority.put("inode_id", (authority.getString("inode_id").toLong() + 1).toString())
        file.writeText(authority.toString())

        val before = wal.snapshot().getLong("generation")
        val result = store.prepareAgentAttempt(request(snapshot, ids, workspace))
        assertEquals("conflict", result.optString("status"))
        assertEquals("E_AGENT_ROOT_STALE", result.optString("failure_code"))
        assertEquals(before, wal.snapshot().getLong("generation"))
    }

    /**
     * A binding this device never held is stale too — the session may name
     * whatever the person chose on another device, and the registry is what
     * says whether it is here.
     */
    @Test fun aRootedAttemptNamingAnUnknownWorkspaceIsStale() = rootedFixture { sessions, wal, store, _ ->
        val workspace = UUID.randomUUID().toString()
        val ids = Ids()
        val snapshot = commitSession(sessions, ids, workspace = workspace)
        val before = wal.snapshot().getLong("generation")
        val result = store.prepareAgentAttempt(request(snapshot, ids, workspace))
        assertEquals("conflict", result.optString("status"))
        assertEquals("E_AGENT_ROOT_STALE", result.optString("failure_code"))
        assertEquals(before, wal.snapshot().getLong("generation"))
    }

    /**
     * A store with no resolver behind it can prove no root at all, so every
     * rooted request is stale. That is the build this platform shipped until
     * the registry existed, and it stays correct rather than crashing.
     */
    @Test fun aStoreWithNoResolverTreatsEveryRootAsStale() = rootedFixture { sessions, wal, _, workspaces ->
        val workspace = workspaces.create("Scratch").getString("workspace_id")
        val ids = Ids()
        val snapshot = commitSession(sessions, ids, workspace = workspace)
        val rootless = AndroidPreparedAttemptStore(sessions, wal)
        val result = rootless.prepareAgentAttempt(request(snapshot, ids, workspace))
        assertEquals("conflict", result.optString("status"))
        assertEquals("E_AGENT_ROOT_STALE", result.optString("failure_code"))
    }

}
