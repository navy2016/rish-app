package tech.zseven.rish.modules

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import org.json.JSONObject
import tech.zseven.rish.RishUnavailable
import tech.zseven.rish.runtime.AndroidPreparedAttemptStore
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.RuntimeJson

/**
 * AgentRuntime on Android.
 *
 * Mirrors the iOS registration in modules/rish/ios/Sources/AgentRuntimeModule.mm
 * (RCT_EXPORT_MODULE(AgentRuntime)) and the JS wrapper in
 * apps/mobile/src/native/AgentRuntime.ts.
 *
 * `prepare_agent_attempt` is served: it reads the committed session and writes
 * the agent WAL through the shared core, exactly as iOS does. Every attempt
 * here is **rootless**, because Android resolves no workspace root, so the core
 * commits it as `not_agent` / `E_AGENT_NO_ROOT` — a definite answer meaning
 * "this attempt gets no agent authority", not "there is no agent engine". The
 * rest of the surface still rejects with "E_AGENT_NATIVE".
 *
 * `implemented` stays false: the JS layer reads it as "the whole agent surface
 * is available", and one served operation is not that.
 */
class AgentRuntimeModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    private val runtime = AndroidRuntimeState.get(reactContext)

    override fun getConstants(): MutableMap<String, Any> = mutableMapOf("implemented" to false)

    override fun getName(): String = "AgentRuntime"

    @ReactMethod
    fun prepare_agent_attempt(request: ReadableMap?, promise: Promise) {
        val captured = try {
            JSONObject(requireNotNull(request).toHashMap())
        } catch (_: Exception) {
            promise.reject("E_AGENT_BAD_ARGUMENTS", "Agent attempt request is invalid")
            return
        }
        runtime.io.execute {
            try {
                val result = runtime.preparedAttempts.prepareAgentAttempt(captured)
                promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(result)))
            } catch (refused: AndroidPreparedAttemptStore.Refused) {
                // The store's own vocabulary reaches JS unchanged; a code the
                // controller does not know would be worse than a stable one.
                promise.reject(refused.code, "Agent attempt could not be prepared")
            } catch (_: Exception) {
                promise.reject("E_AGENT_NATIVE", "Agent attempt could not be prepared")
            }
        }
    }

    @ReactMethod
    fun complete_agent_round_v2(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)

    @ReactMethod
    fun prepare_agent_tool_batch(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)

    @ReactMethod
    fun bind_agent_approval(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)

    @ReactMethod
    fun execute_agent_tool(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)

    @ReactMethod
    fun cancel_agent_attempt(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)

    @ReactMethod
    fun query_agent_attempt(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)

    @ReactMethod
    fun query_agent_tool(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)

    @ReactMethod
    fun recover_agent_attempt(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)

    @ReactMethod
    fun finalize_agent_attempt(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)

    @ReactMethod
    fun discard_agent_attempt(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)

    @ReactMethod
    fun query_agent_cleanup(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("AgentRuntime", "E_AGENT_NATIVE", promise)
}
