import {
  createProjectContextController,
  type ProjectContextControllerDependencies,
} from '../src/project-context/ProjectContextController';
import {
  createProjectContextState,
  projectContextReducer,
  type ProjectContextAction,
  type ProjectContextCandidatePageV1,
  type ProjectContextCandidatePageV2,
  type ProjectContextConsentV1,
  type ProjectContextManifestV2,
  type ProjectContextManifestV1,
  type ProjectContextState,
} from '../src/project-context';
import { ProjectContextBridgeError } from '../src/native/LocalProjectContext';
import {
  CHAT_STATE_SCHEMA_VERSION,
  type ChatState,
  type ChatStore,
  type Conversation,
  type ProjectContextMutationScope,
} from '../src/state';
import type { SessionDurabilityResult } from '../src/completion/SessionPersistence';

const PROJECT_ID = '11111111-1111-4111-8111-111111111111';
const OTHER_PROJECT_ID = '22222222-2222-4222-8222-222222222222';
const RUNTIME_CONTEXT_ID = '33333333-3333-4333-8333-333333333333';
const OTHER_RUNTIME_CONTEXT_ID = '44444444-4444-4444-8444-444444444444';
const SNAPSHOT_A = '55555555-5555-4555-8555-555555555555';
const CONSENT_A = '66666666-6666-4666-8666-666666666666';
const SNAPSHOT_B = '77777777-7777-4777-8777-777777777777';
const CONSENT_B = '88888888-8888-4888-8888-888888888888';
const PREPARATION_ID = '99999999-9999-4999-8999-999999999999';
const SNAPSHOT_C = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const CONSENT_C = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const SNAPSHOT_D = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const CONSENT_D = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const CONVERSATION_ID = 'conversation-a';
const OTHER_CONVERSATION_ID = 'conversation-b';
const NOW = '2026-08-28T08:00:00.000Z';
const LATER = '2026-08-28T08:00:01.000Z';

type Deferred<T> = {
  readonly promise: Promise<T>;
  readonly resolve: (value: T) => void;
  readonly reject: (error: unknown) => void;
};

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function manifest(
  snapshotId: string,
  overrides: Partial<ProjectContextManifestV1> = {},
): ProjectContextManifestV1 {
  const snapshotSha256 = snapshotId === SNAPSHOT_A ? 'a'.repeat(64) : 'b'.repeat(64);
  return {
    schema_version: 1,
    snapshot_id: snapshotId,
    project_id: PROJECT_ID,
    project_name: 'demo',
    branch: 'main',
    head_oid: 'c'.repeat(40),
    clean: true,
    conflicted: false,
    captured_at: snapshotId === SNAPSHOT_A ? NOW : LATER,
    policy_version: 'chat-read-v1.0.0',
    provider_host: 'api.deepseek.com',
    model: 'deepseek-v4-flash',
    included: [
      {
        path: snapshotId === SNAPSHOT_A ? 'README.md' : 'src/index.ts',
        source: 'tracked_file',
        bytes: 12,
        sha256: 'd'.repeat(64),
      },
    ],
    omitted: [],
    context_bytes: 12,
    estimated_tokens: 3,
    snapshot_sha256: snapshotSha256,
    source_fingerprint: 'e'.repeat(64),
    ...overrides,
  };
}

function manifestV2(
  root: {
    readonly schema_version: 1;
    readonly workspace_id: string;
    readonly binding_revision: number;
    readonly project_id: string;
  },
  snapshotId = SNAPSHOT_A,
): ProjectContextManifestV2 {
  const legacy = manifest(snapshotId);
  return {
    schema_version: 2,
    snapshot_id: legacy.snapshot_id,
    root,
    project: {
      schema_version: 2,
      project_id: root.project_id,
      workspace_id: root.workspace_id,
      workspace_binding_revision: root.binding_revision,
      display_name: legacy.project_name,
      git_topology: 'private_split_gitdir',
    },
    project_id: root.project_id,
    conversation_id: RUNTIME_CONTEXT_ID,
    model_id: legacy.model,
    policy: 'chat-read-v1',
    branch: legacy.branch,
    head_oid: legacy.head_oid,
    clean: legacy.clean,
    conflicted: legacy.conflicted,
    captured_at: legacy.captured_at,
    policy_version: legacy.policy_version,
    included: legacy.included.map(item => ({ ...item })),
    omitted: legacy.omitted.map(item => ({ ...item })),
    context_bytes: legacy.context_bytes,
    estimated_tokens: legacy.estimated_tokens,
    snapshot_sha256: legacy.snapshot_sha256,
    source_fingerprint: legacy.source_fingerprint,
  };
}

function consent(
  snapshotId: string,
  receiptId: string,
): ProjectContextConsentV1 {
  return {
    schema_version: 1,
    consent_receipt_id: receiptId,
    snapshot_id: snapshotId,
    snapshot_sha256:
      snapshotId === SNAPSHOT_A ? 'a'.repeat(64) : 'b'.repeat(64),
    confirmed_at: snapshotId === SNAPSHOT_A ? NOW : LATER,
  };
}

function readyContext(
  snapshotId = SNAPSHOT_A,
  receiptId = CONSENT_A,
): ProjectContextState {
  const checking = projectContextReducer(createProjectContextState(PROJECT_ID), {
    type: 'checking',
    preparationId: PREPARATION_ID,
  });
  const prepared = projectContextReducer(checking, {
    type: 'prepared',
    preparationId: PREPARATION_ID,
    manifest: manifest(snapshotId),
  });
  return projectContextReducer(prepared, {
    type: 'confirmed',
    preparationId: PREPARATION_ID,
    manifest: manifest(snapshotId),
    consent: consent(snapshotId, receiptId),
  });
}

function conversation(
  id: string,
  context: ProjectContextState,
  runtimeContextId: string | null,
  projectId = PROJECT_ID,
): Conversation {
  return {
    id,
    projectId,
    workspaceId: null,
    workspaceBootstrapState:
      projectId === null ? 'none' : 'pending_legacy_project',
    runtimeContextId,
    projectContext: context,
    title: 'Project chat',
    titleSource: 'manual',
    modelId: 'deepseek-v4-flash',
    thinkingMode: 'high',
    messages: [],
    turns: [],
    attempts: [],
    createdAt: NOW,
    updatedAt: NOW,
  };
}

function page(
  query: string,
  nextCursor: string | null = null,
): ProjectContextCandidatePageV1 {
  return {
    schema_version: 1,
    project_id: PROJECT_ID,
    candidates: [
      {
        path: `${query || 'root'}.ts`,
        size: 12,
        revision: 'f'.repeat(40),
        git_state: 'unchanged',
        eligible: true,
        omission_reason: null,
      },
    ],
    next_cursor: nextCursor,
  };
}

type StoreHarness = {
  readonly store: ChatStore;
  readonly ensureRuntimeContextId: jest.Mock;
  readonly applyProjectContextAction: jest.Mock;
  readonly replacePrepared: jest.Mock;
  readonly replaceConfirmed: jest.Mock;
  readonly disable: jest.Mock;
  readonly transactions: Array<{
    readonly commit: jest.Mock;
    readonly rollback: jest.Mock;
  }>;
  readonly serializeContext: (conversationId?: string) => string;
  readonly mutateConversation: (
    conversationId: string,
    patch: Partial<
      Pick<
        Conversation,
        | 'projectId'
        | 'runtimeContextId'
        | 'modelId'
        | 'workspaceId'
        | 'workspaceBinding'
        | 'workspaceBootstrapState'
      >
    >,
  ) => void;
  readonly replaceContext: (
    conversationId: string,
    context: ProjectContextState,
  ) => void;
  readonly installDestructiveJournal: () => void;
};

