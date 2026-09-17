import type {
  LocalWorkspacesNativeV1,
  WorkspaceCapability,
  WorkspaceDescriptorV2,
  WorkspaceQueryOperationResultV1,
} from '../native/LocalWorkspaces';
import type {
  LocalProjectDescriptorV2,
  ProjectForWorkspaceResultV1,
} from '../native/LocalProjects';
import {
  assertWorkspaceRootRefV1,
  type WorkspaceRootRefV1,
} from '../native/WorkspaceRoot';
import type { SessionDurabilityResult } from '../completion/SessionPersistence';
import type {
  ChatState,
  ChatStore,
  Conversation,
  OneShotChatTransaction,
} from '../state';
import type { ProjectContextState } from '../project-context';

/** The binding flow is intentionally single-flight per Home surface. */
export type WorkspaceBindingPhase =
  | 'idle'
  | 'resolving'
  | 'project_lookup'
  | 'guarding_context'
  | 'guarding_completion'
  | 'applying'
  | 'persistence_pending'
  | 'committed';

export type WorkspaceBindingControllerState = {
  readonly phase: WorkspaceBindingPhase;
  readonly operationId: string | null;
  readonly conversationId: string | null;
  readonly workspaceId: string | null;
  readonly bindingRevision: number | null;
  readonly projectId: string | null;
  readonly failureCode: WorkspaceBindingFailureCode | null;
};

export type WorkspaceBindingFailureCode =
  | 'E_WORKSPACE_BUSY'
  | 'E_WORKSPACE_INVALID'
  | 'E_WORKSPACE_NOT_FOUND'
  | 'E_WORKSPACE_STATUS_STALE'
  | 'E_WORKSPACE_REVOKED'
  | 'E_WORKSPACE_UNAVAILABLE'
  | 'E_WORKSPACE_NOT_DOWNLOADED'
  | 'E_WORKSPACE_IMPORT_REQUIRED'
  | 'E_WORKSPACE_CAPABILITY'
  | 'E_WORKSPACE_ROOT_CHANGED'
  | 'E_WORKSPACE_CONFLICT'
  | 'E_WORKSPACE_PERSISTENCE'
  | 'E_PROJECT_NATIVE'
  | 'E_PROJECT_RESULT_INVALID'
  | 'E_CONTEXT_OWNER_STALE'
  | 'E_COMPLETION_OWNER_STALE';

export type WorkspaceBindingTargetV1 = Pick<
  WorkspaceDescriptorV2,
  | 'schema_version'
  | 'workspace_id'
  | 'display_name'
  | 'origin'
  | 'status'
  | 'binding_revision'
  | 'capabilities'
  | 'created_at'
  | 'last_opened_at'
>;

export type WorkspaceBindingRequestV1 = {
  /** The conversation must still be the selected conversation at commit. */
  readonly conversationId: string;
  readonly workspaceId: string;
  /** A picker row or native create result captured before the first await. */
  readonly target?: WorkspaceBindingTargetV1;
  readonly requiredCapabilities?: readonly WorkspaceCapability[];
  /** The picker generation and surface nonce are opaque UI ownership tokens. */
  readonly pickerGeneration?: number;
  readonly surfaceNonce?: number;
  /** Files bootstrap must not accidentally adopt a project root. */
  readonly requireProjectless?: boolean;
  /** If present, native project lookup must stay on this exact project. */
  readonly expectedProjectId?: string | null;
  /** Retries reuse this ID; the controller never creates a second ID. */
  readonly operationId?: string;
};

export type EnsureAppWorkspaceRequestV1 = Omit<
  WorkspaceBindingRequestV1,
  'workspaceId' | 'target'
> & {
  readonly displayName: string;
};

export type WorkspaceContextGuardResult =
  | boolean
  | { readonly status: 'rebound' };

export type WorkspaceBindingOutcome =
  | {
      readonly status: 'committed' | 'unchanged';
      readonly operationId: string;
      readonly root: WorkspaceRootRefV1;
      readonly workspace: WorkspaceDescriptorV2;
      readonly project: LocalProjectDescriptorV2 | null;
      readonly ownerDrifted?: boolean;
      readonly code?: WorkspaceBindingFailureCode;
    }
  | {
      readonly status:
        | 'stale'
        | 'blocked'
        | 'conflict'
        | 'not_committed'
        | 'session_only'
        | 'unknown';
      readonly operationId: string;
      readonly code: WorkspaceBindingFailureCode;
      readonly root?: WorkspaceRootRefV1;
      readonly workspace?: WorkspaceDescriptorV2;
      readonly project?: LocalProjectDescriptorV2 | null;
      readonly ownerDrifted?: boolean;
    };

export type WorkspaceBindingControllerDependencies = {
  readonly chat: Pick<
    ChatStore,
    'getState' | 'applyConversationWorkspaceBinding'
  >;
  readonly workspaces: Pick<
    LocalWorkspacesNativeV1,
    'list' | 'resolve' | 'create' | 'queryOperation'
  >;
  readonly projectForWorkspace: (
    root: WorkspaceRootRefV1,
  ) => Promise<ProjectForWorkspaceResultV1>;
  /** Side-effect-free Project Context navigation/destructive guard. */
  readonly contextGuard: (
    conversationId: string,
    targetProjectId: string | null,
  ) => Promise<WorkspaceContextGuardResult>;
  /** Completion guard is called only after contextGuard succeeds. */
  readonly completionGuard: (conversationId: string) => Promise<boolean>;
  /** This callback must perform the V9 CAS persist of the current Store state. */
  readonly persistCurrent: () => Promise<SessionDurabilityResult>;
  readonly createOperationId: () => string;
  readonly isPickerGenerationCurrent?: (generation: number) => boolean;
  readonly isSurfaceNonceCurrent?: (nonce: number) => boolean;
};

type CapturedOwner = {
  readonly conversationId: string;
  readonly selectedConversationId: string | null;
  readonly expectedConversation: Conversation;
  readonly expectedProjectContext: ProjectContextState | null;
  readonly expectedProjectId: string | null;
  readonly expectedWorkspaceId: string | null;
  readonly expectedRuntimeContextId: string | null;
  readonly expectedModelId: Conversation['modelId'];
  readonly expectedDestructiveEpoch: number;
  readonly pickerGeneration: number | null;
  readonly surfaceNonce: number | null;
};

