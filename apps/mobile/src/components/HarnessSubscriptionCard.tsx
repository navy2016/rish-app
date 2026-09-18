import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, AppState, Linking, Platform, Pressable, StyleSheet, Text, View } from 'react-native';
import BadgeCheck from 'lucide-react-native/icons/badge-check';
import CircleAlert from 'lucide-react-native/icons/circle-alert';
import CircleCheck from 'lucide-react-native/icons/circle-check';
import CircleDot from 'lucide-react-native/icons/circle-dot';
import LogIn from 'lucide-react-native/icons/log-in';
import LogOut from 'lucide-react-native/icons/log-out';
import RotateCcw from 'lucide-react-native/icons/rotate-ccw';
import XCircle from 'lucide-react-native/icons/circle-x';
import { useAppPresentation } from '../presentation/AppPresentation';
import { AppIcon } from './AppIcon';
import type { ThemePalette } from '../theme';
import type { HarnessSubscriptionId, HarnessAuthStatus } from '../harnessAuth/types';
import { harnessForModel, isHarnessModelId, type HarnessModelId } from '../harness/types';
import { validVerificationUrl } from '../harnessAuth/url';
import * as Auth from '../harnessAuth/native';
import type { CodexChatSource } from '../harnessAuth/native';

const readChatSource = (id: HarnessSubscriptionId) =>
  id === 'claude-code' ? Auth.claudeChatSource() : Auth.codexChatSource();

export function harnessSubscriptionIdForModel(model: string): HarnessSubscriptionId | null {
  if (!isHarnessModelId(model)) return null;
  const harness = harnessForModel(model as HarnessModelId);
  if (harness === 'claude-code') return 'claude-code';
  if (harness === 'codex') return 'codex';
  return null;
}


