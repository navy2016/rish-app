package tech.zseven.rish.modules

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.UiThreadUtil
import org.json.JSONObject
import tech.zseven.rish.runtime.AndroidClock
import tech.zseven.rish.runtime.AndroidWorkspaceStore
import tech.zseven.rish.runtime.RuntimeJson
import tech.zseven.rish.runtime.WorkspaceFailure
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * LocalWorkspaces — the Android workspace registry.
 *
 * Mirrors modules/rish/ios/Sources/LocalWorkspacesModule.mm and the JS wrapper
 * in apps/mobile/src/native/LocalWorkspaces.ts. Only opaque workspace ids and
 * binding revisions cross the bridge; the tree URIs stay inside
 * [AndroidWorkspaceStore].
 */
class LocalWorkspacesModule(private val react: ReactApplicationContext) :
    ReactContextBaseJavaModule(react), ActivityEventListener {

    private companion object {
        const val PICKER_REQUEST = 7461
        const val TAG = "LocalWorkspaces"
    }

    private val store = AndroidWorkspaceStore.get(react)
    private val pendingSelections = ConcurrentHashMap<String, Selection>()

    private data class Pending(val kind: String, val workspaceId: String?, val revision: Long?, val promise: Promise)
    private data class Selection(val uri: Uri, val workspaceId: String?)

    @Volatile private var pending: Pending? = null

    init {
        react.addActivityEventListener(this)
    }

    override fun getName(): String = TAG
    override fun getConstants(): MutableMap<String, Any> = mutableMapOf("implemented" to true)

    @ReactMethod
    fun list(promise: Promise) = run(promise) { store.listing() }

    @ReactMethod
    fun create(request: ReadableMap?, promise: Promise) = run(promise) {
        store.create(body(request).getString("display_name"))
    }

    @ReactMethod
    fun bootstrapLegacyProject(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        if (!AndroidWorkspaceStore.isUuid(value.getString("project_id"))) {
            throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        }
        store.create("Project")
    }

    @ReactMethod
    fun presentFolderPicker(request: ReadableMap?, promise: Promise) {
        val value = try { body(request) } catch (error: Exception) { return fail(promise, error) }
        val mode = value.optString("mode")
        if (mode != "grant_or_import" && mode != "import_only") {
            return fail(promise, WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid."))
        }
        openPicker(Pending("folder", null, null, promise), promise)
    }

    @ReactMethod
    fun presentRegrantPicker(request: ReadableMap?, promise: Promise) {
        val value = try { body(request) } catch (error: Exception) { return fail(promise, error) }
        val record = try { store.find(value.getString("workspace_id")) } catch (error: Exception) { return fail(promise, error) }
        val revision = value.optDouble("expected_binding_revision", Double.NaN)
        if (revision.isNaN() || revision.toLong() != record.revision) {
            return fail(promise, WorkspaceFailure("E_WORKSPACE_REVISION_STALE", "Workspace binding is stale."))
        }
        openPicker(Pending("regrant", record.id, record.revision, promise), promise)
    }

    @ReactMethod
    fun importSelection(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        val selection = pendingSelections.remove(value.getString("selection_id"))
            ?: throw WorkspaceFailure("E_WORKSPACE_SELECTION_EXPIRED", "Workspace picker selection has expired.")
        val existing = selection.workspaceId?.let { store.find(it) }
        if (existing == null) store.importTree(displayName(selection.uri), selection.uri, "imported")
        else store.updateTree(existing, selection.uri)
    }

    @ReactMethod
    fun cancelSelection(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        val removed = pendingSelections.remove(value.getString("selection_id"))
        JSONObject().put("schema_version", 1).put("status", if (removed == null) "already_settled" else "cancelled")
    }

    @ReactMethod
    fun cancelPicker(request: ReadableMap?, promise: Promise) {
        try { body(request) } catch (error: Exception) { return fail(promise, error) }
        val active = pending
        if (active != null) {
            pending = null
            UiThreadUtil.runOnUiThread {
                try { react.currentActivity?.finishActivity(PICKER_REQUEST) } catch (_: Exception) { }
            }
            active.promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(JSONObject().put("schema_version", 1).put("status", "cancelled"))))
            promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(JSONObject().put("schema_version", 1).put("status", "cancelled"))))
            return
        }
        // Nothing was pending; report the settled state instead of a cancel.
        promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(JSONObject().put("schema_version", 1).put("status", "already_settled"))))
    }

    @ReactMethod
    fun completeRegrant(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        val selection = pendingSelections.remove(value.getString("selection_id"))
            ?: throw WorkspaceFailure("E_WORKSPACE_SELECTION_EXPIRED", "Workspace picker selection has expired.")
        val record = store.find(value.getString("workspace_id"))
        if (value.optDouble("expected_binding_revision", Double.NaN).toLong() != record.revision) {
            throw WorkspaceFailure("E_WORKSPACE_REVISION_STALE", "Workspace binding is stale.")
        }
        if (record.treeUri == selection.uri.toString()) {
            JSONObject().put("schema_version", 1).put("status", "regranted")
                .put("workspace", store.updateTree(record, selection.uri))
        } else {
            JSONObject().put("schema_version", 1).put("status", "different_root")
                .put("new_workspace", store.importTree(displayName(selection.uri), selection.uri, "granted_folder"))
        }
    }

    @ReactMethod
    fun resolve(request: ReadableMap?, promise: Promise) = run(promise) { store.resolve(body(request)) }

    @ReactMethod
    fun forget(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        store.forget(value.getString("workspace_id"), value.optDouble("expected_binding_revision", Double.NaN).toLong())
        JSONObject().put("schema_version", 1).put("status", "forgotten")
    }

    @ReactMethod
    fun prepareDeleteOwnedContent(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        val record = store.find(value.getString("workspace_id"))
        if (value.optDouble("expected_binding_revision", Double.NaN).toLong() != record.revision) {
            throw WorkspaceFailure("E_WORKSPACE_REVISION_STALE", "Workspace binding is stale.")
        }
        JSONObject()
            .put("schema_version", 1)
            .put("confirmation_id", UUID.randomUUID().toString())
            .put("expires_at", AndroidClock.nowAdding(300))
    }

    @ReactMethod
    fun deleteOwnedContent(request: ReadableMap?, promise: Promise) = run(promise) {
        val value = body(request)
        store.forget(value.getString("workspace_id"), value.optDouble("expected_binding_revision", Double.NaN).toLong())
        JSONObject().put("schema_version", 1).put("status", "deleted")
    }

    @ReactMethod
    fun queryOperation(request: ReadableMap?, promise: Promise) = run(promise) {
        body(request)
        JSONObject().put("schema_version", 1).put("status", "not_started")
    }

    private fun openPicker(request: Pending, promise: Promise) {
        synchronized(this) {
            if (pending != null) {
                return fail(promise, WorkspaceFailure("E_WORKSPACE_PICKER_BUSY", "Another workspace picker operation is active."))
            }
            pending = request
        }
        UiThreadUtil.runOnUiThread {
            val activity = react.currentActivity
            if (activity == null || activity.isFinishing) {
                pending = null
                return@runOnUiThread fail(promise, WorkspaceFailure("E_WORKSPACE_UNAVAILABLE", "An active screen is required to choose a folder."))
            }
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                )
            }
            try {
                activity.startActivityForResult(intent, PICKER_REQUEST)
            } catch (_: Exception) {
                pending = null
                fail(promise, WorkspaceFailure("E_WORKSPACE_UNAVAILABLE", "The Android folder picker is unavailable."))
            }
        }
    }

    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICKER_REQUEST) return
        val active = synchronized(this) { val current = pending; pending = null; current } ?: return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            return active.promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(JSONObject().put("schema_version", 1).put("status", "cancelled"))))
        }
        val uri = data.data!!
        try {
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (flags != 0) react.contentResolver.takePersistableUriPermission(uri, flags)
            val result = when (active.kind) {
                "regrant" -> {
                    val selectionId = UUID.randomUUID().toString()
                    pendingSelections[selectionId] = Selection(uri, active.workspaceId)
                    val record = store.find(active.workspaceId!!)
                    JSONObject()
                        .put("schema_version", 1)
                        .put("status", if (record.treeUri == uri.toString()) "same_root_selected" else "different_root_selected")
                        .put("selection_id", selectionId)
                        .put("display_name", displayName(uri))
                }
                else -> JSONObject()
                    .put("schema_version", 1)
                    .put("status", "selected")
                    .put("workspace", store.importTree(displayName(uri), uri, "granted_folder"))
            }
            active.promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(result)))
        } catch (error: Exception) {
            fail(active.promise, error)
        }
    }

    override fun onNewIntent(intent: Intent) = Unit

    override fun invalidate() {
        react.removeActivityEventListener(this)
        synchronized(this) {
            pending?.promise?.reject("E_WORKSPACE_UNAVAILABLE", "The folder picker was cancelled.")
            pending = null
        }
        super.invalidate()
    }

    private fun displayName(uri: Uri): String {
        val raw = try {
            react.contentResolver.query(
                uri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
        } catch (_: Exception) {
            null
        }
        return sanitize(raw ?: "Android folder")
    }

    private fun sanitize(value: String): String {
        val folded = java.text.Normalizer.normalize(value, java.text.Normalizer.Form.NFC)
            .trim().replace('/', '-').replace('\\', '-').replace(":", "-")
        val bounded = if (folded.toByteArray(Charsets.UTF_8).size > 100) folded.take(40) else folded
        return if (bounded.isEmpty() || bounded.startsWith('.')) "Android folder" else bounded
    }

    private fun body(request: ReadableMap?): JSONObject = try {
        RuntimeJson.fromBridgeMap(request?.toHashMap() ?: emptyMap())
    } catch (_: Exception) {
        throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
    }

    private fun run(promise: Promise, action: () -> JSONObject) {
        store.io.execute {
            try {
                promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(action())))
            } catch (error: Exception) {
                fail(promise, error)
            }
        }
    }

    private fun fail(promise: Promise, error: Exception) {
        val failure = error as? WorkspaceFailure
        promise.reject(failure?.code ?: "E_WORKSPACE_UNAVAILABLE", failure?.message ?: "Workspace operation is unavailable.")
    }
}