type ActiveOperation = {
  readonly operationId: string;
  owner: CapturedOwner;
};

type PendingPersistence = {
  readonly operation: ActiveOperation;
  readonly transaction: OneShotChatTransaction;
  readonly candidateConversation: Conversation;
  readonly root: WorkspaceRootRefV1;
  readonly workspace: WorkspaceDescriptorV2;
  readonly project: LocalProjectDescriptorV2 | null;
};

type PendingCreate = {
  readonly operationId: string;
  readonly displayName: string;
};

const DEFAULT_REQUIRED_CAPABILITIES: readonly WorkspaceCapability[] = ['read'];

const INITIAL_STATE: WorkspaceBindingControllerState = Object.freeze({
  phase: 'idle',
  operationId: null,
  conversationId: null,
  workspaceId: null,
  bindingRevision: null,
  projectId: null,
  failureCode: null,
});

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const INVALID_EXPECTED_PROJECT_ID = Symbol('invalid expected project id');

const STABLE_ERROR_CODES: ReadonlySet<string> = new Set([
  'E_WORKSPACE_BUSY',
  'E_WORKSPACE_INVALID',
  'E_WORKSPACE_NOT_FOUND',
  'E_WORKSPACE_STATUS_STALE',
  'E_WORKSPACE_REVOKED',
  'E_WORKSPACE_UNAVAILABLE',
  'E_WORKSPACE_NOT_DOWNLOADED',
  'E_WORKSPACE_IMPORT_REQUIRED',
  'E_WORKSPACE_CAPABILITY',
  'E_WORKSPACE_ROOT_CHANGED',
  'E_WORKSPACE_CONFLICT',
  'E_WORKSPACE_PERSISTENCE',
  'E_PROJECT_NATIVE',
  'E_PROJECT_RESULT_INVALID',
  'E_CONTEXT_OWNER_STALE',
  'E_COMPLETION_OWNER_STALE',
]);

function isCanonicalUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

function cloneExpectedProjectId(
  request: { readonly expectedProjectId?: string | null },
): string | null | undefined | typeof INVALID_EXPECTED_PROJECT_ID {
  try {
    if (!Object.prototype.hasOwnProperty.call(request, 'expectedProjectId')) {
      return undefined;
    }
    const value = request.expectedProjectId;
    if (value === null) return null;
    return isCanonicalUuid(value)
      ? `${value}`
      : INVALID_EXPECTED_PROJECT_ID;
  } catch {
    return INVALID_EXPECTED_PROJECT_ID;
  }
}

function matchesExpectedProject(
  expectedProjectId: string | null | undefined,
  actualProjectId: string | null,
): boolean {
  return expectedProjectId === undefined || expectedProjectId === actualProjectId;
}

function isSafeRevision(value: unknown): value is number {
  return (
    typeof value === 'number' &&
    Number.isSafeInteger(value) &&
    value >= 1 &&
    value < Number.MAX_SAFE_INTEGER &&
    !Object.is(value, -0)
  );
}

function isFiniteEpoch(value: unknown): value is number {
  return (
    typeof value === 'number' &&
    Number.isSafeInteger(value) &&
    value >= 0 &&
    value < Number.MAX_SAFE_INTEGER &&
    !Object.is(value, -0)
  );
}

function isWorkspaceCapability(value: unknown): value is WorkspaceCapability {
  return (
    value === 'read' ||
    value === 'write' ||
    value === 'git' ||
    value === 'project_context'
  );
}

function canonicalCapabilities(
  value: readonly WorkspaceCapability[] | undefined,
): readonly WorkspaceCapability[] | null {
  const capabilities = value ?? DEFAULT_REQUIRED_CAPABILITIES;
  if (!Array.isArray(capabilities) || capabilities.length > 4) return null;
  const result: WorkspaceCapability[] = [];
  for (const capability of capabilities) {
    if (!isWorkspaceCapability(capability) || result.includes(capability)) {
      return null;
    }
    result.push(capability);
  }
  return result;
}

function isTargetDescriptor(value: unknown): value is WorkspaceDescriptorV2 {
  if (typeof value !== 'object' || value === null) return false;
  const descriptor = value as Partial<WorkspaceDescriptorV2>;
  return (
    descriptor.schema_version === 2 &&
    isCanonicalUuid(descriptor.workspace_id) &&
    isSafeRevision(descriptor.binding_revision) &&
    (descriptor.status === 'ok' ||
      descriptor.status === 'stale' ||
      descriptor.status === 'revoked' ||
      descriptor.status === 'unavailable' ||
      descriptor.status === 'not_downloaded') &&
    typeof descriptor.display_name === 'string' &&
    typeof descriptor.origin === 'string' &&
    typeof descriptor.capabilities === 'object' &&
    descriptor.capabilities !== null
  );
}

function hasRequiredCapabilities(
  descriptor: WorkspaceDescriptorV2,
  required: readonly WorkspaceCapability[],
): boolean {
  return required.every(capability => descriptor.capabilities[capability]);
}

function statusFailure(
  descriptor: WorkspaceDescriptorV2,
): WorkspaceBindingFailureCode {
  switch (descriptor.status) {
    case 'stale':
      return 'E_WORKSPACE_STATUS_STALE';
    case 'revoked':
      return 'E_WORKSPACE_REVOKED';
    case 'unavailable':
      return 'E_WORKSPACE_UNAVAILABLE';
    case 'not_downloaded':
      return 'E_WORKSPACE_NOT_DOWNLOADED';
    case 'ok':
      return 'E_WORKSPACE_CONFLICT';
  }
}

function errorCode(error: unknown): WorkspaceBindingFailureCode {
  if (typeof error === 'object' && error !== null) {
    try {
      const descriptor = Object.getOwnPropertyDescriptor(error, 'code');
      const code = descriptor?.value;
      if (typeof code === 'string' && STABLE_ERROR_CODES.has(code)) {
        return code as WorkspaceBindingFailureCode;
      }
    } catch {
      // Hostile native errors intentionally collapse to a stable code below.
    }
  }
  return 'E_WORKSPACE_UNAVAILABLE';
}

