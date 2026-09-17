package tech.zseven.rish.modules

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableMap
import org.json.JSONObject
import tech.zseven.rish.RishUnavailable
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RuntimeJson

/**
 * LocalProjects on Android.
 *
 * Mirrors the iOS registration in modules/rish/ios/Sources/LocalProjectsModule.mm
 * (RCT_EXPORT_MODULE(LocalProjects)) and the JS wrapper in
 * apps/mobile/src/native/LocalProjects.ts.
 *
 * Only [projectForWorkspaceV2] answers. It is the question the workspace
 * binding asks after it resolves a workspace and before it commits: whether a
 * git project is attached to this root. A workspace this app owns and just
 * made has none, and saying so is what lets a person bind a working directory
 * at all -- rejecting it failed the whole bind at the last step.
 *
 * Everything else still rejects with the JS-recognized "E_PROJECT_NATIVE"; no
 * success is stubbed anywhere, and nothing here pretends a repository exists.
 */
class LocalProjectsModule(private val react: ReactApplicationContext) :
    ReactContextBaseJavaModule(react) {

    private val runtime by lazy { AndroidRuntimeState.get(react) }

    override fun getConstants(): MutableMap<String, Any> =
        mutableMapOf("implemented" to RishAgentCoreNative.available)

    override fun getName(): String = "LocalProjects"

    @ReactMethod
    fun list(promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun create(name: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun clone(url: String?, name: String?, options: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun status(projectId: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun diff(projectId: String?, options: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun stageAll(projectId: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun commit(projectId: String?, input: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun setRemote(projectId: String?, url: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun credentialStatus(projectId: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun presentCredentialPrompt(projectId: String?, locale: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun clearCredential(projectId: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun push(projectId: String?, options: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun attachWorkspaceProject(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun projectForWorkspaceV2(request: ReadableMap?, promise: Promise) {
        runtime.io.execute {
            try {
                val root = RuntimeJson.fromBridgeMap(
                    (request ?: throw IllegalArgumentException("root")).toHashMap(),
                )
                // The root reference is the agent's, and whether it names a
                // workspace this device holds is the resolver's answer, not
                // this module's. Asking it also refuses a root that names a
                // project, which is exactly what must not be answered here.
                val resolved = runtime.roots.resolve(
                    workspaceId = root.optString("workspace_id").takeIf { it.isNotEmpty() },
                    projectId = root.opt("project_id")?.takeIf { it != JSONObject.NULL } as? String,
                    bindingRevision = root.opt("binding_revision") as? Int,
                )
                if (resolved == null) {
                    RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)
                    return@execute
                }
                // No project is attached to a workspace this app owns: nothing
                // here ever attached one, and `attachWorkspaceProject` still
                // refuses. "none" is the true answer, not a placeholder.
                val reply = JSONObject().put("schema_version", 1).put("status", "none")
                promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(reply)))
            } catch (error: Throwable) {
                RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)
            }
        }
    }

    @ReactMethod
    fun prepareProjectDetachV1(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun commitProjectDetachV1(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun statusV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun diffV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun stageAllV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun commitV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun pushV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)
}
