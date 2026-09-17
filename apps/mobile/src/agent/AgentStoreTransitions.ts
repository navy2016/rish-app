import { ALL_AGENT_TOOL_NAMES, ALL_AGENT_AUTO_TOOLS, ALL_AGENT_CONFIRM_TOOLS, agentToolRegistryCompatible, agentRegistryToolLimit, isGuestServiceAgentTool, isRuntimeAgentTool, agentToolGrantFamily } from './tool-registry';
import { parseProviderBinding } from '../providers/configuration';
/**
 * Closed, RN-side evidence for the high-level Agent Runtime boundary.
 *
 * This module is deliberately local and pure. It does not import
 * NativeModules, call a selector, persist a result, or execute an effect. A
 * caller supplies one exact request/result pair and receives a redacted,
 * discriminated value that a Store reducer can consume. Native owner fields
 * are not part of any accepted shape.
 */
import type {
  AgentApprovalBindingTokenV2,
  AgentApprovalPreviewV1,
  AgentAttemptProjectionV2,
  AgentBatchCallProjectionV2,
  AgentBatchReceiptV2,
  AgentConversationGrantV2,
  AgentRoundCallPresentationV3,
  AgentRoundOutcomeV3,
  AgentRoundReceiptV2,
  AgentRuntimeCommittedCheckpointV1,
  AgentRuntimeControllerCASV1,
  AgentRegistryVersion,
  AgentRuntimePolicyV1,
  AgentRuntimeRegistryToolV2,
  AgentRuntimeRegistryV2,
  AgentRuntimeRootV1,
  AgentRuntimeTranscriptHandleV1,
  AgentToolReceiptV1,
  BindAgentApprovalRequestV2,
  BindAgentApprovalResultV2,
  CancelAgentAttemptRequestV2,
  CancelAgentAttemptResultV2,
  CompleteAgentRoundRequestV2,
  CompleteAgentRoundResultV2,
  ExecuteAgentToolRequestV2,
  ExecuteAgentToolResultV2,
  PrepareAgentAttemptRequestV2,
  PrepareAgentAttemptResultV2,
  PrepareAgentToolBatchRequestV2,
  PrepareAgentToolBatchResultV2,
  RecoverAgentAttemptRequestV2,
  RecoverAgentAttemptResultV2,
  AgentRecoveredRoundProjectionV2,
  AgentRecoveryTargetV2,
  AgentCancelTargetV2,
  AgentCancelTokenV2,
  AgentRuntimeFailureCode,
} from '../native/AgentRuntime';
import { agentTextSHA256 } from '../completion/SessionPersistence';
import { HARNESS_IDS, isHarnessModelId } from '../harness/types';

export type AgentStoreOperation =
  | 'prepare_agent_attempt'
  | 'complete_agent_round_v2'
  | 'prepare_agent_tool_batch'
  | 'bind_agent_approval'
  | 'execute_agent_tool'
  | 'cancel_agent_attempt'
  | 'recover_agent_attempt';

export type AgentStoreRequest =
  | PrepareAgentAttemptRequestV2
  | CompleteAgentRoundRequestV2
  | PrepareAgentToolBatchRequestV2
  | BindAgentApprovalRequestV2
  | ExecuteAgentToolRequestV2
  | CancelAgentAttemptRequestV2
  | RecoverAgentAttemptRequestV2;

export type AgentStoreResult =
  | PrepareAgentAttemptResultV2
  | CompleteAgentRoundResultV2
  | PrepareAgentToolBatchResultV2
  | BindAgentApprovalResultV2
  | ExecuteAgentToolResultV2
  | CancelAgentAttemptResultV2
  | RecoverAgentAttemptResultV2;

type PrepareEvidence = {
  readonly kind: 'prepare_agent_attempt';
  readonly operation_id: string;
  readonly request: PrepareAgentAttemptRequestV2;
  readonly result: Exclude<PrepareAgentAttemptResultV2, { status: 'conflict' }>;
};

type CompleteEvidence = {
  readonly kind: 'complete_agent_round_v2';
  readonly operation_id: string;
  readonly request: CompleteAgentRoundRequestV2;
  readonly result: Exclude<CompleteAgentRoundResultV2, { status: 'conflict' }>;
};

type BatchEvidence = {
  readonly kind: 'prepare_agent_tool_batch';
  readonly operation_id: string;
  readonly request: PrepareAgentToolBatchRequestV2;
  readonly result: Exclude<PrepareAgentToolBatchResultV2, { status: 'conflict' }>;
};

type ApprovalEvidence = {
  readonly kind: 'bind_agent_approval';
  readonly operation_id: string;
  readonly request: BindAgentApprovalRequestV2;
  readonly result: Exclude<BindAgentApprovalResultV2, { status: 'conflict' }>;
};

type ExecuteEvidence = {
  readonly kind: 'execute_agent_tool';
  readonly operation_id: string;
  readonly request: ExecuteAgentToolRequestV2;
  readonly result: Exclude<ExecuteAgentToolResultV2, { status: 'conflict' }>;
};

type CancelEvidence = {
  readonly kind: 'cancel_agent_attempt';
  readonly operation_id: string;
  readonly request: CancelAgentAttemptRequestV2;
  readonly result: Exclude<CancelAgentAttemptResultV2, { status: 'conflict' }>;
};

type RecoverEvidence = {
  readonly kind: 'recover_agent_attempt';
  readonly operation_id: string;
  readonly request: RecoverAgentAttemptRequestV2;
  readonly result: Exclude<RecoverAgentAttemptResultV2, { status: 'conflict' }>;
};

export type AgentStoreTransitionEvidence =
  | PrepareEvidence
  | CompleteEvidence
  | BatchEvidence
  | ApprovalEvidence
  | ExecuteEvidence
  | CancelEvidence
  | RecoverEvidence;

export class AgentStoreTransitionValidationError extends Error {
  readonly code = 'E_AGENT_TRANSITION_INVALID' as const;

  constructor() {
    super('E_AGENT_TRANSITION_INVALID');
    this.name = 'AgentStoreTransitionValidationError';
  }
}

type RecordValue = Record<string, unknown>;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const OPAQUE = /^[A-Za-z0-9._:-]{1,128}$/u;
const PRINTABLE = /^[\x21-\x7e]+$/u;
const SAFE_SUMMARY = new Set([
  ...ALL_AGENT_TOOL_NAMES.map(tool => `agent.${tool}`),
  'agent.unknown',
]);
const TOOL_NAMES = new Set<string>(ALL_AGENT_TOOL_NAMES);
function isAgentRegistryVersion(value: unknown): value is AgentRegistryVersion {
  return value === 1 || value === 2 || value === 3;
}
const RECEIPT_FAILURE_CODES = new Set<Exclude<AgentRuntimeFailureCode, 'E_AGENT_NATIVE' | 'E_AGENT_NOT_FOUND'>>([
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
  'E_AGENT_DENIED_BY_USER',
  'E_COMPLETION_LENGTH',
  'E_COMPLETION_CONTENT_FILTER',
]);
const RUNTIME_FAILURE_CODES = new Set<AgentRuntimeFailureCode>([
  ...RECEIPT_FAILURE_CODES,
  'E_AGENT_NATIVE',
  'E_AGENT_NOT_FOUND',
]);

function safeFailureCode(value: unknown): value is Exclude<AgentRuntimeFailureCode, 'E_AGENT_NATIVE' | 'E_AGENT_NOT_FOUND'> {
  return typeof value === 'string' && RECEIPT_FAILURE_CODES.has(value as Exclude<AgentRuntimeFailureCode, 'E_AGENT_NATIVE' | 'E_AGENT_NOT_FOUND'>);
}

function runtimeFailureCode(value: unknown): value is AgentRuntimeFailureCode {
  return typeof value === 'string' && RUNTIME_FAILURE_CODES.has(value as AgentRuntimeFailureCode);
}
const FORBIDDEN_KEYS = new Set([
  'arguments_json',
  'raw_arguments',
  'raw_result',
  'tool_feedback',
  'messages',
  'native_envelope',
  'precondition',
  'settled_facts',
  'patch',
  'owner',
  'launch_id',
  'native_task_id',
  'content',
  'path',
  'arguments',
]);

const PREPARE_REQUEST_KEYS = [
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
  'model',
  'thinking_mode',
  'visible_message_ids',
  'visible_history_sha256',
  'visible_message_count',
  'project_context_sha256',
  'registry_version',
  'expected_policy_version',
  'expected_transcript',
] as const;
const COMPLETE_REQUEST_KEYS = [
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
  'model',
  'thinking_mode',
  'visible_history_sha256',
  'visible_message_count',
  'project_context_sha256',
  'transcript',
  'root',
  'registry_version',
  'toolset_sha256',
] as const;
const BATCH_REQUEST_KEYS = [
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
] as const;
const BIND_REQUEST_KEYS = [
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
] as const;
const EXECUTE_REQUEST_KEYS = [
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
] as const;
const CANCEL_REQUEST_KEYS = [
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
] as const;
const RECOVER_REQUEST_KEYS = [
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
] as const;

function ownRecord(value: unknown): RecordValue | null {
  try {
    if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) return null;
    if (Object.getOwnPropertySymbols(value).length !== 0) return null;
    const output = Object.create(null) as RecordValue;
    for (const key of Object.getOwnPropertyNames(value)) {
      if (FORBIDDEN_KEYS.has(key)) return null;
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      if (
        descriptor === undefined ||
        !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
        descriptor.enumerable !== true
      ) return null;
      output[key] = descriptor.value;
    }
    return output;
  } catch {
    return null;
  }
}

/** Clone only the already-validated data tree; never retain native result
 * arrays/objects by reference in reducer evidence. */
function safeClone(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(safeClone);
  if (typeof value !== 'object' || value === null) return value;
  const record = ownRecord(value);
  if (record === null) return null;
  return Object.fromEntries(Object.entries(record).map(([key, entry]) => [key, safeClone(entry)]));
}

function exact(value: unknown, keys: readonly string[]): RecordValue | null {
  const record = ownRecord(value);
  if (record === null) return null;
  const allowed = new Set(keys);
  const names = Object.keys(record);
  if (names.length !== keys.length || names.some(key => !allowed.has(key))) return null;
  return record;
}

/**
 * exact() plus a closed optional-key allowance so post-ship wire fields
 * (currently only `harness_id`) hydrate legacy rows without reopening the
 * closed-shape guarantee. Optional keys are validated by the caller.
 */
function exactWithOptional(
  value: unknown,
  keys: readonly string[],
  optionalKeys: readonly string[],
): RecordValue | null {
  const record = ownRecord(value);
  if (record === null) return null;
  const allowed = new Set([...keys, ...optionalKeys]);
  const names = Object.keys(record);
  if (
    names.some(key => !allowed.has(key)) ||
    keys.some(key => !names.includes(key))
  )
    return null;
  return record;
}

function validHarnessId(value: unknown): value is string {
  return typeof value === 'string' && (HARNESS_IDS as readonly string[]).includes(value);
}

function validProviderModel(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    isHarnessModelId(value)
  );
}

function arrayValue(value: unknown, maximum: number, minimum = 0): unknown[] | null {
  try {
    if (!Array.isArray(value) || Object.getPrototypeOf(value) !== Array.prototype) return null;
    if (Object.getOwnPropertySymbols(value).length !== 0) return null;
    const lengthDescriptor = Object.getOwnPropertyDescriptor(value, 'length');
    if (
      lengthDescriptor === undefined ||
      !Object.prototype.hasOwnProperty.call(lengthDescriptor, 'value') ||
      typeof lengthDescriptor.value !== 'number' ||
      !Number.isSafeInteger(lengthDescriptor.value) ||
      Object.is(lengthDescriptor.value, -0) ||
      lengthDescriptor.value < minimum ||
      lengthDescriptor.value > maximum
    ) return null;
    const output: unknown[] = [];
    for (let index = 0; index < lengthDescriptor.value; index += 1) {
      const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
      if (
        descriptor === undefined ||
        !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
        descriptor.enumerable !== true
      ) return null;
      output.push(descriptor.value);
    }
    if (Object.getOwnPropertyNames(value).some(key => key !== 'length' && !/^\d+$/u.test(key))) return null;
    return output;
  } catch {
    return null;
  }
}

function uuid(value: unknown): value is string {
  return typeof value === 'string' && UUID.test(value);
}

function digest(value: unknown): value is string {
  return typeof value === 'string' && SHA256.test(value);
}

function opaque(value: unknown): value is string {
  return typeof value === 'string' && OPAQUE.test(value);
}

function name(value: unknown): value is string {
  return typeof value === 'string' && value.length <= 64 && PRINTABLE.test(value);
}

function timestamp(value: unknown): value is string {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value) &&
    Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value;
}

function safeInteger(value: unknown, maximum = Number.MAX_SAFE_INTEGER - 1, allowZero = true): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && !Object.is(value, -0) &&
    value >= (allowZero ? 0 : 1) && value <= maximum;
}

function nullableUuid(value: unknown): value is string | null {
  return value === null || uuid(value);
}

function nullableDigest(value: unknown): value is string | null {
  return value === null || digest(value);
}

function enumValue<T extends string>(value: unknown, values: readonly T[]): value is T {
  return typeof value === 'string' && values.includes(value as T);
}

function copyStringArray(value: unknown, maximum: number, validate: (entry: unknown) => entry is string): string[] | null {
  const entries = arrayValue(value, maximum);
  if (entries === null) return null;
  const output: string[] = [];
  const seen = new Set<string>();
  for (const entry of entries) {
    if (!validate(entry) || seen.has(entry)) return null;
    seen.add(entry);
    output.push(entry);
  }
  return output;
}

function validateCheckpoint(value: unknown): AgentRuntimeCommittedCheckpointV1 | null {
  const raw = exact(value, ['schema_version', 'journal_revision', 'session_generation', 'session_sha256']);
  if (raw === null || raw.schema_version !== 1 || !safeInteger(raw.journal_revision) ||
    !safeInteger(raw.session_generation, Number.MAX_SAFE_INTEGER - 1, false) || !digest(raw.session_sha256)) return null;
  return {
    schema_version: 1,
    journal_revision: raw.journal_revision,
    session_generation: raw.session_generation,
    session_sha256: raw.session_sha256,
  };
}

