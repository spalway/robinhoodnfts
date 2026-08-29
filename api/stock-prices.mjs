// GET /api/stock-prices — Robinhood's own price feed, served from our origin.
//
// ===========================================================================
// WHY THIS EXISTS
// ===========================================================================
// api.robinhood.com answers an unauthenticated request from anywhere, and sends
// NO Access-Control-Allow-Origin header. Measured, with an explicit Origin, on
// 2026-08-29. That means the browser refuses the response before the page can
// read it — not a rate limit, not a key, just the same-origin policy doing its
// job. The call has to originate somewhere that is not a browser.
//
// Somewhere that is not a browser is this file. The site already ships a Node
// process to serve dist/ (server.mjs, for Railway), so the cheapest correct
// answer is to hang one more route off it. The page then fetches a RELATIVE
// url, /api/stock-prices, which is same-origin by construction — there is no
// CORS question to answer because there is no cross-origin request.
//
// The same handler is mounted into the Vite dev server (see vite.config.ts), so
// there is exactly one implementation and dev behaves like production. A second
// copy living in a Supabase Edge Function was written first and deleted: two
// implementations of one contract drift, and this one needs no project, no key
// and no deploy step of its own.
//
// ===========================================================================
// TWO UPSTREAMS, AND THEY ARE NOT THE SAME THING
// ===========================================================================
//   /rhj/prices          the documented Stock Token API. Bid and ask for the
//                        ERC-20 on Robinhood Chain. This is the TOKEN's price,
//                        and it is what a desk is actually worth on chain.
//
//   /quotes/?symbols=    the equity quote. Carries previous_close, which the
//                        token endpoint does not, and previous_close is the only
//                        way to state a daily move without inventing one.
//
// So `prices` is the token and `change` is the UNDERLYING EQUITY's session move.
// They are kept apart deliberately rather than blended: a change computed from a
// token mid against an equity close would straddle two books and quietly bake
// the bid/ask spread into the percentage.
//
// The equity leg is BEST EFFORT. If it fails the response still carries every
// price with an empty change map, and the tape renders an em dash per row — a
// thing it already knew how to do. A missing change must never cost the visitor
// the prices.
import { Buffer } from 'node:buffer'

const TOKEN_PRICES = 'https://api.robinhood.com/rhj/prices'
const EQUITY_QUOTES = 'https://api.robinhood.com/quotes/'

/** Robinhood caches /rhj/prices for 15s upstream. Asking faster buys nothing. */
const TTL_MS = 15_000

/** Bounds the roster a CALLER may ask for. Not a cap on the upstream fan-out. */
const MAX_SYMBOLS = 40

const TIMEOUT_MS = 6_000

/**
 * One cache for the whole process, holding the UPSTREAM payload rather than a
 * rendered response. Filtering is per-request and costs nothing; refetching is
 * what costs. Ten visitors in the same second produce one call to Robinhood.
 */
let cache = { at: 0, prices: null, change: null, halted: null }

/** A finite positive number, or null. Never NaN, never 0 standing in for absent. */
function decimal(value) {
  if (typeof value !== 'string' && typeof value !== 'number') return null
  const n = Number(value)
  return Number.isFinite(n) && n > 0 ? n : null
}

async function getJson(url) {
  try {
    const response = await fetch(url, {
      headers: { Accept: 'application/json' },
      // Without this a hung upstream pins the request open until the platform
      // kills it. The caller has a baked-in fallback and would rather have it
      // now than a live answer in thirty seconds.
      signal: AbortSignal.timeout(TIMEOUT_MS),
    })
    if (!response.ok) return null
    return await response.json()
  } catch {
    return null
  }
}

