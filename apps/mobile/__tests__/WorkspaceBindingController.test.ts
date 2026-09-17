import { WorkspaceBindingController } from '../src/workspaces/WorkspaceBindingController';
import {
  createChatStore,
  hydrateChatState,
  type ChatStore,
} from '../src/state';
import type { SessionDurabilityResult } from '../src/completion/SessionPersistence';
import type { WorkspaceRootRefV1 } from '../src/native/WorkspaceRoot';

const WORKSPACE_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const PROJECT_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const OPERATION_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const OTHER_OPERATION_ID = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

function descriptor(
  workspaceId = WORKSPACE_ID,
  bindingRevision = 1,
): {
  schema_version: 2;
  workspace_id: string;
  display_name: string;
  origin: 'rish_created';
  status: 'ok';
  binding_revision: number;
  capabilities: {
    read: boolean;
    write: boolean;
    git: boolean;
    project_context: boolean;
    files_visible: boolean;
  };
  created_at: string;
  last_opened_at: string;
} {
  return {
    schema_version: 2,
    workspace_id: workspaceId,
    display_name: 'Rish Files',
    origin: 'rish_created',
    status: 'ok',
    binding_revision: bindingRevision,
    capabilities: {
      read: true,
      write: true,
      git: false,
      project_context: false,
      files_visible: true,
    },
    created_at: '2026-08-31T00:00:00.000Z',
    last_opened_at: '2026-08-31T00:00:00.000Z',
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(resolveValue => {
    resolve = resolveValue;
  });
  return { promise, resolve };
}

async function flushPromises(): Promise<void> {
  for (let index = 0; index < 8; index += 1) await Promise.resolve();
}

function harness() {
  let conversationSequence = 0;
  const store = createChatStore({
    createId: () => `conversation-${++conversationSequence}`,
    now: () => '2026-08-31T00:00:00.000Z',
  });
  const conversationId = store.createConversation();
  const workspaces = {
    list: jest.fn().mockResolvedValue({
      schema_version: 1,
      workspaces: [descriptor()],
    }),
    resolve: jest.fn().mockResolvedValue({
      schema_version: 1,
      disposition: 'direct',
      workspace: descriptor(),
    }),
    queryOperation: jest.fn().mockResolvedValue({
      schema_version: 1,
      status: 'not_started',
    }),
    create: jest.fn().mockResolvedValue(descriptor()),
  };
  const projectForWorkspace = jest.fn().mockResolvedValue({
    schema_version: 1,
    status: 'none',
  });
  const contextGuard = jest.fn().mockResolvedValue(true);
  const completionGuard = jest.fn().mockResolvedValue(true);
  const persistCurrent = jest
    .fn<Promise<SessionDurabilityResult>, []>()
    .mockResolvedValue({ status: 'committed' });
  const controller = new WorkspaceBindingController({
    chat: store,
    workspaces,
    projectForWorkspace,
    contextGuard,
    completionGuard,
    persistCurrent,
    createOperationId: () => OPERATION_ID,
    isPickerGenerationCurrent: () => true,
    isSurfaceNonceCurrent: () => true,
  });
  return {
    store,
    conversationId,
    workspaces,
    projectForWorkspace,
    contextGuard,
    completionGuard,
    persistCurrent,
    controller,
  };
}

function bindInput(
  conversationId: string,
  overrides: Partial<{
    workspaceId: string;
    target: ReturnType<typeof descriptor>;
    pickerGeneration: number;
    surfaceNonce: number;
    expectedProjectId: string | null;
  }> = {},
) {
  return {
    conversationId,
    workspaceId: WORKSPACE_ID,
    target: descriptor(),
    pickerGeneration: 3,
    surfaceNonce: 9,
    requiredCapabilities: ['read'] as const,
    ...overrides,
  };
}

test('runs resolve -> project lookup -> Context -> Completion -> Store CAS -> V9 persist in order', async () => {
  const fixture = harness();
  const order: string[] = [];
  fixture.workspaces.resolve.mockImplementation(async request => {
    order.push('resolve');
    expect(request).toEqual({
      schema_version: 1,
      workspace_id: WORKSPACE_ID,
      expected_binding_revision: 1,
      required_capabilities: ['read'],
    });
    return {
      schema_version: 1,
      disposition: 'direct',
      workspace: descriptor(),
    };
  });
  fixture.projectForWorkspace.mockImplementation(async root => {
    order.push('project');
    expect(root).toEqual({
      schema_version: 1,
      workspace_id: WORKSPACE_ID,
      binding_revision: 1,
      project_id: null,
    });
    return { schema_version: 1, status: 'none' };
  });
  fixture.contextGuard.mockImplementation(async () => {
    order.push('context');
    return true;
  });
  fixture.completionGuard.mockImplementation(async () => {
    order.push('completion');
    return true;
  });
  fixture.persistCurrent.mockImplementation(async () => {
    order.push('persist');
    return { status: 'committed' };
  });

  const outcome = await fixture.controller.bindWorkspace(
    bindInput(fixture.conversationId),
  );

  expect(outcome).toMatchObject({
    status: 'committed',
    operationId: OPERATION_ID,
    root: {
      schema_version: 1,
      workspace_id: WORKSPACE_ID,
      binding_revision: 1,
      project_id: null,
    },
  });
  expect(order).toEqual([
    'resolve',
    'project',
    'context',
    'completion',
    'persist',
  ]);
  expect(
    fixture.store.getState().conversations[fixture.conversationId],
  ).toMatchObject({
    workspaceId: WORKSPACE_ID,
    workspaceBinding: {
      schemaVersion: 1,
      workspaceId: WORKSPACE_ID,
      bindingRevision: 1,
      projectId: null,
    },
  });
});

test('discovers and creates exactly one app-owned Files workspace with a stable operation ID', async () => {
  const fixture = harness();
  fixture.workspaces.list.mockResolvedValueOnce({
    schema_version: 1,
    workspaces: [],
  });

  const outcome = await fixture.controller.ensureAppOwnedWorkspace({
    conversationId: fixture.conversationId,
    displayName: 'Rish Files',
    requiredCapabilities: ['read', 'write'],
    surfaceNonce: 9,
  });

  expect(outcome.status).toBe('committed');
  expect(fixture.workspaces.create).toHaveBeenCalledWith({
    schema_version: 1,
    display_name: 'Rish Files',
    operation_id: OPERATION_ID,
  });
  expect(fixture.workspaces.resolve).toHaveBeenCalledWith(
    expect.objectContaining({
      expected_binding_revision: 1,
      required_capabilities: ['read', 'write'],
    }),
  );
  expect(fixture.persistCurrent).toHaveBeenCalledTimes(1);
});

test('late callbacks are stale no-ops after invalidation', async () => {
  const fixture = harness();
  const pending = deferred<{
    schema_version: 1;
    disposition: 'direct';
    workspace: ReturnType<typeof descriptor>;
  }>();
  fixture.workspaces.resolve.mockReturnValueOnce(pending.promise);
  const binding = fixture.controller.bindWorkspace(
    bindInput(fixture.conversationId),
  );

  fixture.controller.invalidate();
  pending.resolve({
    schema_version: 1,
    disposition: 'direct',
    workspace: descriptor(),
  });

  await expect(binding).resolves.toMatchObject({ status: 'stale' });
  expect(fixture.projectForWorkspace).not.toHaveBeenCalled();
  expect(fixture.persistCurrent).not.toHaveBeenCalled();
  expect(
    fixture.store.getState().conversations[fixture.conversationId]
      ?.workspaceBinding,
  ).toBeNull();
});

test.each(['project lookup', 'Context guard', 'Completion guard'] as const)(
  'returns stale after owner drift in the %s callback',
  async stage => {
    const fixture = harness();
    const pending = deferred<unknown>();
    if (stage === 'project lookup') {
      fixture.projectForWorkspace.mockReturnValueOnce(pending.promise);
    } else if (stage === 'Context guard') {
      fixture.contextGuard.mockReturnValueOnce(
        pending.promise as Promise<boolean>,
      );
    } else {
      fixture.completionGuard.mockReturnValueOnce(
        pending.promise as Promise<boolean>,
      );
    }
    const operation = fixture.controller.bindWorkspace(
      bindInput(fixture.conversationId),
    );
    await flushPromises();
    fixture.store.createConversation({ select: true });
    pending.resolve(
      stage === 'project lookup' ? { schema_version: 1, status: 'none' } : true,
    );
    await expect(operation).resolves.toMatchObject({ status: 'stale' });
    expect(fixture.persistCurrent).not.toHaveBeenCalled();
  },
);

test('accepts an exact projectless cleanup rebound before applying the workspace root', async () => {
  const fixture = harness();
  const original =
    fixture.store.getState().conversations[fixture.conversationId]!;
  let currentState = {
    ...fixture.store.getState(),
    conversations: {
      ...fixture.store.getState().conversations,
      [fixture.conversationId]: {
        ...original,
        projectId: PROJECT_ID,
        projectContext: {
          snapshot: { snapshot_id: 'snapshot' },
          activePreparationId: null,
        } as never,
      },
    },
  };
  const apply = jest.fn(
    (input: { owner: { expectedProjectContext: unknown } }) => {
      const before = currentState.conversations[fixture.conversationId]!;
      const next = {
        ...before,
        projectId: null,
        workspaceId: WORKSPACE_ID,
        workspaceBinding: {
          schemaVersion: 1 as const,
          workspaceId: WORKSPACE_ID,
          bindingRevision: 1,
          projectId: null,
        },
        projectContext: null,
      };
      currentState = {
        ...currentState,
        conversations: {
          ...currentState.conversations,
          [fixture.conversationId]: next,
        },
      };
      expect(
        (input.owner as unknown as { expected_project_context: unknown })
          .expected_project_context,
      ).toBeNull();
      return {
        commit: jest.fn(() => true),
        rollback: jest.fn(() => true),
      };
    },
  );
  const chat = {
    getState: () => currentState,
    applyConversationWorkspaceBinding: apply,
  } as unknown as ChatStore;
  fixture.contextGuard.mockImplementation(async (_id, targetProjectId) => {
    expect(targetProjectId).toBeNull();
    const cleaned = {
      ...currentState.conversations[fixture.conversationId]!,
      projectId: null,
      workspaceId: null,
      workspaceBinding: null,
      projectContext: null,
    };
    currentState = {
      ...currentState,
      projectContextDestructiveEpoch: 1,
      conversations: {
        ...currentState.conversations,
        [fixture.conversationId]: cleaned,
      },
    };
    return { status: 'rebound' as const };
  });
  fixture.completionGuard.mockResolvedValue(true);
  const controller = new WorkspaceBindingController({
    chat,
    workspaces: fixture.workspaces,
    projectForWorkspace: fixture.projectForWorkspace,
    contextGuard: fixture.contextGuard,
    completionGuard: fixture.completionGuard,
    persistCurrent: fixture.persistCurrent,
    createOperationId: () => OTHER_OPERATION_ID,
  });

  const outcome = await controller.bindWorkspace(
    bindInput(fixture.conversationId),
  );
  expect(outcome).toEqual(expect.objectContaining({ status: 'committed' }));
  expect(fixture.completionGuard).toHaveBeenCalledTimes(1);
  expect(apply).toHaveBeenCalledTimes(1);
});

test('Context guard failure prevents Completion, Store mutation, and persistence', async () => {
  const fixture = harness();
  fixture.contextGuard.mockResolvedValue(false);

  await expect(
    fixture.controller.bindWorkspace(bindInput(fixture.conversationId)),
  ).resolves.toMatchObject({
    status: 'blocked',
    code: 'E_CONTEXT_OWNER_STALE',
  });
  expect(fixture.completionGuard).not.toHaveBeenCalled();
  expect(fixture.persistCurrent).not.toHaveBeenCalled();
  expect(
    fixture.store.getState().conversations[fixture.conversationId]
      ?.workspaceBinding,
  ).toBeNull();
});

test('Store CAS conflict never calls V9 persistence', async () => {
  const fixture = harness();
  const apply = jest.fn().mockReturnValue(null);
  const chat = {
    getState: () => fixture.store.getState(),
    applyConversationWorkspaceBinding: apply,
  } as unknown as ChatStore;
  const controller = new WorkspaceBindingController({
    chat,
    workspaces: fixture.workspaces,
    projectForWorkspace: fixture.projectForWorkspace,
    contextGuard: fixture.contextGuard,
    completionGuard: fixture.completionGuard,
    persistCurrent: fixture.persistCurrent,
    createOperationId: () => OTHER_OPERATION_ID,
  });

  await expect(
    controller.bindWorkspace(bindInput(fixture.conversationId)),
  ).resolves.toMatchObject({
    status: 'conflict',
    code: 'E_WORKSPACE_CONFLICT',
  });
  expect(apply).toHaveBeenCalledTimes(1);
  expect(fixture.persistCurrent).not.toHaveBeenCalled();
});

test('a committed binding survives schema-9 serialize and restart hydration', async () => {
  const fixture = harness();
  await fixture.controller.bindWorkspace(bindInput(fixture.conversationId));
  const restarted = createChatStore({
    initialState: hydrateChatState(fixture.store.serialize()),
  });
  expect(
    restarted.getState().conversations[fixture.conversationId],
  ).toMatchObject({
    workspaceId: WORKSPACE_ID,
    workspaceBinding: {
      workspaceId: WORKSPACE_ID,
      bindingRevision: 1,
      projectId: null,
    },
  });
});

test('project lookup freezes the exact project root and never accepts a mismatched project', async () => {
  const fixture = harness();
  fixture.workspaces.resolve.mockResolvedValue({
    schema_version: 1,
    disposition: 'direct',
    workspace: {
      ...descriptor(),
      capabilities: {
        read: true,
        write: true,
        git: true,
        project_context: true,
        files_visible: true,
      },
    },
  });
  fixture.projectForWorkspace.mockResolvedValue({
    schema_version: 1,
    status: 'attached',
    project: {
      schema_version: 2,
      project_id: PROJECT_ID,
      workspace_id: WORKSPACE_ID,
      workspace_binding_revision: 1,
      display_name: 'Repo',
      git_topology: 'private_split_gitdir',
    },
  });

  const outcome = await fixture.controller.bindWorkspace(
    bindInput(fixture.conversationId),
  );
  expect(outcome.status).toBe('committed');
  expect(fixture.workspaces.resolve).toHaveBeenCalledTimes(2);
  expect(fixture.projectForWorkspace).toHaveBeenCalledTimes(2);
  if (outcome.status === 'committed') {
    expect(outcome.root).toEqual({
      schema_version: 1,
      workspace_id: WORKSPACE_ID,
      binding_revision: 1,
      project_id: PROJECT_ID,
    } satisfies WorkspaceRootRefV1);
  }
});

test('commits only when the attached project stays equal to expectedProjectId', async () => {
  const fixture = harness();
  const projectWorkspace = {
    ...descriptor(),
    capabilities: {
      read: true,
      write: true,
      git: true,
      project_context: true,
      files_visible: true,
    },
  };
  const attached = {
    schema_version: 1 as const,
    status: 'attached' as const,
    project: {
      schema_version: 2 as const,
      project_id: PROJECT_ID,
      workspace_id: WORKSPACE_ID,
      workspace_binding_revision: 1,
      display_name: 'Repo',
      git_topology: 'private_split_gitdir' as const,
    },
  };
  fixture.workspaces.resolve.mockResolvedValue({
    schema_version: 1,
    disposition: 'direct',
    workspace: projectWorkspace,
  });
  fixture.projectForWorkspace.mockResolvedValue(attached);

  await expect(
    fixture.controller.bindWorkspace(
      bindInput(fixture.conversationId, {
        target: projectWorkspace,
        expectedProjectId: PROJECT_ID,
      }),
    ),
  ).resolves.toMatchObject({
    status: 'committed',
    root: { project_id: PROJECT_ID },
  });
  expect(fixture.projectForWorkspace).toHaveBeenCalledTimes(2);
  expect(fixture.persistCurrent).toHaveBeenCalledTimes(1);
});

test('fails closed before persistence when expected project drifts attached to none', async () => {
  const fixture = harness();
  const projectWorkspace = {
    ...descriptor(),
    capabilities: {
      read: true,
      write: true,
      git: true,
      project_context: true,
      files_visible: true,
    },
  };
  fixture.workspaces.resolve.mockResolvedValue({
    schema_version: 1,
    disposition: 'direct',
    workspace: projectWorkspace,
  });
  fixture.projectForWorkspace
    .mockResolvedValueOnce({
      schema_version: 1,
      status: 'attached',
      project: {
        schema_version: 2,
        project_id: PROJECT_ID,
        workspace_id: WORKSPACE_ID,
        workspace_binding_revision: 1,
        display_name: 'Repo',
        git_topology: 'private_split_gitdir',
      },
    })
    .mockResolvedValueOnce({ schema_version: 1, status: 'none' });

  await expect(
    fixture.controller.bindWorkspace(
      bindInput(fixture.conversationId, {
        target: projectWorkspace,
        expectedProjectId: PROJECT_ID,
      }),
    ),
  ).resolves.toMatchObject({
    status: 'conflict',
    code: 'E_WORKSPACE_CONFLICT',
  });
  expect(fixture.persistCurrent).not.toHaveBeenCalled();
  expect(
    fixture.store.getState().conversations[fixture.conversationId]
      ?.workspaceBinding,
  ).toBeNull();
});

test('blocks a non-null project root when the producer cannot prove all V2 capabilities', async () => {
  const fixture = harness();
  fixture.projectForWorkspace.mockResolvedValue({
    schema_version: 1,
    status: 'attached',
    project: {
      schema_version: 2,
      project_id: PROJECT_ID,
      workspace_id: WORKSPACE_ID,
      workspace_binding_revision: 1,
      display_name: 'Repo',
      git_topology: 'private_split_gitdir',
    },
  });

  await expect(
    fixture.controller.bindWorkspace(bindInput(fixture.conversationId)),
  ).resolves.toMatchObject({
    status: 'blocked',
    code: 'E_WORKSPACE_CAPABILITY',
  });
  expect(fixture.workspaces.resolve).toHaveBeenCalledTimes(2);
  expect(fixture.workspaces.resolve.mock.calls[1]?.[0]).toMatchObject({
    required_capabilities: ['read', 'write', 'git', 'project_context'],
  });
  expect(
    fixture.store.getState().conversations[fixture.conversationId]
      ?.workspaceBinding,
  ).toBeNull();
  expect(fixture.persistCurrent).not.toHaveBeenCalled();
});

test('an indeterminate result for a departed owner does not wedge the controller', async () => {
  const fixture = harness();
  const persisted = deferred<{ status: 'unknown' }>();
  fixture.persistCurrent.mockReturnValueOnce(persisted.promise as never);
  const binding = fixture.controller.bindWorkspace(
    bindInput(fixture.conversationId),
  );

  // Let the bind actually reach the write before the picker closes; that is
  // the window the latch used to be installed in. Nothing can retry a
  // candidate nobody owns, so it must not outlive the owner: it was installed
  // anyway, and invalidate() refuses while it is set.
  for (let index = 0; index < 16; index += 1) await Promise.resolve();
  expect(fixture.persistCurrent).toHaveBeenCalledTimes(1);
  fixture.controller.invalidate();
  persisted.resolve({ status: 'unknown' });
  await expect(binding).resolves.toMatchObject({ status: 'stale' });

  // The wedge showed up here: a stranded latch made every later bind refuse
  // with E_WORKSPACE_PERSISTENCE for the life of the app.
  fixture.controller.invalidate();
  fixture.persistCurrent.mockResolvedValueOnce({ status: 'committed' });
  const again = await fixture.controller.bindWorkspace(
    bindInput(fixture.conversationId),
  );
  expect(again).not.toMatchObject({ code: 'E_WORKSPACE_PERSISTENCE' });
});

test('an indeterminate persistence result retains the Store owner for exact retry', async () => {
  const fixture = harness();
  fixture.persistCurrent.mockResolvedValueOnce({ status: 'unknown' });

  await expect(
    fixture.controller.bindWorkspace(bindInput(fixture.conversationId)),
  ).resolves.toMatchObject({
    status: 'unknown',
    code: 'E_WORKSPACE_PERSISTENCE',
  });
  expect(
    fixture.store.getState().conversations[fixture.conversationId]
      ?.workspaceBinding,
  ).not.toBeNull();
  fixture.controller.invalidate();
  fixture.persistCurrent.mockResolvedValueOnce({ status: 'committed' });
  await expect(fixture.controller.retryPersistence()).resolves.toMatchObject({
    status: 'committed',
    operationId: OPERATION_ID,
  });
});

test('session-only persistence retains the candidate instead of rolling it back', async () => {
  const fixture = harness();
  fixture.persistCurrent.mockResolvedValueOnce({ status: 'session_only' });

  await expect(
    fixture.controller.bindWorkspace(bindInput(fixture.conversationId)),
  ).resolves.toMatchObject({
    status: 'session_only',
    code: 'E_WORKSPACE_PERSISTENCE',
  });
  expect(
    fixture.store.getState().conversations[fixture.conversationId]
      ?.workspaceBinding,
  ).not.toBeNull();
  expect(fixture.controller.getState().phase).toBe('persistence_pending');
});

test('retrying a pending A binding after selecting B reports owner drift and never routes A root', async () => {
  const fixture = harness();
  fixture.persistCurrent.mockResolvedValueOnce({ status: 'unknown' });
  await fixture.controller.bindWorkspace(bindInput(fixture.conversationId));
  const bId = fixture.store.createConversation({ select: true });
  expect(bId).not.toBe(fixture.conversationId);
  fixture.persistCurrent.mockResolvedValueOnce({ status: 'committed' });

  await expect(fixture.controller.retryPersistence()).resolves.toMatchObject({
    status: 'committed',
    ownerDrifted: true,
    code: 'E_WORKSPACE_CONFLICT',
  });
  expect(
    fixture.store.getState().conversations[fixture.conversationId]
      ?.workspaceBinding,
  ).not.toBeNull();
});

test('committed persistence is not reversed when a late owner drift arrives', async () => {
  const fixture = harness();
  const pending = deferred<SessionDurabilityResult>();
  fixture.persistCurrent.mockReturnValueOnce(pending.promise);
  const binding = fixture.controller.bindWorkspace(
    bindInput(fixture.conversationId),
  );
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  expect(fixture.persistCurrent).toHaveBeenCalledTimes(1);
  fixture.store.createConversation({ select: true });
  pending.resolve({ status: 'committed' });

  await expect(binding).resolves.toMatchObject({
    status: 'committed',
    ownerDrifted: true,
    code: 'E_WORKSPACE_CONFLICT',
  });
  expect(
    fixture.store.getState().conversations[fixture.conversationId]
      ?.workspaceBinding,
  ).not.toBeNull();
});

test('reconciles an ambiguous app-owned create by querying the same operation before retrying', async () => {
  const fixture = harness();
  fixture.workspaces.list
    .mockResolvedValueOnce({ schema_version: 1, workspaces: [] })
    .mockResolvedValueOnce({ schema_version: 1, workspaces: [descriptor()] });
  fixture.workspaces.create.mockRejectedValueOnce(new Error('bridge lost'));
  fixture.workspaces.queryOperation.mockResolvedValueOnce({
    schema_version: 1,
    status: 'committed',
    receipt: {
      operation_id: OPERATION_ID,
      workspace_id: WORKSPACE_ID,
      operation: 'create',
      binding_revision: 1,
    },
  });

  await expect(
    fixture.controller.ensureAppOwnedWorkspace({
      conversationId: fixture.conversationId,
      displayName: 'Rish Files',
      requiredCapabilities: ['read'],
      surfaceNonce: 9,
      requireProjectless: true,
    }),
  ).resolves.toMatchObject({ status: 'committed' });
  expect(fixture.workspaces.queryOperation).toHaveBeenCalledWith({
    schema_version: 1,
    operation_id: OPERATION_ID,
  });
  expect(fixture.workspaces.create).toHaveBeenCalledTimes(1);
});

test('reuses a global pending create operation after A is invalidated and B becomes selected', async () => {
  const fixture = harness();
  const createPending = deferred<ReturnType<typeof descriptor>>();
  let listCount = 0;
  fixture.workspaces.list.mockImplementation(async () => ({
    schema_version: 1,
    workspaces: listCount++ >= 2 ? [descriptor()] : [],
  }));
  fixture.workspaces.create.mockReturnValueOnce(createPending.promise);
  fixture.workspaces.queryOperation
    .mockResolvedValueOnce({
      schema_version: 1,
      status: 'in_progress',
    })
    .mockResolvedValueOnce({
      schema_version: 1,
      status: 'committed',
      receipt: {
        operation_id: OPERATION_ID,
        workspace_id: WORKSPACE_ID,
        operation: 'create',
        binding_revision: 1,
      },
    });

  const a = fixture.controller.ensureAppOwnedWorkspace({
    conversationId: fixture.conversationId,
    displayName: 'Rish Files',
    requiredCapabilities: ['read'],
    surfaceNonce: 9,
    requireProjectless: true,
  });
  await flushPromises();
  fixture.controller.invalidate();
  const bId = fixture.store.createConversation({ select: true });

  await expect(
    fixture.controller.ensureAppOwnedWorkspace({
      conversationId: bId,
      displayName: 'Another label is ignored while reconciling',
      requiredCapabilities: ['read'],
      surfaceNonce: 10,
      requireProjectless: true,
    }),
  ).resolves.toMatchObject({
    status: 'unknown',
    operationId: OPERATION_ID,
  });
  expect(fixture.workspaces.queryOperation).toHaveBeenCalledWith({
    schema_version: 1,
    operation_id: OPERATION_ID,
  });
  expect(fixture.workspaces.create).toHaveBeenCalledTimes(1);

  createPending.resolve(descriptor());
  await expect(a).resolves.toMatchObject({ status: 'stale' });
  await expect(
    fixture.controller.ensureAppOwnedWorkspace({
      conversationId: bId,
      displayName: 'A different label cannot mint a second operation',
      requiredCapabilities: ['read'],
      surfaceNonce: 10,
      requireProjectless: true,
    }),
  ).resolves.toMatchObject({
    status: 'committed',
    operationId: OPERATION_ID,
  });
  expect(
    fixture.store.getState().conversations[bId]?.workspaceBinding,
  ).toMatchObject({ workspaceId: WORKSPACE_ID });
});