function validateCAS(value: unknown): AgentRuntimeControllerCASV1 | null {
  const raw = exact(value, [
    'schema_version',
    'conversation_id',
    'task_id',
    'attempt_id',
    'expected_controller_generation',
    'expected_journal_revision',
    'expected_session_generation',
    'expected_session_sha256',
  ]);
  if (raw === null || raw.schema_version !== 1 || !uuid(raw.conversation_id) || !uuid(raw.task_id) ||
    !uuid(raw.attempt_id) || !safeInteger(raw.expected_controller_generation) ||
    !safeInteger(raw.expected_journal_revision) ||
    !safeInteger(raw.expected_session_generation, Number.MAX_SAFE_INTEGER - 1, false) ||
    !digest(raw.expected_session_sha256)) return null;
  return {
    schema_version: 1,
    conversation_id: raw.conversation_id,
    task_id: raw.task_id,
    attempt_id: raw.attempt_id,
    expected_controller_generation: raw.expected_controller_generation,
    expected_journal_revision: raw.expected_journal_revision,
    expected_session_generation: raw.expected_session_generation,
    expected_session_sha256: raw.expected_session_sha256,
  };
}

function validateTranscript(value: unknown): AgentRuntimeTranscriptHandleV1 | null {
  const raw = exact(value, ['schema_version', 'transcript_ref', 'generation', 'transcript_sha256', 'transcript_bytes']);
  if (raw === null || raw.schema_version !== 1 || !uuid(raw.transcript_ref) || !safeInteger(raw.generation) ||
    !digest(raw.transcript_sha256) || !safeInteger(raw.transcript_bytes, 2 * 1024 * 1024)) return null;
  return {
    schema_version: 1,
    transcript_ref: raw.transcript_ref,
    generation: raw.generation,
    transcript_sha256: raw.transcript_sha256,
    transcript_bytes: raw.transcript_bytes,
  };
}

function validateRoot(value: unknown): AgentRuntimeRootV1 | null {
  const raw = exact(value, [
    'schema_version',
    'kind',
    'workspace_id',
    'workspace_binding_revision',
    'project_id',
    'root_fingerprint_sha256',
    'capabilities',
  ]);
  if (raw === null || raw.schema_version !== 1 || (raw.kind !== 'project' && raw.kind !== 'workspace') ||
    !uuid(raw.workspace_id) || !safeInteger(raw.workspace_binding_revision, Number.MAX_SAFE_INTEGER - 1, false) ||
    !nullableUuid(raw.project_id) || !digest(raw.root_fingerprint_sha256)) return null;
  if ((raw.kind === 'project') !== (raw.project_id !== null)) return null;
  const capabilities = copyStringArray(raw.capabilities, 6, capability =>
    capability === 'file_read' || capability === 'file_write' || capability === 'git_status' || capability === 'git_commit' || capability === 'git_push' || capability === 'guest_service',
  );
  if (capabilities === null || (raw.kind === 'workspace' && capabilities.some(capability => capability.startsWith('git_')))) return null;
  return {
    schema_version: 1,
    kind: raw.kind,
    workspace_id: raw.workspace_id,
    workspace_binding_revision: raw.workspace_binding_revision,
    project_id: raw.project_id,
    root_fingerprint_sha256: raw.root_fingerprint_sha256,
    capabilities: capabilities as AgentRuntimeRootV1['capabilities'],
  };
}

function validatePolicy(value: unknown): AgentRuntimePolicyV1 | null {
  const raw = exact(value, ['schema_version', 'policy_version', 'max_single_write_bytes', 'max_batch_write_bytes', 'max_attempt_write_bytes']);
  if (raw === null || raw.schema_version !== 1 || raw.policy_version !== 'agent-v1' ||
    raw.max_single_write_bytes !== 32768 || !safeInteger(raw.max_batch_write_bytes, 524288, false) ||
    raw.max_batch_write_bytes < 32768 || !safeInteger(raw.max_attempt_write_bytes, 4194304, false) ||
    raw.max_attempt_write_bytes < raw.max_batch_write_bytes) return null;
  return {
    schema_version: 1,
    policy_version: 'agent-v1',
    max_single_write_bytes: 32768,
    max_batch_write_bytes: raw.max_batch_write_bytes,
    max_attempt_write_bytes: raw.max_attempt_write_bytes,
  };
}

function expectedAccess(toolName: string): AgentRuntimeRegistryToolV2['access'] {
  if ((ALL_AGENT_AUTO_TOOLS as readonly string[]).includes(toolName)) return 'auto';
  if (toolName === 'write_file' || toolName === 'git_commit' || toolName === 'git_push') return 'conversation_confirm';
  if (isGuestServiceAgentTool(toolName)) return 'conversation_confirm';
  return 'durable_deny';
}

function validateRegistry(value: unknown): AgentRuntimeRegistryV2 | null {
  const raw = exact(value, ['schema_version', 'registry_version', 'toolset_sha256', 'tools']);
  if (raw === null || raw.schema_version !== 2 || !isAgentRegistryVersion(raw.registry_version) || !digest(raw.toolset_sha256)) return null;
  const rows = arrayValue(raw.tools, agentRegistryToolLimit(raw.registry_version));
  if (rows === null) return null;
  const tools: AgentRuntimeRegistryToolV2[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    const tool = exact(row, ['schema_version', 'name', 'safe_summary_key', 'access']);
    if (tool === null || tool.schema_version !== 2 || !name(tool.name) || seen.has(tool.name) ||
      !enumValue(tool.access, ['auto', 'conversation_confirm', 'confirm_once', 'durable_deny'] as const) ||
      !name(tool.safe_summary_key) || !SAFE_SUMMARY.has(tool.safe_summary_key) ||
      tool.safe_summary_key !== (TOOL_NAMES.has(tool.name) ? `agent.${tool.name}` : 'agent.unknown') ||
      !agentToolRegistryCompatible(tool.name, raw.registry_version) ||
      tool.access !== expectedAccess(tool.name)) return null;
    seen.add(tool.name);
    tools.push({
      schema_version: 2,
      name: tool.name,
      safe_summary_key: tool.safe_summary_key,
      access: tool.access,
    });
  }
  return { schema_version: 2, registry_version: raw.registry_version, toolset_sha256: raw.toolset_sha256, tools };
}

function validateReceipt(value: unknown): AgentToolReceiptV1 | null {
  const raw = exact(value, [
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
  ]);
  if (raw === null || raw.schema_version !== 1 || !opaque(raw.call_id) || !name(raw.name) ||
    !digest(raw.arguments_sha256) || !digest(raw.result_sha256) || !safeInteger(raw.result_bytes, 32 * 1024 * 1024) ||
    typeof raw.truncated !== 'boolean' || !safeInteger(raw.duration_ms, 24 * 60 * 60 * 1000) ||
    !enumValue(raw.outcome, ['ok', 'failed', 'denied', 'cancelled', 'ambiguous'] as const) ||
    (raw.failure_code !== null && (typeof raw.failure_code !== 'string' || !RECEIPT_FAILURE_CODES.has(raw.failure_code as Exclude<AgentRuntimeFailureCode, 'E_AGENT_NATIVE' | 'E_AGENT_NOT_FOUND'>))) ||
    !nullableUuid(raw.approval_reference)) return null;
  if (raw.outcome === 'ok' && raw.failure_code !== null) return null;
  if (raw.outcome === 'ambiguous' && raw.failure_code !== 'E_AGENT_EXECUTION_AMBIGUOUS') return null;
  if (raw.outcome !== 'ambiguous' && raw.failure_code === 'E_AGENT_EXECUTION_AMBIGUOUS') return null;
  if (raw.outcome !== 'ok' && raw.failure_code === null) return null;
  return {
    schema_version: 1,
    call_id: raw.call_id,
    name: raw.name,
    arguments_sha256: raw.arguments_sha256,
    result_sha256: raw.result_sha256,
    result_bytes: raw.result_bytes,
    truncated: raw.truncated,
    duration_ms: raw.duration_ms,
    outcome: raw.outcome,
    failure_code: raw.failure_code as AgentToolReceiptV1['failure_code'],
    approval_reference: raw.approval_reference,
  };
}

function validateApprovalToken(value: unknown): AgentApprovalBindingTokenV2 | null {
  const raw = exact(value, [
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
  ]);
  if (raw === null || raw.schema_version !== 2 || !uuid(raw.token) || !uuid(raw.task_id) || !uuid(raw.attempt_id) ||
    !uuid(raw.round_id) || !safeInteger(raw.round_index, 7) || !safeInteger(raw.batch_revision, Number.MAX_SAFE_INTEGER - 1, false) ||
    !digest(raw.manifest_sha256) || !safeInteger(raw.call_index, 15) || !opaque(raw.call_id) || !name(raw.name) ||
    !digest(raw.arguments_sha256) || !digest(raw.idempotency_key) || !digest(raw.root_fingerprint_sha256) ||
    !safeInteger(raw.binding_revision, Number.MAX_SAFE_INTEGER - 1, false) || raw.policy_version !== 'agent-v1' ||
    !isAgentRegistryVersion(raw.registry_version) ||
    !agentToolRegistryCompatible(raw.name, raw.registry_version) ||
    !enumValue(raw.access, ['conversation_confirm', 'confirm_once'] as const)) return null;
  const controllerCas = validateCAS(raw.controller_cas);
  if (controllerCas === null || controllerCas.task_id !== raw.task_id || controllerCas.attempt_id !== raw.attempt_id) return null;
  const ids = copyStringArray(raw.batch_call_ids, 16, opaque);
  const args = copyStringArray(raw.batch_arguments_sha256, 16, digest);
  const allowed = arrayValue(raw.allowed_decisions, 4, 1);
  if (ids === null || args === null || ids.length === 0 || ids.length !== args.length || raw.call_index >= ids.length ||
    allowed === null || allowed.some(decision => typeof decision !== 'string')) return null;
  const expected = raw.access === 'conversation_confirm'
    ? ['denied', 'allow_once', 'allow_conversation', 'cancelled']
    : ['denied', 'allow_once', 'cancelled'];
  if (allowed.length !== expected.length || allowed.some((decision, index) => decision !== expected[index])) return null;
  if (ids[raw.call_index] !== raw.call_id || args[raw.call_index] !== raw.arguments_sha256) return null;
  return {
    schema_version: 2,
    token: raw.token,
    controller_cas: controllerCas,
    task_id: raw.task_id,
    attempt_id: raw.attempt_id,
    round_id: raw.round_id,
    round_index: raw.round_index,
    batch_call_ids: ids,
    batch_arguments_sha256: args,
    batch_revision: raw.batch_revision,
    manifest_sha256: raw.manifest_sha256,
    call_index: raw.call_index,
    call_id: raw.call_id,
    name: raw.name,
    arguments_sha256: raw.arguments_sha256,
    idempotency_key: raw.idempotency_key,
    root_fingerprint_sha256: raw.root_fingerprint_sha256,
    binding_revision: raw.binding_revision,
    policy_version: 'agent-v1',
    registry_version: raw.registry_version,
    access: raw.access,
    allowed_decisions: allowed as AgentApprovalBindingTokenV2['allowed_decisions'],
  };
}

function identityCAS(
  raw: RecordValue,
): { readonly cas: AgentRuntimeControllerCASV1; readonly checkpoint: AgentRuntimeCommittedCheckpointV1 } | null {
  const cas = validateCAS(raw.controller_cas);
  const checkpoint = validateCheckpoint(raw.committed_checkpoint);
  if (cas === null || checkpoint === null || cas.expected_journal_revision !== checkpoint.journal_revision ||
    cas.expected_session_generation !== checkpoint.session_generation || cas.expected_session_sha256 !== checkpoint.session_sha256) return null;
  return { cas, checkpoint };
}

function requestIdentity(raw: RecordValue, identity: { task_id: string; conversation_id: string; attempt_id: string }): boolean {
  const common = identityCAS(raw);
  return common !== null && common.cas.task_id === identity.task_id && common.cas.conversation_id === identity.conversation_id && common.cas.attempt_id === identity.attempt_id;
}

function validateTransport(
  transport: unknown,
  projectId: unknown,
  contextDigest: unknown,
  rootKind?: unknown,
): boolean {
  if (transport !== 2 && transport !== 3) return false;
  if (transport === 2 && contextDigest !== null) return false;
  if (transport === 3 && (projectId === null || contextDigest === null || rootKind === 'workspace')) return false;
  if (rootKind === 'workspace' && projectId !== null) return false;
  return nullableDigest(contextDigest) && nullableUuid(projectId);
}

function sameTranscript(
  left: AgentRuntimeTranscriptHandleV1,
  right: AgentRuntimeTranscriptHandleV1,
): boolean {
  return left.schema_version === right.schema_version &&
    left.transcript_ref === right.transcript_ref &&
    left.generation === right.generation &&
    left.transcript_sha256 === right.transcript_sha256 &&
    left.transcript_bytes === right.transcript_bytes;
}

function sameStringArray(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((entry, index) => entry === right[index]);
}

function sameRoot(left: AgentRuntimeRootV1, right: AgentRuntimeRootV1): boolean {
  return left.schema_version === right.schema_version &&
    left.kind === right.kind &&
    left.workspace_id === right.workspace_id &&
    left.workspace_binding_revision === right.workspace_binding_revision &&
    left.project_id === right.project_id &&
    left.root_fingerprint_sha256 === right.root_fingerprint_sha256 &&
    sameStringArray(left.capabilities, right.capabilities);
}

function expectedToolFamily(toolName: string): AgentConversationGrantV2['tool_family'] | null {
  if (toolName === 'write_file') return 'file_write';
  if (toolName === 'git_commit') return 'git_commit';
  if (toolName === 'git_push') return 'git_push';
  if (isGuestServiceAgentTool(toolName)) return 'guest_service';
  return null;
}

