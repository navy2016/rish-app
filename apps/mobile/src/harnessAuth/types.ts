export type HarnessSubscriptionId = 'codex' | 'claude-code';

export type HarnessAuthStatus = {
  schema_version: 1;
  harness_id: HarnessSubscriptionId;
  runtime: {
    kind: 'official-cli';
    available: boolean;
    version?: string;
    reason?: string;
  };
  status: 'unavailable' | 'signed_out' | 'authorizing' | 'signed_in' | 'error';
  auth_method: 'subscription' | 'none';
  account?: { label: string; plan?: string };
  login?: {
    session_id: string;
    /** Optional progress phase supplied by newer native runtimes. */
    phase?: 'starting' | 'waiting_for_browser' | 'verifying';
    verification_url?: string;
    user_code?: string;
    /** Unix time in seconds, matching the native account contract. */
    expires_at?: number;
    can_submit_code?: boolean;
  };
  /** CLI install state; the card offers the download button and shows progress. */
  install?: {
    phase: 'idle' | 'downloading' | 'ready' | 'failed';
    fraction?: number;
    error_code?: string;
  };
  error_code?: string;
};

export type HarnessLoginResult = HarnessAuthStatus;
