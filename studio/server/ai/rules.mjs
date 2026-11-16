export const ACTION = {
  NONE: 'none',
  REDUCE_DELAY: 'reduce_delay',
  SHRINK_BATCH: 'shrink_batch',
  ROTATE_PROXY: 'rotate_proxy',
  SWITCH_ACCOUNT: 'switch_account',
  SWITCH_VARIANT: 'switch_variant',
  SUPPRESS: 'suppress',
  BACKOFF: 'backoff',
  FIX_FROM_EMAIL: 'fix_from_email',
  SWITCH_TLS: 'switch_tls',
  HALT: 'halt',
  ESCALATE: 'escalate'
};

const TABLE = [
  { code: '421', action: ACTION.REDUCE_DELAY, klass: 'connection-throttle', severity: 'warn', params: { factor: 0.5 } },
  { code: '450', action: ACTION.REDUCE_DELAY, klass: 'mailbox-busy', severity: 'warn', params: { factor: 0.7 } },
  { code: '451', action: ACTION.BACKOFF, klass: 'local-error', severity: 'warn', params: { seconds: 30 } },
  { code: '452', action: ACTION.SHRINK_BATCH, klass: 'insufficient-storage', severity: 'warn', params: { factor: 0.5 } },
  { code: '454', action: ACTION.SWITCH_TLS, klass: 'tls-unavailable', severity: 'error', params: {} },
  { code: '535', action: ACTION.HALT, klass: 'auth-failed', severity: 'fatal', params: {} },
  { code: '550', action: ACTION.SUPPRESS, klass: 'mailbox-unavailable', severity: 'warn', params: {} },
  { code: '551', action: ACTION.SUPPRESS, klass: 'user-unknown', severity: 'warn', params: {} },
  { code: '552', action: ACTION.SHRINK_BATCH, klass: 'message-too-large', severity: 'warn', params: { factor: 0.5 } },
  { code: '553', action: ACTION.FIX_FROM_EMAIL, klass: 'sender-mismatch', severity: 'error', params: {} },
  { code: '554', action: ACTION.SWITCH_VARIANT, klass: 'content-rejected', severity: 'error', params: {} },
  { code: '556', action: ACTION.REDUCE_DELAY, klass: 'aborted', severity: 'warn', params: { factor: 0.7 } }
];

export function findCode(text) {
  const explicit = String(text || '').match(/\b([245]\d{2})\b/);
  if (explicit) return explicit[1];
  const loose = String(text || '').match(/([245])(\d{2})/);
  return loose ? loose[1] + loose[2] : '';
}

const SUCCESS_MARKERS = ['mail accepted', 'message accepted', '[250]', 'queued', 'delivered'];
const FAILURE_MARKERS = ['error', 'failed', 'failure', 'rejected', 'denied', 'refused', 'timeout', 'timed out', 'exception', 'not allowed'];

export function isFailureText(text) {
  const t = String(text || '').toLowerCase();
  for (const marker of SUCCESS_MARKERS) {
    if (t.includes(marker)) return false;
  }
  if (/\bfailed\s*=\s*0\b/.test(t)) return false;
  for (const marker of FAILURE_MARKERS) {
    if (t.includes(marker)) return true;
  }
  return /\b[45]\d{2}\b/.test(t);
}

export function classifyError(input) {
  const opts = input || {};
  const text = String(opts.text || '');
  const code = String(opts.code || findCode(text));

  if (!opts.code && !isFailureText(text)) {
    return { code: code, action: ACTION.NONE, klass: 'none', severity: 'none', params: {} };
  }

  if (code) {
    for (const row of TABLE) {
      if (row.code === code) {
        return { code: code, action: row.action, klass: row.klass, severity: row.severity, params: Object.assign({}, row.params) };
      }
    }
    if (code.startsWith('4')) {
      return { code: code, action: ACTION.BACKOFF, klass: 'greylist-deferred', severity: 'warn', params: { seconds: 60 } };
    }
    if (code.startsWith('5')) {
      return { code: code, action: ACTION.ESCALATE, klass: 'server-rejected', severity: 'error', params: {} };
    }
  }

  const lower = text.toLowerCase();
  if (lower.includes('econnreset') || lower.includes('socket hang up') || lower.includes('connection reset')) {
    return { code: code, action: ACTION.ROTATE_PROXY, klass: 'connection-reset', severity: 'warn', params: {} };
  }
  if (lower.includes('timed out') || lower.includes('timeout') || lower.includes('etimedout')) {
    return { code: code, action: ACTION.BACKOFF, klass: 'timeout', severity: 'warn', params: { seconds: 45 } };
  }
  if (lower.includes('tls') && lower.includes('not available')) {
    return { code: code, action: ACTION.SWITCH_TLS, klass: 'tls-unavailable', severity: 'error', params: {} };
  }
  if (lower.includes('does not match authenticated name')) {
    return { code: code, action: ACTION.FIX_FROM_EMAIL, klass: 'sender-mismatch', severity: 'error', params: {} };
  }
  if (lower.includes('authentication credentials invalid') || lower.includes('535')) {
    return { code: code, action: ACTION.HALT, klass: 'auth-failed', severity: 'fatal', params: {} };
  }
  return { code: code, action: ACTION.ESCALATE, klass: 'unknown', severity: 'error', params: {} };
}
