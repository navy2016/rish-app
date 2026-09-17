import { ALL_AGENT_TOOL_NAMES, agentToolRegistryCompatible, agentRegistryToolLimit, isRuntimeAgentTool } from '../agent/tool-registry';
import { isHarnessModelId } from '../harness/types';
import { nativeImplementationAvailable } from './NativeImplementation';
import { parseProviderBinding } from '../providers/configuration';
import {
  agentRuntimeDiagnosticFromError,
  parseAgentRuntimeDiagnostic,
  type AgentRuntimeDiagnostic,
} from './agent-runtime-diagnostic';
import type { ProviderBinding } from '../providers/configuration';
import { NativeModules, TurboModuleRegistry } from 'react-native';

import type {
  DeepSeekThinkingMode,
  HarnessModelId,
} from '../completion/types';
import type { HarnessId } from '../harness/types';
import { isHarnessId } from '../harness/types';

export type {
  DeepSeekModelId,
  DeepSeekThinkingMode,
  HarnessModelId,
} from '../completion/types';
export type { HarnessId } from '../harness/types';

/** Closed failure vocabulary exposed by the high-level Agent bridge. */
export type AgentRuntimeFailureCode =
  | 'E_AGENT_UNKNOWN_TOOL'
  | 'E_AGENT_BAD_ARGUMENTS'
  | 'E_AGENT_BAD_PATH'
  | 'E_AGENT_NO_ROOT'
  | 'E_AGENT_ROOT_STALE'
  | 'E_AGENT_CAPABILITY'
  | 'E_AGENT_APPROVAL'
  | 'E_AGENT_TRANSCRIPT'
  | 'E_AGENT_LEDGER'
  | 'E_AGENT_ROUND_AMBIGUOUS'
  | 'E_AGENT_EXECUTION_AMBIGUOUS'
  | 'E_AGENT_RETRY_LINEAGE'
  | 'E_AGENT_PERSISTENCE'
  | 'E_AGENT_CONFLICT'
  | 'E_AGENT_ROUND_LIMIT'
  | 'E_AGENT_CANCELLED'
  | 'E_AGENT_TOOL_FAILED'
  | 'E_AGENT_DENIED_BY_USER'
  | 'E_AGENT_NATIVE'
  | 'E_AGENT_NOT_FOUND'
  | 'E_AGENT_CAPACITY'
  | 'E_COMPLETION_LENGTH'
  | 'E_COMPLETION_CONTENT_FILTER';

/** Supported native tool registry generations; old sessions retain their version. */
export type AgentRegistryVersion = 1 | 2 | 3;

export type AgentFailureCode = Exclude<
  AgentRuntimeFailureCode,
  'E_AGENT_NATIVE' | 'E_AGENT_NOT_FOUND'
>;

export type AgentRuntimeRootV1 = {
  readonly schema_version: 1;
  readonly kind: 'project' | 'workspace';
  readonly workspace_id: string;
  readonly workspace_binding_revision: number;
  readonly project_id: string | null;
  readonly root_fingerprint_sha256: string;
  readonly capabilities: readonly (
    | 'file_read'
    | 'file_write'
    | 'git_status'
    | 'git_commit'
    | 'git_push'
    | 'guest_service'
  )[];
};

export type AgentRuntimePolicyV1 = {
  readonly schema_version: 1;
  readonly policy_version: 'agent-v1';
  readonly max_single_write_bytes: 32768;
  readonly max_batch_write_bytes: number;
  readonly max_attempt_write_bytes: number;
};

export type AgentRuntimeTranscriptHandleV1 = {
  readonly schema_version: 1;
  readonly transcript_ref: string;
  readonly generation: number;
  readonly transcript_sha256: string;
  readonly transcript_bytes: number;
};

export type AgentToolReceiptV1 = {
  readonly schema_version: 1;
  readonly call_id: string;
  readonly name: string;
  readonly arguments_sha256: string;
  readonly result_sha256: string;
  readonly result_bytes: number;
  readonly truncated: boolean;
  readonly duration_ms: number;
  readonly outcome: 'ok' | 'failed' | 'denied' | 'cancelled' | 'ambiguous';
  readonly failure_code: AgentFailureCode | null;
  readonly approval_reference: string | null;
};

export type AgentConversationGrantV2 = {
  readonly schema_version: 2;
  readonly grant_id: string;
  readonly conversation_id: string;
  readonly workspace_id: string;
  readonly project_id: string | null;
  readonly binding_revision: number;
  readonly root_fingerprint_sha256: string;
  readonly tool_family: 'file_write' | 'git_commit' | 'git_push' | 'guest_service';
  readonly registry_version: AgentRegistryVersion;
  readonly policy_version: string;
  readonly issued_for: {
    readonly schema_version: 1;
    readonly task_id: string;
    readonly attempt_id: string;
  };
  readonly created_at: string;
};

export type AgentRuntimeControllerCASV1 = {
  readonly schema_version: 1;
  readonly conversation_id: string;
  readonly task_id: string;
  readonly attempt_id: string;
  readonly expected_controller_generation: number;
  readonly expected_journal_revision: number;
  readonly expected_session_generation: number;
  readonly expected_session_sha256: string;
};

export type AgentRuntimeCommittedCheckpointV1 = {
  readonly schema_version: 1;
  readonly journal_revision: number;
  readonly session_generation: number;
  readonly session_sha256: string;
};

export type AgentRuntimeRegistryToolV2 = {
  readonly schema_version: 2;
  readonly name: string;
  readonly safe_summary_key: string;
  readonly access:
    | 'auto'
    | 'conversation_confirm'
    | 'confirm_once'
    | 'durable_deny';
};

export type AgentRuntimeRegistryV2 = {
  readonly schema_version: 2;
  readonly registry_version: AgentRegistryVersion;
  readonly toolset_sha256: string;
  readonly tools: readonly AgentRuntimeRegistryToolV2[];
};

export type AgentApprovalBindingTokenV2 = {
  readonly schema_version: 2;
  readonly token: string;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly task_id: string;
  readonly attempt_id: string;
  readonly round_id: string;
  readonly round_index: number;
  readonly batch_call_ids: readonly string[];
  readonly batch_arguments_sha256: readonly string[];
  readonly batch_revision: number;
  readonly manifest_sha256: string;
  readonly call_index: number;
  readonly call_id: string;
  readonly name: string;
  readonly arguments_sha256: string;
  readonly idempotency_key: string;
  readonly root_fingerprint_sha256: string;
  readonly binding_revision: number;
  readonly policy_version: 'agent-v1';
  readonly registry_version: AgentRegistryVersion;
  readonly access: 'conversation_confirm' | 'confirm_once';
  readonly allowed_decisions: readonly (
    | 'denied'
    | 'allow_once'
    | 'allow_conversation'
    | 'cancelled'
  )[];
};

/** Bounded native-computed approval preview. Paths are workspace-relative
 * validated strings; the diff preview is display-only text derived from the
 * prepared intent, never from unvalidated model output. */
export type AgentApprovalPreviewV1 = {
  readonly schema_version: 1;
  readonly kind:
    | 'list_dir'
    | 'read_file'
    | 'write_file'
    | 'git_commit'
    | 'git_push'
    | 'start_guest_cgi'
    | 'stop_guest_cgi'
    | 'list_runtime_environments'
    | 'install_runtime_environment'
    | 'run_program'
    | 'start_runtime_service'
    | 'stop_runtime_service';
  readonly paths: readonly string[];
  readonly content_bytes: number | null;
  readonly prior:
    | {
        readonly schema_version: 1;
        readonly kind: 'absent' | 'known';
        readonly bytes: number | null;
      }
    | null;
  readonly diff_preview: string | null;
  readonly diff_truncated: boolean;
};

export type AgentBatchCallProjectionV2 = {
  readonly schema_version: 2;
  readonly call_index: number;
  readonly call_id: string;
  readonly name: string;
  readonly arguments_sha256: string;
  readonly idempotency_key: string | null;
  readonly safe_summary_key: string;
  readonly approval_preview: AgentApprovalPreviewV1 | null;
  readonly access:
    | 'auto'
    | 'conversation_confirm'
    | 'confirm_once'
    | 'durable_deny';
  readonly approval_state:
    | 'not_required'
    | 'pending'
    | 'bound'
    | 'denied'
    | 'cancelled';
  readonly approval_token: AgentApprovalBindingTokenV2 | null;
  readonly approval_reference: string | null;
  readonly execution_status:
    | 'not_started'
    | 'intent'
    | 'running'
    | 'cancel_requested'
    | 'completed'
    | 'failed'
    | 'denied'
    | 'cancelled'
    | 'unknown'
    | 'ambiguous';
  readonly execution_revision: number | null;
  readonly native_row_revision: number | null;
  readonly receipt: AgentToolReceiptV1 | null;
};

export type AgentAttemptProjectionV2 = {
  readonly schema_version: 2;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly phase:
    | 'not_agent'
    | 'ready_for_round'
    | 'round_in_flight'
    | 'batch_frozen'
    | 'approval_pending'
    | 'execution_intent'
    | 'tool_result_pending'
    | 'final_response'
    | 'cancelled'
    | 'failed'
    | 'unknown'
    | 'ambiguous';
  readonly controller_generation: number;
  readonly journal_revision: number;
  readonly authority_revision: number;
  readonly root: AgentRuntimeRootV1 | null;
  readonly policy: AgentRuntimePolicyV1 | null;
  readonly registry: AgentRuntimeRegistryV2;
  readonly transcript: AgentRuntimeTranscriptHandleV1 | null;
  readonly round_index: number;
  readonly round_id: string | null;
  readonly round_revision: number | null;
  readonly round_status:
    | 'ready'
    | 'active'
    | 'failed_retryable'
    | 'completed'
    | 'cancel_requested'
    | 'cancelled'
    | 'unknown'
    | 'ambiguous'
    | null;
  readonly batch_kind: 'write_batch' | 'read_only_batch' | null;
  readonly batch_revision: number | null;
  readonly manifest_sha256: string | null;
  readonly call_index: number | null;
  readonly batch: readonly AgentBatchCallProjectionV2[];
  readonly frozen_grant_ids: readonly string[];
  readonly reserved_write_bytes: number;
  readonly cancel_source_event_id: string | null;
  readonly cleanup_id: string | null;
};

export type AgentRoundReceiptV2 = {
  readonly provider_configuration?: ProviderBinding;
  readonly schema_version: 2;
  readonly transport_schema_version: 2 | 3;
  readonly turn_id: string;
  readonly task_id: string;
  readonly attempt_id: string;
  readonly round_id: string;
  readonly round_index: number;
  readonly provider_request_id: string;
  readonly provider_response_id: string;
  /** Harness that produced this response; absent on legacy receipts (dsh). */
  readonly harness_id?: HarnessId;
  readonly requested_model: HarnessModelId;
  readonly model: HarnessModelId;
  readonly thinking_mode: DeepSeekThinkingMode;
  readonly finish_reason: 'stop' | 'tool_calls' | 'length' | 'content_filter';
  readonly latency_ms: number;
  readonly visible_history_sha256: string;
  readonly model_input_sha256: string;
  readonly request_body_sha256: string;
  readonly project_context_receipt: {
    readonly schema_version: 1;
    readonly snapshot_id: string;
    readonly snapshot_sha256: string;
    readonly source_fingerprint: string;
    readonly context_bytes: number;
    readonly verified_at: string;
  } | null;
};

export type AgentRoundCallPresentationV3 = {
  readonly schema_version: 3;
  readonly call_index: number;
  readonly call_id: string;
  readonly name: string;
  readonly arguments_sha256: string;
  readonly safe_summary_key: string;
  readonly access:
    | 'auto'
    | 'conversation_confirm'
    | 'confirm_once'
    | 'durable_deny';
  readonly approval_state: 'deferred' | 'durable_denied';
};

export type AgentRoundOutcomeV3 =
  | {
      readonly schema_version: 3;
      readonly kind: 'final';
      readonly finish_reason: 'stop';
      readonly completion_receipt: AgentRoundReceiptV2;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly text: string;
      readonly reasoning: string;
    }
  | {
      readonly schema_version: 3;
      readonly kind: 'tool_batch';
      readonly finish_reason: 'tool_calls';
      readonly completion_receipt: AgentRoundReceiptV2;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly calls: readonly AgentRoundCallPresentationV3[];
      readonly batch_class: 'executable' | 'mixed' | 'denied_only';
      readonly executable_call_count: number;
      readonly denied_call_count: number;
      readonly reasoning: string;
    }
  | {
      readonly schema_version: 3;
      readonly kind: 'blocked';
      readonly finish_reason: 'length' | 'content_filter';
      readonly completion_receipt: AgentRoundReceiptV2;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly failure_code:
        | 'E_COMPLETION_LENGTH'
        | 'E_COMPLETION_CONTENT_FILTER';
    };

export type PrepareAgentAttemptRequestV2 = {
  readonly schema_version: 2;
  readonly operation_id: string;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly committed_checkpoint: AgentRuntimeCommittedCheckpointV1;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly workspace_id: string | null;
  readonly project_id: string | null;
  readonly workspace_binding_revision: number | null;
  readonly transport_schema_version: 2 | 3;
  readonly harness_id: HarnessId;
  readonly model: HarnessModelId;
  readonly thinking_mode: DeepSeekThinkingMode;
  readonly visible_message_ids: readonly string[];
  readonly visible_history_sha256: string;
  readonly visible_message_count: number;
  readonly project_context_sha256: string | null;
  readonly registry_version: AgentRegistryVersion;
  readonly expected_policy_version: 'agent-v1' | null;
  readonly expected_transcript: AgentRuntimeTranscriptHandleV1 | null;
};

export type PrepareAgentAttemptResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: 'prepared' | 'already_prepared';
      readonly operation_id: string;
      readonly attempt: AgentAttemptProjectionV2;
      readonly observed_checkpoint: AgentRuntimeCommittedCheckpointV1;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'not_agent';
      readonly operation_id: string;
      readonly attempt: AgentAttemptProjectionV2;
      readonly failure_code: 'E_AGENT_NO_ROOT';
      readonly observed_checkpoint: AgentRuntimeCommittedCheckpointV1;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'conflict';
      readonly operation_id: string;
      readonly failure_code:
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_ROOT_STALE'
        | 'E_AGENT_TRANSCRIPT';
      readonly expected_controller_generation: number;
      readonly expected_journal_revision: number;
      readonly expected_session_generation: number;
      readonly expected_session_sha256: string;
      readonly actual_controller_generation: number;
      readonly actual_journal_revision: number;
      readonly actual_session_generation: number;
      readonly actual_session_sha256: string;
    };

export type CompleteAgentRoundRequestV2 = {
  readonly schema_version: 2;
  readonly operation_id: string;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly committed_checkpoint: AgentRuntimeCommittedCheckpointV1;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly round_id: string;
  readonly round_index: number;
  readonly launch_attempt: number;
  readonly expected_round_revision: number;
  readonly transport_schema_version: 2 | 3;
  readonly harness_id: HarnessId;
  readonly model: HarnessModelId;
  readonly thinking_mode: DeepSeekThinkingMode;
  readonly visible_history_sha256: string;
  readonly visible_message_count: number;
  readonly project_context_sha256: string | null;
  readonly transcript: AgentRuntimeTranscriptHandleV1;
  readonly root: AgentRuntimeRootV1;
  readonly registry_version: AgentRegistryVersion;
  readonly toolset_sha256: string;
};

export type CompleteAgentRoundResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: 'completed';
      readonly operation_id: string;
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly launch_attempt: number;
      readonly result_round_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly outcome: AgentRoundOutcomeV3;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'in_flight';
      readonly operation_id: string;
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly launch_attempt: number;
      readonly result_round_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
    }
  | {
      readonly schema_version: 2;
      readonly status:
        | 'failed_retryable'
        | 'cancelled'
        | 'unknown'
        | 'ambiguous';
      readonly operation_id: string;
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly launch_attempt: number;
      readonly result_round_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly failure_code: AgentRuntimeFailureCode;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'conflict';
      readonly operation_id: string;
      readonly failure_code:
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_TRANSCRIPT'
        | 'E_AGENT_ROOT_STALE';
      readonly expected_round_revision: number;
      readonly actual_round_revision: number;
      readonly actual_round_status:
        | 'in_flight'
        | 'failed_retryable'
        | 'completed'
        | 'cancel_requested'
        | 'cancelled'
        | 'unknown'
        | 'ambiguous';
      readonly actual_transcript: AgentRuntimeTranscriptHandleV1;
    };

export type PrepareAgentToolBatchRequestV2 = {
  readonly schema_version: 2;
  readonly operation_id: string;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly committed_checkpoint: AgentRuntimeCommittedCheckpointV1;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly round_id: string;
  readonly round_index: number;
  readonly expected_round_revision: number;
  readonly transcript: AgentRuntimeTranscriptHandleV1;
  readonly root: AgentRuntimeRootV1;
  readonly registry_version: AgentRegistryVersion;
  readonly toolset_sha256: string;
  readonly policy_version: 'agent-v1';
  readonly expected_batch_revision: number;
  readonly expected_reserved_write_bytes: number;
};

export type AgentBatchReceiptV2 = {
  readonly schema_version: 2;
  readonly task_id: string;
  readonly attempt_id: string;
  readonly round_id: string;
  readonly round_index: number;
  readonly batch_kind: 'write_batch' | 'read_only_batch';
  readonly batch_revision: number;
  readonly manifest_sha256: string | null;
  readonly transcript: AgentRuntimeTranscriptHandleV1;
  readonly calls: readonly AgentBatchCallProjectionV2[];
  readonly batch_new_write_bytes: number;
  readonly reserved_write_bytes: number;
  readonly effect_gate: 'closed' | 'not_applicable';
};

export type PrepareAgentToolBatchResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: 'prepared' | 'already_prepared';
      readonly operation_id: string;
      readonly receipt: AgentBatchReceiptV2;
      readonly observed_checkpoint: AgentRuntimeCommittedCheckpointV1;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'rejected';
      readonly operation_id: string;
      readonly failure_code:
        | 'E_AGENT_BAD_ARGUMENTS'
        | 'E_AGENT_BAD_PATH'
        | 'E_AGENT_CAPABILITY'
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_CAPACITY'
        | 'E_AGENT_LEDGER'
        | 'E_AGENT_PERSISTENCE'
        | 'E_AGENT_ROOT_STALE'
        | 'E_AGENT_ROUND_LIMIT';
      readonly expected_batch_revision: number;
      readonly expected_reserved_write_bytes: number;
      readonly result_reserved_write_bytes: number;
      readonly effect_gate: 'closed' | 'not_applicable';
      readonly reservation_status: 'unchanged';
      readonly effect_dispatched: false;
      readonly retry_advice: 'none' | 'requery' | 'wait_for_reconciliation';
    }
  | {
      readonly schema_version: 2;
      readonly status: 'conflict';
      readonly operation_id: string;
      readonly failure_code:
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_TRANSCRIPT'
        | 'E_AGENT_ROOT_STALE';
      readonly expected_batch_revision: number;
      readonly actual_batch_revision: number;
      readonly expected_reserved_write_bytes: number;
      readonly actual_reserved_write_bytes: number;
      readonly effect_gate: 'closed' | 'not_applicable';
      readonly reservation_status: 'unchanged';
      readonly effect_dispatched: false;
      readonly retry_advice: 'requery';
    };

export type BindAgentApprovalRequestV2 = {
  readonly schema_version: 2;
  readonly operation_id: string;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly committed_checkpoint: AgentRuntimeCommittedCheckpointV1;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly round_id: string;
  readonly round_index: number;
  readonly manifest_sha256: string;
  readonly batch_revision: number;
  readonly call_index: number;
  readonly call_id: string;
  readonly token: AgentApprovalBindingTokenV2;
  readonly decision:
    | 'denied'
    | 'allow_once'
    | 'allow_conversation'
    | 'cancelled';
  /** Bounded model-directed message for a `denied` decision; must be null
   * for every other decision. */
  readonly deny_message: string | null;
};

export type BindAgentApprovalResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: 'bound' | 'already_bound';
      readonly operation_id: string;
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly call_index: number;
      readonly call_id: string;
      readonly decision:
        | 'denied'
        | 'allow_once'
        | 'allow_conversation'
        | 'cancelled';
      readonly approval_reference: string | null;
      readonly grant: AgentConversationGrantV2 | null;
      readonly result_batch_revision: number;
      readonly observed_checkpoint: AgentRuntimeCommittedCheckpointV1;
      /** Settlement of a user denial: the appended-feedback transcript
       * handle and the redacted denied receipt. Both are null for every
       * allow/cancelled decision. */
      readonly receipt: AgentToolReceiptV1 | null;
      readonly transcript: AgentRuntimeTranscriptHandleV1 | null;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'conflict';
      readonly operation_id: string;
      readonly failure_code:
        | 'E_AGENT_APPROVAL'
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_ROOT_STALE';
      readonly expected_batch_revision: number;
      readonly actual_batch_revision: number;
      readonly actual_decision:
        | 'pending'
        | 'denied'
        | 'allow_once'
        | 'allow_conversation'
        | 'cancelled';
      readonly observed_checkpoint: AgentRuntimeCommittedCheckpointV1;
    };

