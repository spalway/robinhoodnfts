// Display formatting. Everything user-facing routes through here so numbers
// look consistent across eight pages.
//
// This module is also the last line of defence against a number that is
// arithmetically fine and reads as a defect. Two of those exist and both are
// handled once, here, rather than at forty call sites:
//
//   NaN and Infinity render as an em dash. A money column showing "NaN" is worse
//   than one showing nothing, because nothing is honest about not knowing.
//
//   Negative zero renders as zero. `Intl` formats -0 as "-0" and "-$0.00", which
//   reads as a bug to anyone looking at a balance even though the value is
//   correct. Nothing in the app's own arithmetic currently produces one — the
//   clamps in earnings.ts and network.ts see to that — but -0 arrives from
//   ordinary subtraction the moment any of them is relaxed, and a price feed can
//   hand one straight to signedPct as a 24h change.

/**
 * True for a value safe to format. -0 is deliberately NOT excluded here; it is
 * normalised instead, because it is a real zero that merely prints wrong.
 */
function shown(value: number): number | null {
  if (!Number.isFinite(value)) return null
  // `value + 0` would not do it: -0 + 0 is +0 only because addition is defined
  // that way, and relying on that is less legible than saying what is meant.
  return Object.is(value, -0) ? 0 : value
}

export function usd(input: number, decimals = 2): string {
  const value = shown(input)
  if (value === null) return '—'
  return value.toLocaleString('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

/**
 * A live-accruing figure. Six decimals is deliberate: a single xployee earns
 * roughly $0.000003 a second, so at 2 or 4 decimals a "live" number would sit
 * frozen for half a minute at a time. At 6 it visibly moves.
 */
export function usdLive(value: number): string {
  return usd(value, 6)
}

/** Compact USD for stat tiles: $1.2M, $48.3K. */
export function usdCompact(input: number): string {
  const value = shown(input)
  if (value === null) return '—'
  const abs = Math.abs(value)
  if (abs >= 1e9) return `$${(value / 1e9).toFixed(2)}B`
  if (abs >= 1e6) return `$${(value / 1e6).toFixed(2)}M`
  if (abs >= 1e3) return `$${(value / 1e3).toFixed(1)}K`
  return `$${value.toFixed(2)}`
}

export function pct(input: number, decimals = 2): string {
  const value = shown(input)
  if (value === null) return '—'
  // `(value * 100).toFixed()` can still land on "-0.00" for a small negative —
  // -0.00004 is a genuine negative that rounds to nothing at two decimals, and
  // "-0.00%" is the correct reading of it. Only true -0 is normalised.
  return `${(value * 100).toFixed(decimals)}%`
}

/** Signed percent with an arrow glyph — the only up/down signal in a mono UI. */
export function signedPct(input: number, decimals = 2): string {
  const value = shown(input)
  if (value === null) return '—'
  // -0 has already become 0, so a flat reading points up rather than down.
  const arrow = value >= 0 ? '▲' : '▼'
  return `${arrow} ${Math.abs(value).toFixed(decimals)}%`
}

export function num(input: number, decimals = 0): string {
  const value = shown(input)
  if (value === null) return '—'
  return value.toLocaleString('en-US', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

/**
 * A count with its noun, pluralised.
 *
 * Exists because the network genuinely holds one wallet at launch, and every
 * count that reads "1 wallets" is a small piece of evidence that nobody looked
 * at the empty state. Handles the -s case only; pass `many` for anything
 * irregular.
 */
export function plural(count: number, one: string, many = `${one}s`): string {
  return `${num(count)} ${count === 1 ? one : many}`
}

/**
 * $XCs amounts. Adaptive precision: an epoch fee is a couple of tokens while a
 * sale ask is thousands, and rounding both to integers would flatten every
 * contract fee to the same number.
 *
 * The TICKER is XCs; the PRODUCT is xCorp. Two different words, and this
 * function returns the first. `.keep-case` stays correct on the elements that
 * carry it — it protects the lowercase x in "xCorp", "xployee" and every xStock
 * ticker ($AAPLx) — but it is a no-op on this string, which is all caps.
 */
export function xnft(input: number): string {
  const value = shown(input)
  if (value === null) return '—'
  const decimals = Math.abs(value) < 100 ? 2 : 0
  return `${num(value, decimals)} XCs`
}

/** Truncate a base58 address: XsbE…JzJp */
export function shortAddress(address: string, lead = 4, tail = 4): string {
  if (address.length <= lead + tail + 1) return address
  return `${address.slice(0, lead)}…${address.slice(-tail)}`
}

export function dateTime(ms: number): string {
  return new Date(ms).toLocaleString('en-US', {
    month: 'numeric',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    second: '2-digit',
  })
}

export function dateOnly(ms: number): string {
  return new Date(ms).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  })
}

/** Countdown as HH:MM:SS. */
export function duration(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000))
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${pad(h)}:${pad(m)}:${pad(s)}`
}
