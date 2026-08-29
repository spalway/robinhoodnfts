// The parsers in ./supabase against the schema in supabase/migrations.
//
// WHAT THESE TESTS ARE FOR. Three of the reads in that module returned
// `malformed` permanently — not on an edge case, on every row, from the first
// one — because each parser demanded a column the schema deliberately leaves
// null: `payouts.amount` (null until confirm-payout reads the settled transfer
// off the chain), `mints.xployee_id` (null on every genuine mint, because two
// token transfers carry no room to name an xployee) and `trades.signature` /
// `trades.slot` (FORCED null on every simulated sale by
// `trades_origin_matches_evidence`). An all-or-nothing result set then turned
// each of those into a blank page rather than a missing row.
//
// So the fixture rows below are not "unusual input". Each one is the row the
// database actually writes, copied from the migration that defines it, and the
// point of the file is that a future edit to a parser cannot quietly become
// stricter than the column it reads without a test going red.
//
// Everything goes through the real `select` and the real query strings — nothing
// reaches into a parser directly — so these also pin the two orderings that were
// sorting by a column that is null in every row.
import { afterEach, describe, expect, it, vi } from 'vitest'
import type * as SupabaseModule from './supabase'

const URL = 'https://index.test.supabase.co'
const KEY = 'anon-key-public-by-design'

/** Base58-shaped, because the columns are domains with a regex on them. */
const SIG = '5'.repeat(88)
const ADDR = 'AaBbCcDdEeFfGgHhJjKkLlMmNnPpQqRrSsTtUuVvWwXx'
const MINT = 'BbCcDdEeFfGgHhJjKkLlMmNnPpQqRrSsTtUuVvWwXxYy'

/** Every fetch this module makes, in order, so a test can assert the query it sent. */
let calls: string[] = []

/**
 * Imports ./supabase fresh with the env set and `fetch` answering with `body`.
 *
 * Fresh because SUPABASE_URL and SUPABASE_ANON_KEY are read once at module scope
 * — that is what makes `isSupabaseConfigured()` a compile-time-ish gate rather
 * than a per-call check — so stubbing has to happen before the import.
 */
async function load(body: unknown, ok = true, status = 200): Promise<typeof SupabaseModule> {
  calls = []
  vi.resetModules()
  vi.stubEnv('VITE_SUPABASE_URL', URL)
  vi.stubEnv('VITE_SUPABASE_ANON_KEY', KEY)
  vi.stubGlobal('fetch', (input: string) => {
    calls.push(String(input))
    return Promise.resolve({ ok, status, json: () => Promise.resolve(body) } as Response)
  })
  return await import('./supabase')
}

afterEach(() => {
  vi.unstubAllEnvs()
  vi.unstubAllGlobals()
})

/* ---- Fixtures: the rows the schema actually writes ----------------------- */

/** A simulated sale, which is the only kind `record_simulated_sale` can write. */
function tradeRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: '3f1a2b3c-0000-4000-8000-000000000001',
    sale_ref: 'sale-1',
    xployee_id: 42,
    nft_mint: MINT,
    buyer: ADDR,
    seller: MINT,
    gross: '1000000000',
    fee: '50000000',
    net_to_seller: '950000000',
    origin: 'simulated',
    // Both forced null by trades_origin_matches_evidence on a simulated row.
    signature: null,
    slot: null,
    block_time: null,
    recorded_at: '2026-08-05T12:00:00Z',
    ...overrides,
  }
}

/** A chain-verified mint. `xployee_id` is null on every one of them. */
function mintRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    signature: SIG,
    event_index: 0,
    buyer: ADDR,
    burned: '10000000000000',
    fee: '500000000000',
    xployee_id: null,
    slot: 300_000_000,
    block_time: '2026-08-05T12:00:00Z',
    origin: 'chain',
    ...overrides,
  }
}

function feeRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    signature: SIG,
    source: 'mint',
    event_index: 0,
    payer: ADDR,
    amount: '500000000000',
    slot: 300_000_000,
    block_time: '2026-08-05T12:00:00Z',
    origin: 'chain',
    ...overrides,
  }
}