function rootCanUse(root: AgentRuntimeRootV1, toolName: string): boolean {
  const capability = toolName === 'list_dir' || toolName === 'read_file' || toolName === 'list_runtime_environments'
    ? 'file_read'
    : toolName === 'write_file'
      ? 'file_write'
      : toolName === 'git_status'
        ? 'git_status'
        : toolName === 'git_commit'
          ? 'git_commit'
          : toolName === 'git_push'
            ? 'git_push'
            : isGuestServiceAgentTool(toolName)
              ? 'guest_service'
            : null;
  return capability === null || root.capabilities.includes(capability);
}

function resultRoundRevisionMatches(expected: number, result: number): boolean {
  if (!safeInteger(expected) ||
      !safeInteger(result, Number.MAX_SAFE_INTEGER - 1, false)) return false;
  const advance = result - expected;
  return advance > 0 && advance <= 3;
}

function recoveredRoundRevisionMatches(expected: number, result: number): boolean {
  if (!safeInteger(expected) ||
      !safeInteger(result, Number.MAX_SAFE_INTEGER - 1, false)) return false;
  const advance = result - expected;
  // Reconciliation can project the already-completed row without mutating it;
  // retry recovery can instead complete the same native transition sequence.
  return advance >= 0 && advance <= 3;
}

function resultExecutionRevisionMatches(expected: number, result: number): boolean {
  if (!safeInteger(result, Number.MAX_SAFE_INTEGER - 1, false)) return false;
  const advance = result - expected;
  // A complete execution may atomically traverse intent -> claimed ->
  // dispatched -> settled. Query/replay projections may name the same row.
  return advance >= 0 && advance <= 3;
}

function resultExecutionTargetRevisionMatches(expected: number, result: number): boolean {
  if (!safeInteger(result, Number.MAX_SAFE_INTEGER - 1, false)) return false;
  return result === expected || result === expected + 1;
}

function targetRevisionRelation(
  target: AgentCancelTargetV2 | AgentRecoveryTargetV2,
  roundRevision: number | null,
  executionRevision: number | null,
): boolean {
  if (target.kind === 'attempt') return roundRevision === null && executionRevision === null;
  if (target.kind === 'round') return roundRevision !== null && executionRevision === null;
  return roundRevision === null && executionRevision !== null;
}

function validatePrepareRequest(value: unknown): PrepareAgentAttemptRequestV2 | null {
  const raw = exactWithOptional(value, PREPARE_REQUEST_KEYS, ['harness_id']);
  if (raw === null || raw.schema_version !== 2 || !uuid(raw.operation_id) || !uuid(raw.task_id) || !uuid(raw.conversation_id) ||
    !uuid(raw.attempt_id) || !nullableUuid(raw.workspace_id) || !nullableUuid(raw.project_id) ||
    (raw.workspace_binding_revision !== null && !safeInteger(raw.workspace_binding_revision, Number.MAX_SAFE_INTEGER - 1, false)) ||
    !validateTransport(raw.transport_schema_version, raw.project_id, raw.project_context_sha256) ||
    (raw.harness_id !== undefined && !validHarnessId(raw.harness_id)) || !validProviderModel(raw.model) ||
    !enumValue(raw.thinking_mode, ['off', 'high', 'max'] as const) || !digest(raw.visible_history_sha256) ||
    !safeInteger(raw.visible_message_count, 96) || !isAgentRegistryVersion(raw.registry_version) ||
    (raw.expected_policy_version !== null && raw.expected_policy_version !== 'agent-v1')) return null;
  if (
    raw.workspace_id === null
      ? raw.workspace_binding_revision !== null || raw.project_id !== null || raw.project_context_sha256 !== null || raw.transport_schema_version !== 2
      : raw.workspace_binding_revision === null ||
        (raw.project_id === null
          ? raw.project_context_sha256 !== null || raw.transport_schema_version !== 2
          : raw.project_context_sha256 === null || raw.transport_schema_version !== 3)
  ) return null;
  const ids = copyStringArray(raw.visible_message_ids, 96, uuid);
  if (ids === null || ids.length !== raw.visible_message_count) return null;
  const expectedTranscript = raw.expected_transcript === null ? null : validateTranscript(raw.expected_transcript);
  if (raw.expected_transcript !== null && expectedTranscript === null) return null;
  const identity = identityCAS(raw);
  if (identity === null || identity.cas.task_id !== raw.task_id || identity.cas.conversation_id !== raw.conversation_id || identity.cas.attempt_id !== raw.attempt_id) return null;
  const { cas, checkpoint } = identity;
  return {
    schema_version: 2,
    operation_id: raw.operation_id,
    controller_cas: cas,
    committed_checkpoint: checkpoint,
    task_id: raw.task_id,
    conversation_id: raw.conversation_id,
    attempt_id: raw.attempt_id,
    workspace_id: raw.workspace_id,
    project_id: raw.project_id,
    workspace_binding_revision: raw.workspace_binding_revision,
    transport_schema_version: raw.transport_schema_version,
    harness_id: raw.harness_id === undefined ? 'dsh' : raw.harness_id,
    model: raw.model,
    thinking_mode: raw.thinking_mode,
    visible_message_ids: ids,
    visible_history_sha256: raw.visible_history_sha256,
    visible_message_count: raw.visible_message_count,
    project_context_sha256: raw.project_context_sha256,
    registry_version: raw.registry_version,
    expected_policy_version: raw.expected_policy_version,
    expected_transcript: expectedTranscript,
  } as PrepareAgentAttemptRequestV2;
}

function validateRoundRequest(value: unknown): CompleteAgentRoundRequestV2 | null {
  const raw = exactWithOptional(value, COMPLETE_REQUEST_KEYS, ['harness_id']);
  if (raw === null || raw.schema_version !== 2 || !uuid(raw.operation_id) || !uuid(raw.task_id) || !uuid(raw.conversation_id) ||
    !uuid(raw.attempt_id) || !uuid(raw.round_id) || !safeInteger(raw.round_index, 7) || !safeInteger(raw.launch_attempt, 8, false) ||
    !safeInteger(raw.expected_round_revision) ||
    (raw.harness_id !== undefined && !validHarnessId(raw.harness_id)) || !validProviderModel(raw.model) ||
    !enumValue(raw.thinking_mode, ['off', 'high', 'max'] as const) || !digest(raw.visible_history_sha256) || !safeInteger(raw.visible_message_count, 96) ||
    !isAgentRegistryVersion(raw.registry_version) || !digest(raw.toolset_sha256)) return null;
  const transcript = validateTranscript(raw.transcript);
  const root = validateRoot(raw.root);
  if (transcript === null || root === null ||
    !validateTransport(raw.transport_schema_version, root.project_id, raw.project_context_sha256, root.kind) ||
    !requestIdentity(raw, { task_id: raw.task_id, conversation_id: raw.conversation_id, attempt_id: raw.attempt_id })) return null;
  if (root.project_id === null && raw.project_context_sha256 !== null) return null;
  if (root.project_id !== null && raw.project_context_sha256 === null) return null;
  const identity = identityCAS(raw);
  if (identity === null) return null;
  return {
    schema_version: 2,
    operation_id: raw.operation_id,
    controller_cas: identity.cas,
    committed_checkpoint: identity.checkpoint,
    task_id: raw.task_id,
    conversation_id: raw.conversation_id,
    attempt_id: raw.attempt_id,
    round_id: raw.round_id,
    round_index: raw.round_index,
    launch_attempt: raw.launch_attempt,
    expected_round_revision: raw.expected_round_revision,
    transport_schema_version: raw.transport_schema_version,
    harness_id: raw.harness_id === undefined ? 'dsh' : raw.harness_id,
    model: raw.model,
    thinking_mode: raw.thinking_mode,
    visible_history_sha256: raw.visible_history_sha256,
    visible_message_count: raw.visible_message_count,
    project_context_sha256: raw.project_context_sha256,
    transcript,
    root,
    registry_version: raw.registry_version,
    toolset_sha256: raw.toolset_sha256,
  } as CompleteAgentRoundRequestV2;
}


function validateBatchRequest(value: unknown): PrepareAgentToolBatchRequestV2 | null {
  const raw = exact(value, BATCH_REQUEST_KEYS);
  if (raw === null || raw.schema_version !== 2 || !uuid(raw.operation_id) || !uuid(raw.task_id) || !uuid(raw.conversation_id) || !uuid(raw.attempt_id) ||
    !uuid(raw.round_id) || !safeInteger(raw.round_index, 7) || !safeInteger(raw.expected_round_revision) || !isAgentRegistryVersion(raw.registry_version) ||
    !digest(raw.toolset_sha256) || raw.policy_version !== 'agent-v1' || !safeInteger(raw.expected_batch_revision) || !safeInteger(raw.expected_reserved_write_bytes, 4194304)) return null;
  const transcript = validateTranscript(raw.transcript);
  const root = validateRoot(raw.root);
  if (transcript === null || root === null || !requestIdentity(raw, { task_id: raw.task_id, conversation_id: raw.conversation_id, attempt_id: raw.attempt_id })) return null;
  return { ...raw, controller_cas: validateCAS(raw.controller_cas)!, committed_checkpoint: validateCheckpoint(raw.committed_checkpoint)!, transcript, root } as PrepareAgentToolBatchRequestV2;
}

function validateBindRequest(value: unknown): BindAgentApprovalRequestV2 | null {
  // `deny_message` is tolerated as absent (older evidence) and defaults to
  // null; the runtime always supplies it.  Mapped evidence is re-validated
  // at the reducer boundary, so the validator must also accept its own
  // output: the 15-key base plus at most one bounded `deny_message`.
  const record = ownRecord(value);
  if (record === null) return null;
  const names = Object.keys(record);
  const allowedKeys = new Set<string>([...BIND_REQUEST_KEYS, 'deny_message']);
  if (
    names.length < BIND_REQUEST_KEYS.length ||
    names.length > BIND_REQUEST_KEYS.length + 1 ||
    names.some(key => !allowedKeys.has(key))
  ) return null;
  const raw = record;
  if (raw.schema_version !== 2 || !uuid(raw.operation_id) || !uuid(raw.task_id) || !uuid(raw.conversation_id) || !uuid(raw.attempt_id) || !uuid(raw.round_id) ||
    !safeInteger(raw.round_index, 7) || !digest(raw.manifest_sha256) || !safeInteger(raw.batch_revision, Number.MAX_SAFE_INTEGER - 1, false) || !safeInteger(raw.call_index, 15) || !opaque(raw.call_id) ||
    !enumValue(raw.decision, ['denied', 'allow_once', 'allow_conversation', 'cancelled'] as const) || !requestIdentity(raw, { task_id: raw.task_id, conversation_id: raw.conversation_id, attempt_id: raw.attempt_id })) return null;
  const denyMessage = raw.deny_message ?? null;
  if (raw.decision === 'denied' ? (denyMessage !== null && !boundedUTF8(denyMessage, 2000, true)) : denyMessage !== null) return null;
  const token = validateApprovalToken(raw.token);
  const controllerCas = validateCAS(raw.controller_cas);
  const checkpoint = validateCheckpoint(raw.committed_checkpoint);
  if (token === null || controllerCas === null || checkpoint === null || token.task_id !== raw.task_id || token.attempt_id !== raw.attempt_id || token.round_id !== raw.round_id || token.round_index !== raw.round_index ||
    token.batch_revision !== raw.batch_revision || token.manifest_sha256 !== raw.manifest_sha256 || token.call_index !== raw.call_index || token.call_id !== raw.call_id ||
    !controllerCASCanAdvance(token.controller_cas, controllerCas) || !token.allowed_decisions.includes(raw.decision) ||
    expectedToolFamily(token.name) === null ||
    token.access !== 'conversation_confirm' ||
    (raw.decision === 'allow_conversation' && token.access !== 'conversation_confirm')) return null;
  return { ...raw, deny_message: denyMessage, controller_cas: controllerCas, committed_checkpoint: checkpoint, token } as BindAgentApprovalRequestV2;
}

function sameControllerCAS(
  left: AgentRuntimeControllerCASV1,
  right: AgentRuntimeControllerCASV1,
): boolean {
  return left.schema_version === right.schema_version &&
    left.conversation_id === right.conversation_id &&
    left.task_id === right.task_id &&
    left.attempt_id === right.attempt_id &&
    left.expected_controller_generation === right.expected_controller_generation &&
    left.expected_journal_revision === right.expected_journal_revision &&
    left.expected_session_generation === right.expected_session_generation &&
    left.expected_session_sha256 === right.expected_session_sha256;
}