export type ExecuteAgentToolRequestV2 = {
  readonly schema_version: 2;
  readonly operation_id: string;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly committed_checkpoint: AgentRuntimeCommittedCheckpointV1;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly round_id: string;
  readonly round_index: number;
  readonly batch_kind: 'write_batch' | 'read_only_batch';
  readonly manifest_sha256: string | null;
  readonly expected_batch_revision: number;
  readonly call_index: number;
  readonly call_id: string;
  readonly name: string;
  readonly arguments_sha256: string;
  readonly idempotency_key: string;
  readonly expected_execution_revision: number;
  readonly transcript: AgentRuntimeTranscriptHandleV1;
  readonly root: AgentRuntimeRootV1;
  readonly approval_reference: string | null;
};

type ExecuteAgentToolSettledStatus = 'completed' | 'failed' | 'denied';

export type ExecuteAgentToolResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: ExecuteAgentToolSettledStatus;
      readonly operation_id: string;
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly call_index: number;
      readonly call_id: string;
      readonly name: string;
      readonly idempotency_key: string;
      readonly result_execution_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly receipt: AgentToolReceiptV1;
      readonly effect_may_have_occurred: boolean;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'cancelled';
      readonly operation_id: string;
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly call_index: number;
      readonly call_id: string;
      readonly name: string;
      readonly idempotency_key: string;
      readonly result_execution_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly receipt: AgentToolReceiptV1;
      readonly effect_may_have_occurred: false;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'running' | 'cancel_requested';
      readonly operation_id: string;
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly call_index: number;
      readonly call_id: string;
      readonly name: string;
      readonly idempotency_key: string;
      readonly result_execution_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly receipt: null;
      readonly effect_may_have_occurred: boolean;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'unknown';
      readonly operation_id: string;
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly call_index: number;
      readonly call_id: string;
      readonly name: string;
      readonly idempotency_key: string;
      readonly result_execution_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly receipt: null;
      readonly effect_may_have_occurred: false;
      readonly failure_code: 'E_AGENT_EXECUTION_AMBIGUOUS' | 'E_AGENT_LEDGER';
    }
  | {
      readonly schema_version: 2;
      readonly status: 'ambiguous';
      readonly operation_id: string;
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly call_index: number;
      readonly call_id: string;
      readonly name: string;
      readonly idempotency_key: string;
      readonly result_execution_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly receipt: AgentToolReceiptV1;
      readonly effect_may_have_occurred: true;
      readonly failure_code: 'E_AGENT_EXECUTION_AMBIGUOUS';
    }
  | {
      readonly schema_version: 2;
      readonly status: 'conflict';
      readonly operation_id: string;
      readonly failure_code:
        | 'E_AGENT_APPROVAL'
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_ROOT_STALE'
        | 'E_AGENT_TRANSCRIPT';
      readonly expected_execution_revision: number;
      readonly actual_execution_revision: number;
      readonly actual_status:
        | 'intent'
        | 'running'
        | 'cancel_requested'
        | 'settled'
        | 'cancelled'
        | 'unknown'
        | 'ambiguous';
    };

export type AgentCancelTargetV2 =
  | {
      readonly schema_version: 2;
      readonly kind: 'attempt';
      readonly task_id: string;
      readonly attempt_id: string;
    }
  | {
      readonly schema_version: 2;
      readonly kind: 'round';
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
    }
  | {
      readonly schema_version: 2;
      readonly kind: 'tool';
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly call_index: number;
      readonly call_id: string;
      readonly idempotency_key: string;
    };

export type AgentCancelTokenV2 = {
  readonly schema_version: 2;
  readonly issuer: 'completion_controller';
  readonly source_event_id: string;
  readonly token: string;
  readonly task_id: string;
  readonly attempt_id: string;
  readonly expected_phase:
    | 'ready_for_round'
    | 'batch_frozen'
    | 'round_in_flight'
    | 'approval_pending'
    | 'execution_intent'
    | 'tool_result_pending';
  readonly reason_code:
    | 'E_AGENT_CANCELLED'
    | 'E_AGENT_ROOT_STALE'
    | 'E_AGENT_PERSISTENCE';
};

export type CancelAgentAttemptRequestV2 = {
  readonly schema_version: 2;
  readonly operation_id: string;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly committed_checkpoint: AgentRuntimeCommittedCheckpointV1;
  readonly target: AgentCancelTargetV2;
  readonly cancel_token: AgentCancelTokenV2;
  readonly expected_round_revision: number | null;
  readonly expected_execution_revision: number | null;
  readonly expected_transcript: AgentRuntimeTranscriptHandleV1;
  readonly root: AgentRuntimeRootV1;
};

type CancelRequestedStatus =
  | 'cancel_requested'
  | 'cancelled'
  | 'already_cancelled';

export type CancelAgentAttemptResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: CancelRequestedStatus;
      readonly operation_id: string;
      readonly target: AgentCancelTargetV2;
      readonly result_round_revision: number | null;
      readonly result_execution_revision: number | null;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly receipt: AgentToolReceiptV1 | null;
      readonly effect_may_have_occurred: boolean;
      readonly observed_checkpoint: AgentRuntimeCommittedCheckpointV1;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'settled' | 'unknown' | 'ambiguous';
      readonly operation_id: string;
      readonly target: AgentCancelTargetV2;
      readonly result_round_revision: number | null;
      readonly result_execution_revision: number | null;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly receipt: AgentToolReceiptV1 | null;
      readonly effect_may_have_occurred: boolean;
      readonly failure_code: AgentRuntimeFailureCode;
      readonly observed_checkpoint: AgentRuntimeCommittedCheckpointV1;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'conflict';
      readonly operation_id: string;
      readonly target: AgentCancelTargetV2;
      readonly failure_code:
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_CANCELLED'
        | 'E_AGENT_ROOT_STALE';
      readonly expected_controller_generation: number;
      readonly expected_journal_revision: number;
      readonly actual_controller_generation: number;
      readonly actual_journal_revision: number;
    };

export type QueryAgentAttemptRequestV2 = {
  readonly schema_version: 2;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly expected_journal_revision: number;
  readonly expected_session_generation: number;
  readonly expected_session_sha256: string;
  readonly expected_transcript: AgentRuntimeTranscriptHandleV1;
  readonly expected_root_fingerprint_sha256: string;
  readonly expected_workspace_binding_revision: number;
};

export type QueryAgentAttemptResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: 'active' | 'terminal';
      readonly attempt: AgentAttemptProjectionV2;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'not_found';
      readonly failure_code: 'E_AGENT_NOT_FOUND';
    }
  | {
      readonly schema_version: 2;
      readonly status: 'conflict';
      readonly failure_code:
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_TRANSCRIPT'
        | 'E_AGENT_ROOT_STALE';
      readonly expected_journal_revision: number;
      readonly actual_journal_revision: number;
      readonly expected_session_generation: number;
      readonly actual_session_generation: number;
    };

export type QueryAgentToolRequestV2 = {
  readonly schema_version: 2;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly round_id: string;
  readonly round_index: number;
  readonly call_index: number;
  readonly call_id: string;
  readonly idempotency_key: string;
  readonly expected_execution_revision: number;
  readonly expected_transcript: AgentRuntimeTranscriptHandleV1;
  readonly expected_root_fingerprint_sha256: string;
  readonly expected_workspace_binding_revision: number;
};

export type AgentToolProjectionV2 = {
  readonly schema_version: 2;
  readonly task_id: string;
  readonly attempt_id: string;
  readonly round_id: string;
  readonly round_index: number;
  readonly call_index: number;
  readonly call_id: string;
  readonly name: string;
  readonly arguments_sha256: string;
  readonly idempotency_key: string;
  readonly execution_revision: number;
  readonly status:
    | 'intent'
    | 'running'
    | 'cancel_requested'
    | 'completed'
    | 'failed'
    | 'denied'
    | 'cancelled'
    | 'unknown'
    | 'ambiguous';
  readonly transcript: AgentRuntimeTranscriptHandleV1;
  readonly receipt: AgentToolReceiptV1 | null;
};

export type QueryAgentToolResultV2 =
  | {
      readonly schema_version: 2;
      readonly status:
        | 'intent'
        | 'running'
        | 'cancel_requested'
        | 'completed'
        | 'failed'
        | 'denied'
        | 'cancelled'
        | 'unknown'
        | 'ambiguous';
      readonly tool: AgentToolProjectionV2;
    }
  | { readonly schema_version: 2; readonly status: 'not_started' }
  | {
      readonly schema_version: 2;
      readonly status: 'conflict';
      readonly failure_code:
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_TRANSCRIPT'
        | 'E_AGENT_ROOT_STALE';
      readonly expected_execution_revision: number;
      readonly actual_execution_revision: number;
    };

export type AgentRecoveryTargetV2 =
  | {
      readonly schema_version: 2;
      readonly kind: 'attempt';
      readonly task_id: string;
      readonly attempt_id: string;
    }
  | {
      readonly schema_version: 2;
      readonly kind: 'round';
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
    }
  | {
      readonly schema_version: 2;
      readonly kind: 'tool';
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly call_index: number;
      readonly call_id: string;
      readonly idempotency_key: string;
    };

export type AgentRecoveredRoundProjectionV2 =
  | {
      readonly schema_version: 2;
      readonly kind: 'final';
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly launch_attempt: number;
      readonly result_round_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly completion_receipt: AgentRoundReceiptV2;
      readonly text: string;
      readonly reasoning: string;
      readonly assistant_text_sha256: string;
      readonly reasoning_text_sha256: string;
    }
  | {
      readonly schema_version: 2;
      readonly kind: 'tool_batch';
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly launch_attempt: number;
      readonly result_round_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly completion_receipt: AgentRoundReceiptV2;
      readonly text: string;
      readonly reasoning: string;
      readonly assistant_text_sha256: string;
      readonly reasoning_text_sha256: string;
      readonly calls: readonly AgentRoundCallPresentationV3[];
      readonly batch_class: 'executable' | 'mixed' | 'denied_only';
      readonly executable_call_count: number;
      readonly denied_call_count: number;
    }
  | {
      readonly schema_version: 2;
      readonly kind: 'blocked';
      readonly task_id: string;
      readonly attempt_id: string;
      readonly round_id: string;
      readonly round_index: number;
      readonly launch_attempt: number;
      readonly result_round_revision: number;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
      readonly completion_receipt: AgentRoundReceiptV2;
      readonly text: string;
      readonly reasoning: string;
      readonly assistant_text_sha256: string;
      readonly reasoning_text_sha256: string;
      readonly failure_code:
        | 'E_COMPLETION_LENGTH'
        | 'E_COMPLETION_CONTENT_FILTER';
    };

export type RecoverAgentAttemptRequestV2 = {
  readonly schema_version: 2;
  readonly operation_id: string;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly committed_checkpoint: AgentRuntimeCommittedCheckpointV1;
  readonly target: AgentRecoveryTargetV2;
  readonly action: 'reconcile' | 'retry_failed_round';
  readonly expected_round_revision: number | null;
  readonly expected_execution_revision: number | null;
  readonly expected_transcript: AgentRuntimeTranscriptHandleV1;
  readonly root: AgentRuntimeRootV1;
};

export type RecoverAgentAttemptResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: 'resumed';
      readonly operation_id: string;
      readonly next_action:
        | 'persist_round'
        | 'persist_batch'
        | 'persist_approval'
        | 'persist_tool_result'
        | 'persist_final'
        | 'none';
      readonly attempt: AgentAttemptProjectionV2;
      readonly completed_round: AgentRecoveredRoundProjectionV2 | null;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'retryable';
      readonly operation_id: string;
      readonly next_action: 'retry_same_round';
      readonly attempt: AgentAttemptProjectionV2;
      readonly completed_round: AgentRecoveredRoundProjectionV2 | null;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'manual_reconciliation';
      readonly operation_id: string;
      readonly next_action: 'inspect_native_state';
      readonly attempt: AgentAttemptProjectionV2;
      readonly completed_round: AgentRecoveredRoundProjectionV2 | null;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'terminal';
      readonly operation_id: string;
      readonly next_action: 'none';
      readonly attempt: AgentAttemptProjectionV2;
      readonly completed_round: AgentRecoveredRoundProjectionV2 | null;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'conflict';
      readonly operation_id: string;
      readonly failure_code:
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_TRANSCRIPT'
        | 'E_AGENT_ROOT_STALE';
      readonly expected_controller_generation: number;
      readonly expected_journal_revision: number;
      readonly actual_controller_generation: number;
      readonly actual_journal_revision: number;
    };

export type FinalizeAgentAttemptRequestV2 = {
  readonly schema_version: 2;
  readonly operation_id: string;
  readonly controller_cas: AgentRuntimeControllerCASV1;
  readonly committed_checkpoint: AgentRuntimeCommittedCheckpointV1;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly terminal_reason:
    | 'completed'
    | 'cancelled'
    | 'failed'
    | 'conversation_deleted';
  readonly cleanup_id: string;
  readonly transcript: AgentRuntimeTranscriptHandleV1;
  readonly root: AgentRuntimeRootV1;
};

export type FinalizeAgentAttemptResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: 'terminal' | 'already_terminal';
      readonly operation_id: string;
      readonly cleanup_id: string;
      readonly transcript: AgentRuntimeTranscriptHandleV1;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'conflict';
      readonly operation_id: string;
      readonly failure_code:
        | 'E_AGENT_CONFLICT'
        | 'E_AGENT_TRANSCRIPT'
        | 'E_AGENT_ROOT_STALE';
    };

export type DiscardAgentAttemptRequestV2 = {
  readonly schema_version: 2;
  readonly operation_id: string;
  readonly cleanup_id: string;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly transcript_ref: string;
  readonly transcript_sha256: string;
};

export type DiscardAgentAttemptResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: 'discarded' | 'already_missing';
      readonly operation_id: string;
      readonly cleanup_id: string;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'pending' | 'unknown';
      readonly operation_id: string;
      readonly cleanup_id: string;
      readonly failure_code: 'E_AGENT_PERSISTENCE' | 'E_AGENT_TRANSCRIPT';
    };

export type InterruptAgentAttemptRequestV2 = {
  readonly schema_version: 2;
  readonly operation_id: string;
  readonly cleanup_id: string;
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly transcript_ref: string;
  readonly transcript_sha256: string;
  readonly reason: 'completed' | 'cancelled' | 'failed';
  readonly expected_session_generation: number;
  readonly expected_session_sha256: string;
};

export type InterruptAgentAttemptResultV2 =
  | {
      readonly schema_version: 2;
      readonly status: 'discarded' | 'already_missing';
      readonly operation_id: string;
      readonly cleanup_id: string;
    }
  | {
      readonly schema_version: 2;
      readonly status: 'pending' | 'unknown';
      readonly operation_id: string;
      readonly cleanup_id: string;
      readonly failure_code: 'E_AGENT_PERSISTENCE' | 'E_AGENT_TRANSCRIPT';
    };

export type QueryAgentCleanupRequestV2 = {
  readonly schema_version: 2;
  readonly cleanup_id: string;
};

export type QueryAgentCleanupResultV2 = {
  readonly schema_version: 2;
  readonly status: 'pending' | 'discarded' | 'unknown';
  readonly cleanup_id: string;
};

export type AgentRuntimeFacadeV2 = {
  isAvailable(): boolean;
  prepareAgentAttempt(
    request: PrepareAgentAttemptRequestV2,
  ): Promise<PrepareAgentAttemptResultV2>;
  completeAgentRoundV2(
    request: CompleteAgentRoundRequestV2,
  ): Promise<CompleteAgentRoundResultV2>;
  prepareAgentToolBatch(
    request: PrepareAgentToolBatchRequestV2,
  ): Promise<PrepareAgentToolBatchResultV2>;
  bindAgentApproval(
    request: BindAgentApprovalRequestV2,
  ): Promise<BindAgentApprovalResultV2>;
  executeAgentTool(
    request: ExecuteAgentToolRequestV2,
  ): Promise<ExecuteAgentToolResultV2>;
  cancelAgentAttempt(
    request: CancelAgentAttemptRequestV2,
  ): Promise<CancelAgentAttemptResultV2>;
  queryAgentAttempt(
    request: QueryAgentAttemptRequestV2,
  ): Promise<QueryAgentAttemptResultV2>;
  queryAgentTool(
    request: QueryAgentToolRequestV2,
  ): Promise<QueryAgentToolResultV2>;
  recoverAgentAttempt(
    request: RecoverAgentAttemptRequestV2,
  ): Promise<RecoverAgentAttemptResultV2>;
  finalizeAgentAttempt(
    request: FinalizeAgentAttemptRequestV2,
  ): Promise<FinalizeAgentAttemptResultV2>;
  discardAgentAttempt(
    request: DiscardAgentAttemptRequestV2,
  ): Promise<DiscardAgentAttemptResultV2>;
  interruptAgentAttempt(
    request: InterruptAgentAttemptRequestV2,
  ): Promise<InterruptAgentAttemptResultV2>;
  queryAgentCleanup(
    request: QueryAgentCleanupRequestV2,
  ): Promise<QueryAgentCleanupResultV2>;
};

const contextBridgeFailureCodes = [
  'E_CONTEXT_REQUEST_INVALID', 'E_PROJECT_NOT_FOUND', 'E_CONTEXT_CHANGED',
  'E_CONTEXT_SECRET', 'E_CONTEXT_BUDGET', 'E_CONTEXT_STORAGE',
  'E_CONTEXT_TIMEOUT', 'E_CONTEXT_CONSENT_INVALID', 'E_CONTEXT_INTEGRITY',
  'E_CONTEXT_SNAPSHOT_MISSING', 'E_CONTEXT_NATIVE',
] as const;
type AgentBridgeFailureCode = AgentRuntimeFailureCode |
  (typeof contextBridgeFailureCodes)[number];

export class AgentRuntimeError extends Error {
  readonly code: AgentBridgeFailureCode;
  readonly diagnostic: AgentRuntimeDiagnostic | null;

  constructor(code: AgentBridgeFailureCode, diagnostic?: AgentRuntimeDiagnostic | null) {
    super(code);
    this.name = 'AgentRuntimeError';
    this.code = code;
    this.diagnostic = code === 'E_AGENT_PERSISTENCE'
      ? parseAgentRuntimeDiagnostic(diagnostic) : null;
  }
}

const objectPrototype = Object.prototype;
const arrayPrototype = Array.prototype;
const arrayMap = Array.prototype.map;
const MAX_SAFE = Number.MAX_SAFE_INTEGER;
const MAX_VISIBLE_MESSAGES = 96;
const MAX_ROUNDS = 7;
const MAX_CALLS = 15;
const MAX_TRANSCRIPT_BYTES = 2 * 1024 * 1024;
const MAX_RESULT_BYTES = 32 * 1024 * 1024;
const MAX_ATTEMPT_WRITE_BYTES = 4 * 1024 * 1024;
const MAX_SINGLE_WRITE_BYTES = 32768;
const MAX_SUMMARY_BYTES = 128;
const MAX_TEXT_BYTES = 256 * 1024;
const MAX_PROVIDER_ID_BYTES = 128;
const MAX_DURATION_MS = 24 * 60 * 60 * 1000;

function isAgentRegistryVersion(value: unknown): value is AgentRegistryVersion {
  return value === 1 || value === 2 || value === 3;
}

const runtimeFailureCodes = new Set<AgentRuntimeFailureCode>([
  'E_AGENT_UNKNOWN_TOOL',
  'E_AGENT_BAD_ARGUMENTS',
  'E_AGENT_BAD_PATH',
  'E_AGENT_NO_ROOT',
  'E_AGENT_ROOT_STALE',
  'E_AGENT_CAPABILITY',
  'E_AGENT_APPROVAL',
  'E_AGENT_TRANSCRIPT',
  'E_AGENT_LEDGER',
  'E_AGENT_ROUND_AMBIGUOUS',
  'E_AGENT_EXECUTION_AMBIGUOUS',
  'E_AGENT_RETRY_LINEAGE',
  'E_AGENT_PERSISTENCE',
  'E_AGENT_CONFLICT',
  'E_AGENT_ROUND_LIMIT',
  'E_AGENT_CANCELLED',
  'E_AGENT_TOOL_FAILED',
  'E_AGENT_NATIVE',
  'E_AGENT_NOT_FOUND',
  'E_AGENT_CAPACITY',
  'E_COMPLETION_LENGTH',
  'E_COMPLETION_CONTENT_FILTER',
  'E_AGENT_DENIED_BY_USER',
]);

const agentFailureCodes = new Set<AgentFailureCode>([
  'E_AGENT_UNKNOWN_TOOL',
  'E_AGENT_BAD_ARGUMENTS',
  'E_AGENT_BAD_PATH',
  'E_AGENT_ROOT_STALE',
  'E_AGENT_CAPABILITY',
  'E_AGENT_APPROVAL',
  'E_AGENT_TRANSCRIPT',
  'E_AGENT_LEDGER',
  'E_AGENT_ROUND_AMBIGUOUS',
  'E_AGENT_EXECUTION_AMBIGUOUS',
  'E_AGENT_RETRY_LINEAGE',
  'E_AGENT_PERSISTENCE',
  'E_AGENT_CONFLICT',
  'E_AGENT_ROUND_LIMIT',
  'E_AGENT_CANCELLED',
  'E_AGENT_TOOL_FAILED',
  'E_AGENT_CAPACITY',
  'E_COMPLETION_LENGTH',
  'E_COMPLETION_CONTENT_FILTER',
  'E_AGENT_DENIED_BY_USER',
]);