/** A payout the instant `record_payout_pending` wrote it: no verified amount. */
function pendingPayout(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: '3f1a2b3c-0000-4000-8000-000000000002',
    amount: null,
    claimed_amount_unverified: '250000000000',
    amount_verified: false,
    destination: ADDR,
    status: 'pending',
    signature: SIG,
    expires_at_block_height: 300_000_100,
    failure_reason: null,
    requested_at: '2026-08-05T12:00:00Z',
    last_checked_at: null,
    confirmed_at: null,
    ...overrides,
  }
}

function listingRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    nft_mint: MINT,
    xployee_id: 7,
    seller: ADDR,
    kind: 'rent',
    price: null,
    fee_per_epoch: '1000000000',
    term_epochs: 4,
    status: 'active',
    listing_pda: null,
    created_at: '2026-08-05T12:00:00Z',
    updated_at: '2026-08-05T12:00:00Z',
    ...overrides,
  }
}

/**
 * Asserts a read succeeded and narrows away the error arm.
 *
 * The union is written `T | SupabaseError` rather than with a `code` shape so
 * TypeScript subtracts the error constituent and infers T as the RowSet — which
 * is also the check that these functions really do resolve their failures rather
 * than rejecting, since a rejection would never reach this line.
 */
function unwrap<T>(value: T | SupabaseModule.SupabaseError): T {
  if (typeof value === 'object' && value !== null && 'code' in value && 'message' in value) {
    throw new Error(`expected rows, got error: ${String(value.message)}`)
  }
  return value as T
}

/* ---- The nullability contract, column by column -------------------------- */

