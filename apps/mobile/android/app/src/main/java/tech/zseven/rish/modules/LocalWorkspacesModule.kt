package tech.zseven.rish.modules

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import tech.zseven.rish.RishUnavailable

/**
 * LocalWorkspaces — phase-1 Android skeleton.
 *
 * Mirrors the iOS registration in modules/rish/ios/Sources/LocalWorkspacesModule.mm
 * (RCT_EXPORT_MODULE(LocalWorkspaces)) and the JS wrapper in
 * apps/mobile/src/native/LocalWorkspaces.ts. Every method rejects with the JS-
 * recognized "E_WORKSPACE_UNAVAILABLE" unavailable code; no success results are stubbed.
 */
class LocalWorkspacesModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    override fun getConstants(): MutableMap<String, Any> = mutableMapOf("implemented" to false)

    override fun getName(): String = "LocalWorkspaces"

    @ReactMethod
    fun list(promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun create(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun bootstrapLegacyProject(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun presentFolderPicker(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun importSelection(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun cancelSelection(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun presentRegrantPicker(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun completeRegrant(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun resolve(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun forget(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun prepareDeleteOwnedContent(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun deleteOwnedContent(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun queryOperation(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun cancelPicker(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspaces", "E_WORKSPACE_UNAVAILABLE", promise)
}