const operationIds = [
  'prepare_agent_attempt',
  'complete_agent_round_v2',
  'prepare_agent_tool_batch',
  'bind_agent_approval',
  'execute_agent_tool',
  'cancel_agent_attempt',
  'query_agent_attempt',
  'query_agent_tool',
  'recover_agent_attempt',
  'finalize_agent_attempt',
  'discard_agent_attempt',
  'interrupt_agent_attempt',
  'query_agent_cleanup',
] as const;

const legacyOperationIds = [
  'createAgentTranscript',
  'validateAgentTranscript',
  'createAgentRound',
  'claimAgentRound',
  'casAgentRound',
  'claimAgentExecution',
  'casAgentExecution',
  'queryAgentExecution',
  'reserveWriteBytes',
  'openAgentWriteBatchEffectGate',
  'reconcileAgentExecution',
] as const;

type NativeSelector = (typeof operationIds)[number];
type NativeAgentRuntimeV2 = {
  [K in NativeSelector]: (request: unknown) => Promise<unknown>;
};

const nativeMethodCache = new WeakMap<object, NativeAgentRuntimeV2>();

function fail(code: AgentRuntimeFailureCode = 'E_AGENT_BAD_ARGUMENTS'): never {
  throw new AgentRuntimeError(code);
}

function exactRecord(
  value: unknown,
  keys: readonly string[],
  code: AgentRuntimeFailureCode = 'E_AGENT_BAD_ARGUMENTS',
): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value))
    fail(code);
  const object = value as object;
  let prototype: object | null;
  let names: string[];
  let symbols: symbol[];
  try {
    prototype = Object.getPrototypeOf(object) as object | null;
    names = Object.getOwnPropertyNames(object);
    symbols = Object.getOwnPropertySymbols(object);
  } catch {
    fail(code);
  }
  if (prototype !== objectPrototype && prototype !== null) fail(code);
  if (
    symbols.length !== 0 ||
    names.length !== keys.length ||
    names.some(propertyName => !keys.includes(propertyName))
  )
    fail(code);
  const output = Object.create(null) as Record<string, unknown>;
  for (const key of keys) {
    let descriptor: PropertyDescriptor | undefined;
    try {
      descriptor = Object.getOwnPropertyDescriptor(object, key);
    } catch {
      fail(code);
    }
    if (
      descriptor === undefined ||
      !('value' in descriptor) ||
      descriptor.enumerable !== true
    )
      fail(code);
    output[key] = descriptor.value;
  }
  return output;
}

/**
 * exactRecord plus a closed set of optional keys. Optional keys are copied
 * when present and validated by the caller; they let post-ship wire fields
 * (currently only `harness_id`) hydrate legacy rows without weakening the
 * closed-shape guarantee.
 */
function exactRecordWithOptional(
  value: unknown,
  keys: readonly string[],
  optionalKeys: readonly string[],
  code: AgentRuntimeFailureCode = 'E_AGENT_BAD_ARGUMENTS',
): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value))
    fail(code);
  const object = value as object;
  let prototype: object | null;
  let names: string[];
  let symbols: symbol[];
  try {
    prototype = Object.getPrototypeOf(object) as object | null;
    names = Object.getOwnPropertyNames(object);
    symbols = Object.getOwnPropertySymbols(object);
  } catch {
    fail(code);
  }
  if (prototype !== objectPrototype && prototype !== null) fail(code);
  const allowed = [...keys, ...optionalKeys];
  if (
    symbols.length !== 0 ||
    names.some(propertyName => !allowed.includes(propertyName)) ||
    keys.some(key => !names.includes(key))
  )
    fail(code);
  const output = Object.create(null) as Record<string, unknown>;
  for (const key of allowed) {
    if (!names.includes(key)) continue;
    let descriptor: PropertyDescriptor | undefined;
    try {
      descriptor = Object.getOwnPropertyDescriptor(object, key);
    } catch {
      fail(code);
    }
    if (
      descriptor === undefined ||
      !('value' in descriptor) ||
      descriptor.enumerable !== true
    )
      fail(code);
    output[key] = descriptor.value;
  }
  return output;
}

/** Read a discriminant without treating the full tagged union as that shape. */
function peekRecord(
  value: unknown,
  keys: readonly string[],
  code: AgentRuntimeFailureCode = 'E_AGENT_BAD_ARGUMENTS',
): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value))
    fail(code);
  const object = value as object;
  let prototype: object | null;
  let symbols: symbol[];
  try {
    prototype = Object.getPrototypeOf(object) as object | null;
    symbols = Object.getOwnPropertySymbols(object);
  } catch {
    fail(code);
  }
  if (prototype !== objectPrototype && prototype !== null) fail(code);
  if (symbols.length !== 0) fail(code);
  const output = Object.create(null) as Record<string, unknown>;
  for (const key of keys) {
    let descriptor: PropertyDescriptor | undefined;
    try {
      descriptor = Object.getOwnPropertyDescriptor(object, key);
    } catch {
      fail(code);
    }
    if (
      descriptor === undefined ||
      !('value' in descriptor) ||
      descriptor.enumerable !== true
    )
      fail(code);
    output[key] = descriptor.value;
  }
  return output;
}

function strictArray(
  value: unknown,
  maximum: number,
  minimum = 0,
  code: AgentRuntimeFailureCode = 'E_AGENT_BAD_ARGUMENTS',
): unknown[] {
  if (!Array.isArray(value)) fail(code);
  let prototype: object | null;
  let symbols: symbol[];
  let names: string[];
  let lengthDescriptor: PropertyDescriptor | undefined;
  try {
    prototype = Object.getPrototypeOf(value) as object | null;
    symbols = Object.getOwnPropertySymbols(value);
    names = Object.getOwnPropertyNames(value);
    lengthDescriptor = Object.getOwnPropertyDescriptor(value, 'length');
  } catch {
    fail(code);
  }
  if (
    prototype !== arrayPrototype ||
    symbols.length !== 0 ||
    Object.getPrototypeOf(arrayPrototype) !== objectPrototype ||
    Object.getOwnPropertyDescriptor(arrayPrototype, 'map')?.value !==
      arrayMap ||
    lengthDescriptor === undefined ||
    !('value' in lengthDescriptor) ||
    lengthDescriptor.enumerable !== false ||
    !Number.isSafeInteger(lengthDescriptor.value) ||
    lengthDescriptor.value < minimum ||
    lengthDescriptor.value > maximum
  )
    fail(code);
  const length = lengthDescriptor.value as number;
  const allowed = new Set<string>(['length']);
  const output: unknown[] = [];
  for (let index = 0; index < length; index += 1) {
    const key = String(index);
    allowed.add(key);
    let descriptor: PropertyDescriptor | undefined;
    try {
      descriptor = Object.getOwnPropertyDescriptor(value, key);
    } catch {
      fail(code);
    }
    if (
      descriptor === undefined ||
      !('value' in descriptor) ||
      descriptor.enumerable !== true
    )
      fail(code);
    output.push(descriptor.value);
  }
  if (names.some(propertyName => !allowed.has(propertyName))) fail(code);
  return output;
}

function utf8Bytes(value: unknown): number | null {
  if (typeof value !== 'string') return null;
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit <= 0x7f) bytes += 1;
    else if (unit <= 0x7ff) bytes += 2;
    else if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return null;
      bytes += 4;
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return null;
    else bytes += 3;
  }
  return bytes;
}

function boundedString(
  value: unknown,
  maximum: number,
  allowEmpty = false,
): value is string {
  const bytes = utf8Bytes(value);
  return (
    typeof value === 'string' &&
    bytes !== null &&
    bytes <= maximum &&
    (allowEmpty || value.length > 0)
  );
}

function asciiString(value: unknown, maximum: number): value is string {
  return (
    boundedString(value, maximum) &&
    [...value].every(character => character.charCodeAt(0) <= 0x7f)
  );
}

function safeInteger(
  value: unknown,
  maximum: number,
  allowZero = true,
): value is number {
  return (
    typeof value === 'number' &&
    Number.isSafeInteger(value) &&
    !Object.is(value, -0) &&
    value >= 0 &&
    value <= maximum &&
    (allowZero || value !== 0)
  );
}

function uuid(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(
      value,
    )
  );
}

function digest(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{64}$/u.test(value);
}

function opaqueId(value: unknown): value is string {
  return (
    boundedString(value, MAX_PROVIDER_ID_BYTES) &&
    /^[A-Za-z0-9._:-]+$/u.test(value)
  );
}

function name(value: unknown): value is string {
  return asciiString(value, 64) && /^[A-Za-z0-9._:-]+$/u.test(value);
}

function summary(value: unknown): value is string {
  return boundedString(value, MAX_SUMMARY_BYTES);
}

function timestamp(value: unknown): value is string {
  if (
    typeof value !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value)
  )
    return false;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) && new Date(parsed).toISOString() === value;
}

function model(value: unknown): value is HarnessModelId { return isHarnessModelId(value); }

function harness(value: unknown): value is HarnessId {
  return isHarnessId(value);
}

function thinkingMode(value: unknown): value is DeepSeekThinkingMode {
  return value === 'off' || value === 'high' || value === 'max';
}

function booleanValue(value: unknown): value is boolean {
  return typeof value === 'boolean';
}

function nullableUuid(value: unknown): value is string | null {
  return value === null || uuid(value);
}

function nullableDigest(value: unknown): value is string | null {
  return value === null || digest(value);
}

function isAgentFailureCode(value: unknown): value is AgentFailureCode {
  return (
    typeof value === 'string' &&
    agentFailureCodes.has(value as AgentFailureCode)
  );
}

function isRuntimeFailureCode(
  value: unknown,
): value is AgentRuntimeFailureCode {
  return (
    typeof value === 'string' &&
    runtimeFailureCodes.has(value as AgentRuntimeFailureCode)
  );
}

function assign<T>(
  record: Record<string, unknown>,
  key: string,
  value: T,
): void {
  record[key] = value;
}

function validateUuidArray(
  value: unknown,
  maximum: number,
  minimum = 0,
): string[] {
  const values = strictArray(value, maximum, minimum);
  const result: string[] = [];
  const seen = new Set<string>();
  for (const candidate of values) {
    if (!uuid(candidate) || seen.has(candidate)) fail();
    seen.add(candidate);
    result.push(candidate);
  }
  return result;
}

function validateRoot(value: unknown): AgentRuntimeRootV1 {
  const root = exactRecord(value, [
    'schema_version',
    'kind',
    'workspace_id',
    'workspace_binding_revision',
    'project_id',
    'root_fingerprint_sha256',
    'capabilities',
  ]);
  if (
    root.schema_version !== 1 ||
    (root.kind !== 'project' && root.kind !== 'workspace') ||
    !uuid(root.workspace_id) ||
    !safeInteger(root.workspace_binding_revision, MAX_SAFE, false) ||
    !nullableUuid(root.project_id) ||
    (root.kind === 'project' && root.project_id === null) ||
    (root.kind === 'workspace' && root.project_id !== null) ||
    !digest(root.root_fingerprint_sha256)
  )
    fail();
  const capabilities = strictArray(root.capabilities, 6);
  const allowed = new Set([
    'file_read',
    'file_write',
    'git_status',
    'git_commit',
    'git_push',
    'guest_service',
  ]);
  const seen = new Set<string>();
  for (const capability of capabilities) {
    if (
      typeof capability !== 'string' ||
      !allowed.has(capability) ||
      seen.has(capability)
    )
      fail();
    if (root.kind === 'workspace' && capability.startsWith('git_')) fail();
    seen.add(capability);
  }
  assign(root, 'capabilities', capabilities);
  return root as AgentRuntimeRootV1;
}

function validatePolicy(value: unknown): AgentRuntimePolicyV1 {
  const policy = exactRecord(value, [
    'schema_version',
    'policy_version',
    'max_single_write_bytes',
    'max_batch_write_bytes',
    'max_attempt_write_bytes',
  ]);
  if (
    policy.schema_version !== 1 ||
    policy.policy_version !== 'agent-v1' ||
    policy.max_single_write_bytes !== 32768 ||
    !safeInteger(policy.max_batch_write_bytes, 512 * 1024, false) ||
    (policy.max_batch_write_bytes as number) < 32768 ||
    !safeInteger(
      policy.max_attempt_write_bytes,
      MAX_ATTEMPT_WRITE_BYTES,
      false,
    ) ||
    (policy.max_attempt_write_bytes as number) <
      (policy.max_batch_write_bytes as number)
  )
    fail();
  return policy as AgentRuntimePolicyV1;
}

function validateTranscript(value: unknown): AgentRuntimeTranscriptHandleV1 {
  const transcript = exactRecord(value, [
    'schema_version',
    'transcript_ref',
    'generation',
    'transcript_sha256',
    'transcript_bytes',
  ]);
  if (
    transcript.schema_version !== 1 ||
    !uuid(transcript.transcript_ref) ||
    !safeInteger(transcript.generation, MAX_SAFE) ||
    !digest(transcript.transcript_sha256) ||
    !safeInteger(transcript.transcript_bytes, MAX_TRANSCRIPT_BYTES)
  )
    fail();
  return transcript as AgentRuntimeTranscriptHandleV1;
}

function validateControllerCAS(value: unknown): AgentRuntimeControllerCASV1 {
  const cas = exactRecord(value, [
    'schema_version',
    'conversation_id',
    'task_id',
    'attempt_id',
    'expected_controller_generation',
    'expected_journal_revision',
    'expected_session_generation',
    'expected_session_sha256',
  ]);
  if (
    cas.schema_version !== 1 ||
    !uuid(cas.conversation_id) ||
    !uuid(cas.task_id) ||
    !uuid(cas.attempt_id) ||
    !safeInteger(cas.expected_controller_generation, MAX_SAFE) ||
    !safeInteger(cas.expected_journal_revision, MAX_SAFE) ||
    !safeInteger(cas.expected_session_generation, MAX_SAFE) ||
    !digest(cas.expected_session_sha256)
  )
    fail();
  return cas as AgentRuntimeControllerCASV1;
}

function validateCheckpoint(value: unknown): AgentRuntimeCommittedCheckpointV1 {
  const checkpoint = exactRecord(value, [
    'schema_version',
    'journal_revision',
    'session_generation',
    'session_sha256',
  ]);
  if (
    checkpoint.schema_version !== 1 ||
    !safeInteger(checkpoint.journal_revision, MAX_SAFE) ||
    !safeInteger(checkpoint.session_generation, MAX_SAFE) ||
    !digest(checkpoint.session_sha256)
  )
    fail();
  return checkpoint as AgentRuntimeCommittedCheckpointV1;
}

function validateRegistryTool(
  value: unknown,
  registryVersion: AgentRegistryVersion,
): AgentRuntimeRegistryToolV2 {
  const tool = exactRecord(
    value,
    ['schema_version', 'name', 'safe_summary_key', 'access'],
    'E_AGENT_LEDGER',
  );
  if (
    tool.schema_version !== 2 ||
    !name(tool.name) ||
    !summary(tool.safe_summary_key) ||
    !['auto', 'conversation_confirm', 'confirm_once', 'durable_deny'].includes(
      tool.access as string,
    )
  )
    fail('E_AGENT_LEDGER');
  const expected = (ALL_AGENT_TOOL_NAMES as readonly string[]).includes(tool.name as string)
    ? `agent.${tool.name as string}`
    : 'agent.unknown';
  if (tool.safe_summary_key !== expected) fail('E_AGENT_LEDGER');
  if (!agentToolRegistryCompatible(tool.name, registryVersion)) {
    fail('E_AGENT_LEDGER');
  }
  return tool as AgentRuntimeRegistryToolV2;
}

function validateRegistry(value: unknown): AgentRuntimeRegistryV2 {
  const registry = exactRecord(
    value,
    ['schema_version', 'registry_version', 'toolset_sha256', 'tools'],
    'E_AGENT_LEDGER',
  );
  if (
    registry.schema_version !== 2 ||
    !isAgentRegistryVersion(registry.registry_version) ||
    !digest(registry.toolset_sha256)
  )
    fail('E_AGENT_LEDGER');
  const registryVersion = registry.registry_version as AgentRegistryVersion;
  const tools = strictArray(
    registry.tools,
    agentRegistryToolLimit(registryVersion),
    0,
    'E_AGENT_LEDGER',
  ).map(tool => validateRegistryTool(tool, registryVersion));
  const seen = new Set<string>();
  for (const tool of tools)
    if (seen.has(tool.name)) fail('E_AGENT_LEDGER');
    else seen.add(tool.name);
  assign(registry, 'tools', tools);
  return registry as AgentRuntimeRegistryV2;
}

function validateProjectContextReceipt(
  value: unknown,
): AgentRoundReceiptV2['project_context_receipt'] {
  if (value === null) return null;
  const receipt = exactRecord(
    value,
    [
      'schema_version',
      'snapshot_id',
      'snapshot_sha256',
      'source_fingerprint',
      'context_bytes',
      'verified_at',
    ],
    'E_AGENT_LEDGER',
  );
  if (
    receipt.schema_version !== 1 ||
    !boundedString(receipt.snapshot_id, MAX_PROVIDER_ID_BYTES) ||
    !digest(receipt.snapshot_sha256) ||
    !boundedString(receipt.source_fingerprint, MAX_PROVIDER_ID_BYTES) ||
    !safeInteger(receipt.context_bytes, MAX_RESULT_BYTES) ||
    !timestamp(receipt.verified_at)
  )
    fail('E_AGENT_LEDGER');
  return receipt as AgentRoundReceiptV2['project_context_receipt'];
}

function validateRoundReceipt(value: unknown): AgentRoundReceiptV2 {
  const receipt = exactRecordWithOptional(
    value,
    [
      'schema_version',
      'transport_schema_version',
      'turn_id',
      'task_id',
      'attempt_id',
      'round_id',
      'round_index',
      'provider_request_id',
      'provider_response_id',
      'requested_model',
      'model',
      'thinking_mode',
      'finish_reason',
      'latency_ms',
      'visible_history_sha256',
      'model_input_sha256',
      'request_body_sha256',
      'project_context_receipt',
    ],
    ['harness_id', 'provider_configuration'],
    'E_AGENT_LEDGER',
  );
  if (
    receipt.harness_id !== undefined &&
    !harness(receipt.harness_id)
  )
    fail('E_AGENT_LEDGER');
  if (
    receipt.schema_version !== 2 ||
    (receipt.transport_schema_version !== 2 &&
      receipt.transport_schema_version !== 3) ||
    !uuid(receipt.turn_id) ||
    !uuid(receipt.task_id) ||
    !uuid(receipt.attempt_id) ||
    !uuid(receipt.round_id) ||
    !safeInteger(receipt.round_index, MAX_ROUNDS) ||
    !opaqueId(receipt.provider_request_id) ||
    !opaqueId(receipt.provider_response_id) ||
    !model(receipt.requested_model) ||
    !model(receipt.model) ||
    !thinkingMode(receipt.thinking_mode) ||
    !['stop', 'tool_calls', 'length', 'content_filter'].includes(
      receipt.finish_reason as string,
    ) ||
    !safeInteger(receipt.latency_ms, MAX_DURATION_MS) ||
    !digest(receipt.visible_history_sha256) ||
    !digest(receipt.model_input_sha256) ||
    !digest(receipt.request_body_sha256)
  )
    fail('E_AGENT_LEDGER');
  if (receipt.provider_configuration !== undefined && parseProviderBinding(receipt.provider_configuration, receipt.model as HarnessModelId) === null) fail('E_AGENT_LEDGER');
  const context = validateProjectContextReceipt(
    receipt.project_context_receipt,
  );
  if (
    (receipt.transport_schema_version === 2 && context !== null) ||
    (receipt.transport_schema_version === 3 && context === null)
  )
    fail('E_AGENT_LEDGER');
  assign(receipt, 'project_context_receipt', context);
  if (receipt.harness_id === undefined) {
    assign(receipt, 'harness_id', 'dsh');
  }
  return receipt as AgentRoundReceiptV2;
}

function validateToolReceipt(value: unknown): AgentToolReceiptV1 {
  const receipt = exactRecord(
    value,
    [
      'schema_version',
      'call_id',
      'name',
      'arguments_sha256',
      'result_sha256',
      'result_bytes',
      'truncated',
      'duration_ms',
      'outcome',
      'failure_code',
      'approval_reference',
    ],
    'E_AGENT_LEDGER',
  );
  if (
    receipt.schema_version !== 1 ||
    !opaqueId(receipt.call_id) ||
    !name(receipt.name) ||
    !digest(receipt.arguments_sha256) ||
    !digest(receipt.result_sha256) ||
    !safeInteger(receipt.result_bytes, MAX_RESULT_BYTES) ||
    !booleanValue(receipt.truncated) ||
    !safeInteger(receipt.duration_ms, MAX_DURATION_MS) ||
    !['ok', 'failed', 'denied', 'cancelled', 'ambiguous'].includes(
      receipt.outcome as string,
    ) ||
    (receipt.failure_code !== null &&
      !isAgentFailureCode(receipt.failure_code)) ||
    !nullableUuid(receipt.approval_reference)
  )
    fail('E_AGENT_LEDGER');
  if (receipt.outcome === 'ok' && receipt.failure_code !== null)
    fail('E_AGENT_LEDGER');
  if (
    receipt.outcome === 'ambiguous' &&
    receipt.failure_code !== 'E_AGENT_EXECUTION_AMBIGUOUS'
  )
    fail('E_AGENT_LEDGER');
  if (receipt.outcome !== 'ok' && receipt.failure_code === null)
    fail('E_AGENT_LEDGER');
  return receipt as AgentToolReceiptV1;
}