function sameConversationOwner(
  conversation: Conversation | undefined,
  owner: CapturedOwner,
): boolean {
  return (
    conversation !== undefined &&
    conversation === owner.expectedConversation &&
    conversation.id === owner.conversationId &&
    conversation.projectId === owner.expectedProjectId &&
    conversation.workspaceId === owner.expectedWorkspaceId &&
    conversation.runtimeContextId === owner.expectedRuntimeContextId &&
    conversation.modelId === owner.expectedModelId &&
    conversation.projectContext === owner.expectedProjectContext
  );
}

function projectLookupIsValid(
  value: ProjectForWorkspaceResultV1,
  root: WorkspaceRootRefV1,
): value is
  | { schema_version: 1; status: 'none' }
  | {
      schema_version: 1;
      status: 'attached';
      project: LocalProjectDescriptorV2;
    } {
  if (
    typeof value !== 'object' ||
    value === null ||
    value.schema_version !== 1
  ) {
    return false;
  }
  if (value.status === 'none') return true;
  if (value.status !== 'attached') return false;
  const project = value.project;
  return (
    project.schema_version === 2 &&
    isCanonicalUuid(project.project_id) &&
    project.project_id !== root.project_id &&
    project.workspace_id === root.workspace_id &&
    project.workspace_binding_revision === root.binding_revision &&
    typeof project.display_name === 'string' &&
    (project.git_topology === 'legacy_embedded' ||
      project.git_topology === 'private_split_gitdir')
  );
}

function cloneRoot(root: WorkspaceRootRefV1): WorkspaceRootRefV1 {
  return {
    schema_version: 1,
    workspace_id: root.workspace_id,
    binding_revision: root.binding_revision,
    project_id: root.project_id,
  };
}

function normalizedDurability(value: unknown): SessionDurabilityResult {
  if (
    typeof value === 'object' &&
    value !== null &&
    'status' in value &&
    (value.status === 'committed' ||
      value.status === 'session_only' ||
      value.status === 'not_committed' ||
      value.status === 'unknown')
  ) {
    return { status: value.status };
  }
  return { status: 'unknown' };
}

function committedCreateReceipt(
  value: WorkspaceQueryOperationResultV1,
  operationId: string,
): { readonly workspaceId: string; readonly bindingRevision: number } | null {
  if (
    typeof value !== 'object' ||
    value === null ||
    value.schema_version !== 1 ||
    value.status !== 'committed'
  ) {
    return null;
  }
  const receipt = value.receipt;
  if (typeof receipt !== 'object' || receipt === null) return null;
  if (
    receipt.operation_id !== operationId ||
    receipt.operation !== 'create' ||
    !isCanonicalUuid(receipt.workspace_id) ||
    !isSafeRevision(receipt.binding_revision)
  ) {
    return null;
  }
  return {
    workspaceId: receipt.workspace_id,
    bindingRevision: receipt.binding_revision,
  };
}

/**
 * Coordinates the one user-visible workspace amendment. The controller owns
 * no path, bookmark, descriptor authority, or durable state of its own; it
 * only carries opaque metadata until the Store transaction is persisted.
 */
export class WorkspaceBindingController {
  private readonly dependencies: WorkspaceBindingControllerDependencies;
  private state: WorkspaceBindingControllerState = INITIAL_STATE;
  private readonly listeners = new Set<
    (state: WorkspaceBindingControllerState) => void
  >();
  private active: ActiveOperation | null = null;
  private pendingPersistence: PendingPersistence | null = null;
  private pendingCreate: PendingCreate | null = null;

  constructor(dependencies: WorkspaceBindingControllerDependencies) {
    this.dependencies = dependencies;
  }

  getState(): WorkspaceBindingControllerState {
    return this.state;
  }

  subscribe(
    listener: (state: WorkspaceBindingControllerState) => void,
  ): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** Invalidates a pending flow without mutating the Store. */
  invalidate(): void {
    if (this.pendingPersistence !== null) {
      return;
    }
    this.active = null;
    this.publish(INITIAL_STATE);
  }

