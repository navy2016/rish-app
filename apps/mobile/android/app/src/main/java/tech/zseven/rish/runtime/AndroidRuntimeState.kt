package tech.zseven.rish.runtime

import android.app.Application
import android.content.Context
import android.os.Build
import org.json.JSONObject
import java.util.concurrent.Executors

internal class AndroidRuntimeState private constructor(val app: Application) {
    init { AndroidDshModelCatalog.initialize(app) }
    val credentials = AndroidCredentialStore(app)
    val configurations = AndroidProviderConfiguration(app)
    val sessions = AndroidSessionStore(app)
    /// The agent WAL lives beside the session database, outside backup, in the
    /// same bytes iOS writes. One root, because Android resolves none.
    val agentWal = AndroidAgentWal(java.io.File(app.noBackupFilesDir, "agent"))
    /// App-private workspace roots. Android resolves only these: no
    /// security-scoped folders, no legacy projects, no rebinding yet.
    val workspaces = AndroidWorkspaceRegistry(java.io.File(app.filesDir, "workspaces"))
    val roots = AndroidAgentRootResolver(workspaces)
    val preparedAttempts = AndroidPreparedAttemptStore(sessions, agentWal, roots)
    /// Which native tasks this process still owns; a persisted owner from a
    /// previous launch is not alive, so its rows can be recovered.
    val liveTasks = AndroidLiveTasks()
    val executionLedger = AndroidAgentExecutionLedger(agentWal, liveTasks)
    val workspaceTools = AndroidWorkspaceToolExecutor(workspaces, roots)
    val agentRounds = AndroidAgentRoundJournal(agentWal, liveTasks)
    val toolBatch = AndroidAgentToolBatchService(
        agentWal, sessions, preparedAttempts, executionLedger, roots, workspaceTools,
    )
    val toolExecution = AndroidAgentToolExecutionService(
        agentWal, sessions, preparedAttempts, executionLedger, roots, workspaceTools, liveTasks,
    )
    val transport = AndroidModelTransport(credentials, configurations)
    val providerRound = AndroidAgentProviderRoundService(
        sessions, preparedAttempts, agentRounds, roots, AndroidAgentToolRegistry, transport, agentWal,
    )
    val subscriptionAuth = AndroidSubscriptionAuthManager(app)
    val io = Executors.newFixedThreadPool(2)
    @Volatile var selectedSlot = "DEEPSEEK_API_KEY"
    @Volatile var restored = false
    companion object {
        @Volatile private var instance: AndroidRuntimeState? = null
        fun get(context: Context): AndroidRuntimeState = instance ?: synchronized(this) {
            instance ?: AndroidRuntimeState(context.applicationContext as Application).also { instance = it }
        }
    }
    fun loadSnapshot(): JSONObject = sessions.load().also {
        if(it.getString("status") == "present" && it.getString("writer_launch_instance_id") != AndroidSessionStore.launchId) restored = true
    }
    fun proof(): JSONObject {
        val hasCredential = transport.configured(selectedSlot)
        val model = transport.lastModel
        val harness = when(selectedSlot) { "BIGMODEL_API_KEY" -> "glm"; "OPENAI_API_KEY" -> "codex"; "ANTHROPIC_API_KEY" -> "claude-code"; else -> "dsh" }
        val proof = JSONObject().put("schema_version", 2).put("product", "rish").put("active_harness", harness)
            .put("mode", "local_substrate").put("platform", if(Build.HARDWARE in setOf("ranchu", "goldfish")) "android_emulator" else "android_device")
            .put("bundle_id", app.packageName).put("runtime_id", "rish-android-api-v1").put("launch_instance_id", AndroidSessionStore.launchId)
            .put("process_id", android.os.Process.myPid()).put("generated_at", RuntimeJson.now())
            .put("container_root", app.filesDir.absolutePath).put("session_store", app.getDatabasePath("rish.sessions.v1.db").absolutePath)
            .put("model_transport", "okhttp").put("rish_backend", "unavailable").put("rish_protocol_version", 0)
            .put("rish_probe", JSONObject().put("path_kind", "unavailable").put("exit_code", -1))
            .put("mac_dsh_port_3180_reachable", JSONObject.NULL)
            .put("checks", JSONObject().put("credential_in_keychain", false).put("credential_in_secure_store", hasCredential)
                .put("model_response_received", model != null && AndroidProviderConfiguration.harness(model) == harness)
                .put("session_restored_after_restart", restored).put("rish_applet_executed", false))
        transport.lastProof?.let { proof.put("model_response", JSONObject(it.toString())) }
        return JSONObject().put("proof", proof).put("rish", JSONObject().put("available", false))
    }
}
