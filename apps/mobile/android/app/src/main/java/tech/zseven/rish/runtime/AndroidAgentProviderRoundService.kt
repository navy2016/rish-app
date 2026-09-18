package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * `complete_agent_round_v2` on Android.
 *
 * Mirrors modules/rish/ios/Sources/AgentProviderRoundService.mm, whose pure
 * half is already `provider_round` in the shared core. That module names the
 * split: *the host keeps the transport, credentials, the tool registry's
 * native descriptors, the root projection validator, and the two provider
 * digests* -- the digests because they are taken with `NSJSONSerialization`
 * and sorted keys, a different byte protocol from the crate's canonical JSON,
 * so they are passed in as host facts rather than recomputed.
 *
 * The round is the step that asks the model what to do next. What it reads,
 * what the model is shown, how a reply becomes tool calls, and what the
 * journal records are all the core's; calling the provider and writing the
 * row are this file's.
 *
 * **Streaming is not here.** iOS shows a round's text as it arrives; this
 * waits for the whole reply. A round still completes and its calls are still
 * journalled; the only thing missing is watching it happen.
 *
 * Tools do travel, on the chat-completions protocol. What the model is shown
 * is the registry's description of each tool the root carries, and what comes
 * back is read by the core: turning untrusted model output into calls is
 * `completion_response`'s rule, and the transport carries the provider's reply
 * for it rather than reading it here.
 */