  /**
   * Resolve and bind a workspace selected by the picker. The target revision
   * comes from the exact descriptor returned by `list`, never from a label or
   * a caller-created path.
   */
  async bindWorkspace(
    request: WorkspaceBindingRequestV1,
  ): Promise<WorkspaceBindingOutcome> {
    if (this.pendingPersistence !== null) {
      return {
        status: 'blocked',
        operationId: this.pendingPersistence.operation.operationId,
        code: 'E_WORKSPACE_PERSISTENCE',
      };
    }
    if (this.active !== null) {
      return {
        status: 'blocked',
        operationId: this.active.operationId,
        code: 'E_WORKSPACE_BUSY',
      };
    }
    const operationId = this.operationId(request.operationId);
    if (operationId === null) {
      return {
        status: 'blocked',
        operationId: request.operationId ?? '',
        code: 'E_WORKSPACE_INVALID',
      };
    }
    const expectedProjectId = cloneExpectedProjectId(request);
    if (expectedProjectId === INVALID_EXPECTED_PROJECT_ID) {
      return {
        status: 'blocked',
        operationId,
        code: 'E_WORKSPACE_INVALID',
      };
    }
    let owner = this.captureOwner(request);
    if (owner === null) {
      return {
        status: 'stale',
        operationId,
        code: 'E_WORKSPACE_CONFLICT',
      };
    }
    const required = canonicalCapabilities(request.requiredCapabilities);
    if (required === null || !isCanonicalUuid(request.workspaceId)) {
      return { status: 'blocked', operationId, code: 'E_WORKSPACE_INVALID' };
    }
    const operation: ActiveOperation = {
      operationId,
      owner,
    };
    this.active = operation;
    this.publish({
      phase: 'resolving',
      operationId,
      conversationId: owner.conversationId,
      workspaceId: request.workspaceId,
      bindingRevision: request.target?.binding_revision ?? null,
      projectId: null,
      failureCode: null,
    });
    try {
      let target: WorkspaceDescriptorV2 | null = null;
      if (request.target !== undefined) {
        target = isTargetDescriptor(request.target) ? request.target : null;
      } else {
        const listing = await this.dependencies.workspaces.list();
        if (!this.isCurrent(operation)) return this.stale(operationId);
        target =
          listing.workspaces.find(
            workspace => workspace.workspace_id === request.workspaceId,
          ) ?? null;
      }
      if (!this.isCurrent(operation)) return this.stale(operationId);
      if (
        target === null ||
        target.workspace_id !== request.workspaceId ||
        !isTargetDescriptor(target)
      ) {
        return {
          status: 'blocked',
          operationId,
          code: 'E_WORKSPACE_NOT_FOUND',
        };
      }
      if (target.status !== 'ok') {
        return { status: 'blocked', operationId, code: statusFailure(target) };
      }
      if (!hasRequiredCapabilities(target, required)) {
        return {
          status: 'blocked',
          operationId,
          code: 'E_WORKSPACE_CAPABILITY',
        };
      }

      let resolved = await this.dependencies.workspaces.resolve({
        schema_version: 1,
        workspace_id: target.workspace_id,
        expected_binding_revision: target.binding_revision,
        required_capabilities: required,
      });
      if (!this.isCurrent(operation)) return this.stale(operationId);
      if (
        resolved.workspace.workspace_id !== target.workspace_id ||
        resolved.workspace.binding_revision !== target.binding_revision
      ) {
        return {
          status: 'blocked',
          operationId,
          code: 'E_WORKSPACE_ROOT_CHANGED',
        };
      }
      if (resolved.disposition === 'import_required') {
        return {
          status: 'blocked',
          operationId,
          code: 'E_WORKSPACE_IMPORT_REQUIRED',
        };
      }
      if (resolved.workspace.status !== 'ok') {
        return {
          status: 'blocked',
          operationId,
          code: statusFailure(resolved.workspace),
        };
      }
      if (!hasRequiredCapabilities(resolved.workspace, required)) {
        return {
          status: 'blocked',
          operationId,
          code: 'E_WORKSPACE_CAPABILITY',
        };
      }

      const baseRoot = assertWorkspaceRootRefV1({
        schema_version: 1,
        workspace_id: resolved.workspace.workspace_id,
        binding_revision: resolved.workspace.binding_revision,
        project_id: null,
      });
      this.publish({
        phase: 'project_lookup',
        operationId,
        conversationId: owner.conversationId,
        workspaceId: baseRoot.workspace_id,
        bindingRevision: baseRoot.binding_revision,
        projectId: null,
        failureCode: null,
      });
      const lookup = await this.dependencies.projectForWorkspace(baseRoot);
      if (!this.isCurrent(operation)) return this.stale(operationId);
      if (!projectLookupIsValid(lookup, baseRoot)) {
        return {
          status: 'blocked',
          operationId,
          code: 'E_PROJECT_RESULT_INVALID',
        };
      }
      let project = lookup.status === 'attached' ? lookup.project : null;
      if (
        !matchesExpectedProject(
          expectedProjectId,
          project?.project_id ?? null,
        )
      ) {
        return {
          status: 'conflict',
          operationId,
          code: 'E_WORKSPACE_CONFLICT',
        };
      }
      if (request.requireProjectless && project !== null) {
        return { status: 'blocked', operationId, code: 'E_WORKSPACE_CONFLICT' };
      }
      if (project !== null) {
        const projectCapabilities: readonly WorkspaceCapability[] = [
          'read',
          'write',
          'git',
          'project_context',
        ];
        const attachedResolved = await this.dependencies.workspaces.resolve({
          schema_version: 1,
          workspace_id: baseRoot.workspace_id,
          expected_binding_revision: baseRoot.binding_revision,
          required_capabilities: projectCapabilities,
        });
        if (!this.isCurrent(operation)) return this.stale(operationId);
        if (
          attachedResolved.disposition !== 'direct' ||
          attachedResolved.workspace.status !== 'ok' ||
          attachedResolved.workspace.workspace_id !== baseRoot.workspace_id ||
          attachedResolved.workspace.binding_revision !==
            baseRoot.binding_revision ||
          !hasRequiredCapabilities(
            attachedResolved.workspace,
            projectCapabilities,
          )
        ) {
          return {
            status: 'blocked',
            operationId,
            code: 'E_WORKSPACE_CAPABILITY',
          };
        }
        resolved = attachedResolved;
        const recheckedLookup = await this.dependencies.projectForWorkspace(
          baseRoot,
        );
        if (!this.isCurrent(operation)) return this.stale(operationId);
        if (
          projectLookupIsValid(recheckedLookup, baseRoot) &&
          !matchesExpectedProject(
            expectedProjectId,
            recheckedLookup.status === 'attached'
              ? recheckedLookup.project.project_id
              : null,
          )
        ) {
          return {
            status: 'conflict',
            operationId,
            code: 'E_WORKSPACE_CONFLICT',
          };
        }
        if (
          !projectLookupIsValid(recheckedLookup, baseRoot) ||
          recheckedLookup.status !== 'attached' ||
          recheckedLookup.project.project_id !== project.project_id ||
          recheckedLookup.project.workspace_id !== project.workspace_id ||
          recheckedLookup.project.workspace_binding_revision !==
            project.workspace_binding_revision
        ) {
          return {
            status: 'blocked',
            operationId,
            code: 'E_WORKSPACE_ROOT_CHANGED',
          };
        }
        project = recheckedLookup.project;
      }
      const root = assertWorkspaceRootRefV1({
        ...baseRoot,
        project_id: project?.project_id ?? null,
      });
      if (!matchesExpectedProject(expectedProjectId, root.project_id)) {
        return {
          status: 'conflict',
          operationId,
          code: 'E_WORKSPACE_CONFLICT',
        };
      }
      const currentBindingBeforeGuards =
        owner.expectedConversation.workspaceBinding ?? null;
      if (
        currentBindingBeforeGuards !== null &&
        currentBindingBeforeGuards.workspaceId === root.workspace_id &&
        currentBindingBeforeGuards.bindingRevision === root.binding_revision &&
        currentBindingBeforeGuards.projectId === root.project_id
      ) {
        return {
          status: 'unchanged',
          operationId,
          root: cloneRoot(root),
          workspace: resolved.workspace,
          project,
        };
      }
      this.publish({
        phase: 'guarding_context',
        operationId,
        conversationId: owner.conversationId,
        workspaceId: root.workspace_id,
        bindingRevision: root.binding_revision,
        projectId: root.project_id,
        failureCode: null,
      });

      // Context is deliberately first. A false result must not invoke any
      // Completion cancellation or make a Store/native binding mutation.
      const contextGuardResult = await this.dependencies.contextGuard(
        owner.conversationId,
        root.project_id,
      );
      const contextRebound =
        typeof contextGuardResult === 'object' &&
        contextGuardResult !== null &&
        contextGuardResult.status === 'rebound';
      if (
        !(contextRebound
          ? this.isShellCurrent(operation, true)
          : this.isCurrent(operation))
      ) {
        return this.stale(operationId);
      }
      if (contextGuardResult === false) {
        return {
          status: 'blocked',
          operationId,
          code: 'E_CONTEXT_OWNER_STALE',
        };
      }
      if (contextRebound) {
        const refreshedOwner = this.captureOwner(request);
        if (
          refreshedOwner === null ||
          refreshedOwner.conversationId !== owner.conversationId ||
          refreshedOwner.selectedConversationId !==
            owner.selectedConversationId ||
          refreshedOwner.expectedModelId !== owner.expectedModelId ||
          refreshedOwner.expectedProjectId !== root.project_id ||
          refreshedOwner.expectedWorkspaceId !== null
        ) {
          return this.stale(operationId);
        }
        owner = refreshedOwner;
        operation.owner = refreshedOwner;
      }
      this.publish({
        phase: 'guarding_completion',
        operationId,
        conversationId: owner.conversationId,
        workspaceId: root.workspace_id,
        bindingRevision: root.binding_revision,
        projectId: root.project_id,
        failureCode: null,
      });
      const completionGuardResult = await this.dependencies.completionGuard(
        owner.conversationId,
      );
      if (!this.isCurrent(operation)) return this.stale(operationId);
      if (!completionGuardResult) {
        return {
          status: 'blocked',
          operationId,
          code: 'E_COMPLETION_OWNER_STALE',
        };
      }
      if (!this.isCurrent(operation)) return this.stale(operationId);

      const currentBinding =
        owner.expectedConversation.workspaceBinding ?? null;
      if (
        currentBinding !== null &&
        currentBinding.workspaceId === root.workspace_id &&
        currentBinding.bindingRevision === root.binding_revision &&
        currentBinding.projectId === root.project_id
      ) {
        return {
          status: 'unchanged',
          operationId,
          root: cloneRoot(root),
          workspace: resolved.workspace,
          project,
        };
      }
      if (!matchesExpectedProject(expectedProjectId, root.project_id)) {
        return {
          status: 'conflict',
          operationId,
          code: 'E_WORKSPACE_CONFLICT',
        };
      }

      this.publish({
        phase: 'applying',
        operationId,
        conversationId: owner.conversationId,
        workspaceId: root.workspace_id,
        bindingRevision: root.binding_revision,
        projectId: root.project_id,
        failureCode: null,
      });
      const transaction =
        this.dependencies.chat.applyConversationWorkspaceBinding({
          schema_version: 1,
          owner: {
            conversation_id: owner.conversationId,
            expected_conversation: owner.expectedConversation,
            expected_project_context: owner.expectedProjectContext,
            expected_destructive_epoch: owner.expectedDestructiveEpoch,
          },
          binding: {
            schema_version: 1,
            workspace_id: root.workspace_id,
            binding_revision: root.binding_revision,
            project_id: root.project_id,
          },
        });
      if (transaction === null) {
        return {
          status: 'conflict',
          operationId,
          code: 'E_WORKSPACE_CONFLICT',
        };
      }
      const candidateConversation =
        this.dependencies.chat.getState().conversations[owner.conversationId];
      if (candidateConversation === undefined) {
        transaction.rollback();
        return {
          status: 'conflict',
          operationId,
          code: 'E_WORKSPACE_CONFLICT',
        };
      }
      if (!matchesExpectedProject(expectedProjectId, root.project_id)) {
        transaction.rollback();
        return {
          status: 'conflict',
          operationId,
          code: 'E_WORKSPACE_CONFLICT',
        };
      }
      this.publish({
        phase: 'persistence_pending',
        operationId,
        conversationId: owner.conversationId,
        workspaceId: root.workspace_id,
        bindingRevision: root.binding_revision,
        projectId: root.project_id,
        failureCode: null,
      });
      let durability: SessionDurabilityResult;
      try {
        durability = normalizedDurability(
          await this.dependencies.persistCurrent(),
        );
      } catch {
        // A thrown persistence call is indeterminate. Keep the candidate
        // owner and let the exact same operation be retried/query-reconciled.
        durability = { status: 'unknown' };
      }
      const candidateStillOwned =
        this.isShellCurrent(operation) &&
        this.dependencies.chat.getState().conversations[
          owner.conversationId
        ] === candidateConversation;
      const candidateRowStillOwned =
        this.dependencies.chat.getState().conversations[
          owner.conversationId
        ] === candidateConversation;
      if (durability.status === 'committed') {
        // Native session commit is the point of no return. Even if a late
        // listener replaced the in-memory row, never reverse it with a blind
        // rollback; surface a committed/refresh-needed result instead.
        const committed = transaction.commit();
        this.pendingPersistence = null;
        if (!committed || !candidateStillOwned) {
          return {
            status: 'committed',
            operationId,
            code: 'E_WORKSPACE_CONFLICT',
            ownerDrifted: true,
            root: cloneRoot(root),
            workspace: resolved.workspace,
            project,
          };
        }
      } else if (
        durability.status === 'session_only' ||
        durability.status === 'unknown'
      ) {
        // These are recoverable owner states, not rollback permission: the
        // write may have landed, so nothing here rolls it back. The latch
        // exists only so retryPersistence can act on it, and that refuses a
        // candidate nobody owns. Installing one for an owner that is already
        // gone left it with no actor and no exit, because invalidate() refuses
        // while it is set -- so every later bindWorkspace returned
        // E_WORKSPACE_PERSISTENCE for the life of the app.
        if (!candidateStillOwned) return this.stale(operationId);
        this.pendingPersistence = {
          operation,
          transaction,
          candidateConversation,
          root,
          workspace: resolved.workspace,
          project,
        };
        return {
          status: durability.status,
          operationId,
          code: 'E_WORKSPACE_PERSISTENCE',
          root: cloneRoot(root),
          workspace: resolved.workspace,
          project,
        };
      } else {
        // `not_committed` explicitly proves that no session candidate won the
        // CAS, so rollback is safe while the candidate remains owner-live.
        if (!candidateRowStillOwned) return this.stale(operationId);
        if (!transaction.rollback()) {
          return this.stale(operationId);
        }
        if (!candidateStillOwned) return this.stale(operationId);
        return {
          status: 'not_committed',
          operationId,
          code: 'E_WORKSPACE_CONFLICT',
        };
      }
      this.publish({
        phase: 'committed',
        operationId,
        conversationId: owner.conversationId,
        workspaceId: root.workspace_id,
        bindingRevision: root.binding_revision,
        projectId: root.project_id,
        failureCode: null,
      });
      return {
        status: 'committed',
        operationId,
        root: cloneRoot(root),
        workspace: resolved.workspace,
        project,
      };
    } catch (error) {
      if (this.active !== operation || !this.isCurrent(operation)) {
        return this.stale(operationId);
      }
      return { status: 'blocked', operationId, code: errorCode(error) };
    } finally {
      if (this.active === operation) this.active = null;
      if (
        this.active === null &&
        this.pendingPersistence?.operation !== operation &&
        this.state.operationId === operationId &&
        this.state.phase !== 'committed'
      ) {
        this.publish(INITIAL_STATE);
      }
    }
  }

