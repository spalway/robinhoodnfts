// Rarity is skill count. Tier drives the badge treatment, the background layer,
// and every price in the marketplace.

export type TierId = 'entry' | 'mid' | 'expert' | 'xrated'

export interface Tier {
  id: TierId
  /** Display name, always uppercase in UI. */
  label: string
  /** Number of skills an xployee of this tier carries. */
  skills: number
  /** Share of supply, 0–1. Must sum to 1 across all tiers. */
  supply: number
  /** Rarity colour. Applied to the badge *type*, not a filled block. */
  color: string
  /** Deeper shade — background solids, bar segments. */
  shade: string
  /** Lighter shade — hover states, glow falloff. */
  light: string
  effect: 'none' | 'glow' | 'laser'
}

export const TIERS: readonly Tier[] = [
  {
    id: 'entry',
    label: 'UNCOMMON',
    skills: 1,
    supply: 0.6,
    // Light, bland green — the quiet tier, and it should look it. The graphic
    // value is deliberately low-contrast; the readable values live in shade
    // (white plates) and .tier-entry (type).
    color: '#93b083',
    shade: '#456338',
    light: '#bcd0b1',
    effect: 'none',
  },
  {
    id: 'mid',
    label: 'RARE',
    skills: 2,
    supply: 0.25,
    color: '#1D84DE',
    shade: '#145e9e',
    light: '#63aeeb',
    effect: 'none',
  },
  {
    id: 'expert',
    label: 'EPIC',
    skills: 3,
    supply: 0.12,
    // Neon magenta chosen to stay legible as type on a white ground.
    color: '#D211B0',
    shade: '#8d0b76',
    light: '#f45ad6',
    effect: 'glow',
  },
  {
    id: 'xrated',
    label: 'X-RATED',
    skills: 4,
    supply: 0.03,
    // Laser red. The shine sweep uses --laser-shine below.
    color: '#FF1B1B',
    shade: '#830404',
    light: '#ff7a6b',
    effect: 'laser',
  },
] as const

const BY_ID = new Map(TIERS.map((t) => [t.id, t]))

export function getTier(id: TierId): Tier {
  const tier = BY_ID.get(id)
  if (!tier) throw new Error(`unknown tier: ${id}`)
  return tier
}

/** Rarest first. This ordering IS the serial layout — see tierForId. */
const RARITY_ORDER: readonly TierId[] = ['xrated', 'expert', 'mid', 'entry']

/**
 * Rarity is positional: the collection is laid out rarest-first, so a serial is
 * itself a rarity claim. At a 5,000 supply that puts X-RATED at #0000–#0149,
 * EPIC at #0150–#0749, RARE at #0750–#1999, and UNCOMMON across the rest.
 *
 * The boundaries are derived from each tier's `supply` share rather than
 * written out as literals, so editing a share in TIERS moves the bands with it
 * and the two can never silently disagree. Rounding is absorbed by the final
 * band, which is why the loop lets the last tier run to `maxSupply` instead of
 * computing its own end — otherwise a share table that rounds down leaves a gap
 * of unassigned serials, and a gap here is an xployee that cannot exist.
 */
export function tierForId(id: number, maxSupply: number): Tier {
  let start = 0
  for (let i = 0; i < RARITY_ORDER.length; i++) {
    const tier = getTier(RARITY_ORDER[i])
    const last = i === RARITY_ORDER.length - 1
    const end = last ? maxSupply : start + Math.round(tier.supply * maxSupply)
    if (id < end) return tier
    start = end
  }
  return getTier('entry')
}

/** First serial belonging to `tier`, for the supply table on the token page. */
export function tierRange(tierId: TierId, maxSupply: number): { start: number; end: number } {
  let start = 0
  for (let i = 0; i < RARITY_ORDER.length; i++) {
    const tier = getTier(RARITY_ORDER[i])
    const last = i === RARITY_ORDER.length - 1
    const end = last ? maxSupply : start + Math.round(tier.supply * maxSupply)
    if (RARITY_ORDER[i] === tierId) return { start, end }
    start = end
  }
  return { start: 0, end: 0 }
}

/** Ascending rarity, for sorting and for the distribution bar. */
export const TIER_ORDER: readonly TierId[] = ['entry', 'mid', 'expert', 'xrated']

export function tierRank(id: TierId): number {
  return TIER_ORDER.indexOf(id)
}
