import React from 'react';
import TestRenderer, { act } from 'react-test-renderer';
import { AppState, Text as RNText } from 'react-native';
import { HarnessSubscriptionCard, harnessSubscriptionIdForModel } from '../src/components/HarnessSubscriptionCard';
import { validVerificationUrl } from '../src/harnessAuth/url';
import type { HarnessAuthStatus } from '../src/harnessAuth/types';
import * as Auth from '../src/harnessAuth/native';

jest.mock('../src/harnessAuth/native', () => ({ harnessAuthStatus: jest.fn(), startHarnessLogin: jest.fn(), cancelHarnessLogin: jest.fn(), logoutHarness: jest.fn(), presentHarnessLoginCode: jest.fn(), openHarnessAuthorization: jest.fn(), codexChatSource: jest.fn(), selectCodexChatSource: jest.fn(), claudeChatSource: jest.fn(), selectClaudeChatSource: jest.fn() }));
const auth = Auth as jest.Mocked<typeof Auth>;
const runtime = { kind: 'official-cli' as const, available: true, version: '1' };
const status = (harness_id: 'codex' | 'claude-code', value: 'signed_out' | 'authorizing' | 'signed_in', login?: HarnessAuthStatus['login']): HarnessAuthStatus => ({ schema_version: 1, harness_id, runtime, status: value, auth_method: value === 'signed_out' ? 'none' : 'subscription', ...(login ? { login } : {}) });
const deferred = <T,>() => { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; };

jest.mock('../src/presentation/AppPresentation', () => ({
  useAppPresentation: () => ({
    colors: { background: '#000', surface: '#111', surfaceRaised: '#222', text: '#fff', textDim: '#aaa', muted: '#888', danger: '#f44', accent: '#0f0' },
    preferences: { locale: 'en-US' },
    t: (key: string) => key,
  }),
}));

test('accepts only HTTPS URLs on the selected provider host', () => {
  expect(validVerificationUrl('codex', 'https://auth.openai.com/device')).toBe(true);
  expect(validVerificationUrl('claude-code', 'https://console.anthropic.com/oauth')).toBe(true);
  expect(validVerificationUrl('codex', 'https://evil.example/auth')).toBe(false);
  expect(validVerificationUrl('codex', 'http://auth.openai.com/device')).toBe(false);
  expect(validVerificationUrl('claude-code', 'https://auth.openai.com/device')).toBe(false);
  expect(validVerificationUrl('codex', 'https://auth.openai.com/device?code=secret')).toBe(false);
  expect(validVerificationUrl('codex', 'https://auth.openai.com/device?state=ok&code_challenge=x')).toBe(true);
  expect(validVerificationUrl('codex', 'https://user:pass@auth.openai.com/device')).toBe(false);
  expect(validVerificationUrl('codex', 'https://auth.openai.com:8443/device')).toBe(false);
  expect(validVerificationUrl('codex', 'https://auth.openai.com/device#secret')).toBe(false);
});

test('derives subscription identity from canonical model ids', () => {
  expect(harnessSubscriptionIdForModel('gpt-5.6')).toBe('codex');
  expect(harnessSubscriptionIdForModel('claude-sonnet-5')).toBe('claude-code');
  expect(harnessSubscriptionIdForModel('deepseek-v4-pro')).toBeNull();
});

test('fails closed when the native auth contract is unavailable', async () => {
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => {
    renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />);
  });
  const button = renderer.root.findByProps({ accessibilityLabel: 'settings.auth.codexTitle' });
  expect(button.props.disabled).toBe(true);
  await act(async () => renderer.unmount());
});

beforeEach(() => { jest.clearAllMocks(); auth.codexChatSource.mockResolvedValue({ schema_version: 1, source: 'api_key', ready: true, error_code: null }); auth.selectCodexChatSource.mockResolvedValue({ schema_version: 1, source: 'subscription', ready: true, error_code: null }); auth.claudeChatSource.mockResolvedValue({ schema_version: 1, source: 'api_key', ready: true, error_code: null }); auth.selectClaudeChatSource.mockResolvedValue({ schema_version: 1, source: 'subscription', ready: true, error_code: null }); });