function validateReceiptBinding(
  receipt: AgentToolReceiptV1,
  callId: string,
  callName: string,
  argumentsSha256: string,
  approvalReference: string | null,
): void {
  if (
    receipt.call_id !== callId ||
    receipt.name !== callName ||
    receipt.arguments_sha256 !== argumentsSha256 ||
    receipt.approval_reference !== approvalReference
  )
    fail('E_AGENT_LEDGER');
}

function validateIssuedFor(
  value: unknown,
): AgentConversationGrantV2['issued_for'] {
  const issued = exactRecord(
    value,
    ['schema_version', 'task_id', 'attempt_id'],
    'E_AGENT_LEDGER',
  );
  if (
    issued.schema_version !== 1 ||
    !uuid(issued.task_id) ||
    !uuid(issued.attempt_id)
  )
    fail('E_AGENT_LEDGER');
  return issued as AgentConversationGrantV2['issued_for'];
}

function validateGrant(value: unknown): AgentConversationGrantV2 {
  const grant = exactRecord(
    value,
    [
      'schema_version',
      'grant_id',
      'conversation_id',
      'workspace_id',
      'project_id',
      'binding_revision',
      'root_fingerprint_sha256',
      'tool_family',
      'registry_version',
      'policy_version',
      'issued_for',
      'created_at',
    ],
    'E_AGENT_LEDGER',
  );
  if (
    grant.schema_version !== 2 ||
    !uuid(grant.grant_id) ||
    !uuid(grant.conversation_id) ||
    !uuid(grant.workspace_id) ||
    !nullableUuid(grant.project_id) ||
    !safeInteger(grant.binding_revision, MAX_SAFE, false) ||
    !digest(grant.root_fingerprint_sha256) ||
    !['file_write', 'git_commit', 'git_push', 'guest_service'].includes(grant.tool_family as string) ||
    !isAgentRegistryVersion(grant.registry_version) ||
    (grant.tool_family === 'guest_service' && grant.registry_version === 1) ||
    !boundedString(grant.policy_version, 128) ||
    !timestamp(grant.created_at)
  )
    fail('E_AGENT_LEDGER');
  assign(grant, 'issued_for', validateIssuedFor(grant.issued_for));
  return grant as AgentConversationGrantV2;
}

function validateApprovalToken(value: unknown): AgentApprovalBindingTokenV2 {
  const token = exactRecord(
    value,
    [
      'schema_version',
      'token',
      'controller_cas',
      'task_id',
      'attempt_id',
      'round_id',
      'round_index',
      'batch_call_ids',
      'batch_arguments_sha256',
      'batch_revision',
      'manifest_sha256',
      'call_index',
      'call_id',
      'name',
      'arguments_sha256',
      'idempotency_key',
      'root_fingerprint_sha256',
      'binding_revision',
      'policy_version',
      'registry_version',
      'access',
      'allowed_decisions',
    ],
    'E_AGENT_APPROVAL',
  );
  if (
    token.schema_version !== 2 ||
    !uuid(token.token) ||
    !uuid(token.task_id) ||
    !uuid(token.attempt_id) ||
    !uuid(token.round_id) ||
    !safeInteger(token.round_index, MAX_ROUNDS) ||
    !safeInteger(token.batch_revision, MAX_SAFE, false) ||
    !digest(token.manifest_sha256) ||
    !safeInteger(token.call_index, MAX_CALLS) ||
    !opaqueId(token.call_id) ||
    !name(token.name) ||
    !digest(token.arguments_sha256) ||
    !digest(token.idempotency_key) ||
    !digest(token.root_fingerprint_sha256) ||
    !safeInteger(token.binding_revision, MAX_SAFE, false) ||
    token.policy_version !== 'agent-v1' ||
    !isAgentRegistryVersion(token.registry_version) ||
    !agentToolRegistryCompatible(token.name, token.registry_version) ||
    !['conversation_confirm', 'confirm_once'].includes(token.access as string)
  )
    fail('E_AGENT_APPROVAL');
  assign(token, 'controller_cas', validateControllerCAS(token.controller_cas));
  const ids = strictArray(token.batch_call_ids, 16, 1, 'E_AGENT_APPROVAL');
  const digests = strictArray(
    token.batch_arguments_sha256,
    16,
    1,
    'E_AGENT_APPROVAL',
  );
  if (ids.length !== digests.length || token.call_index >= ids.length)
    fail('E_AGENT_APPROVAL');
  const seenIds = new Set<string>();
  const safeIds: string[] = [];
  const safeDigests: string[] = [];
  for (let index = 0; index < ids.length; index += 1) {
    if (
      !opaqueId(ids[index]) ||
      seenIds.has(ids[index] as string) ||
      !digest(digests[index])
    )
      fail('E_AGENT_APPROVAL');
    seenIds.add(ids[index] as string);
    safeIds.push(ids[index] as string);
    safeDigests.push(digests[index] as string);
  }
  if (
    safeIds[token.call_index] !== token.call_id ||
    safeDigests[token.call_index] !== token.arguments_sha256
  )
    fail('E_AGENT_APPROVAL');
  const decisions = strictArray(
    token.allowed_decisions,
    4,
    1,
    'E_AGENT_APPROVAL',
  );
  const expected =
    token.access === 'conversation_confirm'
      ? ['denied', 'allow_once', 'allow_conversation', 'cancelled']
      : ['denied', 'allow_once', 'cancelled'];
  if (
    decisions.length !== expected.length ||
    decisions.some((item, index) => item !== expected[index])
  )
    fail('E_AGENT_APPROVAL');
  for (const decision of decisions)
    if (
      !['denied', 'allow_once', 'allow_conversation', 'cancelled'].includes(
        decision as string,
      )
    )
      fail('E_AGENT_APPROVAL');
  assign(token, 'batch_call_ids', safeIds);
  assign(token, 'batch_arguments_sha256', safeDigests);
  assign(token, 'allowed_decisions', decisions);
  return token as AgentApprovalBindingTokenV2;
}

function validateRoundCall(value: unknown): AgentRoundCallPresentationV3 {
  const call = exactRecord(
    value,
    [
      'schema_version',
      'call_index',
      'call_id',
      'name',
      'arguments_sha256',
      'safe_summary_key',
      'access',
      'approval_state',
    ],
    'E_AGENT_LEDGER',
  );
  if (
    call.schema_version !== 3 ||
    !safeInteger(call.call_index, MAX_CALLS) ||
    !opaqueId(call.call_id) ||
    !name(call.name) ||
    !digest(call.arguments_sha256) ||
    !summary(call.safe_summary_key) ||
    !['auto', 'conversation_confirm', 'confirm_once', 'durable_deny'].includes(
      call.access as string,
    ) ||
    !['deferred', 'durable_denied'].includes(call.approval_state as string)
  )
    fail('E_AGENT_LEDGER');
  if (call.access === 'durable_deny') {
    if (
      call.safe_summary_key !== 'agent.unknown' ||
      call.approval_state !== 'durable_denied'
    )
      fail('E_AGENT_LEDGER');
  } else if (call.approval_state !== 'deferred') fail('E_AGENT_LEDGER');
  return call as AgentRoundCallPresentationV3;
}

function validateOrderedRoundCalls(
  value: unknown,
  minimum = 1,
): AgentRoundCallPresentationV3[] {
  const calls = strictArray(value, 16, minimum, 'E_AGENT_LEDGER').map(
    validateRoundCall,
  );
  for (let index = 0; index < calls.length; index += 1)
    if (calls[index].call_index !== index) fail('E_AGENT_LEDGER');
  return calls;
}

function validatePreviewPath(value: unknown): value is string {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    utf8Bytes(value) === null ||
    utf8Bytes(value)! > 512 ||
    value.startsWith('/') ||
    value.includes('\\') ||
    value.includes('\u0000')
  )
    return false;
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit < 0x20 || unit === 0x7f) return false;
  }
  return true;
}

function validateApprovalPreview(
  value: unknown,
  allowLegacyGuestCgiEmpty = false,
): AgentApprovalPreviewV1 | null {
  if (value === null) return null;
  const preview = exactRecord(
    value,
    [
      'schema_version',
      'kind',
      'paths',
      'content_bytes',
      'prior',
      'diff_preview',
      'diff_truncated',
    ],
    'E_AGENT_LEDGER',
  );
  if (
    preview.schema_version !== 1 ||
    ![
      'list_dir',
      'read_file',
      'write_file',
      'git_commit',
      'git_push',
      'start_guest_cgi',
      'stop_guest_cgi',
      'list_runtime_environments', 'install_runtime_environment', 'run_program', 'start_runtime_service', 'stop_runtime_service',
    ].includes(preview.kind as string) ||
    !Array.isArray(preview.paths) ||
    preview.paths.length > 8 ||
    !preview.paths.every(validatePreviewPath) ||
    (preview.content_bytes !== null &&
      !safeInteger(preview.content_bytes, MAX_SINGLE_WRITE_BYTES)) ||
    !booleanValue(preview.diff_truncated) ||
    (preview.diff_preview !== null &&
      !boundedString(preview.diff_preview, 4096, true))
  )
    fail('E_AGENT_LEDGER');
  let prior: AgentApprovalPreviewV1['prior'];
  if (preview.prior === null) {
    prior = null;
  } else {
    const record = exactRecord(
      preview.prior,
      ['schema_version', 'kind', 'bytes'],
      'E_AGENT_LEDGER',
    );
    if (
      record.schema_version !== 1 ||
      !['absent', 'known'].includes(record.kind as string) ||
      (record.bytes !== null &&
        !safeInteger(record.bytes, MAX_SINGLE_WRITE_BYTES * 2))
    )
      fail('E_AGENT_LEDGER');
    prior = record as unknown as AgentApprovalPreviewV1['prior'];
  }
  assign(preview, 'paths', preview.paths);
  assign(preview, 'prior', prior);
  if (preview.kind === 'write_file') {
    if (
      preview.paths.length !== 1 ||
      preview.content_bytes === null ||
      preview.prior === null
    )
      fail('E_AGENT_LEDGER');
  } else if (preview.kind === 'git_commit' || preview.kind === 'git_push') {
    if (
      preview.paths.length !== 0 ||
      preview.content_bytes !== null ||
      preview.prior !== null ||
      preview.diff_preview !== null
    )
      fail('E_AGENT_LEDGER');
  } else if (preview.kind === 'start_guest_cgi') {
    if (
      ((preview.paths.length !== 2 && preview.paths.length !== 3) &&
        !(allowLegacyGuestCgiEmpty && preview.paths.length === 0)) ||
      preview.content_bytes !== null ||
      preview.prior !== null ||
      preview.diff_preview !== null
    )
      fail('E_AGENT_LEDGER');
  } else if (isRuntimeAgentTool(preview.kind)) {
    const expectedPaths = preview.kind === 'run_program' || preview.kind === 'start_runtime_service' ? 1 : 0;
    if (preview.paths.length !== expectedPaths || preview.content_bytes !== null || preview.prior !== null || preview.diff_preview !== null || preview.diff_truncated) fail('E_AGENT_LEDGER');
  } else if (preview.kind === 'stop_guest_cgi') {
    if (
      preview.paths.length !== 0 ||
      preview.content_bytes !== null ||
      preview.prior !== null ||
      preview.diff_preview !== null
    )
      fail('E_AGENT_LEDGER');
  } else if (
    preview.content_bytes !== null ||
    preview.prior !== null ||
    preview.diff_preview !== null
  ) {
    fail('E_AGENT_LEDGER');
  }
  return preview as unknown as AgentApprovalPreviewV1;
}

function validateBatchCall(value: unknown): AgentBatchCallProjectionV2 {
  const call = exactRecord(
    value,
    [
      'schema_version',
      'call_index',
      'call_id',
      'name',
      'arguments_sha256',
      'idempotency_key',
      'safe_summary_key',
      'approval_preview',
      'access',
      'approval_state',
      'approval_token',
      'approval_reference',
      'execution_status',
      'execution_revision',
      'native_row_revision',
      'receipt',
    ],
    'E_AGENT_LEDGER',
  );
  if (
    call.schema_version !== 2 ||
    !safeInteger(call.call_index, MAX_CALLS) ||
    !opaqueId(call.call_id) ||
    !name(call.name) ||
    !digest(call.arguments_sha256) ||
    !nullableDigest(call.idempotency_key) ||
    !summary(call.safe_summary_key) ||
    !['auto', 'conversation_confirm', 'confirm_once', 'durable_deny'].includes(
      call.access as string,
    ) ||
    !['not_required', 'pending', 'bound', 'denied', 'cancelled'].includes(
      call.approval_state as string,
    ) ||
    ![
      'not_started',
      'intent',
      'running',
      'cancel_requested',
      'completed',
      'failed',
      'denied',
      'cancelled',
      'unknown',
      'ambiguous',
    ].includes(call.execution_status as string) ||
    (call.execution_revision !== null &&
      !safeInteger(call.execution_revision, MAX_SAFE, false)) ||
    (call.native_row_revision !== null &&
      !safeInteger(call.native_row_revision, MAX_SAFE, false)) ||
    (call.receipt !== null && typeof call.receipt !== 'object') ||
    !nullableUuid(call.approval_reference)
  )
    fail('E_AGENT_LEDGER');
  const approvalToken =
    call.approval_token === null
      ? null
      : validateApprovalToken(call.approval_token);
  const receipt =
    call.receipt === null ? null : validateToolReceipt(call.receipt);
  const approvalPreview = validateApprovalPreview(
    call.approval_preview,
    call.name === 'start_guest_cgi' && approvalToken?.registry_version === 2,
  );
  assign(call, 'approval_token', approvalToken);
  assign(call, 'receipt', receipt);
  assign(call, 'approval_preview', approvalPreview);
  if (call.access === 'durable_deny') {
    if (
      call.safe_summary_key !== 'agent.unknown' ||
      call.approval_state !== 'denied' ||
      call.execution_status !== 'denied' ||
      call.idempotency_key !== null ||
      call.approval_token !== null ||
      call.approval_reference !== null ||
      call.execution_revision !== null
    )
      fail('E_AGENT_LEDGER');
  } else if (call.safe_summary_key === 'agent.unknown') {
    fail('E_AGENT_LEDGER');
  }
  if (
    call.access === 'auto' &&
    (call.approval_state !== 'not_required' ||
      call.approval_token !== null ||
      call.approval_reference !== null)
  )
    fail('E_AGENT_LEDGER');
  if (call.access !== 'durable_deny' && call.idempotency_key === null)
    fail('E_AGENT_LEDGER');
  if (call.approval_state === 'pending') {
    if (call.approval_token === null || call.approval_reference !== null)
      fail('E_AGENT_LEDGER');
  }
  if (call.approval_state === 'bound' && call.approval_reference === null)
    fail('E_AGENT_LEDGER');
  if (approvalToken !== null) {
    const token = approvalToken;
    if (
      token.call_index !== call.call_index ||
      token.call_id !== call.call_id ||
      token.name !== call.name ||
      token.arguments_sha256 !== call.arguments_sha256 ||
      token.idempotency_key !== call.idempotency_key ||
      token.access !== call.access
    )
      fail('E_AGENT_LEDGER');
  }
  if (
    call.execution_status === 'not_started' &&
    call.execution_revision !== null
  )
    fail('E_AGENT_LEDGER');
  if (
    call.execution_status !== 'not_started' &&
    call.execution_revision === null
  )
    fail('E_AGENT_LEDGER');
  if (
    ['completed', 'failed', 'cancelled', 'ambiguous'].includes(
      call.execution_status as string,
    ) &&
    call.receipt === null
  )
    fail('E_AGENT_LEDGER');
  if (
    [
      'intent',
      'running',
      'cancel_requested',
      'unknown',
      'not_started',
    ].includes(call.execution_status as string) &&
    call.receipt !== null
  )
    fail('E_AGENT_LEDGER');
  if (receipt !== null) {
    validateReceiptBinding(
      receipt,
      call.call_id,
      call.name,
      call.arguments_sha256,
      call.approval_reference,
    );
    const expectedOutcome =
      call.execution_status === 'completed'
        ? 'ok'
        : call.execution_status === 'failed'
        ? 'failed'
        : call.execution_status === 'denied'
        ? 'denied'
        : call.execution_status === 'cancelled'
        ? 'cancelled'
        : call.execution_status === 'ambiguous'
        ? 'ambiguous'
        : null;
    if (expectedOutcome !== null && receipt.outcome !== expectedOutcome)
      fail('E_AGENT_LEDGER');
  }
  return call as AgentBatchCallProjectionV2;
}

function validateAttemptProjection(value: unknown): AgentAttemptProjectionV2 {
  const attempt = exactRecord(
    value,
    [
      'schema_version',
      'task_id',
      'conversation_id',
      'attempt_id',
      'phase',
      'controller_generation',
      'journal_revision',
      'authority_revision',
      'root',
      'policy',
      'registry',
      'transcript',
      'round_index',
      'round_id',
      'round_revision',
      'round_status',
      'batch_kind',
      'batch_revision',
      'manifest_sha256',
      'call_index',
      'batch',
      'frozen_grant_ids',
      'reserved_write_bytes',
      'cancel_source_event_id',
      'cleanup_id',
    ],
    'E_AGENT_LEDGER',
  );
  if (
    attempt.schema_version !== 2 ||
    !uuid(attempt.task_id) ||
    !uuid(attempt.conversation_id) ||
    !uuid(attempt.attempt_id) ||
    ![
      'not_agent',
      'ready_for_round',
      'round_in_flight',
      'batch_frozen',
      'approval_pending',
      'execution_intent',
      'tool_result_pending',
      'final_response',
      'cancelled',
      'failed',
      'unknown',
      'ambiguous',
    ].includes(attempt.phase as string) ||
    !safeInteger(attempt.controller_generation, MAX_SAFE) ||
    !safeInteger(attempt.journal_revision, MAX_SAFE) ||
    !safeInteger(attempt.authority_revision, MAX_SAFE) ||
    !safeInteger(attempt.round_index, MAX_ROUNDS) ||
    !nullableUuid(attempt.round_id) ||
    (attempt.round_revision !== null &&
      !safeInteger(attempt.round_revision, MAX_SAFE, false)) ||
    (attempt.round_status !== null &&
      ![
        'ready',
        'active',
        'failed_retryable',
        'completed',
        'cancel_requested',
        'cancelled',
        'unknown',
        'ambiguous',
      ].includes(attempt.round_status as string)) ||
    (attempt.batch_kind !== null &&
      !['write_batch', 'read_only_batch'].includes(
        attempt.batch_kind as string,
      )) ||
    (attempt.batch_revision !== null &&
      !safeInteger(attempt.batch_revision, MAX_SAFE, false)) ||
    !nullableDigest(attempt.manifest_sha256) ||
    (attempt.call_index !== null &&
      !safeInteger(attempt.call_index, MAX_CALLS)) ||
    !safeInteger(attempt.reserved_write_bytes, MAX_ATTEMPT_WRITE_BYTES) ||
    !nullableUuid(attempt.cancel_source_event_id) ||
    !nullableUuid(attempt.cleanup_id)
  )
    fail('E_AGENT_LEDGER');
  assign(
    attempt,
    'root',
    attempt.root === null ? null : validateRoot(attempt.root),
  );
  assign(
    attempt,
    'policy',
    attempt.policy === null ? null : validatePolicy(attempt.policy),
  );
  const registry = validateRegistry(attempt.registry);
  assign(attempt, 'registry', registry);
  assign(
    attempt,
    'transcript',
    attempt.transcript === null ? null : validateTranscript(attempt.transcript),
  );
  const batch = strictArray(attempt.batch, 16, 0, 'E_AGENT_LEDGER').map(
    validateBatchCall,
  );
  if (batch.some(call => !agentToolRegistryCompatible(call.name, registry.registry_version))) fail('E_AGENT_LEDGER');
  const grants = validateUuidArray(attempt.frozen_grant_ids, 2);
  assign(attempt, 'batch', batch);
  assign(attempt, 'frozen_grant_ids', grants);
  if (
    attempt.round_id === null &&
    (attempt.round_revision !== null || attempt.round_status !== null)
  )
    fail('E_AGENT_LEDGER');
  if (
    attempt.round_id !== null &&
    (attempt.round_revision === null || attempt.round_status === null)
  )
    fail('E_AGENT_LEDGER');
  if (
    attempt.batch_kind === null &&
    (attempt.batch_revision !== null ||
      attempt.manifest_sha256 !== null ||
      batch.length !== 0)
  )
    fail('E_AGENT_LEDGER');
  if (
    attempt.batch_kind === 'write_batch' &&
    (attempt.batch_revision === null || attempt.manifest_sha256 === null)
  )
    fail('E_AGENT_LEDGER');
  if (
    attempt.batch_kind === 'read_only_batch' &&
    (attempt.batch_revision === null || attempt.manifest_sha256 !== null)
  )
    fail('E_AGENT_LEDGER');
  if (attempt.call_index !== null && attempt.call_index >= batch.length)
    fail('E_AGENT_LEDGER');
  if (attempt.phase === 'not_agent') {
    if (
      attempt.root !== null ||
      attempt.policy !== null ||
      attempt.transcript !== null ||
      registry.tools.length !== 0 ||
      attempt.authority_revision !== 0 ||
      attempt.round_id !== null ||
      attempt.batch_kind !== null ||
      attempt.reserved_write_bytes !== 0 ||
      batch.length !== 0 ||
      attempt.cancel_source_event_id !== null
    )
      fail('E_AGENT_LEDGER');
  } else if (
    attempt.root === null ||
    attempt.policy === null ||
    attempt.transcript === null ||
    attempt.authority_revision === 0
  )
    fail('E_AGENT_LEDGER');
  return attempt as AgentAttemptProjectionV2;
}

