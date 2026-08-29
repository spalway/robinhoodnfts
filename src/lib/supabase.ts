// Read-only Supabase client, anon key only.
//
// Supabase is an index and a payout queue, never an authority on a balance. If it
// disagrees with the chain, the chain is right and this index gets rebuilt — so
// nothing in the app should ever gate a decision on a number that came from here.
//
// Four rules shape this module, and they are the same ones that hold spl.ts
// together:
//
//   1. There is no write. Not a disabled one, not a guarded one — this file has
//      no insert, update or delete, and no generic query builder that could grow
//      one. The two POST helpers at the bottom call Edge Functions, which do
//      their own verification against the chain. RLS denies client writes at the
//      database too; this is the second lock, not the only one.
//   2. Configuration is a gate. VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY are
//      empty until a project exists, and every call returns `not-configured`
//      while they are, the way isConfigured() gates every transfer path.
//   3. Money crosses the wire as a decimal string and is reconstructed with
//      BigInt. Amount columns are `text` in Postgres precisely so that PostgREST
//      cannot hand the browser a JSON number that has already been through a
//      double. A malformed amount is an error, never a silent zero.
//   4. Nothing throws. Every failure RESOLVES to a SupabaseError the UI renders,
//      which is the same contract spl.ts is written under.
//   5. THE SCHEMA IS THE CONTRACT, AND ONE BAD ROW IS ONE BAD ROW. A column the
//      database is allowed to leave null is modelled null here, and a row this
//      module cannot read is dropped by itself instead of taking its siblings
//      with it. Both halves were once wrong in the same direction and the result
//      was not a subtle inaccuracy — it was three reads returning `malformed`
//      permanently, from the very first row, because the parsers demanded columns
//      the schema deliberately leaves empty:
//
//        payouts.amount is NULL until confirm-payout reads the settled transfer
//        off the chain (that nullness IS the "never treat a client-asserted
//        amount as truth" rule), mints.xployee_id is null on every genuine mint
//        because two token transfers carry no room to name an xployee, and
//        trades.signature/slot are FORCED null on every simulated sale by
//        trades_origin_matches_evidence. Each of those made an entire page
//        unrenderable.
//
//      So: required means "not null in the schema AND the row is unusable
//      without it" — an identity and its money. Everything the schema permits to
//      be null is `| null` below, and every read returns a RowSet carrying how
//      many rows were dropped, so a caller summing money can tell a complete page
//      from a partial one instead of being handed a quietly short total.
//
// Rule 4 has a corollary that cost this app a crashing page once, so it is
// written down rather than left to be rediscovered: because a failure resolves,
// `await`ing one of these functions and using the result without a type guard
// hands the *error object* to code expecting rows. NONE of these functions may be
// passed straight to a framework that treats a resolved value as success —
// TanStack Query's `queryFn` in particular. Callers unwrap at their own boundary
// and convert a SupabaseError into whatever failure their framework understands.
// See `orThrow` in usePayouts.ts for the one place this app does that.
//
// The anon key is public by design — it is compiled into the bundle and visible
// to anyone. It is safe there only because the policies in
// supabase/migrations/20260805120200_rls_policies.sql grant it SELECT and nothing
// else, on tables that hold nothing private.

export type SupabaseErrorCode =
  /** No project configured yet. No request was made. */
  | 'not-configured'
  /** The request never reached Supabase. */
  | 'network'
  /** Supabase answered with a non-2xx. */
  | 'http'
  /** A row came back in a shape this module refuses to guess at. */
  | 'malformed'

export interface SupabaseError {
  code: SupabaseErrorCode
  message: string
  status?: number
}

const ERROR_CODES: ReadonlySet<string> = new Set(['not-configured', 'network', 'http', 'malformed'])

export function isSupabaseError(v: unknown): v is SupabaseError {
  if (typeof v !== 'object' || v === null) return false
  const candidate = v as { code?: unknown; message?: unknown }
  return typeof candidate.code === 'string' && ERROR_CODES.has(candidate.code) &&
    typeof candidate.message === 'string'
}

function fail(code: SupabaseErrorCode, message: string, status?: number): SupabaseError {
  return status === undefined ? { code, message } : { code, message, status }
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

function readEnv(key: string): string {
  const value = (import.meta.env as Record<string, unknown>)[key]
  return typeof value === 'string' ? value.trim() : ''
}

export const SUPABASE_URL = readEnv('VITE_SUPABASE_URL').replace(/\/+$/, '')
export const SUPABASE_ANON_KEY = readEnv('VITE_SUPABASE_ANON_KEY')

const NOT_CONFIGURED =
  'The xCorp index is not connected: VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY are unset. No request was made.'

/** False until both env vars hold something. Every call below checks this first. */
export function isSupabaseConfigured(): boolean {
  return SUPABASE_URL.length > 0 && SUPABASE_ANON_KEY.length > 0
}

/**
 * The anon key is the apikey on every request. The BEARER is the session's access
 * token when there is one, and the anon key when there is not.
 *
 * That substitution is the whole of "reads use the anon key, except where the
 * schema says otherwise". Most tables are published to anon; correspondence —
 * friend_requests, threads, messages, trade_offers and their legs — is granted to
 * `authenticated` only, and its policies filter on `current_wallet()`. Sending the
 * anon key as the bearer there is not a smaller read, it is a 401. Sending a
 * session token where anon would have done changes nothing, because every policy
 * that publishes to anon also publishes to authenticated.
 */
function authHeaders(): Record<string, string> {
  const token = sessionToken()
  return {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${token ?? SUPABASE_ANON_KEY}`,
  }
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------
//
// X (Twitter) is the only provider, and a session exists for exactly one reason:
// the writers behind every Edge Function resolve the acting wallet from
// `auth.users` rather than from a request body, so an unauthenticated caller can
// read the public half of the index and write nothing at all.
//
// This is a deliberately small implementation rather than @supabase/supabase-js:
// the whole surface is an implicit-flow redirect, a token in storage, and a
// refresh. Pulling a client library in to hold four fields would add a dependency
// that also brings its own realtime stack, its own query builder — the generic
// writer rule 1 exists to prevent — and its own opinion about storage.
//
// EVERY storage and location touch below is wrapped and lazy. This module is
// imported by tests that run under Node, where `localStorage` and `window` do not
// exist; a module-scope read would make importing the file a crash rather than a
// no-op.

export interface Session {
  accessToken: string
  /** Empty when the provider issued none. A session without one simply expires. */
  refreshToken: string
  /** Epoch ms. */
  expiresAt: number
  /** The `auth.users` id, when the token carried one. Display only — never trusted. */
  userId: string | null
}

const SESSION_KEY = 'xnfts:auth'

/**
 * Treat a token as spent slightly before it is, so a request started now does not
 * arrive after expiry. Thirty seconds is longer than any round trip this app makes
 * and shorter than any sensible token lifetime.
 */
const EXPIRY_SKEW_MS = 30_000

let sessionCache: Session | null | undefined

function coerceSession(value: unknown): Session | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Record<string, unknown>
  const accessToken = typeof raw.accessToken === 'string' ? raw.accessToken : ''
  if (!accessToken) return null
  const expiresAt = typeof raw.expiresAt === 'number' && Number.isFinite(raw.expiresAt) ? raw.expiresAt : 0
  return {
    accessToken,
    refreshToken: typeof raw.refreshToken === 'string' ? raw.refreshToken : '',
    expiresAt,
    userId: typeof raw.userId === 'string' && raw.userId ? raw.userId : null,
  }
}

/** The stored session, whether or not it has expired. */
export function getSession(): Session | null {
  if (sessionCache !== undefined) return sessionCache
  try {
    const raw = localStorage.getItem(SESSION_KEY)
    sessionCache = raw ? coerceSession(JSON.parse(raw)) : null
  } catch {
    // No storage, or a hand-edited entry. Signed out is the answer.
    sessionCache = null
  }
  return sessionCache
}

const sessionListeners = new Set<() => void>()

/** Fires whenever the session appears, changes or is dropped. */
export function subscribeSession(listener: () => void): () => void {
  sessionListeners.add(listener)
  return () => {
    sessionListeners.delete(listener)
  }
}

function setSession(session: Session | null): void {
  sessionCache = session
  try {
    if (session) localStorage.setItem(SESSION_KEY, JSON.stringify(session))
    else localStorage.removeItem(SESSION_KEY)
  } catch {
    // Quota or private mode — the session lives for this tab only.
  }
  for (const listener of sessionListeners) listener()
}

/** The access token, or null when there is no session or it has expired. */
export function sessionToken(): string | null {
  const session = getSession()
  if (!session) return null
  if (session.expiresAt > 0 && session.expiresAt - EXPIRY_SKEW_MS <= Date.now()) return null
  return session.accessToken
}

export function isSignedIn(): boolean {
  return sessionToken() !== null
}

/** The `sub` claim, read for display. Never used to authorise anything — the Edge Functions re-check the token. */
function subjectOf(accessToken: string): string | null {
  const parts = accessToken.split('.')
  if (parts.length !== 3) return null
  try {
    const json = atob(parts[1].replace(/-/g, '+').replace(/_/g, '/'))
    const claims = JSON.parse(json) as { sub?: unknown }
    return typeof claims.sub === 'string' ? claims.sub : null
  } catch {
    return null
  }
}

/**
 * Captures the tokens GoTrue leaves in the URL fragment after an X sign-in, and
 * removes them from the address bar.
 *
 * Returns true when a session was captured, so a caller can tell "just signed in"
 * from "already had one". Safe to call on every boot: with no fragment it does
 * nothing and touches no storage.
 *
 * The fragment is stripped with `history.replaceState` rather than left in place
 * because an access token in the address bar is an access token in the user's
 * history, their bookmarks, and any screenshot they take of the page.
 */
export function captureAuthRedirect(): boolean {
  try {
    const hash = window.location.hash
    if (!hash || hash.length < 2) return false
    const params = new URLSearchParams(hash.slice(1))
    const accessToken = params.get('access_token')
    if (!accessToken) return false

    const expiresIn = Number(params.get('expires_in'))
    const expiresAt = Number.isFinite(expiresIn) && expiresIn > 0
      ? Date.now() + expiresIn * 1000
      // No lifetime quoted: treat it as an hour, which is GoTrue's default, and
      // let the refresh path correct it. A zero here would read as "never
      // expires", which is the wrong direction to guess in.
      : Date.now() + 3_600_000

    setSession({
      accessToken,
      refreshToken: params.get('refresh_token') ?? '',
      expiresAt,
      userId: subjectOf(accessToken),
    })

    const { pathname, search } = window.location
    window.history.replaceState(null, '', `${pathname}${search}`)
    return true
  } catch {
    // No window, or a browser refusing replaceState. Nothing was captured.
    return false
  }
}

/**
 * Sends the browser to X to sign in.
 *
 * Returns false without navigating when the project is unconfigured, which is the
 * same refusal shape as every other call here: unset configuration means the real
 * path builds nothing and goes nowhere.
 */
export function signInWithX(redirectTo?: string): boolean {
  if (!isSupabaseConfigured()) return false
  try {
    const target = redirectTo ?? `${window.location.origin}${window.location.pathname}`
    const url = `${SUPABASE_URL}/auth/v1/authorize?provider=twitter&redirect_to=${encodeURIComponent(target)}`
    window.location.assign(url)
    return true
  } catch {
    return false
  }
}

/**
 * Drops the session locally, and tells GoTrue to revoke it.
 *
 * The local drop happens FIRST and unconditionally. A sign-out that fails because
 * the network is down must still sign the user out of this browser — the opposite
 * order leaves a token in storage after the user has been told they are out.
 */
export async function signOut(): Promise<void> {
  const token = getSession()?.accessToken ?? ''
  setSession(null)
  if (!token || !isSupabaseConfigured()) return
  try {
    await fetch(`${SUPABASE_URL}/auth/v1/logout`, {
      method: 'POST',
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` },
    })
  } catch {
    // The local session is already gone, which is the part that matters here.
  }
}