  /**
   * Explicit Files open path. It reuses one healthy Rish-owned workspace and
   * creates one only when the registry has none; the same operation ID is
   * retained through native create and the later binding flow.
   */
  async ensureAppOwnedWorkspace(
    request: EnsureAppWorkspaceRequestV1,
  ): Promise<WorkspaceBindingOutcome> {
    if (this.pendingPersistence !== null) {
      return {
        status: 'blocked',
        operationId: this.pendingPersistence.operation.operationId,
        code: 'E_WORKSPACE_PERSISTENCE',
      };
    }
    if (this.active !== null) {
      return {
        status: 'blocked',
        operationId: this.active.operationId,
        code: 'E_WORKSPACE_BUSY',
      };
    }
    const pendingCreate = this.pendingCreate;
    const reusableOperationId =
      request.operationId === undefined && pendingCreate !== null
        ? pendingCreate.operationId
        : request.operationId;
    const createDisplayName =
      pendingCreate !== null &&
      pendingCreate.operationId === reusableOperationId
        ? pendingCreate.displayName
        : request.displayName;
    const operationId = this.operationId(reusableOperationId);
    if (operationId === null) {
      return {
        status: 'blocked',
        operationId: request.operationId ?? '',
        code: 'E_WORKSPACE_INVALID',
      };
    }
    const expectedProjectId = cloneExpectedProjectId(request);
    if (expectedProjectId === INVALID_EXPECTED_PROJECT_ID) {
      return {
        status: 'blocked',
        operationId,
        code: 'E_WORKSPACE_INVALID',
      };
    }
    const owner = this.captureOwner(request);
    if (owner === null) return this.stale(operationId);
    const required = canonicalCapabilities(request.requiredCapabilities);
    if (
      required === null ||
      request.displayName.trim().length === 0 ||
      request.displayName !== request.displayName.trim()
    ) {
      return { status: 'blocked', operationId, code: 'E_WORKSPACE_INVALID' };
    }
    const operation: ActiveOperation = {
      operationId,
      owner,
    };
    this.active = operation;
    try {
      const listing = await this.dependencies.workspaces.list();
      if (!this.isCurrent(operation)) return this.stale(operationId);
      const appOwned = listing.workspaces
        .filter(
          workspace =>
            (workspace.origin === 'rish_created' ||
              workspace.origin === 'legacy_app_owned') &&
            workspace.status === 'ok' &&
            workspace.capabilities.files_visible,
        )
        .sort((left, right) =>
          left.workspace_id.localeCompare(right.workspace_id),
        )[0];
      const retryingCreate =
        pendingCreate !== null && pendingCreate.operationId === operationId;
      let target = retryingCreate ? undefined : appOwned;
      if (retryingCreate) {
        let prior: WorkspaceQueryOperationResultV1;
        try {
          prior = await this.dependencies.workspaces.queryOperation({
            schema_version: 1,
            operation_id: operationId,
          });
        } catch {
          if (!this.isCurrent(operation)) return this.stale(operationId);
          return {
            status: 'unknown',
            operationId,
            code: 'E_WORKSPACE_PERSISTENCE',
          };
        }
        if (!this.isCurrent(operation)) return this.stale(operationId);
        const committedPrior = committedCreateReceipt(prior, operationId);
        if (committedPrior !== null) {
          const recoveredListing = await this.dependencies.workspaces.list();
          if (!this.isCurrent(operation)) return this.stale(operationId);
          const recoveredTarget = recoveredListing.workspaces.find(
            workspace =>
              workspace.workspace_id === committedPrior.workspaceId &&
              workspace.binding_revision === committedPrior.bindingRevision,
          );
          if (recoveredTarget === undefined) {
            return {
              status: 'unknown',
              operationId,
              code: 'E_WORKSPACE_ROOT_CHANGED',
            };
          }
          target = recoveredTarget;
        } else if (prior.status === 'in_progress') {
          return {
            status: 'unknown',
            operationId,
            code: 'E_WORKSPACE_PERSISTENCE',
          };
        }
      }
      if (target === undefined) {
        // Mark the native create as a global in-flight operation before the
        // await. If this surface is invalidated, another conversation still
        // has to query/reuse this exact operation rather than minting one.
        this.pendingCreate = {
          operationId,
          displayName: createDisplayName,
        };
        this.publish({
          phase: 'resolving',
          operationId,
          conversationId: owner.conversationId,
          workspaceId: null,
          bindingRevision: null,
          projectId: null,
          failureCode: null,
        });
        let created: WorkspaceDescriptorV2 | null = null;
        try {
          created = await this.dependencies.workspaces.create({
            schema_version: 1,
            display_name: createDisplayName,
            operation_id: operationId,
          });
        } catch {
          // The response is reconciled below using the same operation ID.
        }
        if (!this.isCurrent(operation)) return this.stale(operationId);
        if (
          created !== null &&
          isTargetDescriptor(created) &&
          created.status === 'ok'
        ) {
          target = created;
        } else {
          // A lost/ambiguous create response must be reconciled by the same
          // durable operation ID before any retry is attempted.
          let queried: WorkspaceQueryOperationResultV1;
          try {
            queried = await this.dependencies.workspaces.queryOperation({
              schema_version: 1,
              operation_id: operationId,
            });
          } catch {
            if (!this.isCurrent(operation)) return this.stale(operationId);
            this.pendingCreate = {
              operationId,
              displayName: createDisplayName,
            };
            return {
              status: 'unknown',
              operationId,
              code: 'E_WORKSPACE_PERSISTENCE',
            };
          }
          if (!this.isCurrent(operation)) return this.stale(operationId);
          const committed = committedCreateReceipt(queried, operationId);
          if (committed !== null) {
            const recoveredListing = await this.dependencies.workspaces.list();
            if (!this.isCurrent(operation)) return this.stale(operationId);
            const recoveredTarget = recoveredListing.workspaces.find(
              workspace =>
                workspace.workspace_id === committed.workspaceId &&
                workspace.binding_revision === committed.bindingRevision,
            );
            if (recoveredTarget === undefined) {
              this.pendingCreate = {
                operationId,
                displayName: createDisplayName,
              };
              return {
                status: 'unknown',
                operationId,
                code: 'E_WORKSPACE_ROOT_CHANGED',
              };
            }
            target = recoveredTarget;
          } else if (queried.status === 'not_started') {
            let retried: WorkspaceDescriptorV2 | null = null;
            try {
              retried = await this.dependencies.workspaces.create({
                schema_version: 1,
                display_name: createDisplayName,
                operation_id: operationId,
              });
            } catch {
              if (!this.isCurrent(operation)) return this.stale(operationId);
              this.pendingCreate = {
                operationId,
                displayName: createDisplayName,
              };
              return {
                status: 'unknown',
                operationId,
                code: 'E_WORKSPACE_PERSISTENCE',
              };
            }
            if (!this.isCurrent(operation)) return this.stale(operationId);
            if (isTargetDescriptor(retried)) target = retried;
            else {
              this.pendingCreate = {
                operationId,
                displayName: createDisplayName,
              };
              return {
                status: 'unknown',
                operationId,
                code: 'E_WORKSPACE_PERSISTENCE',
              };
            }
          } else {
            this.pendingCreate = {
              operationId,
              displayName: createDisplayName,
            };
            return {
              status: 'unknown',
              operationId,
              code: 'E_WORKSPACE_PERSISTENCE',
            };
          }
        }
      }
      if (!this.isCurrent(operation)) return this.stale(operationId);
      this.pendingCreate = null;
      if (!isTargetDescriptor(target)) {
        return {
          status: 'blocked',
          operationId,
          code: 'E_WORKSPACE_ROOT_CHANGED',
        };
      }
      // Keep the owner captured before list/create. The private helper cannot
      // recapture after native awaits, so this path calls the common pipeline
      // with an exact target while preserving the same operation ID.
      this.active = null;
      return await this.bindWorkspace({
        conversationId: request.conversationId,
        workspaceId: target.workspace_id,
        target,
        requiredCapabilities: required,
        pickerGeneration: request.pickerGeneration,
        surfaceNonce: request.surfaceNonce,
        requireProjectless: request.requireProjectless,
        ...(expectedProjectId === undefined ? {} : { expectedProjectId }),
        operationId,
      });
    } catch (error) {
      if (this.active !== operation || !this.isCurrent(operation)) {
        return this.stale(operationId);
      }
      return { status: 'blocked', operationId, code: errorCode(error) };
    } finally {
      if (this.active === operation) this.active = null;
    }
  }

