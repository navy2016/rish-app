import { providerBindingHost } from '../providers/configuration';
import {
  LocalProjectContext,
  ProjectContextBridgeError,
} from '../native/LocalProjectContext';
import { providerForModel, providerHostForModel } from '../harness/types';
import {
  workspaceRoot,
  type WorkspaceRootRefV1,
} from '../native/WorkspaceRoot';
import type { SessionDurabilityResult } from '../completion/SessionPersistence';
import type {
  ChatStore,
  ModelId,
  ProjectContextMutationScope,
  ScopedProjectContextTransaction,
} from '../state';
import {
  PROJECT_CONTEXT_BRIDGE_ERROR_CODES,
  PROJECT_CONTEXT_ERROR_CODES,
  type ProjectContextBridgeErrorCode,
  type ProjectContextCandidatePageV1,
  type ProjectContextConsentV1,
  type ProjectContextConsentV2,
  type ProjectContextInspectionV1,
  type ProjectContextManifestV2,
  type ProjectContextManifestV1,
  type ProjectContextCandidatePageV2,
  type ProjectContextSelectionV1,
  type ProjectContextState,
} from './types';

type Candidate = ProjectContextCandidatePageV1['candidates'][number];

export type ProjectContextControllerPhase =
  | 'idle'
  | 'preparing'
  | 'confirming'
  | 'inspecting'
  | 'disabling'
  | 'review'
  | 'persistence_pending'
  | 'cleanup_pending'
  | 'blocked';

export type ProjectContextControllerErrorCode =
  | ProjectContextBridgeErrorCode
  | 'E_CONTEXT_PERSISTENCE'
  | 'E_CONTEXT_OWNER_STALE';

const CONTEXT_NATIVE_TIMEOUT_MS = 30_000;
function boundedNative<T>(operation: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<T>((_, reject) => {
    timer = setTimeout(() => reject(new ProjectContextBridgeError('E_CONTEXT_TIMEOUT')), CONTEXT_NATIVE_TIMEOUT_MS);
  });
  return Promise.race([operation, timeout]).finally(() => { if (timer !== undefined) clearTimeout(timer); });
}

export type ProjectContextControllerOwner = {
  readonly conversationId: string;
  readonly projectId: string;
  readonly runtimeContextId: string | null;
  readonly modelId: ModelId;
  /** Exact workspace authority captured with this owner, when routed. */
  readonly root: WorkspaceRootRefV1 | null;
};

export type ProjectContextActionToken = ProjectContextControllerOwner & {
  readonly generation: number;
  readonly preparationId: string | null;
  readonly listGeneration: number;
};

export type ProjectContextCandidateListState = {
  readonly query: string;
  readonly candidates: readonly Candidate[];
  readonly nextCursor: string | null;
  readonly loading: boolean;
  readonly loadingMore: boolean;
};

export type ProjectContextPendingPersistenceState = {
  readonly kind:
    | 'prepare_intent'
    | 'prepared_manifest'
    | 'confirmed_consent'
    | 'disabled'
    | 'inspection';
  readonly cleanupSnapshotId?: string | null;
};

export type ProjectContextControllerState = {
  readonly phase: ProjectContextControllerPhase;
  readonly owner: ProjectContextControllerOwner | null;
  readonly generation: number;
  readonly listGeneration: number;
  readonly list: ProjectContextCandidateListState;
  readonly selectedPaths: readonly string[];
  readonly selectedCandidates: readonly Candidate[];
  readonly candidateManifest: ProjectContextManifestV1 | null;
  readonly candidatePreparationId: string | null;
  readonly pendingPersistence: ProjectContextPendingPersistenceState | null;
  readonly cleanupSnapshotId: string | null;
  readonly failureCode: ProjectContextControllerErrorCode | null;
};

export type ProjectContextControllerOutcome =
  | { readonly status: 'completed' }
  | {
      readonly status: 'blocked';
      readonly code: ProjectContextControllerErrorCode;
    }
  | {
      readonly status: 'persistence_pending';
      readonly code: 'E_CONTEXT_PERSISTENCE';
    }
  | {
      readonly status: 'cleanup_pending';
      readonly code: ProjectContextControllerErrorCode;
    };

type NativeProjectContext = Pick<
  typeof LocalProjectContext,
  'listCandidates' | 'prepare' | 'confirm' | 'inspect' | 'discard'
> &
  Partial<
    Pick<
      typeof LocalProjectContext,
      | 'listCandidatesV2'
      | 'prepareV2'
      | 'confirmV2'
      | 'inspectV2'
      | 'discardV2'
    >
  >;

export type ProjectContextSearchHandle = {
  readonly cancel: () => void;
};

export type ProjectContextControllerDependencies = {
  readonly chat: ChatStore;
  readonly native: NativeProjectContext;
  readonly persistCurrent: () => Promise<SessionDurabilityResult>;
  readonly createPreparationId: () => string;
  readonly completionMutationBlocked: (conversationId: string) => boolean;
  readonly snapshotReferences: (
    conversationId: string,
    snapshotId?: string,
  ) => readonly unknown[];
  readonly scheduleSearch: (
    delayMilliseconds: number,
    operation: () => void,
  ) => ProjectContextSearchHandle;
  readonly maximumPendingPersistence: 1;
};

