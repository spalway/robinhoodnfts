// What exists on chain at launch, and what the art looks like.
//
// Two separate ideas live here and must not be confused:
//
//   collection()  — xployees that are OWNED. At launch this is exactly one.
//   showcase()    — xployees rendered as ART so the landing page can show the
//                   range. Unminted, unowned, counted in nothing.
//
// Identity is a pure function of the serial (see xployee.ts), so a serial can be
// drawn without being owned. That is what lets the showcase exist without
// inventing a holder for it.
import { buildXployee, MAX_SUPPLY, type Xployee } from './xployee'
import { GENESIS, epochAt } from './accrual'
import { rngFrom } from './rng'
import { TIERS, tierForId, tierRange, type TierId } from './tiers'

/**
 * The project wallet's one holding: #0000.
 *
 * Rarity is positional, so serial 0 is the first X-RATED in the collection —
 * see tierForId. One holding is the whole shipped state: a protocol on its
 * first day has no history, and every previous version of this file invented
 * one (512 xployees over 97 fabricated wallets, then 35 over one). Real holders
 * appear as they mint.
 */
export const GENESIS_SERIAL = 0

export const HIRED_COUNT = 1

/**
 * Reveal order — a seeded permutation of every serial in the supply.
 *
 * This exists because rarity is positional (tiers.ts/tierForId): #0000–#0149
 * are X-RATED. Handing serials out in ascending order would therefore mean the
 * first 150 mints take every X-RATED in existence and every mint after #2000 is
 * uncommon forever — the mint would stop being a lottery and become a queue
 * position. Drawing the next serial from a shuffle restores the lottery while
 * keeping the low numbers genuinely rare.
 *
 * Seeded and cached, so the same permutation regenerates on every machine with
 * no database — the same property the rest of the collection relies on.
 */
let order: number[] | null = null

export function mintOrder(): readonly number[] {
  if (order) return order
  const rng = rngFrom('mintorder')
  const a = Array.from({ length: MAX_SUPPLY }, (_, i) => i)
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1))
    const tmp = a[i]
    a[i] = a[j]
    a[j] = tmp
  }
  order = a
  return order
}

/**
 * Serials already spoken for, which the mint must skip.
 *
 * Only the project wallet's holding. Showcase serials are deliberately NOT in
 * here: they are pictures of what the art can look like, not reservations, and
 * burning six serials on decoration would be a real cost for a cosmetic reason.
 * A minter can and should be able to draw one.
 */
const TAKEN: ReadonlySet<number> = new Set([GENESIS_SERIAL])

export function takenSerials(): ReadonlySet<number> {
  return TAKEN
}

/** The serial the Nth mint receives, skipping anything already held. */
export function serialForMint(position: number): number {
  const o = mintOrder()
  const taken = takenSerials()
  let seen = -1
  for (let i = 0; i < o.length; i++) {
    if (taken.has(o[i])) continue
    seen++
    if (seen === position) return o[i]
  }
  // Every serial is spoken for. Wrap rather than return undefined; a collection
  // this size will not reach it, and a wrong number beats a crash.
  return o[((position % MAX_SUPPLY) + MAX_SUPPLY) % MAX_SUPPLY]
}

let cache: Xployee[] | null = null

/**
 * Everything owned at launch.
 *
 * Hired at GENESIS, which is now the launch date rather than a backdated one —
 * so this worker opens with zero accrued yield and earns from day one like any
 * other. A fixed timestamp rather than Date.now() keeps it identical on every
 * machine and lets the SQL seed carry the same number.
 */
export function collection(): Xployee[] {
  if (!cache) cache = [buildXployee(GENESIS_SERIAL, GENESIS)]
  return cache
}

// ---------------------------------------------------------------------------
// showcase
// ---------------------------------------------------------------------------

/** How many of each tier the landing page shows off. Rarest first. */
const SHOWCASE_MIX: { tier: TierId; count: number }[] = [
  { tier: 'xrated', count: 2 },
  { tier: 'expert', count: 2 },
  { tier: 'mid', count: 2 },
  { tier: 'entry', count: 2 },
]

export const SHOWCASE_COUNT = SHOWCASE_MIX.reduce((n, m) => n + m.count, 0)

/**
 * How unlike everything already chosen a candidate is.
 *
 * Four independent trait slots decide the silhouette, and a shuffle alone will
 * happily hand back two workers in the same uniform with the same head — which
 * on a page whose whole job is "look how varied these are" is the one outcome
 * that must not happen. So candidates are scored against the running selection
 * and the least similar wins.
 *
 * Higher is better. Ties break on the earlier reveal position, so the result is
 * deterministic.
 */
function distinctness(candidate: Xployee, chosen: readonly Xployee[]): number {
  let worst = Infinity
  for (const other of chosen) {
    let shared = 0
    if (candidate.traits.uniform === other.traits.uniform) shared++
    if (candidate.traits.head === other.traits.head) shared++
    if (candidate.traits.face === other.traits.face) shared++
    if (candidate.traits.accessory === other.traits.accessory) shared++
    worst = Math.min(worst, 4 - shared)
  }
  return worst
}

/**
 * How deep into the reveal order to look for each tier's showcase picks.
 *
 * Bounded because the walk is over 5,000 serials and every candidate is built
 * to read its traits. A few hundred candidates per tier is far more than enough
 * variety and keeps this a cheap module-load.
 */
