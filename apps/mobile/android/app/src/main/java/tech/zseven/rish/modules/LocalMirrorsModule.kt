package tech.zseven.rish.modules

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import tech.zseven.rish.RishUnavailable

/**
 * LocalMirrors — phase-1 Android skeleton.
 *
 * Mirrors the iOS registration in modules/rish/ios/Sources/LocalMirrorsModule.mm
 * (RCT_EXPORT_MODULE(LocalMirrors)) and the JS wrapper in
 * apps/mobile/src/native/LocalMirrors.ts. Every method rejects with the JS-
 * recognized "E_NATIVE_UNAVAILABLE" unavailable code; no success results are stubbed.
 */
class LocalMirrorsModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    override fun getConstants(): MutableMap<String, Any> = mutableMapOf("implemented" to false)

    override fun getName(): String = "LocalMirrors"

    @ReactMethod
    fun applyMirrors(mirrors: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalMirrors", "E_NATIVE_UNAVAILABLE", promise)

    @ReactMethod
    fun mirrorStatus(promise: Promise) = RishUnavailable.reject("LocalMirrors", "E_NATIVE_UNAVAILABLE", promise)
}
