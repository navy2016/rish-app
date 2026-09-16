package tech.zseven.rish.modules

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.runtime.AndroidWorkspaceStore
import tech.zseven.rish.runtime.RuntimeJson
import tech.zseven.rish.runtime.WorkspaceFailure

/**
 * LocalWorkspace — bounded file operations inside one authorized workspace.
 *
 * Mirrors modules/rish/ios/Sources/LocalWorkspaceModule.mm and the JS wrapper
 * in apps/mobile/src/native/LocalWorkspace.ts. Every request carries the
 * opaque root reference; the store refuses a stale binding and any path that
 * escapes the workspace before touching a file.
 */
class LocalWorkspaceModule(private val react: ReactApplicationContext) :
    ReactContextBaseJavaModule(react) {

    private val store = AndroidWorkspaceStore.get(react)

    override fun getName(): String = "LocalWorkspace"
    override fun getConstants(): MutableMap<String, Any> = mutableMapOf("implemented" to true)

    @ReactMethod
    fun capabilities(promise: Promise) = run(promise) {
        JSONObject()
            .put("schema_version", 1)
            .put("root", "workspace")
            .put("max_text_bytes", 1024 * 1024)
            .put("max_list_entries", 1000)
            .put("max_tool_output_bytes", 256 * 1024)
            .put("trash_recoverable", true)
            .put("trash_listable", true)
            .put("atomic_writes", true)
            .put("symlinks_allowed", false)
            .put("rish_protocol_version", 1)
            .put("portable_tools", JSONArray(listOf("cat", "grep", "head", "tail", "wc", "sha256sum")))
    }

    @ReactMethod
    fun listV2(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        val record = authorize(value)
        val path = value.optString("path")
        store.list(record, path, value.optInt("max_entries", 0))
    }

    @ReactMethod
    fun readV2(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        val record = authorize(value)
        store.read(record, value.optString("path"), value.optInt("max_bytes", 0))
    }

    @ReactMethod
    fun writeV2(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        val record = authorize(value)
        store.write(
            record,
            value.optString("path"),
            value.optString("content"),
            if (value.isNull("expected_revision")) null else value.optString("expected_revision"),
            value.optBoolean("create_only", false),
        )
    }

    @ReactMethod
    fun createDirectoryV2(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        store.mkdir(authorize(value), value.optString("path"))
    }

    @ReactMethod
    fun renameEntryV2(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        store.rename(authorize(value), value.optString("source_path"), value.optString("destination_path"))
    }

    @ReactMethod
    fun trashEntryV2(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        store.trash(authorize(value), value.optString("path"))
    }

    @ReactMethod
    fun listTrashV2(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        store.listTrash(authorize(value), value.optInt("max_entries", 0))
    }

    @ReactMethod
    fun restoreFromTrashV2(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        store.restore(
            authorize(value),
            value.optString("trash_id"),
            if (value.isNull("destination_path")) null else value.optString("destination_path"),
        )
    }

    @ReactMethod
    fun executePortableToolV2(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        store.tool(
            authorize(value),
            value.optString("tool"),
            value.optString("path"),
            value.optJSONObject("options") ?: JSONObject(),
        )
    }

    /**
     * Resolves the opaque root reference to an authorized record. A revision
     * that no longer matches is a stale binding, never a silent re-resolve.
     */
    private fun authorize(request: JSONObject): AndroidWorkspaceStore.Record {
        val root = request.optJSONObject("root") ?: throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        if (root.opt("schema_version") != 1) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val id = root.optString("workspace_id")
        if (!AndroidWorkspaceStore.isUuid(id)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val projectId = if (root.isNull("project_id")) null else root.optString("project_id")
        if (projectId != null && !AndroidWorkspaceStore.isUuid(projectId)) {
            throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        }
        val record = store.find(id)
        val revision = root.opt("binding_revision")
        val expected = when (revision) {
            is Number -> revision.toLong()
            else -> throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        }
        if (record.revision != expected) throw WorkspaceFailure("E_WORKSPACE_REVISION_STALE", "Workspace binding is stale.")
        if (record.status != "ok") throw WorkspaceFailure("E_WORKSPACE_UNAVAILABLE", "Workspace is unavailable.")
        return record
    }

    private fun body(request: ReadableMap?): JSONObject = try {
        val value = RuntimeJson.fromBridgeMap(request?.toHashMap() ?: emptyMap())
        if (value.opt("schema_version") != 1) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        value
    } catch (error: WorkspaceFailure) {
        throw error
    } catch (_: Exception) {
        throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
    }

    private fun run(promise: Promise, action: () -> JSONObject) {
        store.io.execute {
            try {
                promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(action())))
            } catch (error: Exception) {
                val failure = error as? WorkspaceFailure
                promise.reject(failure?.code ?: "E_WORKSPACE_IO", failure?.message ?: "Workspace operation failed.")
            }
        }
    }
}