function controllerCASCanAdvance(
  issued: AgentRuntimeControllerCASV1,
  current: AgentRuntimeControllerCASV1,
): boolean {
  if (
    issued.schema_version !== current.schema_version ||
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

function validateExecuteRequest(value: unknown): ExecuteAgentToolRequestV2 | null {
  const raw = exact(value, EXECUTE_REQUEST_KEYS);
  if (raw === null || raw.schema_version !== 2 || !uuid(raw.operation_id) || !uuid(raw.task_id) || !uuid(raw.conversation_id) || !uuid(raw.attempt_id) || !uuid(raw.round_id) ||
    !safeInteger(raw.round_index, 7) || !enumValue(raw.batch_kind, ['write_batch', 'read_only_batch'] as const) || !nullableDigest(raw.manifest_sha256) ||
    (raw.batch_kind === 'write_batch' && raw.manifest_sha256 === null) || (raw.batch_kind === 'read_only_batch' && raw.manifest_sha256 !== null) ||
    !safeInteger(raw.expected_batch_revision, Number.MAX_SAFE_INTEGER - 1, false) || !safeInteger(raw.call_index, 15) || !opaque(raw.call_id) || !name(raw.name) || !digest(raw.arguments_sha256) || !digest(raw.idempotency_key) ||
    !safeInteger(raw.expected_execution_revision, Number.MAX_SAFE_INTEGER - 1, false) || !nullableUuid(raw.approval_reference) || !requestIdentity(raw, { task_id: raw.task_id, conversation_id: raw.conversation_id, attempt_id: raw.attempt_id })) return null;
  const transcript = validateTranscript(raw.transcript);
  const root = validateRoot(raw.root);
  const identity = identityCAS(raw);
  if (transcript === null || root === null || identity === null || !TOOL_NAMES.has(raw.name) || !rootCanUse(root, raw.name)) return null;
  if (raw.batch_kind === 'read_only_batch' && ((ALL_AGENT_CONFIRM_TOOLS as readonly string[]).includes(raw.name))) return null;
  const auto = (ALL_AGENT_AUTO_TOOLS as readonly string[]).includes(raw.name);
  if (auto ? raw.approval_reference !== null : raw.approval_reference === null) return null;
  return { ...raw, controller_cas: identity.cas, committed_checkpoint: identity.checkpoint, transcript, root } as ExecuteAgentToolRequestV2;
}

function validateCancelTarget(value: unknown): AgentCancelTargetV2 | null {
  const raw = ownRecord(value);
  if (raw === null || raw.schema_version !== 2 || !enumValue(raw.kind, ['attempt', 'round', 'tool'] as const) || !uuid(raw.task_id) || !uuid(raw.attempt_id)) return null;
  if (raw.kind === 'attempt') {
    return Object.keys(raw).length === 4 ? { schema_version: 2, kind: 'attempt', task_id: raw.task_id, attempt_id: raw.attempt_id } : null;
  }
  const round = exact(raw, ['schema_version', 'kind', 'task_id', 'attempt_id', 'round_id', 'round_index']);
  if (round !== null && round.kind === 'round' && uuid(round.round_id) && safeInteger(round.round_index, 7)) return round as unknown as AgentCancelTargetV2;
  const tool = exact(raw, ['schema_version', 'kind', 'task_id', 'attempt_id', 'round_id', 'round_index', 'call_index', 'call_id', 'idempotency_key']);
  if (tool !== null && tool.kind === 'tool' && uuid(tool.round_id) && safeInteger(tool.round_index, 7) && safeInteger(tool.call_index, 15) && opaque(tool.call_id) && digest(tool.idempotency_key)) return tool as unknown as AgentCancelTargetV2;
  return null;
}

function validateCancelToken(value: unknown): AgentCancelTokenV2 | null {
  const raw = exact(value, ['schema_version', 'issuer', 'source_event_id', 'token', 'task_id', 'attempt_id', 'expected_phase', 'reason_code']);
  if (raw === null || raw.schema_version !== 2 || raw.issuer !== 'completion_controller' || !uuid(raw.source_event_id) || raw.token !== raw.source_event_id || !uuid(raw.task_id) || !uuid(raw.attempt_id) ||
    !enumValue(raw.expected_phase, ['ready_for_round', 'batch_frozen', 'round_in_flight', 'approval_pending', 'execution_intent', 'tool_result_pending'] as const) ||
    !enumValue(raw.reason_code, ['E_AGENT_CANCELLED', 'E_AGENT_ROOT_STALE', 'E_AGENT_PERSISTENCE'] as const)) return null;
  return raw as unknown as AgentCancelTokenV2;
}

function validateCancelRequest(value: unknown): CancelAgentAttemptRequestV2 | null {
  const raw = exact(value, CANCEL_REQUEST_KEYS);
  if (raw === null || raw.schema_version !== 2 || !uuid(raw.operation_id)) return null;
  const identity = identityCAS(raw);
  const target = validateCancelTarget(raw.target);
  const token = validateCancelToken(raw.cancel_token);
  const transcript = validateTranscript(raw.expected_transcript);
  const root = validateRoot(raw.root);
  if (identity === null || target === null || token === null || transcript === null || root === null ||
    token.task_id !== target.task_id || token.attempt_id !== target.attempt_id || target.task_id !== identity.cas.task_id || target.attempt_id !== identity.cas.attempt_id ||
    (target.kind === 'attempt' && (raw.expected_round_revision !== null || raw.expected_execution_revision !== null)) ||
    (target.kind === 'round' && (raw.expected_round_revision === null || raw.expected_execution_revision !== null)) ||
    (target.kind === 'tool' && (raw.expected_round_revision !== null || raw.expected_execution_revision === null)) ||
    (raw.expected_round_revision !== null && !safeInteger(raw.expected_round_revision, Number.MAX_SAFE_INTEGER - 1)) ||
    (raw.expected_execution_revision !== null && !safeInteger(raw.expected_execution_revision, Number.MAX_SAFE_INTEGER - 1, false)) ||
    (target.kind === 'round' && token.expected_phase !== 'round_in_flight') ||
    (target.kind === 'tool' && token.expected_phase !== 'approval_pending' && token.expected_phase !== 'execution_intent' && token.expected_phase !== 'tool_result_pending')) return null;
  return { ...raw, controller_cas: identity.cas, committed_checkpoint: identity.checkpoint, target, cancel_token: token, expected_transcript: transcript, root } as CancelAgentAttemptRequestV2;
}

function validateRecoveryTarget(value: unknown): AgentRecoveryTargetV2 | null {
  return validateCancelTarget(value) as AgentRecoveryTargetV2 | null;
}

function validateRecoverRequest(value: unknown): RecoverAgentAttemptRequestV2 | null {
  const raw = exact(value, RECOVER_REQUEST_KEYS);
  if (raw === null || raw.schema_version !== 2 || !uuid(raw.operation_id) || !enumValue(raw.action, ['reconcile', 'retry_failed_round'] as const) ||
    (raw.expected_round_revision !== null && !safeInteger(raw.expected_round_revision, Number.MAX_SAFE_INTEGER - 1, false)) ||
    (raw.expected_execution_revision !== null && !safeInteger(raw.expected_execution_revision, Number.MAX_SAFE_INTEGER - 1, false))) return null;
  const identity = identityCAS(raw);
  const target = validateRecoveryTarget(raw.target);
  const transcript = validateTranscript(raw.expected_transcript);
  const root = validateRoot(raw.root);
  if (identity === null || target === null || transcript === null || root === null || target.task_id !== identity.cas.task_id || target.attempt_id !== identity.cas.attempt_id ||
    !targetRevisionRelation(target, raw.expected_round_revision, raw.expected_execution_revision)) return null;
  if (raw.action === 'retry_failed_round' && target.kind !== 'round') return null;
  return { ...raw, controller_cas: identity.cas, committed_checkpoint: identity.checkpoint, target, expected_transcript: transcript, root } as RecoverAgentAttemptRequestV2;
}

function equalCheckpoint(left: AgentRuntimeCommittedCheckpointV1, right: AgentRuntimeCommittedCheckpointV1): boolean {
  return left.schema_version === right.schema_version && left.journal_revision === right.journal_revision && left.session_generation === right.session_generation && left.session_sha256 === right.session_sha256;
}

function transcriptRelation(before: AgentRuntimeTranscriptHandleV1, after: AgentRuntimeTranscriptHandleV1): boolean {
  if (before.transcript_ref !== after.transcript_ref || after.generation < before.generation) return false;
  return after.generation !== before.generation ? after.transcript_sha256 !== before.transcript_sha256 : after.transcript_sha256 === before.transcript_sha256 && after.transcript_bytes === before.transcript_bytes;
}

function validateRoundReceipt(value: unknown): AgentRoundReceiptV2 | null {
  const raw = exactWithOptional(value, ['schema_version', 'transport_schema_version', 'turn_id', 'task_id', 'attempt_id', 'round_id', 'round_index', 'provider_request_id', 'provider_response_id', 'requested_model', 'model', 'thinking_mode', 'finish_reason', 'latency_ms', 'visible_history_sha256', 'model_input_sha256', 'request_body_sha256', 'project_context_receipt'], ['harness_id', 'provider_configuration']);
  if (raw === null || raw.schema_version !== 2 || (raw.transport_schema_version !== 2 && raw.transport_schema_version !== 3) || !uuid(raw.turn_id) || !uuid(raw.task_id) || !uuid(raw.attempt_id) || !uuid(raw.round_id) || !safeInteger(raw.round_index, 7) || !opaque(raw.provider_request_id) || !opaque(raw.provider_response_id) || (raw.harness_id !== undefined && !validHarnessId(raw.harness_id)) || !validProviderModel(raw.requested_model) || !validProviderModel(raw.model) || !enumValue(raw.thinking_mode, ['off', 'high', 'max'] as const) || !enumValue(raw.finish_reason, ['stop', 'tool_calls', 'length', 'content_filter'] as const) || !safeInteger(raw.latency_ms, 24 * 60 * 60 * 1000) || !digest(raw.visible_history_sha256) || !digest(raw.model_input_sha256) || !digest(raw.request_body_sha256) || !validateProjectReceipt(raw.project_context_receipt)) return null;
  if (raw.provider_configuration !== undefined && parseProviderBinding(raw.provider_configuration, raw.model as import('../harness/types').HarnessModelId) === null) return null;
  if ((raw.transport_schema_version === 2 && raw.project_context_receipt !== null) ||
    (raw.transport_schema_version === 3 && raw.project_context_receipt === null)) return null;
  const normalized = raw.harness_id === undefined ? { ...raw, harness_id: 'dsh' } : raw;
  return normalized as unknown as AgentRoundReceiptV2;
}

function validateProjectReceipt(value: unknown): boolean {
  if (value === null) return true;
  const raw = exact(value, ['schema_version', 'snapshot_id', 'snapshot_sha256', 'source_fingerprint', 'context_bytes', 'verified_at']);
  return raw !== null && raw.schema_version === 1 && uuid(raw.snapshot_id) && digest(raw.snapshot_sha256) && digest(raw.source_fingerprint) && safeInteger(raw.context_bytes, 256 * 1024, false) && timestamp(raw.verified_at);
}

function validateRoundCall(value: unknown): AgentRoundCallPresentationV3 | null {
  const raw = exact(value, ['schema_version', 'call_index', 'call_id', 'name', 'arguments_sha256', 'safe_summary_key', 'access', 'approval_state']);
  if (raw === null || raw.schema_version !== 3 || !safeInteger(raw.call_index, 15) || !opaque(raw.call_id) || !name(raw.name) || !digest(raw.arguments_sha256) || !name(raw.safe_summary_key) || !SAFE_SUMMARY.has(raw.safe_summary_key) || !enumValue(raw.access, ['auto', 'conversation_confirm', 'confirm_once', 'durable_deny'] as const) || !enumValue(raw.approval_state, ['deferred', 'durable_denied'] as const)) return null;
  const knownTool = TOOL_NAMES.has(raw.name);
  if (raw.access !== (knownTool ? expectedAccess(raw.name) : 'durable_deny') || raw.safe_summary_key !== (knownTool ? `agent.${raw.name}` : 'agent.unknown')) return null;
  if (raw.access === 'durable_deny' ? (raw.safe_summary_key !== 'agent.unknown' || raw.approval_state !== 'durable_denied') : raw.approval_state !== 'deferred') return null;
  return raw as unknown as AgentRoundCallPresentationV3;
}

function roundReceiptMatchesRequest(
  receipt: AgentRoundReceiptV2,
  request: CompleteAgentRoundRequestV2,
): boolean {
  const context = receipt.project_context_receipt;
  return receipt.turn_id === request.task_id &&
    receipt.task_id === request.task_id &&
    receipt.attempt_id === request.attempt_id &&
    receipt.round_id === request.round_id &&
    receipt.round_index === request.round_index &&
    receipt.transport_schema_version === request.transport_schema_version &&
    receipt.requested_model === request.model &&
    receipt.model === request.model &&
    receipt.thinking_mode === request.thinking_mode &&
    // Request authority binds the visible history with the native HJ domain
    // (`visible-history`, {messages}); the receipt records the provider
    // transport's plain canonical-JSON SHA-256. Both are shape-validated at
    // their own boundaries, but they intentionally are not byte-equal.
    (request.project_context_sha256 === null
      ? context === null
      : context !== null && context.snapshot_sha256 === request.project_context_sha256);
}

function validateRoundOutcome(value: unknown, request: CompleteAgentRoundRequestV2): AgentRoundOutcomeV3 | null {
  const raw = ownRecord(value);
  if (raw === null || raw.schema_version !== 3 || !enumValue(raw.kind, ['final', 'tool_batch', 'blocked'] as const)) return null;
  const receipt = validateRoundReceipt(raw.completion_receipt);
  const transcript = validateTranscript(raw.transcript);
  if (receipt === null || transcript === null || !roundReceiptMatchesRequest(receipt, request) || !transcriptRelation(request.transcript, transcript)) return null;
  if (raw.kind === 'final') {
    const final = exact(raw, ['schema_version', 'kind', 'finish_reason', 'completion_receipt', 'transcript', 'text', 'reasoning']);
    return final !== null && final.finish_reason === 'stop' && receipt.finish_reason === 'stop' && typeof final.text === 'string' && typeof final.reasoning === 'string' ? final as unknown as AgentRoundOutcomeV3 : null;
  }
  if (raw.kind === 'blocked') {
    const blocked = exact(raw, ['schema_version', 'kind', 'finish_reason', 'completion_receipt', 'transcript', 'failure_code']);
    return blocked !== null && (blocked.finish_reason === 'length' || blocked.finish_reason === 'content_filter') && receipt.finish_reason === blocked.finish_reason && blocked.failure_code === (blocked.finish_reason === 'length' ? 'E_COMPLETION_LENGTH' : 'E_COMPLETION_CONTENT_FILTER') ? blocked as unknown as AgentRoundOutcomeV3 : null;
  }
  const batch = exact(raw, ['schema_version', 'kind', 'finish_reason', 'completion_receipt', 'transcript', 'calls', 'batch_class', 'executable_call_count', 'denied_call_count', 'reasoning']);
  if (batch === null || batch.finish_reason !== 'tool_calls' || receipt.finish_reason !== 'tool_calls' || typeof batch.reasoning !== 'string' || !enumValue(batch.batch_class, ['executable', 'mixed', 'denied_only'] as const) || !safeInteger(batch.executable_call_count, 16) || !safeInteger(batch.denied_call_count, 16)) return null;
  const callsRaw = arrayValue(batch.calls, 16, 1);
  if (callsRaw === null) return null;
  const calls = callsRaw.map(validateRoundCall);
  if (calls.some(call => call === null)) return null;
  const callIds = new Set<string>();
  for (const call of calls) {
    if (call === null || callIds.has(call.call_id) || !agentToolRegistryCompatible(call.name, request.registry_version)) return null;
    callIds.add(call.call_id);
  }
  if (batch.executable_call_count + batch.denied_call_count !== calls.length ||
    (batch.batch_class === 'executable' && batch.denied_call_count !== 0) ||
    (batch.batch_class === 'denied_only' && (batch.executable_call_count !== 0 || batch.denied_call_count === 0)) ||
    (batch.batch_class === 'mixed' && (batch.executable_call_count === 0 || batch.denied_call_count === 0))) return null;
  const deniedCount = calls.filter(call => call?.access === 'durable_deny').length;
  const expectedClass = deniedCount === 0 ? 'executable' : deniedCount === calls.length ? 'denied_only' : 'mixed';
  if (deniedCount !== batch.denied_call_count || calls.length - deniedCount !== batch.executable_call_count || batch.batch_class !== expectedClass) return null;
  if (calls.some((call, index) => call!.call_index !== index)) return null;
  return { ...batch, completion_receipt: receipt, transcript, calls: calls as AgentRoundCallPresentationV3[] } as unknown as AgentRoundOutcomeV3;
}

function validatePrepareResult(value: unknown, request: PrepareAgentAttemptRequestV2): Exclude<PrepareAgentAttemptResultV2, { status: 'conflict' }> | null {
  const raw = ownRecord(value);
  if (raw === null || raw.status === 'conflict') return null;
  const keys = raw.status === 'prepared' || raw.status === 'already_prepared' || raw.status === 'not_agent'
    ? ['schema_version', 'status', 'operation_id', 'attempt', ...(raw.status === 'not_agent' ? ['failure_code'] : []), 'observed_checkpoint']
    : null;
  if (keys === null || exact(raw, keys) === null || raw.schema_version !== 2 || raw.operation_id !== request.operation_id || !equalCheckpoint(validateCheckpoint(raw.observed_checkpoint)!, validateCheckpoint(request.committed_checkpoint)!)) return null;
  const attempt = validateAttemptProjection(raw.attempt);
  if (attempt === null || attempt.task_id !== request.task_id || attempt.conversation_id !== request.conversation_id || attempt.attempt_id !== request.attempt_id) return null;
  if (raw.status !== 'not_agent' && (request.workspace_id === null
      ? attempt.root !== null || attempt.policy !== null || attempt.transcript !== null
      : attempt.root === null || attempt.root.workspace_id !== request.workspace_id || attempt.root.workspace_binding_revision !== request.workspace_binding_revision || attempt.root.project_id !== request.project_id ||
        (request.project_id === null ? attempt.root.kind !== 'workspace' : attempt.root.kind !== 'project') ||
        (request.expected_transcript !== null && (attempt.transcript === null || !sameTranscript(attempt.transcript, request.expected_transcript))))) return null;
  if (raw.status === 'not_agent') {
    if (raw.failure_code !== 'E_AGENT_NO_ROOT' || attempt.phase !== 'not_agent' || attempt.root !== null || attempt.policy !== null || attempt.transcript !== null || attempt.registry.tools.length !== 0 || attempt.authority_revision !== 0 || attempt.batch.length !== 0 || attempt.batch_kind !== null || attempt.batch_revision !== null || attempt.manifest_sha256 !== null || attempt.reserved_write_bytes !== 0 || attempt.cancel_source_event_id !== null || attempt.cleanup_id !== null) return null;
  } else if (attempt.phase === 'not_agent') return null;
  return { ...raw, attempt, observed_checkpoint: validateCheckpoint(raw.observed_checkpoint)! } as unknown as Exclude<PrepareAgentAttemptResultV2, { status: 'conflict' }>;
}

function validateAttemptProjection(value: unknown): AgentAttemptProjectionV2 | null {
  const raw = exact(value, ['schema_version', 'task_id', 'conversation_id', 'attempt_id', 'phase', 'controller_generation', 'journal_revision', 'authority_revision', 'root', 'policy', 'registry', 'transcript', 'round_index', 'round_id', 'round_revision', 'round_status', 'batch_kind', 'batch_revision', 'manifest_sha256', 'call_index', 'batch', 'frozen_grant_ids', 'reserved_write_bytes', 'cancel_source_event_id', 'cleanup_id']);
  if (raw === null || raw.schema_version !== 2 || !uuid(raw.task_id) || !uuid(raw.conversation_id) || !uuid(raw.attempt_id) || !enumValue(raw.phase, ['not_agent', 'ready_for_round', 'round_in_flight', 'batch_frozen', 'approval_pending', 'execution_intent', 'tool_result_pending', 'final_response', 'cancelled', 'failed', 'unknown', 'ambiguous'] as const) || !safeInteger(raw.controller_generation) || !safeInteger(raw.journal_revision) || !safeInteger(raw.authority_revision) || !safeInteger(raw.round_index, 7) || !nullableUuid(raw.round_id) || (raw.round_revision !== null && !safeInteger(raw.round_revision, Number.MAX_SAFE_INTEGER - 1, false)) || (raw.round_status !== null && !enumValue(raw.round_status, ['ready', 'active', 'failed_retryable', 'completed', 'cancel_requested', 'cancelled', 'unknown', 'ambiguous'] as const)) || (raw.batch_kind !== null && !enumValue(raw.batch_kind, ['write_batch', 'read_only_batch'] as const)) || (raw.batch_revision !== null && !safeInteger(raw.batch_revision, Number.MAX_SAFE_INTEGER - 1, false)) || !nullableDigest(raw.manifest_sha256) || (raw.call_index !== null && !safeInteger(raw.call_index, 15)) || !safeInteger(raw.reserved_write_bytes, 4194304) || !nullableUuid(raw.cancel_source_event_id) || !nullableUuid(raw.cleanup_id)) return null;
  const root = raw.root === null ? null : validateRoot(raw.root);
  const policy = raw.policy === null ? null : validatePolicy(raw.policy);
  const registry = validateRegistry(raw.registry);
  const transcript = raw.transcript === null ? null : validateTranscript(raw.transcript);
  const batch = arrayValue(raw.batch, 16)?.map(validateBatchCall);
  const grants = copyStringArray(raw.frozen_grant_ids, 2, uuid);
  if (registry === null || batch === undefined || batch.some(call => call === null) || grants === null || (raw.root !== null && root === null) || (raw.policy !== null && policy === null) || (raw.transcript !== null && transcript === null)) return null;
  const calls = batch as AgentBatchCallProjectionV2[];
  const callIds = new Set<string>();
  for (const [index, call] of calls.entries()) {
    if (call.call_index !== index || callIds.has(call.call_id) || !agentToolRegistryCompatible(call.name, registry.registry_version)) return null;
    callIds.add(call.call_id);
  }
  if (raw.round_id === null && (raw.round_revision !== null || raw.round_status !== null)) return null;
  if (raw.round_id !== null && (raw.round_status === null || (raw.round_revision === null && raw.round_status !== 'ready'))) return null;
  const allowedLineage: Record<string, readonly string[] | null> = {
    not_agent: null,
    ready_for_round: ['ready'],
    round_in_flight: ['active', 'cancel_requested'],
    batch_frozen: ['completed'],
    approval_pending: ['completed'],
    execution_intent: ['completed', 'cancel_requested'],
    tool_result_pending: ['completed'],
    final_response: ['completed'],
    cancelled: ['completed', 'cancelled'],
    failed: ['completed', 'failed_retryable'],
    unknown: ['unknown'],
    ambiguous: ['ambiguous'],
  };
  const allowedStatuses = allowedLineage[raw.phase];
  if (raw.phase === 'ready_for_round') {
    if (raw.round_status !== null && raw.round_status !== 'ready') return null;
  } else if (raw.phase === 'cancelled' && raw.round_id === null && raw.round_status === null) {
    if (raw.round_index !== 0 || raw.round_revision !== null || calls.length !== 0 ||
        raw.call_index !== null || raw.reserved_write_bytes !== 0) return null;
  } else if (allowedStatuses === null || allowedStatuses === undefined || raw.round_status === null || !allowedStatuses.includes(raw.round_status)) return null;
  if (raw.batch_kind === null && (raw.batch_revision !== null || raw.manifest_sha256 !== null || calls.length !== 0)) return null;
  if (raw.batch_kind === 'write_batch' && (raw.batch_revision === null || raw.manifest_sha256 === null)) return null;
  if (raw.batch_kind === 'read_only_batch' && (raw.batch_revision === null || raw.manifest_sha256 !== null)) return null;
  if (raw.call_index !== null && raw.call_index >= calls.length) return null;
  if (raw.phase === 'not_agent') {
    if (root !== null || policy !== null || transcript !== null || registry.tools.length !== 0 || raw.authority_revision !== 0 || raw.round_id !== null || raw.batch_kind !== null || raw.reserved_write_bytes !== 0 || calls.length !== 0 || raw.cancel_source_event_id !== null) return null;
  } else if (root === null || policy === null || transcript === null || (raw.authority_revision === 0 && raw.phase !== 'ready_for_round')) return null;
  return { ...raw, root, policy, registry, transcript, batch: calls, frozen_grant_ids: grants } as unknown as AgentAttemptProjectionV2;
}

function boundedUTF8(value: unknown, maximum: number, allowEmpty = false): value is string {
  if (typeof value !== 'string' || (!allowEmpty && value.length === 0)) return false;
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit <= 0x7f) bytes += 1;
    else if (unit <= 0x7ff) bytes += 2;
    else if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return false;
      bytes += 4;
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false;
    else bytes += 3;
  }
  return bytes <= maximum;
}

