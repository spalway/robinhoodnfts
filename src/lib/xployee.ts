// seed -> xployee. The single source of identity for every unit in the
// collection. Pure and deterministic: same id, same worker, forever.
import { fakeAddress, randInt, rngFrom, pick } from './rng'
import { tierForId, type Tier } from './tiers'
import { rollSkills, blendedApy, type HeldSkill } from './skills'

export const MAX_SUPPLY = 5000

/** Visual traits, independent of tier — silhouette diversity. */
export interface Traits {
  uniform: string
  head: string
  face: string
  accessory: string
}

export const UNIFORMS = ['Coverall', 'Suit', 'Vest', 'Polo', 'Apron', 'Lab Coat', 'Hoodie', 'Overcoat'] as const
export const HEADS = ['Crop', 'Sweep', 'Bald', 'Bun', 'Mohawk', 'Cap', 'Helmet', 'Curls', 'Bowl', 'Tie-back'] as const
export const FACES = ['Neutral', 'Focused', 'Weary', 'Smirk', 'Grin', 'Scowl', 'Blank', 'Squint'] as const
export const ACCESSORIES = ['None', 'None', 'Glasses', 'Headset', 'Visor', 'Earpiece', 'Badge', 'Lanyard', 'Cigar', 'Shades'] as const

export interface Xployee {
  /** 0-indexed serial. */
  id: number
  /** Deterministic pseudo-address. Never a real key. */
  mint: string
  tier: Tier
  skills: HeldSkill[]
  traits: Traits
  /** ms epoch. When this worker was hired. */
  hiredAt: number
  /** Blended annual rate across its skills. */
  apy: number
  /** Capital deployed at hire, in USD. */
  principal: number
}

/** Hire price scales with tier — more skills, more capital deployed. */
export function principalFor(tier: Tier): number {
  return 1000 * tier.skills
}

// THESE TWO STRINGS ARE SEEDS, NOT COPY. `xployee:` and `xployee` feed
// fakeAddress and rngFrom, so they decide every mint address, every trait and
// every APY in the collection — and the same values are committed as 12,900
// rows of seed SQL. Renaming them to match the brand silently regenerated the
// entire collection and put the browser out of step with the database; only
// supabase/seed.test.ts caught it. Leave them alone.
export function buildXployee(id: number, hiredAt: number): Xployee {
  const mint = fakeAddress(`xployee:${id}`)
  const rng = rngFrom('xployee', String(id))

  // Tier is read off the serial, not rolled. The collection is laid out
  // rarest-first, so identity and rarity are the same fact and an xployee's
  // number is enough to know what it is.
  const tier = tierForId(id, MAX_SUPPLY)
  const skills = rollSkills(rng, tier.skills)

  const traits: Traits = {
    uniform: pick(rng, UNIFORMS),
    head: pick(rng, HEADS),
    face: pick(rng, FACES),
    accessory: pick(rng, ACCESSORIES),
  }

  return {
    id,
    mint,
    tier,
    skills,
    traits,
    hiredAt,
    apy: blendedApy(skills),
    principal: principalFor(tier),
  }
}

/** Short display form: #0042 */
export function serial(id: number): string {
  return `#${String(id).padStart(4, '0')}`
}

/** Deterministic per-xployee jitter, for anything cosmetic that needs variety. */
export function jitter(id: number, key: string, min: number, max: number): number {
  return randInt(rngFrom('jitter', key, String(id)), min, max)
}
