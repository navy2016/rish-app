package tech.zseven.rish.modules

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.guest.GuestRuntimeState
import tech.zseven.rish.runtime.AndroidClock
import tech.zseven.rish.runtime.RuntimeJson
import java.io.File
import java.net.URI
import java.util.concurrent.Executors

/**
 * LocalMirrors — stages the Alpine/pip/npm mirror configuration the rish
 * guest overlay expects.
 *
 * Mirrors modules/rish/ios/Sources/LocalMirrorsModule.mm and the JS wrapper in
 * apps/mobile/src/native/LocalMirrors.ts. The overlay is written under the
 * app's private files directory and only credential-free HTTPS base URLs are
 * accepted. [MirrorApplyResult.staged_config_enters_guest] stays false: the
 * interpreter has no block-device injection, so a staged overlay is not a
 * claim that the booted guest already reads it.
 */
class LocalMirrorsModule(private val react: ReactApplicationContext) :
    ReactContextBaseJavaModule(react) {

    private companion object {
        const val SCHEMA_VERSION = 1
        const val MAX_URL_BYTES = 2048
        const val OVERLAY_ROOT = "rish-guest-overlay"
        const val MANIFEST = "mirrors.json"
        val CATEGORIES = listOf(
            Category("alpine", "etc/apk/repositories", "https://dl-cdn.alpinelinux.org/alpine/"),
            Category("pip", "etc/pip/pip.conf", "https://pypi.org/simple/"),
            Category("npm", "root/.npmrc", "https://registry.npmjs.org/"),
        )
    }

    private data class Category(val name: String, val logicalPath: String, val defaultBase: String)

    private val queue = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "rish-mirrors") }

    override fun getName(): String = "LocalMirrors"
    override fun getConstants(): MutableMap<String, Any> = mutableMapOf("implemented" to true)

    @ReactMethod
    fun applyMirrors(mirrors: ReadableMap?, promise: Promise) {
        queue.execute {
            try {
                val request = RuntimeJson.fromBridgeMap(mirrors?.toHashMap() ?: emptyMap())
                promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(stage(request))))
            } catch (error: Exception) {
                promise.reject("E_MIRROR_CONFIGURATION", error.message ?: "Mirror configuration could not be staged.")
            }
        }
    }

    @ReactMethod
    fun mirrorStatus(promise: Promise) {
        queue.execute {
            try {
                val manifest = File(overlayRoot(), MANIFEST)
                if (!manifest.isFile) {
                    promise.resolve(null)
                    return@execute
                }
                val stored = JSONObject(manifest.readText(Charsets.UTF_8))
                promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(stored)))
            } catch (error: Exception) {
                promise.reject("E_MIRROR_CONFIGURATION", error.message ?: "Stored mirror manifest is invalid.")
            }
        }
    }

    private fun overlayRoot(): File {
        val root = File(react.filesDir, OVERLAY_ROOT)
        if (!root.isDirectory && !root.mkdirs()) error("Mirror overlay directory is unavailable.")
        return root
    }

    private fun normalizedBaseUrl(value: Any?): String? {
        val raw = value as? String ?: return null
        if (raw.isEmpty() || raw.toByteArray(Charsets.UTF_8).size > MAX_URL_BYTES) return null
        val uri = try { URI(raw) } catch (_: Exception) { return null }
        if (!uri.scheme.equals("https", true)) return null
        if (uri.host.isNullOrEmpty()) return null
        if (uri.userInfo != null || uri.query != null || uri.fragment != null) return null
        return if (raw.endsWith("/")) raw else "$raw/"
    }

    private fun entry(mirrors: JSONObject, category: Category): JSONObject {
        val value = mirrors.optJSONObject(category.name) ?: error("Mirror configuration is invalid.")
        val enabled = value.opt("enabled")
        if (enabled !is Boolean) error("Mirror configuration is invalid.")
        val base = normalizedBaseUrl(value.opt("baseUrl")) ?: error("Mirror URL must be a credential-free HTTPS base URL.")
        return JSONObject()
            .put("category", category.name)
            .put("enabled", enabled)
            .put("base_url", if (enabled) base else category.defaultBase)
            .put("logical_path", category.logicalPath)
    }

    private fun stage(mirrors: JSONObject): JSONObject {
        if (mirrors.length() != CATEGORIES.size) error("Mirror configuration must contain three categories.")
        val entries = CATEGORIES.map { entry(mirrors, it) }
        if (entries.size != 3) error("Mirror configuration must contain three categories.")
        val root = overlayRoot()
        write(root, "etc/apk/repositories", "${entries[0].getString("base_url")}v3.21/main\n${entries[0].getString("base_url")}v3.21/community\n")
        write(root, "etc/pip/pip.conf", "[global]\nbreak-system-packages = true\nindex-url = ${entries[1].getString("base_url")}\n")
        write(root, "root/.npmrc", "registry=${entries[2].getString("base_url")}\n")
        val receipt = JSONObject()
            .put("schema_version", SCHEMA_VERSION)
            .put("status", "staged")
            .put("staged_at", AndroidClock.now())
            .put("guest_runtime_mounted", GuestRuntimeState.guestRuntimeMounted)
            .put("staged_config_enters_guest", false)
            .put("root", OVERLAY_ROOT)
            .put("entries", JSONArray(entries))
        write(root, MANIFEST, receipt.toString())
        return receipt
    }

    private fun write(root: File, relative: String, text: String) {
        val target = File(root, relative)
        target.parentFile?.mkdirs()
        target.writeText(text, Charsets.UTF_8)
    }
}