function validateRoundOutcome(value: unknown): AgentRoundOutcomeV3 {
  const kindRecord = peekRecord(
    value,
    [
      'schema_version',
      'kind',
      'finish_reason',
      'completion_receipt',
      'transcript',
    ],
    'E_AGENT_LEDGER',
  );
  const kind = kindRecord.kind;
  if (kind === 'final') {
    const outcome = exactRecord(
      value,
      [
        'schema_version',
        'kind',
        'finish_reason',
        'completion_receipt',
        'transcript',
        'text',
        'reasoning',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      outcome.schema_version !== 3 ||
      outcome.kind !== 'final' ||
      outcome.finish_reason !== 'stop' ||
      !boundedString(outcome.text, MAX_TEXT_BYTES, true) ||
      !boundedString(outcome.reasoning, MAX_TEXT_BYTES, true)
    )
      fail('E_AGENT_LEDGER');
    assign(
      outcome,
      'completion_receipt',
      validateRoundReceipt(outcome.completion_receipt),
    );
    assign(outcome, 'transcript', validateTranscript(outcome.transcript));
    if (
      (outcome.completion_receipt as AgentRoundReceiptV2).finish_reason !==
      'stop'
    )
      fail('E_AGENT_LEDGER');
    return outcome as AgentRoundOutcomeV3;
  }
  if (kind === 'tool_batch') {
    const outcome = exactRecord(
      value,
      [
        'schema_version',
        'kind',
        'finish_reason',
        'completion_receipt',
        'transcript',
        'calls',
        'batch_class',
        'executable_call_count',
        'denied_call_count',
        'reasoning',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      outcome.schema_version !== 3 ||
      outcome.kind !== 'tool_batch' ||
      outcome.finish_reason !== 'tool_calls' ||
      !['executable', 'mixed', 'denied_only'].includes(
        outcome.batch_class as string,
      ) ||
      !safeInteger(outcome.executable_call_count, 16) ||
      !safeInteger(outcome.denied_call_count, 16) ||
      !boundedString(outcome.reasoning, MAX_TEXT_BYTES, true)
    )
      fail('E_AGENT_LEDGER');
    assign(
      outcome,
      'completion_receipt',
      validateRoundReceipt(outcome.completion_receipt),
    );
    assign(outcome, 'transcript', validateTranscript(outcome.transcript));
    const calls = validateOrderedRoundCalls(outcome.calls);
    assign(outcome, 'calls', calls);
    const denied = calls.filter(call => call.access === 'durable_deny').length;
    if (
      denied !== outcome.denied_call_count ||
      calls.length - denied !== outcome.executable_call_count
    )
      fail('E_AGENT_LEDGER');
    const expectedClass =
      denied === 0
        ? 'executable'
        : calls.length === denied
        ? 'denied_only'
        : 'mixed';
    if (
      outcome.batch_class !== expectedClass ||
      (outcome.completion_receipt as AgentRoundReceiptV2).finish_reason !==
        'tool_calls'
    )
      fail('E_AGENT_LEDGER');
    return outcome as AgentRoundOutcomeV3;
  }
  if (kind === 'blocked') {
    const outcome = exactRecord(
      value,
      [
        'schema_version',
        'kind',
        'finish_reason',
        'completion_receipt',
        'transcript',
        'failure_code',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      outcome.schema_version !== 3 ||
      outcome.kind !== 'blocked' ||
      !['length', 'content_filter'].includes(outcome.finish_reason as string) ||
      !['E_COMPLETION_LENGTH', 'E_COMPLETION_CONTENT_FILTER'].includes(
        outcome.failure_code as string,
      )
    )
      fail('E_AGENT_LEDGER');
    if (
      (outcome.finish_reason === 'length' &&
        outcome.failure_code !== 'E_COMPLETION_LENGTH') ||
      (outcome.finish_reason === 'content_filter' &&
        outcome.failure_code !== 'E_COMPLETION_CONTENT_FILTER')
    )
      fail('E_AGENT_LEDGER');
    assign(
      outcome,
      'completion_receipt',
      validateRoundReceipt(outcome.completion_receipt),
    );
    assign(outcome, 'transcript', validateTranscript(outcome.transcript));
    if (
      (outcome.completion_receipt as AgentRoundReceiptV2).finish_reason !==
      outcome.finish_reason
    )
      fail('E_AGENT_LEDGER');
    return outcome as AgentRoundOutcomeV3;
  }
  fail('E_AGENT_LEDGER');
}

function validateRecoveredCommon(projection: Record<string, unknown>): void {
  if (
    projection.schema_version !== 2 ||
    !uuid(projection.task_id) ||
    !uuid(projection.attempt_id) ||
    !uuid(projection.round_id) ||
    !safeInteger(projection.round_index, MAX_ROUNDS) ||
    !safeInteger(projection.launch_attempt, MAX_SAFE, false) ||
    !safeInteger(projection.result_round_revision, MAX_SAFE, false) ||
    !boundedString(projection.text, MAX_TEXT_BYTES, true) ||
    !boundedString(projection.reasoning, MAX_TEXT_BYTES, true) ||
    !digest(projection.assistant_text_sha256) ||
    !digest(projection.reasoning_text_sha256)
  )
    fail('E_AGENT_LEDGER');
  assign(projection, 'transcript', validateTranscript(projection.transcript));
  assign(
    projection,
    'completion_receipt',
    validateRoundReceipt(projection.completion_receipt),
  );
  const receipt = projection.completion_receipt as AgentRoundReceiptV2;
  if (
    receipt.task_id !== projection.task_id ||
    receipt.attempt_id !== projection.attempt_id ||
    receipt.round_id !== projection.round_id ||
    receipt.round_index !== projection.round_index ||
    receipt.turn_id !== projection.task_id
  )
    fail('E_AGENT_LEDGER');
}

function validateRecoveredRound(
  value: unknown,
): AgentRecoveredRoundProjectionV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'kind'],
    'E_AGENT_LEDGER',
  );
  const common = [
    'schema_version',
    'kind',
    'task_id',
    'attempt_id',
    'round_id',
    'round_index',
    'launch_attempt',
    'result_round_revision',
    'transcript',
    'completion_receipt',
    'text',
    'reasoning',
    'assistant_text_sha256',
    'reasoning_text_sha256',
  ] as const;
  if (header.kind === 'final') {
    const result = exactRecord(value, common, 'E_AGENT_LEDGER');
    validateRecoveredCommon(result);
    return result as AgentRecoveredRoundProjectionV2;
  }
  if (header.kind === 'blocked') {
    const result = exactRecord(
      value,
      [...common, 'failure_code'],
      'E_AGENT_LEDGER',
    );
    validateRecoveredCommon(result);
    if (
      !['E_COMPLETION_LENGTH', 'E_COMPLETION_CONTENT_FILTER'].includes(
        result.failure_code as string,
      )
    )
      fail('E_AGENT_LEDGER');
    return result as AgentRecoveredRoundProjectionV2;
  }
  if (header.kind === 'tool_batch') {
    const result = exactRecord(
      value,
      [
        ...common,
        'calls',
        'batch_class',
        'executable_call_count',
        'denied_call_count',
      ],
      'E_AGENT_LEDGER',
    );
    validateRecoveredCommon(result);
    if (
      !['executable', 'mixed', 'denied_only'].includes(
        result.batch_class as string,
      ) ||
      !safeInteger(result.executable_call_count, 16) ||
      !safeInteger(result.denied_call_count, 16)
    )
      fail('E_AGENT_LEDGER');
    const calls = validateOrderedRoundCalls(result.calls);
    assign(result, 'calls', calls);
    const denied = calls.filter(call => call.access === 'durable_deny').length;
    if (
      denied !== result.denied_call_count ||
      calls.length - denied !== result.executable_call_count
    )
      fail('E_AGENT_LEDGER');
    return result as AgentRecoveredRoundProjectionV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateTarget(
  value: unknown,
): AgentCancelTargetV2 | AgentRecoveryTargetV2 {
  const header = peekRecord(value, ['schema_version', 'kind']);
  if (header.kind === 'attempt') {
    const target = exactRecord(value, [
      'schema_version',
      'kind',
      'task_id',
      'attempt_id',
    ]);
    if (
      target.schema_version !== 2 ||
      target.kind !== 'attempt' ||
      !uuid(target.task_id) ||
      !uuid(target.attempt_id)
    )
      fail();
    return target as AgentCancelTargetV2 | AgentRecoveryTargetV2;
  }
  if (header.kind === 'round') {
    const target = exactRecord(value, [
      'schema_version',
      'kind',
      'task_id',
      'attempt_id',
      'round_id',
      'round_index',
    ]);
    if (
      target.schema_version !== 2 ||
      target.kind !== 'round' ||
      !uuid(target.task_id) ||
      !uuid(target.attempt_id) ||
      !uuid(target.round_id) ||
      !safeInteger(target.round_index, MAX_ROUNDS)
    )
      fail();
    return target as AgentCancelTargetV2 | AgentRecoveryTargetV2;
  }
  if (header.kind === 'tool') {
    const target = exactRecord(value, [
      'schema_version',
      'kind',
      'task_id',
      'attempt_id',
      'round_id',
      'round_index',
      'call_index',
      'call_id',
      'idempotency_key',
    ]);
    if (
      target.schema_version !== 2 ||
      target.kind !== 'tool' ||
      !uuid(target.task_id) ||
      !uuid(target.attempt_id) ||
      !uuid(target.round_id) ||
      !safeInteger(target.round_index, MAX_ROUNDS) ||
      !safeInteger(target.call_index, MAX_CALLS) ||
      !opaqueId(target.call_id) ||
      !digest(target.idempotency_key)
    )
      fail();
    return target as AgentCancelTargetV2 | AgentRecoveryTargetV2;
  }
  fail();
}

function validateCancelToken(value: unknown): AgentCancelTokenV2 {
  const token = exactRecord(value, [
    'schema_version',
    'issuer',
    'source_event_id',
    'token',
    'task_id',
    'attempt_id',
    'expected_phase',
    'reason_code',
  ]);
  if (
    token.schema_version !== 2 ||
    token.issuer !== 'completion_controller' ||
    !uuid(token.source_event_id) ||
    token.token !== token.source_event_id ||
    !uuid(token.task_id) ||
    !uuid(token.attempt_id) ||
    ![
      'ready_for_round',
      'batch_frozen',
      'round_in_flight',
      'approval_pending',
      'execution_intent',
      'tool_result_pending',
    ].includes(token.expected_phase as string) ||
    ![
      'E_AGENT_CANCELLED',
      'E_AGENT_ROOT_STALE',
      'E_AGENT_PERSISTENCE',
    ].includes(token.reason_code as string)
  )
    fail();
  return token as AgentCancelTokenV2;
}

function validateIdentity(
  cas: AgentRuntimeControllerCASV1,
  request: { task_id: string; conversation_id: string; attempt_id: string },
): void {
  if (
    cas.task_id !== request.task_id ||
    cas.conversation_id !== request.conversation_id ||
    cas.attempt_id !== request.attempt_id
  )
    fail();
}

/** A committed Store checkpoint is the CAS's exact session assertion. */
function validateControllerCheckpointRelation(
  cas: AgentRuntimeControllerCASV1,
  checkpoint: AgentRuntimeCommittedCheckpointV1,
): void {
  if (
    cas.expected_journal_revision !== checkpoint.journal_revision ||
    cas.expected_session_generation !== checkpoint.session_generation ||
    cas.expected_session_sha256 !== checkpoint.session_sha256
  )
    fail();
}

function validateTransportContext(
  transport: 2 | 3,
  projectId: string | null,
  context: string | null,
  rootKind?: 'project' | 'workspace',
): void {
  if (transport === 2 && context !== null) fail();
  if (
    transport === 3 &&
    (context === null || projectId === null || rootKind === 'workspace')
  )
    fail();
  if (rootKind === 'workspace' && projectId !== null) fail();
}

function requestRecord(
  value: unknown,
  keys: readonly string[],
): Record<string, unknown> {
  return exactRecord(value, keys, 'E_AGENT_BAD_ARGUMENTS');
}

function validateAttemptRequest(value: unknown): PrepareAgentAttemptRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'operation_id',
    'controller_cas',
    'committed_checkpoint',
    'task_id',
    'conversation_id',
    'attempt_id',
    'workspace_id',
    'project_id',
    'workspace_binding_revision',
    'transport_schema_version',
    'harness_id',
    'model',
    'thinking_mode',
    'visible_message_ids',
    'visible_history_sha256',
    'visible_message_count',
    'project_context_sha256',
    'registry_version',
    'expected_policy_version',
    'expected_transcript',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.operation_id) ||
    !uuid(request.task_id) ||
    !uuid(request.conversation_id) ||
    !uuid(request.attempt_id) ||
    (request.transport_schema_version !== 2 &&
      request.transport_schema_version !== 3) ||
    !harness(request.harness_id) ||
    !model(request.model) ||
    !thinkingMode(request.thinking_mode) ||
    !digest(request.visible_history_sha256) ||
    !safeInteger(request.visible_message_count, MAX_VISIBLE_MESSAGES) ||
    !isAgentRegistryVersion(request.registry_version) ||
    (request.expected_policy_version !== null &&
      request.expected_policy_version !== 'agent-v1') ||
    !nullableUuid(request.workspace_id) ||
    !nullableUuid(request.project_id) ||
    (request.workspace_binding_revision !== null &&
      !safeInteger(request.workspace_binding_revision, MAX_SAFE, false)) ||
    !nullableDigest(request.project_context_sha256)
  )
    fail();
  const cas = validateControllerCAS(request.controller_cas);
  const checkpoint = validateCheckpoint(request.committed_checkpoint);
  validateIdentity(
    cas,
    request as { task_id: string; conversation_id: string; attempt_id: string },
  );
  validateControllerCheckpointRelation(cas, checkpoint);
  if (
    request.workspace_id === null ||
    request.workspace_binding_revision === null
  ) {
    if (
      request.workspace_id !== null ||
      request.project_id !== null ||
      request.workspace_binding_revision !== null ||
      request.transport_schema_version === 3
    )
      fail();
  }
  validateTransportContext(
    request.transport_schema_version as 2 | 3,
    request.project_id as string | null,
    request.project_context_sha256 as string | null,
  );
  const visible = validateUuidArray(
    request.visible_message_ids,
    MAX_VISIBLE_MESSAGES,
  );
  if (request.visible_message_count !== visible.length) fail();
  assign(request, 'controller_cas', cas);
  assign(request, 'committed_checkpoint', checkpoint);
  assign(request, 'visible_message_ids', visible);
  assign(
    request,
    'expected_transcript',
    request.expected_transcript === null
      ? null
      : validateTranscript(request.expected_transcript),
  );
  return request as PrepareAgentAttemptRequestV2;
}

function validateCompleteRequest(value: unknown): CompleteAgentRoundRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'operation_id',
    'controller_cas',
    'committed_checkpoint',
    'task_id',
    'conversation_id',
    'attempt_id',
    'round_id',
    'round_index',
    'launch_attempt',
    'expected_round_revision',
    'transport_schema_version',
    'harness_id',
    'model',
    'thinking_mode',
    'visible_history_sha256',
    'visible_message_count',
    'project_context_sha256',
    'transcript',
    'root',
    'registry_version',
    'toolset_sha256',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.operation_id) ||
    !uuid(request.task_id) ||
    !uuid(request.conversation_id) ||
    !uuid(request.attempt_id) ||
    !uuid(request.round_id) ||
    !safeInteger(request.round_index, MAX_ROUNDS) ||
    !safeInteger(request.launch_attempt, MAX_SAFE, false) ||
    !safeInteger(request.expected_round_revision, MAX_SAFE) ||
    (request.transport_schema_version !== 2 &&
      request.transport_schema_version !== 3) ||
    !harness(request.harness_id) ||
    !model(request.model) ||
    !thinkingMode(request.thinking_mode) ||
    !digest(request.visible_history_sha256) ||
    !safeInteger(request.visible_message_count, MAX_VISIBLE_MESSAGES) ||
    !nullableDigest(request.project_context_sha256) ||
    !isAgentRegistryVersion(request.registry_version) ||
    !digest(request.toolset_sha256)
  )
    fail();
  const cas = validateControllerCAS(request.controller_cas);
  const checkpoint = validateCheckpoint(request.committed_checkpoint);
  const root = validateRoot(request.root);
  validateIdentity(
    cas,
    request as { task_id: string; conversation_id: string; attempt_id: string },
  );
  validateControllerCheckpointRelation(cas, checkpoint);
  validateTransportContext(
    request.transport_schema_version as 2 | 3,
    root.project_id,
    request.project_context_sha256 as string | null,
    root.kind,
  );
  assign(request, 'controller_cas', cas);
  assign(request, 'committed_checkpoint', checkpoint);
  assign(request, 'transcript', validateTranscript(request.transcript));
  assign(request, 'root', root);
  return request as CompleteAgentRoundRequestV2;
}

function validateBatchRequest(value: unknown): PrepareAgentToolBatchRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'operation_id',
    'controller_cas',
    'committed_checkpoint',
    'task_id',
    'conversation_id',
    'attempt_id',
    'round_id',
    'round_index',
    'expected_round_revision',
    'transcript',
    'root',
    'registry_version',
    'toolset_sha256',
    'policy_version',
    'expected_batch_revision',
    'expected_reserved_write_bytes',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.operation_id) ||
    !uuid(request.task_id) ||
    !uuid(request.conversation_id) ||
    !uuid(request.attempt_id) ||
    !uuid(request.round_id) ||
    !safeInteger(request.round_index, MAX_ROUNDS) ||
    !safeInteger(request.expected_round_revision, MAX_SAFE) ||
    !isAgentRegistryVersion(request.registry_version) ||
    !digest(request.toolset_sha256) ||
    request.policy_version !== 'agent-v1' ||
    !safeInteger(request.expected_batch_revision, MAX_SAFE) ||
    !safeInteger(request.expected_reserved_write_bytes, MAX_ATTEMPT_WRITE_BYTES)
  )
    fail();
  const cas = validateControllerCAS(request.controller_cas);
  const checkpoint = validateCheckpoint(request.committed_checkpoint);
  validateIdentity(
    cas,
    request as { task_id: string; conversation_id: string; attempt_id: string },
  );
  validateControllerCheckpointRelation(cas, checkpoint);
  assign(request, 'controller_cas', cas);
  assign(request, 'committed_checkpoint', checkpoint);
  assign(request, 'transcript', validateTranscript(request.transcript));
  assign(request, 'root', validateRoot(request.root));
  return request as PrepareAgentToolBatchRequestV2;
}

function validateBindRequest(value: unknown): BindAgentApprovalRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'operation_id',
    'controller_cas',
    'committed_checkpoint',
    'task_id',
    'conversation_id',
    'attempt_id',
    'round_id',
    'round_index',
    'manifest_sha256',
    'batch_revision',
    'call_index',
    'call_id',
    'token',
    'decision',
    'deny_message',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.operation_id) ||
    !uuid(request.task_id) ||
    !uuid(request.conversation_id) ||
    !uuid(request.attempt_id) ||
    !uuid(request.round_id) ||
    !safeInteger(request.round_index, MAX_ROUNDS) ||
    !digest(request.manifest_sha256) ||
    !safeInteger(request.batch_revision, MAX_SAFE, false) ||
    !safeInteger(request.call_index, MAX_CALLS) ||
    !opaqueId(request.call_id) ||
    !['denied', 'allow_once', 'allow_conversation', 'cancelled'].includes(
      request.decision as string,
    )
  )
    fail();
  if (request.decision === 'denied') {
    if (
      request.deny_message !== null &&
      !boundedString(request.deny_message, 2000, true)
    )
      fail();
  } else if (request.deny_message !== null) {
    fail();
  }
  const cas = validateControllerCAS(request.controller_cas);
  const checkpoint = validateCheckpoint(request.committed_checkpoint);
  const token = validateApprovalToken(request.token);
  validateIdentity(
    cas,
    request as { task_id: string; conversation_id: string; attempt_id: string },
  );
  validateControllerCheckpointRelation(cas, checkpoint);
  if (
    token.task_id !== request.task_id ||
    token.attempt_id !== request.attempt_id ||
    token.round_id !== request.round_id ||
    token.round_index !== request.round_index ||
    token.batch_revision !== request.batch_revision ||
    token.manifest_sha256 !== request.manifest_sha256 ||
    token.call_index !== request.call_index ||
    token.call_id !== request.call_id ||
    !controllerCASCanAdvance(token.controller_cas, cas) ||
    !token.allowed_decisions.includes(
      request.decision as
        | 'denied'
        | 'allow_once'
        | 'allow_conversation'
        | 'cancelled',
    )
  )
    fail('E_AGENT_APPROVAL');
  assign(request, 'controller_cas', cas);
  assign(request, 'committed_checkpoint', checkpoint);
  assign(request, 'token', token);
  return request as BindAgentApprovalRequestV2;
}

