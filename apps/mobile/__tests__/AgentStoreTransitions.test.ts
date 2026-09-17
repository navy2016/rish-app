import {
  validateAgentStoreRequest,
  validateAgentStoreResult,
  validateAgentStoreTransition,
  type AgentStoreTransitionEvidence,
} from '../src/agent/AgentStoreTransitions';
import { RUNTIME_AGENT_TOOLS, ALL_AGENT_AUTO_TOOLS, ALL_AGENT_TOOL_NAMES } from '../src/agent/tool-registry';

const UUID_A = '11111111-1111-4111-8111-111111111111';
const UUID_B = '22222222-2222-4222-8222-222222222222';
const UUID_C = '33333333-3333-4333-8333-333333333333';
const UUID_D = '44444444-4444-4444-8444-444444444444';
const SHA = 'a'.repeat(64);

const cas = {
  schema_version: 1 as const,
  conversation_id: UUID_A,
  task_id: UUID_B,
  attempt_id: UUID_C,
  expected_controller_generation: 1,
  expected_journal_revision: 1,
  expected_session_generation: 7,
  expected_session_sha256: SHA,
};

const checkpoint = {
  schema_version: 1 as const,
  journal_revision: 1,
  session_generation: 7,
  session_sha256: SHA,
};

const transcript = {
  schema_version: 1 as const,
  transcript_ref: UUID_D,
  generation: 0,
  transcript_sha256: SHA,
  transcript_bytes: 0,
};

const root = {
  schema_version: 1 as const,
  kind: 'workspace' as const,
  workspace_id: UUID_A,
  workspace_binding_revision: 1,
  project_id: null,
  root_fingerprint_sha256: SHA,
  capabilities: ['file_read'] as const,
};

const prepareRequest = {
  schema_version: 2 as const,
  operation_id: UUID_D,
  controller_cas: cas,
  committed_checkpoint: checkpoint,
  task_id: UUID_B,
  conversation_id: UUID_A,
  attempt_id: UUID_C,
  workspace_id: UUID_A,
  project_id: null,
  workspace_binding_revision: 1,
  transport_schema_version: 2 as const,
  model: 'deepseek-v4-flash' as const,
  thinking_mode: 'high' as const,
  visible_message_ids: [],
  visible_history_sha256: SHA,
  visible_message_count: 0,
  project_context_sha256: null,
  registry_version: 1 as const,
  expected_policy_version: null,
  expected_transcript: null,
};

const registry = {
  schema_version: 2 as const,
  registry_version: 1 as const,
  toolset_sha256: SHA,
  tools: [],
};

const projection = {
  schema_version: 2 as const,
  task_id: UUID_B,
  conversation_id: UUID_A,
  attempt_id: UUID_C,
  phase: 'ready_for_round' as const,
  controller_generation: 1,
  journal_revision: 1,
  authority_revision: 1,
  root,
  policy: {
    schema_version: 1 as const,
    policy_version: 'agent-v1' as const,
    max_single_write_bytes: 32768 as const,
    max_batch_write_bytes: 32768,
    max_attempt_write_bytes: 32768,
  },
  registry,
  transcript,
  round_index: 0,
  round_id: UUID_D,
  round_revision: null,
  round_status: 'ready' as const,
  batch_kind: null,
  batch_revision: null,
  manifest_sha256: null,
  call_index: null,
  batch: [],
  frozen_grant_ids: [],
  reserved_write_bytes: 0,
  cancel_source_event_id: null,
  cleanup_id: null,
};

const prepareResult = {
  schema_version: 2 as const,
  status: 'prepared' as const,
  operation_id: UUID_D,
  attempt: projection,
  observed_checkpoint: checkpoint,
};

const CONVERSATION_X = 'a1111111-1111-4111-8111-111111111111';
const TASK_X = 'b2222222-2222-4222-8222-222222222222';
const ATTEMPT_X = 'c3333333-3333-4333-8333-333333333333';
const ROUND_X = 'd4444444-4444-4444-8444-444444444444';
const OPERATION_X = 'e5555555-5555-4555-8555-555555555555';
const TRANSCRIPT_X = 'f6666666-6666-4666-8666-666666666666';
const WORKSPACE_X = 'a7777777-7777-4777-8777-777777777777';
const PROJECT_X = 'b8888888-8888-4888-8888-888888888888';
const SNAPSHOT_X = 'c9999999-9999-4999-8999-999999999999';
const APPROVAL_X = 'daaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const SHA_CAS = 'a1'.repeat(32);
const SHA_ROOT = 'b2'.repeat(32);
const SHA_HISTORY = 'c3'.repeat(32);
const SHA_CONTEXT = 'd4'.repeat(32);
const SHA_TRANSCRIPT_0 = 'e5'.repeat(32);
const SHA_TRANSCRIPT_1 = 'f6'.repeat(32);
const SHA_TRANSCRIPT_ALT = 'a7'.repeat(32);
const SHA_TOOLSET = 'b8'.repeat(32);
const SHA_MODEL_INPUT = 'c9'.repeat(32);
const SHA_REQUEST_BODY = 'da'.repeat(32);
const SHA_SOURCE = 'eb'.repeat(32);
const SHA_ARGUMENT_AUTO = 'fc'.repeat(32);
const SHA_ARGUMENT_GATED = 'ad'.repeat(32);
const SHA_ARGUMENT_DENIED = 'be'.repeat(32);
const SHA_IDEMPOTENCY = 'cf'.repeat(32);
const SHA_AUTO_IDEMPOTENCY = 'e1'.repeat(32);
const SHA_MANIFEST = 'd0'.repeat(32);
const SHA_RECOVERED_TEXT =
  'f6e09cc89f85dcd21d987a4c4af142fe5bbb741de93d375af548f1d4f1d2063b';
const SHA_RECOVERED_REASONING =
  '5203f7706b13e7c81c22a5d3609059b75177f19c2ff5dc505684d4e69692e0cb';

const casX = {
  schema_version: 1 as const,
  conversation_id: CONVERSATION_X,
  task_id: TASK_X,
  attempt_id: ATTEMPT_X,
  expected_controller_generation: 4,
  expected_journal_revision: 6,
  expected_session_generation: 9,
  expected_session_sha256: SHA_CAS,
};

const checkpointX = {
  schema_version: 1 as const,
  journal_revision: 6,
  session_generation: 9,
  session_sha256: SHA_CAS,
};

const transcriptX = {
  schema_version: 1 as const,
  transcript_ref: TRANSCRIPT_X,
  generation: 2,
  transcript_sha256: SHA_TRANSCRIPT_0,
  transcript_bytes: 32,
};

const nextTranscriptX = {
  ...transcriptX,
  generation: 3,
  transcript_sha256: SHA_TRANSCRIPT_1,
  transcript_bytes: 64,
};

const alternateNextTranscriptX = {
  ...transcriptX,
  generation: 3,
  transcript_sha256: SHA_TRANSCRIPT_ALT,
  transcript_bytes: 65,
};

const projectRootX = {
  schema_version: 1 as const,
  kind: 'project' as const,
  workspace_id: WORKSPACE_X,
  workspace_binding_revision: 3,
  project_id: PROJECT_X,
  root_fingerprint_sha256: SHA_ROOT,
  capabilities: [
    'file_read',
    'file_write',
    'git_status',
    'git_commit',
    'git_push',
  ] as const,
};

const workspaceRootX = {
  schema_version: 1 as const,
  kind: 'workspace' as const,
  workspace_id: WORKSPACE_X,
  workspace_binding_revision: 3,
  project_id: null,
  root_fingerprint_sha256: SHA_ROOT,
  capabilities: ['file_read', 'file_write'] as const,
};

const registryX = {
  schema_version: 2 as const,
  registry_version: 1 as const,
  toolset_sha256: SHA_TOOLSET,
  tools: [] as const,
};

const policyX = {
  schema_version: 1 as const,
  policy_version: 'agent-v1' as const,
  max_single_write_bytes: 32768 as const,
  max_batch_write_bytes: 65536,
  max_attempt_write_bytes: 131072,
};

function makeAttemptX(
  phase: 'ready_for_round' | 'failed' | 'ambiguous' | 'final_response',
) {
  return {
    schema_version: 2 as const,
    task_id: TASK_X,
    conversation_id: CONVERSATION_X,
    attempt_id: ATTEMPT_X,
    phase,
    controller_generation: 4,
    journal_revision: 6,
    authority_revision: 3,
    root: projectRootX,
    policy: policyX,
    registry: registryX,
    transcript: nextTranscriptX,
    round_index: 0,
    round_id: ROUND_X,
    round_revision: phase === 'ready_for_round' ? null : 2,
    round_status: phase === 'ready_for_round'
      ? 'ready' as const
      : phase === 'failed'
      ? 'failed_retryable' as const
      : phase === 'ambiguous'
        ? 'ambiguous' as const
        : 'completed' as const,
    batch_kind: null,
    batch_revision: null,
    manifest_sha256: null,
    call_index: null,
    batch: [] as const,
    frozen_grant_ids: [] as const,
    reserved_write_bytes: 0,
    cancel_source_event_id: null,
    cleanup_id: null,
  };
}

