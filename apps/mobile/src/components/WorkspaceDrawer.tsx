import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import ArchiveRestore from 'lucide-react-native/icons/archive-restore';
import ChevronLeft from 'lucide-react-native/icons/chevron-left';
import FileInput from 'lucide-react-native/icons/file-input';
import FileOutput from 'lucide-react-native/icons/file-output';
import FilePlus from 'lucide-react-native/icons/file-plus';
import FileText from 'lucide-react-native/icons/file-text';
import Folder from 'lucide-react-native/icons/folder';
import FolderPlus from 'lucide-react-native/icons/folder-plus';
import Hash from 'lucide-react-native/icons/hash';
import ListChecks from 'lucide-react-native/icons/list-checks';
import Pencil from 'lucide-react-native/icons/pencil';
import Play from 'lucide-react-native/icons/play';
import RefreshCw from 'lucide-react-native/icons/refresh-cw';
import Save from 'lucide-react-native/icons/save';
import Trash2 from 'lucide-react-native/icons/trash-2';
import X from 'lucide-react-native/icons/x';
import {
  ActivityIndicator,
  Alert,
  Keyboard,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  LocalWorkspace,
  type WorkspaceEntry,
  type WorkspaceTrashReceipt,
} from '../native/LocalWorkspace';
import { LocalDocuments } from '../native/LocalDocuments';
import type { WorkspaceRootRefV1 } from '../native/WorkspaceRoot';
import { useAppPresentation } from '../presentation/AppPresentation';
import { fonts, type ThemePalette } from '../theme';
import { AppIcon } from './AppIcon';
import { SlidingPanel } from './SlidingPanel';
import { StructuredContent, type StructuredBlock } from './StructuredContent';

type CreateKind = 'file' | 'directory';

function joinPath(parent: string, name: string): string {
  return parent.length === 0 ? name : `${parent}/${name}`;
}

function parentPath(path: string): string {
  const parts = path.split('/').filter(Boolean);
  parts.pop();
  return parts.join('/');
}

function displayPath(path: string, rootLabel: string): string {
  return path.length === 0 ? rootLabel : `${rootLabel}/${path}`;
}

function isGitMetadata(path: string): boolean {
  return path.split('/').some(part => part.toLowerCase() === '.git');
}

function sameRoot(
  left: WorkspaceRootRefV1,
  right: WorkspaceRootRefV1,
): boolean {
  return (
    left.workspace_id === right.workspace_id &&
    left.binding_revision === right.binding_revision &&
    left.project_id === right.project_id
  );
}

function rootKey(root: WorkspaceRootRefV1 | undefined): string {
  return root === undefined
    ? 'none'
    : `${root.workspace_id}:${root.binding_revision}:${
        root.project_id ?? 'workspace'
      }`;
}

function copyRoot(root: WorkspaceRootRefV1): WorkspaceRootRefV1 {
  return {
    schema_version: 1,
    workspace_id: root.workspace_id,
    binding_revision: root.binding_revision,
    project_id: root.project_id,
  };
}

