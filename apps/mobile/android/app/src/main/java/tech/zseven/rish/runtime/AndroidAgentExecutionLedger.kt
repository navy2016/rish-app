package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * The execution ledger, as a facade over the shared reducer
 * (`rish_agent_ledger_reduce`). This side owns the WAL transaction, answers
 * whether an owner is still alive in this process, collects the view — the
 * row, the attempt's dispatch markers, the bound and expected transcripts,
 * and the reservation, batch and authority records with their slots — and
 * applies the changes the reducer returns.
 */
internal class AndroidAgentExecutionLedger(
    private val wal: AndroidAgentWal,
    private val liveTasks: AndroidLiveTasks,
) {
    class Refused(val code: Int) : RuntimeException("E_AGENT_STORE_$code")

    private fun reduce(envelope: JSONObject): JSONObject {
        check(RishAgentCoreNative.available) { "the shared agent core is not staged in this build" }
        val reply = RishAgentCoreNative.ledgerReduce(envelope.toString()) ?: throw Refused(2)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) throw Refused(parsed.optInt("error", 2))
        return parsed
    }

    /** `{slot, record}` for every row the reducer may replace by position. */
    private fun slotted(rows: JSONArray?, keep: (JSONObject) -> Boolean): JSONArray {
        val slotted = JSONArray()
        if (rows == null) return slotted
        for (index in 0 until rows.length()) {
            val record = rows.optJSONObject(index) ?: continue
            if (keep(record)) slotted.put(JSONObject().put("slot", index).put("record", record))
        }
        return slotted
    }

    private fun transcriptIndex(transcripts: JSONArray?, reference: Any?): Int {
        if (transcripts == null || reference == null) return -1
        for (index in 0 until transcripts.length()) {
            if (AndroidJson.equal(transcripts.optJSONObject(index)?.opt("transcript_ref"), reference)) return index
        }
        return -1
    }

    private fun ownerAlive(owner: Any?): Boolean {
        val record = owner as? JSONObject ?: return false
        return liveTasks.isAlive(record.optString("native_task_id"), record.optString("launch_id"))
    }

    private fun apply(state: JSONObject, changes: JSONArray, rowIndex: Int) {
        for (index in 0 until changes.length()) {
            val change = changes.getJSONObject(index)
            when (change.optString("kind")) {
                "insert_ledger_row" -> {
                    val rows = state.optJSONArray("ledger") ?: JSONArray()
                    rows.put(change.getJSONObject("row"))
                    state.put("ledger", rows)
                }
                "replace_ledger_row" -> {
                    val rows = state.optJSONArray("ledger") ?: throw Refused(2)
                    if (rowIndex < 0 || rowIndex >= rows.length()) throw Refused(2)
                    rows.put(rowIndex, change.getJSONObject("row"))
                    state.put("ledger", rows)
                }
                "insert_dispatch_marker" -> {
                    val dispatch = state.optJSONArray("dispatch") ?: JSONArray()
                    dispatch.put(change.getJSONObject("marker"))
                    state.put("dispatch", dispatch)
                }
                "mark_dispatched" -> {
                    val dispatch = state.optJSONArray("dispatch") ?: throw Refused(2)
                    var marker = -1
                    for (cursor in 0 until dispatch.length()) {
                        val candidate = dispatch.optJSONObject(cursor) ?: continue
                        if (candidate.optString("kind") == "execution" &&
                            AndroidJson.equal(candidate.opt("locator"), change.opt("locator"))) {
                            marker = cursor; break
                        }
                    }
                    if (marker < 0) throw Refused(2)
                    dispatch.put(marker, JSONObject(dispatch.getJSONObject(marker).toString())
                        .put("dispatch_state", "dispatched"))
                    state.put("dispatch", dispatch)
                }
                "replace_transcript" -> {
                    val transcripts = state.optJSONArray("transcripts") ?: throw Refused(2)
                    val row = change.getJSONObject("row")
                    val at = transcriptIndex(transcripts, row.opt("transcript_ref"))
                    if (at < 0) throw Refused(2)
                    transcripts.put(at, row)
                    state.put("transcripts", transcripts)
                }
                "replace_reservation", "replace_batch", "replace_authority" -> {
                    val table = when (change.optString("kind")) {
                        "replace_reservation" -> "reservations"
                        "replace_batch" -> "batches"
                        else -> "authorities"
                    }
                    val records = state.optJSONArray(table) ?: throw Refused(2)
                    val slot = change.optInt("slot", -1)
                    if (slot < 0 || slot >= records.length()) throw Refused(2)
                    records.put(slot, change.getJSONObject("record"))
                    state.put(table, records)
                }
                else -> throw Refused(2)
            }
        }
    }

    private fun run(
        op: String,
        args: JSONObject,
        locator: Any?,
        taskId: Any?,
        attemptId: Any?,
        expectedTranscript: JSONObject?,
        argOwner: Any?,
        readOnly: Boolean,
        extraEnv: JSONObject? = null,
    ): JSONObject? {
        var output: JSONObject? = null
        val body: (JSONObject) -> Boolean = body@ { state ->
            val rows = state.optJSONArray("ledger") ?: JSONArray()
            var row: JSONObject? = null
            var rowIndex = -1
            var attemptRowCount = 0
            for (index in 0 until rows.length()) {
                val candidate = rows.optJSONObject(index) ?: continue
                if (row == null && locator != null && AndroidJson.equal(candidate.opt("locator"), locator)) {
                    row = candidate; rowIndex = index
                }
                if (attemptId != null &&
                    AndroidJson.equal(candidate.optJSONObject("locator")?.opt("attempt_id"), attemptId)) {
                    attemptRowCount += 1
                }
            }
            val dispatch = JSONArray()
            state.optJSONArray("dispatch")?.let { markers ->
                for (index in 0 until markers.length()) {
                    val marker = markers.optJSONObject(index) ?: continue
                    if (marker.optString("kind") == "execution" && attemptId != null &&
                        AndroidJson.equal(marker.optJSONObject("locator")?.opt("attempt_id"), attemptId)) {
                        dispatch.put(marker)
                    }
                }
            }
            val transcripts = state.optJSONArray("transcripts")
            // The bound transcript is the one the row names; an insert has no
            // row yet, so the intent argument names it instead.
            val bound = row?.opt("transcript_before")
                ?: args.optJSONObject("intent")?.opt("transcript_before")
            val boundIndex = transcriptIndex(transcripts,
                (bound as? JSONObject)?.opt("transcript_ref"))
            val expectedIndex = transcriptIndex(transcripts,
                expectedTranscript?.opt("transcript_ref"))
            val authorityTable = state.optJSONArray("authorities")
            val authorities: Any = if (authorityTable == null || authorityTable.length() == 0) {
                JSONObject.NULL
            } else {
                slotted(authorityTable) { record ->
                    taskId != null && attemptId != null &&
                        AndroidJson.equal(record.opt("task_id"), taskId) &&
                        AndroidJson.equal(record.opt("attempt_id"), attemptId)
                }
            }
            val env = JSONObject().put("launch_id", AndroidAgentWal.launchId)
                .put("now", AndroidClock.now()).put("attempt_row_count", attemptRowCount)
            extraEnv?.let { for (name in it.keys()) env.put(name, it.get(name)) }
            val result = reduce(JSONObject().put("op", op).put("args", args).put("env", env)
                .put("view", JSONObject()
                    .put("row", row ?: JSONObject.NULL)
                    .put("dispatch", dispatch)
                    .put("transcript", if (boundIndex < 0) JSONObject.NULL else transcripts!!.getJSONObject(boundIndex))
                    .put("expected_transcript", if (expectedIndex < 0) JSONObject.NULL else transcripts!!.getJSONObject(expectedIndex))
                    .put("reservations", slotted(state.optJSONArray("reservations")) { AndroidJson.equal(it.opt("attempt_id"), attemptId) })
                    .put("batches", slotted(state.optJSONArray("batches")) { AndroidJson.equal(it.opt("attempt_id"), attemptId) })
                    .put("authorities", authorities)
                    .put("arg_owner_alive", ownerAlive(argOwner))
                    .put("row_owner_alive", ownerAlive(row?.opt("owner")))))
            output = result.optJSONObject("output") ?: throw Refused(2)
            if (readOnly || !result.optBoolean("commit")) return@body false
            apply(state, result.optJSONArray("changes") ?: JSONArray(), rowIndex)
            true
        }
        if (readOnly) {
            body(wal.snapshot())
            return output
        }
        wal.transaction(body)
        return output
    }

    private fun locatorOf(container: JSONObject?): Any? = container?.opt("locator")

    fun insert(insertCas: JSONObject, intent: JSONObject): JSONObject? =
        run("insert", JSONObject().put("insert_cas", insertCas).put("intent", intent),
            locatorOf(insertCas), insertCas.opt("task_id"), insertCas.opt("attempt_id"),
            null, intent.opt("owner"), false)

    fun claim(cas: JSONObject, owner: JSONObject): JSONObject? =
        run("claim", JSONObject().put("cas", cas).put("owner", owner), locatorOf(cas),
            cas.optJSONObject("locator")?.opt("task_id"),
            cas.optJSONObject("locator")?.opt("attempt_id"), null, owner, false)

    fun cas(cas: JSONObject, patch: JSONObject): JSONObject? =
        run("cas", JSONObject().put("cas", cas).put("patch", patch), locatorOf(cas),
            cas.optJSONObject("locator")?.opt("task_id"),
            cas.optJSONObject("locator")?.opt("attempt_id"), null, null, false)

    fun markDispatched(cas: JSONObject): JSONObject? =
        run("mark_dispatched", JSONObject().put("cas", cas), locatorOf(cas),
            cas.optJSONObject("locator")?.opt("task_id"),
            cas.optJSONObject("locator")?.opt("attempt_id"), null, null, false)

    fun settle(cas: JSONObject, settlement: JSONObject): JSONObject? =
        run("settle", JSONObject().put("cas", cas).put("settlement", settlement), locatorOf(cas),
            cas.optJSONObject("locator")?.opt("task_id"),
            cas.optJSONObject("locator")?.opt("attempt_id"), null, null, false)

    fun cancel(cas: JSONObject, patch: JSONObject): JSONObject? =
        run("cancel", JSONObject().put("cas", cas).put("patch", patch), locatorOf(cas),
            cas.optJSONObject("locator")?.opt("task_id"),
            cas.optJSONObject("locator")?.opt("attempt_id"), null, null, false)

    /**
     * Writes a prepared tool batch and the ledger rows it implies, through
     * `rish_agent_ledger_batch_reduce`.
     *
     * The view is the whole attempt as the reducer needs to see it: the frozen
     * round, the attempt's batches and reservation, the transcript the request
     * names, the attempt's ledger rows and dispatch markers, the round's denied
     * calls, the authorities and the operation results. It is collected here
     * because reading the WAL is the host's job, and every decision over it is
     * the reducer's.
     *
     * `approvalTokens` are host-generated because the reducer has no
     * randomness. One per call that may need approval; the reducer takes what
     * it needs and ignores the rest.
     */
    fun prepareToolBatch(
        request: JSONObject,
        approvalTokens: List<String>,
    ): JSONObject? {
        var output: JSONObject? = null
        val taskId = request.opt("task_id")
        val attemptId = request.opt("attempt_id")
        val roundId = request.opt("round_id")
        val body: (JSONObject) -> Boolean = body@ { state ->
            val ledgerRows = JSONArray()
            state.optJSONArray("ledger")?.let { rows ->
                for (index in 0 until rows.length()) {
                    val row = rows.optJSONObject(index) ?: continue
                    if (AndroidJson.equal(row.optJSONObject("locator")?.opt("attempt_id"), attemptId)) {
                        ledgerRows.put(row)
                    }
                }
            }
            val dispatch = JSONArray()
            state.optJSONArray("dispatch")?.let { markers ->
                for (index in 0 until markers.length()) {
                    val marker = markers.optJSONObject(index) ?: continue
                    if (marker.optString("kind") == "execution" &&
                        AndroidJson.equal(marker.optJSONObject("locator")?.opt("attempt_id"), attemptId)) {
                        dispatch.put(marker)
                    }
                }
            }
            val rounds = JSONArray()
            state.optJSONArray("rounds")?.let { table ->
                for (index in 0 until table.length()) {
                    val round = table.optJSONObject(index) ?: continue
                    if (AndroidJson.equal(round.opt("round_id"), roundId)) rounds.put(round)
                }
            }
            val transcripts = state.optJSONArray("transcripts")
            val transcriptIndex = transcriptIndex(
                transcripts, request.optJSONObject("transcript")?.opt("transcript_ref"),
            )
            val authorityTable = state.optJSONArray("authorities")
            val authorities: Any = if (authorityTable == null) JSONObject.NULL else slotted(authorityTable) {
                AndroidJson.equal(it.opt("task_id"), taskId) &&
                    AndroidJson.equal(it.opt("attempt_id"), attemptId)
            }
            val operationResults = JSONArray()
            state.optJSONArray("operation_results")?.let { table ->
                for (index in 0 until table.length()) {
                    val record = table.optJSONObject(index) ?: continue
                    if (AndroidJson.equal(record.opt("task_id"), taskId) &&
                        AndroidJson.equal(record.opt("attempt_id"), attemptId)) {
                        operationResults.put(record)
                    }
                }
            }
            val view = JSONObject()
                .put("tables_present", true)
                .put("rounds", rounds)
                .put("batches", slotted(state.optJSONArray("batches")) {
                    AndroidJson.equal(it.opt("attempt_id"), attemptId)
                })
                .put("reservations", slotted(state.optJSONArray("reservations")) {
                    AndroidJson.equal(it.opt("task_id"), taskId) &&
                        AndroidJson.equal(it.opt("attempt_id"), attemptId)
                })
                .put(
                    "transcript",
                    if (transcriptIndex < 0) JSONObject.NULL
                    else transcripts?.optJSONObject(transcriptIndex) ?: JSONObject.NULL,
                )
                .put("transcript_summaries", JSONArray())
                .put("ledger_rows", ledgerRows)
                .put("dispatch", dispatch)
                .put("denied_calls", JSONArray())
                .put("denied_attempt_count", 0)
                .put("denied_total_count", 0)
                .put("authorities", authorities)
                .put("authorities_present", authorityTable != null)
                .put("operations_present", state.optJSONArray("operation_results") != null)
                .put("operation_results", operationResults)
            val env = JSONObject()
                .put("launch_id", AndroidAgentWal.launchId)
                .put("now", RuntimeJson.now())
                .put("approval_tokens", JSONArray(approvalTokens))
            val reply = try {
                reduce(
                    JSONObject().put("op", "prepare_tool_batch").put("request", request)
                        .put("env", env).put("view", view),
                )
            } catch (_: Refused) {
                return@body false
            }
            // The reducer returns changes and an output; the facade applies
            // the changes to the state the WAL transaction will commit. A
            // batch insert names no existing row, so there is no slot to
            // replace and the row index is deliberately absent.
            apply(state, reply.optJSONArray("changes") ?: JSONArray(), -1)
            output = reply.optJSONObject("output") ?: reply
            true
        }
        wal.transaction(body)
        return output
    }

    fun query(locator: JSONObject, expectedTranscript: JSONObject?, root: JSONObject?): JSONObject? =
        run("query", JSONObject().put("locator", locator)
            .put("expected_transcript", expectedTranscript ?: JSONObject.NULL)
            .put("root", root ?: JSONObject.NULL),
            locator, locator.opt("task_id"), locator.opt("attempt_id"),
            expectedTranscript, null, true)
}