export function HarnessSubscriptionCard({ id, visible, disabled: externalDisabled, onCredentialChanged }: { id: HarnessSubscriptionId; visible: boolean; disabled?: boolean; onCredentialChanged?: (source: CodexChatSource | null) => void }) {
  const { colors, preferences, t } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const [rawState, setRawState] = useState<HarnessAuthStatus | null>(null);
  const rawStateRef = useRef<HarnessAuthStatus | null>(null);
  rawStateRef.current = rawState;
  const [actionBusy, setActionBusy] = useState(false);
  const [browserError, setBrowserError] = useState(false);
  // A status that cannot be read leaves no state to explain itself, and the
  // button is disabled while it is null. Without this the card sits on
  // "checking" for as long as the app is open and the control says nothing.
  const [statusUnreadable, setStatusUnreadable] = useState(false);
  const [localProgress, setLocalProgress] = useState<'starting' | 'verifying' | null>(null);
  const [chatSource, setChatSource] = useState<CodexChatSource | null>(null);
  const [chatSourceError, setChatSourceError] = useState<string | null>(null);
  const actionBusyRef = useRef(false);
  const epoch = useRef(0);
  const scopeRef = useRef<{ id: HarnessSubscriptionId; epoch: number } | null>(null);
  const poll = useRef<ReturnType<typeof setTimeout> | null>(null);
  const startPollingRef = useRef<((scope: object & { id: HarnessSubscriptionId; epoch: number }) => void) | null>(null);
  const refreshBusy = useRef(new WeakSet<object>());
  const sourceBusy = useRef(new WeakSet<object>());
  const authTransition = useRef<'signed_in' | 'signed_out' | 'authorizing' | 'error' | 'unavailable' | null>(null);
  const locale = preferences.locale === 'zh-CN' ? 'zh-CN' : 'en-US';
  const title = id === 'codex' ? t('settings.auth.codexTitle') : t('settings.auth.claudeTitle');
  const currentState = rawState?.harness_id === id ? rawState : null;
  const state = currentState;
  const disabled = externalDisabled || currentState === null || currentState.runtime.available === false || actionBusy;

  const apply = useCallback((next: HarnessAuthStatus, scope: object & { id: HarnessSubscriptionId; epoch: number }) => {
    if (scopeRef.current === scope && next.harness_id === scope.id && scope.epoch === epoch.current) setRawState(next);
  }, []);
  const refresh = useCallback(async (scope: object & { id: HarnessSubscriptionId; epoch: number }) => { if (scopeRef.current !== scope || refreshBusy.current.has(scope)) return; refreshBusy.current.add(scope); try { apply(await Auth.harnessAuthStatus(scope.id), scope); if (scopeRef.current === scope) setStatusUnreadable(false); } catch { if (scopeRef.current === scope) setStatusUnreadable(true); } finally { refreshBusy.current.delete(scope); } }, [apply]);
  const stopPolling = useCallback(() => { if (poll.current) clearTimeout(poll.current); poll.current = null; }, []);
  const startPolling = useCallback((scope: object & { id: HarnessSubscriptionId; epoch: number }) => { stopPolling(); const tick = () => { if (scopeRef.current !== scope || AppState.currentState !== 'active') return; refresh(scope).finally(() => { if (scopeRef.current === scope) poll.current = setTimeout(tick, 2500); }); }; poll.current = setTimeout(tick, 2500); }, [refresh, stopPolling]);
  startPollingRef.current = startPolling;

  useEffect(() => {
    setRawState(null); setLocalProgress(null); setBrowserError(false); setStatusUnreadable(false); setChatSource(null); setChatSourceError(null); authTransition.current = null; const scope = { id, epoch: ++epoch.current }; scopeRef.current = scope;
    if (!visible) { stopPolling(); return; }
    refresh(scope).catch(() => undefined);
    const sub = AppState.addEventListener('change', next => { if (next === 'active') { refresh(scope).catch(() => undefined); if (rawStateRef.current?.status === 'authorizing') startPollingRef.current?.(scope); } else stopPolling(); });
    return () => { stopPolling(); sub?.remove(); if (scopeRef.current === scope) scopeRef.current = null; };
  }, [id, refresh, stopPolling, visible]);

  useEffect(() => {
    if (!currentState) return;
    const status = currentState.status;
    if (authTransition.current === null) { authTransition.current = status; return; }
    if (authTransition.current === status) return;
    authTransition.current = status;
    if (status === 'signed_out') { setChatSource(null); setChatSourceError(null); onCredentialChanged?.(null); }
    if (status === 'signed_in') {
      const scope = scopeRef.current;
      readChatSource(currentState.harness_id).then(source => {
        if (scopeRef.current !== scope) return;
        setChatSource(source); setChatSourceError(source.error_code); onCredentialChanged?.(source);
      }).catch(() => { if (scopeRef.current === scope) setChatSourceError('E_CHAT_SOURCE_STATUS'); });
    }
  }, [currentState, onCredentialChanged]);

  useEffect(() => {
    const scope = scopeRef.current;
    if (!scope || currentState?.status !== 'signed_in' || sourceBusy.current.has(scope)) return;
    sourceBusy.current.add(scope);
    readChatSource(id).then(source => { if (scopeRef.current === scope) { setChatSource(source); setChatSourceError(source.error_code); } }).catch(() => { if (scopeRef.current === scope) setChatSourceError('E_CHAT_SOURCE_STATUS'); }).finally(() => sourceBusy.current.delete(scope));
  }, [id, currentState?.status]);

  useEffect(() => { const scope = scopeRef.current; if (scope && rawState?.harness_id === id && rawState.status === 'authorizing' && visible && AppState.currentState === 'active') startPolling(scope); else stopPolling(); return stopPolling; }, [id, rawState?.harness_id, rawState?.status, startPolling, stopPolling, visible]);

  useEffect(() => {
    if (currentState?.status === 'signed_in' || currentState?.status === 'error' || currentState?.status === 'signed_out' || currentState?.status === 'unavailable') {
      setLocalProgress(null);
    }
  }, [currentState?.status]);

  // Every control this card owns is gated on actionBusy, and nothing resets it:
  // the card stays mounted for the session and the reset effect leaves it
  // alone. A rejected await used to strand it, killing the whole card in
  // silence. The flag is released here no matter how the work ends.
  const runAction = async (work: () => Promise<void>) => {
    actionBusyRef.current = true; setActionBusy(true);
    try { await work(); } catch { setStatusUnreadable(true); }
    finally { actionBusyRef.current = false; setActionBusy(false); setLocalProgress(null); }
  };
  const begin = async () => {
    if (actionBusyRef.current || disabled) return;
    const scope = scopeRef.current; if (!scope) return;
    setBrowserError(false); setLocalProgress('starting');
    await runAction(async () => { apply(await Auth.startHarnessLogin(id), scope); });
  };
  const openAuthorization = () => {
    const login = state?.login;
    if (!login || !validVerificationUrl(id, login.verification_url)) return;
    setBrowserError(false);
    (id === 'codex' || Platform.OS === 'ios' ? Auth.openHarnessAuthorization(id, login.session_id) : Linking.openURL(login.verification_url))
      .then(() => { setBrowserError(false); })
      .catch(() => { setLocalProgress(null); setBrowserError(true); });
  };
  const cancel = async () => { const login = state?.login; const scope = scopeRef.current; if (!login || !scope || actionBusyRef.current) return; setBrowserError(false); await runAction(async () => { apply(await Auth.cancelHarnessLogin(id, login.session_id), scope); }); };
  const logout = async () => { const scope = scopeRef.current; if (!scope || actionBusyRef.current) return; setBrowserError(false); await runAction(async () => { apply(await Auth.logoutHarness(id), scope); }); };
  const install = async () => {
    const scope = scopeRef.current;
    if (!scope || actionBusyRef.current) return;
    // The status poll already reports download progress; this only starts it.
    await runAction(async () => { apply(await Auth.installHarnessCli(id), scope); });
  };
  const submitCode = async () => { const login = state?.login; const scope = scopeRef.current; if (!login?.can_submit_code || !scope || actionBusyRef.current) return; setBrowserError(false); await runAction(async () => { apply(await Auth.presentHarnessLoginCode(id, login.session_id, locale), scope); }); };
  const selectAccount = async () => { if (actionBusyRef.current || currentState?.status !== 'signed_in') return; setChatSourceError(null); await runAction(async () => { const source = await (id === 'claude-code' ? Auth.selectClaudeChatSource('subscription') : Auth.selectCodexChatSource('subscription')); setChatSource(source); setChatSourceError(source.error_code); if (!source.error_code) onCredentialChanged?.(source); }); };
  const expired = currentState?.login?.expires_at !== undefined && currentState.login.expires_at * 1000 <= Date.now();
  const progressPhase = currentState?.status === 'authorizing' ? currentState.login?.phase ?? (currentState.login?.user_code ? 'waiting_for_browser' : 'starting') : null;
  const startingText = t(id === 'claude-code' ? 'settings.auth.progressStartingClaude' : 'settings.auth.progressStarting');
  const progressText = progressPhase === 'starting' ? startingText : progressPhase === 'waiting_for_browser' ? t('settings.auth.progressWaiting') : progressPhase === 'verifying' ? t('settings.auth.progressVerifying') : null;
  const checkingText = t(id === 'claude-code' ? 'settings.auth.checkingClaude' : 'settings.auth.checking');
  const statusText = localProgress === 'starting' ? startingText : currentState === null ? checkingText : currentState.status === 'signed_in' ? t('settings.auth.signedIn') : expired ? t('settings.auth.expired') : currentState.status === 'authorizing' ? progressText ?? t('settings.auth.authorizing') : currentState.status === 'error' ? t('settings.auth.error') : currentState.status === 'unavailable' ? t('settings.auth.unavailable') : t('settings.auth.signedOut');
  const unavailableReason = currentState?.runtime.reason === 'runtime_check_failed' ? t('settings.auth.runtimeCheckFailed') : currentState?.runtime.reason === 'cli_incompatible_sigsys' ? t('settings.auth.cliIncompatible') : currentState?.runtime.reason === 'waiting_for_cleanup' ? t('settings.auth.waitingCleanup') : t('settings.auth.runtimeMissing');

  return <View testID={`harness-subscription-card-${id}`} style={styles.card}>
    <View style={styles.settingHeadingRow}><View style={styles.settingIcon}><AppIcon color={colors.textDim} icon={BadgeCheck} size={17} /></View><View style={styles.flex}><Text style={styles.settingTitle}>{title}</Text><Text style={styles.settingDescription}>{t('settings.auth.subtitle')}</Text></View></View>
    <Text style={styles.credentialBody}>{t('settings.auth.independence')}</Text>
    <View style={styles.authStatusRow}>{(localProgress !== null || progressPhase !== null) && currentState?.status !== 'signed_in' ? <ActivityIndicator testID="harness-auth-progress" animating color={colors.accent} size="small" /> : <AppIcon color={currentState?.status === 'signed_in' ? colors.accent : currentState?.status === 'error' || currentState?.status === 'unavailable' ? colors.danger : colors.textDim} icon={currentState?.status === 'signed_in' ? CircleCheck : currentState?.status === 'error' || currentState?.status === 'unavailable' ? CircleAlert : CircleDot} size={16} />}<Text style={styles.settingDescription}>{statusText}{currentState?.runtime.version ? ` · ${currentState.runtime.version}` : ''}</Text></View>
    {currentState?.status === 'signed_in' && currentState.account && <Text style={styles.settingDescription}>{currentState.account.label}{currentState.account.plan ? ` · ${currentState.account.plan}` : ''}</Text>}
    {currentState?.status === 'signed_in' && chatSource && <Text style={styles.settingDescription}>{t(chatSource.source === 'subscription' ? 'settings.auth.chatSourceSubscription' : 'settings.auth.chatSourceApiKey')}{chatSource.ready ? '' : ` · ${t('settings.auth.chatSourceNotReady')}`}</Text>}
    {chatSourceError && <Text style={styles.proxyError}>{t('settings.auth.chatSourceError')}</Text>}
    {(currentState?.status === 'unavailable' || currentState?.runtime.available === false || (currentState === null && statusUnreadable)) && <Text style={styles.proxyError}>{unavailableReason}</Text>}
    {currentState?.status === 'authorizing' && currentState.login?.user_code && <><Text selectable style={styles.authCode}>{currentState.login.user_code}</Text>{id === 'codex' && <Text style={styles.credentialBody}>{t('settings.auth.codePasteHint')}</Text>}</>}
    {browserError && <Text style={styles.proxyError}>{t('settings.auth.browserError')}</Text>}
    {currentState?.install && currentState.install.phase !== 'ready' && (
      currentState.install.phase === 'downloading'
        ? <View style={styles.authStatusRow}><ActivityIndicator animating color={colors.accent} size="small" /><Text style={styles.settingDescription}>{t('settings.auth.installing')}{typeof currentState.install.fraction === 'number' ? ` · ${Math.round(currentState.install.fraction * 100)}%` : ''}</Text></View>
        : <Pressable accessibilityLabel={t('settings.auth.installCli')} accessibilityRole="button" disabled={actionBusy} onPress={install} style={[styles.primaryButton, actionBusy && styles.disabled]}><Text style={styles.primaryText}>{t('settings.auth.installCli')}</Text></Pressable>
    )}
    {currentState?.install?.phase === 'failed' && <Text style={styles.proxyError}>{t('settings.auth.installFailed')}</Text>}
    <View style={styles.buttonRow}>
      {state?.status === 'signed_in' ? <><Pressable accessibilityLabel={t('settings.auth.useAccount')} accessibilityRole="button" disabled={disabled || chatSource?.source === 'subscription'} onPress={selectAccount} style={[styles.secondaryButton, (disabled || chatSource?.source === 'subscription') && styles.disabled]}><Text style={styles.settingDescription}>{t('settings.auth.useAccount')}</Text></Pressable><Pressable accessibilityLabel={t('settings.auth.logout')} accessibilityRole="button" disabled={disabled} onPress={logout} style={styles.secondaryButton}><AppIcon color={colors.danger} icon={LogOut} size={15} /><Text style={styles.dangerText}>{t('settings.auth.logout')}</Text></Pressable></> : state?.status === 'authorizing' ? <><Pressable accessibilityLabel={t('settings.auth.cancel')} accessibilityRole="button" onPress={cancel} style={styles.secondaryButton}><AppIcon color={colors.textDim} icon={XCircle} size={15} /><Text style={styles.settingDescription}>{t('settings.auth.cancel')}</Text></Pressable>{validVerificationUrl(id, state.login?.verification_url) && <Pressable accessibilityLabel={t('settings.auth.openAuth')} accessibilityRole="button" disabled={id === 'codex' && !state.login?.user_code} onPress={openAuthorization} style={[styles.secondaryButton, id === 'codex' && !state.login?.user_code && styles.disabled]}><Text style={styles.settingDescription}>{t('settings.auth.openAuth')}</Text></Pressable>}{state.login?.can_submit_code && <Pressable accessibilityLabel={t('settings.auth.enterCode')} accessibilityRole="button" onPress={submitCode} style={styles.secondaryButton}><Text style={styles.settingDescription}>{t('settings.auth.enterCode')}</Text></Pressable>}</> : <Pressable accessibilityLabel={title} accessibilityRole="button" disabled={disabled || state?.status === 'unavailable'} onPress={begin} style={[styles.primaryButton, (disabled || state?.status === 'unavailable') && styles.disabled]}><AppIcon color={colors.background} icon={LogIn} size={15} /><Text style={styles.primaryText}>{t('settings.auth.signIn')}</Text></Pressable>}
      <Pressable accessibilityLabel={t('settings.auth.refresh')} accessibilityRole="button" onPress={() => { const scope = scopeRef.current; if (scope) refresh(scope).catch(() => undefined); }} style={styles.secondaryButton}><AppIcon color={colors.textDim} icon={RotateCcw} size={15} /><Text style={styles.settingDescription}>{t('settings.auth.refresh')}</Text></Pressable>
    </View>
  </View>;
}

