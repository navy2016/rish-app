package tech.zseven.rish.runtime

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** A fail-closed workspace rejection carrying a JS-recognized code. */
internal class WorkspaceFailure(val code: String, override val message: String) : Exception(message)

/**
 * The single Android workspace authority and file implementation.
 *
 * JavaScript only ever sees opaque workspace ids and binding revisions. This
 * store is the only component that resolves those ids to an app-owned
 * directory or a persistable Storage Access Framework tree URI, and it checks
 * every path for traversal before resolving it.
 */
internal class AndroidWorkspaceStore private constructor(private val context: Context) {
    companion object {
        private const val PREFS = "rish.android.workspaces.v1"
        private const val RECORDS = "records"
        private const val TRASH = "trash"
        private const val MAX_PATH_BYTES = 1024
        private const val MAX_TEXT_BYTES = 1024 * 1024
        private const val MAX_LIST_ENTRIES = 1000
        private const val MAX_TOOL_OUTPUT_BYTES = 256 * 1024
        private val UUID_PATTERN = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

        @Volatile private var instance: AndroidWorkspaceStore? = null

        fun get(context: Context): AndroidWorkspaceStore = instance ?: synchronized(this) {
            instance ?: AndroidWorkspaceStore(context.applicationContext).also { instance = it }
        }

        fun isUuid(value: String?): Boolean = value != null && UUID_PATTERN.matches(value)
    }

    data class Record(
        val id: String,
        val displayName: String,
        val origin: String,
        val status: String,
        val revision: Long,
        val createdAt: String,
        val lastOpenedAt: String,
        val rootPath: String?,
        val treeUri: String?,
    )

    data class Trash(
        val id: String,
        val workspaceId: String,
        val originalPath: String,
        val kind: String,
        val deletedAt: String,
        val savedPath: String?,
    )