function previewPath(value: unknown): value is string {
  if (typeof value !== 'string' || value.length === 0 ||
      !boundedUTF8(value, 512) || value.startsWith('/') ||
      value.includes('\\') || value.includes('\u0000')) return false;
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
  const raw = exact(value, ['schema_version', 'kind', 'paths', 'content_bytes', 'prior', 'diff_preview', 'diff_truncated']);
  if (raw === null || raw.schema_version !== 1 || !enumValue(raw.kind, ['list_dir', 'read_file', 'write_file', 'git_commit', 'git_push', 'start_guest_cgi', 'stop_guest_cgi', 'list_runtime_environments', 'install_runtime_environment', 'run_program', 'start_runtime_service', 'stop_runtime_service'] as const)) return null;
  const paths = copyStringArray(raw.paths, 8, previewPath);
  if (paths === null ||
    (raw.content_bytes !== null && !safeInteger(raw.content_bytes, 32768)) || typeof raw.diff_truncated !== 'boolean' ||
    (raw.diff_preview !== null && !boundedUTF8(raw.diff_preview, 4096, true))) return null;
  let prior: AgentApprovalPreviewV1['prior'];
  if (raw.prior === null) prior = null;
  else {
    const record = exact(raw.prior, ['schema_version', 'kind', 'bytes']);
    if (record === null || record.schema_version !== 1 || !enumValue(record.kind, ['absent', 'known'] as const) ||
      (record.bytes !== null && !safeInteger(record.bytes, 65536))) return null;
    prior = record as unknown as AgentApprovalPreviewV1['prior'];
  }
  if (raw.kind === 'write_file') {
    if (paths.length !== 1 || raw.content_bytes === null || prior === null) return null;
  } else if (raw.kind === 'git_commit' || raw.kind === 'git_push') {
    if (paths.length !== 0 || raw.content_bytes !== null || prior !== null || raw.diff_preview !== null) return null;
  } else if (raw.kind === 'start_guest_cgi') {
    if (((paths.length !== 2 && paths.length !== 3) &&
         !(allowLegacyGuestCgiEmpty && paths.length === 0)) ||
        raw.content_bytes !== null || prior !== null || raw.diff_preview !== null) return null;
  } else if (isRuntimeAgentTool(raw.kind)) {
    const expectedPaths = raw.kind === 'run_program' || raw.kind === 'start_runtime_service' ? 1 : 0;
    if (paths.length !== expectedPaths || raw.content_bytes !== null || prior !== null || raw.diff_preview !== null || raw.diff_truncated) return null;
  } else if (raw.kind === 'stop_guest_cgi') {
    if (paths.length !== 0 || raw.content_bytes !== null || prior !== null || raw.diff_preview !== null) return null;
  } else if (raw.content_bytes !== null || prior !== null || raw.diff_preview !== null) return null;
  return { ...raw, paths, prior } as unknown as AgentApprovalPreviewV1;
}

