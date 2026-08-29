// The fee engine for the SIMULATED marketplace, and the raw-unit conversions the
// whole app shares. Every charge this codebase computes is computed here and
// nowhere else, so a quote shown in the UI and the amount a ledger row records
// can never disagree about a rounding unit.
//
// NOTHING HERE PRICES A MINT. That absence is the point and it is recent: a mint
// used to be 10,000 $XAS burned plus a 5% leg to the treasury, and it is now
// 10,000 burned and nothing else — one `transferChecked`, one destination, no
// fee, no second amount to reconcile. The rates below survive only because sales
// and contracts are still priced, and both of those are Postgres rows rather than
// transfers.
//
// They are named SIM_* for that reason. A reader reaching for "the protocol fee"
// must not be able to pick one up and thread it back through the mint path by
// accident, and a fee constant that merely *reads* as protocol-wide is exactly
// how that happens. There is no zero-valued mint fee parameter anywhere in this
// codebase either, because a dormant fee is a fee someone re-enables.
//
// One exception, stated out loud rather than left to be discovered: `spl.ts`
// still carries a `buildRentTransaction` that composes SIM_RENT_FEE_BPS into a
// real SPL transfer. Nothing in the app calls it — rentals are Supabase rows. If
// it is ever wired to a button, that rate stops being simulated and both this
// comment and the constant's name have to change with it.
//
// SOLE IMPLEMENTATION — there is no on-chain program and no Rust counterpart to
// keep in step. `spl.ts` composes plain SPL Token transfers whose amounts come
// from this file, so the quote on screen and the amount in the wallet prompt are
// the same bigint rather than two spellings that have to agree. This used to be
// one half of a matched pair with `fee_of()` in an Anchor program; that program
// was abandoned (see `anchor/ABANDONED.md`) and nothing replaced it.
//
// Money is bigint raw units throughout. Floats appear at precisely two places,
// both marked: toRawUnits() on the way in, fromRawUnits() on the way out. The
// simulated market quotes listing prices as ordinary numbers, so the conversion
// has to live somewhere — it lives here, once, rather than in every caller.

/** Basis-point denominator. 10_000 bps = 100%. */
export const BPS_DENOM = 10_000n

/**
 * 5% — outright sales in the simulated marketplace.
 *
 * SIMULATED ONLY. A sale is a Supabase ledger entry; no token moves and this rate
 * never reaches a transaction. It used to be charged on mints as well, which is
 * the reason for the prefix: with the mint fee gone, a bare `TRADE_FEE_BPS` would
 * still read like a charge the protocol takes on the one action that is real.
 */
export const SIM_SALE_FEE_BPS = 500n

/**
 * 10% — rental contracts in the simulated marketplace. Deliberately distinct from
 * the sale rate.
 *
 * SIMULATED in every path the app actually runs. The single caller that could
 * turn it into a real transfer is `spl.buildRentTransaction`, which no component
 * calls; see the header note.
 */
export const SIM_RENT_FEE_BPS = 1_000n

/**
 * Ceiling on any fee this codebase will charge. 2000 rather than 1000 so the 10%
 * rental fee is not sitting exactly at the limit.
 *
 * This was once a real guarantee: the program rejected a `set_config` above it,
 * so a predatory rate was impossible even from a compromised authority. That
 * guarantee is GONE with the program. What survives is a convention — a number
 * the rates in this file are tested against, binding on anyone who reads it and
 * on nobody who does not. Kept exported so the ceiling stays a stated intent
 * rather than a lost one, but do not cite it as protection.
 */
export const MAX_FEE_BPS = 2_000n

/**
 * Whole $XAS burned per mint, and — since the fee was removed — the entire cost
 * of a mint. Scaled by the mint's decimals to reach raw units.
 */
export const MINT_BURN = 10_000n

/**
 * Decimals assumed for $XAS wherever the UI needs raw units before the mint
 * exists. It is only ever a placeholder for the simulated marketplace: `spl.ts`
 * reads the real figure off the mint account and every live money path scales by
 * that, so a deployed mint using anything other than 9 changes nothing here and
 * there is no second copy of the number to keep in step.
 */
export const XNFT_DECIMALS = 9

/** A priced action, broken into the three lines a payer is entitled to see. */
export interface Quote {
  /** What the counterparty receives: the seller's proceeds, or the owner's take. */
  gross: bigint
  /** Marketplace fee, floored. Rides on top of gross; the payer covers it. */
  fee: bigint
  /** What the payer is debited. Always exactly gross + fee. */
  total: bigint
  /** The rate applied, so a label can read the number rather than hard-code it. */
  bps: bigint
}

export interface RentQuote extends Quote {
  /** Listed fee for a single epoch, in raw units. */
  perEpoch: bigint
  /** Contract length in epochs. */
  term: number
}

/**
 * 10^decimals as a bigint. Guarded because the exponent comes from a mint
 * account in production, and an implausible value would silently produce an
 * amount off by orders of magnitude rather than fail.
 *
 * 18 is the widest exponent this module will *compute* at, which is a different
 * and looser question than the widest exponent an SPL amount can *carry*. The
 * encodable ceiling is derived in `spl.ts` (MAX_MINT_DECIMALS) from MINT_BURN,
 * and it is the narrower of the two.
 */
