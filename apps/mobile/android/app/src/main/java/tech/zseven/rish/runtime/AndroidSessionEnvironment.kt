package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * The host facts the shared core needs to judge a session candidate: which of
 * the strings the candidate carries name a model this build supports, which
 * harness and provider host each belongs to, and which provider ids exist.
 * The core owns the rules; only the host knows its own catalogue.
 *
 * This mirrors `DSHSessionCoreEnvironment` in SessionSnapshotStore.mm — the
 * facts are collected from the candidate's own strings, so a session that
 * never mentions a model needs no catalogue at all.
 */
internal object AndroidSessionEnvironment {
    private val providerIds = setOf("dsh", "glm", "codex", "claude-code")

    private fun collect(node: Any?, strings: MutableSet<String>) {
        when (node) {
            is String -> strings.add(node)
            is JSONArray -> for (index in 0 until node.length()) collect(node.opt(index), strings)
            is JSONObject -> for (key in node.keys()) collect(node.opt(key), strings)
        }
    }

    /** Whether this build can talk to `model` at all, and through which
     *  harness. Both are facts only the host has. */
    fun isSupported(model: String): Boolean = harnessOrNull(model) != null

    fun harnessIdFor(model: String): String? = harnessOrNull(model)

    private fun harnessOrNull(model: String): String? =
        try { AndroidProviderConfiguration.harness(model) } catch (_: IllegalStateException) { null }

    fun forCandidate(candidate: JSONObject): JSONObject {
        val strings = sortedSetOf<String>()
        collect(candidate, strings)
        val models = JSONArray()
        val harnessByModel = JSONObject()
        val providers = JSONArray()
        for (value in strings) {
            harnessOrNull(value)?.let { harness ->
                models.put(value)
                harnessByModel.put(value, harness)
            }
            if (value in providerIds) providers.put(value)
        }
        // Android issues no provider bindings and reaches no provider host of
        // its own, so those two facts are empty rather than guessed.
        return JSONObject().put("supported_models", models).put("harness_by_model", harnessByModel)
            .put("provider_ids", providers).put("host_by_model", JSONObject())
            .put("provider_bindings", JSONArray())
    }
}
