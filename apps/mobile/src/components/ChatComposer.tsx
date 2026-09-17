import React, { useMemo, useRef, useState } from 'react';
import type { LucideIcon } from 'lucide-react-native';
import ArrowUp from 'lucide-react-native/icons/arrow-up';
import Camera from 'lucide-react-native/icons/camera';
import ChevronDown from 'lucide-react-native/icons/chevron-down';
import FileImage from 'lucide-react-native/icons/file-image';
import FileText from 'lucide-react-native/icons/file-text';
import FolderCode from 'lucide-react-native/icons/folder-code';
import Images from 'lucide-react-native/icons/images';
import Paperclip from 'lucide-react-native/icons/paperclip';
import Plus from 'lucide-react-native/icons/plus';
import Square from 'lucide-react-native/icons/square';
import X from 'lucide-react-native/icons/x';
import {
  ActivityIndicator,
  Image,
  Keyboard,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import { useAppPresentation } from '../presentation/AppPresentation';
import type { AttachmentDescriptor, ConversationThinkingMode } from '../state';
import { fonts, type ThemePalette } from '../theme';
import { localizedModelDetails, type SupportedModel } from './ModelPicker';
import { localizedThinkingDetails } from './ConversationOptionsPicker';
import { AppIcon } from './AppIcon';

export type AttachmentSource = 'camera' | 'photos' | 'files';

type Props = {
  configured: boolean;
  draft: string;
  attachments: readonly AttachmentDescriptor[];
  attachmentBusy: boolean;
  previewingAttachmentId: string | null;
  harnessName: string;
  providerName: string;
  configurationHint?: string;
  configurationAction?: string;
  configurationPending?: boolean;
  textOnly?: boolean;
  model: SupportedModel;
  modelLabel?: string;
  optionsVisible: boolean;
  thinkingMode: ConversationThinkingMode;
  workspaceName?: string | null;
  workspacePickerVisible?: boolean;
  ownershipKey: string;
  locked: boolean;
  sending: boolean;
  cancelling?: boolean;
  onAddAttachment: (source: AttachmentSource, ownershipKey: string) => void;
  onCancel: () => void;
  onChange: (value: string) => void;
  onConfigure: () => void;
  onLogin?: () => void;
  onOptionsPress: () => void;
  onPreviewAttachment: (id: string, ownershipKey: string) => void;
  onRemoveAttachment: (id: string, ownershipKey: string) => void;
  onSend: () => void;
  onWorkspacePress?: () => void;
};

const menuItems: ReadonlyArray<{
  source: AttachmentSource;
  icon: LucideIcon;
  labelKey:
    | 'messages.attachment.camera'
    | 'messages.attachment.photos'
    | 'messages.attachment.files';
}> = [
  { source: 'camera', icon: Camera, labelKey: 'messages.attachment.camera' },
  { source: 'photos', icon: Images, labelKey: 'messages.attachment.photos' },
  { source: 'files', icon: Paperclip, labelKey: 'messages.attachment.files' },
];

function readableSize(size: number): string {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${Math.max(1, Math.round(size / 1024))} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

export function ChatComposer(props: Props) {
  const { colors, t } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const [attachmentMenuVisible, setAttachmentMenuVisible] = useState(false);
  const pendingAttachmentSource = useRef<AttachmentSource | null>(null);
  const pendingAttachmentOwnership = useRef<string | null>(null);
  const locked = props.locked || props.sending;
  const canSend =
    props.configured &&
    !props.configurationPending &&
    (props.draft.trim().length > 0 || props.attachments.length > 0) &&
    !locked &&
    (!props.textOnly || props.attachments.length === 0) &&
    !props.attachmentBusy;
  const model = localizedModelDetails(props.model, t);
  const thinking = localizedThinkingDetails(props.thinkingMode, t);

  const chooseAttachment = (source: AttachmentSource) => {
    if (locked) return;
    pendingAttachmentSource.current = source;
    setAttachmentMenuVisible(false);
  };

  const finishAttachmentMenuDismiss = () => {
    const source = pendingAttachmentSource.current;
    const ownershipKey = pendingAttachmentOwnership.current;
    pendingAttachmentSource.current = null;
    pendingAttachmentOwnership.current = null;
    if (source !== null && ownershipKey !== null) {
      props.onAddAttachment(source, ownershipKey);
    }
  };

  return (
    <View style={styles.shell}>
      {props.attachments.length > 0 && (
        <ScrollView
          accessibilityLabel={t('messages.attachment.selected')}
          contentContainerStyle={styles.attachmentRow}
          horizontal
          keyboardShouldPersistTaps="handled"
          showsHorizontalScrollIndicator={false}
          style={styles.attachmentScroll}
        >
          {props.attachments.map(attachment => (
            <Pressable
              accessibilityLabel={t('messages.attachment.preview', {
                name: attachment.name,
              })}
              accessibilityRole="button"
              accessibilityState={{
                busy: props.previewingAttachmentId === attachment.id,
                disabled:
                  locked || props.previewingAttachmentId !== null,
              }}
              disabled={locked || props.previewingAttachmentId !== null}
              key={attachment.id}
              onPress={() =>
                props.onPreviewAttachment(attachment.id, props.ownershipKey)
              }
              style={({ pressed }) => [
                styles.attachmentCard,
                pressed && styles.attachmentCardPressed,
              ]}
            >
              {attachment.kind === 'image' &&
              attachment.thumbnail_data_url !== undefined ? (
                <Image
                  resizeMode="cover"
                  source={{ uri: attachment.thumbnail_data_url }}
                  style={styles.attachmentImage}
                />
              ) : (
                <View style={styles.attachmentFile}>
                  <AppIcon
                    color={colors.accent}
                    icon={attachment.kind === 'image' ? FileImage : FileText}
                    size={16}
                  />
                  <Text numberOfLines={1} style={styles.attachmentName}>
                    {attachment.name}
                  </Text>
                  <Text style={styles.attachmentSize}>
                    {readableSize(attachment.size)}
                  </Text>
                </View>
              )}
              {props.previewingAttachmentId === attachment.id && (
                <View style={styles.attachmentPreviewBusy}>
                  <ActivityIndicator color={colors.text} size="small" />
                </View>
              )}
              <Pressable
                accessibilityLabel={t('messages.attachment.remove', {
                  name: attachment.name,
                })}
                accessibilityRole="button"
                accessibilityState={{
                  disabled:
                    locked ||
                    props.attachmentBusy ||
                    props.previewingAttachmentId !== null,
                }}
                disabled={
                  locked ||
                  props.attachmentBusy ||
                  props.previewingAttachmentId !== null
                }
                hitSlop={6}
                onPress={event => {
                  event.stopPropagation();
                  props.onRemoveAttachment(
                    attachment.id,
                    props.ownershipKey,
                  );
                }}
                style={({ pressed }) => [
                  styles.removeAttachment,
                  pressed && styles.pressed,
                ]}
              >
                <AppIcon
                  color={colors.background}
                  icon={X}
                  size={12}
                  strokeWidth={2.2}
                />
              </Pressable>
            </Pressable>
          ))}
        </ScrollView>
      )}
      <TextInput
        accessibilityLabel={t('messages.inputLabel', {
          harness: props.harnessName,
        })}
        accessibilityState={{ disabled: !props.configured || locked }}
        editable={props.configured && !locked}
        multiline
        onChangeText={props.onChange}
        placeholder={
          props.configurationPending
            ? props.configurationHint ?? t('messages.preparingConnection', { harness: props.harnessName })
            : props.configured
            ? t('messages.inputPlaceholder', { harness: props.harnessName })
            : props.configurationHint ?? (props.onLogin ? t('messages.authPlaceholder') : t('messages.configurePlaceholder', { provider: props.providerName }))
        }
        placeholderTextColor={colors.faint}
        // Native multiline inputs can retain their previous intrinsic height
        // after a controlled clear, especially while becoming non-editable.
        // Constrain empty drafts immediately; restore intrinsic sizing for typing.
        style={[
          styles.input,
          props.draft.length === 0 && styles.emptyInput,
        ]}
        value={props.draft}
      />
      {props.textOnly && <Text style={styles.capabilityNote}>{t(props.attachments.length > 0 ? 'messages.subscriptionTextOnlyAttachments' : 'messages.subscriptionTextOnly')}</Text>}
      {!props.configured && !props.configurationPending && <View style={styles.authActions}>
        {props.onLogin && <Pressable accessibilityLabel={t('messages.signIn')} accessibilityRole="button" disabled={locked} onPress={props.onLogin} style={styles.configureChip}>
          <Text style={styles.configureText}>{t('messages.signIn')}</Text>
        </Pressable>}
        <Pressable accessibilityLabel={props.configurationAction ?? t('messages.configureKey', { provider: props.providerName })}
          accessibilityRole="button" accessibilityState={{ disabled: locked }} disabled={locked} onPress={props.onConfigure}
          style={({ pressed }) => [styles.configureChip, props.onLogin && styles.secondaryConfigureChip, pressed && styles.pressed]}>
          <Text style={[styles.configureText, props.onLogin && styles.secondaryConfigureText]}>{props.configurationAction ?? t('messages.configureKeyShort')}</Text>
        </Pressable>
      </View>}
      <View style={styles.actions}>
        <Pressable
          accessibilityLabel={t('messages.attachment.add')}
          accessibilityRole="button"
          accessibilityState={{
            busy: props.attachmentBusy,
            disabled:
              !props.configured || props.textOnly || locked || props.attachmentBusy,
          }}
          disabled={!props.configured || props.textOnly || locked || props.attachmentBusy}
          onPress={() => {
            Keyboard.dismiss();
            pendingAttachmentOwnership.current = props.ownershipKey;
            setAttachmentMenuVisible(true);
          }}
          style={({ pressed }) => [
            styles.addAttachment,
            pressed && styles.pressed,
          ]}
        >
          {props.attachmentBusy ? (
            <ActivityIndicator color={colors.text} size="small" />
          ) : (
            <AppIcon color={colors.text} icon={Plus} size={19} />
          )}
        </Pressable>
        {props.onWorkspacePress !== undefined && (
          <Pressable
            accessibilityLabel={t('messages.chooseWorkspace')}
            accessibilityRole="button"
            accessibilityState={{
              disabled: locked,
              expanded: props.workspacePickerVisible,
            }}
            accessibilityValue={{
              text: props.workspaceName ?? t('messages.chooseWorkspace'),
            }}
            disabled={locked}
            onPress={() => {
              Keyboard.dismiss();
              props.onWorkspacePress?.();
            }}
            style={({ pressed }) => [
              styles.workspaceChip,
              pressed && styles.pressed,
            ]}
            testID="composer-workspace-chip"
          >
            <AppIcon
              color={colors.accent}
              icon={FolderCode}
              size={13}
            />
            <Text
              numberOfLines={2}
              style={[
                styles.workspaceText,
                props.workspaceName == null && styles.workspaceTextUnbound,
              ]}
            >
              {props.workspaceName ?? t('messages.chooseWorkspace')}
            </Text>
            <AppIcon
              color={colors.muted}
              icon={ChevronDown}
              size={14}
              style={styles.chevronIcon}
            />
          </Pressable>
        )}
        {(
          <Pressable
            accessibilityLabel={t('messages.composerOptions', {
              model: props.modelLabel ?? model.name,
              effort: thinking.name,
            })}
            accessibilityRole="button"
            accessibilityState={{
              disabled: locked || props.attachmentBusy,
              expanded: props.optionsVisible,
            }}
            disabled={locked || props.attachmentBusy}
            onPress={() => {
              Keyboard.dismiss();
              props.onOptionsPress();
            }}
            style={({ pressed }) => [
              styles.modelChip,
              pressed && styles.pressed,
            ]}
            testID="composer-options-chip"
          >
            <View style={styles.modelDot} />
            <Text numberOfLines={2} style={styles.modelText}>
              {props.modelLabel ?? model.name} · {thinking.shortName}
            </Text>
            <AppIcon
              color={colors.muted}
              icon={ChevronDown}
              size={14}
              style={styles.chevronIcon}
            />
          </Pressable>
        )}
        <View style={styles.actionSpacer} />
        <Pressable
          accessibilityLabel={
            props.sending
              ? t('messages.stopResponse')
              : t('messages.sendMessage')
          }
          accessibilityRole="button"
          accessibilityState={{
            busy: props.sending || props.configurationPending === true,
            disabled: !props.sending && (locked || !canSend),
          }}
          disabled={!props.sending && (locked || !canSend)}
          onPress={props.sending ? props.onCancel : props.onSend}
          style={({ pressed }) => [
            styles.send,
            props.sending && styles.stop,
            !props.sending && (locked || !canSend) && styles.sendDisabled,
            pressed && styles.pressed,
          ]}
          testID="composer-send"
        >
          {props.sending ? (
            <AppIcon
              color={colors.background}
              fill={colors.background}
              icon={Square}
              size={11}
            />
          ) : props.configurationPending ? (
            <ActivityIndicator color={colors.accent} size="small" />
          ) : (
            <AppIcon color={colors.background} icon={ArrowUp} size={20} />
          )}
        </Pressable>
      </View>
      <Modal
        animationType="fade"
        onDismiss={finishAttachmentMenuDismiss}
        onRequestClose={() => setAttachmentMenuVisible(false)}
        presentationStyle="overFullScreen"
        statusBarTranslucent
        transparent
        testID="attachment-menu-modal"
        visible={attachmentMenuVisible}
      >
        <Pressable
          accessibilityLabel={t('messages.attachment.closeMenu')}
          onPress={() => setAttachmentMenuVisible(false)}
          style={styles.menuBackdrop}
        >
          <View
            accessibilityLabel={t('messages.attachment.menu')}
            accessibilityRole="menu"
            style={styles.attachmentMenu}
          >
            {menuItems.map(item => (
              <Pressable
                accessibilityLabel={t(item.labelKey)}
                accessibilityRole="menuitem"
                accessibilityState={{ disabled: locked }}
                disabled={locked}
                key={item.source}
                onPress={() => chooseAttachment(item.source)}
                style={({ pressed }) => [
                  styles.attachmentMenuItem,
                  pressed && styles.menuItemPressed,
                ]}
              >
                <View style={styles.menuIcon}>
                  <AppIcon color={colors.text} icon={item.icon} size={20} />
                </View>
                <Text style={styles.menuLabel}>{t(item.labelKey)}</Text>
              </Pressable>
            ))}
          </View>
        </Pressable>
      </Modal>
    </View>
  );
}

const createStyles = (colors: ThemePalette) =>
  StyleSheet.create({
    shell: {
      borderRadius: 23,
      paddingHorizontal: 12,
      paddingTop: 11,
      paddingBottom: 9,
      backgroundColor: colors.surface,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
    },
    input: {
      minHeight: 36,
      maxHeight: 116,
      padding: 0,
      color: colors.text,
      fontSize: 17,
      lineHeight: 23,
      fontFamily: fonts.body,
    },
    emptyInput: { height: 36 },
    attachmentScroll: { marginBottom: 9, maxHeight: 72 },
    attachmentRow: { gap: 8, paddingRight: 4 },
    attachmentCard: {
      width: 86,
      height: 64,
      borderRadius: 13,
      backgroundColor: colors.surfaceRaised,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
      overflow: 'visible',
    },
    attachmentImage: { width: '100%', height: '100%', borderRadius: 13 },
    attachmentCardPressed: { opacity: 0.76 },
    attachmentPreviewBusy: {
      position: 'absolute',
      top: 0,
      right: 0,
      bottom: 0,
      left: 0,
      borderRadius: 13,
      backgroundColor: colors.scrim,
      alignItems: 'center',
      justifyContent: 'center',
    },
    attachmentFile: {
      flex: 1,
      justifyContent: 'center',
      paddingHorizontal: 9,
      gap: 2,
    },
    attachmentName: { color: colors.text, fontSize: 10, fontWeight: '700' },
    attachmentSize: { color: colors.muted, fontSize: 8, marginTop: 2 },
    removeAttachment: {
      position: 'absolute',
      right: -5,
      top: -5,
      width: 20,
      height: 20,
      borderRadius: 10,
      alignItems: 'center',
      justifyContent: 'center',
      backgroundColor: colors.text,
      borderWidth: 2,
      borderColor: colors.surface,
    },
    authActions: { flexDirection: 'row', gap: 8, marginBottom: 8 },
    capabilityNote: { color: colors.muted, fontSize: 11, marginBottom: 6 },
    // Send must stay on this row. The chips carry caller-supplied names, so
    // their widths are not ours to bound; wrapping moved send below them
    // instead. The chips shrink and truncate now, and nothing wraps.
    actions: { flexDirection: 'row', flexWrap: 'nowrap', alignItems: 'center', marginTop: 5 },
    actionSpacer: { flex: 1 },
    addAttachment: {
      width: 44,
      height: 44,
      borderRadius: 22,
      backgroundColor: colors.surfaceRaised,
      alignItems: 'center',
      justifyContent: 'center',
      marginRight: 5,
    },
    workspaceChip: {
      minHeight: 44,
      paddingVertical: 7,
      borderRadius: 18,
      paddingHorizontal: 10,
      backgroundColor: colors.surfaceRaised,
      flexDirection: 'row',
      alignItems: 'center',
      gap: 5,
      maxWidth: 132,
      // React Native defaults flexShrink to 0, so without this the chip keeps
      // its full width and the row overflows rather than the label truncating.
      flexShrink: 1,
      marginRight: 6,
    },
    workspaceText: { color: colors.textDim, fontSize: 10, fontWeight: '600', flexShrink: 1 },
    // An unbound chat shows the call to action in the accent colour so the
    // missing binding is visible before the first message is sent.
    workspaceTextUnbound: { color: colors.accent },
    modelChip: {
      minHeight: 44,
      paddingVertical: 7,
      borderRadius: 18,
      paddingHorizontal: 8,
      backgroundColor: colors.surfaceRaised,
      flexDirection: 'row',
      alignItems: 'center',
      maxWidth: 170,
      flexShrink: 1,
    },
    modelDot: {
      width: 5,
      height: 5,
      borderRadius: 2.5,
      backgroundColor: colors.accent,
      marginRight: 5,
    },
    modelText: { color: colors.textDim, fontSize: 10, fontWeight: '600', flexShrink: 1 },
    chevronIcon: { marginLeft: 3 },
    configureChip: {
      minHeight: 44,
      borderRadius: 22,
      paddingHorizontal: 14,
      backgroundColor: colors.accent,
      justifyContent: 'center',
    },
    secondaryConfigureChip: {
      marginLeft: 8,
      backgroundColor: colors.surfaceRaised,
    },
    secondaryConfigureText: { color: colors.text },
    configureText: {
      color: colors.background,
      fontSize: 12,
      fontWeight: '800',
    },
    send: {
      width: 44,
      minHeight: 44,
      borderRadius: 22,
      alignItems: 'center',
      justifyContent: 'center',
      backgroundColor: colors.text,
    },
    sendDisabled: { backgroundColor: colors.surfaceRaised },
    stop: { backgroundColor: colors.text },
    menuBackdrop: {
      flex: 1,
      backgroundColor: colors.scrim,
      justifyContent: 'flex-end',
      paddingLeft: 18,
      paddingBottom: 108,
    },
    attachmentMenu: {
      width: 224,
      borderRadius: 24,
      backgroundColor: colors.surface,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
      paddingHorizontal: 10,
      paddingVertical: 9,
      shadowColor: '#000000',
      shadowOffset: { width: 0, height: 12 },
      shadowOpacity: 0.24,
      shadowRadius: 30,
      elevation: 16,
    },
    attachmentMenuItem: {
      minHeight: 54,
      borderRadius: 17,
      flexDirection: 'row',
      alignItems: 'center',
      paddingHorizontal: 8,
    },
    menuItemPressed: { backgroundColor: colors.surfaceRaised },
    menuIcon: {
      width: 44,
      minHeight: 44,
      borderRadius: 22,
      backgroundColor: colors.surfaceRaised,
      alignItems: 'center',
      justifyContent: 'center',
      marginRight: 12,
    },
    menuLabel: { color: colors.text, fontSize: 16, fontWeight: '600' },
    pressed: { opacity: 0.6, transform: [{ scale: 0.97 }] },
  });
