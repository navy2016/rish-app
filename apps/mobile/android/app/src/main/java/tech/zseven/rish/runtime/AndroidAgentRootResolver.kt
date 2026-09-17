package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * Turns a workspace binding into the root an agent attempt runs against.
 *
 * The evidence is this host's: which record the registry holds, whether its
 * authority still proves the directory on disk. The projection — what that
 * evidence entitles the root to — is the shared rule's
 * ([RishAgentCoreNative.agentRoot], `root_projection.rs`), so a root resolved
 * here carries exactly the capabilities the same evidence would carry on iOS.
 *
 * **Projects are not resolvable here.** A project root needs an independently
 * verified project lease, and Android has no project subsystem. A request that
 * names a `project_id` is refused rather than answered with a workspace root
 * wearing a project's name — the caller asked a question this platform cannot
 * answer, and saying so is the honest reply.
 *
 * **A root that cannot be proven is no root.** Not a read-only root, not a
 * stale one to be repaired: [resolve] returns null and the caller reports the
 * binding as stale.
 */
internal class AndroidAgentRootResolver(private val workspaces: AndroidWorkspaceRegistry) {
    /** The grants a workspace root may carry; a project's three are not here. */
    private val workspaceGrants = listOf("read", "write", "git")

    /**
     * The root for a binding, or null when there is none to be had — the
     * request names no root, names a project, names a workspace this device
     * does not hold, or names one whose directory can no longer be proven.
     */
    fun resolve(
        workspaceId: String?,
        projectId: String?,
        bindingRevision: Int?,
    ): JSONObject? {
        if (!RishAgentCoreNative.available) return null
        // Whether this is even a well-formed root request is the rule's call.
        val request = RishAgentCoreNative.agentRoot(
            JSONObject().put("op", "resolve_request")
                .put("workspace_id", workspaceId ?: JSONObject.NULL)
                .put("project_id", projectId ?: JSONObject.NULL)
                .put("binding_revision", bindingRevision ?: JSONObject.NULL),
        ) ?: return null
        if (request.optString("outcome") != "resolve") return null
        // A project root is a question this platform cannot answer.
        if (request.optString("kind") != "workspace") return null

        val id = request.optString("workspace_id")
        val revision = request.optInt("binding_revision", -1)
        if (revision < 0) return null

        val record = workspaces.list().firstOrNull { it.optString("workspace_id") == id }
            ?: return null
        // The binding has to be the one asked about. An older revision is not
        // a stale version of this root; it is a different one.
        if (record.opt("binding_revision") != revision) return null

        val descriptor = workspaces.descriptor(id) ?: return null
        if (descriptor.optString("status") != "ok") return null
        val capabilities = descriptor.optJSONObject("capabilities") ?: return null
        val grants = JSONArray()
        for (grant in workspaceGrants) {
            if (capabilities.optBoolean(grant)) grants.put(grant)
        }

        val fingerprint = workspaces.fingerprintFor(id) ?: return null
        val reply = RishAgentCoreNative.agentRoot(
            JSONObject().put("op", "workspace_projection")
                .put("workspace_id", id)
                .put("binding_revision", revision)
                .put("root_fingerprint_sha256", fingerprint)
                .put("grants", grants)
                // Android ships no guest CGI tools, and the toolset digest
                // every stored authority is bound to says so too.
                .put("guest_cgi", false),
        ) ?: return null
        return reply.optJSONObject("root")
    }

}