  /** Retry the exact pending V9 write without recreating the workspace bind. */
  async retryPersistence(): Promise<WorkspaceBindingOutcome> {
    const pending = this.pendingPersistence;
    if (pending === null) {
      return {
        status: 'blocked',
        operationId: this.state.operationId ?? '',
        code: 'E_WORKSPACE_CONFLICT',
      };
    }
    if (this.active !== null) {
      return {
        status: 'blocked',
        operationId: this.active.operationId,
        code: 'E_WORKSPACE_BUSY',
      };
    }
    const operation = pending.operation;
    this.active = operation;
    this.publish({
      phase: 'persistence_pending',
      operationId: operation.operationId,
      conversationId: operation.owner.conversationId,
      workspaceId: pending.root.workspace_id,
      bindingRevision: pending.root.binding_revision,
      projectId: pending.root.project_id,
      failureCode: null,
    });
    try {
      let durability: SessionDurabilityResult;
      try {
        durability = normalizedDurability(
          await this.dependencies.persistCurrent(),
        );
      } catch {
        durability = { status: 'unknown' };
      }
      const candidateStillOwned = this.isPendingCandidateCurrent(pending);
      if (durability.status === 'committed') {
        const committed = pending.transaction.commit();
        this.pendingPersistence = null;
        const ownerDrifted = !committed || !candidateStillOwned;
        this.publish({
          phase: 'committed',
          operationId: operation.operationId,
          conversationId: operation.owner.conversationId,
          workspaceId: pending.root.workspace_id,
          bindingRevision: pending.root.binding_revision,
          projectId: pending.root.project_id,
          failureCode: ownerDrifted ? 'E_WORKSPACE_CONFLICT' : null,
        });
        return {
          status: 'committed',
          operationId: operation.operationId,
          ownerDrifted,
          ...(ownerDrifted ? { code: 'E_WORKSPACE_CONFLICT' as const } : {}),
          root: cloneRoot(pending.root),
          workspace: pending.workspace,
          project: pending.project,
        };
      }
      if (
        durability.status === 'session_only' ||
        durability.status === 'unknown'
      ) {
        if (!candidateStillOwned) {
          // The write stands; only the latch is dropped. Nothing can retry a
          // candidate nobody owns, and holding it keeps invalidate() refusing.
          this.pendingPersistence = null;
          return this.stale(operation.operationId);
        }
        return {
          status: durability.status,
          operationId: operation.operationId,
          code: 'E_WORKSPACE_PERSISTENCE',
          root: cloneRoot(pending.root),
          workspace: pending.workspace,
          project: pending.project,
        };
      }
      // not_committed means the write did not land, so the rollback below is
      // safe whoever owns the candidate now. Returning before it left both the
      // Store candidate and the latch behind for good.
      if (!pending.transaction.rollback()) {
        return {
          status: 'conflict',
          operationId: operation.operationId,
          code: 'E_WORKSPACE_CONFLICT',
        };
      }
      this.pendingPersistence = null;
      if (!candidateStillOwned) return this.stale(operation.operationId);
      return {
        status: 'not_committed',
        operationId: operation.operationId,
        code: 'E_WORKSPACE_CONFLICT',
      };
    } finally {
      if (this.active === operation) this.active = null;
      if (
        this.active === null &&
        this.pendingPersistence?.operation !== operation &&
        this.state.operationId === operation.operationId &&
        this.state.phase !== 'committed'
      ) {
        this.publish(INITIAL_STATE);
      }
    }
  }

