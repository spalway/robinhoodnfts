// Live Robinhood Stock Token pricing, with an honest fallback.
//
// The feed is Robinhood's own — /rhj/prices for the token and /quotes/ for the
// underlying equity's session move — reached through OUR OWN ORIGIN at
// /api/stock-prices (api/stock-prices.mjs, mounted by server.mjs in production
// and by the Vite dev server in development).
//
// THE HOP IS NOT OPTIONAL: api.robinhood.com sends no Access-Control-Allow-Origin,
// so a direct fetch from the page is refused by the browser before the body is
// read. The URL below is RELATIVE, deliberately — same origin means no preflight,
// no key, and no second host to configure or keep alive.
//
// Failure stays a first-class path, exactly as it was under Jupiter: if the route
// is unreachable or returns nothing usable, we serve the baked-in reference
// prices and mark the reading CACHED. The UI must never blank, spin forever, or
// render NaN.
//
// GONE FROM HERE: solUsd. Robinhood Chain has no SOL — it settles gas in ETH —
// and a SOL/USD rate on this site would have been a number with nothing behind
// it. Nothing outside this file read it.
import { STOCKS, allSymbols } from './stocks'

export type PriceSource = 'live' | 'cached'

export interface PriceMap {
  /** symbol -> USD price. Always fully populated for every stock. */
  bySymbol: Record<string, number>
  /**
   * symbol -> percent move since the underlying equity's previous close.
   *
   * Only populated for live readings, and legitimately EMPTY even then when
   * Robinhood's equity endpoint is the half that failed. The tape treats a
   * missing entry as "no data" and shows an em dash, which is the truth.
   */
  change24h: Record<string, number>
  /** Symbols Robinhood currently reports as halted. Empty on a cached reading. */
  halted: string[]
  source: PriceSource
  fetchedAt: number
}

export function referencePrices(): Record<string, number> {
  const out: Record<string, number> = {}
  for (const s of STOCKS) out[s.symbol] = s.referencePrice
  return out
}

export function cachedFallback(): PriceMap {
  return {
    bySymbol: referencePrices(),
    change24h: {},
    halted: [],
    source: 'cached',
    fetchedAt: Date.now(),
  }
}

interface ProxyBody {
  ok?: boolean
  prices?: Record<string, unknown>
  change?: Record<string, unknown>
  halted?: unknown
}

/**
 * Fetches live prices. Never throws — always resolves to a usable PriceMap.
 * Any symbol missing from the response keeps its reference price.
 */
export async function fetchPrices(signal?: AbortSignal): Promise<PriceMap> {
  const prices = referencePrices()
  const change24h: Record<string, number> = {}

  try {
    const url = `/api/stock-prices?symbols=${allSymbols().join(',')}`
    const res = await fetch(url, { signal, headers: { Accept: 'application/json' } })
    if (!res.ok) return cachedFallback()

    const body = (await res.json()) as ProxyBody | null
    if (!body || typeof body !== 'object' || !body.prices) return cachedFallback()

    let resolved = 0
    for (const [symbol, value] of Object.entries(body.prices)) {
      // Only symbols this build already knows are accepted. The proxy is ours,
      // but a price map keyed by whatever the upstream happened to return would
      // let a renamed ticker introduce a desk the collection has never heard of.
      if (!(symbol in prices)) continue
      const usd = typeof value === 'number' ? value : Number(value)
      if (!Number.isFinite(usd) || usd <= 0) continue
      prices[symbol] = usd
      resolved++
    }

    // A response that resolved nothing is a failed response, whatever its status.
    if (resolved === 0) return cachedFallback()

    for (const [symbol, value] of Object.entries(body.change ?? {})) {
      if (!(symbol in prices)) continue
      const delta = typeof value === 'number' ? value : Number(value)
      // Zero is a real reading here — a stock genuinely flat on the day — so
      // this checks finiteness only, unlike the price guard above.
      if (Number.isFinite(delta)) change24h[symbol] = delta
    }

    const halted = Array.isArray(body.halted)
      ? body.halted.filter((s): s is string => typeof s === 'string' && s in prices)
      : []

    return { bySymbol: prices, change24h, halted, source: 'live', fetchedAt: Date.now() }
  } catch {
    return cachedFallback()
  }
}
