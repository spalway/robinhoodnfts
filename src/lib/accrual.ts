// Book maths. Every figure here is a pure function of (hire time, now, skills,
// prices) — nothing is stored, so yield ticks live in the UI simply by
// re-rendering against a moving clock.
import { effectiveApy, type HeldSkill } from './skills'
import type { Xployee } from './xployee'

export const EPOCH_MS = 24 * 60 * 60 * 1000
/** Epochs per year, used to annualise trailing figures. */
export const EPOCHS_PER_YEAR = 365

/**
 * Protocol genesis — day one. Fixed so epoch numbering is stable across
 * machines.
 *
 * This is the launch date, not an earlier date the protocol did not exist for.
 * It used to sit seven months back, which meant a site that had never been
 * deployed opened on "epoch 213" with workers carrying most of a year of
 * accrued yield. Everything downstream of this constant — tenure, book value,
 * trailing APY, the settlement ledger — is measured from here, so moving it to
 * launch is what makes those figures start at zero and grow honestly.
 */
export const GENESIS = Date.UTC(2026, 7, 7)

export function epochAt(now: number): number {
  return Math.max(0, Math.floor((now - GENESIS) / EPOCH_MS))
}

export function epochStart(epoch: number): number {
  return GENESIS + epoch * EPOCH_MS
}

export function msUntilNextEpoch(now: number): number {
  return epochStart(epochAt(now) + 1) - now
}

/** How long this worker has been on the books, in years. */
export function tenureYears(x: Xployee, now: number): number {
  return Math.max(0, now - x.hiredAt) / (EPOCH_MS * EPOCHS_PER_YEAR)
}

/**
 * Yield accrued per skill, in USD.
 *
 * Continuous linear accrual against the skill's share of principal. Monotonic
 * in time and exactly zero at t = 0.
 */
export function accruedBySkill(x: Xployee, now: number): { held: HeldSkill; usd: number }[] {
  const years = tenureYears(x, now)
  const perSkillPrincipal = x.principal / x.skills.length
  return x.skills.map((held) => ({
    held,
    usd: perSkillPrincipal * effectiveApy(held) * years,
  }))
}

export function accruedTotal(x: Xployee, now: number): number {
  return accruedBySkill(x, now).reduce((sum, r) => sum + r.usd, 0)
}

/** Principal plus everything earned since hire. */
export function bookValue(x: Xployee, now: number): number {
  return x.principal + accruedTotal(x, now)
}

export interface ApyReading {
  rate: number
  /** True when the worker is younger than the full trailing window. */
  estimated: boolean
}

/**
 * Trailing APY — accrued over the trailing 30 epochs / average book NAV,
 * annualised. Under 30 epochs it annualises over actual lifetime and is
 * flagged so the UI can mark it EST.
 */
export function trailingApy(x: Xployee, now: number, windowEpochs = 30): ApyReading {
  const ageMs = Math.max(0, now - x.hiredAt)
  const windowMs = Math.min(windowEpochs * EPOCH_MS, ageMs)

  if (windowMs <= 0) return { rate: x.apy, estimated: true }

  const start = now - windowMs
  const earned = accruedTotal(x, now) - accruedTotal(x, start)
  const avgNav = (bookValue(x, start) + bookValue(x, now)) / 2
  if (avgNav <= 0) return { rate: 0, estimated: true }

  const periodsPerYear = (EPOCH_MS * EPOCHS_PER_YEAR) / windowMs
  return {
    rate: (earned / avgNav) * periodsPerYear,
    estimated: ageMs < windowEpochs * EPOCH_MS,
  }
}

/** Yield produced per epoch at the current rate — the number a renter cares about. */
export function yieldPerEpoch(x: Xployee): number {
  return (x.principal * x.apy) / EPOCHS_PER_YEAR
}