function validateBatchCall(value: unknown): AgentBatchCallProjectionV2 | null {
  // `approval_preview` is tolerated as absent so evidence produced by
  // older callers still validates; the native bridge always supplies it.
  // Mapped evidence is re-validated at the reducer boundary, so the
  // validator must also accept its own output: the key set is the 16-key
  // base plus at most one bounded `approval_preview`.
  const record = ownRecord(value);
  if (record === null) return null;
  const names = Object.keys(record);
  const allowedKeys = new Set([
    'schema_version', 'call_index', 'call_id', 'name', 'arguments_sha256',
    'idempotency_key', 'safe_summary_key', 'access', 'approval_state',
    'approval_token', 'approval_reference', 'execution_status',
    'execution_revision', 'native_row_revision', 'receipt',
    'approval_preview',
  ]);
  if (
    names.length < 15 ||
    names.length > 16 ||
    names.some(key => !allowedKeys.has(key))
  ) return null;
  const raw = record;
  if (raw.schema_version !== 2 || !safeInteger(raw.call_index, 15) || !opaque(raw.call_id) || !name(raw.name) || !digest(raw.arguments_sha256) || !nullableDigest(raw.idempotency_key) || !name(raw.safe_summary_key) || !SAFE_SUMMARY.has(raw.safe_summary_key) || !enumValue(raw.access, ['auto', 'conversation_confirm', 'confirm_once', 'durable_deny'] as const) || !enumValue(raw.approval_state, ['not_required', 'pending', 'bound', 'denied', 'cancelled'] as const) || !enumValue(raw.execution_status, ['not_started', 'intent', 'running', 'cancel_requested', 'completed', 'failed', 'denied', 'cancelled', 'unknown', 'ambiguous'] as const) || (raw.execution_revision !== null && !safeInteger(raw.execution_revision, Number.MAX_SAFE_INTEGER - 1, false)) || (raw.native_row_revision !== null && !safeInteger(raw.native_row_revision, Number.MAX_SAFE_INTEGER - 1, false)) || (raw.receipt !== null && validateReceipt(raw.receipt) === null) || !nullableUuid(raw.approval_reference)) return null;
  const knownTool = TOOL_NAMES.has(raw.name);
  const expected = knownTool ? expectedAccess(raw.name) : 'durable_deny';
  if (raw.access !== expected || raw.safe_summary_key !== (knownTool ? `agent.${raw.name}` : 'agent.unknown')) return null;
  const token = raw.approval_token === null ? null : validateApprovalToken(raw.approval_token);
  if (raw.approval_token !== null && token === null) return null;
  const receipt = raw.receipt === null ? null : validateReceipt(raw.receipt);
  if (raw.access === 'durable_deny' && (raw.approval_state !== 'denied' || raw.idempotency_key !== null || token !== null || raw.approval_reference !== null || raw.execution_revision !== null || raw.execution_status !== 'denied' || (receipt !== null && (receipt.outcome !== 'denied' || receipt.call_id !== raw.call_id || receipt.name !== raw.name || receipt.arguments_sha256 !== raw.arguments_sha256 || receipt.approval_reference !== null || (receipt.failure_code !== 'E_AGENT_UNKNOWN_TOOL' && receipt.failure_code !== 'E_AGENT_CAPABILITY'))) || (receipt === null ? raw.native_row_revision !== null : raw.native_row_revision !== 1))) return null;
  if (raw.access === 'auto' && (raw.approval_state !== 'not_required' || token !== null || raw.approval_reference !== null)) return null;
  if (raw.approval_state === 'not_required' && raw.access !== 'auto') return null;
  if (raw.access !== 'durable_deny' && raw.approval_state === 'pending' && raw.access !== 'conversation_confirm' && raw.access !== 'confirm_once') return null;
  if (raw.approval_state === 'pending' && raw.approval_reference !== null) return null;
  // Native grant reuse has no newly issued token. This only validates its
  // shape; Store checkpoints and hydration require the referenced live grant
  // to match the conversation, frozen root, registry, policy, and tool family.
  if (raw.approval_state === 'bound' && (raw.approval_reference === null || raw.access === 'auto' || raw.access === 'durable_deny' || (token === null && (raw.access !== 'conversation_confirm' || agentToolGrantFamily(raw.name) === null || raw.native_row_revision === null)) || raw.idempotency_key === null)) return null;
  if ((raw.approval_state === 'denied' || raw.approval_state === 'cancelled') && (token !== null || raw.approval_reference !== null || raw.access === 'auto')) return null;
  if (token !== null && (token.call_index !== raw.call_index || token.call_id !== raw.call_id || token.name !== raw.name || token.arguments_sha256 !== raw.arguments_sha256 || token.access !== raw.access || token.idempotency_key !== raw.idempotency_key)) return null;
  if (receipt !== null && (receipt.call_id !== raw.call_id || receipt.name !== raw.name || receipt.arguments_sha256 !== raw.arguments_sha256 || receipt.approval_reference !== raw.approval_reference || receipt.outcome === 'ok' && receipt.failure_code !== null || receipt.outcome !== 'ok' && receipt.failure_code === null)) return null;
  if (raw.access !== 'durable_deny') {
    // A public post-preparation receipt is only actionable after native has
    // derived both the idempotency key and the intent revision.  An
    // unassigned call is a provider-round projection, not a batch receipt.
    if (raw.idempotency_key === null || raw.execution_revision === null || raw.execution_status === 'not_started') return null;
  }
  if (raw.execution_status === 'not_started' && (raw.receipt !== null || raw.native_row_revision !== null)) return null;
  if (['intent', 'running', 'cancel_requested', 'unknown'].includes(raw.execution_status) && (raw.execution_revision === null || receipt !== null)) return null;
  if (['completed', 'failed', 'cancelled', 'ambiguous'].includes(raw.execution_status) && (raw.execution_revision === null || receipt === null)) return null;
  if (raw.execution_status === 'denied' && raw.access !== 'durable_deny' && (raw.execution_revision === null || receipt === null)) return null;
  if (receipt !== null && raw.native_row_revision === null) return null;
  if (raw.execution_status === 'completed' && receipt?.outcome !== 'ok') return null;
  if (raw.execution_status === 'failed' && receipt?.outcome !== 'failed') return null;
  if (raw.execution_status === 'denied' && receipt?.outcome !== 'denied') return null;
  if (raw.execution_status === 'cancelled' && receipt?.outcome !== 'cancelled') return null;
  if (raw.execution_status === 'ambiguous' && receipt?.outcome !== 'ambiguous') return null;
  if (raw.execution_status === 'unknown' && receipt !== null) return null;
  const preview =
    raw.approval_preview === undefined || raw.approval_preview === null
      ? null
      : validateApprovalPreview(
          raw.approval_preview,
          raw.name === 'start_guest_cgi' && token?.registry_version === 2,
        );
  if (
    raw.approval_preview !== undefined &&
    raw.approval_preview !== null &&
    preview === null
  ) return null;
  return { ...raw, approval_token: token, receipt, approval_preview: preview } as unknown as AgentBatchCallProjectionV2;
}


function validateResultReceipt(value: unknown, identity: { call_id: string; name: string; arguments_sha256: string; approval_reference: string | null }): AgentToolReceiptV1 | null {
  const receipt = validateReceipt(value);
  return receipt !== null && receipt.call_id === identity.call_id && receipt.name === identity.name && receipt.arguments_sha256 === identity.arguments_sha256 && receipt.approval_reference === identity.approval_reference ? receipt : null;
}

function validateCompleteResult(value: unknown, request: CompleteAgentRoundRequestV2): Exclude<CompleteAgentRoundResultV2, { status: 'conflict' }> | null {
  const raw = ownRecord(value);
  if (raw === null || raw.status === 'conflict' || !enumValue(raw.status, ['completed', 'in_flight', 'failed_retryable', 'cancelled', 'unknown', 'ambiguous'] as const)) return null;
  const commonKeys = ['schema_version', 'status', 'operation_id', 'task_id', 'attempt_id', 'round_id', 'round_index', 'launch_attempt', 'result_round_revision', 'transcript'];
  // `in_flight` is the one live result branch and has no failure_code. Keep
  // the result union exact instead of accepting an optional/nullable key.
  const keys = raw.status === 'completed'
    ? [...commonKeys, 'outcome']
    : raw.status === 'in_flight'
      ? commonKeys
      : [...commonKeys, 'failure_code'];
  if (exact(raw, keys) === null || raw.schema_version !== 2 || raw.operation_id !== request.operation_id || raw.task_id !== request.task_id || raw.attempt_id !== request.attempt_id || raw.round_id !== request.round_id || raw.round_index !== request.round_index || raw.launch_attempt !== request.launch_attempt || !resultRoundRevisionMatches(request.expected_round_revision, raw.result_round_revision as number)) return null;
  const transcript = validateTranscript(raw.transcript);
  if (transcript === null || !transcriptRelation(request.transcript, transcript)) return null;
  if (raw.status === 'completed') {
    const outcome = validateRoundOutcome(raw.outcome, request);
    return outcome === null || !sameTranscript(transcript, outcome.transcript) ? null : { ...raw, transcript, outcome } as unknown as Exclude<CompleteAgentRoundResultV2, { status: 'conflict' }>;
  }
  if (raw.status === 'unknown' && !safeFailureCode(raw.failure_code)) return null;
  if (raw.status === 'ambiguous' && raw.failure_code !== 'E_AGENT_ROUND_AMBIGUOUS') return null;
  if (raw.status === 'cancelled' && raw.failure_code !== 'E_AGENT_CANCELLED') return null;
  if (raw.status === 'in_flight' && raw.failure_code !== undefined) return null;
  if (raw.status !== 'in_flight' && !safeFailureCode(raw.failure_code)) return null;
  return { ...raw, transcript } as unknown as Exclude<CompleteAgentRoundResultV2, { status: 'conflict' }>;
}


function validateBatchResult(value: unknown, request: PrepareAgentToolBatchRequestV2): Exclude<PrepareAgentToolBatchResultV2, { status: 'conflict' }> | null {
  const raw = ownRecord(value);
  if (raw === null || raw.status === 'conflict' || (raw.status !== 'prepared' && raw.status !== 'already_prepared' && raw.status !== 'rejected')) return null;
  if (raw.status === 'rejected') {
    const result = exact(raw, ['schema_version', 'status', 'operation_id', 'failure_code', 'expected_batch_revision', 'expected_reserved_write_bytes', 'result_reserved_write_bytes', 'effect_gate', 'reservation_status', 'effect_dispatched', 'retry_advice']);
    if (result === null || result.schema_version !== 2 || result.operation_id !== request.operation_id ||
      !enumValue(result.failure_code, ['E_AGENT_BAD_ARGUMENTS', 'E_AGENT_BAD_PATH', 'E_AGENT_CAPABILITY', 'E_AGENT_CONFLICT', 'E_AGENT_CAPACITY', 'E_AGENT_LEDGER', 'E_AGENT_PERSISTENCE', 'E_AGENT_ROOT_STALE', 'E_AGENT_ROUND_LIMIT'] as const) ||
      result.expected_batch_revision !== request.expected_batch_revision ||
      result.expected_reserved_write_bytes !== request.expected_reserved_write_bytes ||
      !safeInteger(result.result_reserved_write_bytes, 4194304) ||
      result.result_reserved_write_bytes !== request.expected_reserved_write_bytes ||
      !enumValue(result.effect_gate, ['closed', 'not_applicable'] as const) ||
      result.reservation_status !== 'unchanged' || result.effect_dispatched !== false ||
      !enumValue(result.retry_advice, ['none', 'requery', 'wait_for_reconciliation'] as const)) return null;
    const expectedAdvice = result.failure_code === 'E_AGENT_CAPACITY' || result.failure_code === 'E_AGENT_LEDGER'
      || result.failure_code === 'E_AGENT_PERSISTENCE'
      ? 'wait_for_reconciliation'
      : result.failure_code === 'E_AGENT_CONFLICT' || result.failure_code === 'E_AGENT_ROOT_STALE'
        ? 'requery'
        : 'none';
    if (result.retry_advice !== expectedAdvice) return null;
    return result as unknown as Exclude<PrepareAgentToolBatchResultV2, { status: 'conflict' }>;
  }
  const result = exact(raw, ['schema_version', 'status', 'operation_id', 'receipt', 'observed_checkpoint']);
  if (result === null || result.schema_version !== 2 || result.operation_id !== request.operation_id) return null;
  const receipt = validateBatchReceipt(result.receipt, request);
  const observed = validateCheckpoint(result.observed_checkpoint);
  return receipt !== null && observed !== null && equalCheckpoint(observed, validateCheckpoint(request.committed_checkpoint)!) ? { ...result, receipt, observed_checkpoint: observed } as unknown as Exclude<PrepareAgentToolBatchResultV2, { status: 'conflict' }> : null;
}

function validateBatchReceipt(value: unknown, request: PrepareAgentToolBatchRequestV2): AgentBatchReceiptV2 | null {
  const raw = exact(value, ['schema_version', 'task_id', 'attempt_id', 'round_id', 'round_index', 'batch_kind', 'batch_revision', 'manifest_sha256', 'transcript', 'calls', 'batch_new_write_bytes', 'reserved_write_bytes', 'effect_gate']);
  if (raw === null || raw.schema_version !== 2 || raw.task_id !== request.task_id || raw.attempt_id !== request.attempt_id || raw.round_id !== request.round_id || raw.round_index !== request.round_index || !enumValue(raw.batch_kind, ['write_batch', 'read_only_batch'] as const) || !safeInteger(raw.batch_revision, Number.MAX_SAFE_INTEGER - 1, false) || !nullableDigest(raw.manifest_sha256) || (raw.batch_kind === 'write_batch' && raw.manifest_sha256 === null) || (raw.batch_kind === 'read_only_batch' && raw.manifest_sha256 !== null) || !safeInteger(raw.batch_new_write_bytes, 4194304) || !safeInteger(raw.reserved_write_bytes, 4194304) || !enumValue(raw.effect_gate, ['closed', 'not_applicable'] as const)) return null;
  const transcript = validateTranscript(raw.transcript);
  const calls = arrayValue(raw.calls, 16)?.map(validateBatchCall);
  if (transcript === null || calls === undefined || calls.length < 1 || calls.some(call => call === null) || calls.some((call, index) => call!.call_index !== index)) return null;
  // Read-only batches use the round revision; writes use the independent
  // native reservation revision. Crossing from reads to writes may decrease
  // the value. Native validates the prior authority atomically; here bind the
  // returned positive authority to the exact receipt/token/CAS below.
  if (raw.batch_kind === 'read_only_batch' &&
      raw.batch_revision !== request.expected_round_revision) return null;
  if (!transcriptRelation(request.transcript, transcript)) return null;
  for (const call of calls as AgentBatchCallProjectionV2[]) {
    if (!rootCanUse(request.root, call.name) || !agentToolRegistryCompatible(call.name, request.registry_version)) return null;
    const token = call.approval_token;
    if (token !== null && (
      !sameControllerCAS(token.controller_cas, request.controller_cas) ||
      token.task_id !== request.task_id || token.attempt_id !== request.attempt_id ||
      token.round_id !== request.round_id || token.round_index !== request.round_index ||
      token.batch_revision !== raw.batch_revision || token.manifest_sha256 !== raw.manifest_sha256 ||
      token.root_fingerprint_sha256 !== request.root.root_fingerprint_sha256 ||
      token.binding_revision !== request.root.workspace_binding_revision
    )) return null;
  }
  const tokenCalls = (calls as AgentBatchCallProjectionV2[]).filter(call => call.approval_token !== null).map(call => call.approval_token!);
  for (const token of tokenCalls) {
    if (!sameStringArray(token.batch_call_ids, (calls as AgentBatchCallProjectionV2[]).map(call => call.call_id)) ||
      !sameStringArray(token.batch_arguments_sha256, (calls as AgentBatchCallProjectionV2[]).map(call => call.arguments_sha256))) return null;
  }
  // A call settled at preparation (refused arguments) never reaches the
  // write manifest, so only calls still awaiting execution decide the kind.
  const hasMutation = calls.some(
    call =>
      call!.receipt === null && (
        (ALL_AGENT_CONFIRM_TOOLS as readonly string[]).includes(call!.name)),
  );
  if (
    (raw.batch_kind === 'write_batch' &&
      (!hasMutation || raw.manifest_sha256 === null || raw.effect_gate !== 'closed')) ||
    (raw.batch_kind === 'read_only_batch' &&
      (hasMutation || raw.manifest_sha256 !== null || raw.effect_gate !== 'not_applicable' ||
        raw.batch_new_write_bytes !== 0 ||
        raw.reserved_write_bytes !== request.expected_reserved_write_bytes)) ||
    (raw.batch_kind === 'write_batch' &&
      raw.reserved_write_bytes !==
        request.expected_reserved_write_bytes + raw.batch_new_write_bytes) ||
    raw.reserved_write_bytes < raw.batch_new_write_bytes ||
    (raw.batch_kind === 'read_only_batch' && raw.batch_revision !== request.expected_round_revision)
  ) return null;
  return {
    schema_version: 2,
    task_id: raw.task_id,
    attempt_id: raw.attempt_id,
    round_id: raw.round_id,
    round_index: raw.round_index,
    batch_kind: raw.batch_kind,
    batch_revision: raw.batch_revision,
    manifest_sha256: raw.manifest_sha256,
    transcript,
    calls: calls as AgentBatchCallProjectionV2[],
    batch_new_write_bytes: raw.batch_new_write_bytes,
    reserved_write_bytes: raw.reserved_write_bytes,
    effect_gate: raw.effect_gate,
  };
}