describe('the parsers accept exactly what the schema writes', () => {
  it('parses a pending payout whose amount is null — the row every claim starts as', async () => {
    const lib = await load([pendingPayout()])
    const result = unwrap(await lib.fetchPayouts())

    expect(result.skipped).toBe(0)
    expect(result.rows).toHaveLength(1)
    // The defect: `amount` was parsed with the strict money helper, so this row —
    // the only shape a payout has before it settles — failed, and the all-or-
    // nothing result set discarded the entire history along with it.
    expect(result.rows[0].amount).toBeNull()
    expect(result.rows[0].amountVerified).toBe(false)
    // The client's assertion is readable, and separately, so a UI can show what
    // was asked for without any chance of it being read as what was paid.
    expect(result.rows[0].claimedAmount).toBe(250_000_000_000n)
    expect(result.rows[0].status).toBe('pending')
  })

  it('parses a settled payout, where the amount is the chain reading', async () => {
    const lib = await load([
      pendingPayout({
        amount: '250000000000',
        amount_verified: true,
        status: 'confirmed',
        confirmed_at: '2026-08-05T12:01:00Z',
      }),
    ])
    const [row] = unwrap(await lib.fetchPayouts()).rows

    expect(row.amount).toBe(250_000_000_000n)
    expect(row.amountVerified).toBe(true)
    expect(row.confirmedAt).toBe(Date.parse('2026-08-05T12:01:00Z'))
  })

  it('parses a failed payout, which keeps amount null forever', async () => {
    const lib = await load([
      pendingPayout({
        status: 'failed',
        failure_reason: 'Blockhash expired without the transaction landing.',
        confirmed_at: '2026-08-05T12:05:00Z',
      }),
    ])
    const [row] = unwrap(await lib.fetchPayouts()).rows

    expect(row.amount).toBeNull()
    expect(row.amountVerified).toBe(false)
    expect(row.failureReason).toContain('Blockhash expired')
  })

  it('parses a payout posted without any claimed amount', async () => {
    // `claimedAmount` is optional on request-payout: a caller that omits it just
    // has no assertion on record. Both money columns null is a legal row.
    const lib = await load([pendingPayout({ claimed_amount_unverified: null })])
    const [row] = unwrap(await lib.fetchPayouts()).rows

    expect(row.amount).toBeNull()
    expect(row.claimedAmount).toBeNull()
  })

  it('parses a mint with a null xployee_id — which is every mint', async () => {
    const lib = await load([mintRow()])
    const result = unwrap(await lib.fetchRecentMints())

    expect(result.skipped).toBe(0)
    expect(result.rows[0].xployeeId).toBeNull()
    expect(result.rows[0].burned).toBe(10_000_000_000_000n)
    expect(result.rows[0].fee).toBe(500_000_000_000n)
    // Part of the primary key with `signature`: two mints batched into one
    // transaction are two rows sharing a signature, and only this tells them apart.
    expect(result.rows[0].eventIndex).toBe(0)
  })

  it('parses a simulated trade, whose signature and slot the schema forces null', async () => {
    const lib = await load([tradeRow()])
    const result = unwrap(await lib.fetchRecentTrades())

    expect(result.skipped).toBe(0)
    expect(result.rows[0].signature).toBeNull()
    expect(result.rows[0].slot).toBeNull()
    expect(result.rows[0].origin).toBe('simulated')
    // The row still has an identity — its own uuid — which is why it can be keyed
    // in a list without a signature.
    expect(result.rows[0].id).toBe('3f1a2b3c-0000-4000-8000-000000000001')
    expect(result.rows[0].xployeeId).toBe(42)
  })

  it('parses a chain-backed trade too, for the day escrow exists', async () => {
    const lib = await load([tradeRow({ origin: 'chain', signature: SIG, slot: 42 })])
    const [row] = unwrap(await lib.fetchRecentTrades()).rows

    expect(row.origin).toBe('chain')
    expect(row.signature).toBe(SIG)
    expect(row.slot).toBe(42)
  })

  it('parses a listing with every nullable column empty', async () => {
    const lib = await load([
      listingRow({ price: null, fee_per_epoch: null, term_epochs: null, listing_pda: null, updated_at: null }),
    ])
    const result = unwrap(await lib.fetchActiveListings())

    expect(result.skipped).toBe(0)
    expect(result.rows[0].price).toBeNull()
    expect(result.rows[0].feePerEpoch).toBeNull()
    expect(result.rows[0].listingPda).toBeNull()
    expect(result.rows[0].xployeeId).toBe(7)
  })

  it('parses an xployee that is nothing but an id', async () => {
    // record_simulated_sale upserts `(id, owner)` and nothing else, so a row with
    // every generated attribute still null is a row this schema writes.
    const lib = await load([{ id: 5, owner: null, tier: null, skills: null, traits: null, principal: null, apy: null, hired_at: null, mint_signature: null, nft_mint: null }])
    const result = unwrap(await lib.fetchXployeesByOwner(ADDR))

    expect(result.skipped).toBe(0)
    expect(result.rows[0].id).toBe(5)
    expect(result.rows[0].owner).toBeNull()
  })

  it('parses a fee ledger row of each source the check constraint allows', async () => {
    const lib = await load([feeRow({ source: 'mint' }), feeRow({ source: 'rent', event_index: 1 })])
    const result = unwrap(await lib.fetchFeeLedger())

    expect(result.rows.map((r) => r.source)).toEqual(['mint', 'rent'])
    expect(lib.sumFees(result.rows)).toBe(1_000_000_000_000n)
    expect(lib.sumFees(result.rows, 'rent')).toBe(500_000_000_000n)
  })
})

/* ---- The other direction: a parser must not get looser either ------------ */

describe('a row the schema could not have written is still refused', () => {
  it('refuses a money column that is present and unreadable', async () => {
    // Nullable is not the same as anything-goes. `optionalRawUnits` draws the line
    // at absent-versus-garbage: a float would already have been through a double.
    const lib = await load([pendingPayout({ amount: '1.5' })])
    const result = unwrap(await lib.fetchPayouts())

    expect(result.rows).toHaveLength(0)
    expect(result.skipped).toBe(1)
  })

  it('refuses a fee source outside the check constraint', async () => {
    // 'sale' is the one that matters: a simulated sale accrues no real fee, so a
    // fee_ledger row claiming one would break reconciliation against the treasury.
    const lib = await load([feeRow({ source: 'sale' })])
    expect(unwrap(await lib.fetchFeeLedger()).skipped).toBe(1)
  })

  it('refuses a row missing a NOT NULL identity column', async () => {
    // `id` is the only identity a simulated trade has, since its signature is
    // null by constraint. A row without one cannot be keyed, so it is not a row.
    const lib = await load([tradeRow(), tradeRow({ id: null })])
    const result = unwrap(await lib.fetchRecentTrades())

    expect(result.rows).toHaveLength(1)
    expect(result.skipped).toBe(1)
  })

  it('refuses a status or kind outside its enumeration', async () => {
    const lib = await load([listingRow({ status: 'expired' })])
    expect(unwrap(await lib.fetchActiveListings()).skipped).toBe(1)
  })
})

