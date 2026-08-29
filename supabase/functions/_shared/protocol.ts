// The economic model, server side.
//
// MATCHED PAIR — this file and `src/lib/fees.ts` are two spellings of one
// calculation. They are duplicated rather than shared because `src/` is a Vite
// bundle and this is a Deno bundle: the Supabase CLI builds each Edge Function
// from its own module graph rooted at `supabase/functions`, and reaching up into
// `../../../src/lib/fees.ts` is the kind of import that works on one CLI version
// and breaks a deploy on the next. The duplication is therefore deliberate, and
// it is kept honest by being tiny: five constants and one multiply.
//
// What must agree, exactly:
//
//   BPS_DENOM / RENT_FEE_BPS / MINT_BURN — the numbers
//   feeOn()      ↔ fees.feeOn()       — same floor division, same direction
//   mintAmount() ↔ fees.mintAmount()  — the same single 10,000 figure
//
// If those disagree, `ingest-signature` stops recognising the very transactions
// `src/lib/spl.ts` builds, and every real mint is refused as "not a mint". That
// is a loud failure rather than a quiet mis-ingestion, which is the failure mode
// this file is arranged to have.
//
// ---------------------------------------------------------------------------
// THE MINT FEE IS GONE, AND SO IS THE SHAPE THAT COULD HOLD ONE
// ---------------------------------------------------------------------------
// A mint used to be two transfers: 10,000 $xNFT burned and 500 to the treasury.
// It is now ONE transfer of 10,000 to the incinerator and nothing else.
//
// `mintLegs()` returned a `{ burn, fee, total }` triple, and it has been replaced
// by `mintAmount()` returning a bare bigint rather than being edited to put a
// zero in the fee field. That is the same reasoning `src/lib/fees.ts` gives for
// deleting `mintQuote()`: a struct with a `fee` member is a struct somebody fills
// in, and a fee constant sitting at zero is a fee waiting to be re-enabled. A
// function whose return type cannot express a second amount cannot quietly grow
// one.
//
// The economic consequence is worth one line: the burn is now the ENTIRE cost of
// a mint, so every token a buyer spends is destroyed and none of it reaches an
// operator wallet.
//
// Money is bigint raw units. Nothing here takes or returns a number that could
// have been through a double.

/** Basis-point denominator. 10_000 bps = 100%. */
export const BPS_DENOM = 10_000n

/**
 * 10% — rental contracts, the only remaining rate this file applies.
 *
 * There is deliberately no mint rate. Not a zero one: none.
 */
export const RENT_FEE_BPS = 1_000n

/** Whole $xNFT sent to the incinerator per mint, before decimals scaling. */
export const MINT_BURN = 10_000n

/**
 * Solana's canonical incinerator, and the only address a mint's burn leg may be
 * addressed to.
 *
 * A constant here for the same reason it is a constant in `src/lib/spl.ts`: the
 * difference between a burn and a gift to a stranger is one address, so it is not
 * something a request body, an environment variable or a caller argument gets to
 * choose. `ingest-signature` refuses a "mint" whose big leg went anywhere else.
 */
export const INCINERATOR_ADDRESS = '1nc1nerator11111111111111111111111111111111'

/** 10^decimals. Guarded: the exponent is read off a chain account, not chosen here. */
export function scale(decimals: number): bigint | null {
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 18) return null
  return 10n ** BigInt(decimals)
}

/**
 * The fee on `gross`, floored — bigint truncation toward zero is floor for
 * non-negative operands, which is what `src/lib/fees.ts` computes and therefore
 * what the wallet actually signed.
 *
 * Returns null rather than throwing on nonsense, because every caller here is on
 * a path that must resolve to a typed error rather than a stack trace.
 */
export function feeOn(gross: bigint, bps: bigint): bigint | null {
  if (gross < 0n) return null
  if (bps < 0n || bps > BPS_DENOM) return null
  return (gross * bps) / BPS_DENOM
}

/**
 * The exact amount a mint transaction must burn, at this mint's decimals:
 * 10,000 $xNFT to the incinerator, which is the whole of what a mint costs.
 *
 * A bare bigint, not a record. There is no second amount to name and no field
 * for one to appear in — see the header for why that is the shape rather than a
 * `{ burn, fee: 0n }` that reads as a fee somebody switched off.
 *
 * `decimals` is read off the transaction's own token-balance metadata, not
 * configured, so a build pointed at a mint with different decimals produces a
 * different expected amount and still recognises its own transactions.
 *
 * Returns null on an implausible exponent instead of producing an amount that is
 * wrong by orders of magnitude.
 */
export function mintAmount(decimals: number): bigint | null {
  const base = scale(decimals)
  if (base === null) return null
  return MINT_BURN * base
}

/**
 * Postgres `bigint` is signed and every money column in this schema is a digit
 * string checked against a u64-shaped domain. A u64 above this is storable as
 * text but would break any future ::numeric aggregation in a confusing way, so
 * it is refused at the edge instead.
 */
export const U64_MAX = 18_446_744_073_709_551_615n

/** True for a value that can be written into a `u64_text` column unchanged. */
export function isStorableAmount(value: bigint): boolean {
  return value >= 0n && value <= U64_MAX
}