function validateExecuteRequest(value: unknown): ExecuteAgentToolRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'operation_id',
    'controller_cas',
    'committed_checkpoint',
    'task_id',
    'conversation_id',
    'attempt_id',
    'round_id',
    'round_index',
    'batch_kind',
    'manifest_sha256',
    'expected_batch_revision',
    'call_index',
    'call_id',
    'name',
    'arguments_sha256',
    'idempotency_key',
    'expected_execution_revision',
    'transcript',
    'root',
    'approval_reference',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.operation_id) ||
    !uuid(request.task_id) ||
    !uuid(request.conversation_id) ||
    !uuid(request.attempt_id) ||
    !uuid(request.round_id) ||
    !safeInteger(request.round_index, MAX_ROUNDS) ||
    !['write_batch', 'read_only_batch'].includes(
      request.batch_kind as string,
    ) ||
    !nullableDigest(request.manifest_sha256) ||
    !safeInteger(request.expected_batch_revision, MAX_SAFE, false) ||
    !safeInteger(request.call_index, MAX_CALLS) ||
    !opaqueId(request.call_id) ||
    !name(request.name) ||
    !digest(request.arguments_sha256) ||
    !digest(request.idempotency_key) ||
    !safeInteger(request.expected_execution_revision, MAX_SAFE, false) ||
    !nullableUuid(request.approval_reference)
  )
    fail();
  if (
    (request.batch_kind === 'write_batch' &&
      request.manifest_sha256 === null) ||
    (request.batch_kind === 'read_only_batch' &&
      request.manifest_sha256 !== null)
  )
    fail();
  const cas = validateControllerCAS(request.controller_cas);
  const checkpoint = validateCheckpoint(request.committed_checkpoint);
  const root = validateRoot(request.root);
  validateIdentity(
    cas,
    request as { task_id: string; conversation_id: string; attempt_id: string },
  );
  validateControllerCheckpointRelation(cas, checkpoint);
  assign(request, 'controller_cas', cas);
  assign(request, 'committed_checkpoint', checkpoint);
  assign(request, 'transcript', validateTranscript(request.transcript));
  assign(request, 'root', root);
  return request as ExecuteAgentToolRequestV2;
}

function validateCancelRequest(value: unknown): CancelAgentAttemptRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'operation_id',
    'controller_cas',
    'committed_checkpoint',
    'target',
    'cancel_token',
    'expected_round_revision',
    'expected_execution_revision',
    'expected_transcript',
    'root',
  ]);
  if (request.schema_version !== 2 || !uuid(request.operation_id)) fail();
  const cas = validateControllerCAS(request.controller_cas);
  const checkpoint = validateCheckpoint(request.committed_checkpoint);
  const target = validateTarget(request.target) as AgentCancelTargetV2;
  const token = validateCancelToken(request.cancel_token);
  validateControllerCheckpointRelation(cas, checkpoint);
  if (
    token.task_id !== target.task_id ||
    token.attempt_id !== target.attempt_id ||
    cas.task_id !== target.task_id ||
    cas.attempt_id !== target.attempt_id
  )
    fail();
  if (
    (request.expected_round_revision !== null &&
      !safeInteger(request.expected_round_revision, MAX_SAFE)) ||
    (request.expected_execution_revision !== null &&
      !safeInteger(request.expected_execution_revision, MAX_SAFE, false))
  )
    fail();
  if (
    (target.kind === 'attempt' &&
      (request.expected_round_revision !== null ||
        request.expected_execution_revision !== null)) ||
    (target.kind === 'round' &&
      (request.expected_round_revision === null ||
        request.expected_execution_revision !== null)) ||
    (target.kind === 'tool' &&
      (request.expected_round_revision !== null ||
        request.expected_execution_revision === null))
  )
    fail();
  assign(request, 'controller_cas', cas);
  assign(request, 'committed_checkpoint', checkpoint);
  assign(request, 'target', target);
  assign(request, 'cancel_token', token);
  assign(
    request,
    'expected_transcript',
    validateTranscript(request.expected_transcript),
  );
  assign(request, 'root', validateRoot(request.root));
  return request as CancelAgentAttemptRequestV2;
}

function validateQueryAttemptRequest(
  value: unknown,
): QueryAgentAttemptRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'controller_cas',
    'task_id',
    'conversation_id',
    'attempt_id',
    'expected_journal_revision',
    'expected_session_generation',
    'expected_session_sha256',
    'expected_transcript',
    'expected_root_fingerprint_sha256',
    'expected_workspace_binding_revision',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.task_id) ||
    !uuid(request.conversation_id) ||
    !uuid(request.attempt_id) ||
    !safeInteger(request.expected_journal_revision, MAX_SAFE) ||
    !safeInteger(request.expected_session_generation, MAX_SAFE) ||
    !digest(request.expected_session_sha256) ||
    !digest(request.expected_root_fingerprint_sha256) ||
    !safeInteger(request.expected_workspace_binding_revision, MAX_SAFE, false)
  )
    fail();
  const cas = validateControllerCAS(request.controller_cas);
  validateIdentity(
    cas,
    request as { task_id: string; conversation_id: string; attempt_id: string },
  );
  assign(request, 'controller_cas', cas);
  assign(
    request,
    'expected_transcript',
    validateTranscript(request.expected_transcript),
  );
  return request as QueryAgentAttemptRequestV2;
}

function validateQueryToolRequest(value: unknown): QueryAgentToolRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'controller_cas',
    'task_id',
    'conversation_id',
    'attempt_id',
    'round_id',
    'round_index',
    'call_index',
    'call_id',
    'idempotency_key',
    'expected_execution_revision',
    'expected_transcript',
    'expected_root_fingerprint_sha256',
    'expected_workspace_binding_revision',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.task_id) ||
    !uuid(request.conversation_id) ||
    !uuid(request.attempt_id) ||
    !uuid(request.round_id) ||
    !safeInteger(request.round_index, MAX_ROUNDS) ||
    !safeInteger(request.call_index, MAX_CALLS) ||
    !opaqueId(request.call_id) ||
    !digest(request.idempotency_key) ||
    !safeInteger(request.expected_execution_revision, MAX_SAFE) ||
    !digest(request.expected_root_fingerprint_sha256) ||
    !safeInteger(request.expected_workspace_binding_revision, MAX_SAFE, false)
  )
    fail();
  const cas = validateControllerCAS(request.controller_cas);
  validateIdentity(
    cas,
    request as { task_id: string; conversation_id: string; attempt_id: string },
  );
  assign(request, 'controller_cas', cas);
  assign(
    request,
    'expected_transcript',
    validateTranscript(request.expected_transcript),
  );
  return request as QueryAgentToolRequestV2;
}

function validateRecoveryRequest(value: unknown): RecoverAgentAttemptRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'operation_id',
    'controller_cas',
    'committed_checkpoint',
    'target',
    'action',
    'expected_round_revision',
    'expected_execution_revision',
    'expected_transcript',
    'root',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.operation_id) ||
    !['reconcile', 'retry_failed_round'].includes(request.action as string)
  )
    fail();
  const cas = validateControllerCAS(request.controller_cas);
  const checkpoint = validateCheckpoint(request.committed_checkpoint);
  const target = validateTarget(request.target) as AgentRecoveryTargetV2;
  validateControllerCheckpointRelation(cas, checkpoint);
  if (
    (request.expected_round_revision !== null &&
      !safeInteger(request.expected_round_revision, MAX_SAFE, false)) ||
    (request.expected_execution_revision !== null &&
      !safeInteger(request.expected_execution_revision, MAX_SAFE, false))
  )
    fail();
  if (
    (target.kind === 'attempt' &&
      (request.expected_round_revision !== null ||
        request.expected_execution_revision !== null)) ||
    (target.kind === 'round' &&
      (request.expected_round_revision === null ||
        request.expected_execution_revision !== null)) ||
    (target.kind === 'tool' &&
      (request.expected_round_revision !== null ||
        request.expected_execution_revision === null))
  )
    fail();
  if (request.action === 'retry_failed_round' && target.kind !== 'round')
    fail();
  if (cas.task_id !== target.task_id || cas.attempt_id !== target.attempt_id)
    fail();
  assign(request, 'controller_cas', cas);
  assign(request, 'committed_checkpoint', checkpoint);
  assign(request, 'target', target);
  assign(
    request,
    'expected_transcript',
    validateTranscript(request.expected_transcript),
  );
  assign(request, 'root', validateRoot(request.root));
  return request as RecoverAgentAttemptRequestV2;
}

function validateFinalizeRequest(
  value: unknown,
): FinalizeAgentAttemptRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'operation_id',
    'controller_cas',
    'committed_checkpoint',
    'task_id',
    'conversation_id',
    'attempt_id',
    'terminal_reason',
    'cleanup_id',
    'transcript',
    'root',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.operation_id) ||
    !uuid(request.task_id) ||
    !uuid(request.conversation_id) ||
    !uuid(request.attempt_id) ||
    !['completed', 'cancelled', 'failed', 'conversation_deleted'].includes(
      request.terminal_reason as string,
    ) ||
    !uuid(request.cleanup_id)
  )
    fail();
  const cas = validateControllerCAS(request.controller_cas);
  const checkpoint = validateCheckpoint(request.committed_checkpoint);
  validateIdentity(
    cas,
    request as { task_id: string; conversation_id: string; attempt_id: string },
  );
  validateControllerCheckpointRelation(cas, checkpoint);
  assign(request, 'controller_cas', cas);
  assign(request, 'committed_checkpoint', checkpoint);
  assign(request, 'transcript', validateTranscript(request.transcript));
  assign(request, 'root', validateRoot(request.root));
  return request as FinalizeAgentAttemptRequestV2;
}

function validateDiscardRequest(value: unknown): DiscardAgentAttemptRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'operation_id',
    'cleanup_id',
    'task_id',
    'conversation_id',
    'attempt_id',
    'transcript_ref',
    'transcript_sha256',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.operation_id) ||
    !uuid(request.cleanup_id) ||
    !uuid(request.task_id) ||
    !uuid(request.conversation_id) ||
    !uuid(request.attempt_id) ||
    !uuid(request.transcript_ref) ||
    !digest(request.transcript_sha256)
  )
    fail();
  return request as DiscardAgentAttemptRequestV2;
}

function validateCleanupRequest(value: unknown): QueryAgentCleanupRequestV2 {
  const request = requestRecord(value, ['schema_version', 'cleanup_id']);
  if (request.schema_version !== 2 || !uuid(request.cleanup_id)) fail();
  return request as QueryAgentCleanupRequestV2;
}

function validateInterruptRequest(
  value: unknown,
): InterruptAgentAttemptRequestV2 {
  const request = requestRecord(value, [
    'schema_version',
    'operation_id',
    'cleanup_id',
    'task_id',
    'conversation_id',
    'attempt_id',
    'transcript_ref',
    'transcript_sha256',
    'reason',
    'expected_session_generation',
    'expected_session_sha256',
  ]);
  if (
    request.schema_version !== 2 ||
    !uuid(request.operation_id) ||
    !uuid(request.cleanup_id) ||
    !uuid(request.task_id) ||
    !uuid(request.conversation_id) ||
    !uuid(request.attempt_id) ||
    !uuid(request.transcript_ref) ||
    !digest(request.transcript_sha256) ||
    !['completed', 'cancelled', 'failed'].includes(request.reason as string) ||
    !safeInteger(request.expected_session_generation, MAX_SAFE, false) ||
    !digest(request.expected_session_sha256)
  )
    fail();
  return request as InterruptAgentAttemptRequestV2;
}

function validateCommonResultIdentity(
  result: Record<string, unknown>,
  request: {
    operation_id?: string;
    task_id?: string;
    attempt_id?: string;
    round_id?: string;
    round_index?: number;
    call_index?: number;
    call_id?: string;
    name?: string;
    idempotency_key?: string;
  },
): void {
  if (
    request.operation_id !== undefined &&
    result.operation_id !== request.operation_id
  )
    fail('E_AGENT_LEDGER');
  if (
    request.task_id !== undefined &&
    result.task_id !== undefined &&
    result.task_id !== request.task_id
  )
    fail('E_AGENT_LEDGER');
  if (
    request.attempt_id !== undefined &&
    result.attempt_id !== undefined &&
    result.attempt_id !== request.attempt_id
  )
    fail('E_AGENT_LEDGER');
  if (
    request.round_id !== undefined &&
    result.round_id !== undefined &&
    result.round_id !== request.round_id
  )
    fail('E_AGENT_LEDGER');
  if (
    request.round_index !== undefined &&
    result.round_index !== undefined &&
    result.round_index !== request.round_index
  )
    fail('E_AGENT_LEDGER');
  if (
    request.call_index !== undefined &&
    result.call_index !== undefined &&
    result.call_index !== request.call_index
  )
    fail('E_AGENT_LEDGER');
  if (
    request.call_id !== undefined &&
    result.call_id !== undefined &&
    result.call_id !== request.call_id
  )
    fail('E_AGENT_LEDGER');
  if (
    request.name !== undefined &&
    result.name !== undefined &&
    result.name !== request.name
  )
    fail('E_AGENT_LEDGER');
  if (
    request.idempotency_key !== undefined &&
    result.idempotency_key !== undefined &&
    result.idempotency_key !== request.idempotency_key
  )
    fail('E_AGENT_LEDGER');
}

function sameCheckpoint(
  left: AgentRuntimeCommittedCheckpointV1,
  right: AgentRuntimeCommittedCheckpointV1,
): boolean {
  return (
    left.journal_revision === right.journal_revision &&
    left.session_generation === right.session_generation &&
    left.session_sha256 === right.session_sha256
  );
}

function controllerCASCanAdvance(
  issued: AgentRuntimeControllerCASV1,
  current: AgentRuntimeControllerCASV1,
): boolean {
  if (
    issued.conversation_id !== current.conversation_id ||
    issued.task_id !== current.task_id ||
    issued.attempt_id !== current.attempt_id ||
    issued.expected_controller_generation > current.expected_controller_generation ||
    issued.expected_journal_revision > current.expected_journal_revision ||
    issued.expected_session_generation > current.expected_session_generation
  ) return false;
  return issued.expected_session_generation !== current.expected_session_generation ||
    issued.expected_session_sha256 === current.expected_session_sha256;
}

function validatePrepareResult(
  value: unknown,
  request: PrepareAgentAttemptRequestV2,
): PrepareAgentAttemptResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  if (header.status === 'prepared' || header.status === 'already_prepared') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'attempt',
        'observed_checkpoint',
      ],
      'E_AGENT_LEDGER',
    );
    assign(result, 'attempt', validateAttemptProjection(result.attempt));
    assign(
      result,
      'observed_checkpoint',
      validateCheckpoint(result.observed_checkpoint),
    );
    validateCommonResultIdentity(result, request);
    if (
      !sameCheckpoint(
        result.observed_checkpoint as AgentRuntimeCommittedCheckpointV1,
        request.committed_checkpoint,
      ) ||
      (result.attempt as AgentAttemptProjectionV2).task_id !==
        request.task_id ||
      (result.attempt as AgentAttemptProjectionV2).conversation_id !==
        request.conversation_id ||
      (result.attempt as AgentAttemptProjectionV2).attempt_id !==
        request.attempt_id
    )
      fail('E_AGENT_LEDGER');
    return result as PrepareAgentAttemptResultV2;
  }
  if (header.status === 'not_agent') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'attempt',
        'failure_code',
        'observed_checkpoint',
      ],
      'E_AGENT_LEDGER',
    );
    assign(result, 'attempt', validateAttemptProjection(result.attempt));
    assign(
      result,
      'observed_checkpoint',
      validateCheckpoint(result.observed_checkpoint),
    );
    validateCommonResultIdentity(result, request);
    if (
      result.failure_code !== 'E_AGENT_NO_ROOT' ||
      (result.attempt as AgentAttemptProjectionV2).phase !== 'not_agent' ||
      !sameCheckpoint(
        result.observed_checkpoint as AgentRuntimeCommittedCheckpointV1,
        request.committed_checkpoint,
      )
    )
      fail('E_AGENT_LEDGER');
    return result as PrepareAgentAttemptResultV2;
  }
  if (header.status === 'conflict') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'failure_code',
        'expected_controller_generation',
        'expected_journal_revision',
        'expected_session_generation',
        'expected_session_sha256',
        'actual_controller_generation',
        'actual_journal_revision',
        'actual_session_generation',
        'actual_session_sha256',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      ![
        'E_AGENT_CONFLICT',
        'E_AGENT_ROOT_STALE',
        'E_AGENT_TRANSCRIPT',
      ].includes(result.failure_code as string) ||
      !safeInteger(result.expected_controller_generation, MAX_SAFE) ||
      !safeInteger(result.expected_journal_revision, MAX_SAFE) ||
      !safeInteger(result.expected_session_generation, MAX_SAFE) ||
      !digest(result.expected_session_sha256) ||
      !safeInteger(result.actual_controller_generation, MAX_SAFE) ||
      !safeInteger(result.actual_journal_revision, MAX_SAFE) ||
      !safeInteger(result.actual_session_generation, MAX_SAFE) ||
      !digest(result.actual_session_sha256)
    )
      fail('E_AGENT_LEDGER');
    validateCommonResultIdentity(result, request);
    if (
      result.expected_controller_generation !==
        request.controller_cas.expected_controller_generation ||
      result.expected_journal_revision !==
        request.controller_cas.expected_journal_revision ||
      result.expected_session_generation !==
        request.controller_cas.expected_session_generation ||
      result.expected_session_sha256 !==
        request.controller_cas.expected_session_sha256
    )
      fail('E_AGENT_LEDGER');
    return result as PrepareAgentAttemptResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateCompleteResult(
  value: unknown,
  request: CompleteAgentRoundRequestV2,
): CompleteAgentRoundResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  if (header.status === 'completed') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'task_id',
        'attempt_id',
        'round_id',
        'round_index',
        'launch_attempt',
        'result_round_revision',
        'transcript',
        'outcome',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      !safeInteger(result.launch_attempt, MAX_SAFE, false) ||
      !safeInteger(result.result_round_revision, MAX_SAFE, false)
    )
      fail('E_AGENT_LEDGER');
    assign(result, 'transcript', validateTranscript(result.transcript));
    assign(result, 'outcome', validateRoundOutcome(result.outcome));
    validateCommonResultIdentity(result, request);
    const outcome = result.outcome as AgentRoundOutcomeV3;
    const receipt = outcome.completion_receipt;
    if (
      result.launch_attempt !== request.launch_attempt ||
      receipt.task_id !== request.task_id ||
      receipt.attempt_id !== request.attempt_id ||
      receipt.round_id !== request.round_id ||
      receipt.round_index !== request.round_index ||
      receipt.turn_id !== request.task_id ||
      receipt.transport_schema_version !== request.transport_schema_version
    )
      fail('E_AGENT_LEDGER');
    return result as CompleteAgentRoundResultV2;
  }
  if (header.status === 'in_flight') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'task_id',
        'attempt_id',
        'round_id',
        'round_index',
        'launch_attempt',
        'result_round_revision',
        'transcript',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      !safeInteger(result.launch_attempt, MAX_SAFE, false) ||
      !safeInteger(result.result_round_revision, MAX_SAFE, false)
    )
      fail('E_AGENT_LEDGER');
    assign(result, 'transcript', validateTranscript(result.transcript));
    validateCommonResultIdentity(result, request);
    if (result.launch_attempt !== request.launch_attempt)
      fail('E_AGENT_LEDGER');
    return result as CompleteAgentRoundResultV2;
  }
  if (
    header.status === 'failed_retryable' ||
    header.status === 'cancelled' ||
    header.status === 'unknown' ||
    header.status === 'ambiguous'
  ) {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'task_id',
        'attempt_id',
        'round_id',
        'round_index',
        'launch_attempt',
        'result_round_revision',
        'transcript',
        'failure_code',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      !safeInteger(result.launch_attempt, MAX_SAFE, false) ||
      !safeInteger(result.result_round_revision, MAX_SAFE, false) ||
      !isRuntimeFailureCode(result.failure_code)
    )
      fail('E_AGENT_LEDGER');
    assign(result, 'transcript', validateTranscript(result.transcript));
    validateCommonResultIdentity(result, request);
    if (result.launch_attempt !== request.launch_attempt)
      fail('E_AGENT_LEDGER');
    return result as CompleteAgentRoundResultV2;
  }
  if (header.status === 'conflict') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'failure_code',
        'expected_round_revision',
        'actual_round_revision',
        'actual_round_status',
        'actual_transcript',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      ![
        'E_AGENT_CONFLICT',
        'E_AGENT_TRANSCRIPT',
        'E_AGENT_ROOT_STALE',
      ].includes(result.failure_code as string) ||
      !safeInteger(result.expected_round_revision, MAX_SAFE) ||
      !safeInteger(result.actual_round_revision, MAX_SAFE) ||
      ![
        'in_flight',
        'failed_retryable',
        'completed',
        'cancel_requested',
        'cancelled',
        'unknown',
        'ambiguous',
      ].includes(result.actual_round_status as string)
    )
      fail('E_AGENT_LEDGER');
    assign(
      result,
      'actual_transcript',
      validateTranscript(result.actual_transcript),
    );
    validateCommonResultIdentity(result, request);
    if (result.expected_round_revision !== request.expected_round_revision)
      fail('E_AGENT_LEDGER');
    return result as CompleteAgentRoundResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateBatchReceipt(value: unknown): AgentBatchReceiptV2 {
  const receipt = exactRecord(
    value,
    [
      'schema_version',
      'task_id',
      'attempt_id',
      'round_id',
      'round_index',
      'batch_kind',
      'batch_revision',
      'manifest_sha256',
      'transcript',
      'calls',
      'batch_new_write_bytes',
      'reserved_write_bytes',
      'effect_gate',
    ],
    'E_AGENT_LEDGER',
  );
  if (
    receipt.schema_version !== 2 ||
    !uuid(receipt.task_id) ||
    !uuid(receipt.attempt_id) ||
    !uuid(receipt.round_id) ||
    !safeInteger(receipt.round_index, MAX_ROUNDS) ||
    !['write_batch', 'read_only_batch'].includes(
      receipt.batch_kind as string,
    ) ||
    !safeInteger(receipt.batch_revision, MAX_SAFE, false) ||
    !nullableDigest(receipt.manifest_sha256) ||
    !safeInteger(receipt.batch_new_write_bytes, MAX_ATTEMPT_WRITE_BYTES) ||
    !safeInteger(receipt.reserved_write_bytes, MAX_ATTEMPT_WRITE_BYTES) ||
    !['closed', 'not_applicable'].includes(receipt.effect_gate as string)
  )
    fail('E_AGENT_LEDGER');
  assign(receipt, 'transcript', validateTranscript(receipt.transcript));
  const calls = strictArray(receipt.calls, 16, 0, 'E_AGENT_LEDGER').map(
    validateBatchCall,
  );
  assign(receipt, 'calls', calls);
  for (let index = 0; index < calls.length; index += 1)
    if (calls[index].call_index !== index) fail('E_AGENT_LEDGER');
  if (
    receipt.batch_kind === 'write_batch' &&
    (receipt.manifest_sha256 === null || receipt.effect_gate !== 'closed')
  )
    fail('E_AGENT_LEDGER');
  if (
    receipt.batch_kind === 'read_only_batch' &&
    (receipt.manifest_sha256 !== null ||
      receipt.batch_new_write_bytes !== 0 ||
      receipt.effect_gate !== 'not_applicable')
  )
    fail('E_AGENT_LEDGER');
  return receipt as AgentBatchReceiptV2;
}

