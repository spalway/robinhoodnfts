// The xCorp backend, as the browser sees it.
//
// Five calls, all of them RPCs defined in supabase/XCORP-CORE.sql. There is no
// table read here and no query builder that could grow one: the SQL functions
// are the API surface, and going around them would mean this module and the
// database each had their own opinion about what a rank or a mint gate is.
//
// Two rules, both inherited from lib/supabase.ts and both load-bearing:
//
//   1. Nothing throws. Every failure RESOLVES to a BackendError the UI renders.
//      The corollary that has bitten this codebase before: `await`ing one of
//      these and using the result without a type guard hands the ERROR OBJECT to
//      code expecting data. Check with isBackendError first, every time.
//   2. Amounts cross the wire as decimal strings and are rebuilt with BigInt. A
//      u64 token amount does not survive a double, and `paid_raw` is the record
//      of what somebody actually paid.
import { SUPABASE_ANON_KEY, SUPABASE_URL, isSupabaseConfigured } from './supabase'

export type BackendErrorCode = 'not-configured' | 'network' | 'http' | 'malformed'

export interface BackendError {
  code: BackendErrorCode
  message: string
  status?: number
}

const CODES: ReadonlySet<string> = new Set(['not-configured', 'network', 'http', 'malformed'])

export function isBackendError(v: unknown): v is BackendError {
  if (typeof v !== 'object' || v === null) return false
  const c = v as { code?: unknown; message?: unknown }
  return typeof c.code === 'string' && CODES.has(c.code) && typeof c.message === 'string'
}

function fail(code: BackendErrorCode, message: string, status?: number): BackendError {
  return { code, message, status }
}

/**
 * The one place a request is issued.
 *
 * POST, because that is how PostgREST exposes a function — not because anything
 * here writes on its own account. The only call that changes state is
 * `confirmMint`, and what it changes is decided by the database reading Solana,
 * never by a field sent from here.
 */
async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T | BackendError> {
  if (!isSupabaseConfigured()) {
    return fail(
      'not-configured',
      'The xCorp backend is not connected: VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY are unset.',
    )
  }

  let response: Response
  try {
    response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(args),
    })
  } catch (e) {
    const detail = e instanceof Error ? e.message : 'unknown error'
    return fail('network', `Could not reach the xCorp backend: ${detail}`)
  }

  if (!response.ok) {
    // The body carries Postgres's own message, which is far more useful than the
    // status alone — a missing function and a denied grant are both 404/401 and
    // read identically otherwise.
    let detail = ''
    try {
      const body = (await response.json()) as { message?: unknown; hint?: unknown }
      if (typeof body?.message === 'string') detail = ` ${body.message}`
    } catch {
      /* a non-JSON error body is not worth a second failure mode */
    }
    return fail('http', `The backend refused ${fn}.${detail}`, response.status)
  }

  try {
    return (await response.json()) as T
  } catch {
    return fail('malformed', `The backend returned an unreadable response for ${fn}.`)
  }
}

// ---------------------------------------------------------------------------
// Mint gate
// ---------------------------------------------------------------------------

/** Why the mint button is not available. Null means it is. */
export type MintBlockReason = 'not-configured' | 'paused' | 'sold-out' | 'no-config' | null

export interface MintStatus {
  ok: boolean
  reason: MintBlockReason
  configured: boolean
  mintingEnabled: boolean
  mintAddress: string
  devWallet: string
  rpcUrl: string
  /** Whole tokens a mint costs. */
  priceTokens: number
  /** Whole tokens a wallet must hold before the button unlocks. */
  holdRequirementTokens: number
  maxSupply: number
  issued: number
  remaining: number
  walletHoldings: number
}

function num(v: unknown, fallback = 0): number {
  const n = typeof v === 'string' ? Number(v) : typeof v === 'number' ? v : NaN
  return Number.isFinite(n) ? n : fallback
}

function str(v: unknown): string {
  return typeof v === 'string' ? v : ''
}

export async function fetchMintStatus(wallet: string | null): Promise<MintStatus | BackendError> {
  const raw = await rpc<Record<string, unknown>>('xnft_mint_status', { p_wallet: wallet ?? null })
  if (isBackendError(raw)) return raw
  if (typeof raw !== 'object' || raw === null) {
    return fail('malformed', 'The mint gate returned no status.')
  }

  const reason = str(raw.reason)
  return {
    ok: raw.ok === true,
    reason: (reason.length > 0 ? reason : null) as MintBlockReason,
    configured: raw.configured === true,
    mintingEnabled: raw.minting_enabled === true,
    mintAddress: str(raw.mint_address),
    devWallet: str(raw.dev_wallet),
    rpcUrl: str(raw.rpc_url),
    priceTokens: num(raw.price_tokens),
    holdRequirementTokens: num(raw.hold_requirement_tokens),
    maxSupply: num(raw.max_supply),
    issued: num(raw.issued),
    remaining: num(raw.remaining),
    walletHoldings: num(raw.wallet_holdings),
  }
}

