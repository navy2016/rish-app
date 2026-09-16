// C ABI of the shared Rish agent core (modules/rish/core, crate rish-agent-ffi).
//
// Every string-returning function hands back a NUL-terminated UTF-8 buffer
// owned by the library; release it with rish_agent_string_free. Inputs are
// UTF-8 with explicit lengths and are never retained. All functions are safe
// to call from any thread and never unwind across the boundary.
#ifndef RISH_AGENT_CORE_H
#define RISH_AGENT_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// JSON protocol version implemented by the library (see PROTOCOL_VERSION).
uint32_t rish_agent_protocol_version(void);

/// Releases a string returned by any function below. NULL is ignored.
void rish_agent_string_free(char *value);

/// Canonical JSON of a JSON text, or NULL when it is not JSON or cannot be
/// canonicalised (non-finite, negative zero, unsafe integer, depth > 64).
char *rish_agent_canonical_json(const char *json, size_t json_length);

/// DSHAgentHJ: SHA-256("rish.<tag>.v1\0" || canonical JSON), lowercase hex.
char *rish_agent_hash_json(const char *tag, size_t tag_length,
                           const char *json, size_t json_length);

/// DSHAgentHB: SHA-256("rish.<tag>.v1\0" || u64 big-endian length || bytes).
char *rish_agent_hash_bytes(const char *tag, size_t tag_length,
                            const uint8_t *bytes, size_t length);

/// Canonical form of tool arguments when the strict parser accepts them.
char *rish_agent_parse_arguments(const char *json, size_t json_length);

/// One schema-3 round-journal operation over a JSON envelope
/// {"op","args","env","view"}; returns {"ok":true,...} or
/// {"ok":false,"error":<DSHAgentNativeStoreErrorCode>}. NULL only when the
/// input is not UTF-8.
char *rish_agent_round_reduce(const char *json, size_t json_length);

/// One execution-ledger row operation over a JSON envelope
/// {"op","args","env","view"}; returns {"ok":true,...} with the change list
/// and optional operation commit, or {"ok":false,"error":<code>}. NULL only
/// when the input is not UTF-8.
char *rish_agent_ledger_reduce(const char *json, size_t json_length);

/// One batch-level ledger operation (prepare_tool_batch / open_effect_gate)
/// over {"op","request","env","view"}; same reply shape as the row reducer.
char *rish_agent_ledger_batch_reduce(const char *json, size_t json_length);

/// One transcript-store operation over {"op","request","env","view"}.
char *rish_agent_transcript_reduce(const char *json, size_t json_length);

/// One session-schema operation: `request` is {"op","env"} JSON, `input` the
/// operation's raw bytes (candidate JSON, stored envelope, tombstone file; any
/// bytes, empty allowed). Ops: candidate (validation + digest),
/// candidate_digest (lenient), envelope, tombstones, legacy_root. Same reply
/// shape as the reducers.
char *rish_agent_session_reduce(const char *request, size_t request_length,
                                const uint8_t *input, size_t input_length);

/// One tool-batch-service decision over {"op","request",...}: prepare_request,
/// prepare_gate, prepare_calls, prepare_finish, prepare_final,
/// prepare_ledger_failure, bind_request, bind_check.
char *rish_agent_tool_batch_reduce(const char *json, size_t json_length);

/// One tool-execution-service decision over {"op","request",...}: request,
/// session_matches, row, precheck, conflict, arguments, recover_arguments,
/// effect_gate, execution_cas, active_result, safe_result, generic_failure,
/// ambiguous_effect, settlement, settle_failed, recover.
char *rish_agent_tool_execution_reduce(const char *json, size_t json_length);

/// One prepared-attempt-store decision over {"op","request",...}: request,
/// session (takes the committed session's exact JSON bytes), observed,
/// conflict, session_matches, projection, transaction.
char *rish_agent_prepared_attempt_reduce(const char *json, size_t json_length,
                                         const uint8_t *session, size_t session_length);

/// Validates one stored WAL row over {"op","value","env"?}: reference,
/// message, reservation, cleanup, dispatch, write_prior, policy, registry,
/// authority, result_reference, snapshot_reference, operation,
/// operation_result, opaque_call_id, tool_feedback.
char *rish_agent_wal_state_reduce(const char *json, size_t json_length);

