import { NativeModules } from 'react-native';
import type { HarnessAuthStatus, HarnessSubscriptionId } from './types';
import { validVerificationUrl } from './url';
import { isCodexModelId } from '../harness/types';

export async function codexAvailableModels(): Promise<readonly {id: string; name: string}[]> {
  const module = NativeModules.LocalRuntime as {codexAvailableModels?: () => Promise<unknown>};
  if (!module?.codexAvailableModels) throw new Error('E_CODEX_MODEL_CATALOG');
  const value = await module.codexAvailableModels();
  if (!Array.isArray(value) || value.length === 0 || value.length > 64 || value.some(row => !row || !isCodexModelId(row.id) || typeof row.name !== 'string' || row.name.length > 200)) throw new Error('E_CODEX_MODEL_CATALOG');
  return value.map(row => ({id: row.id, name: row.name}));
}

export type CodexChatSource = {
  schema_version: 1;
  source: 'subscription' | 'api_key';
  ready: boolean;
  error_code: string | null;
};

type NativeHarnessAuth = {
  harnessAuthStatus?: (harnessId: HarnessSubscriptionId) => Promise<unknown>;
  startHarnessLogin?: (harnessId: HarnessSubscriptionId) => Promise<unknown>;
  installHarnessCli?: (harnessId: HarnessSubscriptionId) => Promise<unknown>;
  cancelHarnessLogin?: (
    harnessId: HarnessSubscriptionId,
    sessionId: string,
  ) => Promise<unknown>;
  logoutHarness?: (harnessId: HarnessSubscriptionId) => Promise<unknown>;
  presentHarnessLoginCode?: (
    harnessId: HarnessSubscriptionId,
    sessionId: string,
    locale: 'en-US' | 'zh-CN',
  ) => Promise<unknown>;
  codexChatSource?: () => Promise<unknown>;
  selectCodexChatSource?: (source: 'subscription' | 'api_key') => Promise<unknown>;
  claudeChatSource?: () => Promise<unknown>;
  selectClaudeChatSource?: (source: 'subscription' | 'api_key') => Promise<unknown>;
};

const native = () => NativeModules.LocalRuntime as NativeHarnessAuth | undefined;

function safeChatSource(value: unknown, fallback = 'E_CHAT_SOURCE_UNAVAILABLE'): CodexChatSource {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return { schema_version: 1, source: 'api_key', ready: false, error_code: fallback };
  const item = value as Record<string, unknown>;
  if (item.schema_version !== 1 || (item.source !== 'subscription' && item.source !== 'api_key') || typeof item.ready !== 'boolean' || (item.error_code !== null && typeof item.error_code !== 'string')) return { schema_version: 1, source: 'api_key', ready: false, error_code: 'E_CHAT_SOURCE_MALFORMED' };
  return { schema_version: 1, source: item.source, ready: item.ready, error_code: item.error_code === null ? null : item.error_code.slice(0, 128) };
}

export async function codexChatSource(): Promise<CodexChatSource> {
  const fn = native()?.codexChatSource;
  if (typeof fn !== 'function') return safeChatSource(null);
  try { return safeChatSource(await fn()); } catch { return safeChatSource(null, 'E_CHAT_SOURCE_STATUS'); }
}

export async function selectCodexChatSource(source: 'subscription' | 'api_key'): Promise<CodexChatSource> {
  const fn = native()?.selectCodexChatSource;
  if (typeof fn !== 'function') return safeChatSource(null, 'E_CHAT_SOURCE_SELECT');
  try { return safeChatSource(await fn(source)); } catch { return safeChatSource(null, 'E_CHAT_SOURCE_SELECT'); }
}

export async function claudeChatSource(): Promise<CodexChatSource> {
  const fn = native()?.claudeChatSource;
  if (typeof fn !== 'function') return safeChatSource(null);
  try { return safeChatSource(await fn()); } catch { return safeChatSource(null, 'E_CHAT_SOURCE_STATUS'); }
}

export async function selectClaudeChatSource(source: 'subscription' | 'api_key'): Promise<CodexChatSource> {
  const fn = native()?.selectClaudeChatSource;
  if (typeof fn !== 'function') return safeChatSource(null, 'E_CHAT_SOURCE_SELECT');
  try { return safeChatSource(await fn(source)); } catch { return safeChatSource(null, 'E_CHAT_SOURCE_SELECT'); }
}

export async function openHarnessAuthorization(id: HarnessSubscriptionId, sessionId: string): Promise<void> {
  const module = NativeModules.LocalRuntime as {openHarnessAuthorization?: (id: string, session: string) => Promise<unknown>};
  if (!module?.openHarnessAuthorization) throw new Error('E_HARNESS_AUTH_BROWSER');
  await module.openHarnessAuthorization(id, sessionId);
}

function unavailable(harnessId: HarnessSubscriptionId, errorCode = 'E_AUTH_UNAVAILABLE'): HarnessAuthStatus {
  return {
    schema_version: 1,
    harness_id: harnessId,
    runtime: { kind: 'official-cli', available: false, reason: 'Official CLI authentication is unavailable in this build.' },
    status: 'unavailable',
    auth_method: 'none',
    error_code: errorCode,
  };
}

