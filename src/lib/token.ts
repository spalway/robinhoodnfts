// $XCs token configuration — the one file an operator edits at launch.
import { getRuntimeConfig } from './runtimeConfig'
//


// Every surface that names the token (the /token page, the payout modal's
// support link) reads from here, so there is exactly one place to fill in and no
// second place to forget. Four strings and a supply figure.
//
// All four strings are empty on purpose. The interface shipped before the token
// did, and the honest state for an unlaunched token is a visible "not launched
// yet" — not a placeholder address that looks real, and not a button that opens
// a 404. `isTokenLaunched()` is the single gate, which is the same shape the
// mint path uses in lib/spl.ts: an empty address means every path that would
// spend, link or display refuses rather than improvising.

/**
 * The $XCs SPL mint address, base58. This is the "CA" a launch page prints.
 *
 * Paste it verbatim. Base58 is case-sensitive and has no normalisation, so a
 * single case-folded character is a different address — which is why every
 * surface renders it `.mono .keep-case` rather than through the label styles.
 */
export function xnftCa(): string {
  return getRuntimeConfig().xnftMint
}

/** X/Twitter handle only — no leading `@`, no URL. e.g. `xcorpagents`. */
export function supportHandle(): string {
  return getRuntimeConfig().supportHandle
}

/**
 * Total supply, in whole $XCs. A pump.fun launch mints a fixed billion and
 * revokes mint authority, so this is a constant rather than a chain read.
 *
 * bigint because it composes with `MINT_BURN` in lib/fees.ts — the burn maths on
 * the token page multiplies whole-token counts, and doing that in doubles would
 * be exact today and quietly wrong the first time somebody raises the supply.
 */
export const PLANNED_SUPPLY = 1_000_000_000n

/**
 * False until the mint address is set. Everything that could show an address,
 * open a market link or imply the token trades checks this first.
 */
export function isTokenLaunched(): boolean {
  return xnftCa().trim().length > 0
}

/** The handle without its `@`, or null when unset. Never returns a bare `@`. */
/**
 * The project's X handle.
 *
 * Falls back to a built-in default, which the money constants deliberately do
 * NOT do. The difference is what a wrong value costs: a wrong mint address sends
 * real tokens somewhere unrecoverable, so it must refuse rather than guess. A
 * handle is branding — the worst case is a link to the wrong profile, and the
 * cost of NOT having one is that a fresh deploy is missing its X button until
 * somebody remembers to fill in a database row.
 *
 * Supabase still wins whenever it has a value.
 */
const DEFAULT_HANDLE = 'xcorpagents'

export function twitterHandle(): string | null {
  const configured = supportHandle().trim().replace(/^@+/, '')
  const handle = configured.length > 0 ? configured : DEFAULT_HANDLE
  return handle.length > 0 ? handle : null
}

/** The profile URL, or null when the handle is unset — callers render text instead of a dead link. */
export function twitterUrl(): string | null {
  const handle = twitterHandle()
  return handle ? `https://x.com/${handle}` : null
}

/** The pump.fun link, or null. Separate from `isTokenLaunched()`: a token can exist before its page does. */
export function pumpFunUrl(): string | null {
  const url = getRuntimeConfig().pumpFunUrl.trim()
  return url.length > 0 ? url : null
}

/** The DexScreener link, or null. A pair only exists once there is liquidity. */
export function dexScreenerUrl(): string | null {
  const url = getRuntimeConfig().dexscreenerUrl.trim()
  return url.length > 0 ? url : null
}