test('poll receives a delayed authorization URL', async () => {
  jest.useFakeTimers();
  (AppState as any).currentState = 'active';
  const poll = deferred<HarnessAuthStatus>();
  auth.harnessAuthStatus.mockResolvedValueOnce(status('codex', 'signed_out')).mockReturnValueOnce(poll.promise);
  auth.startHarnessLogin.mockResolvedValue(status('codex', 'authorizing', { session_id: 's1' }));
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />); });
  await act(async () => renderer.root.findByProps({ accessibilityLabel: 'settings.auth.codexTitle' }).props.onPress());
  await act(async () => { jest.advanceTimersByTime(2500); await Promise.resolve(); });
  expect(auth.harnessAuthStatus).toHaveBeenCalledTimes(2);
  await act(async () => poll.resolve(status('codex', 'authorizing', { session_id: 's1', verification_url: 'https://auth.openai.com/device' })));
  expect(renderer.root.findAllByProps({ accessibilityLabel: 'settings.auth.openAuth' }).length).toBeGreaterThan(0);
  await act(async () => renderer.unmount()); jest.useRealTimers();
});

test('cancelled login cannot be resurrected by an older signed-in poll', async () => {
  jest.useFakeTimers();
  (AppState as any).currentState = 'active';
  const oldPoll = deferred<HarnessAuthStatus>();
  auth.harnessAuthStatus.mockResolvedValueOnce(status('codex', 'signed_out')).mockReturnValueOnce(oldPoll.promise);
  auth.startHarnessLogin.mockResolvedValue(status('codex', 'authorizing', { session_id: 's1' }));
  auth.cancelHarnessLogin.mockResolvedValue(status('codex', 'signed_out'));
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />); });
  await act(async () => renderer.root.findByProps({ accessibilityLabel: 'settings.auth.codexTitle' }).props.onPress());
  await act(async () => { jest.advanceTimersByTime(2500); await Promise.resolve(); });
  await act(async () => renderer.root.findByProps({ accessibilityLabel: 'settings.auth.cancel' }).props.onPress());
  await act(async () => oldPoll.resolve(status('codex', 'signed_in', { session_id: 'old' })));
  expect(renderer.root.findAllByProps({ children: 'settings.auth.signedIn' })).toHaveLength(0);
  await act(async () => renderer.unmount()); jest.useRealTimers();
});

test('background pauses polling and foreground resumes it', async () => {
  jest.useFakeTimers();
  let onStateChange!: (state: string) => void;
  const listener = jest.spyOn(AppState, 'addEventListener').mockImplementation((_event: any, handler: any) => { onStateChange = handler; return { remove: jest.fn() } as any; });
  auth.harnessAuthStatus.mockResolvedValue(status('codex', 'authorizing', { session_id: 's1' }));
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />); });
  const calls = auth.harnessAuthStatus.mock.calls.length;
  await act(async () => { onStateChange('background'); jest.advanceTimersByTime(5000); });
  expect(auth.harnessAuthStatus).toHaveBeenCalledTimes(calls);
  await act(async () => { onStateChange('active'); await Promise.resolve(); });
  expect(auth.harnessAuthStatus.mock.calls.length).toBeGreaterThan(calls);
  await act(async () => renderer.unmount()); listener.mockRestore(); jest.useRealTimers();
});