internal class AndroidAgentProviderRoundService(
    private val sessions: AndroidSessionStore,
    private val prepared: AndroidPreparedAttemptStore,
    private val rounds: AndroidAgentRoundJournal,
    private val roots: AndroidAgentRootResolver,
    private val tools: AndroidAgentToolRegistry,
    private val transport: AndroidModelTransport,
    private val wal: AndroidAgentWal,
) {
    class Refused(val code: String) : Exception(code)

    private fun decide(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.providerRoundReduce(envelope.toString())
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

    /**
     * The environment the round rules read: which harness serves a model, and
     * what time it is. Both are host facts -- a catalog this build shipped and
     * a clock -- and neither is the core's to invent.
     */
    private fun env(): JSONObject = JSONObject()
        .put("launch_id", AndroidAgentWal.launchId)
        .put("now", RuntimeJson.now())

    fun completeRound(request: JSONObject): JSONObject {
        val root = request.optJSONObject("root")
        val rootOk = root != null && roots.resolve(
            workspaceId = root.optString("workspace_id").takeIf { it.isNotEmpty() },
            projectId = root.opt("project_id")?.takeIf { it != JSONObject.NULL } as? String,
            bindingRevision = root.opt("binding_revision") as? Int,
        ) != null

        // Shape and locator first. A request the rules refuse never reaches
        // the journal, let alone the provider.
        val located = decide(
            JSONObject().put("op", "round_request").put("request", request)
                .put("root_ok", rootOk).put("env", env()),
        )
        val locator = located.optJSONObject("locator") ?: throw Refused(BAD_ARGUMENTS)

        val taskId = request.optString("task_id")
        val attemptId = request.optString("attempt_id")
        val authority = prepared.authorityFor(taskId, attemptId)
            ?: throw Refused(CONFLICT)
        val conversation = sessions.load().optJSONObject("conversation")
            ?: throw Refused(CONFLICT)

        val state = wal.snapshot()
        val row = rowFor(state, locator) ?: throw Refused(CONFLICT)
        val cas = decide(
            JSONObject().put("op", "round_cas").put("row", row),
        ).optJSONObject("cas") ?: throw Refused(CONFLICT)

        // Claimed and marked dispatched before the provider is called, so a
        // crash during the call leaves a round that may have happened rather
        // than one that plainly did not.
        rounds.claim(cas, ownerFor(request)) ?: throw Refused(CONFLICT)
        val claimed = rowFor(wal.snapshot(), locator) ?: throw Refused(CONFLICT)
        val dispatchCas = decide(
            JSONObject().put("op", "round_cas").put("row", claimed),
        ).optJSONObject("cas") ?: throw Refused(CONFLICT)
        rounds.markDispatched(dispatchCas) ?: throw Refused(CONFLICT)

        val body = decide(
            JSONObject().put("op", "transcript_body")
                .put("messages", state.optJSONArray("transcripts") ?: JSONArray()),
        ).optJSONArray("messages") ?: JSONArray()

        // What the model is shown. The registry decides which tools a root
        // carries and what each one is; the core turns a descriptor into the
        // description a model sees, so neither this file nor the transport
        // invents anything a tool can be asked to do.
        val registry = tools.registryForRoot(root ?: JSONObject())
        val declared = JSONArray()
        val names = registry.optJSONArray("tools") ?: JSONArray()
        for (index in 0 until names.length()) {
            val name = names.optJSONObject(index)?.optString("name")
                ?: names.optString(index).takeIf { it.isNotEmpty() }
                ?: continue
            val described = decide(
                JSONObject().put("op", "tool_description")
                    .put("descriptor", tools.descriptorForTool(name, root ?: JSONObject())),
            ).optJSONObject("description")
            if (described != null) declared.put(described)
        }

        val reply = try {
            val envelope = JSONObject()
                .put("schema_version", 2)
                .put("harness_id", request.optString("harness_id"))
                .put("model", request.optString("model"))
                .put("round_id", request.optString("round_id"))
                .put("turn_id", request.optString("turn_id"))
                .put("attempt_id", request.optString("attempt_id"))
                .put("round_index", request.optInt("round_index"))
                .put("thinking_mode", request.optString("thinking_mode", "off"))
                .put("visible_history", body)
                .put("round_transcript", JSONArray())
                .put("project_context", JSONObject.NULL)
                .put("tools", declared)
            transport.execute(transport.prepare(envelope.toString()))
        } catch (_: Exception) {
            null
        }

        // Untrusted model output becomes calls here, by the core's rule and
        // not by reading fields off a provider's JSON in Kotlin.
        val parsed = if (reply == null) null else RishAgentCoreNative.completionResponseReduce(
            JSONObject().put("op", "parse").put("response", reply)
                .put("requested_model", request.optString("model"))
                .put("model_supported", true)
                .put("thinking_mode", request.optString("thinking_mode", "off"))
                .put("fallback_call_id", request.optString("round_id"))
                .toString(),
        )?.let { JSONObject(it) }?.takeIf { it.optBoolean("ok") }

        val status = if (reply == null || parsed == null) "failed_retryable" else "completed"
        val failure = decide(
            JSONObject().put("op", "round_failure_code").put("status", status),
        ).optString("failure_code", "")

        val dispatched = rowFor(wal.snapshot(), locator) ?: throw Refused(CONFLICT)
        val completeCas = decide(
            JSONObject().put("op", "round_cas").put("row", dispatched),
        ).optJSONObject("cas") ?: throw Refused(CONFLICT)
        val patch = JSONObject().put("status", status)
            .put("failure_code", if (failure.isEmpty()) JSONObject.NULL else failure)
            .put("reply", parsed?.opt("parsed") ?: JSONObject.NULL)
        rounds.complete(completeCas, patch) ?: throw Refused(PERSISTENCE)

        val settled = rowFor(wal.snapshot(), locator) ?: throw Refused(CONFLICT)
        return decide(
            JSONObject().put("op", "round_result").put("request", request)
                .put("row", settled).put("status", status)
                .put("failure_code", failure.ifEmpty { "E_AGENT_NATIVE" }),
        ).optJSONObject("result") ?: throw Refused(NATIVE)
    }

    private fun rowFor(state: JSONObject, locator: JSONObject): JSONObject? {
        val table = state.optJSONArray("rounds") ?: return null
        val key = decide(
            JSONObject().put("op", "locator_key").put("locator", locator),
        ).optString("key")
        for (index in 0 until table.length()) {
            val row = table.optJSONObject(index) ?: continue
            val candidate = decide(
                JSONObject().put("op", "locator_key")
                    .put("locator", row.optJSONObject("locator") ?: JSONObject()),
            ).optString("key")
            if (candidate == key) return row
        }
        return null
    }

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
