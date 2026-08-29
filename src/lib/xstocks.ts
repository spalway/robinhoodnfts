// xStocks — tokenized equities that trade on Solana (issued by Backed Finance).
//
// `mint` addresses were resolved against Jupiter's token registry on 2026-08-03
// and are baked in as verified constants — identity is never resolved at
// runtime. `referencePrice` is the fallback used when the live price API is
// unreachable (see prices.ts), captured at the same time.

export interface XStock {
  symbol: string
  name: string
  sector: string
  /** Solana mint address — verified, not synthesised. */
  mint: string
  /** Fallback USD price, used when live pricing is unavailable. */
  referencePrice: number
}

export const XSTOCKS: readonly XStock[] = [
  { symbol: 'NVDAx',  name: 'NVIDIA',           sector: 'Semiconductors',      mint: 'Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh', referencePrice: 205.76 },
  { symbol: 'AAPLx',  name: 'Apple',            sector: 'Megacap Tech',        mint: 'XsbEhLAtcf6HdfpFZ5xEMdqW8nfAvcsP5bdudRLJzJp',  referencePrice: 302.61 },
  { symbol: 'MSFTx',  name: 'Microsoft',        sector: 'Enterprise Software', mint: 'XspzcW1PRtgf6Wj92HCiZdjzKCyFekVD8P5Ueh3dRMX',  referencePrice: 481.07 },
  { symbol: 'JPMx',   name: 'JPMorgan Chase',   sector: 'Financials',          mint: 'XsMAqkcKsUewDrzVkait4e5u4y8REgtyS7jWgCpLV2C',  referencePrice: 358.62 },
  { symbol: 'Vx',     name: 'Visa',             sector: 'Payments',            mint: 'XsqgsbXwWogGJsNcVZ3TyVouy2MbTkfCFhCGGGcQZ2p',  referencePrice: 367.16 },
  { symbol: 'XOMx',   name: 'Exxon Mobil',      sector: 'Energy',              mint: 'XsaHND8sHyfMfsWPj6kSdd5VwvCayZvjYgKmmcNL5qh',  referencePrice: 152.46 },
  { symbol: 'HONx',   name: 'Honeywell',        sector: 'Industrials',         mint: 'XsRbLZthfABAPAfumWNEJhPyiKDW6TvDVeAeW7oKqA2',  referencePrice: 430.34 },
  { symbol: 'LLYx',   name: 'Eli Lilly',        sector: 'Pharmaceuticals',     mint: 'Xsnuv4omNoHozR6EEW5mXkw8Nrny5rB3jVfLqi6gKMH',  referencePrice: 1139.12 },
  { symbol: 'UNHx',   name: 'UnitedHealth',     sector: 'Health Insurance',    mint: 'XszvaiXGPwvk2nwb3o9C1CX4K6zH8sez11E6uyup6fe',  referencePrice: 416.92 },
  { symbol: 'KOx',    name: 'Coca-Cola',        sector: 'Consumer Staples',    mint: 'XsaBXg8dU5cPM6ehmVctMkVqoiRG2ZjMo1cyBJ3AykQ',  referencePrice: 89.04 },
  { symbol: 'PGx',    name: 'Procter & Gamble', sector: 'Consumer Staples',    mint: 'XsYdjDjNUygZ7yGKfQaB6TxLh2gC6RRjzLtLAGJrhzV',  referencePrice: 145.61 },
  { symbol: 'SPYx',   name: 'S&P 500',          sector: 'Broad Market',        mint: 'XsoCS1TfEyfFhfvj8EtZ528L3CaKBDBRqRapnBbDF2W',  referencePrice: 757.85 },
  { symbol: 'TBLLx',  name: '0-3M T-Bill',      sector: 'Treasury Bills',      mint: 'XsqBC5tcVQLYt8wqGCHRnAUUecbRYXoJCReD6w7QEKp',  referencePrice: 105.75 },
  { symbol: 'GLDx',   name: 'Gold Trust',       sector: 'Commodities',         mint: 'Xsv9hRk1z5ystj9MhnA7Lq4vjSsLwzL2nxrwmwtD3re',  referencePrice: 370.90 },
  { symbol: 'COINx',  name: 'Coinbase',         sector: 'Crypto Equity',       mint: 'Xs7ZdzSHLU9ftNJsii5fCeJhoRWSC32SQGzGQtePxNu',  referencePrice: 147.63 },
  { symbol: 'MSTRx',  name: 'Strategy',         sector: 'Crypto Proxy',        mint: 'XsP7xzNPvEHS1m6qfanPUGjNmdnmsLKEoNAnHjdxxyZ',  referencePrice: 93.99 },
] as const

const BY_SYMBOL = new Map(XSTOCKS.map((s) => [s.symbol, s]))
const BY_MINT = new Map(XSTOCKS.map((s) => [s.mint, s]))

export function getStock(symbol: string): XStock {
  const stock = BY_SYMBOL.get(symbol)
  if (!stock) throw new Error(`unknown xStock: ${symbol}`)
  return stock
}

export function stockByMint(mint: string): XStock | undefined {
  return BY_MINT.get(mint)
}

export function allMints(): string[] {
  return XSTOCKS.map((s) => s.mint)
}