function storeHarness(options: {
  readonly ready?: boolean;
  readonly runtimeContextId?: string | null;
} = {}): StoreHarness {
  let state: ChatState = {
    schemaVersion: CHAT_STATE_SCHEMA_VERSION,
    projectContextDestructiveEpoch: 0,
    projectContextDestructiveTransition: null,
    conversations: {
      [CONVERSATION_ID]: conversation(
        CONVERSATION_ID,
        options.ready ? readyContext() : createProjectContextState(PROJECT_ID),
        options.runtimeContextId === undefined
          ? options.ready
            ? RUNTIME_CONTEXT_ID
            : null
          : options.runtimeContextId,
      ),
      [OTHER_CONVERSATION_ID]: conversation(
        OTHER_CONVERSATION_ID,
        createProjectContextState(OTHER_PROJECT_ID),
        OTHER_RUNTIME_CONTEXT_ID,
        OTHER_PROJECT_ID,
      ),
    },
    conversationOrder: [CONVERSATION_ID, OTHER_CONVERSATION_ID],
    selectedConversationId: CONVERSATION_ID,
  };
  const listeners = new Set<(next: ChatState) => void>();
  const transactions: StoreHarness['transactions'] = [];

  const replaceConversation = (
    conversationId: string,
    nextContext: ProjectContextState,
  ) => {
    const current = state.conversations[conversationId];
    if (current === undefined) return false;
    state = {
      ...state,
      conversations: {
        ...state.conversations,
        [conversationId]: { ...current, projectContext: nextContext },
      },
    };
    listeners.forEach(listener => listener(state));
    return true;
  };

  const transaction = (
    conversationId: string,
    previous: ProjectContextState,
    next: ProjectContextState,
    cleanupSnapshotId?: string | null,
  ) => {
    let settled = false;
    const appliedConversation = state.conversations[conversationId];
    const previousConversation =
      appliedConversation === undefined
        ? undefined
        : { ...appliedConversation, projectContext: previous };
    const commit = jest.fn(() => {
      if (settled) return false;
      settled = true;
      return state.conversations[conversationId] === appliedConversation;
    });
    const rollback = jest.fn(() => {
      if (settled) return false;
      settled = true;
      if (
        appliedConversation === undefined ||
        previousConversation === undefined ||
        state.conversations[conversationId] !== appliedConversation
      ) {
        return false;
      }
      state = {
        ...state,
        conversations: {
          ...state.conversations,
          [conversationId]: previousConversation,
        },
      };
      listeners.forEach(listener => listener(state));
      return true;
    });
    transactions.push({ commit, rollback });
    return {
      conversationId,
      previousSnapshotId: previous.snapshot?.snapshot_id ?? null,
      nextSnapshotId: next.snapshot?.snapshot_id ?? null,
      ...(cleanupSnapshotId === undefined ? {} : { cleanupSnapshotId }),
      commit,
      rollback,
    };
  };

  const ensureRuntimeContextId = jest.fn((conversationId: string) => {
    const current = state.conversations[conversationId];
    if (current === undefined || current.projectId === null) return null;
    if (current.runtimeContextId !== null) return current.runtimeContextId;
    state = {
      ...state,
      conversations: {
        ...state.conversations,
        [conversationId]: {
          ...current,
          runtimeContextId: RUNTIME_CONTEXT_ID,
        },
      },
    };
    listeners.forEach(listener => listener(state));
    return RUNTIME_CONTEXT_ID;
  });

  const applyProjectContextAction = jest.fn(
    (conversationId: string, action: ProjectContextAction) => {
      const current = state.conversations[conversationId]?.projectContext;
      if (current === null || current === undefined) return false;
      const next = projectContextReducer(current, action);
      return next === current ? false : replaceConversation(conversationId, next);
    },
  );

  const replacePrepared = jest.fn(
    (
      scope: ProjectContextMutationScope,
      input: {
        preparationId: string;
        selectedPaths: readonly string[];
        manifest: ProjectContextManifestV1;
      },
    ) => {
      const current = state.conversations[scope.conversationId]?.projectContext;
      if (current === null || current === undefined || current !== scope.expectedContext) {
        return null;
      }
      let next = projectContextReducer(current, {
        type: 'selection_changed',
        selectedPaths: input.selectedPaths,
      });
      next = projectContextReducer(next, {
        type: 'checking',
        preparationId: input.preparationId,
      });
      next = projectContextReducer(next, {
        type: 'prepared',
        preparationId: input.preparationId,
        manifest: input.manifest,
      });
      if (!replaceConversation(scope.conversationId, next)) return null;
      return transaction(scope.conversationId, current, next);
    },
  );

  const replaceConfirmed = jest.fn(
    (
      scope: ProjectContextMutationScope,
      input: {
        preparationId: string;
        selectedPaths: readonly string[];
        manifest: ProjectContextManifestV1;
        consent: ProjectContextConsentV1;
      },
    ) => {
      const current = state.conversations[scope.conversationId]?.projectContext;
      if (current === null || current === undefined || current !== scope.expectedContext) {
        return null;
      }
      const next: ProjectContextState = {
        schemaVersion: 1,
        projectId: scope.projectId,
        status: input.manifest.omitted.length > 0 ? 'partial' : 'ready',
        selectedPaths: [...input.selectedPaths],
        activePreparationId: null,
        snapshot: input.manifest,
        consent: input.consent,
        staleReason: null,
        errorCode: null,
      };
      if (!replaceConversation(scope.conversationId, next)) return null;
      return transaction(scope.conversationId, current, next);
    },
  );

  const disable = jest.fn((scope: ProjectContextMutationScope) => {
    const current = state.conversations[scope.conversationId]?.projectContext;
    if (current === null || current === undefined || current !== scope.expectedContext) {
      return null;
    }
    const next = createProjectContextState(scope.projectId);
    if (!replaceConversation(scope.conversationId, next)) return null;
    return transaction(
      scope.conversationId,
      current,
      next,
      current.snapshot?.snapshot_id ?? null,
    );
  });

  const store = {
    getState: () => state,
    subscribe: (listener: (next: ChatState) => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    ensureRuntimeContextId,
    applyProjectContextAction,
    replaceProjectContextPrepared: replacePrepared,
    replaceProjectContextConfirmed: replaceConfirmed,
    disableProjectContext: disable,
  } as unknown as ChatStore;

  return {
    store,
    ensureRuntimeContextId,
    applyProjectContextAction,
    replacePrepared,
    replaceConfirmed,
    disable,
    transactions,
    serializeContext: (conversationId = CONVERSATION_ID) =>
      JSON.stringify(state.conversations[conversationId]?.projectContext),
    mutateConversation: (conversationId, patch) => {
      const current = state.conversations[conversationId];
      if (current === undefined) throw new Error('missing conversation fixture');
      state = {
        ...state,
        conversations: {
          ...state.conversations,
          [conversationId]: { ...current, ...patch },
        },
      };
      listeners.forEach(listener => listener(state));
    },
    replaceContext: (conversationId, context) => {
      if (!replaceConversation(conversationId, context)) {
        throw new Error('missing conversation fixture');
      }
    },
    installDestructiveJournal: () => {
      const source = state.conversations[CONVERSATION_ID]!;
      const snapshot = source.projectContext!.snapshot!;
      state = {
        ...state,
        projectContextDestructiveEpoch: 1,
        projectContextDestructiveTransition: {
          schemaVersion: 1,
          lifecycleId: SNAPSHOT_D,
          epoch: 1,
          action: 'unbind',
          phase: 'intent',
          conversationId: CONVERSATION_ID,
          sourceProjectId: PROJECT_ID,
          sourceRuntimeContextId: source.runtimeContextId,
          sourceModelId: source.modelId,
          snapshotId: snapshot.snapshot_id,
          snapshotSha256: snapshot.snapshot_sha256,
          consentReceiptId:
            source.projectContext?.consent?.consent_receipt_id ?? null,
          targetProjectId: null,
          createdAt: NOW,
          updatedAt: NOW,
        },
      };
      listeners.forEach(listener => listener(state));
    },
  };
}

type NativeHarness = {
  readonly listCandidates: jest.Mock;
  readonly listCandidatesV2?: jest.Mock;
  readonly prepareV2?: jest.Mock;
  readonly confirmV2?: jest.Mock;
  readonly inspectV2?: jest.Mock;
  readonly discardV2?: jest.Mock;
  readonly prepare: jest.Mock;
  readonly confirm: jest.Mock;
  readonly inspect: jest.Mock;
  readonly discard: jest.Mock;
};

type ControllerHarness = {
  readonly controller: ReturnType<typeof createProjectContextController>;
  readonly store: StoreHarness;
  readonly native: NativeHarness;
  readonly ensureRuntimeContextId: jest.Mock;
  readonly replacePrepared: jest.Mock;
  readonly disable: jest.Mock;
  readonly persistCurrent: jest.Mock<Promise<SessionDurabilityResult>, []>;
  readonly persistedContexts: string[];
  readonly completionMutationBlocked: jest.Mock;
  readonly snapshotReferences: jest.Mock;
};

function controllerHarness(options: {
  readonly ready?: boolean;
  readonly runtimeContextId?: string | null;
  readonly durability?: readonly SessionDurabilityResult[];
  readonly native?: Partial<NativeHarness>;
  readonly completionMutationBlocked?: boolean;
  readonly snapshotReferences?: readonly unknown[];
  readonly scheduleSearch?: ProjectContextControllerDependencies['scheduleSearch'];
} = {}): ControllerHarness {
  const store = storeHarness({
    ready: options.ready,
    runtimeContextId: options.runtimeContextId,
  });
  const native: NativeHarness = {
    listCandidates: jest.fn(async (_projectId, query) => page(query)),
    prepare: jest.fn(async () => manifest(SNAPSHOT_B)),
    confirm: jest.fn(async () => consent(SNAPSHOT_B, CONSENT_B)),
    inspect: jest.fn(async (snapshotId: string) => ({
      schema_version: 1,
      state: snapshotId === SNAPSHOT_A ? 'confirmed' : 'prepared',
      manifest: manifest(snapshotId),
    })),
    discard: jest.fn(async () => ({ schema_version: 1, status: 'discarded' })),
    ...options.native,
  };
  const statuses = [...(options.durability ?? [])];
  const persistedContexts: string[] = [];
  const persistCurrent = jest.fn(async () => {
    persistedContexts.push(store.serializeContext());
    return statuses.shift() ?? { status: 'committed' as const };
  });
  const completionMutationBlocked = jest.fn(
    () => options.completionMutationBlocked === true,
  );
  const snapshotReferences = jest.fn(
    () => options.snapshotReferences ?? [],
  );
  const dependencies = {
    chat: store.store,
    native,
    persistCurrent,
    createPreparationId: () => PREPARATION_ID,
    completionMutationBlocked,
    snapshotReferences,
    scheduleSearch:
      options.scheduleSearch ??
      ((_delay: number, operation: () => void) => {
        operation();
        return { cancel: jest.fn() };
      }),
    maximumPendingPersistence: 1,
  } as unknown as ProjectContextControllerDependencies;
  return {
    controller: createProjectContextController(dependencies),
    store,
    native,
    ensureRuntimeContextId: store.ensureRuntimeContextId,
    replacePrepared: store.replacePrepared,
    disable: store.disable,
    persistCurrent,
    persistedContexts,
    completionMutationBlocked,
    snapshotReferences,
  };
}

async function attach(
  harness: ControllerHarness,
  conversationId = CONVERSATION_ID,
) {
  await harness.controller.attachConversation(conversationId);
  return harness.controller.getState();
}

function actionToken(harness: ControllerHarness) {
  const token = harness.controller.getActionToken();
  if (token === null) throw new Error('controller has no action owner');
  return token;
}

async function selectKnownPath(
  harness: ControllerHarness,
  path = 'src/index.ts',
) {
  harness.native.listCandidates.mockResolvedValueOnce({
    schema_version: 1,
    project_id: PROJECT_ID,
    candidates: [
      {
        path,
        size: 12,
        revision: 'f'.repeat(40),
        git_state: 'unchanged',
        eligible: true,
        omission_reason: null,
      },
    ],
    next_cursor: null,
  });
  await harness.controller.search(actionToken(harness), path);
  return harness.controller.setSelectedPaths(actionToken(harness), [path]);
}

describe('ProjectContextController V1', () => {
  test('reverse-gates every presentation mutation while a destructive journal exists', async () => {
    const cancelled = jest.fn();
    const harness = controllerHarness({
      ready: true,
      scheduleSearch: (_delay, operation) => {
        operation();
        return { cancel: cancelled };
      },
    });
    await attach(harness);
    harness.store.installDestructiveJournal();
    const beforeState = harness.controller.getState();
    const beforeToken = harness.controller.getActionToken();
    const hostileToken = new Proxy(
      {},
      {
        get: () => {
          throw new Error('RAW_TOKEN_SENTINEL');
        },
      },
    ) as ReturnType<typeof actionToken>;
    harness.native.listCandidates.mockClear();
    harness.native.prepare.mockClear();
    harness.native.confirm.mockClear();
    harness.native.inspect.mockClear();
    harness.native.discard.mockClear();
    harness.persistCurrent.mockClear();
    harness.ensureRuntimeContextId.mockClear();
    harness.store.applyProjectContextAction.mockClear();
    harness.store.replacePrepared.mockClear();
    harness.store.replaceConfirmed.mockClear();
    harness.store.disable.mockClear();

    const expected = { status: 'blocked', code: 'E_CONTEXT_BUSY' };
    await expect(
      harness.controller.attachConversation(OTHER_CONVERSATION_ID),
    ).resolves.toEqual(expected);
    await expect(
      harness.controller.reconcileHydrated(OTHER_CONVERSATION_ID),
    ).resolves.toEqual(expected);
    await expect(
      harness.controller.search(hostileToken, 'query'),
    ).resolves.toEqual(expected);
    await expect(
      harness.controller.loadMore(hostileToken),
    ).resolves.toEqual(expected);
    expect(
      harness.controller.setSelectedPaths(hostileToken, ['README.md']),
    ).toEqual(expected);
    await expect(harness.controller.prepare(hostileToken)).resolves.toEqual(
      expected,
    );
    await expect(harness.controller.confirm(hostileToken)).resolves.toEqual(
      expected,
    );
    await expect(harness.controller.inspect(hostileToken)).resolves.toEqual(
      expected,
    );
    await expect(harness.controller.disable(hostileToken)).resolves.toEqual(
      expected,
    );
    await expect(
      harness.controller.retryPersistence(hostileToken),
    ).resolves.toEqual(expected);
    await expect(
      harness.controller.retryCleanup(hostileToken),
    ).resolves.toEqual(expected);
    await expect(harness.controller.cancel(hostileToken)).resolves.toEqual(
      expected,
    );
    await expect(
      harness.controller.beforeConversationChange(CONVERSATION_ID),
    ).resolves.toBe(false);
    await expect(
      harness.controller.beforeConversationDelete(CONVERSATION_ID),
    ).resolves.toBe(false);

    expect(harness.controller.getState()).toEqual(beforeState);
    expect(harness.controller.getActionToken()).toEqual(beforeToken);
    expect(cancelled).not.toHaveBeenCalled();
    expect(harness.native.listCandidates).not.toHaveBeenCalled();
    expect(harness.native.prepare).not.toHaveBeenCalled();
    expect(harness.native.confirm).not.toHaveBeenCalled();
    expect(harness.native.inspect).not.toHaveBeenCalled();
    expect(harness.native.discard).not.toHaveBeenCalled();
    expect(harness.persistCurrent).not.toHaveBeenCalled();
    expect(harness.ensureRuntimeContextId).not.toHaveBeenCalled();
    expect(harness.store.applyProjectContextAction).not.toHaveBeenCalled();
    expect(harness.store.replacePrepared).not.toHaveBeenCalled();
    expect(harness.store.replaceConfirmed).not.toHaveBeenCalled();
    expect(harness.store.disable).not.toHaveBeenCalled();
  });

  test('publishes an exact render-time owner token and advances only list generation for search', async () => {
    const harness = controllerHarness({ ready: true });
    await attach(harness);
    const before = actionToken(harness);
    expect(Object.keys(before).sort()).toEqual(
      [
        'generation',
        'conversationId',
        'projectId',
        'runtimeContextId',
        'modelId',
        'preparationId',
        'listGeneration',
      ].sort(),
    );
    expect(before).toMatchObject({
      conversationId: CONVERSATION_ID,
      projectId: PROJECT_ID,
      runtimeContextId: RUNTIME_CONTEXT_ID,
      modelId: 'deepseek-v4-flash',
      preparationId: null,
      listGeneration: expect.any(Number),
    });

    await harness.controller.search(before, 'token-query');
    const after = actionToken(harness);
    expect(after).toEqual({
      ...before,
      listGeneration: before.listGeneration + 1,
    });
  });

  test('fails closed for a null root outside the explicit legacy bootstrap adapter', async () => {
    const harness = controllerHarness({ ready: true });
    harness.store.mutateConversation(CONVERSATION_ID, {
      workspaceBootstrapState: 'none',
    });

    await expect(
      harness.controller.attachConversation(CONVERSATION_ID),
    ).resolves.toEqual({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    expect(harness.controller.getState().owner).toBeNull();
    expect(harness.native.listCandidates).not.toHaveBeenCalled();
    expect(harness.native.prepare).not.toHaveBeenCalled();
  });

  test('routes workspace-bound search through the exact V2 list request', async () => {
    const routedRoot = {
      schema_version: 1 as const,
      workspace_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      binding_revision: 7,
      project_id: PROJECT_ID,
    };
    const routedProject = {
      schema_version: 2 as const,
      project_id: PROJECT_ID,
      workspace_id: routedRoot.workspace_id,
      workspace_binding_revision: routedRoot.binding_revision,
      display_name: 'demo',
      git_topology: 'private_split_gitdir' as const,
    };
    const listCandidatesV2 = jest.fn(
      async (
        request: {
          readonly schema_version: 1;
          readonly root: typeof routedRoot;
          readonly query: string;
          readonly cursor: string | null;
        },
      ): Promise<ProjectContextCandidatePageV2> => ({
        schema_version: 2,
        root: request.root,
        project: routedProject,
        candidates: page(request.query).candidates,
        next_cursor: request.cursor,
      }),
    );
    const harness = controllerHarness({
      native: { listCandidatesV2 },
    });
    harness.store.mutateConversation(
      CONVERSATION_ID,
      {
        workspaceId: routedRoot.workspace_id,
        workspaceBinding: {
          schemaVersion: 1,
          workspaceId: routedRoot.workspace_id,
          bindingRevision: routedRoot.binding_revision,
          projectId: PROJECT_ID,
        },
      },
    );
    await attach(harness);

    await expect(
      harness.controller.search(actionToken(harness), 'src'),
    ).resolves.toEqual({ status: 'completed' });
    expect(listCandidatesV2).toHaveBeenCalledWith({
      schema_version: 1,
      root: routedRoot,
      query: 'src',
      cursor: null,
    });
    expect(harness.native.listCandidates).not.toHaveBeenCalled();
  });

  test('uses the exact V2 discard request for workspace-bound disable cleanup', async () => {
    const routedRoot = {
      schema_version: 1 as const,
      workspace_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      binding_revision: 7,
      project_id: PROJECT_ID,
    };
    const inspectV2 = jest.fn(async () => ({
      schema_version: 2 as const,
      state: 'confirmed' as const,
      manifest: manifestV2(routedRoot),
    }));
    const discardV2 = jest.fn(async (request: {
      readonly schema_version: 2;
      readonly snapshot_id: string;
      readonly root: typeof routedRoot;
    }) => ({
      schema_version: 2 as const,
      status: 'discarded' as const,
      snapshot_id: request.snapshot_id,
      root: request.root,
      workspace_id: request.root.workspace_id,
      workspace_binding_revision: request.root.binding_revision,
    }));
    const harness = controllerHarness({
      ready: true,
      native: { inspectV2, discardV2 },
    });
    harness.store.mutateConversation(CONVERSATION_ID, {
      workspaceId: routedRoot.workspace_id,
      workspaceBinding: {
        schemaVersion: 1,
        workspaceId: routedRoot.workspace_id,
        bindingRevision: routedRoot.binding_revision,
        projectId: PROJECT_ID,
      },
      workspaceBootstrapState: 'none',
    });

    await expect(harness.controller.attachConversation(CONVERSATION_ID)).resolves.toEqual({
      status: 'completed',
    });
    await expect(harness.controller.disable(actionToken(harness))).resolves.toEqual({
      status: 'completed',
    });
    expect(discardV2).toHaveBeenCalledWith({
      schema_version: 2,
      snapshot_id: SNAPSHOT_A,
      root: routedRoot,
    });
    expect(harness.native.discard).not.toHaveBeenCalled();
  });

  test('does not settle V2 cleanup after the workspace binding drifts', async () => {
    const routedRoot = {
      schema_version: 1 as const,
      workspace_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      binding_revision: 7,
      project_id: PROJECT_ID,
    };
    const inspectV2 = jest.fn(async () => ({
      schema_version: 2 as const,
      state: 'confirmed' as const,
      manifest: manifestV2(routedRoot),
    }));
    let harness!: ControllerHarness;
    const discardV2 = jest.fn(async (request: {
      readonly schema_version: 2;
      readonly snapshot_id: string;
      readonly root: typeof routedRoot;
    }) => {
      harness.store.mutateConversation(CONVERSATION_ID, {
        workspaceBinding: {
          schemaVersion: 1,
          workspaceId: routedRoot.workspace_id,
          bindingRevision: routedRoot.binding_revision + 1,
          projectId: PROJECT_ID,
        },
      });
      return {
        schema_version: 2 as const,
        status: 'discarded' as const,
        snapshot_id: request.snapshot_id,
        root: request.root,
        workspace_id: request.root.workspace_id,
        workspace_binding_revision: request.root.binding_revision,
      };
    });
    harness = controllerHarness({
      ready: true,
      native: { inspectV2, discardV2 },
    });
    harness.store.mutateConversation(CONVERSATION_ID, {
      workspaceId: routedRoot.workspace_id,
      workspaceBinding: {
        schemaVersion: 1,
        workspaceId: routedRoot.workspace_id,
        bindingRevision: routedRoot.binding_revision,
        projectId: PROJECT_ID,
      },
      workspaceBootstrapState: 'none',
    });

    await harness.controller.attachConversation(CONVERSATION_ID);
    await expect(
      harness.controller.disable(actionToken(harness)),
    ).resolves.toEqual({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    expect(discardV2).toHaveBeenCalledTimes(1);
    expect(harness.native.discard).not.toHaveBeenCalled();
  });

  test('keeps only the newest query generation and passes cursor unchanged', async () => {
    const oldSearch = deferred<ProjectContextCandidatePageV1>();
    const newSearch = deferred<ProjectContextCandidatePageV1>();
    const nextPage = deferred<ProjectContextCandidatePageV1>();
    const cursor = 'x'.repeat(98);
    const harness = controllerHarness({
      native: {
        listCandidates: jest
          .fn()
          .mockImplementationOnce(() => oldSearch.promise)
          .mockImplementationOnce(() => newSearch.promise)
          .mockImplementationOnce(() => nextPage.promise),
      },
    });
    await attach(harness);

    const renderToken = actionToken(harness);
    const oldRun = harness.controller.search(renderToken, 'old');
    const newRun = harness.controller.search(renderToken, 'new');
    newSearch.resolve(page('new', cursor));
    await newRun;
    oldSearch.resolve(page('old'));
    await oldRun;

    expect(harness.controller.getState()).toMatchObject({
      list: {
        query: 'new',
        candidates: [{ path: 'new.ts' }],
        nextCursor: cursor,
      },
    });

    const more = harness.controller.loadMore(actionToken(harness));
    expect(harness.native.listCandidates).toHaveBeenLastCalledWith(
      PROJECT_ID,
      'new',
      cursor,
    );
    nextPage.resolve(page('next'));
    await more;
    expect(
      harness.controller.getState().list.candidates.map(item => item.path),
    ).toEqual(['new.ts', 'next.ts']);
  });

  test('settles a debounced search when a newer render supersedes it', async () => {
    const scheduled: Array<() => void> = [];
    const cancellations: jest.Mock[] = [];
    const harness = controllerHarness({
      scheduleSearch: (_delay, operation) => {
        const cancel = jest.fn();
        scheduled.push(operation);
        cancellations.push(cancel);
        return { cancel };
      },
    });
    await attach(harness);
    const renderToken = actionToken(harness);

    const first = harness.controller.search(renderToken, 'old');
    const second = harness.controller.search(renderToken, 'new');

    await expect(first).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    expect(cancellations[0]).toHaveBeenCalledTimes(1);
    scheduled[1]?.();
    await expect(second).resolves.toMatchObject({ status: 'completed' });
    expect(harness.controller.getState().list.query).toBe('new');
  });

  test('rejects stale list-generation tokens for loadMore and selection mutation', async () => {
    const cursor = 'y'.repeat(98);
    const harness = controllerHarness({
      native: {
        listCandidates: jest.fn(async (_projectId, query) =>
          page(query, cursor),
        ),
      },
    });
    await attach(harness);
    const staleListToken = actionToken(harness);
    await harness.controller.search(staleListToken, 'fresh-list');
    harness.native.listCandidates.mockClear();

    expect(
      harness.controller.setSelectedPaths(staleListToken, ['fresh-list.ts']),
    ).toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    await expect(
      harness.controller.loadMore(staleListToken),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    expect(harness.native.listCandidates).not.toHaveBeenCalled();
    expect(harness.controller.getState().selectedPaths).toEqual([]);
  });

  test('retains selected candidate metadata across queries and rejects unknown, ineligible, or empty selections', async () => {
    const eligible = {
      path: 'first.ts',
      size: 12,
      revision: '1'.repeat(40),
      git_state: 'unchanged' as const,
      eligible: true,
      omission_reason: null,
    };
    const ineligible = {
      path: 'secret.env',
      size: 4,
      revision: '2'.repeat(40),
      git_state: 'unstaged' as const,
      eligible: false,
      omission_reason: 'secret_path' as const,
    };
    const harness = controllerHarness({
      native: {
        listCandidates: jest
          .fn()
          .mockResolvedValueOnce({
            schema_version: 1,
            project_id: PROJECT_ID,
            candidates: [eligible],
            next_cursor: null,
          })
          .mockResolvedValueOnce({
            schema_version: 1,
            project_id: PROJECT_ID,
            candidates: [ineligible],
            next_cursor: null,
          }),
      },
    });
    await attach(harness);
    await harness.controller.search(actionToken(harness), 'first');
    expect(
      harness.controller.setSelectedPaths(actionToken(harness), ['first.ts']),
    ).toMatchObject({ status: 'completed' });
    await harness.controller.search(actionToken(harness), 'secret');

    expect(harness.controller.getState().selectedCandidates).toEqual([
      eligible,
    ]);
    for (const paths of [[], ['unknown.ts'], ['first.ts', 'secret.env']]) {
      expect(
        harness.controller.setSelectedPaths(actionToken(harness), paths),
      ).toMatchObject({
        status: 'blocked',
        code: 'E_CONTEXT_REQUEST_INVALID',
      });
    }
    expect(harness.controller.getState().selectedPaths).toEqual(['first.ts']);
    expect(harness.controller.getState().selectedCandidates).toEqual([
      eligible,
    ]);
  });

  test('ignores list and cursor results owned by an old conversation', async () => {
    const oldPage = deferred<ProjectContextCandidatePageV1>();
    const harness = controllerHarness({
      native: { listCandidates: jest.fn(() => oldPage.promise) },
    });
    await attach(harness);
    const pending = harness.controller.search(actionToken(harness), 'owned');
    await attach(harness, OTHER_CONVERSATION_ID);
    oldPage.resolve(page('owned'));
    await pending;

    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: OTHER_CONVERSATION_ID },
      list: { candidates: [], nextCursor: null },
    });
  });

  test('persists runtime identity before initial native prepare', async () => {
    const order: string[] = [];
    const harness = controllerHarness({ runtimeContextId: null });
    const ensureRuntime = harness.ensureRuntimeContextId.getMockImplementation()!;
    const replacePrepared = harness.replacePrepared.getMockImplementation()!;
    harness.ensureRuntimeContextId.mockImplementationOnce(
      (conversationId: string) => {
        order.push('runtime');
        return ensureRuntime(conversationId);
      },
    );
    harness.persistCurrent.mockImplementation(async () => {
      order.push('persist');
      harness.persistedContexts.push(harness.store.serializeContext());
      return { status: 'committed' };
    });
    harness.native.prepare.mockImplementationOnce(async () => {
      order.push('native');
      return manifest(SNAPSHOT_B);
    });
    harness.replacePrepared.mockImplementationOnce(
      (scope: ProjectContextMutationScope, input) => {
        order.push('replace');
        return replacePrepared(scope, input);
      },
    );
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));

    expect(order.slice(0, 3)).toEqual(['runtime', 'persist', 'native']);
    expect(harness.native.prepare).toHaveBeenCalledWith({
      schema_version: 1,
      project_id: PROJECT_ID,
      conversation_id: RUNTIME_CONTEXT_ID,
      provider: 'deepseek',
      model: 'deepseek-v4-flash',
      policy: 'chat-read-v1',
      selected_paths: ['src/index.ts'],
    });
  });

  test.each(['session_only', 'not_committed', 'unknown'] as const)(
    'calls zero native prepare for %s intent persistence and retries without duplication',
    async status => {
      const harness = controllerHarness({
        runtimeContextId: null,
        durability: [
          { status },
          { status: 'committed' },
          { status: 'committed' },
        ],
      });
      await attach(harness);
      await selectKnownPath(harness);

      await expect(
        harness.controller.prepare(actionToken(harness)),
      ).resolves.toMatchObject({
        status: 'persistence_pending',
      });
      expect(harness.native.prepare).not.toHaveBeenCalled();
      await harness.controller.retryPersistence(actionToken(harness));
      expect(harness.native.prepare).toHaveBeenCalledTimes(1);
      expect(harness.controller.getState()).toMatchObject({ phase: 'review' });
    },
  );

  test('bounds the in-memory persistence outbox and blocks duplicate prepare', async () => {
    const harness = controllerHarness({
      runtimeContextId: null,
      durability: [{ status: 'unknown' }],
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));

    expect(harness.controller.getState()).toMatchObject({
      phase: 'persistence_pending',
      pendingPersistence: { kind: 'prepare_intent' },
    });
    await expect(
      harness.controller.prepare(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_BUSY',
    });
    expect(harness.native.prepare).not.toHaveBeenCalled();
  });

  test('discards a late prepared snapshot after owner replacement', async () => {
    const prepared = deferred<ProjectContextManifestV1>();
    const harness = controllerHarness({
      native: { prepare: jest.fn(() => prepared.promise) },
    });
    await attach(harness);
    await selectKnownPath(harness);
    const run = harness.controller.prepare(actionToken(harness));
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    expect(harness.native.prepare).toHaveBeenCalledTimes(1);
    await attach(harness, OTHER_CONVERSATION_ID);
    prepared.resolve(manifest(SNAPSHOT_B));
    await run;

    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.store.replacePrepared).not.toHaveBeenCalled();
  });

  test('discards a late prepare result after the same owner installs Context C', async () => {
    const prepared = deferred<ProjectContextManifestV1>();
    const harness = controllerHarness({
      ready: true,
      native: { prepare: jest.fn(() => prepared.promise) },
    });
    await attach(harness);
    await selectKnownPath(harness);
    const run = harness.controller.prepare(actionToken(harness));
    await Promise.resolve();
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_C, CONSENT_C),
    );
    prepared.resolve(manifest(SNAPSHOT_B));
    await run;

    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.store.replacePrepared).not.toHaveBeenCalled();
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_C);
  });

  test('persists an initial prepared manifest before exposing review', async () => {
    const manifestWrite = deferred<SessionDurabilityResult>();
    const harness = controllerHarness({
      runtimeContextId: null,
      durability: [{ status: 'committed' }],
    });
    harness.persistCurrent
      .mockResolvedValueOnce({ status: 'committed' })
      .mockImplementationOnce(() => manifestWrite.promise);
    await attach(harness);
    await selectKnownPath(harness);
    const run = harness.controller.prepare(actionToken(harness));
    for (let index = 0; index < 8; index += 1) await Promise.resolve();

    expect(harness.store.replacePrepared).toHaveBeenCalledTimes(1);
    expect(harness.controller.getState().phase).not.toBe('review');
    manifestWrite.resolve({ status: 'committed' });
    await run;
    expect(harness.controller.getState()).toMatchObject({
      phase: 'review',
      candidateManifest: { snapshot_id: SNAPSHOT_B },
    });
    expect(harness.store.transactions.at(-1)?.commit).toHaveBeenCalledTimes(1);
  });

  test('does not discard prepared B when a new Ready context owns the same snapshot during settle', async () => {
    const manifestWrite = deferred<SessionDurabilityResult>();
    const harness = controllerHarness({ runtimeContextId: null });
    harness.persistCurrent
      .mockResolvedValueOnce({ status: 'committed' })
      .mockImplementationOnce(() => manifestWrite.promise);
    await attach(harness);
    await selectKnownPath(harness);
    const preparing = harness.controller.prepare(actionToken(harness));
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_B, CONSENT_B),
    );
    manifestWrite.resolve({ status: 'committed' });
    await preparing;

    expect(harness.native.discard).not.toHaveBeenCalled();
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_B);
    expect(harness.store.serializeContext()).toContain('"status":"ready"');
  });

  test('does not discard prepared B when a new Ready context owns the same snapshot on retry', async () => {
    const harness = controllerHarness({
      runtimeContextId: null,
      durability: [{ status: 'committed' }, { status: 'unknown' }],
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_B, CONSENT_B),
    );

    await harness.controller.retryPersistence(actionToken(harness));

    expect(harness.native.discard).not.toHaveBeenCalled();
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_B);
    expect(harness.store.serializeContext()).toContain('"status":"ready"');
  });

  test('keeps Ready A serialized while refresh prepare B is controller-local', async () => {
    const harness = controllerHarness({ ready: true });
    const before = harness.store.serializeContext();
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));

    expect(harness.store.serializeContext()).toBe(before);
    expect(harness.store.replacePrepared).not.toHaveBeenCalled();
    expect(harness.controller.getState()).toMatchObject({
      phase: 'review',
      candidateManifest: { snapshot_id: SNAPSHOT_B },
    });
  });

  test('Cancel discards refresh B and leaves serialized A unchanged', async () => {
    const harness = controllerHarness({ ready: true });
    const before = harness.store.serializeContext();
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    await harness.controller.cancel(actionToken(harness));

    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.store.serializeContext()).toBe(before);
    expect(harness.controller.getState()).toMatchObject({ phase: 'idle' });
  });

  test('confirms refresh B once and never rolls back A after native success', async () => {
    const harness = controllerHarness({
      ready: true,
      durability: [{ status: 'not_committed' }, { status: 'committed' }],
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));

    await expect(
      harness.controller.confirm(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'persistence_pending',
    });
    expect(harness.native.confirm).toHaveBeenCalledTimes(1);
    expect(harness.store.replaceConfirmed).toHaveBeenCalledTimes(1);
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_B);
    expect(harness.store.transactions.at(-1)?.rollback).not.toHaveBeenCalled();
    expect(harness.controller.getState()).toMatchObject({
      phase: 'persistence_pending',
      candidateManifest: { snapshot_id: SNAPSHOT_B },
      pendingPersistence: { kind: 'confirmed_consent' },
    });

    await harness.controller.retryPersistence(actionToken(harness));
    expect(harness.native.confirm).toHaveBeenCalledTimes(1);
    expect(harness.store.transactions.at(-1)?.commit).toHaveBeenCalledTimes(1);
    expect(harness.controller.getState()).toMatchObject({ phase: 'idle' });
  });

  test('never applies a late confirmation over same-owner Context C', async () => {
    const confirmation = deferred<ProjectContextConsentV1>();
    const harness = controllerHarness({
      ready: true,
      native: { confirm: jest.fn(() => confirmation.promise) },
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    const run = harness.controller.confirm(actionToken(harness));
    await Promise.resolve();
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_C, CONSENT_C),
    );
    confirmation.resolve(consent(SNAPSHOT_B, CONSENT_B));
    await run;

    expect(harness.store.replaceConfirmed).not.toHaveBeenCalled();
    expect(harness.store.applyProjectContextAction).toHaveBeenCalledWith(
      CONVERSATION_ID,
      { type: 'project_changed' },
    );
    expect(harness.persistCurrent).toHaveBeenCalled();
    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_C);
  });

  test('never rolls back post-confirm when Context C wins during persistence', async () => {
    const persistence = deferred<SessionDurabilityResult>();
    const harness = controllerHarness({ ready: true });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    harness.persistCurrent.mockImplementationOnce(() => persistence.promise);
    const confirming = harness.controller.confirm(actionToken(harness));
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_B);
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_C, CONSENT_C),
    );
    persistence.resolve({ status: 'committed' });
    await confirming;

    expect(harness.store.transactions.at(-1)?.rollback).not.toHaveBeenCalled();
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_C);
    expect(harness.store.applyProjectContextAction).toHaveBeenCalledWith(
      CONVERSATION_ID,
      { type: 'project_changed' },
    );
    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.controller.getState()).toMatchObject({
      phase: 'blocked',
      candidateManifest: null,
      pendingPersistence: null,
    });
  });

  test('carries confirmed B cleanup through a second context drift while quarantine settles', async () => {
    const confirmation = deferred<ProjectContextConsentV1>();
    const quarantineWrite = deferred<SessionDurabilityResult>();
    const harness = controllerHarness({
      ready: true,
      native: { confirm: jest.fn(() => confirmation.promise) },
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    harness.persistCurrent.mockImplementationOnce(() => quarantineWrite.promise);
    const confirming = harness.controller.confirm(actionToken(harness));
    await Promise.resolve();
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_C, CONSENT_C),
    );
    confirmation.resolve(consent(SNAPSHOT_B, CONSENT_B));
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    expect(harness.controller.getState()).toMatchObject({
      phase: 'persistence_pending',
      pendingPersistence: { kind: 'inspection' },
    });
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_D, CONSENT_D),
    );
    quarantineWrite.resolve({ status: 'committed' });
    await confirming;

    expect(harness.store.serializeContext()).toContain(SNAPSHOT_D);
    expect(harness.store.serializeContext()).toContain('"status":"stale"');
    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.controller.getState()).toMatchObject({
      phase: 'blocked',
      cleanupSnapshotId: null,
    });
  });

  test('carries confirmed B cleanup through a second context drift on retry', async () => {
    const confirmation = deferred<ProjectContextConsentV1>();
    const harness = controllerHarness({
      ready: true,
      durability: [{ status: 'unknown' }],
      native: { confirm: jest.fn(() => confirmation.promise) },
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    const confirming = harness.controller.confirm(actionToken(harness));
    await Promise.resolve();
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_C, CONSENT_C),
    );
    confirmation.resolve(consent(SNAPSHOT_B, CONSENT_B));
    await confirming;
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_D, CONSENT_D),
    );

    await harness.controller.retryPersistence(actionToken(harness));

    expect(harness.store.serializeContext()).toContain(SNAPSHOT_D);
    expect(harness.store.serializeContext()).toContain('"status":"stale"');
    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
  });

  test('hard-blocks conversation attach while native confirmation owns the snapshot', async () => {
    const confirmation = deferred<ProjectContextConsentV1>();
    const harness = controllerHarness({
      ready: true,
      native: { confirm: jest.fn(() => confirmation.promise) },
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    const confirming = harness.controller.confirm(actionToken(harness));
    await Promise.resolve();

    await expect(
      harness.controller.attachConversation(OTHER_CONVERSATION_ID),
    ).resolves.toMatchObject({ status: 'blocked', code: 'E_CONTEXT_BUSY' });
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: CONVERSATION_ID },
      phase: 'confirming',
    });

    confirmation.resolve(consent(SNAPSHOT_B, CONSENT_B));
    await expect(confirming).resolves.toMatchObject({ status: 'completed' });
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_B);
  });

  test('disables state durably before native snapshot cleanup', async () => {
    const order: string[] = [];
    const harness = controllerHarness({ ready: true });
    const disable = harness.disable.getMockImplementation()!;
    harness.disable.mockImplementationOnce(
      (scope: ProjectContextMutationScope) => {
        order.push('disable');
        return disable(scope);
      },
    );
    harness.persistCurrent.mockImplementationOnce(async () => {
      order.push('persist');
      return { status: 'committed' };
    });
    harness.native.discard.mockImplementationOnce(async () => {
      order.push('discard');
      return { schema_version: 1, status: 'discarded' };
    });
    await attach(harness);
    await harness.controller.disable(actionToken(harness));

    expect(order).toEqual(['disable', 'persist', 'discard']);
    expect(harness.store.serializeContext()).not.toContain(SNAPSHOT_A);
  });

  test('does not discard on failed disable persistence and retries cleanup once', async () => {
    const harness = controllerHarness({
      ready: true,
      durability: [{ status: 'session_only' }, { status: 'committed' }],
    });
    await attach(harness);
    await harness.controller.disable(actionToken(harness));
    expect(harness.native.discard).not.toHaveBeenCalled();
    expect(harness.controller.getState()).toMatchObject({
      phase: 'persistence_pending',
      pendingPersistence: { kind: 'disabled' },
    });
    await harness.controller.retryPersistence(actionToken(harness));
    expect(harness.native.discard).toHaveBeenCalledTimes(1);
  });

  test.each([
    { completionMutationBlocked: true, snapshotReferences: [] },
    {
      completionMutationBlocked: false,
      snapshotReferences: [
        {
          conversationId: CONVERSATION_ID,
          attemptId: 'attempt-retry',
          kind: 'retryable',
        },
      ],
    },
  ])('blocks every context mutation for completion or exact retry ownership %#', async options => {
    const harness = controllerHarness({ ready: true, ...options });
    await attach(harness);
    harness.controller.setSelectedPaths(actionToken(harness), ['src/index.ts']);

    await expect(
      harness.controller.prepare(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
    });
    await expect(
      harness.controller.confirm(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
    });
    await expect(
      harness.controller.disable(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
    });
    expect(harness.native.prepare).not.toHaveBeenCalled();
    expect(harness.native.confirm).not.toHaveBeenCalled();
    expect(harness.native.discard).not.toHaveBeenCalled();
  });

  test('inspect preserves ready, maps stale and missing, and restores prepared review', async () => {
    const ready = controllerHarness({ ready: true });
    await attach(ready);
    await ready.controller.inspect(actionToken(ready));
    expect(ready.store.applyProjectContextAction).not.toHaveBeenCalled();

    ready.native.inspect.mockResolvedValueOnce({
      schema_version: 1,
      state: 'stale',
      manifest: manifest(SNAPSHOT_A),
    });
    await ready.controller.inspect(actionToken(ready));
    expect(ready.store.applyProjectContextAction).toHaveBeenCalledWith(
      CONVERSATION_ID,
      { type: 'project_changed' },
    );

    const missing = controllerHarness({ ready: true });
    missing.native.inspect.mockRejectedValueOnce(
      new ProjectContextBridgeError('E_CONTEXT_SNAPSHOT_MISSING'),
    );
    await attach(missing);
    await missing.controller.inspect(actionToken(missing));
    expect(missing.store.applyProjectContextAction).toHaveBeenCalledWith(
      CONVERSATION_ID,
      { type: 'snapshot_missing' },
    );

    const prepared = controllerHarness({ runtimeContextId: RUNTIME_CONTEXT_ID });
    await attach(prepared);
    await selectKnownPath(prepared);
    await prepared.controller.prepare(actionToken(prepared));
    await prepared.controller.inspect(actionToken(prepared));
    expect(prepared.controller.getState()).toMatchObject({ phase: 'review' });
  });

  test('never applies a late inspection over same-owner Context C', async () => {
    const inspection = deferred<{
      schema_version: 1;
      state: 'stale';
      manifest: ProjectContextManifestV1;
    }>();
    const harness = controllerHarness({ ready: true });
    await attach(harness);
    harness.native.inspect.mockImplementationOnce(() => inspection.promise);
    harness.store.applyProjectContextAction.mockClear();
    const run = harness.controller.inspect(actionToken(harness));
    await Promise.resolve();
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_C, CONSENT_C),
    );
    inspection.resolve({
      schema_version: 1,
      state: 'stale',
      manifest: manifest(SNAPSHOT_A),
    });
    await run;

    expect(harness.store.applyProjectContextAction).not.toHaveBeenCalled();
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_C);
  });

  test('guards navigation for native mutation, review responsibility, and pending persistence', async () => {
    const prepared = deferred<ProjectContextManifestV1>();
    const harness = controllerHarness({
      native: { prepare: jest.fn(() => prepared.promise) },
    });
    await attach(harness);
    await selectKnownPath(harness);
    const run = harness.controller.prepare(actionToken(harness));
    await Promise.resolve();
    await expect(
      harness.controller.beforeConversationChange(CONVERSATION_ID),
    ).resolves.toBe(false);
    prepared.resolve(manifest(SNAPSHOT_B));
    await run;
    await expect(
      harness.controller.beforeConversationChange(CONVERSATION_ID),
    ).resolves.toBe(false);

    const pending = controllerHarness({
      runtimeContextId: null,
      durability: [{ status: 'unknown' }],
    });
    await attach(pending);
    await selectKnownPath(pending);
    await pending.controller.prepare(actionToken(pending));
    await expect(
      pending.controller.beforeConversationDelete(CONVERSATION_ID),
    ).resolves.toBe(false);
  });

  test('blocks deleting a conversation until its persisted snapshot is disabled', async () => {
    const harness = controllerHarness({ ready: true });
    await attach(harness);
    await expect(
      harness.controller.beforeConversationDelete(CONVERSATION_ID),
    ).resolves.toBe(false);
    await harness.controller.disable(actionToken(harness));
    await expect(
      harness.controller.beforeConversationDelete(CONVERSATION_ID),
    ).resolves.toBe(true);
  });

  test('keeps state and persisted inputs metadata-only with value-free errors', async () => {
    const harness = controllerHarness({
      native: {
        prepare: jest.fn(async () => {
          throw {
            code: 'E_CONTEXT_BUSY',
            message: 'RAW_PROJECT_SECRET',
            absolute_path: '/private/project',
          };
        }),
      },
    });
    await attach(harness);
    await selectKnownPath(harness, 'README.md');
    await harness.controller.prepare(actionToken(harness));

    const serialized = JSON.stringify({
      controller: harness.controller.getState(),
      persisted: harness.persistedContexts,
      nativeCalls: harness.native.prepare.mock.calls,
    });
    expect(serialized).not.toContain('RAW_PROJECT_SECRET');
    expect(serialized).not.toContain('/private/project');
    expect(serialized).not.toContain('content');
    expect(harness.controller.getState()).toMatchObject({
      failureCode: 'E_CONTEXT_BUSY',
    });
  });

  test('isolates throwing subscribers from context transactions', async () => {
    const harness = controllerHarness();
    await attach(harness);
    harness.controller.subscribe(() => {
      throw new Error('RAW_LISTENER_DETAIL');
    });

    await expect(selectKnownPath(harness)).resolves.toMatchObject({
      status: 'completed',
    });
    await expect(
      harness.controller.prepare(actionToken(harness)),
    ).resolves.toMatchObject({ status: 'completed' });
    expect(harness.controller.getState()).toMatchObject({ phase: 'review' });
  });

  test('rolls disable back to Ready A on not_committed and performs zero cleanup', async () => {
    const harness = controllerHarness({
      ready: true,
      durability: [{ status: 'not_committed' }],
    });
    const before = harness.store.serializeContext();
    await attach(harness);

    await expect(
      harness.controller.disable(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_PERSISTENCE',
    });
    expect(harness.disable).toHaveBeenCalledTimes(1);
    expect(harness.store.transactions.at(-1)?.rollback).toHaveBeenCalledTimes(1);
    expect(harness.store.transactions.at(-1)?.commit).not.toHaveBeenCalled();
    expect(harness.store.serializeContext()).toBe(before);
    expect(harness.native.discard).not.toHaveBeenCalled();
    expect(harness.controller.getState()).toMatchObject({
      phase: 'blocked',
      pendingPersistence: null,
    });
  });

  test.each(['session_only', 'unknown'] as const)(
    'keeps disabled state blocked and pending for %s durability without native cleanup',
    async status => {
      const harness = controllerHarness({
        ready: true,
        durability: [{ status }],
      });
      await attach(harness);

      await expect(
        harness.controller.disable(actionToken(harness)),
      ).resolves.toMatchObject({
        status: 'persistence_pending',
        code: 'E_CONTEXT_PERSISTENCE',
      });
      expect(harness.store.serializeContext()).not.toContain(SNAPSHOT_A);
      expect(harness.store.transactions.at(-1)?.rollback).not.toHaveBeenCalled();
      expect(harness.native.discard).not.toHaveBeenCalled();
      expect(harness.controller.getState()).toMatchObject({
        phase: 'persistence_pending',
        pendingPersistence: {
          kind: 'disabled',
          cleanupSnapshotId: SNAPSHOT_A,
        },
      });
      await expect(
        harness.controller.beforeConversationChange(CONVERSATION_ID),
      ).resolves.toBe(false);
    },
  );

  test('does not settle an inspection outbox over same-owner Context C', async () => {
    const persistence = deferred<SessionDurabilityResult>();
    const harness = controllerHarness({
      ready: true,
      native: {
        inspect: jest.fn(async () => ({
          schema_version: 1,
          state: 'stale',
          manifest: manifest(SNAPSHOT_A),
        })),
      },
    });
    harness.persistCurrent.mockImplementationOnce(() => persistence.promise);
    const run = harness.controller.attachConversation(CONVERSATION_ID);
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    expect(harness.controller.getState()).toMatchObject({
      phase: 'persistence_pending',
      pendingPersistence: { kind: 'inspection' },
    });
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_C, CONSENT_C),
    );
    persistence.resolve({ status: 'committed' });
    await run;

    expect(harness.store.serializeContext()).toContain(SNAPSHOT_C);
    expect(harness.controller.getState()).toMatchObject({
      phase: 'blocked',
      failureCode: 'E_CONTEXT_OWNER_STALE',
      pendingPersistence: null,
    });
  });

  test('does not rebind prepare-intent persistence retry to same-owner Context C', async () => {
    const harness = controllerHarness({
      runtimeContextId: null,
      durability: [{ status: 'unknown' }],
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_C, CONSENT_C),
    );

    await expect(
      harness.controller.retryPersistence(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    expect(harness.native.prepare).not.toHaveBeenCalled();
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_C);
  });

  test('does not rebind inspection persistence retry to same-owner Context C', async () => {
    const harness = controllerHarness({
      ready: true,
      durability: [{ status: 'unknown' }],
      native: {
        inspect: jest.fn(async () => ({
          schema_version: 1,
          state: 'stale',
          manifest: manifest(SNAPSHOT_A),
        })),
      },
    });
    await attach(harness);
    harness.store.replaceContext(
      CONVERSATION_ID,
      readyContext(SNAPSHOT_C, CONSENT_C),
    );

    await expect(
      harness.controller.retryPersistence(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    expect(harness.native.inspect).toHaveBeenCalledTimes(1);
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_C);
  });

  test('keeps cleanup pending after native discard failure and retries cleanup only', async () => {
    const harness = controllerHarness({ ready: true });
    harness.native.discard
      .mockRejectedValueOnce(new ProjectContextBridgeError('E_CONTEXT_STORAGE'))
      .mockResolvedValueOnce({ schema_version: 1, status: 'discarded' });
    await attach(harness);

    await expect(
      harness.controller.disable(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'cleanup_pending',
      code: 'E_CONTEXT_STORAGE',
    });
    expect(harness.disable).toHaveBeenCalledTimes(1);
    expect(harness.persistCurrent).toHaveBeenCalledTimes(1);
    expect(harness.store.transactions.at(-1)?.commit).toHaveBeenCalledTimes(1);
    expect(harness.store.serializeContext()).not.toContain(SNAPSHOT_A);
    expect(harness.controller.getState()).toMatchObject({
      phase: 'cleanup_pending',
      cleanupSnapshotId: SNAPSHOT_A,
    });

    await expect(
      harness.controller.retryCleanup(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'completed',
    });
    expect(harness.native.discard).toHaveBeenCalledTimes(2);
    expect(harness.disable).toHaveBeenCalledTimes(1);
    expect(harness.persistCurrent).toHaveBeenCalledTimes(1);
  });

  test('never discards after a cleanup publish listener installs Context C', async () => {
    const harness = controllerHarness({ ready: true });
    let drifted = false;
    harness.controller.subscribe(next => {
      const context = harness.store.store.getState().conversations[
        CONVERSATION_ID
      ]?.projectContext;
      if (
        drifted ||
        next.phase !== 'disabling' ||
        context?.snapshot !== null
      ) {
        return;
      }
      drifted = true;
      harness.store.replaceContext(
        CONVERSATION_ID,
        readyContext(SNAPSHOT_C, CONSENT_C),
      );
    });
    await attach(harness);

    await expect(
      harness.controller.disable(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'cleanup_pending',
      code: 'E_CONTEXT_BUSY',
    });
    expect(harness.native.discard).not.toHaveBeenCalled();
    expect(harness.store.serializeContext()).toContain(SNAPSHOT_C);
    expect(harness.controller.getState()).toMatchObject({
      phase: 'cleanup_pending',
      cleanupSnapshotId: SNAPSHOT_A,
    });
  });

  test('does not abandon cleanup responsibility when another conversation attaches', async () => {
    const harness = controllerHarness({ ready: true });
    harness.native.discard
      .mockRejectedValueOnce(new ProjectContextBridgeError('E_CONTEXT_STORAGE'))
      .mockResolvedValueOnce({ schema_version: 1, status: 'discarded' });
    await attach(harness);
    await harness.controller.disable(actionToken(harness));

    await expect(
      harness.controller.attachConversation(OTHER_CONVERSATION_ID),
    ).resolves.toMatchObject({ status: 'completed' });
    expect(harness.native.discard).toHaveBeenCalledTimes(2);
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: OTHER_CONVERSATION_ID },
      cleanupSnapshotId: null,
    });
  });

  test('cleans refresh B before attaching another conversation', async () => {
    const harness = controllerHarness({ ready: true });
    const before = harness.store.serializeContext();
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));

    await harness.controller.attachConversation(OTHER_CONVERSATION_ID);

    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.store.serializeContext()).toBe(before);
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: OTHER_CONVERSATION_ID },
      candidateManifest: null,
    });
  });

  test.each([
    {
      name: 'stale',
      native: () =>
        Promise.resolve({
          schema_version: 1,
          state: 'stale',
          manifest: manifest(SNAPSHOT_A),
        }),
      action: { type: 'project_changed' as const },
    },
    {
      name: 'missing',
      native: () =>
        Promise.reject(
          new ProjectContextBridgeError('E_CONTEXT_SNAPSHOT_MISSING'),
        ),
      action: { type: 'snapshot_missing' as const },
    },
  ])(
    'persists inspect $name mutation and blocks navigation/mutation while durability is unknown',
    async row => {
      const inspectWrite = deferred<SessionDurabilityResult>();
      const harness = controllerHarness({
        ready: true,
        native: { inspect: jest.fn(row.native) },
      });
      harness.persistCurrent.mockImplementationOnce(() => inspectWrite.promise);
      const attaching = harness.controller.attachConversation(CONVERSATION_ID);
      for (let index = 0; index < 8; index += 1) await Promise.resolve();

      expect(harness.store.applyProjectContextAction).toHaveBeenCalledWith(
        CONVERSATION_ID,
        row.action,
      );
      expect(harness.controller.getState()).toMatchObject({
        phase: 'persistence_pending',
        pendingPersistence: { kind: 'inspection' },
      });
      await expect(
        harness.controller.beforeConversationChange(CONVERSATION_ID),
      ).resolves.toBe(false);
      await expect(
        harness.controller.prepare(actionToken(harness)),
      ).resolves.toMatchObject({
        status: 'blocked',
        code: 'E_CONTEXT_BUSY',
      });

      inspectWrite.resolve({ status: 'unknown' });
      await attaching;
      expect(harness.controller.getState()).toMatchObject({
        phase: 'persistence_pending',
      });
    },
  );

  test('attaches and reconciles a persisted snapshot through native inspecting before Ready', async () => {
    const firstInspection = deferred<{
      schema_version: 1;
      state: 'confirmed';
      manifest: ProjectContextManifestV1;
    }>();
    const secondInspection = deferred<{
      schema_version: 1;
      state: 'confirmed';
      manifest: ProjectContextManifestV1;
    }>();
    const harness = controllerHarness({
      ready: true,
      native: {
        inspect: jest
          .fn()
          .mockImplementationOnce(() => firstInspection.promise)
          .mockImplementationOnce(() => secondInspection.promise),
      },
    });

    const attaching = harness.controller.attachConversation(CONVERSATION_ID);
    await Promise.resolve();
    expect(harness.controller.getState()).toMatchObject({ phase: 'inspecting' });
    expect(harness.native.inspect).toHaveBeenCalledWith(SNAPSHOT_A);
    firstInspection.resolve({
      schema_version: 1,
      state: 'confirmed',
      manifest: manifest(SNAPSHOT_A),
    });
    await attaching;
    expect(harness.controller.getState()).toMatchObject({ phase: 'idle' });

    const reconciling = harness.controller.reconcileHydrated(CONVERSATION_ID);
    await Promise.resolve();
    expect(harness.controller.getState()).toMatchObject({ phase: 'inspecting' });
    secondInspection.resolve({
      schema_version: 1,
      state: 'confirmed',
      manifest: manifest(SNAPSHOT_A),
    });
    await reconciling;
    expect(harness.native.inspect).toHaveBeenCalledTimes(2);
    expect(harness.controller.getState()).toMatchObject({ phase: 'idle' });
  });

  test('reconcileHydrated discards same-conversation refresh B before re-inspecting A', async () => {
    const harness = controllerHarness({ ready: true });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    harness.native.discard.mockClear();
    harness.native.inspect.mockClear();

    await harness.controller.reconcileHydrated(CONVERSATION_ID);

    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.native.inspect).toHaveBeenCalledWith(SNAPSHOT_A);
    expect(harness.controller.getState()).toMatchObject({
      phase: 'idle',
      candidateManifest: null,
    });
  });

  test.each([
    consent(SNAPSHOT_A, CONSENT_B),
    {
      ...consent(SNAPSHOT_B, CONSENT_B),
      snapshot_sha256: 'f'.repeat(64),
    },
  ])('rejects mismatched native consent without replacing or persisting Ready', async badConsent => {
    const harness = controllerHarness({
      ready: true,
      native: { confirm: jest.fn(async () => badConsent) },
    });
    const before = harness.store.serializeContext();
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    harness.persistCurrent.mockClear();

    await expect(
      harness.controller.confirm(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_RESULT_INVALID',
    });
    expect(harness.native.confirm).toHaveBeenCalledTimes(1);
    expect(harness.store.replaceConfirmed).not.toHaveBeenCalled();
    expect(harness.persistCurrent).not.toHaveBeenCalled();
    expect(harness.store.serializeContext()).toBe(before);
  });

  test('hard-blocks duplicate prepare, confirm, and persistence retry owners', async () => {
    const prepared = deferred<ProjectContextManifestV1>();
    const harness = controllerHarness({
      native: { prepare: jest.fn(() => prepared.promise) },
    });
    await attach(harness);
    await selectKnownPath(harness);
    const firstPrepare = harness.controller.prepare(actionToken(harness));
    await Promise.resolve();
    await expect(
      harness.controller.prepare(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_BUSY',
    });
    expect(harness.native.prepare).toHaveBeenCalledTimes(1);
    prepared.resolve(manifest(SNAPSHOT_B));
    await firstPrepare;

    const confirmation = deferred<ProjectContextConsentV1>();
    harness.native.confirm.mockImplementationOnce(() => confirmation.promise);
    const firstConfirm = harness.controller.confirm(actionToken(harness));
    await Promise.resolve();
    await expect(
      harness.controller.confirm(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_BUSY',
    });
    expect(harness.native.confirm).toHaveBeenCalledTimes(1);
    confirmation.resolve(consent(SNAPSHOT_B, CONSENT_B));
    await firstConfirm;

    const persistence = deferred<SessionDurabilityResult>();
    const pending = controllerHarness({
      runtimeContextId: null,
      durability: [{ status: 'unknown' }],
    });
    await attach(pending);
    await selectKnownPath(pending);
    await pending.controller.prepare(actionToken(pending));
    pending.persistCurrent.mockImplementationOnce(() => persistence.promise);
    const firstRetry = pending.controller.retryPersistence(actionToken(pending));
    await Promise.resolve();
    await expect(
      pending.controller.retryPersistence(actionToken(pending)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_BUSY',
    });
    persistence.resolve({ status: 'committed' });
    await firstRetry;
  });

  test.each([
    {
      name: 'attaching another conversation',
      mutate: async (harness: ControllerHarness) => {
        await harness.controller.attachConversation(OTHER_CONVERSATION_ID);
      },
    },
    {
      name: 'changing the model',
      mutate: async (harness: ControllerHarness) => {
        harness.store.mutateConversation(CONVERSATION_ID, {
          modelId: 'deepseek-v4-pro',
        });
      },
    },
    {
      name: 'changing the project',
      mutate: async (harness: ControllerHarness) => {
        harness.store.mutateConversation(CONVERSATION_ID, {
          projectId: OTHER_PROJECT_ID,
        });
      },
    },
    {
      name: 'changing the runtime context',
      mutate: async (harness: ControllerHarness) => {
        harness.store.mutateConversation(CONVERSATION_ID, {
          runtimeContextId: OTHER_RUNTIME_CONTEXT_ID,
        });
      },
    },
  ])('rejects every old Sheet mutation after $name with zero side effects', async row => {
    const harness = controllerHarness({ ready: true });
    await attach(harness);
    await selectKnownPath(harness);
    const staleToken = actionToken(harness);
    await row.mutate(harness);
    harness.native.listCandidates.mockClear();
    harness.native.prepare.mockClear();
    harness.native.confirm.mockClear();
    harness.native.discard.mockClear();
    harness.store.replacePrepared.mockClear();
    harness.store.replaceConfirmed.mockClear();
    harness.store.disable.mockClear();
    harness.persistCurrent.mockClear();

    for (const operation of [
      () => harness.controller.prepare(staleToken),
      () => harness.controller.confirm(staleToken),
      () => harness.controller.disable(staleToken),
      () => harness.controller.search(staleToken, 'stale-query'),
    ]) {
      await expect(operation()).resolves.toMatchObject({
        status: 'blocked',
        code: 'E_CONTEXT_OWNER_STALE',
      });
    }

    expect(harness.native.listCandidates).not.toHaveBeenCalled();
    expect(harness.native.prepare).not.toHaveBeenCalled();
    expect(harness.native.confirm).not.toHaveBeenCalled();
    expect(harness.native.discard).not.toHaveBeenCalled();
    expect(harness.store.replacePrepared).not.toHaveBeenCalled();
    expect(harness.store.replaceConfirmed).not.toHaveBeenCalled();
    expect(harness.store.disable).not.toHaveBeenCalled();
    expect(harness.persistCurrent).not.toHaveBeenCalled();
  });

  test.each([
    {
      name: 'model',
      patch: { modelId: 'deepseek-v4-pro' as const },
    },
    {
      name: 'runtime context',
      patch: { runtimeContextId: OTHER_RUNTIME_CONTEXT_ID },
    },
  ])('internally cleans refresh B before attach after $name ownership drifts', async row => {
    const harness = controllerHarness({ ready: true });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    harness.store.mutateConversation(CONVERSATION_ID, row.patch);

    await harness.controller.attachConversation(OTHER_CONVERSATION_ID);

    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: OTHER_CONVERSATION_ID },
    });
  });

  test('internally cleans refresh B before attach after project ownership drifts', async () => {
    const harness = controllerHarness({ ready: true });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    harness.store.replaceContext(
      CONVERSATION_ID,
      createProjectContextState(OTHER_PROJECT_ID),
    );
    harness.store.mutateConversation(CONVERSATION_ID, {
      projectId: OTHER_PROJECT_ID,
    });

    await harness.controller.attachConversation(OTHER_CONVERSATION_ID);

    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: OTHER_CONVERSATION_ID },
    });
  });

  test('never exposes a new-project token over old-project candidate authority', async () => {
    const harness = controllerHarness();
    await attach(harness);
    await selectKnownPath(harness, 'shared.ts');
    const before = actionToken(harness);
    harness.store.replaceContext(
      CONVERSATION_ID,
      createProjectContextState(OTHER_PROJECT_ID),
    );
    harness.store.mutateConversation(CONVERSATION_ID, {
      projectId: OTHER_PROJECT_ID,
    });

    const staleRenderToken = actionToken(harness);
    expect(staleRenderToken.projectId).toBe(before.projectId);
    await expect(
      harness.controller.prepare(staleRenderToken),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    expect(harness.native.prepare).not.toHaveBeenCalled();

    await harness.controller.reconcileHydrated(CONVERSATION_ID);
    expect(harness.controller.getState().selectedPaths).toEqual([]);
    await expect(
      harness.controller.prepare(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_RESULT_INVALID',
    });
    expect(harness.native.prepare).toHaveBeenCalledWith(expect.objectContaining({ selected_paths: [] }));
  });

  test('recovers prepared persistence responsibility before attach after owner drift', async () => {
    const harness = controllerHarness({
      runtimeContextId: null,
      durability: [
        { status: 'committed' },
        { status: 'unknown' },
        { status: 'committed' },
      ],
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    harness.store.mutateConversation(CONVERSATION_ID, {
      modelId: 'deepseek-v4-pro',
    });

    await harness.controller.attachConversation(OTHER_CONVERSATION_ID);

    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: OTHER_CONVERSATION_ID },
    });
  });

  test('recovers cleanup responsibility before attach after owner drift', async () => {
    const harness = controllerHarness({ ready: true });
    harness.native.discard
      .mockRejectedValueOnce(new ProjectContextBridgeError('E_CONTEXT_STORAGE'))
      .mockResolvedValueOnce({ schema_version: 1, status: 'discarded' });
    await attach(harness);
    await harness.controller.disable(actionToken(harness));
    harness.store.mutateConversation(CONVERSATION_ID, {
      modelId: 'deepseek-v4-pro',
    });

    await harness.controller.attachConversation(OTHER_CONVERSATION_ID);

    expect(harness.native.discard).toHaveBeenCalledTimes(2);
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: OTHER_CONVERSATION_ID },
    });
  });

  test('keeps disabled cleanup when real transaction commit CAS loses to owner drift', async () => {
    const harness = controllerHarness({
      ready: true,
      durability: [{ status: 'unknown' }, { status: 'committed' }],
    });
    await attach(harness);
    await harness.controller.disable(actionToken(harness));
    harness.store.mutateConversation(CONVERSATION_ID, {
      modelId: 'deepseek-v4-pro',
    });

    await harness.controller.attachConversation(OTHER_CONVERSATION_ID);

    expect(harness.store.transactions.at(-1)?.commit).toHaveReturnedWith(false);
    expect(harness.store.transactions.at(-1)?.rollback).not.toHaveBeenCalled();
    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_A);
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: OTHER_CONVERSATION_ID },
      cleanupSnapshotId: null,
    });
  });

  test('persists confirmed context stale before attach after owner drift', async () => {
    const harness = controllerHarness({
      ready: true,
      durability: [{ status: 'unknown' }, { status: 'committed' }],
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    await harness.controller.confirm(actionToken(harness));
    harness.store.mutateConversation(CONVERSATION_ID, {
      modelId: 'deepseek-v4-pro',
    });

    await harness.controller.attachConversation(OTHER_CONVERSATION_ID);

    expect(harness.store.serializeContext(CONVERSATION_ID)).toContain(
      '"status":"stale"',
    );
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: OTHER_CONVERSATION_ID },
    });
  });

  test('cleans confirmed B before attach when project drift no longer references it', async () => {
    const harness = controllerHarness({
      ready: true,
      durability: [{ status: 'unknown' }, { status: 'committed' }],
    });
    await attach(harness);
    await selectKnownPath(harness);
    await harness.controller.prepare(actionToken(harness));
    await harness.controller.confirm(actionToken(harness));
    harness.store.replaceContext(
      CONVERSATION_ID,
      createProjectContextState(OTHER_PROJECT_ID),
    );
    harness.store.mutateConversation(CONVERSATION_ID, {
      projectId: OTHER_PROJECT_ID,
    });

    await harness.controller.attachConversation(OTHER_CONVERSATION_ID);

    expect(harness.native.discard).toHaveBeenCalledWith(SNAPSHOT_B);
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: OTHER_CONVERSATION_ID },
    });
  });

  test('dedupes duplicate candidate paths deterministically with first occurrence winning', async () => {
    const duplicate = {
      path: 'shared.ts',
      size: 10,
      revision: '1'.repeat(40),
      git_state: 'unchanged' as const,
      eligible: true,
      omission_reason: null,
    };
    const harness = controllerHarness({
      native: {
        listCandidates: jest
          .fn()
          .mockResolvedValueOnce({
            schema_version: 1,
            project_id: PROJECT_ID,
            candidates: [duplicate, { ...duplicate }],
            next_cursor: 'z'.repeat(98),
          })
          .mockResolvedValueOnce({
            schema_version: 1,
            project_id: PROJECT_ID,
            candidates: [
              { ...duplicate, size: 99, revision: '2'.repeat(40) },
              {
                ...duplicate,
                path: 'second.ts',
                revision: '3'.repeat(40),
              },
            ],
            next_cursor: null,
          }),
      },
    });
    await attach(harness);
    await harness.controller.search(actionToken(harness), 'shared');
    await harness.controller.loadMore(actionToken(harness));

    expect(harness.controller.getState().list.candidates).toEqual([
      duplicate,
      { ...duplicate, path: 'second.ts', revision: '3'.repeat(40) },
    ]);
  });

  test('does not issue a delayed native search after owner identity drifts', async () => {
    let scheduled: (() => void) | null = null;
    const harness = controllerHarness({
      scheduleSearch: (_delay, operation) => {
        scheduled = operation;
        return { cancel: jest.fn() };
      },
    });
    await attach(harness);
    const run = harness.controller.search(actionToken(harness), 'delayed');
    harness.store.mutateConversation(CONVERSATION_ID, {
      modelId: 'deepseek-v4-pro',
    });
    (scheduled as (() => void) | null)?.();

    await expect(run).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    expect(harness.native.listCandidates).not.toHaveBeenCalled();
  });

  test('projects synchronous scheduler failures to a value-free error', async () => {
    const harness = controllerHarness({
      scheduleSearch: () => {
        throw new Error('RAW_SCHEDULER_DETAIL');
      },
    });
    await attach(harness);

    await expect(
      harness.controller.search(actionToken(harness), 'scheduled'),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_NATIVE',
    });
    expect(JSON.stringify(harness.controller.getState())).not.toContain(
      'RAW_SCHEDULER_DETAIL',
    );
  });

  test('isolates a throwing scheduler cancel and still settles the superseded search', async () => {
    const scheduled: Array<() => void> = [];
    const harness = controllerHarness({
      scheduleSearch: (_delay, operation) => {
        scheduled.push(operation);
        return {
          cancel: () => {
            throw new Error('RAW_CANCEL_DETAIL');
          },
        };
      },
    });
    await attach(harness);
    const token = actionToken(harness);
    const first = harness.controller.search(token, 'first');
    const second = harness.controller.search(token, 'second');

    await expect(first).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    scheduled[1]?.();
    await expect(second).resolves.toMatchObject({ status: 'completed' });
  });

  test('projects a revoked proxy native error without leaking or throwing', async () => {
    const revoked = Proxy.revocable({}, {});
    revoked.revoke();
    const harness = controllerHarness({
      native: { prepare: jest.fn(async () => Promise.reject(revoked.proxy)) },
    });
    await attach(harness);
    await selectKnownPath(harness);

    await expect(
      harness.controller.prepare(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_NATIVE',
    });
  });

  test('returns frozen defensive state and revalidates private candidate authority at prepare', async () => {
    const candidate = {
      path: 'owned.ts',
      size: 12,
      revision: '9'.repeat(40),
      git_state: 'unchanged' as const,
      eligible: true,
      omission_reason: null,
    };
    const harness = controllerHarness({
      native: {
        listCandidates: jest.fn(async () => ({
          schema_version: 1,
          project_id: PROJECT_ID,
          candidates: [candidate],
          next_cursor: null,
        })),
      },
    });
    await attach(harness);
    await harness.controller.search(actionToken(harness), 'owned');
    harness.controller.setSelectedPaths(actionToken(harness), ['owned.ts']);
    const exposed = harness.controller.getState();
    expect(Object.isFrozen(exposed)).toBe(true);
    expect(Object.isFrozen(exposed.selectedPaths)).toBe(true);
    expect(Object.isFrozen(exposed.selectedCandidates[0])).toBe(true);
    candidate.eligible = false;
    try {
      (exposed.selectedCandidates[0] as { eligible: boolean }).eligible = false;
    } catch {
      // Strict mode may throw; either way the private candidate stays unchanged.
    }

    await expect(
      harness.controller.prepare(actionToken(harness)),
    ).resolves.toMatchObject({ status: 'completed' });
    expect(harness.native.prepare).toHaveBeenCalledTimes(1);
  });

  test('blocks synchronous listener reentry before an outer prepare owns native work', async () => {
    const harness = controllerHarness();
    await attach(harness);
    await selectKnownPath(harness);
    let reentrant: Promise<unknown> | null = null;
    harness.controller.subscribe(() => {
      if (reentrant === null) {
        reentrant = harness.controller.attachConversation(
          OTHER_CONVERSATION_ID,
        );
      }
    });

    await harness.controller.prepare(actionToken(harness));

    await expect(reentrant).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_BUSY',
    });
    expect(harness.native.prepare).toHaveBeenCalledWith(
      expect.objectContaining({
        project_id: PROJECT_ID,
        selected_paths: ['src/index.ts'],
      }),
    );
    expect(harness.controller.getState()).toMatchObject({
      owner: { conversationId: CONVERSATION_ID },
      phase: 'review',
    });
  });

  test('blocks outer prepare when a synchronous listener directly drifts the shared store', async () => {
    const harness = controllerHarness();
    await attach(harness);
    await selectKnownPath(harness, 'shared.ts');
    let drifted = false;
    harness.controller.subscribe(() => {
      if (drifted) return;
      drifted = true;
      harness.store.replaceContext(
        CONVERSATION_ID,
        createProjectContextState(OTHER_PROJECT_ID),
      );
      harness.store.mutateConversation(CONVERSATION_ID, {
        projectId: OTHER_PROJECT_ID,
      });
    });

    await expect(
      harness.controller.prepare(actionToken(harness)),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });
    expect(harness.native.prepare).not.toHaveBeenCalled();
  });

  test('fails closed for hostile tokens and path containers without invoking native', async () => {
    const harness = controllerHarness();
    await attach(harness);
    const hostileToken = new Proxy(actionToken(harness), {
      get() {
        throw new Error('RAW_TOKEN_GETTER');
      },
    });
    expect(
      harness.controller.setSelectedPaths(hostileToken, ['src/index.ts']),
    ).toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_OWNER_STALE',
    });

    await selectKnownPath(harness);
    const hostilePaths = new Proxy(['src/index.ts'], {
      get() {
        throw new Error('RAW_PATH_GETTER');
      },
    });
    expect(
      harness.controller.setSelectedPaths(actionToken(harness), hostilePaths),
    ).toMatchObject({
      status: 'blocked',
      code: 'E_CONTEXT_REQUEST_INVALID',
    });
    expect(harness.native.prepare).not.toHaveBeenCalled();
  });

  test('never truncates a search query into an orphan surrogate', async () => {
    const harness = controllerHarness();
    await attach(harness);
    const query = `${'a'.repeat(255)}😀`;

    await harness.controller.search(actionToken(harness), query);

    const forwarded = harness.native.listCandidates.mock.calls.at(-1)?.[1];
    expect(forwarded).toBe('a'.repeat(255));
    expect(forwarded).not.toMatch(/[\uD800-\uDFFF]/u);
  });
});
