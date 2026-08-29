// Reading Robinhood Chain, for the verifier.
//
// The Solana build had rpc.ts and transfers.ts doing this job: fetch a
// transaction, walk its token balance deltas, attribute each movement to an
// owner. Almost none of that survives, because EVM answers the same question
// far more directly — an ERC-20 transfer emits a log, and the log names the
// sender, the recipient and the amount. There are no token accounts to resolve
// back to owners, and therefore no "the node did not report an owner" case,
// which was the subtlest failure mode on the other side.
//
// Deliberately not ethers or viem: the whole surface is two RPC methods and one
// event topic, all fixed constants. Hand-decoding a 32-byte word is smaller and
// more auditable than an ABI coder in a Deno cold start.

export interface EvmFailure {
  code: 'network' | 'malformed'
  message: string
}

export function isEvmFailure(v: unknown): v is EvmFailure {
  return typeof v === 'object' && v !== null && 'code' in v && 'message' in v
}

/**
 * keccak256("Transfer(address,address,uint256)").
 *
 * A constant, so nothing here has to hash at runtime. Every ERC-20 transfer on
 * every chain emits this topic; it is the one thing the verifier matches on.
 */
export const TRANSFER_TOPIC = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'

export interface RpcLog {
  address: string
  topics: string[]
  data: string
  logIndex: string
}

export interface Receipt {
  status: string
  from: string
  to: string | null
  blockNumber: string
  logs: RpcLog[]
}

async function rpc<T>(url: string, method: string, params: unknown[]): Promise<T | EvmFailure> {
  let response: Response
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    })
  } catch (e) {
    const detail = e instanceof Error ? e.message : 'unknown error'
    return { code: 'network', message: `Could not reach the chain: ${detail}` }
  }
  if (!response.ok) {
    return { code: 'network', message: `The node refused the request (${response.status}).` }
  }
  let body: { result?: unknown; error?: { message?: string } }
  try {
    body = await response.json()
  } catch {
    return { code: 'malformed', message: 'The node returned an unreadable response.' }
  }
  if (body.error) {
    return { code: 'network', message: body.error.message ?? 'The node reported an error.' }
  }
  return body.result as T
}

/**
 * The receipt, or null when the chain has not seen the hash.
 *
 * NULL IS NOT AN ERROR and the distinction is the whole point. A transaction
 * broadcast a second ago and one that never existed both come back null, and
 * the caller must treat that as "not yet" — never as proof of failure.
 */
export async function getReceipt(url: string, hash: string): Promise<Receipt | null | EvmFailure> {
  const result = await rpc<Receipt | null>(url, 'eth_getTransactionReceipt', [hash])
  if (isEvmFailure(result)) return result
  return result ?? null
}

/** `decimals()` on an ERC-20. */
export async function getDecimals(url: string, token: string): Promise<number | EvmFailure> {
  const result = await rpc<string>(url, 'eth_call', [{ to: token.toLowerCase(), data: '0x313ce567' }, 'latest'])
  if (isEvmFailure(result)) return result
  const n = hexToBigInt(result)
  if (n === null || n < 0n || n > 36n) {
    return { code: 'malformed', message: 'The token reports an implausible decimal count.' }
  }
  return Number(n)
}

export function hexToBigInt(hex: unknown): bigint | null {
  if (typeof hex !== 'string' || !/^0x[0-9a-fA-F]*$/.test(hex)) return null
  return hex === '0x' ? 0n : BigInt(hex)
}

/** A 32-byte topic word carrying an address in its low 20 bytes. */
export function addressFromTopic(topic: string): string | null {
  if (typeof topic !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(topic)) return null
  return '0x' + topic.slice(26).toLowerCase()
}

export function sameAddress(a: string | null | undefined, b: string | null | undefined): boolean {
  if (!a || !b) return false
  return a.trim().toLowerCase() === b.trim().toLowerCase()
}

export function isTxHash(value: string): boolean {
  return /^0x[0-9a-fA-F]{64}$/.test(value.trim())
}

export function isAddress(value: string): boolean {
  return /^0x[0-9a-fA-F]{40}$/.test(value.trim())
}

export interface TokenTransfer {
  from: string
  to: string
  amount: bigint
  logIndex: number
}

/**
 * Every ERC-20 transfer of ONE token in a receipt, in log order.
 *
 * Filtered on the emitting contract as well as the topic, which is what stops a
 * transaction that also moves some other token from being read as a payment.
 * A malformed log is skipped rather than throwing — but see the caller: it
 * counts what it found and refuses anything that is not exactly one.
 */
export function transfersOf(receipt: Receipt, token: string): TokenTransfer[] {
  const out: TokenTransfer[] = []
  for (const log of receipt.logs ?? []) {
    if (!sameAddress(log.address, token)) continue
    if (!Array.isArray(log.topics) || log.topics[0]?.toLowerCase() !== TRANSFER_TOPIC) continue
    const from = addressFromTopic(log.topics[1])
    const to = addressFromTopic(log.topics[2])
    const amount = hexToBigInt(log.data)
    if (from === null || to === null || amount === null) continue
    out.push({ from, to, amount, logIndex: Number(hexToBigInt(log.logIndex) ?? 0n) })
  }
  return out
}
