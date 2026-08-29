// Skills are the yield engine. Each one works a desk tied to an xStock.
// Rarity (tier) decides how many an xployee carries; this registry decides
// what each one is worth.
import type { Rng } from './rng'
import { pickDistinct, randInt } from './rng'

export interface Skill {
  id: string
  /** Job title, shown on the xployee sheet. */
  label: string
  /** The desk worked. */
  desk: string
  /** xStock symbol this skill accrues into. */
  ticker: string
  /** Base annual yield rate, 0–1. */
  baseApy: number
  /**
   * Draw weight. High-APY skills are weighted scarce so that a 4-skill
   * X-RATED holding two of them is genuinely rare — and priced that way.
   */
  weight: number
}

export const SKILLS: readonly Skill[] = [
  { id: 'silicon',   label: 'Silicon Analyst',  desk: 'Semis',          ticker: 'NVDAx', baseApy: 0.092, weight: 5 },
  { id: 'platform',  label: 'Platform Ops',     desk: 'Megacap Tech',   ticker: 'AAPLx', baseApy: 0.074, weight: 8 },
  { id: 'cloud',     label: 'Cloud Architect',  desk: 'Enterprise SW',  ticker: 'MSFTx', baseApy: 0.071, weight: 8 },
  { id: 'ledger',    label: 'Ledger Clerk',     desk: 'Financials',     ticker: 'JPMx',  baseApy: 0.063, weight: 10 },
  { id: 'rails',     label: 'Card Rails',       desk: 'Payments',       ticker: 'Vx',    baseApy: 0.058, weight: 10 },
  { id: 'crude',     label: 'Crude Desk',       desk: 'Energy',         ticker: 'XOMx',  baseApy: 0.081, weight: 6 },
  { id: 'grid',      label: 'Grid Tech',        desk: 'Industrials',    ticker: 'HONx',  baseApy: 0.052, weight: 11 },
  { id: 'trial',     label: 'Trial Nurse',      desk: 'Pharma',         ticker: 'LLYx',  baseApy: 0.067, weight: 9 },
  { id: 'claims',    label: 'Claims Adjuster',  desk: 'Health Ins.',    ticker: 'UNHx',  baseApy: 0.059, weight: 10 },
  { id: 'shelf',     label: 'Shelf Stocker',    desk: 'Staples',        ticker: 'KOx',   baseApy: 0.044, weight: 13 },
  { id: 'brand',     label: 'Brand Manager',    desk: 'Consumer',       ticker: 'PGx',   baseApy: 0.046, weight: 12 },
  { id: 'ballast',   label: 'Index Ballast',    desk: 'Broad Market',   ticker: 'SPYx',  baseApy: 0.040, weight: 14 },
  { id: 'bills',     label: 'Bills Desk',       desk: 'T-Bills',        ticker: 'TBLLx', baseApy: 0.048, weight: 12 },
  { id: 'vault',     label: 'Vault Keeper',     desk: 'Gold',           ticker: 'GLDx',  baseApy: 0.032, weight: 11 },
  { id: 'teller',    label: 'Chain Teller',     desk: 'Crypto Equity',  ticker: 'COINx', baseApy: 0.126, weight: 3 },
  { id: 'degen',     label: 'Treasury Degen',   desk: 'Crypto Proxy',   ticker: 'MSTRx', baseApy: 0.141, weight: 2 },
] as const

const BY_ID = new Map(SKILLS.map((s) => [s.id, s]))

export function getSkill(id: string): Skill {
  const skill = BY_ID.get(id)
  if (!skill) throw new Error(`unknown skill: ${id}`)
  return skill
}

/** A skill as held by one xployee, with its individual proficiency roll. */
export interface HeldSkill {
  skill: Skill
  /** 0.6–1.0. Scales the skill's effective yield. */
  proficiency: number
}

export function effectiveApy(held: HeldSkill): number {
  return held.skill.baseApy * held.proficiency
}

/**
 * Draw `count` distinct skills, weighted toward the common ones, each with a
 * proficiency roll.
 */
export function rollSkills(rng: Rng, count: number): HeldSkill[] {
  const drawn = pickDistinct(rng, SKILLS, count, (s) => s.weight)
  return drawn.map((skill) => ({
    skill,
    proficiency: randInt(rng, 60, 100) / 100,
  }))
}

/**
 * An xployee's blended APY: the mean of its skills' effective rates.
 *
 * Deliberately a mean and not a sum — more skills means more desks and more
 * diversification, not a flat multiple of the yield. Scarcity still pays,
 * because rare high-APY skills lift the average.
 */
export function blendedApy(held: readonly HeldSkill[]): number {
  if (held.length === 0) return 0
  return held.reduce((sum, h) => sum + effectiveApy(h), 0) / held.length
}
