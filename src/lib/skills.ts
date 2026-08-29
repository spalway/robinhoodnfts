// Skills are the yield engine. Each one works a desk tied to a Robinhood Stock
// Token. Rarity (tier) decides how many an xployee carries; this registry
// decides what each one is worth.
//
// ===========================================================================
// WHAT IS LOAD-BEARING IN THE ARRAY BELOW, AND WHAT IS NOT
// ===========================================================================
// `rollSkills` draws through `pickDistinct`, which walks THIS ARRAY IN THIS
// ORDER and selects by `weight`. So the array's order, its length, each `id`
// and each `weight` are part of the collection's identity: they decide which
// desks every one of 5,000 xployees carries, and the same draws are committed
// as seed rows. Reordering the array or touching a weight regenerates the
// collection and puts the browser out of step with the database.
//
// `ticker`, `desk` and `label` are NOT part of that. They are what a desk is
// called and which token it tracks — display, resolved at render time. Six of
// them changed when the roster moved from Backed's xStocks to Robinhood's own
// tokens (see the table in stocks.ts) and not one draw moved with them.
//
// `baseApy` sits in between: it changes no draw, but it does change every
// figure the sheet quotes. Left alone.
import type { Rng } from './rng'
import { pickDistinct, randInt } from './rng'

export interface Skill {
  id: string
  /** Job title, shown on the xployee sheet. */
  label: string
  /** The desk worked. */
  desk: string
  /** Robinhood Stock Token symbol this skill accrues into. */
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
  { id: 'silicon',   label: 'Silicon Analyst',  desk: 'Semis',          ticker: 'NVDA', baseApy: 0.092, weight: 5 },
  { id: 'platform',  label: 'Platform Ops',     desk: 'Megacap Tech',   ticker: 'AAPL', baseApy: 0.074, weight: 8 },
  { id: 'cloud',     label: 'Cloud Architect',  desk: 'Enterprise SW',  ticker: 'MSFT', baseApy: 0.071, weight: 8 },
  { id: 'ledger',    label: 'Ledger Clerk',     desk: 'Fintech',        ticker: 'SOFI', baseApy: 0.063, weight: 10 },
  { id: 'rails',     label: 'Card Rails',       desk: 'Payments',       ticker: 'FISV', baseApy: 0.058, weight: 10 },
  { id: 'crude',     label: 'Crude Desk',       desk: 'Energy',         ticker: 'XOM',  baseApy: 0.081, weight: 6 },
  { id: 'grid',      label: 'Grid Tech',        desk: 'Industrials',    ticker: 'GE',   baseApy: 0.052, weight: 11 },
  { id: 'trial',     label: 'Trial Nurse',      desk: 'Pharma',         ticker: 'LLY',  baseApy: 0.067, weight: 9 },
  { id: 'claims',    label: 'Claims Adjuster',  desk: 'Health Ins.',    ticker: 'UNH',  baseApy: 0.059, weight: 10 },
  { id: 'shelf',     label: 'Shelf Stocker',    desk: 'Staples',        ticker: 'COST', baseApy: 0.044, weight: 13 },
  { id: 'brand',     label: 'Fulfilment Lead',  desk: 'E-Commerce',     ticker: 'AMZN', baseApy: 0.046, weight: 12 },
  { id: 'ballast',   label: 'Index Ballast',    desk: 'Broad Market',   ticker: 'SPY',  baseApy: 0.040, weight: 14 },
  { id: 'bills',     label: 'Bills Desk',       desk: 'T-Bills',        ticker: 'SGOV', baseApy: 0.048, weight: 12 },
  { id: 'vault',     label: 'Vault Keeper',     desk: 'Gold',           ticker: 'GLD',  baseApy: 0.032, weight: 11 },
  { id: 'teller',    label: 'Chain Teller',     desk: 'Crypto Equity',  ticker: 'COIN', baseApy: 0.126, weight: 3 },
  { id: 'degen',     label: 'Treasury Degen',   desk: 'Crypto Proxy',   ticker: 'MSTR', baseApy: 0.141, weight: 2 },
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