    private val prefs: SharedPreferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Serializes every bridge operation off the RN and UI threads. */
    val io: ExecutorService = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "rish-workspace") }

    private fun uuid(): String = UUID.randomUUID().toString().lowercase()

    private fun validName(value: String): Boolean {
        if (value.isEmpty() || value.toByteArray(StandardCharsets.UTF_8).size > 120) return false
        if (value != value.trim() || java.text.Normalizer.normalize(value, java.text.Normalizer.Form.NFC) != value) return false
        if (value.startsWith('.') || value.equals("rish workspaces", true) || value.startsWith(".rish-", true)) return false
        return value.none { it.code <= 0x1f || it.code == 0x7f || it == '/' || it == '\\' || it == ':' }
    }

    private fun validPath(path: String, allowRoot: Boolean = true): Boolean {
        if (path.toByteArray(StandardCharsets.UTF_8).size > MAX_PATH_BYTES) return false
        if (path.isEmpty()) return allowRoot
        if (path.startsWith('/') || path.contains('\\')) return false
        return path.split('/').all { component ->
            component.isNotEmpty() && component != "." && component != ".." &&
                !component.equals(".git", true) && !component.equals(".trash", true) &&
                !component.startsWith(".staging-", true) && !component.startsWith(".rish-write-", true) &&
                component.toByteArray(StandardCharsets.UTF_8).size <= 255 &&
                component.none { it.code <= 0x1f || it.code == 0x7f }
        }
    }

    private fun records(): MutableList<Record> {
        val array = try { JSONArray(prefs.getString(RECORDS, "[]")) } catch (_: Exception) { JSONArray() }
        val result = mutableListOf<Record>()
        for (index in 0 until array.length()) {
            val row = array.optJSONObject(index) ?: continue
            val id = row.optString("id")
            if (!isUuid(id)) continue
            result += Record(
                id,
                row.optString("display_name", "Workspace"),
                row.optString("origin", "rish_created"),
                row.optString("status", "ok"),
                row.optLong("binding_revision", 1),
                row.optString("created_at", AndroidClock.now()),
                row.optString("last_opened_at", AndroidClock.now()),
                row.optString("root_path").takeIf { it.isNotEmpty() },
                row.optString("tree_uri").takeIf { it.isNotEmpty() },
            )
        }
        return result
    }

    private fun saveRecords(rows: List<Record>) {
        val array = JSONArray()
        rows.forEach { row ->
            array.put(
                JSONObject()
                    .put("id", row.id)
                    .put("display_name", row.displayName)
                    .put("origin", row.origin)
                    .put("status", row.status)
                    .put("binding_revision", row.revision)
                    .put("created_at", row.createdAt)
                    .put("last_opened_at", row.lastOpenedAt)
                    .put("root_path", row.rootPath ?: JSONObject.NULL)
                    .put("tree_uri", row.treeUri ?: JSONObject.NULL),
            )
        }
        check(prefs.edit().putString(RECORDS, array.toString()).commit())
    }

    @Synchronized fun find(id: String): Record =
        records().firstOrNull { it.id == id }
            ?: throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace is not available.")

    private fun capabilities(record: Record): JSONObject = JSONObject()
        .put("read", record.status == "ok")
        .put("write", record.status == "ok")
        .put("git", false)
        .put("project_context", false)
        .put("files_visible", record.status == "ok")

    fun descriptor(record: Record, metadataOnly: Boolean = false): JSONObject {
        val flags = if (metadataOnly) JSONObject()
            .put("read", false)
            .put("write", false)
            .put("git", false)
            .put("project_context", false)
            .put("files_visible", false)
        else capabilities(record)
        return JSONObject()
            .put("schema_version", 2)
            .put("workspace_id", record.id)
            .put("display_name", record.displayName)
            .put("origin", record.origin)
            .put("status", record.status)
            .put("binding_revision", record.revision)
            .put("capabilities", flags)
            .put("created_at", record.createdAt)
            .put("last_opened_at", record.lastOpenedAt)
    }

    fun rootRef(record: Record): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("workspace_id", record.id)
        .put("binding_revision", record.revision)
        .put("project_id", JSONObject.NULL)

    @Synchronized fun listing(): JSONObject {
        val rows = JSONArray()
        records().sortedBy { it.displayName.lowercase() }.forEach { rows.put(descriptor(it)) }
        return JSONObject().put("schema_version", 1).put("workspaces", rows)
    }

    @Synchronized fun create(displayName: String): JSONObject {
        if (!validName(displayName)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        if (records().any { it.displayName == displayName }) {
            throw WorkspaceFailure("E_WORKSPACE_CONFLICT", "A workspace with that name already exists.")
        }
        val id = uuid()
        val root = File(context.filesDir, "rish-workspaces/$id")
        if (!root.mkdirs() && !root.isDirectory) throw WorkspaceFailure("E_WORKSPACE_IO", "Workspace could not be created.")
        File(root, ".trash").mkdirs()
        val now = AndroidClock.now()
        val record = Record(id, displayName, "rish_created", "ok", 1, now, now, root.absolutePath, null)
        saveRecords(records().apply { add(record) })
        return descriptor(record)
    }

    /** Grants a tree URI. Files are accessed in place; nothing is copied. */
    @Synchronized fun importTree(displayName: String, treeUri: Uri, origin: String): JSONObject {
        if (!validName(displayName)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val now = AndroidClock.now()
        val record = Record(uuid(), displayName, origin, "ok", 1, now, now, null, treeUri.toString())
        saveRecords(records().apply { add(record) })
        return descriptor(record)
    }

    @Synchronized fun updateTree(record: Record, treeUri: Uri): JSONObject {
        val next = record.copy(revision = record.revision + 1, lastOpenedAt = AndroidClock.now(), treeUri = treeUri.toString(), status = "ok")
        saveRecords(records().map { if (it.id == record.id) next else it })
        return descriptor(next)
    }

    @Synchronized fun remove(record: Record) {
        record.rootPath?.let { File(it).deleteRecursively() }
        record.treeUri?.let { value ->
            try {
                context.contentResolver.releasePersistableUriPermission(
                    Uri.parse(value),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (_: Exception) {
                // The grant may already be gone; forgetting the record still stands.
            }
        }
        saveRecords(records().filterNot { it.id == record.id })
        saveTrash(trashRecords().filterNot { it.workspaceId == record.id })
    }

    @Synchronized fun resolve(request: JSONObject): JSONObject {
        record(request.getString("workspace_id"))
        val expected = if (request.isNull("expected_binding_revision")) null else request.optLong("expected_binding_revision")
        val record = if (expected == null) record(request.getString("workspace_id")) else requireRevision(request.getString("workspace_id"), expected)
        val required = request.optJSONArray("required_capabilities") ?: JSONArray()
        for (index in 0 until required.length()) {
            if (required.optString(index) == "git" || required.optString(index) == "project_context") {
                throw WorkspaceFailure("E_WORKSPACE_CAPABILITY", "Workspace capability is unavailable.")
            }
        }
        val current = if (expected == null) record else touch(record)
        return JSONObject()
            .put("schema_version", 1)
            .put("disposition", "direct")
            .put("workspace", descriptor(current, metadataOnly = expected == null))
    }

    private fun record(id: String): Record = find(id)

    private fun requireRevision(id: String, revision: Long): Record {
        val record = find(id)
        if (record.revision != revision) throw WorkspaceFailure("E_WORKSPACE_REVISION_STALE", "Workspace binding is stale.")
        return record
    }

    private fun touch(record: Record): Record {
        val updated = record.copy(lastOpenedAt = AndroidClock.now())
        saveRecords(records().map { if (it.id == record.id) updated else it })
        return updated
    }

    @Synchronized fun forget(id: String, revision: Long) = remove(requireRevision(id, revision))

    // ---- file access -----------------------------------------------------

    private fun rootFile(record: Record, path: String): File {
        if (!validPath(path)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val rootPath = record.rootPath ?: throw WorkspaceFailure("E_WORKSPACE_IO", "Workspace root is unavailable.")
        val root = File(rootPath).canonicalFile
        val target = File(root, path).canonicalFile
        if (target != root && !target.path.startsWith(root.path + File.separator)) {
            throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace path escapes its root.")
        }
        return target
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun digest(file: File): String = when {
        file.isFile -> FileInputStream(file).use { input ->
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(32 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        }
        else -> sha256("directory:${file.name}".toByteArray(StandardCharsets.UTF_8))
    }

    private fun fileEntry(path: String, file: File): JSONObject {
        val kind = if (file.isDirectory) "directory" else "file"
        val size = if (file.isFile) file.length() else 0L
        return JSONObject()
            .put("path", path)
            .put("name", file.name)
            .put("kind", kind)
            .put("size", size)
            .put("modified_at", AndroidClock.now())
            .put("revision", digest(file))
    }

    private fun documentEntry(path: String, name: String, directory: Boolean, size: Long, modified: Long): JSONObject = JSONObject()
        .put("path", path)
        .put("name", name)
        .put("kind", if (directory) "directory" else "file")
        .put("size", size)
        .put("modified_at", AndroidClock.now())
        .put("revision", sha256("$path:$name:$size:$modified".toByteArray(StandardCharsets.UTF_8)))

    private data class Child(val uri: Uri, val name: String, val directory: Boolean, val size: Long, val modified: Long)

    private fun children(parent: Uri, parentId: String): List<Child> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(parent, parentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        val result = mutableListOf<Child>()
        context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            val idColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                val name = cursor.getString(nameColumn) ?: continue
                result += Child(
                    DocumentsContract.buildDocumentUriUsingTree(parent, cursor.getString(idColumn)),
                    name,
                    cursor.getString(mimeColumn) == DocumentsContract.Document.MIME_TYPE_DIR,
                    if (cursor.isNull(sizeColumn)) 0L else cursor.getLong(sizeColumn),
                    if (cursor.isNull(modifiedColumn)) 0L else cursor.getLong(modifiedColumn),
                )
            }
        }
        return result
    }

    private data class TreeRoot(val tree: Uri, val documentId: String)

    private fun treeRoot(record: Record): TreeRoot {
        val tree = Uri.parse(record.treeUri ?: throw WorkspaceFailure("E_WORKSPACE_IO", "Workspace root is unavailable."))
        return TreeRoot(tree, DocumentsContract.getTreeDocumentId(tree))
    }

    /** Resolves a relative path inside a granted tree, refusing anything else. */
    private fun document(record: Record, path: String): Child? {
        if (!validPath(path)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val (tree, rootId) = treeRoot(record)
        if (path.isEmpty()) return Child(DocumentsContract.buildDocumentUriUsingTree(tree, rootId), "", true, 0L, 0L)
        var current = rootId
        var found: Child? = null
        for (part in path.split('/')) {
            found = children(tree, current).firstOrNull { it.name == part }
                ?: throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace entry is not available.")
            current = DocumentsContract.getDocumentId(found.uri)
        }
        return found
    }

    private fun hidden(name: String): Boolean = name == ".trash" || name.equals(".git", true) || name.startsWith(".staging-") || name.startsWith(".rish-write-")

    @Synchronized fun list(record: Record, path: String, maxEntries: Int): JSONObject {
        if (maxEntries !in 1..MAX_LIST_ENTRIES) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val entries = JSONArray()
        if (record.rootPath != null) {
            val directory = rootFile(record, path)
            if (!directory.isDirectory) throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace entry is not available.")
            directory.listFiles()
                ?.filterNot { hidden(it.name) }
                ?.sortedBy { it.name.lowercase() }
                ?.take(maxEntries)
                ?.forEach { child -> entries.put(fileEntry(if (path.isEmpty()) child.name else "$path/${child.name}", child)) }
        } else {
            val directory = document(record, path) ?: throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace entry is not available.")
            val (tree, _) = treeRoot(record)
            children(tree, DocumentsContract.getDocumentId(directory.uri))
                .filterNot { hidden(it.name) }
                .sortedBy { it.name.lowercase() }
                .take(maxEntries)
                .forEach { child -> entries.put(documentEntry(if (path.isEmpty()) child.name else "$path/${child.name}", child.name, child.directory, child.size, child.modified)) }
        }
        return JSONObject().put("schema_version", 1).put("root", rootRef(record)).put("path", path).put("entries", entries)
    }

    @Synchronized fun read(record: Record, path: String, maxBytes: Int): JSONObject {
        if (maxBytes !in 1..MAX_TEXT_BYTES || !validPath(path, false)) {
            throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        }
        val bytes: ByteArray
        val entry: JSONObject
        if (record.rootPath != null) {
            val file = rootFile(record, path)
            if (!file.isFile) throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace entry is not available.")
            if (file.length() > maxBytes) throw WorkspaceFailure("E_WORKSPACE_IO", "File is larger than the request allows.")
            bytes = file.readBytes()
            entry = fileEntry(path, file)
        } else {
            val child = document(record, path) ?: throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace entry is not available.")
            if (child.directory) throw WorkspaceFailure("E_WORKSPACE_INVALID", "A directory cannot be read as text.")
            val stream = context.contentResolver.openInputStream(child.uri)
                ?: throw WorkspaceFailure("E_WORKSPACE_IO", "File could not be opened.")
            bytes = stream.use { it.readAtMost(maxBytes + 1) }
            if (bytes.size > maxBytes) throw WorkspaceFailure("E_WORKSPACE_IO", "File is larger than the request allows.")
            entry = documentEntry(path, child.name, false, bytes.size.toLong(), child.modified)
        }
        return JSONObject()
            .put("schema_version", 1)
            .put("root", rootRef(record))
            .put("path", path)
            .put("file", entry)
            .put("content", bytes.toString(StandardCharsets.UTF_8))
    }

    @Synchronized fun write(record: Record, path: String, content: String, expectedRevision: String?, createOnly: Boolean): JSONObject {
        if (!validPath(path, false)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val bytes = content.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > MAX_TEXT_BYTES) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        if (record.rootPath != null) {
            val file = rootFile(record, path)
            if (file.exists() && !file.isFile) throw WorkspaceFailure("E_WORKSPACE_INVALID", "The target is not a file.")
            if (createOnly && file.exists()) throw WorkspaceFailure("E_WORKSPACE_CONFLICT", "The file already exists.")
            if (file.exists() && expectedRevision != null && digest(file) != expectedRevision) {
                throw WorkspaceFailure("E_WORKSPACE_CONFLICT", "The file changed since it was read.")
            }
            file.parentFile?.mkdirs()
            val staging = File(file.parentFile, ".rish-write-${uuid()}")
            FileOutputStream(staging).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            if (!staging.renameTo(file)) {
                staging.delete()
                throw WorkspaceFailure("E_WORKSPACE_IO", "File could not be written.")
            }
            return JSONObject().put("schema_version", 1).put("root", rootRef(record)).put("file", fileEntry(path, file)).put("created", createOnly && !file.exists())
        }
        val parts = path.split('/').toMutableList()
        val name = parts.removeAt(parts.size - 1)
        val parent = document(record, parts.joinToString("/")) ?: throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace directory is not available.")
        if (!parent.directory) throw WorkspaceFailure("E_WORKSPACE_INVALID", "The parent is not a directory.")
        val existing = document(record, path)
        if (createOnly && existing != null) throw WorkspaceFailure("E_WORKSPACE_CONFLICT", "The file already exists.")
        if (existing != null && existing.directory) throw WorkspaceFailure("E_WORKSPACE_INVALID", "The target is not a file.")
        val uri = existing?.uri
            ?: DocumentsContract.createDocument(context.contentResolver, parent.uri, mime(name), name)
            ?: throw WorkspaceFailure("E_WORKSPACE_IO", "File could not be created.")
        context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
            ?: throw WorkspaceFailure("E_WORKSPACE_IO", "File could not be written.")
        val created = existing == null
        return JSONObject().put("schema_version", 1).put("root", rootRef(record)).put("file", documentEntry(path, name, false, bytes.size.toLong(), System.currentTimeMillis())).put("created", created)
    }

    @Synchronized fun mkdir(record: Record, path: String): JSONObject {
        if (!validPath(path, false)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val entry: JSONObject
        if (record.rootPath != null) {
            val directory = rootFile(record, path)
            if (!directory.mkdirs() && !directory.isDirectory) throw WorkspaceFailure("E_WORKSPACE_IO", "Directory could not be created.")
            entry = fileEntry(path, directory)
        } else {
            val parts = path.split('/').toMutableList()
            val name = parts.removeAt(parts.size - 1)
            val parent = document(record, parts.joinToString("/")) ?: throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace directory is not available.")
            if (!parent.directory) throw WorkspaceFailure("E_WORKSPACE_INVALID", "The parent is not a directory.")
            DocumentsContract.createDocument(context.contentResolver, parent.uri, DocumentsContract.Document.MIME_TYPE_DIR, name)
                ?: throw WorkspaceFailure("E_WORKSPACE_IO", "Directory could not be created.")
            entry = documentEntry(path, name, true, 0L, System.currentTimeMillis())
        }
        return JSONObject().put("schema_version", 1).put("root", rootRef(record)).put("directory", entry)
    }

    @Synchronized fun rename(record: Record, source: String, destination: String): JSONObject {
        if (!validPath(source, false) || !validPath(destination, false)) {
            throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        }
        val entry: JSONObject
        if (record.rootPath != null) {
            val from = rootFile(record, source)
            val to = rootFile(record, destination)
            if (!from.exists()) throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace entry is not available.")
            if (to.exists()) throw WorkspaceFailure("E_WORKSPACE_CONFLICT", "The destination already exists.")
            to.parentFile?.mkdirs()
            if (!from.renameTo(to)) throw WorkspaceFailure("E_WORKSPACE_IO", "Entry could not be renamed.")
            entry = fileEntry(destination, to)
        } else {
            val from = document(record, source) ?: throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace entry is not available.")
            if (document(record, destination) != null) throw WorkspaceFailure("E_WORKSPACE_CONFLICT", "The destination already exists.")
            DocumentsContract.renameDocument(context.contentResolver, from.uri, destination.substringAfterLast('/'))
                ?: throw WorkspaceFailure("E_WORKSPACE_IO", "Entry could not be renamed.")
            entry = documentEntry(destination, destination.substringAfterLast('/'), from.directory, from.size, System.currentTimeMillis())
        }
        return JSONObject().put("schema_version", 1).put("root", rootRef(record)).put("entry", entry).put("from", source)
    }

    private fun trashRecords(): MutableList<Trash> {
        val array = try { JSONArray(prefs.getString(TRASH, "[]")) } catch (_: Exception) { JSONArray() }
        val rows = mutableListOf<Trash>()
        for (index in 0 until array.length()) {
            val row = array.optJSONObject(index) ?: continue
            if (!isUuid(row.optString("id")) || !isUuid(row.optString("workspace_id"))) continue
            rows += Trash(
                row.getString("id"),
                row.getString("workspace_id"),
                row.getString("original_path"),
                row.getString("kind"),
                row.getString("deleted_at"),
                row.optString("saved_path").takeIf { it.isNotEmpty() },
            )
        }
        return rows
    }

    private fun saveTrash(rows: List<Trash>) {
        val array = JSONArray()
        rows.forEach { row ->
            array.put(
                JSONObject()
                    .put("id", row.id)
                    .put("workspace_id", row.workspaceId)
                    .put("original_path", row.originalPath)
                    .put("kind", row.kind)
                    .put("deleted_at", row.deletedAt)
                    .put("saved_path", row.savedPath ?: JSONObject.NULL),
            )
        }
        check(prefs.edit().putString(TRASH, array.toString()).commit())
    }

    private fun receipt(row: Trash): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("trash_id", row.id)
        .put("original_path", row.originalPath)
        .put("kind", row.kind)
        .put("deleted_at", row.deletedAt)

    @Synchronized fun trash(record: Record, path: String): JSONObject {
        if (!validPath(path, false)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val kind: String
        var saved: String? = null
        if (record.rootPath != null) {
            val source = rootFile(record, path)
            if (!source.exists()) throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace entry is not available.")
            kind = if (source.isDirectory) "directory" else "file"
            val target = File(File(record.rootPath, ".trash"), "${uuid()}-${source.name}")
            if (!source.renameTo(target)) throw WorkspaceFailure("E_WORKSPACE_IO", "Entry could not be moved to trash.")
            saved = target.absolutePath
        } else {
            val source = document(record, path) ?: throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Workspace entry is not available.")
            kind = if (source.directory) "directory" else "file"
            if (!DocumentsContract.deleteDocument(context.contentResolver, source.uri)) {
                throw WorkspaceFailure("E_WORKSPACE_IO", "Entry could not be removed.")
            }
        }
        val row = Trash(uuid(), record.id, path, kind, AndroidClock.now(), saved)
        saveTrash(trashRecords().apply { add(row) })
        return JSONObject().put("schema_version", 1).put("root", rootRef(record)).put("receipt", receipt(row))
    }

    @Synchronized fun listTrash(record: Record, maxEntries: Int): JSONObject {
        val limit = maxEntries.coerceIn(1, MAX_LIST_ENTRIES)
        val entries = JSONArray()
        trashRecords().filter { it.workspaceId == record.id }.take(limit).forEach { entries.put(receipt(it)) }
        return JSONObject().put("schema_version", 1).put("root", rootRef(record)).put("entries", entries).put("invalid_record_count", 0)
    }

    @Synchronized fun restore(record: Record, trashId: String, destination: String?): JSONObject {
        if (!isUuid(trashId)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val row = trashRecords().firstOrNull { it.id == trashId && it.workspaceId == record.id }
            ?: throw WorkspaceFailure("E_WORKSPACE_NOT_FOUND", "Trash entry is not available.")
        if (record.rootPath == null) throw WorkspaceFailure("E_WORKSPACE_IO", "This workspace keeps files in place, so restore is unavailable.")
        val targetPath = destination ?: row.originalPath
        if (!validPath(targetPath, false)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val target = rootFile(record, targetPath)
        if (target.exists()) throw WorkspaceFailure("E_WORKSPACE_CONFLICT", "The restore destination already exists.")
        val payload = File(row.savedPath ?: throw WorkspaceFailure("E_WORKSPACE_IO", "Trash payload is unavailable."))
        if (!payload.exists()) throw WorkspaceFailure("E_WORKSPACE_IO", "Trash payload is unavailable.")
        target.parentFile?.mkdirs()
        if (!payload.renameTo(target)) throw WorkspaceFailure("E_WORKSPACE_IO", "Trash entry could not be restored.")
        saveTrash(trashRecords().filterNot { it.id == row.id })
        return JSONObject()
            .put("schema_version", 1)
            .put("root", rootRef(record))
            .put("entry", fileEntry(targetPath, target))
            .put("trash_id", trashId)
            .put("original_path", row.originalPath)
    }

    @Synchronized fun tool(record: Record, tool: String, path: String, options: JSONObject): JSONObject {
        val names = setOf("cat", "grep", "head", "tail", "wc", "sha256sum")
        if (tool !in names || !validPath(path, false)) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
        val content = read(record, path, MAX_TEXT_BYTES).getString("content")
        val name = path.substringAfterLast('/')
        val output = when (tool) {
            "cat" -> content
            "sha256sum" -> "${sha256(content.toByteArray(StandardCharsets.UTF_8))}  $name\n"
            "wc" -> when (options.optString("metric", "lines")) {
                "words" -> "${content.trim().split(Regex("\\s+")).count { it.isNotEmpty() }} $name\n"
                "bytes" -> "${content.toByteArray(StandardCharsets.UTF_8).size} $name\n"
                else -> "${content.count { it == '\n' }} $name\n"
            }
            "head" -> content.lineSequence().take(options.optInt("lines", 40)).joinToString("\n")
            "tail" -> content.lines().takeLast(options.optInt("lines", 40)).joinToString("\n")
            else -> {
                val pattern = options.optString("pattern", "")
                val insensitive = options.optBoolean("case_insensitive", false)
                if (pattern.isEmpty()) throw WorkspaceFailure("E_WORKSPACE_INVALID", "Workspace request is invalid.")
                content.lineSequence().filter { line ->
                    if (insensitive) line.lowercase().contains(pattern.lowercase()) else line.contains(pattern)
                }.joinToString("\n")
            }
        }
        val bounded = if (output.toByteArray(StandardCharsets.UTF_8).size > MAX_TOOL_OUTPUT_BYTES) {
            String(output.toByteArray(StandardCharsets.UTF_8).copyOf(MAX_TOOL_OUTPUT_BYTES), StandardCharsets.UTF_8)
        } else output
        return JSONObject()
            .put("schema_version", 1)
            .put("root", rootRef(record))
            .put("tool", tool)
            .put("path", path)
            .put("exit_code", 0)
            .put("stdout", bounded)
            .put("stderr", "")
            .put("protocol_version", 1)
            .put("path_kind", "portable_applet")
    }

    private fun mime(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "text/plain"
}

private fun InputStream.readAtMost(limit: Int): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(32 * 1024)
    while (output.size() <= limit) {
        val count = read(buffer)
        if (count < 0) break
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}
