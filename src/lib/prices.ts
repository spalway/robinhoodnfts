// Live xStock pricing via Jupiter, with an honest fallback.
//
// Failure is a first-class path: if the API is unreachable, rate-limited, or
// returns a symbol we can't parse, we serve baked-in reference prices and mark
// the reading CACHED. The UI must never blank, spin forever, or render NaN.
import { XSTOCKS, allMints, stockByMint } from './xstocks'

export type PriceSource = 'live' | 'cached'

export interface PriceMap {
  /** symbol -> USD price. Always fully populated for every xStock. */
  bySymbol: Record<string, number>
  /** symbol -> 24h percent change. Only populated for live readings. */
  change24h: Record<string, number>
  /**
   * SOL/USD. Payouts are quoted in SOL, so this is the one price in the app
   * that decides how much somebody is actually owed.
   */
  solUsd: number
  source: PriceSource
  fetchedAt: number
}

const JUPITER_PRICE_URL = 'https://lite-api.jup.ag/price/v3'

/** Wrapped SOL. Jupiter prices it on the same endpoint as every xStock. */
export const SOL_MINT = 'So11111111111111111111111111111111111111112'

/**
 * Last-resort SOL/USD, used only when the feed is unreachable.
 *
 * This number used to be the ONLY source: a hardcoded 180 in earnings.ts,
 * labelled a placeholder, rendered to the visitor as "at $180 / SOL". Live SOL
 * was $74.81 when that was found, so the payout page was overstating the rate
 * by 2.4x and therefore understating every payout by the same factor — on the
 * one page where a number means money.
 *
 * A fallback is still needed, because a dead price feed must not make the page
 * render NaN. But it is now a fallback, it is labelled CACHED on screen when it
 * is in use, and it is deliberately conservative.
 */
export const SOL_USD_FALLBACK = 150

export function referencePrices(): Record<string, number> {
  const out: Record<string, number> = {}
  for (const s of XSTOCKS) out[s.symbol] = s.referencePrice
  return out
}

export function cachedFallback(): PriceMap {
  return {
    bySymbol: referencePrices(),
    change24h: {},
    solUsd: SOL_USD_FALLBACK,
    source: 'cached',
    fetchedAt: Date.now(),
  }
}

/**
 * Fetches live prices. Never throws — always resolves to a usable PriceMap.
 * Any symbol missing from the response keeps its reference price.
 */
export async function fetchPrices(signal?: AbortSignal): Promise<PriceMap> {
  const prices = referencePrices()
  const change24h: Record<string, number> = {}

  try {
    const url = `${JUPITER_PRICE_URL}?ids=${[...allMints(), SOL_MINT].join(',')}`
    const res = await fetch(url, { signal })
    if (!res.ok) return cachedFallback()

    const body = (await res.json()) as Record<
      string,
      { usdPrice?: number; priceChange24h?: number } | null
    >
    if (!body || typeof body !== 'object') return cachedFallback()

    let resolved = 0
    let solUsd = SOL_USD_FALLBACK
    for (const [mint, entry] of Object.entries(body)) {
      if (mint === SOL_MINT) {
        const sol = entry?.usdPrice
        // Not counted toward `resolved`: SOL is not an xStock, and a response
        // carrying only SOL has still failed at the job this feed exists for.
        if (typeof sol === 'number' && Number.isFinite(sol) && sol > 0) solUsd = sol
        continue
      }
      const stock = stockByMint(mint)
      const usd = entry?.usdPrice
      if (!stock || typeof usd !== 'number' || !Number.isFinite(usd) || usd <= 0) continue
      prices[stock.symbol] = usd
      resolved++

      const delta = entry?.priceChange24h
      if (typeof delta === 'number' && Number.isFinite(delta)) change24h[stock.symbol] = delta
    }

    // A response that resolved nothing is a failed response, whatever its status.
    if (resolved === 0) return cachedFallback()

    return { bySymbol: prices, change24h, solUsd, source: 'live', fetchedAt: Date.now() }
  } catch {
    return cachedFallback()
  }
}