/**
 * Exchanges the refresh token for a new access token.
 *
 * A failure CLEARS the session rather than leaving a stale one in place: a refresh
 * that GoTrue refuses means the session is over, and keeping the dead token would
 * turn every subsequent write into an unexplained 401.
 */
export async function refreshSession(): Promise<Session | SupabaseError> {
  if (!isSupabaseConfigured()) return fail('not-configured', NOT_CONFIGURED)
  const session = getSession()
  if (!session?.refreshToken) return fail('http', 'This session cannot be refreshed. Sign in with X again.', 401)

  let response: Response
  try {
    response = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
      method: 'POST',
      headers: { apikey: SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: session.refreshToken }),
    })
  } catch (e) {
    const detail = e instanceof Error ? e.message : 'unknown error'
    // A network failure is NOT a dead session — the token may still be perfectly
    // good — so this path deliberately leaves it alone.
    return fail('network', `Could not reach the auth service: ${detail}`)
  }

  if (!response.ok) {
    setSession(null)
    return fail('http', 'That session has ended. Sign in with X again.', response.status)
  }

  let body: unknown
  try {
    body = await response.json()
  } catch {
    return fail('malformed', 'The auth service returned an unreadable session.')
  }

  const raw = body as { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown }
  const accessToken = typeof raw.access_token === 'string' ? raw.access_token : ''
  if (!accessToken) {
    setSession(null)
    return fail('malformed', 'The auth service returned a session with no token.')
  }
  const expiresIn = typeof raw.expires_in === 'number' ? raw.expires_in : 3600
  const next: Session = {
    accessToken,
    refreshToken: typeof raw.refresh_token === 'string' ? raw.refresh_token : session.refreshToken,
    expiresAt: Date.now() + expiresIn * 1000,
    userId: subjectOf(accessToken),
  }
  setSession(next)
  return next
}

// ---------------------------------------------------------------------------
// Row shapes, after parsing
// ---------------------------------------------------------------------------

/**
 * Which kind of thing a row is a record of. Mirrors the `row_origin` domain, and
 * a reader deciding whether to link a row to an explorer checks this rather than
 * guessing from whether a signature happens to be present.
 */
export type RowOrigin = 'chain' | 'simulated'

export interface WalletRow {
  address: string
  handle: string | null
  bio: string | null
  twitter: string | null
}

export interface XployeeRow {
  id: number
  nftMint: string | null
  owner: string | null
  tier: string | null
  skills: number | null
  traits: unknown
  /** USD notional from the deterministic generator, not a token balance. */
  principal: number | null
  apy: number | null
  hiredAt: number | null
  mintSignature: string | null
}

export interface ListingRow {
  nftMint: string
  /**
   * The join key that actually works, and not null in the schema. `nftMint` is
   * the primary key but nothing populates the matching column on `xployees`, so
   * this is the only field here that can be tied back to an xployee.
   */
  xployeeId: number
  seller: string
  kind: 'sale' | 'rent'
  price: bigint | null
  feePerEpoch: bigint | null
  termEpochs: number | null
  status: 'active' | 'sold' | 'rented' | 'cancelled'
  /**
   * Vestigial. There is no escrow program, so no listing has a PDA and this is
   * null on every row written from here on. It stays mapped rather than dropped
   * because the column still exists in the schema and silently discarding a
   * column is how a reader starts disagreeing with its database — a migration
   * owned by another track has to remove it before this field can go.
   */
  listingPda: string | null
  updatedAt: number | null
}

export interface TradeRow {
  /**
   * The row's own uuid, and the only identity a trade has. A sale is simulated,
   * so there is no signature to key it by — which is exactly why the schema gave
   * this table a generated primary key instead of one.
   */
  id: string
  xployeeId: number
  nftMint: string
  buyer: string
  seller: string
  gross: bigint
  /** Notional. What a 5% fee would have been; it never reached a treasury. */
  fee: bigint
  netToSeller: bigint
  /**
   * 'simulated' on every row that exists today. Check it before presenting a
   * trade as on-chain — the `trades_origin_matches_evidence` constraint ties it
   * to the two fields below, so 'simulated' and a signature cannot co-occur.
   */
  origin: RowOrigin
  /** Both null on a simulated row, which the schema FORCES. Not a missing value — an impossible one. */
  signature: string | null
  slot: number | null
  blockTime: number | null
  recordedAt: number | null
}