/** Refreshes the cache if it is older than TTL. Returns false if Robinhood is down. */
async function refresh() {
  if (cache.prices && Date.now() - cache.at < TTL_MS) return true

  const tokens = await getJson(TOKEN_PRICES)
  if (!tokens || !Array.isArray(tokens.quotes)) return false

  const prices = {}
  const halted = []
  for (const quote of tokens.quotes) {
    const symbol = typeof quote?.tokenSymbol === 'string' ? quote.tokenSymbol : null
    if (!symbol) continue
    const bid = decimal(quote.bid)
    const ask = decimal(quote.ask)
    // The mid. A one-sided book is served at whichever side exists rather than
    // dropped — a real price with a wide spread beats no price at all.
    const mid = bid && ask ? (bid + ask) / 2 : (bid ?? ask)
    if (mid === null) continue
    prices[symbol] = mid
    if (quote.isTradingHalt === true) halted.push(symbol)
  }
  if (Object.keys(prices).length === 0) return false

  // EVERY symbol, in chunks — not a slice.
  //
  // This read `Object.keys(prices).slice(0, MAX_SYMBOLS)` first, and the bug it
  // caused is worth recording: the cache holds all ~194 tokens Robinhood lists,
  // so slicing 40 off the front took an ARBITRARY 40 of them. The site asks for
  // sixteen, four of which happened to fall inside that window, so the tape came
  // back with twelve em dashes and four percentages and looked like Robinhood
  // had partial data. It did not — the request never asked.
  //
  // Verified: /quotes/ answers all 194 in a single call (879 characters of URL).
  // Chunked at 100 anyway, in parallel, so a future limit costs a round trip
  // rather than silently truncating the answer again.
  const change = {}
  const symbols = Object.keys(prices)
  const chunks = []
  for (let i = 0; i < symbols.length; i += 100) chunks.push(symbols.slice(i, i + 100))

  const pages = await Promise.all(
    chunks.map((chunk) => getJson(`${EQUITY_QUOTES}?symbols=${chunk.join(',')}`)),
  )
  for (const page of pages) {
    for (const row of page?.results ?? []) {
      const symbol = typeof row?.symbol === 'string' ? row.symbol : null
      if (!symbol || !(symbol in prices)) continue
      const last = decimal(row.last_trade_price)
      const close = decimal(row.previous_close)
      if (last === null || close === null) continue
      change[symbol] = ((last - close) / close) * 100
    }
  }

  cache = { at: Date.now(), prices, change, halted }
  return true
}

/**
 * The requested roster, or null for "everything Robinhood lists".
 *
 * Validated rather than forwarded. These symbols are only ever used as object
 * keys here — the upstream URL is built from Robinhood's OWN symbols, never from
 * the caller's — but anything that is not a plain uppercase ticker is dropped
 * regardless. There is no legitimate ticker this rejects.
 */
function requestedSymbols(raw) {
  if (!raw) return null
  const symbols = raw
    .split(',')
    .map((s) => s.trim().toUpperCase())
    .filter((s) => /^[A-Z]{1,8}$/.test(s))
  return symbols.length === 0 ? null : new Set(symbols.slice(0, MAX_SYMBOLS))
}

/**
 * Node http handler. Mounted by server.mjs in production and by the Vite dev
 * server in development, so the two behave identically.
 */
export async function handleStockPrices(req, res) {
  const query = (req.url || '').split('?')[1] || ''
  const keep = requestedSymbols(new URLSearchParams(query).get('symbols'))

  const ok = await refresh()
  if (!ok) {
    // The one hard failure. Without token prices there is nothing to serve, and
    // 502 tells prices.ts to use its baked-in reference map — which is exactly
    // right, and is why this is not dressed up as a 200 with an empty body that
    // a client could mistake for "every stock is worth nothing".
    res.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' })
    res.end(JSON.stringify({ ok: false, error: 'Robinhood’s stock-token price API is unreachable.' }))
    return
  }

  const prices = {}
  const change = {}
  for (const [symbol, value] of Object.entries(cache.prices)) {
    if (keep && !keep.has(symbol)) continue
    prices[symbol] = value
    if (symbol in cache.change) change[symbol] = cache.change[symbol]
  }
  const halted = cache.halted.filter((s) => !keep || keep.has(s))

  const body = Buffer.from(
    JSON.stringify({
      ok: true,
      source: 'robinhood',
      prices,
      change,
      halted,
      // Whether the equity leg landed. The client does not branch on it, but an
      // operator staring at an all-dashes tape should not have to guess which of
      // the two upstreams went quiet.
      changeAvailable: Object.keys(change).length > 0,
      fetchedAt: new Date(cache.at).toISOString(),
    }),
  )

  res.writeHead(200, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    // Matches the upstream TTL. Same-origin, so no CORS headers are needed or
    // wanted — adding them would invite calls this endpoint has no reason to serve.
    'Cache-Control': `public, max-age=${Math.floor(TTL_MS / 1000)}`,
    'X-Content-Type-Options': 'nosniff',
  })
  res.end(req.method === 'HEAD' ? undefined : body)
}

export const STOCK_PRICES_PATH = '/api/stock-prices'
