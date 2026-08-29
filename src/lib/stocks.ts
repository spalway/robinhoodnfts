// Robinhood Stock Tokens — the tokenized equities that trade on Robinhood Chain.
//
// This file replaces xstocks.ts, which held Backed Finance's xStock mints on
// Solana. Those addresses are not merely stale here, they are unreachable: a
// base58 Solana mint has no meaning on an EVM chain, and Jupiter — the feed that
// priced them — indexes Solana only. Every symbol, name and address below was
// resolved against Robinhood's OWN registry:
//
//   GET https://api.robinhood.com/rhj/assets      (194 tokens, all chainId 4663)
//   GET https://api.robinhood.com/rhj/prices      (bid/ask for all of them)
//
// captured 2026-08-29 and baked in as verified constants. Identity is NEVER
// resolved at runtime, and that is a deliberate refusal rather than laziness: a
// feed allowed to rename a desk is a feed allowed to point a desk at a contract
// nobody vetted. The live call carries prices and nothing else.
//
// SIX TICKERS CHANGED, because Robinhood does not issue the other six. JPM, V,
// HON, KO, PG and TBLL are simply not on the chain — the previous roster was
// Backed's, and the two issuers list different books. Their desks moved to the
// nearest real Robinhood token in the same business:
//
//   JPM  -> SOFI   Financials became fintech; there is no bank token.
//   V    -> FISV   Fiserv is the payment rails Visa stood in for.
//   HON  -> GE     Same industrial slot, and GE is the bigger name.
//   KO   -> COST   Staples, and the only large one Robinhood lists.
//   PG   -> AMZN   Consumer, traded up to the e-commerce book.
//   TBLL -> SGOV   Identical asset: a 0-3 month Treasury fund.
//
// The skills array in skills.ts keeps its ids, order and weights, so the
// substitution changes which COMPANY a desk trades and never which desk an
// xployee draws. See the note there.
//
// Symbols carry no `x` suffix. Backed appends one (AAPLx) and the brand leaned
// on it; Robinhood does not, and inventing a ticker that resolves to nothing
// would be the one lie this file exists to prevent. The lowercase x lives in
// xCorp, xployee and xNET, where it belongs.

export interface Stock {
  /** Robinhood's own ticker, exactly as their registry spells it. */
  symbol: string
  /** Short display name. Robinhood's is "NVIDIA • Robinhood Token"; this is the head of it. */
  name: string
  sector: string
  /** ERC-20 contract on Robinhood Chain (chainId 4663), 18 decimals. Cased exactly as Robinhood's registry returns it — never re-checksummed by hand. */
  address: string
  /** Bid/ask mid at capture. The fallback when the live feed is unreachable. */
  referencePrice: number
}

export const STOCKS: readonly Stock[] = [
  { symbol: 'NVDA', name: 'NVIDIA',           sector: 'Semiconductors',      address: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC', referencePrice: 219.63 },
  { symbol: 'AAPL', name: 'Apple',            sector: 'Megacap Tech',        address: '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9', referencePrice: 318.60 },
  { symbol: 'MSFT', name: 'Microsoft',        sector: 'Enterprise Software', address: '0xe93237C50D904957Cf27E7B1133b510C669c2e74', referencePrice: 512.16 },
  { symbol: 'SOFI', name: 'SoFi',             sector: 'Fintech',             address: '0x98E75885157C80992A8D41b696D8c9C6Fb30A926', referencePrice: 18.07 },
  { symbol: 'FISV', name: 'Fiserv',           sector: 'Payments',            address: '0x9ECe29A4A2397C0a35fb5fA8EE2b9509130a98cc', referencePrice: 53.25 },
  { symbol: 'XOM',  name: 'ExxonMobil',       sector: 'Energy',              address: '0xf9B46d3D1B22199D4D1025a9cEDB540A33F1a2d5', referencePrice: 157.00 },
  { symbol: 'GE',   name: 'General Electric', sector: 'Industrials',         address: '0x63b814DDBd6BF339f25Fed8c36158a008D5B373e', referencePrice: 339.66 },
  { symbol: 'LLY',  name: 'Eli Lilly',        sector: 'Pharmaceuticals',     address: '0x8005d266423c7ea827372c9c864491e5786600ea', referencePrice: 1172.78 },
  { symbol: 'UNH',  name: 'UnitedHealth',     sector: 'Health Insurance',    address: '0xcF364ea52787e289De6F32077834056E3E70D6A8', referencePrice: 415.00 },
  { symbol: 'COST', name: 'Costco',           sector: 'Consumer Staples',    address: '0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2', referencePrice: 898.50 },
  { symbol: 'AMZN', name: 'Amazon',           sector: 'E-Commerce',          address: '0x12f190a9F9d7D37a250758b26824B97CE941bF54', referencePrice: 257.10 },
  { symbol: 'SPY',  name: 'S&P 500',          sector: 'Broad Market',        address: '0x117cc2133c37B721F49dE2A7a74833232B3B4C0C', referencePrice: 769.36 },
  { symbol: 'SGOV', name: '0-3M Treasury',    sector: 'Treasury Bills',      address: '0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5', referencePrice: 100.56 },
  { symbol: 'GLD',  name: 'Gold Trust',       sector: 'Commodities',         address: '0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e', referencePrice: 409.18 },
  { symbol: 'COIN', name: 'Coinbase',         sector: 'Crypto Equity',       address: '0x6330D8C3178a418788dF01a47479c0ce7CCF450b', referencePrice: 182.43 },
  { symbol: 'MSTR', name: 'Strategy',         sector: 'Crypto Proxy',        address: '0xec262a75e413fAfD0dF80480274532C79D42da09', referencePrice: 132.57 },
] as const

const BY_SYMBOL = new Map(STOCKS.map((s) => [s.symbol, s]))

export function getStock(symbol: string): Stock {
  const stock = BY_SYMBOL.get(symbol)
  if (!stock) throw new Error(`unknown Robinhood stock token: ${symbol}`)
  return stock
}

export function stockBySymbol(symbol: string): Stock | undefined {
  return BY_SYMBOL.get(symbol)
}

/** The symbols the price proxy is asked for. Nothing else is requested. */
export function allSymbols(): string[] {
  return STOCKS.map((s) => s.symbol)
}
