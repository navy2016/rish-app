package tech.zseven.rish.runtime

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Snapshot and commit receipt in one FULL-synchronous SQLite transaction.
 *
 * SQLite is the storage mechanism; every decision — what a request may look
 * like, whether a candidate is acceptable and what it digests to, whether this
 * operation already committed, whether `expected` is still the authority, and
 * what a query may conclude — belongs to the shared core, exactly as it does
 * on iOS. There is no second set of rules here to drift from it.
 */
internal class AndroidSessionStore(context: Context, name: String = "rish.sessions.v1.db") : SQLiteOpenHelper(context.applicationContext, name, null, 3) {
    companion object { val launchId: String = UUID.randomUUID().toString(); const val MAX_BYTES = 16 * 1024 * 1024 }
    override fun onConfigure(db: SQLiteDatabase) { db.execSQL("PRAGMA synchronous=FULL") }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE snapshot (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL, digest TEXT NOT NULL, candidate TEXT NOT NULL, writer TEXT NOT NULL)")
        // Commits only. A conflict is not an outcome an operation keeps: the
        // controller may retry the same operation once it has re-read the
        // authority, and a stored conflict would replay forever.
        db.execSQL("CREATE TABLE commits (operation TEXT PRIMARY KEY, generation INTEGER NOT NULL, digest TEXT NOT NULL)")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        check(oldVersion in 1..2 && newVersion == 3)
        // Preserve prototype snapshots while migrating their digest protocol.
        // Old receipts are dropped rather than translated: they were keyed by
        // the whole request's bytes and could carry a conflict, neither of
        // which the shared rules recognise, so they stay unobserved.
        db.rawQuery("SELECT candidate FROM snapshot WHERE id=1", null).use { cursor ->
            if (cursor.moveToFirst()) {
                db.execSQL("UPDATE snapshot SET digest=? WHERE id=1", arrayOf(candidateDigest(cursor.getString(0))))
            }
        }
        db.execSQL("DROP TABLE IF EXISTS operations")
        db.execSQL("CREATE TABLE IF NOT EXISTS commits (operation TEXT PRIMARY KEY, generation INTEGER NOT NULL, digest TEXT NOT NULL)")
    }

    /** The candidate's digest, as the shared core computes it. */
    private fun candidateDigest(candidate: String): String =
        RishAgentCoreNative.session(JSONObject().put("op", "candidate_digest"), candidate).getString("digest")

    private fun reference(generation: Long, digest: String) = JSONObject().put("schema_version", 1).put("generation", generation).put("session_sha256", digest)

    private fun load(db: SQLiteDatabase): JSONObject {
        db.rawQuery("SELECT generation,digest,candidate,writer FROM snapshot WHERE id=1", null).use { cursor ->
            if (!cursor.moveToFirst()) return JSONObject().put("schema_version", 1).put("status", "missing")
                .put("snapshot", JSONObject.NULL).put("session_json", JSONObject.NULL).put("writer_launch_instance_id", JSONObject.NULL).put("current_launch_instance_id", launchId)
            val candidate = cursor.getString(2)
            check(candidateDigest(candidate) == cursor.getString(1)) { "Corrupt session snapshot" }
            return JSONObject().put("schema_version", 1).put("status", "present")
                .put("snapshot", reference(cursor.getLong(0), cursor.getString(1))).put("session_json", candidate)
                .put("writer_launch_instance_id", cursor.getString(3)).put("current_launch_instance_id", launchId)
        }
    }
    @Synchronized fun load(): JSONObject = load(readableDatabase)

    /**
     * The state as the core reads it: the current snapshot and the whole
     * commit chain. SQLite keeps every commit, so the chain is never evicted
     * and a query can always prove an operation's absence.
     */
    private fun loadedState(db: SQLiteDatabase): JSONObject {
        db.rawQuery("SELECT generation,digest FROM snapshot WHERE id=1", null).use { cursor ->
            if (!cursor.moveToFirst()) return JSONObject().put("kind", "missing")
            val commits = JSONArray()
            db.rawQuery("SELECT operation,generation,digest FROM commits ORDER BY generation ASC", null).use { rows ->
                while (rows.moveToNext()) {
                    commits.put(JSONObject().put("schema_version", 1).put("operation_id", rows.getString(0))
                        .put("generation", rows.getLong(1)).put("session_sha256", rows.getString(2)))
                }
            }
            return JSONObject().put("kind", "present").put("generation", cursor.getLong(0))
                .put("session_sha256", cursor.getString(1)).put("recent_commits", commits)
        }
    }

    /**
     * Storage preserves opaque JSON bytes; it does not issue project, tool or
     * Agent authority. Those native APIs remain closed on Android, so a
     * candidate that carries their journals is refused here — a platform
     * policy on top of the shared acceptance rules, not a different reading of
     * them.
     *
     * **Workspace bindings are no longer among them.** Android has a workspace
     * registry now, so a conversation may name a `workspace_id` and carry a
     * `workspace_binding`; the shared schema already says what a well-formed
     * one looks like, and whether the binding can still be *proved* is decided
     * where it is used, not here. A session records what the person chose; the
     * root resolver decides what that is still worth.
     *
     * `project_id` and `project_context` stay refused: there is no project
     * subsystem to issue or verify them.
     */
    private fun refuseUnsupportedAuthority(parsed: JSONObject) {
        for (field in listOf("workspace_authority_outbox", "agent_transcript_cleanup_outbox", "session_events")) {
            require((parsed.optJSONArray(field)?.length() ?: 0) == 0) { "Native authority journals are not supported on Android yet" }
        }
        require(parsed.isNull("project_context_destructive_transition"))
        parsed.optJSONArray("conversations")?.let { conversations ->
            for (index in 0 until conversations.length()) {
                val conversation = conversations.getJSONObject(index)
                for (field in listOf("project_id", "project_context")) require(conversation.isNull(field))
                require((conversation.optJSONArray("agent_grants")?.length() ?: 0) == 0)
                conversation.optJSONArray("attempts")?.let { attempts ->
                    for (i in 0 until attempts.length()) require(attempts.getJSONObject(i).isNull("agent"))
                }
            }
        }
    }

    @Synchronized fun persist(request: JSONObject): JSONObject {
        RishAgentCoreNative.session(JSONObject().put("op", "cas_request").put("request", request))
        val candidate = request.getString("candidate_json")
        require(candidate.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
        // The core judges the candidate's bytes and answers with their digest;
        // an unacceptable candidate never reaches the transaction. The
        // catalogue facts come from this build, because only it knows them.
        val parsed = JSONObject(candidate)
        val digest = RishAgentCoreNative.session(JSONObject().put("op", "candidate")
            .put("env", AndroidSessionEnvironment.forCandidate(parsed)), candidate).getString("digest")
        refuseUnsupportedAuthority(parsed)
        val operation = request.getString("operation_id")
        val expected = request.getJSONObject("expected")
        val db = writableDatabase
        db.beginTransaction()
        try {
            val precheck = RishAgentCoreNative.session(JSONObject().put("op", "cas_precheck")
                .put("operation_id", operation).put("expected", expected)
                .put("candidate_digest", digest).put("state", loadedState(db)))
            when (precheck.getString("outcome")) {
                // An exact repeat: the same operation already committed these
                // very bytes, so it answers with what it committed then.
                "committed" -> {
                    val snapshot = precheck.getJSONObject("snapshot")
                    return JSONObject().put("schema_version", 1).put("status", "committed")
                        .put("snapshot", reference(snapshot.getLong("generation"), snapshot.getString("session_sha256")))
                }
                // Not written down: the controller may re-read and retry.
                "conflict" -> return JSONObject().put("schema_version", 1).put("status", "conflict")
                    .put("current", precheck.getJSONObject("current"))
            }
            val loaded = load(db)
            val generation = if (loaded.getString("status") == "missing") 1L else loaded.getJSONObject("snapshot").getLong("generation") + 1
            require(generation in 1..9007199254740991L)
            if (loaded.getString("status") == "present") db.delete("snapshot", "id=1", null)
            db.insertOrThrow("snapshot", null, ContentValues().apply {
                put("id", 1); put("generation", generation); put("digest", digest); put("candidate", candidate); put("writer", launchId)
            })
            db.insertOrThrow("commits", null, ContentValues().apply {
                put("operation", operation); put("generation", generation); put("digest", digest)
            })
            db.setTransactionSuccessful()
            return JSONObject().put("schema_version", 1).put("status", "committed").put("snapshot", reference(generation, digest))
        } finally { db.endTransaction() }
    }

    @Synchronized fun query(request: JSONObject): JSONObject {
        RishAgentCoreNative.session(JSONObject().put("op", "query_request").put("request", request))
        val reply = RishAgentCoreNative.session(JSONObject().put("op", "query_commit")
            .put("operation_id", request.getString("operation_id"))
            .put("state", loadedState(readableDatabase)))
        return reply.getJSONObject("result")
    }
}