function makeRoundReceiptX(
  transport: 2 | 3,
  finishReason: 'stop' | 'tool_calls' | 'length' | 'content_filter',
) {
  return {
    schema_version: 2 as const,
    transport_schema_version: transport,
    turn_id: TASK_X,
    task_id: TASK_X,
    attempt_id: ATTEMPT_X,
    round_id: ROUND_X,
    round_index: 0,
    provider_request_id: 'provider-request-x',
    provider_response_id: 'provider-response-x',
    requested_model: 'deepseek-v4-pro' as const,
    model: 'deepseek-v4-pro' as const,
    thinking_mode: 'max' as const,
    finish_reason: finishReason,
    latency_ms: 23,
    visible_history_sha256: SHA_HISTORY,
    model_input_sha256: SHA_MODEL_INPUT,
    request_body_sha256: SHA_REQUEST_BODY,
    project_context_receipt: transport === 3
      ? {
          schema_version: 1 as const,
          snapshot_id: SNAPSHOT_X,
          snapshot_sha256: SHA_CONTEXT,
          source_fingerprint: SHA_SOURCE,
          context_bytes: 128,
          verified_at: '2026-09-01T02:03:04.005Z',
        }
      : null,
  };
}

function makeCompleteRequestX(transport: 2 | 3) {
  return {
    schema_version: 2 as const,
    operation_id: OPERATION_X,
    controller_cas: casX,
    committed_checkpoint: checkpointX,
    task_id: TASK_X,
    conversation_id: CONVERSATION_X,
    attempt_id: ATTEMPT_X,
    round_id: ROUND_X,
    round_index: 0,
    launch_attempt: 2,
    expected_round_revision: 1,
    transport_schema_version: transport,
    model: 'deepseek-v4-pro' as const,
    thinking_mode: 'max' as const,
    visible_history_sha256: SHA_HISTORY,
    visible_message_count: 2,
    project_context_sha256: transport === 3 ? SHA_CONTEXT : null,
    transcript: transcriptX,
    root: transport === 3 ? projectRootX : workspaceRootX,
    registry_version: 1 as const,
    toolset_sha256: SHA_TOOLSET,
  };
}