const createStyles = (colors: ThemePalette) => StyleSheet.create({
  card: { borderRadius: 20, backgroundColor: colors.surface, paddingHorizontal: 15, paddingVertical: 13 },
  settingHeadingRow: { flexDirection: 'row', alignItems: 'center' },
  settingIcon: { width: 30, height: 30, borderRadius: 10, backgroundColor: colors.surfaceRaised, alignItems: 'center', justifyContent: 'center', marginRight: 10 },
  flex: { flex: 1 }, settingTitle: { color: colors.text, fontSize: 15, fontWeight: '600' }, settingDescription: { color: colors.muted, fontSize: 12, lineHeight: 18 },
  credentialBody: { color: colors.muted, fontSize: 12, lineHeight: 18, marginTop: 8 }, authStatusRow: { flexDirection: 'row', alignItems: 'center', gap: 7, marginTop: 12 }, authCode: { color: colors.text, fontSize: 20, fontWeight: '700', letterSpacing: 2, marginTop: 10 }, proxyError: { color: colors.danger, fontSize: 12, lineHeight: 18, marginTop: 8 },
  buttonRow: { flexDirection: 'row', gap: 8, marginTop: 14, flexWrap: 'wrap' }, primaryButton: { minHeight: 42, borderRadius: 12, backgroundColor: colors.accent, paddingHorizontal: 14, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8 }, secondaryButton: { minHeight: 42, borderRadius: 12, backgroundColor: colors.surfaceRaised, paddingHorizontal: 12, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 7 }, primaryText: { color: colors.background, fontSize: 12, fontWeight: '700' }, dangerText: { color: colors.danger, fontSize: 12, fontWeight: '700' }, disabled: { opacity: 0.5 },
});