/// One WAL operation-relation decision over
/// {"op","state","arguments","timestamp"?,"snapshot"?}: start, start_target,
/// query, commit_prepare, commit_apply, prepare_authority, record_batch,
/// record_denied_call. The reply is {"result":"commit"|"replay"|"proceed"|
/// "error", ...}; the host applies "changes" only once it has written and
/// confirmed the transaction.
char *rish_agent_wal_operation_reduce(const char *json, size_t json_length);

/// One storage root's resident WAL state. rish_agent_wal_open adopts a state
/// the host has read and validated and returns an opaque handle;
/// rish_agent_wal_snapshot reads the committed state back;
/// rish_agent_wal_begin takes a candidate and returns the exact bytes to
/// write; rish_agent_wal_confirm resolves it with "committed",
/// "not_committed" or "unknown". An unknown confirmation is never downgraded
/// to not-committed: it invalidates the handle, snapshot then returns NULL,
/// and only a fresh read from disk can make a new one. Close with
/// rish_agent_wal_close.
void *rish_agent_wal_open(const char *json, size_t json_length);
char *rish_agent_wal_snapshot(void *handle);
char *rish_agent_wal_begin(void *handle, const char *json, size_t json_length);
char *rish_agent_wal_confirm(void *handle, const char *outcome, size_t outcome_length);
void rish_agent_wal_close(void *handle);

/// The frozen tool table over {"op","guest_cgi"?,"root"?,"name"?,"registry"?}:
/// toolset_sha256, registry, policy, descriptor, native_descriptor,
/// registry_shape. Whether this build has the guest CGI tools is the host's
/// to say and changes the toolset digest.
char *rish_agent_tool_registry_reduce(const char *json, size_t json_length);

/// Parses one provider completion response over
/// {"op":"parse","response","requested_model","model_supported","thinking_mode",
/// "fallback_call_id"}. This is where untrusted model output becomes something
/// executable. The reply is {"ok":true,"parsed":{...}} or
/// {"ok":false,"failure_code":"E_COMPLETION_..."} — a failure code, not a store
/// error code, because a provider reply is not a store operation.
char *rish_agent_completion_response_reduce(const char *json, size_t json_length);

/// One Git-tool decision over {"op",...}: timezone_string, timezone_minutes,
/// index_digest,
/// commit_identity, failure_result. libgit2 stays with the host; which staged
/// paths may be committed, the exact bytes of the commit object and therefore
/// the id it will have are decided here — predicting that id is what makes a
/// crash between writing the object and recording it recoverable.
char *rish_agent_git_tool_reduce(const char *json, size_t json_length);

/// One workspace-tool decision over {"op",...}: bounds, path_components,
/// revision, directory_listing, diff_preview, write_expected_prior, feedback,
/// failure_result. The host owns the descriptors and the bytes; which paths it
/// may touch, what a listing looks like and what a person is shown before
/// approving a write are decided here.
char *rish_agent_workspace_tool_reduce(const char *json, size_t json_length);

/// The frozen root projection over {"op",...}: projection_shape, capabilities,
/// grants, resolve_request, workspace_projection, project_projection, root_ref,
/// operation_mode, final_proof_request, matches. Resolving a root is the
/// host's job; every judgement it makes on the way is decided here.
char *rish_agent_root_reduce(const char *json, size_t json_length);

/// One runtime-coordinator decision over
/// {"op","request","state"?,"session"?,"facts"?,"proof"?,"base"?,"queried"?}:
/// query_tool_request, query_attempt_request, presentations_request,
/// session_proof, session_owns_attempt, query_tool_session_conflict,
/// query_tool_ledger_conflict, query_tool_result,
/// query_attempt_session_conflict, query_attempt_base_conflict,
/// query_attempt_projection, tool_projection, latest_batch_calls,
/// cleanup_outbox_proof, cancel_source_proof, child_operation_id.
char *rish_agent_runtime_reduce(const char *json, size_t json_length);

/// One provider-round decision over {"op","request",...}: round_request,
/// selector_request, selector_matches, result_shape, round_cas, locator_key,
/// assistant_message, public_receipt, recovered_projection, context_bundle,
/// conflict, unknown_result, round_result, query_result, selector_conflict,
/// failure_code, safe_result, tool_description, transcript_body,
/// started_operation_commit, public_result, round_failure_code.
char *rish_agent_provider_round_reduce(const char *json, size_t json_length);

/// "rish-agent-core <version> <git sha>" of the linked build; free with
/// rish_agent_string_free.
char *rish_agent_build_id(void);

#ifdef __cplusplus
}
#endif

#endif