/* ---- One bad row is one bad row ----------------------------------------- */

describe('a row-level failure does not discard its siblings', () => {
  it('keeps the readable rows and reports how many it dropped', async () => {
    const lib = await load([pendingPayout(), { id: 'nonsense' }, pendingPayout({ id: 'other', signature: '4'.repeat(88) })])
    const result = unwrap(await lib.fetchPayouts())

    // The old policy returned a `malformed` error here and the page rendered
    // nothing at all. Two good rows are two good rows.
    expect(result.rows).toHaveLength(2)
    expect(result.skipped).toBe(1)
  })

  it('reports the drop rather than hiding it, so a money total can decline to be exact', async () => {
    const lib = await load([feeRow(), { amount: 'not a number' }])
    const result = unwrap(await lib.fetchFeeLedger())

    expect(lib.sumFees(result.rows)).toBe(500_000_000_000n)
    // The caller summing this can see the sum is short. Silently dropping the row
    // would have understated the treasury's accrual with no way to notice.
    expect(result.skipped).toBe(1)
  })

  it('survives a non-object in the array', async () => {
    const lib = await load([mintRow(), null, 7, 'row'])
    const result = unwrap(await lib.fetchRecentMints())

    expect(result.rows).toHaveLength(1)
    expect(result.skipped).toBe(3)
  })

  it('still errors when a single-row read cannot read its single row', async () => {
    // Nothing to save here, and "there is no listing" and "there is one this app
    // cannot read" send a caller in opposite directions.
    const lib = await load([listingRow({ kind: 'barter' })])
    const result = await lib.fetchListing(MINT)

    expect(lib.isSupabaseError(result)).toBe(true)
  })

  it('returns null — not an error — when a single-row read finds nothing', async () => {
    const lib = await load([])
    expect(await lib.fetchWallet(ADDR)).toBeNull()
  })
})

/* ---- Ordering: never sort by a column that is null on every row ---------- */

describe('every read orders by a column its rows actually have', () => {
  it('orders trades by recorded_at, because slot is null on every simulated row', async () => {
    const lib = await load([tradeRow()])
    await lib.fetchRecentTrades()

    expect(calls[0]).toContain('order=recorded_at.desc')
    expect(calls[0]).not.toContain('order=slot.desc')
  })

  it('orders payouts by requested_at, which is not null even while pending', async () => {
    const lib = await load([pendingPayout()])
    await lib.fetchPayouts()

    expect(calls[0]).toContain('order=requested_at.desc')
    expect(calls[0]).not.toContain('confirmed_at')
  })

  it('orders mints and the fee ledger by slot, which is not null on a chain row', async () => {
    const lib = await load([mintRow()])
    await lib.fetchRecentMints()
    await lib.fetchFeeLedger()

    expect(calls[0]).toContain('order=slot.desc')
    expect(calls[1]).toContain('order=slot.desc')
  })
})

/* ---- The contract that has not changed ---------------------------------- */

describe('failures still resolve rather than throw', () => {
  it('resolves a typed error on a non-2xx instead of rejecting', async () => {
    const lib = await load([], false, 503)
    const result = await lib.fetchPayouts()

    expect(lib.isSupabaseError(result)).toBe(true)
    expect(lib.isSupabaseError(result) && result.code).toBe('http')
    expect(lib.isSupabaseError(result) && result.status).toBe(503)
  })

  it('makes no request at all when the project is not configured', async () => {
    calls = []
    vi.resetModules()
    vi.stubEnv('VITE_SUPABASE_URL', '')
    vi.stubEnv('VITE_SUPABASE_ANON_KEY', '')
    vi.stubGlobal('fetch', (input: string) => {
      calls.push(String(input))
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve([]) } as Response)
    })
    const lib = await import('./supabase')

    const result = await lib.fetchPayouts()
    expect(lib.isSupabaseError(result) && result.code).toBe('not-configured')
    expect(calls).toEqual([])
  })
})