// ---------------------------------------------------------------------------
// Confirming a payment
// ---------------------------------------------------------------------------

/**
 * What the verifier decided.
 *
 * 'pending' is the branch that matters most and the one a UI must not get wrong.
 * It means the RPC has not caught up to a transaction that has ALREADY been
 * signed and sent — the normal state for the first few seconds. Rendering it as
 * a failure is how somebody pays a second time.
 */
export type ConfirmStatus = 'confirmed' | 'duplicate' | 'pending' | 'busy' | 'rejected'

export interface MintAssignment {
  /** 'issued' = a serial was dealt. 'held' = paid, verified, no serial available. */
  status: 'issued' | 'held'
  serial: number | null
  label: string | null
  tier: string | null
  heldReason: string | null
}

export interface ConfirmResult {
  ok: boolean
  status: ConfirmStatus
  reason: string | null
  message: string | null
  buyer: string | null
  assignment: MintAssignment | null
}

/**
 * Call an Edge Function.
 *
 * Separate from `rpc` because it is a different service on a different path.
 * Only `confirmMint` uses it, and only because verification has to read Solana
 * — which Postgres cannot do, so the one call that needs a network lives out
 * here while every read stays an RPC.
 */
async function edge<T>(fn: string, body: Record<string, unknown>): Promise<T | BackendError> {
  if (!isSupabaseConfigured()) {
    return fail(
      'not-configured',
      'The xCorp backend is not connected: VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY are unset.',
    )
  }

  let response: Response
  try {
    response = await fetch(`${SUPABASE_URL}/functions/v1/${fn}`, {
      method: 'POST',
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    })
  } catch (e) {
    const detail = e instanceof Error ? e.message : 'unknown error'
    return fail('network', `Could not reach the verifier: ${detail}`)
  }

  // A non-2xx is NOT treated as a failed mint. The verifier answers 200 with a
  // status for every outcome it can actually decide; anything else is this
  // module failing to reach it, and the caller renders that as "not yet".
  let parsed: unknown
  try {
    parsed = await response.json()
  } catch {
    return fail('malformed', 'The verifier returned an unreadable result.')
  }
  if (!response.ok && (typeof parsed !== 'object' || parsed === null || !('status' in parsed))) {
    return fail('http', 'The verifier refused the request.', response.status)
  }
  return parsed as T
}

export async function confirmMint(signature: string): Promise<ConfirmResult | BackendError> {
  const raw = await edge<Record<string, unknown>>('confirm-mint', { signature })
  if (isBackendError(raw)) return raw
  if (typeof raw !== 'object' || raw === null) {
    return fail('malformed', 'The verifier returned no result.')
  }

  const a = raw.assignment as Record<string, unknown> | undefined
  const status = str(raw.status)

  return {
    ok: raw.ok === true,
    // An unrecognised status is treated as 'pending', never as 'rejected'. The
    // failure mode of guessing wrong in the other direction is a buyer being
    // told a mint they paid for did not happen.
    status: (['confirmed', 'duplicate', 'pending', 'busy', 'rejected'].includes(status)
      ? status
      : 'pending') as ConfirmStatus,
    reason: str(raw.reason) || null,
    message: str(raw.message) || null,
    buyer: str(raw.buyer) || null,
    assignment: a
      ? {
          status: a.status === 'held' ? 'held' : 'issued',
          serial: typeof a.serial === 'number' ? a.serial : null,
          label: str(a.label) || null,
          tier: str(a.tier) || null,
          heldReason: str(a.held_reason) || null,
        }
      : null,
  }
}

// ---------------------------------------------------------------------------
// xNet
// ---------------------------------------------------------------------------

export interface LeaderRow {
  position: number
  wallet: string
  handle: string | null
  holdings: number
  rarityScore: number
  bestTier: string
  bestSerial: number
  xboss: string
  firstMintAt: number
}

function parseLeader(row: Record<string, unknown>): LeaderRow | null {
  const wallet = str(row.wallet)
  if (!wallet) return null
  return {
    position: num(row.rank_position),
    wallet,
    handle: str(row.handle) || null,
    holdings: num(row.holdings),
    rarityScore: num(row.rarity_score),
    bestTier: str(row.best_tier) || 'entry',
    bestSerial: num(row.best_serial),
    xboss: str(row.xboss) || 'BOSS',
    firstMintAt: Date.parse(str(row.first_mint_at)) || 0,
  }
}