function scale(decimals: number): bigint {
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 18) {
    throw new RangeError(`fees: implausible decimals (${decimals})`)
  }
  return 10n ** BigInt(decimals)
}

/**
 * The fee on `gross`, floored.
 *
 * Both operands are non-negative, so bigint's truncation toward zero *is* floor.
 * Flooring is the deliberate direction: the treasury never collects a fractional
 * unit it is not owed, and the payer is never over-charged by one.
 *
 * Throws on nonsense input rather than returning a plausible wrong number. This
 * is a pure calculation over values the app controls, not one of the async money
 * paths in `spl.ts` that must always resolve to a typed error — a negative
 * amount here is a bug in the caller and should stop the render, loudly.
 */
export function feeOn(gross: bigint, bps: bigint): bigint {
  if (gross < 0n) throw new RangeError('fees: gross cannot be negative')
  if (bps < 0n || bps > BPS_DENOM) throw new RangeError(`fees: bps out of range (${bps})`)
  return (gross * bps) / BPS_DENOM
}

/** What the payer is debited for a gross amount: the amount plus its fee. */
export function totalWithFee(gross: bigint, bps: bigint): bigint {
  return gross + feeOn(gross, bps)
}

/** Splits a gross amount into the gross / fee / total triple the UI renders. */
export function quoteFor(gross: bigint, bps: bigint): Quote {
  const fee = feeOn(gross, bps)
  return { gross, fee, total: gross + fee, bps }
}

/**
 * Whole tokens (possibly fractional) to raw units.
 *
 * `toFixed` rather than `Math.round(amount * 10 ** decimals)`: the multiply
 * accumulates binary error and turns a listed 0.07 into 69999999 raw units at 9
 * decimals. Rounding in decimal digits first keeps the number the visitor was
 * shown and the number that gets charged identical.
 */
export function toRawUnits(amount: number, decimals: number = XNFT_DECIMALS): bigint {
  const base = scale(decimals)
  if (!Number.isFinite(amount)) throw new RangeError('fees: amount is not finite')
  if (amount < 0) throw new RangeError('fees: amount cannot be negative')
  // Past 1e21 toFixed emits exponential notation and the split below would parse
  // garbage. Refuse instead of returning a confidently wrong balance.
  if (amount >= 1e21) throw new RangeError('fees: amount is too large to convert exactly')

  const [whole, frac] = amount.toFixed(decimals).split('.')
  return BigInt(whole) * base + BigInt(frac === undefined || frac === '' ? '0' : frac)
}

/**
 * Raw units back to whole tokens, for display only. Exact within a float's range
 * because the whole and fractional parts are converted separately — the same
 * trick `solana.ts` uses for balances.
 *
 * Cannot produce -0, NaN or Infinity for any bigint input: `Number(bigint)` is
 * never negative zero, `base` is a positive power of ten so the division never
 * divides by zero, and both terms are finite for every value a u64 can hold.
 * fees.test.ts sweeps that rather than taking it on trust — a "-0" in a money
 * column reads as a defect even when the value is right.
 */
export function fromRawUnits(raw: bigint, decimals: number = XNFT_DECIMALS): number {
  const base = scale(decimals)
  return Number(raw / base) + Number(raw % base) / Number(base)
}

/** A bps rate as a fraction, for `pct()`. 500n -> 0.05. */
export function bpsFraction(bps: bigint): number {
  return Number(bps) / Number(BPS_DENOM)
}

/**
 * What one mint debits, in raw units: MINT_BURN scaled to the mint's decimals.
 * All of it reaches the incinerator.
 *
 * A bare bigint and deliberately not a Quote. A Quote carries a `fee`, and a mint
 * has none — handing back a zero in the shape of a charge is precisely the
 * dormant parameter a later edit switches on. There is one number here because
 * the transaction has one leg.
 */
export function mintAmount(decimals: number = XNFT_DECIMALS): bigint {
  return MINT_BURN * scale(decimals)
}

/**
 * One outright sale in the simulated marketplace. `price` is in whole $XAS — the
 * seller receives exactly that, and the buyer pays it plus the 5% fee.
 */
export function saleQuote(price: number, decimals: number = XNFT_DECIMALS): Quote {
  return quoteFor(toRawUnits(price, decimals), SIM_SALE_FEE_BPS)
}

/**
 * One rental contract. `feePerEpoch` is in whole $XAS; the owner receives
 * `feePerEpoch × term` and the renter pays 10% on top of it.
 *
 * The fee is charged on the contract total rather than per epoch: flooring once
 * on the whole rather than `term` times leaves the treasury with the unit the
 * per-epoch rounding would have thrown away, and matches the single fee transfer
 * `spl.ts` would compose for a rental.
 */
export function rentQuote(
  feePerEpoch: number,
  term: number,
  decimals: number = XNFT_DECIMALS,
): RentQuote {
  if (!Number.isInteger(term) || term < 0) throw new RangeError(`fees: bad term (${term})`)
  const perEpoch = toRawUnits(feePerEpoch, decimals)
  return { ...quoteFor(perEpoch * BigInt(term), SIM_RENT_FEE_BPS), perEpoch, term }
}