function newOperationId(): string {
  try {
    const crypto = (
      globalThis as typeof globalThis & {
        crypto?: { randomUUID?: () => string };
      }
    ).crypto;
    if (crypto !== undefined && typeof crypto.randomUUID === 'function') {
      return crypto.randomUUID().toLowerCase();
    }
  } catch {
    // Fall through to the local UUID-shaped fallback when the platform
    // crypto implementation is unavailable or brand-checks its receiver.
  }
  const hex = Array.from({ length: 32 }, () =>
    Math.floor(Math.random() * 16).toString(16),
  );
  hex[12] = '4';
  hex[16] = (8 + (Number.parseInt(hex[16] ?? '8', 16) % 4)).toString(16);
  return `${hex.slice(0, 8).join('')}-${hex.slice(8, 12).join('')}-${hex
    .slice(12, 16)
    .join('')}-${hex.slice(16, 20).join('')}-${hex.slice(20).join('')}`;
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function WorkspaceDrawer({
  confirmDestructive = true,
  workspaceRoot,
  workspaceLabel,
  // Kept as a display-only input while the Home coordinator migrates. It is
  // deliberately never used as an authority or passed to native code.
  projectScope,
  readOnly = false,
  visible,
  onClose,
  onDismiss,
  onRunProgram,
  runProgramBlocked = false,
}: {
  confirmDestructive?: boolean;
  workspaceRoot?: WorkspaceRootRefV1;
  workspaceLabel?: string;
  projectScope?: { rootPath: string; label: string };
  readOnly?: boolean;
  visible: boolean;
  onClose: () => void;
  onDismiss?: () => void;
  onRunProgram?: () => void;
  runProgramBlocked?: boolean;
}) {
  const insets = useSafeAreaInsets();
  const { colors, t } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const rootLabel = workspaceLabel ?? projectScope?.label ?? 'workspace';
  const rootReady = workspaceRoot !== undefined;
  const rootGenerationRef = useRef<{
    key: string;
    generation: number;
    root: WorkspaceRootRefV1 | undefined;
  }>({ key: '', generation: 0, root: undefined });
  const nextRootKey = rootKey(workspaceRoot);
  if (rootGenerationRef.current.key !== nextRootKey) {
    rootGenerationRef.current = {
      key: nextRootKey,
      generation: rootGenerationRef.current.generation + 1,
      root: workspaceRoot === undefined ? undefined : copyRoot(workspaceRoot),
    };
  }
  const captureRoot = useCallback(
    () => (workspaceRoot === undefined ? undefined : copyRoot(workspaceRoot)),
    [workspaceRoot],
  );
  const isCurrentRoot = useCallback(
    (captured: WorkspaceRootRefV1 | undefined, generation: number) => {
      const current = rootGenerationRef.current;
      return (
        generation === current.generation &&
        (captured === undefined
          ? current.root === undefined
          : current.root !== undefined && sameRoot(captured, current.root))
      );
    },
    [],
  );
  const [path, setPath] = useState('');
  const [entries, setEntries] = useState<WorkspaceEntry[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [createKind, setCreateKind] = useState<CreateKind | null>(null);
  const [newName, setNewName] = useState('');
  const [renameEntry, setRenameEntry] = useState<WorkspaceEntry | null>(null);
  const [renameName, setRenameName] = useState('');
  const filesScroll = useRef<React.ComponentRef<typeof ScrollView>>(null);
  const nameFormTop = useRef(0);
  const nameFormActive = useRef(false);
  nameFormActive.current = visible && (createKind !== null || renameEntry !== null);
  const revealNameForm = useCallback(() => {
    if (!nameFormActive.current) return;
    requestAnimationFrame(() => {
      if (nameFormActive.current) filesScroll.current?.scrollTo({ y: nameFormTop.current, animated: true });
    });
  }, []);
  useEffect(() => {
    if (!visible) return;
    const listener = Keyboard.addListener('keyboardDidShow', revealNameForm);
    return () => listener.remove();
  }, [visible, revealNameForm]);
  const [openFile, setOpenFile] = useState<WorkspaceEntry | null>(null);
  const openFileAuthorityRef = useRef<{
    root: WorkspaceRootRefV1;
    generation: number;
  } | null>(null);
  const [content, setContent] = useState('');
  const [savedContent, setSavedContent] = useState('');
  const editorGeneration = useRef({
    view: `${nextRootKey}:${visible}`,
    epoch: 0,
  });
  const view = `${nextRootKey}:${visible}`;
  if (editorGeneration.current.view !== view) {
    editorGeneration.current = {
      view,
      epoch: editorGeneration.current.epoch + 1,
    };
  }
  const editorEpoch = editorGeneration.current.epoch;
  const editorState = useRef({
    openFile,
    content,
    savedContent,
    visible,
    busy,
    readOnly,
    path,
  });
  editorState.current = {
    openFile,
    content,
    savedContent,
    visible,
    busy,
    readOnly,
    path,
  };
  const exportInFlight = useRef<object | null>(null);
  const changeContent = useCallback((value: string) => {
    editorState.current.content = value;
    setContent(value);
  }, []);

  useEffect(
    () => () => {
      editorGeneration.current.epoch += 1;
      editorState.current.visible = false;
    },
    [],
  );
  const [toolBlocks, setToolBlocks] = useState<StructuredBlock[]>([]);
  const [recentTrash, setRecentTrash] = useState<WorkspaceTrashReceipt[]>([]);

  const load = useCallback(
    async (nextPath: string) => {
      const root = captureRoot();
      const generation = rootGenerationRef.current.generation;
      if (!rootReady || root === undefined || !LocalWorkspace.isAvailable()) {
        setError(t('files.unavailable'));
        return;
      }
      setBusy(true);
      setError(null);
      setNotice(null);
      try {
        if (isGitMetadata(nextPath))
          throw new Error(t('files.gitMetadataProtected'));
        const [directory, trash] = await Promise.all([
          LocalWorkspace.listV2({
            schema_version: 1,
            root,
            path: nextPath,
            max_entries: 1000,
          }),
          LocalWorkspace.listTrashV2({
            schema_version: 1,
            root,
            max_entries: 8,
          }),
        ]);
        if (!isCurrentRoot(root, generation)) return;
        if (
          directory.path !== nextPath ||
          directory.root.workspace_id !== root.workspace_id ||
          directory.root.binding_revision !== root.binding_revision ||
          directory.root.project_id !== root.project_id
        )
          throw new Error(t('files.unavailable'));
        setPath(directory.path);
        setEntries(
          directory.entries.filter(entry => !isGitMetadata(entry.path)),
        );
        setRecentTrash(trash.entries);
      } catch (caught) {
        if (!isCurrentRoot(root, generation)) return;
        setError(caught instanceof Error ? caught.message : String(caught));
      } finally {
        if (isCurrentRoot(root, generation)) setBusy(false);
      }
    },
    [captureRoot, isCurrentRoot, rootReady, t],
  );

  useEffect(() => {
    if (!visible) return;
    editorGeneration.current.epoch += 1;
    setPath('');
    setEntries([]);
    setRecentTrash([]);
    setBusy(false);
    setOpenFile(null);
    openFileAuthorityRef.current = null;
    setContent('');
    setSavedContent('');
    setToolBlocks([]);
    setCreateKind(null);
    setNewName('');
    setRenameEntry(null);
    setRenameName('');
    load('').catch(() => undefined);
  }, [load, visible, workspaceRoot]);

  const open = useCallback(
    async (entry: WorkspaceEntry) => {
      const epoch = ++editorGeneration.current.epoch;
      if (entry.kind === 'directory') {
        await load(entry.path);
        return;
      }
      setBusy(true);
      setError(null);
      const root = captureRoot();
      const generation = rootGenerationRef.current.generation;
      try {
        if (root === undefined) throw new Error(t('files.unavailable'));
        const file = await LocalWorkspace.readV2({
          schema_version: 1,
          root,
          path: entry.path,
          max_bytes: 1024 * 1024,
        });
        if (
          !isCurrentRoot(root, generation) ||
          epoch !== editorGeneration.current.epoch ||
          !editorState.current.visible
        )
          return;
        if (!sameRoot(root, file.root)) throw new Error(t('files.unavailable'));
        setOpenFile(file.file);
        openFileAuthorityRef.current = { root, generation };
        setContent(file.content);
        setSavedContent(file.content);
        setToolBlocks([]);
      } catch (caught) {
        if (
          !isCurrentRoot(root, generation) ||
          epoch !== editorGeneration.current.epoch ||
          !editorState.current.visible
        )
          return;
        setError(caught instanceof Error ? caught.message : String(caught));
      } finally {
        if (
          isCurrentRoot(root, generation) &&
          epoch === editorGeneration.current.epoch
        )
          setBusy(false);
      }
    },
    [captureRoot, isCurrentRoot, load, t],
  );

  const beginCreate = useCallback(
    (kind: CreateKind) => {
      if (readOnly || !rootReady) return;
      setRenameEntry(null);
      setRenameName('');
      setCreateKind(kind);
      setNewName('');
    },
    [readOnly, rootReady],
  );

  const beginRename = useCallback(
    (entry: WorkspaceEntry) => {
      if (readOnly || !rootReady) return;
      setCreateKind(null);
      setNewName('');
      setRenameEntry(entry);
      setRenameName(entry.name);
    },
    [readOnly, rootReady],
  );

  useEffect(() => {
    if (!readOnly) return;
    setCreateKind(null);
    setNewName('');
    setRenameEntry(null);
    setRenameName('');
  }, [readOnly]);

  const create = useCallback(async () => {
    if (readOnly || !rootReady) return;
    const name = newName.trim();
    if (createKind === null || name.length === 0) return;
    const root = captureRoot();
    const generation = rootGenerationRef.current.generation;
    setBusy(true);
    setError(null);
    try {
      if (!isCurrentRoot(root, generation)) return;
      const target = joinPath(path, name);
      if (isGitMetadata(target)) {
        setError(t('files.gitMetadataProtected'));
        return;
      }
      if (root === undefined) throw new Error(t('files.unavailable'));
      let createdRoot: WorkspaceRootRefV1;
      if (createKind === 'directory') {
        const result = await LocalWorkspace.createDirectoryV2({
          schema_version: 1,
          root,
          path: target,
        });
        createdRoot = result.root;
      } else {
        const result = await LocalWorkspace.writeV2({
          schema_version: 1,
          root,
          path: target,
          content: '',
          expected_revision: null,
          create_only: true,
        });
        createdRoot = result.root;
      }
      if (!isCurrentRoot(root, generation)) return;
      if (!sameRoot(root, createdRoot)) throw new Error(t('files.unavailable'));
      setCreateKind(null);
      setNewName('');
      await load(path);
      if (!isCurrentRoot(root, generation)) return;
    } catch (caught) {
      if (!isCurrentRoot(root, generation)) return;
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      if (isCurrentRoot(root, generation)) setBusy(false);
    }
  }, [
    captureRoot,
    createKind,
    isCurrentRoot,
    load,
    newName,
    path,
    readOnly,
    rootReady,
    t,
  ]);

  const save = useCallback(async (): Promise<boolean> => {
    const current = editorState.current;
    if (
      openFile === null ||
      readOnly ||
      current.readOnly ||
      !current.visible ||
      current.busy ||
      exportInFlight.current !== null ||
      editorEpoch !== editorGeneration.current.epoch ||
      current.openFile?.path !== openFile.path ||
      current.openFile.revision !== openFile.revision
    )
      return false;
    const authority = openFileAuthorityRef.current;
    const root = authority?.root;
    const generation = authority?.generation ?? -1;
    const draft = current.content;
    const owns = () =>
      isCurrentRoot(root, generation) &&
      editorState.current.visible &&
      editorEpoch === editorGeneration.current.epoch;
    editorState.current.busy = true;
    setBusy(true);
    setError(null);
    try {
      if (!owns()) return false;
      if (root === undefined) throw new Error(t('files.unavailable'));
      const result = await LocalWorkspace.writeV2({
        schema_version: 1,
        root,
        path: openFile.path,
        content: draft,
        expected_revision: openFile.revision,
        create_only: false,
      });
      if (!owns()) return false;
      if (!sameRoot(root, result.root) || result.file.path !== openFile.path)
        throw new Error(t('files.unavailable'));
      editorState.current.openFile = result.file;
      editorState.current.savedContent = draft;
      setOpenFile(result.file);
      setSavedContent(draft);
      setEntries(previous =>
        previous.map(entry =>
          entry.path === result.file.path ? result.file : entry,
        ),
      );
      // A queued edit may arrive during the write: preserve it and do not
      // let a save-and-close action discard the newer draft.
      return editorState.current.content === draft;
    } catch (caught) {
      if (!owns()) return false;
      setError(caught instanceof Error ? caught.message : String(caught));
      return false;
    } finally {
      if (owns()) {
        editorState.current.busy = false;
        setBusy(false);
      }
    }
  }, [editorEpoch, isCurrentRoot, openFile, readOnly, t]);

  const closeEditor = useCallback(() => {
    editorGeneration.current.epoch += 1;
    editorState.current.openFile = null;
    editorState.current.content = '';
    editorState.current.savedContent = '';
    editorState.current.busy = false;
    setBusy(false);
    setOpenFile(null);
    openFileAuthorityRef.current = null;
    setContent('');
    setSavedContent('');
    setToolBlocks([]);
  }, []);

  const confirmEditorExit = useCallback(
    (afterClose: () => void) => {
      if (
        openFile === null ||
        content === savedContent ||
        !confirmDestructive
      ) {
        afterClose();
        return;
      }

      Alert.alert(`${t('files.saveChanges')}?`, openFile.path, [
        { text: t('common.cancel'), style: 'cancel' },
        { text: t('common.close'), style: 'destructive', onPress: afterClose },
        {
          text: t('common.save'),
          onPress: () => {
            save()
              .then(saved => {
                if (saved) afterClose();
              })
              .catch(() => undefined);
          },
        },
      ]);
    },
    [confirmDestructive, content, openFile, save, savedContent, t],
  );

  const requestEditorClose = useCallback(() => {
    confirmEditorExit(closeEditor);
  }, [closeEditor, confirmEditorExit]);

  const requestDrawerClose = useCallback(() => {
    confirmEditorExit(() => {
      closeEditor();
      onClose();
    });
  }, [closeEditor, confirmEditorExit, onClose]);

  const applyRename = useCallback(async () => {
    if (
      readOnly ||
      !rootReady ||
      renameEntry === null ||
      renameName.trim().length === 0
    )
      return;
    const root = captureRoot();
    const generation = rootGenerationRef.current.generation;
    setBusy(true);
    try {
      if (!isCurrentRoot(root, generation)) return;
      const destination = joinPath(
        parentPath(renameEntry.path),
        renameName.trim(),
      );
      if (isGitMetadata(destination)) {
        setError(t('files.gitMetadataProtected'));
        return;
      }
      if (root === undefined) throw new Error(t('files.unavailable'));
      const result = await LocalWorkspace.renameEntryV2({
        schema_version: 1,
        root,
        source_path: renameEntry.path,
        destination_path: destination,
      });
      if (!isCurrentRoot(root, generation)) return;
      if (!sameRoot(root, result.root)) throw new Error(t('files.unavailable'));
      setRenameEntry(null);
      setRenameName('');
      await load(path);
      if (!isCurrentRoot(root, generation)) return;
    } catch (caught) {
      if (!isCurrentRoot(root, generation)) return;
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      if (isCurrentRoot(root, generation)) setBusy(false);
    }
  }, [
    captureRoot,
    isCurrentRoot,
    load,
    path,
    readOnly,
    renameEntry,
    renameName,
    rootReady,
    t,
  ]);

  const moveToTrash = useCallback(
    (entry: WorkspaceEntry) => {
      if (readOnly || !rootReady) return;
      const root = captureRoot();
      const generation = rootGenerationRef.current.generation;
      const perform = async () => {
        if (!isCurrentRoot(root, generation)) return;
        setBusy(true);
        try {
          if (!isCurrentRoot(root, generation)) return;
          if (root === undefined) throw new Error(t('files.unavailable'));
          const result = await LocalWorkspace.trashEntryV2({
            schema_version: 1,
            root,
            path: entry.path,
          });
          if (!isCurrentRoot(root, generation)) return;
          if (!sameRoot(root, result.root))
            throw new Error(t('files.unavailable'));
          setRecentTrash(previous => [result.receipt, ...previous].slice(0, 8));
          if (openFile?.path === entry.path) setOpenFile(null);
          await load(path);
          if (!isCurrentRoot(root, generation)) return;
        } catch (caught) {
          if (!isCurrentRoot(root, generation)) return;
          setError(caught instanceof Error ? caught.message : String(caught));
        } finally {
          if (isCurrentRoot(root, generation)) setBusy(false);
        }
      };
      if (!confirmDestructive) {
        perform().catch(() => undefined);
        return;
      }
      Alert.alert(
        t('files.destructiveTitle', { name: entry.name }),
        t('files.destructiveBody', {
          kind: t(
            entry.kind === 'file' ? 'files.kind.file' : 'files.kind.folder',
          ),
        }),
        [
          { text: t('common.cancel'), style: 'cancel' },
          {
            text: t('files.moveToTrash'),
            style: 'destructive',
            onPress: () => perform().catch(() => undefined),
          },
        ],
      );
    },
    [
      confirmDestructive,
      load,
      openFile?.path,
      path,
      readOnly,
      rootReady,
      t,
      captureRoot,
      isCurrentRoot,
    ],
  );

  const restore = useCallback(
    async (receipt: WorkspaceTrashReceipt) => {
      if (readOnly || !rootReady) return;
      const root = captureRoot();
      const generation = rootGenerationRef.current.generation;
      setBusy(true);
      setError(null);
      try {
        if (!isCurrentRoot(root, generation)) return;
        if (root === undefined) throw new Error(t('files.unavailable'));
        const result = await LocalWorkspace.restoreFromTrashV2({
          schema_version: 1,
          root,
          trash_id: receipt.trash_id,
          destination_path: null,
        });
        if (!isCurrentRoot(root, generation)) return;
        if (!sameRoot(root, result.root))
          throw new Error(t('files.unavailable'));
        setRecentTrash(previous =>
          previous.filter(item => item.trash_id !== receipt.trash_id),
        );
        await load(path);
        if (!isCurrentRoot(root, generation)) return;
      } catch (caught) {
        if (!isCurrentRoot(root, generation)) return;
        setError(caught instanceof Error ? caught.message : String(caught));
      } finally {
        if (isCurrentRoot(root, generation)) setBusy(false);
      }
    },
    [captureRoot, isCurrentRoot, load, path, readOnly, rootReady, t],
  );

  const runTool = useCallback(
    async (tool: 'sha256sum' | 'wc') => {
      if (openFile === null) return;
      const callId = `tool-${Date.now()}`;
      const argumentsText = JSON.stringify({
        path: openFile.path,
        ...(tool === 'wc' ? { metric: 'words' } : {}),
      });
      const authority = openFileAuthorityRef.current;
      const root = authority?.root;
      const generation = authority?.generation ?? -1;
      setToolBlocks([
        {
          id: `${callId}-call`,
          type: 'tool-call',
          name: tool,
          arguments: argumentsText,
          status: 'running',
        },
      ]);
      try {
        if (!isCurrentRoot(root, generation)) return;
        if (root === undefined) throw new Error(t('files.unavailable'));
        const result = await LocalWorkspace.executePortableToolV2({
          schema_version: 1,
          root,
          tool,
          path: openFile.path,
          options: tool === 'wc' ? { metric: 'words' } : {},
        });
        if (!isCurrentRoot(root, generation)) return;
        if (!sameRoot(root, result.root))
          throw new Error(t('files.unavailable'));
        setToolBlocks([
          {
            id: `${callId}-call`,
            type: 'tool-call',
            name: tool,
            arguments: argumentsText,
            status: 'success',
          },
          {
            id: `${callId}-result`,
            type: 'tool-result',
            name: tool,
            output: result.stdout || result.stderr,
            isError: result.exit_code !== 0,
          },
        ]);
      } catch (caught) {
        if (!isCurrentRoot(root, generation)) return;
        setToolBlocks([
          {
            id: `${callId}-call`,
            type: 'tool-call',
            name: tool,
            arguments: argumentsText,
            status: 'error',
          },
          {
            id: `${callId}-result`,
            type: 'tool-result',
            name: tool,
            output: caught instanceof Error ? caught.message : String(caught),
            isError: true,
          },
        ]);
      }
    },
    [isCurrentRoot, openFile, t],
  );

  const importFromFiles = useCallback(async () => {
    if (readOnly || busy || !rootReady) return;
    if (!LocalDocuments.isAvailable()) {
      setError(t('files.documentsUnavailable'));
      return;
    }
    setBusy(true);
    setError(null);
    setNotice(null);
    const root = captureRoot();
    const generation = rootGenerationRef.current.generation;
    const operationId = newOperationId();
    try {
      if (!isCurrentRoot(root, generation)) return;
      if (root === undefined) throw new Error(t('files.unavailable'));
      const result = await LocalDocuments.presentImportPicker({
        schema_version: 1,
        root,
        operation_id: operationId,
        destination_path: path,
      });
      if (!isCurrentRoot(root, generation)) return;
      if (!sameRoot(root, result.root)) throw new Error(t('files.unavailable'));
      if (result.status === 'cancelled') return;
      await load(path);
      if (!isCurrentRoot(root, generation)) return;
      setNotice(t('files.importedCount', { count: result.entries.length }));
    } catch (caught) {
      if (!isCurrentRoot(root, generation)) return;
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      if (isCurrentRoot(root, generation)) setBusy(false);
    }
  }, [busy, captureRoot, isCurrentRoot, load, path, readOnly, rootReady, t]);

  const exportPathsToFiles = useCallback(
    async (sourcePaths: string[]) => {
      const current = editorState.current;
      if (
        sourcePaths.length === 0 ||
        !current.visible ||
        current.busy ||
        exportInFlight.current !== null ||
        editorEpoch !== editorGeneration.current.epoch ||
        current.path !== path
      )
        return;
      if (
        current.openFile !== null &&
        current.content !== current.savedContent
      ) {
        setNotice(t('files.saveBeforeExport'));
        return;
      }
      if (!LocalDocuments.isAvailable()) {
        setError(t('files.documentsUnavailable'));
        return;
      }
      const token = {};
      exportInFlight.current = token;
      editorState.current.busy = true;
      setBusy(true);
      setError(null);
      setNotice(null);
      const root = captureRoot();
      const generation = rootGenerationRef.current.generation;
      const owns = () =>
        isCurrentRoot(root, generation) &&
        editorState.current.visible &&
        editorEpoch === editorGeneration.current.epoch;
      try {
        if (!owns()) return;
        if (root === undefined) throw new Error(t('files.unavailable'));
        const result = await LocalDocuments.presentExportPicker({
          schema_version: 1,
          root,
          operation_id: newOperationId(),
          source_paths: sourcePaths.slice(),
        });
        if (!owns()) return;
        if (!sameRoot(root, result.root))
          throw new Error(t('files.unavailable'));
        if (result.status === 'cancelled') return;
        setNotice(t('files.exportedCount', { count: result.item_count }));
      } catch (caught) {
        if (!owns()) return;
        setError(caught instanceof Error ? caught.message : String(caught));
      } finally {
        if (exportInFlight.current === token) exportInFlight.current = null;
        if (owns()) {
          editorState.current.busy = false;
          setBusy(false);
        }
      }
    },
    [captureRoot, editorEpoch, isCurrentRoot, path, t],
  );

  const exportToFiles = useCallback(async () => {
    if (
      openFile === null ||
      editorState.current.openFile?.path !== openFile.path
    )
      return;
    await exportPathsToFiles([openFile.path]);
  }, [exportPathsToFiles, openFile]);

  return (
    <SlidingPanel
      accessibilityLabel={t('files.title')}
      onClose={requestDrawerClose}
      onDismiss={onDismiss}
      visible={visible}
    >
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
        enabled={visible}
        style={styles.keyboardRoot}
      >
      <View
        style={[
          styles.root,
          { paddingTop: insets.top + 10, paddingBottom: insets.bottom + 12 },
        ]}
      >
        <View style={styles.header}>
          <View style={styles.headerText}>
            <Text style={styles.eyebrow}>
              {t('files.onDevice').toLocaleUpperCase()}
            </Text>
            <Text
              accessibilityRole="header"
              numberOfLines={1}
              style={styles.title}
            >
              {openFile === null
                ? workspaceLabel ?? projectScope?.label ?? t('files.title')
                : openFile.name}
            </Text>
          </View>
          <Pressable
            accessibilityLabel={t('files.close')}
            accessibilityRole="button"
            onPress={requestDrawerClose}
            style={styles.close}
          >
            <AppIcon color={colors.text} icon={X} size={21} />
          </Pressable>
        </View>

        {onRunProgram !== undefined && rootReady && (
          <Pressable
            accessibilityLabel={t('files.runProgram')}
            accessibilityRole="button"
            disabled={busy || runProgramBlocked}
            onPress={() => confirmEditorExit(() => {
              closeEditor();
              onRunProgram();
            })}
            style={styles.pathBar}
          >
            <AppIcon color={colors.text} icon={Play} size={18} />
            <Text style={styles.pathText}>{t('files.runProgram')}</Text>
          </Pressable>
        )}

        {openFile === null ? (
          <ScrollView
            ref={filesScroll}
            style={styles.fileScroll}
            contentContainerStyle={styles.fileScrollContent}
            keyboardShouldPersistTaps="handled"
            keyboardDismissMode="interactive"
          >
            <View style={styles.pathBar}>
              {path.length > 0 && (
                <Pressable
                  accessibilityLabel={t('files.up')}
                  accessibilityRole="button"
                  disabled={busy}
                  onPress={() => load(parentPath(path)).catch(() => undefined)}
                  style={styles.pathAction}
                >
                  <AppIcon
                    color={colors.textDim}
                    icon={ChevronLeft}
                    size={20}
                  />
                </Pressable>
              )}
              <Text numberOfLines={1} style={styles.pathText}>
                {displayPath(path, rootLabel)}
              </Text>
              <Pressable
                accessibilityLabel={t('files.refresh')}
                accessibilityRole="button"
                disabled={busy}
                onPress={() => load(path).catch(() => undefined)}
                style={styles.pathAction}
              >
                <AppIcon color={colors.textDim} icon={RefreshCw} size={18} />
              </Pressable>
            </View>
            <View style={styles.createButtons}>
              <Pressable
                accessibilityLabel={t('files.newFile')}
                accessibilityRole="button"
                accessibilityState={{
                  disabled: readOnly || busy || !rootReady,
                }}
                disabled={readOnly || busy || !rootReady}
                onPress={() => beginCreate('file')}
                style={[
                  styles.createButton,
                  (readOnly || busy || !rootReady) && styles.disabled,
                ]}
              >
                <AppIcon color={colors.accent} icon={FilePlus} size={17} />
                <Text style={styles.createButtonText}>
                  {t('files.newFile')}
                </Text>
              </Pressable>
              <Pressable
                accessibilityLabel={t('files.newFolder')}
                accessibilityRole="button"
                accessibilityState={{
                  disabled: readOnly || busy || !rootReady,
                }}
                disabled={readOnly || busy || !rootReady}
                onPress={() => beginCreate('directory')}
                style={[
                  styles.createButton,
                  (readOnly || busy || !rootReady) && styles.disabled,
                ]}
              >
                <AppIcon color={colors.accent} icon={FolderPlus} size={17} />
                <Text style={styles.createButtonText}>
                  {t('files.newFolder')}
                </Text>
              </Pressable>
              <Pressable
                accessibilityLabel={t('files.importFromFiles')}
                accessibilityRole="button"
                accessibilityState={{
                  disabled:
                    readOnly ||
                    busy ||
                    !rootReady ||
                    !LocalDocuments.isAvailable(),
                }}
                disabled={
                  readOnly ||
                  busy ||
                  !rootReady ||
                  !LocalDocuments.isAvailable()
                }
                onPress={() => importFromFiles().catch(() => undefined)}
                style={[
                  styles.createButton,
                  (readOnly ||
                    busy ||
                    !rootReady ||
                    !LocalDocuments.isAvailable()) &&
                    styles.disabled,
                ]}
              >
                <AppIcon color={colors.accent} icon={FileInput} size={17} />
                <Text style={styles.createButtonText}>
                  {t('files.importFromFiles')}
                </Text>
              </Pressable>
            </View>
            {createKind !== null && (
              <View style={styles.inlineEditor} onLayout={event => {
                nameFormTop.current = event.nativeEvent.layout.y;
                if (Keyboard.isVisible()) revealNameForm();
              }}>
                <Text style={styles.inlineLabel}>
                  {createKind === 'file'
                    ? t('files.newFile')
                    : t('files.newFolder')}
                </Text>
                <TextInput
                  accessibilityLabel={t('files.namePlaceholder')}
                  autoFocus
                  autoCapitalize="none"
                  autoCorrect={false}
                  spellCheck={false}
                  returnKeyType="done"
                  onFocus={revealNameForm}
                  onSubmitEditing={() => create().catch(() => undefined)}
                  onChangeText={setNewName}
                  placeholder={t('files.namePlaceholder')}
                  placeholderTextColor={colors.faint}
                  style={styles.nameInput}
                  value={newName}
                />
                <View style={styles.inlineActions}>
                  <Pressable
                    accessibilityLabel={t('common.cancel')}
                    accessibilityRole="button"
                    onPress={() => {
                      setCreateKind(null);
                      setNewName('');
                    }}
                    style={styles.inlineSecondary}
                  >
                    <Text style={styles.inlineSecondaryText}>
                      {t('common.cancel')}
                    </Text>
                  </Pressable>
                  <Pressable
                    accessibilityLabel={t('files.create')}
                    accessibilityRole="button"
                    accessibilityState={{
                      disabled: busy || newName.trim().length === 0,
                    }}
                    disabled={busy || newName.trim().length === 0}
                    onPress={() => create().catch(() => undefined)}
                    style={[
                      styles.inlinePrimary,
                      (busy || newName.trim().length === 0) && styles.disabled,
                    ]}
                  >
                    <Text style={styles.inlinePrimaryText}>
                      {t('files.create')}
                    </Text>
                  </Pressable>
                </View>
              </View>
            )}
            {renameEntry !== null && (
              <View style={styles.inlineEditor} onLayout={event => {
                nameFormTop.current = event.nativeEvent.layout.y;
                if (Keyboard.isVisible()) revealNameForm();
              }}>
                <Text style={styles.inlineLabel}>
                  {t('files.rename', { name: renameEntry.name })}
                </Text>
                <TextInput
                  accessibilityLabel={t('common.rename')}
                  autoFocus
                  autoCapitalize="none"
                  autoCorrect={false}
                  spellCheck={false}
                  returnKeyType="done"
                  onFocus={revealNameForm}
                  onSubmitEditing={() => applyRename().catch(() => undefined)}
                  onChangeText={setRenameName}
                  placeholder={renameEntry.name}
                  placeholderTextColor={colors.faint}
                  style={styles.nameInput}
                  value={renameName}
                />
                <View style={styles.inlineActions}>
                  <Pressable
                    accessibilityLabel={t('common.cancel')}
                    accessibilityRole="button"
                    onPress={() => {
                      setRenameEntry(null);
                      setRenameName('');
                    }}
                    style={styles.inlineSecondary}
                  >
                    <Text style={styles.inlineSecondaryText}>
                      {t('common.cancel')}
                    </Text>
                  </Pressable>
                  <Pressable
                    accessibilityLabel={t('common.rename')}
                    accessibilityRole="button"
                    accessibilityState={{
                      disabled: busy || renameName.trim().length === 0,
                    }}
                    disabled={busy || renameName.trim().length === 0}
                    onPress={() => applyRename().catch(() => undefined)}
                    style={[
                      styles.inlinePrimary,
                      (busy || renameName.trim().length === 0) &&
                        styles.disabled,
                    ]}
                  >
                    <Text style={styles.inlinePrimaryText}>
                      {t('common.rename')}
                    </Text>
                  </Pressable>
                </View>
              </View>
            )}
            <View style={styles.list}>
              {busy && entries.length === 0 ? (
                <View style={styles.loading}>
                  <ActivityIndicator color={colors.accent} />
                  <Text style={styles.loadingText}>{t('files.loading')}</Text>
                </View>
              ) : entries.length === 0 ? (
                <View style={styles.empty}>
                  <Text style={styles.emptyTitle}>{t('files.emptyTitle')}</Text>
                  <Text style={styles.emptyBody}>{t('files.emptyBody')}</Text>
                </View>
              ) : (
                entries.map(entry => (
                  <View key={entry.path} style={styles.entryRow}>
                    <Pressable
                      accessibilityLabel={t('files.open', { name: entry.name })}
                      accessibilityRole="button"
                      disabled={busy}
                      onPress={() => open(entry).catch(() => undefined)}
                      style={styles.entryMain}
                    >
                      <View style={styles.entryIcon}>
                        <AppIcon
                          color={colors.accent}
                          icon={entry.kind === 'directory' ? Folder : FileText}
                          size={17}
                        />
                      </View>
                      <View style={styles.entryCopy}>
                        <Text numberOfLines={1} style={styles.entryName}>
                          {entry.name}
                        </Text>
                        <Text style={styles.entryMeta}>
                          {entry.kind === 'directory'
                            ? t('files.kind.folder')
                            : formatSize(entry.size)}
                        </Text>
                      </View>
                    </Pressable>
                    <Pressable
                      accessibilityLabel={t('files.exportEntry', {
                        name: entry.name,
                      })}
                      accessibilityRole="button"
                      accessibilityState={{
                        disabled:
                          busy || !rootReady || !LocalDocuments.isAvailable(),
                      }}
                      disabled={
                        busy || !rootReady || !LocalDocuments.isAvailable()
                      }
                      onPress={() =>
                        exportPathsToFiles([entry.path]).catch(() => undefined)
                      }
                      style={[
                        styles.smallAction,
                        (busy || !rootReady || !LocalDocuments.isAvailable()) &&
                          styles.disabled,
                      ]}
                    >
                      <AppIcon
                        color={colors.muted}
                        icon={FileOutput}
                        size={17}
                      />
                    </Pressable>
                    {!readOnly && (
                      <Pressable
                        accessibilityLabel={t('files.rename', {
                          name: entry.name,
                        })}
                        accessibilityRole="button"
                        disabled={busy || !rootReady}
                        onPress={() => beginRename(entry)}
                        style={styles.smallAction}
                      >
                        <AppIcon color={colors.muted} icon={Pencil} size={16} />
                      </Pressable>
                    )}
                    {!readOnly && (
                      <Pressable
                        accessibilityLabel={t('files.delete', {
                          name: entry.name,
                        })}
                        accessibilityRole="button"
                        disabled={busy || !rootReady}
                        onPress={() => moveToTrash(entry)}
                        style={styles.smallAction}
                      >
                        <AppIcon
                          color={colors.danger}
                          icon={Trash2}
                          size={17}
                        />
                      </Pressable>
                    )}
                  </View>
                ))
              )}
              {!readOnly && recentTrash.length > 0 && (
                <Text style={styles.sectionLabel}>
                  {t('files.recent').toLocaleUpperCase()}
                </Text>
              )}
              {!readOnly &&
                recentTrash.map(receipt => (
                  <View key={receipt.trash_id} style={styles.trashRow}>
                    <Text numberOfLines={1} style={styles.trashName}>
                      {receipt.original_path}
                    </Text>
                    <Pressable
                      accessibilityLabel={`${t('files.restore')} ${
                        receipt.original_path
                      }`}
                      accessibilityRole="button"
                      disabled={busy || !rootReady}
                      onPress={() => restore(receipt).catch(() => undefined)}
                      style={styles.restoreButton}
                    >
                      <AppIcon
                        color={colors.success}
                        icon={ArchiveRestore}
                        size={15}
                      />
                      <Text style={styles.restoreText}>
                        {t('files.restore')}
                      </Text>
                    </Pressable>
                  </View>
                ))}
            </View>
          </ScrollView>
        ) : (
          <ScrollView
            style={styles.fileScroll}
            contentContainerStyle={styles.editor}
            keyboardDismissMode="interactive"
            keyboardShouldPersistTaps="handled"
          >
            <Text style={styles.editorPath}>
              {displayPath(openFile.path, rootLabel)}
            </Text>
            <TextInput
              accessibilityLabel={t('files.content')}
              editable={!readOnly && !busy}
              autoCapitalize="none"
              autoCorrect={false}
              spellCheck={false}
              multiline
              onChangeText={changeContent}
              placeholder={t('files.content')}
              placeholderTextColor={colors.faint}
              style={styles.contentInput}
              textAlignVertical="top"
              value={content}
            />
            {content !== savedContent && (
              <Text accessibilityRole="alert" style={styles.editorPath}>
                {t('files.saveBeforeExport')}
              </Text>
            )}
            <View style={styles.editorActions}>
              <Pressable
                accessibilityLabel={t('common.close')}
                accessibilityRole="button"
                onPress={requestEditorClose}
                style={styles.inlineSecondary}
              >
                <AppIcon color={colors.textDim} icon={X} size={15} />
                <Text style={styles.inlineSecondaryText}>
                  {t('common.close')}
                </Text>
              </Pressable>
              <Pressable
                accessibilityLabel={t('files.exportToFiles')}
                accessibilityRole="button"
                accessibilityState={{
                  disabled:
                    busy ||
                    content !== savedContent ||
                    !rootReady ||
                    !LocalDocuments.isAvailable(),
                }}
                disabled={
                  busy ||
                  content !== savedContent ||
                  !rootReady ||
                  !LocalDocuments.isAvailable()
                }
                onPress={() => exportToFiles().catch(() => undefined)}
                style={[
                  styles.inlineSecondary,
                  (busy ||
                    content !== savedContent ||
                    !rootReady ||
                    !LocalDocuments.isAvailable()) &&
                    styles.disabled,
                ]}
              >
                <AppIcon color={colors.textDim} icon={FileOutput} size={15} />
                <Text style={styles.inlineSecondaryText}>
                  {t('files.exportToFiles')}
                </Text>
              </Pressable>
              {!readOnly && (
                <Pressable
                  accessibilityLabel={t('files.saveChanges')}
                  accessibilityRole="button"
                  accessibilityState={{
                    disabled: busy || content === savedContent,
                  }}
                  disabled={busy || content === savedContent}
                  onPress={() => save().catch(() => undefined)}
                  style={[
                    styles.inlinePrimary,
                    (busy || content === savedContent) && styles.disabled,
                  ]}
                >
                  <AppIcon color={colors.background} icon={Save} size={15} />
                  <Text style={styles.inlinePrimaryText}>
                    {t('files.saveChanges')}
                  </Text>
                </Pressable>
              )}
            </View>
            <Text style={styles.sectionLabel}>
              {t('files.toolOutput').toLocaleUpperCase()}
            </Text>
            <View style={styles.toolActions}>
              <Pressable
                accessibilityLabel={t('files.checksum')}
                accessibilityRole="button"
                disabled={busy}
                onPress={() => runTool('sha256sum').catch(() => undefined)}
                style={styles.toolButton}
              >
                <AppIcon color={colors.textDim} icon={Hash} size={15} />
                <Text style={styles.toolButtonText}>{t('files.checksum')}</Text>
              </Pressable>
              <Pressable
                accessibilityLabel={t('files.count')}
                accessibilityRole="button"
                disabled={busy}
                onPress={() => runTool('wc').catch(() => undefined)}
                style={styles.toolButton}
              >
                <AppIcon color={colors.textDim} icon={ListChecks} size={15} />
                <Text style={styles.toolButtonText}>{t('files.count')}</Text>
              </Pressable>
            </View>
            {toolBlocks.length > 0 && (
              <StructuredContent autoExpandTools blocks={toolBlocks} />
            )}
          </ScrollView>
        )}
        {error !== null && (
          <Text
            accessibilityLiveRegion="assertive"
            accessibilityRole="alert"
            style={styles.error}
          >
            {error}
          </Text>
        )}
        {error === null && notice !== null && (
          <Text accessibilityLiveRegion="polite" style={styles.notice}>
            {notice}
          </Text>
        )}
      </View>
      </KeyboardAvoidingView>
    </SlidingPanel>
  );
}

const createStyles = (colors: ThemePalette) =>
  StyleSheet.create({
    keyboardRoot: { flex: 1 },
    fileScroll: { flex: 1 },
    fileScrollContent: { paddingBottom: 16 },
    root: {
      flex: 1,
      backgroundColor: colors.background,
      paddingHorizontal: 18,
    },
    header: {
      height: 62,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
    },
    // A file name is unbounded, and space-between pushes the second child past
    // the edge once the first outgrows the row. The title column yields width
    // and truncates so close stays on screen and the row keeps its height.
    headerText: { flex: 1, minWidth: 0 },
    eyebrow: {
      color: colors.accent,
      fontSize: 8,
      fontWeight: '800',
      letterSpacing: 1.7,
    },
    title: {
      color: colors.text,
      fontFamily: fonts.display,
      fontSize: 27,
      marginTop: 4,
    },
    close: {
      width: 44,
      height: 44,
      borderRadius: 22,
      backgroundColor: colors.surface,
      alignItems: 'center',
      justifyContent: 'center',
      flexShrink: 0,
      marginLeft: 8,
    },
    pathBar: {
      height: 46,
      borderRadius: 13,
      backgroundColor: colors.surface,
      flexDirection: 'row',
      alignItems: 'center',
      paddingHorizontal: 2,
      marginTop: 10,
    },
    pathAction: {
      width: 44,
      height: 44,
      alignItems: 'center',
      justifyContent: 'center',
    },
    pathText: {
      flex: 1,
      color: colors.muted,
      fontFamily: fonts.mono,
      fontSize: 10,
      paddingHorizontal: 6,
    },
    createButtons: {
      flexDirection: 'row',
      flexWrap: 'wrap',
      gap: 8,
      marginTop: 10,
    },
    createButton: {
      minHeight: 44,
      borderRadius: 12,
      backgroundColor: colors.surfaceRaised,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 7,
      paddingHorizontal: 12,
    },
    createButtonText: {
      color: colors.textDim,
      fontSize: 11,
      fontWeight: '700',
    },
    inlineEditor: {
      borderRadius: 16,
      backgroundColor: colors.surfaceWarm,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.accentSoft,
      padding: 13,
      marginTop: 11,
    },
    inlineLabel: { color: colors.text, fontSize: 13, fontWeight: '700' },
    nameInput: {
      height: 44,
      borderRadius: 12,
      backgroundColor: colors.background,
      color: colors.text,
      fontSize: 14,
      paddingHorizontal: 12,
      marginTop: 9,
    },
    inlineActions: {
      flexDirection: 'row',
      justifyContent: 'flex-end',
      gap: 8,
      marginTop: 9,
    },
    inlineSecondary: {
      minHeight: 44,
      borderRadius: 12,
      backgroundColor: colors.surfaceRaised,
      paddingHorizontal: 14,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 7,
    },
    inlineSecondaryText: {
      color: colors.textDim,
      fontSize: 11,
      fontWeight: '700',
    },
    inlinePrimary: {
      minHeight: 44,
      borderRadius: 12,
      backgroundColor: colors.text,
      paddingHorizontal: 14,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 7,
    },
    inlinePrimaryText: {
      color: colors.background,
      fontSize: 11,
      fontWeight: '800',
    },
    list: { paddingVertical: 12, paddingBottom: 32 },
    entryRow: {
      minHeight: 62,
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: colors.lineSoft,
      flexDirection: 'row',
      alignItems: 'center',
    },
    entryMain: {
      flex: 1,
      minHeight: 62,
      flexDirection: 'row',
      alignItems: 'center',
    },
    entryIcon: {
      width: 34,
      height: 34,
      borderRadius: 10,
      backgroundColor: colors.surfaceRaised,
      alignItems: 'center',
      justifyContent: 'center',
      marginRight: 10,
    },
    entryCopy: { flex: 1 },
    entryName: { color: colors.text, fontSize: 14, fontWeight: '600' },
    entryMeta: {
      color: colors.muted,
      fontFamily: fonts.mono,
      fontSize: 9,
      marginTop: 4,
    },
    smallAction: {
      width: 44,
      height: 44,
      alignItems: 'center',
      justifyContent: 'center',
    },
    loading: { paddingVertical: 44, alignItems: 'center', gap: 10 },
    loadingText: { color: colors.muted, fontSize: 12 },
    empty: { paddingVertical: 44, alignItems: 'center' },
    emptyTitle: { color: colors.text, fontFamily: fonts.display, fontSize: 20 },
    emptyBody: {
      color: colors.muted,
      fontSize: 12,
      lineHeight: 18,
      marginTop: 6,
      textAlign: 'center',
    },
    sectionLabel: {
      color: colors.faint,
      fontSize: 8,
      fontWeight: '800',
      letterSpacing: 1.6,
      marginTop: 23,
      marginBottom: 8,
    },
    trashRow: {
      minHeight: 52,
      borderRadius: 13,
      backgroundColor: colors.surface,
      flexDirection: 'row',
      alignItems: 'center',
      paddingLeft: 12,
      paddingRight: 4,
      marginBottom: 6,
    },
    trashName: {
      flex: 1,
      color: colors.muted,
      fontFamily: fonts.mono,
      fontSize: 10,
    },
    restoreButton: {
      minHeight: 44,
      borderRadius: 10,
      backgroundColor: colors.surfaceRaised,
      paddingHorizontal: 12,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 7,
    },
    restoreText: { color: colors.success, fontSize: 10, fontWeight: '700' },
    editor: { paddingTop: 12, paddingBottom: 35 },
    editorPath: {
      color: colors.muted,
      fontFamily: fonts.mono,
      fontSize: 10,
      marginBottom: 10,
    },
    contentInput: {
      minHeight: 330,
      borderRadius: 17,
      backgroundColor: colors.surface,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
      color: colors.text,
      fontFamily: fonts.mono,
      fontSize: 13,
      lineHeight: 20,
      padding: 14,
    },
    editorActions: {
      flexDirection: 'row',
      justifyContent: 'flex-end',
      gap: 8,
      marginTop: 10,
    },
    toolActions: { flexDirection: 'row', gap: 8, marginBottom: 10 },
    toolButton: {
      minHeight: 44,
      borderRadius: 12,
      backgroundColor: colors.surfaceRaised,
      paddingHorizontal: 12,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 7,
    },
    toolButtonText: {
      color: colors.textDim,
      fontFamily: fonts.mono,
      fontSize: 10,
      fontWeight: '700',
    },
    error: {
      color: colors.danger,
      fontSize: 11,
      lineHeight: 16,
      paddingVertical: 8,
    },
    notice: {
      color: colors.success,
      fontSize: 11,
      lineHeight: 16,
      paddingVertical: 8,
    },
    disabled: { opacity: 0.35 },
  });
