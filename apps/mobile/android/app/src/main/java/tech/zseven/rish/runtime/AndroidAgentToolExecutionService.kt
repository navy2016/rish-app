package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * `execute_agent_tool` on Android.
 *
 * Mirrors modules/rish/ios/Sources/AgentToolExecutionService.mm. The shared
 * core decides everything about the execution -- whether the request is
 * well-formed, whether the committed session is still the one it names, every
 * pre-execution check over the WAL views, the ledger CAS, the arguments handed
 * to the executor, how an effect settles and what the reply says. Its own
 * module documents the split: *the host keeps the WAL operation relation, the
 * session load, the root proofs, liveness, the executors and the ledger calls*,
 * and that is exactly what is left here.
 *
 * The one rule this file owns is that it owns none. Every branch below comes
 * back from `tool_execution`, and a branch it does not recognise is a refusal
 * rather than a guess.
 */
internal class AndroidAgentToolExecutionService(
    private val wal: AndroidAgentWal,
    private val sessions: AndroidSessionStore,
    private val prepared: AndroidPreparedAttemptStore,
    private val ledger: AndroidAgentExecutionLedger,
    private val roots: AndroidAgentRootResolver,
    private val workspaceTools: AndroidWorkspaceToolExecutor,
    private val liveTasks: AndroidLiveTasks,
) {
    class Refused(val code: String) : Exception(code)

    private fun decide(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.toolExecutionReduce(envelope.toString())
            ?: throw Refused(NATIVE)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) throw Refused(codeFor(parsed.optInt("error", 2)))
        return parsed
    }

    /**
     * The store's numeric refusals become the codes JavaScript branches on.
     * An unrecognised one is `E_AGENT_NATIVE` rather than a number nobody
     * downstream knows how to read.
     */
    private fun codeFor(error: Int): String = when (error) {
        1 -> "E_AGENT_BAD_ARGUMENTS"
        3 -> "E_AGENT_CONFLICT"
        4 -> "E_AGENT_PERSISTENCE"
        else -> NATIVE
    }

    /**
     * Runs one tool call. The reply is whatever the core said the reply is:
     * a conflict, a result already settled, a result for a call another owner
     * is running, or the result of doing the work now.
     */
    fun execute(request: JSONObject): JSONObject {
        // Shape first, so a malformed request never reaches a view of the WAL.
        decide(JSONObject().put("op", "request").put("request", request))

        val taskId = request.optString("task_id")
        val attemptId = request.optString("attempt_id")
        val root = request.optJSONObject("root") ?: throw Refused(BAD_ARGUMENTS)

        val conversation = sessions.load().optJSONObject("conversation")
        val state = wal.snapshot()
        val authority = prepared.authorityFor(taskId, attemptId)
        // Whether the root still proves out is the resolver's answer, and the
        // core only needs to know that it did.
        val rootOk = roots.resolve(
            workspaceId = root.optString("workspace_id").takeIf { it.isNotEmpty() },
            projectId = root.opt("project_id")?.takeIf { it != JSONObject.NULL } as? String,
            bindingRevision = root.opt("binding_revision") as? Int,
        ) != null

        val view = JSONObject()
            .put("op", "precheck").put("request", request)
            .put("authority", authority ?: JSONObject.NULL)
            .put("batches", state.optJSONArray("batches") ?: JSONArray())
            .put("ledger", state.optJSONArray("ledger") ?: JSONArray())
            .put("operation_results", state.optJSONArray("operation_results") ?: JSONArray())
            .put("conversation", conversation ?: JSONObject.NULL)
            .put("root_ok", rootOk)
            .put("dispatch_state", dispatchState(state, request))
            .put("owner_alive", liveTasks.isAlive(taskId, AndroidAgentWal.launchId))
        val precheck = decide(view)

        precheck.optJSONObject("conflict")?.let { return it }
        precheck.optJSONObject("commit")?.let { return it.optJSONObject("result") ?: it }
        precheck.optJSONObject("result")?.let { return it }
        if (!precheck.optBoolean("proceed")) throw Refused(NATIVE)

        val row = rowFor(state, request) ?: throw Refused(CONFLICT)
        return run(request, row, state)
    }

    /**
     * Claim, dispatch, do the work, settle. The order is the point: a row is
     * marked dispatched **before** the effect, so a crash in between leaves a
     * row that says an effect may have happened rather than one that says it
     * did not.
     */
    private fun run(request: JSONObject, row: JSONObject, state: JSONObject): JSONObject {
        val claimCas = decide(
            JSONObject().put("op", "execution_cas").put("request", request)
                .put("row", row).put("state", "intent"),
        ).optJSONObject("cas") ?: throw Refused(CONFLICT)
        val owner = ownerFor(request)
        ledger.claim(claimCas, owner) ?: throw Refused(CONFLICT)

        val claimed = rowFor(wal.snapshot(), request) ?: throw Refused(CONFLICT)
        val dispatchCas = decide(
            JSONObject().put("op", "execution_cas").put("request", request)
                .put("row", claimed).put("state", "claimed"),
        ).optJSONObject("cas") ?: throw Refused(CONFLICT)
        ledger.markDispatched(dispatchCas) ?: throw Refused(CONFLICT)

        val arguments = decide(
            JSONObject().put("op", "arguments").put("request", request)
                .put("messages", state.optJSONArray("transcripts") ?: JSONArray()),
        ).optJSONObject("arguments") ?: throw Refused(BAD_ARGUMENTS)

        val began = System.currentTimeMillis()
        val effect = effectOf(request, arguments)
        val duration = System.currentTimeMillis() - began

        val dispatched = rowFor(wal.snapshot(), request) ?: throw Refused(CONFLICT)
        val plan = decide(
            JSONObject().put("op", "settlement").put("request", request)
                .put("row", dispatched).put("effect", effect)
                .put("duration_ms", duration),
        )
        val settlement = plan.optJSONObject("settlement") ?: throw Refused(NATIVE)
        val settleCas = decide(
            JSONObject().put("op", "execution_cas").put("request", request)
                .put("row", dispatched).put("state", "dispatched"),
        ).optJSONObject("cas") ?: throw Refused(CONFLICT)
        if (ledger.settle(settleCas, settlement) == null) {
            // The effect happened and the ledger did not record it. That is
            // not a failure to execute; it is a failure to remember, and the
            // core spells the difference.
            return decide(
                JSONObject().put("op", "settle_failed").put("request", request)
                    .put("row", dispatched).put("plan", plan).put("effect", effect),
            ).optJSONObject("result") ?: throw Refused(PERSISTENCE)
        }
        val settled = rowFor(wal.snapshot(), request) ?: throw Refused(CONFLICT)
        return decide(
            JSONObject().put("op", "safe_result").put("request", request).put("row", settled),
        ).optJSONObject("result") ?: throw Refused(NATIVE)
    }

    /**
     * Only the three workspace tools run here. A name the registry knows but
     * this platform cannot serve -- a git tool, a runtime program, a guest CGI
     * handler -- becomes the core's generic failure rather than a crash or a
     * silence, so the round sees a settled call it can carry on from.
     */
    private fun effectOf(request: JSONObject, arguments: JSONObject): JSONObject {
        val name = request.optString("name")
        if (name !in workspaceTools.tools) {
            return decide(
                JSONObject().put("op", "generic_failure").put("request", request),
            ).optJSONObject("effect") ?: throw Refused(NATIVE)
        }
        return try {
            workspaceTools.execute(name, arguments, request.optJSONObject("root") ?: JSONObject())
        } catch (refused: AndroidWorkspaceToolExecutor.Refused) {
            decide(JSONObject().put("op", "generic_failure").put("request", request))
                .optJSONObject("effect") ?: throw Refused(NATIVE)
        }
    }

    private fun rowFor(state: JSONObject, request: JSONObject): JSONObject? =
        decide(
            JSONObject().put("op", "row").put("request", request)
                .put("ledger", state.optJSONArray("ledger") ?: JSONArray()),
        ).optJSONObject("row")

    private fun dispatchState(state: JSONObject, request: JSONObject): String =
        rowFor(state, request)?.optString("state") ?: "absent"

    private fun ownerFor(request: JSONObject): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("task_id", request.optString("task_id"))
        .put("launch_id", AndroidAgentWal.launchId)
        .put("native_task_id", request.optString("operation_id"))
        .put("owner_generation", 1)
        .put("heartbeat_at", RuntimeJson.now())

    private companion object {
        const val NATIVE = "E_AGENT_NATIVE"
        const val CONFLICT = "E_AGENT_CONFLICT"
        const val BAD_ARGUMENTS = "E_AGENT_BAD_ARGUMENTS"
        const val PERSISTENCE = "E_AGENT_PERSISTENCE"
    }
}
