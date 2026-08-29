// Request/response plumbing shared by all three functions.
//
// The rule carried over from src/lib/solana.ts holds on the server too: nothing
// throws out of a handler. Every failure becomes a typed FnError that turns into
// a JSON body the caller can branch on, because a 500 with a stack trace tells a
// browser nothing it can act on and tells an attacker rather more than nothing.

export type FnErrorCode =
  /** A required address or endpoint has not been configured yet. */
  | 'not-configured'
  /** The caller sent something malformed. */
  | 'bad-request'
  /** The chain has not seen this signature yet — retryable, not a failure. */
  | 'not-found'
  /** The chain has seen it and it is not ours, or it failed. Not retryable. */
  | 'rejected'
  /** Solana RPC was unreachable or answered with an error. */
  | 'upstream'
  /** PostgREST was unreachable or refused the write. */
  | 'database'
  /**
   * A bounded resource is full right now. Distinct from 'rejected' because the
   * caller's correct response is the opposite one: nothing is wrong with what
   * they sent, and trying again shortly is expected to work.
   */
  | 'busy'
  | 'unknown'

export interface FnError {
  code: FnErrorCode
  message: string
  detail?: string
}

export function fnError(code: FnErrorCode, message: string, detail?: string): FnError {
  return detail === undefined ? { code, message } : { code, message, detail }
}

export function isFnError(v: unknown): v is FnError {
  return typeof v === 'object' && v !== null && typeof (v as FnError).code === 'string' &&
    typeof (v as FnError).message === 'string'
}

/**
 * `not-found` is a 202, not a 404. A signature that RPC has not caught up to yet
 * is the normal case immediately after a send, and the client's correct response
 * is to try again in a second — which is a different instruction than "this will
 * never work", so it gets a different status code.
 */
const STATUS: Record<FnErrorCode, number> = {
  'not-configured': 503,
  'bad-request': 400,
  'not-found': 202,
  rejected: 422,
  upstream: 502,
  database: 500,
  // 429 rather than 503: the service is up and the request was fine, there is
  // simply no room in a bounded queue at this instant.
  busy: 429,
  unknown: 500,
}

/**
 * The anon key is public and every readable row is already public, so a wildcard
 * origin gives away nothing that a page-view does not. The functions' safety does
 * not rest on who is allowed to call them — it rests on them re-reading the chain
 * rather than believing the caller.
 */
export const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  })
}

export function errorResponse(error: FnError): Response {
  return jsonResponse({ ok: false, error }, STATUS[error.code])
}

export function preflight(): Response {
  return new Response(null, { status: 204, headers: CORS_HEADERS })
}

/** Parses a JSON body without throwing. An empty body is `{}`, not an error. */
export async function readJsonBody(request: Request): Promise<Record<string, unknown> | FnError> {
  let raw: string
  try {
    raw = await request.text()
  } catch {
    return fnError('bad-request', 'Could not read the request body.')
  }
  if (raw.trim().length === 0) return {}
  try {
    const parsed = JSON.parse(raw)
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return fnError('bad-request', 'Expected a JSON object.')
    }
    return parsed as Record<string, unknown>
  } catch {
    return fnError('bad-request', 'Request body was not valid JSON.')
  }
}

/**
 * Wraps a handler so an unexpected throw anywhere inside still leaves through the
 * same JSON shape as a handled failure. Without this a decoding bug on one exotic
 * transaction would surface to the browser as an opaque 500.
 */
export function serveSafely(handler: (request: Request) => Promise<Response>): (request: Request) => Promise<Response> {
  return async (request: Request) => {
    if (request.method === 'OPTIONS') return preflight()
    if (request.method !== 'POST') {
      return errorResponse(fnError('bad-request', 'This endpoint accepts POST only.'))
    }
    try {
      return await handler(request)
    } catch (e) {
      const detail = e instanceof Error ? e.message : 'unknown error'
      return errorResponse(fnError('unknown', 'The function failed unexpectedly.', detail))
    }
  }
}