export type ProjectContextController = {
  getState(): ProjectContextControllerState;
  subscribe(
    listener: (state: ProjectContextControllerState) => void,
  ): () => void;
  getActionToken(): ProjectContextActionToken | null;
  attachConversation(
    conversationId: string,
  ): Promise<ProjectContextControllerOutcome>;
  reconcileHydrated(
    conversationId: string,
  ): Promise<ProjectContextControllerOutcome>;
  search(
    expected: ProjectContextActionToken,
    query: string,
  ): Promise<ProjectContextControllerOutcome>;
  loadMore(
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome>;
  setSelectedPaths(
    expected: ProjectContextActionToken,
    paths: readonly string[],
  ): ProjectContextControllerOutcome;
  prepare(
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome>;
  confirm(
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome>;
  inspect(
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome>;
  disable(
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome>;
  retryPersistence(
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome>;
  retryCleanup(
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome>;
  cancel(
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome>;
  beforeConversationChange(conversationId: string): Promise<boolean>;
  beforeConversationDelete(conversationId: string): Promise<boolean>;
};

type OperationKind =
  | 'prepare'
  | 'confirm'
  | 'inspect'
  | 'disable'
  | 'retry_persistence'
  | 'retry_cleanup'
  | 'cancel';

type ActiveOperation = ProjectContextControllerOwner & {
  readonly id: number;
  readonly generation: number;
  readonly kind: OperationKind;
  readonly expectedContext: ProjectContextState;
};

type PrepareIntentOutbox = {
  readonly kind: 'prepare_intent';
  readonly operation: ActiveOperation;
  readonly preparationId: string;
  readonly selectedPaths: readonly string[];
  readonly baselineSnapshotId: string | null;
  readonly baselineWasConfirmed: boolean;
};

type PreparedManifestOutbox = {
  readonly kind: 'prepared_manifest';
  readonly operation: ActiveOperation;
  readonly transaction: ScopedProjectContextTransaction;
  readonly preparationId: string;
  readonly selectedPaths: readonly string[];
  readonly manifest: ProjectContextManifestV1;
};

type ConfirmedConsentOutbox = {
  readonly kind: 'confirmed_consent';
  readonly operation: ActiveOperation;
  readonly transaction: ScopedProjectContextTransaction;
  readonly preparationId: string;
  readonly selectedPaths: readonly string[];
  readonly manifest: ProjectContextManifestV1;
};

type DisabledOutbox = {
  readonly kind: 'disabled';
  readonly operation: ActiveOperation;
  readonly transaction: ScopedProjectContextTransaction;
  readonly cleanupSnapshotId: string | null;
};

type InspectionOutbox = {
  readonly kind: 'inspection';
  readonly operation: ActiveOperation;
  readonly resultingPhase: 'idle' | 'review' | 'blocked';
  readonly cleanupSnapshotId?: string;
  readonly cleanupPurpose?: 'candidate' | 'confirmed_drift';
};

type PersistenceOutbox =
  | PrepareIntentOutbox
  | PreparedManifestOutbox
  | ConfirmedConsentOutbox
  | DisabledOutbox
  | InspectionOutbox;

type ListOperation = ProjectContextControllerOwner & {
  readonly generation: number;
  readonly listGeneration: number;
  readonly query: string;
};

const completed: ProjectContextControllerOutcome = Object.freeze({
  status: 'completed',
});
const persistencePending: ProjectContextControllerOutcome = Object.freeze({
  status: 'persistence_pending',
  code: 'E_CONTEXT_PERSISTENCE',
});
const MAX_KNOWN_CANDIDATES = 5_000;
const knownErrorCodes: ReadonlySet<string> = new Set([
  ...PROJECT_CONTEXT_ERROR_CODES,
  ...PROJECT_CONTEXT_BRIDGE_ERROR_CODES,
]);

function blocked(
  code: ProjectContextControllerErrorCode,
): ProjectContextControllerOutcome {
  return { status: 'blocked', code };
}

function cleanupPending(
  code: ProjectContextControllerErrorCode,
): ProjectContextControllerOutcome {
  return { status: 'cleanup_pending', code };
}

function emptyList(): ProjectContextCandidateListState {
  return {
    query: '',
    candidates: [],
    nextCursor: null,
    loading: false,
    loadingMore: false,
  };
}

function initialState(): ProjectContextControllerState {
  return {
    phase: 'idle',
    owner: null,
    generation: 0,
    listGeneration: 0,
    list: emptyList(),
    selectedPaths: [],
    selectedCandidates: [],
    candidateManifest: null,
    candidatePreparationId: null,
    pendingPersistence: null,
    cleanupSnapshotId: null,
    failureCode: null,
  };
}

function orderedPaths(paths: readonly string[]): readonly string[] {
  return [...new Set(paths)].sort((left, right) =>
    left < right ? -1 : left > right ? 1 : 0,
  );
}

function normalizedQuery(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  let query = value.trim();
  for (let index = 0; index < query.length; index += 1) {
    const unit = query.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const low = query.charCodeAt(index + 1);
      if (low < 0xdc00 || low > 0xdfff) return null;
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return null;
    }
  }
  if (query.length > 256) {
    query = query.slice(0, 256);
    const last = query.charCodeAt(query.length - 1);
    if (last >= 0xd800 && last <= 0xdbff) query = query.slice(0, -1);
  }
  return query;
}

function dedupeCandidates(
  candidates: readonly Candidate[],
): readonly Candidate[] {
  const seen = new Set<string>();
  const output: Candidate[] = [];
  for (const candidate of candidates) {
    if (seen.has(candidate.path)) continue;
    seen.add(candidate.path);
    output.push(candidate);
  }
  return output;
}

function cloneCandidate(candidate: Candidate): Candidate {
  return {
    path: candidate.path,
    size: candidate.size,
    revision: candidate.revision,
    git_state: candidate.git_state,
    eligible: candidate.eligible,
    omission_reason: candidate.omission_reason,
  };
}

function cloneManifest(
  manifest: ProjectContextManifestV1,
): ProjectContextManifestV1 {
  return {
    ...manifest,
    included: manifest.included.map(item => ({ ...item })),
    omitted: manifest.omitted.map(item => ({ ...item })),
  };
}

function manifestV2ForController(
  manifest: ProjectContextManifestV2,
  root: WorkspaceRootRefV1,
  owner: ProjectContextControllerOwner,
): ProjectContextManifestV1 | null {
  if (
    !sameRoot(manifest.root, root) ||
    manifest.project_id !== owner.projectId ||
    manifest.project.project_id !== owner.projectId ||
    manifest.project.workspace_id !== root.workspace_id ||
    manifest.project.workspace_binding_revision !== root.binding_revision ||
    manifest.model_id !== owner.modelId ||
    manifest.conversation_id !== owner.runtimeContextId
  ) {
    return null;
  }
  return {
    schema_version: 1,
    snapshot_id: manifest.snapshot_id,
    project_id: manifest.project_id,
    project_name: manifest.project.display_name,
    branch: manifest.branch,
    head_oid: manifest.head_oid,
    clean: manifest.clean,
    conflicted: manifest.conflicted,
    captured_at: manifest.captured_at,
    policy_version: manifest.policy_version,
    provider_host: manifest.provider_configuration === undefined ? providerHostForModel(manifest.model_id) : providerBindingHost(manifest.provider_configuration),
    ...(manifest.provider_configuration === undefined ? {} : { provider_configuration: manifest.provider_configuration }),
    model: manifest.model_id,
    included: manifest.included.map(item => ({ ...item })),
    omitted: manifest.omitted.map(item => ({ ...item })),
    context_bytes: manifest.context_bytes,
    estimated_tokens: manifest.estimated_tokens,
    snapshot_sha256: manifest.snapshot_sha256,
    source_fingerprint: manifest.source_fingerprint,
  };
}

function consentV2ForController(
  consent: ProjectContextConsentV2,
  root: WorkspaceRootRefV1,
  manifest: ProjectContextManifestV1,
): ProjectContextConsentV1 | null {
  if (
    !sameRoot(consent.root, root) ||
    consent.workspace_id !== root.workspace_id ||
    consent.workspace_binding_revision !== root.binding_revision ||
    consent.snapshot_id !== manifest.snapshot_id ||
    consent.snapshot_sha256 !== manifest.snapshot_sha256
  ) {
    return null;
  }
  return {
    schema_version: 1,
    consent_receipt_id: consent.consent_receipt_id,
    snapshot_id: consent.snapshot_id,
    snapshot_sha256: consent.snapshot_sha256,
    confirmed_at: consent.confirmed_at,
  };
}

function pageV2ForController(
  page: ProjectContextCandidatePageV2,
  root: WorkspaceRootRefV1,
): ProjectContextCandidatePageV1 | null {
  if (
    !sameRoot(page.root, root) ||
    page.project.project_id !== root.project_id ||
    page.project.workspace_id !== root.workspace_id ||
    page.project.workspace_binding_revision !== root.binding_revision
  ) {
    return null;
  }
  return {
    schema_version: 1,
    project_id: root.project_id as string,
    candidates: page.candidates.map(candidate => ({ ...candidate })),
    next_cursor: page.next_cursor,
  };
}

function freezeCandidate(candidate: Candidate): Candidate {
  return Object.freeze(cloneCandidate(candidate));
}

function freezeManifest(
  manifest: ProjectContextManifestV1,
): ProjectContextManifestV1 {
  return Object.freeze({
    ...manifest,
    included: Object.freeze(
      manifest.included.map(item => Object.freeze({ ...item })),
    ),
    omitted: Object.freeze(
      manifest.omitted.map(item => Object.freeze({ ...item })),
    ),
  });
}

function exposedState(
  source: ProjectContextControllerState,
): ProjectContextControllerState {
  return Object.freeze({
    ...source,
    owner:
      source.owner === null
        ? null
        : Object.freeze({
            ...source.owner,
            root: Object.freeze(cloneRoot(source.owner.root)),
          }),
    list: Object.freeze({
      ...source.list,
      candidates: Object.freeze(source.list.candidates.map(freezeCandidate)),
    }),
    selectedPaths: Object.freeze([...source.selectedPaths]),
    selectedCandidates: Object.freeze(
      source.selectedCandidates.map(freezeCandidate),
    ),
    candidateManifest:
      source.candidateManifest === null
        ? null
        : freezeManifest(source.candidateManifest),
    pendingPersistence:
      source.pendingPersistence === null
        ? null
        : Object.freeze({ ...source.pendingPersistence }),
  });
}

function sameOwner(
  left: ProjectContextControllerOwner,
  right: ProjectContextControllerOwner,
): boolean {
  return (
    left.conversationId === right.conversationId &&
    left.projectId === right.projectId &&
    left.runtimeContextId === right.runtimeContextId &&
    left.modelId === right.modelId &&
    sameRoot(left.root, right.root)
  );
}

type DerivedWorkspaceRoot = {
  readonly root: WorkspaceRootRefV1 | null;
  readonly invalid: boolean;
};

function deriveWorkspaceRoot(conversation: {
  readonly workspaceId: string | null;
  readonly projectId: string | null;
  readonly workspaceBinding?: {
    readonly workspaceId: string;
    readonly bindingRevision: number;
    readonly projectId: string | null;
  } | null;
}): DerivedWorkspaceRoot {
  const binding = conversation.workspaceBinding;
  if (conversation.workspaceId === null) {
    return { root: null, invalid: binding !== undefined && binding !== null };
  }
  if (
    binding === undefined ||
    binding === null ||
    binding.workspaceId !== conversation.workspaceId ||
    binding.projectId !== conversation.projectId
  ) {
    return { root: null, invalid: true };
  }
  try {
    return {
      root: workspaceRoot(
        binding.workspaceId,
        binding.bindingRevision,
        binding.projectId,
      ),
      invalid: false,
    };
  } catch {
    return { root: null, invalid: true };
  }
}

function sameRoot(
  left: WorkspaceRootRefV1 | null | undefined,
  right: WorkspaceRootRefV1 | null | undefined,
): boolean {
  return left === null || left === undefined ||
      right === null || right === undefined
    ? left == null && right == null
    : left.workspace_id === right.workspace_id &&
        left.binding_revision === right.binding_revision &&
        left.project_id === right.project_id;
}

function cloneRoot(root: WorkspaceRootRefV1 | null): WorkspaceRootRefV1 | null {
  return root === null
    ? null
    : {
        schema_version: 1,
        workspace_id: root.workspace_id,
        binding_revision: root.binding_revision,
        project_id: root.project_id,
      };
}

function controllerError(error: unknown): ProjectContextControllerErrorCode {
  try {
    if (error instanceof ProjectContextBridgeError) return error.code;
    if (typeof error === 'object' && error !== null) {
      const descriptor = Object.getOwnPropertyDescriptor(error, 'code');
      if (
        descriptor !== undefined &&
        'value' in descriptor &&
        typeof descriptor.value === 'string' &&
        knownErrorCodes.has(descriptor.value)
      ) {
        return descriptor.value as ProjectContextBridgeErrorCode;
      }
    }
  } catch {
    // Hostile thrown values collapse to a stable value-free code.
  }
  return 'E_CONTEXT_NATIVE';
}

function validPreparationId(value: string): boolean {
  return value.length > 0 && value.length <= 128;
}

function matchingManifest(
  left: ProjectContextManifestV1,
  right: ProjectContextManifestV1,
): boolean {
  return (
    left.snapshot_id === right.snapshot_id &&
    left.snapshot_sha256 === right.snapshot_sha256 &&
    left.project_id === right.project_id &&
    left.model === right.model
  );
}

function matchingConsent(
  manifest: ProjectContextManifestV1,
  consent: ProjectContextConsentV1,
): boolean {
  return (
    consent.snapshot_id === manifest.snapshot_id &&
    consent.snapshot_sha256 === manifest.snapshot_sha256
  );
}

function contextPhase(context: ProjectContextState | null): 'idle' | 'review' | 'blocked' {
  if (context === null) return 'blocked';
  if (context.snapshot !== null && context.consent === null) return 'review';
  if (
    context.status === 'stale' ||
    context.status === 'error' ||
    context.status === 'unavailable'
  ) {
    return 'blocked';
  }
  return 'idle';
}

function publicPending(
  outbox: PersistenceOutbox,
): ProjectContextPendingPersistenceState {
  return outbox.kind === 'disabled'
    ? {
        kind: outbox.kind,
        cleanupSnapshotId: outbox.cleanupSnapshotId,
      }
    : { kind: outbox.kind };
}

export function createProjectContextController(
  dependencies: ProjectContextControllerDependencies,
): ProjectContextController {
  let state = initialState();
  let activeOperation: ActiveOperation | null = null;
  let operationSequence = 0;
  let persistenceOutbox: PersistenceOutbox | null = null;
  let scheduledSearch: ProjectContextSearchHandle | null = null;
  let scheduledSearchResolution:
    | ((outcome: ProjectContextControllerOutcome) => void)
    | null = null;
  let notifyingListeners = false;
  let cleanupPurpose:
    | 'disabled'
    | 'candidate'
    | 'confirmed_drift'
    | null = null;
  const knownCandidates = new Map<string, Candidate>();
  const listeners = new Set<(next: ProjectContextControllerState) => void>();

  const publish = (
    patch: Partial<ProjectContextControllerState>,
  ): ProjectContextControllerState => {
    state = { ...state, ...patch };
    const visible = exposedState(state);
    notifyingListeners = true;
    try {
      listeners.forEach(listener => {
        try {
          listener(visible);
        } catch {
          // Observers cannot interrupt a controller transaction or leak details.
        }
      });
    } finally {
      notifyingListeners = false;
    }
    return state;
  };

  const liveOwner = (): ProjectContextControllerOwner | null => {
    const conversationId = state.owner?.conversationId;
    if (conversationId === undefined) return null;
    const conversation = dependencies.chat.getState().conversations[conversationId];
    if (
      conversation === undefined ||
      conversation.projectId === null ||
      conversation.projectContext === null ||
      conversation.projectContext.projectId !== conversation.projectId
    ) {
      return null;
    }
    const derivedRoot = deriveWorkspaceRoot(conversation);
    // A null root is only allowed while the explicit legacy-project bootstrap
    // adapter is pending. Normal production Context state must already carry
    // the complete workspace binding and must never downgrade to V1 routing.
    if (
      derivedRoot.invalid ||
      (derivedRoot.root === null &&
        conversation.workspaceBootstrapState !== 'pending_legacy_project')
    ) {
      return null;
    }
    return {
      conversationId,
      projectId: conversation.projectId,
      runtimeContextId: conversation.runtimeContextId,
      modelId: conversation.modelId,
      root: cloneRoot(derivedRoot.root),
    };
  };

  const currentContext = (): ProjectContextState | null => {
    const owner = state.owner;
    if (owner === null) return null;
    return (
      dependencies.chat.getState().conversations[owner.conversationId]
        ?.projectContext ?? null
    );
  };

  const currentToken = (): ProjectContextActionToken | null => {
    if (state.owner === null) return null;
    const token = {
      generation: state.generation,
      ...state.owner,
      preparationId: state.candidatePreparationId,
      listGeneration: state.listGeneration,
    };
    // Preserve the legacy token's exact enumerable shape for unbound
    // project-context callers. Routed V2 owners keep the root enumerable so
    // render callbacks can capture and compare the authority explicitly.
    if (state.owner.root === null) {
      const legacyToken = { ...token };
      Object.defineProperty(legacyToken, 'root', {
        configurable: true,
        enumerable: false,
        value: undefined,
        writable: false,
      });
      return legacyToken as ProjectContextActionToken;
    }
    return token;
  };

  const validExpected = (
    expected: ProjectContextActionToken,
    requireListGeneration: boolean,
  ): boolean => {
    try {
      if (notifyingListeners) return false;
      const token = currentToken();
      const live = liveOwner();
      if (token === null || live === null || !sameOwner(token, live)) {
        return false;
      }
      return (
        expected.generation === token.generation &&
        expected.conversationId === token.conversationId &&
        expected.projectId === token.projectId &&
        expected.runtimeContextId === token.runtimeContextId &&
        expected.modelId === token.modelId &&
        sameRoot(expected.root, token.root) &&
        expected.preparationId === token.preparationId &&
        (!requireListGeneration ||
          expected.listGeneration === token.listGeneration)
      );
    } catch {
      return false;
    }
  };

  const beginOperation = (kind: OperationKind): ActiveOperation | null => {
    const owner = liveOwner();
    const expectedContext = currentContext();
    if (
      owner === null ||
      expectedContext === null ||
      activeOperation !== null
    ) {
      return null;
    }
    operationSequence += 1;
    const operation = {
      id: operationSequence,
      generation: state.generation,
      kind,
      expectedContext,
      ...owner,
    };
    activeOperation = operation;
    return operation;
  };

  const replaceOperationOwner = (
    operation: ActiveOperation,
    owner: ProjectContextControllerOwner,
  ): ActiveOperation => {
    const next = { ...operation, ...owner };
    if (activeOperation?.id === operation.id) activeOperation = next;
    return next;
  };

  const replaceOperationContext = (
    operation: ActiveOperation,
    expectedContext: ProjectContextState,
  ): ActiveOperation => {
    const next = { ...operation, expectedContext };
    if (activeOperation?.id === operation.id) activeOperation = next;
    return next;
  };

  const operationOwnerLive = (operation: ActiveOperation): boolean => {
    const live = liveOwner();
    return (
      activeOperation?.id === operation.id &&
      state.generation === operation.generation &&
      live !== null &&
      sameOwner(operation, live)
    );
  };

  const operationLive = (operation: ActiveOperation): boolean => {
    return (
      operationOwnerLive(operation) &&
      currentContext() === operation.expectedContext
    );
  };

  const finishOperation = (operation: ActiveOperation) => {
    if (activeOperation?.id === operation.id) activeOperation = null;
  };

  const hasReferences = (
    owner: ProjectContextControllerOwner,
    snapshotId?: string,
  ): boolean => {
    try {
      return (
        dependencies.snapshotReferences(owner.conversationId, snapshotId)
          .length > 0
      );
    } catch {
      return true;
    }
  };

  const externallyBlocked = (owner: ProjectContextControllerOwner): boolean => {
    try {
      return (
        dependencies.completionMutationBlocked(owner.conversationId) ||
        hasReferences(owner)
      );
    } catch {
      return true;
    }
  };

  const rejectStale = (): ProjectContextControllerOutcome =>
    blocked('E_CONTEXT_OWNER_STALE');

  const rejectBusy = (): ProjectContextControllerOutcome =>
    blocked('E_CONTEXT_BUSY');

  const destructiveJournalActive = (): boolean => {
    try {
      return (
        dependencies.chat.getState().projectContextDestructiveTransition !==
        null
      );
    } catch {
      return true;
    }
  };

  const setFailure = (
    code: ProjectContextControllerErrorCode,
  ): ProjectContextControllerOutcome => {
    publish({ phase: 'blocked', failureCode: code });
    return blocked(code);
  };

  const safePersist = async (): Promise<SessionDurabilityResult> => {
    try {
      const result = await dependencies.persistCurrent();
      if (
        result.status === 'committed' ||
        result.status === 'session_only' ||
        result.status === 'not_committed' ||
        result.status === 'unknown'
      ) {
        return result;
      }
    } catch {
      // Persist exceptions are projected to unknown durability.
    }
    return { status: 'unknown' };
  };

  const setOutbox = (outbox: PersistenceOutbox) => {
    if (
      persistenceOutbox !== null ||
      dependencies.maximumPendingPersistence !== 1
    ) {
      return false;
    }
    persistenceOutbox = outbox;
    publish({
      phase: 'persistence_pending',
      pendingPersistence: publicPending(outbox),
      failureCode: null,
    });
    return true;
  };

  const clearOutbox = (outbox: PersistenceOutbox) => {
    if (persistenceOutbox === outbox) {
      persistenceOutbox = null;
      publish({ pendingPersistence: null });
    }
  };

  const cancelScheduledSearch = () => {
    try {
      scheduledSearch?.cancel();
    } catch {
      // Scheduler cleanup is best-effort and never escapes the controller.
    }
    scheduledSearch = null;
    const resolve = scheduledSearchResolution;
    scheduledSearchResolution = null;
    resolve?.(blocked('E_CONTEXT_OWNER_STALE'));
  };

  const mutationScope = (
    owner: ProjectContextControllerOwner,
    expectedContext: ProjectContextState,
  ): ProjectContextMutationScope | null => {
    if (owner.runtimeContextId === null) return null;
    return {
      conversationId: owner.conversationId,
      projectId: owner.projectId,
      runtimeContextId: owner.runtimeContextId,
      modelId: owner.modelId,
      expectedContext,
    };
  };

  const safeDiscard = async (
    snapshotId: string,
    owner: ProjectContextControllerOwner,
  ): Promise<boolean> => {
    try {
      if (owner.root !== null) {
        if (typeof dependencies.native.discardV2 !== 'function') return false;
        await boundedNative(dependencies.native.discardV2({
          schema_version: 2,
          snapshot_id: snapshotId,
          root: cloneRoot(owner.root)!,
        }));
      } else {
        await boundedNative(dependencies.native.discard(snapshotId));
      }
      return true;
    } catch {
      // Stale-result disposal has no durable pointer to retry from.
      return false;
    }
  };

  const discardPreparedIfUnreferenced = async (
    operation: ActiveOperation,
    snapshotId: string,
  ): Promise<boolean> => {
    const conversation =
      dependencies.chat.getState().conversations[operation.conversationId];
    const referenced = hasReferences(operation, snapshotId);
    const latestConversation =
      dependencies.chat.getState().conversations[operation.conversationId];
    if (
      conversation?.projectContext?.snapshot?.snapshot_id === snapshotId ||
      latestConversation?.projectContext?.snapshot?.snapshot_id === snapshotId ||
      referenced
    ) {
      return false;
    }
    return safeDiscard(snapshotId, operation);
  };

  const cleanupSnapshot = async (
    operation: ActiveOperation,
    snapshotId: string | null,
    purpose: 'disabled' | 'candidate' | 'confirmed_drift',
  ): Promise<ProjectContextControllerOutcome> => {
    if (snapshotId === null) {
      cleanupPurpose = null;
      publish({
        phase: 'idle',
        cleanupSnapshotId: null,
        failureCode: null,
      });
      return completed;
    }
    if (
      currentContext()?.snapshot?.snapshot_id === snapshotId ||
      hasReferences(operation, snapshotId)
    ) {
      cleanupPurpose = purpose;
      publish({
        phase: 'cleanup_pending',
        cleanupSnapshotId: snapshotId,
        failureCode: 'E_CONTEXT_BUSY',
      });
      return cleanupPending('E_CONTEXT_BUSY');
    }
    cleanupPurpose = purpose;
    publish({ phase: 'disabling', cleanupSnapshotId: snapshotId });
    const referencedAfterPublish = hasReferences(operation, snapshotId);
    if (
      !operationLive(operation) ||
      currentContext()?.snapshot?.snapshot_id === snapshotId ||
      referencedAfterPublish
    ) {
      const code = operationOwnerLive(operation)
        ? 'E_CONTEXT_BUSY'
        : 'E_CONTEXT_OWNER_STALE';
      publish({
        phase: 'cleanup_pending',
        cleanupSnapshotId: snapshotId,
        failureCode: code,
      });
      return cleanupPending(code);
    }
    try {
      if (operation.root !== null) {
        if (typeof dependencies.native.discardV2 !== 'function') {
          return setFailure('E_CONTEXT_NATIVE');
        }
        await boundedNative(dependencies.native.discardV2({
          schema_version: 2,
          snapshot_id: snapshotId,
          root: cloneRoot(operation.root)!,
        }));
      } else {
        await boundedNative(dependencies.native.discard(snapshotId));
      }
      if (!operationLive(operation)) return rejectStale();
      const context = currentContext();
      cleanupPurpose = null;
      publish({
        phase:
          purpose === 'candidate'
            ? contextPhase(context)
            : purpose === 'confirmed_drift'
              ? 'blocked'
              : 'idle',
        cleanupSnapshotId: null,
        candidateManifest:
          purpose === 'candidate' ? null : state.candidateManifest,
        candidatePreparationId:
          purpose === 'candidate' ? null : state.candidatePreparationId,
        selectedPaths:
          purpose === 'candidate'
            ? context?.selectedPaths ?? []
            : state.selectedPaths,
        selectedCandidates:
          purpose === 'candidate'
            ? (context?.selectedPaths ?? []).flatMap(path => {
                const candidate = knownCandidates.get(path);
                return candidate === undefined ? [] : [candidate];
              })
            : state.selectedCandidates,
        failureCode: null,
      });
      return completed;
    } catch (error) {
      if (!operationLive(operation)) return rejectStale();
      const code = controllerError(error);
      cleanupPurpose = purpose;
      publish({
        phase: 'cleanup_pending',
        cleanupSnapshotId: snapshotId,
        failureCode: code,
      });
      return cleanupPending(code);
    }
  };

  const listOperationLive = (operation: ListOperation): boolean => {
    const owner = liveOwner();
    return (
      owner !== null &&
      sameOwner(operation, owner) &&
      state.generation === operation.generation &&
      state.listGeneration === operation.listGeneration &&
      state.list.query === operation.query
    );
  };

  const applyPage = (
    operation: ListOperation,
    page: ProjectContextCandidatePageV1,
    append: boolean,
  ): ProjectContextControllerOutcome => {
    if (!listOperationLive(operation)) return rejectStale();
    if (page.project_id !== operation.projectId) {
      return setFailure('E_CONTEXT_RESULT_INVALID');
    }
    const projectedPage = page.candidates.map(cloneCandidate);
    const candidates = dedupeCandidates(
      append
        ? [...state.list.candidates, ...projectedPage]
        : projectedPage,
    );
    for (const candidate of projectedPage) {
      if (
        !knownCandidates.has(candidate.path) &&
        knownCandidates.size < MAX_KNOWN_CANDIDATES
      ) {
        knownCandidates.set(candidate.path, candidate);
      }
    }
    const selectedCandidates = state.selectedPaths.flatMap(path => {
      const candidate = knownCandidates.get(path);
      return candidate === undefined ? [] : [candidate];
    });
    publish({
      list: {
        ...state.list,
        candidates,
        nextCursor: page.next_cursor,
        loading: false,
        loadingMore: false,
      },
      selectedCandidates,
      failureCode: null,
    });
    return completed;
  };

  const failList = (
    operation: ListOperation,
    error: unknown,
  ): ProjectContextControllerOutcome => {
    if (!listOperationLive(operation)) return rejectStale();
    const code = controllerError(error);
    publish({
      list: { ...state.list, loading: false, loadingMore: false },
      failureCode: code,
    });
    return blocked(code);
  };

  let continuePrepare: (
    outbox: PrepareIntentOutbox,
  ) => Promise<ProjectContextControllerOutcome>;
  let cancel: (
    expected: ProjectContextActionToken,
  ) => Promise<ProjectContextControllerOutcome>;
  let quarantineConfirmedDrift: (
    operation: ActiveOperation,
    snapshotId?: string,
  ) => Promise<ProjectContextControllerOutcome>;
  let retryPersistence: (
    expected: ProjectContextActionToken,
  ) => Promise<ProjectContextControllerOutcome>;
  let retryCleanup: (
    expected: ProjectContextActionToken,
  ) => Promise<ProjectContextControllerOutcome>;

  const settleCommittedOutbox = async (
    outbox: PersistenceOutbox,
  ): Promise<ProjectContextControllerOutcome> => {
    clearOutbox(outbox);
    switch (outbox.kind) {
      case 'prepare_intent':
        if (!operationLive(outbox.operation)) {
          return setFailure('E_CONTEXT_OWNER_STALE');
        }
        if (externallyBlocked(outbox.operation)) {
          return setFailure('E_CONTEXT_BUSY');
        }
        return continuePrepare(outbox);
      case 'prepared_manifest':
        if (!operationLive(outbox.operation)) {
          outbox.transaction.commit();
          await discardPreparedIfUnreferenced(
            outbox.operation,
            outbox.manifest.snapshot_id,
          );
          publish({
            candidateManifest: null,
            candidatePreparationId: null,
          });
          return setFailure('E_CONTEXT_OWNER_STALE');
        }
        outbox.transaction.commit();
        publish({
          phase: 'review',
          candidateManifest: outbox.manifest,
          candidatePreparationId: outbox.preparationId,
          selectedPaths: outbox.selectedPaths,
          failureCode: null,
        });
        return completed;
      case 'confirmed_consent':
        if (!operationLive(outbox.operation)) {
          outbox.transaction.commit();
          return quarantineConfirmedDrift(
            outbox.operation,
            outbox.manifest.snapshot_id,
          );
        }
        outbox.transaction.commit();
        publish({
          phase: 'idle',
          candidateManifest: null,
          candidatePreparationId: null,
          selectedPaths: outbox.selectedPaths,
          selectedCandidates: outbox.selectedPaths.flatMap(path => {
            const candidate = knownCandidates.get(path);
            return candidate === undefined ? [] : [candidate];
          }),
          failureCode: null,
        });
        return completed;
      case 'disabled':
        if (!operationLive(outbox.operation)) {
          outbox.transaction.commit();
          cleanupPurpose = 'disabled';
          publish({
            owner: liveOwner() ?? state.owner,
            phase: 'cleanup_pending',
            cleanupSnapshotId: outbox.cleanupSnapshotId,
            failureCode: 'E_CONTEXT_OWNER_STALE',
          });
          return cleanupPending('E_CONTEXT_OWNER_STALE');
        }
        outbox.transaction.commit();
        publish({
          candidateManifest: null,
          candidatePreparationId: null,
          selectedPaths: [],
          selectedCandidates: [],
        });
        return cleanupSnapshot(
          outbox.operation,
          outbox.cleanupSnapshotId,
          'disabled',
        );
      case 'inspection':
        if (!operationLive(outbox.operation)) {
          if (outbox.cleanupSnapshotId !== undefined) {
            return quarantineConfirmedDrift(
              outbox.operation,
              outbox.cleanupSnapshotId,
            );
          }
          return setFailure('E_CONTEXT_OWNER_STALE');
        }
        publish({ phase: outbox.resultingPhase, failureCode: null });
        if (outbox.cleanupSnapshotId !== undefined) {
          return cleanupSnapshot(
            outbox.operation,
            outbox.cleanupSnapshotId,
            outbox.cleanupPurpose ?? 'confirmed_drift',
          );
        }
        return completed;
    }
  };

  const persistOutbox = async (
    outbox: PersistenceOutbox,
  ): Promise<ProjectContextControllerOutcome> => {
    if (!setOutbox(outbox)) return rejectBusy();
    const durability = await safePersist();
    if (persistenceOutbox !== outbox) return rejectStale();
    if (durability.status === 'committed') {
      return settleCommittedOutbox(outbox);
    }
    if (outbox.kind === 'disabled' && durability.status === 'not_committed') {
      clearOutbox(outbox);
      outbox.transaction.rollback();
      publish({
        phase: 'blocked',
        cleanupSnapshotId: null,
        failureCode: 'E_CONTEXT_PERSISTENCE',
      });
      return blocked('E_CONTEXT_PERSISTENCE');
    }
    publish({
      phase: 'persistence_pending',
      failureCode: 'E_CONTEXT_PERSISTENCE',
    });
    return persistencePending;
  };

  continuePrepare = async (
    intent: PrepareIntentOutbox,
  ): Promise<ProjectContextControllerOutcome> => {
    const operation = intent.operation;
    if (!operationLive(operation)) return rejectStale();
    publish({ phase: 'preparing', failureCode: null });
    const selection: ProjectContextSelectionV1 = {
      schema_version: 1,
      project_id: operation.projectId,
      conversation_id: operation.runtimeContextId!,
      provider: providerForModel(operation.modelId),
      model: operation.modelId,
      policy: 'chat-read-v1',
      selected_paths: intent.selectedPaths,
    };
    let manifest: ProjectContextManifestV1;
    try {
      if (operation.root !== null) {
        if (typeof dependencies.native.prepareV2 !== 'function') {
          return setFailure('E_CONTEXT_NATIVE');
        }
        const v2Manifest = await boundedNative(dependencies.native.prepareV2({
          schema_version: 2,
          root: cloneRoot(operation.root)!,
          conversation_id: operation.runtimeContextId!,
          model_id: operation.modelId,
          policy: 'chat-read-v1',
          selected_paths: [...intent.selectedPaths],
        }));
        const projected = manifestV2ForController(
          v2Manifest,
          operation.root,
          operation,
        );
        if (projected === null) return setFailure('E_CONTEXT_RESULT_INVALID');
        manifest = cloneManifest(projected);
      } else {
        manifest = cloneManifest(await boundedNative(dependencies.native.prepare(selection)));
      }
    } catch (error) {
      if (!operationLive(operation)) return rejectStale();
      const code = controllerError(error);
      if (code === 'E_CONTEXT_CANCELLED') {
        publish({
          phase: 'idle',
          candidateManifest: null,
          candidatePreparationId: null,
          failureCode: null,
        });
        return completed;
      }
      return setFailure(code);
    }
    if (!operationLive(operation)) {
      await discardPreparedIfUnreferenced(operation, manifest.snapshot_id);
      return rejectStale();
    }
    if (
      manifest.project_id !== operation.projectId ||
      manifest.model !== operation.modelId
    ) {
      await discardPreparedIfUnreferenced(operation, manifest.snapshot_id);
      return setFailure('E_CONTEXT_RESULT_INVALID');
    }
    publish({
      candidateManifest: manifest,
      candidatePreparationId: intent.preparationId,
      selectedPaths: intent.selectedPaths,
    });
    if (intent.baselineWasConfirmed && intent.baselineSnapshotId !== null) {
      publish({ phase: 'review', failureCode: null });
      return completed;
    }
    const context = currentContext();
    const owner = liveOwner();
    if (context === null || owner === null) {
      await discardPreparedIfUnreferenced(operation, manifest.snapshot_id);
      return setFailure('E_CONTEXT_OWNER_STALE');
    }
    const scope = mutationScope(owner, context);
    if (scope === null) {
      await discardPreparedIfUnreferenced(operation, manifest.snapshot_id);
      return setFailure('E_CONTEXT_OWNER_STALE');
    }
    const transaction = dependencies.chat.replaceProjectContextPrepared(scope, {
      preparationId: intent.preparationId,
      selectedPaths: intent.selectedPaths,
      manifest,
    });
    if (transaction === null) {
      await discardPreparedIfUnreferenced(operation, manifest.snapshot_id);
      return setFailure('E_CONTEXT_OWNER_STALE');
    }
    const replacedContext = currentContext();
    if (replacedContext === null) {
      await discardPreparedIfUnreferenced(operation, manifest.snapshot_id);
      return setFailure('E_CONTEXT_OWNER_STALE');
    }
    const persistedOperation = replaceOperationContext(
      operation,
      replacedContext,
    );
    return persistOutbox({
      kind: 'prepared_manifest',
      operation: persistedOperation,
      transaction,
      preparationId: intent.preparationId,
      selectedPaths: intent.selectedPaths,
      manifest,
    });
  };

  const attach = async (
    conversationId: string,
  ): Promise<ProjectContextControllerOutcome> => {
    if (destructiveJournalActive()) return rejectBusy();
    if (notifyingListeners) return rejectBusy();
    if (activeOperation !== null && activeOperation.kind !== 'prepare') {
      return rejectBusy();
    }
    const recoveryOwner = liveOwner();
    if (
      state.owner !== null &&
      recoveryOwner !== null &&
      !sameOwner(state.owner, recoveryOwner)
    ) {
      const projectChanged = state.owner.projectId !== recoveryOwner.projectId;
      if (projectChanged) knownCandidates.clear();
      publish({
        owner: recoveryOwner,
        generation: state.generation + 1,
        listGeneration: state.listGeneration + 1,
        list: emptyList(),
        selectedPaths: projectChanged ? [] : state.selectedPaths,
        selectedCandidates: projectChanged ? [] : state.selectedCandidates,
      });
    }
    if (persistenceOutbox !== null) {
      const token = currentToken();
      if (token === null) return rejectBusy();
      const outcome = await retryPersistence(token);
      if (outcome.status !== 'completed') return outcome;
    }
    if (state.cleanupSnapshotId !== null) {
      const token = currentToken();
      if (token === null) return rejectBusy();
      const outcome = await retryCleanup(token);
      if (outcome.status !== 'completed') return outcome;
    }
    const attachedContext = currentContext();
    const candidateIsSerializedUnconfirmed =
      state.candidateManifest !== null &&
      attachedContext?.snapshot?.snapshot_id ===
        state.candidateManifest.snapshot_id &&
      attachedContext.consent === null;
    if (
      state.owner !== null &&
      state.candidateManifest !== null &&
      (state.owner.conversationId !== conversationId ||
        !candidateIsSerializedUnconfirmed)
    ) {
      const token = currentToken();
      if (token === null) return rejectStale();
      const outcome = await cancel(token);
      if (outcome.status !== 'completed') return outcome;
    }
    cancelScheduledSearch();
    activeOperation = null;
    knownCandidates.clear();
    const conversation = dependencies.chat.getState().conversations[conversationId];
    const generation = state.generation + 1;
    if (
      conversation === undefined ||
      conversation.projectId === null ||
      conversation.projectContext === null ||
      conversation.projectContext.projectId !== conversation.projectId
    ) {
      publish({
        ...initialState(),
        generation,
      });
      return completed;
    }
    const context = conversation.projectContext;
    const derivedRoot = deriveWorkspaceRoot(conversation);
    if (
      derivedRoot.invalid ||
      (derivedRoot.root === null &&
        conversation.workspaceBootstrapState !== 'pending_legacy_project')
    ) {
      publish({
        ...initialState(),
        generation,
        phase: 'blocked',
        failureCode: 'E_CONTEXT_OWNER_STALE',
      });
      return blocked('E_CONTEXT_OWNER_STALE');
    }
    const owner: ProjectContextControllerOwner = {
      conversationId,
      projectId: conversation.projectId,
      runtimeContextId: conversation.runtimeContextId,
      modelId: conversation.modelId,
      root: cloneRoot(derivedRoot.root),
    };
    publish({
      phase: context.snapshot === null ? contextPhase(context) : 'inspecting',
      owner,
      generation,
      listGeneration: 0,
      list: emptyList(),
      selectedPaths: context.selectedPaths,
      selectedCandidates: [],
      candidateManifest:
        context.snapshot !== null && context.consent === null
          ? context.snapshot
          : null,
      candidatePreparationId: context.activePreparationId,
      pendingPersistence: null,
      cleanupSnapshotId: null,
      failureCode: null,
    });
    if (context.snapshot === null) return completed;
    return inspectInternal();
  };

  const persistInspection = async (
    operation: ActiveOperation,
    resultingPhase: 'idle' | 'review' | 'blocked',
    cleanupSnapshotId?: string,
    cleanupKind?: 'candidate' | 'confirmed_drift',
  ): Promise<ProjectContextControllerOutcome> =>
    persistOutbox({
      kind: 'inspection',
      operation,
      resultingPhase,
      ...(cleanupSnapshotId === undefined ? {} : { cleanupSnapshotId }),
      ...(cleanupKind === undefined ? {} : { cleanupPurpose: cleanupKind }),
    });

  quarantineConfirmedDrift = async (
    operation: ActiveOperation,
    snapshotId?: string,
  ): Promise<ProjectContextControllerOutcome> => {
    if (
      activeOperation?.id !== operation.id ||
      state.generation !== operation.generation ||
      state.owner?.conversationId !== operation.conversationId
    ) {
      return rejectStale();
    }
    const live = liveOwner();
    if (live === null) return rejectStale();
    dependencies.chat.applyProjectContextAction(
      operation.conversationId,
      { type: 'project_changed' },
    );
    const invalidatedContext = currentContext();
    if (invalidatedContext === null) return rejectStale();
    let quarantinedOperation = replaceOperationOwner(operation, live);
    quarantinedOperation = replaceOperationContext(
      quarantinedOperation,
      invalidatedContext,
    );
    publish({
      owner: live,
      candidateManifest: null,
      candidatePreparationId: null,
      selectedPaths: invalidatedContext.selectedPaths,
      selectedCandidates: invalidatedContext.selectedPaths.flatMap(path => {
        const candidate = knownCandidates.get(path);
        return candidate === undefined ? [] : [candidate];
      }),
      failureCode: 'E_CONTEXT_OWNER_STALE',
    });
    return persistInspection(
      quarantinedOperation,
      'blocked',
      snapshotId,
      snapshotId === undefined ? undefined : 'confirmed_drift',
    );
  };

  const invalidateInspectedContext = async (
    operation: ActiveOperation,
    action: { readonly type: 'project_changed' | 'snapshot_missing' },
  ): Promise<ProjectContextControllerOutcome> => {
    if (!operationLive(operation)) return rejectStale();
    const changed = dependencies.chat.applyProjectContextAction(
      operation.conversationId,
      action,
    );
    if (!changed) {
      publish({ phase: 'blocked', failureCode: null });
      return completed;
    }
    const invalidatedContext = currentContext();
    if (invalidatedContext === null) return rejectStale();
    return persistInspection(
      replaceOperationContext(operation, invalidatedContext),
      'blocked',
    );
  };

  const acceptPreparedInspection = async (
    operation: ActiveOperation,
    inspection: ProjectContextInspectionV1,
  ): Promise<ProjectContextControllerOutcome> => {
    const context = currentContext();
    const owner = liveOwner();
    if (context === null || owner === null) return rejectStale();
    const preparationId =
      context.activePreparationId ?? dependencies.createPreparationId();
    if (!validPreparationId(preparationId)) {
      return setFailure('E_CONTEXT_RESULT_INVALID');
    }
    publish({
      candidateManifest: inspection.manifest,
      candidatePreparationId: preparationId,
      selectedPaths: context.selectedPaths,
    });
    if (
      context.consent === null &&
      context.snapshot !== null &&
      matchingManifest(context.snapshot, inspection.manifest)
    ) {
      publish({ phase: 'review', failureCode: null });
      return completed;
    }
    const scope = mutationScope(owner, context);
    if (scope === null) return setFailure('E_CONTEXT_OWNER_STALE');
    const transaction = dependencies.chat.replaceProjectContextPrepared(scope, {
      preparationId,
      selectedPaths: context.selectedPaths,
      manifest: inspection.manifest,
    });
    if (transaction === null) return setFailure('E_CONTEXT_OWNER_STALE');
    const replacedContext = currentContext();
    if (replacedContext === null) return setFailure('E_CONTEXT_OWNER_STALE');
    return persistOutbox({
      kind: 'prepared_manifest',
      operation: replaceOperationContext(operation, replacedContext),
      transaction,
      preparationId,
      selectedPaths: context.selectedPaths,
      manifest: inspection.manifest,
    });
  };

  const inspectInternal = async (): Promise<ProjectContextControllerOutcome> => {
    if (destructiveJournalActive()) return rejectBusy();
    if (activeOperation !== null || persistenceOutbox !== null) {
      return rejectBusy();
    }
    const context = currentContext();
    const snapshot = state.candidateManifest ?? context?.snapshot ?? null;
    if (snapshot === null) {
      publish({ phase: contextPhase(context), failureCode: null });
      return completed;
    }
    const operation = beginOperation('inspect');
    if (operation === null) return rejectStale();
    publish({ phase: 'inspecting', failureCode: null });
    if (!operationLive(operation)) {
      finishOperation(operation);
      return setFailure('E_CONTEXT_OWNER_STALE');
    }
    try {
      let inspection: ProjectContextInspectionV1;
      if (operation.root !== null) {
        if (typeof dependencies.native.inspectV2 !== 'function') {
          finishOperation(operation);
          return setFailure('E_CONTEXT_NATIVE');
        }
        const rawInspection = await boundedNative(dependencies.native.inspectV2({
          schema_version: 2,
          snapshot_id: snapshot.snapshot_id,
          root: cloneRoot(operation.root)!,
        }));
        const projectedManifest = manifestV2ForController(
          rawInspection.manifest,
          operation.root,
          operation,
        );
        if (projectedManifest === null) {
          finishOperation(operation);
          return setFailure('E_CONTEXT_RESULT_INVALID');
        }
        inspection = {
          schema_version: 1,
          state: rawInspection.state,
          manifest: cloneManifest(projectedManifest),
        };
      } else {
        const rawInspection = await dependencies.native.inspect(
          snapshot.snapshot_id,
        );
        inspection = {
          ...rawInspection,
          manifest: cloneManifest(rawInspection.manifest),
        };
      }
      if (!operationLive(operation)) return rejectStale();
      if (
        inspection.manifest.project_id !== operation.projectId ||
        inspection.manifest.model !== operation.modelId
      ) {
        return setFailure('E_CONTEXT_RESULT_INVALID');
      }
      if (inspection.state === 'prepared') {
        return acceptPreparedInspection(operation, inspection);
      }
      if (inspection.state === 'stale') {
        return invalidateInspectedContext(operation, {
          type: 'project_changed',
        });
      }
      const liveContext = currentContext();
      if (
        liveContext?.snapshot !== null &&
        liveContext?.snapshot !== undefined &&
        liveContext.consent !== null &&
        matchingManifest(liveContext.snapshot, inspection.manifest) &&
        matchingConsent(inspection.manifest, liveContext.consent)
      ) {
        publish({ phase: 'idle', failureCode: null });
        return completed;
      }
      return invalidateInspectedContext(operation, {
        type: 'project_changed',
      });
    } catch (error) {
      if (!operationLive(operation)) return rejectStale();
      const code = controllerError(error);
      if (code === 'E_CONTEXT_SNAPSHOT_MISSING') {
        return invalidateInspectedContext(operation, {
          type: 'snapshot_missing',
        });
      }
      return setFailure(code);
    } finally {
      finishOperation(operation);
    }
  };

  const prepare = async (
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome> => {
    if (destructiveJournalActive()) return rejectBusy();
    if (!validExpected(expected, true)) return rejectStale();
    const owner = liveOwner();
    if (
      owner === null ||
      activeOperation !== null ||
      persistenceOutbox !== null ||
      state.cleanupSnapshotId !== null ||
      state.candidateManifest !== null
    ) {
      return rejectBusy();
    }
    if (externallyBlocked(owner)) return rejectBusy();
    const selectedPaths = [...state.selectedPaths];
    const authorizedCandidates = selectedPaths.flatMap(path => {
      const candidate = knownCandidates.get(path);
      return candidate === undefined || !candidate.eligible ? [] : [candidate];
    });
    if (
      authorizedCandidates.length !== selectedPaths.length
    ) {
      return blocked('E_CONTEXT_REQUEST_INVALID');
    }
    const preparationId = dependencies.createPreparationId();
    if (!validPreparationId(preparationId)) {
      return setFailure('E_CONTEXT_RESULT_INVALID');
    }
    if (!validExpected(expected, true)) return rejectStale();
    const context = currentContext();
    if (context === null) return rejectStale();
    const baselineSnapshotId = context.snapshot?.snapshot_id ?? null;
    const baselineWasConfirmed = context.consent !== null;
    let operation = beginOperation('prepare');
    if (operation === null) return rejectBusy();
    publish({
      phase: 'preparing',
      candidatePreparationId: preparationId,
      candidateManifest: null,
      selectedCandidates: authorizedCandidates,
      failureCode: null,
    });
    if (!operationLive(operation)) {
      finishOperation(operation);
      publish({
        phase: 'blocked',
        candidatePreparationId: null,
        failureCode: 'E_CONTEXT_OWNER_STALE',
      });
      return rejectStale();
    }
    if (operation.runtimeContextId === null) {
      const runtimeContextId = dependencies.chat.ensureRuntimeContextId(
        owner.conversationId,
      );
      const updatedOwner = liveOwner();
      if (
        runtimeContextId === null ||
        updatedOwner === null ||
        updatedOwner.runtimeContextId !== runtimeContextId ||
        updatedOwner.projectId !== owner.projectId ||
        updatedOwner.modelId !== owner.modelId ||
        !sameRoot(updatedOwner.root, owner.root)
      ) {
        finishOperation(operation);
        return setFailure('E_CONTEXT_OWNER_STALE');
      }
      publish({ owner: updatedOwner });
      operation = replaceOperationOwner(operation, updatedOwner);
      if (!operationLive(operation)) {
        finishOperation(operation);
        return setFailure('E_CONTEXT_OWNER_STALE');
      }
      const outcome = await persistOutbox({
        kind: 'prepare_intent',
        operation,
        preparationId,
        selectedPaths,
        baselineSnapshotId,
        baselineWasConfirmed,
      });
      finishOperation(operation);
      return outcome;
    }
    const outcome = await continuePrepare({
      kind: 'prepare_intent',
      operation,
      preparationId,
      selectedPaths,
      baselineSnapshotId,
      baselineWasConfirmed,
    });
    finishOperation(operation);
    return outcome;
  };

  const confirm = async (
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome> => {
    if (destructiveJournalActive()) return rejectBusy();
    if (!validExpected(expected, true)) return rejectStale();
    const owner = liveOwner();
    const manifest = state.candidateManifest;
    const preparationId = state.candidatePreparationId;
    if (
      owner === null ||
      manifest === null ||
      preparationId === null ||
      state.phase !== 'review' ||
      activeOperation !== null ||
      persistenceOutbox !== null
    ) {
      return rejectBusy();
    }
    if (externallyBlocked(owner)) return rejectBusy();
    const operation = beginOperation('confirm');
    if (operation === null) return rejectBusy();
    publish({ phase: 'confirming', failureCode: null });
    if (!operationLive(operation)) {
      finishOperation(operation);
      return setFailure('E_CONTEXT_OWNER_STALE');
    }
    try {
      let receipt: ProjectContextConsentV1 | null;
      if (operation.root !== null) {
        if (typeof dependencies.native.confirmV2 !== 'function') {
          return setFailure('E_CONTEXT_NATIVE');
        }
        const v2Receipt = await boundedNative(dependencies.native.confirmV2({
          schema_version: 2,
          snapshot_id: manifest.snapshot_id,
          root: cloneRoot(operation.root)!,
        }));
        receipt = consentV2ForController(
          v2Receipt,
          operation.root,
          manifest,
        );
      } else {
        receipt = {
          ...(await boundedNative(dependencies.native.confirm(manifest.snapshot_id))),
        };
      }
      if (receipt === null || !matchingConsent(manifest, receipt)) {
        return setFailure('E_CONTEXT_RESULT_INVALID');
      }
      if (!operationLive(operation)) {
        return await quarantineConfirmedDrift(
          operation,
          manifest.snapshot_id,
        );
      }
      const context = currentContext();
      const live = liveOwner();
      if (context === null || live === null) return rejectStale();
      const scope = mutationScope(live, context);
      if (scope === null) return setFailure('E_CONTEXT_OWNER_STALE');
      const transaction = dependencies.chat.replaceProjectContextConfirmed(
        scope,
        {
          preparationId,
          selectedPaths: state.selectedPaths,
          manifest,
          consent: receipt,
        },
      );
      if (transaction === null) return setFailure('E_CONTEXT_OWNER_STALE');
      const confirmedContext = currentContext();
      if (confirmedContext === null) {
        return setFailure('E_CONTEXT_OWNER_STALE');
      }
      return await persistOutbox({
        kind: 'confirmed_consent',
        operation: replaceOperationContext(operation, confirmedContext),
        transaction,
        preparationId,
        selectedPaths: state.selectedPaths,
        manifest,
      });
    } catch (error) {
      if (!operationLive(operation)) return rejectStale();
      return setFailure(controllerError(error));
    } finally {
      finishOperation(operation);
    }
  };

  const disable = async (
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome> => {
    if (destructiveJournalActive()) return rejectBusy();
    if (!validExpected(expected, true)) return rejectStale();
    const owner = liveOwner();
    if (
      owner === null ||
      activeOperation !== null ||
      persistenceOutbox !== null ||
      state.cleanupSnapshotId !== null ||
      state.candidateManifest !== null
    ) {
      return rejectBusy();
    }
    if (externallyBlocked(owner)) return rejectBusy();
    const context = currentContext();
    if (context === null) return rejectStale();
    const scope = mutationScope(owner, context);
    if (scope === null) return setFailure('E_CONTEXT_OWNER_STALE');
    const operation = beginOperation('disable');
    if (operation === null) return rejectBusy();
    publish({ phase: 'disabling', failureCode: null });
    const transaction = dependencies.chat.disableProjectContext(scope);
    if (transaction === null) {
      finishOperation(operation);
      return setFailure('E_CONTEXT_OWNER_STALE');
    }
    const disabledContext = currentContext();
    if (disabledContext === null) {
      finishOperation(operation);
      return setFailure('E_CONTEXT_OWNER_STALE');
    }
    const outcome = await persistOutbox({
      kind: 'disabled',
      operation: replaceOperationContext(operation, disabledContext),
      transaction,
      cleanupSnapshotId: transaction.cleanupSnapshotId,
    });
    finishOperation(operation);
    return outcome;
  };

  retryPersistence = async (
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome> => {
    if (destructiveJournalActive()) return rejectBusy();
    if (!validExpected(expected, true)) return rejectStale();
    const outbox = persistenceOutbox;
    if (outbox === null) return rejectBusy();
    if (activeOperation !== null) return rejectBusy();
    const live = liveOwner();
    if (live === null) return rejectBusy();
    if (!sameOwner(live, outbox.operation)) {
      if (
        outbox.kind === 'prepare_intent' &&
        live.projectId !== outbox.operation.projectId
      ) {
        clearOutbox(outbox);
        publish({
          phase: 'blocked',
          candidateManifest: null,
          candidatePreparationId: null,
          selectedPaths: [],
          selectedCandidates: [],
          failureCode: 'E_CONTEXT_OWNER_STALE',
        });
        return completed;
      }
      if (outbox.kind === 'prepared_manifest') {
        clearOutbox(outbox);
        const rolledBack = outbox.transaction.rollback();
        const liveContext = currentContext();
        if (
          !rolledBack &&
          liveContext?.snapshot?.snapshot_id ===
            outbox.manifest.snapshot_id &&
          liveContext.consent === null
        ) {
          publish({ owner: live });
          const token = currentToken();
          return token === null ? rejectBusy() : cancel(token);
        }
        const recoveryOperation = beginOperation('retry_persistence');
        if (recoveryOperation === null) return rejectBusy();
        publish({ owner: live });
        let outcome: ProjectContextControllerOutcome;
        if (rolledBack) {
          outcome = await persistInspection(
            recoveryOperation,
            contextPhase(currentContext()),
            outbox.manifest.snapshot_id,
            'candidate',
          );
        } else if (
          liveContext?.snapshot?.snapshot_id === outbox.manifest.snapshot_id
        ) {
          outcome = await quarantineConfirmedDrift(recoveryOperation);
        } else {
          await discardPreparedIfUnreferenced(
            recoveryOperation,
            outbox.manifest.snapshot_id,
          );
          outcome = setFailure('E_CONTEXT_OWNER_STALE');
        }
        finishOperation(recoveryOperation);
        return outcome;
      }
      if (outbox.kind === 'confirmed_consent') {
        clearOutbox(outbox);
        outbox.transaction.commit();
        const recoveryOperation = beginOperation('retry_persistence');
        if (recoveryOperation === null) return rejectBusy();
        publish({ owner: live });
        const outcome = await quarantineConfirmedDrift(
          recoveryOperation,
          currentContext()?.snapshot?.snapshot_id ===
            outbox.manifest.snapshot_id
            ? undefined
            : outbox.manifest.snapshot_id,
        );
        finishOperation(recoveryOperation);
        return outcome;
      }
      publish({ owner: live });
    }
    if (currentContext() !== outbox.operation.expectedContext) {
      clearOutbox(outbox);
      switch (outbox.kind) {
        case 'confirmed_consent': {
          outbox.transaction.commit();
          const driftOperation = beginOperation('retry_persistence');
          if (driftOperation === null) return rejectBusy();
          const outcome = await quarantineConfirmedDrift(
            driftOperation,
            outbox.manifest.snapshot_id,
          );
          finishOperation(driftOperation);
          return outcome;
        }
        case 'prepared_manifest':
          outbox.transaction.commit();
          await discardPreparedIfUnreferenced(
            outbox.operation,
            outbox.manifest.snapshot_id,
          );
          publish({
            candidateManifest: null,
            candidatePreparationId: null,
          });
          return setFailure('E_CONTEXT_OWNER_STALE');
        case 'disabled':
          outbox.transaction.commit();
          cleanupPurpose = 'disabled';
          publish({
            owner: liveOwner() ?? state.owner,
            phase: 'cleanup_pending',
            cleanupSnapshotId: outbox.cleanupSnapshotId,
            failureCode: 'E_CONTEXT_OWNER_STALE',
          });
          return cleanupPending('E_CONTEXT_OWNER_STALE');
        case 'prepare_intent':
          publish({
            candidateManifest: null,
            candidatePreparationId: null,
          });
          return setFailure('E_CONTEXT_OWNER_STALE');
        case 'inspection':
          if (outbox.cleanupSnapshotId !== undefined) {
            const driftOperation = beginOperation('retry_persistence');
            if (driftOperation === null) return rejectBusy();
            const outcome = await quarantineConfirmedDrift(
              driftOperation,
              outbox.cleanupSnapshotId,
            );
            finishOperation(driftOperation);
            return outcome;
          }
          return setFailure('E_CONTEXT_OWNER_STALE');
      }
    }
    const operation = beginOperation('retry_persistence');
    if (operation === null) return rejectBusy();
    const retryOutbox = { ...outbox, operation } as PersistenceOutbox;
    persistenceOutbox = retryOutbox;
    publish({ pendingPersistence: publicPending(retryOutbox) });
    const durability = await safePersist();
    let outcome: ProjectContextControllerOutcome;
    if (persistenceOutbox !== retryOutbox) {
      outcome = rejectStale();
    } else if (durability.status === 'committed') {
      outcome = await settleCommittedOutbox(retryOutbox);
    } else if (
      retryOutbox.kind === 'disabled' &&
      durability.status === 'not_committed'
    ) {
      clearOutbox(retryOutbox);
      retryOutbox.transaction.rollback();
      publish({
        phase: 'blocked',
        cleanupSnapshotId: null,
        failureCode: 'E_CONTEXT_PERSISTENCE',
      });
      outcome = blocked('E_CONTEXT_PERSISTENCE');
    } else {
      publish({
        phase: 'persistence_pending',
        failureCode: 'E_CONTEXT_PERSISTENCE',
      });
      outcome = persistencePending;
    }
    finishOperation(operation);
    return outcome;
  };

  retryCleanup = async (
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome> => {
    if (destructiveJournalActive()) return rejectBusy();
    if (!validExpected(expected, true)) return rejectStale();
    if (
      state.cleanupSnapshotId === null ||
      persistenceOutbox !== null ||
      activeOperation !== null
    ) {
      return rejectBusy();
    }
    const live = liveOwner();
    if (live === null) return rejectBusy();
    publish({ owner: live });
    const operation = beginOperation('retry_cleanup');
    if (operation === null) return rejectBusy();
    const outcome = await cleanupSnapshot(
      operation,
      state.cleanupSnapshotId,
      cleanupPurpose ?? 'disabled',
    );
    finishOperation(operation);
    return outcome;
  };

  cancel = async (
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome> => {
    if (destructiveJournalActive()) return rejectBusy();
    if (!validExpected(expected, true)) return rejectStale();
    if (activeOperation !== null || persistenceOutbox !== null) {
      return rejectBusy();
    }
    cancelScheduledSearch();
    const manifest = state.candidateManifest;
    if (manifest === null) {
      publish({
        generation: state.generation + 1,
        phase: 'idle',
        listGeneration: state.listGeneration + 1,
        list: emptyList(),
        failureCode: null,
      });
      return completed;
    }
    const owner = liveOwner();
    if (owner === null || hasReferences(owner, manifest.snapshot_id)) {
      return rejectBusy();
    }
    publish({
      owner,
      generation: state.generation + 1,
      listGeneration: state.listGeneration + 1,
      list: { ...state.list, loading: false, loadingMore: false },
    });
    const context = currentContext();
    if (
      context?.snapshot?.snapshot_id === manifest.snapshot_id &&
      context.consent === null
    ) {
      const scope = mutationScope(owner, context);
      if (scope === null) return rejectStale();
      const operation = beginOperation('cancel');
      if (operation === null) return rejectBusy();
      const transaction = dependencies.chat.disableProjectContext(scope);
      if (transaction === null) {
        finishOperation(operation);
        return rejectStale();
      }
      const disabledContext = currentContext();
      if (disabledContext === null) {
        finishOperation(operation);
        return rejectStale();
      }
      const outcome = await persistOutbox({
        kind: 'disabled',
        operation: replaceOperationContext(operation, disabledContext),
        transaction,
        cleanupSnapshotId: transaction.cleanupSnapshotId,
      });
      finishOperation(operation);
      return outcome;
    }
    const operation = beginOperation('cancel');
    if (operation === null) return rejectBusy();
    const outcome = await cleanupSnapshot(
      operation,
      manifest.snapshot_id,
      'candidate',
    );
    finishOperation(operation);
    return outcome;
  };

  const search = async (
    expected: ProjectContextActionToken,
    query: string,
  ): Promise<ProjectContextControllerOutcome> => {
    if (destructiveJournalActive()) return rejectBusy();
    if (!validExpected(expected, false)) return rejectStale();
    const owner = liveOwner();
    if (owner === null) return rejectStale();
    cancelScheduledSearch();
    const normalized = normalizedQuery(query);
    if (normalized === null) return blocked('E_CONTEXT_REQUEST_INVALID');
    const listGeneration = state.listGeneration + 1;
    const operation: ListOperation = {
      ...owner,
      generation: state.generation,
      listGeneration,
      query: normalized,
    };
    publish({
      listGeneration,
      list: {
        query: normalized,
        candidates: [],
        nextCursor: null,
        loading: true,
        loadingMore: false,
      },
      failureCode: null,
    });
    return new Promise(resolve => {
      let started = false;
      scheduledSearchResolution = resolve;
      try {
        const handle = dependencies.scheduleSearch(180, () => {
          started = true;
          scheduledSearch = null;
          scheduledSearchResolution = null;
          if (!listOperationLive(operation)) {
            resolve(rejectStale());
            return;
          }
          const listed =
            operation.root !== null &&
            typeof dependencies.native.listCandidatesV2 === 'function'
              ? dependencies.native.listCandidatesV2({
                  schema_version: 1,
                  root: cloneRoot(operation.root)!,
                  query: normalized,
                  cursor: null,
                })
                  .then(page => {
                    const projected = pageV2ForController(page, operation.root!);
                    if (projected === null) {
                      throw new ProjectContextBridgeError(
                        'E_CONTEXT_RESULT_INVALID',
                      );
                    }
                    return projected;
                  })
              : operation.root !== null
                ? Promise.reject(
                    new ProjectContextBridgeError('E_CONTEXT_NATIVE'),
                  )
                : dependencies.native.listCandidates(
                    owner.projectId,
                    normalized,
                    null,
                  );
          listed
            .then(page => resolve(applyPage(operation, page, false)))
            .catch(error => resolve(failList(operation, error)));
        });
        scheduledSearch = started ? null : handle;
      } catch (error) {
        scheduledSearch = null;
        scheduledSearchResolution = null;
        resolve(failList(operation, error));
      }
    });
  };

  const loadMore = async (
    expected: ProjectContextActionToken,
  ): Promise<ProjectContextControllerOutcome> => {
    if (destructiveJournalActive()) return rejectBusy();
    if (!validExpected(expected, true)) return rejectStale();
    const owner = liveOwner();
    const cursor = state.list.nextCursor;
    if (owner === null) return rejectStale();
    if (cursor === null) return completed;
    if (state.list.loading || state.list.loadingMore) return rejectBusy();
    const listGeneration = state.listGeneration + 1;
    const operation: ListOperation = {
      ...owner,
      generation: state.generation,
      listGeneration,
      query: state.list.query,
    };
    publish({
      listGeneration,
      list: { ...state.list, loadingMore: true },
      failureCode: null,
    });
    try {
      let page: ProjectContextCandidatePageV1;
      if (operation.root !== null) {
        if (typeof dependencies.native.listCandidatesV2 !== 'function') {
          return setFailure('E_CONTEXT_NATIVE');
        }
        const v2Page = await boundedNative(dependencies.native.listCandidatesV2({
          schema_version: 1,
          root: cloneRoot(operation.root)!,
          query: operation.query,
          cursor,
        }));
        const projected = pageV2ForController(v2Page, operation.root);
        if (projected === null) return setFailure('E_CONTEXT_RESULT_INVALID');
        page = projected;
      } else {
        page = await boundedNative(dependencies.native.listCandidates(
          owner.projectId,
          operation.query,
          cursor,
        ));
      }
      return applyPage(operation, page, true);
    } catch (error) {
      return failList(operation, error);
    } finally {
      // setFailure and failList publish a phase and nothing else, so a failed
      // page left this set. Load more then refuses for good and Prepare stays
      // disabled with it, which the sheet gives no way to undo.
      if (state.list.loadingMore) {
        publish({ list: { ...state.list, loadingMore: false } });
      }
    }
  };

  const setSelectedPaths = (
    expected: ProjectContextActionToken,
    paths: readonly string[],
  ): ProjectContextControllerOutcome => {
    if (destructiveJournalActive()) return rejectBusy();
    if (!validExpected(expected, true)) return rejectStale();
    const owner = liveOwner();
    if (
      owner === null ||
      activeOperation !== null ||
      persistenceOutbox !== null ||
      state.cleanupSnapshotId !== null ||
      state.candidateManifest !== null ||
      externallyBlocked(owner)
    ) {
      return rejectBusy();
    }
    try {
      if (!Array.isArray(paths)) {
        return blocked('E_CONTEXT_REQUEST_INVALID');
      }
      const selectedPaths = orderedPaths(paths);
      if (selectedPaths.length === 0 && (knownCandidates.size > 0 || state.listGeneration === 0)) {
        return blocked('E_CONTEXT_REQUEST_INVALID');
      }
      const selectedCandidates = selectedPaths.flatMap(path => {
        if (typeof path !== 'string') return [];
        const candidate = knownCandidates.get(path);
        return candidate === undefined || !candidate.eligible ? [] : [candidate];
      });
      if (selectedCandidates.length !== selectedPaths.length) {
        return blocked('E_CONTEXT_REQUEST_INVALID');
      }
      publish({
        generation: state.generation + 1,
        listGeneration: state.listGeneration + 1,
        list: { ...state.list, loading: false, loadingMore: false },
        selectedPaths,
        selectedCandidates,
        failureCode: null,
      });
      return completed;
    } catch {
      return blocked('E_CONTEXT_REQUEST_INVALID');
    }
  };

  const navigationAllowed = (): boolean =>
    !destructiveJournalActive() &&
    !notifyingListeners &&
    activeOperation === null &&
    persistenceOutbox === null &&
    state.cleanupSnapshotId === null &&
    state.candidateManifest === null;

  const deletionAllowed = (conversationId: string): boolean => {
    if (!navigationAllowed()) return false;
    const context =
      dependencies.chat.getState().conversations[conversationId]
        ?.projectContext;
    return context === undefined || context === null || context.snapshot === null;
  };

  return {
    getState: () => exposedState(state),
    subscribe: listener => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    getActionToken: currentToken,
    attachConversation: attach,
    reconcileHydrated: attach,
    search,
    loadMore,
    setSelectedPaths,
    prepare,
    confirm,
    inspect: async expected => {
      if (destructiveJournalActive()) return rejectBusy();
      if (!validExpected(expected, true)) return rejectStale();
      return inspectInternal();
    },
    disable,
    retryPersistence,
    retryCleanup,
    cancel,
    beforeConversationChange: async _conversationId => navigationAllowed(),
    beforeConversationDelete: async conversationId =>
      deletionAllowed(conversationId),
  };
}