export interface MintRow {
  signature: string
  /**
   * Position of the mint's first transfer inside the transaction. Part of the
   * primary key with `signature`, so it is also what makes a row identifiable:
   * two mints batched into one signature are two rows sharing one signature.
   */
  eventIndex: number
  buyer: string
  burned: bigint
  fee: bigint
  /**
   * Null on every genuine mint. A mint transaction is two token transfers and
   * carries no room to name an xployee, so nothing on-chain says which one it
   * bought. Requiring this here failed every chain-verified mint ever indexed.
   */
  xployeeId: number | null
  slot: number
  blockTime: number | null
}

/**
 * 'sale' is absent, and its absence is load-bearing. The fee_ledger is
 * reconciled against a treasury token account anyone can read, and a simulated
 * sale accrues nothing there — so the schema's check constraint permits only
 * these two, and a wider type here would invite a `sumFees(rows, 'sale')` that
 * silently returns zero forever.
 */
export type FeeSource = 'mint' | 'rent'

export interface FeeLedgerRow {
  signature: string
  source: FeeSource
  /** Third leg of the primary key, so one transaction carrying two fees is two rows. */
  eventIndex: number
  amount: bigint
  slot: number
  blockTime: number | null
}

export type PayoutStatus = 'pending' | 'confirmed' | 'failed'