function validateBatchResult(
  value: unknown,
  request: PrepareAgentToolBatchRequestV2,
): PrepareAgentToolBatchResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  if (header.status === 'prepared' || header.status === 'already_prepared') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'receipt',
        'observed_checkpoint',
      ],
      'E_AGENT_LEDGER',
    );
    assign(result, 'receipt', validateBatchReceipt(result.receipt));
    assign(
      result,
      'observed_checkpoint',
      validateCheckpoint(result.observed_checkpoint),
    );
    validateCommonResultIdentity(result, request);
    const receipt = result.receipt as AgentBatchReceiptV2;
    if (
      !sameCheckpoint(
        result.observed_checkpoint as AgentRuntimeCommittedCheckpointV1,
        request.committed_checkpoint,
      ) ||
      receipt.task_id !== request.task_id ||
      receipt.attempt_id !== request.attempt_id ||
      receipt.round_id !== request.round_id ||
      receipt.round_index !== request.round_index
    )
      fail('E_AGENT_LEDGER');
    return result as PrepareAgentToolBatchResultV2;
  }
  if (header.status === 'rejected') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'failure_code',
        'expected_batch_revision',
        'expected_reserved_write_bytes',
        'result_reserved_write_bytes',
        'effect_gate',
        'reservation_status',
        'effect_dispatched',
        'retry_advice',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      ![
        'E_AGENT_BAD_ARGUMENTS',
        'E_AGENT_BAD_PATH',
        'E_AGENT_CAPABILITY',
        'E_AGENT_CONFLICT',
        'E_AGENT_CAPACITY',
        'E_AGENT_LEDGER',
        'E_AGENT_PERSISTENCE',
        'E_AGENT_ROOT_STALE',
        'E_AGENT_ROUND_LIMIT',
      ].includes(result.failure_code as string) ||
      !safeInteger(result.expected_batch_revision, MAX_SAFE) ||
      !safeInteger(
        result.expected_reserved_write_bytes,
        MAX_ATTEMPT_WRITE_BYTES,
      ) ||
      !safeInteger(
        result.result_reserved_write_bytes,
        MAX_ATTEMPT_WRITE_BYTES,
      ) ||
      !['closed', 'not_applicable'].includes(result.effect_gate as string) ||
      result.reservation_status !== 'unchanged' ||
      result.effect_dispatched !== false ||
      !['none', 'requery', 'wait_for_reconciliation'].includes(
        result.retry_advice as string,
      )
    )
      fail('E_AGENT_LEDGER');
    validateCommonResultIdentity(result, request);
    if (
      result.expected_batch_revision !== request.expected_batch_revision ||
      result.expected_reserved_write_bytes !==
        request.expected_reserved_write_bytes
    )
      fail('E_AGENT_LEDGER');
    return result as PrepareAgentToolBatchResultV2;
  }
  if (header.status === 'conflict') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'failure_code',
        'expected_batch_revision',
        'actual_batch_revision',
        'expected_reserved_write_bytes',
        'actual_reserved_write_bytes',
        'effect_gate',
        'reservation_status',
        'effect_dispatched',
        'retry_advice',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      ![
        'E_AGENT_CONFLICT',
        'E_AGENT_TRANSCRIPT',
        'E_AGENT_ROOT_STALE',
      ].includes(result.failure_code as string) ||
      !safeInteger(result.expected_batch_revision, MAX_SAFE) ||
      !safeInteger(result.actual_batch_revision, MAX_SAFE) ||
      !safeInteger(
        result.expected_reserved_write_bytes,
        MAX_ATTEMPT_WRITE_BYTES,
      ) ||
      !safeInteger(
        result.actual_reserved_write_bytes,
        MAX_ATTEMPT_WRITE_BYTES,
      ) ||
      !['closed', 'not_applicable'].includes(result.effect_gate as string) ||
      result.reservation_status !== 'unchanged' ||
      result.effect_dispatched !== false ||
      result.retry_advice !== 'requery'
    )
      fail('E_AGENT_LEDGER');
    validateCommonResultIdentity(result, request);
    if (
      result.expected_batch_revision !== request.expected_batch_revision ||
      result.expected_reserved_write_bytes !==
        request.expected_reserved_write_bytes
    )
      fail('E_AGENT_LEDGER');
    return result as PrepareAgentToolBatchResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateBindResult(
  value: unknown,
  request: BindAgentApprovalRequestV2,
): BindAgentApprovalResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  if (header.status === 'bound' || header.status === 'already_bound') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'task_id',
        'attempt_id',
        'round_id',
        'call_index',
        'call_id',
        'decision',
        'approval_reference',
        'grant',
        'result_batch_revision',
        'observed_checkpoint',
        'receipt',
        'transcript',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      !uuid(result.task_id) ||
      !uuid(result.attempt_id) ||
      !uuid(result.round_id) ||
      !safeInteger(result.call_index, MAX_CALLS) ||
      !opaqueId(result.call_id) ||
      !['denied', 'allow_once', 'allow_conversation', 'cancelled'].includes(
        result.decision as string,
      ) ||
      !nullableUuid(result.approval_reference) ||
      (result.grant !== null && typeof result.grant !== 'object') ||
      !safeInteger(result.result_batch_revision, MAX_SAFE, false)
    )
      fail('E_AGENT_LEDGER');
    const deniedReceipt =
      result.receipt === null ? null : validateToolReceipt(result.receipt);
    const deniedTranscript =
      result.transcript === null ? null : validateTranscript(result.transcript);
    assign(result, 'receipt', deniedReceipt);
    assign(result, 'transcript', deniedTranscript);
    if (result.decision === 'denied') {
      if (deniedReceipt === null || deniedTranscript === null)
        fail('E_AGENT_LEDGER');
      validateReceiptBinding(
        deniedReceipt,
        result.call_id as string,
        request.token.name,
        request.token.arguments_sha256,
        null,
      );
      if (
        deniedReceipt.outcome !== 'denied' ||
        deniedReceipt.failure_code !== 'E_AGENT_DENIED_BY_USER'
      )
        fail('E_AGENT_LEDGER');
    } else if (deniedReceipt !== null || deniedTranscript !== null) {
      fail('E_AGENT_LEDGER');
    }
    assign(
      result,
      'grant',
      result.grant === null ? null : validateGrant(result.grant),
    );
    assign(
      result,
      'observed_checkpoint',
      validateCheckpoint(result.observed_checkpoint),
    );
    validateCommonResultIdentity(result, request);
    if (
      result.task_id !== request.task_id ||
      result.attempt_id !== request.attempt_id ||
      result.round_id !== request.round_id ||
      result.call_index !== request.call_index ||
      result.call_id !== request.call_id ||
      result.decision !== request.decision ||
      result.result_batch_revision !== request.batch_revision ||
      !sameCheckpoint(
        result.observed_checkpoint as AgentRuntimeCommittedCheckpointV1,
        request.committed_checkpoint,
      )
    )
      fail('E_AGENT_LEDGER');
    return result as BindAgentApprovalResultV2;
  }
  if (header.status === 'conflict') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'failure_code',
        'expected_batch_revision',
        'actual_batch_revision',
        'actual_decision',
        'observed_checkpoint',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      !['E_AGENT_APPROVAL', 'E_AGENT_CONFLICT', 'E_AGENT_ROOT_STALE'].includes(
        result.failure_code as string,
      ) ||
      !safeInteger(result.expected_batch_revision, MAX_SAFE, false) ||
      !safeInteger(result.actual_batch_revision, MAX_SAFE, false) ||
      ![
        'pending',
        'denied',
        'allow_once',
        'allow_conversation',
        'cancelled',
      ].includes(result.actual_decision as string)
    )
      fail('E_AGENT_LEDGER');
    assign(
      result,
      'observed_checkpoint',
      validateCheckpoint(result.observed_checkpoint),
    );
    validateCommonResultIdentity(result, request);
    if (
      result.expected_batch_revision !== request.batch_revision ||
      !sameCheckpoint(
        result.observed_checkpoint as AgentRuntimeCommittedCheckpointV1,
        request.committed_checkpoint,
      )
    )
      fail('E_AGENT_LEDGER');
    return result as BindAgentApprovalResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateExecuteResult(
  value: unknown,
  request: ExecuteAgentToolRequestV2,
): ExecuteAgentToolResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  const commonKeys = [
    'schema_version',
    'status',
    'operation_id',
    'task_id',
    'attempt_id',
    'round_id',
    'round_index',
    'call_index',
    'call_id',
    'name',
    'idempotency_key',
    'result_execution_revision',
    'transcript',
  ];
  if (
    header.status === 'completed' ||
    header.status === 'failed' ||
    header.status === 'denied' ||
    header.status === 'cancelled'
  ) {
    const result = exactRecord(
      value,
      [...commonKeys, 'receipt', 'effect_may_have_occurred'],
      'E_AGENT_LEDGER',
    );
    if (
      !safeInteger(result.result_execution_revision, MAX_SAFE, false) ||
      !booleanValue(result.effect_may_have_occurred)
    )
      fail('E_AGENT_LEDGER');
    assign(result, 'transcript', validateTranscript(result.transcript));
    assign(result, 'receipt', validateToolReceipt(result.receipt));
    validateCommonResultIdentity(result, request);
    validateReceiptBinding(
      result.receipt as AgentToolReceiptV1,
      request.call_id,
      request.name,
      request.arguments_sha256,
      request.approval_reference,
    );
    if (
      result.status === 'cancelled' &&
      result.effect_may_have_occurred !== false
    )
      fail('E_AGENT_LEDGER');
    if (
      result.status === 'denied' &&
      (result.receipt as AgentToolReceiptV1).outcome !== 'denied'
    )
      fail('E_AGENT_LEDGER');
    if (
      result.status === 'completed' &&
      (result.receipt as AgentToolReceiptV1).outcome !== 'ok'
    )
      fail('E_AGENT_LEDGER');
    if (
      result.status === 'failed' &&
      (result.receipt as AgentToolReceiptV1).outcome !== 'failed'
    )
      fail('E_AGENT_LEDGER');
    if (
      result.status === 'cancelled' &&
      (result.receipt as AgentToolReceiptV1).outcome !== 'cancelled'
    )
      fail('E_AGENT_LEDGER');
    return result as ExecuteAgentToolResultV2;
  }
  if (header.status === 'running' || header.status === 'cancel_requested') {
    const result = exactRecord(
      value,
      [...commonKeys, 'receipt', 'effect_may_have_occurred'],
      'E_AGENT_LEDGER',
    );
    if (
      result.receipt !== null ||
      !booleanValue(result.effect_may_have_occurred) ||
      !safeInteger(result.result_execution_revision, MAX_SAFE, false)
    )
      fail('E_AGENT_LEDGER');
    assign(result, 'transcript', validateTranscript(result.transcript));
    validateCommonResultIdentity(result, request);
    return result as ExecuteAgentToolResultV2;
  }
  if (header.status === 'unknown') {
    const result = exactRecord(
      value,
      [...commonKeys, 'receipt', 'effect_may_have_occurred', 'failure_code'],
      'E_AGENT_LEDGER',
    );
    if (
      result.receipt !== null ||
      result.effect_may_have_occurred !== false ||
      !safeInteger(result.result_execution_revision, MAX_SAFE, false) ||
      !['E_AGENT_EXECUTION_AMBIGUOUS', 'E_AGENT_LEDGER'].includes(
        result.failure_code as string,
      )
    )
      fail('E_AGENT_LEDGER');
    assign(result, 'transcript', validateTranscript(result.transcript));
    validateCommonResultIdentity(result, request);
    return result as ExecuteAgentToolResultV2;
  }
  if (header.status === 'ambiguous') {
    const result = exactRecord(
      value,
      [...commonKeys, 'receipt', 'effect_may_have_occurred', 'failure_code'],
      'E_AGENT_LEDGER',
    );
    if (
      result.effect_may_have_occurred !== true ||
      result.failure_code !== 'E_AGENT_EXECUTION_AMBIGUOUS' ||
      !safeInteger(result.result_execution_revision, MAX_SAFE, false)
    )
      fail('E_AGENT_LEDGER');
    assign(result, 'transcript', validateTranscript(result.transcript));
    assign(result, 'receipt', validateToolReceipt(result.receipt));
    if ((result.receipt as AgentToolReceiptV1).outcome !== 'ambiguous')
      fail('E_AGENT_LEDGER');
    validateReceiptBinding(
      result.receipt as AgentToolReceiptV1,
      request.call_id,
      request.name,
      request.arguments_sha256,
      request.approval_reference,
    );
    validateCommonResultIdentity(result, request);
    return result as ExecuteAgentToolResultV2;
  }
  if (header.status === 'conflict') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'failure_code',
        'expected_execution_revision',
        'actual_execution_revision',
        'actual_status',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      ![
        'E_AGENT_APPROVAL',
        'E_AGENT_CONFLICT',
        'E_AGENT_ROOT_STALE',
        'E_AGENT_TRANSCRIPT',
      ].includes(result.failure_code as string) ||
      !safeInteger(result.expected_execution_revision, MAX_SAFE, false) ||
      !safeInteger(result.actual_execution_revision, MAX_SAFE, false) ||
      ![
        'intent',
        'running',
        'cancel_requested',
        'settled',
        'cancelled',
        'unknown',
        'ambiguous',
      ].includes(result.actual_status as string)
    )
      fail('E_AGENT_LEDGER');
    validateCommonResultIdentity(result, request);
    if (
      result.expected_execution_revision !== request.expected_execution_revision
    )
      fail('E_AGENT_LEDGER');
    return result as ExecuteAgentToolResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function sameTarget(
  left: AgentCancelTargetV2,
  right: AgentCancelTargetV2,
): boolean {
  if (
    left.kind !== right.kind ||
    left.task_id !== right.task_id ||
    left.attempt_id !== right.attempt_id
  )
    return false;
  if (left.kind === 'attempt' || right.kind === 'attempt')
    return left.kind === right.kind;
  if (
    left.round_id !== right.round_id ||
    left.round_index !== right.round_index
  )
    return false;
  if (left.kind === 'round' || right.kind === 'round')
    return left.kind === right.kind;
  return (
    left.call_index === right.call_index &&
    left.call_id === right.call_id &&
    left.idempotency_key === right.idempotency_key
  );
}