  private operationId(value: string | undefined): string | null {
    try {
      const candidate = value ?? this.dependencies.createOperationId();
      return isCanonicalUuid(candidate) ? candidate : null;
    } catch {
      return null;
    }
  }

  private captureOwner(
    request: Pick<
      WorkspaceBindingRequestV1,
      'conversationId' | 'pickerGeneration' | 'surfaceNonce'
    >,
  ): CapturedOwner | null {
    const state = this.dependencies.chat.getState();
    const conversation = state.conversations[request.conversationId];
    if (
      conversation === undefined ||
      state.selectedConversationId !== request.conversationId ||
      !isFiniteEpoch(state.projectContextDestructiveEpoch)
    ) {
      return null;
    }
    return {
      conversationId: request.conversationId,
      selectedConversationId: state.selectedConversationId,
      expectedConversation: conversation,
      expectedProjectContext: conversation.projectContext,
      expectedProjectId: conversation.projectId,
      expectedWorkspaceId: conversation.workspaceId,
      expectedRuntimeContextId: conversation.runtimeContextId,
      expectedModelId: conversation.modelId,
      expectedDestructiveEpoch: state.projectContextDestructiveEpoch,
      pickerGeneration: request.pickerGeneration ?? null,
      surfaceNonce: request.surfaceNonce ?? null,
    };
  }

