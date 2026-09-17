package tech.zseven.rish.modules

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import tech.zseven.rish.RishUnavailable

/**
 * LocalWorkspace — phase-1 Android skeleton.
 *
 * Mirrors the iOS registration in modules/rish/ios/Sources/LocalWorkspaceModule.mm
 * (RCT_EXPORT_MODULE(LocalWorkspace)) and the JS wrapper in
 * apps/mobile/src/native/LocalWorkspace.ts. Every method rejects with the JS-
 * recognized "E_WORKSPACE_UNAVAILABLE" unavailable code; no success results are stubbed.
 */
class LocalWorkspaceModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    override fun getConstants(): MutableMap<String, Any> = mutableMapOf("implemented" to false)

    override fun getName(): String = "LocalWorkspace"

    @ReactMethod
    fun capabilities(promise: Promise) = RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun listV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun readV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun writeV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun createDirectoryV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun renameEntryV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun trashEntryV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun listTrashV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun restoreFromTrashV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun executePortableToolV2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)
}
