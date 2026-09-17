package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * `prepare_agent_tool_batch` on Android.
 *
 * Mirrors modules/rish/ios/Sources/AgentToolBatchService.mm. This is the step
 * that turns a finished round's raw tool calls into ledger rows an execution
 * can claim, and it owns no rules: the request shape, the preparation gate,
 * the per-call analysis, the executor-outcome mapping, the final authority
 * check and the ledger-failure rejection all come back from `tool_batch`,
 * whose own module names the split -- *the host keeps the WAL operation
 * relation, the session load, the root proofs, the executors' preparation
 * probes and the denied-approval transaction, and calls back with what it
 * observed*.
 *
 * The probe is the interesting half. For every call the core says has an
 * executor, the host asks that executor what the call asserts about the world
 * right now, and hands the answer back. A probe that refuses is an outcome
 * too: the core turns it into a rejection the round can carry rather than a
 * failure that loses the batch.
 */
internal class AndroidAgentToolBatchService(
    private val wal: AndroidAgentWal,
    private val sessions: AndroidSessionStore,
    private val prepared: AndroidPreparedAttemptStore,
    private val ledger: AndroidAgentExecutionLedger,
    private val roots: AndroidAgentRootResolver,
    private val workspaceTools: AndroidWorkspaceToolExecutor,
) {
    class Refused(val code: String) : Exception(code)

    private fun decide(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.toolBatchReduce(envelope.toString())
            ?: throw Refused(NATIVE)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) throw Refused(codeFor(parsed.optInt("error", 2)))
        return parsed
    }

    private fun codeFor(error: Int): String = when (error) {
        1 -> "E_AGENT_BAD_ARGUMENTS"
        3 -> "E_AGENT_CONFLICT"
        4 -> "E_AGENT_PERSISTENCE"
        else -> NATIVE
    }

    fun prepare(request: JSONObject): JSONObject {
        decide(JSONObject().put("op", "prepare_request").put("request", request))

        val taskId = request.optString("task_id")
        val attemptId = request.optString("attempt_id")
        val root = request.optJSONObject("root") ?: throw Refused(BAD_ARGUMENTS)

        val conversation = sessions.load().optJSONObject("conversation")
        val sessionOk = decide(
            JSONObject().put("op", "prepare_request").put("request", request),
        ).let { conversation != null }
        val resolved = roots.resolve(
            workspaceId = root.optString("workspace_id").takeIf { it.isNotEmpty() },
            projectId = root.opt("project_id")?.takeIf { it != JSONObject.NULL } as? String,
            bindingRevision = root.opt("binding_revision") as? Int,
        )
        val state = wal.snapshot()
        val authority = prepared.authorityFor(taskId, attemptId)
        val round = roundFor(state, request)

        val gate = decide(
            JSONObject().put("op", "prepare_gate").put("request", request)
                .put("authority", authority ?: JSONObject.NULL)
                .put("round", round ?: JSONObject.NULL)
                .put("session_ok", sessionOk)
                .put("root_ok", resolved != null),
        )
        if (!gate.optBoolean("proceed")) return gate

        val analysis = decide(
            JSONObject().put("op", "prepare_calls").put("request", request)
                .put("round", round ?: JSONObject.NULL)
                .put("messages", state.optJSONArray("transcripts") ?: JSONArray())
                .put("authority", authority ?: JSONObject.NULL)
                .put("grants", resolved?.optJSONArray("capabilities") ?: JSONArray()),
        )
        val calls = analysis.optJSONArray("calls") ?: return analysis

        // The probes. One per call, in order, and the order is kept because
        // the core reads the outcomes positionally.
        val outcomes = JSONArray()
        for (index in 0 until calls.length()) {
            outcomes.put(probe(calls.optJSONObject(index), root))
        }

        val finished = decide(
            JSONObject().put("op", "prepare_finish").put("request", request)
                .put("calls", calls).put("outcomes", outcomes),
        )
        val preparedCalls = finished.optJSONArray("prepared_calls") ?: JSONArray()

        // The authority is read again after the probes: they take time, and a
        // batch may only be written against the authority it started under.
        val finalAuthority = prepared.authorityFor(taskId, attemptId)
        val final = decide(
            JSONObject().put("op", "prepare_final").put("request", request)
                .put("authority", authority ?: JSONObject.NULL)
                .put("final_authority", finalAuthority ?: JSONObject.NULL)
                .put("started_authority_revision", authority?.opt("authority_revision") ?: JSONObject.NULL)
                .put("request_sha256", JSONObject.NULL)
                .put("prepared_calls", preparedCalls)
                .put("mutation_batch", finished.optBoolean("mutation_batch")),
        )
        val internal = final.optJSONObject("internal") ?: return final

        val tokens = (0 until preparedCalls.length()).map { UUID.randomUUID().toString() }
        return ledger.prepareToolBatch(internal, tokens) ?: decide(
            JSONObject().put("op", "prepare_ledger_failure").put("request", request)
                .put("native_code", 3).put("prepared_calls", preparedCalls),
        ).optJSONObject("rejected") ?: throw Refused(PERSISTENCE)
    }

    /**
     * What one call asserts about the world right now. A call the core gave no
     * executor is not probed; a probe that refuses becomes an outcome the core
     * turns into a rejection, so one bad call does not lose the batch.
     */
    private fun probe(call: JSONObject?, root: JSONObject): JSONObject {
        if (call == null) return JSONObject()
        if (call.opt("executor") == null || call.opt("executor") == JSONObject.NULL) {
            return JSONObject()
        }
        if (!call.isNull("rejection")) return JSONObject()
        val name = call.optString("name")
        if (name !in workspaceTools.tools) {
            // Not servable here. The core's own invalid-argument mapping turns
            // this into the right rejection for the tool's family.
            return JSONObject().put("error", 1)
        }
        val arguments = call.optJSONObject("arguments") ?: JSONObject()
        return try {
            JSONObject().put("prepared", workspaceTools.prepare(name, arguments, root))
        } catch (refused: AndroidWorkspaceToolExecutor.Refused) {
            JSONObject().put("error", errorFor(refused.code))
        }
    }

    /** The executor's vocabulary back into the store codes the core reads. */
    private fun errorFor(code: String): Int = when (code) {
        "E_AGENT_CONFLICT" -> 3
        "E_AGENT_NOT_FOUND" -> 5
        "E_AGENT_PERSISTENCE" -> 4
        else -> 1
    }

    private fun roundFor(state: JSONObject, request: JSONObject): JSONObject? {
        val rounds = state.optJSONArray("rounds") ?: return null
        for (index in 0 until rounds.length()) {
            val round = rounds.optJSONObject(index) ?: continue
            if (AndroidJson.equal(round.opt("round_id"), request.opt("round_id"))) return round
        }
        return null
    }

    private companion object {
        const val NATIVE = "E_AGENT_NATIVE"
        const val BAD_ARGUMENTS = "E_AGENT_BAD_ARGUMENTS"
        const val PERSISTENCE = "E_AGENT_PERSISTENCE"
    }
}
