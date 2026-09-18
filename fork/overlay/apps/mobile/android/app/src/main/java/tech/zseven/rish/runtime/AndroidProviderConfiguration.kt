package tech.zseven.rish.runtime

import android.content.Context
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject

internal class AndroidProviderConfiguration(context: Context, namespace: String = "rish.providers.v1") {
    private val preferences = context.applicationContext.getSharedPreferences(namespace, Context.MODE_PRIVATE)
    companion object {
        val models = mapOf(
            "dsh" to setOf("deepseek-v4-flash", "deepseek-v4-pro", "deepseek-v4-flash-vision-exp"),
            "glm" to setOf("GLM-5.3", "GLM-5.3-Flash"),
            "codex" to setOf("gpt-5.6", "gpt-5.6-mini", "gpt-5.6-nano"),
            "claude-code" to setOf("claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001", "claude-fable-5-1"),
        )
        fun harness(model: String): String = if (AndroidDshModelCatalog.isKnown(model)) "dsh" else models.entries.firstOrNull { model in it.value }?.key ?: error("E_COMPLETION_MODEL_MISMATCH")
        fun slot(harness: String): String = when(harness) {
            "dsh" -> "DEEPSEEK_API_KEY"; "glm" -> "BIGMODEL_API_KEY"; "codex" -> "OPENAI_API_KEY"; "claude-code" -> "ANTHROPIC_API_KEY"
            else -> error("E_COMPLETION_MODEL_MISMATCH")
        }
        fun profileDigest(value: JSONObject) = RuntimeJson.sha("rish.provider-configuration-v1.v1\u0000" + RuntimeJson.canonical(value))
    }
    fun read(harness: String): JSONObject {
        require(harness in setOf("codex", "claude-code", "dsh"))
        preferences.getString(harness, null)?.let { return normalize(JSONObject(it)).also { value -> require(value.getString("harness_id") == harness) } }
        return JSONObject().put("schema_version", 1).put("harness_id", harness).put("name", "")
            .put("endpoint_url", when(harness) { "codex" -> "https://api.openai.com/v1/responses"; "claude-code" -> "https://api.anthropic.com/v1/messages"; else -> "https://api.deepseek.com/chat/completions" })
            .put("protocol", when(harness) { "codex" -> "responses"; "claude-code" -> "messages"; else -> "chat-completions" })
            .put("auth_type", when(harness) { "codex" -> "bearer"; "claude-code" -> "x-api-key"; else -> "bearer" })
            .put("send_reasoning", true).put("model_mappings", JSONObject()).put("official", true)
    }
    fun normalize(raw: JSONObject): JSONObject {
        RuntimeJson.checkVersion(raw, 1)
        val keys = raw.keys().asSequence().toSet()
        require(keys - "full_url" == setOf("schema_version", "harness_id", "name", "endpoint_url", "protocol", "auth_type", "model_mappings", "send_reasoning"))
        val harness = raw.getString("harness_id"); require(harness in setOf("codex", "claude-code", "dsh"))
        val name = raw.getString("name"); require(name.isNotEmpty() && name.toByteArray().size <= 80 && name.none { it.isISOControl() })
        val protocol = raw.getString("protocol"); require(protocol in setOf("messages", "chat-completions", "responses"))
        require(raw.getString("auth_type") in setOf("bearer", "x-api-key", "api-key"))
        require(raw.opt("send_reasoning") is Boolean)
        if (raw.has("full_url")) require(raw.opt("full_url") is Boolean)
        val urlText = raw.getString("endpoint_url"); require(urlText.length <= 2048 && urlText.none { it.isISOControl() })
        val url = urlText.trim().toHttpUrlOrNull() ?: error("Invalid endpoint")
        require(url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null)
        require(url.isHttps || url.host in setOf("localhost", "127.0.0.1", "::1"))
        var path = url.encodedPath
        if (!raw.optBoolean("full_url", false)) {
            val suffix = when(protocol) { "messages" -> "messages"; "responses" -> "responses"; else -> "chat/completions" }
            path = path.trimEnd('/')
            var knownEndpoint = false
            for (known in listOf("/messages", "/responses", "/chat/completions")) if(path.endsWith(known)) { path = path.removeSuffix(known); knownEndpoint = true; break }
            if (!knownEndpoint && !path.endsWith("/v1")) path += "/v1"
            path += "/$suffix"
        }
        val mappings = raw.getJSONObject("model_mappings"); require(mappings.length() <= 4)
        for (model in mappings.keys()) {
            // The dsh catalogue grows from the model settings, so a mapping may
            // name any model this build knows, not only the bundled three.
            require(model in models.getValue(harness) || (harness == "dsh" && AndroidDshModelCatalog.isKnown(model)))
            val wire = mappings.getString(model)
            require(wire.length in 1..128 && wire.none { it.isWhitespace() || it.isISOControl() })
        }
        val normalized = JSONObject(raw.toString()).put("endpoint_url", url.newBuilder().encodedPath(path).build().toString()).put("full_url", raw.optBoolean("full_url", false))
        return normalized
    }
    fun save(raw: JSONObject): JSONObject {
        val normalized = normalize(raw)
        check(preferences.edit().putString(normalized.getString("harness_id"), normalized.toString()).commit())
        return normalized
    }
    fun reset(harness: String): JSONObject {
        require(harness in setOf("codex", "claude-code", "dsh"))
        check(preferences.edit().remove(harness).commit()); return read(harness)
    }
    fun forModel(model: String): JSONObject {
        val harness = harness(model)
        if (harness in setOf("codex", "claude-code", "dsh")) return read(harness)
        return JSONObject().put("official", true).put("harness_id", harness)
            .put("endpoint_url", if(harness == "glm") "https://open.bigmodel.cn/api/anthropic/v1/messages" else "https://api.deepseek.com/chat/completions")
            .put("protocol", if(harness == "glm") "messages" else "chat-completions")
            .put("auth_type", if(harness == "glm") "x-api-key" else "bearer")
            .put("send_reasoning", true).put("model_mappings", JSONObject())
    }
    fun binding(config: JSONObject, model: String): JSONObject? {
        if (config.optBoolean("official")) return null
        val binding = JSONObject().put("schema_version", 1).put("harness_id", config.getString("harness_id"))
            .put("endpoint_url", config.getString("endpoint_url")).put("protocol", config.getString("protocol"))
            .put("auth_type", config.getString("auth_type")).put("send_reasoning", config.getBoolean("send_reasoning"))
            .put("model_id", config.getJSONObject("model_mappings").optString(model, model))
        return binding.put("profile_id", profileDigest(binding))
    }
    fun previousAccount(slot: String): String {
        require(slot in AndroidCredentialStore.slots)
        val harness = when(slot) { "OPENAI_API_KEY" -> "codex"; "ANTHROPIC_API_KEY" -> "claude-code"; "DEEPSEEK_API_KEY" -> "dsh"; else -> return slot }
        val config = read(harness)
        if(config.optBoolean("official")) return slot
        val identity = mapOf("harness_id" to harness, "endpoint_url" to config.getString("endpoint_url"),
            "auth_type" to config.getString("auth_type"), "protocol" to config.getString("protocol"))
        val legacy = identity.keys.sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + JSONObject.quote(identity.getValue(it)) }
        return "CUSTOM_PROVIDER_${harness}_${RuntimeJson.sha("rish.provider-configuration-v1.v1\u0000" + legacy)}"
    }
    fun effectiveAccount(slot: String): String {
        require(slot in AndroidCredentialStore.slots)
        val harness = when(slot) { "OPENAI_API_KEY" -> "codex"; "ANTHROPIC_API_KEY" -> "claude-code"; "DEEPSEEK_API_KEY" -> "dsh"; else -> return slot }
        val config = read(harness)
        if(config.optBoolean("official")) return slot
        val identity = JSONObject().put("harness_id", harness).put("endpoint_url", config.getString("endpoint_url"))
            .put("auth_type", config.getString("auth_type")).put("protocol", config.getString("protocol"))
        return "CUSTOM_PROVIDER_${harness}_${profileDigest(identity)}"
    }
}