function parse(value: unknown, expected: HarnessSubscriptionId): HarnessAuthStatus {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return unavailable(expected, 'E_AUTH_MALFORMED');
  const item = value as Record<string, unknown>;
  const runtime = item.runtime;
  if (typeof runtime !== 'object' || runtime === null || Array.isArray(runtime)) return unavailable(expected, 'E_AUTH_MALFORMED');
  const runtimeItem = runtime as Record<string, unknown>;
  const statuses = ['unavailable', 'signed_out', 'authorizing', 'signed_in', 'error'] as const;
  const methods = ['subscription', 'none'] as const;
  const status = item.status;
  if (
    item.schema_version !== 1 ||
    item.harness_id !== expected ||
    runtimeItem.kind !== 'official-cli' || typeof runtimeItem.available !== 'boolean' ||
    !statuses.includes(status as typeof statuses[number]) || !methods.includes(item.auth_method as typeof methods[number]) ||
    ((status === 'signed_in' || status === 'authorizing') && (item.auth_method !== 'subscription' || runtimeItem.available !== true)) ||
    ((status === 'unavailable' || status === 'signed_out') && item.auth_method !== 'none')
  ) return unavailable(expected, 'E_AUTH_MALFORMED');
  const safe: HarnessAuthStatus = { schema_version: 1, harness_id: expected, runtime: { kind: 'official-cli', available: runtimeItem.available } as HarnessAuthStatus['runtime'], status: status as HarnessAuthStatus['status'], auth_method: item.auth_method as HarnessAuthStatus['auth_method'] };
  if (typeof runtimeItem.version === 'string') safe.runtime.version = runtimeItem.version.slice(0, 128);
  if (typeof runtimeItem.reason === 'string') safe.runtime.reason = runtimeItem.reason.slice(0, 500);
  const install = item.install;
  if (typeof install === 'object' && install !== null && !Array.isArray(install)) {
    const i = install as Record<string, unknown>;
    const phases = ['idle', 'downloading', 'ready', 'failed'] as const;
    if (phases.includes(i.phase as typeof phases[number])) {
      safe.install = { phase: i.phase as NonNullable<HarnessAuthStatus['install']>['phase'] };
      if (typeof i.fraction === 'number' && i.fraction >= 0 && i.fraction <= 1) safe.install.fraction = i.fraction;
      if (typeof i.error_code === 'string') safe.install.error_code = i.error_code.slice(0, 200);
    }
  }
  const account = item.account;
  if (typeof account === 'object' && account !== null && !Array.isArray(account) && typeof (account as Record<string, unknown>).label === 'string') {
    const a = account as Record<string, unknown>; safe.account = { label: (a.label as string).slice(0, 200) }; if (typeof a.plan === 'string') safe.account.plan = a.plan.slice(0, 100);
  }
  const login = item.login;
  if (typeof login === 'object' && login !== null && !Array.isArray(login)) {
    const l = login as Record<string, unknown>;
    if (typeof l.session_id !== 'string' || l.session_id.length === 0 || l.session_id.length > 256) return unavailable(expected, 'E_AUTH_MALFORMED');
    const safeLogin: NonNullable<HarnessAuthStatus['login']> = { session_id: l.session_id, ...(typeof l.verification_url === 'string' ? { verification_url: l.verification_url } : {}) };
    if (l.verification_url !== undefined && !validVerificationUrl(expected, l.verification_url)) return unavailable(expected, 'E_AUTH_MALFORMED');
    safe.login = safeLogin;
    if (l.phase === 'starting' || l.phase === 'waiting_for_browser' || l.phase === 'verifying') safeLogin.phase = l.phase;
    if (typeof l.user_code === 'string') safeLogin.user_code = l.user_code.slice(0, 128);
    if (l.expires_at !== undefined && (!Number.isSafeInteger(l.expires_at) || (l.expires_at as number) <= 0)) return unavailable(expected, 'E_AUTH_MALFORMED');
    if (typeof l.expires_at === 'number') safeLogin.expires_at = l.expires_at;
    if (typeof l.can_submit_code === 'boolean') safeLogin.can_submit_code = l.can_submit_code;
  }
  if (status === 'authorizing' && !safe.login) return unavailable(expected, 'E_AUTH_MALFORMED');
  if (typeof item.error_code === 'string') safe.error_code = item.error_code.slice(0, 128);
  return safe;
}

export async function harnessAuthStatus(id: HarnessSubscriptionId) {
  const fn = native()?.harnessAuthStatus;
  if (typeof fn !== 'function') return unavailable(id);
  try { return parse(await fn(id), id); } catch { return unavailable(id, 'E_AUTH_STATUS'); }
}

export async function startHarnessLogin(id: HarnessSubscriptionId) {
  const fn = native()?.startHarnessLogin;
  if (typeof fn !== 'function') return unavailable(id);
  try { return parse(await fn(id), id); } catch { return unavailable(id, 'E_AUTH_START'); }
}

export async function installHarnessCli(id: HarnessSubscriptionId) {
  const fn = native()?.installHarnessCli;
  if (typeof fn !== 'function') return unavailable(id);
  try { return parse(await fn(id), id); } catch { return unavailable(id, 'E_AUTH_INSTALL'); }
}

export async function cancelHarnessLogin(id: HarnessSubscriptionId, sessionId: string) {
  const fn = native()?.cancelHarnessLogin;
  if (typeof fn !== 'function') return unavailable(id);
  try { return parse(await fn(id, sessionId), id); } catch { return unavailable(id, 'E_AUTH_CANCEL'); }
}

export async function logoutHarness(id: HarnessSubscriptionId) {
  const fn = native()?.logoutHarness;
  if (typeof fn !== 'function') return unavailable(id);
  try { return parse(await fn(id), id); } catch { return unavailable(id, 'E_AUTH_LOGOUT'); }
}

export async function presentHarnessLoginCode(id: HarnessSubscriptionId, sessionId: string, locale: 'en-US' | 'zh-CN') {
  const fn = native()?.presentHarnessLoginCode;
  if (typeof fn !== 'function') return unavailable(id);
  try { return parse(await fn(id, sessionId, locale), id); } catch { return unavailable(id, 'E_AUTH_CODE'); }
}