test('browser rejection is shown and a retry can succeed', async () => {
  auth.harnessAuthStatus.mockResolvedValue(status('codex', 'authorizing', { session_id: 's1', verification_url: 'https://auth.openai.com/device' }));
  const open = auth.openHarnessAuthorization.mockRejectedValueOnce(new Error('blocked')).mockResolvedValueOnce(undefined);
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />); });
  await act(async () => renderer.root.findByProps({ accessibilityLabel: 'settings.auth.openAuth' }).props.onPress());
  expect(renderer.root.findAllByProps({ children: 'settings.auth.browserError' }).length).toBeGreaterThan(0);
  await act(async () => renderer.root.findByProps({ accessibilityLabel: 'settings.auth.openAuth' }).props.onPress());
  expect(open).toHaveBeenCalledTimes(2);
  expect(renderer.root.findAllByProps({ children: 'settings.auth.browserError' })).toHaveLength(0);
  expect(open).toHaveBeenLastCalledWith('codex', 's1');
  await act(async () => renderer.unmount());
});

// Every control on this card is gated on one busy flag that nothing resets:
// the card stays mounted for the session. A rejected action used to strand it,
// leaving the whole card inert and silent for the rest of the run.
test('a rejected action does not leave the card permanently inert', async () => {
  auth.harnessAuthStatus.mockResolvedValue(status('codex', 'signed_in'));
  auth.codexChatSource.mockResolvedValue({ source: 'api_key', ready: true, error_code: null } as never);
  auth.logoutHarness.mockRejectedValueOnce(new Error('bridge lost'))
    .mockResolvedValueOnce(status('codex', 'signed_out'));
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />); });

  const logout = () => renderer.root.findByProps({ accessibilityLabel: 'settings.auth.logout' });
  await act(async () => logout().props.onPress());
  expect(auth.logoutHarness).toHaveBeenCalledTimes(1);

  // The card has to still answer. Before the fix the busy flag was stranded
  // and this second press did nothing at all.
  expect(logout().props.disabled).toBe(false);
  await act(async () => logout().props.onPress());
  expect(auth.logoutHarness).toHaveBeenCalledTimes(2);
  await act(async () => renderer.unmount());
});

test('native expiry uses Unix seconds rather than milliseconds', async () => {
  auth.harnessAuthStatus.mockResolvedValue(status('codex', 'authorizing', {session_id: 'time', expires_at: Math.floor(Date.now() / 1000) + 600}));
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />); });
  expect(renderer.root.findAllByProps({children: 'settings.auth.expired'})).toHaveLength(0);
  await act(async () => renderer.unmount());
});

test('old provider status cannot paint after provider switch', async () => {
  const old = deferred<any>();
  auth.harnessAuthStatus.mockImplementationOnce(() => old.promise).mockResolvedValue(status('claude-code', 'signed_out'));
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />); });
  await act(async () => { renderer.update(<HarnessSubscriptionCard id="claude-code" visible />); });
  await act(async () => old.resolve(status('codex', 'signed_in', { session_id: 'old' })));
  expect(renderer.root.findByProps({ testID: 'harness-subscription-card-claude-code' })).toBeDefined();
  expect(renderer.root.findAllByProps({ children: 'settings.auth.signedIn' })).toHaveLength(0);
  await act(async () => renderer.unmount());
});

test('double start is fenced to one native call', async () => {
  auth.harnessAuthStatus.mockResolvedValue(status('codex', 'signed_out'));
  const pending = deferred<any>(); auth.startHarnessLogin.mockReturnValue(pending.promise);
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />); });
  const button = renderer.root.findByProps({ accessibilityLabel: 'settings.auth.codexTitle' });
  button.props.onPress(); button.props.onPress();
  expect(auth.startHarnessLogin).toHaveBeenCalledTimes(1);
  pending.resolve(status('codex', 'authorizing', { session_id: 's' }));
  await act(async () => renderer.unmount());
});

