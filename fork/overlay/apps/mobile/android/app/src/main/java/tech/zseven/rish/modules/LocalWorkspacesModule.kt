package tech.zseven.rish.modules

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.UiThreadUtil
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.RishUnavailable
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RuntimeJson
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * LocalWorkspaces on Android.
 *
 * Mirrors the iOS registration in modules/rish/ios/Sources/LocalWorkspacesModule.mm
 * and the JS wrapper in apps/mobile/src/native/LocalWorkspaces.ts. Every rule
 * it needs already lives in the shared core and every mechanism already lives
 * in [AndroidWorkspaceRegistry]; this is the wire between them and the bridge,
 * and it decides nothing of its own.
 *
 * A person can make a workspace here and an agent can work inside it: create,
 * list, resolve and the operation query are real. Binding a folder the person
 * chose is not: that needs the Storage Access Framework, whose grants are a
 * different thing from an owned directory, and it keeps refusing until that
 * lands rather than pretending a picker appeared.
 */
class LocalWorkspacesModule(private val react: ReactApplicationContext) :
    ReactContextBaseJavaModule(react), ActivityEventListener {

    private val runtime by lazy { AndroidRuntimeState.get(react) }
    private val registry: AndroidWorkspaceRegistry get() = runtime.workspaces

    private data class Selection(val uri: String, val displayName: String)

    private val pendingSelections = ConcurrentHashMap<String, Selection>()

    @Volatile
    private var pickerPromise: Promise? = null

    init {
        react.addActivityEventListener(this)
    }

    /**
     * Without the core there are no rules to ask, so there is nothing this
     * module could answer honestly. That is the same question LocalGuest asks
     * about its runtime, and the same answer.
     */
    override fun getConstants(): MutableMap<String, Any> =
        mutableMapOf("implemented" to RishAgentCoreNative.available)

    override fun getName(): String = "LocalWorkspaces"

    private fun resolve(promise: Promise, value: JSONObject) =
        promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(value)))

    /**
     * A refusal carries the workspace code JS branches on and no detail: a
     * message could name a directory, and a path is not JavaScript's to see.
     */
    private fun reject(promise: Promise, error: Throwable) {
        val code = (error as? AndroidWorkspaceRegistry.Refused)?.code ?: "E_WORKSPACE_UNAVAILABLE"
        promise.reject(code, code)
    }

    private fun work(promise: Promise, action: () -> JSONObject) {
        runtime.io.execute {
            try {
                if (!RishAgentCoreNative.available) throw AndroidWorkspaceRegistry.Refused(UNAVAILABLE)
                resolve(promise, action())
            } catch (error: Throwable) {
                reject(promise, error)
            }
        }
    }

    /** `exactKeys` on the way in: an unexpected key is a different request. */
    private fun request(value: ReadableMap?, vararg keys: String): JSONObject {
        val map = RuntimeJson.fromBridgeMap(
            (value ?: throw AndroidWorkspaceRegistry.Refused(INVALID)).toHashMap(),
        )
        val present = map.keys().asSequence().toSet()
        if (present != keys.toSet()) throw AndroidWorkspaceRegistry.Refused(INVALID)
        RuntimeJson.checkVersion(map, 1)
        return map
    }

    private fun text(request: JSONObject, key: String): String {
        val value = request.opt(key)
        if (value !is String || value.isEmpty()) throw AndroidWorkspaceRegistry.Refused(INVALID)
        return value
    }

    private fun descriptorOrRefuse(workspaceId: String): JSONObject =
        registry.descriptor(workspaceId) ?: throw AndroidWorkspaceRegistry.Refused(UNAVAILABLE)

    @ReactMethod
    fun list(promise: Promise) = work(promise) {
        val workspaces = JSONArray()
        // `list` already leaves out every record it cannot still prove, so a
        // descriptor missing here is a record that stopped being provable
        // between the two reads rather than one to report as broken.
        for (record in registry.list()) {
            val id = record.optString("workspace_id")
            registry.descriptor(id)?.let { workspaces.put(it) }
        }
        JSONObject().put("schema_version", 1).put("workspaces", workspaces)
    }

    @ReactMethod
    fun create(request: ReadableMap?, promise: Promise) = work(promise) {
        val fields = request(request, "schema_version", "display_name", "operation_id")
        val record = registry.create(
            displayName = text(fields, "display_name"),
            operationId = text(fields, "operation_id"),
        )
        descriptorOrRefuse(record.getString("workspace_id"))
    }

    /**
     * An owned workspace is always reachable directly: there is no grant to
     * have expired, because the directory is the app's own. A revision the
     * caller did not expect, or a capability this binding does not carry, is
     * refused rather than answered with a descriptor that would mislead.
     */
    @ReactMethod
    fun resolve(request: ReadableMap?, promise: Promise) = work(promise) {
        val fields = request(
            request,
            "schema_version",
            "workspace_id",
            "expected_binding_revision",
            "required_capabilities",
        )
        val descriptor = descriptorOrRefuse(text(fields, "workspace_id"))
        val expected = fields.opt("expected_binding_revision")
        if (expected != null && expected != JSONObject.NULL) {
            if (expected !is Int) throw AndroidWorkspaceRegistry.Refused(INVALID)
            if (expected != descriptor.optInt("binding_revision")) {
                throw AndroidWorkspaceRegistry.Refused(STALE)
            }
        }
        val required = fields.opt("required_capabilities") as? JSONArray
            ?: throw AndroidWorkspaceRegistry.Refused(INVALID)
        val capabilities = descriptor.optJSONObject("capabilities")
            ?: throw AndroidWorkspaceRegistry.Refused(UNAVAILABLE)
        for (index in 0 until required.length()) {
            val capability = required.opt(index)
            if (capability !is String) throw AndroidWorkspaceRegistry.Refused(INVALID)
            if (!capabilities.optBoolean(capability)) {
                throw AndroidWorkspaceRegistry.Refused(CAPABILITY)
            }
        }
        JSONObject().put("schema_version", 1).put("disposition", "direct")
            .put("workspace", descriptor)
    }

    @ReactMethod
    fun queryOperation(request: ReadableMap?, promise: Promise) = work(promise) {
        val fields = request(request, "schema_version", "operation_id")
        registry.queryOperation(text(fields, "operation_id"))
            ?: throw AndroidWorkspaceRegistry.Refused(NOT_FOUND)
    }

    // --- folder picking ----------------------------------------------------
    //
    // Choosing a folder outside the app goes through the Storage Access
    // Framework. A persisted tree grant is not an owned directory -- it can be
    // revoked, it has no POSIX path, and the guest cannot read it the way it
    // reads one -- so this imports: the picked tree is copied into a new owned
    // workspace, which then binds and runs like any other. That is the same
    // shape `import_only` asks for; `grant_or_import` has no in-place branch
    // here and takes the import path too.

    @ReactMethod
    fun presentFolderPicker(request: ReadableMap?, promise: Promise) {
        val fields = try {
            request(request, "schema_version", "operation_id", "mode")
        } catch (error: Throwable) {
            return reject(promise, error)
        }
        val mode = fields.opt("mode")
        if (mode != "grant_or_import" && mode != "import_only") {
            return reject(promise, AndroidWorkspaceRegistry.Refused(INVALID))
        }
        synchronized(this) {
            if (pickerPromise != null) {
                return reject(promise, AndroidWorkspaceRegistry.Refused(BUSY))
            }
            pickerPromise = promise
        }
        UiThreadUtil.runOnUiThread {
            val activity = react.currentActivity
            if (activity == null || activity.isFinishing) {
                synchronized(this) { pickerPromise = null }
                return@runOnUiThread reject(
                    promise,
                    AndroidWorkspaceRegistry.Refused(UNAVAILABLE),
                )
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
                synchronized(this) { pickerPromise = null }
                reject(promise, AndroidWorkspaceRegistry.Refused(UNAVAILABLE))
            }
        }
    }

    override fun onActivityResult(
        activity: Activity,
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        if (requestCode != PICKER_REQUEST) return
        val promise = synchronized(this) {
            val active = pickerPromise
            pickerPromise = null
            active
        } ?: return
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            return resolve(
                promise,
                JSONObject().put("schema_version", 1).put("status", "cancelled"),
            )
        }
        val flags = (data?.flags ?: 0) and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        try {
            react.contentResolver.takePersistableUriPermission(uri, flags)
        } catch (_: SecurityException) {
        }
        val displayName = displayNameFor(uri)
        val selectionId = UUID.randomUUID().toString()
        pendingSelections[selectionId] = Selection(uri.toString(), displayName)
        resolve(
            promise,
            JSONObject()
                .put("schema_version", 1)
                .put("status", "requires_import")
                .put("selection_id", selectionId)
                .put("display_name", displayName)
                .put("location_class", "provider_managed"),
        )
    }

    override fun onNewIntent(intent: Intent) = Unit

    @ReactMethod
    fun importSelection(request: ReadableMap?, promise: Promise) {
        val fields = try {
            request(request, "schema_version", "selection_id", "operation_id")
        } catch (error: Throwable) {
            return reject(promise, error)
        }
        val selection = pendingSelections.remove(fields.getString("selection_id"))
            ?: return reject(promise, AndroidWorkspaceRegistry.Refused(NOT_FOUND))
        val operationId = fields.getString("operation_id")
        runtime.io.execute {
            try {
                resolve(promise, importIntoOwnedWorkspace(selection, operationId))
            } catch (error: Throwable) {
                reject(promise, error)
            }
        }
    }

    @ReactMethod
    fun cancelSelection(request: ReadableMap?, promise: Promise) {
        val fields = try {
            request(request, "schema_version", "selection_id")
        } catch (error: Throwable) {
            return reject(promise, error)
        }
        val removed = pendingSelections.remove(fields.getString("selection_id"))
        resolve(
            promise,
            JSONObject().put("schema_version", 1)
                .put("status", if (removed == null) "already_settled" else "cancelled"),
        )
    }

    @ReactMethod
    fun cancelPicker(request: ReadableMap?, promise: Promise) {
        try {
            request(request, "schema_version", "operation_id")
        } catch (error: Throwable) {
            return reject(promise, error)
        }
        val active = synchronized(this) {
            val settled = pickerPromise
            pickerPromise = null
            settled
        }
        if (active == null) {
            return resolve(
                promise,
                JSONObject().put("schema_version", 1).put("status", "already_settled"),
            )
        }
        UiThreadUtil.runOnUiThread {
            try {
                react.currentActivity?.finishActivity(PICKER_REQUEST)
            } catch (_: Exception) {
            }
        }
        resolve(active, JSONObject().put("schema_version", 1).put("status", "cancelled"))
        resolve(promise, JSONObject().put("schema_version", 1).put("status", "cancelled"))
    }

    /** Copies the picked tree into a fresh owned workspace and answers its descriptor. */
    private fun importIntoOwnedWorkspace(selection: Selection, operationId: String): JSONObject {
        if (!RishAgentCoreNative.available) throw AndroidWorkspaceRegistry.Refused(UNAVAILABLE)
        if (!RuntimeJson.uuid(operationId)) throw AndroidWorkspaceRegistry.Refused(INVALID)
        val record = registry.create(
            displayName = boundDisplayName(selection.displayName),
            operationId = operationId,
        )
        val workspaceId = record.getString("workspace_id")
        val root = registry.rootFor(workspaceId)
            ?: throw AndroidWorkspaceRegistry.Refused(PERSISTENCE)
        copyTree(Uri.parse(selection.uri), root)
        return registry.descriptor(workspaceId)
            ?: throw AndroidWorkspaceRegistry.Refused(PERSISTENCE)
    }

    private class CopyBudget {
        var entries = 0
        var bytes = 0L
    }

    private fun copyTree(treeUri: Uri, destination: File) {
        copyChildren(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
            destination,
            CopyBudget(),
        )
    }

    private fun copyChildren(
        treeUri: Uri,
        documentId: String,
        directory: File,
        budget: CopyBudget,
    ) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        val cursor = try {
            react.contentResolver.query(childrenUri, projection, null, null, null)
        } catch (_: Exception) {
            null
        } ?: throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_IO")
        cursor.use { rows ->
            while (rows.moveToNext()) {
                val id = if (rows.isNull(0)) null else rows.getString(0)
                val name = if (rows.isNull(1)) null else rows.getString(1)
                if (id == null || name == null) continue
                if (!usableName(name)) continue
                budget.entries += 1
                if (budget.entries > MAX_IMPORT_ENTRIES) {
                    throw AndroidWorkspaceRegistry.Refused(CAPABILITY)
                }
                val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                val target = File(directory, name)
                val childIsDirectory = !rows.isNull(2) &&
                    rows.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                if (childIsDirectory) {
                    if (!target.isDirectory && !target.mkdirs()) {
                        throw AndroidWorkspaceRegistry.Refused(PERSISTENCE)
                    }
                    copyChildren(treeUri, id, target, budget)
                } else {
                    copyFile(childUri, target, budget)
                }
            }
        }
    }

    private fun copyFile(source: Uri, target: File, budget: CopyBudget) {
        val input = try {
            react.contentResolver.openInputStream(source)
        } catch (_: Exception) {
            null
        } ?: throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_IO")
        input.use { stream ->
            val parent = target.parentFile
            if (parent != null && !parent.isDirectory && !parent.mkdirs()) {
                throw AndroidWorkspaceRegistry.Refused(PERSISTENCE)
            }
            val staging = File(parent, ".rish-write-" + UUID.randomUUID())
            try {
                FileOutputStream(staging).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = stream.read(buffer)
                        if (read < 0) break
                        budget.bytes += read
                        if (budget.bytes > MAX_IMPORT_BYTES) {
                            throw AndroidWorkspaceRegistry.Refused(CAPABILITY)
                        }
                        output.write(buffer, 0, read)
                    }
                    output.fd.sync()
                }
                if (!staging.renameTo(target)) {
                    throw AndroidWorkspaceRegistry.Refused(PERSISTENCE)
                }
            } catch (error: Throwable) {
                staging.delete()
                throw error
            }
        }
    }

    private fun usableName(name: String): Boolean =
        name.isNotEmpty() && name != "." && name != ".." &&
            !name.contains('/') && !name.contains('\u0000') &&
            name != ".trash" && !name.equals(".git", true) &&
            !name.startsWith(".staging-") && !name.startsWith(".rish-write-")

    private fun displayNameFor(treeUri: Uri): String {
        val documentId = DocumentsContract.getTreeDocumentId(treeUri)
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        val queried = try {
            react.contentResolver.query(
                documentUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
            }
        } catch (_: Exception) {
            null
        }
        return boundDisplayName((queried ?: "").trim())
    }

    /** Within the bound the JS display-name checker accepts (1..120 UTF-8 bytes). */
    private fun boundDisplayName(value: String): String {
        val builder = StringBuilder()
        var bytes = 0
        for (character in value) {
            val size = character.toString().toByteArray(Charsets.UTF_8).size
            if (bytes + size > 120) break
            builder.append(character)
            bytes += size
        }
        return if (builder.isEmpty()) "Imported folder" else builder.toString()
    }

    override fun invalidate() {
        val active = synchronized(this) {
            val settled = pickerPromise
            pickerPromise = null
            settled
        }
        try {
            active?.reject(UNAVAILABLE, UNAVAILABLE)
        } catch (_: Exception) {
        }
        pendingSelections.clear()
        super.invalidate()
    }

    @ReactMethod
    fun presentRegrantPicker(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    @ReactMethod
    fun completeRegrant(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    @ReactMethod
    fun bootstrapLegacyProject(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    // Forgetting a workspace and deleting its content are a clearance the core
    // already rules on; the host half -- removing a directory and proving it
    // is gone -- is not written, and a delete that reported success without
    // doing it would be the worst possible lie here. There is likewise no
    // granted-folder record on Android for a regrant to answer.

    @ReactMethod
    fun forget(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    @ReactMethod
    fun prepareDeleteOwnedContent(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    @ReactMethod
    fun deleteOwnedContent(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    private fun refuseUnbuilt(promise: Promise) =
        RishUnavailable.reject("LocalWorkspaces", UNAVAILABLE, promise)

    private companion object {
        const val PICKER_REQUEST = 7461
        const val MAX_IMPORT_ENTRIES = 20000
        const val MAX_IMPORT_BYTES = 1024L * 1024L * 1024L
        const val UNAVAILABLE = "E_WORKSPACE_UNAVAILABLE"
        const val INVALID = "E_WORKSPACE_INVALID"
        const val STALE = "E_WORKSPACE_STALE"
        const val CAPABILITY = "E_WORKSPACE_CAPABILITY"
        const val NOT_FOUND = "E_WORKSPACE_NOT_FOUND"
        const val PERSISTENCE = "E_WORKSPACE_PERSISTENCE"
        const val BUSY = "E_WORKSPACE_BUSY"
    }
}