export interface PayoutRow {
  id: string
  /**
   * The authoritative figure, read off the chain by confirm-payout — and NULL
   * until it has been, which is most of a payout's life and all of a failed one.
   *
   * That null is the schema's enforcement of "never treat a client-asserted
   * amount as truth", not a gap: `payouts_amount_iff_confirmed` makes 'confirmed'
   * unreachable while it is null. Parsing it with the strict money helper is what
   * made every payout read fail from the first claim onward, so it is nullable
   * here and callers render '—' rather than a number nobody has verified.
   */
  amount: bigint | null
  /**
   * What the browser said it was claiming, before anything had landed. Never
   * truth — it is kept only so a discrepancy with `amount` is visible once the
   * chain answers. Null when the caller made no assertion.
   */
  claimedAmount: bigint | null
  /**
   * Generated in the database as `amount is not null`, so it cannot drift from
   * the column it describes. A pending payout is always false; confirm-payout
   * makes it true by writing the settled figure.
   */
  amountVerified: boolean
  destination: string
  status: PayoutStatus
  signature: string | null
  failureReason: string | null
  requestedAt: number
  confirmedAt: number | null
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

const DIGITS = /^(0|[1-9][0-9]{0,19})$/

/** Raw token units. Returns null on anything that is not a plain decimal string. */
function rawUnits(value: unknown): bigint | null {
  if (typeof value !== 'string' || !DIGITS.test(value)) return null
  return BigInt(value)
}

/**
 * The same thing for a nullable money column, and the distinction it draws is
 * the one the payout parser needed: absent is a STATE, garbage is a DEFECT.
 * `payouts.amount` being null means the chain has not answered yet; `'1.5'` in
 * that column means a number has already been through a double somewhere.
 */
function optionalRawUnits(value: unknown): bigint | null | 'invalid' {
  if (value === null || value === undefined) return null
  const parsed = rawUnits(value)
  return parsed === null ? 'invalid' : parsed
}

function text(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function integer(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) ? value : null
}

function decimal(value: unknown): number | null {
  // Postgres `numeric` can arrive as a string from PostgREST depending on the
  // column; both forms are accepted here because neither is a token balance.
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string') {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

/** ISO 8601 → epoch ms. Returns null rather than NaN, which would poison a sort. */
function timestamp(value: unknown): number | null {
  if (typeof value !== 'string') return null
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? null : parsed
}

const MALFORMED = 'The index returned a row this app refuses to guess at. Nothing was displayed rather than a wrong number.'

/**
 * Every parser below follows one rule, and it is the rule that was broken:
 *
 *   A field is required here if and only if the schema declares it NOT NULL and
 *   the row is unusable without it — its identity and its money. Anything the
 *   database is permitted to leave empty is `| null`, never a rejection.
 *
 * The failing direction is asymmetric, which is why the rule is one-directional.
 * A parser that is looser than the schema accepts a row that cannot exist, and
 * nothing happens. A parser that is stricter rejects rows that the schema
 * deliberately writes, forever, silently — and that is what shipped.
 */
function parseTrade(row: Record<string, unknown>): TradeRow | null {
  const gross = rawUnits(row.gross)
  const fee = rawUnits(row.fee)
  const netToSeller = rawUnits(row.net_to_seller)
  const id = text(row.id)
  const nftMint = text(row.nft_mint)
  const buyer = text(row.buyer)
  const seller = text(row.seller)
  const xployeeId = integer(row.xployee_id)
  const origin = text(row.origin)
  if (gross === null || fee === null || netToSeller === null) return null
  if (!id || !nftMint || !buyer || !seller || xployeeId === null) return null
  if (origin !== 'chain' && origin !== 'simulated') return null
  return {
    id,
    xployeeId,
    nftMint,
    buyer,
    seller,
    gross,
    fee,
    netToSeller,
    origin,
    // Null on every simulated row, and the schema's origin/evidence constraint is
    // what forces that. Demanding them here rejected the only kind of trade this
    // application can write.
    signature: text(row.signature),
    slot: integer(row.slot),
    blockTime: timestamp(row.block_time),
    recordedAt: timestamp(row.recorded_at),
  }
}

function parseMint(row: Record<string, unknown>): MintRow | null {
  const burned = rawUnits(row.burned)
  const fee = rawUnits(row.fee)
  const signature = text(row.signature)
  const eventIndex = integer(row.event_index)
  const buyer = text(row.buyer)
  const slot = integer(row.slot)
  if (burned === null || fee === null) return null
  if (!signature || eventIndex === null || !buyer || slot === null) return null
  // `xployee_id` is documented as null in practice and record_mint never writes
  // it. It is a nullable column, so it is a nullable field.
  return { signature, eventIndex, buyer, burned, fee, xployeeId: integer(row.xployee_id), slot, blockTime: timestamp(row.block_time) }
}

function parseFeeLedger(row: Record<string, unknown>): FeeLedgerRow | null {
  const amount = rawUnits(row.amount)
  const signature = text(row.signature)
  const source = text(row.source)
  const eventIndex = integer(row.event_index)
  const slot = integer(row.slot)
  if (amount === null || !signature || eventIndex === null || slot === null) return null
  // Matches the column's check constraint exactly. A third value would be a row
  // the database could not have written.
  if (source !== 'mint' && source !== 'rent') return null
  return { signature, source, eventIndex, amount, slot, blockTime: timestamp(row.block_time) }
}

function parseListing(row: Record<string, unknown>): ListingRow | null {
  const price = optionalRawUnits(row.price)
  const feePerEpoch = optionalRawUnits(row.fee_per_epoch)
  if (price === 'invalid' || feePerEpoch === 'invalid') return null

  const nftMint = text(row.nft_mint)
  const xployeeId = integer(row.xployee_id)
  const seller = text(row.seller)
  const kind = text(row.kind)
  const status = text(row.status)
  if (!nftMint || xployeeId === null || !seller) return null
  if (kind !== 'sale' && kind !== 'rent') return null
  if (status !== 'active' && status !== 'sold' && status !== 'rented' && status !== 'cancelled') return null

  return {
    nftMint,
    xployeeId,
    seller,
    kind,
    price,
    feePerEpoch,
    termEpochs: integer(row.term_epochs),
    status,
    listingPda: text(row.listing_pda),
    updatedAt: timestamp(row.updated_at),
  }
}

function parseXployee(row: Record<string, unknown>): XployeeRow | null {
  const id = integer(row.id)
  if (id === null) return null
  return {
    id,
    nftMint: text(row.nft_mint),
    owner: text(row.owner),
    tier: text(row.tier),
    skills: integer(row.skills),
    traits: row.traits ?? null,
    principal: decimal(row.principal),
    apy: decimal(row.apy),
    hiredAt: timestamp(row.hired_at),
    mintSignature: text(row.mint_signature),
  }
}

function parseWallet(row: Record<string, unknown>): WalletRow | null {
  const address = text(row.address)
  if (!address) return null
  return { address, handle: text(row.handle), bio: text(row.bio), twitter: text(row.twitter) }
}

function parsePayout(row: Record<string, unknown>): PayoutRow | null {
  // Both amounts are nullable columns, so both go through the optional helper —
  // but a present-and-unreadable amount is still a refusal. `optionalRawUnits`
  // draws that line: absent is a state, garbage is a defect.
  const amount = optionalRawUnits(row.amount)
  const claimedAmount = optionalRawUnits(row.claimed_amount_unverified)
  if (amount === 'invalid' || claimedAmount === 'invalid') return null

  const id = text(row.id)
  const destination = text(row.destination)
  const status = text(row.status)
  const requestedAt = timestamp(row.requested_at)
  if (!id || !destination || requestedAt === null) return null
  if (status !== 'pending' && status !== 'confirmed' && status !== 'failed') return null
  return {
    id,
    amount,
    claimedAmount,
    // Read from the generated column rather than derived from `amount` here, so
    // this module reports what the database says rather than a second opinion
    // that could disagree with it.
    amountVerified: row.amount_verified === true,
    destination,
    status,
    signature: text(row.signature),
    failureReason: text(row.failure_reason),
    requestedAt,
    confirmedAt: timestamp(row.confirmed_at),
  }
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

/**
 * The one place a GET is issued. Every read below goes through it, which is what
 * makes "this module cannot write" checkable by reading forty lines rather than
 * the whole file: the method is hard-coded and there is no sibling.
 */
async function select(table: string, query: string): Promise<unknown[] | SupabaseError> {
  if (!isSupabaseConfigured()) return fail('not-configured', NOT_CONFIGURED)

  let response: Response
  try {
    response = await fetch(`${SUPABASE_URL}/rest/v1/${table}?${query}`, {
      method: 'GET',
      headers: authHeaders(),
    })
  } catch (e) {
    const detail = e instanceof Error ? e.message : 'unknown error'
    return fail('network', `Could not reach the xCorp index: ${detail}`)
  }

  if (!response.ok) {
    return fail('http', `The xCorp index refused a read of ${table}.`, response.status)
  }

  try {
    const body = await response.json()
    return Array.isArray(body) ? body : []
  } catch {
    return fail('malformed', `The xCorp index returned an unreadable response for ${table}.`)
  }
}

/**
 * What a multi-row read returns.
 *
 * `skipped` exists because the two obvious policies are both wrong. Failing the
 * whole read on one bad row is what this module used to do, and it turned a
 * single unreadable row into a blank page — worse, combined with parsers stricter
 * than the schema, it turned every row into a bad row and three pages never
 * rendered at all. But silently dropping the row and handing back the rest would
 * quietly understate a fee total, and a number that is quietly wrong is worse
 * than no number.
 *
 * So the row is dropped and the drop is reported. A caller rendering a list shows
 * what it has; a caller summing money checks `skipped` and refuses to call the
 * total exact. Neither one gets to be wrong by accident.
 */
export interface RowSet<T> {
  rows: T[]
  /** Rows the parser refused. Non-zero means this page is incomplete. */
  skipped: number
}

/**
 * Applies a parser across a result set. Never fails: a row that cannot be read
 * is left out and counted, and its siblings survive it.
 */
function parseRows<T>(rows: unknown[], parse: (row: Record<string, unknown>) => T | null): RowSet<T> {
  const out: T[] = []
  let skipped = 0
  for (const row of rows) {
    if (typeof row !== 'object' || row === null) {
      skipped++
      continue
    }
    const parsed = parse(row as Record<string, unknown>)
    if (parsed === null) {
      skipped++
      continue
    }
    out.push(parsed)
  }
  return { rows: out, skipped }
}

/**
 * The single-row form of the same policy. There are no siblings to save here, so
 * an unreadable sole row is still an error — reporting it as `null` would say
 * "there is no listing" when the truth is "there is one and this app could not
 * read it", and those two lead a caller somewhere different.
 */
function parseOne<T>(
  rows: unknown[],
  parse: (row: Record<string, unknown>) => T | null,
): T | null | SupabaseError {
  const parsed = parseRows(rows, parse)
  if (parsed.rows.length > 0) return parsed.rows[0]
  return parsed.skipped > 0 ? fail('malformed', MALFORMED) : null
}

/**
 * PostgREST caps a response at `max_rows` (1000, in supabase/config.toml), and a
 * capped response looks exactly like a complete one — it is a short array, not an
 * error. Two of the reads below are over collections that legitimately exceed
 * that, so they page until a page comes back short.
 *
 * `MAX_PAGES` is a stop rather than a limit: without it a server that ignored
 * `offset` would loop forever, and an infinite loop inside a render path is a
 * frozen tab rather than a missing row. Ten pages is 10,000 rows, well past the
 * 5,000-serial collection.
 */
const PAGE_SIZE = 1000
const MAX_PAGES = 10

async function selectAllPages<T>(
  table: string,
  query: string,
  parse: (row: Record<string, unknown>) => T | null,
): Promise<RowSet<T> | SupabaseError> {
  const out: T[] = []
  let skipped = 0
  for (let page = 0; page < MAX_PAGES; page++) {
    const rows = await select(table, `${query}&limit=${PAGE_SIZE}&offset=${page * PAGE_SIZE}`)
    // A failure part-way through is still a failure. Returning the pages that did
    // arrive would hand a caller a partial ownership graph that looks whole.
    if (isSupabaseError(rows)) return rows
    const parsed = parseRows(rows, parse)
    out.push(...parsed.rows)
    skipped += parsed.skipped
    if (rows.length < PAGE_SIZE) break
  }
  return { rows: out, skipped }
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

/**
 * Clamps a row limit into something PostgREST will accept.
 *
 * Takes `unknown` rather than `number` on purpose. The type says `number` at
 * every call site below, and yet this helper once received a TanStack
 * QueryFunctionContext — a read was passed directly as a `queryFn` — which made
 * `Math.floor` yield NaN and shipped `limit=NaN` to PostgREST, which answers 400.
 * A limit is a URL fragment, so a value that is not a finite number must fall
 * back to a working default rather than be interpolated: the request is either
 * well-formed or it is not made.
 */
function bounded(limit: unknown, fallback: number): number {
  const wanted = typeof limit === 'number' && Number.isFinite(limit) ? Math.floor(limit) : fallback
  // Matches the PostgREST max_rows cap in supabase/config.toml; asking for more
  // silently returns fewer, which is a confusing way to lose data.
  return Math.max(1, Math.min(wanted, 1000))
}

/**
 * Ordered by `recorded_at`, not by `slot`.
 *
 * Every trade is simulated and `trades_origin_matches_evidence` forces `slot`
 * null on a simulated row, so `order=slot.desc` was sorting the table by a column
 * that is null in every single row — an arbitrary order presented as "most
 * recent". `recorded_at` is not null, has its own index, and is the only thing
 * this table knows about when a sale happened.
 */
export async function fetchRecentTrades(limit = 50): Promise<RowSet<TradeRow> | SupabaseError> {
  const rows = await select('trades', `select=*&order=recorded_at.desc&limit=${bounded(limit, 50)}`)
  return isSupabaseError(rows) ? rows : parseRows(rows, parseTrade)
}

export async function fetchRecentMints(limit = 50): Promise<RowSet<MintRow> | SupabaseError> {
  const rows = await select('mints', `select=*&order=slot.desc&limit=${bounded(limit, 50)}`)
  return isSupabaseError(rows) ? rows : parseRows(rows, parseMint)
}

/**
 * The accrual side of the treasury. Returned as rows rather than a server-side
 * SUM on purpose: PostgREST would serialise an aggregate as a JSON number, and a
 * lifetime fee total in raw units passes 2^53 long before it stops mattering.
 * Sum these with BigInt at the call site.
 *
 * This is the read that `RowSet.skipped` exists for: a dropped row here is a fee
 * missing from a total, so a caller presenting the sum as complete has to check
 * that it is.
 */
export async function fetchFeeLedger(limit = 200): Promise<RowSet<FeeLedgerRow> | SupabaseError> {
  const rows = await select('fee_ledger', `select=*&order=slot.desc&limit=${bounded(limit, 200)}`)
  return isSupabaseError(rows) ? rows : parseRows(rows, parseFeeLedger)
}

export function sumFees(rows: readonly FeeLedgerRow[], source?: FeeSource): bigint {
  let total = 0n
  for (const row of rows) {
    if (source === undefined || row.source === source) total += row.amount
  }
  return total
}

export async function fetchActiveListings(limit = 200): Promise<RowSet<ListingRow> | SupabaseError> {
  const rows = await select(
    'listings',
    `select=*&status=eq.active&order=updated_at.desc&limit=${bounded(limit, 200)}`,
  )
  return isSupabaseError(rows) ? rows : parseRows(rows, parseListing)
}

export async function fetchListing(nftMint: string): Promise<ListingRow | null | SupabaseError> {
  const rows = await select('listings', `select=*&nft_mint=eq.${encodeURIComponent(nftMint)}&limit=1`)
  return isSupabaseError(rows) ? rows : parseOne(rows, parseListing)
}

export async function fetchXployeesByOwner(owner: string): Promise<RowSet<XployeeRow> | SupabaseError> {
  const rows = await select('xployees', `select=*&owner=eq.${encodeURIComponent(owner)}&order=id.asc&limit=1000`)
  return isSupabaseError(rows) ? rows : parseRows(rows, parseXployee)
}

export async function fetchWallet(address: string): Promise<WalletRow | null | SupabaseError> {
  const rows = await select('wallets', `select=*&address=eq.${encodeURIComponent(address)}&limit=1`)
  return isSupabaseError(rows) ? rows : parseOne(rows, parseWallet)
}

/**
 * Payout history, readable by anyone: every row here describes a token transfer
 * already visible on any explorer, so the policy publishes it rather than gating
 * it behind a session this app cannot mint.
 *
 * Ordered by `requested_at`, which is not null on every row — unlike
 * `confirmed_at`, which is null on everything still in flight.
 *
 * Like every read here it RESOLVES to a SupabaseError on failure, so it must be
 * unwrapped before use and must never be handed to a `queryFn` — see the
 * corollary to rule 4 at the top of this file.
 */
export async function fetchPayouts(limit = 50): Promise<RowSet<PayoutRow> | SupabaseError> {
  const rows = await select('payouts', `select=*&order=requested_at.desc&limit=${bounded(limit, 50)}`)
  return isSupabaseError(rows) ? rows : parseRows(rows, parsePayout)
}

// ---------------------------------------------------------------------------
// The identity, social and payout-queue tables
// ---------------------------------------------------------------------------
//
// Everything below was added when the client stopped generating this data in the
// browser. Two things about it are deliberate and easy to undo by accident:
//
//   1. EVERY read names its columns. Not `select=*`. `public.profiles` is
//      published to anon through a COLUMN-level grant that withholds
//      `auth_user_id` and `twitter_user_id`, and `select=*` expands to every
//      column in the table — including the two the grant refuses — which is a
//      permission error on the whole read rather than a narrower row. Naming
//      columns is also what stops a future migration adding a column and silently
//      widening what this browser downloads.
//   2. Nullability is copied from the DDL, not from what a happy row happens to
//      contain. The rule at the top of this file was learned from three reads that
//      returned `malformed` forever; these tables have far more nullable columns
//      than the originals — `responded_at`, `read_at`, `expires_at`, `paid_at`,
//      every operator field — and modelling any of them as required would repeat
//      it exactly.

export interface ProfileRow {
  wallet: string
  /** User-typed nickname. Null on a profile created by a wallet link before anything was typed. */
  handle: string | null
  bio: string | null
  avatarXployeeId: number | null
  /**
   * VERIFIED ONLY, and null until a wallet is linked. `profiles_twitter_is_verified`
   * makes a handle without a provider id, a timestamp and an auth user
   * unrepresentable, so a non-null value here is a handle X confirmed — never one
   * somebody typed.
   */
  twitterHandle: string | null
  twitterVerifiedAt: number | null
  createdAt: number | null
  updatedAt: number | null
}

export interface FriendEdgeRow {
  wallet: string
  friend: string
  since: number | null
}

export type FriendRequestStatus = 'pending' | 'accepted' | 'declined' | 'withdrawn'

export interface FriendRequestRow {
  id: string
  requester: string
  addressee: string
  status: FriendRequestStatus
  message: string | null
  createdAt: number | null
  /** Null exactly while the request is pending — the schema constrains the pair. */
  respondedAt: number | null
}

export interface ThreadRow {
  id: string
  participantA: string
  participantB: string
  createdAt: number | null
  /** Null on a thread whose first message has not landed. Sorting must tolerate it. */
  lastMessageAt: number | null
  messageCount: number
}

export interface MessageRow {
  id: string
  threadId: string
  sender: string
  body: string
  sentAt: number | null
  /** Set when the RECIPIENT read it. Null is the unread state, not a missing value. */
  readAt: number | null
}

export type TradeOfferStatus = 'pending' | 'accepted' | 'declined' | 'withdrawn' | 'expired'

export interface TradeOfferRow {
  id: string
  sender: string
  recipient: string
  note: string | null
  status: TradeOfferStatus
  /**
   * Two non-negative amounts rather than one signed one, matching the schema.
   * `trade_offers_one_direction_of_cash` makes both-at-once unrepresentable, so
   * the direction of the sweetener is which of these is non-zero.
   */
  sweetenerFromSender: bigint
  sweetenerFromRecipient: bigint
  createdAt: number | null
  expiresAt: number | null
  respondedAt: number | null
}

export interface TradeOfferLegRow {
  offerId: string
  xployeeId: number
  side: 'offered' | 'requested'
}

export type PayoutRequestStatus = 'pending' | 'approved' | 'paid' | 'rejected' | 'cancelled'

export interface PayoutRequestRow {
  /** The claim id a human reads out. It is the primary key; there is no second identity. */
  claimId: string
  wallet: string
  /** Display notional in exact decimal. Gates nothing. */
  amountUsd: number
  /** The money column, raw lamports. */
  amountLamports: bigint
  solUsdAtRequest: number | null
  status: PayoutRequestStatus
  /** All four null until an operator records a transfer they made by hand. */
  signature: string | null
  paidLamports: bigint | null
  operatorNote: string | null
  paidAt: number | null
  requestedAt: number
  reviewedAt: number | null
  updatedAt: number | null
}

function parseProfile(row: Record<string, unknown>): ProfileRow | null {
  const wallet = text(row.wallet)
  if (!wallet) return null
  return {
    wallet,
    handle: text(row.handle),
    bio: text(row.bio),
    avatarXployeeId: integer(row.avatar_xployee_id),
    twitterHandle: text(row.twitter_handle),
    twitterVerifiedAt: timestamp(row.twitter_verified_at),
    createdAt: timestamp(row.created_at),
    updatedAt: timestamp(row.updated_at),
  }
}

function parseFriendEdge(row: Record<string, unknown>): FriendEdgeRow | null {
  const wallet = text(row.wallet)
  const friend = text(row.friend)
  if (!wallet || !friend) return null
  return { wallet, friend, since: timestamp(row.since) }
}

const FRIEND_REQUEST_STATUSES: ReadonlySet<string> = new Set(['pending', 'accepted', 'declined', 'withdrawn'])

function parseFriendRequest(row: Record<string, unknown>): FriendRequestRow | null {
  const id = text(row.id)
  const requester = text(row.requester)
  const addressee = text(row.addressee)
  const status = text(row.status)
  if (!id || !requester || !addressee || !status) return null
  if (!FRIEND_REQUEST_STATUSES.has(status)) return null
  return {
    id,
    requester,
    addressee,
    status: status as FriendRequestStatus,
    message: text(row.message),
    createdAt: timestamp(row.created_at),
    respondedAt: timestamp(row.responded_at),
  }
}

function parseThread(row: Record<string, unknown>): ThreadRow | null {
  const id = text(row.id)
  const participantA = text(row.participant_a)
  const participantB = text(row.participant_b)
  if (!id || !participantA || !participantB) return null
  return {
    id,
    participantA,
    participantB,
    createdAt: timestamp(row.created_at),
    lastMessageAt: timestamp(row.last_message_at),
    // `not null default 0` in the schema, but a count is not an identity: a row
    // whose counter is unreadable is still a renderable thread.
    messageCount: integer(row.message_count) ?? 0,
  }
}

function parseMessage(row: Record<string, unknown>): MessageRow | null {
  const id = text(row.id)
  const threadId = text(row.thread_id)
  const sender = text(row.sender)
  const body = text(row.body)
  if (!id || !threadId || !sender || !body) return null
  return { id, threadId, sender, body, sentAt: timestamp(row.sent_at), readAt: timestamp(row.read_at) }
}

const OFFER_STATUSES: ReadonlySet<string> = new Set([
  'pending', 'accepted', 'declined', 'withdrawn', 'expired',
])

function parseTradeOffer(row: Record<string, unknown>): TradeOfferRow | null {
  const id = text(row.id)
  const sender = text(row.sender)
  const recipient = text(row.recipient)
  const status = text(row.status)
  if (!id || !sender || !recipient || !status) return null
  if (!OFFER_STATUSES.has(status)) return null
  // Both columns are NOT NULL with a '0' default, so an unreadable one is a defect
  // rather than a state — and a sweetener that silently became zero is a price
  // quietly removed from an offer.
  const fromSender = rawUnits(row.sweetener_from_sender)
  const fromRecipient = rawUnits(row.sweetener_from_recipient)
  if (fromSender === null || fromRecipient === null) return null
  return {
    id,
    sender,
    recipient,
    note: text(row.note),
    status: status as TradeOfferStatus,
    sweetenerFromSender: fromSender,
    sweetenerFromRecipient: fromRecipient,
    createdAt: timestamp(row.created_at),
    expiresAt: timestamp(row.expires_at),
    respondedAt: timestamp(row.responded_at),
  }
}

function parseTradeOfferLeg(row: Record<string, unknown>): TradeOfferLegRow | null {
  const offerId = text(row.offer_id)
  const xployeeId = integer(row.xployee_id)
  const side = text(row.side)
  if (!offerId || xployeeId === null) return null
  if (side !== 'offered' && side !== 'requested') return null
  return { offerId, xployeeId, side }
}

const PAYOUT_REQUEST_STATUSES: ReadonlySet<string> = new Set([
  'pending', 'approved', 'paid', 'rejected', 'cancelled',
])

function parsePayoutRequest(row: Record<string, unknown>): PayoutRequestRow | null {
  const amountLamports = rawUnits(row.amount_lamports)
  const paidLamports = optionalRawUnits(row.paid_lamports)
  if (amountLamports === null || paidLamports === 'invalid') return null

  const claimId = text(row.claim_id)
  const wallet = text(row.wallet)
  const status = text(row.status)
  const amountUsd = decimal(row.amount_usd)
  const requestedAt = timestamp(row.requested_at)
  if (!claimId || !wallet || !status || amountUsd === null || requestedAt === null) return null
  if (!PAYOUT_REQUEST_STATUSES.has(status)) return null

  return {
    claimId,
    wallet,
    amountUsd,
    amountLamports,
    solUsdAtRequest: decimal(row.sol_usd_at_request),
    status: status as PayoutRequestStatus,
    signature: text(row.signature),
    paidLamports,
    operatorNote: text(row.operator_note),
    paidAt: timestamp(row.paid_at),
    requestedAt,
    reviewedAt: timestamp(row.reviewed_at),
    updatedAt: timestamp(row.updated_at),
  }
}

/**
 * PostgREST's `in.(…)` list, escaped.
 *
 * Base58 addresses and uuids contain nothing that needs quoting, but a value that
 * reached here from a row rather than from a constant is a value this module did
 * not choose, and an unescaped comma inside one silently splits a filter into two.
 */
function inList(values: readonly string[]): string {
  return `(${values.map((v) => `"${encodeURIComponent(v).replace(/"/g, '%22')}"`).join(',')})`
}

/** Column lists, named once so a read and its parser cannot drift apart. */
const PROFILE_COLUMNS = 'wallet,handle,bio,avatar_xployee_id,twitter_handle,twitter_verified_at,created_at,updated_at'
const FRIEND_REQUEST_COLUMNS = 'id,requester,addressee,status,message,created_at,responded_at'
const THREAD_COLUMNS = 'id,participant_a,participant_b,created_at,last_message_at,message_count'
const MESSAGE_COLUMNS = 'id,thread_id,sender,body,sent_at,read_at'
const TRADE_OFFER_COLUMNS =
  'id,sender,recipient,note,status,sweetener_from_sender,sweetener_from_recipient,created_at,expires_at,responded_at'
// ---------------------------------------------------------------------------
// Protocol config — the runtime replacement for the VITE_ deployment constants
// ---------------------------------------------------------------------------

export interface ProtocolConfigRow {
  xnftMint: string
  devWallet: string
  treasuryWallet: string
  /** Browser RPC endpoint. Empty means "use the public one". */
  rpcUrl: string
  pumpFunUrl: string
  dexscreenerUrl: string
  supportHandle: string
  mintingEnabled: boolean
  updatedAt: number
}

/**
 * The single config row.
 *
 * Returns null for every failure — unreachable, unreadable, missing row, wrong
 * shape — rather than a partial object, because a caller that receives half a
 * config will happily arm a mint with half a config. `lib/runtimeConfig` turns
 * that null into a disarmed snapshot.
 *
 * Every field is coerced to a string with no fallback to some other source. A
 * blank column means blank, which means "not configured", which means refuse.
 */
export async function fetchProtocolConfig(): Promise<ProtocolConfigRow | null> {
  // `*`, and the ONLY place in this file that does not name its columns.
  //
  // PostgREST 400s the whole request when a select names a column the table does
  // not have. With columns named, adding one to this table — `rpc_url` was the
  // first — meant a frontend deployed before its migration could not read ANY of
  // its config: no mint address, no project wallet, no market links, minting
  // disarmed. A purely additive column would have taken the site's entire
  // configuration down, in an ordering nobody would think to check.
  //
  // The usual objection to `*` does not apply here. This is one row of values
  // that are public by definition, with a read-only anon policy, and the parse
  // below still names every field it uses — an unknown column is ignored, and a
  // missing one coerces to '' and reads as "not configured", which is exactly
  // what it is.
  const rows = await select('protocol_config', 'select=*&id=eq.1&limit=1')
  if (isSupabaseError(rows)) return null

  const row = rows[0] as Record<string, unknown> | undefined
  if (!row || typeof row !== 'object') return null

  return {
    xnftMint: text(row.xnft_mint) ?? '',
    devWallet: text(row.dev_wallet) ?? '',
    treasuryWallet: text(row.treasury_wallet) ?? '',
    rpcUrl: text(row.rpc_url) ?? '',
    pumpFunUrl: text(row.pump_fun_url) ?? '',
    dexscreenerUrl: text(row.dexscreener_url) ?? '',
    supportHandle: text(row.support_handle) ?? '',
    // Defaults to FALSE on anything unparseable. An unreadable switch is an off
    // switch — the opposite default would arm a mint on a malformed response.
    mintingEnabled: row.minting_enabled === true,
    updatedAt: Date.parse(String(row.updated_at ?? '')) || 0,
  }
}

const PAYOUT_REQUEST_COLUMNS =
  'claim_id,wallet,amount_usd,amount_lamports,sol_usd_at_request,status,signature,paid_lamports,operator_note,requested_at,reviewed_at,paid_at,updated_at'

export async function fetchProfile(wallet: string): Promise<ProfileRow | null | SupabaseError> {
  const rows = await select('profiles', `select=${PROFILE_COLUMNS}&wallet=eq.${encodeURIComponent(wallet)}&limit=1`)
  return isSupabaseError(rows) ? rows : parseOne(rows, parseProfile)
}

/**
 * Profiles for a set of wallets, in one request rather than one per wallet.
 *
 * An empty input returns an empty set WITHOUT issuing a request: PostgREST reads
 * `in.()` as a syntax error, and a directory page with nothing on it should not be
 * able to produce a 400.
 */
export async function fetchProfiles(wallets: readonly string[]): Promise<RowSet<ProfileRow> | SupabaseError> {
  if (wallets.length === 0) return { rows: [], skipped: 0 }
  const rows = await select(
    'profiles',
    `select=${PROFILE_COLUMNS}&wallet=in.${inList(wallets)}&limit=${bounded(wallets.length, 1000)}`,
  )
  return isSupabaseError(rows) ? rows : parseRows(rows, parseProfile)
}

/**
 * The public wallet directory. Read as pages because `public.wallets` holds the
 * whole xNET — 97 seeded wallets plus everyone who has ever linked one — and
 * PostgREST caps a single response at `max_rows`.
 */
export async function fetchWallets(): Promise<RowSet<WalletRow> | SupabaseError> {
  return await selectAllPages('wallets', 'select=address,handle,bio,twitter&order=address.asc', parseWallet)
}

/**
 * Every xployee that belongs to somebody.
 *
 * `owner=not.is.null` rather than the whole table: the collection is 5,000 rows
 * and only the hired ones have an owner, so this is the ownership graph rather
 * than a download of the catalogue. Identity — tier, skills, traits — is still
 * rebuilt in the browser from the serial, which is what keeps this read small.
 */
export async function fetchOwnedXployees(): Promise<RowSet<XployeeRow> | SupabaseError> {
  return await selectAllPages(
    'xployees',
    'select=id,owner,tier,skills,principal,apy,hired_at,nft_mint,mint_signature&owner=not.is.null&order=id.asc',
    parseXployee,
  )
}

/** Both directions of the friendship graph for one wallet, from the `friend_edges` view. */
export async function fetchFriends(wallet: string): Promise<RowSet<FriendEdgeRow> | SupabaseError> {
  const rows = await select(
    'friend_edges',
    `select=wallet,friend,since&wallet=eq.${encodeURIComponent(wallet)}&order=since.desc&limit=1000`,
  )
  return isSupabaseError(rows) ? rows : parseRows(rows, parseFriendEdge)
}

/**
 * The visitor's friend requests, both directions and every status.
 *
 * No wallet filter, and that is not an oversight: `friend_requests` is granted to
 * `authenticated` only and its policy already restricts the rows to the session's
 * own wallet. Adding `requester=eq.…` here would let a caller ask about somebody
 * else and receive an empty list — which reads as "they have no requests" rather
 * than "you cannot see them". The policy is the filter.
 */
export async function fetchFriendRequests(limit = 200): Promise<RowSet<FriendRequestRow> | SupabaseError> {
  const rows = await select(
    'friend_requests',
    `select=${FRIEND_REQUEST_COLUMNS}&order=created_at.desc&limit=${bounded(limit, 200)}`,
  )
  return isSupabaseError(rows) ? rows : parseRows(rows, parseFriendRequest)
}

/** Ordered `nullslast`, because a thread with no message yet has a null `last_message_at`. */
export async function fetchThreads(limit = 100): Promise<RowSet<ThreadRow> | SupabaseError> {
  const rows = await select(
    'threads',
    `select=${THREAD_COLUMNS}&order=last_message_at.desc.nullslast&limit=${bounded(limit, 100)}`,
  )
  return isSupabaseError(rows) ? rows : parseRows(rows, parseThread)
}

export async function fetchMessages(
  threadIds: readonly string[],
  limit = 500,
): Promise<RowSet<MessageRow> | SupabaseError> {
  if (threadIds.length === 0) return { rows: [], skipped: 0 }
  const rows = await select(
    'messages',
    `select=${MESSAGE_COLUMNS}&thread_id=in.${inList(threadIds)}&order=sent_at.desc&limit=${bounded(limit, 500)}`,
  )
  return isSupabaseError(rows) ? rows : parseRows(rows, parseMessage)
}

/** Same reasoning as `fetchFriendRequests`: the RLS policy is the participant filter. */
export async function fetchTradeOffers(limit = 200): Promise<RowSet<TradeOfferRow> | SupabaseError> {
  const rows = await select(
    'trade_offers',
    `select=${TRADE_OFFER_COLUMNS}&order=created_at.desc&limit=${bounded(limit, 200)}`,
  )
  return isSupabaseError(rows) ? rows : parseRows(rows, parseTradeOffer)
}

export async function fetchTradeOfferLegs(
  offerIds: readonly string[],
): Promise<RowSet<TradeOfferLegRow> | SupabaseError> {
  if (offerIds.length === 0) return { rows: [], skipped: 0 }
  const rows = await select(
    'trade_offer_legs',
    `select=offer_id,xployee_id,side&offer_id=in.${inList(offerIds)}&limit=1000`,
  )
  return isSupabaseError(rows) ? rows : parseRows(rows, parseTradeOfferLeg)
}

/**
 * A wallet's SOL claim queue.
 *
 * The wallet filter IS meaningful here, unlike on the correspondence tables: the
 * policy publishes every `paid` request to anon, so an unfiltered read would
 * return the whole protocol's settled history rather than this wallet's queue.
 */
export async function fetchPayoutRequests(
  wallet: string,
  limit = 100,
): Promise<RowSet<PayoutRequestRow> | SupabaseError> {
  const rows = await select(
    'payout_requests',
    `select=${PAYOUT_REQUEST_COLUMNS}&wallet=eq.${encodeURIComponent(wallet)}&order=requested_at.desc&limit=${bounded(limit, 100)}`,
  )
  return isSupabaseError(rows) ? rows : parseRows(rows, parsePayoutRequest)
}

/**
 * Every wallet's queue, oldest first — the operator's view.
 *
 * Ascending, unlike the per-wallet read above, and that inversion is the point.
 * A requester wants their newest claim at the top; an operator wants the one
 * that has been waiting longest, because that is the one closest to breaking the
 * three-hour promise the claim modal makes.
 *
 * Reads the same public table with the same anon key. That is not an oversight:
 * a payout is a SOL transfer between two addresses, so the queue is only ever
 * assembling facts the chain publishes anyway, and gating it in Postgres while
 * it is legible on any explorer would be theatre. Nothing here can WRITE.
 */
export async function fetchAllPayoutRequests(
  limit = 200,
): Promise<RowSet<PayoutRequestRow> | SupabaseError> {
  const rows = await select(
    'payout_requests',
    `select=${PAYOUT_REQUEST_COLUMNS}&order=requested_at.asc&limit=${bounded(limit, 500)}`,
  )
  return isSupabaseError(rows) ? rows : parseRows(rows, parsePayoutRequest)
}

/**
 * Record that the operator settled a request by hand.
 *
 * Goes through the Edge Function rather than PostgREST because this is a write,
 * and the anon key writes nothing — the service role lives server-side and the
 * function is what holds it. The signature is the evidence; an amount without
 * one is an assertion, and the schema will not promote a row to `paid` without
 * a signature to check it against.
 */
export async function settlePayoutRequest(input: {
  claimId: string
  signature: string
  paidLamports: bigint
  operatorNote?: string
}): Promise<unknown | SupabaseError> {
  return invoke('settle-payout-request', {
    claim_id: input.claimId,
    signature: input.signature,
    paid_lamports: input.paidLamports.toString(),
    operator_note: input.operatorNote ?? null,
  })
}

// ---------------------------------------------------------------------------
// Edge Functions
// ---------------------------------------------------------------------------

async function invoke<T>(fn: string, body: Record<string, unknown>): Promise<T | SupabaseError> {
  if (!isSupabaseConfigured()) return fail('not-configured', NOT_CONFIGURED)

  let response: Response
  try {
    response = await fetch(`${SUPABASE_URL}/functions/v1/${fn}`, {
      method: 'POST',
      headers: { ...authHeaders(), 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
  } catch (e) {
    const detail = e instanceof Error ? e.message : 'unknown error'
    return fail('network', `Could not reach ${fn}: ${detail}`)
  }

  let parsed: unknown
  try {
    parsed = await response.json()
  } catch {
    return fail('malformed', `${fn} returned an unreadable response.`)
  }

  if (!response.ok) {
    const error = (parsed as { error?: { message?: unknown } } | null)?.error
    const message = typeof error?.message === 'string' ? error.message : `${fn} failed.`
    return fail('http', message, response.status)
  }

  return parsed as T
}

export interface IngestResult {
  ok: true
  signature: string
  status: 'indexed' | 'duplicate'
  slot?: number
  blockTime?: string | null
  events: { kind: 'mint' | 'sale' | 'rent' | 'payout'; outcome: 'inserted' | 'duplicate' | 'ignored' }[]
}

/**
 * Hands a signature to the indexer. Posting the same one twice is a no-op, so
 * this is safe to call optimistically after a send and again on a retry.
 *
 * Note what is *not* sent: no amount, no price, no fee. The function re-reads the
 * transaction from RPC and writes from its own decoding, so there is nothing the
 * caller could lie about even if it wanted to.
 *
 * NOT for payouts. This function indexes mints, sales and rentals; it writes no
 * `payouts` row, so a claim posted here is accepted, indexed as nothing, and
 * lost — which is exactly what happened until the Payouts desk was rewired to
 * `recordPayoutSignature` below. A payout has to be recorded with its amount
 * before the chain has settled it; that is a different call.
 */
export async function ingestSignature(signature: string): Promise<IngestResult | SupabaseError> {
  return await invoke<IngestResult>('ingest-signature', { signature })
}

// There is no client for `request-payout`'s `build` action, and there should not
// be one. It composed an instruction for a program that was abandoned before it
// was deployed; a claim is now two ordinary SPL accounts and a transferChecked,
// built locally by buildClaimTransaction() in ./spl. Asking a server to compose a
// transfer this client can compose itself only adds a party that could compose a
// different one. The `record` action below is still needed — it writes a row this
// browser cannot write.

export interface RecordedPayout {
  ok: true
  action: 'record'
  payout: Record<string, unknown>
  amountVerified: false
}

/**
 * Writes the pending payout row. Call this the instant the wallet returns a
 * signature — the transaction genuinely is unconfirmed at that moment, and the
 * row is the honest record of that.
 *
 * The destination is not a parameter and must not become one. The function
 * resolves it server-side, so a browser cannot write an audit row naming a
 * destination the transfer did not use. `amount` is sent because nothing else
 * knows it yet: the transaction has not landed, so there is nothing to read it
 * from. `confirm-payout` replaces it with the settled figure and only then sets
 * `amountVerified`.
 */
export async function recordPayoutSignature(
  signature: string,
  amount: bigint,
): Promise<RecordedPayout | SupabaseError> {
  return await invoke<RecordedPayout>('request-payout', {
    action: 'record',
    signature,
    amount: amount.toString(),
  })
}

export interface ConfirmResult {
  ok: true
  checked: number
  confirmed: number
  failed: number
  stillPending: number
  settlements: { signature: string; resolution: PayoutStatus; note?: string }[]
}

/**
 * Polls a pending payout and settles it. A row that comes back `pending` has not
 * failed — the chain has not answered yet, and the caller must not offer a retry
 * that would produce a second claim. Also runs on a schedule server-side, so not
 * calling this at all is safe; it just settles later.
 */
export async function confirmPayout(signature?: string): Promise<ConfirmResult | SupabaseError> {
  return await invoke<ConfirmResult>('confirm-payout', signature ? { signature } : {})
}

// ---------------------------------------------------------------------------
// The writes a session performs
// ---------------------------------------------------------------------------
//
// Every one of these posts to an Edge Function, and none of them names a wallet.
// The functions resolve the acting wallet from the bearer token through
// `public.actor_wallet`, so there is no request shape that acts as somebody else —
// the same discipline as "destinations read from configuration, never caller
// parameters", applied to identity.
//
// A refusal from the database ("you are already friends", "that offer is not
// open") arrives as a non-2xx carrying its sentence, which `invoke` turns into an
// `http` SupabaseError. That is an outcome the UI renders, not an exception.

/** Sends a request without a session, so it can only ever fail. Called out rather than left to a 401. */
const NOT_SIGNED_IN =
  'This action needs a signed-in session. Sign in with X and link a wallet first; nothing was written.'

async function invokeAsUser<T>(fn: string, body: Record<string, unknown>): Promise<T | SupabaseError> {
  if (!isSupabaseConfigured()) return fail('not-configured', NOT_CONFIGURED)
  // Checked here rather than discovered as a 401, because the two lead a user
  // somewhere different: one is "sign in", the other is "something is broken".
  if (sessionToken() === null) return fail('http', NOT_SIGNED_IN, 401)
  return await invoke<T>(fn, body)
}

export interface SocialWriteResult {
  ok: true
  action: string
  result?: Record<string, unknown>
}

/**
 * The whole social write surface: friend requests and their answers, unfriending,
 * messages, read receipts, trade offers and their answers.
 *
 * ACCEPTING AN OFFER MOVES NOTHING. The Edge Function says so on every acceptance
 * (`settled: false`) because there is no escrow anywhere in this protocol — an
 * offer that reassigned xployees would be a settlement layer hidden inside a
 * messaging table. A caller must not render an acceptance as a transfer.
 */
export async function postSocial(
  body: Record<string, unknown>,
): Promise<SocialWriteResult | SupabaseError> {
  return await invokeAsUser<SocialWriteResult>('social', body)
}

export interface ProfileWriteResult {
  ok: true
  wallet: string
  handle: string | null
}

/**
 * Handle, bio and avatar. THERE IS NO X HANDLE PARAMETER, and adding one would be
 * refused: the function rejects a body carrying `twitter` rather than ignoring it,
 * because silently dropping the field leaves a caller believing it can set one.
 * A verified handle reaches a profile down exactly one path — `linkWallet` below,
 * after X has confirmed the account.
 */
export async function saveRemoteProfile(input: {
  handle: string | null
  bio: string | null
  avatarXployeeId: number | null
}): Promise<ProfileWriteResult | SupabaseError> {
  return await invokeAsUser<ProfileWriteResult>('profile', {
    handle: input.handle,
    bio: input.bio,
    avatarXployeeId: input.avatarXployeeId,
  })
}

export interface LinkChallenge {
  ok: true
  action: 'challenge'
  nonce: string
  /** Signed byte for byte. Returned rather than described so the two sides cannot disagree about a template. */
  statement: string
  expiresInSeconds: number
}

export interface LinkResult {
  ok: true
  action: 'verify' | 'unlink'
  wallet: string
  twitterHandle?: string
}

/**
 * Step one of proving that an X account and a Solana wallet are the same person.
 * Returns the exact text the wallet must sign, carrying a nonce THIS SERVER
 * issued — a signature over a client-chosen message is a signature that could have
 * been collected somewhere else and replayed here.
 */
export async function requestLinkChallenge(wallet: string): Promise<LinkChallenge | SupabaseError> {
  return await invokeAsUser<LinkChallenge>('link-wallet', { action: 'challenge', wallet })
}

/** Step two. The challenge is single-use and is consumed in the same transaction that writes the link. */
export async function completeLinkWallet(input: {
  wallet: string
  nonce: string
  signature: string
}): Promise<LinkResult | SupabaseError> {
  return await invokeAsUser<LinkResult>('link-wallet', { action: 'verify', ...input })
}

export async function unlinkWallet(): Promise<LinkResult | SupabaseError> {
  return await invokeAsUser<LinkResult>('link-wallet', { action: 'unlink' })
}

export interface MintReservation {
  ok: true
  action: 'reserve'
  wallet: string
  /** True when a live reservation was handed back. A retry must not consume a second serial. */
  reused: boolean
  reservation: Record<string, unknown> | null
  poolRemaining: number | null
}

/**
 * Takes the mint budget and holds a serial, BEFORE anything is burned.
 *
 * The ordering is the point. A limit checked when a burn is indexed is checked
 * after the tokens are already gone — it cannot prevent a bulk mint, only decide
 * whether to hand over an xployee for money that has already been destroyed. So
 * the reservation comes first and `ingest-signature` redeems it.
 *
 * Releasing a reservation does NOT refund the budget, so a client must not
 * reserve speculatively: reserve when the user is about to sign.
 */
export async function reserveMint(): Promise<MintReservation | SupabaseError> {
  return await invokeAsUser<MintReservation>('mint-reserve', { action: 'reserve' })
}

export async function releaseMintReservation(reservationId: string): Promise<unknown | SupabaseError> {
  return await invokeAsUser<unknown>('mint-reserve', { action: 'release', reservationId })
}

export interface PayoutRequestResult {
  ok: true
  action: 'request'
  /** 'duplicate' when the same claim id was already queued — a retried post finds its own ticket. */
  outcome: 'queued' | 'duplicate'
  claimId: string
  amountUsd: number
  amountLamports: string | null
}

/**
 * Opens a SOL claim ticket.
 *
 * The amount comes from the browser because accrual is computed there, and the
 * database does not trust it — `request_payout` recomputes the wallet's maximum
 * possible accrual from principal x apy x tenure and refuses anything above it.
 * The claim id is generated by `newClaimId()` in ./earnings, which is also what
 * makes a retry idempotent.
 */
export async function postPayoutRequest(input: {
  claimId: string
  amountUsd: number
  solUsd: number
}): Promise<PayoutRequestResult | SupabaseError> {
  return await invokeAsUser<PayoutRequestResult>('payout-request', { action: 'request', ...input })
}

export async function cancelPayoutRequest(claimId: string): Promise<unknown | SupabaseError> {
  return await invokeAsUser<unknown>('payout-request', { action: 'cancel', claimId })
}