test('shows a spinner and truthful starting phase while getting a device code', async () => {
  auth.harnessAuthStatus.mockResolvedValue(status('codex', 'signed_out'));
  const pending = deferred<HarnessAuthStatus>();
  auth.startHarnessLogin.mockReturnValue(pending.promise);
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />); });
  await act(async () => { void renderer.root.findByProps({ accessibilityLabel: 'settings.auth.codexTitle' }).props.onPress(); await Promise.resolve(); await Promise.resolve(); });
  expect(renderer.root.findByProps({ testID: 'harness-auth-progress' }).props.animating).toBe(true);
  expect(renderer.root.findAllByType(RNText).some(node => String(node.props.children).startsWith('settings.auth.progressStarting'))).toBe(true);
  await act(async () => { pending.resolve(status('codex', 'authorizing', { session_id: 's-start', phase: 'waiting_for_browser' })); await pending.promise; });
  expect(renderer.root.findAllByProps({ children: 'settings.auth.progressStarting' })).toHaveLength(0);
  await act(async () => renderer.unmount());
});

test('uses native waiting phase and confirms only after the authorization browser closes', async () => {
  auth.harnessAuthStatus.mockResolvedValue(status('codex', 'authorizing', { session_id: 's-verify', phase: 'waiting_for_browser', verification_url: 'https://auth.openai.com/device', user_code: 'ABCD' }));
  const browser = deferred<void>();
  auth.openHarnessAuthorization.mockReturnValue(browser.promise);
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="codex" visible />); await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); });
  expect(renderer.root.findAllByType(RNText).some(node => String(node.props.children).startsWith('settings.auth.progressWaiting'))).toBe(true);
  await act(async () => { renderer.root.findByProps({ accessibilityLabel: 'settings.auth.openAuth' }).props.onPress(); await Promise.resolve(); });
  expect(renderer.root.findAllByType(RNText).some(node => String(node.props.children).startsWith('settings.auth.progressVerifying'))).toBe(false);
  await act(async () => { browser.resolve(); await browser.promise; });
  expect(renderer.root.findAllByType(RNText).some(node => String(node.props.children).startsWith('settings.auth.progressWaiting'))).toBe(true);
  auth.harnessAuthStatus.mockResolvedValueOnce(status('codex', 'authorizing', { session_id: 's-verify', phase: 'verifying', verification_url: 'https://auth.openai.com/device', user_code: 'ABCD' }));
  await act(async () => { renderer.root.findByProps({ accessibilityLabel: 'settings.auth.refresh' }).props.onPress(); await Promise.resolve(); await Promise.resolve(); });
  expect(renderer.root.findAllByType(RNText).some(node => String(node.props.children).startsWith('settings.auth.progressVerifying'))).toBe(true);
  expect(renderer.root.findByProps({ testID: 'harness-auth-progress' }).props.animating).toBe(true);
  await act(async () => renderer.unmount());
});

test('Claude authorization uses the native in-app browser on iOS', async () => {
  auth.harnessAuthStatus.mockResolvedValue(status('claude-code', 'authorizing', {
    session_id: 'claude-browser', phase: 'waiting_for_browser',
    verification_url: 'https://claude.com/cai/oauth/authorize?code=true&state=fixture',
  }));
  auth.openHarnessAuthorization.mockResolvedValue();
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="claude-code" visible />); });
  await act(async () => { renderer.root.findByProps({ accessibilityLabel: 'settings.auth.openAuth' }).props.onPress(); });
  expect(auth.openHarnessAuthorization).toHaveBeenCalledWith('claude-code', 'claude-browser');
  await act(async () => renderer.unmount());
});

test('a signed-in Claude account can select subscription for chat', async () => {
  auth.harnessAuthStatus.mockResolvedValue(status('claude-code', 'signed_in'));
  const changed = jest.fn();
  let renderer!: TestRenderer.ReactTestRenderer;
  await act(async () => { renderer = TestRenderer.create(<HarnessSubscriptionCard id="claude-code" visible onCredentialChanged={changed} />); });
  await act(async () => { await renderer.root.findByProps({ accessibilityLabel: 'settings.auth.useAccount' }).props.onPress(); });
  expect(auth.selectClaudeChatSource).toHaveBeenCalledWith('subscription');
  expect(auth.selectCodexChatSource).not.toHaveBeenCalled();
  expect(changed).toHaveBeenCalledWith(expect.objectContaining({source:'subscription',ready:true}));
  await act(async () => renderer.unmount());
});