describe('AgentStoreTransitions', () => {
  test('accepts the v3 thirteen-tool projection and rejects runtime tools under older versions', () => {
    const tools = ALL_AGENT_TOOL_NAMES.map(name => ({ schema_version: 2, name,
      safe_summary_key: `agent.${name}`, access: (ALL_AGENT_AUTO_TOOLS as readonly string[]).includes(name) ? 'auto' : 'conversation_confirm' }));
    const result = { ...prepareResult, attempt: { ...projection, registry: { ...registry, registry_version: 3, tools } } };
    const transition = { operation: 'prepare_agent_attempt', request: { ...prepareRequest, registry_version: 3 }, result };
    expect(validateAgentStoreTransition(transition)?.kind).toBe('prepare_agent_attempt');
    for (const name of RUNTIME_AGENT_TOOLS) for (const version of [1, 2]) {
      expect(validateAgentStoreTransition({ ...transition, result: { ...result, attempt: { ...result.attempt,
        registry: { ...result.attempt.registry, registry_version: version, tools: tools.filter(tool => tool.name === name) },
      } } })).toBeNull();
    }
    expect(validateAgentStoreTransition({ ...transition, result: { ...result, attempt: { ...result.attempt,
      registry: { ...result.attempt.registry, tools: tools.map(tool => tool.name === 'run_program' ? { ...tool, access: 'auto' } : tool) },
    } } })).toBeNull();
  });

  test.each(RUNTIME_AGENT_TOOLS)('accepts a v3 %s batch with its bounded approval preview', name => {
    const readOnly = name === 'list_runtime_environments';
    const serviceRoot = { ...root, capabilities: [readOnly ? 'file_read' : 'guest_service'] };
    const request = { schema_version: 2, operation_id: UUID_D, controller_cas: cas, committed_checkpoint: checkpoint,
      task_id: UUID_B, conversation_id: UUID_A, attempt_id: UUID_C, round_id: UUID_D, round_index: 0,
      expected_round_revision: 1, transcript, root: serviceRoot, registry_version: 3, toolset_sha256: SHA,
      policy_version: 'agent-v1', expected_batch_revision: 0, expected_reserved_write_bytes: 0 };
    const token = { schema_version: 2, token: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', controller_cas: cas,
      task_id: UUID_B, attempt_id: UUID_C, round_id: UUID_D, round_index: 0, batch_call_ids: ['runtime-call'],
      batch_arguments_sha256: [SHA], batch_revision: 1, manifest_sha256: SHA, call_index: 0, call_id: 'runtime-call',
      name, arguments_sha256: SHA, idempotency_key: SHA, root_fingerprint_sha256: SHA, binding_revision: 1,
      policy_version: 'agent-v1', registry_version: 3, access: 'conversation_confirm',
      allowed_decisions: ['denied', 'allow_once', 'allow_conversation', 'cancelled'] };
    const call = { schema_version: 2, call_index: 0, call_id: 'runtime-call', name, arguments_sha256: SHA,
      idempotency_key: SHA, safe_summary_key: `agent.${name}`, access: readOnly ? 'auto' : 'conversation_confirm',
      approval_state: readOnly ? 'not_required' : 'pending', approval_token: readOnly ? null : token,
      approval_reference: null, execution_status: 'intent', execution_revision: 1, native_row_revision: null, receipt: null,
      approval_preview: { schema_version: 1, kind: name, paths: name === 'run_program' || name === 'start_runtime_service' ? ['src/server.js'] : [],
        content_bytes: null, prior: null, diff_preview: null, diff_truncated: false } };
    const receipt = { schema_version: 2, task_id: UUID_B, attempt_id: UUID_C, round_id: UUID_D, round_index: 0,
      batch_kind: readOnly ? 'read_only_batch' : 'write_batch', batch_revision: 1, manifest_sha256: readOnly ? null : SHA,
      transcript, calls: [call], batch_new_write_bytes: 0, reserved_write_bytes: 0, effect_gate: readOnly ? 'not_applicable' : 'closed' };
    const result = { schema_version: 2, status: 'prepared', operation_id: UUID_D, receipt, observed_checkpoint: checkpoint };
    const transition = { operation: 'prepare_agent_tool_batch', request, result };
    expect(validateAgentStoreTransition(transition)?.kind).toBe('prepare_agent_tool_batch');
    const executeRequest = { schema_version: 2, operation_id: UUID_D, controller_cas: cas, committed_checkpoint: checkpoint,
      task_id: UUID_B, conversation_id: UUID_A, attempt_id: UUID_C, round_id: UUID_D, round_index: 0,
      batch_kind: receipt.batch_kind, manifest_sha256: receipt.manifest_sha256, expected_batch_revision: 1,
      call_index: 0, call_id: call.call_id, name, arguments_sha256: SHA, idempotency_key: SHA,
      expected_execution_revision: 1, transcript, root: serviceRoot, approval_reference: readOnly ? null : UUID_D };
    expect(validateAgentStoreRequest('execute_agent_tool', executeRequest)).not.toBeNull();
    expect(validateAgentStoreRequest('execute_agent_tool', { ...executeRequest, approval_reference: readOnly ? UUID_D : null })).toBeNull();
    expect(validateAgentStoreTransition({ ...transition, request: { ...request, registry_version: 2 } })).toBeNull();
    expect(validateAgentStoreTransition({ ...transition, request: { ...request, root: { ...serviceRoot, capabilities: [] } } })).toBeNull();
    expect(validateAgentStoreTransition({ ...transition, result: { ...result, receipt: { ...receipt,
      calls: [{ ...call, approval_preview: { ...call.approval_preview, paths: ['one', 'two'] } }],
    } } })).toBeNull();
  });
  test('accepts a complete prepare pair and emits a closed discriminated evidence union', () => {
    const evidence = validateAgentStoreTransition({
      operation: 'prepare_agent_attempt',
      request: prepareRequest,
      result: prepareResult,
    });
    expect(evidence).not.toBeNull();
    expect(evidence?.kind).toBe('prepare_agent_attempt');
    expect((evidence as AgentStoreTransitionEvidence).operation_id).toBe(UUID_D);
  });

  test.each([
    ['unknown request key', { ...prepareRequest, path: '/secret' }],
    ['owner field', { ...prepareRequest, owner: null }],
    ['CAS identity mismatch', { ...prepareRequest, task_id: UUID_A }],
  ])('rejects %s before any mapping', (_name, request) => {
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_attempt',
        request,
        result: prepareResult,
      }),
    ).toBeNull();
  });

  test('rejects conflict results and mismatched observed checkpoints', () => {
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_attempt',
        request: prepareRequest,
        result: { ...prepareResult, status: 'conflict', actual_session_generation: 8 },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_attempt',
        request: prepareRequest,
        result: {
          ...prepareResult,
          observed_checkpoint: { ...checkpoint, session_generation: 8 },
        },
      }),
    ).toBeNull();
  });

  test('accepts the exact in_flight round result without a failure_code key', () => {
    const request = {
      schema_version: 2 as const,
      operation_id: UUID_D,
      controller_cas: cas,
      committed_checkpoint: checkpoint,
      task_id: UUID_B,
      conversation_id: UUID_A,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      launch_attempt: 1,
      expected_round_revision: 0,
      transport_schema_version: 2 as const,
      model: 'deepseek-v4-flash' as const,
      thinking_mode: 'high' as const,
      visible_history_sha256: SHA,
      visible_message_count: 0,
      project_context_sha256: null,
      transcript,
      root,
      registry_version: 1 as const,
      toolset_sha256: SHA,
    };
    const result = {
      schema_version: 2 as const,
      status: 'in_flight' as const,
      operation_id: UUID_D,
      task_id: UUID_B,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      launch_attempt: 1,
      result_round_revision: 1,
      transcript,
    };
    const evidence = validateAgentStoreTransition({
      operation: 'complete_agent_round_v2',
      request,
      result,
    });
    expect(evidence?.kind).toBe('complete_agent_round_v2');
    expect(
      validateAgentStoreTransition({
        operation: 'complete_agent_round_v2',
        request,
        result: { ...result, failure_code: null },
      }),
    ).toBeNull();

    for (const failureCode of [
      'E_AGENT_ROUND_AMBIGUOUS',
      'E_AGENT_TRANSCRIPT',
      'E_AGENT_PERSISTENCE',
    ] as const) {
      expect(
        validateAgentStoreTransition({
          operation: 'complete_agent_round_v2',
          request,
          result: {
            ...result,
            status: 'unknown',
            failure_code: failureCode,
          },
        })?.kind,
      ).toBe('complete_agent_round_v2');
    }
    for (const failureCode of [
      'E_AGENT_NATIVE',
      'E_AGENT_NOT_FOUND',
      'E_AGENT_NOT_A_REAL_CODE',
    ]) {
      expect(
        validateAgentStoreTransition({
          operation: 'complete_agent_round_v2',
          request,
          result: {
            ...result,
            status: 'unknown',
            failure_code: failureCode,
          },
        }),
      ).toBeNull();
    }
  });

  test('accepts prepare_batch with the complete safe receipt, not only its calls', () => {
    const request = {
      schema_version: 2 as const,
      operation_id: UUID_D,
      controller_cas: cas,
      committed_checkpoint: checkpoint,
      task_id: UUID_B,
      conversation_id: UUID_A,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      expected_round_revision: 1,
      transcript,
      root,
      registry_version: 1 as const,
      toolset_sha256: SHA,
      policy_version: 'agent-v1' as const,
      expected_batch_revision: 0,
      expected_reserved_write_bytes: 0,
    };
    const call = {
      schema_version: 2 as const,
      call_index: 0,
      call_id: 'call-1',
      name: 'list_dir',
      arguments_sha256: SHA,
      idempotency_key: SHA_AUTO_IDEMPOTENCY,
      safe_summary_key: 'agent.list_dir',
      access: 'auto' as const,
      approval_state: 'not_required' as const,
      approval_token: null,
      approval_reference: null,
      execution_status: 'intent' as const,
      execution_revision: 1,
      native_row_revision: null,
      receipt: null,
    };
    const receipt = {
      schema_version: 2 as const,
      task_id: UUID_B,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      batch_kind: 'read_only_batch' as const,
      batch_revision: 1,
      manifest_sha256: null,
      transcript,
      calls: [call],
      batch_new_write_bytes: 0,
      reserved_write_bytes: 0,
      effect_gate: 'not_applicable' as const,
    };
    const evidence = validateAgentStoreTransition({
      operation: 'prepare_agent_tool_batch',
      request,
      result: {
        schema_version: 2 as const,
        status: 'prepared' as const,
        operation_id: UUID_D,
        receipt,
        observed_checkpoint: checkpoint,
      },
    });
    expect(evidence?.kind).toBe('prepare_agent_tool_batch');
    if (
      evidence?.kind === 'prepare_agent_tool_batch' &&
      evidence.result.status !== 'rejected'
    ) {
      expect(evidence.result.receipt.calls).toHaveLength(1);
      expect(evidence.result.receipt.batch_revision).toBe(1);
    }
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result: {
          schema_version: 2 as const,
          status: 'prepared' as const,
          operation_id: UUID_D,
          receipt: [call],
          observed_checkpoint: checkpoint,
        },
      }),
    ).toBeNull();
  });

  test('accepts native v2 CGI previews and preserves the old empty-path resume shape', () => {
    const serviceRoot = { ...root, capabilities: ['guest_service'] as const };
    const serviceRequest = {
      schema_version: 2 as const,
      operation_id: UUID_D,
      controller_cas: cas,
      committed_checkpoint: checkpoint,
      task_id: UUID_B,
      conversation_id: UUID_A,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      expected_round_revision: 0,
      transcript,
      root: serviceRoot,
      registry_version: 2 as const,
      toolset_sha256: SHA,
      policy_version: 'agent-v1' as const,
      expected_batch_revision: 0,
      expected_reserved_write_bytes: 0,
    };
    const serviceToken = {
      schema_version: 2 as const,
      token: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      controller_cas: cas,
      task_id: UUID_B,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      batch_call_ids: ['call-cgi'],
      batch_arguments_sha256: [SHA],
      batch_revision: 1,
      manifest_sha256: SHA,
      call_index: 0,
      call_id: 'call-cgi',
      name: 'start_guest_cgi',
      arguments_sha256: SHA,
      idempotency_key: SHA,
      root_fingerprint_sha256: SHA,
      binding_revision: 1,
      policy_version: 'agent-v1' as const,
      registry_version: 2 as const,
      access: 'conversation_confirm' as const,
      allowed_decisions: ['denied', 'allow_once', 'allow_conversation', 'cancelled'] as const,
    };
    const serviceCall = {
      schema_version: 2 as const,
      call_index: 0,
      call_id: 'call-cgi',
      name: 'start_guest_cgi',
      arguments_sha256: SHA,
      idempotency_key: SHA,
      safe_summary_key: 'agent.start_guest_cgi',
      access: 'conversation_confirm' as const,
      approval_state: 'pending' as const,
      approval_token: serviceToken,
      approval_reference: null,
      execution_status: 'intent' as const,
      execution_revision: 1,
      native_row_revision: null,
      receipt: null,
      approval_preview: {
        schema_version: 1 as const,
        kind: 'start_guest_cgi' as const,
        paths: ['demo/index.html', 'demo/backend.sh', 'demo/initial.json'],
        content_bytes: null,
        prior: null,
        diff_preview: null,
        diff_truncated: false,
      },
    };
    const serviceReceipt = {
      schema_version: 2 as const,
      task_id: UUID_B,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      batch_kind: 'write_batch' as const,
      batch_revision: 1,
      manifest_sha256: SHA,
      transcript,
      calls: [serviceCall],
      batch_new_write_bytes: 0,
      reserved_write_bytes: 0,
      effect_gate: 'closed' as const,
    };
    expect(validateAgentStoreTransition({
      operation: 'prepare_agent_tool_batch',
      request: serviceRequest,
      result: {
        schema_version: 2 as const,
        status: 'prepared' as const,
        operation_id: UUID_D,
        receipt: serviceReceipt,
        observed_checkpoint: checkpoint,
      },
    })?.kind).toBe('prepare_agent_tool_batch');
    expect(validateAgentStoreTransition({
      operation: 'prepare_agent_tool_batch',
      request: serviceRequest,
      result: {
        schema_version: 2 as const,
        status: 'prepared' as const,
        operation_id: UUID_D,
        receipt: {
          ...serviceReceipt,
          calls: [{
            ...serviceCall,
            approval_preview: { ...serviceCall.approval_preview, paths: [] },
          }],
        },
        observed_checkpoint: checkpoint,
      },
    })?.kind).toBe('prepare_agent_tool_batch');
    expect(validateAgentStoreTransition({
      operation: 'prepare_agent_tool_batch',
      request: serviceRequest,
      result: {
        schema_version: 2 as const,
        status: 'prepared' as const,
        operation_id: UUID_D,
        receipt: {
          ...serviceReceipt,
          calls: [{
            ...serviceCall,
            approval_preview: { ...serviceCall.approval_preview, paths: ['demo/index.html'] },
          }],
        },
        observed_checkpoint: checkpoint,
      },
    }),
    ).toBeNull();
  });

  test('requires the exact ambiguous execute branch to carry a real ambiguous receipt and failure code', () => {
    const request = {
      schema_version: 2 as const,
      operation_id: UUID_D,
      controller_cas: cas,
      committed_checkpoint: checkpoint,
      task_id: UUID_B,
      conversation_id: UUID_A,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      batch_kind: 'read_only_batch' as const,
      manifest_sha256: null,
      expected_batch_revision: 1,
      call_index: 0,
      call_id: 'call-1',
      name: 'read_file',
      arguments_sha256: SHA,
      idempotency_key: SHA,
      expected_execution_revision: 1,
      transcript,
      root,
      approval_reference: null,
    };
    const result = {
      schema_version: 2 as const,
      status: 'ambiguous' as const,
      operation_id: UUID_D,
      task_id: UUID_B,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      call_index: 0,
      call_id: 'call-1',
      name: 'read_file',
      idempotency_key: SHA,
      result_execution_revision: 2,
      transcript,
      receipt: {
        schema_version: 1,
        call_id: 'call-1',
        name: 'read_file',
        arguments_sha256: SHA,
        result_sha256: 'b'.repeat(64),
        result_bytes: 0,
        truncated: false,
        duration_ms: 1,
        outcome: 'ambiguous' as const,
        failure_code: 'E_AGENT_EXECUTION_AMBIGUOUS' as const,
        approval_reference: null,
      },
      effect_may_have_occurred: true,
      failure_code: 'E_AGENT_EXECUTION_AMBIGUOUS' as const,
    };
    expect(
      validateAgentStoreTransition({
        operation: 'execute_agent_tool',
        request,
        result,
      })?.kind,
    ).toBe('execute_agent_tool');
    expect(
      validateAgentStoreTransition({
        operation: 'execute_agent_tool',
        request,
        result: { ...result, failure_code: undefined },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'execute_agent_tool',
        request,
        result: { ...result, receipt: null },
      }),
    ).toBeNull();
  });

  test('does not accept native owner/launch/task fields or raw payload names', () => {
    for (const key of [
      'owner',
      'launch_id',
      'native_task_id',
      'arguments',
      'content',
      'path',
      'raw_result',
      'precondition',
    ]) {
      expect(
        validateAgentStoreTransition({
          operation: 'prepare_agent_attempt',
          request: { ...prepareRequest, [key]: null },
          result: prepareResult,
        }),
      ).toBeNull();
    }
  });

  test('rejects accessors, mutable arrays, non-canonical IDs, and unsafe revisions', () => {
    const accessor = { ...prepareRequest } as Record<string, unknown>;
    Object.defineProperty(accessor, 'task_id', {
      enumerable: true,
      get: () => UUID_B,
    });
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_attempt',
        request: accessor,
        result: prepareResult,
      }),
    ).toBeNull();

    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_attempt',
        request: {
          ...prepareRequest,
          operation_id: OPERATION_X.toUpperCase(),
        },
        result: {
          ...prepareResult,
          operation_id: OPERATION_X.toUpperCase(),
        },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_attempt',
        request: {
          ...prepareRequest,
          controller_cas: {
            ...cas,
            expected_session_generation: Number.MAX_SAFE_INTEGER,
          },
        },
        result: prepareResult,
      }),
    ).toBeNull();
  });

  test('accepts a fully bound conversation approval grant and rejects broken bindings', () => {
    const manifestSha = 'b1'.repeat(32);
    const argumentsSha = 'c2'.repeat(32);
    const idempotencyKey = 'd3'.repeat(32);
    const rootSha = 'e4'.repeat(32);
    const tokenId = 'a5555555-5555-4555-8555-555555555555';
    const approvalReference = 'b6666666-6666-4666-8666-666666666666';
    const grantId = 'c7777777-7777-4777-8777-777777777777';
    const workspaceId = 'd8888888-8888-4888-8888-888888888888';
    const token = {
      schema_version: 2 as const,
      token: tokenId,
      controller_cas: cas,
      task_id: UUID_B,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      batch_call_ids: ['call-write'],
      batch_arguments_sha256: [argumentsSha],
      batch_revision: 1,
      manifest_sha256: manifestSha,
      call_index: 0,
      call_id: 'call-write',
      name: 'write_file',
      arguments_sha256: argumentsSha,
      idempotency_key: idempotencyKey,
      root_fingerprint_sha256: rootSha,
      binding_revision: 1,
      policy_version: 'agent-v1' as const,
      registry_version: 1 as const,
      access: 'conversation_confirm' as const,
      allowed_decisions: [
        'denied',
        'allow_once',
        'allow_conversation',
        'cancelled',
      ] as const,
    };
    const request = {
      schema_version: 2 as const,
      operation_id: tokenId,
      controller_cas: cas,
      committed_checkpoint: checkpoint,
      task_id: UUID_B,
      conversation_id: UUID_A,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      manifest_sha256: manifestSha,
      batch_revision: 1,
      call_index: 0,
      call_id: 'call-write',
      token,
      decision: 'allow_conversation' as const,
    };
    const grant = {
      schema_version: 2 as const,
      grant_id: grantId,
      conversation_id: UUID_A,
      workspace_id: workspaceId,
      project_id: null,
      binding_revision: 1,
      root_fingerprint_sha256: rootSha,
      tool_family: 'file_write' as const,
      registry_version: 1 as const,
      policy_version: 'agent-v1' as const,
      issued_for: {
        schema_version: 1 as const,
        task_id: UUID_B,
        attempt_id: UUID_C,
      },
      created_at: '2026-09-01T01:02:03.004Z',
    };
    const result = {
      schema_version: 2 as const,
      status: 'bound' as const,
      operation_id: tokenId,
      task_id: UUID_B,
      attempt_id: UUID_C,
      round_id: UUID_D,
      call_index: 0,
      call_id: 'call-write',
      decision: 'allow_conversation' as const,
      approval_reference: approvalReference,
      grant,
      result_batch_revision: 1,
      observed_checkpoint: checkpoint,
    };

    expect(
      validateAgentStoreTransition({
        operation: 'bind_agent_approval',
        request,
        result,
      })?.kind,
    ).toBe('bind_agent_approval');
    const advancedCas = {
      ...cas,
      expected_controller_generation: 2,
      expected_journal_revision: 2,
      expected_session_generation: 8,
      expected_session_sha256: 'b'.repeat(64),
    };
    const advancedCheckpoint = {
      ...checkpoint,
      journal_revision: 2,
      session_generation: 8,
      session_sha256: 'b'.repeat(64),
    };
    expect(
      validateAgentStoreTransition({
        operation: 'bind_agent_approval',
        request: {
          ...request,
          controller_cas: advancedCas,
          committed_checkpoint: advancedCheckpoint,
          token,
        },
        result: {
          ...result,
          observed_checkpoint: advancedCheckpoint,
        },
      })?.kind,
    ).toBe('bind_agent_approval');
    expect(
      validateAgentStoreTransition({
        operation: 'bind_agent_approval',
        request: {
          ...request,
          token: {
            ...token,
            controller_cas: { ...cas, expected_controller_generation: 2 },
          },
        },
        result,
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'bind_agent_approval',
        request,
        result: {
          ...result,
          grant: {
            ...grant,
            issued_for: { ...grant.issued_for, task_id: UUID_A },
          },
        },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'bind_agent_approval',
        request,
        result: { ...result, approval_reference: null },
      }),
    ).toBeNull();
  });

  test('accepts tool cancellation only for the exact target revision matrix', () => {
    const sourceEventId = 'e9999999-9999-4999-8999-999999999999';
    const idempotencyKey = 'f5'.repeat(32);
    const argumentsSha = 'a6'.repeat(32);
    const target = {
      schema_version: 2 as const,
      kind: 'tool' as const,
      task_id: UUID_B,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
      call_index: 0,
      call_id: 'call-cancel',
      idempotency_key: idempotencyKey,
    };
    const request = {
      schema_version: 2 as const,
      operation_id: sourceEventId,
      controller_cas: cas,
      committed_checkpoint: checkpoint,
      target,
      cancel_token: {
        schema_version: 2 as const,
        issuer: 'completion_controller' as const,
        source_event_id: sourceEventId,
        token: sourceEventId,
        task_id: UUID_B,
        attempt_id: UUID_C,
        expected_phase: 'execution_intent' as const,
        reason_code: 'E_AGENT_CANCELLED' as const,
      },
      expected_round_revision: null,
      expected_execution_revision: 1,
      expected_transcript: transcript,
      root,
    };
    const result = {
      schema_version: 2 as const,
      status: 'cancelled' as const,
      operation_id: sourceEventId,
      target,
      result_round_revision: null,
      result_execution_revision: 2,
      transcript,
      receipt: {
        schema_version: 1 as const,
        call_id: 'call-cancel',
        name: 'read_file',
        arguments_sha256: argumentsSha,
        result_sha256: 'b7'.repeat(32),
        result_bytes: 0,
        truncated: false,
        duration_ms: 1,
        outcome: 'cancelled' as const,
        failure_code: 'E_AGENT_CANCELLED' as const,
        approval_reference: null,
      },
      effect_may_have_occurred: false,
      observed_checkpoint: checkpoint,
    };

    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request,
        result,
      })?.kind,
    ).toBe('cancel_agent_attempt');
    const cancelRequested = {
      ...result,
      status: 'cancel_requested' as const,
      receipt: null,
      effect_may_have_occurred: false,
    };
    for (const effectMayHaveOccurred of [false, true]) {
      expect(
        validateAgentStoreTransition({
          operation: 'cancel_agent_attempt',
          request,
          result: {
            ...cancelRequested,
            effect_may_have_occurred: effectMayHaveOccurred,
          },
        })?.kind,
      ).toBe('cancel_agent_attempt');
    }
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request,
        result: {
          ...cancelRequested,
          receipt: result.receipt,
          effect_may_have_occurred: true,
        },
      })?.kind,
    ).toBe('cancel_agent_attempt');
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request,
        result: {
          ...cancelRequested,
          receipt: { ...result.receipt, call_id: 'call-other' },
        },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request,
        result: {
          ...cancelRequested,
          failure_code: 'E_AGENT_CANCELLED',
        },
      }),
    ).toBeNull();
    for (const failureCode of [
      'E_AGENT_NOT_FOUND',
      'E_AGENT_PERSISTENCE',
    ] as const) {
      expect(
        validateAgentStoreTransition({
          operation: 'cancel_agent_attempt',
          request,
          result: {
            ...cancelRequested,
            status: 'unknown',
            failure_code: failureCode,
          },
        })?.kind,
      ).toBe('cancel_agent_attempt');
    }
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request,
        result: {
          ...cancelRequested,
          status: 'unknown',
          failure_code: 'E_AGENT_NOT_A_REAL_CODE',
        },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request: {
          ...request,
          expected_round_revision: 1,
          expected_execution_revision: null,
        },
        result,
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request,
        result: { ...result, result_execution_revision: 3 },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request: { ...request, expected_execution_revision: 0 },
        result: { ...result, result_execution_revision: 1 },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request,
        result: { ...result, effect_may_have_occurred: true },
      }),
    ).toBeNull();

    const roundZeroOperation = 'a1111111-1111-4111-8111-111111111111';
    const roundZeroTarget = {
      schema_version: 2 as const,
      kind: 'round' as const,
      task_id: UUID_B,
      attempt_id: UUID_C,
      round_id: UUID_D,
      round_index: 0,
    };
    const roundZeroRequest = {
      ...request,
      operation_id: roundZeroOperation,
      target: roundZeroTarget,
      cancel_token: {
        ...request.cancel_token,
        source_event_id: roundZeroOperation,
        token: roundZeroOperation,
        expected_phase: 'round_in_flight' as const,
      },
      expected_round_revision: 0,
      expected_execution_revision: null,
    };
    const roundZeroResult = {
      ...result,
      operation_id: roundZeroOperation,
      target: roundZeroTarget,
      result_round_revision: 1,
      result_execution_revision: null,
      receipt: null,
    };
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request: roundZeroRequest,
        result: roundZeroResult,
      })?.kind,
    ).toBe('cancel_agent_attempt');
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request: { ...roundZeroRequest, expected_round_revision: -0 },
        result: roundZeroResult,
      }),
    ).toBeNull();
  });

  test('accepts manual recovery and rejects target/status/completed-round mismatches', () => {
    const operationId = 'faaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const target = {
      schema_version: 2 as const,
      kind: 'attempt' as const,
      task_id: UUID_B,
      attempt_id: UUID_C,
    };
    const request = {
      schema_version: 2 as const,
      operation_id: operationId,
      controller_cas: cas,
      committed_checkpoint: checkpoint,
      target,
      action: 'reconcile' as const,
      expected_round_revision: null,
      expected_execution_revision: null,
      expected_transcript: transcript,
      root,
    };
    const result = {
      schema_version: 2 as const,
      status: 'manual_reconciliation' as const,
      operation_id: operationId,
      next_action: 'inspect_native_state' as const,
      attempt: projection,
      completed_round: null,
    };

    expect(
      validateAgentStoreTransition({
        operation: 'recover_agent_attempt',
        request,
        result,
      })?.kind,
    ).toBe('recover_agent_attempt');
    expect(
      validateAgentStoreTransition({
        operation: 'recover_agent_attempt',
        request: {
          ...request,
          expected_round_revision: 1,
          expected_execution_revision: 1,
        },
        result,
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'recover_agent_attempt',
        request,
        result: { ...result, next_action: 'none' },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'recover_agent_attempt',
        request,
        result: {
          ...result,
          completed_round: {
            schema_version: 2,
            kind: 'final',
            task_id: UUID_B,
          },
        },
      }),
    ).toBeNull();
  });

  test('enforces the prepare workspace/project/transport tuple', () => {
    const workspaceRequest = {
      schema_version: 2 as const,
      operation_id: OPERATION_X,
      controller_cas: casX,
      committed_checkpoint: checkpointX,
      task_id: TASK_X,
      conversation_id: CONVERSATION_X,
      attempt_id: ATTEMPT_X,
      workspace_id: WORKSPACE_X,
      project_id: null,
      workspace_binding_revision: 3,
      transport_schema_version: 2 as const,
      model: 'deepseek-v4-pro' as const,
      thinking_mode: 'max' as const,
      visible_message_ids: [SNAPSHOT_X],
      visible_history_sha256: SHA_HISTORY,
      visible_message_count: 1,
      project_context_sha256: null,
      registry_version: 1 as const,
      expected_policy_version: 'agent-v1' as const,
      expected_transcript: nextTranscriptX,
    };
    const workspaceAttempt = {
      ...makeAttemptX('ready_for_round'),
      root: workspaceRootX,
    };
    const result = {
      schema_version: 2 as const,
      status: 'prepared' as const,
      operation_id: OPERATION_X,
      attempt: workspaceAttempt,
      observed_checkpoint: checkpointX,
    };

    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_attempt',
        request: workspaceRequest,
        result,
      })?.kind,
    ).toBe('prepare_agent_attempt');
    for (const invalidRequest of [
      {
        ...workspaceRequest,
        workspace_id: null,
        workspace_binding_revision: 3,
      },
      {
        ...workspaceRequest,
        project_id: PROJECT_X,
      },
      {
        ...workspaceRequest,
        project_id: PROJECT_X,
        transport_schema_version: 3,
        project_context_sha256: null,
      },
    ]) {
      expect(
        validateAgentStoreTransition({
          operation: 'prepare_agent_attempt',
          request: invalidRequest,
          result,
        }),
      ).toBeNull();
    }
  });

  test.each([2, 3] as const)(
    'accepts a completed round with exact transport v%s context binding',
    transport => {
      const request = makeCompleteRequestX(transport);
      const receipt = makeRoundReceiptX(transport, 'stop');
      const outcome = {
        schema_version: 3 as const,
        kind: 'final' as const,
        finish_reason: 'stop' as const,
        completion_receipt: receipt,
        transcript: nextTranscriptX,
        text: 'done',
        reasoning: 'checked',
      };
      const result = {
        schema_version: 2 as const,
        status: 'completed' as const,
        operation_id: OPERATION_X,
        task_id: TASK_X,
        attempt_id: ATTEMPT_X,
        round_id: ROUND_X,
        round_index: 0,
        launch_attempt: 2,
        result_round_revision: 2,
        transcript: nextTranscriptX,
        outcome,
      };

      expect(
        validateAgentStoreTransition({
          operation: 'complete_agent_round_v2',
          request,
          result,
        })?.kind,
      ).toBe('complete_agent_round_v2');
      expect(
        validateAgentStoreTransition({
          operation: 'complete_agent_round_v2',
          request,
          result: { ...result, result_round_revision: 3 },
        })?.kind,
      ).toBe('complete_agent_round_v2');
      expect(
        validateAgentStoreTransition({
          operation: 'complete_agent_round_v2',
          request,
          result: {
            ...result,
            outcome: { ...outcome, transcript: alternateNextTranscriptX },
          },
        }),
      ).toBeNull();
      expect(
        validateAgentStoreTransition({
          operation: 'complete_agent_round_v2',
          request,
          result: {
            ...result,
            outcome: {
              ...outcome,
              completion_receipt: {
                ...receipt,
                visible_history_sha256: SHA_ARGUMENT_AUTO,
              },
            },
          },
        })?.kind,
      ).toBe('complete_agent_round_v2');
      expect(
        validateAgentStoreTransition({
          operation: 'complete_agent_round_v2',
          request,
          result: {
            ...result,
            outcome: {
              ...outcome,
              completion_receipt: {
                ...receipt,
                model: 'deepseek-v4-flash',
              },
            },
          },
        }),
      ).toBeNull();
      expect(
        validateAgentStoreTransition({
          operation: 'complete_agent_round_v2',
          request,
          result: {
            ...result,
            outcome: {
              ...outcome,
              completion_receipt: transport === 3
                ? {
                    ...receipt,
                    project_context_receipt: {
                      ...receipt.project_context_receipt!,
                      snapshot_sha256: SHA_ARGUMENT_GATED,
                    },
                  }
                : {
                    ...receipt,
                    project_context_receipt: {
                      schema_version: 1,
                      snapshot_id: SNAPSHOT_X,
                      snapshot_sha256: SHA_CONTEXT,
                      source_fingerprint: SHA_SOURCE,
                      context_bytes: 128,
                      verified_at: '2026-09-01T02:03:04.005Z',
                    },
                  },
            },
          },
        }),
      ).toBeNull();
    },
  );

  test('accepts one-to-three native round revision advances and rejects gaps or rollback', () => {
    const receipt = makeRoundReceiptX(2, 'stop');
    const outcome = {
      schema_version: 3 as const,
      kind: 'final' as const,
      finish_reason: 'stop' as const,
      completion_receipt: receipt,
      transcript: nextTranscriptX,
      text: 'done',
      reasoning: '',
    };
    const baseResult = {
      schema_version: 2 as const,
      status: 'completed' as const,
      operation_id: OPERATION_X,
      task_id: TASK_X,
      attempt_id: ATTEMPT_X,
      round_id: ROUND_X,
      round_index: 0,
      launch_attempt: 2,
      transcript: nextTranscriptX,
      outcome,
    };
    for (const [expected, accepted, rejected] of [
      [0, [1, 2, 3], [0, 4]],
      [1, [2, 3, 4], [0, 1, 5]],
      [2, [3, 4, 5], [1, 2, 6]],
    ] as const) {
      const request = {
        ...makeCompleteRequestX(2),
        expected_round_revision: expected,
      };
      for (const resultRoundRevision of accepted) {
        expect(
          validateAgentStoreTransition({
            operation: 'complete_agent_round_v2',
            request,
            result: {
              ...baseResult,
              result_round_revision: resultRoundRevision,
            },
          })?.kind,
        ).toBe('complete_agent_round_v2');
      }
      for (const resultRoundRevision of rejected) {
        expect(
          validateAgentStoreTransition({
            operation: 'complete_agent_round_v2',
            request,
            result: {
              ...baseResult,
              result_round_revision: resultRoundRevision,
            },
          }),
        ).toBeNull();
      }
    }
  });

  test('validates auto, gated, and durable-deny calls as one atomic batch receipt', () => {
    const tokenId = 'ebbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const callIds = ['call-auto', 'call-gated', 'call-denied'] as const;
    const argumentDigests = [
      SHA_ARGUMENT_AUTO,
      SHA_ARGUMENT_GATED,
      SHA_ARGUMENT_DENIED,
    ] as const;
    const token = {
      schema_version: 2 as const,
      token: tokenId,
      controller_cas: casX,
      task_id: TASK_X,
      attempt_id: ATTEMPT_X,
      round_id: ROUND_X,
      round_index: 0,
      batch_call_ids: callIds,
      batch_arguments_sha256: argumentDigests,
      batch_revision: 1,
      manifest_sha256: SHA_MANIFEST,
      call_index: 1,
      call_id: callIds[1],
      name: 'write_file',
      arguments_sha256: argumentDigests[1],
      idempotency_key: SHA_IDEMPOTENCY,
      root_fingerprint_sha256: SHA_ROOT,
      binding_revision: 3,
      policy_version: 'agent-v1' as const,
      registry_version: 1 as const,
      access: 'conversation_confirm' as const,
      allowed_decisions: [
        'denied',
        'allow_once',
        'allow_conversation',
        'cancelled',
      ] as const,
    };
    const calls = [
      {
        schema_version: 2 as const,
        call_index: 0,
        call_id: callIds[0],
        name: 'read_file',
        arguments_sha256: argumentDigests[0],
        idempotency_key: SHA_AUTO_IDEMPOTENCY,
        safe_summary_key: 'agent.read_file',
        access: 'auto' as const,
        approval_state: 'not_required' as const,
        approval_token: null,
        approval_reference: null,
        execution_status: 'intent' as const,
        execution_revision: 1,
        native_row_revision: null,
        receipt: null,
      },
      {
        schema_version: 2 as const,
        call_index: 1,
        call_id: callIds[1],
        name: 'write_file',
        arguments_sha256: argumentDigests[1],
        idempotency_key: SHA_IDEMPOTENCY,
        safe_summary_key: 'agent.write_file',
        access: 'conversation_confirm' as const,
        approval_state: 'pending' as const,
        approval_token: token,
        approval_reference: null,
        execution_status: 'intent' as const,
        execution_revision: 1,
        native_row_revision: null,
        receipt: null,
      },
      {
        schema_version: 2 as const,
        call_index: 2,
        call_id: callIds[2],
        name: 'shell_exec',
        arguments_sha256: argumentDigests[2],
        idempotency_key: null,
        safe_summary_key: 'agent.unknown',
        access: 'durable_deny' as const,
        approval_state: 'denied' as const,
        approval_token: null,
        approval_reference: null,
        execution_status: 'denied' as const,
        execution_revision: null,
        native_row_revision: 1,
        receipt: {
          schema_version: 1 as const,
          call_id: callIds[2],
          name: 'shell_exec',
          arguments_sha256: argumentDigests[2],
          result_sha256: SHA_REQUEST_BODY,
          result_bytes: 0,
          truncated: false,
          duration_ms: 0,
          outcome: 'denied' as const,
          failure_code: 'E_AGENT_UNKNOWN_TOOL' as const,
          approval_reference: null,
        },
      },
    ];
    const request = {
      schema_version: 2 as const,
      operation_id: OPERATION_X,
      controller_cas: casX,
      committed_checkpoint: checkpointX,
      task_id: TASK_X,
      conversation_id: CONVERSATION_X,
      attempt_id: ATTEMPT_X,
      round_id: ROUND_X,
      round_index: 0,
      expected_round_revision: 1,
      transcript: transcriptX,
      root: projectRootX,
      registry_version: 1 as const,
      toolset_sha256: SHA_TOOLSET,
      policy_version: 'agent-v1' as const,
      expected_batch_revision: 0,
      expected_reserved_write_bytes: 16,
    };
    const receipt = {
      schema_version: 2 as const,
      task_id: TASK_X,
      attempt_id: ATTEMPT_X,
      round_id: ROUND_X,
      round_index: 0,
      batch_kind: 'write_batch' as const,
      batch_revision: 1,
      manifest_sha256: SHA_MANIFEST,
      transcript: nextTranscriptX,
      calls,
      batch_new_write_bytes: 32,
      reserved_write_bytes: 48,
      effect_gate: 'closed' as const,
    };
    const result = {
      schema_version: 2 as const,
      status: 'prepared' as const,
      operation_id: OPERATION_X,
      receipt,
      observed_checkpoint: checkpointX,
    };

    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result,
      })?.kind,
    ).toBe('prepare_agent_tool_batch');
    const revisionResult = (batchRevision: number) => ({
      ...result,
      receipt: {
        ...receipt,
        batch_revision: batchRevision,
        calls: [
          calls[0],
          {
            ...calls[1],
            approval_token: {
              ...token,
              batch_revision: batchRevision,
            },
          },
          calls[2],
        ],
      },
    });
    const revisionRequest = { ...request, expected_batch_revision: 1 };
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request: revisionRequest,
        result: revisionResult(2),
      })?.kind,
    ).toBe('prepare_agent_tool_batch');
    for (const opaqueRevision of [1, 3, 7]) {
      expect(validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch', request: revisionRequest,
        result: revisionResult(opaqueRevision),
      })?.kind).toBe('prepare_agent_tool_batch');
    }
    for (const invalidBatchRevision of [0, -1, NaN, Infinity, Number.MAX_SAFE_INTEGER]) {
      expect(
        validateAgentStoreTransition({
          operation: 'prepare_agent_tool_batch',
          request: revisionRequest,
          result: revisionResult(invalidBatchRevision),
        }),
      ).toBeNull();
    }
    for (const missingIntentCall of [
      {
        ...calls[0],
        idempotency_key: null,
        execution_status: 'not_started' as const,
        execution_revision: null,
      },
      {
        ...calls[1],
        approval_token: null,
        idempotency_key: null,
        execution_status: 'not_started' as const,
        execution_revision: null,
      },
      {
        ...calls[1],
        execution_status: 'not_started' as const,
        execution_revision: null,
      },
    ]) {
      const invalidCalls: unknown[] = [...calls];
      invalidCalls[missingIntentCall.call_index] = missingIntentCall;
      expect(
        validateAgentStoreTransition({
          operation: 'prepare_agent_tool_batch',
          request,
          result: {
            ...result,
            receipt: { ...receipt, calls: invalidCalls },
          },
        }),
      ).toBeNull();
    }
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result: {
          ...result,
          receipt: { ...receipt, reserved_write_bytes: 47 },
        },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result: {
          ...result,
          receipt: {
            ...receipt,
            calls: [
              calls[0],
              {
                ...calls[1],
                approval_token: {
                  ...token,
                  batch_arguments_sha256: [
                    SHA_ARGUMENT_GATED,
                    SHA_ARGUMENT_AUTO,
                    SHA_ARGUMENT_DENIED,
                  ],
                },
              },
              calls[2],
            ],
          },
        },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result: {
          ...result,
          receipt: {
            ...receipt,
            calls: [
              calls[0],
              calls[1],
              {
                ...calls[2],
                receipt: { ...calls[2].receipt, call_id: callIds[0] },
              },
            ],
          },
        },
      }),
    ).toBeNull();

    const rejected = {
      schema_version: 2 as const,
      status: 'rejected' as const,
      operation_id: OPERATION_X,
      failure_code: 'E_AGENT_CAPACITY' as const,
      expected_batch_revision: 0,
      expected_reserved_write_bytes: 16,
      result_reserved_write_bytes: 16,
      effect_gate: 'closed' as const,
      reservation_status: 'unchanged' as const,
      effect_dispatched: false as const,
      retry_advice: 'wait_for_reconciliation' as const,
    };
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result: rejected,
      })?.kind,
    ).toBe('prepare_agent_tool_batch');
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result: { ...rejected, retry_advice: 'none' },
      }),
    ).toBeNull();
    // A store that could not write says so in its own code, so this layer has
    // to carry it. It waits out the condition the way a capacity refusal does.
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result: { ...rejected, failure_code: 'E_AGENT_PERSISTENCE' as const },
      })?.kind,
    ).toBe('prepare_agent_tool_batch');
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result: {
          ...rejected,
          failure_code: 'E_AGENT_PERSISTENCE' as const,
          retry_advice: 'requery' as const,
        },
      }),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result: { ...rejected, result_reserved_write_bytes: 17 },
      }),
    ).toBeNull();
  });

  test('accepts an initial read-only batch after round revision has advanced beyond one', () => {
    const request = {
      schema_version: 2 as const,
      operation_id: OPERATION_X,
      controller_cas: casX,
      committed_checkpoint: checkpointX,
      task_id: TASK_X,
      conversation_id: CONVERSATION_X,
      attempt_id: ATTEMPT_X,
      round_id: ROUND_X,
      round_index: 0,
      expected_round_revision: 2,
      transcript: transcriptX,
      root: workspaceRootX,
      registry_version: 1 as const,
      toolset_sha256: SHA_TOOLSET,
      policy_version: 'agent-v1' as const,
      expected_batch_revision: 0,
      expected_reserved_write_bytes: 0,
    };
    const call = {
      schema_version: 2 as const,
      call_index: 0,
      call_id: 'call-read-only-late',
      name: 'read_file',
      arguments_sha256: SHA_ARGUMENT_AUTO,
      idempotency_key: SHA_AUTO_IDEMPOTENCY,
      safe_summary_key: 'agent.read_file',
      access: 'auto' as const,
      approval_state: 'not_required' as const,
      approval_token: null,
      approval_reference: null,
      execution_status: 'intent' as const,
      execution_revision: 1,
      native_row_revision: null,
      receipt: null,
    };
    const result = {
      schema_version: 2 as const,
      status: 'prepared' as const,
      operation_id: OPERATION_X,
      receipt: {
        schema_version: 2 as const,
        task_id: TASK_X,
        attempt_id: ATTEMPT_X,
        round_id: ROUND_X,
        round_index: 0,
        batch_kind: 'read_only_batch' as const,
        batch_revision: 2,
        manifest_sha256: null,
        transcript: nextTranscriptX,
        calls: [call],
        batch_new_write_bytes: 0,
        reserved_write_bytes: 0,
        effect_gate: 'not_applicable' as const,
      },
      observed_checkpoint: checkpointX,
    };

    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_tool_batch',
        request,
        result,
      })?.kind,
    ).toBe('prepare_agent_tool_batch');
  });

  test('binds execute status, effect, revision, transcript, and receipt atomically', () => {
    const request = {
      schema_version: 2 as const,
      operation_id: OPERATION_X,
      controller_cas: casX,
      committed_checkpoint: checkpointX,
      task_id: TASK_X,
      conversation_id: CONVERSATION_X,
      attempt_id: ATTEMPT_X,
      round_id: ROUND_X,
      round_index: 0,
      batch_kind: 'read_only_batch' as const,
      manifest_sha256: null,
      expected_batch_revision: 1,
      call_index: 0,
      call_id: 'call-execute',
      name: 'read_file',
      arguments_sha256: SHA_ARGUMENT_AUTO,
      idempotency_key: SHA_IDEMPOTENCY,
      expected_execution_revision: 1,
      transcript: transcriptX,
      root: workspaceRootX,
      approval_reference: null,
    };
    const okReceipt = {
      schema_version: 1 as const,
      call_id: 'call-execute',
      name: 'read_file',
      arguments_sha256: SHA_ARGUMENT_AUTO,
      result_sha256: SHA_REQUEST_BODY,
      result_bytes: 12,
      truncated: false,
      duration_ms: 4,
      outcome: 'ok' as const,
      failure_code: null,
      approval_reference: null,
    };
    const common = {
      schema_version: 2 as const,
      operation_id: OPERATION_X,
      task_id: TASK_X,
      attempt_id: ATTEMPT_X,
      round_id: ROUND_X,
      round_index: 0,
      call_index: 0,
      call_id: 'call-execute',
      name: 'read_file',
      idempotency_key: SHA_IDEMPOTENCY,
      result_execution_revision: 2,
      transcript: nextTranscriptX,
    };
    const completed = {
      ...common,
      status: 'completed' as const,
      receipt: okReceipt,
      effect_may_have_occurred: false,
    };
    const failed = {
      ...common,
      status: 'failed' as const,
      receipt: {
        ...okReceipt,
        outcome: 'failed' as const,
        failure_code: 'E_AGENT_TOOL_FAILED' as const,
      },
      effect_may_have_occurred: true,
    };
    const unknown = {
      ...common,
      status: 'unknown' as const,
      receipt: null,
      effect_may_have_occurred: false as const,
      failure_code: 'E_AGENT_LEDGER' as const,
    };
    const ambiguous = {
      ...common,
      status: 'ambiguous' as const,
      receipt: {
        ...okReceipt,
        outcome: 'ambiguous' as const,
        failure_code: 'E_AGENT_EXECUTION_AMBIGUOUS' as const,
      },
      effect_may_have_occurred: true as const,
      failure_code: 'E_AGENT_EXECUTION_AMBIGUOUS' as const,
    };

    for (const result of [completed, failed, unknown, ambiguous]) {
      expect(
        validateAgentStoreTransition({
          operation: 'execute_agent_tool',
          request,
          result,
        })?.kind,
      ).toBe('execute_agent_tool');
    }
    expect(
      validateAgentStoreTransition({
        operation: 'execute_agent_tool',
        request,
        result: { ...completed, result_execution_revision: 4 },
      })?.kind,
    ).toBe('execute_agent_tool');
    for (const result of [
      { ...completed, result_execution_revision: 5 },
      { ...failed, receipt: okReceipt },
      { ...unknown, receipt: okReceipt },
      { ...ambiguous, effect_may_have_occurred: false },
      {
        ...completed,
        receipt: { ...okReceipt, call_id: 'call-other' },
      },
      {
        ...completed,
        transcript: {
          ...alternateNextTranscriptX,
          transcript_ref: OPERATION_X,
        },
      },
    ]) {
      expect(
        validateAgentStoreTransition({
          operation: 'execute_agent_tool',
          request,
          result,
        }),
      ).toBeNull();
    }

    const gatedRequest = {
      ...request,
      batch_kind: 'write_batch' as const,
      manifest_sha256: SHA_MANIFEST,
      call_id: 'call-write-execute',
      name: 'write_file',
      arguments_sha256: SHA_ARGUMENT_GATED,
      root: projectRootX,
      approval_reference: APPROVAL_X,
    };
    const gatedResult = {
      ...completed,
      call_id: 'call-write-execute',
      name: 'write_file',
      receipt: {
        ...okReceipt,
        call_id: 'call-write-execute',
        name: 'write_file',
        arguments_sha256: SHA_ARGUMENT_GATED,
        approval_reference: APPROVAL_X,
      },
    };
    expect(
      validateAgentStoreTransition({
        operation: 'execute_agent_tool',
        request: gatedRequest,
        result: gatedResult,
      })?.kind,
    ).toBe('execute_agent_tool');
  });

  test('accepts attempt and round cancellation revision tuples', () => {
    const attemptOperation = 'fddddddd-dddd-4ddd-8ddd-dddddddddddd';
    const roundOperation = 'aeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    const attemptTarget = {
      schema_version: 2 as const,
      kind: 'attempt' as const,
      task_id: TASK_X,
      attempt_id: ATTEMPT_X,
    };
    const roundTarget = {
      schema_version: 2 as const,
      kind: 'round' as const,
      task_id: TASK_X,
      attempt_id: ATTEMPT_X,
      round_id: ROUND_X,
      round_index: 0,
    };
    const attemptRequest = {
      schema_version: 2 as const,
      operation_id: attemptOperation,
      controller_cas: casX,
      committed_checkpoint: checkpointX,
      target: attemptTarget,
      cancel_token: {
        schema_version: 2 as const,
        issuer: 'completion_controller' as const,
        source_event_id: attemptOperation,
        token: attemptOperation,
        task_id: TASK_X,
        attempt_id: ATTEMPT_X,
        expected_phase: 'approval_pending' as const,
        reason_code: 'E_AGENT_CANCELLED' as const,
      },
      expected_round_revision: null,
      expected_execution_revision: null,
      expected_transcript: transcriptX,
      root: projectRootX,
    };
    const roundRequest = {
      ...attemptRequest,
      operation_id: roundOperation,
      target: roundTarget,
      cancel_token: {
        ...attemptRequest.cancel_token,
        source_event_id: roundOperation,
        token: roundOperation,
        expected_phase: 'round_in_flight' as const,
      },
      expected_round_revision: 1,
    };
    const attemptResult = {
      schema_version: 2 as const,
      status: 'cancelled' as const,
      operation_id: attemptOperation,
      target: attemptTarget,
      result_round_revision: null,
      result_execution_revision: null,
      transcript: transcriptX,
      receipt: null,
      effect_may_have_occurred: false,
      observed_checkpoint: checkpointX,
    };
    const roundResult = {
      ...attemptResult,
      operation_id: roundOperation,
      target: roundTarget,
      result_round_revision: 2,
    };

    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request: attemptRequest,
        result: attemptResult,
      })?.kind,
    ).toBe('cancel_agent_attempt');
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request: roundRequest,
        result: roundResult,
      })?.kind,
    ).toBe('cancel_agent_attempt');
    const roundZeroRequest = {
      ...roundRequest,
      expected_round_revision: 0,
    };
    const roundZeroResult = {
      ...roundResult,
      result_round_revision: 1,
    };
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request: roundZeroRequest,
        result: roundZeroResult,
      })?.kind,
    ).toBe('cancel_agent_attempt');
    for (const invalidRoundRevision of [-1, Number.NaN]) {
      expect(
        validateAgentStoreTransition({
          operation: 'cancel_agent_attempt',
          request: {
            ...roundRequest,
            expected_round_revision: invalidRoundRevision,
          },
          result: roundZeroResult,
        }),
      ).toBeNull();
    }
    expect(
      validateAgentStoreTransition({
        operation: 'cancel_agent_attempt',
        request: roundRequest,
        result: { ...roundResult, result_execution_revision: 1 },
      }),
    ).toBeNull();
  });

  test('accepts all four recovery statuses only with their exact next actions', () => {
    const request = {
      schema_version: 2 as const,
      operation_id: OPERATION_X,
      controller_cas: casX,
      committed_checkpoint: checkpointX,
      target: {
        schema_version: 2 as const,
        kind: 'round' as const,
        task_id: TASK_X,
        attempt_id: ATTEMPT_X,
        round_id: ROUND_X,
        round_index: 0,
      },
      action: 'reconcile' as const,
      expected_round_revision: 1,
      expected_execution_revision: null,
      expected_transcript: transcriptX,
      root: projectRootX,
    };
    const completedRound = {
      schema_version: 2 as const,
      kind: 'final' as const,
      task_id: TASK_X,
      attempt_id: ATTEMPT_X,
      round_id: ROUND_X,
      round_index: 0,
      launch_attempt: 2,
      result_round_revision: 2,
      transcript: nextTranscriptX,
      completion_receipt: makeRoundReceiptX(3, 'stop'),
      text: 'recovered',
      reasoning: 'durable native receipt',
      assistant_text_sha256: SHA_RECOVERED_TEXT,
      reasoning_text_sha256: SHA_RECOVERED_REASONING,
    };
    const resumed = {
      schema_version: 2 as const,
      status: 'resumed' as const,
      operation_id: OPERATION_X,
      next_action: 'persist_final' as const,
      attempt: makeAttemptX('final_response'),
      completed_round: completedRound,
    };
    const retryable = {
      schema_version: 2 as const,
      status: 'retryable' as const,
      operation_id: OPERATION_X,
      next_action: 'retry_same_round' as const,
      attempt: makeAttemptX('failed'),
      completed_round: null,
    };
    const manual = {
      schema_version: 2 as const,
      status: 'manual_reconciliation' as const,
      operation_id: OPERATION_X,
      next_action: 'inspect_native_state' as const,
      attempt: makeAttemptX('ambiguous'),
      completed_round: null,
    };
    const terminal = {
      schema_version: 2 as const,
      status: 'terminal' as const,
      operation_id: OPERATION_X,
      next_action: 'none' as const,
      attempt: makeAttemptX('final_response'),
      completed_round: completedRound,
    };
    const retryRequest = { ...request, action: 'retry_failed_round' as const };

    for (const [activeRequest, result] of [
      [request, resumed],
      [retryRequest, retryable],
      [request, manual],
      [request, terminal],
    ] as const) {
      expect(
        validateAgentStoreTransition({
          operation: 'recover_agent_attempt',
          request: activeRequest,
          result,
        })?.kind,
      ).toBe('recover_agent_attempt');
    }
    for (const [activeRequest, result] of [
      [request, { ...resumed, next_action: 'persist_batch' }],
      [retryRequest, { ...retryable, next_action: 'none' }],
      [request, { ...manual, next_action: 'none' }],
      [request, { ...terminal, next_action: 'inspect_native_state' }],
      [
        request,
        {
          ...resumed,
          completed_round: {
            ...completedRound,
            assistant_text_sha256: undefined,
          },
        },
      ],
    ] as const) {
      expect(
        validateAgentStoreTransition({
          operation: 'recover_agent_attempt',
          request: activeRequest,
          result,
        }),
      ).toBeNull();
    }
    for (const completedRoundDigestMismatch of [
      {
        ...completedRound,
        assistant_text_sha256: SHA_ARGUMENT_AUTO,
      },
      {
        ...completedRound,
        reasoning_text_sha256: SHA_ARGUMENT_GATED,
      },
    ]) {
      expect(
        validateAgentStoreTransition({
          operation: 'recover_agent_attempt',
          request,
          result: {
            ...resumed,
            completed_round: completedRoundDigestMismatch,
          },
        }),
      ).toBeNull();
    }

    const sameRevisionRound = {
      ...completedRound,
      result_round_revision: request.expected_round_revision,
    };
    const sameRevisionResult = {
      ...resumed,
      attempt: {
        ...makeAttemptX('final_response'),
        round_revision: request.expected_round_revision,
      },
      completed_round: sameRevisionRound,
    };
    expect(
      validateAgentStoreTransition({
        operation: 'recover_agent_attempt',
        request,
        result: sameRevisionResult,
      })?.kind,
    ).toBe('recover_agent_attempt');
    for (const invalidRevision of [0, 5]) {
      expect(
        validateAgentStoreTransition({
          operation: 'recover_agent_attempt',
          request,
          result: {
            ...sameRevisionResult,
            attempt: {
              ...sameRevisionResult.attempt,
              round_revision: invalidRevision,
            },
            completed_round: {
              ...sameRevisionRound,
              result_round_revision: invalidRevision,
            },
          },
        }),
      ).toBeNull();
    }
  });

  test('rejects cancel/recover CAS-checkpoint drift and invalid helper operations', () => {
    const cancelOperation = 'f1111111-1111-4111-8111-111111111111';
    const mismatchedCheckpoint = {
      ...checkpointX,
      journal_revision: checkpointX.journal_revision + 1,
    };
    const attemptTarget = {
      schema_version: 2 as const,
      kind: 'attempt' as const,
      task_id: TASK_X,
      attempt_id: ATTEMPT_X,
    };
    const cancelRequest = {
      schema_version: 2 as const,
      operation_id: cancelOperation,
      controller_cas: casX,
      committed_checkpoint: mismatchedCheckpoint,
      target: attemptTarget,
      cancel_token: {
        schema_version: 2 as const,
        issuer: 'completion_controller' as const,
        source_event_id: cancelOperation,
        token: cancelOperation,
        task_id: TASK_X,
        attempt_id: ATTEMPT_X,
        expected_phase: 'approval_pending' as const,
        reason_code: 'E_AGENT_CANCELLED' as const,
      },
      expected_round_revision: null,
      expected_execution_revision: null,
      expected_transcript: transcriptX,
      root: projectRootX,
    };
    const recoverRequest = {
      schema_version: 2 as const,
      operation_id: OPERATION_X,
      controller_cas: casX,
      committed_checkpoint: mismatchedCheckpoint,
      target: attemptTarget,
      action: 'reconcile' as const,
      expected_round_revision: null,
      expected_execution_revision: null,
      expected_transcript: transcriptX,
      root: projectRootX,
    };

    expect(
      validateAgentStoreRequest('cancel_agent_attempt', cancelRequest),
    ).toBeNull();
    expect(
      validateAgentStoreRequest('recover_agent_attempt', recoverRequest),
    ).toBeNull();

    const validRecoverRequest = {
      ...recoverRequest,
      committed_checkpoint: checkpointX,
    };
    const validRecoverResult = {
      schema_version: 2 as const,
      status: 'manual_reconciliation' as const,
      operation_id: OPERATION_X,
      next_action: 'inspect_native_state' as const,
      attempt: makeAttemptX('ambiguous'),
      completed_round: null,
    };
    const invalidOperation = 'recover_agent_attempt_typo' as Parameters<
      typeof validateAgentStoreRequest
    >[0];
    expect(
      validateAgentStoreRequest(invalidOperation, validRecoverRequest),
    ).toBeNull();
    expect(
      validateAgentStoreResult(
        invalidOperation,
        validRecoverRequest,
        validRecoverResult,
      ),
    ).toBeNull();
    expect(
      validateAgentStoreTransition({
        operation: 'recover_agent_attempt',
        request: validRecoverRequest,
        result: { ...validRecoverResult, operation_id: APPROVAL_X },
      }),
    ).toBeNull();
  });

  test('returns a defensive deep clone and rejects outer unknown keys/accessors', () => {
    const sourceIds = [SNAPSHOT_X];
    const sourceCapabilities = ['file_read', 'file_write'];
    const request = {
      schema_version: 2 as const,
      operation_id: OPERATION_X,
      controller_cas: casX,
      committed_checkpoint: checkpointX,
      task_id: TASK_X,
      conversation_id: CONVERSATION_X,
      attempt_id: ATTEMPT_X,
      workspace_id: WORKSPACE_X,
      project_id: null,
      workspace_binding_revision: 3,
      transport_schema_version: 2 as const,
      model: 'deepseek-v4-pro' as const,
      thinking_mode: 'max' as const,
      visible_message_ids: sourceIds,
      visible_history_sha256: SHA_HISTORY,
      visible_message_count: 1,
      project_context_sha256: null,
      registry_version: 1 as const,
      expected_policy_version: 'agent-v1' as const,
      expected_transcript: nextTranscriptX,
    };
    const attempt = {
      ...makeAttemptX('ready_for_round'),
      root: { ...workspaceRootX, capabilities: sourceCapabilities },
    };
    const result = {
      schema_version: 2 as const,
      status: 'prepared' as const,
      operation_id: OPERATION_X,
      attempt,
      observed_checkpoint: checkpointX,
    };
    const evidence = validateAgentStoreTransition({
      operation: 'prepare_agent_attempt',
      request,
      result,
    });
    expect(evidence?.kind).toBe('prepare_agent_attempt');
    if (evidence?.kind !== 'prepare_agent_attempt') {
      throw new Error('expected prepare evidence');
    }
    expect(evidence.request.visible_message_ids).not.toBe(sourceIds);
    expect(evidence.result.attempt.root?.capabilities).not.toBe(sourceCapabilities);
    sourceIds[0] = OPERATION_X;
    sourceCapabilities[0] = 'file_write';
    expect(evidence.request.visible_message_ids[0]).toBe(SNAPSHOT_X);
    expect(evidence.result.attempt.root?.capabilities[0]).toBe('file_read');

    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_attempt',
        request,
        result,
        extra: true,
      }),
    ).toBeNull();
    const accessorResult = { ...result } as Record<string, unknown>;
    Object.defineProperty(accessorResult, 'attempt', {
      enumerable: true,
      get: () => attempt,
    });
    expect(
      validateAgentStoreTransition({
        operation: 'prepare_agent_attempt',
        request,
        result: accessorResult,
      }),
    ).toBeNull();
  });
});