const SHOWCASE_POOL = 400

let showcaseCache: Xployee[] | null = null

/**
 * A few unowned xployees, spanning every rarity, chosen to look unlike each
 * other.
 *
 * These are NOT minted, NOT owned and NOT counted in any statistic. They exist
 * so a launch-day landing page can show what the collection looks like without
 * the protocol pretending anyone has bought one.
 *
 * Serials come off the reveal permutation, so these are numbers a real mint
 * could genuinely draw rather than hand-picked favourites — and the project
 * wallet's own holding is excluded so the page never shows it twice.
 */
export function showcase(): Xployee[] {
  if (showcaseCache) return showcaseCache

  const byTier = new Map<TierId, Xployee[]>()
  for (const m of SHOWCASE_MIX) byTier.set(m.tier, [])

  for (const serial of mintOrder()) {
    if (serial === GENESIS_SERIAL) continue
    const tier = tierForId(serial, MAX_SUPPLY).id
    const pool = byTier.get(tier)
    if (!pool || pool.length >= SHOWCASE_POOL) continue
    pool.push(buildXployee(serial, GENESIS))
    if ([...byTier.values()].every((p) => p.length >= SHOWCASE_POOL)) break
  }

  const picked: Xployee[] = []
  for (const m of SHOWCASE_MIX) {
    const pool = byTier.get(m.tier) ?? []
    for (let n = 0; n < m.count; n++) {
      let best: Xployee | null = null
      let bestScore = -Infinity
      for (const candidate of pool) {
        if (picked.includes(candidate)) continue
        const score = distinctness(candidate, picked)
        if (score > bestScore) {
          bestScore = score
          best = candidate
        }
      }
      if (best) picked.push(best)
    }
  }

  showcaseCache = picked
  return picked
}

// ---------------------------------------------------------------------------
// lookups and aggregates
// ---------------------------------------------------------------------------

/**
 * The xployee with this serial, owned or not.
 *
 * Identity is a pure function of the serial, so this resolves anything inside
 * the supply — which is what lets a showcase card link to a detail sheet for a
 * worker nobody has minted. Ownership is a separate question and is answered by
 * `collection()` and by the caller's own holdings; the sheet already
 * distinguishes them.
 */
export function byId(id: number): Xployee | undefined {
  if (!Number.isInteger(id) || id < 0 || id >= MAX_SUPPLY) return undefined
  if (id === GENESIS_SERIAL) return collection()[0]
  return buildXployee(id, GENESIS)
}

/**
 * Whether anybody holds this serial.
 *
 * The detail sheet renders for any serial in the supply, so it has to be able
 * to say which it is looking at. An unminted worker has no book: it has never
 * been hired, so nothing has accrued and there is nothing to claim. Presenting
 * one with a book value and a ticking balance would be inventing a position.
 *
 * Only the protocol's own view. A visitor's local hires are theirs and the
 * sheet checks those separately.
 */
export function isMinted(id: number): boolean {
  return TAKEN.has(id)
}

/** Newest hires first. */
export function recentHires(count: number): Xployee[] {
  return [...collection()].sort((a, b) => b.hiredAt - a.hiredAt).slice(0, count)
}

export function tierCounts(): Record<TierId, number> {
  const counts = { entry: 0, mid: 0, expert: 0, xrated: 0 } as Record<TierId, number>
  for (const x of collection()) counts[x.tier.id]++
  return counts
}

/** Aggregate principal deployed across every desk, by ticker. */
export function deskExposure(): { ticker: string; principal: number; workers: number }[] {
  const map = new Map<string, { principal: number; workers: number }>()
  for (const x of collection()) {
    const share = x.principal / x.skills.length
    for (const held of x.skills) {
      const row = map.get(held.skill.ticker) ?? { principal: 0, workers: 0 }
      row.principal += share
      row.workers += 1
      map.set(held.skill.ticker, row)
    }
  }
  return [...map.entries()]
    .map(([ticker, v]) => ({ ticker, ...v }))
    .sort((a, b) => b.principal - a.principal)
}

export function totalPrincipal(): number {
  return collection().reduce((sum, x) => sum + x.principal, 0)
}

export const SUPPLY = { hired: HIRED_COUNT, max: MAX_SUPPLY }

export function currentEpoch(now: number): number {
  return epochAt(now)
}

/**
 * What the supply is laid out to be — not what has been minted.
 *
 * This used to report the composition of the seeded crew, which at a supply of
 * one says "100% X-RATED" and is true but useless. Before anything is minted
 * the honest and interesting number is the plan: how many of each rarity exist
 * to be drawn, and which serial band each occupies.
 */
export function tierDistribution() {
  const counts = tierCounts()
  return TIERS.map((tier) => {
    // From tierRange, not `supply * MAX_SUPPLY`: the last band absorbs the
    // rounding so the four counts sum to exactly MAX_SUPPLY. Multiplying the
    // shares independently does not, and a supply table that does not add up
    // is the first thing a reader checks.
    const band = tierRange(tier.id, MAX_SUPPLY)
    const supply = band.end - band.start
    return {
      tier,
      /** Owned right now. */
      count: counts[tier.id],
      /** Total that will ever exist at this rarity. */
      supply,
      /** Serial band, inclusive of start, exclusive of end. */
      band,
      share: supply / MAX_SUPPLY,
    }
  })
}
