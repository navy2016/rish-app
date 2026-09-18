package tech.zseven.rish.runtime

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
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
        // Every receipt the candidate carries gets a binding answer, computed
        // with the core's own canonicalisation so the lookup key matches the
        // rule that asks for it. A binding this host cannot vouch for is
        // answered invalid rather than left out, because "not found" and
        // "invalid" both mean the same thing to the rule: not this host's.
        val answers = LinkedHashMap<String, JSONObject>()
        collectBindingAnswers(candidate, answers)
        val bindings = JSONArray()
        for (answer in answers.values) bindings.put(answer)
        return JSONObject().put("supported_models", models).put("harness_by_model", harnessByModel)
            .put("provider_ids", providers).put("host_by_model", JSONObject())
            .put("provider_bindings", bindings)
    }

    private fun collectBindingAnswers(node: Any?, answers: MutableMap<String, JSONObject>) {
        when (node) {
            is JSONObject -> {
                val binding = node.optJSONObject("provider_configuration")
                val model = node.opt("model")
                if (binding != null && model is String) {
                    answerFor(binding, model)?.let { answer ->
                        answers.putIfAbsent(answer.getString("canonical_sha256"), answer)
                    }
                }
                for (key in node.keys()) collectBindingAnswers(node.opt(key), answers)
            }
            is JSONArray -> for (index in 0 until node.length()) {
                collectBindingAnswers(node.opt(index), answers)
            }
        }
    }

    private fun answerFor(binding: JSONObject, model: String): JSONObject? {
        val keyed = JSONObject().put("binding", binding).put("model", model)
        val canonical = try {
            RishAgentCoreNative.canonical(keyed.toString())
        } catch (_: Exception) {
            null
        } ?: return null
        return JSONObject()
            .put("canonical_sha256", RuntimeJson.sha(canonical))
            .put("valid", bindingValid(binding, model))
            .put("host", bindingHost(binding) ?: JSONObject.NULL)
    }

    /**
     * Whether this host still recognises the binding: one of the configurable
     * harnesses, a profile digest this host itself could have minted, and a
     * harness that agrees with the model it was used for.
     */
    private fun bindingValid(binding: JSONObject, model: String): Boolean {
        val harness = binding.optString("harness_id")
        if (harness != "dsh" && harness != "codex" && harness != "claude-code") return false
        if (binding.optInt("schema_version", -1) != 1) return false
        val profileId = binding.optString("profile_id")
        if (profileId.isEmpty()) return false
        val stripped = JSONObject(binding.toString())
        stripped.remove("profile_id")
        val expected = try {
            RuntimeJson.sha(
                "rish.provider-configuration-v1.v1\u0000" + RuntimeJson.canonical(stripped),
            )
        } catch (_: Exception) {
            return false
        }
        if (expected != profileId) return false
        return try {
            harnessOrNull(model) == harness
        } catch (_: Exception) {
            false
        }
    }

    private fun bindingHost(binding: JSONObject): String? {
        val url = binding.optString("endpoint_url")
        if (url.isEmpty()) return null
        return try {
            url.toHttpUrlOrNull()?.host
        } catch (_: Exception) {
            null
        }
    }
}
