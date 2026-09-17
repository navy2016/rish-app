import React from 'react';
import ReactTestRenderer, { act, type ReactTestInstance } from 'react-test-renderer';
import { StyleSheet } from 'react-native';

import { ChatComposer } from '../src/components/ChatComposer';
import { AppPresentationProvider } from '../src/presentation/AppPresentation';
import {
  createDefaultPreferences,
  createPreferencesStore,
} from '../src/preferences';

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, right: 0, bottom: 0, left: 0 }),
}));

function presentation(children: React.ReactNode) {
  const store = createPreferencesStore({
    initialPreferences: { ...createDefaultPreferences(), locale: 'en-US' },
  });
  return <AppPresentationProvider store={store}>{children}</AppPresentationProvider>;
}

function render(modelLabel: string, workspaceName: string | null) {
  let tree!: ReactTestRenderer.ReactTestRenderer;
  act(() => {
    tree = ReactTestRenderer.create(
      presentation(
        <ChatComposer
          attachmentBusy={false}
          attachments={[]}
          configured
          draft=""
          harnessName="DSH"
          locked={false}
          model="deepseek-v4-flash"
          modelLabel={modelLabel}
          onAddAttachment={() => {}}
          onCancel={() => {}}
          onChange={() => {}}
          onConfigure={() => {}}
          onOptionsPress={() => {}}
          onPreviewAttachment={() => {}}
          onRemoveAttachment={() => {}}
          onSend={() => {}}
          onWorkspacePress={() => {}}
          optionsVisible={false}
          ownershipKey="conversation-1"
          previewingAttachmentId={null}
          providerName="DeepSeek"
          sending={false}
          thinkingMode="high"
          workspaceName={workspaceName}
        />,
      ),
    );
  });
  return tree;
}

// Pressable takes its style as a function of the press state; resolve it the
// way the renderer would before flattening.
const flat = (node: ReactTestInstance) => {
  const style = node.props.style as unknown;
  const resolved = typeof style === 'function'
    ? (style as (state: { pressed: boolean }) => unknown)({ pressed: false })
    : style;
  return StyleSheet.flatten(resolved as never) as Record<string, unknown>;
};

// A caller can name a model anything, and a long name used to wrap the send
// button onto its own line below the chips. The row must never wrap; the
// chips give up width instead.
test('a long model name cannot push send off the action row', () => {
  const tree = render('deepseek-v4-flash-vision-experimental-preview', '很长的工作区名称在这里');
  const send = tree.root.findByProps({ testID: 'composer-send' });
  const options = tree.root.findByProps({ testID: 'composer-options-chip' });
  const workspace = tree.root.findByProps({ testID: 'composer-workspace-chip' });

  // Same parent means the same row once nothing wraps.
  expect(options.parent).toBe(send.parent);
  expect(workspace.parent).toBe(send.parent);
  expect(flat(send.parent!).flexWrap).toBe('nowrap');

  // React Native defaults flexShrink to 0, so the chips have to ask for it or
  // the row overflows instead of the labels truncating.
  expect(flat(options).flexShrink).toBe(1);
  expect(flat(workspace).flexShrink).toBe(1);
  expect(flat(send).flexShrink ?? 0).toBe(0);

  // The label still truncates rather than growing the chip without limit.
  const label = options.findByType('Text' as never);
  expect(label.props.numberOfLines).toBeGreaterThan(0);
});