function validateBindResult(value: unknown, request: BindAgentApprovalRequestV2): Exclude<BindAgentApprovalResultV2, { status: 'conflict' }> | null {
  const raw = ownRecord(value);
  if (raw === null || raw.status === 'conflict' || (raw.status !== 'bound' && raw.status !== 'already_bound')) return null;
  // `receipt`/`transcript` are tolerated as absent (older evidence) and
  // default to null; a denied decision still requires the real settlement.
  // Mapped evidence is re-validated at the reducer boundary, so the
  // validator must also accept its own output: the 13-key base plus at most
  // the two denial-settlement keys.
  const names = Object.keys(raw);
  const allowedKeys = new Set([
    'schema_version', 'status', 'operation_id', 'task_id', 'attempt_id',
    'round_id', 'call_index', 'call_id', 'decision', 'approval_reference',
    'grant', 'result_batch_revision', 'observed_checkpoint', 'receipt',
    'transcript',
  ]);
  if (
    names.length < 13 ||
    names.length > 15 ||
    names.some(key => !allowedKeys.has(key))
  ) return null;
  const result = raw;
  if (result.schema_version !== 2 || result.operation_id !== request.operation_id || result.task_id !== request.task_id || result.attempt_id !== request.attempt_id || result.round_id !== request.round_id || result.call_index !== request.call_index || result.call_id !== request.call_id || result.decision !== request.decision || !nullableUuid(result.approval_reference) || !safeInteger(result.result_batch_revision, Number.MAX_SAFE_INTEGER - 1, false) || result.result_batch_revision !== request.batch_revision) return null;
  const observed = validateCheckpoint(result.observed_checkpoint);
  if (observed === null || !equalCheckpoint(observed, validateCheckpoint(request.committed_checkpoint)!)) return null;
  const grant = result.grant === null ? null : validateGrant(result.grant);
  if (result.grant !== null && grant === null) return null;
  if ((request.decision === 'allow_conversation') !== (grant !== null)) return null;
  if ((request.decision === 'denied' || request.decision === 'cancelled') && result.approval_reference !== null) return null;
  if ((request.decision === 'allow_once' || request.decision === 'allow_conversation') && result.approval_reference === null) return null;
  if (grant !== null && (grant.conversation_id !== request.conversation_id || grant.issued_for.task_id !== request.task_id || grant.issued_for.attempt_id !== request.attempt_id || grant.root_fingerprint_sha256 !== request.token.root_fingerprint_sha256 || grant.binding_revision !== request.token.binding_revision || grant.registry_version !== request.token.registry_version || grant.policy_version !== request.token.policy_version || grant.tool_family !== expectedToolFamily(request.token.name))) return null;
  const rawReceipt = result.receipt ?? null;
  const rawTranscript = result.transcript ?? null;
  const deniedReceipt = rawReceipt === null ? null : validateReceipt(rawReceipt);
  if (rawReceipt !== null && deniedReceipt === null) return null;
  const deniedTranscript = rawTranscript === null ? null : validateTranscript(rawTranscript);
  if (rawTranscript !== null && deniedTranscript === null) return null;
  if (request.decision === 'denied') {
    if (deniedReceipt === null || deniedTranscript === null || deniedReceipt.outcome !== 'denied' || deniedReceipt.failure_code !== 'E_AGENT_DENIED_BY_USER' || deniedReceipt.approval_reference !== null || deniedReceipt.call_id !== request.call_id || deniedReceipt.name !== request.token.name || deniedReceipt.arguments_sha256 !== request.token.arguments_sha256) return null;
  } else if (deniedReceipt !== null || deniedTranscript !== null) return null;
  return { ...result, grant, observed_checkpoint: observed, receipt: deniedReceipt, transcript: deniedTranscript } as unknown as Exclude<BindAgentApprovalResultV2, { status: 'conflict' }>;
}

function validateGrant(value: unknown): AgentConversationGrantV2 | null {
  const raw = exact(value, ['schema_version', 'grant_id', 'conversation_id', 'workspace_id', 'project_id', 'binding_revision', 'root_fingerprint_sha256', 'tool_family', 'registry_version', 'policy_version', 'issued_for', 'created_at']);
  if (raw === null || raw.schema_version !== 2 || !uuid(raw.grant_id) || !uuid(raw.conversation_id) || !uuid(raw.workspace_id) || !nullableUuid(raw.project_id) || !safeInteger(raw.binding_revision, Number.MAX_SAFE_INTEGER - 1, false) || !digest(raw.root_fingerprint_sha256) || !enumValue(raw.tool_family, ['file_write', 'git_commit', 'git_push', 'guest_service'] as const) || !isAgentRegistryVersion(raw.registry_version) || (raw.tool_family === 'guest_service' && raw.registry_version === 1) || raw.policy_version !== 'agent-v1' || !timestamp(raw.created_at)) return null;
  const issued = exact(raw.issued_for, ['schema_version', 'task_id', 'attempt_id']);
  return issued !== null && issued.schema_version === 1 && uuid(issued.task_id) && uuid(issued.attempt_id) ? raw as unknown as AgentConversationGrantV2 : null;
}

function validateExecuteResult(value: unknown, request: ExecuteAgentToolRequestV2): Exclude<ExecuteAgentToolResultV2, { status: 'conflict' }> | null {
  const raw = ownRecord(value);
  if (raw === null || raw.status === 'conflict' || !enumValue(raw.status, ['completed', 'failed', 'denied', 'cancelled', 'running', 'cancel_requested', 'unknown', 'ambiguous'] as const)) return null;
  const keys = raw.status === 'running' || raw.status === 'cancel_requested' || raw.status === 'unknown' || raw.status === 'ambiguous'
    ? ['schema_version', 'status', 'operation_id', 'task_id', 'attempt_id', 'round_id', 'round_index', 'call_index', 'call_id', 'name', 'idempotency_key', 'result_execution_revision', 'transcript', 'receipt', 'effect_may_have_occurred', ...((raw.status === 'unknown' || raw.status === 'ambiguous') ? ['failure_code'] : [])]
    : ['schema_version', 'status', 'operation_id', 'task_id', 'attempt_id', 'round_id', 'round_index', 'call_index', 'call_id', 'name', 'idempotency_key', 'result_execution_revision', 'transcript', 'receipt', 'effect_may_have_occurred'];
  if (exact(raw, keys) === null || raw.schema_version !== 2 || raw.operation_id !== request.operation_id || raw.task_id !== request.task_id || raw.attempt_id !== request.attempt_id || raw.round_id !== request.round_id || raw.round_index !== request.round_index || raw.call_index !== request.call_index || raw.call_id !== request.call_id || raw.name !== request.name || raw.idempotency_key !== request.idempotency_key || !safeInteger(raw.result_execution_revision, Number.MAX_SAFE_INTEGER - 1, false) || typeof raw.effect_may_have_occurred !== 'boolean') return null;
  const transcript = validateTranscript(raw.transcript);
  if (transcript === null || !transcriptRelation(request.transcript, transcript)) return null;
  if (raw.status === 'running' || raw.status === 'cancel_requested' || raw.status === 'unknown') {
    if (raw.status === 'unknown' && raw.failure_code !== 'E_AGENT_EXECUTION_AMBIGUOUS' && raw.failure_code !== 'E_AGENT_LEDGER') return null;
    if (!resultExecutionRevisionMatches(request.expected_execution_revision, raw.result_execution_revision as number) || raw.receipt !== null || (raw.status === 'unknown' && raw.effect_may_have_occurred !== false)) return null;
    return { ...raw, transcript } as unknown as Exclude<ExecuteAgentToolResultV2, { status: 'conflict' }>;
  }
  if (raw.status === 'ambiguous' && raw.failure_code !== 'E_AGENT_EXECUTION_AMBIGUOUS') return null;
  if (!resultExecutionRevisionMatches(request.expected_execution_revision, raw.result_execution_revision as number)) return null;
  const receipt = validateResultReceipt(raw.receipt, { call_id: request.call_id, name: request.name, arguments_sha256: request.arguments_sha256, approval_reference: request.approval_reference });
  if (receipt === null || receipt.outcome !== (raw.status === 'completed' ? 'ok' : raw.status) || (raw.status === 'cancelled' && raw.effect_may_have_occurred !== false) || (raw.status === 'denied' && raw.effect_may_have_occurred !== false) || (raw.status === 'ambiguous' && raw.effect_may_have_occurred !== true)) return null;
  return { ...raw, transcript, receipt } as unknown as Exclude<ExecuteAgentToolResultV2, { status: 'conflict' }>;
}

function validateCancelResult(value: unknown, request: CancelAgentAttemptRequestV2): Exclude<CancelAgentAttemptResultV2, { status: 'conflict' }> | null {
  const raw = ownRecord(value);
  if (raw === null || raw.status === 'conflict' || !enumValue(raw.status, ['cancel_requested', 'cancelled', 'already_cancelled', 'settled', 'unknown', 'ambiguous'] as const)) return null;
  const result = exact(raw, ['schema_version', 'status', 'operation_id', 'target', 'result_round_revision', 'result_execution_revision', 'transcript', 'receipt', 'effect_may_have_occurred', ...(raw.status === 'settled' || raw.status === 'unknown' || raw.status === 'ambiguous' ? ['failure_code'] : []), 'observed_checkpoint']);
  const target = result === null ? null : validateCancelTarget(result.target);
  if (result === null || result.schema_version !== 2 || result.operation_id !== request.operation_id || target === null || !equalTarget(target, request.target) || !nullableRevision(result.result_round_revision) || !nullableRevision(result.result_execution_revision) || typeof result.effect_may_have_occurred !== 'boolean') return null;
  const observed = validateCheckpoint(result.observed_checkpoint);
  const transcript = validateTranscript(result.transcript);
  const requestCheckpoint = validateCheckpoint(request.committed_checkpoint);
  if (observed === null || transcript === null || requestCheckpoint === null || !equalCheckpoint(observed, requestCheckpoint) || !transcriptRelation(request.expected_transcript, transcript) || !resultTargetRevisionsMatch(target, request, result.result_round_revision, result.result_execution_revision)) return null;
  const receipt = result.receipt === null ? null : validateReceipt(result.receipt);
  if (result.receipt !== null && receipt === null) return null;
  if (receipt !== null && (target.kind !== 'tool' || receipt.call_id !== target.call_id)) return null;
  if ((result.status === 'cancel_requested' && target.kind === 'attempt') ||
    ((result.status === 'cancelled' || result.status === 'already_cancelled') && result.effect_may_have_occurred)) return null;
  if (result.status === 'cancelled' || result.status === 'already_cancelled') {
    if (target.kind === 'tool' && (receipt === null || receipt.outcome !== 'cancelled')) return null;
    if (target.kind !== 'tool' && receipt !== null) return null;
  }
  if (result.status === 'settled') {
    if (target.kind !== 'tool' || receipt === null || !safeFailureCode(result.failure_code) || (receipt.outcome !== 'ok' && receipt.failure_code === null)) return null;
  }
  if (result.status === 'unknown' && (receipt !== null || !runtimeFailureCode(result.failure_code))) return null;
  if (result.status === 'ambiguous' && (target.kind !== 'tool' || receipt === null || receipt.outcome !== 'ambiguous' || receipt.failure_code !== 'E_AGENT_EXECUTION_AMBIGUOUS' || result.failure_code !== 'E_AGENT_EXECUTION_AMBIGUOUS' || result.effect_may_have_occurred !== true)) return null;
  return { ...result, observed_checkpoint: observed, transcript, target, receipt } as unknown as Exclude<CancelAgentAttemptResultV2, { status: 'conflict' }>;
}

function nullableRevision(value: unknown): value is number | null {
  return value === null || safeInteger(value, Number.MAX_SAFE_INTEGER - 1, false);
}