export async function fetchLeaderboard(
  opts: { limit?: number; offset?: number; query?: string } = {},
): Promise<LeaderRow[] | BackendError> {
  const rows = await rpc<unknown>('xnft_leaderboard', {
    p_limit: opts.limit ?? 50,
    p_offset: opts.offset ?? 0,
    p_query: opts.query && opts.query.trim().length > 0 ? opts.query.trim() : null,
  })
  if (isBackendError(rows)) return rows
  if (!Array.isArray(rows)) return fail('malformed', 'The leaderboard returned no rows.')
  // A row this module cannot read is dropped by itself rather than taking the
  // whole table down with it.
  return rows
    .map((r) => parseLeader(r as Record<string, unknown>))
    .filter((r): r is LeaderRow => r !== null)
}

export interface NetworkStats {
  wallets: number
  issued: number
  maxSupply: number
  rarityTotal: number
  tiers: Record<string, number>
}

export async function fetchNetworkStats(): Promise<NetworkStats | BackendError> {
  const raw = await rpc<Record<string, unknown>>('xnft_network_stats')
  if (isBackendError(raw)) return raw
  const tiers = (raw?.tiers ?? {}) as Record<string, unknown>
  return {
    wallets: num(raw?.wallets),
    issued: num(raw?.issued),
    maxSupply: num(raw?.max_supply),
    rarityTotal: num(raw?.rarity_total),
    tiers: Object.fromEntries(Object.entries(tiers).map(([k, v]) => [k, num(v)])),
  }
}

/**
 * Who holds one serial, or null if it has not been minted.
 *
 * The one GET in this module. `xnft_holdings` publishes SELECT to anon by
 * design — it is the ownership record and every row in it corresponds to a
 * public transaction — so a narrow read of one row does not need a function
 * wrapped around it. Nothing else here reads a table directly.
 */
export async function fetchHolder(
  serial: number,
): Promise<{ owner: string; tier: string; mintedAt: number; signature: string } | null | BackendError> {
  if (!isSupabaseConfigured()) return null
  let response: Response
  try {
    response = await fetch(
      `${SUPABASE_URL}/rest/v1/xnft_holdings?select=owner,tier,minted_at,mint_signature&serial=eq.${encodeURIComponent(
        String(serial),
      )}&limit=1`,
      {
        headers: {
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
        },
      },
    )
  } catch {
    return fail('network', 'Could not reach the xCorp backend.')
  }
  if (!response.ok) return fail('http', 'The backend refused a holdings read.', response.status)

  try {
    const rows = (await response.json()) as Record<string, unknown>[]
    const row = Array.isArray(rows) ? rows[0] : undefined
    if (!row) return null
    return {
      owner: str(row.owner),
      tier: str(row.tier) || 'entry',
      mintedAt: Date.parse(str(row.minted_at)) || 0,
      signature: str(row.mint_signature),
    }
  } catch {
    return fail('malformed', 'The backend returned an unreadable holdings row.')
  }
}

export interface CrewMember {
  serial: number
  label: string
  tier: string
  skills: number
  rarityWeight: number
  mintedAt: number
  signature: string
}

export interface WalletPage {
  ok: boolean
  wallet: string
  handle: string | null
  position: number | null
  holdings: number
  rarityScore: number
  xboss: string | null
  firstMintAt: number
  crew: CrewMember[]
}

export async function fetchWalletPage(wallet: string): Promise<WalletPage | BackendError> {
  const raw = await rpc<Record<string, unknown>>('xnft_wallet', { p_wallet: wallet })
  if (isBackendError(raw)) return raw
  if (typeof raw !== 'object' || raw === null) {
    return fail('malformed', 'That wallet returned no page.')
  }

  const crew = Array.isArray(raw.crew) ? (raw.crew as Record<string, unknown>[]) : []
  return {
    ok: raw.ok === true,
    wallet: str(raw.wallet),
    handle: str(raw.handle) || null,
    position: typeof raw.position === 'number' ? raw.position : null,
    holdings: num(raw.holdings),
    rarityScore: num(raw.rarity_score),
    xboss: str(raw.xboss) || null,
    firstMintAt: Date.parse(str(raw.first_mint_at)) || 0,
    crew: crew.map((c) => ({
      serial: num(c.serial),
      label: str(c.label),
      tier: str(c.tier) || 'entry',
      skills: num(c.skills),
      rarityWeight: num(c.rarity_weight),
      mintedAt: Date.parse(str(c.minted_at)) || 0,
      signature: str(c.signature),
    })),
  }
}