function validateCancelResult(
  value: unknown,
  request: CancelAgentAttemptRequestV2,
): CancelAgentAttemptResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  const expectedTarget = request.target;
  if (
    header.status === 'cancel_requested' ||
    header.status === 'cancelled' ||
    header.status === 'already_cancelled'
  ) {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'target',
        'result_round_revision',
        'result_execution_revision',
        'transcript',
        'receipt',
        'effect_may_have_occurred',
        'observed_checkpoint',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      (result.result_round_revision !== null &&
        !safeInteger(result.result_round_revision, MAX_SAFE, false)) ||
      (result.result_execution_revision !== null &&
        !safeInteger(result.result_execution_revision, MAX_SAFE, false)) ||
      !booleanValue(result.effect_may_have_occurred) ||
      (result.receipt !== null && typeof result.receipt !== 'object')
    )
      fail('E_AGENT_LEDGER');
    assign(result, 'target', validateTarget(result.target));
    assign(result, 'transcript', validateTranscript(result.transcript));
    assign(
      result,
      'receipt',
      result.receipt === null ? null : validateToolReceipt(result.receipt),
    );
    assign(
      result,
      'observed_checkpoint',
      validateCheckpoint(result.observed_checkpoint),
    );
    validateCommonResultIdentity(result, request);
    if (
      !sameTarget(result.target as AgentCancelTargetV2, expectedTarget) ||
      !sameCheckpoint(
        result.observed_checkpoint as AgentRuntimeCommittedCheckpointV1,
        request.committed_checkpoint,
      )
    )
      fail('E_AGENT_LEDGER');
    return result as CancelAgentAttemptResultV2;
  }
  if (
    header.status === 'settled' ||
    header.status === 'unknown' ||
    header.status === 'ambiguous'
  ) {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'target',
        'result_round_revision',
        'result_execution_revision',
        'transcript',
        'receipt',
        'effect_may_have_occurred',
        'failure_code',
        'observed_checkpoint',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      (result.result_round_revision !== null &&
        !safeInteger(result.result_round_revision, MAX_SAFE, false)) ||
      (result.result_execution_revision !== null &&
        !safeInteger(result.result_execution_revision, MAX_SAFE, false)) ||
      !booleanValue(result.effect_may_have_occurred) ||
      !isRuntimeFailureCode(result.failure_code) ||
      (result.receipt !== null && typeof result.receipt !== 'object')
    )
      fail('E_AGENT_LEDGER');
    assign(result, 'target', validateTarget(result.target));
    assign(result, 'transcript', validateTranscript(result.transcript));
    assign(
      result,
      'receipt',
      result.receipt === null ? null : validateToolReceipt(result.receipt),
    );
    assign(
      result,
      'observed_checkpoint',
      validateCheckpoint(result.observed_checkpoint),
    );
    validateCommonResultIdentity(result, request);
    if (
      !sameTarget(result.target as AgentCancelTargetV2, expectedTarget) ||
      !sameCheckpoint(
        result.observed_checkpoint as AgentRuntimeCommittedCheckpointV1,
        request.committed_checkpoint,
      )
    )
      fail('E_AGENT_LEDGER');
    if (
      result.status === 'ambiguous' &&
      (result.receipt === null ||
        (result.receipt as AgentToolReceiptV1).outcome !== 'ambiguous')
    )
      fail('E_AGENT_LEDGER');
    if (result.status === 'unknown' && result.receipt !== null)
      fail('E_AGENT_LEDGER');
    return result as CancelAgentAttemptResultV2;
  }
  if (header.status === 'conflict') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'target',
        'failure_code',
        'expected_controller_generation',
        'expected_journal_revision',
        'actual_controller_generation',
        'actual_journal_revision',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      !['E_AGENT_CONFLICT', 'E_AGENT_CANCELLED', 'E_AGENT_ROOT_STALE'].includes(
        result.failure_code as string,
      ) ||
      !safeInteger(result.expected_controller_generation, MAX_SAFE) ||
      !safeInteger(result.expected_journal_revision, MAX_SAFE) ||
      !safeInteger(result.actual_controller_generation, MAX_SAFE) ||
      !safeInteger(result.actual_journal_revision, MAX_SAFE)
    )
      fail('E_AGENT_LEDGER');
    assign(result, 'target', validateTarget(result.target));
    validateCommonResultIdentity(result, request);
    if (
      !sameTarget(result.target as AgentCancelTargetV2, expectedTarget) ||
      result.expected_controller_generation !==
        request.controller_cas.expected_controller_generation ||
      result.expected_journal_revision !==
        request.controller_cas.expected_journal_revision
    )
      fail('E_AGENT_LEDGER');
    return result as CancelAgentAttemptResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateQueryAttemptResult(
  value: unknown,
  request: QueryAgentAttemptRequestV2,
): QueryAgentAttemptResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  if (header.status === 'active' || header.status === 'terminal') {
    const result = exactRecord(
      value,
      ['schema_version', 'status', 'attempt'],
      'E_AGENT_LEDGER',
    );
    const attempt = validateAttemptProjection(result.attempt);
    assign(result, 'attempt', attempt);
    if (
      attempt.task_id !== request.task_id ||
      attempt.conversation_id !== request.conversation_id ||
      attempt.attempt_id !== request.attempt_id
    )
      fail('E_AGENT_LEDGER');
    return result as QueryAgentAttemptResultV2;
  }
  if (header.status === 'not_found') {
    const result = exactRecord(
      value,
      ['schema_version', 'status', 'failure_code'],
      'E_AGENT_LEDGER',
    );
    if (result.failure_code !== 'E_AGENT_NOT_FOUND') fail('E_AGENT_LEDGER');
    return result as QueryAgentAttemptResultV2;
  }
  if (header.status === 'conflict') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'failure_code',
        'expected_journal_revision',
        'actual_journal_revision',
        'expected_session_generation',
        'actual_session_generation',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      ![
        'E_AGENT_CONFLICT',
        'E_AGENT_TRANSCRIPT',
        'E_AGENT_ROOT_STALE',
      ].includes(result.failure_code as string) ||
      !safeInteger(result.expected_journal_revision, MAX_SAFE) ||
      !safeInteger(result.actual_journal_revision, MAX_SAFE) ||
      !safeInteger(result.expected_session_generation, MAX_SAFE) ||
      !safeInteger(result.actual_session_generation, MAX_SAFE)
    )
      fail('E_AGENT_LEDGER');
    if (
      result.expected_journal_revision !== request.expected_journal_revision ||
      result.expected_session_generation !== request.expected_session_generation
    )
      fail('E_AGENT_LEDGER');
    return result as QueryAgentAttemptResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateToolProjection(value: unknown): AgentToolProjectionV2 {
  const tool = exactRecord(
    value,
    [
      'schema_version',
      'task_id',
      'attempt_id',
      'round_id',
      'round_index',
      'call_index',
      'call_id',
      'name',
      'arguments_sha256',
      'idempotency_key',
      'execution_revision',
      'status',
      'transcript',
      'receipt',
    ],
    'E_AGENT_LEDGER',
  );
  if (
    tool.schema_version !== 2 ||
    !uuid(tool.task_id) ||
    !uuid(tool.attempt_id) ||
    !uuid(tool.round_id) ||
    !safeInteger(tool.round_index, MAX_ROUNDS) ||
    !safeInteger(tool.call_index, MAX_CALLS) ||
    !opaqueId(tool.call_id) ||
    !name(tool.name) ||
    !digest(tool.arguments_sha256) ||
    !digest(tool.idempotency_key) ||
    !safeInteger(tool.execution_revision, MAX_SAFE, false) ||
    ![
      'intent',
      'running',
      'cancel_requested',
      'completed',
      'failed',
      'denied',
      'cancelled',
      'unknown',
      'ambiguous',
    ].includes(tool.status as string) ||
    (tool.receipt !== null && typeof tool.receipt !== 'object')
  )
    fail('E_AGENT_LEDGER');
  assign(tool, 'transcript', validateTranscript(tool.transcript));
  const receipt =
    tool.receipt === null ? null : validateToolReceipt(tool.receipt);
  assign(tool, 'receipt', receipt);
  if (
    ['intent', 'running', 'cancel_requested', 'unknown'].includes(
      tool.status as string,
    ) &&
    tool.receipt !== null
  )
    fail('E_AGENT_LEDGER');
  if (
    ['completed', 'failed', 'denied', 'cancelled', 'ambiguous'].includes(
      tool.status as string,
    ) &&
    tool.receipt === null
  )
    fail('E_AGENT_LEDGER');
  if (tool.status === 'ambiguous' && receipt?.outcome !== 'ambiguous')
    fail('E_AGENT_LEDGER');
  if (receipt !== null) {
    validateReceiptBinding(
      receipt,
      tool.call_id,
      tool.name,
      tool.arguments_sha256,
      receipt.approval_reference,
    );
    const expectedOutcome =
      tool.status === 'completed'
        ? 'ok'
        : tool.status === 'failed'
        ? 'failed'
        : tool.status === 'denied'
        ? 'denied'
        : tool.status === 'cancelled'
        ? 'cancelled'
        : tool.status === 'ambiguous'
        ? 'ambiguous'
        : null;
    if (expectedOutcome !== null && receipt.outcome !== expectedOutcome)
      fail('E_AGENT_LEDGER');
  }
  return tool as AgentToolProjectionV2;
}

function validateQueryToolResult(
  value: unknown,
  request: QueryAgentToolRequestV2,
): QueryAgentToolResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  if (header.status === 'not_started')
    return exactRecord(
      value,
      ['schema_version', 'status'],
      'E_AGENT_LEDGER',
    ) as QueryAgentToolResultV2;
  if (header.status === 'conflict') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'failure_code',
        'expected_execution_revision',
        'actual_execution_revision',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      ![
        'E_AGENT_CONFLICT',
        'E_AGENT_TRANSCRIPT',
        'E_AGENT_ROOT_STALE',
      ].includes(result.failure_code as string) ||
      !safeInteger(result.expected_execution_revision, MAX_SAFE) ||
      !safeInteger(result.actual_execution_revision, MAX_SAFE)
    )
      fail('E_AGENT_LEDGER');
    if (
      result.expected_execution_revision !== request.expected_execution_revision
    )
      fail('E_AGENT_LEDGER');
    return result as QueryAgentToolResultV2;
  }
  if (
    ![
      'intent',
      'running',
      'cancel_requested',
      'completed',
      'failed',
      'denied',
      'cancelled',
      'unknown',
      'ambiguous',
    ].includes(header.status as string)
  )
    fail('E_AGENT_LEDGER');
  const result = exactRecord(
    value,
    ['schema_version', 'status', 'tool'],
    'E_AGENT_LEDGER',
  );
  const tool = validateToolProjection(result.tool);
  assign(result, 'tool', tool);
  if (
    tool.task_id !== request.task_id ||
    tool.attempt_id !== request.attempt_id ||
    tool.round_id !== request.round_id ||
    tool.round_index !== request.round_index ||
    tool.call_index !== request.call_index ||
    tool.call_id !== request.call_id ||
    tool.idempotency_key !== request.idempotency_key ||
    tool.status !== result.status
  )
    fail('E_AGENT_LEDGER');
  return result as QueryAgentToolResultV2;
}

function validateRecoveryResult(
  value: unknown,
  request: RecoverAgentAttemptRequestV2,
): RecoverAgentAttemptResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  if (
    header.status === 'resumed' ||
    header.status === 'retryable' ||
    header.status === 'manual_reconciliation' ||
    header.status === 'terminal'
  ) {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'next_action',
        'attempt',
        'completed_round',
      ],
      'E_AGENT_LEDGER',
    );
    const allowed =
      header.status === 'resumed'
        ? [
            'persist_round',
            'persist_batch',
            'persist_approval',
            'persist_tool_result',
            'persist_final',
            'none',
          ]
        : header.status === 'retryable'
        ? ['retry_same_round']
        : header.status === 'manual_reconciliation'
        ? ['inspect_native_state']
        : ['none'];
    if (!allowed.includes(result.next_action as string)) fail('E_AGENT_LEDGER');
    const attempt = validateAttemptProjection(result.attempt);
    assign(result, 'attempt', attempt);
    const completedRound =
      result.completed_round === null
        ? null
        : validateRecoveredRound(result.completed_round);
    assign(result, 'completed_round', completedRound);
    validateCommonResultIdentity(result, request);
    if (
      attempt.task_id !== request.target.task_id ||
      attempt.attempt_id !== request.target.attempt_id
    )
      fail('E_AGENT_LEDGER');
    if (completedRound !== null) {
      if (
        request.target.kind !== 'round' ||
        completedRound.task_id !== request.target.task_id ||
        completedRound.attempt_id !== request.target.attempt_id ||
        completedRound.round_id !== request.target.round_id ||
        completedRound.round_index !== request.target.round_index
      )
        fail('E_AGENT_LEDGER');
    }
    const nextAction = result.next_action as string;
    if (nextAction === 'persist_round' && completedRound === null)
      fail('E_AGENT_LEDGER');
    if (
      nextAction === 'persist_batch' &&
      (completedRound === null || completedRound.kind !== 'tool_batch')
    )
      fail('E_AGENT_LEDGER');
    if (
      nextAction === 'persist_final' &&
      (completedRound === null || completedRound.kind !== 'final')
    )
      fail('E_AGENT_LEDGER');
    if (
      header.status === 'resumed' &&
      ['persist_approval', 'persist_tool_result', 'none'].includes(
        nextAction,
      ) &&
      completedRound !== null
    )
      fail('E_AGENT_LEDGER');
    if (
      (header.status === 'retryable' ||
        header.status === 'manual_reconciliation') &&
      completedRound !== null
    )
      fail('E_AGENT_LEDGER');
    return result as RecoverAgentAttemptResultV2;
  }
  if (header.status === 'conflict') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'failure_code',
        'expected_controller_generation',
        'expected_journal_revision',
        'actual_controller_generation',
        'actual_journal_revision',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      ![
        'E_AGENT_CONFLICT',
        'E_AGENT_TRANSCRIPT',
        'E_AGENT_ROOT_STALE',
      ].includes(result.failure_code as string) ||
      !safeInteger(result.expected_controller_generation, MAX_SAFE) ||
      !safeInteger(result.expected_journal_revision, MAX_SAFE) ||
      !safeInteger(result.actual_controller_generation, MAX_SAFE) ||
      !safeInteger(result.actual_journal_revision, MAX_SAFE)
    )
      fail('E_AGENT_LEDGER');
    validateCommonResultIdentity(result, request);
    if (
      result.expected_controller_generation !==
        request.controller_cas.expected_controller_generation ||
      result.expected_journal_revision !==
        request.controller_cas.expected_journal_revision
    )
      fail('E_AGENT_LEDGER');
    return result as RecoverAgentAttemptResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateFinalizeResult(
  value: unknown,
  request: FinalizeAgentAttemptRequestV2,
): FinalizeAgentAttemptResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  if (header.status === 'terminal' || header.status === 'already_terminal') {
    const result = exactRecord(
      value,
      ['schema_version', 'status', 'operation_id', 'cleanup_id', 'transcript'],
      'E_AGENT_LEDGER',
    );
    if (!uuid(result.cleanup_id) || result.cleanup_id !== request.cleanup_id)
      fail('E_AGENT_LEDGER');
    assign(result, 'transcript', validateTranscript(result.transcript));
    validateCommonResultIdentity(result, request);
    return result as FinalizeAgentAttemptResultV2;
  }
  if (header.status === 'conflict') {
    const result = exactRecord(
      value,
      ['schema_version', 'status', 'operation_id', 'failure_code'],
      'E_AGENT_LEDGER',
    );
    if (
      ![
        'E_AGENT_CONFLICT',
        'E_AGENT_TRANSCRIPT',
        'E_AGENT_ROOT_STALE',
      ].includes(result.failure_code as string)
    )
      fail('E_AGENT_LEDGER');
    validateCommonResultIdentity(result, request);
    return result as FinalizeAgentAttemptResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateDiscardResult(
  value: unknown,
  request: DiscardAgentAttemptRequestV2,
): DiscardAgentAttemptResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  if (header.status === 'discarded' || header.status === 'already_missing') {
    const result = exactRecord(
      value,
      ['schema_version', 'status', 'operation_id', 'cleanup_id'],
      'E_AGENT_LEDGER',
    );
    if (!uuid(result.cleanup_id) || result.cleanup_id !== request.cleanup_id)
      fail('E_AGENT_LEDGER');
    validateCommonResultIdentity(result, request);
    return result as DiscardAgentAttemptResultV2;
  }
  if (header.status === 'pending' || header.status === 'unknown') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'cleanup_id',
        'failure_code',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      !uuid(result.cleanup_id) ||
      result.cleanup_id !== request.cleanup_id ||
      !['E_AGENT_PERSISTENCE', 'E_AGENT_TRANSCRIPT'].includes(
        result.failure_code as string,
      )
    )
      fail('E_AGENT_LEDGER');
    validateCommonResultIdentity(result, request);
    return result as DiscardAgentAttemptResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateInterruptResult(
  value: unknown,
  request: InterruptAgentAttemptRequestV2,
): InterruptAgentAttemptResultV2 {
  const header = peekRecord(
    value,
    ['schema_version', 'status'],
    'E_AGENT_LEDGER',
  );
  if (header.schema_version !== 2) fail('E_AGENT_LEDGER');
  if (header.status === 'discarded' || header.status === 'already_missing') {
    const result = exactRecord(
      value,
      ['schema_version', 'status', 'operation_id', 'cleanup_id'],
      'E_AGENT_LEDGER',
    );
    if (!uuid(result.cleanup_id) || result.cleanup_id !== request.cleanup_id)
      fail('E_AGENT_LEDGER');
    validateCommonResultIdentity(result, request);
    return result as InterruptAgentAttemptResultV2;
  }
  if (header.status === 'pending' || header.status === 'unknown') {
    const result = exactRecord(
      value,
      [
        'schema_version',
        'status',
        'operation_id',
        'cleanup_id',
        'failure_code',
      ],
      'E_AGENT_LEDGER',
    );
    if (
      !uuid(result.cleanup_id) ||
      result.cleanup_id !== request.cleanup_id ||
      !['E_AGENT_PERSISTENCE', 'E_AGENT_TRANSCRIPT'].includes(
        result.failure_code as string,
      )
    )
      fail('E_AGENT_LEDGER');
    validateCommonResultIdentity(result, request);
    return result as InterruptAgentAttemptResultV2;
  }
  fail('E_AGENT_LEDGER');
}

function validateCleanupResult(
  value: unknown,
  request: QueryAgentCleanupRequestV2,
): QueryAgentCleanupResultV2 {
  const result = exactRecord(
    value,
    ['schema_version', 'status', 'cleanup_id'],
    'E_AGENT_LEDGER',
  );
  if (
    result.schema_version !== 2 ||
    !['pending', 'discarded', 'unknown'].includes(result.status as string) ||
    !uuid(result.cleanup_id) ||
    result.cleanup_id !== request.cleanup_id
  )
    fail('E_AGENT_LEDGER');
  return result as QueryAgentCleanupResultV2;
}

function turboNative(): unknown {
  try {
    const value = TurboModuleRegistry.get('AgentRuntime');
    if (typeof value === 'object' && value !== null) return value;
  } catch {}
  return null;
}

function legacyNative(): unknown {
  try {
    const value = Reflect.get(NativeModules, 'AgentRuntime') as unknown;
    return typeof value === 'object' && value !== null ? value : null;
  } catch {
    return null;
  }
}

function cachedNativeMethods(value: unknown): NativeAgentRuntimeV2 | null {
  if (!nativeImplementationAvailable(value)) return null;
  if (typeof value !== 'object' || value === null) return null;
  const object = value as object;
  const cached = nativeMethodCache.get(object);
  if (cached !== undefined) return cached;
  const snapshot = Object.create(null) as NativeAgentRuntimeV2;
  try {
    for (const selector of legacyOperationIds) {
      if (typeof Reflect.get(object, selector) === 'function') {
        return null;
      }
    }
    for (const selector of operationIds) {
      const method = Reflect.get(object, selector) as unknown;
      if (typeof method !== 'function') {
        return null;
      }
      snapshot[selector] = method.bind(
        object,
      ) as NativeAgentRuntimeV2[typeof selector];
    }
  } catch {
    return null;
  }
  nativeMethodCache.set(object, snapshot);
  return snapshot;
}

function resolveNativeMethods(): NativeAgentRuntimeV2 | null {
  const legacy = cachedNativeMethods(legacyNative());
  return legacy ?? cachedNativeMethods(turboNative());
}

function nativeFailureCode(
  error: unknown,
  fallback: AgentRuntimeFailureCode,
): AgentBridgeFailureCode {
  try {
    if (typeof error === 'object' && error !== null) {
      const candidate = (error as { code?: unknown }).code;
      if (isRuntimeFailureCode(candidate)) return candidate;
      // Context validation fails before a native round starts. Preserve its
      // closed error code without widening persisted tool-result vocabulary.
      if (typeof candidate === 'string' &&
          contextBridgeFailureCodes.some(code => code === candidate)) {
        return candidate as (typeof contextBridgeFailureCodes)[number];
      }
    }
  } catch {
    // Native error messages and hostile accessors never cross the bridge.
  }
  return fallback;
}

async function invokeNative<Request, Result>(
  selector: NativeSelector,
  request: Request,
  requestValidator: (value: unknown) => Request,
  resultValidator: (value: unknown, request: Request) => Result,
): Promise<Result> {
  let safeRequest: Request;
  try {
    safeRequest = requestValidator(request);
  } catch (error) {
    if (error instanceof AgentRuntimeError) throw error;
    throw new AgentRuntimeError('E_AGENT_BAD_ARGUMENTS');
  }
  const native = resolveNativeMethods();
  if (native === null) throw new AgentRuntimeError('E_AGENT_NATIVE');
  let raw: unknown;
  try {
    raw = await native[selector](safeRequest);
  } catch (error) {
    throw new AgentRuntimeError(
      nativeFailureCode(error, 'E_AGENT_PERSISTENCE'),
      selector === 'complete_agent_round_v2' ? agentRuntimeDiagnosticFromError(error) : null,
    );
  }
  try {
    return resultValidator(raw, safeRequest);
  } catch (error) {
    if (error instanceof AgentRuntimeError) throw error;
    throw new AgentRuntimeError('E_AGENT_LEDGER');
  }
}

export const AgentRuntime: AgentRuntimeFacadeV2 = Object.freeze({
  isAvailable: (): boolean => resolveNativeMethods() !== null,
  prepareAgentAttempt: (request: PrepareAgentAttemptRequestV2) =>
    invokeNative(
      'prepare_agent_attempt',
      request,
      validateAttemptRequest,
      validatePrepareResult,
    ),
  completeAgentRoundV2: (request: CompleteAgentRoundRequestV2) =>
    invokeNative(
      'complete_agent_round_v2',
      request,
      validateCompleteRequest,
      validateCompleteResult,
    ),
  prepareAgentToolBatch: (request: PrepareAgentToolBatchRequestV2) =>
    invokeNative(
      'prepare_agent_tool_batch',
      request,
      validateBatchRequest,
      validateBatchResult,
    ),
  bindAgentApproval: (request: BindAgentApprovalRequestV2) =>
    invokeNative(
      'bind_agent_approval',
      request,
      validateBindRequest,
      validateBindResult,
    ),
  executeAgentTool: (request: ExecuteAgentToolRequestV2) =>
    invokeNative(
      'execute_agent_tool',
      request,
      validateExecuteRequest,
      validateExecuteResult,
    ),
  cancelAgentAttempt: (request: CancelAgentAttemptRequestV2) =>
    invokeNative(
      'cancel_agent_attempt',
      request,
      validateCancelRequest,
      validateCancelResult,
    ),
  queryAgentAttempt: (request: QueryAgentAttemptRequestV2) =>
    invokeNative(
      'query_agent_attempt',
      request,
      validateQueryAttemptRequest,
      validateQueryAttemptResult,
    ),
  queryAgentTool: (request: QueryAgentToolRequestV2) =>
    invokeNative(
      'query_agent_tool',
      request,
      validateQueryToolRequest,
      validateQueryToolResult,
    ),
  recoverAgentAttempt: (request: RecoverAgentAttemptRequestV2) =>
    invokeNative(
      'recover_agent_attempt',
      request,
      validateRecoveryRequest,
      validateRecoveryResult,
    ),
  finalizeAgentAttempt: (request: FinalizeAgentAttemptRequestV2) =>
    invokeNative(
      'finalize_agent_attempt',
      request,
      validateFinalizeRequest,
      validateFinalizeResult,
    ),
  discardAgentAttempt: (request: DiscardAgentAttemptRequestV2) =>
    invokeNative(
      'discard_agent_attempt',
      request,
      validateDiscardRequest,
      validateDiscardResult,
    ),
  interruptAgentAttempt: (request: InterruptAgentAttemptRequestV2) =>
    invokeNative(
      'interrupt_agent_attempt',
      request,
      validateInterruptRequest,
      validateInterruptResult,
    ),
  queryAgentCleanup: (request: QueryAgentCleanupRequestV2) =>
    invokeNative(
      'query_agent_cleanup',
      request,
      validateCleanupRequest,
      validateCleanupResult,
    ),
});

export type AgentRuntimeFacade = AgentRuntimeFacadeV2;