  private isCurrent(operation: ActiveOperation): boolean {
    if (this.active !== operation) return false;
    const { owner } = operation;
    const state: ChatState = this.dependencies.chat.getState();
    if (
      state.selectedConversationId !== owner.selectedConversationId ||
      state.projectContextDestructiveEpoch !== owner.expectedDestructiveEpoch ||
      !sameConversationOwner(state.conversations[owner.conversationId], owner)
    ) {
      return false;
    }
    if (
      owner.pickerGeneration !== null &&
      this.dependencies.isPickerGenerationCurrent !== undefined &&
      !this.dependencies.isPickerGenerationCurrent(owner.pickerGeneration)
    ) {
      return false;
    }
    return !(
      owner.surfaceNonce !== null &&
      this.dependencies.isSurfaceNonceCurrent !== undefined &&
      !this.dependencies.isSurfaceNonceCurrent(owner.surfaceNonce)
    );
  }

  /** Once Store.apply has run, the conversation reference intentionally changed. */
  private isShellCurrent(
    operation: ActiveOperation,
    allowEpochChange = false,
  ): boolean {
    if (this.active !== operation) return false;
    const { owner } = operation;
    const state = this.dependencies.chat.getState();
    if (
      state.selectedConversationId !== owner.selectedConversationId ||
      (!allowEpochChange &&
        state.projectContextDestructiveEpoch !== owner.expectedDestructiveEpoch)
    ) {
      return false;
    }
    if (
      owner.pickerGeneration !== null &&
      this.dependencies.isPickerGenerationCurrent !== undefined &&
      !this.dependencies.isPickerGenerationCurrent(owner.pickerGeneration)
    ) {
      return false;
    }
    return !(
      owner.surfaceNonce !== null &&
      this.dependencies.isSurfaceNonceCurrent !== undefined &&
      !this.dependencies.isSurfaceNonceCurrent(owner.surfaceNonce)
    );
  }

  /** Recovery remains bound to its original selected conversation and surface. */
  private isPendingCandidateCurrent(pending: PendingPersistence): boolean {
    if (this.active !== pending.operation) return false;
    const state = this.dependencies.chat.getState();
    if (
      state.selectedConversationId !==
        pending.operation.owner.selectedConversationId ||
      state.conversations[pending.operation.owner.conversationId] !==
        pending.candidateConversation ||
      state.projectContextDestructiveEpoch !==
        pending.operation.owner.expectedDestructiveEpoch
    ) {
      return false;
    }
    const owner = pending.operation.owner;
    if (
      owner.pickerGeneration !== null &&
      this.dependencies.isPickerGenerationCurrent !== undefined &&
      !this.dependencies.isPickerGenerationCurrent(owner.pickerGeneration)
    ) {
      return false;
    }
    return !(
      owner.surfaceNonce !== null &&
      this.dependencies.isSurfaceNonceCurrent !== undefined &&
      !this.dependencies.isSurfaceNonceCurrent(owner.surfaceNonce)
    );
  }

  private stale(operationId: string): WorkspaceBindingOutcome {
    return { status: 'stale', operationId, code: 'E_WORKSPACE_CONFLICT' };
  }

  private publish(next: WorkspaceBindingControllerState): void {
    this.state = next;
    this.listeners.forEach(listener => {
      try {
        listener(next);
      } catch {
        // Observers cannot strand a native or Store operation.
      }
    });
  }
}

export function createWorkspaceBindingController(
  dependencies: WorkspaceBindingControllerDependencies,
): WorkspaceBindingController {
  return new WorkspaceBindingController(dependencies);
}