function equalTarget(left: AgentCancelTargetV2, right: AgentCancelTargetV2): boolean {
  if (left.schema_version !== right.schema_version || left.kind !== right.kind || left.task_id !== right.task_id || left.attempt_id !== right.attempt_id) return false;
  if (left.kind === 'attempt' || right.kind === 'attempt') return left.kind === right.kind;
  if (left.round_id !== right.round_id || left.round_index !== right.round_index) return false;
  if (left.kind === 'round' || right.kind === 'round') return left.kind === right.kind;
  return left.call_index === right.call_index && left.call_id === right.call_id && left.idempotency_key === right.idempotency_key;
}

function resultTargetRevisionsMatch(
  target: AgentCancelTargetV2,
  request: CancelAgentAttemptRequestV2,
  roundRevision: number | null,
  executionRevision: number | null,
): boolean {
  if (!targetRevisionRelation(target, roundRevision, executionRevision)) return false;
  if (target.kind === 'attempt') return true;
  if (target.kind === 'round') return request.expected_round_revision !== null && roundRevision !== null && resultRoundRevisionMatches(request.expected_round_revision, roundRevision);
  return request.expected_execution_revision !== null && executionRevision !== null && resultExecutionTargetRevisionMatches(request.expected_execution_revision, executionRevision);
}

function attemptMatchesRecoveryTarget(
  attempt: AgentAttemptProjectionV2,
  target: AgentRecoveryTargetV2,
  request: RecoverAgentAttemptRequestV2,
): boolean {
  if (attempt.phase === 'not_agent' || attempt.root === null || attempt.policy === null || attempt.transcript === null || !sameRoot(attempt.root, request.root) || !transcriptRelation(request.expected_transcript, attempt.transcript)) return false;
  if (target.kind === 'attempt') return true;
  if (attempt.round_id !== target.round_id || attempt.round_index !== target.round_index || attempt.round_revision === null) return false;
  if (target.kind === 'round') return request.expected_round_revision !== null && recoveredRoundRevisionMatches(request.expected_round_revision, attempt.round_revision);
  const call = attempt.batch[target.call_index];
  return call !== undefined && call.call_id === target.call_id && call.idempotency_key === target.idempotency_key &&
    request.expected_execution_revision !== null && call.execution_revision !== null && resultExecutionTargetRevisionMatches(request.expected_execution_revision, call.execution_revision);
}

function validateRecoverResult(value: unknown, request: RecoverAgentAttemptRequestV2): Exclude<RecoverAgentAttemptResultV2, { status: 'conflict' }> | null {
  const raw = ownRecord(value);
  if (raw === null || raw.status === 'conflict' || !enumValue(raw.status, ['resumed', 'retryable', 'manual_reconciliation', 'terminal'] as const)) return null;
  const result = exact(raw, ['schema_version', 'status', 'operation_id', 'next_action', 'attempt', 'completed_round']);
  if (result === null || result.schema_version !== 2 || result.operation_id !== request.operation_id) return null;
  const attempt = validateAttemptProjection(result.attempt);
  if (attempt === null || attempt.task_id !== request.target.task_id || attempt.attempt_id !== request.target.attempt_id || attempt.conversation_id !== request.controller_cas.conversation_id || !attemptMatchesRecoveryTarget(attempt, request.target, request)) return null;
  if (!enumValue(result.next_action, ['persist_round', 'persist_batch', 'persist_approval', 'persist_tool_result', 'persist_final', 'retry_same_round', 'inspect_native_state', 'none'] as const)) return null;
  const completedRound = result.completed_round === null ? null : validateRecoveredRound(result.completed_round, request.target);
  if (result.completed_round !== null && completedRound === null) return null;
  if (completedRound !== null) {
    const completedTranscript = validateTranscript(completedRound.transcript);
    if (completedTranscript === null || !transcriptRelation(request.expected_transcript, completedTranscript) || attempt.round_id !== completedRound.round_id || attempt.round_index !== completedRound.round_index || attempt.round_revision !== completedRound.result_round_revision || attempt.round_status !== 'completed') return null;
  }
  if (result.status === 'resumed') {
    if (result.next_action === 'retry_same_round' || result.next_action === 'inspect_native_state') return null;
    if (result.next_action === 'persist_final' && (completedRound === null || completedRound.kind !== 'final')) return null;
    if (result.next_action === 'persist_round' && completedRound === null) return null;
    if (result.next_action === 'persist_batch') {
      if (completedRound === null || completedRound.kind !== 'tool_batch') return null;
      // A completed provider round may precede batch preparation. When native
      // returns prepared WAL rows, every row must bind to that recovered round.
      if (attempt.batch.length > 0 && (completedRound.calls.length !== attempt.batch.length ||
          completedRound.calls.some((call, index) => {
            const prepared = attempt.batch[index];
            return prepared === undefined || call.call_index !== prepared.call_index || call.call_id !== prepared.call_id ||
              call.name !== prepared.name || call.arguments_sha256 !== prepared.arguments_sha256 ||
              call.safe_summary_key !== prepared.safe_summary_key || call.access !== prepared.access;
          }))) return null;
    }
    if ((result.next_action === 'persist_approval' || result.next_action === 'persist_tool_result' || result.next_action === 'none') && completedRound !== null) return null;
  } else if (result.status === 'retryable') {
    if (result.next_action !== 'retry_same_round' || completedRound !== null || attempt.phase !== 'failed') return null;
  } else if (result.status === 'manual_reconciliation') {
    if (result.next_action !== 'inspect_native_state' || completedRound !== null) return null;
  } else if (result.next_action !== 'none' || (completedRound !== null && completedRound.kind !== 'final')) return null;
  return { ...result, attempt, completed_round: completedRound } as unknown as Exclude<RecoverAgentAttemptResultV2, { status: 'conflict' }>;
}

function validateRecoveredRound(value: unknown, target: AgentRecoveryTargetV2): AgentRecoveredRoundProjectionV2 | null {
  const raw = ownRecord(value);
  if (raw === null || !enumValue(raw.kind, ['final', 'tool_batch', 'blocked'] as const)) return null;
  const commonKeys = ['schema_version', 'kind', 'task_id', 'attempt_id', 'round_id', 'round_index', 'launch_attempt', 'result_round_revision', 'transcript', 'completion_receipt', 'text', 'reasoning', 'assistant_text_sha256', 'reasoning_text_sha256'];
  const keys = raw.kind === 'tool_batch' ? [...commonKeys, 'calls', 'batch_class', 'executable_call_count', 'denied_call_count'] : raw.kind === 'blocked' ? [...commonKeys, 'failure_code'] : commonKeys;
  if (exact(raw, keys) === null || raw.schema_version !== 2 || !uuid(raw.task_id) || !uuid(raw.attempt_id) || !uuid(raw.round_id) || !safeInteger(raw.round_index, 7) || !safeInteger(raw.launch_attempt, 8, false) || !safeInteger(raw.result_round_revision, Number.MAX_SAFE_INTEGER - 1, false) || typeof raw.text !== 'string' || raw.text.length > 2 * 1024 * 1024 || typeof raw.reasoning !== 'string' || raw.reasoning.length > 2 * 1024 * 1024 || !digest(raw.assistant_text_sha256) || !digest(raw.reasoning_text_sha256)) return null;
  if (agentTextSHA256(raw.text) !== raw.assistant_text_sha256 || agentTextSHA256(raw.reasoning) !== raw.reasoning_text_sha256) return null;
  if (raw.task_id !== target.task_id || raw.attempt_id !== target.attempt_id || (target.kind !== 'attempt' && (raw.round_id !== target.round_id || raw.round_index !== target.round_index))) return null;
  const receipt = validateRoundReceipt(raw.completion_receipt);
  const transcript = validateTranscript(raw.transcript);
  if (receipt === null || transcript === null || receipt.turn_id !== raw.task_id || receipt.task_id !== raw.task_id || receipt.attempt_id !== raw.attempt_id || receipt.round_id !== raw.round_id || receipt.round_index !== raw.round_index) return null;
  if (raw.kind === 'final' && (receipt.finish_reason !== 'stop' || raw.failure_code !== undefined)) return null;
  if (raw.kind === 'blocked' && ((receipt.finish_reason !== 'length' && receipt.finish_reason !== 'content_filter') || raw.failure_code !== (receipt.finish_reason === 'length' ? 'E_COMPLETION_LENGTH' : 'E_COMPLETION_CONTENT_FILTER'))) return null;
  if (raw.kind === 'tool_batch') {
    const calls = arrayValue(raw.calls, 16, 1)?.map(validateRoundCall);
    if (calls === undefined || calls.some(call => call === null) || !enumValue(raw.batch_class, ['executable', 'mixed', 'denied_only'] as const) || !safeInteger(raw.executable_call_count, 16) || !safeInteger(raw.denied_call_count, 16) || raw.executable_call_count + raw.denied_call_count !== calls.length) return null;
    const seenCallIds = new Set<string>();
    for (const [index, call] of calls.entries()) {
      if (call === null || call.call_index !== index || seenCallIds.has(call.call_id)) return null;
      seenCallIds.add(call.call_id);
    }
    const deniedCount = calls.filter(call => call?.access === 'durable_deny').length;
    const expectedClass = deniedCount === 0 ? 'executable' : deniedCount === calls.length ? 'denied_only' : 'mixed';
    if (deniedCount !== raw.denied_call_count || calls.length - deniedCount !== raw.executable_call_count || raw.batch_class !== expectedClass) return null;
    return { ...raw, completion_receipt: receipt, transcript, calls: calls as AgentRoundCallPresentationV3[] } as unknown as AgentRecoveredRoundProjectionV2;
  }
  return { ...raw, completion_receipt: receipt, transcript } as unknown as AgentRecoveredRoundProjectionV2;
}

function validateTransitionPair(operation: AgentStoreOperation, request: unknown, result: unknown): AgentStoreTransitionEvidence | null {
  try {
    if (operation === 'prepare_agent_attempt') {
      const safeRequest = validatePrepareRequest(request);
      const safeResult = safeRequest === null ? null : validatePrepareResult(result, safeRequest);
      return safeRequest !== null && safeResult !== null ? { kind: operation, operation_id: safeRequest.operation_id, request: safeRequest, result: safeResult } : null;
    }
    if (operation === 'complete_agent_round_v2') {
      const safeRequest = validateRoundRequest(request);
      const safeResult = safeRequest === null ? null : validateCompleteResult(result, safeRequest);
      return safeRequest !== null && safeResult !== null ? { kind: operation, operation_id: safeRequest.operation_id, request: safeRequest, result: safeResult } : null;
    }
    if (operation === 'prepare_agent_tool_batch') {
      const safeRequest = validateBatchRequest(request);
      const safeResult = safeRequest === null ? null : validateBatchResult(result, safeRequest);
      return safeRequest !== null && safeResult !== null ? { kind: operation, operation_id: safeRequest.operation_id, request: safeRequest, result: safeResult } : null;
    }
    if (operation === 'bind_agent_approval') {
      const safeRequest = validateBindRequest(request);
      const safeResult = safeRequest === null ? null : validateBindResult(result, safeRequest);
      return safeRequest !== null && safeResult !== null ? { kind: operation, operation_id: safeRequest.operation_id, request: safeRequest, result: safeResult } : null;
    }
    if (operation === 'execute_agent_tool') {
      const safeRequest = validateExecuteRequest(request);
      const safeResult = safeRequest === null ? null : validateExecuteResult(result, safeRequest);
      return safeRequest !== null && safeResult !== null ? { kind: operation, operation_id: safeRequest.operation_id, request: safeRequest, result: safeResult } : null;
    }
    if (operation === 'cancel_agent_attempt') {
      const safeRequest = validateCancelRequest(request);
      const safeResult = safeRequest === null ? null : validateCancelResult(result, safeRequest);
      return safeRequest !== null && safeResult !== null ? { kind: operation, operation_id: safeRequest.operation_id, request: safeRequest, result: safeResult } : null;
    }
    if (operation !== 'recover_agent_attempt') return null;
    const safeRequest = validateRecoverRequest(request);
    const safeResult = safeRequest === null ? null : validateRecoverResult(result, safeRequest);
    return safeRequest !== null && safeResult !== null ? { kind: operation, operation_id: safeRequest.operation_id, request: safeRequest, result: safeResult } : null;
  } catch {
    return null;
  }
}

export function validateAgentStoreTransition(value: unknown): AgentStoreTransitionEvidence | null {
  const outer = exact(value, ['operation', 'request', 'result']);
  if (outer === null || !enumValue(outer.operation, [
    'prepare_agent_attempt',
    'complete_agent_round_v2',
    'prepare_agent_tool_batch',
    'bind_agent_approval',
    'execute_agent_tool',
    'cancel_agent_attempt',
    'recover_agent_attempt',
  ] as const)) return null;
  const evidence = validateTransitionPair(outer.operation, outer.request, outer.result);
  return evidence === null ? null : safeClone(evidence) as AgentStoreTransitionEvidence;
}

export function assertAgentStoreTransition(value: unknown): AgentStoreTransitionEvidence {
  const evidence = validateAgentStoreTransition(value);
  if (evidence === null) throw new AgentStoreTransitionValidationError();
  return evidence;
}

export const validateAgentTransitionEvidence = validateAgentStoreTransition;
export const mapAgentStoreTransition = validateAgentStoreTransition;
export const parseAgentStoreTransition = validateAgentStoreTransition;

export function validateAgentStoreRequest(operation: AgentStoreOperation, value: unknown): AgentStoreRequest | null {
  switch (operation) {
    case 'prepare_agent_attempt': return validatePrepareRequest(value);
    case 'complete_agent_round_v2': return validateRoundRequest(value);
    case 'prepare_agent_tool_batch': return validateBatchRequest(value);
    case 'bind_agent_approval': return validateBindRequest(value);
    case 'execute_agent_tool': return validateExecuteRequest(value);
    case 'cancel_agent_attempt': return validateCancelRequest(value);
    case 'recover_agent_attempt': return validateRecoverRequest(value);
    default: return null;
  }
}

export function validateAgentStoreResult(operation: AgentStoreOperation, request: unknown, result: unknown): AgentStoreResult | null {
  const evidence = validateTransitionPair(operation, request, result);
  return evidence === null ? null : safeClone(evidence.result) as AgentStoreResult;
}
